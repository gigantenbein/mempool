// Copyright 2021 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Author: Marc Gantenbein, ETH Zurich

module tcdm_adapter_tb;

  /*****************
   *  Definitions  *
   *****************/

  timeunit      1ns;
  timeprecision 1ps;

  import mempool_pkg::*;
  import snitch_pkg::MetaIdWidth;
  import cf_math_pkg::idx_width;

  localparam ClockPeriod = 1ns;
  localparam TA          = 0.2ns; // Application time
  localparam TT          = 0.8ns; // Test time

  // set number of cores sending requests
  localparam int   NUMACTIVECORES   = 256;
  // set number of rounds where each core can send a request if he is active
  localparam int   NUMITERATIONS    = 2000;
  // randomize address and payloads for TCDM
  localparam logic FULL_RANDOM_TEST = 0;
  // print requests sent and received
  localparam logic VERBOSE          = 1;
  // if valid, delay raising of ready flag at output of TCDM adapter
  // by a random duration
  localparam logic STALL_OUTPUT     = 1;

  // overrides param from mempool_pkg
  localparam int   LrWaitQueueSize  = 256;

 /********************************
   *  Clock and Reset Generation  *
   ********************************/

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
  * PARAMS
  ****************/
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
  tcdm_req_t     [NUMACTIVECORES-1:0]  snitch_req;

  logic [NUMACTIVECORES-1:0] snitch_req_valid;
  logic [NUMACTIVECORES-1:0] snitch_req_ready;

  tcdm_resp_t [NUMACTIVECORES-1:0] snitch_resp;
  tcdm_resp_t [NUMACTIVECORES-1:0] snitch_resp_out;
  logic       [NUMACTIVECORES-1:0] snitch_resp_valid;
  logic       [NUMACTIVECORES-1:0] snitch_resp_ready;

  // signal from qnode to interconnect
  tcdm_req_t  [NUMACTIVECORES-1:0] tile_req;
  // needed for driving metadata that does not pass through lrwait_qnode
  tcdm_req_t  [NUMACTIVECORES-1:0] tile_req_queue_in;
  logic [NUMACTIVECORES-1:0]       tile_req_valid_o;
  logic       [NUMACTIVECORES-1:0] tile_req_ready_i;


  tcdm_resp_t [NUMACTIVECORES-1:0] tile_resp;
  logic       [NUMACTIVECORES-1:0] tile_resp_valid;
  logic       [NUMACTIVECORES-1:0] tile_resp_ready;


  // signals for TCDM
  tcdm_req_t     tcdm_req;
  logic          tcdm_req_valid, tcdm_req_ready;
  tcdm_resp_t    tcdm_resp;
  logic          tcdm_resp_valid, tcdm_resp_ready;

  // signals to sram
  logic           sram_req_valid;
  logic           sram_req_write;
  bank_addr_t     sram_req_addr;
  data_t          sram_req_wdata;
  data_t          sram_resp_rdata;
  strb_t          sram_req_be;

  /**********
   *  DUTs  *
   **********/
  for (genvar c = 0; unsigned'(c) < NUMACTIVECORES; c++) begin : gen_qnodes

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
  end // for (genvar c = 0; unsigned'(c) < NUMACTIVECORES; c++)

  tcdm_adapter #(
      .AddrWidth  (TCDMAddrMemWidth),
      .DataWidth  (DataWidth       ),
      .metadata_t (bank_metadata_t ),
      .LrScEnable (LrScEnable      ),
      .RegisterAmo(1'b0            )
  ) dut (
      .clk_i       (clk                                 ),
      .rst_ni      (rst_n                               ),
      .in_valid_i  (tcdm_req_valid                      ),
      .in_ready_o  (tcdm_req_ready                      ),
      .in_address_i(tcdm_req.addr[TCDMAddrMemWidth-1:0] ),
      .in_amo_i    (tcdm_req.amo                        ),
      .in_write_i  (tcdm_req.write                      ),
      .in_wdata_i  (tcdm_req.wdata                      ),
      .in_meta_i   (tcdm_req.meta                       ),
      .in_be_i     (tcdm_req.be                         ),
      .in_valid_o  (tcdm_resp_valid                     ),
      .in_ready_i  (tcdm_resp_ready                     ),
      .in_rdata_o  (tcdm_resp.rdata                     ),
      .in_meta_o   (tcdm_resp.meta                      ),
      .out_req_o   (sram_req_valid                      ),
      .out_add_o   (sram_req_addr                       ),
      .out_write_o (sram_req_write                      ),
      .out_wdata_o (sram_req_wdata                      ),
      .out_be_o    (sram_req_be                         ),
      .out_rdata_i (sram_resp_rdata                     )
  );

  // Bank
  tc_sram #(
    .DataWidth(DataWidth           ),
    .NumWords (2**TCDMAddrMemWidth ),
    .NumPorts (1                   ),
    .SimInit  ("ones"              )
  ) mem_bank (
    .clk_i  (clk             ),
    .rst_ni (rst_n           ),
    .req_i  (sram_req_valid  ),
    .we_i   (sram_req_write  ),
    .addr_i (sram_req_addr   ),
    .wdata_i(sram_req_wdata  ),
    .be_i   (sram_req_be     ),
    .rdata_o(sram_resp_rdata )
  );

  // ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
  // Convenience functions
  // ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++

  function int get_core_id_from_metadata(input bank_metadata_t meta);
    int abs_core_id;

    if (meta.ini_addr[IniAddrWidth-1] == 1'b0) begin
      // the core is in the local tile
      // IniAddr = {0, core_id}
      abs_core_id = meta.ini_addr[IniAddrWidth-2:0];
    end else begin
      // the core is from a remote tile
      meta.ini_addr[IniAddrWidth-1] = 1'b1;

      // core_id is meta data without remote/local tile bit
      // but without lrwait bit
      abs_core_id = meta[MetaWidth-2:1];
    end
    return abs_core_id;
  endfunction; // get_core_id_from_metadata


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

    automatic int core_id1 = get_core_id_from_metadata(.meta(meta1));
    automatic int core_id2 = get_core_id_from_metadata(.meta(meta2));

    if (core_id1 == core_id2) begin
      return 1;
    end else begin
      return 0;
    end
  endfunction // match_meta_id_for_core_id

    task pass_request_to_monitor(input bank_addr_t     addr,
                               input amo_t           amo,
                               input data_t          data,
                               input logic           wen,
                               input bank_metadata_t metadata);
    if (VERBOSE) begin
      $display( "%s %h ||  %s %b ||  %s %b ",
                "request:",amo,
                "metadata:", metadata,
                "address", addr);
    end
    unique case (amo)
      4'hA: monitor.load_reserved(.addr(addr), .metadata(metadata));
      4'hB: monitor.store_conditional(.addr(addr), .metadata(metadata), .data(data));
      4'h0: begin
        if (wen) begin
          monitor.write_access(.addr(addr), .data(data));
        end else begin
          monitor.read_access(.addr(addr), .metadata(metadata));
        end
      end
      default: $display("Unknown request");
    endcase; // unique case (amo)
  endtask // pass_request_to_monitor


class TcdmRequest;
  bank_addr_t       addr;
  tile_core_id_t    core_id;
  bank_metadata_t   meta;

  data_t            data;
  amo_t             amo;
  logic             wen;
  strb_t            be;

  int               abs_core_id;

  function new(input bank_addr_t req_addr,
               input       data_t req_data,
               input       amo_t req_amo,
               input logic req_wen,
               input       strb_t req_be,
               input int   req_abs_core_id);
    addr = req_addr;

    data = req_data;
    wen = req_wen;
    amo = req_amo;
    be = req_be;
    abs_core_id = req_abs_core_id;

    meta = get_metadata_from_core_id(.abs_core_id(abs_core_id));

    if (VERBOSE) begin
      // this.display();
    end
  endfunction; // new

  function void display();
    $display( "Send request");
    $display( "%-30s %h","TCDM address:", this.addr);
    $display( "%-30s %h","data:", this.data);
    $display( "%-30s %h","write_en:", this.wen);
    $display( "%-30s %h","be:", this.be);
    $display( "%-30s %h","AMO:", this.amo);
    $display( "%-30s %b","meta:", this.meta);
    $display( "%-30s %b","abs_core_id:", this.abs_core_id);
  endfunction
endclass : TcdmRequest // TcdmRequest

// handshake requests from multiple sources by round-robin arbitration
// into queue
class ManyToOneQueue #(
  parameter int  NumInputs   = 1,
  parameter int  InputStall  = 1,
  parameter int  OutputStall = 1
);

  // Inputs:  tile_req, tile_req_valid_o, tile_req_ready_i
  // Outputs: tcmd_req, tcdm_req_valid, tcdm_req_ready
  tcdm_req_t queue_data[$];

  function new();
    tile_req_ready_i  = '0;
    tcdm_req_valid = '0;
    tcdm_req = '0;
  endfunction

  task push_inputs_to_queue();
    fork
      while(1'b1) begin
        for (int c = 0; c < NumInputs; c++) begin
          if (tile_req_valid_o[c] == 1'b1) begin
            // #($urandom_range(0, InputStall)*ClockPeriod);
            @(posedge clk);
            #(TA);
            tile_req_ready_i[c] = 1'b1;

            #(TT-TA);
            tile_req_queue_in[c].addr         = tile_req[c].addr;
            tile_req_queue_in[c].amo          = tile_req[c].amo;
            tile_req_queue_in[c].write        = tile_req[c].write;
            tile_req_queue_in[c].wdata        = tile_req[c].wdata;
            tile_req_queue_in[c].be           = tile_req[c].be;
            tile_req_queue_in[c].meta.meta_id = tile_req[c].meta.meta_id;
            tile_req_queue_in[c].meta.lrwait  = tile_req[c].meta.lrwait;

            this.queue_data.push_back(tile_req_queue_in[c]);

            @(posedge clk);
            #(TA);

            tile_req_ready_i[c] = 1'b0;
            @(posedge clk);
          end
        end // for (int c = 0; i < NumInputs; c++)
        #(TT);
        @(posedge clk);
      end // while (1'b1)
    join_none
  endtask // push_inputs_to_queue

  task pop_output_from_queue();
    fork
      while(1'b1) begin
        wait(this.queue_data.size() > 0);
        @(posedge clk);
        // #($urandom_range(0, OutputStall)*ClockPeriod);
        #(TA);
        tcdm_req_valid = 1'b1;
        tcdm_req = this.queue_data.pop_front();
        wait(tcdm_req_ready == 1'b1);
        #(TT);

        // we only load LR and SC into Monitor
        if (tcdm_req.meta.lrwait == 1'b0) begin
          pass_request_to_monitor(.addr(tcdm_req.addr),
                                  .amo(tcdm_req.amo),
                                  .data(tcdm_req.wdata),
                                  .wen(tcdm_req.write),
                                  .metadata(tcdm_req.meta));
        end
        @(posedge clk);

        #(TA);
        tcdm_req_valid = 1'b0;
        tcdm_req = '0;
        @(posedge clk);
      end
    join_none
  endtask
endclass // ManyToOneQueue

class OneToManyQueue #(
  parameter int  NumOutputs  = 1,
  parameter int  InputStall  = 1,
  parameter int  OutputStall = 1
);

  tcdm_resp_t queue_data[$];
  tcdm_resp_t out_data;
  int    core_id;

  function new();
    tcdm_resp_ready  = '0;
    tile_resp_valid = '0;
    tile_resp = '0;
  endfunction


  // Inputs:  tcdm_resp, tile_resp_ready, tcdm_resp_valid
  // Outputs: tile_resp, tile_resp_valid, tcdm_resp_ready

  task push_input_to_queue();
    fork
      while(1'b1) begin
        wait (tcdm_resp_valid == 1'b1);
        // #($urandom_range(0, InputStall)*ClockPeriod);
        // @(posedge clk);
        #(TA);
        tcdm_resp_ready = 1'b1;

        #(TT-TA);
        this.queue_data.push_back(tcdm_resp);

        @(posedge clk);
        #(TA);
        tcdm_resp_ready = 1'b0;
        @(posedge clk);

      end
    join_none
  endtask // push_inputs_to_queue

  task pop_outputs_from_queue();
    fork
      while(1'b1) begin
        wait(this.queue_data.size() > 0);
        @(posedge clk);
        // get metadata and unique core id
        out_data = this.queue_data.pop_front();
        core_id = get_core_id_from_metadata(out_data.meta);

        #(TA);
        tile_resp_valid[core_id] = 1'b1;
        tile_resp[core_id] = out_data;

        // wait until TT to see if resp ready
        #(TT-TA);
        wait(tile_resp_ready[core_id] == 1'b1);
        @(posedge clk);

        #(TA);
        tile_resp_valid[core_id] = 1'b0;
      end // while (1'b1)
    join_none
  endtask
endclass

typedef enum logic [1:0] {
  Active        = 2'h0,
  WaitForResp   = 2'h1,
  WaitForLRResp = 2'h2,
  DoSCNext      = 2'h3
} core_status_t;

class Generator;
  // Description:
  // Draw a random core id and generate requests in a fixed order
  // A request is one of the following:
  // - Read access
  // - Write access
  // - Load reserved
  // - Store conditional
  // A core can only send the next request when a response to the previous
  // request has been received
  logic [NUMACTIVECORES-1:0]    is_core_active;
  int                           random_core;

  core_status_t                 core_status[NUMACTIVECORES-1:0];
  bank_metadata_t               core_metadata[NUMACTIVECORES-1:0];
  logic                         random_test;

  rand bank_addr_t              rand_addr;
  rand data_t                   rand_data;
  int                           current_core;

  int                           random_draw;


  constraint c_generator {
    if (FULL_RANDOM_TEST) {
      rand_addr > 0;
      rand_addr < 256;
      rand_data > 0;
      rand_data < 32000;
    }
    else {
      rand_addr == 42;
      rand_data == 32'hCAFECAFE;
    }
  }

  function new();
    for (int i = 0; i < NUMACTIVECORES; i++) begin
      this.is_core_active[i] = 1'b1;
      this.core_status[i] = Active;
    end

  endfunction; // new

  task generate_requests();
    fork
      for (int i = 0; i < NUMITERATIONS; i++) begin
        current_core = $urandom_range(NUMACTIVECORES-1);
        generate_random_request(.rand_core(current_core));
      end
    join_none
  endtask

  task generate_random_request(input int rand_core);

    // only generate SC request AFTER a LR has been issued
    // TODO store address during LR for subsequent LR
    // get random address and random number
    if(!this.randomize()) begin
      $display("Failed to randomize Generator class.");
      $finish(1);
    end

    unique case (core_status[rand_core])
      Active: begin
        // get index for random instruction
          random_draw = $urandom_range(0);
          unique case (random_draw)
            0: begin
              load_reserved(.addr(rand_addr),.data(rand_data),.core_id(rand_core));
              core_status[rand_core] = WaitForLRResp;
            end
            2: begin
              // write_memory(.addr(rand_addr),.data(rand_data),.core_id(rand_core));
              // do not expect a response from write
              core_status[rand_core] = Active;
            end
            1: begin
              read_memory(.addr(rand_addr),.data(rand_data),.core_id(rand_core));
              core_status[rand_core] = WaitForResp;
            end
            default: $display("invalid number drawn");
          endcase // case (random_draw)
      end
      WaitForLRResp: begin
        // $display("WaitForLRResp");
        #(ClockPeriod);
      end
      DoSCNext: begin
        // send store conditional
        store_conditional(.addr(rand_addr),.data(rand_data),.core_id(rand_core));
        core_status[rand_core] = WaitForResp;
      end
      WaitForResp: begin
        // $display("WaitForResp");
        #(ClockPeriod);
      end
      default: begin
        $display("Invalid core status");
      end
    endcase // unique case (core_status[rand_core])
    #(ClockPeriod);
  endtask; // generate_random_request

endclass : Generator



class InputDriver;
  // Description:
  // send requests by handshaking into module
  function new();
    // initialize qnode interface
    snitch_req = '0;
    snitch_req_valid = '0;
  endfunction

  task send_request_from_core(input TcdmRequest req);
    @(posedge clk);
    #(TA);
    snitch_req[req.abs_core_id].addr         = req.addr;
    snitch_req[req.abs_core_id].write        = req.wen;
    snitch_req[req.abs_core_id].amo          = req.amo;
    snitch_req[req.abs_core_id].wdata        = req.data;
    snitch_req[req.abs_core_id].be           = req.be;
    snitch_req[req.abs_core_id].meta.meta_id = req.meta.meta_id;

    snitch_req_valid[req.abs_core_id] = 1'b1;

    // rest of metadata is not needed in qnode, pass directly to queue
    tile_req_queue_in[req.abs_core_id].meta.ini_addr = req.meta.ini_addr;
    tile_req_queue_in[req.abs_core_id].meta.tile_id  = req.meta.tile_id;
    tile_req_queue_in[req.abs_core_id].meta.core_id  = req.meta.core_id;

    wait(snitch_req_ready[req.abs_core_id]);
    #(TT-TA);


    @(posedge clk);
    #(TA);
    // set values back to 0
    snitch_req_valid[req.abs_core_id] = 1'b0;
    snitch_req[req.abs_core_id] = '0;
    #(TT-TA);
    @(posedge clk);

  endtask // send_request_from_core


endclass : InputDriver;

/***********
 * RespDriver
 ***********/
// Description:
// Handshake signals from Qnodes into actual responses for Scoreboard
class RespDriver;
  logic finished_generator;

  function new();
    snitch_resp_ready = '0;
    finished_generator = 1'b0;
  endfunction; // new

  task listen();
    wait (rst_n);
    @(posedge clk);

    while (!finished_generator) begin
      for(int c = 0; c < NUMACTIVECORES; c++) begin
          if(snitch_resp_valid[c]) begin
            #(TA);
            snitch_resp_ready[c] = 1'b1;

            // get responses from qnode
            #(TT-TA);
            snitch_resp_out[c] = snitch_resp[c];
            snitch_resp_out[c].meta          = snitch_resp[c].meta;
            snitch_resp_out[c].meta.lrwait   = tile_resp[c].meta.lrwait;
            snitch_resp_out[c].meta.ini_addr = tile_resp[c].meta.ini_addr;
            snitch_resp_out[c].meta.core_id  = tile_resp[c].meta.core_id;
            snitch_resp_out[c].meta.tile_id  = tile_resp[c].meta.tile_id;

            scrbrd.actual_data_resp.push_back(snitch_resp[c].rdata);
            scrbrd.actual_metadata_resp.push_back(snitch_resp_out[c].meta);

            // activate core again
            if (generator.core_status[get_core_id_from_metadata(snitch_resp_out[c].meta)]
                == WaitForResp) begin
              // core received response
              generator.core_status[get_core_id_from_metadata(snitch_resp_out[c].meta)] = Active;
            end else if (generator.core_status[get_core_id_from_metadata(snitch_resp_out[c].meta)]
                         == WaitForLRResp) begin
              // core receive LRResp, do SC next
              generator.core_status[get_core_id_from_metadata(snitch_resp_out[c].meta)] = DoSCNext;
            end

            @(posedge clk);
            #(TA);
            snitch_resp_ready[c] = 1'b0;
            @(posedge clk);
          end // if (snitch_resp_valid[c])

        #(TA);
        @(posedge clk);
        end
      end
  endtask
endclass : RespDriver;

  typedef struct packed {
    meta_id_t meta_id;
    bank_addr_t addr;
  } reservation_t;

 typedef bank_metadata_t reservation_queue_t[$:LrWaitQueueSize];

class Monitor;
  // Description:
  // Observe req and resp lines and compare stimuli
  // to golden model built up of associative array of queues for reservations

  // create a queue for each adress that is reserved
  reservation_queue_t reservation_queues[bank_addr_t];

  data_t              resp_data;
  bank_metadata_t     resp_metadata;

  // store data in a mock memory to compare to responses obtained from SRAM
  data_t              mock_memory[bank_addr_t];

  // check size of queue before inserting a new reservation
  bank_addr_t         check_size;
  int                 current_queue_size;

  // Golden Model for write access to TCDM
  // Pop the reservation if one was available
  // No response is expected
  task write_access(input bank_addr_t addr, input data_t data);
    if (VERBOSE) begin
      $display("write access");
    end
    // add write access to mock memory
    mock_memory[addr] = data;

    // pop reservation from queue if reservation existed
    // for same address
    if (reservation_queues.exists(addr) &&
        reservation_queues[addr].size() != 0) begin
      if (VERBOSE) begin
        $display("pop reservation");
      end
      void'(reservation_queues[addr].pop_front());
    end
  endtask; // write_access

  // Golden model for read access to TCDM
  task read_access(input bank_addr_t addr, input bank_metadata_t metadata);
    if (VERBOSE) begin
      $display("read access");
    end
    if (mock_memory.exists(addr)) begin
      resp_data = mock_memory[addr];
    end else begin
      resp_data = 32'hffffffff;
    end
    scrbrd.expected_data_resp.push_back(resp_data);
    scrbrd.expected_metadata_resp.push_back(metadata);
  endtask; // read_access

  task load_reserved(input bank_addr_t addr, input bank_metadata_t metadata);
    if (VERBOSE) begin
      $display("load reserved addr %h metadata %h", addr, metadata);
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
    if (reservation_queues.first(check_size)) begin
      current_queue_size = 0;

      do begin
        current_queue_size += reservation_queues[check_size].size();
      end while (reservation_queues.next(check_size));
      if (VERBOSE) begin
        $display("Current size of reservation queue %d ", current_queue_size);
      end
    end

    // Check if queue is full, else ignore reservation and send out response directly
    if (current_queue_size < LrWaitQueueSize) begin
      // place reservation in queue
      if (reservation_queues.exists(addr)) begin
        // has a reservation already been placed in the queue?
        if (reservation_queues[addr].size() == 0) begin
          if (VERBOSE) begin
            $display("reservation queue empty, response sending");
            $display("Push reservation with metadata %b", metadata);
          end

          // response can be sent
          scrbrd.expected_data_resp.push_back(resp_data);
          scrbrd.expected_metadata_resp.push_back(metadata);

          // push reservation onto LRWait queue
          reservation_queues[addr].push_back(metadata);

        // check if core issuing LR already holds a reservation
        end else if (match_metadata_for_core_id(.meta1(reservation_queues[addr][0]),
                                                .meta2(metadata))) begin
          if (VERBOSE) begin
            $display("Same core issued another reservation.");
          end
          // core at head of queue issued another reservation
          scrbrd.expected_data_resp.push_back(resp_data);
          scrbrd.expected_metadata_resp.push_back(metadata);
        end else begin
          // there already is somebody in the queue
          // append yourself to the queue
          // push reservation onto LRWait queue
          reservation_queues[addr].push_back(metadata);
        end
      end else begin // if (reservation_queues.exists(addr))
        if (VERBOSE) begin
          $display("first reservation");
        end
        // the adress does not exist in the queue, thus it is the first reservation
        scrbrd.expected_data_resp.push_back(resp_data);
        scrbrd.expected_metadata_resp.push_back(metadata);

        // push reservation onto LRWait queue
        reservation_queues[addr].push_back(metadata);
      end // else: !if(reservation_queues.exists(addr))
    end else begin
      // queue is full, we sent the LR response directly
      scrbrd.expected_data_resp.push_back(resp_data);
      scrbrd.expected_metadata_resp.push_back(metadata);
    end

  endtask // load_reserved

  task store_conditional(input bank_addr_t addr, input bank_metadata_t metadata, input data_t data);
    if (VERBOSE) begin
      $display("store conditional addr %h metadata %h", addr, metadata);
    end

    // check if reservation is valid
    // take head of LR queue
    if (reservation_queues.exists(addr)) begin
      if (match_metadata_for_core_id(.meta1(reservation_queues[addr][0]),
                                                .meta2(metadata))) begin
        // metadata matches, issue SC
        mock_memory[addr] = data;
        scrbrd.expected_data_resp.push_back(1'b0);
        scrbrd.expected_metadata_resp.push_back(metadata);

        // pop reservation
        void'(reservation_queues[addr].pop_front());
        if (reservation_queues[addr].size() != 0) begin
          if (VERBOSE) begin
            $display("Send out load reserved");
          end
          resp_metadata = reservation_queues[addr][0];
          scrbrd.expected_data_resp.push_back(mock_memory[addr]);
          scrbrd.expected_metadata_resp.push_back(resp_metadata);
        end
      end else begin
        // SC failed
        if (VERBOSE) begin
          $display("metadata %b reservation in queue %b", metadata, reservation_queues[addr][0]);
          $display("store conditional failed");
        end
        scrbrd.expected_data_resp.push_back(1'b1);
        scrbrd.expected_metadata_resp.push_back(metadata);
      end
    end else begin
      // sc failed
      scrbrd.expected_data_resp.push_back(1'b1);
      scrbrd.expected_metadata_resp.push_back(metadata);
    end
  endtask; // store_conditional

endclass : Monitor;


/**************
 * Scoreboard *
 **************/
class Scoreboard;
  // Description:
  // Gather expected and actual responses and compare them
  data_t expected_data_resp[$];
  data_t actual_data_resp[$];

  bank_metadata_t expected_metadata_resp[$];
  bank_metadata_t actual_metadata_resp[$];

  int success_counter;
  int number_of_resp;

  function void compare_responses();
    $display("++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++");
    $display("+                        RESULTS                           +");
    $display("++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++");

    success_counter = 0;
    number_of_resp = expected_data_resp.size();
    if (number_of_resp > actual_data_resp.size()) begin
      $display("NUMBER OF EXPECTED RESPONSES DOES NOT MATCH RECEIVED RESPONSES!");
      $display("Expected %2d != %2d Actual responses",
               number_of_resp, actual_data_resp.size());
      $display("++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++");
      number_of_resp = actual_data_resp.size();
    end

    for (int i=0; i < number_of_resp; i++) begin
      if (expected_data_resp[i] == actual_data_resp[i] &&
          expected_metadata_resp[i] == actual_metadata_resp[i]) begin
        success_counter += 1;
        if (VERBOSE) begin
          $display("PASS");
        end
      end else begin
        $display("FAIL");
        $display( "%-30s %h != %h","Data", expected_data_resp[i], actual_data_resp[i]);
        $display( "%-30s %b != %b","Metadata", expected_metadata_resp[i], actual_metadata_resp[i]);
        $display("++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++");
      end
    end
    $display("[%2d/%2d] responses match", success_counter, number_of_resp);
    if (success_counter != number_of_resp) begin
      $display("[EOC] Simulation ended at %t (retval = %0d).", $time, 1);
      $finish(1);
    end
  endfunction // compare
endclass // Scoreboard

  InputDriver inpdriver;

  TcdmRequest req;

  RespDriver respdriver;
  Generator generator;
  Monitor monitor;

  ManyToOneQueue #(.NumInputs(NUMACTIVECORES),
                   .InputStall(0),
                   .OutputStall(0)) tile_to_tcdm_queue;

  OneToManyQueue #(.NumOutputs(NUMACTIVECORES),
                   .InputStall(0),
                   .OutputStall(0)) tcdm_to_tile_queue;

  Scoreboard scrbrd;

  task store_conditional(input addr_t addr,
                         input     data_t data,
                         input int core_id);

    req = new(.req_addr(addr), .req_data(data),
                 .req_amo(4'hB),
                 .req_wen(1'b0),
                 .req_be(4'hF),
                 .req_abs_core_id(core_id));
    inpdriver.send_request_from_core(req);
  endtask // store_conditional

  task load_reserved(input addr_t addr,
                     input data_t data,
                     input int core_id);

    req = new(.req_addr(addr), .req_data(data),
              .req_amo(4'hA),
              .req_wen(1'b0),
              .req_be(4'h0),
              .req_abs_core_id(core_id));
    inpdriver.send_request_from_core(req);
  endtask // load_reserved

  task write_memory( input addr_t addr,
                     input data_t data,
                     input int core_id);
    req = new(.req_addr(addr), .req_data(data),
              .req_amo(4'h0),
              .req_wen(1'b1),
              .req_be(4'hF),
              .req_abs_core_id(core_id));
    inpdriver.send_request_from_core(req);
  endtask // write_memory

  task read_memory( input addr_t addr,
                     input data_t data,
                     input int core_id);
    req = new(.req_addr(addr), .req_data(data),
              .req_amo(4'h0),
              .req_wen(1'b0),
              .req_be(4'h0),
              .req_abs_core_id(core_id));
    inpdriver.send_request_from_core(req);
  endtask // read_memory


  /**************
   * Simulation *
   **************/

  initial begin : req_driver
    // Wait for reset.
    wait (rst_n);
    @(posedge clk);

    inpdriver = new();
    respdriver = new();
    scrbrd = new();
    generator = new();

    tile_to_tcdm_queue = new();
    tcdm_to_tile_queue = new();

    monitor = new();

    fork : Listener
      respdriver.listen();
    join_none
    #(10*ClockPeriod);

    if(!generator.randomize()) begin
      $display("Failed to randomize Generator class.");
      $display("[EOC] Simulation ended at %t (retval = %0d).", $time, 1);
      $finish(1);
    end
    generator.generate_requests();
    tile_to_tcdm_queue.push_inputs_to_queue();
    tile_to_tcdm_queue.pop_output_from_queue();

    tcdm_to_tile_queue.push_input_to_queue();
    tcdm_to_tile_queue.pop_outputs_from_queue();

    #(40000*ClockPeriod);
    //    respdriver.display_responses();

    respdriver.finished_generator = 1'b1;
    scrbrd.compare_responses();

    $display("[EOC] Simulation ended at %t (retval = %0d).", $time, 0);
    $finish(0);
  end // req_driver

endmodule : tcdm_adapter_tb
