// Fanchen Kong <fanchen.kong@kuleuven.be>
// Yunhao Deng <yunhao.deng@kuleuven.be>

// Send the write request in AXI-conform transfers
// Since the xdma only uses the aw/w to send/receive data
// This rtl only handles the write_req
module xdma_burst_reshaper #(
    parameter type data_t          = logic,
    parameter type addr_t          = logic,
    parameter type len_t           = logic,
    parameter type xdma_req_idx_t  = logic,
    // typedef struct packed {
    //     id_t                                 dma_id; 
    //     logic                                dma_type;
    //     addr_t                               remote_addr;
    //     len_t                                dma_length;
    //     logic                                ready_to_transfer;
    // } xdma_req_desc_t;   
    parameter type xdma_req_desc_t = logic,

    // typedef struct packed {
    //     id_t                                 id;
    //     addr_t                               addr;
    //     logic [7:0]                          len;
    //     logic [2:0]                          size;
    //     logic [1:0]                          burst;
    //     logic [3:0]                          cache;
    // } xdma_req_aw_desc_t;
    parameter type xdma_req_aw_desc_t = logic,
    // typedef struct packed {
    //     logic [7:0]                         num_beats;
    //     logic                               is_single;
    //     logic                               is_write_data;
    // } xdma_req_w_desc_t;
    parameter type xdma_req_w_desc_t = logic,
    // The xdma_req_idx_t value that gates the AW/W-channel write-data path.
    // Wide adapter passes `ToRemoteData` (value 0 in xdma_wide_to_remote_idx_e
    // — the only wide entry, so the gate is always-active for wide writes).
    // Narrow adapter leaves the default `'0` to preserve the pre-refactor
    // behaviour (the original code compared against `xdma_pkg::ToRemoteData`,
    // which in the narrow encoding aliases to `ToRemoteFinish`).
    parameter xdma_req_idx_t WriteDataIdx = '0,
    // Dependent Parameters
    parameter int unsigned DataWidth = $bits(data_t),  //512
    parameter int unsigned StrbWidth = DataWidth / 8,  //64
    parameter addr_t       PageSize          = (256 * StrbWidth > 4096) ? 4096 : 256 * StrbWidth, // 256 is max axi length
    parameter len_t MaxNumBeats = PageSize / StrbWidth  // 4096/64 = 64

) (
    /// Clock
    input  logic              clk_i,
    /// Asynchronous reset, active low
    input  logic              rst_ni,
    ///
    input  logic              write_req_done_i,
    ///
    input  xdma_req_desc_t    write_req_desc_i,
    ///
    input  xdma_req_idx_t     write_req_idx_i,
    /// Handshake: burst request is valid
    input  logic              write_req_desc_valid_i,
    /// Write transfer request
    output xdma_req_aw_desc_t write_req_aw_desc_o,
    output xdma_req_w_desc_t  write_req_w_desc_o,
    /// Handshake: write transfer request valid
    output logic              write_req_desc_valid_o,
    /// Handshake: write transfer request ready
    input  logic              write_req_desc_ready_i
);
  //--------------------------------------
  // remain lens counter
  //--------------------------------------

  logic counter_en;
  logic counter_clear;
  logic counter_load;
  len_t lens_counter_q;

  delta_counter #(
      .WIDTH($bits(len_t))
  ) i_lens_counter (
      .clk_i     (clk_i),
      .rst_ni    (rst_ni),
      .clear_i   (counter_clear),
      .en_i      (counter_en),
      .load_i    (counter_load),
      .down_i    (1'b1),
      .delta_i   (MaxNumBeats),
      .d_i       (write_req_desc_i.dma_length),
      .q_o       (lens_counter_q),
      .overflow_o()
  );

  logic finish;
  assign finish = (lens_counter_q <= MaxNumBeats) & write_req_desc_ready_i;
  // The state enum
  typedef enum logic [1:0] {
    IDLE,
    BUSY,
    FINISH
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
  always_comb begin : proc_next_state_logic
    next_state = cur_state;
    case (cur_state)
      IDLE:   if (write_req_desc_valid_i) next_state = BUSY;
      BUSY:   if (finish) next_state = FINISH;
      FINISH: if (write_req_done_i) next_state = IDLE;
    endcase
  end



  // Output logic
  always_comb begin : proc_output_logic
    counter_en = 1'b0;
    counter_clear = 1'b0;
    counter_load = 1'b0;
    write_req_desc_valid_o = 1'b0;
    case (cur_state)
      IDLE: begin
        counter_en = 1'b0;
        counter_clear = 1'b0;
        if (write_req_desc_valid_i) counter_load = 1'b1;
        write_req_desc_valid_o = 1'b0;
      end
      BUSY: begin
        counter_en = write_req_desc_ready_i;
        counter_clear = finish;
        counter_load = 1'b0;
        write_req_desc_valid_o = 1'b1;
      end
      FINISH: begin
        counter_en = 1'b0;
        counter_clear = 1'b1;
        counter_load = 1'b0;
        write_req_desc_valid_o = 1'b0;
      end
    endcase
  end

  logic [7:0] num_beats;
  logic is_write_data;
  // Gates the AW/W write-data path; see `WriteDataIdx` declaration above for
  // the wide vs narrow contract.
  assign is_write_data =  (write_req_idx_i==WriteDataIdx) && (write_req_desc_i.dma_type);
  assign num_beats = (lens_counter_q >= MaxNumBeats) ? MaxNumBeats : lens_counter_q;
  always_comb begin : proc_pack_write_req
    //-----------------------
    // create the AW request
    //-----------------------        
    write_req_aw_desc_o.id = write_req_desc_i.dma_id;
    write_req_aw_desc_o.addr = write_req_desc_i.remote_addr;
    write_req_aw_desc_o.len = num_beats - 1;  // the minus 1 here is from Length = axLen + 1
    // AWSIZE = log2(bytes-per-beat) MUST equal the instance's strobe width, or it is an AXI
    // protocol violation: the wide instance (StrbWidth=64) needs 3'b110, the narrow CFG
    // instance (StrbWidth=8) needs 3'b011. The old hardcoded 3'b110 was illegal on the narrow
    // master (claims 64 B/beat on an 8-byte bus). It is inert in functional sim -- cache is
    // hardcoded 0 below, so the downstream axi_dw_upsizer takes W_PASSTHROUGH (never reads
    // AWSIZE), the memory endpoint places bytes from WSTRB, and no protocol checker runs -- but
    // an FPGA AXI interconnect (SmartConnect) / axi_protocol_checker / synthesis DRC flags it.
    write_req_aw_desc_o.size = 3'($clog2(StrbWidth));  // per-instance: 6 wide, 3 narrow
    write_req_aw_desc_o.burst = 2'b01;  // BURST TYPE
    write_req_aw_desc_o.cache = 3'b0;
    write_req_aw_desc_o.is_write_data = is_write_data;
    //-----------------------
    // Create the W request
    //-----------------------
    write_req_w_desc_o.num_beats = num_beats;
    write_req_w_desc_o.is_single = (num_beats == 8'd1);
    write_req_w_desc_o.is_write_data = is_write_data;
  end

endmodule
