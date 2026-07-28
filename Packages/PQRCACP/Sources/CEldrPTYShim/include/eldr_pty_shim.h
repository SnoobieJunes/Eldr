// SPDX-License-Identifier: Apache-2.0
// WS-L4 (Linux PTY re-seam): Swift's Glibc module exports NONE of the pty family
// (`openpty`/`posix_openpt`/`grantpt`/`unlockpt`/`ptsname_r` — libutil/<pty.h> and
// feature-guarded stdlib declarations), nor the `POSIX_SPAWN_SETSID` macro (behind
// __USE_GNU). This shim exposes exactly the two symbols the Swift side needs.
//
// DELIBERATELY NO SYSTEM INCLUDES IN THIS HEADER: absorbing <pty.h>/<spawn.h> (and
// their transitive <sys/select.h> etc.) into this clang module collides with the same
// headers absorbed into CDispatch/Glibc ("fd_set is not present in definition …").
// The system headers are included ONLY in shim.c, where the values/functions are read
// from the REAL glibc — never hand-copied constants (glibc's POSIX_SPAWN_SETSID is
// 0x80 where Darwin's is 0x0400; copying literals is exactly the bug class to avoid).
// Same pattern as SwiftNIO's CNIOLinux shims.
//
// On Apple platforms (and anything non-Linux) this compiles to an EMPTY module: no
// code, no symbols, no external dependency — PQRCACP's zero-external-packages promise
// is untouched (this is an internal target, not a package dependency).
#pragma once

#if defined(__linux__)

/* glibc's POSIX_SPAWN_SETSID, read from <spawn.h> at shim.c compile time. The flags
 * argument of posix_spawnattr_setflags is a `short`, so this is one too. */
extern const short ELDR_POSIX_SPAWN_SETSID;

/* openpty(3) with the termios/winsize params pinned to NULL (the Swift side never
 * passes them): allocates the master/slave pair, grants + unlocks the slave, and
 * writes its path into `name` (caller supplies >= 256 bytes; "/dev/pts/N" is short).
 * Returns 0 on success, -1 with errno set on failure — the untouched openpty contract. */
int eldr_openpty(int *amaster, int *aslave, char *name);

#endif /* __linux__ */
