// Copyright 2021 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Description: Handles the protocol conversion from valid/ready to req/gnt and correctly returns
// the metadata. Additionally, it handles atomics. Hence, it needs to be instantiated in front of
// an SRAM over which it has exclusive access.
//
// Author: Samuel Riedel <sriedel@iis.ee.ethz.ch>

`include "common_cells/registers.svh"

module tcdm_adapter
  import mempool_pkg::NumCores;
  import mempool_pkg::NumGroups;
  import mempool_pkg::NumCoresPerTile;
  import mempool_pkg::LrWaitQueueSize;
  import cf_math_pkg::idx_width;
#(
  parameter int unsigned  AddrWidth    = 32,
  parameter int unsigned  DataWidth    = 32,
  parameter type          metadata_t   = logic,
  parameter bit           LrScEnable   = 1,
  // Cut path between request and response at the cost of increased AMO latency
  parameter bit           RegisterAmo  = 1'b0,
  // Dependent parameters. DO NOT CHANGE.
  localparam int unsigned CoreIdWidth  = idx_width(NumCores),
  localparam int unsigned IniAddrWidth = idx_width(NumCoresPerTile + NumGroups),
  localparam int unsigned BeWidth      = DataWidth/8
) (
  input  logic                 clk_i,
  input  logic                 rst_ni,
  // master side
  input  logic                 in_valid_i,   // Bank request
  output logic                 in_ready_o,   // Bank grant
  input  logic [AddrWidth-1:0] in_address_i, // Address
  input  logic [3:0]           in_amo_i,     // Atomic Memory Operation
  input  logic                 in_write_i,   // 1: Store, 0: Load
  input  logic [DataWidth-1:0] in_wdata_i,   // Write data
  input  metadata_t            in_meta_i,    // Meta data
  input  logic [BeWidth-1:0]   in_be_i,      // Byte enable
  output logic                 in_valid_o,   // Read data
  input  logic                 in_ready_i,   // Read data
  output logic [DataWidth-1:0] in_rdata_o,   // Read data
  output metadata_t            in_meta_o,    // Meta data
  // slave side
  output logic                 out_req_o,   // Bank request
  output logic [AddrWidth-1:0] out_add_o,   // Address
  output logic                 out_write_o, // 1: Store, 0: Load
  output logic [DataWidth-1:0] out_wdata_o, // Write data
  output logic [BeWidth-1:0]   out_be_o,    // Bit enable
  input  logic [DataWidth-1:0] out_rdata_i  // Read data
);

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
  } amo_op_t;

  logic meta_valid, meta_ready;
  logic meta_valid_in;
  
  logic rdata_valid, rdata_ready;

  /// read signal before register
  logic [DataWidth-1:0] out_rdata;

  logic out_gnt;
  logic pop_resp;

  enum logic [1:0] {
      Idle, DoAMO, WriteBackAMO
  } state_q, state_d;

  logic                 load_amo;
  amo_op_t              amo_op_q;
  logic [BeWidth-1:0]   be_expand;
  logic [AddrWidth-1:0] addr_q;

  logic [31:0] amo_operand_a;
  logic [31:0] amo_operand_b_q;
  logic [31:0] amo_result, amo_result_q;

  logic        sc_successful_d, sc_successful_q;
  logic        sc_sent_d, sc_sent_q;
  logic        sc_q;
  logic        first_lr;
  logic        load_lr;
  
  metadata_t registered_in_meta_o;
    
  logic        lr_available_d, lr_available_q;

  // register data stored by SC to pass to next LR in queue
  logic [DataWidth-1:0] sc_wdata_d, sc_wdata_q;;

  logic                 queue_inp_req_i, queue_inp_gnt_o;
  logic                 queue_oup_req_i, queue_oup_pop_i;
  logic                 queue_oup_gnt_o, queue_oup_valid_o;
  
  metadata_t            queue_oup_data_o;

  // only load the metadata if it is the first LR
  // if LRWait, only store metadata in id_queue
  assign meta_valid_in = (amo_op_t'(in_amo_i) == AMOLR) ?
                         first_lr :
                         (in_valid_i && in_ready_o && !in_write_i);

  // if sending lr response, bypass metadata register and send metadata from
  // queue if sc has been sent
  assign in_meta_o = (lr_available_q && sc_sent_q)
                      ? queue_oup_data_o : registered_in_meta_o;
      
  // unique core identifier, does not necessarily match core_id
  logic [CoreIdWidth:0] unique_core_id;  

  // Store the metadata at handshake
  spill_register #(
    .T     (metadata_t),
    .Bypass(1'b0      )
  ) i_metadata_register (
    .clk_i  (clk_i                ),
    .rst_ni (rst_ni               ),
    .valid_i(meta_valid_in        ),
    .ready_o(meta_ready           ),
    .data_i (in_meta_i            ),
    .valid_o(meta_valid           ),
    .ready_i(pop_resp             ),
    .data_o (registered_in_meta_o )
  );

  // Store response if it's not accepted immediately
  fall_through_register #(
    .T(logic[DataWidth-1:0])
  ) i_rdata_register (
    .clk_i     (clk_i               ),
    .rst_ni    (rst_ni              ),
    .clr_i     (1'b0                ),
    .testmode_i(1'b0                ),
    .data_i    (out_rdata           ),
    .valid_i   (out_gnt || load_lr  ),
    .ready_o   (rdata_ready         ),
    .data_o    (in_rdata_o          ),
    .valid_o   (rdata_valid         ),
    .ready_i   (pop_resp            )
  );
   

  // if SC successful, store value to return in next cycle

  `FFARN(sc_wdata_q, sc_wdata_d, '0, clk_i, rst_ni);

  // In case of a SC we must forward SC result from the cycle earlier.
  // In case of load_lr send the data of most recent store as LR response
  // Send lr occurs 1 cycle after successful SC iff queue for id not empty
  assign out_rdata = load_lr ?
                     sc_wdata_q :
                     (sc_q ?  $unsigned(!sc_successful_q) : out_rdata_i);

  // Ready to output data if both meta and read data
  // are available (the read data will always be last)
  assign in_valid_o = (meta_valid || lr_available_q) && rdata_valid;
  
  // Only pop the data from the registers once both registers are ready
  // If  a LR happens and the response is held back, pop the metadata immediately
  assign pop_resp   = in_ready_i && in_valid_o;
  
  // Generate out_gnt one cycle after sending read request to the bank
  `FFARN(out_gnt, (out_req_o && !out_write_o) || sc_successful_d, 1'b0, clk_i, rst_ni);

  // ----------------
  // LR/SC
  // ----------------

  // if (LrScEnable) begin : gen_lrsc
                    
    id_queue #(
       .ID_WIDTH(AddrWidth),
       .CAPACITY(LrWaitQueueSize),
       .FULL_BW(1),
       .data_t(metadata_t)
     ) i_lrsc_queue (
       .clk_i            (clk_i      ),
       .rst_ni           (rst_ni     ),

       .inp_id_i         (in_address_i      ),
       .inp_data_i       (in_meta_i     ),
       .inp_req_i        (queue_inp_req_i      ),
       .inp_gnt_o        (queue_inp_gnt_o    ),

       // tie to 0 to disable exists 
       .exists_data_i    ('0),
       .exists_mask_i    ('0),
       .exists_req_i     (1'b0),
       .exists_o         (),
       .exists_gnt_o     (),

       .oup_id_i         (in_address_i          ),
       .oup_pop_i        (queue_oup_pop_i       ),
       .oup_req_i        (queue_oup_req_i       ),
       .oup_data_o       (queue_oup_data_o      ),
       .oup_data_valid_o (queue_oup_valid_o),
       .oup_gnt_o        (queue_oup_gnt_o       )
     );

    `FFARN(lr_available_q, lr_available_d, 1'b0, clk_i, rst_ni);
  
    `FFARN(sc_successful_q, sc_successful_d, 1'b0, clk_i, rst_ni);
    `FFARN(sc_sent_q, sc_sent_d, 1'b0, clk_i, rst_ni);

    `FFARN(sc_q, in_valid_i && in_ready_o && (amo_op_t'(in_amo_i) == AMOSC), 1'b0, clk_i, rst_ni);

    always_comb begin
      sc_successful_d = 1'b0;
      sc_sent_d = sc_sent_q;
      
      queue_inp_req_i = 1'b0;
      first_lr = 1'b0;
      load_lr = 1'b0;

      lr_available_d = lr_available_q;
            
      queue_oup_req_i = 1'b0;
      queue_oup_pop_i = 1'b0;

      sc_wdata_d = sc_wdata_q;

      // new valid transaction
      if (in_valid_i && in_ready_o) begin
        if (amo_op_t'(in_amo_i) == AMOLR) begin
          // we do not check if a reservation from a core already exists
          // since we assume the core is waiting and thus cannot place a
          // new reservation
          queue_inp_req_i = 1'b1;

          // if queue_inp_gnt_o == 0, the queue is full and we perform a LR
          // without placing a reservation, set first_lr to feed req
          // to TCDM
          if (!queue_inp_gnt_o) begin
            first_lr = 1'b1;
          end
          
          // check if queue is empty for id
          queue_oup_req_i = 1;
          if (queue_oup_gnt_o) begin
            if (!queue_oup_valid_o) begin
              // queue is empty
              first_lr = 1'b1;
            end
          end
          
        end else if (amo_op_t'(in_amo_i) == AMOSC) begin
          queue_oup_req_i = 1;
          // check if ID matches by reading head
          // if output is granted but not valid
          // queue is empty and thus fail SC
          if((queue_oup_gnt_o && queue_oup_valid_o) &&
             (queue_oup_data_o.ini_addr == in_meta_i.ini_addr) &&
             (queue_oup_data_o.tile_id == in_meta_i.tile_id) &&
             (queue_oup_data_o.core_id == in_meta_i.core_id)) begin
            // entry in queue matches SC
            sc_successful_d = 1'b1;
            sc_sent_d = 1'b0;
            
            // store value for sending back with next LR
            sc_wdata_d = in_wdata_i;
            queue_oup_pop_i = 1'b1;
          end
        end // if (amo_op_t'(in_amo_i) == AMOSC)

        // if write to adress from another core occurs
        // pop reservation at head
        if (in_write_i == 1'b1) begin
          queue_oup_req_i = 1;
          if (queue_oup_gnt_o && queue_oup_valid_o) begin
            queue_oup_pop_i = 1'b1;
          end
        end
      end // if (in_valid_i && in_ready_o)


      // response of sc is consumed
      if ((sc_successful_q || lr_available_q) && pop_resp) begin
        sc_sent_d = 1'b1;
      end
      
      // send LR after successful SC
      if (sc_successful_q) begin
        // query for the next reservation in the queue
        queue_oup_req_i = 1;
        // only make lr available when SC response was shifted out
        if (queue_oup_gnt_o && queue_oup_valid_o) begin
          // queue is not empty and we have a successor to send LR
          // result
          lr_available_d = 1'b1;
        end
      end
      
      if (lr_available_q) begin
        queue_oup_req_i = 1;
        // if rdata_register has been consumed
        // feed lr data
        if (rdata_ready) begin
          load_lr = 1'b1;
        end
        
        if (sc_sent_q && pop_resp) begin
          lr_available_d = 1'b0;
          sc_sent_d = 1'b0;
        end
      end
    end // always_comb
  // end else begin : disable_lrcs
  //   assign sc_q = 1'b0;
  //   assign sc_successful_d = 1'b0;
  //   assign sc_successful_q = 1'b0;
  // end

  // ----------------
  // Atomics
  // ----------------

  always_comb begin
    // feed-through
    // block new req when feeding out LR
    in_ready_o = lr_available_d ? 1'b0 : (in_valid_o && !in_ready_i ? 1'b0 : 1'b1);

    // if LR, only load value when either first LR or SC happened    
    out_req_o   = (amo_op_t'(in_amo_i) == AMOLR) ?
                  (first_lr && in_valid_i && in_ready_o) : (in_valid_i && in_ready_o);
    out_add_o   = in_address_i;
    out_write_o = in_write_i || (sc_successful_d && (amo_op_t'(in_amo_i) == AMOSC));
    out_wdata_o = in_wdata_i;
    out_be_o    = in_be_i;

    state_d     = state_q;
    load_amo    = 1'b0;

    unique case (state_q)
      Idle: begin
        if (in_valid_i && in_ready_o && !(amo_op_t'(in_amo_i) inside {AMONone, AMOLR, AMOSC})) begin
          load_amo = 1'b1;
          state_d = DoAMO;
        end
      end
      // Claim the memory interface
      DoAMO, WriteBackAMO: begin
        in_ready_o  = 1'b0;
        state_d     = (RegisterAmo && state_q != WriteBackAMO) ?  WriteBackAMO : Idle;
        // Commit AMO
        out_req_o   = 1'b1;
        out_write_o = 1'b1;
        out_add_o   = addr_q;
        out_be_o    = 4'b1111;
        // serve from register if we cut the path
        if (RegisterAmo) begin
          out_wdata_o = amo_result_q;
        end else begin
          out_wdata_o = amo_result;
        end
      end
      default:;
    endcase
  end

  if (RegisterAmo) begin : gen_amo_slice
    `FFLNR(amo_result_q, amo_result, (state_q == DoAMO), clk_i)
  end else begin : gen_amo_slice
    assign amo_result_q = '0;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q         <= Idle;
      amo_op_q        <= amo_op_t'('0);
      addr_q          <= '0;
      amo_operand_b_q <= '0;
    end else begin
      state_q         <= state_d;
      if (load_amo) begin
        amo_op_q        <= amo_op_t'(in_amo_i);
        addr_q          <= in_address_i;
        amo_operand_b_q <= in_wdata_i;
      end else begin
        amo_op_q        <= AMONone;
      end
    end
  end

  // ----------------
  // AMO ALU
  // ----------------
  logic [33:0] adder_sum;
  logic [32:0] adder_operand_a, adder_operand_b;

  assign amo_operand_a = out_rdata_i;
  assign adder_sum     = adder_operand_a + adder_operand_b;
  /* verilator lint_off WIDTH */
  always_comb begin : amo_alu

    adder_operand_a = $signed(amo_operand_a);
    adder_operand_b = $signed(amo_operand_b_q);

    amo_result = amo_operand_b_q;

    unique case (amo_op_q)
      // the default is to output operand_b
      AMOSwap:;
      AMOAdd: amo_result = adder_sum[31:0];
      AMOAnd: amo_result = amo_operand_a & amo_operand_b_q;
      AMOOr:  amo_result = amo_operand_a | amo_operand_b_q;
      AMOXor: amo_result = amo_operand_a ^ amo_operand_b_q;
      AMOMax: begin
        adder_operand_b = -$signed(amo_operand_b_q);
        amo_result = adder_sum[32] ? amo_operand_b_q : amo_operand_a;
      end
      AMOMin: begin
        adder_operand_b = -$signed(amo_operand_b_q);
        amo_result = adder_sum[32] ? amo_operand_a : amo_operand_b_q;
      end
      AMOMaxu: begin
        adder_operand_a = $unsigned(amo_operand_a);
        adder_operand_b = -$unsigned(amo_operand_b_q);
        amo_result = adder_sum[32] ? amo_operand_b_q : amo_operand_a;
      end
      AMOMinu: begin
        adder_operand_a = $unsigned(amo_operand_a);
        adder_operand_b = -$unsigned(amo_operand_b_q);
        amo_result = adder_sum[32] ? amo_operand_a : amo_operand_b_q;
      end
      default: amo_result = '0;
    endcase
  end

  // pragma translate_off
  // Check for unsupported parameters
  if (DataWidth != 32) begin
    $error($sformatf("Module currently only supports DataWidth = 32. DataWidth is currently set to: %0d", DataWidth));
  end

  `ifndef VERILATOR
    rdata_full : assert property(
      @(posedge clk_i) disable iff (~rst_ni) (out_gnt |-> rdata_ready))
      else $fatal (1, "Trying to push new data although the i_rdata_register is not ready.");

    // If lr_available_d set, the queue has to contain a valid next value
    lrwait_data_ready : assert property(   
      @(posedge clk_i) disable iff (~rst_ni) (lr_available_d |-> queue_oup_gnt_o && queue_oup_valid_o))
      else $fatal (1, "Output for LRWait became invalid.");
  `endif
  // pragma translate_on

endmodule
