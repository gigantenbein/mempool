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
 * MUTEX == 0  LR/SC
 * MUTEX == 1  amo lock (parametrized)
 * MUTEX == 2  MCS lock
 * MUTEX == 3  LRWait MCS (Software based LRWait)
 * MUTEX == 4  LR/SC lock (parametrized)
 * MUTEX == 5  LRWait lock (parametrized)
 * MUTEX == 6  LRWait vanilla
 * MUTEX == 7  Software backoff (parametrized)
 * MUTEX == 8  hardware aided backoff (parametrized)
 * MUTEX == 9  LOAD/STORE without mutex
 * MUTEX == 10 idle pollers (no activity)
 */

/*
 * BACKOFF: Number of cycles to backoff after failed mutex access
 */

/*
 * NBINS: How many bins are accessed?
 */

#define NUM_TCDMBANKS (NUM_CORES * 4)

#define vector_N (NUM_CORES * 4) // NUM_CORES / 4 * NUM_TCDMBANKS_PER_TILE (=16)

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
volatile uint32_t num_active_cores __attribute__((section(".l1_prio")));

// Move values from consecutive TCDM banks to other vector
void vector_move_vanilla(uint32_t core_id, uint32_t num_cores) {

  // start index where results are written
  uint32_t start_index = core_id * (vector_N / num_cores);

  for (uint32_t i = 0; i < NUM_TCDMBANKS; i += 8) {
    vector_b[(start_index+i+0) % NUM_TCDMBANKS] = *(vector_a + (start_index+i+0) % NUM_TCDMBANKS);
    vector_b[(start_index+i+1) % NUM_TCDMBANKS] = *(vector_a + (start_index+i+1) % NUM_TCDMBANKS);
    vector_b[(start_index+i+2) % NUM_TCDMBANKS] = *(vector_a + (start_index+i+2) % NUM_TCDMBANKS);
    vector_b[(start_index+i+3) % NUM_TCDMBANKS] = *(vector_a + (start_index+i+3) % NUM_TCDMBANKS);
    vector_b[(start_index+i+4) % NUM_TCDMBANKS] = *(vector_a + (start_index+i+4) % NUM_TCDMBANKS);
    vector_b[(start_index+i+5) % NUM_TCDMBANKS] = *(vector_a + (start_index+i+5) % NUM_TCDMBANKS);
    vector_b[(start_index+i+6) % NUM_TCDMBANKS] = *(vector_a + (start_index+i+6) % NUM_TCDMBANKS);
    vector_b[(start_index+i+7) % NUM_TCDMBANKS] = *(vector_a + (start_index+i+7) % NUM_TCDMBANKS);
  }
}

int main() {
  uint32_t core_id = mempool_get_core_id();
  uint32_t num_cores = mempool_get_core_count();
  // Initialize barrier and synchronize
  mempool_barrier_init(core_id);

  volatile uint32_t random_number = 0;
  volatile uint32_t drawn_number = 0;

  if (core_id == 0){
    for (uint32_t i = 0; i < vector_N; i++) {
      hist_bins[i] = 0;
    }
    if (NBINS > vector_N) {
      // make sure we have enough spots for our bins
      return -1;
    }
    for (int i = 0; i<NBINS; i++){
      // generate unique random histogram bins
      do {
        asm volatile("csrr %0, mscratch" : "=r"(random_number));
        drawn_number = random_number % vector_N;
      } while(hist_bins[drawn_number] == 1);
      write_csr(93, drawn_number);
      hist_bins[drawn_number] = 1;
      hist_indices[i] = drawn_number;

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
    finished_flag = 0;
  }

  mempool_barrier(num_cores);
  uint32_t bin_value = 0;

  // used to calculate throughput of application
  uint32_t hist_iterations = 0;
  uint32_t task_number = 0;
  uint32_t sc_result = 0;
  mempool_timer_t countdown = 0;

  mempool_barrier(num_cores);
  mempool_timer_t start_time = mempool_get_timer();

  mempool_barrier(num_cores);

  while (countdown < NUMCYCLES + start_time) {
    // draw a random number from 0 to 8
    // depending on number, to this many iterations on other task
    asm volatile("csrr %0, mscratch" : "=r"(random_number));
    task_number = random_number % 10;

#if MUTEX != 10
    asm volatile("csrr %0, mscratch" : "=r"(random_number));
    drawn_number = random_number % NBINS;
    // pick index that assigns a random bin to drawn number
    drawn_number = hist_indices[drawn_number];
#endif

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
    mempool_wait(BACKOFF);
    hist_bins[drawn_number] += 1;
#elif MUTEX == 10
    // idling
    mempool_wait(1000);
#endif
    // if (task_number % 4 == 0) {
    if (0) {
      for (uint32_t i = 0; i < task_number; i++) {
        vector_move_vanilla(core_id, NUM_CORES);
      }
    } else {
      mempool_wait(task_number);
    }
    hist_iterations++;
    countdown = mempool_get_timer();
  }
  write_csr(time, hist_iterations);

  // wait until all cores have finished
  mempool_barrier(num_cores);

  return 0;
}
