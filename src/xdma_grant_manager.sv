// Fanchen Kong <fanchen.kong@kuleuven.be>
// Yunhao Deng <yunhao.deng@kuleuven.be>

module xdma_grant_manager #(
    parameter type addr_t                                = logic,
    parameter type xdma_from_remote_data_accompany_cfg_t = logic,
    parameter type xdma_to_remote_grant_t                = logic,
    parameter type xdma_req_desc_t                       = logic
) (
    /// Clock
    input  logic                                 clk_i,
    /// Asynchronous reset, active low
    input  logic                                 rst_ni,

    input  addr_t                                cluster_base_addr_i,
    /// 
    input xdma_from_remote_data_accompany_cfg_t  xdma_from_remote_data_accompany_cfg_i,
    ///
    output xdma_req_desc_t                       xdma_to_remote_grant_desc_o,
    ///
    output xdma_to_remote_grant_t                xdma_to_remote_grant_o,
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
            IDLE:        if (grant_valid           ) next_state = SEND_GRANT;
            SEND_GRANT:  if (grant_happening       ) next_state = WAIT_FINISH;
            WAIT_FINISH: if (grant_valid==1'b0     ) next_state = IDLE;
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

    //--------------------------------------
    // Unpack the to_remote_grant
    //--------------------------------------
    always_comb begin : proc_unpack_to_remote_grant
        //--------------------------------------
        // Description
        //--------------------------------------   
        xdma_to_remote_grant_desc_o.dma_id           = xdma_from_remote_data_accompany_cfg_i.dma_id;
        xdma_to_remote_grant_desc_o.dma_length       = 1;
        xdma_to_remote_grant_desc_o.dma_type         = xdma_from_remote_data_accompany_cfg_i.dma_type;
        xdma_to_remote_grant_desc_o.remote_addr      = (xdma_from_remote_data_accompany_cfg_i.src_addr>=xdma_pkg::MainMemBaseAddr)? xdma_pkg::MainMemEndAddr-xdma_pkg::MMIOGrantOffset : xdma_pkg::get_cluster_end_addr(xdma_from_remote_data_accompany_cfg_i.src_addr)-xdma_pkg::MMIOGrantOffset;
        xdma_to_remote_grant_desc_o.ready_to_transfer= xdma_from_remote_data_accompany_cfg_i.ready_to_transfer;

        //--------------------------------------
        // Data
        //--------------------------------------  
        // The to_remote_grant is unpakced from the from_remote_data_accompany_cfg_i
        // Task id
        xdma_to_remote_grant_o.dma_id = xdma_from_remote_data_accompany_cfg_i.dma_id;
        // the grant signal also have the info on the grant initiator
        xdma_to_remote_grant_o.from = xdma_from_remote_data_accompany_cfg_i.src_addr;
        // the rest is not in use
        xdma_to_remote_grant_o.reserved = '0;
    end
endmodule