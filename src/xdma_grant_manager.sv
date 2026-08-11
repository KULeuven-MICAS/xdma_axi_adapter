// Fanchen Kong <fanchen.kong@kuleuven.be>
// Yunhao Deng <yunhao.deng@kuleuven.be>

module xdma_grant_manager #(
    parameter type xdma_from_remote_data_accompany_cfg_t = logic
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
    input  logic                                 to_remote_grant_ready_i
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
      // 5 states in a 3-bit encoding leave 3 unused. This arm keeps them from being
      // absorbing: `next_state = cur_state` above would trap an upset here forever,
      // and every future grant with it.
      default: next_state = IDLE;
    endcase
  end

  // Output logic
  always_comb begin : proc_output_logic
    to_remote_grant_valid_o = 1'b0;
    case (cur_state)
      IDLE: to_remote_grant_valid_o = 1'b0;
      WRITE_LAST: to_remote_grant_valid_o = 1'b0;
      WRITE_MIDDLE: to_remote_grant_valid_o = 1'b0;
      // Unconditional, so VALID holds until the sink takes it. It must NOT be qualified by
      // `grant_valid`, which follows `ready_to_transfer` -- a live external level (the
      // receiving datapath's writerBusy) that can fall at any time. A VALID that retracts
      // after the narrow req_manager has arbitrated this input breaks AXI-stream stability
      // and loses the grant, leaving this FSM here (its only exit is the handshake) and the
      // req_manager in BUSY (its only exit is a beat count nothing will now produce), which
      // takes the whole narrow port down with it, cfg and finish included. The payload is
      // frozen over the same window in xdma_axi_adapter_top.
      SEND_GRANT_TO_PREV_HOP: to_remote_grant_valid_o = 1'b1;
      WAIT_FINISH: to_remote_grant_valid_o = 1'b0;
      default: to_remote_grant_valid_o = 1'b0;
    endcase
  end
endmodule
