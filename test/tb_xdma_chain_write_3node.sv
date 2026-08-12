// Authors:
// - Fanchen Kong <fanchen.kong@kuleuven.be>
//
// ChainWrite across three clusters: C0 sources the payload, C1 forwards it, C2 sinks it.
//
// A chain needs three nodes before a MIDDLE hop exists, and that is what this testbench
// adds over `tb_xdma_axi_adapter_top`, which is head-and-tail only. `xdma_grant_manager`'s
// WRITE_MIDDLE state and `xdma_finish_manager`'s WriteMiddleBusy / SendToPreviousHop states
// are reachable only through a node that both receives and forwards, so without a middle
// node that logic ships untested.
//
// Both AXI buses are wired through real crossbars. cfg, grant and finish all ride the
// narrow bus, so a chain cannot form without it.
//
// Roles follow position in the data flow, C0 -> C1 -> C2:
//
//   node 0 (head)   is_first_cw=1, is_last_cw=0   sources the payload, owns the task
//   node 1 (middle) neither                       forwards it (junction FIFO below)
//   node 2 (tail)   is_first_cw=0, is_last_cw=1   sinks it
//
// Checked: cfg propagates hop by hop bit-exact; every node forwards exactly the beats it
// received; the payload arrives at the tail unmodified and in order, which can only happen
// if the grant credit cascaded backwards tail -> middle -> head first; `xdma_finish_o`
// pulses once and only on the head, the node whose core is waiting; and a second, longer
// transfer completes, proving every FSM returned to idle.

`timescale 1ns / 1ps
`include "axi/typedef.svh"

