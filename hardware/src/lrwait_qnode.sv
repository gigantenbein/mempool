// Copyright 2021 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Description: The Qnode implements a distributed MCS lock together
// with the TCDM adapter. An MCS lock is a queue based lock where,
// each hart stores a pointer to a hart that tried to acquire the
// lock after him.
// The Qnode is the storage of this "pointer" to the next hart. So
// when a hart queues up in the TCDM adapter, the Qnode of his
// predecessor is updated with his metadata. Then when the predecessor
// is finished, the Qnode releases a WakeUp which passes the lock to his
// successor.
//
// Nomenclature:
// LRReq         : Load reserved req going from Snitch to TCDM
// LRResp        : Load reserved resp going from TCDM to Snitch
// SCReq         : Store conditional req going from Snitch to TCDM
// SCResp        : Store conditional resp coming from TCDM to Snitch
// SuccUpdate    : Successor update sent by TCDM when a Load reserved at the
//                 the TCDM arrives and the Tail node is already occupied. The
//                 tail node is then replaced with the requester and a
//                 SuccUpdate is sent to the core that was in the Tail node
//                 previously
//                 The LRWait bit in the metadata is asserted.
// WakeUpReq     : Req going to TCDM with payload containing the metadata which
//                 core to wake up next
//                 The LRWait bit in the metadata is asserted.
//
// Author: Marc Gantenbein

