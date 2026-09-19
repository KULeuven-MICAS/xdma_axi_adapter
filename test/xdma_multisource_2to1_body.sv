// Authors:
// - Fanchen Kong <fanchen.kong@kuleuven.be>
//
// Shared body of the two-sources-one-destination testbenches. Node 0 and node 1 each issue
// a plain remote write to node 2; node 2 is a pure receiver that sources nothing.
//
//        C0 ──── write A (id A) ────►┐
//                                     ├──► C2
//        C1 ──── write B (id B) ────►┘
//
// This is the shape the chain testbenches cannot express. A chain is linear -- every node
// is a hop in exactly one transaction, which is the assumption `xdma_grant_manager`'s
// WRITE_MIDDLE / SEND_GRANT_TO_PREV_HOP states were written under. Here node 2 is the
// destination of two *unrelated* transactions whose receive windows abut, and the adapter
// keeps exactly ONE remote context per direction to serve them with.
//
// The two wrappers differ in a single parameter, and that is the point:
//
//   SerialiseWindows = 1  `tb_xdma_multisource_serial`     -- node 2 fully closes window A
//                                                             (and its finish retires)
//                                                             before window B opens
//   SerialiseWindows = 0  `tb_xdma_multisource_collision`  -- window B opens on the cycle
//                                                             window A stops being named,
//                                                             with `ready_to_transfer`
//                                                             never falling in between
//
// Everything else -- cfg frames, payload, lengths, ids, the wide and narrow buses -- is
// identical. So whatever the second arm does that the first does not is caused by the
// abutting windows alone.
//
// WHY THE SECOND ARM IS THE INTERESTING ONE. The receiving node has one
// `from_remote_data_accompany_cfg_i` port, so two receive windows necessarily arrive one
// after the other on that one port. This arm drives them ABUTTING -- the level held high
// across the change of identity -- and asks whether the adapter's two remote-context
// consumers read that bare level or the identity of the transfer that owns the context:
//
//   xdma_grant_manager   WAIT_FINISH exits on `grant_valid == 0`, and
//                        `grant_valid = ready_to_transfer & dma_type` is combinational off
//                        the LIVE port. B holding the level high means A's context never
//                        retires, so B is never granted.
//
//   xdma_finish_manager  WriteLastBusy exits on `~ready_to_transfer`, so A's finish is
//                        never cascaded back to C0 either.
//
// If a context retires on the bare level the result is a three-way wedge: C1 waits for a grant
// that cannot be issued, C0 waits for a finish that cannot be sent, and C2 sits in both busy
// states forever.
//
// A sending side that drops the level between transfers never produces this stimulus. These
// arms pin the behaviour required of one that does not, which is what a fabric-replicated
// multicast would present.
//
// A FOURTH arm, `DestAlsoIssues`, adds the one thing none of the three has: node 2 runs its
// own remote write back to node 0 while it is taking delivery. Every node is then both an
// issuer and a destination, which is what `docs/xdma_multi_issuer_multicast_hang.md` reports
// hanging in HeMAiA, reduced to the two-issuer bisect that document asks for.
//
// All arms assert the CORRECT behaviour: both writes deliver their payload intact and in
// order, each sender reports exactly one `xdma_finish_o`, the receiver reports none, and no
// watchdog latches.

`timescale 1ns / 1ps
`include "axi/typedef.svh"

