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

#define QUEUE 1

#include "non_blocking_queue.h"

#define NUMBER_OF_NODES 16

non_blocking_queue_t *queue;
non_blocking_node_t* nodes[NUMBER_OF_NODES];

int main() {
  uint32_t core_id = mempool_get_core_id();
  uint32_t num_cores = mempool_get_core_count();
  // Initialize synchronization variables
  mempool_barrier_init(core_id);

  // initializes the heap allocator
  mempool_init(core_id, num_cores);

  if (core_id == 0) {
    printf("queue initializing\n");
    queue = initialize_queue();
    if (queue == NULL) {
      printf("queue initialization failed\n");
      return 1;
    }
  }

  // alloc space for nodes with values from 1 to 16
  if(core_id == 0){
    for (int i; i<NUMBER_OF_NODES; i++){
      *(nodes+i) = domain_malloc(get_alloc_l1(), sizeof(non_blocking_node_t));
      if (*(nodes+i) == NULL) return -1;
      nodes[i]->next = NULL;
      nodes[i]->value = i;
    }
  }

  mempool_barrier(num_cores);
  if (core_id == 0) {
    enqueue(queue,nodes[0]);
    enqueue(queue,nodes[1]);
    enqueue(queue,nodes[2]);
    enqueue(queue,nodes[3]);
    enqueue(queue,nodes[4]);
    enqueue(queue,nodes[5]);
    enqueue(queue,nodes[6]);
    enqueue(queue,nodes[7]);
    printf("dequeue %3d \n", dequeue(queue));
    printf("dequeue %3d \n", dequeue(queue));
    printf("dequeue %3d \n", dequeue(queue));
    printf("dequeue %3d \n", dequeue(queue));

  } else if (core_id == 1) {
    enqueue(queue,nodes[8]);
    enqueue(queue,nodes[9]);
    enqueue(queue,nodes[10]);
    enqueue(queue,nodes[11]);
    printf("dequeue %3d \n", dequeue(queue));
    printf("dequeue %3d \n", dequeue(queue));
    printf("dequeue %3d \n", dequeue(queue));
    printf("dequeue %3d \n", dequeue(queue));
    enqueue(queue,nodes[12]);
    enqueue(queue,nodes[13]);
    enqueue(queue,nodes[14]);
    enqueue(queue,nodes[15]);
  }

  mempool_barrier(num_cores);
  if (core_id == 1) {
    printf("dequeue %3d \n", dequeue(queue));
    printf("dequeue %3d \n", dequeue(queue));
    printf("dequeue %3d \n", dequeue(queue));
    printf("dequeue %3d \n", dequeue(queue));
    printf("dequeue %3d \n", dequeue(queue));
    printf("dequeue %3d \n", dequeue(queue));
    printf("dequeue %3d \n", dequeue(queue));
    printf("dequeue %3d \n", dequeue(queue));
  }

  // wait until all cores have finished
  mempool_barrier(num_cores);

  return 0;
}
