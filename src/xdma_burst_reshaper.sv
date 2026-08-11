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
    // The xdma_req_idx_t value that gates the AW/W-channel write-data path: a
    // request only counts as write data, and is only grant-gated, when its index
    // matches. The wide adapter passes `ToRemoteData`, the sole wide entry, so
    // the gate is always active for wide writes. The narrow adapter takes the
    // default `'0`, which in the narrow encoding is `ToRemoteFinish`; that is
    // harmless because the narrow backend ties `write_req_grant_i` high.
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
      // Three states in a 2-bit encoding; keep the unused one from being absorbing.
      default: next_state = IDLE;
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
      default: begin
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
  // The `lens_counter_q == 0` arm exists only to bound the damage of a malformed
  // zero-length descriptor. `num_beats` is 8 bit and `len = num_beats - 1`, so a zero
  // count would underflow to `awlen = 255` and open a 256-beat burst on the shared bus
  // that nothing will ever feed -- far worse than the single stray beat this emits.
  // A zero length is not reachable from the frontend (`readyToTransfer` follows
  // reader/writer busy, which never asserts for a zero-length transfer); the assertion
  // below catches it if that ever changes. Note the deliberate truncation in the middle
  // arm: the narrow instance has MaxNumBeats = 256, which wraps to 8'd0 and pairs with
  // `awlen = 255` to mean exactly 256 beats.
  assign num_beats = (lens_counter_q == 0)          ? 8'd1 :
                     (lens_counter_q >= MaxNumBeats) ? MaxNumBeats : lens_counter_q;
  always_comb begin : proc_pack_write_req
    //-----------------------
    // create the AW request
    //-----------------------        
    write_req_aw_desc_o.id = write_req_desc_i.dma_id;
    write_req_aw_desc_o.addr = write_req_desc_i.remote_addr;
    write_req_aw_desc_o.len = num_beats - 1;  // the minus 1 here is from Length = axLen + 1
    // AWSIZE is log2(bytes-per-beat) and must equal this instance's strobe width, or the
    // burst claims a beat wider than the bus it rides -- an AXI protocol violation that an
    // FPGA interconnect, an axi_protocol_checker or a synthesis DRC will flag. Derived from
    // StrbWidth so each instance is right by construction: 3'b110 wide, 3'b011 narrow.
    write_req_aw_desc_o.size = 3'($clog2(StrbWidth));  // per-instance: 6 wide, 3 narrow
    write_req_aw_desc_o.burst = 2'b01;  // BURST TYPE: INCR
    // AxCACHE = 0010: bit 1 is `axi_pkg::CACHE_MODIFIABLE`, telling the interconnect it may
    // reshape this burst. The other three bits stay 0 (non-bufferable, non-cacheable),
    // which is what an MMIO-style target wants. 
    //
    // WHY MODIFIABLE. `axi_dw_upsizer` packs narrow beats into wide ones ONLY when
    // `modifiable(aw.cache)` holds; otherwise it takes its passthrough branch and forwards
    // the original `len`/`size` unchanged. The cross-cluster cfg frame is 512 bit but
    // leaves the NARROW port as 8 x 64 bit beats (`to_remote_cfg_desc.dma_length =
    // frame_length << WIDE_NARROW_DW_BITS` in xdma_axi_adapter_top). A cross-die cfg
    // carries a foreign chip id, matches no rule in the SoC narrow crossbar, and therefore
    // default-routes onto the narrow->wide bridge (`axi_dw_converter` 64->512) on its way
    // to the D2D link. With AxCACHE = 0 that bridge spends 8 x 512 bit beats carrying 8
    // useful bytes each; with the bit set it emits ONE full 64 B beat. Same bytes, 8x fewer
    // beats across the wide crossbar and the die boundary.
    //
    // WHY IT IS SAFE. The packing is undone symmetrically at the far end: `axi_dw_downsizer`
    // does NOT gate on `modifiable` -- it splits any INCR whose `size` exceeds the master
    // width -- so the 64 B beat becomes 8 x 8 B beats at the original addresses, all inside
    // the same 4 KiB cfg MMIO window, and the receiving `xdma_write_demux` /
    // `i_cfg_dw_up_converter` reassemble exactly what they see today. The cfg base is 4 KiB
    // aligned (MMIOCFGOffset), so a frame packs into whole wide beats with no partial head
    // or tail.
    //
    // WHAT IS UNAFFECTED. `to_remote_grant` / `to_remote_finish` are single-beat
    // (`dma_length = 1`, so `len == 0`) and a width converter never reshapes a single-beat
    // burst. The wide `ToRemoteData` path is already at full width, so no converter packs
    // it either; the bit is inert there.
    write_req_aw_desc_o.cache = 4'b0010;
    write_req_aw_desc_o.is_write_data = is_write_data;
    //-----------------------
    // Create the W request
    //-----------------------
    write_req_w_desc_o.num_beats = num_beats;
    write_req_w_desc_o.is_single = (num_beats == 8'd1);
    write_req_w_desc_o.is_write_data = is_write_data;
  end

`ifndef SYNTHESIS
  // A zero-length descriptor cannot be served: the burst it would open has no beats, and
  // xdma_meta_manager compares against `dma_length - 1`, which underflows so `done` never
  // fires and the port hangs. Catch it where it originates rather than downstream.
  assert property (@(posedge clk_i) disable iff (!rst_ni)
      write_req_desc_valid_i |-> (write_req_desc_i.dma_length != 0))
    else $error("xdma_burst_reshaper: zero-length write descriptor accepted");
`endif

endmodule
