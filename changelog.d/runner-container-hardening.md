### Security

- **The runner container now drops every capability, refuses privilege
  escalation, caps its process count and runs with a read-only root.** It
  executes untrusted student code, and none of those four costs a test script
  anything it legitimately needs. Brought upstream from a production
  deployment that had been carrying them locally.

  The tmpfs that replaces the writable root deliberately does **not** carry
  `noexec`. The runner's work root defaults to `/tmp/chickadee-runner-cache`,
  and a compiled language writes a binary there and executes it — a C++
  assignment compiles with g++ and execs the result, so `noexec` would turn
  every C++ test into a permission error the student reads as a broken test.
  Resource ceilings (`mem_limit`, `cpus`) are left commented for the same
  class of reason: 256 MB suits Python and R and will not compile C++ or
  Java, and tmpfs pages count against the memory cgroup.
