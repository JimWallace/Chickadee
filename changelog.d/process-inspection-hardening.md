### Security

- **The runner and the server refuse inspection by other processes of their user.** Both mark themselves non-dumpable at start (Linux `prctl(PR_SET_DUMPABLE, 0)`). A child process they start runs as the same user, and it could read their environment through `/proc`, which holds the runner secret and the server's credentials. The kernel now refuses that read to any process without `CAP_SYS_PTRACE`. The runner's start-up log reports the result as `process_inspection`.
