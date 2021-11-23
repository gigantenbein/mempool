// Copyright 2021 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Author: Marc Gantenbein, ETH Zurich

#ifndef __MCS_MUTEX_H__
#define __MCS_MUTEX_H__

#include "alloc.h"
#include "amo_mutex.h"
#include "lr_sc_mutex.h"
#include "runtime.h"

typedef struct mcs_lock_t mcs_lock_t;

struct mcs_lock_t {
  struct mcs_lock_t *next;
  uint32_t locked; // 1 if lock acquired
};

// return a pointer to the initialized lock
mcs_lock_t* initialize_mcs_lock(){
  // Allocate memory
  mcs_lock_t *const lock = simple_malloc(sizeof(mcs_lock_t));
  // Check if memory allocations were successful
  if (lock == NULL) return NULL;
  // Set initial values
  lock->next = NULL;
  lock->locked = 0;

  return lock;
}

int32_t uninitialize_mcs_lock(mcs_lock_t *const lock){
  simple_free(lock);
  return 0;
}

int32_t lock_mcs(mcs_lock_t *const lock, mcs_lock_t  *const node){
  // check lock and set yourself as tail
  // write_csr(88, lock->next);
  // write_csr(86, node);
  mcs_lock_t* next = (mcs_lock_t*) amo_swap(&(lock->next), (uint32_t) node);
  write_csr(89, lock->next);
  // write_csr(87, next);

  if (next != NULL){
    // set yourself as locked
    node->locked = 1;

    // append yourself as next node of previous
    amo_swap(&(next->next), (uint32_t) node);
    write_csr(88, lock->next);
    write_csr(87, next->next);

    // spin until your node is freed
    while (amo_swap(&node->locked,1)){

    }
  }

  return 0;
}

int32_t unlock_mcs(mcs_lock_t *const lock, mcs_lock_t *const node){
  if (node->next == NULL) {
    mcs_lock_t* tail_node = load_reserved(&(lock->next));
    write_csr(78, 1);
    write_csr(78, tail_node);
    // is node the only node in queue
    if (tail_node == node){
      store_conditional(&(lock->next), NULL);
      return 0;
    } else {
      store_conditional(&(lock->next), tail_node);
    }
    write_csr(78, 2);
    // someone broke the queue, wait here
    while (node->next == NULL);
  }
  write_csr(78, 0);
  // free your successor
  node->next->locked = 0;
  return 0;
}

#endif // MCS_MUTEX_H
