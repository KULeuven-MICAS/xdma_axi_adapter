// Fanchen Kong <fanchen.kong@kuleuven.be>
// Yunhao Deng <yunhao.deng@kuleuven.be>

// In XDMA we only need the aw/w to transfer data/cfg
module xdma_axi_to_write #(
    /// AXI4+ATOP request type. See `include/axi/typedef.svh`.
    parameter type axi_in_req_t  = logic,
    /// AXI4+ATOP response type. See `include/axi/typedef.svh`.
    parameter type axi_in_resp_t = logic,
    ///
    parameter type data_t        = logic,
    parameter type addr_t        = logic,
    parameter type axi_id_t      = logic,
    parameter type strb_t        = logic,
    /// Reqrsp request channel type.
    parameter type reqrsp_req_t  = logic,
    /// Reqrsp response channel type.
    parameter type reqrsp_rsp_t  = logic

) (
    /// Clock input.
    input  logic         clk_i,
    /// Asynchronous reset, active low.
    input  logic         rst_ni,
    /// The unit is busy handling an AXI4+ATOP request.
    output logic         busy_o,
    /// AXI4+ATOP slave port, request input.
    input  axi_in_req_t  axi_req_i,
    /// AXI4+ATOP slave port, response output.
    output axi_in_resp_t axi_rsp_o,
    /// Reqrsp request channel.
    output reqrsp_req_t  reqrsp_req_o,
    /// Reqrsp respone channel.
    input  reqrsp_rsp_t  reqrsp_rsp_i
);
  typedef struct packed {
    addr_t          addr;
    axi_pkg::atop_t atop;
    axi_id_t        id;
    logic           last;
    axi_pkg::qos_t  qos;
    axi_pkg::size_t size;
    logic           write;
    logic           lock;
  } meta_t;
  axi_pkg::len_t w_cnt_d, w_cnt_q;
  logic wr_valid, wr_ready;
  meta_t wr_meta, wr_meta_d, wr_meta_q;
  assign busy_o   = axi_req_i.aw_valid | axi_req_i.w_valid | (w_cnt_q > 0);
  assign wr_ready = reqrsp_rsp_i.q_ready;
  // Handle writes.
  always_comb begin
    // Default assignments
    axi_rsp_o.aw_ready = 1'b0;
    axi_rsp_o.w_ready  = 1'b0;
    wr_meta_d          = wr_meta_q;
    wr_meta            = '{default: '0};
    wr_valid           = 1'b0;
    w_cnt_d            = w_cnt_q;
    // Handle W bursts in progress.
    if (w_cnt_q > '0) begin
      wr_meta_d.last = (w_cnt_q == 8'd1);
      wr_meta        = wr_meta_d;
      wr_meta.addr   = wr_meta_q.addr + axi_pkg::num_bytes(wr_meta_q.size);
      if (axi_req_i.w_valid) begin
        wr_valid = 1'b1;
        if (wr_ready) begin
          axi_rsp_o.w_ready = 1'b1;
          w_cnt_d--;
          wr_meta_d.addr = wr_meta.addr;
        end
      end
      // Handle new AW if there is one.
    end else if (axi_req_i.aw_valid && axi_req_i.w_valid) begin
      wr_meta_d = '{
          addr: addr_t'(axi_pkg::aligned_addr(axi_req_i.aw.addr, axi_req_i.aw.size)),
          atop: axi_req_i.aw.atop,
          id: axi_req_i.aw.id,
          last: (axi_req_i.aw.len == '0),
          qos: axi_req_i.aw.qos,
          size: axi_req_i.aw.size,
          write: 1'b1,
          lock: axi_req_i.aw.lock
      };
      wr_meta = wr_meta_d;
      wr_meta.addr = addr_t'(axi_req_i.aw.addr);
      wr_valid = 1'b1;
      if (wr_ready) begin
        w_cnt_d = axi_req_i.aw.len;
        axi_rsp_o.aw_ready = 1'b1;
        axi_rsp_o.w_ready = 1'b1;
      end
    end
  end

  // Compose the req channel
  always_comb begin : proc_req_compose
    reqrsp_req_o.addr = wr_meta.addr;
    reqrsp_req_o.write = wr_meta.write;
    reqrsp_req_o.amo = xdma_pkg::AMONone;
    reqrsp_req_o.data = (wr_meta.write) ? axi_req_i.w.data : '0;
    reqrsp_req_o.strb = (wr_meta.write) ? axi_req_i.w.strb : '0;
    reqrsp_req_o.size = wr_meta.size;
    reqrsp_req_o.q_valid = wr_valid;
    reqrsp_req_o.p_ready = 1'b1;
  end


  // Tie-off unused axi rsp
  // We do not need any ar channel
  always_comb begin : proc_ar_compose
    axi_rsp_o.ar_ready = '0;
  end

  // We do not need any r channel
  always_comb begin : proc_r_compose
    axi_rsp_o.r = '0;
    axi_rsp_o.r_valid = '0;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin : proc_ff
    if (!rst_ni) begin
      wr_meta_q <= meta_t'{default: '0};
      w_cnt_q   <= '0;
    end else begin
      wr_meta_q <= wr_meta_d;
      w_cnt_q   <= w_cnt_d;
    end
  end

  // Simple B Response
  // After we get the w last signal we send a B
  // The state enum
  logic b_valid;
  typedef enum logic [0:0] {
    IDLE,
    B_SEND_VALID
  } state_t;
  state_t cur_state, next_state;
  // State Update
  always_ff @(posedge clk_i, negedge rst_ni) begin
    if (!rst_ni) begin
      cur_state <= IDLE;
    end else begin
      cur_state <= next_state;
    end
  end
  // Next state logic
  always_comb begin
    next_state = cur_state;
    case (cur_state)
      // Any of the valid is high, the next state is busy
      IDLE: if (wr_meta_d.last && wr_valid && wr_ready) next_state = B_SEND_VALID;
      B_SEND_VALID: if (axi_req_i.b_ready) next_state = IDLE;
    endcase
  end
  // Output logic
  always_comb begin
    b_valid = 1'b0;
    case (cur_state)
      IDLE: b_valid = 1'b0;
      B_SEND_VALID: b_valid = 1'b1;
    endcase
  end
  always_comb begin : proc_b_compose
    axi_rsp_o.b = '0;
    axi_rsp_o.b.id = wr_meta_q.id;
    axi_rsp_o.b.resp = 2'b00;  // RESP_OK
    axi_rsp_o.b_valid = b_valid;
  end
endmodule
