// Authors:
// - Fanchen Kong <fanchen.kong@kuleuven.be>
//
// The HeMAiA multi-issuer multicast hang, reduced to three nodes.
//
// `docs/xdma_multi_issuer_multicast_hang.md` reports FlashAttention decode wedging when all
// four clusters issue a star multicast while each is also a destination of the other three.
// A GRANT manager is the first thing to stall; the stalled cluster's own hart is fine, so
// whatever it holds is blocking somebody else; the senders' wide sends stall later; and two
// harts spin forever on a completion that is lost rather than late.
//
// `tb_xdma_multisource_send_while_receiving` shows that two issuers with a fan-out of one
// do NOT reproduce it, which is the bisect that report asks for in its section 5. This
// testbench adds the one thing that case lacks: a fan-out of MORE THAN ONE per sender.
//
// WHY THAT IS THE HINGE. The adapter keeps one context in each direction. `xdma_req_manager`
// commits the wide send to a single destination until that transfer completes, and
// `xdma_grant_manager` commits the receive to a single source -- it arms in IDLE and then
// holds the context through WAIT_FINISH until that source's window closes. Neither can be
// re-aimed. So with a fan-out of two a cycle is constructible, and with three nodes it is a
// three-cycle:
//
//     node    wide send committed to     grant manager armed on
//     C0      C0 -> C1                   C1 -> C0
//     C1      C1 -> C2                   C2 -> C1
//     C2      C2 -> C0                   C0 -> C2
//
// C0 waits for a grant from C1; C1's grant manager is holding C2's context and cannot arm on
// C0 until C2 -> C1 completes; C2 will not start C2 -> C1 because its send is committed to
// C2 -> C0, which waits for a grant from C0, whose grant manager is holding C1's context...
// Every node is waiting on the node behind it. Nothing times out and nothing retries.
//
// The pairing is not contrived. Which incoming transfer a node's receive context serves is
// decided by cfg arrival order, which across four concurrently-issuing clusters is
// arbitrary; this testbench just pins one arrival order that closes the cycle.
//
// A PASS here means every one of the six transfers delivered its payload intact and each
// issuer reported exactly one completion. A FAIL is the HeMAiA signature: grant managers
// parked, senders parked behind them, and completions that never arrive.

`timescale 1ns / 1ps
`include "axi/typedef.svh"

