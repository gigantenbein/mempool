// Copyright 2021 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Author: Marc Gantenbein, Samuel Riedel, ETH Zurich

#include "lr_sc_mutex.h"

lr_sc_mutex_t *lr_sc_allocate_mutex() {
  lr_sc_mutex_t *const new_mutex = simple_malloc(sizeof(lr_sc_mutex_t));
  // Verify correct allocation
  if (new_mutex == NULL) {
    return NULL;
  }
  // Initialize the mutex
  lr_sc_unlock_mutex(new_mutex);
  return new_mutex;
}

void lr_sc_free_mutex(lr_sc_mutex_t *const mutex) { simple_free((void *)mutex); }
