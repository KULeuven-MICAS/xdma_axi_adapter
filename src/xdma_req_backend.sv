// Authors:
// - Fanchen Kong <fanchen.kong@kuleuven.be>
// - Yunhao Deng <yunhao.deng@kuleuven.be>

module xdma_req_backend #(
    /// Number of AX beats that can be in-flight
    parameter int unsigned ReqFifoDepth = -1,

    /// Data
    parameter type addr_t = logic,
    parameter type data_t = logic,
    parameter type strb_t = logic,
    parameter type len_t  = logic,

    parameter type xdma_req_idx_t     = logic,
    // typedef struct packed {
    //     id_t                                 dma_id; 
    //     logic                                dma_type;
    //     addr_t                               remote_addr;
    //     len_t                                dma_length;
    //     logic                                ready_to_transfer;
    // } xdma_req_desc_t;   
    parameter type xdma_req_desc_t    = logic,
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
    parameter type xdma_req_w_desc_t  = logic,
    // The xdma_req_idx_t value that identifies a write-data burst. Passed
    // through to xdma_burst_reshaper; see its declaration for the full
    // rationale. Caller (xdma_axi_adapter_top) supplies the appropriate
    // enum literal (`ToRemoteData` for the wide instance).
    parameter xdma_req_idx_t WriteDataIdx = '0,
    // Whole-burst writes. Every request on this instance is a write-data burst (the wide path's
    // only request is ToRemoteData). Its data first fills a buffer of WBufBeats beats; a burst's
    // AW leaves only once every beat of THAT burst is in the buffer, and its W beats leave only
    // after its AW, back to back. A burst that holds a shared AXI port's write order (an
    // interconnect delivers W in AW order) then always has its data, whatever the beats behind
    // it are waiting for. Clear: the AW leaves as soon as a W beat is ready, as before.
    parameter bit          WholeBurstWrite = 1'b0,
    // At least the longest burst the reshaper cuts (a 4 KiB page; 64 beats at 512 bit),
    // otherwise such a burst could never be whole in the buffer.
    parameter int unsigned WBufBeats       = 32'd64,

    /// Enable or disable tracing
    parameter bit  DmaTracing     = 0,
    /// AXI4+ATOP request struct definition.
    parameter type axi_out_req_t  = logic,
    /// AXI4+ATOP response struct definition.
    parameter type axi_out_resp_t = logic
) (
    /// Clock
    input  logic           clk_i,
    /// Asynchronous reset, active low
    input  logic           rst_ni,
    /// Inpt Data 
    input  data_t          write_req_data_i,
    /// Handshake
    input  logic           write_req_data_valid_i,
    /// Handshake
    output logic           write_req_data_ready_o,
    /// Grant
    input  logic           write_req_grant_i,
    /// Req Done
    input  logic           write_req_done_i,
    ///
    input  xdma_req_idx_t  write_req_idx_i,
    /// Req Description
    input  xdma_req_desc_t write_req_desc_i,
    /// Handshake
    input  logic           write_req_desc_valid_i,
    /// AXI Interface
    /// AXI4+ATOP master request
    output axi_out_req_t   axi_dma_req_o,
    /// AXI4+ATOP master response
    input  axi_out_resp_t  axi_dma_resp_i
);
  //--------------------------------------
  // XDMA Burst Reshaper
  //--------------------------------------
  xdma_req_aw_desc_t xdma_req_aw_desc;
  xdma_req_w_desc_t xdma_req_w_desc;
  logic write_req_desc_valid;
  logic write_req_desc_ready;
  xdma_burst_reshaper #(
      .data_t            (data_t),
      .len_t             (len_t),
      .addr_t            (addr_t),
      .xdma_req_idx_t    (xdma_req_idx_t),
      .xdma_req_desc_t   (xdma_req_desc_t),
      .xdma_req_aw_desc_t(xdma_req_aw_desc_t),
      .xdma_req_w_desc_t (xdma_req_w_desc_t),
      .WriteDataIdx      (WriteDataIdx)
  ) i_xdma_burst_reshaper (
      .clk_i                 (clk_i),
      .rst_ni                (rst_ni),
      .write_req_done_i      (write_req_done_i),
      // Input data
      .write_req_desc_i      (write_req_desc_i),
      .write_req_idx_i       (write_req_idx_i),
      .write_req_desc_valid_i(write_req_desc_valid_i),
      // Output data
      .write_req_aw_desc_o   (xdma_req_aw_desc),
      .write_req_w_desc_o    (xdma_req_w_desc),
      .write_req_desc_valid_o(write_req_desc_valid),
      .write_req_desc_ready_i(write_req_desc_ready)
  );

  //--------------------------------------
  // AW emitter
  //--------------------------------------
  // object currently at the tail of the fifo
  xdma_req_aw_desc_t current_req_aw_desc;
  // control signals
  logic aw_emitter_full;
  logic aw_emitter_empty;
  logic aw_emitter_push;
  logic aw_emitter_pop;

  // instantiate a fifo to buffer the address write requests
  fifo_v3 #(
      .FALL_THROUGH(1'b0),
      .dtype       (xdma_req_aw_desc_t),
      .DEPTH       (ReqFifoDepth)
  ) i_fifo_aw_emitter (
      .clk_i     (clk_i),
      .rst_ni    (rst_ni),
      .flush_i   (1'b0),
      .testmode_i(1'b0),
      .full_o    (aw_emitter_full),
      .empty_o   (aw_emitter_empty),
      .usage_o   (),
      .data_i    (xdma_req_aw_desc),
      .push_i    (aw_emitter_push),
      .data_o    (current_req_aw_desc),
      .pop_i     (aw_emitter_pop)
  );

  //--------------------------------------
  // W emitter
  //--------------------------------------
  // object currently at the tail of the fifo
  xdma_req_w_desc_t current_req_w_desc;
  // control signals
  logic w_emitter_full;
  logic w_emitter_empty;
  logic w_emitter_push;
  logic w_emitter_pop;

  // instanciate a fifo to buffer the write requests
  fifo_v3 #(
      .FALL_THROUGH(1'b0),
      .dtype       (xdma_req_w_desc_t),
      .DEPTH       (ReqFifoDepth)
  ) i_fifo_w_emitter (
      .clk_i     (clk_i),
      .rst_ni    (rst_ni),
      .flush_i   (1'b0),
      .testmode_i(1'b0),
      .full_o    (w_emitter_full),
      .empty_o   (w_emitter_empty),
      .usage_o   (),
      .data_i    (xdma_req_w_desc),
      .push_i    (w_emitter_push),
      .data_o    (current_req_w_desc),
      .pop_i     (w_emitter_pop)
  );

  //--------------------------------------
  // XDMA Data Path
  //--------------------------------------
  logic  w_dp_valid;
  logic  w_dp_ready;
  data_t w_data;
  strb_t w_strb;
  logic  w_last;
  logic  w_valid;
  logic  w_ready;
  // The data path's input: the request data itself, or with WholeBurstWrite the buffer's head
  data_t dp_data;
  logic  dp_data_valid;
  logic  dp_data_ready;
  // With WholeBurstWrite: the AW at the head of the emitter may leave (its whole burst is
  // buffered); without, always
  logic  aw_burst_whole;
  xdma_data_path #(
      .data_t           (data_t),
      .strb_t           (strb_t),
      .xdma_req_w_desc_t(xdma_req_w_desc_t)
  ) i_xdma_data_path (
      .clk_i                 (clk_i),
      .rst_ni                (rst_ni),
      // Data
      .write_req_data_i      (dp_data),
      .write_req_data_valid_i(dp_data_valid),
      .write_req_data_ready_o(dp_data_ready),
      // Grant
      .write_req_grant_i     (write_req_grant_i),
      // From W emitter
      .w_desc_i              (current_req_w_desc),
      .w_dp_valid_i          (w_dp_valid),
      .w_dp_ready_o          (w_dp_ready),
      // AXI Interface
      .w_data_o              (w_data),
      .w_strb_o              (w_strb),
      .w_last_o              (w_last),
      .w_valid_o             (w_valid),
      .w_ready_i             (w_ready)
  );
  assign w_dp_valid = !w_emitter_empty;
  assign w_emitter_pop = w_dp_ready & !w_emitter_empty;

  //--------------------------------------
  // Whole-burst buffer (WholeBurstWrite)
  //--------------------------------------
  if (WholeBurstWrite) begin : gen_whole_burst
    // The longest burst the reshaper cuts: a 4 KiB page, or 256 beats when a page holds more
    localparam int unsigned BeatBytes     = $bits(data_t) / 8;
    localparam int unsigned MaxBurstBeats = (256 * BeatBytes > 4096) ? 4096 / BeatBytes : 256;
    localparam int unsigned CntWidth      = $clog2(WBufBeats + 1);
    if (WBufBeats < MaxBurstBeats) begin : gen_bad_depth
      $fatal(1, "xdma_req_backend: WBufBeats = %0d cannot hold a whole %0d-beat burst",
             WBufBeats, MaxBurstBeats);
    end

    logic                                       buf_in_ready, buf_valid;
    logic [((WBufBeats > 1) ? $clog2(WBufBeats) : 1)-1:0] buf_usage;
    logic [CntWidth-1:0]                        buf_beats;       // beats in the buffer
    // Beats of the bursts whose AW has left and that are still to go out on W. They are the
    // oldest in the buffer (an AW leaves only once its burst is in it).
    logic [CntWidth-1:0]                        owed_q, owed_d;
    logic [CntWidth-1:0]                        head_burst_beats;

    // A data write (WriteDataIdx with dma_type set) is taken only once granted, as the data path
    // takes it without the buffer. Anything else, such as the payload a remote READ sends back
    // (dma_type 0, never granted), is taken as it comes.
    logic in_needs_grant;
    assign in_needs_grant = (write_req_idx_i == WriteDataIdx) && write_req_desc_i.dma_type;
    stream_fifo #(
        .FALL_THROUGH(1'b0),
        .DEPTH       (WBufBeats),
        .T           (data_t)
    ) i_w_buf (
        .clk_i     (clk_i),
        .rst_ni    (rst_ni),
        .flush_i   (1'b0),
        .testmode_i(1'b0),
        .usage_o   (buf_usage),
        .data_i    (write_req_data_i),
        .valid_i   (write_req_data_valid_i & (write_req_grant_i | ~in_needs_grant)),
        .ready_o   (buf_in_ready),
        .data_o    (dp_data),
        .valid_o   (buf_valid),
        .ready_i   (dp_data_ready & (owed_q != '0))
    );
    assign write_req_data_ready_o = buf_in_ready & (write_req_grant_i | ~in_needs_grant);
    // a W beat goes out only for a burst whose AW has left
    assign dp_data_valid          = buf_valid & (owed_q != '0);

    // usage_o reads 0 when the buffer is full
    assign buf_beats        = buf_in_ready ? CntWidth'(buf_usage) : CntWidth'(WBufBeats);
    assign head_burst_beats = CntWidth'(current_req_aw_desc.len) + CntWidth'(1);
    // the head AW's burst is whole once the beats past those still owed cover it
    assign aw_burst_whole   = (buf_beats - owed_q) >= head_burst_beats;

    always_comb begin
      owed_d = owed_q;
      if (aw_emitter_pop) owed_d = owed_d + head_burst_beats;
      if (w_valid && w_ready) owed_d = owed_d - CntWidth'(1);
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) owed_q <= '0;
      else owed_q <= owed_d;
    end
  end else begin : gen_pass_through
    assign dp_data                = write_req_data_i;
    assign dp_data_valid          = write_req_data_valid_i;
    assign write_req_data_ready_o = dp_data_ready;
    assign aw_burst_whole         = 1'b1;
  end
  //--------------------------------------
  // Refill control
  //--------------------------------------
  // the aw and w fifos of both channels are filled
  // together, as request come bundled.
  // A ToRemoteData write must not be ACCEPTED into the emitter FIFOs until it is allowed to be
  // EMITTED. The two conditions used to be asymmetric, and that asymmetry stranded descriptors:
  //
  //   push: write_req_desc_valid & ~fifo_full                       (unconditional)
  //   pop : aw_ready & aw_valid, and for is_write_data `aw_valid`
  //         additionally needs write_req_grant_i && w_valid
  //
  // So a to-remote write that was armed but never granted -- or granted but never supplied with
  // W data -- pushed a descriptor that could not be emitted and that nothing ever removed. The
  // emitter FIFOs have `flush_i` tied low, so the descriptor SURVIVED THE END OF ITS TRANSFER,
  // carrying that transfer's destination address. The next to-remote write at this node popped
  // it and was routed to the PREVIOUS transfer's destination.
  
  logic write_req_emittable;
  assign write_req_emittable = ~xdma_req_aw_desc.is_write_data | write_req_grant_i;

  always_comb begin : proc_refill

    // Write related channels
    write_req_desc_ready = ~aw_emitter_full & ~w_emitter_full & write_req_emittable;
    w_emitter_push       = write_req_desc_valid & write_req_desc_ready;
    aw_emitter_push      = write_req_desc_valid & write_req_desc_ready;
  end
  //--------------------------------------
  // Bus control
  //--------------------------------------
  // here the AXI bus is unpacked/packed.
  always_comb begin : proc_axi_packer
    // We do not need the ar/r right now
    // We tie them to zero
    axi_dma_req_o          = '0;
    // assign W signals
    axi_dma_req_o.w.data   = w_data;
    axi_dma_req_o.w.strb   = w_strb;
    axi_dma_req_o.w.last   = w_last;
    axi_dma_req_o.w_valid  = w_valid;
    w_ready                = axi_dma_resp_i.w_ready;
    // AW signals
    axi_dma_req_o.aw.id    = current_req_aw_desc.id;
    axi_dma_req_o.aw.addr  = current_req_aw_desc.addr;
    axi_dma_req_o.aw.len   = current_req_aw_desc.len;
    axi_dma_req_o.aw.size  = current_req_aw_desc.size;
    axi_dma_req_o.aw.burst = current_req_aw_desc.burst;
    axi_dma_req_o.aw.cache = current_req_aw_desc.cache;
    // A ToRemoteData (is_write_data) write MUST NOT assert its AW until its W data is ready
    // (w_valid = grant && write_req_data_valid_i). Otherwise a cross-die chain MIDDLE node issues
    // its data-forward AW to the NEXT hop the instant it receives its own grant -- before it has
    // folded any data -- which locks that output port in the D2D write-aware router with no W to
    // release it, and (via the single serialized soc->D2D stream + AXI W-ordering) blocks this
    // node's OUTGOING grant to its PREV hop. The prev hop then never sends data, so the data W is
    // never ready: deadlock. Gating AW on w_valid makes the grant win, breaking the cycle. Harmless
    // for normal writes (data is already present, so w_valid is high and the AW is not delayed).
    // w_valid is the beat on the bus now, which can still belong to the burst BEFORE: the AW of
    // the next burst then leaves before any of its own data exists, and a burst can run dry in
    // the middle. With WholeBurstWrite the AW instead waits until its own burst is buffered
    // whole (aw_burst_whole), so the data of a burst that has taken a shared port's write order
    // is always there. Every other AW (e.g. a remote read's payload) waits for its whole burst
    // too, so the beats owed by the AWs that have left (owed_q) never exceed the buffer.
    axi_dma_req_o.aw_valid = (current_req_aw_desc.is_write_data) ?
        ~aw_emitter_empty && write_req_grant_i && (WholeBurstWrite ? aw_burst_whole : w_valid) :
        ~aw_emitter_empty && (WholeBurstWrite ? aw_burst_whole : 1'b1);
    aw_emitter_pop         = axi_dma_resp_i.aw_ready & axi_dma_req_o.aw_valid;
    // B signals
    // we are always ready to accept b signals, as we do not need them
    // inside the DMA (we don't care if write failed)
    axi_dma_req_o.b_ready  = 1'b1;
  end
endmodule : xdma_req_backend
