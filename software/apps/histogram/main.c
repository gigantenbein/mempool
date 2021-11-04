// Copyright 2021 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Author: Marc Gantenbein, ETH Zurich
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "alloc.h"
#include "encoding.h"
#include "lr_sc_mutex.h"
#include "printf.h"
#include "runtime.h"
#include "synchronization.h"

uint32_t hist_bins[NBINS] __attribute__((section(".l1_prio")));;

// uint32_t rand_lim(uint32_t limit, uint32_t seed) {
  // create well distributed random number from 0 to limit

//   uint32_t divisor = (uint32_t)(RAND_MAX/limit);
//     uint32_t retval;

//     do { 
//         retval = rand_r(&seed) / divisor;
//     } while (retval > limit);

//     return retval;
// }

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
    }
    srand(42);
  }
  // seed random number generator
  // Take care with concurrent access to std's rand function


  mempool_barrier(num_cores);
  uint32_t drawn_number = 0;

  uint32_t rand_state = core_id + 1;
  uint32_t bin_value = 0;
  mempool_barrier(num_cores);
  mempool_start_benchmark();
  
  if (core_id < 16){
    for (int i = 0; i<NDRAWS; i++){
      // rand_r is threadsafe in comparison to rand()
      // needs seed as pointer
      drawn_number =(uint32_t) rand_r(&rand_state) % NBINS;

      lr_sc_add((hist_bins + drawn_number), 1);               

      // do {
      //   bin_value = load_reserved((hist_bins + drawn_number)) + 1;
      // } while(store_conditional((hist_bins+drawn_number), bin_value));
    }
  }
  mempool_stop_benchmark();

  mempool_barrier(num_cores);
  if(core_id == 0) {
    uint32_t sum = 0;
    for (uint32_t i = 0; i<NBINS; i++){
      printf("BIN %3d Value %3d \n", i, *(hist_bins+i));
      sum += *(hist_bins+i);
    }
    printf("NBINS %3d NDRAWS %3d num_cores %3d \n",NBINS,NDRAWS,num_cores);
    printf("SUM %3d = %3d \n", sum, NDRAWS*num_cores);
  }
  // wait until all cores have finished
  mempool_barrier(num_cores);
  return 0;
}