module tb_xdma_multi_issuer_ring ();

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
    logic     is_initiator;
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

  // A sender legitimately parks its wide send for the whole grant round trip, so this has
  // to sit well above that. It still trips ~40x faster than `SimTimeout`, which keeps the
  // collision arm reporting WHICH FSM wedged rather than just "the run timed out".
  localparam int unsigned TbStallTimeout = 32'd10000;

  localparam time CyclTime   = 10ns;
  localparam time SimTimeout = 4ms;

  // Two writes of this many 512-bit beats each. Short on purpose: nothing here is about
  // burst boundaries, and a short transfer makes the two receive windows abut tightly.
  localparam int unsigned TbLen = 32'd8;

  // One id per transfer, so a grant or finish landing on the wrong context is visible.
  // Transfer n->d is IdOf[n][d].
  localparam tb_id_t IdOf [3][3] = '{'{4'd0, 4'd1, 4'd2},
                                     '{4'd3, 4'd0, 4'd4},
                                     '{4'd5, 4'd6, 4'd0}};

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
  // Adapter-facing signals
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
  logic [TbNumClusters-1:0] xdma_stall_error;

  // Nodes 0 and 1 always source payload. Node 2 sinks, and in the `DestAlsoIssues` arm it
  // sources as well -- which also puts its own outgoing cfg on the narrow bus, where cfg
  // outranks grant in `find_first_one_idx`.
  tb_wide_data_t s0_data, s1_data, s2_data;
  logic          s0_valid, s1_valid, s2_valid;
  wire [TbNumClusters-1:0][TbAxiWideDataWidth-1:0] to_remote_data;
  wire [TbNumClusters-1:0]                         to_remote_data_valid;
  assign to_remote_data[0]       = s0_data;
  assign to_remote_data[1]       = s1_data;
  assign to_remote_data[2]       = s2_data;
  assign to_remote_data_valid[0] = s0_valid;
  assign to_remote_data_valid[1] = s1_valid;
  assign to_remote_data_valid[2] = s2_valid;

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
        .MMIOSize             (MMIOSize),
        .StallTimeout         (TbStallTimeout)
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
        .xdma_stall_error_o              (xdma_stall_error[i]),
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
  tb_wide_data_t rx_q[3][$];
  int rx_cnt[3];
  int tx_cnt[3];
  int finish_cnt[3];
  int errors = 0;

  always @(posedge clk) begin
    if (rst_n) begin
      for (int i = 0; i < TbNumClusters; i++) begin
        if (from_remote_data_valid[i] && from_remote_data_ready[i]) begin
          rx_q[i].push_back(from_remote_data[i]);
          rx_cnt[i]++;
        end
        if (to_remote_data_valid[i] && to_remote_data_ready[i]) tx_cnt[i]++;
        if (xdma_finish[i]) finish_cnt[i]++;
      end
    end
  end

  // The wedge is the point of this testbench, so print the cycle rather than just the symptom:
  // for every node, what its send is committed to and what its grant manager armed on.
  task automatic dump_state();
    $display("[TB] --- the cycle, node by node ---");
    $display("[TB]  C0 grant=%-22s send->%h  recv id=%0d src=%h rtt=%0b  finish=%s",
             gen_adapter[0].i_dut.i_xdma_grant_manager.cur_state.name(),
             to_remote_acfg[0].dst_addr, from_remote_acfg[0].dma_id,
             from_remote_acfg[0].src_addr, from_remote_acfg[0].ready_to_transfer,
             gen_adapter[0].i_dut.i_xdma_finish_manager.last_write_current_state.name());
    $display("[TB]  C1 grant=%-22s send->%h  recv id=%0d src=%h rtt=%0b  finish=%s",
             gen_adapter[1].i_dut.i_xdma_grant_manager.cur_state.name(),
             to_remote_acfg[1].dst_addr, from_remote_acfg[1].dma_id,
             from_remote_acfg[1].src_addr, from_remote_acfg[1].ready_to_transfer,
             gen_adapter[1].i_dut.i_xdma_finish_manager.last_write_current_state.name());
    $display("[TB]  C2 grant=%-22s send->%h  recv id=%0d src=%h rtt=%0b  finish=%s",
             gen_adapter[2].i_dut.i_xdma_grant_manager.cur_state.name(),
             to_remote_acfg[2].dst_addr, from_remote_acfg[2].dma_id,
             from_remote_acfg[2].src_addr, from_remote_acfg[2].ready_to_transfer,
             gen_adapter[2].i_dut.i_xdma_finish_manager.last_write_current_state.name());
    $display("[TB]  beats sent   C0=%0d C1=%0d C2=%0d (expect %0d each)",
             tx_cnt[0], tx_cnt[1], tx_cnt[2], 2 * TbLen);
    $display("[TB]  beats rcvd   C0=%0d C1=%0d C2=%0d (expect %0d each)",
             rx_cnt[0], rx_cnt[1], rx_cnt[2], 2 * TbLen);
    $display("[TB]  xdma_finish  C0=%0d C1=%0d C2=%0d (expect %0d each)",
             finish_cnt[0], finish_cnt[1], finish_cnt[2], 2);
  endtask

  always @(posedge clk) begin
    if (rst_n && (|xdma_stall_error)) begin
      $error("[TB] stall watchdog tripped: xdma_stall_error = %b", xdma_stall_error);
      dump_state();
      $fatal(1, "[TB] multi-issuer ring FAILED (deadlock)");
    end
  end

  initial begin
    #SimTimeout;
    $error("[TB] global timeout -- the ring never drained");
    dump_state();
    $fatal(1, "[TB] multi-issuer ring FAILED (timeout)");
  end

  //====================================================================
  // Stimulus helpers
  //====================================================================
  tb_xdma_inter_cluster_cfg_t last_cfg_sent;
  logic [15:0] cfg_seed = 16'hA5A5;

  task automatic check_int(input int actual, input int expected, input string what);
    if (actual != expected) begin
      errors++;
      $error("%s: expected %0d, got %0d", what, expected, actual);
    end
  endtask

  // Tagged by (source, destination) so a beat delivered to the wrong context is visible.
  function automatic tb_wide_data_t beat(input int unsigned src, input int unsigned dst,
                                         input int unsigned i);
    tb_wide_data_t d;
    d          = '0;
    d[63:0]    = 64'hC0FF_EE00_0000_0000 + (src << 20) + (dst << 16) + i;
    d[255:192] = 64'h5A5A_5A5A_0000_0000 + (src << 20) + (dst << 16) + i;
    d[511:448] = 64'hFEED_FACE_0000_0000 + (src << 20) + (dst << 16) + i;
    return d;
  endfunction

  task automatic send_cfg(input int unsigned src, input int unsigned dst);
    tb_xdma_inter_cluster_cfg_t cfg;
    logic [15:0] seed;
    cfg_seed = cfg_seed + 16'h1234;
    seed = cfg_seed;
    cfg                                     = '0;
    cfg.dma_type                            = 1'b1;
    cfg.frame_length                        = 4'd1;
    cfg.dma_id                              = IdOf[src][dst];
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

    @(negedge clk);
    while (!from_remote_cfg_valid[dst]) @(negedge clk);
    if (from_remote_cfg[dst] !== tb_wide_data_t'(last_cfg_sent)) begin
      errors++;
      $error("node %0d cfg frame mismatch from %0d", dst, src);
    end
    @(posedge clk);
  endtask

  // Commit node `src`'s single wide send context to destination `dst`.
  task automatic commit_send(input int unsigned src, input int unsigned dst);
    to_remote_acfg[src].dma_id            <= IdOf[src][dst];
    to_remote_acfg[src].dma_type          <= 1'b1;
    to_remote_acfg[src].src_addr          <= cluster_base(src);
    to_remote_acfg[src].dst_addr          <= cluster_base(dst);
    to_remote_acfg[src].dma_length        <= tb_len_t'(TbLen);
    to_remote_acfg[src].ready_to_transfer <= 1'b1;
    to_remote_acfg[src].is_first_cw       <= 1'b1;
    to_remote_acfg[src].is_last_cw        <= 1'b0;
    to_remote_acfg[src].is_initiator      <= 1'b1;
  endtask

  // Point node `dst`'s single receive context at the write coming from `src`.
  task automatic commit_recv(input int unsigned dst, input int unsigned src);
    from_remote_acfg[dst].dma_id            <= IdOf[src][dst];
    from_remote_acfg[dst].dma_type          <= 1'b1;
    from_remote_acfg[dst].src_addr          <= cluster_base(src);
    from_remote_acfg[dst].dst_addr          <= cluster_base(dst);
    from_remote_acfg[dst].dma_length        <= tb_len_t'(TbLen);
    from_remote_acfg[dst].ready_to_transfer <= 1'b1;
    from_remote_acfg[dst].is_first_cw       <= 1'b0;
    from_remote_acfg[dst].is_last_cw        <= 1'b1;
    from_remote_acfg[dst].is_initiator      <= 1'b0;
  endtask

  task automatic push_payload(input int unsigned src, input int unsigned dst);
    for (int unsigned i = 0; i < TbLen; i++) begin
      case (src)
        0: begin s0_data <= beat(0, dst, i); s0_valid <= 1'b1; end
        1: begin s1_data <= beat(1, dst, i); s1_valid <= 1'b1; end
        default: begin s2_data <= beat(2, dst, i); s2_valid <= 1'b1; end
      endcase
      @(negedge clk);
      while (!to_remote_data_ready[src]) @(negedge clk);
      @(posedge clk);
    end
    case (src)
      0: s0_valid <= 1'b0;
      1: s1_valid <= 1'b0;
      default: s2_valid <= 1'b0;
    endcase
  endtask

  // One hop of the ring, from `src`'s point of view: it is committed to `dst`, pushes its
  // payload, and waits for the finish to come back before it may re-aim its send context.
  task automatic run_leg(input int unsigned src, input int unsigned dst,
                         input int unsigned leg);
    int unsigned want;
    commit_send(src, dst);
    @(posedge clk);
    push_payload(src, dst);
    want = leg + 1;
    wait (finish_cnt[src] == want);
    @(posedge clk);
    to_remote_acfg[src].ready_to_transfer <= 1'b0;
    @(posedge clk);
  endtask

  // One hop from `dst`'s point of view: hold the receive window open until the payload has
  // landed, then close it, which is what releases the finish back to `src`.
  task automatic serve_leg(input int unsigned dst, input int unsigned src,
                           input int unsigned leg);
    int unsigned want;
    commit_recv(dst, src);
    want = (leg + 1) * TbLen;
    wait (rx_cnt[dst] == want);
    @(posedge clk);
    from_remote_acfg[dst].ready_to_transfer <= 1'b0;
    @(posedge clk);
  endtask

  //====================================================================
  // Test
  //====================================================================
  initial begin
    to_remote_cfg       = '0;
    to_remote_cfg_valid = '0;
    to_remote_acfg      = '0;
    from_remote_acfg    = '0;
    s0_data             = '0;
    s1_data             = '0;
    s2_data             = '0;
    s0_valid            = 1'b0;
    s1_valid            = 1'b0;
    s2_valid            = 1'b0;
    for (int i = 0; i < 3; i++) begin
      rx_cnt[i]     = 0;
      tx_cnt[i]     = 0;
      finish_cnt[i] = 0;
    end

    @(posedge rst_n);
    repeat (10) @(posedge clk);

    $display("[TB] 3-node all-to-all: every node issues to both others and receives from both");

    //---- Phase A: every node announces BOTH of its writes before any data moves ----
    // A star multicast configures all of its destinations up front, so across concurrently
    // issuing clusters the arrival order at any one destination is arbitrary. This order is
    // the adversarial one: at each node the cfg that arrives FIRST is from the sender that
    // is about to commit its own send context somewhere else.
    send_cfg(2, 1);
    send_cfg(0, 2);
    send_cfg(1, 0);
    send_cfg(0, 1);
    send_cfg(1, 2);
    send_cfg(2, 0);
    repeat (5) @(posedge clk);

    //---- Phases B..D: the ring runs ----
    // Leg 0 is the cycle: C0->C1, C1->C2, C2->C0 as sends, while the receive contexts are
    // aimed at C1->C0, C2->C1, C0->C2 -- each node serving the sender that is busy elsewhere.
    // Leg 1 is what is left over, and only becomes reachable once leg 0 has drained.
    fork
      begin run_leg(0, 1, 0); run_leg(0, 2, 1); end
      begin run_leg(1, 2, 0); run_leg(1, 0, 1); end
      begin run_leg(2, 0, 0); run_leg(2, 1, 1); end
      begin serve_leg(0, 2, 0); serve_leg(0, 1, 1); end
      begin serve_leg(1, 0, 0); serve_leg(1, 2, 1); end
      begin serve_leg(2, 1, 0); serve_leg(2, 0, 1); end
    join

    repeat (20) @(posedge clk);

    //---- Checks ----
    for (int unsigned n = 0; n < 3; n++) begin
      check_int(tx_cnt[n], 2 * TbLen, $sformatf("beats sent by C%0d", n));
      check_int(rx_cnt[n], 2 * TbLen, $sformatf("beats delivered to C%0d", n));
      check_int(finish_cnt[n], 2, $sformatf("C%0d xdma_finish_o pulses", n));
    end

    if (|xdma_stall_error) begin
      errors++;
      $error("[TB] a stall watchdog latched during the run: %b", xdma_stall_error);
    end

    if (errors != 0) $fatal(1, "[TB] multi-issuer ring FAILED with %0d error(s)", errors);
    $display("[PASS] tb_xdma_multi_issuer_ring");
    $finish;
  end

endmodule
