// Copyright 2021 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Author: Marc Gantenbein, ETH Zurich

#include <stdint.h>
#include <string.h>

#include "encoding.h"
#include "lrwait_mutex.h"
#include "printf.h"
#include "runtime.h"
#include "synchronization.h"

volatile uint32_t tail __attribute__((section(".l1_prio")));
volatile uint32_t head __attribute__((section(".l1_prio")));
uint32_t producer_id __attribute__((section(".l1_prio")));
uint32_t consumer_id __attribute__((section(".l1_prio")));

#define N 100
volatile uint32_t items[N] __attribute__((section(".l1_prio")));

#define ITERATIONS NBINS

// not thread safe
uint32_t enqueue(uint32_t item) {
  if(((tail+1) % N ) == head) {
    // wait until head moves
    monitor_wait(&head, head);
  }
  items[tail] = item;
  tail = (tail + 1) % N;
}


uint32_t dequeue() {
  uint32_t item = 0;
  if (tail == head) {
    // wait until tail moves
    monitor_wait(&tail, tail);
  }
  item = items[head];
  head = (head + 1) % N;
  return item;
}

int main() {
  uint32_t core_id = mempool_get_core_id();
  uint32_t num_cores = mempool_get_core_count();
  uint32_t random_number = 0;
  volatile uint32_t cur_val = 0;
  uint32_t amo_counter = 0;
  // Initialize synchronization variables
  mempool_barrier_init(core_id);
  if(core_id == 0) {
    tail = 0;
    head = 0;
    // select 2 random cores for being producer and consumer
    asm volatile("csrr %0, mscratch" : "=r"(random_number));
    producer_id = random_number % num_cores;
    asm volatile("csrr %0, mscratch" : "=r"(random_number));
    consumer_id = random_number % num_cores;
  }

  mempool_barrier(num_cores);
  mempool_timer_t start_time = mempool_get_timer();

  if (core_id == producer_id) {
    for (int i = 0; i < ITERATIONS; i++) {
#if MUTEX == 0
      amo_counter++;
      while (((tail + 1) % N) == head){
        mempool_wait(BACKOFF);
        amo_counter++;
      }
      items[tail] = core_id;
      tail = (tail + 1) % N;
#elif MUTEX == 11
      enqueue(core_id);
      amo_counter++;
#endif
      asm volatile("csrr %0, mscratch" : "=r"(random_number));
      mempool_wait(10 * (random_number % num_cores));
    }
  }

  if (core_id == consumer_id) {
    write_csr(89,999);
    for (int i = 0; i < ITERATIONS; i++) {
#if MUTEX == 0
      cur_val = tail;
      amo_counter++;
      while (tail == head){
        mempool_wait(BACKOFF);
        amo_counter++;
      }
      if(items[head] != producer_id) {
        write_csr(89, 9999);
      }
      head = (head + 1) % N;
#elif MUTEX == 11
      dequeue();
      amo_counter++;
#endif
    }
  }

  mempool_timer_t stop_time = mempool_get_timer();
  mempool_barrier(num_cores);

  uint32_t time_diff = stop_time - start_time;

  if (core_id == producer_id || core_id == consumer_id) {
    write_csr(90, time_diff);
    write_csr(time, amo_counter);
  }
  mempool_barrier(num_cores);


  // wait until all cores have finished

  return 0;
}
