// Copyright 2021 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Author: Marc Gantenbein, Samuel Riedel, ETH Zurich

#ifndef __LR_SC_H__
#define __LR_SC_H__

#include <stdint.h>
#include <string.h>

#include "runtime.h"

/**
 * Mutex type.
 */
typedef volatile uint32_t lr_sc_mutex_t;

/**
 * Expose the load-reserved instruction. Loads a word from a specified
 * address and creates a reservation.
 *
 * @param   address     Pointer to the address to create reservation and load
 *                      the value from.
 *
 * @return  Value currently stored in memory.
 */
static inline uint32_t load_reserved(volatile void* const address)
{
  uint32_t value;
  __asm__ __volatile__ ("" : : : "memory");
  asm volatile("lr.w %0, (%1)" : "=r"(value) : "r"(address));
  __asm__ __volatile__ ("" : : : "memory");
  return value;
}

/**
 * Expose the store-conditional instruction. Only stores a value if a previously
 * made reservation has not been broken by another core.
 *
 * @param   address     A pointer to an address on L2 memory to store the value.
 * @param   value       Value to store.
 *
 * @return  0: Store was successful, the reservation was still valid.
 *          1: Reservation was broken, no store happened.
 *          2: Slave error. The slave does not support atomic operations.
 *          3: The address does not exist.
 */
static inline int32_t store_conditional(volatile void* const address, uint32_t const value)
{
  int32_t result;
  __asm__ __volatile__ ("" : : : "memory");
  asm volatile("sc.w %0, %1, (%2)" : "=r"(result) : "r"(value), "r"(address));
  __asm__ __volatile__ ("" : : : "memory");
  return result;
}

/**
 * Try to acquire a specified lock.
 *
 * @param   mutex       A pointer to the mutex location to be locked.
 *
 * @return  0 if the mutex was successfully locked.
 */
static inline int32_t lr_sc_try_lock(lr_sc_mutex_t* const mutex)
{
  if (load_reserved(mutex))
    {
      return 1;
    }
  else
    {
      return store_conditional(mutex, 1);
    }
}

/**
 * Blocking function to lock a mutex. This function only returns once the mutex
 * has been locked. A backoff timer is used to prevent live-locks.
 *
 * @param   mutex       A pointer to the lock's memory location.
 */
static inline void lr_sc_lock_mutex(lr_sc_mutex_t* const mutex,   uint32_t backoff)
{
  while(lr_sc_try_lock(mutex))
    {
      mempool_wait(backoff);
    }
}

/**
 * Unlock the specified mutex.
 *
 * @param   mutex       A pointer to the mutex to be unlocked.
 */
static inline void lr_sc_unlock_mutex(lr_sc_mutex_t* const mutex)
{
  __asm__ __volatile__ ("" : : : "memory");
  *mutex = 0;
  __asm__ __volatile__ ("" : : : "memory");
}

/**
 * Allocate and initialize a mutex
 *
 * @return  A pointer to the allocated memory location to be used as a lock.
 *          NULL if memory allocation failed.
 */
lr_sc_mutex_t* lr_sc_allocate_mutex();

/**
 * Free the memory allocated for the specified mutex.
 *
 * @param   mutex       A pointer to the mutex to be freed.
 */
void lr_sc_free_mutex(lr_sc_mutex_t* mutex);

/**
 * Swap value atomically if the old memory value matches.
 * The store conditional in the else clause makes sure that the
 * reservation is discarded if the CAS fails
 *
 * @param   address     A pointer to an address in L2 memory.
 * @param   old         The value expected in the memory.
 * @param   new         The new value to be stored if 'old' matched the memory.
 *
 * @return  0 on success, -1 if value did not match, >0 if atomic access failed.
 */
static inline int32_t compare_and_swap(volatile void* const address, uint32_t old, uint32_t new)
{
  uint32_t temp = load_reserved(address);
  if (temp == old) {
    return store_conditional(address, new);
  }
  else {
    store_conditional(address, temp);
    return -1;
  }
}

#endif
