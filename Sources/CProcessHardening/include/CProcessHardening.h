// CProcessHardening/include/CProcessHardening.h
//
// Stops other processes of the same user from inspecting this process.
//
// The runner and the server start child processes that run code they do not
// trust: a student's test script, or an `=` expression course staff wrote.
// A child runs as the same user. On Linux it can then read
// /proc/<parent pid>/environ, which holds RUNNER_SHARED_SECRET and the
// server's database and OIDC credentials. The child's own environment is an
// allowlist; this closes the parent's.
//
// This is a C target because prctl(2) is variadic, and Swift does not import
// variadic C functions.

#ifndef C_PROCESS_HARDENING_H
#define C_PROCESS_HARDENING_H

/// Marks this process non-dumpable (Linux), so the kernel refuses to let a
/// process without CAP_SYS_PTRACE read its environment, memory or other
/// /proc entries. Returns 0 on success and -1 when the kernel refuses. On other
/// platforms it does nothing and returns 0.
int chickadee_refuse_process_inspection(void);

/// 1 when other processes of the same user may inspect this process, 0 when
/// they may not, and -1 when the platform cannot say.
int chickadee_process_inspection_allowed(void);

#endif