module xdma_multisource_2to1_body #(
    /// 1 = node 2 closes its receive window and lets the first write retire before opening
    ///     the second (the "receiver idle between writes" case, which passes today).
    /// 0 = the two receive windows abut with no gap in `ready_to_transfer` (the reproducer).
    parameter bit SerialiseWindows = 1'b0,
    /// 1 = node 2 is already taking delivery of a remote READ of its own when the first
    ///     write's window opens behind it -- the "receiver is not idle" case. It lands on the
    ///     read FSM rather than the write one.
    parameter bit ReadFirst        = 1'b0,
    /// 1 = node 2 is ITSELF an issuer while it takes delivery: it runs its own remote write
    ///     back to node 0 concurrently. Every node is then both an issuer and a destination,
    ///     which is the configuration `docs/xdma_multi_issuer_multicast_hang.md` reports
    ///     hanging, reduced to its two-issuer bisect.
    parameter bit DestAlsoIssues   = 1'b0
) ();

  localparam string ArmName = DestAlsoIssues ? "abutting windows, receiver also issuing"
                            : (SerialiseWindows ? "serialised windows"
                            : (ReadFirst ? "abutting windows behind a local read"
                                         : "abutting windows"));
  // Node 2 owns the read task and nothing else, so it reports a completion only in the
  // `ReadFirst` arm.
  // Node 2 owns the read task in the `ReadFirst` arm and its own outgoing write in the
  // `DestAlsoIssues` arm; it owns neither otherwise.
  localparam int unsigned C2Finishes = (ReadFirst ? 1 : 0) + (DestAlsoIssues ? 1 : 0);


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

  // Beats node 0 must take delivery of: node 2's write, in the arm where node 2 issues one.
  localparam int unsigned C0RxBeats = DestAlsoIssues ? TbLen : 0;

  localparam tb_id_t IdA = 4'd5;
  localparam tb_id_t IdB = 4'd9;
  localparam tb_id_t IdR = 4'd2;
  // Node 2's own outgoing write, in the `DestAlsoIssues` arm.
  localparam tb_id_t IdC = 4'd11;

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
  tb_wide_data_t rx_q[$];
  int rx_cnt;
  tb_wide_data_t rx0_q[$];
  int rx0_cnt;
  int tx_cnt[TbNumClusters];
  int finish_cnt[TbNumClusters];
  int errors = 0;

  always @(posedge clk) begin
    if (rst_n) begin
      if (from_remote_data_valid[2] && from_remote_data_ready[2]) begin
        rx_q.push_back(from_remote_data[2]);
        rx_cnt++;
      end
      if (from_remote_data_valid[0] && from_remote_data_ready[0]) begin
        rx0_q.push_back(from_remote_data[0]);
        rx0_cnt++;
      end
      for (int i = 0; i < TbNumClusters; i++) begin
        if (to_remote_data_valid[i] && to_remote_data_ready[i]) tx_cnt[i]++;
        if (xdma_finish[i]) finish_cnt[i]++;
      end
    end
  end

  // A watchdog trip is the failure. Print the three FSMs that the single-context
  // limitation parks, so the log names the mechanism rather than just the symptom.
  task automatic dump_state();
    $display("[TB] --- adapter state at the wedge ---");
    $display("[TB]   C2 grant_manager.cur_state                 = %s",
             gen_adapter[2].i_dut.i_xdma_grant_manager.cur_state.name());
    $display("[TB]   C2 finish_manager.last_write_current_state = %s",
             gen_adapter[2].i_dut.i_xdma_finish_manager.last_write_current_state.name());
    $display("[TB]   C2 finish_manager.read_current_state        = %s",
             gen_adapter[2].i_dut.i_xdma_finish_manager.read_current_state.name());
    $display("[TB]   C2 from_remote acfg: id=%0d src=%h ready_to_transfer=%0b",
             from_remote_acfg[2].dma_id, from_remote_acfg[2].src_addr,
             from_remote_acfg[2].ready_to_transfer);
    // Unrolled: a generate block cannot be indexed by a variable.
    $display("[TB]   C2 to_remote acfg:   id=%0d dst=%h ready_to_transfer=%0b",
             to_remote_acfg[2].dma_id, to_remote_acfg[2].dst_addr,
             to_remote_acfg[2].ready_to_transfer);
    $display("[TB]   C0 grant_manager.cur_state                  = %s",
             gen_adapter[0].i_dut.i_xdma_grant_manager.cur_state.name());
    $display("[TB]   C0 finish_manager.first_write_current_state = %s",
             gen_adapter[0].i_dut.i_xdma_finish_manager.first_write_current_state.name());
    $display("[TB]   C1 finish_manager.first_write_current_state = %s",
             gen_adapter[1].i_dut.i_xdma_finish_manager.first_write_current_state.name());
    $display("[TB]   beats: C0 sent %0d, C1 sent %0d, C2 received %0d (expected %0d each / %0d)",
             tx_cnt[0], tx_cnt[1], rx_cnt, TbLen, 2 * TbLen);
    $display("[TB]   xdma_finish pulses: C0=%0d C1=%0d C2=%0d", finish_cnt[0], finish_cnt[1],
             finish_cnt[2]);
    if (DestAlsoIssues) begin
      $display("[TB]   C2 sent %0d beats of its own write, C0 received %0d (expected %0d)",
               tx_cnt[2], rx0_cnt, TbLen);
    end
  endtask

  always @(posedge clk) begin
    if (rst_n && (|xdma_stall_error)) begin
      $error("[TB] stall watchdog tripped: xdma_stall_error = %b", xdma_stall_error);
      dump_state();
      $display("[TB] 2-to-1 %s FAILED (deadlock)", ArmName);
      $finish;
    end
  end

  initial begin
    #SimTimeout;
    $error("[TB] global timeout -- the two writes never both completed");
    dump_state();
    $display("[TB] 2-to-1 %s FAILED (timeout)", ArmName);
    $finish;
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

  // Tag the payload with its source so an out-of-order or cross-contaminated delivery
  // cannot pass: the two writes carry disjoint beat values.
  function automatic tb_wide_data_t beat(input int unsigned src, input int unsigned i);
    tb_wide_data_t d;
    d          = '0;
    d[63:0]    = 64'hC0FF_EE00_0000_0000 + (src << 16) + i;
    d[255:192] = 64'h5A5A_5A5A_0000_0000 + (src << 16) + i;
    d[511:448] = 64'hFEED_FACE_0000_0000 + (src << 16) + i;
    return d;
  endfunction

  // One cfg frame, src -> dst. Sent one at a time and awaited at the destination: the
  // narrow path reassembles a frame from 8 beats, so two frames pushed concurrently into
  // one receiver would interleave. That is a separate question from the one this
  // testbench asks, so it is kept out of the way rather than tested here.
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

    @(negedge clk);
    while (!from_remote_cfg_valid[dst]) @(negedge clk);
    if (from_remote_cfg[dst] !== tb_wide_data_t'(last_cfg_sent)) begin
      errors++;
      $error("node %0d cfg frame mismatch\n  expected %h\n  got      %h", dst,
             tb_wide_data_t'(last_cfg_sent), from_remote_cfg[dst]);
    end
    @(posedge clk);
  endtask

  // Open a sender's window. `is_first_cw` with no `is_last_cw` is the head of a
  // (degenerate, single-hop) write, and the sender owns the task, so it is the initiator.
  task automatic open_sender(input int unsigned src, input tb_id_t id);
    to_remote_acfg[src].dma_id            <= id;
    to_remote_acfg[src].dma_type          <= 1'b1;
    to_remote_acfg[src].src_addr          <= cluster_base(src);
    to_remote_acfg[src].dst_addr          <= cluster_base(2);
    to_remote_acfg[src].dma_length        <= tb_len_t'(TbLen);
    to_remote_acfg[src].ready_to_transfer <= 1'b1;
    to_remote_acfg[src].is_first_cw       <= 1'b1;
    to_remote_acfg[src].is_last_cw        <= 1'b0;
    to_remote_acfg[src].is_initiator      <= 1'b1;
  endtask

  // Node 2's own outgoing write, back to node 0. Node 2 is then an issuer at the same time
  // as it is a destination, and its cfg for this write shares the narrow bus with the grants
  // it owes nodes 0 and 1.
  task automatic open_sender_c2(input tb_id_t id);
    to_remote_acfg[2].dma_id            <= id;
    to_remote_acfg[2].dma_type          <= 1'b1;
    to_remote_acfg[2].src_addr          <= cluster_base(2);
    to_remote_acfg[2].dst_addr          <= cluster_base(0);
    to_remote_acfg[2].dma_length        <= tb_len_t'(TbLen);
    to_remote_acfg[2].ready_to_transfer <= 1'b1;
    to_remote_acfg[2].is_first_cw       <= 1'b1;
    to_remote_acfg[2].is_last_cw        <= 1'b0;
    to_remote_acfg[2].is_initiator      <= 1'b1;
  endtask

  // Node 0's receive window for node 2's write. Node 0 is a sender and a destination at the
  // same time, so its own grant manager is in use while its wide send is still outstanding.
  task automatic point_c0_receiver_at_c2(input tb_id_t id);
    from_remote_acfg[0].dma_id            <= id;
    from_remote_acfg[0].dma_type          <= 1'b1;
    from_remote_acfg[0].src_addr          <= cluster_base(2);
    from_remote_acfg[0].dst_addr          <= cluster_base(0);
    from_remote_acfg[0].dma_length        <= tb_len_t'(TbLen);
    from_remote_acfg[0].ready_to_transfer <= 1'b1;
    from_remote_acfg[0].is_first_cw       <= 1'b0;
    from_remote_acfg[0].is_last_cw        <= 1'b1;
    from_remote_acfg[0].is_initiator      <= 1'b0;
  endtask

  // Open a remote-READ receive window on node 2. Only the read FSM in
  // `xdma_finish_manager` watches this -- `dma_type = 0` keeps the grant manager and the
  // middle/last-write FSM in idle -- so no payload is transported for it here; the FSM
  // under test reads the accompany cfg and nothing else.
  task automatic open_receiver_read(input tb_id_t id);
    from_remote_acfg[2].dma_id            <= id;
    from_remote_acfg[2].dma_type          <= 1'b0;  // read
    from_remote_acfg[2].src_addr          <= cluster_base(1);
    from_remote_acfg[2].dst_addr          <= cluster_base(2);
    from_remote_acfg[2].dma_length        <= tb_len_t'(TbLen);
    from_remote_acfg[2].ready_to_transfer <= 1'b1;
    from_remote_acfg[2].is_first_cw       <= 1'b0;
    from_remote_acfg[2].is_last_cw        <= 1'b0;
    // Node 2 issued this read, so it owns it.
    from_remote_acfg[2].is_initiator      <= 1'b1;
  endtask

  // Point node 2's single receive context at `src`'s transfer. `ready_to_transfer` is
  // written unconditionally high -- in the collision arm this is what makes the two
  // windows abut, because the caller never drives it low in between.
  task automatic point_receiver_at(input int unsigned src, input tb_id_t id);
    from_remote_acfg[2].dma_id            <= id;
    from_remote_acfg[2].dma_type          <= 1'b1;
    from_remote_acfg[2].src_addr          <= cluster_base(src);
    from_remote_acfg[2].dst_addr          <= cluster_base(2);
    from_remote_acfg[2].dma_length        <= tb_len_t'(TbLen);
    from_remote_acfg[2].ready_to_transfer <= 1'b1;
    from_remote_acfg[2].is_first_cw       <= 1'b0;
    from_remote_acfg[2].is_last_cw        <= 1'b1;
    // The receiver sources nothing and owns neither task.
    from_remote_acfg[2].is_initiator      <= 1'b0;
  endtask

  // Push `TbLen` beats from `src`. The adapter gates its wide W beats on the grant credit,
  // so this blocks until node 2 has granted this sender -- which is exactly what node 1
  // never gets in the collision arm.
  task automatic send_payload(input int unsigned src);
    for (int unsigned i = 0; i < TbLen; i++) begin
      if (src == 0) begin
        s0_data  <= beat(0, i);
        s0_valid <= 1'b1;
      end else if (src == 1) begin
        s1_data  <= beat(1, i);
        s1_valid <= 1'b1;
      end else begin
        s2_data  <= beat(2, i);
        s2_valid <= 1'b1;
      end
      @(negedge clk);
      while (!to_remote_data_ready[src]) @(negedge clk);
      @(posedge clk);
    end
    if (src == 0) s0_valid <= 1'b0;
    else if (src == 1) s1_valid <= 1'b0;
    else s2_valid <= 1'b0;
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
    rx_cnt              = 0;
    rx0_cnt             = 0;
    for (int i = 0; i < TbNumClusters; i++) begin
      tx_cnt[i]     = 0;
      finish_cnt[i] = 0;
    end

    @(posedge rst_n);
    repeat (10) @(posedge clk);

    $display("[TB] 2-to-1 remote write, %s: C0(id=%0d) and C1(id=%0d) -> C2, %0d beats each",
             ArmName, IdA, IdB, TbLen);

    //---- Phase A: both senders configure the destination ----
    send_cfg(0, 2, IdA);
    send_cfg(1, 2, IdB);
    // Node 2 configures its own outgoing write in the same phase, so by the time it owes
    // node 0 and node 1 their grants it is already an issuer with cfg traffic of its own.
    if (DestAlsoIssues) send_cfg(2, 0, IdC);
    repeat (5) @(posedge clk);

    //---- Phase B: BOTH senders go live at once ----
    // This is the "two issuers targeting one destination concurrently" case. Node 1's
    // adapter claims its wide send here and then parks on the grant; nothing it does can
    // reach the bus until node 2 grants it.
    open_sender(0, IdA);
    open_sender(1, IdB);
    if (DestAlsoIssues) begin
      open_sender_c2(IdC);
      point_c0_receiver_at_c2(IdC);
    end
    @(posedge clk);

    if (ReadFirst) begin
      // The receiver is busy with its own remote read first. Its window is NOT closed
      // before the write's is opened -- the node is simply busy throughout, which is the
      // whole point: `ready_to_transfer` never falls, so the read context has to retire on
      // the port no longer naming a read.
      open_receiver_read(IdR);
      repeat (20) @(posedge clk);
    end

    // The receiver can only name one of them, so it starts with A.
    point_receiver_at(0, IdA);
    @(posedge clk);

    fork
      send_payload(0);
      send_payload(1);
      if (DestAlsoIssues) send_payload(2);
    join_none

    //---- Phase C: A's payload lands, and the receive context turns over ----
    wait (rx_cnt == TbLen);
    @(posedge clk);
    // Sender 0 is done pushing bytes; its task is not over until the finish comes back.
    to_remote_acfg[0].ready_to_transfer <= 1'b0;

    if (SerialiseWindows) begin
      // Control arm: the receiver goes fully idle -- `ready_to_transfer` falls, the grant
      // manager leaves WAIT_FINISH, the finish manager leaves WriteLastBusy and cascades
      // A's finish back to C0 -- before B is named. One context is enough for this.
      from_remote_acfg[2].ready_to_transfer <= 1'b0;
      wait (finish_cnt[0] == 1);
      repeat (20) @(posedge clk);
    end
    // Reproducer arm falls straight through: `ready_to_transfer` was never driven low, so
    // the port stops naming A and starts naming B on the same cycle. Nothing in the
    // adapter looks at WHICH transfer the context holds, only at that bare level, so A's
    // context never retires and B's grant is never issued.
    point_receiver_at(1, IdB);
    @(posedge clk);

    //---- Phase D: B's payload lands ----
    wait (rx_cnt == 2 * TbLen);
    @(posedge clk);
    from_remote_acfg[2].ready_to_transfer <= 1'b0;
    to_remote_acfg[1].ready_to_transfer   <= 1'b0;

    // Node 2's own write retires on the same terms: node 0 closes the receive window it
    // opened for it, and node 2 closes its sender window.
    if (DestAlsoIssues) begin
      wait (rx0_cnt == TbLen);
      @(posedge clk);
      from_remote_acfg[0].ready_to_transfer <= 1'b0;
      to_remote_acfg[2].ready_to_transfer   <= 1'b0;
    end

    //---- Phase E: both senders retire ----
    wait (finish_cnt[0] == 1 && finish_cnt[1] == 1 && finish_cnt[2] == C2Finishes);
    repeat (20) @(posedge clk);

    //---- Checks ----
    check_int(tx_cnt[0], TbLen, "beats sent by C0");
    check_int(tx_cnt[1], TbLen, "beats sent by C1");
    check_int(rx_cnt, 2 * TbLen, "beats delivered to C2");
    check_int(tx_cnt[2], DestAlsoIssues ? TbLen : 0, "beats sent by C2");
    check_int(rx0_cnt, C0RxBeats, "beats delivered to C0");
    // Each sender issued its own task, so each reports exactly one completion; the
    // receiver owns neither and must stay silent.
    check_int(finish_cnt[0], 1, "C0 xdma_finish_o pulses");
    check_int(finish_cnt[1], 1, "C1 xdma_finish_o pulses");
    check_int(finish_cnt[2], C2Finishes, "C2 xdma_finish_o pulses");

    // A's beats, then B's. Cross-contamination between the two contexts would show up
    // here as the wrong source tag at the wrong index.
    for (int unsigned i = 0; i < TbLen; i++) begin
      if (rx_q[i] !== beat(0, i)) begin
        errors++;
        $error("write A payload mismatch at beat %0d\n  expected %h\n  got      %h", i,
               beat(0, i), rx_q[i]);
      end
      if (rx_q[TbLen+i] !== beat(1, i)) begin
        errors++;
        $error("write B payload mismatch at beat %0d\n  expected %h\n  got      %h", i,
               beat(1, i), rx_q[TbLen+i]);
      end
    end

    // Node 2's own payload, checked the same way: its beats carry source tag 2.
    for (int unsigned i = 0; i < C0RxBeats; i++) begin
      if (rx0_q[i] !== beat(2, i)) begin
        errors++;
        $error("C2's own write payload mismatch at beat %0d\n  expected %h\n  got      %h", i,
               beat(2, i), rx0_q[i]);
      end
    end

    if (|xdma_stall_error) begin
      errors++;
      $error("[TB] a stall watchdog latched during the run: %b", xdma_stall_error);
    end

    if (errors == 0) $display("[TB] 2-to-1 %s PASSED", ArmName);
    else $display("[TB] 2-to-1 %s FAILED with %0d error(s)", ArmName, errors);
    $finish;
  end

endmodule
