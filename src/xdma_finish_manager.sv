// Authors:
// - Fanchen Kong <fanchen.kong@kuleuven.be>
// - Yunhao Deng <yunhao.deng@kuleuven.be>

/// This module tracks the handshake signal of the
/// from_remote_data 
//  to_remote_data

module xdma_finish_manager #(
    parameter type         id_t                                  = logic,
    parameter type         len_t                                 = logic,
    parameter type         addr_t                                = logic,
    parameter type         data_t                                = logic,
    parameter type         xdma_to_remote_data_accompany_cfg_t   = logic,
    parameter type         xdma_from_remote_data_accompany_cfg_t = logic,
    parameter type         xdma_req_desc_t                       = logic,
    parameter type         xdma_to_remote_finish_t               = logic,
    /// Guard against a node mistaking itself for the head of a chain it is only a hop in.
    ///
    /// FSM2 decides "I am the head of a chained write" from the *to-remote* accompany cfg
    /// alone (`dma_type & ready_to_transfer & is_first_cw & ~is_last_cw`). A node whose local
    /// reader runs while it is also taking delivery of a chain can present that exact shape
    /// without heading anything, and arming FSM2 on it is a one-way door: `WriteFirstBusy` has
    /// no exit but an id-matched finish, and the id latched from a transient need never match
    /// one. A parked FSM2 then:
    ///
    ///   - releases a grant credit through `xdma_write_finish_o` that the node never reserved;
    ///   - holds `from_remote_finish_ready_o` high, acknowledging and destroying finish beats
    ///     meant for FSM3, so chains form and never retire;
    ///   - cannot serve a task the node genuinely heads, so that initiator's core never
    ///     completes.
    ///
    /// Set, FSM2 additionally requires that the node is not taking delivery of chained-write
    /// data, both to arm and to STAY armed: a chain's head sources the payload and never
    /// receives it. Covering the busy state as well as the arm matters because the local reader
    /// leads the receive window, so an arm-only guard sees nothing to act on.
    ///
    /// Clear the parameter only to obtain the unguarded behaviour;
    /// `tb_xdma_finish_manager_guard` instantiates both.
    parameter bit          SpuriousFinishGuard                   = 1'b1,
    /// Bring-up stall watchdog: consecutive cycles any of the three FSMs below may sit in
    /// a non-idle state without advancing before `stall_error_o` latches. 0 (default)
    /// removes the watchdog. See `xdma_stall_watchdog`.
    parameter int unsigned StallTimeout                          = 0,
    //Dependent parameter
    parameter int unsigned LenWidth                              = $bits(len_t)
) (
    /// Clock
    input  logic                                 clk_i,
    /// Asynchronous reset, active low
    input  logic                                 rst_ni,
    /// Status Signal
    // The XDMA finish indicator, connect to XDMA Frontend. Only becomes high at first XDMA (Write / ChainWrite)
    output logic                                 xdma_finish_o,
    // The XDMA remote write finish indicator, connect to grant_manager. Becomes high for the whole chain
    output logic                                 xdma_write_finish_o,
    /// to remote
    input  xdma_to_remote_data_accompany_cfg_t   to_remote_data_accompany_cfg_i,
    /// from remote accompany cfg
    input  xdma_from_remote_data_accompany_cfg_t from_remote_data_accompany_cfg_i,
    // input  logic                                 from_remote_data_happening_i,
    /// from remote finish
    input  data_t                                from_remote_finish_i,
    input  logic                                 from_remote_finish_valid_i,
    output logic                                 from_remote_finish_ready_o,

    output addr_t                                remote_addr_o,
    output id_t                                  from_remote_dma_id_o,
    output logic                                 to_remote_finish_valid_o,
    input  logic                                 to_remote_finish_ready_i,
    /// Sticky: one of the three FSMs stalled for `StallTimeout` cycles. Tied low when
    /// the watchdog is disabled.
    output logic                                 stall_error_o
);

  xdma_to_remote_finish_t from_remote_finish;
  assign from_remote_finish = from_remote_finish_i;

  // Status that need the pull up xdma_finish_o: Read task, The first hop of a write task
  typedef enum logic [1:0] {
    ReadIdle,
    ReadBusy,
    ReadFinish
  } xdma_read_status_t;

  typedef enum logic [1:0] {
    WriteFirstIdle,
    WriteFirstBusy,
    WriteFirstFinish
  } xdma_first_write_status_t;

  typedef enum logic [2:0] {
    WriteMiddleLastIdle,
    WriteMiddleBusy,
    WriteLastBusy,
    WriteLastFinish,
    SendToPreviousHop
  } xdma_last_write_status_t;

  // The temporal saver for to_remote_id, from_remote_id, and from_remote_addr
  id_t   to_remote_dma_id_q;
  id_t   from_remote_dma_id_q;
  addr_t from_remote_addr_q;
  // Ownership is captured with the id it belongs to, on the same enables. The finish
  // arrives long after the accompany cfg that announced the transfer, and by then the
  // sender datapath may already have dropped the sideband -- sampling `is_initiator`
  // combinationally at that point would read whatever happens to be on the port.
  logic  to_remote_is_initiator_q;
  logic  from_remote_is_initiator_q;
  // FSM1 gets its own copy. FSM1 and FSM3 arm on mutually exclusive values of `dma_type`,
  // but they can be busy at the same time -- a node pulling a remote read while a remote
  // write lands on it is exactly the "receiver is not idle" case -- and each must judge its
  // own window against its own transfer.
  id_t   read_dma_id_q;
  addr_t read_addr_q;
  logic to_remote_dma_id_en, from_remote_dma_id_en, from_remote_addr_en, read_ctx_en;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      to_remote_dma_id_q        <= '0;
      from_remote_dma_id_q      <= '0;
      from_remote_addr_q        <= '0;
      to_remote_is_initiator_q  <= 1'b0;
      from_remote_is_initiator_q <= 1'b0;
      read_dma_id_q             <= '0;
      read_addr_q               <= '0;
    end else begin
      if (to_remote_dma_id_en) begin
        to_remote_dma_id_q       <= to_remote_data_accompany_cfg_i.dma_id;
        to_remote_is_initiator_q <= to_remote_data_accompany_cfg_i.is_initiator;
      end
      if (from_remote_dma_id_en) begin
        from_remote_dma_id_q       <= from_remote_data_accompany_cfg_i.dma_id;
        from_remote_is_initiator_q <= from_remote_data_accompany_cfg_i.is_initiator;
      end
      if (from_remote_addr_en) from_remote_addr_q <= from_remote_data_accompany_cfg_i.src_addr;
      if (read_ctx_en) begin
        read_dma_id_q <= from_remote_data_accompany_cfg_i.dma_id;
        read_addr_q   <= from_remote_data_accompany_cfg_i.src_addr;
      end
    end
  end

  // "The from-remote port still names the transfer this FSM armed on."
  //
  // `ready_to_transfer` is a LEVEL held by the receiving node's datapath for as long as it is
  // busy, so a bare `~ready_to_transfer` exit means "the node went idle", not "my transfer
  // ended". Comparing the live port against the identity latched at arm time says the second,
  // which is what these FSMs need: a receive window is over when the port stops naming its
  // transfer, whether or not the node has gone quiet. `src_addr` is compared alongside `dma_id`
  // because ids are only unique per source.
  //
  // A frontend that changes the identity and the level together makes these equivalent to the
  // level alone. They hold for one that does not. `tb_xdma_multisource_*` drives the case where
  // two receive windows abut with the level never falling.
  logic read_ctx_open, from_remote_ctx_open;
  assign read_ctx_open = from_remote_data_accompany_cfg_i.ready_to_transfer
                       & (~from_remote_data_accompany_cfg_i.dma_type)
                       & (from_remote_data_accompany_cfg_i.dma_id == read_dma_id_q)
                       & (from_remote_data_accompany_cfg_i.src_addr == read_addr_q);
  assign from_remote_ctx_open = from_remote_data_accompany_cfg_i.ready_to_transfer
                              & from_remote_data_accompany_cfg_i.dma_type
                              & (from_remote_data_accompany_cfg_i.dma_id == from_remote_dma_id_q)
                              & (from_remote_data_accompany_cfg_i.src_addr == from_remote_addr_q);

  // The declaration for the FSM
  xdma_read_status_t read_current_state, read_next_state;
  xdma_first_write_status_t first_write_current_state, first_write_next_state;
  xdma_last_write_status_t last_write_current_state, last_write_next_state;

  // First FSM: Read
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      read_current_state <= ReadIdle;
    end else begin
      read_current_state <= read_next_state;
    end
  end

  // Two signals to send the read finish to XDMACtrl
  logic read_finish_valid, read_finish_ready;
  always_comb begin
    read_next_state   = read_current_state;
    read_finish_valid = 1'b0;
    read_ctx_en       = 1'b0;
    case (read_current_state)
      ReadIdle: begin
        if ((~from_remote_data_accompany_cfg_i.dma_type) && from_remote_data_accompany_cfg_i.ready_to_transfer) begin
          read_ctx_en     = 1'b1;
          read_next_state = ReadBusy;
        end
      end
      ReadBusy: begin
        if (!read_ctx_open) begin
          read_finish_valid = 1'b1;
          if (read_finish_ready) begin
            read_next_state = ReadIdle;
          end else begin
            read_next_state = ReadFinish;
          end
        end
      end
      ReadFinish: begin
        read_finish_valid = 1'b1;
        if (read_finish_ready) begin
          read_next_state = ReadIdle;
        end
      end
      default: begin
        read_next_state = ReadIdle;
      end
    endcase
  end

  // Second FSM: First Write
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      first_write_current_state <= WriteFirstIdle;
    end else begin
      first_write_current_state <= first_write_next_state;
    end
  end

  // Two signals to send the write finish to XDMACtrl
  logic first_write_finish_valid, first_write_finish_ready;

  // "This node is taking delivery of a chained write's payload."
  //
  // True for a MIDDLE hop and for a TAIL, since both have `is_first_cw` clear. A bare
  // `ready_to_transfer` would not do: it is also high for a plain remote write, which says
  // nothing about chain position.
  //
  // Deliberately the same predicate FSM3's middle branch arms on, so the two FSMs are mutually
  // exclusive by construction rather than by timing.
  logic receiving_chained_write;
  assign receiving_chained_write = from_remote_data_accompany_cfg_i.dma_type
                                 & from_remote_data_accompany_cfg_i.ready_to_transfer
                                 & (~from_remote_data_accompany_cfg_i.is_first_cw);

  // "The to-remote port reads as the head of a chained write."
  logic head_claim;
  assign head_claim = to_remote_data_accompany_cfg_i.dma_type
                    & to_remote_data_accompany_cfg_i.ready_to_transfer
                    & to_remote_data_accompany_cfg_i.is_first_cw
                    & (~to_remote_data_accompany_cfg_i.is_last_cw);

  // See `SpuriousFinishGuard` above: a node taking delivery of a chain's data is not that
  // chain's head, so it may neither claim the role nor keep a claim it already took --
  // unless the claim is on a task this node issued itself (`is_initiator`).
  //
  // `receiving_chained_write` is a POSITION predicate, and position cannot separate a spurious
  // claim from a genuine outgoing transfer on a node that also receives: both present
  // `dma_type=1, is_first_cw=1, is_last_cw=0`. Ownership separates them. A chain head never
  // owns the task in ChainGather -- the collector does -- so a claim the guard exists to
  // suppress carries `is_initiator = 0`, and one that must survive carries 1. Two plain remote
  // writes crossing in opposite directions put a node in both roles at once, and without the
  // ownership term that node loses its own completion with nothing stalling and no watchdog
  // firing: its claim is retracted when the incoming window opens, and the to-remote window is
  // a few cycles long, so there is nothing left to re-arm on.
  //
  // Two forms, because the two uses sample at different times -- the same live-versus-latched
  // split `to_remote_dma_id_q` exists for:
  //
  //   ARM     evaluated together with `head_claim`, so the to-remote port is describing the
  //           claim and the live `is_initiator` is the right copy.
  //   RETRACT evaluated from `WriteFirstBusy` with no `head_claim` term -- the point is to drop
  //           a claim after the fact -- and by then the window has closed and the live port is
  //           showing the next frame or nothing. Use the copy latched when the claim was taken.
  logic not_receiving_chained_write;      // arm
  logic keep_claim_while_receiving;       // stay armed
  assign not_receiving_chained_write = ~SpuriousFinishGuard
                                     | ~receiving_chained_write
                                     | to_remote_data_accompany_cfg_i.is_initiator;
  assign keep_claim_while_receiving  = ~SpuriousFinishGuard
                                     | ~receiving_chained_write
                                     | to_remote_is_initiator_q;
  always_comb begin
    first_write_next_state = first_write_current_state;
    first_write_finish_valid = 1'b0;
    to_remote_dma_id_en = 1'b0;
    case (first_write_current_state)
      WriteFirstIdle: begin
        if (head_claim && not_receiving_chained_write) begin
          to_remote_dma_id_en = 1'b1;
          first_write_next_state = WriteFirstBusy;
        end
      end
      WriteFirstBusy: begin
        // Retract the claim as soon as the node proves it is only a hop. Without this the
        // guard is inert in the ordering the hardware produces, where the local reader --
        // and so the head-shaped transient -- leads the receive window by several cycles.
        if (!keep_claim_while_receiving) begin
          first_write_next_state = WriteFirstIdle;
        end else if (from_remote_finish_valid_i &&
                     from_remote_finish.dma_id == to_remote_dma_id_q) begin
          first_write_finish_valid = 1'b1;
          if (first_write_finish_ready) begin
            first_write_next_state = WriteFirstIdle;
          end else begin
            first_write_next_state = WriteFirstFinish;
          end
        end
      end
      WriteFirstFinish: begin
        first_write_finish_valid = 1'b1;
        if (first_write_finish_ready) begin
          first_write_next_state = WriteFirstIdle;
        end
      end
      default: begin
        first_write_next_state = WriteFirstIdle;
      end
    endcase
  end

  // Completion to the local core. Position in the chain says who must FORWARD a finish;
  // `is_initiator` says who must REPORT one. FSM2 (head) and FSM3's tail branch each offer
  // a completion, and only the one whose node owns the task is allowed through:
  //   ChainWrite  -- initiator is the head, so FSM2 reports and the tail stays quiet.
  //   ChainGather -- initiator is the collector at the tail, so FSM3 reports and the head
  //                  stays quiet, even though it is still the node that sourced the data.
  // Gating the OUTPUT rather than the FSM matters: a non-initiator head must still run
  // FSM2 to completion, because `xdma_write_finish_o` below is what releases its grant
  // credit. The backwards finish cascade is identical in both modes.
  //
  // Pinned to the ACCEPTED handshakes, not to the held valid levels -- the same discipline
  // `xdma_write_finish_o` below follows, and for the same reason.
  //
  // `xdma_finish_o` is one bit carrying no id and no count, so the frontend can only tell two
  // completions apart by counting assertions. FSM1's and FSM2's valids are LEVELS held until
  // their handshake, and the arbitration right below gives FSM3's single-cycle pulse priority
  // over both, so a completion that has to wait its turn stays asserted across the cycle it was
  // denied. Driven from the raw levels the output would then be high for two cycles whether one
  // task or two had retired -- one waveform for two counts, which no counting rule can read
  // correctly. Gating on the accepted handshake makes it exactly one cycle per retired task.
  // `tail_write_finish_valid` is already handshake-pinned, so it needs no extra term.
  logic tail_write_finish_valid;
  assign xdma_finish_o = (tail_write_finish_valid & from_remote_is_initiator_q)
                       | (read_finish_valid & read_finish_ready)
                       | (first_write_finish_valid & first_write_finish_ready
                          & to_remote_is_initiator_q);
  always_comb begin
    read_finish_ready = '0;
    first_write_finish_ready = '0;
    // The tail's completion is a single cycle pinned to the outgoing-finish handshake, so
    // it cannot wait its turn -- it takes the cycle, and the two level-held sources retry.
    if (tail_write_finish_valid) begin
      read_finish_ready = '0;
      first_write_finish_ready = '0;
    end else if (read_finish_valid) read_finish_ready = '1;
    else if (first_write_finish_valid) first_write_finish_ready = '1;
  end

  // Third FSM: Middle / Last Write
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      last_write_current_state <= WriteMiddleLastIdle;
    end else begin
      last_write_current_state <= last_write_next_state;
    end
  end

  logic middle_last_write_finish_valid;

  assign remote_addr_o = from_remote_addr_q;
  assign from_remote_dma_id_o = from_remote_dma_id_q;

  always_comb begin
    last_write_next_state = last_write_current_state;
    from_remote_dma_id_en = 1'b0;
    from_remote_addr_en = 1'b0;
    to_remote_finish_valid_o = 1'b0;
    middle_last_write_finish_valid = 1'b0;
    tail_write_finish_valid = 1'b0;

    case (last_write_current_state)
      WriteMiddleLastIdle: begin
        if (from_remote_data_accompany_cfg_i.dma_type && 
            from_remote_data_accompany_cfg_i.ready_to_transfer && 
            (~from_remote_data_accompany_cfg_i.is_first_cw) && 
            (~from_remote_data_accompany_cfg_i.is_last_cw)) begin
          from_remote_dma_id_en = 1'b1;
          from_remote_addr_en   = 1'b1;
          last_write_next_state = WriteMiddleBusy;
        end else if (from_remote_data_accompany_cfg_i.dma_type && 
                     from_remote_data_accompany_cfg_i.ready_to_transfer && 
                     (~from_remote_data_accompany_cfg_i.is_first_cw) && 
                     from_remote_data_accompany_cfg_i.is_last_cw) begin
          from_remote_dma_id_en = 1'b1;
          from_remote_addr_en   = 1'b1;
          last_write_next_state = WriteLastBusy;
        end
      end
      WriteMiddleBusy: begin
        if (from_remote_finish_valid_i && from_remote_finish.dma_id == from_remote_dma_id_q) begin
          last_write_next_state = SendToPreviousHop;
        end
      end
      WriteLastBusy: begin
        if (!from_remote_ctx_open) begin
          last_write_next_state = WriteLastFinish;
        end
      end
      WriteLastFinish: begin
        to_remote_finish_valid_o = 1'b1;
        if (to_remote_finish_ready_i) begin
          // The chain retires here. Offer a local completion too -- it only reaches the
          // core if this node owns the task (ChainGather's collector); for a ChainWrite
          // tail `is_initiator` is 0 and this is inert.
          tail_write_finish_valid = 1'b1;
          last_write_next_state   = WriteMiddleLastIdle;
        end
      end
      SendToPreviousHop: begin
        to_remote_finish_valid_o = 1'b1;
        if (to_remote_finish_ready_i) begin
          middle_last_write_finish_valid = 1'b1;
          last_write_next_state = WriteMiddleLastIdle;
        end
      end
      default: begin
        last_write_next_state = WriteMiddleLastIdle;
      end
    endcase
  end

  // Acknowledge a finish beat only if one of the two FSMs will actually act on it.
  //
  // The unconditional OR of the two busy states acked every beat that arrived while EITHER
  // FSM was waiting, id or no id. A beat carrying a different id -- one meant for the other
  // FSM, or for a task whose FSM has not armed yet -- therefore completed its handshake and
  // vanished, leaving whoever was waiting for it waiting forever: a chain that forms and
  // never retires. Holding instead makes that case a bounded stall the watchdog can name.
  // With neither FSM waiting an orphan beat is still drained, so a stray finish cannot back
  // up the shared narrow receive path.
  logic finish_for_middle, finish_for_head, no_finish_consumer;
  assign finish_for_middle = (last_write_current_state == WriteMiddleBusy)
                           & (from_remote_finish.dma_id == from_remote_dma_id_q);
  assign finish_for_head = (first_write_current_state == WriteFirstBusy)
                         & (from_remote_finish.dma_id == to_remote_dma_id_q);
  assign no_finish_consumer = (last_write_current_state != WriteMiddleBusy)
                            & (first_write_current_state != WriteFirstBusy);
  assign from_remote_finish_ready_o = finish_for_middle | finish_for_head | no_finish_consumer;
  // Assign xdma_write_finish_o signal
  // This signal is used to the grant_manager to release the reserved entry
  // There are two conditions to release the entry:
  // 1. The first write node (the first CW of a write task)
  // 2. The intermediate node in CW
  // Deliberately NOT gated by `is_initiator`: releasing a grant credit is a transport
  // obligation of every node that holds one, independent of who owns the task.
  //
  // Pinned to the ACCEPTED handshake, not to the held valid level. `grant_fifo_pop` in
  // `xdma_axi_adapter_top` is level-driven, so a `first_write_finish_valid` that has to wait
  // its turn behind `tail_write_finish_valid` or `read_finish_valid` -- it is held across
  // `WriteFirstFinish` until then -- would pop one credit per cycle it waited.
  // `middle_last_write_finish_valid` is already a single handshake-pinned cycle.
  assign xdma_write_finish_o = middle_last_write_finish_valid
                             | (first_write_finish_valid & first_write_finish_ready);

  //--------------------------------------
  // Bring-up stall watchdog
  //--------------------------------------
  // One watchdog per FSM: their busy states are independent, so a single OR of the three
  // *stall levels* would never rearm and would fire spuriously. OR the *errors* instead.
  // The waits being bounded here are the ones that hang a chain silently -- WriteFirstBusy
  // (head waiting for the finish to come back around the chain) and WriteMiddleBusy
  // (middle hop waiting for the next hop's finish) -- plus the read FSM for symmetry.
  logic read_stalled, first_write_stalled, last_write_stalled;
  logic read_stall_error, first_write_stall_error, last_write_stall_error;

  assign read_stalled = (read_current_state != ReadIdle) &&
                        (read_next_state == read_current_state);
  assign first_write_stalled = (first_write_current_state != WriteFirstIdle) &&
                               (first_write_next_state == first_write_current_state);
  assign last_write_stalled = (last_write_current_state != WriteMiddleLastIdle) &&
                              (last_write_next_state == last_write_current_state);

  xdma_stall_watchdog #(
      .Timeout(StallTimeout),
      .Name   ("xdma_finish_manager.read")
  ) i_read_stall_watchdog (
      .clk_i        (clk_i),
      .rst_ni       (rst_ni),
      .stalled_i    (read_stalled),
      .stall_error_o(read_stall_error)
  );

  xdma_stall_watchdog #(
      .Timeout(StallTimeout),
      .Name   ("xdma_finish_manager.first_write")
  ) i_first_write_stall_watchdog (
      .clk_i        (clk_i),
      .rst_ni       (rst_ni),
      .stalled_i    (first_write_stalled),
      .stall_error_o(first_write_stall_error)
  );

  xdma_stall_watchdog #(
      .Timeout(StallTimeout),
      .Name   ("xdma_finish_manager.middle_last_write")
  ) i_last_write_stall_watchdog (
      .clk_i        (clk_i),
      .rst_ni       (rst_ni),
      .stalled_i    (last_write_stalled),
      .stall_error_o(last_write_stall_error)
  );

  assign stall_error_o = read_stall_error | first_write_stall_error | last_write_stall_error;

endmodule