module tb_xdma_chain_write_3node ();

  // The head owns the task, so it is the node that must raise `xdma_finish_o`.
  localparam int unsigned InitiatorNode = 0;

  //====================================================================
  // Protocol typedefs (mirror xdma_axi_adapter_top's body)
  //====================================================================
  localparam int unsigned TbMaxMemSizeKiB      = 32'd4096;
  localparam int unsigned TbWordlineWidth      = 32'd64;
  localparam int unsigned TbAxiAddrWidth       = 32'd48;
  localparam int unsigned TbAxiWideDataWidth   = 32'd512;
  localparam int unsigned TbAxiNarrowDataWidth = 32'd64;
  localparam int unsigned TbXDMAIdWidth        = 32'd4;
  localparam int unsigned TbTotalFrameWidth    = 32'd4;
  localparam int unsigned TbDMALengthWidth     =
      $clog2(TbMaxMemSizeKiB) + 10 - $clog2(TbWordlineWidth / 8);
  localparam int unsigned TbFirstFramePayloadWidth =
      TbAxiWideDataWidth - 1 - TbTotalFrameWidth - TbXDMAIdWidth - 2 * TbAxiAddrWidth;

  typedef logic [           TbXDMAIdWidth-1:0] tb_id_t;
  typedef logic [          TbAxiAddrWidth-1:0] tb_addr_t;
  typedef logic [      TbAxiWideDataWidth-1:0] tb_wide_data_t;
  typedef logic [       TbTotalFrameWidth-1:0] tb_frame_length_t;
  typedef logic [TbFirstFramePayloadWidth-1:0] tb_first_frame_payload_t;
  typedef logic [        TbDMALengthWidth-1:0] tb_len_t;

  typedef struct packed {
    tb_first_frame_payload_t first_frame_remaining_payload;
    tb_addr_t                writer_addr;
    tb_addr_t                reader_addr;
    tb_id_t                  dma_id;
    tb_frame_length_t        frame_length;
    // dma_type: 0 = read, 1 = write
    logic                    dma_type;
  } tb_xdma_inter_cluster_cfg_t;

  typedef struct packed {
    tb_id_t   dma_id;
    logic     dma_type;
    tb_addr_t src_addr;
    tb_addr_t dst_addr;
    tb_len_t  dma_length;
    logic     ready_to_transfer;
    logic     is_first_cw;
    logic     is_last_cw;
  } tb_xdma_accompany_cfg_t;

  typedef struct packed {
    int unsigned idx;
    tb_addr_t    start_addr;
    tb_addr_t    end_addr;
  } tb_rule_t;

  //====================================================================
  // System constants
  //====================================================================
  localparam int unsigned TbNumClusters       = 32'd3;
  localparam tb_addr_t    ClusterBaseAddr     = 48'h1000_0000;
  localparam tb_addr_t    ClusterAddressSpace = 48'h0010_0000;
  localparam tb_addr_t    MainMemBaseAddr     = 48'h8000_0000;
  localparam tb_addr_t    MainMemEndAddr      = 48'b1 << 32;
  localparam int unsigned MMIOSize            = 16;

  localparam time CyclTime   = 10ns;
  localparam time SimTimeout = 2ms;

  function automatic tb_addr_t cluster_base(input int unsigned i);
    return ClusterBaseAddr + i * ClusterAddressSpace;
  endfunction

  //====================================================================
  // Interconnect
  //====================================================================
  localparam int unsigned TbAxiUserWidth = 32'd1;
  localparam int unsigned TbIdWidthIn    = 32'd8;
  localparam int unsigned TbIdWidthOut   = $clog2(TbNumClusters) + TbIdWidthIn;
  localparam int unsigned TbPipeline     = 32'd1;

  typedef logic [          TbIdWidthIn-1:0] id_mst_t;
  typedef logic [         TbIdWidthOut-1:0] id_slv_t;
  typedef logic [       TbAxiUserWidth-1:0] user_t;
  typedef logic [   TbAxiWideDataWidth-1:0] data_wide_t;
  typedef logic [ TbAxiWideDataWidth/8-1:0] strb_wide_t;
  typedef logic [ TbAxiNarrowDataWidth-1:0] data_narrow_t;
  typedef logic [TbAxiNarrowDataWidth/8-1:0] strb_narrow_t;

  `AXI_TYPEDEF_ALL(axi_wide_mst, tb_addr_t, id_mst_t, data_wide_t, strb_wide_t, user_t)
  `AXI_TYPEDEF_ALL(axi_wide_slv, tb_addr_t, id_slv_t, data_wide_t, strb_wide_t, user_t)
  `AXI_TYPEDEF_ALL(axi_narrow_mst, tb_addr_t, id_mst_t, data_narrow_t, strb_narrow_t, user_t)
  `AXI_TYPEDEF_ALL(axi_narrow_slv, tb_addr_t, id_slv_t, data_narrow_t, strb_narrow_t, user_t)

  function automatic tb_rule_t [TbNumClusters-1:0] addr_map_gen();
    for (int unsigned i = 0; i < TbNumClusters; i++) begin
      addr_map_gen[i] = tb_rule_t'{
          idx: i,
          start_addr: ClusterBaseAddr + i * ClusterAddressSpace,
          end_addr: ClusterBaseAddr + (i + 1) * ClusterAddressSpace
      };
    end
  endfunction

  localparam tb_rule_t [TbNumClusters-1:0] XbarRule = addr_map_gen();

  localparam axi_pkg::xbar_cfg_t WideXbarCfg = '{
      NoSlvPorts: TbNumClusters,
      NoMstPorts: TbNumClusters,
      MaxMstTrans: 10,
      MaxSlvTrans: 6,
      FallThrough: 1'b0,
      LatencyMode: axi_pkg::CUT_ALL_AX,
      PipelineStages: TbPipeline,
      AxiIdWidthSlvPorts: TbIdWidthIn,
      AxiIdUsedSlvPorts: TbIdWidthIn,
      UniqueIds: 1'b0,
      AxiAddrWidth: TbAxiAddrWidth,
      AxiDataWidth: TbAxiWideDataWidth,
      NoAddrRules: TbNumClusters
  };

  localparam axi_pkg::xbar_cfg_t NarrowXbarCfg = '{
      NoSlvPorts: TbNumClusters,
      NoMstPorts: TbNumClusters,
      MaxMstTrans: 10,
      MaxSlvTrans: 6,
      FallThrough: 1'b0,
      LatencyMode: axi_pkg::CUT_ALL_AX,
      PipelineStages: TbPipeline,
      AxiIdWidthSlvPorts: TbIdWidthIn,
      AxiIdUsedSlvPorts: TbIdWidthIn,
      UniqueIds: 1'b0,
      AxiAddrWidth: TbAxiAddrWidth,
      AxiDataWidth: TbAxiNarrowDataWidth,
      NoAddrRules: TbNumClusters
  };

  logic clk;
  logic rst_n;

  axi_wide_mst_req_t    [TbNumClusters-1:0] wide_mst_req;
  axi_wide_mst_resp_t   [TbNumClusters-1:0] wide_mst_rsp;
  axi_wide_slv_req_t    [TbNumClusters-1:0] wide_slv_req;
  axi_wide_slv_resp_t   [TbNumClusters-1:0] wide_slv_rsp;
  axi_narrow_mst_req_t  [TbNumClusters-1:0] narrow_mst_req;
  axi_narrow_mst_resp_t [TbNumClusters-1:0] narrow_mst_rsp;
  axi_narrow_slv_req_t  [TbNumClusters-1:0] narrow_slv_req;
  axi_narrow_slv_resp_t [TbNumClusters-1:0] narrow_slv_rsp;

  axi_xbar #(
      .Cfg          (WideXbarCfg),
      .ATOPs        (0),
      .slv_aw_chan_t(axi_wide_mst_aw_chan_t),
      .mst_aw_chan_t(axi_wide_slv_aw_chan_t),
      .w_chan_t     (axi_wide_mst_w_chan_t),
      .slv_b_chan_t (axi_wide_mst_b_chan_t),
      .mst_b_chan_t (axi_wide_slv_b_chan_t),
      .slv_ar_chan_t(axi_wide_mst_ar_chan_t),
      .mst_ar_chan_t(axi_wide_slv_ar_chan_t),
      .slv_r_chan_t (axi_wide_mst_r_chan_t),
      .mst_r_chan_t (axi_wide_slv_r_chan_t),
      .slv_req_t    (axi_wide_mst_req_t),
      .slv_resp_t   (axi_wide_mst_resp_t),
      .mst_req_t    (axi_wide_slv_req_t),
      .mst_resp_t   (axi_wide_slv_resp_t),
      .rule_t       (tb_rule_t)
  ) i_wide_xbar (
      .clk_i                (clk),
      .rst_ni               (rst_n),
      .test_i               (1'b0),
      .slv_ports_req_i      (wide_mst_req),
      .slv_ports_resp_o     (wide_mst_rsp),
      .mst_ports_req_o      (wide_slv_req),
      .mst_ports_resp_i     (wide_slv_rsp),
      .addr_map_i           (XbarRule),
      .en_default_mst_port_i('0),
      .default_mst_port_i   ('0)
  );

  axi_xbar #(
      .Cfg          (NarrowXbarCfg),
      .ATOPs        (0),
      .slv_aw_chan_t(axi_narrow_mst_aw_chan_t),
      .mst_aw_chan_t(axi_narrow_slv_aw_chan_t),
      .w_chan_t     (axi_narrow_mst_w_chan_t),
      .slv_b_chan_t (axi_narrow_mst_b_chan_t),
      .mst_b_chan_t (axi_narrow_slv_b_chan_t),
      .slv_ar_chan_t(axi_narrow_mst_ar_chan_t),
      .mst_ar_chan_t(axi_narrow_slv_ar_chan_t),
      .slv_r_chan_t (axi_narrow_mst_r_chan_t),
      .mst_r_chan_t (axi_narrow_slv_r_chan_t),
      .slv_req_t    (axi_narrow_mst_req_t),
      .slv_resp_t   (axi_narrow_mst_resp_t),
      .mst_req_t    (axi_narrow_slv_req_t),
      .mst_resp_t   (axi_narrow_slv_resp_t),
      .rule_t       (tb_rule_t)
  ) i_narrow_xbar (
      .clk_i                (clk),
      .rst_ni               (rst_n),
      .test_i               (1'b0),
      .slv_ports_req_i      (narrow_mst_req),
      .slv_ports_resp_o     (narrow_mst_rsp),
      .mst_ports_req_o      (narrow_slv_req),
      .mst_ports_resp_i     (narrow_slv_rsp),
      .addr_map_i           (XbarRule),
      .en_default_mst_port_i('0),
      .default_mst_port_i   ('0)
  );

  clk_rst_gen #(
      .ClkPeriod   (CyclTime),
      .RstClkCycles(5)
  ) i_clk_gen (
      .clk_o (clk),
      .rst_no(rst_n)
  );

  //====================================================================
  // Adapter-facing signals
  //====================================================================
  // Purely testbench-driven
  tb_xdma_inter_cluster_cfg_t [TbNumClusters-1:0] to_remote_cfg;
  logic                       [TbNumClusters-1:0] to_remote_cfg_valid;
  tb_xdma_accompany_cfg_t     [TbNumClusters-1:0] to_remote_acfg;
  tb_xdma_accompany_cfg_t     [TbNumClusters-1:0] from_remote_acfg;
  logic                       [TbNumClusters-1:0] from_remote_cfg_ready;
  assign from_remote_cfg_ready = '1;

  // Adapter outputs
  logic [TbNumClusters-1:0] to_remote_cfg_ready;
  logic [TbNumClusters-1:0] to_remote_data_ready;
  logic [TbNumClusters-1:0][TbAxiWideDataWidth-1:0] from_remote_cfg;
  logic [TbNumClusters-1:0] from_remote_cfg_valid;
  logic [TbNumClusters-1:0][TbAxiWideDataWidth-1:0] from_remote_data;
  logic [TbNumClusters-1:0] from_remote_data_valid;
  logic [TbNumClusters-1:0] xdma_finish;

  // Mixed sources (testbench for the head, the junction FIFO for the middle, tied off for
  // the tail) -- nets, so the per-bit drivers below are unambiguous.
  wire [TbNumClusters-1:0][TbAxiWideDataWidth-1:0] to_remote_data;
  wire [TbNumClusters-1:0]                         to_remote_data_valid;
  wire [TbNumClusters-1:0]                         from_remote_data_ready;

  tb_wide_data_t head_data;
  logic          head_valid;
  tb_wide_data_t mid_data;
  logic          mid_valid;
  logic          junction_ready;

  assign to_remote_data[0]       = head_data;
  assign to_remote_data[1]       = mid_data;
  assign to_remote_data[2]       = '0;
  assign to_remote_data_valid[0] = head_valid;
  assign to_remote_data_valid[1] = mid_valid;
  assign to_remote_data_valid[2] = 1'b0;
  // The head sinks nothing; the tail is the testbench's collection point and never stalls.
  assign from_remote_data_ready[0] = 1'b1;
  assign from_remote_data_ready[1] = junction_ready;
  assign from_remote_data_ready[2] = 1'b1;

  for (genvar i = 0; i < TbNumClusters; i++) begin : gen_adapter
    xdma_axi_adapter_top #(
        .MaxMemSizeKiB        (TbMaxMemSizeKiB),
        .WordlineWidth        (TbWordlineWidth),
        .WideAXIIdWidth       (TbIdWidthOut),
        .NarrowAXIIdWidth     (TbIdWidthOut),
        .axi_wide_out_req_t   (axi_wide_mst_req_t),
        .axi_wide_out_resp_t  (axi_wide_mst_resp_t),
        .axi_wide_in_req_t    (axi_wide_slv_req_t),
        .axi_wide_in_resp_t   (axi_wide_slv_resp_t),
        .axi_narrow_out_req_t (axi_narrow_mst_req_t),
        .axi_narrow_out_resp_t(axi_narrow_mst_resp_t),
        .axi_narrow_in_req_t  (axi_narrow_slv_req_t),
        .axi_narrow_in_resp_t (axi_narrow_slv_resp_t),
        .ClusterBaseAddr      (ClusterBaseAddr),
        .ClusterAddressSpace  (ClusterAddressSpace),
        .MainMemBaseAddr      (MainMemBaseAddr),
        .MainMemEndAddr       (MainMemEndAddr),
        .MMIOSize             (MMIOSize)
    ) i_dut (
        .clk_i                           (clk),
        .rst_ni                          (rst_n),
        .cluster_base_addr_i             (cluster_base(i)),
        .to_remote_cfg_i                 (to_remote_cfg[i]),
        .to_remote_cfg_valid_i           (to_remote_cfg_valid[i]),
        .to_remote_cfg_ready_o           (to_remote_cfg_ready[i]),
        .to_remote_data_i                (to_remote_data[i]),
        .to_remote_data_valid_i          (to_remote_data_valid[i]),
        .to_remote_data_ready_o          (to_remote_data_ready[i]),
        .to_remote_data_accompany_cfg_i  (to_remote_acfg[i]),
        .from_remote_cfg_o               (from_remote_cfg[i]),
        .from_remote_cfg_valid_o         (from_remote_cfg_valid[i]),
        .from_remote_cfg_ready_i         (from_remote_cfg_ready[i]),
        .from_remote_data_o              (from_remote_data[i]),
        .from_remote_data_valid_o        (from_remote_data_valid[i]),
        .from_remote_data_ready_i        (from_remote_data_ready[i]),
        .from_remote_data_accompany_cfg_i(from_remote_acfg[i]),
        .xdma_finish_o                   (xdma_finish[i]),
        .axi_xdma_wide_out_req_o         (wide_mst_req[i]),
        .axi_xdma_wide_out_resp_i        (wide_mst_rsp[i]),
        .axi_xdma_wide_in_req_i          (wide_slv_req[i]),
        .axi_xdma_wide_in_resp_o         (wide_slv_rsp[i]),
        .axi_xdma_narrow_out_req_o       (narrow_mst_req[i]),
        .axi_xdma_narrow_out_resp_i      (narrow_mst_rsp[i]),
        .axi_xdma_narrow_in_req_i        (narrow_slv_req[i]),
        .axi_xdma_narrow_in_resp_o       (narrow_slv_rsp[i])
    );
  end

  //====================================================================
  // Node 1 junction: from_remote_data -> to_remote_data
  //====================================================================
  // Stand-in for the Chisel junction, which for a chained write is the middle node's
  // writer/reader pair. The adapter is payload-agnostic -- no module in it inspects a
  // payload bit -- so a plain FIFO is a faithful model at this level.
  stream_fifo #(
      .FALL_THROUGH(1'b0),
      .DEPTH       (32'd8),
      .T           (tb_wide_data_t)
  ) i_junction (
      .clk_i     (clk),
      .rst_ni    (rst_n),
      .flush_i   (1'b0),
      .testmode_i(1'b0),
      .usage_o   (  /* unused */),
      .data_i    (from_remote_data[1]),
      .valid_i   (from_remote_data_valid[1]),
      .ready_o   (junction_ready),
      .data_o    (mid_data),
      .valid_o   (mid_valid),
      .ready_i   (to_remote_data_ready[1])
  );

  //====================================================================
  // Monitors
  //====================================================================
  tb_wide_data_t tail_rx_q[$];
  int tail_rx_cnt;
  int head_tx_cnt;
  int mid_tx_cnt;
  int finish_cnt[TbNumClusters];
  int errors = 0;

  always @(posedge clk) begin
    if (rst_n) begin
      if (from_remote_data_valid[2] && from_remote_data_ready[2]) begin
        tail_rx_q.push_back(from_remote_data[2]);
        tail_rx_cnt++;
      end
      if (to_remote_data_valid[0] && to_remote_data_ready[0]) head_tx_cnt++;
      if (to_remote_data_valid[1] && to_remote_data_ready[1]) mid_tx_cnt++;
      for (int i = 0; i < TbNumClusters; i++) if (xdma_finish[i]) finish_cnt[i]++;
    end
  end

  initial begin
    #SimTimeout;
    $fatal(1, "[TB] global timeout -- the chain never completed");
  end

  //====================================================================
  // Coverage of the middle-hop states
  //====================================================================
  // The reason this testbench exists is the MIDDLE node, so assert that its control FSMs
  // actually entered the states no two-node testbench can reach. Without this a refactor
  // could quietly stop exercising them and still report PASS -- the payload would still
  // arrive, because the data plane does not care how the credit was granted.
  //
  // Encodings mirror the enums in xdma_grant_manager (IDLE, WRITE_LAST, WRITE_MIDDLE,
  // SEND_GRANT_TO_PREV_HOP, WAIT_FINISH) and xdma_finish_manager (WriteMiddleLastIdle,
  // WriteMiddleBusy, WriteLastBusy, WriteLastFinish, SendToPreviousHop).
  logic saw_grant_write_middle;
  logic saw_finish_middle_busy;
  logic saw_finish_send_to_prev;

  always @(posedge clk) begin
    if (!rst_n) begin
      saw_grant_write_middle  <= 1'b0;
      saw_finish_middle_busy  <= 1'b0;
      saw_finish_send_to_prev <= 1'b0;
    end else begin
      if (gen_adapter[1].i_dut.i_xdma_grant_manager.cur_state == 3'd2) begin
        saw_grant_write_middle <= 1'b1;
      end
      if (gen_adapter[1].i_dut.i_xdma_finish_manager.last_write_current_state == 3'd1) begin
        saw_finish_middle_busy <= 1'b1;
      end
      if (gen_adapter[1].i_dut.i_xdma_finish_manager.last_write_current_state == 3'd4) begin
        saw_finish_send_to_prev <= 1'b1;
      end
    end
  end

  task automatic check_middle_coverage();
    if (!saw_grant_write_middle) begin
      errors++;
      $error("node 1 grant manager never entered WRITE_MIDDLE");
    end
    if (!saw_finish_middle_busy) begin
      errors++;
      $error("node 1 finish manager never entered WriteMiddleBusy");
    end
    if (!saw_finish_send_to_prev) begin
      errors++;
      $error("node 1 finish manager never entered SendToPreviousHop");
    end
    if (saw_grant_write_middle && saw_finish_middle_busy && saw_finish_send_to_prev) begin
      $display("[TB] middle-hop coverage: WRITE_MIDDLE, WriteMiddleBusy, SendToPreviousHop all reached");
    end
  endtask

  //====================================================================
  // Stimulus helpers
  //====================================================================
  tb_xdma_inter_cluster_cfg_t last_cfg_sent;
  // Every frame gets a fresh seed. With a repeating seed a stale-payload bug in the
  // receive path can accidentally match the expected value and pass unnoticed.
  logic [15:0] cfg_seed = 16'hA5A5;

  task automatic check_int(input int actual, input int expected, input string what);
    if (actual != expected) begin
      errors++;
      $error("%s: expected %0d, got %0d", what, expected, actual);
    end
  endtask

  task automatic clear_counters();
    tail_rx_q.delete();
    tail_rx_cnt = 0;
    head_tx_cnt = 0;
    mid_tx_cnt  = 0;
    for (int i = 0; i < TbNumClusters; i++) finish_cnt[i] = 0;
  endtask

  // Send one cfg frame from `src` addressed at `dst`. `frame_length = 1` means a single
  // 512-bit frame, which the adapter serialises into 8 narrow beats and the receiver
  // reassembles. The payload marks both ends of the 512-bit word so a truncated or
  // mis-serialised frame cannot pass unnoticed.
  task automatic send_cfg(input int unsigned src, input int unsigned dst, input tb_id_t id);
    tb_xdma_inter_cluster_cfg_t cfg;
    logic [15:0] seed;
    cfg_seed = cfg_seed + 16'h1234;
    seed = cfg_seed;
    cfg                                     = '0;
    cfg.dma_type                            = 1'b1;  // write
    cfg.frame_length                        = 4'd1;
    cfg.dma_id                              = id;
    cfg.reader_addr                         = cluster_base(src);
    cfg.writer_addr                         = cluster_base(dst);
    cfg.first_frame_remaining_payload[15:0] = seed;
    cfg.first_frame_remaining_payload[TbFirstFramePayloadWidth-1-:16] = ~seed;
    last_cfg_sent = cfg;

    to_remote_cfg[src]       <= cfg;
    to_remote_cfg_valid[src] <= 1'b1;
    @(negedge clk);
    while (!to_remote_cfg_ready[src]) @(negedge clk);
    @(posedge clk);
    to_remote_cfg_valid[src] <= 1'b0;
    to_remote_cfg[src]       <= '0;
  endtask

  task automatic expect_cfg(input int unsigned dst);
    @(negedge clk);
    while (!from_remote_cfg_valid[dst]) @(negedge clk);
    if (from_remote_cfg[dst] !== tb_wide_data_t'(last_cfg_sent)) begin
      errors++;
      $error("node %0d cfg frame mismatch\n  expected %h\n  got      %h", dst,
             tb_wide_data_t'(last_cfg_sent), from_remote_cfg[dst]);
    end
    @(posedge clk);
  endtask

  function automatic tb_wide_data_t beat(input int unsigned i);
    tb_wide_data_t d;
    d          = '0;
    d[63:0]    = 64'hC0FF_EE00_0000_0000 + i;
    d[255:192] = 64'h5A5A_5A5A_0000_0000 + i;
    d[511:448] = 64'hFEED_FACE_0000_0000 + i;
    return d;
  endfunction

  task automatic send_payload(input int unsigned len);
    for (int unsigned i = 0; i < len; i++) begin
      head_data  <= beat(i);
      head_valid <= 1'b1;
      @(negedge clk);
      while (!to_remote_data_ready[0]) @(negedge clk);
      @(posedge clk);
    end
    head_valid <= 1'b0;
  endtask

  //====================================================================
  // One end-to-end chained transfer across the three nodes
  //====================================================================
  task automatic run_chain(input tb_id_t id, input int unsigned len);
    $display("[TB] ChainWrite transfer: dma_id=%0d, dma_length=%0d", id, len);

    //---- Phase A: cfg walks the chain, hop by hop ----
    // The initiator configures the whole chain, so cfg walks outward from the head, in the
    // same direction as the data. The adapter routes a cfg frame purely from `writer_addr`.
    send_cfg(0, 1, id);
    expect_cfg(1);
    send_cfg(1, 2, id);
    expect_cfg(2);
    repeat (5) @(posedge clk);

    //---- Phase B: the chain windows open ----
    // Tail: takes delivery and is the last hop -> its grant manager seeds the credit
    // cascade that unblocks the middle and then the head.
    from_remote_acfg[2].dma_id            <= id;
    from_remote_acfg[2].dma_type          <= 1'b1;
    from_remote_acfg[2].src_addr          <= cluster_base(1);
    from_remote_acfg[2].dst_addr          <= cluster_base(2);
    from_remote_acfg[2].dma_length        <= tb_len_t'(len);
    from_remote_acfg[2].ready_to_transfer <= 1'b1;
    from_remote_acfg[2].is_first_cw       <= 1'b0;
    from_remote_acfg[2].is_last_cw        <= 1'b1;

    // Middle: neither first nor last, on both sides. This is the WRITE_MIDDLE /
    // WriteMiddleBusy path that no existing testbench reaches.
    from_remote_acfg[1].dma_id            <= id;
    from_remote_acfg[1].dma_type          <= 1'b1;
    from_remote_acfg[1].src_addr          <= cluster_base(0);
    from_remote_acfg[1].dst_addr          <= cluster_base(1);
    from_remote_acfg[1].dma_length        <= tb_len_t'(len);
    from_remote_acfg[1].ready_to_transfer <= 1'b1;
    from_remote_acfg[1].is_first_cw       <= 1'b0;
    from_remote_acfg[1].is_last_cw        <= 1'b0;

    // The middle node's *outgoing* busy level has to cover its whole participation window.
    // A middle node that drops this level early never asserts `ready_to_transfer`, so its
    // grant manager never leaves IDLE and the chain deadlocks with no diagnostic.
    to_remote_acfg[1].dma_id            <= id;
    to_remote_acfg[1].dma_type          <= 1'b1;
    to_remote_acfg[1].src_addr          <= cluster_base(1);
    to_remote_acfg[1].dst_addr          <= cluster_base(2);
    to_remote_acfg[1].dma_length        <= tb_len_t'(len);
    to_remote_acfg[1].ready_to_transfer <= 1'b1;
    to_remote_acfg[1].is_first_cw       <= 1'b0;
    to_remote_acfg[1].is_last_cw        <= 1'b0;

    // Head: sources the data and owns the task.
    to_remote_acfg[0].dma_id            <= id;
    to_remote_acfg[0].dma_type          <= 1'b1;
    to_remote_acfg[0].src_addr          <= cluster_base(0);
    to_remote_acfg[0].dst_addr          <= cluster_base(1);
    to_remote_acfg[0].dma_length        <= tb_len_t'(len);
    to_remote_acfg[0].ready_to_transfer <= 1'b1;
    to_remote_acfg[0].is_first_cw       <= 1'b1;
    to_remote_acfg[0].is_last_cw        <= 1'b0;
    @(posedge clk);

    //---- Phase C: payload ----
    send_payload(len);

    // The tail closing its receive window is what starts the finish cascade.
    wait (tail_rx_cnt == len);
    @(posedge clk);
    from_remote_acfg[2].ready_to_transfer <= 1'b0;
    to_remote_acfg[1].ready_to_transfer   <= 1'b0;
    from_remote_acfg[1].ready_to_transfer <= 1'b0;
    to_remote_acfg[0].ready_to_transfer   <= 1'b0;

    //---- Phase D: the finish cascades backwards, the head reports ----
    // tail -> middle -> head, releasing each grant credit on the way.
    wait (finish_cnt[InitiatorNode] == 1);
    repeat (20) @(posedge clk);

    //---- Checks ----
    check_int(tail_rx_cnt, len, "beats delivered to the tail");
    check_int(head_tx_cnt, len, "beats sent by the head");
    check_int(mid_tx_cnt, len, "beats forwarded by the middle");
    // Exactly one node reports completion, and it is the head. A middle node that pulses
    // its core, or a head that pulses twice because a finish was replayed, fails here.
    for (int unsigned n = 0; n < TbNumClusters; n++) begin
      check_int(finish_cnt[n], (n == InitiatorNode) ? 1 : 0,
                $sformatf("node %0d xdma_finish_o pulses (initiator is node %0d)", n,
                          InitiatorNode));
    end

    for (int unsigned i = 0; i < len; i++) begin
      if (tail_rx_q[i] !== beat(i)) begin
        errors++;
        $error("payload mismatch at beat %0d\n  expected %h\n  got      %h", i, beat(i),
               tail_rx_q[i]);
      end
    end

    // Settle and clear for the next transfer.
    to_remote_acfg   <= '0;
    from_remote_acfg <= '0;
    repeat (20) @(posedge clk);
    clear_counters();
  endtask

  //====================================================================
  // Test
  //====================================================================
  initial begin
    to_remote_cfg       = '0;
    to_remote_cfg_valid = '0;
    to_remote_acfg      = '0;
    from_remote_acfg    = '0;
    head_data           = '0;
    head_valid          = 1'b0;
    clear_counters();

    @(posedge rst_n);
    repeat (10) @(posedge clk);

    // Short transfer: a single burst (MaxNumBeats = 64 on the wide path).
    run_chain(4'd3, 8);

    // Longer transfer: crosses the burst boundary, and proves every FSM went back to idle.
    run_chain(4'd5, 100);

    check_middle_coverage();

    if (errors != 0) begin
      $fatal(1, "[TB] tb_xdma_chain_write_3node FAILED with %0d error(s)", errors);
    end
    $display("[PASS] tb_xdma_chain_write_3node");
    $finish;
  end

endmodule
