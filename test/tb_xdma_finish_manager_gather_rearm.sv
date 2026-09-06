// Authors:
// - Fanchen Kong <fanchen.kong@kuleuven.be>
//
// Directed test for FSM2 (`first_write`) of `xdma_finish_manager` under the ChainGather
// orderings that actually occur in silicon, and for the node being REUSABLE afterwards.
//
// `tb_xdma_finish_manager_guard` covers the same hazard with the *receive* window opened
// BEFORE the head-shaped to-remote pulse. That ordering is the one `SpuriousFinishGuard`
// catches, and it is not the one the hardware produces: at a gather node the local reader
// supplies the junction's own operand and starts FIRST, so the head-shaped pulse leads the
// receive window. This testbench pins down the three consequences.
//
//   Phase 1  reader-first ordering. `to_remote` momentarily reads as a chain head while
//            `from_remote` is still idle, so `SpuriousFinishGuard`'s predicate
//            (`~from_remote.ready_to_transfer`) is TRUE and the guard is inert. FSM2 latches
//            either way and releases a grant credit the node never reserved.
//
//   Phase 2  the same node, a second task. This is the part that turns a spurious latch
//            into a dead node: FSM2 arms with whatever `dma_id` the to-remote port happens
//            to be showing, and `WriteFirstBusy` has NO exit other than an id-matched
//            finish. Arm it with a stale id -- which is what the sender datapath presents
//            between tasks, since its cfg queue keeps driving the popped frame -- and FSM2
//            never returns to `WriteFirstIdle` for the rest of the run.
//
//   Phase 3  `from_remote_finish_ready_o` was the bare OR of the two busy states, so ANY
//            beat arriving while either FSM waited was acknowledged -- id or no id -- and
//            destroyed. A beat belonging to another task, or to the other FSM, therefore
//            vanished and left whoever was waiting for it waiting forever.
//
//   Phase 4  regression: a genuine chain head -- the case FSM2 exists for -- must still
//            latch, report when it owns the task, and release its credit.
//
// What a node must satisfy to be the head of a chain, and what every check below rests on:
// a chain's head SOURCES the payload. It never takes delivery of that chain's data. So a
// node presenting a head-shaped to-remote cfg for task T while also receiving chained-write
// data for task T is not the head of T, whichever of the two arrives first.

