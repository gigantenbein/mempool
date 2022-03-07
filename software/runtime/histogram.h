// Copyright 2021 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Author: Marc Gantenbein, ETH Zurich

// Description: Synthetic histogram application with different mutex accesses

#ifndef __HISTOGRAM_H__
#define __HISTOGRAM_H__

#include "amo_mutex.h"
#include "encoding.h"

#include "runtime.h"
#include "synchronization.h"

#if MUTEX == 0 || MUTEX == 4 ||  MUTEX == 7 || MUTEX == 8
#include "lr_sc_mutex.h"
#elif MUTEX == 5 || MUTEX == 6
#include "lrwait_mutex.h"
#endif

#if MUTEX == 2 || MUTEX == 3 || MUTEX == 11
#include "mcs_mutex.h"
#endif

#define vector_N (NUM_CORES * 4) // NUM_CORES / 4 * NUM_TCDMBANKS_PER_TILE (=16)

// allocate bins accross all TCDM banks
volatile uint32_t hist_bins[vector_N] __attribute__((section(".l1_prio")));

// pick random indices for the histogram bins
volatile uint32_t hist_indices[NBINS] __attribute__((section(".l1_prio")));

#if MUTEX == 1 || MUTEX == 4 || MUTEX == 5
// amo mutex or LR/SC mutex or LRWait mutex
amo_mutex_t* hist_locks[NBINS] __attribute__((section(".l1_prio")));
#elif MUTEX == 2 || MUTEX == 3 || MUTEX == 11
// msc mutex or lrwait_software
mcs_lock_t* hist_locks[NBINS] __attribute__((section(".l1_prio")));
mcs_lock_t* mcs_nodes[NUM_CORES] __attribute__((section(".l1_prio")));
#endif

int32_t initialize_histogram() {
  uint32_t drawn_number = 0;
  uint32_t random_number = 0;
  // Initialize series of bins and all of them to zero
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

    // initalize mutexes
#if MUTEX == 1 || MUTEX == 4 || MUTEX == 5
    hist_locks[i] = amo_allocate_mutex();
#elif MUTEX == 2 || MUTEX == 3 || MUTEX == 11
    hist_locks[i] = initialize_mcs_lock();
#endif

  }
#if MUTEX == 2 || MUTEX == 11
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
  return 0;
}


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
static inline void histogram_iteration(uint32_t core_id) {
  uint32_t drawn_number = 0;
  uint32_t random_number = 0;
  uint32_t bin_value = 0;
  // index of histogram bin
  uint32_t hist_index = 0;
  uint32_t hist_iterations = 0;
  uint32_t sc_result = 0;

  asm volatile("csrr %0, mscratch" : "=r"(random_number));
  drawn_number = random_number % NBINS;

  // pick index that assigns a random bin to drawn number
  hist_index = hist_indices[drawn_number];
#if MUTEX == 0
  // Vanilla LR/SC
  do {
    bin_value = load_reserved((hist_bins + hist_index)) + 1;
  } while(store_conditional((hist_bins+hist_index), bin_value));
#elif MUTEX == 1
  // Amo lock
  amo_lock_mutex(hist_locks[drawn_number], BACKOFF);
  hist_bins[hist_index] += 1;
  amo_unlock_mutex(hist_locks[drawn_number]);
#elif MUTEX == 2
  // MCS lock
  lock_mcs(hist_locks[drawn_number], mcs_nodes[core_id], BACKOFF);
  hist_bins[hist_index] += 1;
  unlock_mcs(hist_locks[drawn_number], mcs_nodes[core_id], BACKOFF);
#elif MUTEX == 3
  // LRWait MCS/Software based LRWait
  lrwait_mcs(hist_locks[drawn_number], mcs_nodes[core_id]);
  hist_bins[hist_index] += 1;
  lrwait_wakeup_mcs(hist_locks[drawn_number], mcs_nodes[core_id], BACKOFF);
#elif MUTEX == 4
  // LR/SC lock
  lr_sc_lock_mutex(hist_locks[drawn_number], BACKOFF);
  hist_bins[hist_index] += 1;
  lr_sc_unlock_mutex(hist_locks[drawn_number]);
#elif MUTEX == 5
  // LRWait lock
  lrwait_lock_mutex(hist_locks[drawn_number], BACKOFF);
  hist_bins[hist_index] += 1;
  lrwait_unlock_mutex(hist_locks[drawn_number]);
#elif MUTEX == 6
  // LRWait vanilla
  bin_value = load_reserved_wait((hist_bins + hist_index)) + 1;
  while(store_conditional_wait((hist_bins+hist_index), bin_value)) {
    mempool_wait(BACKOFF);
    bin_value = load_reserved_wait((hist_bins + hist_index)) + 1;
  }
#elif MUTEX == 7
  // LR/SC with BACKOFF
  bin_value = load_reserved((hist_bins + hist_index)) + 1;
  while(store_conditional((hist_bins+hist_index), bin_value)) {
    mempool_wait(BACKOFF);
    bin_value = load_reserved((hist_bins + hist_index)) + 1;
  }
#elif MUTEX == 8
  // LRBackoff
  bin_value = load_reserved((hist_bins + hist_index)) + 1;
  sc_result = store_conditional((hist_bins+hist_index), bin_value);
  while(sc_result != 0) {
    mempool_wait(sc_result*BACKOFF);
    bin_value = load_reserved((hist_bins + hist_index)) + 1;
    sc_result = store_conditional((hist_bins+hist_index), bin_value);
  }
#elif MUTEX == 9
  mempool_wait(BACKOFF);
  hist_bins[hist_index] += 1;
#elif MUTEX == 11
  // LRWait MCS/Software based LRWait
  mwait_mcs(hist_locks[drawn_number], mcs_nodes[core_id]);
  hist_bins[hist_index] += 1;
  unlock_mcs(hist_locks[drawn_number], mcs_nodes[core_id], BACKOFF);
#endif
}
#endif // HISTOGRAM_H
