// Copyright (c) 2013, Facebook, Inc. All rights reserved.
// https://github.com/facebook/fishhook (BSD)
#ifndef BXFLOAT_FISHHOOK_H
#define BXFLOAT_FISHHOOK_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

struct rebinding {
    const char *name;
    void *replacement;
    void **replaced;
};

int rebind_symbols(struct rebinding rebindings[], size_t rebindings_nel);

#ifdef __cplusplus
}
#endif

#endif
