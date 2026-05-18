`timescale 1ns/1ps
module tb_xdma_burst_reshaper();
    // Standalone-test typedefs. xdma_pkg has been retired; this tb owns
    // its own protocol typedefs (mirrors the adapter's body).
    localparam int unsigned TbMaxMemSizeKiB  = 32'd4096;
    localparam int unsigned TbWordlineWidth  = 32'd64;
    localparam int unsigned TbAxiAddrWidth   = 32'd48;
    localparam int unsigned TbAxiDataWidth   = 32'd512;
    localparam int unsigned TbXDMAIdWidth     = 32'd4;
    localparam int unsigned TbDMALengthWidth =
        $clog2(TbMaxMemSizeKiB) + 10 - $clog2(TbWordlineWidth/8);
    typedef logic [TbXDMAIdWidth-1:0]     tb_id_t;
    typedef logic [TbAxiAddrWidth-1:0]   tb_addr_t;
    typedef logic [TbAxiDataWidth-1:0]   tb_data_t;
    typedef logic [TbDMALengthWidth-1:0] tb_len_t;
    typedef struct packed {
      tb_id_t   dma_id;
      logic     dma_type;
      tb_addr_t remote_addr;
      tb_len_t  dma_length;
      logic     ready_to_transfer;
    } tb_xdma_req_desc_t;
    typedef struct packed {
      tb_id_t     id;
      tb_addr_t   addr;
      logic [7:0] len;
      logic [2:0] size;
      logic [1:0] burst;
      logic [3:0] cache;
      logic       is_write_data;
    } tb_xdma_req_aw_desc_t;
    typedef struct packed {
      logic [7:0] num_beats;
      logic       is_single;
      logic       is_write_data;
    } tb_xdma_req_w_desc_t;
    typedef logic [$clog2(1)-1:0] tb_xdma_req_idx_t;
    // DUT signals
    logic clk;
    logic rst_n;
    localparam time CyclTime = 10ns;
    localparam time ApplTime =  2ns;
    localparam time TestTime =  8ns;
    localparam tb_addr_t ClusterBaseAddr     = 'h1000_0000;
    localparam tb_addr_t ClusterAddressSpace = 'h0010_0000;
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
    tb_xdma_req_desc_t   write_req_desc;
    tb_xdma_req_idx_t    write_req_idx;
    tb_xdma_req_aw_desc_t write_req_aw_desc;
    tb_xdma_req_w_desc_t  write_req_w_desc;
    logic write_req_desc_valid;
    logic write_req_desc_ready;
    xdma_burst_reshaper #(
        .data_t            (tb_data_t),
        .addr_t            (tb_addr_t),
        .len_t             (tb_len_t),
        .xdma_req_idx_t    (tb_xdma_req_idx_t),
        .xdma_req_desc_t   (tb_xdma_req_desc_t),
        .xdma_req_aw_desc_t(tb_xdma_req_aw_desc_t),
        .xdma_req_w_desc_t (tb_xdma_req_w_desc_t)
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
    write_req_desc.remote_addr <= #ApplTime ClusterBaseAddr + 1 * ClusterAddressSpace;
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