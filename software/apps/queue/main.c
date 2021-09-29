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
#include "blocking_queue.h"

#define NUMBER_OF_NODES 16

queue_t *queue;

int main() {
    uint32_t core_id = mempool_get_core_id();
    uint32_t num_cores = mempool_get_core_count();
    // Initialize synchronization variables
    mempool_barrier_init(core_id);

    // initializes the heap allocator
    mempool_init(core_id, num_cores);

    if (core_id == 0) {
      queue = initialize_queue();
      if (queue == NULL) {
        printf("queue initialization failed\n");
        return 1;
      }
    }

    mempool_barrier(num_cores);
    if (core_id == 0) {
      enqueue(queue, 1);
      enqueue(queue, 2);
      enqueue(queue, 3);
      enqueue(queue, 4);
      enqueue(queue, 5);
    }

    else if (core_id == 1) {
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
