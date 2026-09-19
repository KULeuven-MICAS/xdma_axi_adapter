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
  logic ctx_match;
  logic ctx_open;
  logic ctx_en;

  // The identity of the transfer this FSM armed on, latched when it leaves IDLE.
  //
  // `ready_to_transfer` alone cannot say whether the transfer this FSM is serving is still
  // the one on the port: it is a LEVEL derived from the receiving node's writer busy state, so
  // it answers "is SOME transfer running", not "is MINE". Comparing the live port against this
  // latched copy answers the second question, and `WAIT_FINISH` exits on that instead.
  //
  // The exit condition is then local to this FSM: it does not depend on the sending side
  // choosing to drop the level between transfers. A frontend that changes the identity and the
  // level together makes this equivalent to the level alone; it holds for one that does not.
  // `tb_xdma_multisource_collision` and `tb_xdma_multisource_read_collision` drive the case
  // where two receive windows abut with the level never falling.
  //
  // Widths are taken from the port so the module still needs no type parameters.
  logic [ $bits(from_remote_data_accompany_cfg_i.dma_id)-1:0] ctx_dma_id_q;
  logic [$bits(from_remote_data_accompany_cfg_i.src_addr)-1:0] ctx_src_addr_q;
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

  // "The port still names the transfer this FSM armed on." Both fields matter: `dma_id` is
  // only unique per source, so two sources can legitimately have the same id in flight.
  assign ctx_match = (from_remote_data_accompany_cfg_i.dma_id == ctx_dma_id_q) &&
                     (from_remote_data_accompany_cfg_i.src_addr == ctx_src_addr_q);
  assign ctx_open  = grant_valid && ctx_match;

  always_ff @(posedge clk_i, negedge rst_ni) begin
    if (!rst_ni) begin
      ctx_dma_id_q   <= '0;
      ctx_src_addr_q <= '0;
    end else if (ctx_en) begin
      ctx_dma_id_q   <= from_remote_data_accompany_cfg_i.dma_id;
      ctx_src_addr_q <= from_remote_data_accompany_cfg_i.src_addr;
    end
  end
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
    ctx_en     = 1'b0;
    case (cur_state)
      IDLE: begin
        if (is_write_last) begin
          ctx_en     = 1'b1;
          next_state = WRITE_LAST;
        end
        if (is_write_middle) begin
          ctx_en     = 1'b1;
          next_state = WRITE_MIDDLE;
        end
      end
      WRITE_LAST: next_state = SEND_GRANT_TO_PREV_HOP;
      WRITE_MIDDLE: if (from_remote_grant_i) next_state = SEND_GRANT_TO_PREV_HOP;
      SEND_GRANT_TO_PREV_HOP: if (grant_happening) next_state = WAIT_FINISH;
      // Wait until the receive window THIS FSM armed on closes -- which is the port no
      // longer naming that transfer, not the shared busy level merely falling. A chain hop
      // holds one id and one source for its whole participation window, so this is
      // identical to the old `grant_valid == 0` there; it only differs when a second
      // transfer from another source abuts the first.
      WAIT_FINISH: if (!ctx_open) next_state = IDLE;
    endcase
  end

  // Output logic
  always_comb begin : proc_output_logic
    to_remote_grant_valid_o = 1'b0;
    case (cur_state)
      IDLE: to_remote_grant_valid_o = 1'b0;
      WRITE_LAST: to_remote_grant_valid_o = 1'b0;
      WRITE_MIDDLE: to_remote_grant_valid_o = 1'b0;
      // `ctx_open`, not `grant_valid`. The grant PACKET is assembled in
      // `xdma_axi_adapter_top` from the LIVE port -- `to_remote_grant.from` and the
      // destination MMIO address both come from `from_remote_data_accompany_cfg.src_addr`.
      // Qualifying the valid with `ctx_match` makes "the packet describes the transfer this
      // FSM armed on" true by construction, instead of resting on the cross-module argument
      // that a sender cannot advance before its grant (true today, but not local to this
      // file). If the port ever does move on first, the FSM parks and the watchdog names
      // it -- a loud stall rather than a grant silently delivered to the wrong node.
      SEND_GRANT_TO_PREV_HOP: to_remote_grant_valid_o = ctx_open;
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
