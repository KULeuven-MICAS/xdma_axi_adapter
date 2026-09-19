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
    /// The accompany cfg this FSM armed on, held for as long as the grant is being offered.
    /// The grant PACKET must be built from this and not from the live port: see the comment
    /// on `ctx_cfg_q` below.
    output xdma_from_remote_data_accompany_cfg_t armed_cfg_o,
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
  // The WHOLE cfg is latched, not just the identity, because the grant packet is built from
  // it -- see `armed_cfg_o`.
  xdma_from_remote_data_accompany_cfg_t ctx_cfg_q;
  assign armed_cfg_o = ctx_cfg_q;
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
  assign ctx_match = (from_remote_data_accompany_cfg_i.dma_id == ctx_cfg_q.dma_id) &&
                     (from_remote_data_accompany_cfg_i.src_addr == ctx_cfg_q.src_addr);
  assign ctx_open  = grant_valid && ctx_match;

  always_ff @(posedge clk_i, negedge rst_ni) begin
    if (!rst_ni) begin
      ctx_cfg_q <= '0;
    end else if (ctx_en) begin
      ctx_cfg_q <= from_remote_data_accompany_cfg_i;
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
      // UNCONDITIONAL once this FSM has committed. It must not be qualified by the live
      // port, in any form.
      //
      // The correctness that qualification was buying -- "the packet describes the transfer
      // this FSM armed on" -- now comes from `armed_cfg_o`: the packet is built in
      // `xdma_axi_adapter_top` from the LATCHED cfg, so it names the right node by
      // construction whatever the port does next. That is the same shape the finish path
      // already has, where `to_remote_finish_valid_o` is likewise unconditional and the
      // packet comes from `from_remote_addr_q`.
      //
      // Qualifying it instead trades a wrong grant for a lost one. AXI VALID may not be
      // retracted before its handshake, and this FSM leaves this state only on that
      // handshake, so a port that moves on while the grant is still queued behind the narrow
      // bus -- cfg outranks grant in `find_first_one_idx`, so a node that is also an issuer
      // queues grants behind its own cfg -- parks the FSM for good. The sender then waits
      // forever for a grant that was committed and never sent, which is a silent hang at the
      // far end and a stall watchdog here.
      SEND_GRANT_TO_PREV_HOP: to_remote_grant_valid_o = 1'b1;
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
