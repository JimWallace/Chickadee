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
# Current: Swift 6.3 on Ubuntu 24.04 (noble).
# ============================================================

# Global ARG — must be declared before the first FROM so it can be used in
# the `FROM ${BINARIES}` stage-selector below.
ARG BINARIES=compile

# ── Compile from source ─────────────────────────────────────
FROM swift:6.3-noble AS compile

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
FROM ubuntu:24.04 AS prebuilt

WORKDIR /out
COPY artifacts/chickadee-server artifacts/chickadee-runner /out/
# Artifact upload/download can drop the executable bit; restore it.
RUN chmod +x /out/chickadee-server /out/chickadee-runner

# ── Select the binary source ────────────────────────────────
# (BINARIES is the global ARG declared at the top of this file.)
FROM ${BINARIES} AS binaries

# Verify both binaries are present — fail fast with a clear message if not.
RUN ls -lh /out/chickadee-server /out/chickadee-runner

# ============================================================
# Stage 2 — Runtime
# Must use the same Ubuntu version as the build stage (noble).
# ============================================================
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# System dependencies:
#   - C runtime libs (Swift stdlib is statically linked)
#   - zip / unzip: the server and worker shell out to /usr/bin/{zip,unzip}
#     for test-setup extract/publish, course-bundle import/export, and the
#     personal-data export (ZipArchiver, TestSetupZipHelpers). They were only
#     ever present transitively; installed explicitly so a future base-image
#     change can't silently drop them and break those paths.
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
        unzip \
        zip \
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
        lua5.4 \
        octave \
        gnuplot-nox \
        fonts-freefont-otf \
        g++ \
        racket \
        default-jdk \
    && rm -rf /var/lib/apt/lists/*
# default-jdk — javac and java, for the fifth and sixth reasons this image
# carries a toolchain. On the SERVER image because the Java personalization
# driver compiles a generated program per `=`-expression evaluation; on the
# RUNNER image because every generated Java test is a `.sh` wrapper that runs
# javac before java. Both halves need the COMPILER, which is why the capability
# probe is `javac --version` and not `java --version`: a JRE-only host would
# advertise Java and then fail every test at exit 127.
#
# `default-jdk` rather than a pinned `openjdk-N-jdk`: it tracks the base image's
# LTS (21 on noble) and needs no bump when the base moves. ~350 MB installed,
# the same order as the octave line below and accepted on the same grounds.
# racket — the interpreter generated .rkt tests are handed to, and the one the
# Racket personalization driver runs under. The Debian package carries the HtDP
# teaching-language collections (`#lang htdp/bsl`), which is what CS 135/115
# submissions are written in — a minimal Racket would grade full Racket and
# reject every teaching-language file, so the full package is the requirement.
#
# g++ — the C++ toolchain the generated .sh wrappers and the C++
# personalization driver invoke. On the SERVER image because
# `PersonalizationEvaluator` compiles a driver per `=`-expression evaluation
# (~0.3s each, measured); on the runner image because every generated C++
# test compiles its single translation unit before running. ~60 MB installed.
# `octave` provides /usr/bin/octave-cli, the binary the worker invokes for .m
# test scripts. There is no CLI-only Debian/Ubuntu package: even with
# --no-install-recommends, `octave` hard-depends on the Qt5 stack, so this line
# costs ~338 MB installed (measured on noble). Accepted as the price of Octave
# validation working at all — without the interpreter, every Octave test exits
# 127 and instructor validation cannot pass (the failure class #1280 fixed for
# Lua).
#
# gnuplot-nox + fonts-freefont-otf (~7 MB together) are what make HEADLESS
# figure creation work under octave-cli: without a toolkit, `figure()` errors
# "no graphics toolkits are available!", and gnuplot without that font dies in
# ft_text_renderer — either way every figureCount notebook check errors at
# validation. Measured, not assumed; the wasm kernel side needs nothing (its
# plotly toolkit is built in).

# Non-root user for the application processes.
RUN useradd --system --user-group --create-home chickadee

WORKDIR /app

# Compiled binaries (from whichever binary source was selected above).
COPY --from=binaries /out/chickadee-server  ./chickadee-server
COPY --from=binaries /out/chickadee-runner  ./chickadee-runner

# Static assets — the server reads these from its working directory at runtime.
# The entrypoint script symlinks them from the data volume (/data) to these
# image copies on each startup, so updates to templates or JupyterLite are
# picked up on redeploy without re-copying ~586 MB into the volume every boot.
COPY Public     ./Public
COPY Resources  ./Resources
# Authoring guides served as MCP resources (see MCPResourceProvider).
COPY docs       ./docs

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
