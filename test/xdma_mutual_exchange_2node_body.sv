// Authors:
// - Fanchen Kong <fanchen.kong@kuleuven.be>
//
// Two nodes that write to each other at the same time. C0 -> C1 (id A) and C1 -> C0 (id B),
// both in flight together, so **every node is simultaneously the head of its own write and
// the tail of someone else's**.
//
// This is the smallest form of the measured "every cluster both sends and receives" arm.
// It is not a chain and not a star: the two roles a chain keeps on separate nodes land on
// one node here.
//
// WHAT IT PROBES. `SpuriousFinishGuard` in `xdma_finish_manager` makes FSM2 -- the head's
// completion FSM -- require that the node is NOT taking delivery of chained-write data,
// both to arm and to stay armed:
//
//   receiving_chained_write = dma_type & ready_to_transfer & (~is_first_cw)
//
// Read that predicate carefully: it is true for a MIDDLE hop and for a TAIL, because both
// have `is_first_cw = 0`. It does not distinguish "I am a hop in the chain I think I head"
// from "I am the destination of an unrelated write". So a node receiving *any* remote write
// has its head claim retracted, including the claim on its own, entirely separate outgoing
// transfer -- and while retracted it cannot re-arm either.
//
// The guard's own comment states the assumption it rests on:
//
//     "This rests on the frontend running one task at a time per node, so a node is never
//      simultaneously the head of one chain and a hop in another."
//
// That assumption is exactly what concurrent multi-issuer traffic breaks, and it is the
// same assumption the single-remote-context deadlock rested on. This testbench asks whether
// the guard survives it.
//
// Two sequencings, because the answer depends on one:
//
//   HoldSenderWindow = 1  each node keeps its to-remote window open until its own finish
//                         arrives -- the faithful model, since the task is not over until
//                         then. FSM2 can re-arm once the incoming window closes.
//   HoldSenderWindow = 0  each node drops both windows together, as the chain testbenches
//                         do. FSM2 has no `head_claim` left to re-arm on.
//
// Either way the assertion is the same: both payloads arrive intact and each node reports
// exactly one `xdma_finish_o`, for the write it issued.

`timescale 1ns / 1ps
`include "axi/typedef.svh"

