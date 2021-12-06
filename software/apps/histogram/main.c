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
#include "printf.h"
#include "runtime.h"
#include "synchronization.h"

void shift_lfsr(uint32_t *lfsr)
{
  *lfsr ^= *lfsr >> 7;
  *lfsr ^= *lfsr << 9;
  *lfsr ^= *lfsr >> 13;
}

uint32_t NUMBER_OF_CYCLES = 1000;

uint32_t hist_bins[NBINS] __attribute__((section(".l1_prio")));

#if MUTEX == 1
// amo mutex
amo_mutex_t* hist_locks[NBINS] __attribute__((section(".l1_prio")));
#elif MUTEX == 2
// msc mutex
mcs_lock_t* hist_locks[NBINS] __attribute__((section(".l1_prio")));
mcs_lock_t* mcs_nodes[NUM_CORES] __attribute__((section(".l1_prio")));
#elif MUTEX == 3
// lrwait software
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
      
#if MUTEX == 1
      hist_locks[i] = amo_allocate_mutex();
#elif MUTEX == 2
      hist_locks[i] = initialize_mcs_lock();
#elif MUTEX == 3
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
  uint32_t init_lfsr = core_id * 42 + 1;

  uint32_t bin_value = 0;
  uint32_t lr_counter = 0;
  mempool_barrier(num_cores);
  mempool_timer_t start_time = mempool_get_timer();

  uint32_t hist_iterations = 0;
  mempool_timer_t countdown = 0;

  while(countdown < NUMBER_OF_CYCLES) {
    // needs seed as pointer
    shift_lfsr(&init_lfsr);
    drawn_number = init_lfsr % NBINS;
#if MUTEX == 1
    amo_lock_mutex(hist_locks[drawn_number]);
    hist_bins[drawn_number] += 1;
    amo_unlock_mutex(hist_locks[drawn_number]);
#elif MUTEX == 2
    lock_mcs(hist_locks[drawn_number], mcs_nodes[core_id]);
    hist_bins[drawn_number] += 1;
    unlock_mcs(hist_locks[drawn_number], mcs_nodes[core_id]);
#elif MUTEX == 3
    lrwait_mcs(hist_locks[drawn_number], mcs_nodes[core_id]);
    hist_bins[drawn_number] += 1;
    lrwait_wakeup_mcs(hist_locks[drawn_number], mcs_nodes[core_id]);
#else
    do {
      bin_value = load_reserved((hist_bins + drawn_number)) + 1;
      lr_counter += 1;
    } while(store_conditional((hist_bins+drawn_number), bin_value));
#endif
    hist_iterations++;
    countdown = mempool_get_timer() - start_time;
  }

  write_csr(time, hist_iterations++);
  
#if MUTEX==0
  write_csr(99, lr_counter);
#endif

  mempool_barrier(num_cores);
  
  // if(core_id == 0) {
  //   uint32_t sum = 0;
  //   for (uint32_t i = 0; i<NBINS; i++){
  //     sum += *(hist_bins+i);
  //   }
  //   if (sum != NDRAWS*num_cores){
  //     return -1;
  //   }
  // }
  // wait until all cores have finished
  return 0;
}
