// Authors:
// Fanchen Kong <fanchen.kong@kuleuven.be>


//! XDMA Package
/// Contains all necessary type definitions, constants, and generally useful functions.
package xdma_pkg;
    localparam int unsigned AxiDataWidth         = 32'd512;
    localparam int unsigned StrbWidth            = AxiDataWidth/8;
    localparam int unsigned DMAIdWidth           = 32'd8;
    localparam int unsigned AddrWidth            = 32'd48;
    localparam int unsigned StrideWidth          = 32'd19;
    localparam int unsigned BoundWidth           = 32'd19;
    localparam int unsigned EnableChannelWidth   = 32'd8;
    localparam int unsigned EnableByteWidth      = 32'd8;
    localparam int unsigned DMALengthWidth       = 32'd19;
    localparam int unsigned NrBroadcast          = 32'd4;
    localparam int unsigned NrDimension          = 32'd6;
    typedef logic [                     AxiDataWidth-1:0]  data_t;
    typedef logic [                        StrbWidth-1:0]  strb_t;
    typedef logic [                       DMAIdWidth-1:0]  id_t;
    typedef logic [                        AddrWidth-1:0]  addr_t;
    typedef logic [                      StrideWidth-1:0]  stride_t;
    typedef logic [                       BoundWidth-1:0]  bound_t;
    typedef logic [               EnableChannelWidth-1:0]  enable_channel_t;
    typedef logic [                  EnableByteWidth-1:0]  enable_byte_t;
    typedef logic [                   DMALengthWidth-1:0]  len_t;
    typedef logic [AxiDataWidth-DMAIdWidth-AddrWidth-1:0]  grant_reserved_t;
    typedef logic [AxiDataWidth-DMAIdWidth-AddrWidth-1:0]  finish_reserved_t;

    //--------------------------------------
    // to remote cfg type
    //--------------------------------------
    typedef struct packed {
        addr_t write_addr_3;
        addr_t write_addr_2;
        addr_t write_addr_1;
        addr_t write_addr_0;
    } xdma_inter_cluster_cfg_broadcast_t;

    typedef struct packed {
        bound_t temporal_bound_5;
        bound_t temporal_bound_4;
        bound_t temporal_bound_3;
        bound_t temporal_bound_2;
        bound_t temporal_bound_1;
        bound_t temporal_bound_0;
    } xdma_inter_cluster_cfg_temporal_bound_t;

    typedef struct packed {
        stride_t temporal_stride_5;
        stride_t temporal_stride_4;
        stride_t temporal_stride_3;
        stride_t temporal_stride_2;
        stride_t temporal_stride_1;
        stride_t temporal_stride_0;
    } xdma_inter_cluster_cfg_temporal_stride_t;

    typedef struct packed {
        enable_byte_t                            enable_byte;
        enable_channel_t                         enable_channel;
        xdma_inter_cluster_cfg_temporal_stride_t temporal_stride;
        xdma_inter_cluster_cfg_temporal_bound_t  temporal_bound;
        stride_t                                 spatial_stride;
        xdma_inter_cluster_cfg_broadcast_t       writer_addr;
        addr_t                                   reader_addr;
        // The dma_type
        // 0: read
        // 1: write
        logic                                    dma_type;
        id_t                                     dma_id;
    } xdma_inter_cluster_cfg_t;
    // typedef struct packed {
    //     addr_t write_addr_0;
    //     addr_t write_addr_1;
    //     addr_t write_addr_2;
    //     addr_t write_addr_3;
    // } xdma_inter_cluster_cfg_broadcast_t;

    // typedef struct packed {
    //     bound_t temporal_bound_0;
    //     bound_t temporal_bound_1;
    //     bound_t temporal_bound_2;
    //     bound_t temporal_bound_3;
    //     bound_t temporal_bound_4;
    //     bound_t temporal_bound_5;
    // } xdma_inter_cluster_cfg_temporal_bound_t;

    // typedef struct packed {
    //     stride_t temporal_stride_0;
    //     stride_t temporal_stride_1;
    //     stride_t temporal_stride_2;
    //     stride_t temporal_stride_3;
    //     stride_t temporal_stride_4;
    //     stride_t temporal_stride_5;
    // } xdma_inter_cluster_cfg_temporal_stride_t;

    // typedef struct packed {
    //     id_t                                     dma_id; 
    //     // The dma_type
    //     // 0: read
    //     // 1: write
    //     logic                                    dma_type;
    //     // The reader addr indicates the source of data
    //     addr_t                                   reader_addr;
    //     xdma_inter_cluster_cfg_broadcast_t       writer_addr;
    //     stride_t                                 spatial_stride;
    //     xdma_inter_cluster_cfg_temporal_bound_t  temporal_bound;
    //     xdma_inter_cluster_cfg_temporal_stride_t temporal_stride;
    //     enable_channel_t                         enable_channel;
    //     enable_byte_t                            enable_byte;
    // } xdma_inter_cluster_cfg_t;

    typedef logic [AxiDataWidth-1:0] xdma_to_remote_data_t;
    typedef logic [AxiDataWidth-1:0] xdma_from_remote_data_t;

    
    //--------------------------------------
    // to remote IDX
    //--------------------------------------
    // Here we can tell if the write data is the to_remote_write

    typedef enum int unsigned {
        ToRemoteFinish = 0,
        ToRemoteGrant  = 1,
        ToRemoteCfg    = 2,
        ToRemoteData   = 3,
        NUM_INP = 4
    } xdma_to_remote_idx_e;

    // typedef enum int unsigned {
    //     ToRemoteCfg  = 0,
    //     ToRemoteData = 1,
    //     ToRemoteGrant= 2,
    //     NUM_INP = 3
    // } xdma_to_remote_idx_e;


    typedef logic [$clog2(NUM_INP)-1:0] xdma_req_idx_t;
    //--------------------------------------
    // Accompany CFG
    //--------------------------------------
    typedef struct packed {
        id_t                                 dma_id; 
        logic                                dma_type;
        addr_t                               src_addr;
        addr_t                               dst_addr;
        len_t                                dma_length;
        logic                                ready_to_transfer;
    } xdma_accompany_cfg_t;
    //--------------------------------------
    // Req description
    //--------------------------------------    
    typedef struct packed {
        id_t                                 dma_id; 
        logic                                dma_type;
        addr_t                               remote_addr;
        len_t                                dma_length;
        logic                                ready_to_transfer;
    } xdma_req_desc_t;   

    //-------------------------------- ------
    // req meta type
    //--------------------------------------    
    typedef struct packed {
        id_t                                 dma_id;
        len_t                                dma_length;
    } xdma_req_meta_t;    

    //--------------------------------------
    // to remote grant
    //--------------------------------------
    typedef struct packed {
        id_t                                 dma_id;
        addr_t                               from;
        grant_reserved_t                     reserved;
    } xdma_to_remote_grant_t;

    //--------------------------------------
    // from remote grant
    //--------------------------------------
    typedef struct packed {
        id_t                                 dma_id;
        addr_t                               from;
    } xdma_from_remote_grant_t;

    //--------------------------------------
    // to remote finish
    //--------------------------------------
    typedef struct packed {
        id_t                                 dma_id;
        addr_t                               from;
        finish_reserved_t                    reserved;
    } xdma_to_remote_finish_t;

    //--------------------------------------
    // From remote finish
    //--------------------------------------
    typedef struct packed {
        id_t                                 dma_id;
        addr_t                               from;
    } xdma_from_remote_finish_t;
    //--------------------------------------
    // AW desc
    //--------------------------------------
    typedef struct packed {
        id_t                                 id;
        addr_t                               addr;
        logic [7:0]                          len;
        logic [2:0]                          size;
        logic [1:0]                          burst;
        logic [3:0]                          cache;
    } xdma_req_aw_desc_t;

    //--------------------------------------
    // W desc
    //--------------------------------------
    typedef struct packed {
        logic [7:0]                         num_beats;
        logic                               is_single;
        logic                               is_write_data;
    } xdma_req_w_desc_t;


    //--------------------------------------
    // addr decoder rule
    //--------------------------------------
    typedef struct packed {
       int unsigned idx;
       addr_t       start_addr;
       addr_t       end_addr;
    } rule_t;
    //--------------------------------------
    // addr decoder idx
    //--------------------------------------

    typedef enum int unsigned {
        FromRemoteFinish = 0,
        FromRemoteGrant  = 1,
        FromRemoteCfg    = 2,
        FromRemoteData   = 3,
        NUM_OUP = 4
    } xdma_from_remote_idx_e;


    //--------------------------------------
    // Reqrsp Type for Standalone Test
    //-------------------------------------- 
    typedef enum logic [3:0] {
        AMONone = 4'h0,
        AMOSwap = 4'h1,
        AMOAdd  = 4'h2,
        AMOAnd  = 4'h3,
        AMOOr   = 4'h4,
        AMOXor  = 4'h5,
        AMOMax  = 4'h6,
        AMOMaxu = 4'h7,
        AMOMin  = 4'h8,
        AMOMinu = 4'h9,
        AMOLR   = 4'hA,
        AMOSC   = 4'hB
    } amo_op_e;

    typedef struct packed {
        addr_t      addr;
        logic       write;
        amo_op_e    amo;
        data_t      data;
        strb_t      strb;
        logic [2:0] size;
        logic       q_valid;
        logic       p_ready;
    } reqrsp_req_t;

    typedef struct packed {
        data_t      data;
        logic       error;
        logic       p_valid;
        logic       q_ready;
    } reqrsp_rsp_t;
    //0x0000_1000 = 4096 = 4KB
    // The base addr of the cluster is          = 0x1000_0000
    // The cluster tcdm size is           128kB = 0x0002_0000
    // The cluster periph size is          64kB = 0x0001_0000
    // The addr space for the cluster is    1MB = 0x0010_0000
    // The cluster end addr is                  = 0x1010_0000
    // 4KB space is                             = 0x0000_1000
    // We put the mmio at the end of the addr space
    // Virtual TCDM   ADDR                       = 0x100F_C000 - 0x100F_D000                                        
    // Virtual CFG    ADDR                       = 0x100F_D000 - 0x100F_E000;
    // Virtual GRANT  ADDR                       = 0x100F_E000 - 0x100F_F000;
    // Virtual FINISH ADDR                       = 0x100F_F000 - 0x1010_0000;  
    localparam addr_t ClusterBaseAddr             = 'h1000_0000;
    localparam addr_t ClusterAddressSpace         = 'h0010_0000;
    localparam int    SHIFT_BITS                  = $clog2(ClusterAddressSpace);
    localparam addr_t MainMemBaseAddr             = 'h8000_0000;
    localparam addr_t MainMemEndAddr              =  48'b1 << 33;
    localparam addr_t MMIOSize                    = 'h0000_1000;
    localparam addr_t MMIODataOffset              =  (FromRemoteData+1  )*MMIOSize;
    localparam addr_t MMIOCFGOffset               =  (FromRemoteCfg+1   )*MMIOSize;
    localparam addr_t MMIOGrantOffset             =  (FromRemoteGrant+1 )*MMIOSize;
    localparam addr_t MMIOFinishOffset            =  (FromRemoteFinish+1)*MMIOSize;

    function int get_cluster_id(addr_t addr);
        return (addr - ClusterBaseAddr) >> SHIFT_BITS;
    endfunction
    
    function addr_t get_cluster_base_addr(addr_t addr);
         int cluster_id;
         cluster_id = get_cluster_id(addr);
         return ClusterBaseAddr + cluster_id * ClusterAddressSpace;
    endfunction

    function addr_t get_cluster_end_addr(addr_t addr);
         int cluster_id;
         cluster_id = get_cluster_id(addr);
         return ClusterBaseAddr + (cluster_id+1) * ClusterAddressSpace;
    endfunction

endpackage  