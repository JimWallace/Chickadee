### Security

- **A sandboxed job's files hold at most `--job-disk-limit` of memory (#2252).** Each test script had separate tmpfs mounts for `/tmp` (512 MB), `HOME` (256 MB), `/var/tmp`, `/dev/shm` and, since #2251, its working directory: about 1.1 GB per job of memory that belongs to no process, which the kernel's OOM killer cannot attribute to the job that wrote it. They are now folders in one private tmpfs of `--job-disk-limit` megabytes (default 256). An exact per-job memory limit needs a cgroup and is left for a change to how the runner is started.
