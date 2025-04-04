// Authors:
// - Fanchen Kong <fanchen.kong@kuleuven.be>
// - Yunhao Deng <yunhao.deng@kuleuven.be>

/// This module tracks the handshake signal of the
/// from_remote_data 
//  to_remote_data
module xdma_finish_manager #(
    parameter type id_t                                  = logic,
    parameter type len_t                                 = logic,
    parameter type addr_t                                = logic,
    parameter type data_t                                = logic,
    parameter type xdma_to_remote_data_accompany_cfg_t   = logic,
    parameter type xdma_from_remote_data_accompany_cfg_t = logic,
    parameter type xdma_req_desc_t                       = logic,
    parameter type xdma_to_remote_finish_t               = logic,
    parameter type xdma_from_remote_finish_t             = logic,
    //Dependent parameter
    parameter int unsigned LenWidth = $bits(len_t)
) (
    /// Clock
    input  logic                                 clk_i,
    /// Asynchronous reset, active low
    input  logic                                 rst_ni,
    /// Cluster Base addr
    input  addr_t                                cluster_base_addr_i,
    /// Status Signal
    output logic                                 xdma_finish_o,
    /// to remote
    input  xdma_to_remote_data_accompany_cfg_t   to_remote_data_accompany_cfg_i,
    /// from remote accompany cfg
    input  xdma_from_remote_data_accompany_cfg_t from_remote_data_accompany_cfg_i,
    input  logic                                 from_remote_data_happening_i,
    /// from remote finish
    input  data_t                                from_remote_finish_i,
    input  logic                                 from_remote_finish_valid_i,
    output logic                                 from_remote_finish_ready_o,

    output xdma_to_remote_finish_t               to_remote_finish_o,
    output logic                                 to_remote_finish_valid_o,
    input  logic                                 to_remote_finish_ready_i,
    output xdma_req_desc_t                       to_remote_finish_desc_o
    // typedef struct packed {
    //     id_t                                 dma_id; 
    //     logic                                dma_type;
    //     addr_t                               src_addr;
    //     addr_t                               dst_addr;
    //     len_t                                dma_length;
    //     logic                                ready_to_transfer;
    // } xdma_accompany_cfg_t;   
);

    // Status
    typedef enum logic [3:0] {
        IDLE,
        READ_BUSY,
        WRITE_FIRST_BUSY,
        WRITE_LAST_BUSY,
        WRITE_MIDDLE_BUSY,
        SEND_FINISH_TO_PREV_HOP,
        FINISH
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



    //-------------------------------------
    // FF to hold from remote dma id and addr
    //-------------------------------------
    logic reg_load;
    logic reg_clear;
    id_t from_remote_dma_id_q, from_remote_dma_id_d;
    addr_t remote_addr_q, remote_addr_d;
    assign from_remote_dma_id_d = from_remote_data_accompany_cfg_i.dma_id;
    assign remote_addr_d = from_remote_data_accompany_cfg_i.src_addr;
    always_ff @(posedge clk_i, negedge rst_ni) begin
        if (!rst_ni) begin
            from_remote_dma_id_q <= '0;
            remote_addr_q <= '0;
        end else begin
            if (reg_clear) begin
                from_remote_dma_id_q <= '0;
                remote_addr_q <= '0;
            end else if (reg_load) begin 
                from_remote_dma_id_q <= from_remote_dma_id_d;
                remote_addr_q <= remote_addr_d;
            end  
        end
    end
    //-------------------------------------
    // FF to hold from to remote data dma_id
    //-------------------------------------    
    id_t to_remote_dma_id_q, to_remote_dma_id_d;

    assign to_remote_dma_id_d = to_remote_data_accompany_cfg_i.dma_id;
    always_ff @(posedge clk_i, negedge rst_ni) begin
        if (!rst_ni) begin
            to_remote_dma_id_q <= '0;
        end else begin
            if (reg_clear) begin
                to_remote_dma_id_q <= '0;
            end else if (reg_load) begin 
                to_remote_dma_id_q <= to_remote_dma_id_d;
            end  
        end
    end


    //-------------------------------------
    // Receive FINISH FIFO
    //-------------------------------------
    // This temp is the structure converter from data_t to xdma_to_remote_grant_t
    xdma_pkg::xdma_to_remote_finish_t from_remote_finish_tmp;
    assign from_remote_finish_tmp = from_remote_finish_i;

    xdma_from_remote_finish_t receive_finish;
    always_comb begin : proc_unpack_received_finish
        receive_finish.dma_id = from_remote_finish_tmp.dma_id;
        receive_finish.from = from_remote_finish_tmp.from;
    end
    logic finish_fifo_full;
    logic finish_fifo_empty;
    logic finish_fifo_push;
    logic finish_fifo_pop;
    xdma_from_remote_finish_t receive_finish_cur;
    logic remote_finish;
    fifo_v3 #(
        .dtype(xdma_from_remote_finish_t),
        .DEPTH(3)
    ) i_xdma_receive_finish_fifo (
        .clk_i     (clk_i),
        .rst_ni    (rst_ni),
        .flush_i   (1'b0),
        .testmode_i(1'b0),
        .full_o    (finish_fifo_full),
        .empty_o   (finish_fifo_empty),
        .usage_o   (),
        .data_i    (receive_finish),
        .push_i    (finish_fifo_push),
        .data_o    (receive_finish_cur),
        .pop_i     (finish_fifo_pop)
    );
    logic is_local_dma_id;
    assign is_local_dma_id = (cur_state==WRITE_FIRST_BUSY)? (receive_finish_cur.dma_id==to_remote_dma_id_q) : (receive_finish_cur.dma_id==from_remote_dma_id_q);
    logic pop_fifo;
    assign pop_fifo = (cur_state==WRITE_FIRST_BUSY)? remote_finish: (to_remote_finish_valid_o&&to_remote_finish_ready_i);

    assign remote_finish = !finish_fifo_empty && is_local_dma_id;
    assign finish_fifo_pop = !finish_fifo_empty && pop_fifo;
    assign from_remote_finish_ready_o = !finish_fifo_full;
    assign finish_fifo_push = from_remote_finish_valid_i && !finish_fifo_full;    





    logic len_counter_en;
    logic len_counter_clear;
    logic len_counter_load;
    len_t len_counter_d;
    len_t len_counter_q;
    assign len_counter_d = from_remote_data_accompany_cfg_i.dma_length;
    counter #(
        .WIDTH($bits(len_t))
    ) i_len_counter(
        .clk_i     (clk_i             ),
        .rst_ni    (rst_ni            ),
        .clear_i   (len_counter_clear ),
        .en_i      (len_counter_en    ),
        .load_i    (len_counter_load  ),
        .down_i    (1'b1              ),
        .d_i       (len_counter_d     ),
        .q_o       (len_counter_q     ),
        .overflow_o()
    );
    logic local_finish;
    logic is_read;
    logic is_write_last;
    logic is_write_first;
    assign local_finish = (len_counter_q=='0);
    assign is_read =        (from_remote_data_accompany_cfg_i.dst_addr == cluster_base_addr_i) && 
                            (from_remote_data_accompany_cfg_i.dma_type == 1'b0) &&
                            from_remote_data_accompany_cfg_i.ready_to_transfer;

    assign is_write_first = (to_remote_data_accompany_cfg_i.src_addr == cluster_base_addr_i) && 
                            (to_remote_data_accompany_cfg_i.dma_type == 1'b1) &&
                            to_remote_data_accompany_cfg_i.ready_to_transfer;

    assign is_write_last = (from_remote_data_accompany_cfg_i.dst_addr == cluster_base_addr_i) && 
                           (from_remote_data_accompany_cfg_i.dma_type == 1'b1) &&
                           from_remote_data_accompany_cfg_i.ready_to_transfer;

    logic valid_to_send_finish;


    // Next state logic
    always_comb begin : proc_next_state_logic
        next_state = cur_state;
        case (cur_state)
            IDLE: begin
                                     if (is_read)             next_state = READ_BUSY;
                                     if (is_write_first)      next_state = WRITE_FIRST_BUSY;
                                     if (is_write_last)       next_state = WRITE_LAST_BUSY;
            end              
            READ_BUSY:               if (local_finish)        next_state = FINISH;

            WRITE_FIRST_BUSY:        if(remote_finish)        next_state = FINISH;
            WRITE_LAST_BUSY: begin
                                     if(to_remote_data_accompany_cfg_i.ready_to_transfer) next_state = WRITE_MIDDLE_BUSY;
                                     if(local_finish)         next_state = SEND_FINISH_TO_PREV_HOP;
            end
            WRITE_MIDDLE_BUSY:       if(remote_finish)        next_state = SEND_FINISH_TO_PREV_HOP;
            SEND_FINISH_TO_PREV_HOP: if(to_remote_finish_valid_o&&to_remote_finish_ready_i) next_state = FINISH;
            FINISH:                                           next_state = IDLE;
        endcase
    end    

    // Output logic
    always_comb begin : proc_output_logic
        len_counter_en = 1'b0;
        len_counter_clear = 1'b0;
        len_counter_load = 1'b0;
        reg_load = 1'b0;
        reg_clear = 1'b0;
        xdma_finish_o = 1'b0;
        valid_to_send_finish = 1'b0;
        case (cur_state)
            IDLE: begin
                len_counter_en = 1'b0;
                len_counter_clear = 1'b0;
                if(from_remote_data_accompany_cfg_i.ready_to_transfer) begin 
                    len_counter_load = 1'b1;
                    reg_load = 1'b1;
                end
                if(to_remote_data_accompany_cfg_i.ready_to_transfer) begin
                    len_counter_load = 1'b0;
                    reg_load = 1'b1;
                end
                reg_clear = 1'b0;
                xdma_finish_o = 1'b0;
                valid_to_send_finish = 1'b0;                
            end
            READ_BUSY: begin
                len_counter_en = from_remote_data_happening_i;
                len_counter_clear = 1'b0;
                len_counter_load = 1'b0;
                reg_load = 1'b0;
                reg_clear = 1'b0;
                xdma_finish_o = 1'b0;
                valid_to_send_finish = 1'b0; 
            end
            WRITE_FIRST_BUSY: begin
                len_counter_en = 1'b0;
                len_counter_clear = 1'b0;
                len_counter_load = 1'b0;
                reg_load = 1'b0;
                reg_clear = 1'b0;
                xdma_finish_o = 1'b0;
                valid_to_send_finish = 1'b0;
            end
            WRITE_LAST_BUSY: begin
                // The last hop needs to count the data handshake
                len_counter_en = from_remote_data_happening_i;
                len_counter_clear = 1'b0;
                len_counter_load = 1'b0;
                reg_load = 1'b0;
                reg_clear = 1'b0;
                xdma_finish_o = 1'b0;
                valid_to_send_finish = 1'b0; 
            end
            WRITE_MIDDLE_BUSY: begin
                // The middle hop do not have to count the handshake
                // it only wait the next hop to be done
                len_counter_en = 1'b0;
                len_counter_clear = 1'b1;
                len_counter_load = 1'b0;
                reg_load = 1'b0;
                reg_clear = 1'b0;
                xdma_finish_o = 1'b0;
                valid_to_send_finish = 1'b0; 
            end
            SEND_FINISH_TO_PREV_HOP: begin
                len_counter_en = 1'b0;
                len_counter_clear = 1'b0;
                len_counter_load = 1'b0;
                reg_load = 1'b0;
                reg_clear = 1'b0;
                xdma_finish_o = 1'b0;
                valid_to_send_finish = 1'b1; 
            end
            FINISH: begin
                len_counter_en = 1'b0;
                len_counter_clear = 1'b1;
                len_counter_load = 1'b0;
                reg_clear = 1'b1;
                reg_load = 1'b0;
                xdma_finish_o = 1'b1;
                valid_to_send_finish = 1'b0;
            end
        endcase
    end

    // to remote finish composition
    always_comb begin : proc_to_remote_finish
        to_remote_finish_o = '0;
        to_remote_finish_o.dma_id = from_remote_dma_id_q;
        to_remote_finish_o.from = cluster_base_addr_i;
        to_remote_finish_valid_o = valid_to_send_finish;
        to_remote_finish_desc_o.dma_id = from_remote_dma_id_q;
        to_remote_finish_desc_o.dma_type = 1'b1; // write
        to_remote_finish_desc_o.remote_addr = (remote_addr_q>=xdma_pkg::MainMemBaseAddr)? xdma_pkg::MainMemEndAddr-xdma_pkg::MMIOFinishOffset : xdma_pkg::get_cluster_end_addr(remote_addr_q)-xdma_pkg::MMIOFinishOffset;
        to_remote_finish_desc_o.dma_length = 1;
        to_remote_finish_desc_o.ready_to_transfer = valid_to_send_finish;
    end



endmodule