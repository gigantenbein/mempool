# Copyright 2021 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

onerror {resume}
quietly WaveActivateNextPane {} 0

add wave -noupdate -group DUT /tcdm_adapter_tb/*

add wave -noupdate -group TCDMAdapter0 /tcdm_adapter_tb/gen_tcdms[0]/i_tcdm_adapter/*
add wave -noupdate -group TCDMAdapter0 /tcdm_adapter_tb/gen_tcdms[0]/i_tcdm_adapter/gen_lrwait/*
add wave -noupdate -group TCDMAdapter0 /tcdm_adapter_tb/gen_tcdms[0]/i_tcdm_adapter/gen_lrwait/gen_multip_lrwait_nodes/*
add wave -noupdate -group TCDMAdapter0 /tcdm_adapter_tb/gen_tcdms[0]/i_tcdm_adapter/i_metadata_register/*
add wave -noupdate -group TCDMAdapter0 /tcdm_adapter_tb/gen_tcdms[0]/i_tcdm_adapter/i_metadata_register/spill_register_flushable_i/gen_spill_reg/*
add wave -noupdate -group TCDMAdapter1 /tcdm_adapter_tb/gen_tcdms[1]/i_tcdm_adapter/*
add wave -noupdate -group TCDMAdapter2 /tcdm_adapter_tb/gen_tcdms[2]/i_tcdm_adapter/*
add wave -noupdate -group TCDMAdapter3 /tcdm_adapter_tb/gen_tcdms[3]/i_tcdm_adapter/*

add wave -noupdate -group QNODE0 /tcdm_adapter_tb/gen_qnodes[0]/i_lrwait_qnode/*
add wave -noupdate -group QNODE1 /tcdm_adapter_tb/gen_qnodes[1]/i_lrwait_qnode/*
add wave -noupdate -group QNODE2 /tcdm_adapter_tb/gen_qnodes[2]/i_lrwait_qnode/*
add wave -noupdate -group QNODE3 /tcdm_adapter_tb/gen_qnodes[3]/i_lrwait_qnode/*
add wave -noupdate -group QNODE4 /tcdm_adapter_tb/gen_qnodes[4]/i_lrwait_qnode/*
add wave -noupdate -group QNODE5 /tcdm_adapter_tb/gen_qnodes[5]/i_lrwait_qnode/*

add wave -noupdate -group interconnect_to_tcdm /tcdm_adapter_tb/gen_stream_xbar[0]/i_interconnect_req/*
add wave -noupdate -group interconnect_to_qnode /tcdm_adapter_tb/gen_stream_xbar[0]/i_interconnect_resp/*

# add wave -noupdate -group MEMBANK /tcdm_adapter_tb/mem_bank/*

# add wave -noupdate -group FALLTHROUGH /tcdm_adapter_tb/dut/i_rdata_register/*

# add wave -noupdate -group RDATA_FIFO /tcdm_adapter_tb/dut/i_rdata_register/i_fifo/*

run -a
