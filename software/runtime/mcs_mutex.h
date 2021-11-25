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
  node->next = NULL;
  node->locked = 0;

  mcs_lock_t* next = (mcs_lock_t*) amo_swap(&(lock->next), (uint32_t) node);

  if (next != NULL){
    // set yourself as locked
    node->locked = 1;

    // append yourself as next node of previous
    amo_swap(&(next->next), (uint32_t) node);

    // spin until your node is freed
    while (amo_swap(&node->locked,1)){
      mempool_wait(1);
    }
  }

  return 0;
}

int32_t unlock_mcs(mcs_lock_t *const lock, mcs_lock_t *const node){
  mcs_lock_t* old_tail;
  mcs_lock_t* usurper;
  if (node->next == NULL) {
    // node has no successor
    old_tail = amo_swap(&(lock->next), NULL);
    if (old_tail == node) {
      // node really had no successor
      return 0;
    }
    usurper = amo_swap(&(lock->next), old_tail);
    while(node->next == NULL) {
      mempool_wait(1);
    }
    if (usurper != NULL) {
      // somebody got into the queue ahead of our victims
      usurper->next = node->next;
    } else {
      node->next->locked = 0;
    }
  } else {
    node->next->locked = 0;
  }
  return 0;
}

// LRWAIT SOFTWARE

// return a pointer to the initialized lock
mcs_lock_t* initialize_lrwait_mcs(uint32_t core_id){
  // Allocate memory
  mcs_lock_t *const lock = simple_malloc(sizeof(mcs_lock_t));
  // Check if memory allocations were successful
  if (lock == NULL) return NULL;
  // Set initial values
  lock->next = NULL;
  lock->locked = core_id;

  return lock;
}


int32_t lrwait_mcs(mcs_lock_t *const lock, mcs_lock_t  *const node){
  // check lock and set yourself as tail
  node->next = NULL;

  mcs_lock_t* next = (mcs_lock_t*) amo_swap(&(lock->next), (uint32_t) node);
  if (next != NULL){
    // append yourself as next node of previous
    amo_swap(&(next->next), (uint32_t) node);

    // spin until your node is freed
    mempool_wfi();
  }

  return 0;
}

int32_t lrwait_wakeup_mcs(mcs_lock_t *const lock, mcs_lock_t *const node){
  mcs_lock_t* old_tail;
  mcs_lock_t* usurper;
  if (node->next == NULL) {
    // node has no successor
    old_tail = amo_swap(&(lock->next), NULL);
    if (old_tail == node) {
      // node really had no successor
      return 0;
    }
    usurper = amo_swap(&(lock->next), old_tail);
    while(node->next == NULL) {
      mempool_wait(1);
    }
    if (usurper != NULL) {
      // somebody got into the queue ahead of our victims
      usurper->next = node->next;
    } else {
      wake_up(node->next->locked);
    }
  } else {
    wake_up(node->next->locked);
  }
  return 0;
}

#endif // MCS_MUTEX_H
