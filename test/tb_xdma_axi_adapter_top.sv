// Authors:
// - Fanchen Kong <fanchen.kong@kuleuven.be>
// - Yunhao Deng <yunhao.deng@kuleuven.be>
//
// Two-cluster adapter testbench: a plain remote write, node 0 -> node 1.
//
// Head and tail with no middle hop, so the sender carries `is_first_cw` and the receiver
// carries `is_last_cw`. Both AXI buses are wired through real crossbars, and cfg, grant
// and finish all ride the narrow bus, so nothing here completes without the full control
// round trip: cfg out, grant back, data out, finish back.
//
// That makes this the end-to-end cover for the narrow-port fixes -- the grant holding its
// VALID with a frozen payload, and the receive finish FIFO -- which the unit testbenches
// (tb_xdma_grant_hold, tb_xdma_finish_backpressure) only reach in isolation.

`timescale 1ns / 1ps
`include "axi/typedef.svh"

module tb_xdma_axi_adapter_top ();

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
  localparam int unsigned TbNumClusters       = 32'd2;
  localparam tb_addr_t    ClusterBaseAddr     = 48'h1000_0000;
  localparam tb_addr_t    ClusterAddressSpace = 48'h0010_0000;
  localparam tb_addr_t    MainMemBaseAddr     = 48'h8000_0000;
  localparam tb_addr_t    MainMemEndAddr      = 48'b1 << 32;
  localparam int unsigned MMIOSize            = 16;

  localparam time CyclTime   = 10ns;
  localparam time SimTimeout = 1ms;

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

  typedef logic [           TbIdWidthIn-1:0] id_mst_t;
  typedef logic [          TbIdWidthOut-1:0] id_slv_t;
  typedef logic [        TbAxiUserWidth-1:0] user_t;
  typedef logic [    TbAxiWideDataWidth-1:0] data_wide_t;
  typedef logic [  TbAxiWideDataWidth/8-1:0] strb_wide_t;
  typedef logic [  TbAxiNarrowDataWidth-1:0] data_narrow_t;
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
  // Adapters
  //====================================================================
  tb_xdma_inter_cluster_cfg_t [TbNumClusters-1:0] to_remote_cfg;
  logic                       [TbNumClusters-1:0] to_remote_cfg_valid;
  tb_xdma_accompany_cfg_t     [TbNumClusters-1:0] to_remote_acfg;
  tb_xdma_accompany_cfg_t     [TbNumClusters-1:0] from_remote_acfg;
  logic                       [TbNumClusters-1:0] from_remote_cfg_ready;
  logic                       [TbNumClusters-1:0] from_remote_data_ready;
  assign from_remote_cfg_ready  = '1;
  assign from_remote_data_ready = '1;

  logic [TbNumClusters-1:0] to_remote_cfg_ready;
  logic [TbNumClusters-1:0] to_remote_data_ready;
  logic [TbNumClusters-1:0][TbAxiWideDataWidth-1:0] from_remote_cfg;
  logic [TbNumClusters-1:0] from_remote_cfg_valid;
  logic [TbNumClusters-1:0][TbAxiWideDataWidth-1:0] from_remote_data;
  logic [TbNumClusters-1:0] from_remote_data_valid;
  logic [TbNumClusters-1:0] xdma_finish;

  // Only node 0 sources payload; node 1 is the sink.
  tb_wide_data_t head_data;
  logic          head_valid;
  wire [TbNumClusters-1:0][TbAxiWideDataWidth-1:0] to_remote_data;
  wire [TbNumClusters-1:0]                         to_remote_data_valid;
  assign to_remote_data[0]       = head_data;
  assign to_remote_data[1]       = '0;
  assign to_remote_data_valid[0] = head_valid;
  assign to_remote_data_valid[1] = 1'b0;

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
  // Monitors
  //====================================================================
  tb_wide_data_t rx_q[$];
  int rx_cnt;
  int tx_cnt;
  int finish_cnt[TbNumClusters];
  int errors = 0;

  always @(posedge clk) begin
    if (rst_n) begin
      if (from_remote_data_valid[1] && from_remote_data_ready[1]) begin
        rx_q.push_back(from_remote_data[1]);
        rx_cnt++;
      end
      if (to_remote_data_valid[0] && to_remote_data_ready[0]) tx_cnt++;
      for (int i = 0; i < TbNumClusters; i++) if (xdma_finish[i]) finish_cnt[i]++;
    end
  end

  initial begin
    #SimTimeout;
    $fatal(1, "[TB] global timeout -- the transfer never completed");
  end

  //====================================================================
  // Stimulus
  //====================================================================
  tb_xdma_inter_cluster_cfg_t last_cfg_sent;

  task automatic check_int(input int actual, input int expected, input string what);
    if (actual != expected) begin
      errors++;
      $error("%s: expected %0d, got %0d", what, expected, actual);
    end
  endtask

  function automatic tb_wide_data_t beat(input int unsigned i);
    tb_wide_data_t d;
    d          = '0;
    d[63:0]    = 64'hC0FF_EE00_0000_0000 + i;
    d[511:448] = 64'hFEED_FACE_0000_0000 + i;
    return d;
  endfunction

  task automatic write_send_cfg(input tb_id_t id);
    tb_xdma_inter_cluster_cfg_t cfg;
    cfg                                     = '0;
    cfg.dma_type                            = 1'b1;  // write
    cfg.frame_length                        = 4'd1;
    cfg.dma_id                              = id;
    cfg.reader_addr                         = cluster_base(0);
    cfg.writer_addr                         = cluster_base(1);
    cfg.first_frame_remaining_payload[31:0] = 32'hCAFE_F00D;
    last_cfg_sent                           = cfg;

    to_remote_cfg[0]       <= cfg;
    to_remote_cfg_valid[0] <= 1'b1;
    @(negedge clk);
    while (!to_remote_cfg_ready[0]) @(negedge clk);
    @(posedge clk);
    to_remote_cfg_valid[0] <= 1'b0;
    to_remote_cfg[0]       <= '0;
  endtask

  task automatic write_send_data(input tb_id_t id, input int unsigned len);
    // Receiver window: node 1 is the last (and only) hop of this write.
    from_remote_acfg[1].dma_id            <= id;
    from_remote_acfg[1].dma_type          <= 1'b1;
    from_remote_acfg[1].src_addr          <= cluster_base(0);
    from_remote_acfg[1].dst_addr          <= cluster_base(1);
    from_remote_acfg[1].dma_length        <= tb_len_t'(len);
    from_remote_acfg[1].ready_to_transfer <= 1'b1;
    from_remote_acfg[1].is_first_cw       <= 1'b0;
    from_remote_acfg[1].is_last_cw        <= 1'b1;

    // Sender window: node 0 originates.
    to_remote_acfg[0].dma_id            <= id;
    to_remote_acfg[0].dma_type          <= 1'b1;
    to_remote_acfg[0].src_addr          <= cluster_base(0);
    to_remote_acfg[0].dst_addr          <= cluster_base(1);
    to_remote_acfg[0].dma_length        <= tb_len_t'(len);
    to_remote_acfg[0].ready_to_transfer <= 1'b1;
    to_remote_acfg[0].is_first_cw       <= 1'b1;
    to_remote_acfg[0].is_last_cw        <= 1'b0;
    @(posedge clk);

    for (int unsigned i = 0; i < len; i++) begin
      head_data  <= beat(i);
      head_valid <= 1'b1;
      @(negedge clk);
      while (!to_remote_data_ready[0]) @(negedge clk);
      @(posedge clk);
    end
    head_valid <= 1'b0;

    // The receiver closing its window is what releases the finish back to node 0.
    wait (rx_cnt == len);
    @(posedge clk);
    from_remote_acfg[1].ready_to_transfer <= 1'b0;
    to_remote_acfg[0].ready_to_transfer   <= 1'b0;
  endtask

  task automatic run_write(input tb_id_t id, input int unsigned len);
    $display("[TB] remote write: dma_id=%0d, dma_length=%0d", id, len);

    write_send_cfg(id);
    @(negedge clk);
    while (!from_remote_cfg_valid[1]) @(negedge clk);
    if (from_remote_cfg[1] !== tb_wide_data_t'(last_cfg_sent)) begin
      errors++;
      $error("node 1 cfg frame mismatch\n  expected %h\n  got      %h",
             tb_wide_data_t'(last_cfg_sent), from_remote_cfg[1]);
    end
    @(posedge clk);
    repeat (5) @(posedge clk);

    write_send_data(id, len);

    wait (finish_cnt[0] == 1);
    repeat (20) @(posedge clk);

    check_int(tx_cnt, len, "beats sent by node 0");
    check_int(rx_cnt, len, "beats received by node 1");
    check_int(finish_cnt[0], 1, "node 0 reports exactly one xdma_finish_o");
    check_int(finish_cnt[1], 0, "node 1 reports no local xdma_finish_o");

    for (int unsigned i = 0; i < len; i++) begin
      if (rx_q[i] !== beat(i)) begin
        errors++;
        $error("payload mismatch at beat %0d\n  expected %h\n  got      %h", i, beat(i), rx_q[i]);
      end
    end

    to_remote_acfg   <= '0;
    from_remote_acfg <= '0;
    repeat (20) @(posedge clk);
    rx_q.delete();
    rx_cnt = 0;
    tx_cnt = 0;
    for (int i = 0; i < TbNumClusters; i++) finish_cnt[i] = 0;
  endtask

  initial begin
    to_remote_cfg       = '0;
    to_remote_cfg_valid = '0;
    to_remote_acfg      = '0;
    from_remote_acfg    = '0;
    head_data           = '0;
    head_valid          = 1'b0;
    rx_cnt              = 0;
    tx_cnt              = 0;
    for (int i = 0; i < TbNumClusters; i++) finish_cnt[i] = 0;

    @(posedge rst_n);
    repeat (10) @(posedge clk);

    // Single beat. The reader drops its busy flag before the grant round trip completes,
    // so this is the case that needs the sticky write-readiness latch.
    run_write(4'd7, 1);
    // 100 beats crosses the 64-beat page, so the burst reshaper splits it and the second
    // run also re-exercises the grant and finish paths back to back.
    run_write(4'd8, 100);

    if (errors != 0) $fatal(1, "[TB] tb_xdma_axi_adapter_top FAILED with %0d error(s)", errors);
    $display("[PASS] tb_xdma_axi_adapter_top");
    $finish;
  end

endmodule
