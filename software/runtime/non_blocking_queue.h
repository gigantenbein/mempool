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

#ifndef __NON_BLOCKING_QUEUE_LRSC_H__
#define __NON_BLOCKING_QUEUE_LRSC_H__

#include "alloc.h"
#include "lr_sc_mutex.h"


//
// Node & queue type
//
typedef struct non_blocking_node_t     non_blocking_node_t;
typedef struct non_blocking_queue_t    non_blocking_queue_t;

struct non_blocking_node_t {
  uint32_t value;
  non_blocking_node_t* volatile next;
};

struct non_blocking_queue_t {
  non_blocking_node_t* volatile head;
  non_blocking_node_t* volatile tail;
};

//
// Allocates memory for queue object and sets initial values.
//
// @return  A pointer to the created queue object. NULL on failure.
//
non_blocking_queue_t* initialize_queue()
{

  // Allocate memory
  non_blocking_queue_t* const queue = (non_blocking_queue_t *)domain_malloc(get_alloc_l1(), sizeof(non_blocking_queue_t));
  non_blocking_node_t* node = (non_blocking_node_t *)domain_malloc(get_alloc_l1(), sizeof(non_blocking_node_t));
  // Check if memory allocations were successful
  if (queue == NULL || node == NULL) return NULL;
  // Set initial values
  node->value = 0;
  node->next  = NULL;
  queue->head = node;
  queue->tail = node;

  return queue;
}

// Frees all memory used by the queue including all nodes inside it.
//
// @param   queue       A pointer to the queue to be freed.
//
// @return  Zero on success.
//
int uninitialize_queue(non_blocking_queue_t* queue)
{
  non_blocking_node_t* node_current = queue->head;
  // Free all nodes
  while (node_current->next != NULL)
    {
      non_blocking_node_t* node_next = (non_blocking_node_t*) node_current->next;
      simple_free(node_current);
      node_current = node_next;
    }
  simple_free(node_current);

  // Free queue
  simple_free(queue);

  return 0;
}

//
// Add a new value to an existing queue.
int32_t enqueue(non_blocking_queue_t* const queue, non_blocking_node_t volatile* new_node) {
  non_blocking_node_t volatile* tail;
  non_blocking_node_t volatile* next;
  new_node->next = NULL;

  // Add node to queue
  while(1) {
    tail = queue->tail;
    next = (non_blocking_node_t*) load_reserved(&tail->next);

    // Check if next is really the last node
    if (tail != queue->tail) {
      store_conditional(&tail->next, (uint32_t) next);
      continue;
    }
    if (next == NULL) {
      if (!store_conditional(&tail->next, (uint32_t) new_node)) {
        // node successfully inserted
        break;
      }
      else {
        // Other core broke reservation
        continue;
      }
    }
    // Tail did not point to the last node --> update tail pointer
    else {
      store_conditional(&tail->next, (uint32_t) next);

      tail = (non_blocking_node_t*) load_reserved(&queue->tail);
      next = tail->next;

      if (next != NULL) {
        store_conditional(&queue->tail, (uint32_t) next);
      }
      else {
        store_conditional(&queue->tail, (uint32_t) tail);
      }
    }
  }

  // Update the tail node
  tail = (non_blocking_node_t*) load_reserved(&queue->tail);
  next = tail->next;
  // give up reservation before leaving
  if (next != NULL) {
    store_conditional(&queue->tail, (unsigned) next);
  }
  else{
    store_conditional(&queue->tail, (uint32_t) tail);
  }

  return 0;
}

//
// Read head of the queue and remove node.
non_blocking_node_t volatile* dequeue(non_blocking_queue_t* const queue)
{
  // Variables used as buffer
  volatile uint32_t value = -1;
  non_blocking_node_t volatile* head;
  non_blocking_node_t volatile* tail;
  non_blocking_node_t volatile* next;
  while (1) {
    head = (non_blocking_node_t*) load_reserved(&queue->head);
    tail = queue->tail;
    __asm__ __volatile__ ("" : : : "memory");
    next = head->next;
    if (head != queue->head) {
      // write_csr(95,888888);
      store_conditional(&queue->head, (uint32_t) head);
      continue; // CHECK Necessary?
    }
    if (head == tail) {
      store_conditional(&queue->head, (uint32_t) head);
      // Queue empty or tail falling behind
      if (next == NULL) {
        return NULL;
      }
      // Help updating tail
      tail = (non_blocking_node_t*) load_reserved(&queue->tail);
      next = tail->next;
      if (next != NULL){
        if(!store_conditional(&queue->tail, (uint32_t) next)){
          return NULL;
        }
        else{
          // write_csr(trace,6);
        }
      }
      store_conditional(&queue->tail, (uint32_t) tail);
    }
    else {
      // Queue is not empty
      // value = next->value;

      if (!store_conditional(&queue->head, (uint32_t) next)) {
        value = next->value;
        break;
      }
      else {
        continue;
      }
    }
  }
  // Free the nodes memory
  __asm__ __volatile__ ("" : : : "memory");
  head->next = NULL;
  head->value = value;
  return head;
}

// CAS version taken from Michael, Maged M. and Scott, Michael L.
// Simple, Fast, and Practical Non-Blocking and Blocking Concurrent Queue Algorithms

//
// Add a new value to an existing queue.
int32_t cas_enqueue(non_blocking_queue_t* queue, non_blocking_node_t* volatile new_node) {
  non_blocking_node_t volatile* tail;
  non_blocking_node_t volatile* next;
  new_node->next = NULL;

  // Add node to queue
  while(1) {
    tail = queue->tail;
    next = tail->next;

    // Check if next is really the last node
    if (tail == queue->tail) {
      if (next == NULL) {
        if (compare_and_swap(&tail->next, (uint32_t)next, (uint32_t)new_node) == 0) {
          break;
        }
      } else {
        compare_and_swap(&queue->tail, (uint32_t)tail, (uint32_t)next);
      }
    }
  }

  compare_and_swap(&queue->tail, (uint32_t)tail, (uint32_t)new_node);
  return 0;
}

//
// Read head of the queue and remove node.
non_blocking_node_t volatile* cas_dequeue(non_blocking_queue_t* queue)
{
  // Variables used as buffer
  volatile uint32_t value = 0;
  non_blocking_node_t volatile* head;
  non_blocking_node_t volatile* tail;
  non_blocking_node_t volatile* next;
  while (1) {
    head = queue->head;
    tail = queue->tail;
    next = head->next;
    if (head == queue->head) {
      if (head == tail) {
        if (next == NULL) {
          return NULL;
        }
        compare_and_swap(&queue->tail, (uint32_t)tail, (uint32_t)next);
      } else {
        value = next->value;
        if(compare_and_swap(&queue->head, (uint32_t)head, (uint32_t)next) == 0) {
          break;
        }
      }
    }
  }
  // Free the nodes memory
  // simple_free((void*) head);
  __asm__ __volatile__ ("" : : : "memory");
  head->next = NULL;
  head->value = value;
  return head;
}

#endif
