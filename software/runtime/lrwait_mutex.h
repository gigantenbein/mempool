// Copyright 2021 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Author: Marc Gantenbein, Samuel Riedel, ETH Zurich

#ifndef __LRWAIT_H__
#define __LRWAIT_H__

#include <stdint.h>
#include <string.h>

#include "runtime.h"

/**
 * Mutex type.
 */
typedef volatile uint32_t lr_sc_mutex_t;

/**
 * Expose the custom load reserved wait instructions. Loads a word from a specified
 * address and creates a reservation. Only receive a response to the load reserved
 * wait when you are the first core in the queue
 *
 * @param   address     Pointer to the address to create reservation and load
 *                      the value from.
 *
 * @return  Value currently stored in memory.
 */
static inline uint32_t load_reserved_wait(volatile void* const address)
{
  uint32_t value;
  __asm__ __volatile__ ("" : : : "memory");
  asm volatile("lrwait.w %0, (%1)" : "=r"(value) : "r"(address));
  __asm__ __volatile__ ("" : : : "memory");
  return value;
}

/**
 * Expose the store-conditional instruction. Only stores a value if a previously
 * made reservation has not been broken by another core. Nested LRWait/SCWaits are
 * not allowed
 *
 * @param   address     A pointer to an address on L2 memory to store the value.
 * @param   value       Value to store.
 *
 * @return  0: Store was successful, the reservation was still valid.
 *          1: Reservation was broken, no store happened.
 */
static inline int32_t store_conditional_wait(volatile void* const address, uint32_t const value)
{
  int32_t result;
  __asm__ __volatile__ ("" : : : "memory");
  asm volatile("scwait.w %0, %1, (%2)" : "=r"(result) : "r"(value), "r"(address));
  __asm__ __volatile__ ("" : : : "memory");
  return result;
}

static inline int32_t monitor_wait(volatile void* const address, uint32_t const value)
{
  int32_t result;
  __asm__ __volatile__ ("" : : : "memory");
  asm volatile("mwait.w %0, %1, (%2)" : "=r"(result) : "r"(value), "r"(address));
  __asm__ __volatile__ ("" : : : "memory");
  return result;
}

static inline int32_t lrwait_try_lock(lr_sc_mutex_t* const mutex)
{
  if (*mutex)
    {
      return 1;
    }
  else
    {
      load_reserved_wait(mutex);
      return store_conditional_wait(mutex, 1);
    }
}

static inline void lrwait_lock_mutex(lr_sc_mutex_t* const mutex,   uint32_t backoff)
{
  while(lrwait_try_lock(mutex))
    {
      mempool_wait(backoff);
    }
}

static inline void lrwait_unlock_mutex(lr_sc_mutex_t* const mutex)
{
  __asm__ __volatile__ ("" : : : "memory");
  do {
    load_reserved_wait(mutex);
  } while(store_conditional_wait(mutex, 0));
  __asm__ __volatile__ ("" : : : "memory");
}

/**
 * Swap value atomically if the old memory value matches.
 * The store conditional in the else clause makes sure that the
 * reservation is discarded if the CAS fails
 */
static inline int32_t compare_and_swap(volatile void* const address, uint32_t old, uint32_t new)
{
  uint32_t temp = load_reserved_wait(address);
  if (temp == old) {
    return store_conditional_wait(address, new);
  }
  else {
    store_conditional_wait(address, temp);
    return -1;
  }
}

#endif
