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

// Author: Marc Gantenbein, Samuel Riedel ETH Zurich

// Description: Different queue implementations with blocking and non blocking
//              variants

#ifndef __QUEUE_H__
#define __QUEUE_H__

#include "alloc.h"
#include "amo_mutex.h"

#if MUTEX == 5 || MUTEX == 6
#include "lrwait_mutex.h"
#else
#include "lr_sc_mutex.h"
#endif

typedef struct node_t  node_t;
typedef struct queue_t queue_t;

struct node_t {
  uint32_t value;
  node_t* volatile next;
};

struct queue_t {
  node_t* volatile head;
  node_t* volatile tail;

  // not used for non_blocking_queue
  amo_mutex_t *head_lock;
  amo_mutex_t *tail_lock;
};

#if MUTEX == 1
int32_t amo_enqueue(queue_t* queue, node_t* volatile new_node) {
  // Make sure node does not point anywhere
  new_node->next = NULL;
  // Exclusive access: Add node to queue
  amo_lock_mutex(queue->tail_lock, BACKOFF);
  queue->tail->next = new_node;
  queue->tail       = new_node;
  amo_unlock_mutex(queue->tail_lock);
  return 0;
}

node_t volatile* amo_dequeue(queue_t* queue) {
  // Get lock to access head of queue
  amo_lock_mutex(queue->head_lock, BACKOFF);
  // Read head node
  node_t *node = queue->head;
  node_t *new_head = node->next;
  if (new_head == NULL) {
    // Queue is empty
    amo_unlock_mutex(queue->head_lock);
    return NULL;
  } else {
    // Read nodes value and update head
    int32_t value = new_head->value;
    queue->head = new_head;
    // Release queue lock
    amo_unlock_mutex(queue->head_lock);

    // Return node
    node->value = value;
    node->next = NULL;
    return node;
  }
}
#endif

//
// Add a new value to an existing queue.
#if MUTEX == 6
int32_t lrwait_enqueue(queue_t* queue, node_t* volatile new_node) {
  node_t volatile* tail;
  node_t volatile* next;

  tail = load_reserved_wait(&queue->tail);
  tail->next = new_node;

  return store_conditional_wait(&queue->tail, new_node);
}

node_t volatile* lrwait_dequeue(queue_t* queue) {
  volatile uint32_t value = 0;
  node_t volatile* head;
  node_t volatile* tail;
  node_t volatile* next;

  tail = queue->tail;
  head = (node_t*) load_reserved_wait(&queue->head);
  next = head->next;

  if (next == NULL) {
    store_conditional_wait(&queue->head, head);
    return NULL;
  }
  value = next->value;
  store_conditional_wait(&queue->head, next);

  head->next = NULL;
  head->value = value;
  return head;
}
#endif

// CAS version taken from Michael, Maged M. and Scott, Michael L.
// Simple, Fast, and Practical Non-Blocking and Blocking Concurrent Queue Algorithms

//
// Add a new value to an existing queue.
int32_t cas_enqueue(queue_t* queue, node_t* volatile new_node) {
  node_t volatile* tail;
  node_t volatile* next;

#if MUTEX == 6
  load_reserved_wait(&new_node->next);
  store_conditional_wait(&new_node->next, NULL);
#elif MUTEX == 0
  load_reserved(&new_node->next);
  store_conditional(&new_node->next, NULL);
#else
  new_node->next = NULL;
#endif


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
node_t volatile* cas_dequeue(queue_t* queue)
{
  // Variables used as buffer
  volatile uint32_t value = 0;
  node_t volatile* head;
  node_t volatile* tail;
  node_t volatile* next;
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
  __asm__ __volatile__ ("" : : : "memory");

  head->value = value;
  return head;
}

#if MUTEX != 6
// Original LR/SC lock free dequeing algorithm from Samuel Riedel
// Adapted from the CAS lock free queue lock algorithm
uint32_t lock_free_lrsc_enqueue(queue_t* const queue, node_t* new_node)
{
  node_t volatile* tail;
  node_t volatile* next;

#if MUTEX == 6
  load_reserved_wait(&new_node->next);
  store_conditional_wait(&new_node->next, NULL);
#elif MUTEX == 0
  load_reserved(&new_node->next);
  store_conditional(&new_node->next, NULL);
#else
  new_node->next = NULL;
#endif

  // Add node to queue
  while(1) {
    tail = queue->tail;
    next = (node_t*) load_reserved(&tail->next);
    // Check if next is really the last node
    if (tail != queue->tail) {
      store_conditional(&tail->next, (uint32_t) tail->next);
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
      store_conditional(&tail->next, (uint32_t) tail->next);

      tail = (node_t*) load_reserved(&queue->tail);
      next = tail->next;

      if (next != NULL) {
        store_conditional(&queue->tail, (uint32_t) next);
      }
      else{
        store_conditional(&queue->tail, (uint32_t) queue->tail);
      }
    }
  }

  // Update the tail node
  tail = (node_t*) load_reserved(&queue->tail);
  next = tail->next;
  // give up reservation before leaving
  if (next != NULL) {
    store_conditional(&queue->tail, (uint32_t) next);
  }
  else{
    store_conditional(&queue->tail, (uint32_t) queue->tail);
  }

  return 0;
}

// Original LR/SC lock free dequeing algorithm from Samuel Riedel
// Adapted from the CAS lock free queue lock algorithm
node_t* lock_free_lrsc_dequeue(queue_t* const queue)
{
  // Variables used as buffer
  node_t volatile* head;
  node_t volatile* tail;
  node_t volatile* next;
  volatile uint32_t value = 0;
  while (1) {
    head = (node_t*) load_reserved(&queue->head);
    tail = queue->tail;
    next = head->next;
    if (head != queue->head) {
      store_conditional(&queue->head, queue->head);
      continue;
    }
    if (head == tail) {
      // Queue empty or tail falling behind
      if (next == NULL) {
        return NULL;
      }
      // give up reservation from before
      store_conditional(&queue->head, queue->head);

      // Help updating tail
      tail = (node_t*) load_reserved(&queue->tail);
      next = tail->next;
      if (next != NULL) {
        if(!store_conditional(&queue->tail, (uint32_t) next)) {
          return NULL;
        }
      } else {
        store_conditional(&queue->tail, (uint32_t) queue->tail);
      }
    }
    else {
      value = next->value;
       if (!store_conditional(&queue->head, (uint32_t) next)) {
        break;
      }
      else {
        continue;
      }
    }
  }
  __asm__ __volatile__ ("" : : : "memory");
  head->value = value;
  return head;
}
#endif

int32_t enqueue(queue_t* queue, node_t* volatile new_node) {
#if MUTEX == 1
  return amo_enqueue(queue, new_node);
#elif MUTEX == 6
  return lrwait_enqueue(queue, new_node);
// #elif MUTEX == 0
//   return lock_free_lrsc_enqueue(queue, new_node);
#else
  return cas_enqueue(queue, new_node);
#endif
}

node_t volatile* dequeue(queue_t* queue) {
#if MUTEX == 1
  return amo_dequeue(queue);
#elif MUTEX == 6
  return lrwait_dequeue(queue);
// #elif MUTEX == 0
//   return lock_free_lrsc_dequeue(queue);
#else
  return cas_dequeue(queue);
#endif
}

#endif
