// Copyright 2021 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Author: Marc Gantenbein, Samuel Riedel, ETH Zurich

#ifndef __AMO_MUTEX_H__
#define __AMO_MUTEX_H__

#include <stdint.h>
#include <string.h>

#include "runtime.h"
#include "printf.h"

#define ACTIVE_CORES 2
#define BACKOFF 2

typedef uint32_t volatile amo_mutex_t;

//
// Expose the atomic swap instruction.
//
// @param   address     A pointer to an address on L2 memory to store the value.
// @param   value       Value to add to the specified memory location.
//
// @return  Value previously stored in memory.
//
static inline uint32_t amo_swap(void volatile *const address, uint32_t value) {
  uint32_t ret;
  asm volatile("" : : : "memory");
  asm volatile("amoswap.w  %0, %1, (%2)"
               : "=r"(ret)
               : "r"(value), "r"(address));
  asm volatile("" : : : "memory");
  return ret;
}

//
// Try to acquire a specified lock.
//
// @param   mutex       A pointer to the mutex location to be locked.
//
// @return  0 if the mutex was successfully locked.
//
static inline uint32_t amo_try_lock(amo_mutex_t *const mutex) {
  return amo_swap(mutex, 1);
}

//
// Blocking function to lock a mutex. This function only returns once the mutex
// has been locked. A backoff timer is used to prevent live-locks.
//
// @param   mutex       A pointer to the lock's memory location.
// @param   backoff       A pointer to the lock's memory location.
//
static inline void amo_lock_mutex(amo_mutex_t *mutex) {
  uint32_t backoff = BACKOFF * ACTIVE_CORES;
  while (amo_try_lock(mutex)) {
    mempool_wait(backoff);
  }
}

//
// Unlock the specified mutex.
//
// @param   mutex       A pointer to the mutex to be unlocked.
//
static inline void amo_unlock_mutex(amo_mutex_t *const mutex) {
  amo_swap(mutex, 0);
}

//
// Allocate and initialize a mutex in L2 memory.
//
// @return  A pointer to the allocated memory location to be used as a lock.
//          NULL if memory allocation failed.
//
amo_mutex_t *amo_allocate_mutex();

//
// Free the memory allocated for the specified mutex.
//
// @param   mutex       A pointer to the mutex to be freed.
//
void amo_free_mutex(amo_mutex_t *const mutex);

#endif // AMO_MUTEX_H
