// Authors:
// - Fanchen Kong <fanchen.kong@kuleuven.be>
//
// Top-level regressions for two hazards on the shared narrow port.
//
// 1. FINISH BUFFERING. The finish manager only raises READY in WriteFirstBusy /
//    WriteMiddleBusy. Wired straight to the demux, that made the AXI slave port's READY,
//    so a finish arriving at any other moment stalled the port and blocked the cfg and
//    grant traffic of every task behind it. The receive finish FIFO decouples the two.
//
// 2. STICKY WRITE READINESS. `wide_write_rtt_q` latches the to_remote WRITE readiness
//    pulse. With the clear ahead of the set, a pulse coincident with the previous
//    transfer's `done` was swallowed -- exactly the one-cycle pulse the latch exists for.

`include "axi/typedef.svh"

module tb_xdma_finish_backpressure;

  localparam time ClkPeriod = 10ns;

  localparam int unsigned AxiAddrWidth       = 48;
  localparam int unsigned AxiWideDataWidth   = 512;
  localparam int unsigned AxiNarrowDataWidth = 64;
  localparam int unsigned AxiIdWidth         = 1;
  localparam int unsigned AxiUserWidth       = 1;
  localparam int unsigned MaxMemSizeKiB      = 4096;
  localparam int unsigned WordlineWidth      = 64;
  localparam int unsigned XDMAIdWidth        = 4;

  localparam int unsigned DMALengthWidth =
      $clog2(MaxMemSizeKiB) + 10 - $clog2(WordlineWidth / 8);
  localparam int unsigned AccompanyCfgBits =
      XDMAIdWidth + 1 + 2 * AxiAddrWidth + DMALengthWidth + 3;

  // Bit position of `ready_to_transfer` inside the packed accompany cfg
  // { dma_id, dma_type, src_addr, dst_addr, dma_length, ready_to_transfer,
  //   is_first_cw, is_last_cw }
  localparam int unsigned RttBit     = 2;
  localparam int unsigned DmaTypeBit = AccompanyCfgBits - XDMAIdWidth - 1;

  typedef logic [AxiAddrWidth-1:0]         axi_addr_t;
  typedef logic [AxiIdWidth-1:0]           axi_id_t;
  typedef logic [AxiUserWidth-1:0]         axi_user_t;
  typedef logic [AxiWideDataWidth-1:0]     axi_wide_data_t;
  typedef logic [AxiWideDataWidth/8-1:0]   axi_wide_strb_t;
  typedef logic [AxiNarrowDataWidth-1:0]   axi_narrow_data_t;
  typedef logic [AxiNarrowDataWidth/8-1:0] axi_narrow_strb_t;

  `AXI_TYPEDEF_ALL(axi_wide, axi_addr_t, axi_id_t, axi_wide_data_t, axi_wide_strb_t,
                   axi_user_t)
  `AXI_TYPEDEF_ALL(axi_narrow, axi_addr_t, axi_id_t, axi_narrow_data_t, axi_narrow_strb_t,
                   axi_user_t)

  // The cluster this adapter belongs to, and the finish window at the top of it.
  localparam axi_addr_t ClusterBaseAddr = 48'h1000_0000;
  localparam axi_addr_t ClusterEndAddr  = 48'h1010_0000;
  localparam axi_addr_t FinishWindow    = ClusterEndAddr - 48'h1000;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #(ClkPeriod / 2) clk = ~clk;

  logic [AxiWideDataWidth-1:0] to_remote_cfg, to_remote_data;
  logic [AxiWideDataWidth-1:0] from_remote_cfg, from_remote_data;
  logic to_remote_cfg_valid, to_remote_cfg_ready;
  logic to_remote_data_valid, to_remote_data_ready;
  logic from_remote_cfg_valid, from_remote_cfg_ready;
  logic from_remote_data_valid, from_remote_data_ready;
  logic [AccompanyCfgBits-1:0] to_acc, from_acc;
  logic xdma_finish;

  axi_wide_req_t    wide_out_req, wide_in_req;
  axi_wide_resp_t   wide_out_resp, wide_in_resp;
  axi_narrow_req_t  narrow_out_req, narrow_in_req;
  axi_narrow_resp_t narrow_out_resp, narrow_in_resp;

  int errors = 0;

  xdma_axi_adapter_top #(
      .MaxMemSizeKiB        (MaxMemSizeKiB),
      .WordlineWidth        (WordlineWidth),
      .AxiAddrWidth         (AxiAddrWidth),
      .AxiWideDataWidth     (AxiWideDataWidth),
      .AxiNarrowDataWidth   (AxiNarrowDataWidth),
      .XDMAIdWidth          (XDMAIdWidth),
      .WideAXIIdWidth       (AxiIdWidth),
      .NarrowAXIIdWidth     (AxiIdWidth),
      .axi_wide_out_req_t   (axi_wide_req_t),
      .axi_wide_out_resp_t  (axi_wide_resp_t),
      .axi_wide_in_req_t    (axi_wide_req_t),
      .axi_wide_in_resp_t   (axi_wide_resp_t),
      .axi_narrow_out_req_t (axi_narrow_req_t),
      .axi_narrow_out_resp_t(axi_narrow_resp_t),
      .axi_narrow_in_req_t  (axi_narrow_req_t),
      .axi_narrow_in_resp_t (axi_narrow_resp_t)
  ) i_dut (
      .clk_i                          (clk),
      .rst_ni                         (rst_n),
      .cluster_base_addr_i            (ClusterBaseAddr),
      .to_remote_cfg_i                (to_remote_cfg),
      .to_remote_cfg_valid_i          (to_remote_cfg_valid),
      .to_remote_cfg_ready_o          (to_remote_cfg_ready),
      .to_remote_data_i               (to_remote_data),
      .to_remote_data_valid_i         (to_remote_data_valid),
      .to_remote_data_ready_o         (to_remote_data_ready),
      .to_remote_data_accompany_cfg_i (to_acc),
      .from_remote_cfg_o              (from_remote_cfg),
      .from_remote_cfg_valid_o        (from_remote_cfg_valid),
      .from_remote_cfg_ready_i        (from_remote_cfg_ready),
      .from_remote_data_o             (from_remote_data),
      .from_remote_data_valid_o       (from_remote_data_valid),
      .from_remote_data_ready_i       (from_remote_data_ready),
      .from_remote_data_accompany_cfg_i(from_acc),
      .xdma_finish_o                  (xdma_finish),
      .axi_xdma_wide_out_req_o        (wide_out_req),
      .axi_xdma_wide_out_resp_i       (wide_out_resp),
      .axi_xdma_wide_in_req_i         (wide_in_req),
      .axi_xdma_wide_in_resp_o        (wide_in_resp),
      .axi_xdma_narrow_out_req_o      (narrow_out_req),
      .axi_xdma_narrow_out_resp_i     (narrow_out_resp),
      .axi_xdma_narrow_in_req_i       (narrow_in_req),
      .axi_xdma_narrow_in_resp_o      (narrow_in_resp)
  );

  // Single-beat write into the adapter's narrow slave port. Returns the number of cycles
  // the port took to accept it, or -1 if it never did.
  task automatic narrow_write(input axi_addr_t address, input axi_narrow_data_t payload,
                              input int unsigned timeout, output int cycles);
    int unsigned waited;
    narrow_in_req         = '0;
    narrow_in_req.aw.addr = address;
    narrow_in_req.aw.len  = 8'd0;
    narrow_in_req.aw.size = 3'b011;   // 8 bytes
    narrow_in_req.aw.burst = axi_pkg::BURST_INCR;
    narrow_in_req.aw_valid = 1'b1;
    narrow_in_req.w.data   = payload;
    narrow_in_req.w.strb   = '1;
    narrow_in_req.w.last   = 1'b1;
    narrow_in_req.w_valid  = 1'b1;
    narrow_in_req.b_ready  = 1'b1;

    waited = 0;
    cycles = -1;
    while (waited < timeout) begin
      @(posedge clk);
      #1;
      if (narrow_in_resp.aw_ready && narrow_in_resp.w_ready) begin
        cycles = waited;
        break;
      end
      waited++;
    end
    narrow_in_req = '0;
    narrow_in_req.b_ready = 1'b1;
    @(posedge clk);
  endtask

  int accepted;
  initial begin
    to_remote_cfg = '0;
    to_remote_data = '0;
    to_remote_cfg_valid = 1'b0;
    to_remote_data_valid = 1'b0;
    from_remote_cfg_ready = 1'b1;
    from_remote_data_ready = 1'b1;
    to_acc = '0;
    from_acc = '0;
    wide_out_resp = '0;
    wide_in_req = '0;
    narrow_out_resp = '0;
    narrow_in_req = '0;
    repeat (3) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    //--------------------------------------------------------------------
    // 1. A finish arriving while no FSM waits for it must still be taken.
    //--------------------------------------------------------------------
    narrow_write(FinishWindow, 64'h3, 32, accepted);
    if (accepted < 0) begin
      $error("[tb_xdma_finish_backpressure] idle finish never accepted: narrow port stalled");
      errors++;
    end else begin
      $display("[tb_xdma_finish_backpressure] idle finish accepted after %0d cycles",
               accepted);
    end

    // The port must keep working afterwards: more finishes, up to the FIFO depth.
    narrow_write(FinishWindow, 64'h4, 32, accepted);
    if (accepted < 0) begin
      $error("[tb_xdma_finish_backpressure] second idle finish never accepted");
      errors++;
    end

    //--------------------------------------------------------------------
    // 2. The write-readiness latch must not lose a pulse that coincides
    //    with the previous transfer's `done`.
    //--------------------------------------------------------------------
    to_acc = '0;
    to_acc[DmaTypeBit] = 1'b1;   // a to_remote WRITE

    // A lone one-cycle pulse is captured.
    to_acc[RttBit] = 1'b1;
    @(posedge clk);
    #1;
    to_acc[RttBit] = 1'b0;
    #1;
    if (i_dut.wide_write_rtt_q !== 1'b1) begin
      $error("[tb_xdma_finish_backpressure] lone readiness pulse not latched");
      errors++;
    end

    // Clear it the normal way.
    force i_dut.wide_write_req_done = 1'b1;
    @(posedge clk);
    #1;
    release i_dut.wide_write_req_done;
    #1;
    if (i_dut.wide_write_rtt_q !== 1'b0) begin
      $error("[tb_xdma_finish_backpressure] latch did not clear on done");
      errors++;
    end

    // Now the coincident case: a new pulse in the same cycle as the previous `done`.
    to_acc[RttBit] = 1'b1;
    force i_dut.wide_write_req_done = 1'b1;
    @(posedge clk);
    #1;
    release i_dut.wide_write_req_done;
    to_acc[RttBit] = 1'b0;
    #1;
    if (i_dut.wide_write_rtt_q !== 1'b1) begin
      $error("[tb_xdma_finish_backpressure] readiness pulse coincident with done was dropped");
      errors++;
    end else begin
      $display("[tb_xdma_finish_backpressure] readiness pulse survived a coincident done");
    end

    if (errors != 0) begin
      $fatal(1, "[tb_xdma_finish_backpressure] FAILED with %0d error(s)", errors);
    end
    $display("[PASS] tb_xdma_finish_backpressure");
    $finish;
  end

endmodule
