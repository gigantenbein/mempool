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
  int value;
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
  non_blocking_queue_t *const queue = (non_blocking_queue_t *)domain_malloc(get_alloc_l1(), 4 * 4);
  non_blocking_node_t *const node = domain_malloc(get_alloc_l1(), sizeof(non_blocking_node_t));
  // Check if memory allocations were successful
  if (queue == NULL || node == NULL) return NULL;
  // Set initial values
  node->value = -1;
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

void print_queue(non_blocking_queue_t* const queue) {
  printf("Head %3d \n", queue->head->value);
  printf("Tail %3d \n", queue->tail->value);

  non_blocking_node_t volatile* current_node;
  current_node = queue->head->next;
  printf("Node %3d\n",current_node->value);
  if (current_node->next == current_node->next->next){
    printf("Node %3d\n",current_node->next->value);
    printf("Node %3d\n",current_node->next->next->value);
  }

  while(current_node != NULL){
    printf("Node %3d\n",current_node->value);
    current_node = current_node->next;
  }

}
//
// Add a new value to an existing queue.
//
// @param   queue       A pointer to the queue to add the value to.
// @param   value       Value to be added to the queue.
//
// @return  Zero on success, -1 if allocation of new node failed.
//
int enqueue(non_blocking_queue_t* const queue, non_blocking_node_t* new_node)
{
  non_blocking_node_t volatile* tail;
  non_blocking_node_t volatile* next;

  // Add node to queue
  while(1)
    {
      tail = queue->tail;
      next = (non_blocking_node_t*) load_reserved(&tail->next);
      // Check if next is really the last node
      if (tail != queue->tail){
        store_conditional(&tail->next, (unsigned) next);
        continue;
      }
      if (next == NULL)
        {
          if (!store_conditional(&tail->next, (unsigned) new_node))
            {
              // node successfully inserted
              break;
            }
          else
            {
              // Other core broke reservation
              continue;
            }
        }
      // Tail did not point to the last node --> update tail pointer
      else
        {
          store_conditional(&tail->next, (unsigned) next);

          tail = (non_blocking_node_t*) load_reserved(&queue->tail);
          next = tail->next;

          if (next != NULL) {
            store_conditional(&queue->tail, (unsigned) next);
          }
          else{
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
//
// @param   queue       A pointer to the queue to read.
//
// @return  Value of queue. -1 if the queue was empty.
//
int dequeue(non_blocking_queue_t* const queue)
{
  // Variables used as buffer
  int value = -1;
  non_blocking_node_t volatile* head;
  non_blocking_node_t volatile* tail;
  non_blocking_node_t volatile* next;
  while (1)
    {
      head = (non_blocking_node_t*) load_reserved(&queue->head);
      tail = queue->tail;
      __asm__ __volatile__ ("" : : : "memory");
      next = head->next;
      if (head != queue->head) continue; // CHECK Necessary?
      if (head == tail)
        {
          write_csr(trace,1);
          // Queue empty or tail falling behind
          if (next == NULL)
            {
              return -1;
            }
          // Help updating tail
          tail = (non_blocking_node_t*) load_reserved(&queue->tail);
          next = tail->next;
          if (next != NULL){
            write_csr(trace,5);

            if(!store_conditional(&queue->tail, (uint32_t) next)){
              return -1;
            }
            else{
              write_csr(trace,6);
            }
          }
        }
      else
        {
          // Queue is not empty
          value = next->value;
          write_csr(trace,2);
          if (!store_conditional(&queue->head, (uint32_t) next))
            {
                                  write_csr(trace,3);
              break;
            }
          else
            {                    write_csr(trace,4);
              continue;
            }
        }
    }
  // Free the nodes memory
  simple_free((void*) head);
  return value;
}

#endif