`include "common_cells/registers.svh"

module lrwait_qnode
  import snitch_pkg::meta_id_t;
#(
  parameter type metadata_t   = logic
) (
  input logic            clk_i,
  input logic            rst_ni,

  // TCDM Ports
  // Snitch side
  // requests
  input  logic [31:0]    snitch_qaddr_i,
  input  logic           snitch_qwrite_i,
  input  logic [3:0]     snitch_qamo_i,
  input  logic [31:0]    snitch_qdata_i,
  input  logic [3:0]     snitch_qstrb_i,
  input  meta_id_t       snitch_qid_i,
  input  logic           snitch_qvalid_i,
  output logic           snitch_qready_o,

  // responses
  output logic [31:0]    snitch_pdata_o,
  output logic           snitch_perror_o,
  output meta_id_t       snitch_pid_o,
  output logic           snitch_pvalid_o,
  input  logic           snitch_pready_i,

  // Interconnect side
  // requests
  output logic [31:0]    tile_qaddr_o,
  output logic           tile_qwrite_o,
  output logic [3:0]     tile_qamo_o,
  output logic [31:0]    tile_qdata_o,
  output logic [3:0]     tile_qstrb_o,
  output meta_id_t       tile_qid_o,
  output logic           tile_qlrwait_o,
  output logic           tile_qvalid_o,
  input  logic           tile_qready_i,
  // responses
  input  logic [31:0]    tile_pdata_i,
  input  logic           tile_perror_i,
  input  meta_id_t       tile_pid_i,
  input  logic           tile_plrwait_i,
  input  logic           tile_pvalid_i,
  output logic           tile_pready_o
 );

  import mempool_pkg::AddrWidth;
  import mempool_pkg::DataWidth;
  import mempool_pkg::NumCores;
  import mempool_pkg::NumGroups;
  import mempool_pkg::NumCoresPerTile;
  import mempool_pkg::NumTilesPerGroup;
  import snitch_pkg::MetaIdWidth;

  import cf_math_pkg::idx_width;

  // ini_addr_width + meta_id_width + core_id_width + tile_id_width + lrwait
  localparam int MetaWidth = idx_width(NumCoresPerTile + NumGroups) +
                             MetaIdWidth +
                             idx_width(NumCoresPerTile) +
                             idx_width(NumTilesPerGroup) + 1;

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

  enum logic [1:0] {
      Idle, ReadyForSC, InLRQueue, SendWakeUp
  } state_q, state_d;

  // define next node pointer
  typedef struct packed {
    // indicates if a reservation can be active
    logic        valid;
    // pointer to successor by having metadata for successor
    // this metadata is sent to the tcdm and then used to send a wakeup
    // to the next core using the metadata stored here
    logic [MetaWidth-1:0] metadata;

    // used to match requests and responses and check if we received response
    // for instruction observed
    meta_id_t instruction_id;

    // indicates which reservation the load reserved points to
    logic [AddrWidth-1:0] addr;
  } next_node_t;

  next_node_t             next_node_d, next_node_q;
  `FF(next_node_q, next_node_d, 1'b0, clk_i, rst_ni);


  // assign pass through signals
  assign tile_qstrb_o    = snitch_qstrb_i;
  assign tile_qwrite_o   = snitch_qwrite_i;
  assign snitch_perror_o = tile_perror_i;

  // signal to check if a SC corresponding to a LR already passed
  logic sc_req_arrived_d, sc_req_arrived_q;
  `FF(sc_req_arrived_q, sc_req_arrived_d, 1'b0, clk_i, rst_ni);

  // allow signals to directly pass
  logic pass_through_request, pass_through_response;

  // pass responses through if they are not SuccUpdates
  assign pass_through_response = !tile_plrwait_i;

  assign tile_pready_o   = pass_through_response ? snitch_pready_i : tile_pvalid_i;
  assign snitch_pvalid_o = pass_through_response ? tile_pvalid_i   : 1'b0;
  assign snitch_pdata_o  = pass_through_response ? tile_pdata_i    : 1'b0;
  assign snitch_pid_o    = pass_through_response ? tile_pid_i      : 1'b0;

  // always allow handshakes except when inserting WakeUp
  assign pass_through_request = (state_q == SendWakeUp) ? 1'b0 : 1'b1;
  assign snitch_qready_o = pass_through_request ? tile_qready_i   : 1'b0;

  always_comb begin
    state_d          = state_q;
    next_node_d      = next_node_q;

    sc_req_arrived_d = sc_req_arrived_q;

    tile_qvalid_o    = pass_through_request ? snitch_qvalid_i : 1'b0;
    tile_qdata_o     = snitch_qdata_i;
    tile_qamo_o      = snitch_qamo_i;
    tile_qaddr_o     = snitch_qaddr_i;
    tile_qid_o       = snitch_qid_i;

    tile_qlrwait_o   = 1'b0;

    // FSM
    unique case (state_q)
      // Wait for LR to start
      Idle: begin
        // a request arrives
        if (snitch_qvalid_i && tile_qready_i) begin
          if (amo_op_t'(snitch_qamo_i) == AMOLR) begin
            next_node_d.instruction_id = snitch_qid_i;
            next_node_d.addr           = snitch_qaddr_i;
            next_node_d.valid          = 1'b1;
          end
          if (amo_op_t'(snitch_qamo_i) == AMOSC) begin
            // a SC without reservations passes
            $fatal("Always place a reservation for an SC");
          end
        end
        // a response arrives
        if (tile_pvalid_i) begin
          if (snitch_pready_i) begin
            // It has to be either a LRResp or a SCResp
            if((tile_pid_i == next_node_q.instruction_id) &&
               (next_node_q.valid == 1'b1)) begin
              state_d = ReadyForSC;
            end
          end else if (tile_plrwait_i == 1'b1) begin
            // we are waiting for a response and now have received a SuccUpdate
            next_node_d.metadata = tile_pdata_i[MetaWidth-1:0];
            state_d = InLRQueue;
          end
        end
      end // case: Idle

      ReadyForSC: begin
        // a request arrives
        if (snitch_qvalid_i && tile_qready_i) begin
          if (amo_op_t'(snitch_qamo_i) == AMOLR) begin
            // a core issued another reservation
            $fatal("Core issued another LR while LR was still active");
          end else if ((amo_op_t'(snitch_qamo_i) == AMOSC)) begin
            if ((next_node_q.addr == snitch_qaddr_i) &&
                (next_node_q.valid == 1'b1)) begin
              // SC matches address of reservation
              next_node_d.instruction_id = snitch_qid_i;
              next_node_d.addr           = snitch_qaddr_i;
              sc_req_arrived_d           = 1'b1;
            end else begin
              $fatal("Yes, always place a reservation for an SC");
            end
          end
        end

        // a resp arrives
        if (tile_pvalid_i) begin
          if (tile_plrwait_i == 1'b1) begin
            // the response is a SuccUpdate
            next_node_d.metadata = tile_pdata_i[MetaWidth-1:0];
            if (sc_req_arrived_d == 1'b1) begin
              // we check the current sc_req_arrived since a response
              // and a request can arrive at the same time
              state_d = SendWakeUp;
            end else begin
              state_d = InLRQueue;
            end
          end else if(tile_pid_i == next_node_q.instruction_id) begin
            // it is a SCResp, we can go back to Idle since we are sure
            // that no SC update will arrive now until the next LR/SC
            // cycle
            if(snitch_pready_i == 1'b1) begin
              // only go back to idle when handshake happened
              sc_req_arrived_d  = 1'b0;
              next_node_d.valid = 1'b0;

              state_d = Idle;
            end
          end
        end
      end // case: WaitForSC

      InLRQueue: begin
        // a request arrives
        if (snitch_qvalid_i && tile_qready_i) begin
          if ((amo_op_t'(snitch_qamo_i) == AMOSC)) begin
            if ((next_node_q.addr == snitch_qaddr_i) &&
                (next_node_q.valid == 1'b1)) begin
              // SC matches address of reservation
              next_node_d.instruction_id = snitch_qid_i;
              next_node_d.addr           = snitch_qaddr_i;
              sc_req_arrived_d           = 1'b1;
              state_d                    = SendWakeUp;
            end else begin
              $fatal("no reservation for SC");
            end
          end else if (sc_req_arrived_d == 1'b1) begin // if ((amo_op_t'(snitch_qamo_i) == AMOSC))
            $fatal("Only send one SC per reservation");
          end
        end // if (snitch_qvalid_i && tile_qready_i)
      end

      SendWakeUp: begin
        sc_req_arrived_d  = 1'b0;
        next_node_d.valid = 1'b0;

        // send wake up
        tile_qamo_o    = AMOLR;
        tile_qaddr_o   = next_node_q.addr;

        // set metadata and set lrwait flag
        tile_qid_o     = snitch_qid_i;
        tile_qlrwait_o = 1'b1;

        // store metadata of successor in payload
        // TODO: replace with datawidth
        tile_qdata_o                = 32'b0;
        tile_qdata_o[MetaWidth-1:0] = next_node_q.metadata;

        tile_qvalid_o  = 1'b1;
        // wait for handshake
        if (tile_qready_i == 1'b1) begin
          // handshake happened
          state_d = Idle;
        end
      end // case: SendWakeUp

      default: begin
        state_d = Idle;
      end
    endcase
  end // always

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q         <= Idle;
    end else begin
      state_q         <= state_d;
    end
  end

  // pragma translate_off

`ifndef VERILATOR
  illegal_transition : assert property(
                                       @(posedge clk_i) disable iff (~rst_ni) ((state_q == InLRQueue)|=> not (state_q == Idle)))
    else $fatal (1, "Trying to do an illegal transition going from InLRQueue to Idle");
  leave_send_wakeup : assert property(
                                      @(posedge clk_i) disable iff (~rst_ni) ((state_q == SendWakeUp)|=> (state_q == SendWakeUp)
                                                                              or (state_q == Idle)))
    else $fatal (1, "SendWakeUp did not succeed");
`endif
  // pragma translate_on

endmodule
