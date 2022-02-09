// Copyright 2021 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Author: Marc Gantenbein, ETH Zurich

#include <stdint.h>
#include <string.h>

#include "encoding.h"
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

// vector_a has an element in each TCDM bank
volatile uint32_t vector_a[vector_N] __attribute__((section(".l1_prio")));
volatile uint32_t vector_b[vector_N] __attribute__((section(".l1_prio")));
volatile uint32_t vector_c[vector_N] __attribute__((section(".l1_prio")));
volatile uint32_t vector_d[vector_N] __attribute__((section(".l1_prio")));

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
    initialize_histogram();
    for (int i = 0; i<NUM_CORES; i++){
      core_status[i] = 0;
    }
    finished_flag = 0;
  }

  mempool_barrier(num_cores);
  // used to calculate throughput of application
  uint32_t hist_iterations = 0;
  uint32_t task_number = 0;
  uint32_t sc_result = 0;
  mempool_timer_t countdown = 0;

  mempool_barrier(num_cores);
  mempool_timer_t start_time = mempool_get_timer();

  mempool_barrier(num_cores);

  while (countdown < NUMCYCLES + start_time) {
    // polling access
#if MUTEX != 10
    histogram_iteration(core_id);
#else
    // idling
    mempool_wait(1000);
#endif

    // draw a random number from 0 to 8
    // depending on number, to this many iterations on other task
    asm volatile("csrr %0, mscratch" : "=r"(random_number));
    task_number = random_number % 10;

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
