// SPDX-License-Identifier: Apache-2.0
// The ONLY translation unit that touches the system headers (see the header for why
// they must stay out of the module). Values and calls are the real glibc ones.
#if defined(__linux__)

#ifndef _GNU_SOURCE
#define _GNU_SOURCE 1
#endif

#include <pty.h>   /* openpty(3) */
#include <spawn.h> /* POSIX_SPAWN_SETSID */
#include <stddef.h>

#include "include/eldr_pty_shim.h"

const short ELDR_POSIX_SPAWN_SETSID = POSIX_SPAWN_SETSID;

int eldr_openpty(int *amaster, int *aslave, char *name) {
    return openpty(amaster, aslave, name, NULL, NULL);
}

#endif /* __linux__ */
