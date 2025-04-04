`timescale 1ns/1ps
module tb_xdma_burst_reshaper();
    import xdma_pkg::*;

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
    logic write_req_done;
    xdma_pkg::xdma_req_desc_t write_req_desc;
    xdma_pkg::xdma_req_idx_t write_req_idx;
    xdma_pkg::xdma_req_aw_desc_t write_req_aw_desc;
    xdma_pkg::xdma_req_w_desc_t write_req_w_desc;
    logic write_req_desc_valid;
    logic write_req_desc_ready;
    xdma_burst_reshaper #(
        .data_t            (xdma_pkg::data_t),
        .addr_t            (xdma_pkg::addr_t),
        .len_t             (xdma_pkg::len_t),
        .xdma_req_idx_t    (xdma_pkg::xdma_req_idx_t),
        .xdma_req_desc_t   (xdma_pkg::xdma_req_desc_t),
        .xdma_req_aw_desc_t(xdma_pkg::xdma_req_aw_desc_t),
        .xdma_req_w_desc_t (xdma_pkg::xdma_req_w_desc_t)
    ) i_xdma_burst_reshaper (
        .clk_i                           (clk                 ),
        .rst_ni                          (rst_n               ),
        .write_req_done_i                (write_req_done      ),
        .write_req_desc_i                (write_req_desc      ),
        .write_req_idx_i                 (write_req_idx       ),
        .write_req_desc_valid_i          (write_req_desc.ready_to_transfer),
        .write_req_aw_desc_o             (write_req_aw_desc   ),
        .write_req_w_desc_o              (write_req_w_desc    ),
        .write_req_desc_valid_o          (write_req_desc_valid),
        .write_req_desc_ready_i          (write_req_desc_ready)        
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
    write_req_done <= #ApplTime '0;
    write_req_desc <= #ApplTime '0;
    write_req_idx <= #ApplTime '0;
    write_req_desc_ready <= #ApplTime '0;
endtask

task automatic set_input();
    write_req_desc.dma_id <= #ApplTime 8'd99;
    write_req_desc.dma_type <= #ApplTime '0;
    write_req_desc.remote_addr <= #ApplTime xdma_pkg::ClusterBaseAddr + 1 * xdma_pkg::ClusterAddressSpace;
    write_req_desc.dma_length <= #ApplTime 'd100;
    write_req_desc.ready_to_transfer <= #ApplTime 1'b1;
    write_req_desc_ready <= #ApplTime 1'b1;
endtask



initial begin
    reset_input();
    rand_wait(20,20);
    set_input();
    rand_wait(10,20);
    write_req_done <= #ApplTime 1'b1;
    rand_wait(10,20);
    $finish;
end
endmodule