module xdma_mutual_exchange_2node_body #(
    /// Keep each node's to-remote window open until its own completion arrives.
    parameter bit HoldSenderWindow = 1'b1
) ();

  localparam string ArmName = HoldSenderWindow ? "sender window held to completion"
                                               : "both windows dropped together";

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
  localparam int unsigned TbNumClusters       = 32'd2;
  localparam tb_addr_t    ClusterBaseAddr     = 48'h1000_0000;
  localparam tb_addr_t    ClusterAddressSpace = 48'h0010_0000;
  localparam tb_addr_t    MainMemBaseAddr     = 48'h8000_0000;
  localparam tb_addr_t    MainMemEndAddr      = 48'b1 << 32;
  localparam int unsigned MMIOSize            = 16;
  localparam int unsigned TbStallTimeout      = 32'd10000;

  localparam time CyclTime   = 10ns;
  localparam time SimTimeout = 4ms;

  localparam int unsigned TbLen = 32'd8;
  localparam tb_id_t      IdA   = 4'd6;   // C0 -> C1
  localparam tb_id_t      IdB   = 4'd11;  // C1 -> C0

  function automatic tb_addr_t cluster_base(input int unsigned i);
    return ClusterBaseAddr + i * ClusterAddressSpace;
  endfunction

  function automatic int unsigned peer(input int unsigned i);
    return 1 - i;
  endfunction

  function automatic tb_id_t id_of(input int unsigned i);
    return (i == 0) ? IdA : IdB;
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
      NoSlvPorts: TbNumClusters, NoMstPorts: TbNumClusters,
      MaxMstTrans: 10, MaxSlvTrans: 6, FallThrough: 1'b0,
      LatencyMode: axi_pkg::CUT_ALL_AX, PipelineStages: TbPipeline,
      AxiIdWidthSlvPorts: TbIdWidthIn, AxiIdUsedSlvPorts: TbIdWidthIn, UniqueIds: 1'b0,
      AxiAddrWidth: TbAxiAddrWidth, AxiDataWidth: TbAxiWideDataWidth,
      NoAddrRules: TbNumClusters
  };

  localparam axi_pkg::xbar_cfg_t NarrowXbarCfg = '{
      NoSlvPorts: TbNumClusters, NoMstPorts: TbNumClusters,
      MaxMstTrans: 10, MaxSlvTrans: 6, FallThrough: 1'b0,
      LatencyMode: axi_pkg::CUT_ALL_AX, PipelineStages: TbPipeline,
      AxiIdWidthSlvPorts: TbIdWidthIn, AxiIdUsedSlvPorts: TbIdWidthIn, UniqueIds: 1'b0,
      AxiAddrWidth: TbAxiAddrWidth, AxiDataWidth: TbAxiNarrowDataWidth,
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
      .Cfg(WideXbarCfg), .ATOPs(0),
      .slv_aw_chan_t(axi_wide_mst_aw_chan_t), .mst_aw_chan_t(axi_wide_slv_aw_chan_t),
      .w_chan_t(axi_wide_mst_w_chan_t),
      .slv_b_chan_t(axi_wide_mst_b_chan_t), .mst_b_chan_t(axi_wide_slv_b_chan_t),
      .slv_ar_chan_t(axi_wide_mst_ar_chan_t), .mst_ar_chan_t(axi_wide_slv_ar_chan_t),
      .slv_r_chan_t(axi_wide_mst_r_chan_t), .mst_r_chan_t(axi_wide_slv_r_chan_t),
      .slv_req_t(axi_wide_mst_req_t), .slv_resp_t(axi_wide_mst_resp_t),
      .mst_req_t(axi_wide_slv_req_t), .mst_resp_t(axi_wide_slv_resp_t),
      .rule_t(tb_rule_t)
  ) i_wide_xbar (
      .clk_i(clk), .rst_ni(rst_n), .test_i(1'b0),
      .slv_ports_req_i(wide_mst_req), .slv_ports_resp_o(wide_mst_rsp),
      .mst_ports_req_o(wide_slv_req), .mst_ports_resp_i(wide_slv_rsp),
      .addr_map_i(XbarRule), .en_default_mst_port_i('0), .default_mst_port_i('0)
  );

  axi_xbar #(
      .Cfg(NarrowXbarCfg), .ATOPs(0),
      .slv_aw_chan_t(axi_narrow_mst_aw_chan_t), .mst_aw_chan_t(axi_narrow_slv_aw_chan_t),
      .w_chan_t(axi_narrow_mst_w_chan_t),
      .slv_b_chan_t(axi_narrow_mst_b_chan_t), .mst_b_chan_t(axi_narrow_slv_b_chan_t),
      .slv_ar_chan_t(axi_narrow_mst_ar_chan_t), .mst_ar_chan_t(axi_narrow_slv_ar_chan_t),
      .slv_r_chan_t(axi_narrow_mst_r_chan_t), .mst_r_chan_t(axi_narrow_slv_r_chan_t),
      .slv_req_t(axi_narrow_mst_req_t), .slv_resp_t(axi_narrow_mst_resp_t),
      .mst_req_t(axi_narrow_slv_req_t), .mst_resp_t(axi_narrow_slv_resp_t),
      .rule_t(tb_rule_t)
  ) i_narrow_xbar (
      .clk_i(clk), .rst_ni(rst_n), .test_i(1'b0),
      .slv_ports_req_i(narrow_mst_req), .slv_ports_resp_o(narrow_mst_rsp),
      .mst_ports_req_o(narrow_slv_req), .mst_ports_resp_i(narrow_slv_rsp),
      .addr_map_i(XbarRule), .en_default_mst_port_i('0), .default_mst_port_i('0)
  );

  clk_rst_gen #(.ClkPeriod(CyclTime), .RstClkCycles(5)) i_clk_gen (
      .clk_o(clk), .rst_no(rst_n));

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
  logic [TbNumClusters-1:0] xdma_stall_error;

  // Both nodes source payload -- that is the whole point.
  tb_wide_data_t s0_data, s1_data;
  logic          s0_valid, s1_valid;
  wire [TbNumClusters-1:0][TbAxiWideDataWidth-1:0] to_remote_data;
  wire [TbNumClusters-1:0]                         to_remote_data_valid;
  assign to_remote_data[0]       = s0_data;
  assign to_remote_data[1]       = s1_data;
  assign to_remote_data_valid[0] = s0_valid;
  assign to_remote_data_valid[1] = s1_valid;

  for (genvar i = 0; i < TbNumClusters; i++) begin : gen_adapter
    xdma_axi_adapter_top #(
        .MaxMemSizeKiB(TbMaxMemSizeKiB), .WordlineWidth(TbWordlineWidth),
        .WideAXIIdWidth(TbIdWidthOut), .NarrowAXIIdWidth(TbIdWidthOut),
        .axi_wide_out_req_t(axi_wide_mst_req_t), .axi_wide_out_resp_t(axi_wide_mst_resp_t),
        .axi_wide_in_req_t(axi_wide_slv_req_t), .axi_wide_in_resp_t(axi_wide_slv_resp_t),
        .axi_narrow_out_req_t(axi_narrow_mst_req_t),
        .axi_narrow_out_resp_t(axi_narrow_mst_resp_t),
        .axi_narrow_in_req_t(axi_narrow_slv_req_t),
        .axi_narrow_in_resp_t(axi_narrow_slv_resp_t),
        .ClusterBaseAddr(ClusterBaseAddr), .ClusterAddressSpace(ClusterAddressSpace),
        .MainMemBaseAddr(MainMemBaseAddr), .MainMemEndAddr(MainMemEndAddr),
        .MMIOSize(MMIOSize), .StallTimeout(TbStallTimeout)
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
  tb_wide_data_t rx_q[TbNumClusters][$];
  int rx_cnt[TbNumClusters];
  int tx_cnt[TbNumClusters];
  int finish_cnt[TbNumClusters];
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

  task automatic dump_state();
    $display("[TB] --- adapter state ---");
    $display("[TB]   C0 FSM2 first_write=%s  FSM3 last_write=%s",
             gen_adapter[0].i_dut.i_xdma_finish_manager.first_write_current_state.name(),
             gen_adapter[0].i_dut.i_xdma_finish_manager.last_write_current_state.name());
    $display("[TB]   C1 FSM2 first_write=%s  FSM3 last_write=%s",
             gen_adapter[1].i_dut.i_xdma_finish_manager.first_write_current_state.name(),
             gen_adapter[1].i_dut.i_xdma_finish_manager.last_write_current_state.name());
    $display("[TB]   C0 grant=%s   C1 grant=%s",
             gen_adapter[0].i_dut.i_xdma_grant_manager.cur_state.name(),
             gen_adapter[1].i_dut.i_xdma_grant_manager.cur_state.name());
    $display("[TB]   beats sent   : C0=%0d C1=%0d (expected %0d each)", tx_cnt[0], tx_cnt[1],
             TbLen);
    $display("[TB]   beats received: C0=%0d C1=%0d (expected %0d each)", rx_cnt[0], rx_cnt[1],
             TbLen);
    $display("[TB]   xdma_finish pulses: C0=%0d C1=%0d (expected 1 each)", finish_cnt[0],
             finish_cnt[1]);
  endtask

  always @(posedge clk) begin
    if (rst_n && (|xdma_stall_error)) begin
      $error("[TB] stall watchdog tripped: xdma_stall_error = %b", xdma_stall_error);
      dump_state();
      $display("[TB] mutual exchange (%s) FAILED (deadlock)", ArmName);
      $finish;
    end
  end

  initial begin
    #SimTimeout;
    $error("[TB] global timeout -- the exchange never completed");
    dump_state();
    $display("[TB] mutual exchange (%s) FAILED (timeout)", ArmName);
    $finish;
  end

  //====================================================================
  // Stimulus
  //====================================================================
  tb_xdma_inter_cluster_cfg_t last_cfg_sent;
  logic [15:0] cfg_seed = 16'hA5A5;

  task automatic check_int(input int actual, input int expected, input string what);
    if (actual != expected) begin
      errors++;
      $error("%s: expected %0d, got %0d", what, expected, actual);
    end
  endtask

  function automatic tb_wide_data_t beat(input int unsigned src, input int unsigned i);
    tb_wide_data_t d;
    d          = '0;
    d[63:0]    = 64'hC0FF_EE00_0000_0000 + (src << 16) + i;
    d[511:448] = 64'hFEED_FACE_0000_0000 + (src << 16) + i;
    return d;
  endfunction

  task automatic send_cfg(input int unsigned src, input tb_id_t id);
    tb_xdma_inter_cluster_cfg_t cfg;
    cfg_seed = cfg_seed + 16'h1234;
    cfg                                     = '0;
    cfg.dma_type                            = 1'b1;
    cfg.frame_length                        = 4'd1;
    cfg.dma_id                              = id;
    cfg.reader_addr                         = cluster_base(src);
    cfg.writer_addr                         = cluster_base(peer(src));
    cfg.first_frame_remaining_payload[15:0] = cfg_seed;
    last_cfg_sent                           = cfg;

    to_remote_cfg[src]       <= cfg;
    to_remote_cfg_valid[src] <= 1'b1;
    @(negedge clk);
    while (!to_remote_cfg_ready[src]) @(negedge clk);
    @(posedge clk);
    to_remote_cfg_valid[src] <= 1'b0;
    to_remote_cfg[src]       <= '0;
    @(negedge clk);
    while (!from_remote_cfg_valid[peer(src)]) @(negedge clk);
    @(posedge clk);
  endtask

  task automatic send_payload(input int unsigned src);
    for (int unsigned i = 0; i < TbLen; i++) begin
      if (src == 0) begin
        s0_data  <= beat(0, i);
        s0_valid <= 1'b1;
      end else begin
        s1_data  <= beat(1, i);
        s1_valid <= 1'b1;
      end
      @(negedge clk);
      while (!to_remote_data_ready[src]) @(negedge clk);
      @(posedge clk);
    end
    if (src == 0) s0_valid <= 1'b0;
    else s1_valid <= 1'b0;
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
    s0_valid            = 1'b0;
    s1_valid            = 1'b0;
    for (int i = 0; i < TbNumClusters; i++) begin
      rx_cnt[i] = 0; tx_cnt[i] = 0; finish_cnt[i] = 0;
    end

    @(posedge rst_n);
    repeat (10) @(posedge clk);

    $display("[TB] mutual exchange, %s: C0(id=%0d) <-> C1(id=%0d), %0d beats each", ArmName,
             IdA, IdB, TbLen);

    // cfg both ways, one at a time (frame reassembly is not what is under test here).
    send_cfg(0, IdA);
    send_cfg(1, IdB);
    repeat (5) @(posedge clk);

    // Every node opens BOTH windows: head of its own write, tail of its peer's.
    for (int unsigned n = 0; n < TbNumClusters; n++) begin
      to_remote_acfg[n].dma_id            <= id_of(n);
      to_remote_acfg[n].dma_type          <= 1'b1;
      to_remote_acfg[n].src_addr          <= cluster_base(n);
      to_remote_acfg[n].dst_addr          <= cluster_base(peer(n));
      to_remote_acfg[n].dma_length        <= tb_len_t'(TbLen);
      to_remote_acfg[n].ready_to_transfer <= 1'b1;
      to_remote_acfg[n].is_first_cw       <= 1'b1;
      to_remote_acfg[n].is_last_cw        <= 1'b0;
      to_remote_acfg[n].is_initiator      <= 1'b1;

      from_remote_acfg[n].dma_id            <= id_of(peer(n));
      from_remote_acfg[n].dma_type          <= 1'b1;
      from_remote_acfg[n].src_addr          <= cluster_base(peer(n));
      from_remote_acfg[n].dst_addr          <= cluster_base(n);
      from_remote_acfg[n].dma_length        <= tb_len_t'(TbLen);
      from_remote_acfg[n].ready_to_transfer <= 1'b1;
      from_remote_acfg[n].is_first_cw       <= 1'b0;
      from_remote_acfg[n].is_last_cw        <= 1'b1;
      from_remote_acfg[n].is_initiator      <= 1'b0;
    end
    @(posedge clk);

    fork
      send_payload(0);
      send_payload(1);
    join_none

    // Both receive windows close once their payload has landed. That releases each node's
    // finish to its peer.
    wait (rx_cnt[0] == TbLen && rx_cnt[1] == TbLen);
    @(posedge clk);
    from_remote_acfg[0].ready_to_transfer <= 1'b0;
    from_remote_acfg[1].ready_to_transfer <= 1'b0;
    if (!HoldSenderWindow) begin
      // The chain testbenches' sequencing: sender and receiver windows drop together.
      to_remote_acfg[0].ready_to_transfer <= 1'b0;
      to_remote_acfg[1].ready_to_transfer <= 1'b0;
    end

    wait (finish_cnt[0] == 1 && finish_cnt[1] == 1);
    @(posedge clk);
    to_remote_acfg[0].ready_to_transfer <= 1'b0;
    to_remote_acfg[1].ready_to_transfer <= 1'b0;
    repeat (20) @(posedge clk);

    //---- Checks ----
    for (int unsigned n = 0; n < TbNumClusters; n++) begin
      check_int(tx_cnt[n], TbLen, $sformatf("beats sent by C%0d", n));
      check_int(rx_cnt[n], TbLen, $sformatf("beats received by C%0d", n));
      // Each node issued exactly one task, so each must report exactly one completion.
      check_int(finish_cnt[n], 1, $sformatf("C%0d xdma_finish_o pulses", n));
      for (int unsigned i = 0; i < TbLen; i++) begin
        if (rx_q[n][i] !== beat(peer(n), i)) begin
          errors++;
          $error("C%0d payload mismatch at beat %0d\n  expected %h\n  got      %h", n, i,
                 beat(peer(n), i), rx_q[n][i]);
        end
      end
    end

    if (|xdma_stall_error) begin
      errors++;
      $error("[TB] a stall watchdog latched during the run: %b", xdma_stall_error);
    end

    if (errors == 0) $display("[TB] mutual exchange (%s) PASSED", ArmName);
    else $display("[TB] mutual exchange (%s) FAILED with %0d error(s)", ArmName, errors);
    $finish;
  end

endmodule
