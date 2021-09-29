// Copyright 2021 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Author: Marc Gantenbein, Samuel Riedel, ETH Zurich

#include "amo_mutex.h"

amo_mutex_t* amo_allocate_mutex()
{
    amo_mutex_t* const new_mutex = simple_malloc(sizeof(amo_mutex_t));
    // Verify correct allocation
    if (new_mutex == NULL) { return NULL; }
    // Initialize the mutex
    amo_unlock_mutex(new_mutex);
    return new_mutex;
}

void amo_free_mutex(amo_mutex_t* const mutex)
{
    simple_free((void*) mutex);
}
