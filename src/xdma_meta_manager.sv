// Authors:
// - Fanchen Kong <fanchen.kong@kuleuven.be>
// - Yunhao Deng <yunhao.deng@kuleuven.be>

/// This module tracks the handshake signal for the w 
// and output the trans_complete once the required data is sent to axi
// here we do not care on the b.valid

module xdma_meta_manager #(
    parameter type xdma_req_meta_t = logic,
    parameter type id_t            = logic,
    parameter type len_t           = logic,
    //Dependent parameter
    parameter int unsigned LenWidth = $bits(len_t)
) (
    /// Clock
    input  logic                        clk_i,
    /// Asynchronous reset, active low
    input  logic                        rst_ni,
    /// typedef struct packed {
    ///     id_t                                 dma_id;
    ///     len_t                                dma_length;
    /// } xdma_req_meta_t;     
    input  xdma_req_meta_t              write_req_meta_i,
    /// one req is start
    input  logic                        write_req_busy_i,
    /// Current transaction is done, valid for 1 CC
    output logic                        write_req_done_o,
    /// Current DMA ID
    output id_t                         cur_dma_id_o,
    /// AXI Handshake Signal
    input  logic                        write_happening_i
);

    logic counter_en;
    logic counter_clear;
    logic counter_load;
    len_t lens_counter_q;
    counter #(
        .WIDTH($bits(len_t))
    ) i_lens_counter(
        .clk_i     (clk_i              ),
        .rst_ni    (rst_ni             ),
        .clear_i   (counter_clear      ),
        .en_i      (counter_en         ),
        .load_i    (counter_load       ),
        .down_i    (1'b1               ),
        .d_i       (write_req_meta_i.dma_length),
        .q_o       (lens_counter_q     ),
        .overflow_o()
    );

    typedef enum logic [1:0] {
        IDLE,
        BUSY,
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

    // Next state logic
    always_comb begin : proc_next_state_logic
        next_state = cur_state;
        case (cur_state)
            IDLE:   if (write_req_busy_i      ) next_state = BUSY;
            BUSY:   if (lens_counter_q=='0    ) next_state = FINISH;
            FINISH: next_state = IDLE;
        endcase
    end

    // Output logic
    always_comb begin : proc_output_logic
        counter_en = 1'b0;
        counter_clear = 1'b0;
        counter_load = 1'b0;
        write_req_done_o = 1'b0;
        cur_dma_id_o = 1'b0;
        case (cur_state)
            IDLE: begin
                counter_en = 1'b0;
                counter_clear = 1'b0;
                if (write_req_busy_i) counter_load = 1'b1;
                write_req_done_o = 1'b0;
                cur_dma_id_o = 1'b0;
            end
            BUSY: begin
                counter_en = write_happening_i;
                counter_clear = 1'b0;
                counter_load = 1'b0;
                write_req_done_o = (lens_counter_q=='0);
                cur_dma_id_o = write_req_meta_i.dma_id;
            end
            FINISH: begin
                counter_en = 1'b0;
                counter_clear = 1'b1;
                counter_load = 1'b0;
                write_req_done_o = 1'b0;
                cur_dma_id_o = '0;
            end
        endcase
    end



    // //--------------------------------------
    // // Req Meta fifo
    // //--------------------------------------
    // // Right 
    // xdma_req_meta_t cur_req_meta;
    // logic req_meta_fifo_full;
    // logic req_meta_fifo_empty;
    // logic req_meta_fifo_push;
    // logic req_meta_fifo_pop;
    // // FIFO acting like a reg
    // // leave here for future extensibility
    // fifo_v3 #(
    //     .DEPTH(1),
    //     .dtype(xdma_req_meta_t)
    // ) i_req_meta_queue (
    //     .clk_i     (clk_i                ),
    //     .rst_ni    (rst_ni               ),
    //     .flush_i   (1'b0                 ),
    //     .testmode_i(1'b0                 ),
    //     .full_o    (req_meta_fifo_full   ),
    //     .empty_o   (req_meta_fifo_empty  ),
    //     .usage_o   (                     ),
    //     .data_i    (write_req_meta_i     ),
    //     .push_i    (req_meta_fifo_push   ),
    //     .data_o    (cur_req_meta         ),
    //     .pop_i     (req_meta_fifo_pop    )
    // );
    // assign req_meta_fifo_push = write_req_busy_i && !req_meta_fifo_full;
    
    // assign cur_dma_id_o = cur_req_meta.dma_id;
    // //--------------------------------------
    // // Transfer Counter
    // //--------------------------------------
    // // Here we use a counter to track the handshake signal from the W
    // logic clear_counter;
    // logic en_counter;
    // len_t counter_q;

    // counter #(
    //     .WIDTH (LenWidth)
    // ) i_trans_counter (
    //     .clk_i       ( clk_i              ),
    //     .rst_ni      ( rst_ni             ),
    //     .clear_i     ( clear_counter      ),
    //     .en_i        ( en_counter         ),
    //     .load_i      ( '0                 ),
    //     .down_i      ( '0                 ),
    //     .d_i         ( '0                 ),
    //     .q_o         ( counter_q          ),
    //     .overflow_o  (                    )
    // );
    // assign en_counter = write_happening_i && !req_meta_fifo_empty;
    // assign clear_counter = (counter_q==cur_req_meta.dma_length) && !req_meta_fifo_empty;
    // assign write_req_done_o = clear_counter;

    // assign req_meta_fifo_pop = clear_counter;
endmodule