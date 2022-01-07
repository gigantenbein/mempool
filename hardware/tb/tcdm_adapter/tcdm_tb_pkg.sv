package tcdm_tb_pkg;

  import mempool_pkg::*;
  import snitch_pkg::MetaIdWidth;
  import cf_math_pkg::idx_width;
  /****************
  * PARAMS
  ****************/


  // set number of cores sending requests
  localparam int   NumActiveCores = 256;
  localparam int   CoreIdWidth    = (NumActiveCores > 2 ) ?
                                    unsigned'($clog2(NumActiveCores)) : 1;
  localparam int   SelCoreWidth   = CoreIdWidth;
  // number of TCDM banks per tile
  localparam int   NumTcdmBanks   = 16;
  localparam int   SelTcdmWidth   = (NumTcdmBanks > 2 ) ?
                                    unsigned'($clog2(NumTcdmBanks)) : 1;


  // set number of rounds to send requests
  localparam int   NumIterations    = 100;

  // randomize address and payloads for TCDM
  localparam logic FULL_RANDOM_TEST = 0;
  // print requests sent and received
  localparam logic VERBOSE          = 0;
  // if valid, delay raising of ready flag at output of TCDM adapter
  // by a random duration
  localparam logic STALL_OUTPUT     = 1;

  // overrides param from mempool_pkg
  localparam int   LrWaitQueueSize  = 256;

  localparam int unsigned IniAddrWidth = idx_width(NumCoresPerTile + NumGroups);
  // ini_addr_width + meta_id_width + core_id_width + tile_id_width
  localparam int MetaWidth = idx_width(NumCoresPerTile + NumGroups) +
                             MetaIdWidth +
                             idx_width(NumCoresPerTile) +
                             idx_width(NumTilesPerGroup) + 1;

  /****************
  * TYPES
  ****************/
  typedef logic [IniAddrWidth-1:0] local_req_interco_addr_t;

  // Bank metadata
  typedef struct packed {
    local_req_interco_addr_t ini_addr;
    meta_id_t                meta_id;
    tile_group_id_t          tile_id;
    tile_core_id_t           core_id;
    logic                    lrwait;
  } bank_metadata_t;

  typedef struct packed {
    addr_t          addr;
    bank_metadata_t meta;
    logic [3:0]     amo;
    logic           write;
    data_t          wdata;
    strb_t          be;
  } tcdm_req_t;

  typedef struct packed {
    bank_metadata_t meta;
    data_t          rdata;
  } tcdm_resp_t;

  typedef logic [SelTcdmWidth-1:0] sel_tcdm_t;
  typedef logic [SelCoreWidth-1:0] sel_qnode_t;

endpackage : tcdm_tb_pkg
