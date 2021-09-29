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

#ifndef __BLOCKING_QUEUE_H__
#define __BLOCKING_QUEUE_H__

#include "alloc.h"
#include "amo_mutex.h"
#include "printf.h"

typedef struct node_t  node_t;
typedef struct queue_t queue_t;

struct node_t {
    int32_t value;
    node_t* next;
};

struct queue_t {
    node_t* head;
    node_t* tail;
    amo_mutex_t* head_lock;
    amo_mutex_t* tail_lock;
};

//
// Allocates memory for queue object and sets initial values.
//
// @return  A pointer to the created queue object. NULL on failure.
//
queue_t *initialize_queue();

//
// Frees all memory used by the queue including all nodes inside it.
//
// @param   queue       A pointer to the queue to be freed.
//
// @return  Zero on success.
//
int32_t uninitialize_queue(queue_t *queue);

//
// Add a new value to an existing queue.
//
// @param   queue       A pointer to the queue to add the value to.
// @param   value       Value to be added to the queue.
//
// @return  Zero on success, -1 if allocation of new node failed.
//
int32_t enqueue(queue_t *const queue, const int32_t value);

//
// Read head of the queue and remove node.
//
// @param   queue       A pointer to the queue to read.
//
// @return  Value of queue. -1 if the queue was empty.
//
int32_t dequeue(queue_t *const queue);

#endif
