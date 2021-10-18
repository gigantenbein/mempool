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

#define NBINS 20
#define NDRAWS 100

uint32_t hist_bins[NBINS];

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

  }
  // seed random number generator
  // Take care with concurrent access to std's rand function
  srand(core_id);

  mempool_barrier(num_cores);
  uint32_t drawn_number = 0;
  uint32_t bin_value = 0;
  for (int i = 0; i<NDRAWS; i++){
    drawn_number = (uint32_t) (rand() % NBINS);
    printf("int %3d \n", drawn_number);
    do {
      bin_value = load_reserved((hist_bins + drawn_number)) + 1;
    } while(store_conditional((hist_bins+drawn_number), bin_value));
  }

  mempool_barrier(num_cores);
  if(core_id == 0) {
    for (int i = 0; i<NBINS; i++){
      printf("BIN %3d Value %3d \n", i, *(hist_bins+i));
    }
  }
  // wait until all cores have finished
  mempool_barrier(num_cores);
  return 0;
}
