// Authors:
// - Fanchen Kong <fanchen.kong@kuleuven.be>
//
// Directed test for the completion-reporting path in `xdma_finish_manager`.
//
// `xdma_finish_o` is ONE bit shared by three independent completion sources:
//
//   xdma_finish_o = (tail_write_finish_valid & from_remote_is_initiator_q)   // FSM3, tail
//                 |  read_finish_valid                                       // FSM1, read
//                 | (first_write_finish_valid & to_remote_is_initiator_q);   // FSM2, head
//
// It carries no id and no count, so the frontend can only tell two completions apart by
// counting assertions. Two of the three sources are level-held until their handshake, and
// the arbitration below them gives FSM3's single-cycle pulse priority:
//
//   if (tail_write_finish_valid) begin read_finish_ready = 0; first_write_finish_ready = 0; end
//   else if (read_finish_valid) ...
//
// So when FSM3 retires on the same cycle FSM1 wants to, FSM1 is held for one cycle and
// retries -- and `xdma_finish_o` is high for two consecutive cycles.
//
// The question this testbench asks: is that two-cycle assertion distinguishable from one
// task completing? It runs the identical stimulus twice, changing only whether the node
// OWNS the write that FSM3 retires:
//
//   Phase A  the write's `is_initiator` = 0 (a ChainWrite tail -- forwards a finish but
//            owns nothing). ONE task completes here: the local read.
//   Phase B  the write's `is_initiator` = 1 (the node owns it). TWO tasks complete.
//
// If both phases drive the same `xdma_finish_o` waveform, then no counting rule on the
// frontend can be right: counting cycles over-reports Phase A, counting rising edges
// under-reports Phase B. That is the defect, and it holds whatever the frontend's counting
// rule is.
//
// REACHABILITY. It needs the narrow finish channel to backpressure while FSM3 sits in
// `WriteLastFinish` -- ordinary contention -- and a local read retiring on the cycle that
// channel frees. The defect is in the output encoding rather than in any one FSM, so it does
// not depend on which turnover produced the two completions.

