// Authors:
// - Fanchen Kong <fanchen.kong@kuleuven.be>
//
// Shared body of the concurrent-chain testbenches: two ChainGathers at once through the two
// clusters of every chip, as a multi-chip system runs one output slice per cluster.
// `tb_xdma_concurrent_chains` runs it with the whole-burst remote writes on and expects both
// chains to complete; `tb_xdma_concurrent_chains_deadlock` runs it with them off and expects
// the deadlock, so a change that makes this testbench stop reaching the hazard fails too.
//
// THE SYSTEM. Three chips of two clusters, one adapter each: node n = 2 * chip + cluster.
//
//   chain A: node 0 (chip 0, cluster 0, head) -> node 2 (chip 1, middle) -> node 4 (chip 2, tail)
//   chain B: node 1 (chip 0, cluster 1, head) -> node 3 (chip 1, middle) -> node 5 (chip 2, tail)
//
// Both chains run the same way (chip 0 -> 1 -> 2), each a ChainGather owned by its tail.
// What makes this a chip and not three loose clusters is the wide fabric:
//
//   outbound  the two clusters' wide masters meet in one axi_mux per chip: one write channel
//             whose W beats follow the order of its accepted AWs
//   inbound   writes to a chip arrive through one port of the chip-level crossbar and only then
//             split to its two clusters: one W stream, in AW order
//
// The narrow bus (cfg, grant, finish) is a plain crossbar; it takes no part in the hazard.
// Each middle hop's junction is a short FIFO, so a hop takes input only as fast as its output
// drains, as the folding junction does.
//
// THE HAZARD. At chip 1 the inbound stream and the outbound channel are shared by A and B.
// If the outbound channel has accepted the AW of an A burst whose data has not arrived, the
// channel waits for A; if the inbound stream's head is a B burst, B's junction is full because
// its output waits behind A; A's data is behind B's burst. Without the whole-burst writes an
// AW leaves once SOME W beat is ready -- possibly one of the burst before -- so this happens.
//
// Checked when the chains complete: each tail receives its own chain's payload, whole and in
// order; exactly the two tails report completion; each middle releases one grant credit.
// Deadlock: no beat moves anywhere for StallCycles while a chain is incomplete.

`timescale 1ns / 1ps
`include "axi/typedef.svh"

