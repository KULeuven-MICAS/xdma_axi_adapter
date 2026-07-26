// Authors:
// - Fanchen Kong <fanchen.kong@kuleuven.be>
//
// Directed test for the `SpuriousFinishGuard` backstop in `xdma_finish_manager`.
//
// Two identical finish managers get identical stimulus; the only difference is the guard
// parameter. The stimulus reproduces the ChainGather middle-node hazard: the node is
// taking delivery of a chained write (from-remote accompany cfg says "middle": dma_type=1,
// ready_to_transfer=1, neither first nor last) while its *own* reader is running, so the
// to-remote accompany cfg momentarily looks exactly like a chain head (dma_type=1,
// ready_to_transfer=1, is_first_cw=1, is_last_cw=0). That is the shape FSM2 mistakes for
// "I am the head".
//
//   Phase 1 (the hazard)  guard OFF -> FSM2 latches and later raises a spurious
//                                      `xdma_finish_o` at this node's core
//                         guard ON  -> FSM2 stays idle; the middle-hop finish forwarding
//                                      (FSM3 -> `to_remote_finish_valid_o`) is untouched
//   Phase 2 (regression)  a genuine chain head, receiving nothing, must still report
//                         `xdma_finish_o` with the guard ON -- the guard must not make
//                         the head path over-restrictive.

