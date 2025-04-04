`timescale 1ns/1ps
`include "axi/typedef.svh"
`include "axi/assign.svh"
module tb_xdma_axi_adapter_top();
    import xdma_pkg::*;
    ///---------------------
    /// AXI XBAR
    ///---------------------
    localparam int unsigned TbAxiUserWidth     = 32'd1;
    localparam int unsigned TbNumClusters      = 32'd2;
    localparam int unsigned TbNumMasters       = TbNumClusters;
    localparam int unsigned TbNumSlaves        = TbNumClusters;
    localparam int unsigned TbPipeline         = 32'd1;
    localparam int unsigned TbWideIdWidthIn    = 32'd8;
    localparam bit TbUniqueIds                 = 1'b0 ;
    localparam int unsigned TbAxiAddrWidth     =  32'd48;
    localparam int unsigned TbAxiDataWidth     =  32'd512;
    localparam int unsigned TbAxiStrbWidth     =  TbAxiDataWidth/8;
    localparam int unsigned TbWideIdWidthOut   = $clog2(TbNumMasters) + TbWideIdWidthIn;

    typedef logic [TbWideIdWidthIn-1:0]     id_dma_mst_t;
    typedef logic [TbWideIdWidthOut-1:0]    id_dma_slv_t;
    typedef logic [TbAxiAddrWidth-1:0]      addr_t;
    typedef logic [TbAxiDataWidth-1:0]      data_dma_t;
    typedef logic [TbAxiStrbWidth-1:0]      strb_dma_t;
    typedef logic [TbAxiUserWidth-1:0]      user_dma_t;
    `AXI_TYPEDEF_ALL(axi_mst_dma, addr_t, id_dma_mst_t, data_dma_t, strb_dma_t, user_dma_t)
    `AXI_TYPEDEF_ALL(axi_slv_dma, addr_t, id_dma_slv_t, data_dma_t, strb_dma_t, user_dma_t)

    typedef xdma_pkg::rule_t         xbar_rule_t;

    localparam axi_pkg::xbar_cfg_t DmaXbarCfg = '{
        NoSlvPorts:         TbNumMasters,
        NoMstPorts:         TbNumSlaves,
        MaxMstTrans:        10,
        MaxSlvTrans:        6,
        FallThrough:        1'b0,
        LatencyMode:        axi_pkg::CUT_ALL_AX,
        PipelineStages:     TbPipeline,
        AxiIdWidthSlvPorts: TbWideIdWidthIn,
        AxiIdUsedSlvPorts:  TbWideIdWidthIn,
        UniqueIds:          TbUniqueIds,
        AxiAddrWidth:       TbAxiAddrWidth,
        AxiDataWidth:       TbAxiDataWidth,
        NoAddrRules:        TbNumSlaves
    };
    localparam addr_t ClusterBaseAddr = xdma_pkg::ClusterBaseAddr;
    localparam addr_t ClusterAddressSpace =  xdma_pkg::ClusterAddressSpace;
    localparam xbar_rule_t [DmaXbarCfg.NoAddrRules-1:0] dma_xbar_rule = addr_map_gen(ClusterBaseAddr, ClusterAddressSpace);

    function xbar_rule_t [DmaXbarCfg.NoAddrRules-1:0] addr_map_gen(input addr_t ClusterBaseAddr, input addr_t ClusterAddressSpace);
        for (int unsigned i = 0; i < DmaXbarCfg.NoAddrRules; i++) begin
        addr_map_gen[i] = xbar_rule_t'{
            idx:        unsigned'(i),
            start_addr:  ClusterBaseAddr + i     * ClusterAddressSpace,
            end_addr:    ClusterBaseAddr + (i+1) * ClusterAddressSpace,
            default:    '0
        };
        end
    endfunction    
    logic clk;
    // DUT signals
    logic rst_n;
    axi_mst_dma_req_t   [TbNumMasters-1:0] wide_axi_mst_req;
    axi_mst_dma_resp_t  [TbNumMasters-1:0] wide_axi_mst_rsp;
    axi_slv_dma_req_t  [TbNumSlaves-1 :0] wide_axi_slv_req;
    axi_slv_dma_resp_t [TbNumSlaves-1 :0] wide_axi_slv_rsp;

    axi_xbar #(
        .Cfg (DmaXbarCfg),
        .ATOPs (0),
        .slv_aw_chan_t (axi_mst_dma_aw_chan_t),
        .mst_aw_chan_t (axi_slv_dma_aw_chan_t),
        .w_chan_t (axi_mst_dma_w_chan_t),
        .slv_b_chan_t (axi_mst_dma_b_chan_t),
        .mst_b_chan_t (axi_slv_dma_b_chan_t),
        .slv_ar_chan_t (axi_mst_dma_ar_chan_t),
        .mst_ar_chan_t (axi_slv_dma_ar_chan_t),
        .slv_r_chan_t (axi_mst_dma_r_chan_t),
        .mst_r_chan_t (axi_slv_dma_r_chan_t),
        .slv_req_t (axi_mst_dma_req_t),
        .slv_resp_t (axi_mst_dma_resp_t),
        .mst_req_t (axi_slv_dma_req_t),
        .mst_resp_t (axi_slv_dma_resp_t),
        .rule_t (xbar_rule_t)
    ) i_axi_dma_xbar (
        .clk_i (clk),
        .rst_ni (rst_n),
        .test_i (1'b0),
        .slv_ports_req_i (wide_axi_mst_req),
        .slv_ports_resp_o (wide_axi_mst_rsp),
        .mst_ports_req_o (wide_axi_slv_req),
        .mst_ports_resp_i (wide_axi_slv_rsp),
        .addr_map_i (dma_xbar_rule),
        .en_default_mst_port_i ('0),
        .default_mst_port_i ('0)
    );
    // -------------
    // DUT signals
    // -------------
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
    ///---------------------
    /// XDMA AXI Interface
    ///---------------------
    // Now we only simulate two clusers
    // which is enough to test the whole system

    /// XDMA signals
    logic [TbNumClusters-1:0] xdma_finish;
    ///---------------------
    /// TO REMOTE
    ///---------------------
    // to remote cfg
    xdma_pkg::xdma_inter_cluster_cfg_t [TbNumClusters-1:0] xdma_to_remote_cfg;
    logic [TbNumClusters-1:0] xdma_to_remote_cfg_valid;
    logic [TbNumClusters-1:0] xdma_to_remote_cfg_ready;
    // to remote data
    xdma_pkg::xdma_to_remote_data_t [TbNumClusters-1:0] xdma_to_remote_data;
    logic [TbNumClusters-1:0] xdma_to_remote_data_valid;
    logic [TbNumClusters-1:0] xdma_to_remote_data_ready;
    // to remote accompany cfg
    xdma_pkg::xdma_accompany_cfg_t [TbNumClusters-1:0] xdma_to_remote_data_accompany_cfg;
    ///---------------------
    /// FROM REMOTE
    ///---------------------
    // from remote cfg
    xdma_pkg::xdma_inter_cluster_cfg_t [TbNumClusters-1:0] xdma_from_remote_cfg;
    logic [TbNumClusters-1:0] xdma_from_remote_cfg_valid;
    logic [TbNumClusters-1:0] xdma_from_remote_cfg_ready;
    // from remote data
    xdma_pkg::xdma_from_remote_data_t [TbNumClusters-1:0] xdma_from_remote_data;
    logic [TbNumClusters-1:0] xdma_from_remote_data_valid;
    logic [TbNumClusters-1:0] xdma_from_remote_data_ready;
    // from remote data accompany cfg
    xdma_pkg::xdma_accompany_cfg_t [TbNumClusters-1:0] xdma_from_remote_data_accompany_cfg;

    // AXI adapter tops
    xdma_axi_adapter_top #(
        .axi_id_t       (id_dma_slv_t),
        .axi_out_req_t  (axi_mst_dma_req_t ),
        .axi_out_resp_t (axi_mst_dma_resp_t),
        .axi_in_req_t   (axi_slv_dma_req_t ),
        .axi_in_resp_t  (axi_slv_dma_resp_t),
        .reqrsp_req_t   (xdma_pkg::reqrsp_req_t),
        .reqrsp_rsp_t   (xdma_pkg::reqrsp_rsp_t),
        .data_t         (xdma_pkg::data_t),
        .strb_t         (xdma_pkg::strb_t),
        .addr_t         (xdma_pkg::addr_t),
        .len_t          (xdma_pkg::len_t),
        .xdma_to_remote_cfg_t (xdma_pkg::xdma_inter_cluster_cfg_t),
        .xdma_to_remote_data_t(xdma_pkg::xdma_to_remote_data_t),
        .xdma_to_remote_data_accompany_cfg_t(xdma_pkg::xdma_accompany_cfg_t),
        .xdma_req_desc_t(xdma_pkg::xdma_req_desc_t),
        .xdma_req_meta_t(xdma_pkg::xdma_req_meta_t),
        .xdma_to_remote_grant_t(xdma_pkg::xdma_to_remote_grant_t),
        .xdma_from_remote_grant_t(xdma_pkg::xdma_from_remote_grant_t),
        .xdma_from_remote_cfg_t(xdma_pkg::xdma_inter_cluster_cfg_t),
        .xdma_from_remote_data_t(xdma_pkg::xdma_from_remote_data_t),
        .xdma_from_remote_data_accompany_cfg_t(xdma_pkg::xdma_accompany_cfg_t)
    ) i_xdma_axi_adapter_0 (
        .clk_i                           (clk),
        .rst_ni                          (rst_n),
        .cluster_base_addr_i             (xdma_pkg::ClusterBaseAddr),
        // To remote cfg
        .to_remote_cfg_i                 (xdma_to_remote_cfg[0]),
        .to_remote_cfg_valid_i           (xdma_to_remote_cfg_valid[0]),
        .to_remote_cfg_ready_o           (xdma_to_remote_cfg_ready[0]),
        // to remote data
        .to_remote_data_i                (xdma_to_remote_data[0]),
        .to_remote_data_valid_i          (xdma_to_remote_data_valid[0]),
        .to_remote_data_ready_o          (xdma_to_remote_data_ready[0]),
        // to remote data accompany cfg
        .to_remote_data_accompany_cfg_i  (xdma_to_remote_data_accompany_cfg[0]),
        // from remote cfg
        .from_remote_cfg_o               (xdma_from_remote_cfg[0]),
        .from_remote_cfg_valid_o         (xdma_from_remote_cfg_valid[0]),
        .from_remote_cfg_ready_i         (xdma_from_remote_cfg_ready[0]),
        // from remote data
        .from_remote_data_o              (xdma_from_remote_data[0]),
        .from_remote_data_valid_o        (xdma_from_remote_data_valid[0]),
        .from_remote_data_ready_i        (xdma_from_remote_data_ready[0]),
        // from remote data accompany cfg
        .from_remote_data_accompany_cfg_i(xdma_from_remote_data_accompany_cfg[0]),
        // xdma finish
        .xdma_finish_o                   (xdma_finish[0]),
        // AXI interface
        .axi_xdma_wide_out_req_o         (wide_axi_mst_req[0]),
        .axi_xdma_wide_out_resp_i        (wide_axi_mst_rsp[0]),
        .axi_xdma_wide_in_req_i          (wide_axi_slv_req[0]),
        .axi_xdma_wide_in_resp_o         (wide_axi_slv_rsp[0])
    );

    xdma_axi_adapter_top #(
        .axi_id_t       (id_dma_slv_t),
        .axi_out_req_t  (axi_mst_dma_req_t ),
        .axi_out_resp_t (axi_mst_dma_resp_t),
        .axi_in_req_t   (axi_slv_dma_req_t ),
        .axi_in_resp_t  (axi_slv_dma_resp_t),
        .reqrsp_req_t   (xdma_pkg::reqrsp_req_t),
        .reqrsp_rsp_t   (xdma_pkg::reqrsp_rsp_t),
        .data_t         (xdma_pkg::data_t),
        .strb_t         (xdma_pkg::strb_t),
        .addr_t         (xdma_pkg::addr_t),
        .len_t          (xdma_pkg::len_t),
        .xdma_to_remote_cfg_t (xdma_pkg::xdma_inter_cluster_cfg_t),
        .xdma_to_remote_data_t(xdma_pkg::xdma_to_remote_data_t),
        .xdma_to_remote_data_accompany_cfg_t(xdma_pkg::xdma_accompany_cfg_t),
        .xdma_req_desc_t(xdma_pkg::xdma_req_desc_t),
        .xdma_req_meta_t(xdma_pkg::xdma_req_meta_t),
        .xdma_to_remote_grant_t(xdma_pkg::xdma_to_remote_grant_t),
        .xdma_from_remote_grant_t(xdma_pkg::xdma_from_remote_grant_t),
        .xdma_from_remote_cfg_t(xdma_pkg::xdma_inter_cluster_cfg_t),
        .xdma_from_remote_data_t(xdma_pkg::xdma_from_remote_data_t),
        .xdma_from_remote_data_accompany_cfg_t(xdma_pkg::xdma_accompany_cfg_t)
    ) i_xdma_axi_adapter_1 (
        .clk_i                           (clk),
        .rst_ni                          (rst_n),
        .cluster_base_addr_i             (xdma_pkg::ClusterBaseAddr + 1 * xdma_pkg::ClusterAddressSpace),
        // To remote cfg
        .to_remote_cfg_i                 (xdma_to_remote_cfg[1]),
        .to_remote_cfg_valid_i           (xdma_to_remote_cfg_valid[1]),
        .to_remote_cfg_ready_o           (xdma_to_remote_cfg_ready[1]),
        // to remote data
        .to_remote_data_i                (xdma_to_remote_data[1]),
        .to_remote_data_valid_i          (xdma_to_remote_data_valid[1]),
        .to_remote_data_ready_o          (xdma_to_remote_data_ready[1]),
        // to remote data accompany cfg
        .to_remote_data_accompany_cfg_i  (xdma_to_remote_data_accompany_cfg[1]),
        // from remote cfg
        .from_remote_cfg_o               (xdma_from_remote_cfg[1]),
        .from_remote_cfg_valid_o         (xdma_from_remote_cfg_valid[1]),
        .from_remote_cfg_ready_i         (xdma_from_remote_cfg_ready[1]),
        // from remote data
        .from_remote_data_o              (xdma_from_remote_data[1]),
        .from_remote_data_valid_o        (xdma_from_remote_data_valid[1]),
        .from_remote_data_ready_i        (xdma_from_remote_data_ready[1]),
        // from remote data accompany cfg
        .from_remote_data_accompany_cfg_i(xdma_from_remote_data_accompany_cfg[1]),
        //
        .xdma_finish_o                   (xdma_finish[1]),
        // AXI interface
        .axi_xdma_wide_out_req_o         (wide_axi_mst_req[1]),
        .axi_xdma_wide_out_resp_i        (wide_axi_mst_rsp[1]),
        .axi_xdma_wide_in_req_i          (wide_axi_slv_req[1]),
        .axi_xdma_wide_in_resp_o         (wide_axi_slv_rsp[1])
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


task automatic reset_xdma();
    xdma_to_remote_cfg = '0;
    xdma_to_remote_cfg_valid = '0;
    xdma_to_remote_data = '0;
    xdma_to_remote_data_valid = '0;
    xdma_to_remote_data_accompany_cfg = '0;
    xdma_from_remote_data_accompany_cfg = '0;
    xdma_from_remote_cfg_ready = '1;
    xdma_from_remote_data_ready = '1;
endtask




task automatic read_send_cfg;
    $display("Start Send CFG");
    xdma_to_remote_cfg[0].dma_id <= #ApplTime 8'd88;
    xdma_to_remote_cfg[0].dma_type <= #ApplTime '0;
    xdma_to_remote_cfg[0].reader_addr <= #ApplTime xdma_pkg::ClusterBaseAddr + 1 * xdma_pkg::ClusterAddressSpace;
    xdma_to_remote_cfg[0].writer_addr.write_addr_0 <= #ApplTime xdma_pkg::ClusterBaseAddr;
    xdma_to_remote_cfg[0].writer_addr.write_addr_1 <= #ApplTime '0;
    xdma_to_remote_cfg[0].writer_addr.write_addr_2 <= #ApplTime '0;
    xdma_to_remote_cfg[0].writer_addr.write_addr_3 <= #ApplTime '0;
    xdma_to_remote_cfg[0].spatial_stride <= #ApplTime 8;
    xdma_to_remote_cfg[0].temporal_bound.temporal_bound_0 <= #ApplTime 16;
    xdma_to_remote_cfg[0].temporal_bound.temporal_bound_1 <= #ApplTime 16;
    xdma_to_remote_cfg[0].temporal_bound.temporal_bound_2 <= #ApplTime 16;
    xdma_to_remote_cfg[0].temporal_bound.temporal_bound_3 <= #ApplTime 16;
    xdma_to_remote_cfg[0].temporal_bound.temporal_bound_4 <= #ApplTime 16;
    xdma_to_remote_cfg[0].temporal_bound.temporal_bound_5 <= #ApplTime 16;
    xdma_to_remote_cfg[0].temporal_stride.temporal_stride_0 <= #ApplTime 8;
    xdma_to_remote_cfg[0].temporal_stride.temporal_stride_1 <= #ApplTime 8;
    xdma_to_remote_cfg[0].temporal_stride.temporal_stride_2 <= #ApplTime 8;
    xdma_to_remote_cfg[0].temporal_stride.temporal_stride_3 <= #ApplTime 8;
    xdma_to_remote_cfg[0].temporal_stride.temporal_stride_4 <= #ApplTime 8;
    xdma_to_remote_cfg[0].temporal_stride.temporal_stride_5 <= #ApplTime 8;
    xdma_to_remote_cfg[0].enable_channel <= #ApplTime 1;
    xdma_to_remote_cfg[0].enable_byte <= #ApplTime 1;
    xdma_to_remote_cfg_valid[0] <= #ApplTime 1;
    cycle_start();
    while(xdma_to_remote_cfg_ready[0]!=1) begin cycle_end(); cycle_start();
    end
    cycle_end();
    xdma_to_remote_cfg[0] <= #ApplTime '0;
    xdma_to_remote_cfg_valid[0] <= #ApplTime 0;
    xdma_from_remote_data_accompany_cfg[0].dma_id <= #ApplTime 8'd88;
    xdma_from_remote_data_accompany_cfg[0].dma_type <= #ApplTime '0;
    xdma_from_remote_data_accompany_cfg[0].src_addr <= #ApplTime xdma_pkg::ClusterBaseAddr + 1 * xdma_pkg::ClusterAddressSpace;
    xdma_from_remote_data_accompany_cfg[0].dst_addr <= #ApplTime xdma_pkg::ClusterBaseAddr;
    xdma_from_remote_data_accompany_cfg[0].dma_length <= #ApplTime 100;
    xdma_from_remote_data_accompany_cfg[0].ready_to_transfer <= #ApplTime 1;
    $display("End Send CFG");
endtask

task automatic read_send_data;
    
    xdma_pkg::data_t local_mem[$];
    int dma_length = 100;
    for (int i = 1; i <= dma_length; i++) begin
        local_mem.push_back(1024 + i);
    end
    $display("Start Send Data");
    xdma_to_remote_data_accompany_cfg[1].dma_id <= #ApplTime 8'd88;
    xdma_to_remote_data_accompany_cfg[1].dma_length <= #ApplTime 'd100;
    xdma_to_remote_data_accompany_cfg[1].dma_type <= #ApplTime '0;
    xdma_to_remote_data_accompany_cfg[1].src_addr <= #ApplTime xdma_pkg::ClusterBaseAddr + 1 * xdma_pkg::ClusterAddressSpace;
    xdma_to_remote_data_accompany_cfg[1].dst_addr <= #ApplTime xdma_pkg::ClusterBaseAddr;
    xdma_to_remote_data_accompany_cfg[1].ready_to_transfer <= #ApplTime 1'b1;
    // standard axi handshake for
    for (int i = 1; i <= dma_length; i++) begin
        rand_wait(0,5);
        $display("Send Data idx = %d", i);
        xdma_to_remote_data[1] = local_mem.pop_front();
        xdma_to_remote_data_valid[1] = 1'b1;
        cycle_start();
        while(xdma_to_remote_data_ready[1]!=1) begin cycle_end(); cycle_start();
        end
        cycle_end();
        xdma_to_remote_data_valid[1] = 1'b0;
    end

endtask



task automatic write_send_cfg;
    xdma_to_remote_cfg[0].dma_id <= #ApplTime 8'd88;
    xdma_to_remote_cfg[0].dma_type <= #ApplTime 1'b1;
    xdma_to_remote_cfg[0].reader_addr <= #ApplTime xdma_pkg::ClusterBaseAddr;
    xdma_to_remote_cfg[0].writer_addr.write_addr_0 <= #ApplTime xdma_pkg::ClusterBaseAddr + 1 * xdma_pkg::ClusterAddressSpace;
    xdma_to_remote_cfg[0].writer_addr.write_addr_1 <= #ApplTime '0;
    xdma_to_remote_cfg[0].writer_addr.write_addr_2 <= #ApplTime '0;
    xdma_to_remote_cfg[0].writer_addr.write_addr_3 <= #ApplTime '0;
    xdma_to_remote_cfg[0].spatial_stride <= #ApplTime 8;
    xdma_to_remote_cfg[0].temporal_bound.temporal_bound_0 <= #ApplTime 16;
    xdma_to_remote_cfg[0].temporal_bound.temporal_bound_1 <= #ApplTime 16;
    xdma_to_remote_cfg[0].temporal_bound.temporal_bound_2 <= #ApplTime 16;
    xdma_to_remote_cfg[0].temporal_bound.temporal_bound_3 <= #ApplTime 16;
    xdma_to_remote_cfg[0].temporal_bound.temporal_bound_4 <= #ApplTime 16;
    xdma_to_remote_cfg[0].temporal_bound.temporal_bound_5 <= #ApplTime 16;
    xdma_to_remote_cfg[0].temporal_stride.temporal_stride_0 <= #ApplTime 8;
    xdma_to_remote_cfg[0].temporal_stride.temporal_stride_1 <= #ApplTime 8;
    xdma_to_remote_cfg[0].temporal_stride.temporal_stride_2 <= #ApplTime 8;
    xdma_to_remote_cfg[0].temporal_stride.temporal_stride_3 <= #ApplTime 8;
    xdma_to_remote_cfg[0].temporal_stride.temporal_stride_4 <= #ApplTime 8;
    xdma_to_remote_cfg[0].temporal_stride.temporal_stride_5 <= #ApplTime 8;
    xdma_to_remote_cfg[0].enable_channel <= #ApplTime 1;
    xdma_to_remote_cfg[0].enable_byte <= #ApplTime 1;
    xdma_to_remote_cfg_valid[0] <= #ApplTime 1;
    cycle_start();
    while(xdma_to_remote_cfg_ready[0]!=1) begin cycle_end(); cycle_start();
    end
    cycle_end();
    xdma_to_remote_cfg[0] <= #ApplTime '0;
    xdma_to_remote_cfg_valid[0] <= #ApplTime 0;
endtask

task automatic write_send_data;
    xdma_pkg::data_t local_mem[$];
    int dma_length = 100;
    for (int i = 1; i <= dma_length; i++) begin
        local_mem.push_back(1024 + i);
    end

    xdma_from_remote_data_accompany_cfg[1].dma_id <= #ApplTime 8'd88;
    xdma_from_remote_data_accompany_cfg[1].dma_length <= #ApplTime 'd100;
    xdma_from_remote_data_accompany_cfg[1].dma_type <= #ApplTime 1'b1;
    xdma_from_remote_data_accompany_cfg[1].src_addr <= #ApplTime xdma_pkg::ClusterBaseAddr;
    xdma_from_remote_data_accompany_cfg[1].dst_addr <= #ApplTime xdma_pkg::ClusterBaseAddr + 1 * xdma_pkg::ClusterAddressSpace;
    xdma_from_remote_data_accompany_cfg[1].ready_to_transfer <= #ApplTime 1'b1;
    


    xdma_to_remote_data_accompany_cfg[0].dma_id <= #ApplTime 8'd88;
    xdma_to_remote_data_accompany_cfg[0].dma_length <= #ApplTime 'd100;
    xdma_to_remote_data_accompany_cfg[0].dma_type <= #ApplTime 1'b1;
    xdma_to_remote_data_accompany_cfg[0].src_addr <= #ApplTime xdma_pkg::ClusterBaseAddr;
    xdma_to_remote_data_accompany_cfg[0].dst_addr <= #ApplTime xdma_pkg::ClusterBaseAddr + 1 * xdma_pkg::ClusterAddressSpace;
    xdma_to_remote_data_accompany_cfg[0].ready_to_transfer <= #ApplTime 1'b1;
    // standard axi handshake for
    for (int i = 1; i <= dma_length; i++) begin
        $display("Send Data idx = %d", i);
        xdma_to_remote_data[0] = local_mem.pop_front();
        xdma_to_remote_data_valid[0] = 1'b1;
        cycle_start();
        while(xdma_to_remote_data_ready[0]!=1) begin cycle_end(); cycle_start();
        end
        cycle_end();
        xdma_to_remote_data_valid[0] = 1'b0;
        rand_wait(0,5);
    end
endtask






initial begin
    reset_xdma();
    rand_wait(20,20);

    write_send_cfg();
    wait(xdma_from_remote_cfg_valid[1]);
    rand_wait(1,5);
    write_send_data();



    // read_send_cfg();
    // wait(xdma_from_remote_cfg_valid[1]);
    // rand_wait(1,5);
    // read_send_data();
    // wait(xdma_finish[0]);
    // xdma_from_remote_data_accompany_cfg[0].ready_to_transfer <= #ApplTime 0;
    // $display("Send Finish");

    repeat(10) begin cycle_end(); cycle_start(); end    
    $finish;
end

endmodule