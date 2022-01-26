// Copyright 2021 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Author: Marc Gantenbein, ETH Zurich
#include <stdint.h>
#include <stdlib.h>
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
 */

/*
 * BACKOFF: Number of cycles to backoff after failed mutex access
 */

/*
 * NUMCYCLES: How many cycles do we run the application?
 */

/*
 * NBINS: How many bins are accessed?
 */

uint32_t hist_bins[NBINS] __attribute__((section(".l1_prio")));

#if MUTEX == 1 || MUTEX == 4 || MUTEX == 5
// amo mutex or LR/SC mutex or LRWait mutex
amo_mutex_t* hist_locks[NBINS] __attribute__((section(".l1_prio")));
#elif MUTEX == 2 || MUTEX == 3
// msc mutex or lrwait_software
mcs_lock_t* hist_locks[NBINS] __attribute__((section(".l1_prio")));
mcs_lock_t* mcs_nodes[NUM_CORES] __attribute__((section(".l1_prio")));
#endif

int main() {
  uint32_t core_id = mempool_get_core_id();
  uint32_t num_cores = mempool_get_core_count();
  // Initialize synchronization variables
  mempool_barrier_init(core_id);

  // initializes the heap allocator
  mempool_init(core_id, num_cores);

  if (core_id == 0){
    // Initialize series of bins and all of them to zero
    for (int i = 0; i<NBINS; i++){
      hist_bins[i] =0;

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
  }

  mempool_barrier(num_cores);
  uint32_t drawn_number = 0;

  uint32_t bin_value = 0;
  uint32_t hist_iterations = 0;
  uint32_t random_number = 0;
  uint32_t sc_result = 0;
  mempool_timer_t countdown = 0;

  mempool_barrier(num_cores);
  mempool_timer_t start_time = mempool_get_timer();

  while(countdown < NUMCYCLES + start_time) {
    asm volatile("csrr %0, mscratch" : "=r"(random_number));
    drawn_number = random_number % NBINS;
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
    do {
      mempool_wait(BACKOFF);
      bin_value = load_reserved_wait((hist_bins + drawn_number)) + 1;
    } while(store_conditional_wait((hist_bins+drawn_number), bin_value));
#elif MUTEX == 7
    // LR/SC with BACKOFF
    do {
      mempool_wait(BACKOFF);
      bin_value = load_reserved((hist_bins + drawn_number)) + 1;
    } while(store_conditional((hist_bins+drawn_number), bin_value));
#elif MUTEX == 8
    // LRBackoff
    do {
      mempool_wait(sc_result*BACKOFF);
      bin_value = load_reserved((hist_bins + drawn_number)) + 1;
      sc_result = store_conditional((hist_bins+drawn_number), bin_value);
    } while(sc_result != 0);

#endif
    hist_iterations++;
    countdown = mempool_get_timer();
  }

  write_csr(time, hist_iterations);

  mempool_barrier(num_cores);

  if(core_id == 0) {
    uint32_t sum = 0;
    for (uint32_t i = 0; i<NBINS; i++){
      sum += *(hist_bins+i);
    }
    write_csr(90, sum);
  }
  mempool_barrier(num_cores);
  // wait until all cores have finished
  return 0;
}
