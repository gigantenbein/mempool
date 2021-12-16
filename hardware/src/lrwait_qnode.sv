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

  // ini_addr_width + meta_id_width + core_id_width + tile_id_width
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
      Idle, WaitForSC, InQueue, SendWakeUp
  } state_q, state_d;

  // assign pass through signals
  assign tile_qstrb_o  = snitch_qstrb_i;
  assign tile_qwrite_o = snitch_qwrite_i;
  assign snitch_perror_o = tile_perror_i;

  // define next node pointer
  typedef struct packed {
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
  // signal to check if a SC corresponding to a LR already passed
  logic                   sc_req_arrived_d, sc_req_arrived_q;
  // allow signals to directly pass
  logic                   pass_through_request, pass_through_response;

  `FF(sc_req_arrived_q, sc_req_arrived_d, 1'b0, clk_i, rst_ni);
  `FF(next_node_q, next_node_d, 1'b0, clk_i, rst_ni);

  always_comb begin
    state_d = state_q;
    next_node_d = next_node_q;

    sc_req_arrived_d = sc_req_arrived_q;

    // pass responses through if they are not SuccUpdates
    pass_through_response = !tile_plrwait_i;

    tile_pready_o   = pass_through_response ? snitch_pready_i : tile_pvalid_i;
    snitch_pvalid_o = pass_through_response ? tile_pvalid_i   : 1'b0;
    snitch_pdata_o  = pass_through_response ? tile_pdata_i    : 1'b0;
    snitch_pid_o    = pass_through_response ? tile_pid_i      : 1'b0;

    // always allow handshakes except when inserting WakeUp
    pass_through_request = (state_q == SendWakeUp) ? 1'b0 : 1'b1;

    tile_qvalid_o   = pass_through_request ? snitch_qvalid_i : 1'b0;
    snitch_qready_o = pass_through_request ? tile_qready_i   : 1'b0;

    tile_qdata_o    = snitch_qdata_i;
    tile_qamo_o     = snitch_qamo_i;
    tile_qaddr_o    = snitch_qaddr_i;
    tile_qid_o      = snitch_qid_i;

    tile_qlrwait_o = 1'b0;

    // FSM
    unique case (state_q)
      // Wait for LR to start
      Idle: begin
        // a request arrives
        if (snitch_qvalid_i && tile_qready_i) begin
          if (amo_op_t'(snitch_qamo_i) == AMOLR) begin
            // register addr of LR
            next_node_d.addr = snitch_qaddr_i;
            next_node_d.instruction_id = snitch_qid_i;
          end
        end
        // a response arrives
        if (tile_pvalid_i) begin
          // check if it is a LRresp
          if (next_node_q.instruction_id == tile_qid_o) begin
            state_d = WaitForSC;
          end
          if(tile_plrwait_i == 1'b1) begin
            // it is a successor update
            next_node_d.metadata = tile_pdata_i[MetaWidth-1:0];
            state_d = InQueue;
          end
        end
      end // case: Idle

      // If we received our LRresp, we are ready to wait for a SC
      // When we receive a SC request
      WaitForSC: begin

        // a request arrives
        if (snitch_qvalid_i && tile_qready_i) begin
          if (amo_op_t'(snitch_qamo_i) == AMOLR) begin
            // register addr of LR
            if(next_node_d.addr == snitch_qaddr_i) begin
              // a core issued a nested reservation
              // to same address it is fine
            end else begin
              // TODO: THROW an error
            end
          end else if ((amo_op_t'(snitch_qamo_i) == AMOSC) &&
                       (snitch_qaddr_i == next_node_q.addr)) begin
            next_node_d.instruction_id = snitch_qid_i;
            sc_req_arrived_d = 1'b1;
          end
        end

        if (tile_pvalid_i) begin
          // a resp arrives
          if(tile_plrwait_i == 1'b1) begin
            // SuccUpdate arrived
            next_node_d.metadata = tile_pdata_i[MetaWidth-1:0];
            if (sc_req_arrived_d == 1'b1) begin
              state_d = SendWakeUp;
            end
            state_d = InQueue;
          end else if (next_node_q.instruction_id == tile_pid_i) begin
            state_d = Idle;
          end
        end
      end // case: WaitForSC

      InQueue: begin
        // a request arrives
        if (snitch_qvalid_i && tile_qready_i) begin
          if ((amo_op_t'(snitch_qamo_i) == AMOSC) &&
              (snitch_qaddr_i == next_node_q.addr)) begin
            // send the wake up
            next_node_d.addr = snitch_qaddr_i;
            state_d = SendWakeUp;
          end
        end
      end // case: InQueue

      SendWakeUp: begin
        sc_req_arrived_d = 1'b0;

        // send wake up
        tile_qamo_o = AMOLR;
        tile_qaddr_o = next_node_q.addr;

        // set metadata and set lrwait flag
        tile_qid_o = snitch_qid_i;
        tile_qlrwait_o = 1'b1;

        // store metadata of successor in payload
        // TODO: replace with datawidth
        tile_qdata_o = 32'b0;
        tile_qdata_o[MetaWidth-1:0] = next_node_q.metadata;

        tile_qvalid_o = 1'b1;
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

  // // pragma translate_off

  // `ifndef VERILATOR
  //   rdata_full : assert property(
  //     @(posedge clk_i) disable iff (~rst_ni) ())
  //     else $fatal (1, "Trying to push new data although the i_rdata_register is not ready.");
  // `endif
  // // pragma translate_on

endmodule
