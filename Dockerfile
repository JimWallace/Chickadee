# syntax=docker/dockerfile:1
# ============================================================
# Binary source — selectable so CI can skip the in-image compile.
#
#   BINARIES=compile  (default) — build from source in this image.
#       Used by `docker build .` and `docker compose up --build`.
#   BINARIES=prebuilt           — copy release binaries already built
#       and placed in ./artifacts/ by the CI `build-release` job, so
#       the image build does not recompile on every push.
#
# Both paths must use the same Swift / Ubuntu version so the
# statically-linked-stdlib binaries match the runtime glibc.
# To update Swift: change the tag here and in the runtime stage.
# Current: Swift 6.3 on Ubuntu 22.04 (jammy).
# ============================================================

# ── Compile from source ─────────────────────────────────────
FROM swift:6.3-jammy AS compile

WORKDIR /build

# Resolve dependencies in a dedicated layer.
# Only re-fetches when Package.swift or Package.resolved changes —
# source edits don't bust this cache.
COPY Package.swift Package.resolved ./
RUN swift package resolve --skip-update

# Copy sources and tests.  Tests/ is never compiled in this step (we build
# specific products only), but SPM validates all target paths in Package.swift
# even for targets it isn't building — so the directories must exist.
COPY Sources ./Sources
COPY Tests   ./Tests

# Build products one at a time so each gets its own log output.
# --static-swift-stdlib embeds the runtime so the runtime stage needs no Swift libs.
RUN swift build -c release --static-swift-stdlib --product chickadee-server
RUN swift build -c release --static-swift-stdlib --product chickadee-runner
RUN mkdir -p /out \
    && cp .build/release/chickadee-server .build/release/chickadee-runner /out/

# ── Prebuilt binaries from the build context ────────────────
# Only built when BINARIES=prebuilt; its COPY paths are not evaluated
# otherwise.  CI downloads the `build-release` artifact into ./artifacts/.
FROM ubuntu:22.04 AS prebuilt

WORKDIR /out
COPY artifacts/chickadee-server artifacts/chickadee-runner /out/
# Artifact upload/download can drop the executable bit; restore it.
RUN chmod +x /out/chickadee-server /out/chickadee-runner

# ── Select the binary source ────────────────────────────────
ARG BINARIES=compile
FROM ${BINARIES} AS binaries

# Verify both binaries are present — fail fast with a clear message if not.
RUN ls -lh /out/chickadee-server /out/chickadee-runner

# ============================================================
# Stage 2 — Runtime
# Must use the same Ubuntu version as the build stage (jammy).
# ============================================================
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# System dependencies:
#   - C runtime libs (Swift stdlib is statically linked)
#   - Python 3 + common scientific packages (for Python test scripts / submissions)
#   - R base (for R test scripts / submissions)
#
# If your courses need additional Python packages, extend this image:
#   FROM chickadee:latest
#   USER root
#   RUN pip3 install --no-cache-dir <your-packages>
#   USER chickadee
#
# For additional R packages:
#   RUN Rscript -e "install.packages(c('tidyverse', ...), repos='https://cloud.r-project.org')"
RUN apt-get update && apt-get upgrade -y && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        file \
        tzdata \
        libsqlite3-0 \
        libssl3 \
        libcurl4 \
        python3 \
        python3-pip \
        python3-numpy \
        python3-pandas \
        python3-scipy \
        python3-matplotlib \
        r-base \
    && rm -rf /var/lib/apt/lists/*

# Non-root user for the application processes.
RUN useradd --system --user-group --create-home chickadee

WORKDIR /app

# Compiled binaries (from whichever binary source was selected above).
COPY --from=binaries /out/chickadee-server  ./chickadee-server
COPY --from=binaries /out/chickadee-runner  ./chickadee-runner

# Static assets — the server reads these from its working directory at runtime.
# The entrypoint script syncs them to the data volume (/data) on each startup,
# so updates to templates or JupyterLite are always picked up on redeploy.
COPY Public     ./Public
COPY Resources  ./Resources

# Startup script (server only; runner uses its binary directly).
COPY deploy/docker-entrypoint.sh ./docker-entrypoint.sh
RUN chmod +x ./docker-entrypoint.sh

RUN mkdir -p /data && chown -R chickadee:chickadee /app /data

USER chickadee

EXPOSE 8080

# Healthcheck uses the /health endpoint built into Chickadee.
HEALTHCHECK --interval=15s --timeout=5s --start-period=30s --retries=3 \
    CMD curl -sf http://localhost:8080/health || exit 1

ENTRYPOINT ["./docker-entrypoint.sh"]