module xdma_concurrent_chains_body #(
    /// The adapters' RemoteWriteWholeBurst.
    parameter bit          WholeBurst  = 1'b1,
    /// 1: the run must deadlock (and passes when it does); 0: both chains must complete.
    parameter bit          ExpectDeadlock = 1'b0,
    /// Beats each chain moves (512 beats = 32 KiB, eight 64-beat bursts).
    parameter int unsigned PayloadBeats = 32'd512,
    /// Depth of a middle hop's junction FIFO.
    parameter int unsigned JunctionDepth = 32'd4
) ();

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
  localparam int unsigned NumChips      = 32'd3;
  localparam int unsigned NumNodes      = 2 * NumChips;
  localparam int unsigned NumChains     = 32'd2;
  localparam tb_addr_t    ClusterBaseAddr     = 48'h1000_0000;
  localparam tb_addr_t    ClusterAddressSpace = 48'h0010_0000;
  localparam tb_addr_t    MainMemBaseAddr     = 48'h8000_0000;
  localparam tb_addr_t    MainMemEndAddr      = 48'b1 << 32;
  localparam int unsigned MMIOSize            = 16;

  localparam time         CyclTime    = 10ns;
  localparam time         SimTimeout  = 5ms;
  localparam int unsigned StallCycles = 32'd5000;

  function automatic tb_addr_t cluster_base(input int unsigned n);
    return ClusterBaseAddr + n * ClusterAddressSpace;
  endfunction

  // chain c's head, middle and tail: the chain runs through cluster c of chips 0, 1, 2
  function automatic int unsigned node_of(input int unsigned chain, input int unsigned chip);
    return 2 * chip + chain;
  endfunction

  //====================================================================
  // Interconnect
  //====================================================================
  localparam int unsigned TbAxiUserWidth = 32'd1;
  localparam int unsigned IdOut   = 32'd8;                              // a cluster's masters
  localparam int unsigned IdMux   = IdOut + 1;                          // a chip's outbound port
  localparam int unsigned IdIn    = IdMux + $clog2(NumChips);           // into a cluster (wide)
  localparam int unsigned IdNarIn = IdOut + $clog2(NumNodes);           // into a cluster (narrow)
  if (IdIn != IdNarIn) begin : gen_bad_ids
    $fatal(1, "the wide (%0d) and narrow (%0d) inbound ID widths must match", IdIn, IdNarIn);
  end
  localparam int unsigned TbPipeline = 32'd1;

  typedef logic [IdOut-1:0]                   id_out_t;
  typedef logic [IdMux-1:0]                   id_mux_t;
  typedef logic [IdIn-1:0]                    id_in_t;
  typedef logic [TbAxiUserWidth-1:0]          user_t;
  typedef logic [TbAxiWideDataWidth-1:0]      data_wide_t;
  typedef logic [TbAxiWideDataWidth/8-1:0]    strb_wide_t;
  typedef logic [TbAxiNarrowDataWidth-1:0]    data_narrow_t;
  typedef logic [TbAxiNarrowDataWidth/8-1:0]  strb_narrow_t;

  `AXI_TYPEDEF_ALL(axi_wide_out, tb_addr_t, id_out_t, data_wide_t, strb_wide_t, user_t)
  `AXI_TYPEDEF_ALL(axi_wide_mux, tb_addr_t, id_mux_t, data_wide_t, strb_wide_t, user_t)
  `AXI_TYPEDEF_ALL(axi_wide_in, tb_addr_t, id_in_t, data_wide_t, strb_wide_t, user_t)
  `AXI_TYPEDEF_ALL(axi_narrow_out, tb_addr_t, id_out_t, data_narrow_t, strb_narrow_t, user_t)
  `AXI_TYPEDEF_ALL(axi_narrow_in, tb_addr_t, id_in_t, data_narrow_t, strb_narrow_t, user_t)

  // chip k owns nodes 2k and 2k + 1, contiguous in the address map
  function automatic tb_rule_t [NumChips-1:0] chip_rules();
    for (int unsigned k = 0; k < NumChips; k++) begin
      chip_rules[k] = tb_rule_t'{idx: k, start_addr: cluster_base(2 * k),
                                 end_addr: cluster_base(2 * k + 2)};
    end
  endfunction

  function automatic tb_rule_t [1:0] cluster_rules(input int unsigned chip);
    for (int unsigned c = 0; c < 2; c++) begin
      cluster_rules[c] = tb_rule_t'{idx: c, start_addr: cluster_base(2 * chip + c),
                                    end_addr: cluster_base(2 * chip + c + 1)};
    end
  endfunction

  function automatic tb_rule_t [NumNodes-1:0] node_rules();
    for (int unsigned n = 0; n < NumNodes; n++) begin
      node_rules[n] = tb_rule_t'{idx: n, start_addr: cluster_base(n),
                                 end_addr: cluster_base(n + 1)};
    end
  endfunction

  localparam axi_pkg::xbar_cfg_t ChipXbarCfg = '{
      NoSlvPorts: NumChips,
      NoMstPorts: NumChips,
      MaxMstTrans: 10,
      MaxSlvTrans: 6,
      FallThrough: 1'b0,
      LatencyMode: axi_pkg::CUT_ALL_AX,
      PipelineStages: TbPipeline,
      AxiIdWidthSlvPorts: IdMux,
      AxiIdUsedSlvPorts: IdMux,
      UniqueIds: 1'b0,
      AxiAddrWidth: TbAxiAddrWidth,
      AxiDataWidth: TbAxiWideDataWidth,
      NoAddrRules: NumChips
  };

  localparam axi_pkg::xbar_cfg_t SplitXbarCfg = '{
      NoSlvPorts: 1,
      NoMstPorts: 2,
      MaxMstTrans: 10,
      MaxSlvTrans: 6,
      FallThrough: 1'b0,
      LatencyMode: axi_pkg::CUT_ALL_AX,
      PipelineStages: TbPipeline,
      AxiIdWidthSlvPorts: IdIn,
      AxiIdUsedSlvPorts: IdIn,
      UniqueIds: 1'b0,
      AxiAddrWidth: TbAxiAddrWidth,
      AxiDataWidth: TbAxiWideDataWidth,
      NoAddrRules: 2
  };

  localparam axi_pkg::xbar_cfg_t NarrowXbarCfg = '{
      NoSlvPorts: NumNodes,
      NoMstPorts: NumNodes,
      MaxMstTrans: 10,
      MaxSlvTrans: 6,
      FallThrough: 1'b0,
      LatencyMode: axi_pkg::CUT_ALL_AX,
      PipelineStages: TbPipeline,
      AxiIdWidthSlvPorts: IdOut,
      AxiIdUsedSlvPorts: IdOut,
      UniqueIds: 1'b0,
      AxiAddrWidth: TbAxiAddrWidth,
      AxiDataWidth: TbAxiNarrowDataWidth,
      NoAddrRules: NumNodes
  };

  logic clk;
  logic rst_n;

  clk_rst_gen #(
      .ClkPeriod   (CyclTime),
      .RstClkCycles(5)
  ) i_clk_gen (
      .clk_o (clk),
      .rst_no(rst_n)
  );

  axi_wide_out_req_t    [NumNodes-1:0] wide_out_req;
  axi_wide_out_resp_t   [NumNodes-1:0] wide_out_rsp;
  axi_wide_in_req_t     [NumNodes-1:0] wide_in_req;
  axi_wide_in_resp_t    [NumNodes-1:0] wide_in_rsp;
  axi_wide_mux_req_t    [NumChips-1:0] chip_out_req;
  axi_wide_mux_resp_t   [NumChips-1:0] chip_out_rsp;
  axi_wide_in_req_t     [NumChips-1:0] chip_in_req;
  axi_wide_in_resp_t    [NumChips-1:0] chip_in_rsp;
  axi_narrow_out_req_t  [NumNodes-1:0] narrow_out_req;
  axi_narrow_out_resp_t [NumNodes-1:0] narrow_out_rsp;
  axi_narrow_in_req_t   [NumNodes-1:0] narrow_in_req;
  axi_narrow_in_resp_t  [NumNodes-1:0] narrow_in_rsp;

  // Per chip: the outbound mux of its two clusters, and the inbound split to them
  for (genvar k = 0; k < NumChips; k++) begin : gen_chip
    axi_mux #(
        .SlvAxiIDWidth(IdOut),
        .slv_aw_chan_t(axi_wide_out_aw_chan_t),
        .mst_aw_chan_t(axi_wide_mux_aw_chan_t),
        .w_chan_t     (axi_wide_out_w_chan_t),
        .slv_b_chan_t (axi_wide_out_b_chan_t),
        .mst_b_chan_t (axi_wide_mux_b_chan_t),
        .slv_ar_chan_t(axi_wide_out_ar_chan_t),
        .mst_ar_chan_t(axi_wide_mux_ar_chan_t),
        .slv_r_chan_t (axi_wide_out_r_chan_t),
        .mst_r_chan_t (axi_wide_mux_r_chan_t),
        .slv_req_t    (axi_wide_out_req_t),
        .slv_resp_t   (axi_wide_out_resp_t),
        .mst_req_t    (axi_wide_mux_req_t),
        .mst_resp_t   (axi_wide_mux_resp_t),
        .NoSlvPorts   (32'd2),
        .MaxWTrans    (32'd8),
        .FallThrough  (1'b0),
        .SpillAw      (1'b1),
        .SpillW       (1'b0),
        .SpillB       (1'b0),
        .SpillAr      (1'b1),
        .SpillR       (1'b0)
    ) i_out_mux (
        .clk_i      (clk),
        .rst_ni     (rst_n),
        .test_i     (1'b0),
        .slv_reqs_i (wide_out_req[2*k+:2]),
        .slv_resps_o(wide_out_rsp[2*k+:2]),
        .mst_req_o  (chip_out_req[k]),
        .mst_resp_i (chip_out_rsp[k])
    );

    axi_xbar #(
        .Cfg          (SplitXbarCfg),
        .ATOPs        (0),
        .slv_aw_chan_t(axi_wide_in_aw_chan_t),
        .mst_aw_chan_t(axi_wide_in_aw_chan_t),
        .w_chan_t     (axi_wide_in_w_chan_t),
        .slv_b_chan_t (axi_wide_in_b_chan_t),
        .mst_b_chan_t (axi_wide_in_b_chan_t),
        .slv_ar_chan_t(axi_wide_in_ar_chan_t),
        .mst_ar_chan_t(axi_wide_in_ar_chan_t),
        .slv_r_chan_t (axi_wide_in_r_chan_t),
        .mst_r_chan_t (axi_wide_in_r_chan_t),
        .slv_req_t    (axi_wide_in_req_t),
        .slv_resp_t   (axi_wide_in_resp_t),
        .mst_req_t    (axi_wide_in_req_t),
        .mst_resp_t   (axi_wide_in_resp_t),
        .rule_t       (tb_rule_t)
    ) i_in_split (
        .clk_i                (clk),
        .rst_ni               (rst_n),
        .test_i               (1'b0),
        .slv_ports_req_i      (chip_in_req[k:k]),
        .slv_ports_resp_o     (chip_in_rsp[k:k]),
        .mst_ports_req_o      (wide_in_req[2*k+:2]),
        .mst_ports_resp_i     (wide_in_rsp[2*k+:2]),
        .addr_map_i           (cluster_rules(k)),
        .en_default_mst_port_i('0),
        .default_mst_port_i   ('0)
    );
  end

  // Between the chips
  axi_xbar #(
      .Cfg          (ChipXbarCfg),
      .ATOPs        (0),
      .slv_aw_chan_t(axi_wide_mux_aw_chan_t),
      .mst_aw_chan_t(axi_wide_in_aw_chan_t),
      .w_chan_t     (axi_wide_mux_w_chan_t),
      .slv_b_chan_t (axi_wide_mux_b_chan_t),
      .mst_b_chan_t (axi_wide_in_b_chan_t),
      .slv_ar_chan_t(axi_wide_mux_ar_chan_t),
      .mst_ar_chan_t(axi_wide_in_ar_chan_t),
      .slv_r_chan_t (axi_wide_mux_r_chan_t),
      .mst_r_chan_t (axi_wide_in_r_chan_t),
      .slv_req_t    (axi_wide_mux_req_t),
      .slv_resp_t   (axi_wide_mux_resp_t),
      .mst_req_t    (axi_wide_in_req_t),
      .mst_resp_t   (axi_wide_in_resp_t),
      .rule_t       (tb_rule_t)
  ) i_chip_xbar (
      .clk_i                (clk),
      .rst_ni               (rst_n),
      .test_i               (1'b0),
      .slv_ports_req_i      (chip_out_req),
      .slv_ports_resp_o     (chip_out_rsp),
      .mst_ports_req_o      (chip_in_req),
      .mst_ports_resp_i     (chip_in_rsp),
      .addr_map_i           (chip_rules()),
      .en_default_mst_port_i('0),
      .default_mst_port_i   ('0)
  );

  axi_xbar #(
      .Cfg          (NarrowXbarCfg),
      .ATOPs        (0),
      .slv_aw_chan_t(axi_narrow_out_aw_chan_t),
      .mst_aw_chan_t(axi_narrow_in_aw_chan_t),
      .w_chan_t     (axi_narrow_out_w_chan_t),
      .slv_b_chan_t (axi_narrow_out_b_chan_t),
      .mst_b_chan_t (axi_narrow_in_b_chan_t),
      .slv_ar_chan_t(axi_narrow_out_ar_chan_t),
      .mst_ar_chan_t(axi_narrow_in_ar_chan_t),
      .slv_r_chan_t (axi_narrow_out_r_chan_t),
      .mst_r_chan_t (axi_narrow_in_r_chan_t),
      .slv_req_t    (axi_narrow_out_req_t),
      .slv_resp_t   (axi_narrow_out_resp_t),
      .mst_req_t    (axi_narrow_in_req_t),
      .mst_resp_t   (axi_narrow_in_resp_t),
      .rule_t       (tb_rule_t)
  ) i_narrow_xbar (
      .clk_i                (clk),
      .rst_ni               (rst_n),
      .test_i               (1'b0),
      .slv_ports_req_i      (narrow_out_req),
      .slv_ports_resp_o     (narrow_out_rsp),
      .mst_ports_req_o      (narrow_in_req),
      .mst_ports_resp_i     (narrow_in_rsp),
      .addr_map_i           (node_rules()),
      .en_default_mst_port_i('0),
      .default_mst_port_i   ('0)
  );

  //====================================================================
  // Adapters
  //====================================================================
  tb_xdma_inter_cluster_cfg_t [NumNodes-1:0] to_remote_cfg;
  logic                       [NumNodes-1:0] to_remote_cfg_valid;
  tb_xdma_accompany_cfg_t     [NumNodes-1:0] to_remote_acfg;
  tb_xdma_accompany_cfg_t     [NumNodes-1:0] from_remote_acfg;
  logic                       [NumNodes-1:0] from_remote_cfg_ready;
  assign from_remote_cfg_ready = '1;

  logic [NumNodes-1:0] to_remote_cfg_ready;
  logic [NumNodes-1:0] to_remote_data_ready;
  logic [NumNodes-1:0][TbAxiWideDataWidth-1:0] from_remote_cfg;
  logic [NumNodes-1:0] from_remote_cfg_valid;
  logic [NumNodes-1:0][TbAxiWideDataWidth-1:0] from_remote_data;
  logic [NumNodes-1:0] from_remote_data_valid;
  logic [NumNodes-1:0] xdma_finish;
  logic [NumNodes-1:0] xdma_stall_error;

  // Heads (chip 0): the testbench; middles (chip 1): the junctions; tails (chip 2): nothing
  wire [NumNodes-1:0][TbAxiWideDataWidth-1:0] to_remote_data;
  wire [NumNodes-1:0]                         to_remote_data_valid;
  wire [NumNodes-1:0]                         from_remote_data_ready;

  tb_wide_data_t [NumChains-1:0] head_data;
  logic          [NumChains-1:0] head_valid;
  tb_wide_data_t [NumChains-1:0] mid_data;
  logic          [NumChains-1:0] mid_valid;
  logic          [NumChains-1:0] junction_ready;

  for (genvar c = 0; c < NumChains; c++) begin : gen_roles
    // head
    assign to_remote_data[c]               = head_data[c];
    assign to_remote_data_valid[c]         = head_valid[c];
    assign from_remote_data_ready[c]       = 1'b1;
    // middle
    assign to_remote_data[2 + c]           = mid_data[c];
    assign to_remote_data_valid[2 + c]     = mid_valid[c];
    assign from_remote_data_ready[2 + c]   = junction_ready[c];
    // tail: the collection point, never stalls
    assign to_remote_data[4 + c]           = '0;
    assign to_remote_data_valid[4 + c]     = 1'b0;
    assign from_remote_data_ready[4 + c]   = 1'b1;

    stream_fifo #(
        .FALL_THROUGH(1'b0),
        .DEPTH       (JunctionDepth),
        .T           (tb_wide_data_t)
    ) i_junction (
        .clk_i     (clk),
        .rst_ni    (rst_n),
        .flush_i   (1'b0),
        .testmode_i(1'b0),
        .usage_o   (  /* unused */),
        .data_i    (from_remote_data[2 + c]),
        .valid_i   (from_remote_data_valid[2 + c]),
        .ready_o   (junction_ready[c]),
        .data_o    (mid_data[c]),
        .valid_o   (mid_valid[c]),
        .ready_i   (to_remote_data_ready[2 + c])
    );
  end

  for (genvar n = 0; n < NumNodes; n++) begin : gen_adapter
    xdma_axi_adapter_top #(
        .MaxMemSizeKiB        (TbMaxMemSizeKiB),
        .WordlineWidth        (TbWordlineWidth),
        .WideAXIIdWidth       (IdIn),
        .NarrowAXIIdWidth     (IdIn),
        .axi_wide_out_req_t   (axi_wide_out_req_t),
        .axi_wide_out_resp_t  (axi_wide_out_resp_t),
        .axi_wide_in_req_t    (axi_wide_in_req_t),
        .axi_wide_in_resp_t   (axi_wide_in_resp_t),
        .axi_narrow_out_req_t (axi_narrow_out_req_t),
        .axi_narrow_out_resp_t(axi_narrow_out_resp_t),
        .axi_narrow_in_req_t  (axi_narrow_in_req_t),
        .axi_narrow_in_resp_t (axi_narrow_in_resp_t),
        .ClusterBaseAddr      (ClusterBaseAddr),
        .ClusterAddressSpace  (ClusterAddressSpace),
        .MainMemBaseAddr      (MainMemBaseAddr),
        .MainMemEndAddr       (MainMemEndAddr),
        .MMIOSize             (MMIOSize),
        .StallTimeout         (32'd0),
        .RemoteWriteWholeBurst(WholeBurst)
    ) i_dut (
        .clk_i                           (clk),
        .rst_ni                          (rst_n),
        .cluster_base_addr_i             (cluster_base(n)),
        .to_remote_cfg_i                 (to_remote_cfg[n]),
        .to_remote_cfg_valid_i           (to_remote_cfg_valid[n]),
        .to_remote_cfg_ready_o           (to_remote_cfg_ready[n]),
        .to_remote_data_i                (to_remote_data[n]),
        .to_remote_data_valid_i          (to_remote_data_valid[n]),
        .to_remote_data_ready_o          (to_remote_data_ready[n]),
        .to_remote_data_accompany_cfg_i  (to_remote_acfg[n]),
        .from_remote_cfg_o               (from_remote_cfg[n]),
        .from_remote_cfg_valid_o         (from_remote_cfg_valid[n]),
        .from_remote_cfg_ready_i         (from_remote_cfg_ready[n]),
        .from_remote_data_o              (from_remote_data[n]),
        .from_remote_data_valid_o        (from_remote_data_valid[n]),
        .from_remote_data_ready_i        (from_remote_data_ready[n]),
        .from_remote_data_accompany_cfg_i(from_remote_acfg[n]),
        .xdma_finish_o                   (xdma_finish[n]),
        .xdma_stall_error_o              (xdma_stall_error[n]),
        .axi_xdma_wide_out_req_o         (wide_out_req[n]),
        .axi_xdma_wide_out_resp_i        (wide_out_rsp[n]),
        .axi_xdma_wide_in_req_i          (wide_in_req[n]),
        .axi_xdma_wide_in_resp_o         (wide_in_rsp[n]),
        .axi_xdma_narrow_out_req_o       (narrow_out_req[n]),
        .axi_xdma_narrow_out_resp_i      (narrow_out_rsp[n]),
        .axi_xdma_narrow_in_req_i        (narrow_in_req[n]),
        .axi_xdma_narrow_in_resp_o       (narrow_in_rsp[n])
    );
  end

  //====================================================================
  // Monitors
  //====================================================================
  tb_wide_data_t tail_rx_q[NumChains][$];
  int tail_rx_cnt[NumChains];
  int head_tx_cnt[NumChains];
  int mid_tx_cnt[NumChains];
  int finish_cnt[NumNodes];
  int mid_credit_cnt[NumChains];
  // per node, on its wide outbound port: AWs accepted and W beats sent
  int aw_cnt[NumNodes];
  int w_cnt[NumNodes];
  longint unsigned cycle, last_move;
  int errors = 0;

  always @(posedge clk) begin
    if (!rst_n) begin
      cycle     <= 0;
      last_move <= 0;
    end else begin
      cycle <= cycle + 1;
      for (int c = 0; c < NumChains; c++) begin
        if (from_remote_data_valid[4 + c] && from_remote_data_ready[4 + c]) begin
          tail_rx_q[c].push_back(from_remote_data[4 + c]);
          tail_rx_cnt[c]++;
          last_move <= cycle;
        end
        if (to_remote_data_valid[c] && to_remote_data_ready[c]) begin
          head_tx_cnt[c]++;
          last_move <= cycle;
        end
        if (to_remote_data_valid[2 + c] && to_remote_data_ready[2 + c]) begin
          mid_tx_cnt[c]++;
          last_move <= cycle;
        end
      end
      for (int n = 0; n < NumNodes; n++) begin
        if (xdma_finish[n]) finish_cnt[n]++;
        if (wide_out_req[n].aw_valid && wide_out_rsp[n].aw_ready) aw_cnt[n]++;
        if (wide_out_req[n].w_valid && wide_out_rsp[n].w_ready) w_cnt[n]++;
      end
      if (gen_adapter[2].i_dut.xdma_write_finish) mid_credit_cnt[0]++;
      if (gen_adapter[3].i_dut.xdma_write_finish) mid_credit_cnt[1]++;
    end
  end

  initial begin
    #SimTimeout;
    $error("[TB] global timeout");
    $finish;
  end

  //====================================================================
  // Stimulus
  //====================================================================
  logic [15:0] cfg_seed = 16'hA5A5;

  task automatic check_int(input int actual, input int expected, input string what);
    if (actual != expected) begin
      errors++;
      $error("%s: expected %0d, got %0d", what, expected, actual);
    end
  endtask

  task automatic clear_counters();
    for (int c = 0; c < NumChains; c++) begin
      tail_rx_q[c].delete();
      tail_rx_cnt[c]    = 0;
      head_tx_cnt[c]    = 0;
      mid_tx_cnt[c]     = 0;
      mid_credit_cnt[c] = 0;
    end
    for (int n = 0; n < NumNodes; n++) begin
      finish_cnt[n] = 0;
      aw_cnt[n]     = 0;
      w_cnt[n]      = 0;
    end
  endtask

  // One 512-bit cfg frame from `src` to `dst`; returns what was sent, to compare at `dst`
  task automatic send_cfg(input int unsigned src, input int unsigned dst, input tb_id_t id,
                          output tb_xdma_inter_cluster_cfg_t cfg);
    logic [15:0] seed;
    cfg_seed = cfg_seed + 16'h1234;
    seed = cfg_seed;
    cfg                                     = '0;
    cfg.dma_type                            = 1'b1;
    cfg.frame_length                        = 4'd1;
    cfg.dma_id                              = id;
    cfg.reader_addr                         = cluster_base(src);
    cfg.writer_addr                         = cluster_base(dst);
    cfg.first_frame_remaining_payload[15:0] = seed;
    cfg.first_frame_remaining_payload[TbFirstFramePayloadWidth-1-:16] = ~seed;
    to_remote_cfg[src]       <= cfg;
    to_remote_cfg_valid[src] <= 1'b1;
    @(negedge clk);
    while (!to_remote_cfg_ready[src]) @(negedge clk);
    @(posedge clk);
    to_remote_cfg_valid[src] <= 1'b0;
    to_remote_cfg[src]       <= '0;
  endtask

  task automatic expect_cfg(input int unsigned dst, input tb_xdma_inter_cluster_cfg_t cfg);
    @(negedge clk);
    while (!from_remote_cfg_valid[dst]) @(negedge clk);
    if (from_remote_cfg[dst] !== tb_wide_data_t'(cfg)) begin
      errors++;
      $error("node %0d cfg frame mismatch", dst);
    end
    @(posedge clk);
  endtask

  // chain c's beat i: the chain in the payload, so a beat delivered to the other chain fails
  function automatic tb_wide_data_t beat(input int unsigned c, input int unsigned i);
    tb_wide_data_t d;
    d          = '0;
    d[63:0]    = 64'hC0FF_EE00_0000_0000 + (c << 24) + i;
    d[255:192] = 64'h5A5A_5A5A_0000_0000 + (c << 24) + i;
    d[511:448] = 64'hFEED_FACE_0000_0000 + (c << 24) + i;
    return d;
  endfunction

  task automatic send_payload(input int unsigned c, input int unsigned len);
    for (int unsigned i = 0; i < len; i++) begin
      head_data[c]  <= beat(c, i);
      head_valid[c] <= 1'b1;
      @(negedge clk);
      while (!to_remote_data_ready[c]) @(negedge clk);
      @(posedge clk);
    end
    head_valid[c] <= 1'b0;
  endtask

  // The cfg walk of chain c, tail -> middle -> head (a ChainGather is owned by its tail)
  task automatic configure(input int unsigned c, input tb_id_t id);
    tb_xdma_inter_cluster_cfg_t cfg;
    int unsigned h, m, t;
    h = node_of(c, 0);
    m = node_of(c, 1);
    t = node_of(c, 2);
    send_cfg(t, m, id, cfg);
    expect_cfg(m, cfg);
    send_cfg(m, h, id, cfg);
    expect_cfg(h, cfg);
  endtask

  // Open chain c's windows: tail, middle (both sides), head
  task automatic open_chain(input int unsigned c, input tb_id_t id, input int unsigned len);
    int unsigned h, m, t;
    h = node_of(c, 0);
    m = node_of(c, 1);
    t = node_of(c, 2);
    from_remote_acfg[t] <= tb_xdma_accompany_cfg_t'{dma_id: id, dma_type: 1'b1,
        src_addr: cluster_base(m), dst_addr: cluster_base(t), dma_length: tb_len_t'(len),
        ready_to_transfer: 1'b1, is_first_cw: 1'b0, is_last_cw: 1'b1, is_initiator: 1'b1};
    from_remote_acfg[m] <= tb_xdma_accompany_cfg_t'{dma_id: id, dma_type: 1'b1,
        src_addr: cluster_base(h), dst_addr: cluster_base(m), dma_length: tb_len_t'(len),
        ready_to_transfer: 1'b1, is_first_cw: 1'b0, is_last_cw: 1'b0, is_initiator: 1'b0};
    to_remote_acfg[m] <= tb_xdma_accompany_cfg_t'{dma_id: id, dma_type: 1'b1,
        src_addr: cluster_base(m), dst_addr: cluster_base(t), dma_length: tb_len_t'(len),
        ready_to_transfer: 1'b1, is_first_cw: 1'b0, is_last_cw: 1'b0, is_initiator: 1'b0};
    to_remote_acfg[h] <= tb_xdma_accompany_cfg_t'{dma_id: id, dma_type: 1'b1,
        src_addr: cluster_base(h), dst_addr: cluster_base(m), dma_length: tb_len_t'(len),
        ready_to_transfer: 1'b1, is_first_cw: 1'b1, is_last_cw: 1'b0, is_initiator: 1'b0};
    @(posedge clk);
  endtask

  task automatic close_chain(input int unsigned c);
    from_remote_acfg[node_of(c, 2)].ready_to_transfer <= 1'b0;
    to_remote_acfg[node_of(c, 1)].ready_to_transfer   <= 1'b0;
    from_remote_acfg[node_of(c, 1)].ready_to_transfer <= 1'b0;
    to_remote_acfg[node_of(c, 0)].ready_to_transfer   <= 1'b0;
  endtask

  // One chain, end to end; `skew` cycles before its payload starts
  task automatic run_one(input int unsigned c, input tb_id_t id, input int unsigned len,
                         input int unsigned skew);
    configure(c, id);
    repeat (5) @(posedge clk);
    open_chain(c, id, len);
    repeat (skew) @(posedge clk);
    send_payload(c, len);
    wait (tail_rx_cnt[c] == len);
    @(posedge clk);
    close_chain(c);
    wait (finish_cnt[node_of(c, 2)] == 1);
  endtask

  // Both chains at once. Returns 1 if they completed, 0 if nothing moved for StallCycles.
  task automatic run_both(input int unsigned len, input int unsigned skew_b, output bit done);
    done = 1'b0;
    fork
      begin
        fork
          run_one(0, 4'd3, len, 0);
          run_one(1, 4'd5, len, skew_b);
        join
        done = 1'b1;
      end
      begin
        @(posedge clk);
        wait (cycle - last_move > StallCycles);
      end
    join_any
    disable fork;
  endtask

  task automatic report_counts(input string what);
    for (int c = 0; c < NumChains; c++) begin
      $display("[TB] %s chain %s: head sent %0d, middle forwarded %0d, tail received %0d of %0d",
               what, c ? "B" : "A", head_tx_cnt[c], mid_tx_cnt[c], tail_rx_cnt[c], PayloadBeats);
    end
    // A burst whose AW has left but whose W beats have not all gone holds its port's write order
    for (int unsigned n = 0; n < 4; n++) begin
      $display("[TB] %s node %0d (chip %0d %s, chain %s): wide AWs accepted %0d, W beats sent %0d",
               what, n, n / 2, (n < 2) ? "head" : "middle", (n % 2) ? "B" : "A", aw_cnt[n],
               w_cnt[n]);
    end
  endtask

  task automatic check_run();
    repeat (20) @(posedge clk);
    for (int c = 0; c < NumChains; c++) begin
      check_int(tail_rx_cnt[c], PayloadBeats, $sformatf("chain %0d beats at the tail", c));
      check_int(mid_tx_cnt[c], PayloadBeats, $sformatf("chain %0d beats forwarded", c));
      check_int(mid_credit_cnt[c], 1, $sformatf("chain %0d grant credits of the middle", c));
      for (int unsigned i = 0; i < PayloadBeats && i < tail_rx_q[c].size(); i++) begin
        if (tail_rx_q[c][i] !== beat(c, i)) begin
          errors++;
          $error("chain %0d beat %0d: expected %h, got %h", c, i, beat(c, i), tail_rx_q[c][i]);
          break;
        end
      end
    end
    for (int unsigned n = 0; n < NumNodes; n++) begin
      check_int(finish_cnt[n], (n >= 4) ? 1 : 0, $sformatf("node %0d completions", n));
    end
    if (|xdma_stall_error) begin
      errors++;
      $error("a stall watchdog latched: %b", xdma_stall_error);
    end
  endtask

  //====================================================================
  // Test
  //====================================================================
  initial begin
    bit done;
    to_remote_cfg       = '0;
    to_remote_cfg_valid = '0;
    to_remote_acfg      = '0;
    from_remote_acfg    = '0;
    head_data           = '0;
    head_valid          = '0;
    clear_counters();

    @(posedge rst_n);
    repeat (10) @(posedge clk);

    if (ExpectDeadlock) begin
      run_both(PayloadBeats, 0, done);
      report_counts(done ? "completed" : "deadlocked");
      if (done) begin
        errors++;
        $error("both chains completed without the whole-burst writes: this testbench no longer reaches the deadlock");
      end else begin
        $display("[TB] deadlock reproduced as expected (no beat moved for %0d cycles)",
                 StallCycles);
      end
    end else begin
      // several offsets between the two chains' payloads, each a fresh pair of transfers
      static int unsigned skews[4] = '{0, 1, 17, 70};
      foreach (skews[s]) begin
        $display("[TB] both chains, chain B %0d cycles behind", skews[s]);
        run_both(PayloadBeats, skews[s], done);
        report_counts(done ? "completed" : "deadlocked");
        if (!done) begin
          errors++;
          $error("the chains deadlocked with chain B %0d cycles behind", skews[s]);
          break;
        end
        check_run();
        to_remote_acfg   <= '0;
        from_remote_acfg <= '0;
        repeat (20) @(posedge clk);
        clear_counters();
      end
    end

    if (errors == 0) $display("[TB] concurrent chains (whole-burst %0d) PASSED", WholeBurst);
    else $display("[TB] concurrent chains (whole-burst %0d) FAILED with %0d error(s)", WholeBurst,
                  errors);
    $finish;
  end

endmodule
