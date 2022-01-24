// Copyright 2021 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Description: The Qnode implements a queue in fashion of a linked
// list for ordering Load-Reserved(LRWait) to the TCDM adapter. Instead
// of queueing up all LRWaits directly in front of the TCDM, the queue
// is distributed to each core sending the reservation and to the
// tcdm_adapter itself. When the core is part of LRWait queue the Qnode
// contains a "pointer" in the form of metadata to its successor.
//
// The Qnode is the storage of this "pointer" to the next hart. So
// when a hart queues up in the TCDM adapter, the Qnode of his
// predecessor is updated with the metadata of the successor. Then
// when the predecessor is finished, the Qnode releases a WakeUp
// which passes the lock to his successor.
//
// If neither LRWait or SCWaits are used, this module acts as a simple
// wiring from Snitch to the interconnect and will be optimized away.
//
// Nomenclature:
// LRWaitReq  : Load reserved req going from Snitch to TCDM
// LRWaitResp : Load reserved resp going from TCDM to Snitch
// SCWaitReq  : Store conditional req going from Snitch to TCDM
// SCWaitResp : Store conditional resp coming from TCDM to Snitch
// SuccUpdate : Successor update sent by TCDM when a Load reserved at the
//              the TCDM arrives and the Tail node is already occupied. The
//              tail node is then replaced with the requester and a
//              SuccUpdate is sent to the core that was in the Tail node
//              previously
//              The LRWaitWait bit in the metadata is asserted.
// WakeUpReq  : Req going to TCDM with payload containing the metadata which
//              core to wake up next
//              The LRWaitWait bit in the metadata is asserted.
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
    AMOSC   = 4'hB,
    LRWAIT  = 4'hC,
    SCWAIT  = 4'hD
  } amo_op_t;

  enum logic [1:0] {
    Idle, ReadyForSCWait, InLRWaitQueue, SendWakeUp
  } state_q, state_d;

  // define next node pointer
  typedef struct packed {
    // indicates if a reservation can be active
    logic                 valid;
    // pointer to successor by having metadata for successor
    // this metadata is sent to the tcdm and then used to send a wakeup
    // to the next core using the metadata stored here
    logic [MetaWidth-1:0] metadata;

    // used to match requests and responses and check if we received response
    // for instruction observed
    meta_id_t             instruction_id;

    // indicates which reservation the load reserved points to
    logic [AddrWidth-1:0] addr;
  } next_node_t;

  next_node_t             next_node_d, next_node_q;
  `FF(next_node_q, next_node_d, 1'b0, clk_i, rst_ni);

  // signal to check if a SCWait corresponding to a LRWait already passed
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
  assign snitch_perror_o = pass_through_response ? tile_perror_i   : 1'b0;

  // always allow handshakes except when inserting WakeUp
  assign pass_through_request = (state_q == SendWakeUp) ? 1'b0 : 1'b1;
  assign snitch_qready_o      = pass_through_request ? tile_qready_i   : 1'b0;

  assign tile_qwrite_o        = pass_through_request ? snitch_qwrite_i : 1'b0;
  assign tile_qstrb_o         = pass_through_request ? snitch_qstrb_i  : '0;

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
      // Wait for LRWait to start
      Idle: begin
        // a request arrives
        if (snitch_qvalid_i && tile_qready_i) begin
          // if a LRWaitReq passes, store the address
          if (amo_op_t'(snitch_qamo_i) == LRWAIT) begin
            next_node_d.instruction_id = snitch_qid_i;
            next_node_d.addr           = snitch_qaddr_i;
            next_node_d.valid          = 1'b1;
          end
        end
        // a response arrives
        if (tile_pvalid_i) begin
          if (snitch_pready_i) begin
            // It has to be either a LRWaitResp or a SCWaitResp
            if((tile_pid_i == next_node_q.instruction_id) &&
               (next_node_q.valid == 1'b1)) begin
              state_d = ReadyForSCWait;
            end
          end else if (tile_plrwait_i == 1'b1) begin
            // we are waiting for a response and now have received a SuccUpdate
            next_node_d.metadata = tile_pdata_i[MetaWidth-1:0];
            state_d = InLRWaitQueue;
          end
        end
      end // case: Idle

      ReadyForSCWait: begin
        // a request arrives
        if (snitch_qvalid_i && tile_qready_i) begin
          if ((amo_op_t'(snitch_qamo_i) == SCWAIT)) begin
            if ((next_node_q.addr == snitch_qaddr_i) &&
                (next_node_q.valid == 1'b1)) begin
              // SCWait matches address of reservation
              next_node_d.instruction_id = snitch_qid_i;
              next_node_d.addr           = snitch_qaddr_i;
              sc_req_arrived_d           = 1'b1;
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
              state_d = InLRWaitQueue;
            end
          end else if(tile_pid_i == next_node_q.instruction_id) begin
            // it is a SCWaitResp, we can go back to Idle since we are sure
            // that no SCWait update will arrive now until the next LRWait/SCWait
            // cycle
            if(snitch_pready_i == 1'b1) begin
              // only go back to idle when handshake happened
              sc_req_arrived_d  = 1'b0;
              next_node_d.valid = 1'b0;

              state_d = Idle;
            end
          end
        end
      end // case: WaitForSCWait

      InLRWaitQueue: begin
        // a request arrives
        if (snitch_qvalid_i && tile_qready_i) begin
          if ((amo_op_t'(snitch_qamo_i) == SCWAIT)) begin
            if ((next_node_q.addr == snitch_qaddr_i) &&
                (next_node_q.valid == 1'b1)) begin
              // SCWait matches address of reservation
              next_node_d.instruction_id = snitch_qid_i;
              next_node_d.addr           = snitch_qaddr_i;
              sc_req_arrived_d           = 1'b1;
              state_d                    = SendWakeUp;
            end
          end // if (snitch_qvalid_i && tile_qready_i)
        end
      end // case: InLRWaitQueue

      SendWakeUp: begin
        sc_req_arrived_d  = 1'b0;
        next_node_d.valid = 1'b0;

        // send wake up
        tile_qamo_o    = LRWAIT;
        tile_qaddr_o   = next_node_q.addr;

        // set metadata and set lrwait flag
        tile_qid_o     = snitch_qid_i;
        tile_qlrwait_o = 1'b1;

        // store metadata of successor in payload
        tile_qdata_o                = '0;
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
    @(posedge clk_i) disable iff (~rst_ni) ((state_q == InLRWaitQueue)|=> not (state_q == Idle)))
    else $warning (1, "Trying to do an illegal transition going from InLRWaitQueue to Idle");

  // Assert that SendWakeUp state is eventually left
  leave_send_wakeup : assert property(
    @(posedge clk_i) disable iff (~rst_ni) ((state_q == SendWakeUp)|=>
                                            (state_q == SendWakeUp) || (state_q == Idle)))
    else $warning (1, "SendWakeUp did not succeed");

  // if qnode is in an idle state, it is not allowed to receive a SCWait
  // A SCWait has to be preceeded by a LRWait
  lr_before_sc : assert property(
    @(posedge clk_i) disable iff (~rst_ni) (((state_q == Idle) &&
                                             (snitch_qvalid_i && tile_qready_i)) |->
                                            ~(amo_op_t'(snitch_qamo_i) == SCWAIT)))
    else $warning (1, "A SCWait was sent without a preceding LRWait");

  // nested LRWaits are disallowed. This includes issuing a reservation again or
  // sending a reservation to another location
  no_nested_lr : assert property(
    @(posedge clk_i) disable iff (~rst_ni) (((state_q == ReadyForSCWait) &&
                                             (snitch_qvalid_i && tile_qready_i)) |->
                                            ~(amo_op_t'(snitch_qamo_i) == LRWAIT)))
    else $warning (1, "Another LRWait was issued while the previous LRWait was still active.");

  // an SCWait has to go to an address that has been reserved before and no SCWait has occurred so far
  sc_to_valid_address : assert property(
    @(posedge clk_i) disable iff (~rst_ni) ((((state_q == ReadyForSCWait) ||
                                              (state_q == InLRWaitQueue)) &&
                                             ((snitch_qvalid_i && tile_qready_i) &&
                                             (amo_op_t'(snitch_qamo_i) == SCWAIT)))|->
                                            ((next_node_q.addr == snitch_qaddr_i) &&
                                             (next_node_q.valid == 1'b1))))
    else $warning (1, "The SCWait was not preceeded by a LRWait to the same address.");

  only_one_sc_per_lr : assert property(
    @(posedge clk_i) disable iff (~rst_ni) (((state_q == InLRWaitQueue) &&
                                             (snitch_qvalid_i && tile_qready_i) &&
                                             (amo_op_t'(snitch_qamo_i) == SCWAIT))|->
                                             !sc_req_arrived_q))
    else $warning (1, "More than one SCWait was sent for a LRWait");
`endif
  // pragma translate_on

endmodule