`timescale 1ns / 1ps
module tb_xdma_finish_manager_gather_rearm ();

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

  typedef logic [                                TbXDMAIdWidth-1:0] tb_id_t;
  typedef logic [                               TbAxiAddrWidth-1:0] tb_addr_t;
  typedef logic [                         TbAxiNarrowDataWidth-1:0] tb_narrow_data_t;
  typedef logic [                             TbDMALengthWidth-1:0] tb_len_t;
  typedef logic [TbAxiNarrowDataWidth-TbXDMAIdWidth-TbAxiAddrWidth-1:0] tb_finish_reserved_t;

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
  localparam tb_addr_t TbPrevAddr = 48'h1000_0000;
  localparam tb_addr_t TbNextAddr = 48'h2000_0000;

  // Task ids. The point of Phase 2 is that they DIFFER: the stale frame the sender keeps
  // driving between tasks carries the previous id, so a latch taken on it can never be
  // satisfied by the new task's finish.
  localparam tb_id_t TbIdA = 4'd1;
  localparam tb_id_t TbIdB = 4'd2;
  localparam tb_id_t TbIdC = 4'd3;

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

  logic     xdma_finish;
  logic     xdma_write_finish;
  logic     from_remote_finish_ready;
  logic     to_remote_finish_valid;
  logic     stall_error;
  tb_addr_t remote_addr;
  tb_id_t   from_remote_dma_id;

  xdma_finish_manager #(
      .id_t                                 (tb_id_t),
      .len_t                                (tb_len_t),
      .addr_t                               (tb_addr_t),
      .data_t                               (tb_narrow_data_t),
      .xdma_to_remote_data_accompany_cfg_t  (tb_xdma_accompany_cfg_t),
      .xdma_from_remote_data_accompany_cfg_t(tb_xdma_accompany_cfg_t),
      .xdma_req_desc_t                      (tb_xdma_req_desc_t),
      .xdma_to_remote_finish_t              (tb_xdma_to_remote_finish_t)
  ) i_dut (
      .clk_i                           (clk),
      .rst_ni                          (rst_n),
      .xdma_finish_o                   (xdma_finish),
      .xdma_write_finish_o             (xdma_write_finish),
      .to_remote_data_accompany_cfg_i  (to_remote_cfg),
      .from_remote_data_accompany_cfg_i(from_remote_cfg),
      .from_remote_finish_i            (from_remote_finish),
      .from_remote_finish_valid_i      (from_remote_finish_valid),
      .from_remote_finish_ready_o      (from_remote_finish_ready),
      .remote_addr_o                   (remote_addr),
      .from_remote_dma_id_o            (from_remote_dma_id),
      .to_remote_finish_valid_o        (to_remote_finish_valid),
      .to_remote_finish_ready_i        (to_remote_finish_ready),
      .stall_error_o                   (stall_error)
  );

  initial begin
    clk = 1'b0;
    forever #(TbCyclTime / 2) clk = ~clk;
  end

  initial begin
    #500us;
    $error("[TB] global timeout");
    $finish;
  end

  //--------------------------------------
  // Monitors
  //--------------------------------------
  int local_finish_cnt;
  int fwd_finish_cnt;
  int credit_cnt;
  // A finish beat consumed by the DUT that neither FSM was waiting for: the handshake
  // completes, the beat is gone, and whichever FSM it was meant for waits forever.
  int dropped_finish_cnt;

  tb_xdma_to_remote_finish_t finish_beat;
  assign finish_beat = from_remote_finish;

  wire finish_handshake = from_remote_finish_valid && from_remote_finish_ready;
  wire tb_id_t finish_beat_id = finish_beat.dma_id;

  always @(posedge clk) begin
    if (rst_n) begin
      if (xdma_finish) local_finish_cnt++;
      if (to_remote_finish_valid && to_remote_finish_ready) fwd_finish_cnt++;
      if (xdma_write_finish) credit_cnt++;
      if (finish_handshake
          && !(i_dut.last_write_current_state == i_dut.WriteMiddleBusy
               && finish_beat_id == i_dut.from_remote_dma_id_q)
          && !(i_dut.first_write_current_state == i_dut.WriteFirstBusy
               && finish_beat_id == i_dut.to_remote_dma_id_q)) begin
        dropped_finish_cnt++;
      end
    end
  end

  task automatic check(input int actual, input int expected, input string what);
    if (actual != expected) begin
      errors++;
      $error("%s: expected %0d, got %0d", what, expected, actual);
    end
  endtask

  task automatic check_fsm2_idle(input string what);
    if (i_dut.first_write_current_state !== i_dut.WriteFirstIdle) begin
      errors++;
      $error("%s: FSM2 is parked in %0s, so this node can never head a chain again", what,
             i_dut.first_write_current_state.name());
    end
  endtask

  task automatic clear_counters();
    #1ns;
    local_finish_cnt   = 0;
    fwd_finish_cnt     = 0;
    credit_cnt         = 0;
    dropped_finish_cnt = 0;
  endtask

  task automatic deliver_finish(input tb_id_t id);
    tb_xdma_to_remote_finish_t f;
    f = '0;
    f.dma_id = id;
    f.from = TbPrevAddr;
    from_remote_finish       <= f;
    from_remote_finish_valid <= 1'b1;
    @(posedge clk);
    // Single-beat delivery, exactly like the narrow req manager: the beat is offered for
    // one cycle and is gone whether or not anyone was waiting for it.
    from_remote_finish_valid <= 1'b0;
    @(posedge clk);
  endtask

  // The to-remote port as a gather node's local reader presents it: a head-shaped frame,
  // because a locally-originated reader is stamped HEAD and the chain tag makes it a WRITE.
  task automatic drive_head_shaped(input tb_id_t id, input logic initiator);
    to_remote_cfg.dma_id            <= id;
    to_remote_cfg.dma_type          <= 1'b1;
    to_remote_cfg.src_addr          <= TbNextAddr;
    to_remote_cfg.dst_addr          <= TbNextAddr;
    to_remote_cfg.ready_to_transfer <= 1'b1;
    to_remote_cfg.is_first_cw       <= 1'b1;
    to_remote_cfg.is_last_cw        <= 1'b0;
    to_remote_cfg.is_initiator      <= initiator;
  endtask

  // The same port once the gather FSM has latched: the node forwards the fold as a MIDDLE.
  task automatic drive_middle_shaped(input tb_id_t id);
    to_remote_cfg.dma_id            <= id;
    to_remote_cfg.dma_type          <= 1'b1;
    to_remote_cfg.src_addr          <= TbNextAddr;
    to_remote_cfg.dst_addr          <= TbNextAddr;
    to_remote_cfg.ready_to_transfer <= 1'b1;
    to_remote_cfg.is_first_cw       <= 1'b0;
    to_remote_cfg.is_last_cw        <= 1'b0;
    to_remote_cfg.is_initiator      <= 1'b0;
  endtask

  // This node takes delivery of the chain's payload: neither first nor last.
  task automatic open_receive_window(input tb_id_t id);
    from_remote_cfg.dma_id            <= id;
    from_remote_cfg.dma_type          <= 1'b1;
    from_remote_cfg.src_addr          <= TbPrevAddr;
    from_remote_cfg.dst_addr          <= TbNextAddr;
    from_remote_cfg.ready_to_transfer <= 1'b1;
    from_remote_cfg.is_first_cw       <= 1'b0;
    from_remote_cfg.is_last_cw        <= 1'b0;
    from_remote_cfg.is_initiator      <= 1'b0;
  endtask

  // One complete pass of a gather MIDDLE hop, in hardware order: reader first, then the
  // gather FSM latches, then the receive window, then the finish cascading backwards.
  task automatic gather_middle_pass(input tb_id_t reader_id, input tb_id_t chain_id);
    // 1. The local reader starts first and momentarily reads as a chain head.
    drive_head_shaped(reader_id, 1'b0);
    repeat (3) @(posedge clk);
    // 2. The gather FSM latches; from here the node forwards the fold as a MIDDLE.
    drive_middle_shaped(chain_id);
    repeat (2) @(posedge clk);
    // 3. The payload arrives and is forwarded.
    open_receive_window(chain_id);
    repeat (6) @(posedge clk);
    // 4. Both windows close once this hop's data has moved. The cascade cannot start
    //    before this: the tail only emits its finish after ITS window closed, and this
    //    hop's window closed earlier still.
    to_remote_cfg.ready_to_transfer   <= 1'b0;
    from_remote_cfg.ready_to_transfer <= 1'b0;
    repeat (2) @(posedge clk);
    // 5. The next hop's finish arrives and must be forwarded to the previous hop.
    deliver_finish(chain_id);
    repeat (4) @(posedge clk);
    to_remote_cfg   <= '0;
    from_remote_cfg <= '0;
    repeat (4) @(posedge clk);
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
    // Phase 1 -- reader-first ordering: the guard's predicate is inert here
    //====================================================================
    $display("[TB] Phase 1: gather middle, local reader starts BEFORE the receive window");
    gather_middle_pass(TbIdA, TbIdA);
    #1ns;

    check(fwd_finish_cnt, 1, "P1 finish forwarded to the previous hop");
    check(local_finish_cnt, 0, "P1 a middle hop never reports to its core");
    // One task, one reserved grant, one release. FSM2 latching off the reader transient
    // makes it two, and the second pop is against a credit nothing reserved.
    check(credit_cnt, 1, "P1 grant credits released (one task = one credit)");
    check(dropped_finish_cnt, 0, "P1 finish beats acked but unused");
    check_fsm2_idle("P1");
    clear_counters();

    //====================================================================
    // Phase 2 -- second task through the same node, arming id is stale
    //====================================================================
    // Between tasks the sender datapath keeps driving its popped cfg frame, so the reader
    // transient for task B carries task A's id. FSM2 latches on it and then waits for a
    // finish tagged A that will never come -- `WriteFirstBusy` has no other exit.
    $display("[TB] Phase 2: second task, reader transient carries the PREVIOUS task's id");
    gather_middle_pass(TbIdA, TbIdB);
    #1ns;

    check(fwd_finish_cnt, 1, "P2 finish forwarded to the previous hop");
    check(local_finish_cnt, 0, "P2 a middle hop never reports to its core");
    check(credit_cnt, 1, "P2 grant credits released");
    check_fsm2_idle("P2");
    clear_counters();

    //====================================================================
    // Phase 3 -- a beat belonging to another task must not be consumed
    //====================================================================
    // With 4-bit task ids and several chains alive across the array, a finish beat for a
    // task this node is not waiting on will arrive while FSM3 waits on its own. Acking it
    // costs the beat, and the node that WAS waiting for it never retires.
    $display("[TB] Phase 3: a finish beat for another task must not be acked and destroyed");
    drive_head_shaped(TbIdC, 1'b0);
    repeat (3) @(posedge clk);
    drive_middle_shaped(TbIdC);
    repeat (2) @(posedge clk);
    open_receive_window(TbIdC);
    repeat (4) @(posedge clk);

    // FSM3 is now waiting for task C. A beat for task A arrives.
    deliver_finish(TbIdA);
    repeat (2) @(posedge clk);
    #1ns;
    check(dropped_finish_cnt, 0, "P3 stray beat acked while nobody was waiting for it");
    check(fwd_finish_cnt, 0, "P3 stray beat must not retire the chain");

    // The chain's own finish then arrives, and the chain retires normally.
    to_remote_cfg.ready_to_transfer   <= 1'b0;
    from_remote_cfg.ready_to_transfer <= 1'b0;
    repeat (2) @(posedge clk);
    deliver_finish(TbIdC);
    repeat (4) @(posedge clk);
    #1ns;
    check(fwd_finish_cnt, 1, "P3 chain retires on its own finish");
    check(credit_cnt, 1, "P3 grant credits released");

    to_remote_cfg   <= '0;
    from_remote_cfg <= '0;
    repeat (4) @(posedge clk);
    check_fsm2_idle("P3");
    clear_counters();

    //====================================================================
    // Phase 4 -- regression: a genuine chain head still works
    //====================================================================
    // Nothing above may narrow the case FSM2 exists for. A real head sources the payload
    // and takes delivery of nothing, so no guard here can see a receive window.
    $display("[TB] Phase 4: genuine chain head (ChainWrite initiator)");
    drive_head_shaped(TbIdA, 1'b1);
    repeat (4) @(posedge clk);
    to_remote_cfg.ready_to_transfer <= 1'b0;  // its local reader is done
    repeat (2) @(posedge clk);
    deliver_finish(TbIdA);
    repeat (4) @(posedge clk);
    #1ns;

    check(local_finish_cnt, 1, "P4 head that owns the task reports exactly once");
    check(credit_cnt, 1, "P4 head releases exactly one grant credit");
    check_fsm2_idle("P4");

    to_remote_cfg <= '0;
    repeat (4) @(posedge clk);

    if (stall_error) begin
      errors++;
      $error("[TB] a stall watchdog latched during the run");
    end

    if (errors == 0) $display("[TB] tb_xdma_finish_manager_gather_rearm PASSED");
    else
      $display("[TB] tb_xdma_finish_manager_gather_rearm FAILED with %0d error(s)", errors);
    $finish;
  end

endmodule
