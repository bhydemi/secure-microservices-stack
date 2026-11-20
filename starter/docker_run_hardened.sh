#!/usr/bin/env bash
# Hardened build + run commands for starter/Dockerfile.
#
# Docker-bench's "Container Runtime" section grades how a container is
# *run*, not just how its image is built -- a perfectly hardened Dockerfile
# still fails those checks if it's started with `docker run <image>` and
# nothing else. Each flag below closes one specific runtime weakness; cross
# reference the exact CIS Docker Benchmark clause numbers against your own
# docker-bench output and starter/docs/CIS_Docker_Benchmark_v1.2.0.pdf, since
# section numbering can shift between benchmark versions.
set -euo pipefail

docker build -t secure-microservices-stack:hardened starter/

docker run -d \
  --name secure-microservices-stack \
  --user appuser \
  `# don't let the process gain more privileges than it started with (e.g. via a setuid binary)` \
  --security-opt=no-new-privileges \
  `# start with zero Linux capabilities; add back only the ones a given workload actually needs` \
  --cap-drop=ALL \
  `# make the root filesystem read-only so a compromise can't persist a backdoor to disk` \
  --read-only \
  --tmpfs /tmp \
  `# bound memory/CPU so one container can't starve the host or its neighbors` \
  --memory=256m \
  --cpus=0.5 \
  `# bound the number of processes/threads the container can fork (fork-bomb protection)` \
  --pids-limit=100 \
  `# never share the host's process namespace (the default already keeps this off --` \
  `# this comment is a reminder not to add --pid=host, not a flag that needs adding)` \
  `# restart on failure a bounded number of times instead of an unconditional restart loop` \
  --restart=on-failure:5 \
  secure-microservices-stack:hardened
