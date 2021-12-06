// Copyright 2021 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Author: Samuel Riedel, ETH Zurich

#include <stdint.h>
#include <string.h>

#include "alloc.h"
#include "amo_mutex.h"
#include "encoding.h"
#include "lr_sc_mutex.h"
#include "mcs_mutex.h"
#include "printf.h"
#include "runtime.h"
#include "synchronization.h"
#include "xpulp/mat_mul.h"

// laziness
#define MUTEX 0

#define matrix_M 64
#define matrix_N 32
#define matrix_P 64

#define vector_N 16*256

int32_t vector_a[vector_N] __attribute__((section(".l1_prio")));
int32_t vector_b[vector_N] __attribute__((section(".l1_prio")));

void shift_lfsr(uint32_t *lfsr) {
  *lfsr ^= *lfsr >> 7;
  *lfsr ^= *lfsr << 9;
  *lfsr ^= *lfsr >> 13;
}

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

void memory_strider(uint32_t core_id, uint32_t num_cores) {
  mempool_barrier(num_cores);
  
  uint32_t* strider = core_id * 1024;
  uint32_t ret = 0;

  mempool_timer_t start_time = mempool_get_timer();
  for (int i = 0; i < 1024; i++) {
    // strider
    // *strider += 1;
    ret += *strider;
    strider += 1;
    mempool_wait(1);
    if (i % 100 == 0){
      write_csr(99,i);
    }
  }

  mempool_timer_t stop_time = mempool_get_timer();
  uint32_t time_diff = stop_time - start_time;
  write_csr(time, time_diff);
}

void vector_mult(uint32_t core_id, uint32_t num_cores) {
  // init vector

  if (core_id == 0) {
    for (uint32_t i = 0; i < vector_N; i++) {
      // vector_a[i] = rand_r(&seed);
      // vector_b[i] = rand_r(&seed);
      vector_a[i] = i;
      vector_b[i] = i;
    }
  }
  mempool_barrier(num_cores);

  // start time
  mempool_timer_t start_time = mempool_get_timer();
  
  for (uint32_t j = 0 ; j < 5 ; j++){
    for (uint32_t i = 0; i < vector_N; i += 8) {
      vector_a[i]   += vector_a[i]   * vector_b[i] *   (core_id + 1);
      vector_a[i+1] += vector_a[i+1] * vector_b[i+1] * (core_id + 1);
      vector_a[i+2] += vector_a[i+2] * vector_b[i+2] * (core_id + 1);
      vector_a[i+3] += vector_a[i+3] * vector_b[i+3] * (core_id + 1);
      vector_a[i+4] += vector_a[i+4] * vector_b[i+4] * (core_id + 1);
      vector_a[i+5] += vector_a[i+5] * vector_b[i+5] * (core_id + 1);
      vector_a[i+6] += vector_a[i+6] * vector_b[i+6] * (core_id + 1);
      vector_a[i+7] += vector_a[i+7] * vector_b[i+7] * (core_id + 1);
    }
  }
  // stop timer
  mempool_timer_t stop_time = mempool_get_timer();
  uint32_t time_diff = stop_time - start_time;
  write_csr(time, time_diff);
  mempool_barrier(num_cores);
}

int main() {
  uint32_t core_id = mempool_get_core_id();
  uint32_t num_cores = mempool_get_core_count();
  // Initialize barrier and synchronize
  mempool_barrier_init(core_id);

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
      // has to be waken up
      mcs_nodes[i] = initialize_lrwait_mcs(i);
    }
#endif
  }
  mempool_barrier(num_cores);
  uint32_t drawn_number = 0;
  uint32_t init_lfsr = core_id * 42 + 1;
  
#if MUTEX == 0
  uint32_t bin_value = 0;
  uint32_t lr_counter = 0;
#endif

  mempool_barrier(num_cores);

  if (core_id < MATRIXCORES){
    // Test the Matrix multiplication
    //    test_matrix_multiplication(matrix_a, matrix_b, matrix_c, matrix_M, matrix_N,
    //                         matrix_P, core_id, MATRIXCORES);
    // memory_strider(core_id, MATRIXCORES);
    vector_mult(core_id, MATRIXCORES);
  } else {
    while(1) {
      if(!OTHER_CORE_IDLE) {
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
      } else {
        mempool_wait(100);
      }
    }
  }
    
  // wait until all cores have finished
  mempool_barrier(MATRIXCORES);

  return 0;
}
