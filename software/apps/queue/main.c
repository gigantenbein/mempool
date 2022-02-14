// Copyright 2021 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Author: Marc Gantenbein, ETH Zurich

#include <stdint.h>
#include <string.h>

#include "encoding.h"
#include "runtime.h"
#include "synchronization.h"

#include "queue.h"

#define NUMBER_OF_NODES 256

queue_t queue __attribute__((section(".l1_prio")));
node_t nodes[NUMBER_OF_NODES] __attribute__((section(".l1_prio")));
node_t dummy_node __attribute__((section(".l1_prio")));

int main() {
  uint32_t core_id = mempool_get_core_id();
  uint32_t num_cores = mempool_get_core_count();
  // Initialize synchronization variables
  mempool_barrier_init(core_id);

  // initializes the heap allocator
  mempool_init(core_id, num_cores);

  // statically allocate queue
  if (core_id == 0) {
    dummy_node.next = NULL;
    dummy_node.value = 0;
    queue.head = &dummy_node;
    queue.tail = &dummy_node;

#if MUTEX == 1
    queue.head_lock = amo_allocate_mutex();
    queue.tail_lock = amo_allocate_mutex();
#endif
  }

  // initialize nodes to enqueue
  if(core_id == 0) {
    for (uint32_t i = 0; i<NUMBER_OF_NODES; i++){
      nodes[i].next = NULL;
      nodes[i].value = i;
    }
  }
  node_t* temp;

  mempool_barrier(num_cores);
  mempool_timer_t start_time = mempool_get_timer();

  if (core_id < MATRIXCORES) {
    enqueue(&queue, (nodes+core_id));
    for (int i = 0; i < NUMCYCLES; i++) {
#if BACKOFF != 0
      mempool_wait(BACKOFF);
#endif
      temp = dequeue(&queue);
#if BACKOFF != 0
      mempool_wait(BACKOFF);
#endif
      enqueue(&queue, temp);
    }
#if BACKOFF != 0
      mempool_wait(BACKOFF);
#endif
    // temp = cas_dequeue(&queue);
  }

  mempool_timer_t stop_time = mempool_get_timer();
  mempool_barrier(num_cores);

  // dump times
  if (core_id < MATRIXCORES) {
    uint32_t time_diff = stop_time - start_time;
    write_csr(time, time_diff);
  }

  mempool_barrier(num_cores);

  return 0;
}
