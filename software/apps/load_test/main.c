// Copyright 2021 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Author: Marc Gantenbein, ETH Zurich

#include <stdint.h>
#include <string.h>

#include "alloc.h"
#include "amo_mutex.h"
#include "encoding.h"
#include "lr_sc_mutex.h"
#include "mcs_mutex.h"
#include "runtime.h"
#include "synchronization.h"

/*
 * MUTEX == 0 LR/SC
 * MUTEX == 1 amo lock (parametrized)
 * MUTEX == 2 MCS lock
 * MUTEX == 3 LRWait MCS (Software based LRWait)
 * MUTEX == 4 LR/SC lock (parametrized)
 * MUTEX == 5 LRWait lock (parametrized)
 * MUTEX == 6 LRWait vanilla
 * MUTEX == 7 Software backoff (parametrized)
 * MUTEX == 8 hardware aided backoff (parametrized)
 * MUTEX == 9 LOAD/STORE without mutex
 */

/*
 * BACKOFF: Number of cycles to backoff after failed mutex access
 */

/*
 * NBINS: How many bins are accessed?
 */

#define NUM_TCDMBANKS NUM_CORES * 4

#define vector_N NUM_CORES * 4 // NUM_CORES / 4 * NUM_TCDMBANKS_PER_TILE (=16)

// vector_a has an element in each TCDM bank
volatile uint32_t vector_a[vector_N] __attribute__((section(".l1_prio")));
volatile uint32_t vector_b[vector_N] __attribute__((section(".l1_prio")));
volatile uint32_t vector_c[vector_N] __attribute__((section(".l1_prio")));
volatile uint32_t vector_d[vector_N] __attribute__((section(".l1_prio")));
volatile uint32_t vector_e[vector_N] __attribute__((section(".l1_prio")));
volatile uint32_t vector_f[vector_N] __attribute__((section(".l1_prio")));
volatile uint32_t vector_g[vector_N] __attribute__((section(".l1_prio")));
volatile uint32_t vector_h[vector_N] __attribute__((section(".l1_prio")));

// allocate bins accross all TCDM banks
volatile uint32_t hist_bins[vector_N] __attribute__((section(".l1_prio")));

// pick random indices for the histogram bins
volatile uint32_t hist_indices[NBINS] __attribute__((section(".l1_prio")));

#if MUTEX == 1 || MUTEX == 4 || MUTEX == 5
// amo mutex or LR/SC mutex or LRWait mutex
amo_mutex_t* hist_locks[NBINS] __attribute__((section(".l1_prio")));
#elif MUTEX == 2 || MUTEX == 3
// msc mutex or lrwait_software
mcs_lock_t* hist_locks[NBINS] __attribute__((section(".l1_prio")));
mcs_lock_t* mcs_nodes[NUM_CORES] __attribute__((section(".l1_prio")));
#endif

// indicates if core is active
volatile uint32_t core_status[NUM_CORES] __attribute__((section(".l1_prio")));

// if this flag == MATRIXCORES, all workers are finished with their task
volatile uint32_t finished_flag __attribute__((section(".l1_prio")));

