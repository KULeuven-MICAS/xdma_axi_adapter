`timescale 1ns/1ps
module tb_xdma_meta_manager();
    // Standalone-test mirror of the adapter's parameter knobs (xdma_pkg
    // has been retired; this tb owns its own protocol typedefs).
    localparam int unsigned TbMaxMemSizeKiB  = 32'd4096;
    localparam int unsigned TbWordlineWidth  = 32'd64;
    localparam int unsigned TbXDMAIdWidth     = 32'd4;
    localparam int unsigned TbDMALengthWidth =
        $clog2(TbMaxMemSizeKiB) + 10 - $clog2(TbWordlineWidth/8);
    typedef logic [TbXDMAIdWidth-1:0]     tb_id_t;
    typedef logic [TbDMALengthWidth-1:0] tb_len_t;
    typedef struct packed {
      tb_id_t  dma_id;
      tb_len_t dma_length;
    } tb_xdma_req_meta_t;
      // DUT signals
    logic clk;
    logic rst_n;
    localparam time CyclTime = 10ns;
    localparam time ApplTime =  2ns;
    localparam time TestTime =  8ns;
    //-----------------------------------
    // Clock generator
    //-----------------------------------
    clk_rst_gen #(
        .ClkPeriod    ( CyclTime ),
        .RstClkCycles ( 5        )
    ) i_clk_gen (
        .clk_o (clk),
        .rst_no(rst_n)
    );
    tb_xdma_req_meta_t write_req_meta;
    logic write_req_busy;
    logic write_req_done;
    tb_id_t cur_dma_id;
    logic write_happening;
    xdma_meta_manager #(
        .xdma_req_meta_t(tb_xdma_req_meta_t),
        .id_t           (tb_id_t),
        .len_t          (tb_len_t)
    ) i_xdma_meta_manager (
        .clk_i     (clk              ),
        .rst_ni    (rst_n            ),       
        .write_req_meta_i(write_req_meta),
        .write_req_busy_i(write_req_busy),
        .write_req_done_o(write_req_done),
        .cur_dma_id_o    (cur_dma_id),
        .write_happening_i(write_happening) 
    );
task cycle_start;
    #TestTime;
endtask

task cycle_end;
    @(posedge clk);
endtask 

task automatic rand_wait(input int unsigned min, max);
    int unsigned rand_success, cycles;
    rand_success = std::randomize(cycles) with {
    cycles >= min;
    cycles <= max;
    };
    assert (rand_success) else $error("Failed to randomize wait cycles!");
    repeat (cycles) @(posedge clk);
endtask

task automatic reset_input();
    write_req_meta <= #ApplTime '0;
    write_req_busy <= #ApplTime '0;
    write_happening <= #ApplTime '0;
endtask




initial begin
    reset_input();
    rand_wait(20,20);
    write_req_meta.dma_id <= #ApplTime 'd88;
    write_req_meta.dma_length <= #ApplTime 'd1;
    rand_wait(1,5);
    write_req_busy <= #ApplTime 1'b1;
    rand_wait(1,5);
    write_happening <= #ApplTime 1'b1;
    cycle_end();
    write_happening <= #ApplTime 1'b0;
    wait(write_req_done);
    write_req_busy <= #ApplTime 1'b0;
    rand_wait(10,10);
    $finish;
end
endmodule