`timescale 1ns / 1ps
module tb_xdma_finish_manager_guard ();

  //--------------------------------------
  // Protocol typedefs (mirror xdma_axi_adapter_top's body)
  //--------------------------------------
  localparam int unsigned TbMaxMemSizeKiB      = 32'd4096;
  localparam int unsigned TbWordlineWidth      = 32'd64;
  localparam int unsigned TbAxiAddrWidth       = 32'd48;
  localparam int unsigned TbAxiNarrowDataWidth = 32'd64;
  localparam int unsigned TbXDMAIdWidth        = 32'd4;
  localparam int unsigned TbDMALengthWidth     =
      $clog2(TbMaxMemSizeKiB) + 10 - $clog2(TbWordlineWidth / 8);

  typedef logic [       TbXDMAIdWidth-1:0]                                    tb_id_t;
  typedef logic [      TbAxiAddrWidth-1:0]                                    tb_addr_t;
  typedef logic [TbAxiNarrowDataWidth-1:0]                                    tb_narrow_data_t;
  typedef logic [    TbDMALengthWidth-1:0]                                    tb_len_t;
  typedef logic [TbAxiNarrowDataWidth-TbXDMAIdWidth-TbAxiAddrWidth-1:0]       tb_finish_reserved_t;

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
    tb_id_t   dma_id;
    logic     dma_type;
    tb_addr_t remote_addr;
    tb_len_t  dma_length;
    logic     ready_to_transfer;
  } tb_xdma_req_desc_t;

  typedef struct packed {
    tb_id_t              dma_id;
    tb_addr_t            from;
    tb_finish_reserved_t reserved;
  } tb_xdma_to_remote_finish_t;

  localparam time      TbCyclTime = 10ns;
  localparam tb_id_t   TbDmaId    = 4'd9;
  localparam tb_addr_t TbPrevAddr = 48'h1000_0000;

  //--------------------------------------
  // DUT plumbing
  //--------------------------------------
  logic clk;
  logic rst_n;
  int   errors = 0;

  tb_xdma_accompany_cfg_t to_remote_cfg;
  tb_xdma_accompany_cfg_t from_remote_cfg;
  tb_narrow_data_t        from_remote_finish;
  logic                   from_remote_finish_valid;
  logic                   to_remote_finish_ready;

  // [0] = guard disabled (the module default), [1] = guard enabled
  logic [1:0] xdma_finish;
  logic [1:0] xdma_write_finish;
  logic [1:0] from_remote_finish_ready;
  logic [1:0] to_remote_finish_valid;
  logic [1:0] stall_error;
  tb_addr_t [1:0] remote_addr;
  tb_id_t [1:0] from_remote_dma_id;

  for (genvar i = 0; i < 2; i++) begin : gen_dut
    xdma_finish_manager #(
        .id_t                                 (tb_id_t),
        .len_t                                (tb_len_t),
        .addr_t                               (tb_addr_t),
        .data_t                               (tb_narrow_data_t),
        .xdma_to_remote_data_accompany_cfg_t  (tb_xdma_accompany_cfg_t),
        .xdma_from_remote_data_accompany_cfg_t(tb_xdma_accompany_cfg_t),
        .xdma_req_desc_t                      (tb_xdma_req_desc_t),
        .xdma_to_remote_finish_t              (tb_xdma_to_remote_finish_t),
        .SpuriousFinishGuard                  (i == 1)
    ) i_dut (
        .clk_i                           (clk),
        .rst_ni                          (rst_n),
        .xdma_finish_o                   (xdma_finish[i]),
        .xdma_write_finish_o             (xdma_write_finish[i]),
        .to_remote_data_accompany_cfg_i  (to_remote_cfg),
        .from_remote_data_accompany_cfg_i(from_remote_cfg),
        .from_remote_finish_i            (from_remote_finish),
        .from_remote_finish_valid_i      (from_remote_finish_valid),
        .from_remote_finish_ready_o      (from_remote_finish_ready[i]),
        .remote_addr_o                   (remote_addr[i]),
        .from_remote_dma_id_o            (from_remote_dma_id[i]),
        .to_remote_finish_valid_o        (to_remote_finish_valid[i]),
        .to_remote_finish_ready_i        (to_remote_finish_ready),
        .stall_error_o                   (stall_error[i])
    );
  end

  initial begin
    clk = 1'b0;
    forever #(TbCyclTime / 2) clk = ~clk;
  end

  //--------------------------------------
  // Pulse counters
  //--------------------------------------
  int local_finish_cnt[2];
  int fwd_finish_cnt  [2];
  always @(posedge clk) begin
    if (rst_n) begin
      for (int i = 0; i < 2; i++) begin
        if (xdma_finish[i]) local_finish_cnt[i]++;
        if (to_remote_finish_valid[i] && to_remote_finish_ready) fwd_finish_cnt[i]++;
      end
    end
  end

  task automatic check(input int actual, input int expected, input string what);
    if (actual != expected) begin
      errors++;
      $error("%s: expected %0d, got %0d", what, expected, actual);
    end
  endtask

  // `#1ns` keeps the counter reads/clears out of the same delta as the counting
  // `always @(posedge clk)` block.
  task automatic clear_counters();
    #1ns;
    for (int i = 0; i < 2; i++) begin
      local_finish_cnt[i] = 0;
      fwd_finish_cnt[i]   = 0;
    end
  endtask

  // One-cycle finish delivery. Both DUTs assert `from_remote_finish_ready_o` in the
  // states under test, so a single beat is consumed by both.
  task automatic deliver_finish(input tb_id_t id);
    tb_xdma_to_remote_finish_t f;
    f = '0;
    f.dma_id = id;
    f.from = TbPrevAddr;
    from_remote_finish       <= f;
    from_remote_finish_valid <= 1'b1;
    @(posedge clk);
    from_remote_finish_valid <= 1'b0;
    @(posedge clk);
  endtask

  initial begin
    rst_n                    = 1'b0;
    to_remote_cfg            = '0;
    from_remote_cfg          = '0;
    from_remote_finish       = '0;
    from_remote_finish_valid = 1'b0;
    to_remote_finish_ready   = 1'b1;
    clear_counters();

    repeat (5) @(posedge clk);
    rst_n <= 1'b1;
    repeat (2) @(posedge clk);

    //====================================================================
    // Phase 1 -- the ChainGather middle-node hazard
    //====================================================================
    $display("[TB] Phase 1: gather middle node, reader busy while receiving a chained write");

    // This node is taking delivery of a chained write: neither first nor last.
    from_remote_cfg.dma_id            <= TbDmaId;
    from_remote_cfg.dma_type          <= 1'b1;
    from_remote_cfg.src_addr          <= TbPrevAddr;
    from_remote_cfg.ready_to_transfer <= 1'b1;
    from_remote_cfg.is_first_cw       <= 1'b0;
    from_remote_cfg.is_last_cw        <= 1'b0;
    repeat (2) @(posedge clk);

    // Its own reader starts, and the to-remote accompany cfg momentarily reads as a head.
    to_remote_cfg.dma_id            <= TbDmaId;
    to_remote_cfg.dma_type          <= 1'b1;
    to_remote_cfg.ready_to_transfer <= 1'b1;
    to_remote_cfg.is_first_cw       <= 1'b1;
    to_remote_cfg.is_last_cw        <= 1'b0;
    repeat (3) @(posedge clk);

    // The tail's finish arrives and travels back up the chain.
    deliver_finish(TbDmaId);
    repeat (3) @(posedge clk);
    #1ns;

    check(local_finish_cnt[0], 1, "guard OFF: spurious local finish at the middle node");
    check(local_finish_cnt[1], 0, "guard ON: local finish suppressed at the middle node");
    // The middle-hop forwarding must be identical either way -- the guard only touches FSM2.
    check(fwd_finish_cnt[0], 1, "guard OFF: finish forwarded to the previous hop");
    check(fwd_finish_cnt[1], 1, "guard ON: finish forwarded to the previous hop");

    // Tear the transfer down.
    to_remote_cfg   <= '0;
    from_remote_cfg <= '0;
    repeat (4) @(posedge clk);
    clear_counters();

    //====================================================================
    // Phase 2 -- a genuine chain head must still report, guard or not
    //====================================================================
    $display("[TB] Phase 2: genuine chain head, receiving nothing");

    to_remote_cfg.dma_id            <= TbDmaId;
    to_remote_cfg.dma_type          <= 1'b1;
    to_remote_cfg.ready_to_transfer <= 1'b1;
    to_remote_cfg.is_first_cw       <= 1'b1;
    to_remote_cfg.is_last_cw        <= 1'b0;
    repeat (3) @(posedge clk);

    deliver_finish(TbDmaId);
    repeat (3) @(posedge clk);
    #1ns;

    check(local_finish_cnt[0], 1, "guard OFF: head reports finish");
    check(local_finish_cnt[1], 1, "guard ON: head still reports finish");

    to_remote_cfg <= '0;
    repeat (5) @(posedge clk);

    if (errors == 0) $display("[TB] tb_xdma_finish_manager_guard PASSED");
    else $display("[TB] tb_xdma_finish_manager_guard FAILED with %0d error(s)", errors);
    $finish;
  end

endmodule
