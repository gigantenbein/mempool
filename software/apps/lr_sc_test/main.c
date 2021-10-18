// Copyright 2021 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Author: Marc Gantenbein, ETH Zurich

#include <stdint.h>
#include <string.h>

#include "encoding.h"
#include "printf.h"
#include "runtime.h"
#include "synchronization.h"

#include "lr_sc_mutex.h"

#define NUMBER_OF_NODES 16

uint32_t dummy __attribute__((section(".l1_prio")));
uint32_t dummy2 __attribute__((section(".l1_prio")));

int main() {
  uint32_t core_id = mempool_get_core_id();
  uint32_t num_cores = mempool_get_core_count();
  // Initialize synchronization variables
  mempool_barrier_init(core_id);

  // initializes the heap allocator
  mempool_init(core_id, num_cores);

  // if (core_id == 0){
  //   dummy = 0;
  //   dummy2 = 0;
  // }

  // mempool_barrier(num_cores);

  // ===================================================
  // Tests included in ISA tests as well
  // ===================================================

  // check that sc without reservation fails

  // if(store_conditional(&dummy, 5) == 0){
  //   return -1;
  // }

  // // check that sc did not commit into memory
  // if(dummy != 0){
  //   printf("dummy %3d \n", dummy);
  //   return -1;
  // }

  // // make sure that sc with the wrong reservation fails.
  // value = load_reserved(&dummy);

  // if(store_conditional(&dummy + 8096, 5) == 0){
  //   printf("fail\n");
  //   return -1;
  // }

  // mempool_barrier(num_cores);

  /* // Test lr_sc with single retrying */
  /* if (core_id == 1){ */
  /*   load_reserved(&dummy); */
  /* } */

  /* mempool_barrier(num_cores); */
  /* if(core_id == 0){ */
  /*   load_reserved(&dummy); */
  /*   printf("Core %3d has value %3d\n", core_id, store_conditional(&dummy, value + core_id)); */
  /* } */

  /* mempool_barrier(num_cores); */
  /* if(core_id == 1){ */
  /*   printf("Core %3d has value %3d\n", core_id, store_conditional(&dummy, value + core_id)); */
  /* } */


  /* mempool_barrier(num_cores); */
  /* if (core_id == 4){ */
  /*   if( store_conditional(&dummy, value + core_id)){ */
  /*     printf("Core %3d failed store_conditional.\n", core_id); */
  /*     load_reserved(&dummy); */
  /*     printf("Core %3d sc returned %3d.\n", core_id, store_conditional(&dummy, 0)); */
  /*   } */
  /*   else{ */
  /*     return -1; */
  /*   } */
  /* } */
  // ===================================================

  // mempool_barrier(num_cores);

  if(core_id < num_cores){
    do{
    }while(store_conditional(&dummy, load_reserved(&dummy) + core_id));
  }
  mempool_barrier(num_cores);
  if (core_id == 0){
    printf("Result is %3d.\n", dummy);
  }
  mempool_barrier(num_cores);

  // if (core_id != 0) {
  //   mempool_wfi();
  // }

  // dummy = core_id;
  // wake_up(core_id + 1);

  // // wait until all cores have finished
  // mempool_barrier(num_cores);
  return 0;

}
