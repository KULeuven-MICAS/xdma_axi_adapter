// Authors:
// - Fanchen Kong <fanchen.kong@kuleuven.be>
// - Yunhao Deng <yunhao.deng@kuleuven.be>
module dw_down_converter #(
    parameter int unsigned INPUT_DW  = 512,
    parameter int unsigned OUTPUT_DW = 64,
    // Dependent parameters, DO NOT OVERRIDE!
    parameter int unsigned DOWN_RATIO = INPUT_DW / OUTPUT_DW
) (
    input  logic                 clk,
    input  logic                 rst_ni,
    input  logic [INPUT_DW-1:0]  data_i,
    input  logic                 valid_i,
    output logic                 ready_o,
    output logic [OUTPUT_DW-1:0] data_o,
    output logic                 valid_o,
    input  logic                 ready_i
);

    // Counter width must be at least $clog2(DOWN_RATIO)
    localparam int unsigned CNT_WIDTH = $clog2(DOWN_RATIO);

    logic [CNT_WIDTH-1:0] count_q;
    logic                 counter_en, counter_clr, counter_load, counter_down;
    logic [CNT_WIDTH-1:0] counter_d;
    logic                 counter_overflow;

    logic [OUTPUT_DW-1:0] buffer_q;
    logic                 buffer_valid_q, buffer_load;

    // Counter instantiation
    counter #(
        .WIDTH(CNT_WIDTH),
        .STICKY_OVERFLOW(1'b0)
    ) u_counter (
        .clk_i       (clk),
        .rst_ni      (rst_ni),
        .clear_i     (counter_clr),
        .en_i        (counter_en),
        .load_i      (counter_load),
        .down_i      (counter_down),
        .d_i         (counter_d),
        .q_o         (count_q),
        .overflow_o  (counter_overflow)
    );

    // Load data into internal buffer
    assign buffer_load = valid_i && ready_o;

    always_ff @(posedge clk or negedge rst_ni) begin
        if (!rst_ni) begin
            buffer_q        <= '0;
            buffer_valid_q  <= 1'b0;
        end else if (buffer_load) begin
            buffer_q        <= data_i;
            buffer_valid_q  <= 1'b1;
        end else if (counter_clr) begin
            buffer_valid_q  <= 1'b0;
        end
    end

    // Output logic
    assign data_o = buffer_q[INPUT_DW * count_q +: INPUT_DW];
    assign valid_o = buffer_valid_q;

    // Handshake control
    assign ready_o = !buffer_valid_q || (valid_o && ready_i && (count_q == DOWN_RATIO - 1));

    // Counter control
    always_comb begin
        counter_en   = valid_o && ready_i;
        counter_clr  = counter_en && (count_q == DOWN_RATIO - 1);
        counter_load = 1'b0;
        counter_d    = '0;
        counter_down = 1'b0;
    end

    initial begin
        assert (INPUT_DW % OUTPUT_DW == 0)
            else $fatal("INPUT_DW must be an integer multiple of OUTPUT_DW.");
    end
endmodule