// Fanchen Kong <fanchen.kong@kuleuven.be>
// Yunhao Deng <yunhao.deng@kuleuven.be>

module xdma_grant_manager #(
    parameter type xdma_from_remote_data_accompany_cfg_t = logic
) (
    /// Clock
    input logic clk_i,
    /// Asynchronous reset, active low
    input logic rst_ni,

    input  xdma_from_remote_data_accompany_cfg_t xdma_from_remote_data_accompany_cfg_i,
    ///
    output logic                                 xdma_to_remote_grant_valid_o,
    ///
    input  logic                                 xdma_to_remote_grant_ready_i
);
  logic grant_valid;
  logic grant_happening;
  assign grant_valid = xdma_from_remote_data_accompany_cfg_i.ready_to_transfer && xdma_from_remote_data_accompany_cfg_i.dma_type;
  assign grant_happening = xdma_to_remote_grant_valid_o && xdma_to_remote_grant_ready_i;
  typedef enum logic [1:0] {
    IDLE,
    SEND_GRANT,
    WAIT_FINISH
  } state_t;

  state_t cur_state, next_state;
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
      IDLE:        if (grant_valid) next_state = SEND_GRANT;
      SEND_GRANT:  if (grant_happening) next_state = WAIT_FINISH;
      WAIT_FINISH: if (grant_valid == 1'b0) next_state = IDLE;
    endcase
  end

  // Output logic
  always_comb begin : proc_output_logic
    xdma_to_remote_grant_valid_o = 1'b0;
    case (cur_state)
      IDLE: begin
        xdma_to_remote_grant_valid_o = 1'b0;
      end
      SEND_GRANT: begin
        xdma_to_remote_grant_valid_o = grant_valid;
      end
      WAIT_FINISH: begin
        xdma_to_remote_grant_valid_o = 1'b0;
      end
    endcase
  end
endmodule
