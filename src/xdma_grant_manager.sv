// Fanchen Kong <fanchen.kong@kuleuven.be>
// Yunhao Deng <yunhao.deng@kuleuven.be>

module xdma_grant_manager #(
    parameter type         xdma_from_remote_data_accompany_cfg_t = logic,
    /// Bring-up stall watchdog: number of consecutive cycles this FSM may sit in a
    /// non-IDLE state without advancing before `stall_error_o` latches. 0 (default)
    /// removes the watchdog. See `xdma_stall_watchdog` for the rationale.
    parameter int unsigned StallTimeout                          = 0
) (
    /// Clock
    input  logic                                 clk_i,
    /// Asynchronous reset, active low
    input  logic                                 rst_ni,
    /// from remote grant
    input  logic                                 from_remote_grant_i,
    /// from remote data accompany cfg
    input  xdma_from_remote_data_accompany_cfg_t from_remote_data_accompany_cfg_i,
    ///
    output logic                                 to_remote_grant_valid_o,
    ///
    input  logic                                 to_remote_grant_ready_i,
    /// Sticky: this FSM stalled for `StallTimeout` cycles. Tied low when the watchdog
    /// is disabled.
    output logic                                 stall_error_o
);

  typedef enum logic [2:0] {
    IDLE,
    WRITE_LAST,
    WRITE_MIDDLE,
    SEND_GRANT_TO_PREV_HOP,
    WAIT_FINISH
  } state_t;

  state_t cur_state, next_state;

  logic is_write_last;
  logic is_write_middle;
  logic grant_happening;
  logic grant_valid;
  assign is_write_middle = (from_remote_data_accompany_cfg_i.dma_type == 1'b1) &&
                         (!from_remote_data_accompany_cfg_i.is_first_cw) &&
                         (!from_remote_data_accompany_cfg_i.is_last_cw) &&
                          from_remote_data_accompany_cfg_i.ready_to_transfer;

  assign is_write_last = (from_remote_data_accompany_cfg_i.dma_type == 1'b1) &&
                         (!from_remote_data_accompany_cfg_i.is_first_cw) &&
                         (from_remote_data_accompany_cfg_i.is_last_cw) &&
                          from_remote_data_accompany_cfg_i.ready_to_transfer;
  assign grant_happening = to_remote_grant_valid_o && to_remote_grant_ready_i;
  assign grant_valid = from_remote_data_accompany_cfg_i.ready_to_transfer && from_remote_data_accompany_cfg_i.dma_type;
  // State Update
  always_ff @(posedge clk_i, negedge rst_ni) begin
    if (!rst_ni) begin
      cur_state <= IDLE;
    end else begin
      cur_state <= next_state;
    end
  end

  // Next state logic
  always_comb begin : proc_next_state_logic
    next_state = cur_state;
    case (cur_state)
      IDLE: begin
        if (is_write_last) next_state = WRITE_LAST;
        if (is_write_middle) next_state = WRITE_MIDDLE;
      end
      WRITE_LAST: next_state = SEND_GRANT_TO_PREV_HOP;
      WRITE_MIDDLE: if (from_remote_grant_i) next_state = SEND_GRANT_TO_PREV_HOP;
      SEND_GRANT_TO_PREV_HOP: if (grant_happening) next_state = WAIT_FINISH;
      // Wait the current req is finish
      WAIT_FINISH: if (grant_valid == 1'b0) next_state = IDLE;
    endcase
  end

  // Output logic
  always_comb begin : proc_output_logic
    to_remote_grant_valid_o = 1'b0;
    case (cur_state)
      IDLE: to_remote_grant_valid_o = 1'b0;
      WRITE_LAST: to_remote_grant_valid_o = 1'b0;
      WRITE_MIDDLE: to_remote_grant_valid_o = 1'b0;
      SEND_GRANT_TO_PREV_HOP: to_remote_grant_valid_o = grant_valid;
      WAIT_FINISH: to_remote_grant_valid_o = 1'b0;
    endcase
  end

  //--------------------------------------
  // Bring-up stall watchdog
  //--------------------------------------
  // Every non-IDLE state here waits on something that can never arrive if a hop upstream
  // or downstream wedges: WRITE_MIDDLE on the next hop's grant, SEND_GRANT_TO_PREV_HOP on
  // the narrow channel accepting our grant, WAIT_FINISH on the receive window closing.
  // "In a wait state and the next state is the same" is exactly "no progress".
  logic stalled;
  assign stalled = (cur_state != IDLE) && (next_state == cur_state);

  xdma_stall_watchdog #(
      .Timeout(StallTimeout),
      .Name   ("xdma_grant_manager")
  ) i_stall_watchdog (
      .clk_i        (clk_i),
      .rst_ni       (rst_ni),
      .stalled_i    (stalled),
      .stall_error_o(stall_error_o)
  );
endmodule
