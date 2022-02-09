// Copyright 2021 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Author: Marc Gantenbein, ETH Zurich

#include <stdint.h>
#include <string.h>

#include "histogram.h"
#include "encoding.h"
#include "runtime.h"
#include "synchronization.h"

#define NUM_TCDMBANKS (NUM_CORES * 4)

// vector_a has an element in each TCDM bank
volatile uint32_t vector_a[vector_N] __attribute__((section(".l1_prio")));
volatile uint32_t vector_b[vector_N] __attribute__((section(".l1_prio")));
volatile uint32_t vector_c[vector_N] __attribute__((section(".l1_prio")));
volatile uint32_t vector_d[vector_N] __attribute__((section(".l1_prio")));
volatile uint32_t vector_e[vector_N] __attribute__((section(".l1_prio")));
volatile uint32_t vector_f[vector_N] __attribute__((section(".l1_prio")));
volatile uint32_t vector_g[vector_N] __attribute__((section(".l1_prio")));
volatile uint32_t vector_h[vector_N] __attribute__((section(".l1_prio")));

// indicates if core is active
volatile uint32_t core_status[NUM_CORES] __attribute__((section(".l1_prio")));

// if this flag == MATRIXCORES, all workers are finished with their task
volatile uint32_t finished_flag __attribute__((section(".l1_prio")));
volatile uint32_t num_active_cores __attribute__((section(".l1_prio")));

void vector_move_per_tcdm_bank(uint32_t core_id, uint32_t num_cores) {

  // start index where results are written
  uint32_t start_index = core_id * (vector_N / num_cores);
  uint32_t end_index   = (core_id + 1) * (vector_N / num_cores);

  mempool_barrier(num_cores);
  mempool_timer_t start_time = mempool_get_timer();

  // hardcode memory accesses such that you do 8 memory accesses to the same TCDM bank
  // each core uses TCDM banks in another part of mempool, s.t. each core has a unique
  // region which together cover all TCDM banks
  for (uint32_t i = 0; i < 20; i += 1) {
    vector_b[start_index+8*i+0] = *(vector_a + NUM_TCDMBANKS * (0 + 8 * i ) + core_id*16);
    vector_b[start_index+8*i+1] = *(vector_a + NUM_TCDMBANKS * (1 + 8 * i ) + core_id*16);
    vector_b[start_index+8*i+2] = *(vector_a + NUM_TCDMBANKS * (2 + 8 * i ) + core_id*16);
    vector_b[start_index+8*i+3] = *(vector_a + NUM_TCDMBANKS * (3 + 8 * i ) + core_id*16);
    vector_b[start_index+8*i+4] = *(vector_a + NUM_TCDMBANKS * (4 + 8 * i ) + core_id*16);
    vector_b[start_index+8*i+5] = *(vector_a + NUM_TCDMBANKS * (5 + 8 * i ) + core_id*16);
    vector_b[start_index+8*i+6] = *(vector_a + NUM_TCDMBANKS * (6 + 8 * i ) + core_id*16);
    vector_b[start_index+8*i+7] = *(vector_a + NUM_TCDMBANKS * (7 + 8 * i ) + core_id*16);
  }

  // stop timer
  mempool_timer_t stop_time = mempool_get_timer();
  uint32_t time_diff = stop_time - start_time;
  write_csr(time, time_diff);
}

