`timescale 1ns/1ps

module tb_find_first_one_idx();


parameter TEST_WIDTH = 3;
localparam CLK_PERIOD = 10;


logic [TEST_WIDTH-1:0] in_i;
logic [$clog2(TEST_WIDTH>1?TEST_WIDTH:1)-1:0] idx_o;
logic valid_o;
logic [TEST_WIDTH-1:0] random_val;
int expected_idx;
find_first_one_idx #(
    .N(TEST_WIDTH)
) dut (
    .in_i(in_i),
    .idx_o(idx_o),
    .valid_o(valid_o)
);


initial begin
    $display("\n[INFO] Starting testbench for N=%0d", TEST_WIDTH);
    // Test case 1: All zero
    in_i = {TEST_WIDTH{1'b0}};
    #CLK_PERIOD;
    check_output(.expected_valid(0), 
                 .expected_idx(0),
                 .case_num(1)
    );

    // Test case 2: Single Bit
    for (int i=0; i<TEST_WIDTH; i++) begin
        in_i = (1 << i);
        #CLK_PERIOD;
        check_output(.expected_valid(1),
                     .expected_idx(i),
                     .case_num(200+i)
        );
    end

    // Test case 3: Multi-bit
    if (TEST_WIDTH > 1) begin
        // Lower bit 
        in_i = {TEST_WIDTH{1'b1}};
        #CLK_PERIOD;
        check_output(.expected_valid(1),
                     .expected_idx(0),
                     .case_num(3)
        );

        // Middle bit
        in_i = (1 << (TEST_WIDTH-1)) | 1;
        #CLK_PERIOD;
        check_output(.expected_valid(1),
                     .expected_idx(0),
                     .case_num(4)
        );
    end

    // Test case 4: Random test
    repeat(10) begin
        random_val = $urandom_range(0, (1<<TEST_WIDTH)-1);
        in_i = random_val;
        #CLK_PERIOD;
        expected_idx = get_expected_index(random_val);
        check_output(.expected_valid(|random_val),
                     .expected_idx(expected_idx),
                     .case_num(500+$urandom_range(0,99))
        );
    end

    $display("\n[PASS] All testcases completed successfully!");
    $finish;
end


task check_output(input bit expected_valid, 
                  input int expected_idx,
                  input int case_num);
    if (TEST_WIDTH == 1) begin
        if (valid_o !== |in_i) begin
            $error("[Case%0d] valid_o error! Input=%b, Got=%b, Expected=%b",
                   case_num, in_i, valid_o, |in_i);
            $finish;
        end
        if (valid_o && (idx_o !== 0)) begin
            $error("[Case%0d] idx_o error! Input=%b, Got=%0d, Expected=0",
                   case_num, in_i, idx_o);
            $finish;
        end
    end
    else begin
        if (valid_o !== expected_valid) begin
            $error("[Case%0d] valid_o error! Input=%b, Got=%b, Expected=%b",
                   case_num, in_i, valid_o, expected_valid);
            $finish;
        end
        if (valid_o && (idx_o !== expected_idx)) begin
            $error("[Case%0d] idx_o error! Input=%b, Got=%0d, Expected=%0d",
                   case_num, in_i, idx_o, expected_idx);
            $finish;
        end
    end
endtask


function int get_expected_index(logic [TEST_WIDTH-1:0] val);
    for (int i=0; i<TEST_WIDTH; i++) begin
        if (val[i]) return i;
    end
    return 0;
endfunction

endmodule