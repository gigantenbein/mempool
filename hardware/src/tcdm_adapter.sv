// Copyright 2021 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Description: Handles the protocol conversion from valid/ready to req/gnt and correctly returns
// the metadata. Additionally, it handles atomics. Hence, it needs to be instantiated in front of
// an SRAM over which it has exclusive access.
//
// Author: Samuel Riedel <sriedel@iis.ee.ethz.ch>

`include "common_cells/registers.svh"

module tcdm_adapter #(
  parameter int unsigned  AddrWidth     = 32,
  parameter int unsigned  DataWidth     = 32,
  parameter type          metadata_t    = logic,
  parameter bit           LrScEnable    = 1,
  parameter bit           LrWaitEnable  = 1,
  parameter int unsigned  NumLrWaitAddr = 4,
  // Cut path between request and response at the cost of increased AMO latency
  parameter bit           RegisterAmo   = 1'b0,
  // Dependent parameters. DO NOT CHANGE.
  localparam int unsigned BeWidth       = DataWidth/8
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

  import mempool_pkg::NumCores;
  import mempool_pkg::NumGroups;
  import mempool_pkg::NumCoresPerTile;
  import mempool_pkg::NumTilesPerGroup;
  import cf_math_pkg::idx_width;
  import snitch_pkg::MetaIdWidth;

  // ini_addr_width + meta_id_width + core_id_width + tile_id_width
  localparam int MetaWidth = idx_width(NumCoresPerTile + NumGroups) +
                             MetaIdWidth +
                             idx_width(NumCoresPerTile) +
                             idx_width(NumTilesPerGroup) +
                             LrWaitEnable;

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

  logic meta_valid,  meta_ready;
  logic rdata_valid, rdata_ready;

  // meta and rdata before registering
  metadata_t            in_meta;
  logic [DataWidth-1:0] out_rdata;

  logic out_gnt;
  logic pop_resp;

  // AMO
  enum logic [1:0] {
      Idle, DoAMO, WriteBackAMO
  } state_q, state_d;

  logic                 load_amo;
  amo_op_t              amo_op_q;
  logic [AddrWidth-1:0] addr_q;

  logic [31:0] amo_operand_a;
  logic [31:0] amo_operand_b_q;
  logic [31:0] amo_result, amo_result_q;

  // signals for DistLRWait
  // LRWait that arrives is a wake_up_req
  logic        wake_up_req;

  // LRWait that should be sent is a successor update
  logic        successor_update_d, successor_update_q;

  // indicate if request was a SC or a SCWait
  logic        sc_active;
  logic        sc_successful_d, sc_successful_q;

  logic        sc_lrsc_successful_d, sc_lrsc_successful_q;
  logic        sc_lrwait_successful_d, sc_lrwait_successful_q;

  // storage of metadata to send to next core
  logic [MetaWidth-1:0] wake_up_data_d, wake_up_data_q;
  metadata_t            lrwait_meta;

  // Store the metadata at handshake
  spill_register #(
    .T     (metadata_t),
    .Bypass(1'b0      )
  ) i_metadata_register (
    .clk_i  (clk_i                                  ),
    .rst_ni (rst_ni                                 ),
    .valid_i(in_valid_i && in_ready_o && !in_write_i),
    .ready_o(meta_ready                             ),
    .data_i (in_meta                                ),
    .valid_o(meta_valid                             ),
    .ready_i(pop_resp                               ),
    .data_o (in_meta_o                              )
  );

  // Store response if it's not accepted immediately
  fall_through_register #(
    .T(logic[DataWidth-1:0])
  ) i_rdata_register (
    .clk_i     (clk_i      ),
    .rst_ni    (rst_ni     ),
    .clr_i     (1'b0       ),
    .testmode_i(1'b0       ),
    .data_i    (out_rdata  ),
    .valid_i   (out_gnt    ),
    .ready_o   (rdata_ready),
    .data_o    (in_rdata_o ),
    .valid_o   (rdata_valid),
    .ready_i   (pop_resp   )
  );

  assign in_meta = (wake_up_req || successor_update_d) ? lrwait_meta : in_meta_i;

  // In case of a SCWait we must forward SCWait result from the cycle earlier.
  // wake_up_data_q is implicitly zero-padded form MetaWidth to DataWidth
  assign out_rdata = sc_active ? !sc_successful_q :
                     (successor_update_q ? wake_up_data_q : out_rdata_i);

  // Ready to output data if both meta and read data
  // are available (the read data will always be last)
  assign in_valid_o = meta_valid && rdata_valid;
  // Only pop the data from the registers once both registers are ready
  assign pop_resp   = in_ready_i && in_valid_o;

  // Generate out_gnt one cycle after sending read request to the bank
  `FF(out_gnt, (out_req_o && !out_write_o) || sc_successful_d || successor_update_d,
      1'b0, clk_i, rst_ni);

  if (LrWaitEnable || LrScEnable) begin
    assign sc_successful_d = sc_lrsc_successful_d || sc_lrwait_successful_d;
    // indicate that an SCWait is active
    `FF(sc_active, in_valid_i && in_ready_o &&
        ((amo_op_t'(in_amo_i) == AMOSC) || (amo_op_t'(in_amo_i) == SCWAIT)),
        1'b0, clk_i, rst_ni);
    `FF(sc_successful_q, sc_successful_d, 1'b0, clk_i, rst_ni);
  end else begin
    assign sc_active = 1'b0;
    assign sc_successful_d = 1'b0;
  end

  // ----------------
  // LRWait
  // ----------------

  if (LrWaitEnable) begin : gen_lrwait

    // the reservation structure builds up a MCS queue in hardware with the
    // tail node in front of the TCDM bank. The nodes pointing to a successor
    // are located in front of the core issuing a LRWait
    // An additional head node is needed, to prevent SCWaits without a reservation
    // from succeeding
    typedef struct packed {
      // needed to prevent rogue SCWaits from succeeding
      logic        head_valid;
      // indicate if tail points to a real core
      logic        tail_valid;
      // addr of reservation
      logic [AddrWidth-1:0] addr;
      // head of queue who can issue successful SCWaits
      metadata_t            head;
      metadata_t            tail;
    } queue_reservation_t;

    queue_reservation_t [NumLrWaitAddr-1:0] lrwait_reservation_d, lrwait_reservation_q;

    `FF(lrwait_reservation_q, lrwait_reservation_d, 1'b0, clk_i, rst_ni);
    `FF(successor_update_q, successor_update_d, 1'b0, clk_i, rst_ni);
    `FF(wake_up_data_q, wake_up_data_d, 1'b0, clk_i, rst_ni);

    localparam int unsigned NodeIdxWidth = $clog2(NumLrWaitAddr);

    logic                    all_nodes_full;
    logic                    addr_match;
    logic [NodeIdxWidth-1:0] node_idx;

    // check for free reservation node
    if (NumLrWaitAddr > 1) begin : gen_multip_lrwait_nodes
      logic [NumLrWaitAddr-1:0] idx_matches_addr;
      logic [NumLrWaitAddr-1:0] node_is_free;
      logic [NumLrWaitAddr-1:0] node_is_available;

      for (genvar a = 0; a < NumLrWaitAddr; a++) begin
        assign idx_matches_addr[a] = in_valid_i
                                     && (lrwait_reservation_q[a].addr == in_address_i)
                                       && (lrwait_reservation_q[a].tail_valid);
        assign node_is_free[a] = !lrwait_reservation_q[a].tail_valid;
      end

      // if no node is free, the LRWait queue is full
      assign all_nodes_full = ~|(node_is_free);

      // addr match means we can pick an existing node
      assign addr_match = |idx_matches_addr;

      // pick an existing node or one that is free
      assign node_is_available = addr_match ? idx_matches_addr : node_is_free;

      // find free index for address
      // Find the first free index
      lzc #(
        .WIDTH ( NumLrWaitAddr ),
        .MODE  ( 0             ) // Start at index 0.
      ) i_ld_free_lzc (
        .in_i    ( node_is_available),
        .cnt_o   ( node_idx         ),
        .empty_o ( /*unused*/       )
      );

    end else begin : single_lrwait_node // block: gen_multip_lrwait_nodes
      assign node_idx       = 1'b0;
      assign all_nodes_full = 1'b0;
      assign addr_match     = 1'b1;
    end

    always_comb begin
      lrwait_reservation_d = lrwait_reservation_q;

      lrwait_meta    = '0;
      wake_up_req    = 1'b0;
      wake_up_data_d = wake_up_data_q;

      successor_update_d = 1'b0;

      sc_lrwait_successful_d = 1'b0;

      if (in_valid_i && in_ready_o) begin
        // a request arrives
        if ((amo_op_t'(in_amo_i) == LRWAIT)) begin
          // a LRWait was issued
          if(in_meta_i.lrwait == 1'b1) begin
            // the LRWait is a wake-up request from a Qnode
            wake_up_req = 1'b1;
            // extract metadata
            // cast from data to lrwait
            lrwait_meta = in_wdata_i;
            lrwait_meta.lrwait = 1'b0;

            // set incoming metadata as head
            lrwait_reservation_d[node_idx].head_valid = 1'b1;
            lrwait_reservation_d[node_idx].head = lrwait_meta;

            // if an LRWait, check if we have space for new reservation
          end else if (!(all_nodes_full) || addr_match) begin
            // it is a normal LRWait
            if((in_meta_i == lrwait_reservation_q[node_idx].head)
               && (lrwait_reservation_q[node_idx].head_valid == 1'b1)
               && (in_address_i == lrwait_reservation_q[node_idx].addr)) begin
              // core issued a reservation again
              // make sure the reservation is still valid
              lrwait_reservation_d[node_idx].head_valid = 1'b1;
            end else if ((lrwait_reservation_q[node_idx].tail_valid == 1'b1)
                         && (in_address_i == lrwait_reservation_q[node_idx].addr)) begin
              // there is somebody in the queue
              // prepare successor update
              // load data into read register
              wake_up_data_d = in_meta_i;

              // get metadata from tail
              lrwait_meta = lrwait_reservation_q[node_idx].tail;
              // set as successor update
              lrwait_meta.lrwait = 1'b1;

              // set as tail node
              lrwait_reservation_d[node_idx].tail = in_meta_i;

              // prevent request on SRAM
              successor_update_d = 1'b1;
            end else begin
              // the queue has been empty
              // set yourself as head and tail node
              lrwait_reservation_d[node_idx].tail       = in_meta_i;
              lrwait_reservation_d[node_idx].tail_valid = 1'b1;
              lrwait_reservation_d[node_idx].head       = in_meta_i;
              lrwait_reservation_d[node_idx].head_valid = 1'b1;
              lrwait_reservation_d[node_idx].addr       = in_address_i;
            end
          end
        end else if ((amo_op_t'(in_amo_i) == SCWAIT)) begin // if ((amo_op_t'(in_amo_i) == LRWAIT))
          if (in_meta_i == lrwait_reservation_q[node_idx].head &&
              lrwait_reservation_q[node_idx].head_valid == 1'b1 &&
              in_address_i == lrwait_reservation_q[node_idx].addr ) begin
            sc_lrwait_successful_d = 1'b1;
            // invalidate reservation
            lrwait_reservation_d[node_idx].head_valid = 1'b0;
            if (lrwait_reservation_q[node_idx].head == lrwait_reservation_q[node_idx].tail) begin
              // if head and tail match, it was the only node in the queue
              lrwait_reservation_d[node_idx].tail_valid = 1'b0;
            end
          end else begin
            sc_lrwait_successful_d = 1'b0;
          end

        // check whether another core has made a write attempt or an AMO occured
        end else if ((in_address_i == lrwait_reservation_q[node_idx].addr) &&
                     (!(amo_op_t'(in_amo_i) inside {AMONone, AMOLR, AMOSC, LRWAIT, SCWAIT}) ||
                      in_write_i ||
                      ((amo_op_t'(in_amo_i) == AMOSC) && sc_lrwait_successful_d))) begin

          // a write occurred to a reserved location
          lrwait_reservation_d[node_idx].head_valid = 1'b0;
          if (lrwait_reservation_q[node_idx].head == lrwait_reservation_q[node_idx].tail) begin
            // if head and tail match, it was the only node in the queue
            lrwait_reservation_d[node_idx].tail_valid = 1'b0;
          end
        end
      end // if (in_valid_i && in_ready_o)
    end // always_comb
  end else begin: disable_lrwait // block: gen_lrwait
    assign sc_lrwait_successful_d = 1'b0;

    assign successor_update_d = 1'b0;
    assign wake_up_data_d = 1'b0;
    assign wake_up_req = 1'b0;

    assign lrwait_meta = '0;
  end

  // ----------------
  // LR/SC
  // ----------------

  if (LrScEnable) begin : gen_lrsc
    localparam int unsigned CoreIdWidth  = idx_width(NumCores);
    localparam int unsigned IniAddrWidth = idx_width(NumCoresPerTile + NumGroups);

    // unique core identifier, does not necessarily match core_id
    logic [CoreIdWidth:0] unique_core_id;

    typedef struct packed {
      /// Is the reservation valid.
      logic                 valid;
      /// On which address is the reservation placed.
      /// This address is aligned to the memory size
      /// implying that the reservation happen on a set size
      /// equal to the word width of the memory (32 or 64 bit).
      logic [AddrWidth-1:0] addr;
      /// Which core made this reservation. Important to
      /// track the reservations from different cores and
      /// to prevent any live-locking.
      logic [CoreIdWidth:0] core;
    } reservation_t;
    reservation_t lrsc_reservation_d, lrsc_reservation_q;

    `FF(lrsc_reservation_q, lrsc_reservation_d, 1'b0, clk_i, rst_ni);

    always_comb begin
      // {group_id, tile_id, core_id}
      // MSB of ini_addr determines if request is coming from local or remote tile
      if (in_meta_i.ini_addr[IniAddrWidth-1] == 0) begin
        // Request is coming from the local tile
        // take group id of TCDM adapter
        unique_core_id = {'0, in_meta_i.tile_id, in_meta_i.ini_addr[IniAddrWidth-2:0]};
      end else begin
        // Request is coming from a remote tile
        // take group id from ini_addr
        // Ignore first bit of IniAddr to obtain the group address
        unique_core_id = {in_meta_i.ini_addr[IniAddrWidth-2:0],
                          in_meta_i.tile_id, in_meta_i.core_id};
      end

      lrsc_reservation_d = lrsc_reservation_q;
      sc_lrsc_successful_d = 1'b0;
      // new valid transaction
      if (in_valid_i && in_ready_o) begin

        // An SC can only pair with the most recent LR in program order.
        // Place a reservation on the address if there isn't already a valid reservation.
        // We prevent a live-lock by don't throwing away the reservation of a hart unless
        // it makes a new reservation in program order or issues any SC.
        if (amo_op_t'(in_amo_i) == AMOLR &&
            (!lrsc_reservation_q.valid || lrsc_reservation_q.core == unique_core_id)) begin
          lrsc_reservation_d.valid = 1'b1;
          lrsc_reservation_d.addr = in_address_i;
          lrsc_reservation_d.core = unique_core_id;
        end

        // An SC may succeed only if no store from another hart (or other device) to
        // the reservation set can be observed to have occurred between
        // the LR and the SC, and if there is no other SC between the
        // LR and itself in program order.

        // check whether another core has made a write attempt
        if ((unique_core_id != lrsc_reservation_q.core) &&
            (in_address_i == lrsc_reservation_q.addr) &&
            (!(amo_op_t'(in_amo_i) inside {AMONone, AMOLR, AMOSC, LRWAIT, SCWAIT}) || in_write_i ||
             (amo_op_t'(in_amo_i) ==  SCWAIT) && sc_lrwait_successful_d)) begin
          lrsc_reservation_d.valid = 1'b0;
        end

        // An SC from the same hart clears any pending reservation.
        if (lrsc_reservation_q.valid && amo_op_t'(in_amo_i) == AMOSC
            && lrsc_reservation_q.core == unique_core_id) begin
          lrsc_reservation_d.valid = 1'b0;
          sc_lrsc_successful_d = (lrsc_reservation_q.addr == in_address_i);
        end
      end
    end // always_comb
  end else begin : disable_lrsc
    assign sc_lrsc_successful_d = 1'b0;
  end

  // ----------------
  // Atomics
  // ----------------

  always_comb begin
    // feed-through
    in_ready_o  = in_valid_o && !in_ready_i ? 1'b0 : 1'b1;
    out_req_o   = in_valid_i && in_ready_o;
    out_add_o   = in_address_i;
    out_write_o = in_write_i || (sc_successful_d &&
                                 ((amo_op_t'(in_amo_i) == SCWAIT) ||
                                  (amo_op_t'(in_amo_i) == AMOSC)));
    out_wdata_o = in_wdata_i;
    out_be_o    = in_be_i;

    state_d     = state_q;
    load_amo    = 1'b0;

    unique case (state_q)
      Idle: begin
        if(in_valid_i && in_ready_o &&
           !(amo_op_t'(in_amo_i) inside {AMONone, AMOLR, AMOSC, LRWAIT, SCWAIT})) begin
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
  `endif
  // pragma translate_on

endmodule
