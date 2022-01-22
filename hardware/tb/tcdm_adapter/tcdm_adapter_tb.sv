// Copyright 2021 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Author: Marc Gantenbein, ETH Zurich

// Description: Drives cores with LR and SC and routes all requests to different
//              TCDM banks according to address.

module tcdm_adapter_tb;

  /*                           NumActiveCores                      NumTCDMBanks
   *
   *      +-----------+           +-------+                               +--------+
   *      |           +-----------+ qnode +--                            /+ TCDM   |
   *      |           |           +-------+  \---                    /--- +--------+
   *      |           |           +-------+      \--- +---------+ /--     +--------+
   *      |           +-----------+ qnode +----\     \+         +-   /----+ TCDM   |
   *      |  Driver   |           +-------+     ------+   xbar  +----     +--------+
   *      |           |           +-------+     /-----+         +-----    +--------+
   *      |           +-----------+ qnode +-----     -+         +-    \---+ TCDM   |
   *      |           |           +-------+      ---/ +---------+ \---    +--------+
   *      |           |           +-------+  ---/                     \-- +--------+
   *      +           +-----------+ qnode +-/                            \+ TCDM   |
   *      +-----------+           +-------+                               +--------+
   *
   */


  /*****************
   *  Definitions  *
   *****************/

  timeunit      1ns;
  timeprecision 1ps;

  import tcdm_tb_pkg::*;
  import mempool_pkg::*;

 /********************************
   *  Clock and Reset Generation  *
   ********************************/

  // Simulation
  localparam ClockPeriod = 1ns;
  localparam TA          = 0.2ns; // Application time
  localparam TT          = 0.8ns; // Test time

  logic clk;
  logic rst_n;

  /****************
  * CLOCK
  ****************/
  always #(ClockPeriod/2) clk = !clk;

  /****************
  * RESET
  ****************/
  // Controlling the reset
  initial begin
    clk   = 1'b1;
    rst_n = 1'b0;
    repeat (5)
      #(ClockPeriod);
    rst_n = 1'b1;
  end

  /****************
  * SIGNALS
  ****************/

  //
  //
  //     +-------+                     +-------+
  //     |       |      snitch_req     |       |
  //     |       +--------------------->       |
  //     | Driver|                     | Qnode |
  //     |       <---------------------|       |
  //     |       |      snitch_resp    |       |
  //     +-------+                     +-------+
  //

  // signals for qnode
  tcdm_req_t  [NumActiveCores-1:0] snitch_req;

  logic       [NumActiveCores-1:0] snitch_req_valid;
  logic       [NumActiveCores-1:0] snitch_req_ready;

  tcdm_resp_t [NumActiveCores-1:0] snitch_resp;
  tcdm_resp_t [NumActiveCores-1:0] snitch_resp_out;
  logic       [NumActiveCores-1:0] snitch_resp_valid;
  logic       [NumActiveCores-1:0] snitch_resp_ready;

  // signal from qnode to interconnect
  tcdm_req_t  [NumActiveCores-1:0] tile_req;
  // needed for driving metadata that does not pass through lrwait_qnode
  tcdm_req_t  [NumActiveCores-1:0] tile_req_xbar_in;
  logic       [NumActiveCores-1:0] tile_req_valid_o;
  logic       [NumActiveCores-1:0] tile_req_ready_i;

  sel_tcdm_t  [NumActiveCores-1:0] select_tcdm_bank;


  tcdm_resp_t [NumActiveCores-1:0] tile_resp;
  logic       [NumActiveCores-1:0] tile_resp_valid;
  logic       [NumActiveCores-1:0] tile_resp_ready;

  // signals for TCDM
  tcdm_req_t  [NumTcdmBanks-1:0]   tcdm_req;
  logic       [NumTcdmBanks-1:0]   tcdm_req_valid, tcdm_req_ready;

  sel_qnode_t [NumTcdmBanks-1:0]   select_qnode;

  tcdm_resp_t [NumTcdmBanks-1:0]   tcdm_resp;
  logic       [NumTcdmBanks-1:0]   tcdm_resp_valid, tcdm_resp_ready;

  // signals to sram
  logic       [NumTcdmBanks-1:0]   sram_req_valid;
  logic       [NumTcdmBanks-1:0]   sram_req_write;
  bank_addr_t [NumTcdmBanks-1:0]   sram_req_addr;
  data_t      [NumTcdmBanks-1:0]   sram_req_wdata;
  data_t      [NumTcdmBanks-1:0]   sram_resp_rdata;
  strb_t      [NumTcdmBanks-1:0]   sram_req_be;

  /**********
   *  DUTs  *
   **********/
  for (genvar c = 0; unsigned'(c) < NumActiveCores; c++) begin : gen_qnodes

    // generate select signal for stream xbar according to address
    // addr = 32 bit
    // addr[31:8] indicates TCDM bank to pick
    // addr[7:0]  is address in TCDM bank
    assign select_tcdm_bank[c] = tile_req[c].addr[TCDMAddrMemWidth + SelTcdmWidth-1:TCDMAddrMemWidth];

    assign tile_req_xbar_in[c].addr         = tile_req[c].addr;
    assign tile_req_xbar_in[c].write        = tile_req[c].write;
    assign tile_req_xbar_in[c].amo          = tile_req[c].amo;
    assign tile_req_xbar_in[c].wdata        = tile_req[c].wdata;
    assign tile_req_xbar_in[c].be           = tile_req[c].be;
    assign tile_req_xbar_in[c].meta.meta_id = tile_req[c].meta.meta_id;
    assign tile_req_xbar_in[c].meta.lrwait  = tile_req[c].meta.lrwait;

    // directly wire part of meta id not needed in qnode to stream_xbar
    assign tile_req_xbar_in[c].meta.ini_addr = get_metadata_from_core_id(c).ini_addr;
    assign tile_req_xbar_in[c].meta.tile_id  = get_metadata_from_core_id(c).tile_id;
    assign tile_req_xbar_in[c].meta.core_id  = get_metadata_from_core_id(c).core_id;


    lrwait_qnode #(
      .metadata_t   (meta_id_t)
    ) i_lrwait_qnode (
        .clk_i              (clk                         ),
        .rst_ni             (rst_n                       ),

        // TCDM Ports
        // Snitch side
        // requests
        .snitch_qaddr_i     (snitch_req[c].addr          ),
        .snitch_qwrite_i    (snitch_req[c].write         ),
        .snitch_qamo_i      (snitch_req[c].amo           ),
        .snitch_qdata_i     (snitch_req[c].wdata         ),
        .snitch_qstrb_i     (snitch_req[c].be            ),
        .snitch_qid_i       (snitch_req[c].meta.meta_id  ),
        .snitch_qvalid_i    (snitch_req_valid[c]         ),
        .snitch_qready_o    (snitch_req_ready[c]         ),

        // responses
        .snitch_pdata_o     (snitch_resp[c].rdata        ),
        .snitch_perror_o    (/*Unused*/                  ),
        .snitch_pid_o       (snitch_resp[c].meta.meta_id ),
        .snitch_pvalid_o    (snitch_resp_valid[c]        ),
        .snitch_pready_i    (snitch_resp_ready[c]        ),

        // Interconnect side
        // TCDM ports
        // requests
        .tile_qaddr_o       (tile_req[c].addr            ),
        .tile_qwrite_o      (tile_req[c].write           ),
        .tile_qamo_o        (tile_req[c].amo             ),
        .tile_qdata_o       (tile_req[c].wdata           ),
        .tile_qstrb_o       (tile_req[c].be              ),
        .tile_qid_o         (tile_req[c].meta.meta_id    ),
        .tile_qlrwait_o     (tile_req[c].meta.lrwait     ),
        .tile_qvalid_o      (tile_req_valid_o[c]         ),
        .tile_qready_i      (tile_req_ready_i[c]         ),

        // responses
        .tile_pdata_i       (tile_resp[c].rdata          ),
        .tile_perror_i      (/*Unused*/                  ),
        .tile_pid_i         (tile_resp[c].meta.meta_id   ),
        .tile_plrwait_i     (tile_resp[c].meta.lrwait    ),
        .tile_pvalid_i      (tile_resp_valid[c]          ),
        .tile_pready_o      (tile_resp_ready[c]          )
    );
  end // for (genvar c = 0; unsigned'(c) < NumActiveCores; c++)

  for (genvar s = 0; unsigned'(s) < 1; s++) begin : gen_stream_xbar

    stream_xbar #(
      .NumInp   (NumActiveCores   ),
      .NumOut   (NumTcdmBanks     ),
      .payload_t(tcdm_req_t      )
    ) i_interconnect_req (
      .clk_i  (clk                         ),
      .rst_ni (rst_n                       ),
      .flush_i(1'b0                        ),
      // External priority flag
      .rr_i   ('0                          ),
      // Master
      .data_i (tile_req_xbar_in            ),
      .valid_i(tile_req_valid_o            ),
      .ready_o(tile_req_ready_i            ),
      .sel_i  (select_tcdm_bank            ),
      // Slave
      .data_o (tcdm_req                    ),
      .valid_o(tcdm_req_valid              ),
      .ready_i(tcdm_req_ready              ),
      .idx_o  (/* Unused */                )
    );

    stream_xbar #(
      .NumInp   (NumTcdmBanks   ),
      .NumOut   (NumActiveCores     ),
      .payload_t (tcdm_resp_t)
    ) i_interconnect_resp (
      .clk_i  (clk                         ),
      .rst_ni (rst_n                       ),
      .flush_i(1'b0                        ),
      // External priority flag
      .rr_i   ('0                          ),
      // Master
      .data_i (tcdm_resp                   ),
      .valid_i(tcdm_resp_valid             ),
      .ready_o(tcdm_resp_ready             ),
      .sel_i  (select_qnode                ),
      // Slave
      .data_o (tile_resp                   ),
      .valid_o(tile_resp_valid             ),
      .ready_i(tile_resp_ready             ),
      .idx_o  (/* Unused */                )
    );
  end: gen_stream_xbar


  for (genvar t = 0; unsigned'(t) < NumTcdmBanks; t++) begin : gen_tcdms
    tcdm_adapter #(
        .AddrWidth     (TCDMAddrMemWidth),
        .DataWidth     (DataWidth       ),
        .metadata_t    (bank_metadata_t ),
        .LrScEnable    (LrScEnable      ),
        .LrWaitEnable  (LrWaitEnable    ),
        .NumLrWaitAddr (NumLrWaitAddr   ),
        .RegisterAmo   (1'b0            )
    ) i_tcdm_adapter (
        .clk_i       (clk                                    ),
        .rst_ni      (rst_n                                  ),
        .in_valid_i  (tcdm_req_valid[t]                      ),
        .in_ready_o  (tcdm_req_ready[t]                      ),
        .in_address_i(tcdm_req[t].addr[TCDMAddrMemWidth-1:0] ),
        .in_amo_i    (tcdm_req[t].amo                        ),
        .in_write_i  (tcdm_req[t].write                      ),
        .in_wdata_i  (tcdm_req[t].wdata                      ),
        .in_meta_i   (tcdm_req[t].meta                       ),
        .in_be_i     (tcdm_req[t].be                         ),
        .in_valid_o  (tcdm_resp_valid[t]                     ),
        .in_ready_i  (tcdm_resp_ready[t]                     ),
        .in_rdata_o  (tcdm_resp[t].rdata                     ),
        .in_meta_o   (tcdm_resp[t].meta                      ),
        .out_req_o   (sram_req_valid[t]                      ),
        .out_add_o   (sram_req_addr[t]                       ),
        .out_write_o (sram_req_write[t]                      ),
        .out_wdata_o (sram_req_wdata[t]                      ),
        .out_be_o    (sram_req_be[t]                         ),
        .out_rdata_i (sram_resp_rdata[t]                     )
    );

    assign select_qnode[t] = get_core_id_as_logic(tcdm_resp[t].meta);

    // Bank
    tc_sram #(
      .DataWidth (DataWidth           ),
      .NumWords  (2**TCDMAddrMemWidth ),
      .NumPorts  (1                   ),
      .SimInit   ("ones"              )
    ) mem_bank (
      .clk_i   (clk                ),
      .rst_ni  (rst_n              ),
      .req_i   (sram_req_valid[t]  ),
      .we_i    (sram_req_write[t]  ),
      .addr_i  (sram_req_addr[t]   ),
      .wdata_i (sram_req_wdata[t]  ),
      .be_i    (sram_req_be[t]     ),
      .rdata_o (sram_resp_rdata[t] )
    );
  end

  // +++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
  // Convenience functions
  // +++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++

  function logic [CoreIdWidth-1:0] get_core_id_as_logic(input bank_metadata_t meta);
    // TODO test for more different configutrations
    logic [CoreIdWidth-1:0]    abs_core_id;
    abs_core_id = '0;

    if (meta.ini_addr[IniAddrWidth-1] == 1'b0) begin
      // the core is in the local tile
      // IniAddr = {0, core_id}

      abs_core_id = meta.ini_addr[IniAddrWidth-2:0];

    end else begin
      // core_id is meta data without remote/local tile bit
      // and without lrwait bit
      abs_core_id = meta[MetaWidth-2:1];
    end // else: !if(meta.ini_addr[IniAddrWidth-1] == 1'b0)

    return abs_core_id;
  endfunction // get_core_id_as_logic

  function int get_core_id_as_int(input bank_metadata_t meta);
    automatic int core_id = get_core_id_as_logic(.meta(meta));
    return core_id;
  endfunction; // get_core_id_as_int


  function bank_metadata_t get_metadata_from_core_id(input int abs_core_id);
    bank_metadata_t meta;

    meta = '0;

    if (abs_core_id < 4) begin
      // define those cores as being in the local tile
      meta.ini_addr = abs_core_id;
      meta.ini_addr[IniAddrWidth-1] = 1'b0;
    end else begin
      meta[MetaWidth-1:1] = abs_core_id;
      meta.ini_addr[IniAddrWidth-1] = 1'b1;
    end
    return meta;
  endfunction; // get_metadata_from_core_id

  // compare meta_ids and determine if they are coming from the same core
  function int match_metadata_for_core_id(input bank_metadata_t meta1,
                                          input bank_metadata_t meta2);

    automatic int core_id1 = get_core_id_as_int(.meta(meta1));
    automatic int core_id2 = get_core_id_as_int(.meta(meta2));

    if (core_id1 == core_id2) begin
      return 1;
    end else begin
      return 0;
    end
  endfunction // match_meta_id_for_core_id


class TcdmRequest;
  addr_t            addr;
  tile_core_id_t    core_id;
  bank_metadata_t   meta;

  data_t            data;
  amo_t             amo;
  logic             wen;
  strb_t            be;

  local int         core_index;


  function new(input       req_addr,
               input       data_t req_data,
               input       amo_t req_amo,
               input logic req_wen,
               input       strb_t req_be,
               input int   core_id);
    addr = req_addr;

    data = req_data;
    wen = req_wen;
    amo = req_amo;
    be = req_be;
    core_index = core_id;

    meta = get_metadata_from_core_id(.abs_core_id(core_index));
  endfunction; // new

  function void display();
    $display( "Send request");
    $display( "%-30s %h","TCDM address:", this.addr);
    $display( "%-30s %h","data:", this.data);
    $display( "%-30s %h","write_en:", this.wen);
    $display( "%-30s %h","be:", this.be);
    $display( "%-30s %h","AMO:", this.amo);
    $display( "%-30s %b","meta:", this.meta);
    $display( "%-30s %b","abs_core_id:", this.core_index);
  endfunction
endclass : TcdmRequest // TcdmRequest


  function void pass_request_to_goldenmodel_tcdm(input TcdmRequest req);

    automatic bank_addr_t     addr     = req.addr[TCDMAddrMemWidth-1:0];
    automatic logic           wen      = req.wen;
    automatic amo_t           amo      = req.amo;
    automatic data_t          data     = req.data;
    automatic bank_metadata_t metadata = req.meta;

    automatic int tcdm_index = unsigned'(req.addr[TCDMAddrMemWidth + SelTcdmWidth-1:TCDMAddrMemWidth]);

    if (VERBOSE) begin
      // $display( "%s %h ||  %s %b ||  %s %b ",
      //           "request:",  amo,
      //           "metadata:", metadata,
      //           "address",   addr);
    end
    unique case (amo)
      4'hC: goldenmodel_tcdm[tcdm_index].load_reserved(.addr(addr),
                                                       .metadata(metadata));
      4'hD: goldenmodel_tcdm[tcdm_index].store_conditional(.addr(addr),
                                                           .metadata(metadata),
                                                           .data(data));
      4'h0: begin
        if (wen) begin
          goldenmodel_tcdm[tcdm_index].write_access(.addr(addr), .data(data));
        end else begin
          goldenmodel_tcdm[tcdm_index].read_access(.addr(addr), .metadata(metadata));
        end
      end
      default: $display("Unknown request");
    endcase; // unique case (amo)
  endfunction // pass_request_to_goldenmodel_tcdm


typedef enum logic [1:0] {
  Active        = 2'h0,
  WaitForResp   = 2'h1,
  WaitForLRResp = 2'h2,
  DoSCNext      = 2'h3
} core_status_t;

// Description:
// Draw a random core id and generate requests in a fixed order
// A request is one of the following:
// - Read access
// - Write access
// - Load reserved
// - Store conditional
// A core can only send the next request when a response to the previous
// request has been received
class Generator;

  core_status_t                 core_status;
  bank_metadata_t               core_metadata;

  rand addr_t                   rand_addr;
  rand data_t                   rand_data;

  int                           random_draw;

  local int                     core_index;


  constraint c_generator {
    if (FULL_RANDOM_TEST) {
      // pick a random address from possible addresses
      rand_addr > 0;
      rand_addr < NumTcdmBanks * TCDMSizePerBank;
      // generate random data
      rand_data > 0;
      rand_data < 32000;
    }
    else {
      rand_addr inside {1, 2, 3, 520};
      // generate random data
      rand_data > 0;
      rand_data < 32000;
    }
  }

  function new(input int core_id);
    core_index = core_id;
    this.core_status = Active;

  endfunction; // new

  task generate_requests();
    fork
      // spawn as a thread but make the following sequential
      begin
        for (int i = 0; i < NumIterations; i++) begin
          generate_random_request(.iteration(i));
        end
        // if the last request was a LR, do a SC so that
        // other cores are unblocked
        if (core_status == DoSCNext) begin
          store_conditional(.addr(rand_addr),.data(rand_data),.core_id(core_index));
          core_status = WaitForResp;
        end
        // tell respdriver you are finished

        #(1000*ClockPeriod);
        respdriver[core_index].finished_generator = 1'b1;
      end
    join_none
  endtask

  task generate_random_request(input int iteration);

    // only generate SC request AFTER a LR has been issued
    // TODO store address during LR for subsequent LR
    if (VERBOSE) begin
      $display("iteration %d core %d", iteration, core_index);
      $display("status %d core %d", core_status, core_index);
    end

    wait((core_status == Active) || (core_status == DoSCNext))

    unique case (core_status)
      Active: begin
        // get index for random instruction
        random_draw = $urandom_range(0);
        // get random address and random number
        if(!this.randomize()) begin
          $display("Failed to randomize Generator class.");
          $finish(1);
        end
        unique case (random_draw)
          0: begin
            load_reserved(.addr(rand_addr),.data(rand_data),.core_id(core_index));
            core_status = WaitForLRResp;
          end
          1: begin
            write_memory(.addr(rand_addr),.data(rand_data),.core_id(core_index));
            // do not expect a response from write
            core_status = Active;
          end
          2: begin
            read_memory(.addr(rand_addr),.data(rand_data),.core_id(core_index));
            core_status = WaitForResp;
          end
          default: $display("invalid number drawn");
        endcase // case (random_draw)
      end
      DoSCNext: begin
        // send store conditional
        store_conditional(.addr(rand_addr),.data(rand_data),.core_id(core_index));
        core_status = WaitForResp;
      end
      default: begin
        $display("Invalid core status");
      end
    endcase // unique case (core_status[core_index])
  endtask; // generate_random_request

endclass : Generator

// Description:
// send requests by handshaking into module
// each Qnode has his own driver
class InputDriver;
  // shorthand for core_index
  local int core_index;
  bank_metadata_t meta;

  function new(input int core_id);
    // initialize qnode interface
    core_index = core_id;
    snitch_req[core_index] = '0;
    snitch_req_valid[core_index] = '0;

    // tie metadata that is generated in interconnect
    // to core id of core driving
    meta = get_metadata_from_core_id(.abs_core_id(core_index));
    snitch_req[core_index].meta.ini_addr = meta.ini_addr;
    snitch_req[core_index].meta.tile_id  = meta.tile_id;
    snitch_req[core_index].meta.core_id  = meta.core_id;

  endfunction

  task send_request_from_core(input TcdmRequest req);
    @(posedge clk);
    #(TA);

    snitch_req[core_index].addr         = req.addr;
    snitch_req[core_index].write        = req.wen;
    snitch_req[core_index].amo          = req.amo;
    snitch_req[core_index].wdata        = req.data;
    snitch_req[core_index].be           = req.be;
    snitch_req[core_index].meta.meta_id = req.meta.meta_id;

    snitch_req_valid[core_index] = 1'b1;
    // rest of metadata is not needed in qnode, pass directly to queue
    // tile_req_xbar_in[core_index] = tile_req[core_index];

    do begin
      wait(snitch_req_ready[core_index]);
      #(TT-TA);
    end while (snitch_req_ready[core_index] == 1'b0);

    pass_request_to_goldenmodel_tcdm(.req(req));

    @(posedge clk);
    #(TA);
    // set values back to 0
    snitch_req_valid[core_index] = 1'b0;
    snitch_req[core_index]       = '0;
    #(TT-TA);
    @(posedge clk);
  endtask // send_request_from_core

endclass : InputDriver;

// Description:
// Handshake signals from Qnodes into actual responses for each core.
class RespDriver;

  logic finished_generator;

  data_t actual_data_resp[$];
  bank_metadata_t actual_metadata_resp[$];

  // expected data which is written by golden model
  data_t expected_data_resp[$];
  bank_metadata_t expected_metadata_resp[$];

  local int core_index;

  function new(input int core_id);
    if(VERBOSE) begin
      $display("listening for core %d", core_id);
    end

    core_index = core_id;

    finished_generator = 1'b0;
  endfunction; // new

  task listen();
    fork
      while (!finished_generator) begin

        if(snitch_resp_valid[core_index]) begin
          #(TA);
          snitch_resp_ready[core_index] = 1'b1;

          // get responses from qnode
          #(TT-TA);
          snitch_resp_out[core_index] = snitch_resp[core_index];
          snitch_resp_out[core_index].meta          = snitch_resp[core_index].meta;
          snitch_resp_out[core_index].meta.lrwait   = tile_resp[core_index].meta.lrwait;
          snitch_resp_out[core_index].meta.ini_addr = tile_resp[core_index].meta.ini_addr;
          snitch_resp_out[core_index].meta.core_id  = tile_resp[core_index].meta.core_id;
          snitch_resp_out[core_index].meta.tile_id  = tile_resp[core_index].meta.tile_id;

          actual_data_resp.push_back(snitch_resp[core_index].rdata);
          actual_metadata_resp.push_back(snitch_resp_out[core_index].meta);

          // activate core again
          if (generator[core_index].core_status == WaitForResp) begin
            // core received response
            generator[core_index].core_status = Active;
          end else if (generator[core_index].core_status == WaitForLRResp) begin
            // core received LRResp, do SC next
            generator[core_index].core_status = DoSCNext;
          end

          @(posedge clk);
          #(TA);
          snitch_resp_ready[core_index] = 1'b0;
          @(posedge clk);
        end // if (snitch_resp_valid[core_index])

        #(TA);
        @(posedge clk);
      end // while (!finished_generator)
    join_none
  endtask
endclass : RespDriver;

  typedef struct packed {
    meta_id_t meta_id;
    bank_addr_t addr;
  } reservation_t;

 typedef bank_metadata_t reservation_queue_t[$:LrWaitQueueSize];

// Description:
// Observe req and resp lines and compare stimuli to golden model.
// The golden model consists of a queue for every address where reservations
// can be stored
class GoldenTCDM;

  // create a queue for each adress that is reserved
  reservation_queue_t reservation_queues[bank_addr_t];
  logic               reservation_queues_valid[bank_addr_t];

  data_t              resp_data;
  bank_metadata_t     resp_metadata;

  // store data in a mock memory to compare to responses obtained from SRAM
  data_t              mock_memory[bank_addr_t];

  // check size of queue before inserting a new reservation
  bank_addr_t         check_size;
  int                 current_queue_size;
  int                 number_of_active_queues;
  int                 queue_is_full;

  // Golden Model for write access to TCDM
  // Pop the reservation if one was available
  // No response is expected
  function void write_access(input bank_addr_t addr,
                             input data_t data);
    if (VERBOSE) begin
      $display("write access addr %h ", addr);
    end
    // add write access to mock memory
    mock_memory[addr] = data;

    // pop reservation from queue if reservation existed
    // for same address
    if (reservation_queues.exists(addr) &&
        reservation_queues[addr].size() != 0) begin
      if (VERBOSE) begin
        $display("set reservation to invalid");
      end
      reservation_queues_valid[addr]=1'b0;
      // void'(reservation_queues[addr].pop_front());
    end
  endfunction; // write_access

  // Golden model for read access to TCDM
  function void read_access(input bank_addr_t addr,
                            input bank_metadata_t metadata);
    automatic int req_core_id = get_core_id_as_int(.meta(metadata));
    if (VERBOSE) begin
      $display("read access");
    end
    if (mock_memory.exists(addr)) begin
      resp_data = mock_memory[addr];
    end else begin
      resp_data = 32'hffffffff;
    end
    respdriver[req_core_id].expected_data_resp.push_back(resp_data);
    respdriver[req_core_id].expected_metadata_resp.push_back(metadata);
  endfunction; // read_access

  function void load_reserved(input bank_addr_t addr,
                              input bank_metadata_t metadata);
    automatic int req_core_id = get_core_id_as_int(.meta(metadata));
    if (VERBOSE) begin
      $display("load reserved addr %h metadata %h, core_id %d", addr, metadata, req_core_id);
    end

    // check if value loaded has already been written or if we output default
    // value
    if (mock_memory.exists(addr)) begin
      resp_data = mock_memory[addr];
    end else begin
      resp_data = 32'hffffffff;
    end

    // check queue size by adding sizes of all queues in associative array
    // to not exceed total queue size

    // if reservation_queues is not empty, check the size of each entry
    if (reservation_queues.first(check_size)) begin
      current_queue_size = 0;
      number_of_active_queues = 0;

      do begin
        if (reservation_queues[check_size].size() >= 1) begin
          // there is a reservation queue for the current address
          number_of_active_queues += 1;
        end

        current_queue_size += reservation_queues[check_size].size();
      end while (reservation_queues.next(check_size) >= 1);
      if (VERBOSE) begin
        $display("Current size of reservation queue %d ", current_queue_size);
        $display("Number of active queues %d ", number_of_active_queues);
      end
      if ((current_queue_size < LrWaitQueueSize) &&
          (number_of_active_queues < NumLrWaitAddr)) begin
        // there is an empty queue node available
        queue_is_full = 0;
      end else if (reservation_queues.exists(addr)) begin
        // all queue nodes are occupied, but an occupied node contains the same
        // address
        if (reservation_queues[addr].size() == 0) begin
          // this case can never happen?
          queue_is_full = 1;
        end else begin
          queue_is_full = 0;
        end
      end else begin
        // all nodes are occupied and no queue node matches the current address
        queue_is_full = 1;
      end
    end

    // Check if queue is full, else ignore reservation and send out response directly
    if(!queue_is_full) begin
      // place reservation in queue
      if (reservation_queues.exists(addr)) begin
        // has a reservation already been placed in the queue?
        if (reservation_queues[addr].size() == 0) begin
          if (VERBOSE) begin
            $display("reservation queue empty, responsen sending");
            $display("Push reservation with metadata %b", metadata);
          end

          // response can be sent
          respdriver[req_core_id].expected_data_resp.push_back(resp_data);
          respdriver[req_core_id].expected_metadata_resp.push_back(metadata);

          // push reservation onto LRWait queue
          reservation_queues[addr].push_back(metadata);
          reservation_queues_valid[addr]=1'b1;

        // check if core issuing LR already holds a reservation
        end else if (match_metadata_for_core_id(.meta1(reservation_queues[addr][0]),
                                                .meta2(metadata))) begin
          if (VERBOSE) begin
            $display("Same core issued another reservation.");
          end
          // core at head of queue issued another reservation
          respdriver[req_core_id].expected_data_resp.push_back(resp_data);
          respdriver[req_core_id].expected_metadata_resp.push_back(metadata);
          reservation_queues_valid[addr]=1'b1;
        end else if (reservation_queues[addr].size() == 1 &&
                     reservation_queues_valid[addr] == 1'b0) begin
          // the core was the only one in the queue and his head node has been
          // invalidated by a write, the next core can overwrite the reservation
          $display("It happened!");

          // pop the old reservation
          void'(reservation_queues[addr].pop_front());

          // response can be sent
          respdriver[req_core_id].expected_data_resp.push_back(resp_data);
          respdriver[req_core_id].expected_metadata_resp.push_back(metadata);

          // push reservation onto LRWait queue
          reservation_queues[addr].push_back(metadata);
          reservation_queues_valid[addr]=1'b1;

        end else begin
          // there already is somebody in the queue
          // append yourself to the queue
          // push reservation onto LRWait queue
          reservation_queues[addr].push_back(metadata);
          if (VERBOSE) begin
            $display("There already is someone in the queue, wait for response.");
          end
        end
      end else begin // if (reservation_queues.exists(addr))
        if (VERBOSE) begin
          $display("first reservation");
        end
        // the adress does not exist in the queue, thus it is the first reservation
        respdriver[req_core_id].expected_data_resp.push_back(resp_data);
        respdriver[req_core_id].expected_metadata_resp.push_back(metadata);

        // push reservation onto LRWait queue
        reservation_queues[addr].push_back(metadata);
        reservation_queues_valid[addr]=1'b1;
      end // else: !if(reservation_queues.exists(addr))
    end else begin
      // queue is full, we sent the LR response directly
      if (VERBOSE) begin
        $display("Queue is full, no reservation placed.");
      end
      respdriver[req_core_id].expected_data_resp.push_back(resp_data);
      respdriver[req_core_id].expected_metadata_resp.push_back(metadata);
    end

  endfunction // load_reserved

  function void store_conditional(input bank_addr_t addr,
                                  input bank_metadata_t metadata,
                                  input data_t data);
    automatic int req_core_id = get_core_id_as_int(.meta(metadata));
    automatic int resp_core_id;

    if (VERBOSE) begin
      $display("store conditional addr %h metadata %h, core_id %d", addr, metadata, req_core_id);
    end

    // check if reservation is valid
    // take head of LR queue

    // check if there is a queue for the current address
    if (reservation_queues.exists(addr)) begin
      if (VERBOSE) begin
        $display("store conditional reservation %h ", reservation_queues[addr][0]);
      end

      if (reservation_queues[addr].size() != 0) begin
        if (match_metadata_for_core_id(.meta1(reservation_queues[addr][0]),
                                       .meta2(metadata))) begin
          // check if the reservation has not been invalidated by a write
          if (reservation_queues_valid[addr] == 1'b1) begin
            // metadata matches, issue SC
            mock_memory[addr] = data;
            respdriver[req_core_id].expected_data_resp.push_back(1'b0);
            respdriver[req_core_id].expected_metadata_resp.push_back(metadata);
            if (VERBOSE) begin
              $display("store conditional succeeded");
            end
          end else begin
            // reservation was invalidated, SC failed
            respdriver[req_core_id].expected_data_resp.push_back(1'b1);
            respdriver[req_core_id].expected_metadata_resp.push_back(metadata);
            if (VERBOSE) begin
              $display("store conditional failed due to rogue write");
            end
          end

          // pop reservation
          void'(reservation_queues[addr].pop_front());
          if (reservation_queues[addr].size() != 0) begin

            resp_metadata = reservation_queues[addr][0];
            resp_core_id = get_core_id_as_int(.meta(resp_metadata));
            if (VERBOSE) begin
              $display("Send out load reserved to core %d", resp_core_id);
              $display("status %d", generator[resp_core_id].core_status);
            end
            reservation_queues_valid[addr]=1'b1;

            respdriver[resp_core_id].expected_data_resp.push_back(mock_memory[addr]);
            respdriver[resp_core_id].expected_metadata_resp.push_back(resp_metadata);
          end
        end else begin
          // sc failed since metadata did not match head of queue
          if (VERBOSE) begin
            $display("store conditional failed");
          end
          respdriver[req_core_id].expected_data_resp.push_back(1'b1);
          respdriver[req_core_id].expected_metadata_resp.push_back(metadata);
        end
      end else begin
        // SC failed since queue for address is empty
        if (VERBOSE) begin
          if (reservation_queues[addr].size() != 0) begin
            $display("metadata %b reservation in queue %b", metadata, reservation_queues[addr][0]);
          end else begin
            $display("metadata %b no reservation was placed", metadata);
          end
          $display("store conditional failed");
        end
        respdriver[req_core_id].expected_data_resp.push_back(1'b1);
        respdriver[req_core_id].expected_metadata_resp.push_back(metadata);
      end
    end else begin
      // sc failed since there is no queue for the address
      if (VERBOSE) begin
        $display("store conditional failed");
      end
      respdriver[req_core_id].expected_data_resp.push_back(1'b1);
      respdriver[req_core_id].expected_metadata_resp.push_back(metadata);
    end
  endfunction; // store_conditional

endclass : GoldenTCDM;


/**************
 * Scoreboard *
 **************/
class Scoreboard;
  // Description:

  function void compare_responses();
    automatic int total_success_count = 0;
    automatic int total_resp_count = 0;
    $display("++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++");
    $display("+                        RESULTS                           +");
    $display("++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++");

    // for each core check if expected and received responses match
    for (int c = 0; c < NumActiveCores; c++) begin
      automatic int number_of_resp = respdriver[c].expected_data_resp.size();
      automatic int success_counter = 0;

      if (number_of_resp !=  respdriver[c].actual_data_resp.size()) begin
        $display("NUMBER OF EXPECTED RESPONSES DOES NOT MATCH RECEIVED RESPONSES!");
        $display("Expected %2d != %2d Actual responses for core %d", number_of_resp,
                 respdriver[c].actual_data_resp.size(), c);
        $display("++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++");
        if (respdriver[c].actual_data_resp.size() > number_of_resp) begin
          number_of_resp = respdriver[c].actual_data_resp.size();
        end
      end

      for (int i=0; i < number_of_resp; i++) begin
        if (respdriver[c].expected_data_resp[i] == respdriver[c].actual_data_resp[i] &&
            respdriver[c].expected_metadata_resp[i] == respdriver[c].actual_metadata_resp[i]) begin
          success_counter += 1;
          if (VERBOSE) begin
            $display("PASS");
          end
        end else begin
          if (VERBOSE) begin
            $display("%-30s %s != %s","FAIL","Expected","Actual");
            $display( "%-30s %h != %h","Data", respdriver[c].expected_data_resp[i],
                      respdriver[c].actual_data_resp[i]);
            $display( "%-30s %b != %b","Metadata", respdriver[c].expected_metadata_resp[i],
                      respdriver[c].actual_metadata_resp[i]);
            $display("++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++");
          end
        end
      end // for (int i=0; i < number_of_resp; i++)
      total_success_count += success_counter;
      total_resp_count    += number_of_resp;
      if (VERBOSE) begin
        $display("[%2d/%2d] responses match for core %d", success_counter, number_of_resp, c);
      end
    end // for (int c = 0; c < NumActiveCores; c++)
    $display("[%2d/%2d] responses match", total_success_count, total_resp_count);
    $display("[EOC] Simulation ended at %t (retval = %0d).",
             $time, !(total_success_count == total_resp_count));
  endfunction // compare
endclass // Scoreboard

  InputDriver inpdriver[NumActiveCores-1:0];
  TcdmRequest req[NumActiveCores-1:0];
  RespDriver  respdriver[NumActiveCores-1:0];
  Generator   generator[NumActiveCores-1:0];

  GoldenTCDM goldenmodel_tcdm[NumTcdmBanks-1:0];

  Scoreboard scrbrd;

  task store_conditional(input addr_t  addr,
                         input  data_t data,
                         input int     core_id);
    req[core_id].addr    = addr;
    req[core_id].data    = data;
    req[core_id].amo     = 4'hD;
    req[core_id].wen     = 1'b0;
    req[core_id].be      = 4'hF;
    req[core_id].core_id = core_id;

    inpdriver[core_id].send_request_from_core(req[core_id]);
  endtask // store_conditional

  task load_reserved(input addr_t addr,
                     input data_t data,
                     input int    core_id);
    req[core_id].addr    = addr;
    req[core_id].data    = data;
    req[core_id].amo     = 4'hC;
    req[core_id].wen     = 1'b0;
    req[core_id].be      = 4'h0;
    req[core_id].core_id = core_id;

    inpdriver[core_id].send_request_from_core(req[core_id]);
  endtask // load_reserved

  task write_memory( input addr_t addr,
                     input data_t data,
                     input int    core_id);
    req[core_id].addr    = addr;
    req[core_id].data    = data;
    req[core_id].amo     = 4'h0;
    req[core_id].wen     = 1'b1;
    req[core_id].be      = 4'hF;
    req[core_id].core_id = core_id;

    inpdriver[core_id].send_request_from_core(req[core_id]);
  endtask // write_memory

  task read_memory( input addr_t addr,
                    input data_t data,
                    input int    core_id);
    req[core_id].addr    = addr;
    req[core_id].data    = data;
    req[core_id].amo     = 4'h0;
    req[core_id].wen     = 1'b0;
    req[core_id].be      = 4'h0;
    req[core_id].core_id = core_id;

    inpdriver[core_id].send_request_from_core(req[core_id]);
  endtask // read_memory


  /**************
   * Simulation *
   **************/

  initial begin : req_driver
    // Wait for reset.
    wait (rst_n);
    @(posedge clk);
    snitch_req = '0;
    snitch_resp_ready = '0;

    // factory
    for (int c = 0; c < NumActiveCores; c++) begin
      inpdriver[c]  = new(.core_id(c));
      respdriver[c] = new(.core_id(c));
      generator[c]  = new(.core_id(c));
      req[c]        = new(.req_addr('0), .req_data('0),
                          .req_amo(4'h0),
                          .req_wen(1'b0),
                          .req_be(4'h0),
                          .core_id(c));
    end

    for (int t = 0; t < NumTcdmBanks; t++) begin
      goldenmodel_tcdm[t] = new();
    end

    for (int d = 0; d < NumActiveCores; d++) begin
      respdriver[d].listen();
    end

    // spawn all generator threads and wati for each one to finish
    for (int d = 0; d < NumActiveCores; d++) begin
      generator[d].generate_requests();
    end

    // wait for all threads to finish
    wait fork;

    scrbrd.compare_responses();

    $finish(0);
  end // req_driver

endmodule : tcdm_adapter_tb