void vector_move_per_tcdm_bank(uint32_t core_id, uint32_t num_cores) {

  // start index where results are written
  uint32_t start_index = core_id * (vector_N / num_cores);
  uint32_t end_index   = (core_id + 1) * (vector_N / num_cores);

  mempool_barrier(num_cores);
  mempool_timer_t start_time = mempool_get_timer();

  // hardcode memory accesses such that you do 8 memory accesses to the same TCDM bank
  // each core uses TCDM banks in another part of mempool, s.t. each core has a unique
  // region which together cover all TCDM banks
  for (uint32_t i = 0; i < 2; i += 1) {
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

  uint32_t random_number = 0;
  uint32_t drawn_number = 0;

  if (core_id == 0){


    for (int i = 0; i<NBINS; i++){
      asm volatile("csrr %0, mscratch" : "=r"(random_number));
      drawn_number = random_number % NUM_CORES;
      hist_indices[i] = drawn_number;
      write_csr(93, drawn_number);
      hist_bins[drawn_number] = 0;

      // initialize mutexes
#if MUTEX == 1 || MUTEX == 4 || MUTEX == 5
      hist_locks[i] = amo_allocate_mutex();
#elif MUTEX == 2 || MUTEX == 3
      hist_locks[i] = initialize_mcs_lock();
#endif
    }
#if MUTEX == 2
    for (int i = 0; i < NUM_CORES; i++){
      mcs_nodes[i] = initialize_mcs_lock(i);
    }
#elif MUTEX == 3
    for (int i = 0; i < NUM_CORES; i++){
      // pass core_id to lock to indicate which node
      // has to be woken up
      mcs_nodes[i] = initialize_lrwait_mcs(i);
    }
#endif

    for (int i = 0; i<NUM_CORES; i++){
      core_status[i] = 0;
    }

    // set random cores to active
    for (int i = 0; i<MATRIXCORES; i++){
      asm volatile("csrr %0, mscratch" : "=r"(random_number));
      drawn_number = random_number % NUM_CORES;
      core_status[drawn_number] = 1;
      write_csr(92, drawn_number);
    }
    finished_flag = 0;
  }

  mempool_barrier(num_cores);

  volatile uint32_t bin_value = 0;
  uint32_t sc_result = 0;
  uint32_t lr_counter = 0;

  mempool_barrier(num_cores);

  // if (core_status[core_id]){
  if (core_id < MATRIXCORES) {
    // wait for other cores to start histogram application
    // vector_move_per_tcdm_bank(core_id, MATRIXCORES);

    vector_move_vanilla(core_id, MATRIXCORES);
    // primitive barrier to wait for all workers to finish
    amo_add(&finished_flag, 1);
    while(finished_flag < MATRIXCORES) {
      mempool_wait(100);
    }
  } else {

    // Polling access of Pollers
    while(1) {
      if(!OTHERCOREIDLE) {
        // polling access
        asm volatile("csrr %0, mscratch" : "=r"(random_number));
        drawn_number = random_number % NBINS;
        // pick index that assigns a random bin to drawn number
        drawn_number = hist_indices[drawn_number];

#if MUTEX == 0
        // Vanilla LR/SC
        do {
          bin_value = load_reserved((hist_bins + drawn_number)) + 1;
        } while(store_conditional((hist_bins+drawn_number), bin_value));
#elif MUTEX == 1
        // Amo lock
        amo_lock_mutex(hist_locks[drawn_number], BACKOFF);
        hist_bins[drawn_number] += 1;
        amo_unlock_mutex(hist_locks[drawn_number]);
#elif MUTEX == 2
        // MCS lock
        lock_mcs(hist_locks[drawn_number], mcs_nodes[core_id], BACKOFF);
        hist_bins[drawn_number] += 1;
        unlock_mcs(hist_locks[drawn_number], mcs_nodes[core_id], BACKOFF);
#elif MUTEX == 3
        // LRWait MCS/Software based LRWait
        lrwait_mcs(hist_locks[drawn_number], mcs_nodes[core_id]);
        hist_bins[drawn_number] += 1;
        lrwait_wakeup_mcs(hist_locks[drawn_number], mcs_nodes[core_id], BACKOFF);
#elif MUTEX == 4
        // LR/SC lock
        lr_sc_lock_mutex(hist_locks[drawn_number], BACKOFF);
        hist_bins[drawn_number] += 1;
        lr_sc_unlock_mutex(hist_locks[drawn_number]);
#elif MUTEX == 5
        // LRWait lock
        lrwait_lock_mutex(hist_locks[drawn_number], BACKOFF);
        hist_bins[drawn_number] += 1;
        lrwait_unlock_mutex(hist_locks[drawn_number]);
#elif MUTEX == 6
        // LRWait vanilla
        bin_value = load_reserved_wait((hist_bins + drawn_number)) + 1;
        while(store_conditional_wait((hist_bins+drawn_number), bin_value)) {
          mempool_wait(BACKOFF);
          bin_value = load_reserved_wait((hist_bins + drawn_number)) + 1;
        }
#elif MUTEX == 7
        // LR/SC with BACKOFF
        bin_value = load_reserved((hist_bins + drawn_number)) + 1;
        while(store_conditional((hist_bins+drawn_number), bin_value)) {
          mempool_wait(BACKOFF);
          bin_value = load_reserved((hist_bins + drawn_number)) + 1;
        }
#elif MUTEX == 8
        // LRBackoff
        bin_value = load_reserved((hist_bins + drawn_number)) + 1;
        sc_result = store_conditional((hist_bins+drawn_number), bin_value);
        while(sc_result != 0) {
          mempool_wait(sc_result*BACKOFF);
          bin_value = load_reserved((hist_bins + drawn_number)) + 1;
          sc_result = store_conditional((hist_bins+drawn_number), bin_value);
        }
#elif MUTEX == 9
        // mempool_wait(BACKOFF);
        hist_bins[drawn_number] += 1;
#endif
      } else {
        mempool_wait(1000);
      }
    }
  }

  return 0;
}
