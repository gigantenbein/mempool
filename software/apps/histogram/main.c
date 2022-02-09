// Copyright 2021 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Author: Marc Gantenbein, ETH Zurich
#include <stdint.h>
#include <string.h>

#include "encoding.h"
#include "histogram.h"
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
 * NUMCYCLES: How many cycles do we run the application?
 */

/*
 * NBINS: How many bins are accessed?
 */

int main() {
  uint32_t core_id = mempool_get_core_id();
  uint32_t num_cores = mempool_get_core_count();
  // Initialize synchronization variables
  mempool_barrier_init(core_id);

  // initializes the heap allocator
  mempool_init(core_id, num_cores);

  if (core_id == 0){
    initialize_histogram();
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

  if(core_id == 0) {
    uint32_t sum = 0;
    for (uint32_t i = 0; i<vector_N; i++){
      sum += *(hist_bins+i);
    }
    write_csr(90, sum);
  }

  // wait until all cores have finished
  mempool_barrier(num_cores);

  return 0;
}
