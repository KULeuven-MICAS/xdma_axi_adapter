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
    /// Belt-and-braces guard against the ChainGather spurious-finish hazard.
    ///
    /// FSM2 below decides "I am the head of a chained write" purely from the *to-remote*
    /// accompany cfg (`dma_type & ready_to_transfer & is_first_cw & ~is_last_cw`). In
    /// ChainWrite a middle node's reader never runs, so that branch is dead there. In
    /// ChainGather a middle node's reader *does* run concurrently, and the Chisel side
    /// derives `toRemoteAccompaniedCfg.readyToTransfer` from `readerBusy`
    /// (`XDMADataPath.scala`) while `is_first_cw` reads 1 for a locally-originated reader
    /// (`XDMACfgIO.scala`). If `readerBusy` rises even one cycle before the chained-write
    /// condition, FSM2 latches `to_remote_dma_id_q`, enters WriteFirstBusy, waits forever
    /// for an id-matched finish that is addressed to the real head, and eventually raises
    /// a spurious `xdma_finish_o` at the middle node's core.
    ///
    /// With this parameter set, FSM2 additionally requires that this node is *not*
    /// currently receiving a chained write -- a node taking delivery of one is by
    /// definition not that chain's head.
    ///
    /// Default OFF: the primary fix belongs in Chisel (widen the
    /// `toRemoteAccompaniedCfg` mux to cover the whole reader-busy window at a gather
    /// node), and turning this on unconditionally would also block a node that is
    /// legitimately the head of one task while receiving an unrelated chained write.
    /// Enable it as a backstop during bring-up if the Chisel fix proves fiddly.
    parameter bit          SpuriousFinishGuard                   = 1'b0,
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
  logic to_remote_dma_id_en, from_remote_dma_id_en, from_remote_addr_en;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      to_remote_dma_id_q        <= '0;
      from_remote_dma_id_q      <= '0;
      from_remote_addr_q        <= '0;
      to_remote_is_initiator_q  <= 1'b0;
      from_remote_is_initiator_q <= 1'b0;
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
    end
  end

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
    case (read_current_state)
      ReadIdle: begin
        if ((~from_remote_data_accompany_cfg_i.dma_type) && from_remote_data_accompany_cfg_i.ready_to_transfer) begin
          read_next_state = ReadBusy;
        end
      end
      ReadBusy: begin
        if (~from_remote_data_accompany_cfg_i.ready_to_transfer) begin
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
  // See `SpuriousFinishGuard` above: when enabled, a node that is currently taking
  // delivery of a chained write cannot be mistaken for that chain's head.
  logic not_receiving_chained_write;
  assign not_receiving_chained_write =
      ~SpuriousFinishGuard | ~from_remote_data_accompany_cfg_i.ready_to_transfer;
  always_comb begin
    first_write_next_state = first_write_current_state;
    first_write_finish_valid = 1'b0;
    to_remote_dma_id_en = 1'b0;
    case (first_write_current_state)
      WriteFirstIdle: begin
        if (to_remote_data_accompany_cfg_i.dma_type &&
        to_remote_data_accompany_cfg_i.ready_to_transfer &&
        to_remote_data_accompany_cfg_i.is_first_cw &&
        (~to_remote_data_accompany_cfg_i.is_last_cw) &&
        not_receiving_chained_write) begin
          to_remote_dma_id_en = 1'b1;
          first_write_next_state = WriteFirstBusy;
        end
      end
      WriteFirstBusy: begin
        if (from_remote_finish_valid_i && from_remote_finish.dma_id == to_remote_dma_id_q) begin
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
  logic tail_write_finish_valid;
  assign xdma_finish_o = (tail_write_finish_valid & from_remote_is_initiator_q)
                       | read_finish_valid
                       | (first_write_finish_valid & to_remote_is_initiator_q);
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
        if (~from_remote_data_accompany_cfg_i.ready_to_transfer) begin
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

  // Assign from_remote_finish_ready_o signal
  assign from_remote_finish_ready_o = last_write_current_state == WriteMiddleBusy | first_write_current_state == WriteFirstBusy;
  // Assign xdma_write_finish_o signal
  // This signal is used to the grant_manager to release the reserved entry
  // There are two conditions to release the entry:
  // 1. The first write node (the first CW of a write task)
  // 2. The intermediate node in CW
  // Deliberately NOT gated by `is_initiator`: releasing a grant credit is a transport
  // obligation of every node that holds one, independent of who owns the task.
  assign xdma_write_finish_o = middle_last_write_finish_valid | first_write_finish_valid;

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
