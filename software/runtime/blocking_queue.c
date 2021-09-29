// Copyright 2021 ETH Zurich and University of Bologna.
//
// SPDX-License-Identifier: Apache-2.0
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//    http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// Author: Samuel Riedel, Marc Gantenbein ETH Zurich

#include "blocking_queue.h"

queue_t *initialize_queue() {

  // Allocate memory
  queue_t *const queue = (queue_t *)domain_malloc(get_alloc_l1(), 4 * 4);
  node_t *const node = domain_malloc(get_alloc_l1(), sizeof(node_t));
  queue->head_lock = amo_allocate_mutex();
  queue->tail_lock = amo_allocate_mutex();
  // Check if memory allocations were successful
  if (queue == NULL || node == NULL)
    return NULL;
  if (queue->head_lock == NULL || queue->tail_lock == NULL)
    return NULL;
  // Set initial values
  node->value = -1;
  node->next = NULL;
  queue->head = node;
  queue->tail = node;

  return queue;
}

int32_t uninitialize_queue(queue_t *queue) {
  // Acquire all locks
  amo_lock_mutex(queue->head_lock);
  amo_lock_mutex(queue->tail_lock);

  node_t *node_current = queue->head;
  // Free all nodes
  while (node_current->next != NULL) {
    node_t *node_next = node_current->next;
    simple_free(node_current);
    node_current = node_next;
  }
  simple_free(node_current);

  // Free queue
  amo_free_mutex(queue->head_lock);
  amo_free_mutex(queue->tail_lock);
  simple_free(queue);

  return 0;
}

int32_t enqueue(queue_t *const queue, const int32_t value) {
  // Allocate new node
  node_t *const node = simple_malloc(sizeof(node_t));
  if (node == NULL)
    return -1;
  // Set values
  node->value = value;
  node->next = NULL;
  // Exclusive access: Add node to queue
  amo_lock_mutex(queue->tail_lock);
  queue->tail->next = node;
  queue->tail = node;
  amo_unlock_mutex(queue->tail_lock);
  return 0;
}

int32_t dequeue(queue_t *const queue) {
  // Get lock to access head of queue
  amo_lock_mutex(queue->head_lock);
  // Read head node
  node_t *node = queue->head;
  node_t *new_head = node->next;
  if (new_head == NULL) {
    // Queue is empty
    amo_unlock_mutex(queue->head_lock);
    return -1;
  } else {
    // Read nodes value and update head
    int32_t value = new_head->value;
    queue->head = new_head;
    // Release queue lock
    amo_unlock_mutex(queue->head_lock);
    // Free node
    simple_free(node);
    return value;
  }
}
