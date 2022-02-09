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

#include "non_blocking_queue.h"

#define NUMBER_OF_NODES 256

non_blocking_queue_t queue __attribute__((section(".l1_prio")));
non_blocking_node_t nodes[NUMBER_OF_NODES] __attribute__((section(".l1_prio")));
non_blocking_node_t dummy_node __attribute__((section(".l1_prio")));

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
  }

  // initialize nodes to enqueue
  if(core_id == 0){
    for (uint32_t i = 0; i<NUMBER_OF_NODES; i++){
      nodes[i].next = NULL;
      nodes[i].value = i;
    }
  }
  non_blocking_node_t* temp;

  mempool_barrier(num_cores);

  if (core_id < NUMBER_OF_NODES) {
    cas_enqueue(&queue, (nodes+core_id));
    temp = cas_dequeue(&queue);
    for (int i = 0; i < 2; i++) {
      cas_enqueue(&queue, temp);
      write_csr(93, temp->value);
      temp = cas_dequeue(&queue);
    }
  }

  mempool_barrier(num_cores);

  return 0;
}
