// Authors:
// - Fanchen Kong <fanchen.kong@kuleuven.be>
//
// Unit test for `xdma_stall_watchdog`.
//
// Checks the three properties the adapter relies on:
//   1. `Timeout - 1` stalled cycles do NOT raise the flag (no false positives on the
//      legitimate gaps in a healthy transfer),
//   2. the `Timeout`-th consecutive stalled cycle does,
//   3. the flag is sticky (a chain that eventually limps to completion is still reported),
//      and any progress rearms the counter.
//
// The instance under test sets `ErrorOnStall = 0` so tripping the watchdog on purpose
// prints instead of raising a simulator error -- `scripts/run_vsim.sh` greps for
// "Errors: 0,".

`timescale 1ns / 1ps
module tb_xdma_stall_watchdog ();

  localparam int unsigned TbTimeout  = 8;
  localparam time         TbCyclTime = 10ns;

  logic clk;
  logic rst_n;
  logic stalled;
  logic stall_error;
  int   errors = 0;

  xdma_stall_watchdog #(
      .Timeout     (TbTimeout),
      .ErrorOnStall(1'b0),
      .Name        ("tb_xdma_stall_watchdog")
  ) i_dut (
      .clk_i        (clk),
      .rst_ni       (rst_n),
      .stalled_i    (stalled),
      .stall_error_o(stall_error)
  );

  // A disabled watchdog must be inert no matter what is driven at it.
  logic stall_error_disabled;
  xdma_stall_watchdog #(
      .Timeout(0),
      .Name   ("tb_xdma_stall_watchdog.disabled")
  ) i_dut_disabled (
      .clk_i        (clk),
      .rst_ni       (rst_n),
      .stalled_i    (stalled),
      .stall_error_o(stall_error_disabled)
  );

  initial begin
    clk = 1'b0;
    forever #(TbCyclTime / 2) clk = ~clk;
  end

  task automatic check(input logic actual, input logic expected, input string what);
    if (actual !== expected) begin
      errors++;
      $error("%s: expected %0b, got %0b", what, expected, actual);
    end
  endtask

  // Hold `stalled` high for `n` clock edges, then sample.
  task automatic stall_for(input int unsigned n);
    stalled <= 1'b1;
    repeat (n) @(posedge clk);
    #1ns;
  endtask

  initial begin
    rst_n   = 1'b0;
    stalled = 1'b0;
    repeat (5) @(posedge clk);
    rst_n <= 1'b1;
    @(posedge clk);
    #1ns;
    check(stall_error, 1'b0, "flag after reset");

    // 1. One cycle short of the timeout must stay quiet.
    stall_for(TbTimeout - 1);
    check(stall_error, 1'b0, "flag at Timeout-1 stalled cycles");

    // ... and a single cycle of progress must rearm the counter.
    stalled <= 1'b0;
    @(posedge clk);
    #1ns;
    stall_for(TbTimeout - 1);
    check(stall_error, 1'b0, "flag after rearm + Timeout-1 stalled cycles");

    // 2. The Timeout-th consecutive stalled cycle trips it.
    stall_for(1);
    check(stall_error, 1'b1, "flag at Timeout stalled cycles");

    // 3. Sticky: progress does not clear it.
    stalled <= 1'b0;
    repeat (5) @(posedge clk);
    #1ns;
    check(stall_error, 1'b1, "flag is sticky after progress resumes");

    // A `Timeout == 0` instance never reports, whatever it saw above.
    check(stall_error_disabled, 1'b0, "disabled watchdog stays low");

    repeat (5) @(posedge clk);
    if (errors == 0) $display("[TB] tb_xdma_stall_watchdog PASSED");
    else $display("[TB] tb_xdma_stall_watchdog FAILED with %0d error(s)", errors);
    $finish;
  end

endmodule
