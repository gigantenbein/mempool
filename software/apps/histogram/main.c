// Copyright 2021 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Author: Marc Gantenbein, ETH Zurich
#include <stdint.h>
#include <string.h>
#include "amo_mutex.h"
#include "encoding.h"
#include "histogram.h"
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
 * MUTEX == 11 MWait
 * MUTEX == 12 AMO ADD
 * MUTEX == 13 Exponential backoff amo_lock/spin_lock
 * MUTEX == 14 Exponential backoff LR/SC
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

volatile uint32_t check_iter __attribute__((section(".l1_prio")));



int main() {
  uint32_t core_id = mempool_get_core_id();
  uint32_t num_cores = mempool_get_core_count();
  // Initialize synchronization variables
  mempool_barrier_init(core_id);

  // initializes the heap allocator
  mempool_init(core_id, num_cores);

  if (core_id == 0){
    initialize_histogram();
    check_iter  = 0;
  }

  mempool_barrier(num_cores);

  uint32_t hist_iterations = 0;
  mempool_timer_t countdown = 0;

  mempool_barrier(num_cores);
  mempool_timer_t start_time = mempool_get_timer();

  while(countdown < NUMCYCLES + start_time) {
    histogram_iteration(core_id);
    hist_iterations++;
    countdown = mempool_get_timer();
  }

  write_csr(time, hist_iterations);

  mempool_barrier(num_cores);
  amo_add(&check_iter, hist_iterations);
  mempool_barrier(num_cores);

  if(core_id == 0) {
    uint32_t sum = 0;
    for (uint32_t i = 0; i<vector_N; i++){
      sum += *(hist_bins+i);
    }
    write_csr(90, sum);
    write_csr(91, check_iter);
  }

  // wait until all cores have finished
  mempool_barrier(num_cores);

  return 0;
}