// Move values from consecutive TCDM banks to other vector
void vector_move_vanilla(uint32_t core_id, uint32_t num_cores) {

  // start index where results are written
  uint32_t start_index = core_id * (vector_N / num_cores);

  mempool_barrier(num_cores);
  mempool_timer_t start_time = mempool_get_timer();

  // hardcode memory accesses such that you do 8 memory accesses to the same TCDM bank
  // each core uses TCDM banks in another part of mempool, s.t. each core has a unique
  // region which together cover all TCDM banks
  for (uint32_t j = 0; j < NUMCYCLES; j += 1000) {
    for (uint32_t i = 0; i < NUM_TCDMBANKS; i += 8) {
      vector_b[(start_index+i+0) % NUM_TCDMBANKS] = *(vector_a + (start_index+i+0) % NUM_TCDMBANKS);
      vector_b[(start_index+i+1) % NUM_TCDMBANKS] = *(vector_a + (start_index+i+1) % NUM_TCDMBANKS);
      vector_b[(start_index+i+2) % NUM_TCDMBANKS] = *(vector_a + (start_index+i+2) % NUM_TCDMBANKS);
      vector_b[(start_index+i+3) % NUM_TCDMBANKS] = *(vector_a + (start_index+i+3) % NUM_TCDMBANKS);
      vector_b[(start_index+i+4) % NUM_TCDMBANKS] = *(vector_a + (start_index+i+4) % NUM_TCDMBANKS);
      vector_b[(start_index+i+5) % NUM_TCDMBANKS] = *(vector_a + (start_index+i+5) % NUM_TCDMBANKS);
      vector_b[(start_index+i+6) % NUM_TCDMBANKS] = *(vector_a + (start_index+i+6) % NUM_TCDMBANKS);
      vector_b[(start_index+i+7) % NUM_TCDMBANKS] = *(vector_a + (start_index+i+7) % NUM_TCDMBANKS);

      vector_c[(start_index+i+0) % NUM_TCDMBANKS] = *(vector_d + (start_index+i+0) % NUM_TCDMBANKS);
      vector_c[(start_index+i+1) % NUM_TCDMBANKS] = *(vector_d + (start_index+i+1) % NUM_TCDMBANKS);
      vector_c[(start_index+i+2) % NUM_TCDMBANKS] = *(vector_d + (start_index+i+2) % NUM_TCDMBANKS);
      vector_c[(start_index+i+3) % NUM_TCDMBANKS] = *(vector_d + (start_index+i+3) % NUM_TCDMBANKS);
      vector_c[(start_index+i+4) % NUM_TCDMBANKS] = *(vector_d + (start_index+i+4) % NUM_TCDMBANKS);
      vector_c[(start_index+i+5) % NUM_TCDMBANKS] = *(vector_d + (start_index+i+5) % NUM_TCDMBANKS);
      vector_c[(start_index+i+6) % NUM_TCDMBANKS] = *(vector_d + (start_index+i+6) % NUM_TCDMBANKS);
      vector_c[(start_index+i+7) % NUM_TCDMBANKS] = *(vector_d + (start_index+i+7) % NUM_TCDMBANKS);


      // vector_c[start_index+i+0] = *(vector_d + (start_index+i+0) % NUM_TCDMBANKS);
      // vector_c[start_index+i+1] = *(vector_d + (start_index+i+1) % NUM_TCDMBANKS);
      // vector_c[start_index+i+2] = *(vector_d + (start_index+i+2) % NUM_TCDMBANKS);
      // vector_c[start_index+i+3] = *(vector_d + (start_index+i+3) % NUM_TCDMBANKS);
      // vector_c[start_index+i+4] = *(vector_d + (start_index+i+4) % NUM_TCDMBANKS);
      // vector_c[start_index+i+5] = *(vector_d + (start_index+i+5) % NUM_TCDMBANKS);
      // vector_c[start_index+i+6] = *(vector_d + (start_index+i+6) % NUM_TCDMBANKS);
      // vector_c[start_index+i+7] = *(vector_d + (start_index+i+7) % NUM_TCDMBANKS);
    }
  }

  // stop timer
  mempool_timer_t stop_time = mempool_get_timer();
  uint32_t time_diff = stop_time - start_time;
  write_csr(time, time_diff);
}

int main() {
  uint32_t core_id = mempool_get_core_id();
  uint32_t num_cores = mempool_get_core_count();
  // Initialize barrier and synchronize
  mempool_barrier_init(core_id);

  if (core_id == 0){
    uint32_t random_number = 0;
    uint32_t drawn_number = 0;

    initialize_histogram();

    for (int i = 0; i<NUM_CORES; i++){
      core_status[i] = 0;
    }

    // set random cores to active
    for (int i = 0; i<MATRIXCORES; i++){
      // make sure every core is distinct, i.e. no collision
      do {
        asm volatile("csrr %0, mscratch" : "=r"(random_number));
        drawn_number = random_number % NUM_CORES;
      } while(core_status[drawn_number] == 1);

      core_status[drawn_number] = 1;
      write_csr(92, drawn_number);
    }
    // get number of active cores
    num_active_cores = 0;
    for (int i = 0; i < NUM_CORES; i++) {
      num_active_cores += core_status[i];
    }
    finished_flag = 0;
  }

  mempool_barrier(num_cores);

  if (core_status[core_id]){
    // wait for other cores to start histogram application
    mempool_wait(100);

    // start working task
    vector_move_vanilla(core_id, num_active_cores);

    // primitive barrier to wait for all workers to finish
    amo_add(&finished_flag, 1);
    while(finished_flag < num_active_cores) {
      mempool_wait(100);
    }
  } else {
    // Polling access of Pollers
    while(1) {
      // polling access
#if MUTEX != 10
      histogram_iteration(core_id);
#else
      // idling
      mempool_wait(1000);
#endif
    }
  }

  return 0;
}
