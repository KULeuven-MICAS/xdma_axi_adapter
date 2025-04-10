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
  // addr_t remote_addr_q;
  // delta_counter #(
  //     .WIDTH($bits(addr_t))
  // ) i_addr_counter(
  //     .clk_i     (clk_i            ),
  //     .rst_ni    (rst_ni           ),
  //     .clear_i   (counter_clear    ),
  //     .en_i      (counter_en       ),
  //     .load_i    (counter_load     ),
  //     .down_i    (1'b0             ),
  //     .delta_i   (PageSize         ),
  //     .d_i       (write_req_desc_i.remote_addr),
  //     .q_o       (remote_addr_q    ),
  //     .overflow_o()
  // );


  logic finish;
  assign finish = (lens_counter_q < MaxNumBeats) & write_req_desc_ready_i;
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
  assign num_beats = (lens_counter_q >= MaxNumBeats) ? MaxNumBeats : lens_counter_q;
  always_comb begin : proc_pack_write_req
    //-----------------------
    // create the AW request
    //-----------------------        
    write_req_aw_desc_o.id = write_req_desc_i.dma_id;
    write_req_aw_desc_o.addr = write_req_desc_i.remote_addr;
    write_req_aw_desc_o.len = num_beats - 1;  // the minus 1 here is from Length = axLen + 1
    write_req_aw_desc_o.size = 3'b110;  // 64B //TODO: Should compute from a function
    write_req_aw_desc_o.burst = 2'b01;  // BURST TYPE
    write_req_aw_desc_o.cache = 3'b0;
    //-----------------------
    // Create the W request
    //-----------------------
    write_req_w_desc_o.num_beats = num_beats;
    write_req_w_desc_o.is_single = (num_beats == 8'd1);
    write_req_w_desc_o.is_write_data = (write_req_idx_i==xdma_pkg::ToRemoteData) && (write_req_desc_i.dma_type);
  end


  // // Here we need to split the too long req (exceed 4KB size) to smaller req
  // // for standard 4KB page
  // // we have 64B/beat
  // // => one aw can send at most 64beats => aw.len at most 63 (Length = awLen + 1)
  // // If we have more than 64 dma_length, we need to split it into several small reqs

  // //--------------------------------------
  // // state; internally hold one transfer
  // //--------------------------------------
  // xdma_req_desc_t xdma_req_d, xdma_req_q;
  // logic xdma_req_valid_d, xdma_req_valid_q;
  // logic [7:0] w_num_lengths;
  // logic       w_finish;

  // always_comb begin : proc_write_transaction
  //     // default: keep last state
  //     xdma_req_d = xdma_req_q;
  //     xdma_req_valid_d = xdma_req_valid_q;
  //     // more bytes remaining than we can send
  //     if (xdma_req_q.dma_length > MaxNumBeats) begin
  //         w_num_lengths = MaxNumBeats;
  //         // update the dma_length
  //         xdma_req_d.dma_length = xdma_req_q.dma_length - MaxNumBeats;
  //         // not finished
  //         w_finish = 1'b0;
  //         // next address, depends on burst type. only type 01 is supported yet
  //         xdma_req_d.remote_addr = xdma_req_q.remote_addr + PageSize;

  //         // remaining bytes fit in one burst
  //         // reset storage for the write channel to stop this channel
  //     end else begin
  //         w_num_lengths = xdma_req_q.dma_length;
  //         // default: when a transfer is finished, set it to 0
  //         xdma_req_d.remote_addr = '0;
  //         // finished
  //         w_finish    = 1'b1;
  //     end
  //     //-----------------------
  //     // create the AW request
  //     //-----------------------
  //     write_req_aw_desc_o.id   = xdma_req_q.dma_id;
  //     write_req_aw_desc_o.addr = xdma_req_q.remote_addr;
  //     write_req_aw_desc_o.len  = w_num_lengths - 1; // the minus 1 here is from Length = axLen + 1
  //                                                // hence axLen = Length - 1
  //     write_req_aw_desc_o.size = 3'b110; // 64B //TODO: Should compute from a function
  //     write_req_aw_desc_o.burst = 2'b01; // BURST TYPE
  //     write_req_aw_desc_o.cache = 3'b0;  
  //     //-----------------------
  //     // Create the W request
  //     //-----------------------
  //     write_req_w_desc_o.num_beats = w_num_lengths;
  //     write_req_w_desc_o.is_single = (w_num_lengths == 8'd1);
  //     // the data needs to from the to_remote_data port and the type is write
  //     write_req_w_desc_o.is_write_data = (write_req_idx_i==xdma_pkg::ToRemoteData) && (xdma_req_q.dma_type);


  //     //--------------------------------------
  //     // Module control
  //     //--------------------------------------
  //     write_req_desc_valid_o = (write_req_desc_i == '0) ? 1'b0 : xdma_req_valid_q;
  //     write_req_desc_ready_o = w_finish & write_req_desc_valid_i & write_req_desc_ready_i;
  //     //--------------------------------------
  //     // Refill
  //     //--------------------------------------
  //     // new request is taken in if w machines are ready.
  //     if (write_req_desc_ready_o) begin
  //         xdma_req_d.dma_id      = write_req_desc_i.dma_id;
  //         xdma_req_d.dma_type    = write_req_desc_i.dma_type;
  //         xdma_req_d.remote_addr = write_req_desc_i.remote_addr;
  //         xdma_req_d.dma_length   = write_req_desc_i.dma_length;
  //         xdma_req_d.ready_to_transfer = write_req_desc_i.ready_to_transfer;
  //         xdma_req_valid_d = write_req_desc_valid_i;
  //     end        
  // end

  // //--------------------------------------
  // // State
  // //--------------------------------------
  // always_ff @(posedge clk_i or negedge rst_ni) begin
  //     if (!rst_ni) begin
  //         xdma_req_q       <= '0;
  //         xdma_req_valid_q <= '0;
  //     end else begin
  //     if (write_req_desc_ready_i) begin
  //         xdma_req_q       <= xdma_req_d;
  //         xdma_req_valid_q <= xdma_req_valid_d;
  //     end
  //     end
  // end
endmodule