`timescale 1ns / 1ps
module tb_xdma_finish_manager_completion_merge ();

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

  typedef logic [       TbXDMAIdWidth-1:0]                              tb_id_t;
  typedef logic [      TbAxiAddrWidth-1:0]                              tb_addr_t;
  typedef logic [TbAxiNarrowDataWidth-1:0]                              tb_narrow_data_t;
  typedef logic [    TbDMALengthWidth-1:0]                              tb_len_t;
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

  localparam tb_id_t IdW1 = 4'd1;  // the write FSM3 retires
  localparam tb_id_t IdRd = 4'd2;  // the node's own read
  localparam tb_id_t IdW2 = 4'd3;  // the write that closes the read's window

  //--------------------------------------
  // DUT
  //--------------------------------------
  logic clk;
  logic rst_n;
  int   errors = 0;

  tb_xdma_accompany_cfg_t to_remote_cfg;
  tb_xdma_accompany_cfg_t from_remote_cfg;
  tb_narrow_data_t        from_remote_finish;
  logic                   from_remote_finish_valid;
  logic                   to_remote_finish_ready;

  logic                   xdma_finish;
  logic                   xdma_write_finish;
  logic                   from_remote_finish_ready;
  logic                   to_remote_finish_valid;
  logic                   stall_error;
  tb_addr_t               remote_addr;
  tb_id_t                 from_remote_dma_id;

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

  //--------------------------------------
  // Record the exact `xdma_finish_o` waveform, cycle by cycle
  //--------------------------------------
  bit recording;
  bit wave[$];
  int finish_cycles;

  always @(posedge clk) begin
    if (rst_n && recording) begin
      wave.push_back(xdma_finish);
      if (xdma_finish) finish_cycles++;
    end
  end

  function automatic string wave_str(input bit w[$]);
    string s = "";
    foreach (w[i]) s = {s, w[i] ? "1" : "0"};
    return s;
  endfunction

  task automatic check(input int actual, input int expected, input string what);
    if (actual != expected) begin
      errors++;
      $error("%s: expected %0d, got %0d", what, expected, actual);
    end
  endtask

  //--------------------------------------
  // Window drivers
  //--------------------------------------
  // A write this node is the LAST hop of. `owns` is `is_initiator`: set for a plain remote
  // write or a ChainGather collector, clear for a ChainWrite tail.
  task automatic drive_write_last(input tb_id_t id, input bit owns);
    from_remote_cfg.dma_id            <= id;
    from_remote_cfg.dma_type          <= 1'b1;
    from_remote_cfg.src_addr          <= TbPrevAddr;
    from_remote_cfg.dst_addr          <= '0;
    from_remote_cfg.dma_length        <= tb_len_t'(8);
    from_remote_cfg.ready_to_transfer <= 1'b1;
    from_remote_cfg.is_first_cw       <= 1'b0;
    from_remote_cfg.is_last_cw        <= 1'b1;
    from_remote_cfg.is_initiator      <= owns;
  endtask

  // A remote read this node issued and is taking delivery of.
  task automatic drive_read(input tb_id_t id);
    from_remote_cfg.dma_id            <= id;
    from_remote_cfg.dma_type          <= 1'b0;
    from_remote_cfg.src_addr          <= TbPrevAddr;
    from_remote_cfg.dst_addr          <= '0;
    from_remote_cfg.dma_length        <= tb_len_t'(8);
    from_remote_cfg.ready_to_transfer <= 1'b1;
    from_remote_cfg.is_first_cw       <= 1'b0;
    from_remote_cfg.is_last_cw        <= 1'b0;
    from_remote_cfg.is_initiator      <= 1'b1;
  endtask

  //--------------------------------------
  // One phase. Identical stimulus; only `owns_w1` differs.
  //--------------------------------------
  // Completions that genuinely retire here:
  //   the local read  -- always
  //   write W1        -- only when `owns_w1`, since FSM3's completion is gated by
  //                      `from_remote_is_initiator_q`
  task automatic run_phase(input bit owns_w1, input string name, output bit w[$],
                           output int cycles);
    $display("[TB] %s: write W1 is_initiator=%0b -> %0d task(s) should be reported", name,
             owns_w1, owns_w1 ? 2 : 1);

    // 1. W1's window opens; FSM3 arms and latches (id, src, is_initiator).
    drive_write_last(IdW1, owns_w1);
    repeat (4) @(posedge clk);

    // 2. Park FSM3 in WriteLastFinish: its window closes, but the narrow finish channel
    //    backpressures. Contention on that channel is ordinary, not exotic.
    to_remote_finish_ready <= 1'b0;
    drive_read(IdRd);
    repeat (4) @(posedge clk);

    // 3. Start recording, then close the read's window and release the finish channel on
    //    the SAME cycle. FSM1 asserts `read_finish_valid`; FSM3 asserts
    //    `tail_write_finish_valid`; the arbitration holds FSM1 for a cycle.
    recording     = 1'b1;
    finish_cycles = 0;
    wave.delete();
    @(posedge clk);
    drive_write_last(IdW2, 1'b0);
    to_remote_finish_ready <= 1'b1;
    repeat (8) @(posedge clk);
    recording = 1'b0;

    w      = wave;
    cycles = finish_cycles;
    $display("[TB]   xdma_finish_o = %s  (%0d cycle(s) high)", wave_str(wave), finish_cycles);

    // Settle: close W2 and let everything drain back to idle.
    from_remote_cfg <= '0;
    repeat (10) @(posedge clk);
  endtask

  //--------------------------------------
  // Test
  //--------------------------------------
  bit wave_a[$];
  bit wave_b[$];
  int cycles_a, cycles_b;

  initial begin
    rst_n                    = 1'b0;
    to_remote_cfg            = '0;
    from_remote_cfg          = '0;
    from_remote_finish       = '0;
    from_remote_finish_valid = 1'b0;
    to_remote_finish_ready   = 1'b1;
    recording                = 1'b0;
    finish_cycles            = 0;

    repeat (5) @(posedge clk);
    rst_n <= 1'b1;
    repeat (2) @(posedge clk);

    run_phase(1'b0, "Phase A -- ChainWrite tail (owns nothing)", wave_a, cycles_a);
    run_phase(1'b1, "Phase B -- plain remote write (owns the task)", wave_b, cycles_b);

    //====================================================================
    // The assertion
    //====================================================================
    // One task completes in A, two in B. Whatever the frontend's counting rule, the two
    // must be distinguishable at this port -- otherwise a completion is silently lost or
    // invented.
    if (wave_str(wave_a) == wave_str(wave_b)) begin
      errors++;
      $error("[TB] xdma_finish_o cannot distinguish 1 completion from 2: Phase A (1 task) = %s, Phase B (2 tasks) = %s -- counting cycles over-reports A, counting edges under-reports B",
             wave_str(wave_a), wave_str(wave_b));
    end

    // Stated separately so the log says WHICH rule each phase breaks.
    check(cycles_a, 1, "Phase A: xdma_finish_o cycles high (1 task completed)");
    check(cycles_b, 2, "Phase B: xdma_finish_o cycles high (2 tasks completed)");

    if (stall_error) begin
      errors++;
      $error("[TB] stall watchdog latched");
    end

    if (errors == 0) $display("[TB] tb_xdma_finish_manager_completion_merge PASSED");
    else
      $display("[TB] tb_xdma_finish_manager_completion_merge FAILED with %0d error(s)",
               errors);
    $finish;
  end

endmodule
