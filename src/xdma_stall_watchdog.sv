// Authors:
// - Fanchen Kong <fanchen.kong@kuleuven.be>
// - Yunhao Deng <yunhao.deng@kuleuven.be>

/// Bring-up stall watchdog for the XDMA cross-cluster control FSMs.
///
/// Rationale: *every* wait in the adapter's
/// control path is unbounded -- grant propagation (`xdma_grant_manager` WRITE_MIDDLE /
/// SEND_GRANT_TO_PREV_HOP / WAIT_FINISH), the finish round trip
/// (`xdma_finish_manager` WriteFirstBusy / WriteMiddleBusy), the beat count
/// (`xdma_meta_manager`), the burst reshaper's FINISH state, and W beats blocked on a
/// missing grant (`xdma_data_path`). A chain hop that never completes therefore hangs
/// the whole chain *silently*: there is no timeout, no assertion and no status bit
/// anywhere in the adapter. Debugging that from the core side means staring at a core
/// spinning in FINISH_REMOTE with no idea which hop wedged.
///
/// This module turns "waiting forever" into an observable, sticky status bit. Instantiate
/// it next to an FSM, drive `stalled_i` with a level that means *"waiting, and made no
/// progress this cycle"* (typically `state != IDLE && next_state == state`), and route
/// `stall_error_o` out to a status register / ILA.
///
/// `Timeout == 0` (the default) removes the watchdog entirely -- no counter, no register,
/// `stall_error_o` tied low -- so the cost is opt-in. Pick a `Timeout` comfortably above
/// the longest *legitimate* wait: the wait states also cover a whole in-flight transfer,
/// so a few times the worst-case transfer length is the right order of magnitude.
module xdma_stall_watchdog #(
    /// Number of consecutive stalled cycles tolerated before `stall_error_o` latches.
    /// 0 disables the watchdog completely (no logic is generated).
    parameter int unsigned Timeout      = 0,
    /// Emit the diagnostic with `$error` (1) rather than `$display` (0). Keep 1 for RTL
    /// and SoC bring-up -- a stall here is always a bug. The unit testbench uses 0 so it
    /// can trip the watchdog on purpose without polluting the simulator's error count.
    parameter bit          ErrorOnStall = 1'b1,
    /// Instance name reported in the simulation-only diagnostic.
    parameter string       Name         = "xdma"
) (
    /// Clock
    input  logic clk_i,
    /// Asynchronous reset, active low
    input  logic rst_ni,
    /// Level: the observed FSM is waiting and did not advance this cycle.
    input  logic stalled_i,
    /// Sticky: set once `stalled_i` has held for `Timeout` consecutive cycles.
    /// Cleared only by reset.
    output logic stall_error_o
);

  if (Timeout == 0) begin : gen_no_watchdog
    assign stall_error_o = 1'b0;
  end else begin : gen_watchdog
    // +1 so `Timeout` itself is representable and the counter can saturate on it.
    localparam int unsigned CntWidth = $clog2(Timeout + 1);

    logic [CntWidth-1:0] cnt_q;
    logic                saturated;
    logic                stall_error_q;

    assign saturated = (cnt_q == CntWidth'(Timeout));

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        cnt_q         <= '0;
        stall_error_q <= 1'b0;
      end else begin
        if (!stalled_i) begin
          // Any progress rearms the watchdog. The error bit stays sticky on purpose:
          // a chain that eventually limps to completion still needs to be reported.
          cnt_q <= '0;
        end else if (!saturated) begin
          cnt_q <= cnt_q + 1;
          if (cnt_q == CntWidth'(Timeout - 1)) begin
            stall_error_q <= 1'b1;
            // pragma translate_off
            if (ErrorOnStall) begin
              $error("[XDMA-STALL] %s (%m) made no progress for %0d cycles", Name, Timeout);
            end else begin
              $display("[XDMA-STALL] %s (%m) made no progress for %0d cycles", Name, Timeout);
            end
            // pragma translate_on
          end
        end
      end
    end

    assign stall_error_o = stall_error_q;
  end

endmodule
