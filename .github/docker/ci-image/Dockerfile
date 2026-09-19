# CI test image: the mirrored Swift toolchain plus the system packages the
# test jobs need.  Before this image, every test job apt-get installed these
# at job start — 20–40 s per job per run, plus 3×15 s retry loops whenever an
# Ubuntu mirror flaked.  Built and pushed by mirror-images.yml (weekly, on
# demand, and on PRs that touch this file or that workflow), immediately
# after the base mirror refreshes, so the toolchain inside always matches
# ghcr.io/<owner>/chickadee/swift:6.4-noble.
#
# BASE_IMAGE defaults to the GHCR mirror, not docker.io, so building never
# hits Docker Hub rate limits (the reason the mirror exists — see
# mirror-images.yml). The workflow overrides it with the lowercased owner.
#
# Toolchain identity is unchanged — `swift --version` is byte-identical to
# the base image, so the `.build` cache keys shared with jobs still on the
# plain mirror keep matching.
ARG BASE_IMAGE=ghcr.io/jimwallace/chickadee/swift:6.4-noble
FROM ${BASE_IMAGE}

# file      — SubmissionNormalizer MIME detection (worker-tests, nightly)
# python3   — LocalHTTPTestServer + notebook probes (WorkerTests) and
#             generated pattern-family scripts, `#!/usr/bin/env python3`
#             (APITests, nightly); noble, unlike jammy, does not bundle it
# zip/unzip — test-setup and course-bundle fixtures (APITests, nightly)
# curl      — nightly coverage tooling
# r-base    — Rscript for the R execution-path suites (PatternFamilyRendererR,
#             NotebookCheckRendererR, PersonalizationEvaluatorR, WorkerTests R
#             normalization); without it every hasRscript guard skips silently
#             and a shipped feature's grading path has zero CI coverage
# lua5.4    — the Lua execution-path suites (LuaNativeGradingTests,
#             LuaPersonalizationDriverTests, the conformance matrix's executed
#             Lua rows); provides /usr/bin/lua via update-alternatives. Same
#             silent-skip trap as r-base: it shipped in #1282 without this line,
#             so every native Lua grading test guarded `luaAvailable` and skipped
#             — the did-not-skip probes below now fail in CI if it regresses
# python3-pandas / python3-matplotlib — NotebookCheckRuntimeState tests that
#             exercise dataframe/plot check kinds against a real interpreter
# ca-certificates — needed by curl for the Node fetch below and by npm.
#             Node itself is NOT apt's: see the NODE_VERSION block after this
#             layer. The browser probe jobs (editor smoke, exec-hang,
#             grading-hang, lifecycle, reset, bridge, visual) run the
#             Playwright harness in Tools/editor-smoke-test, and they used to
#             apt-get node at job start, which is the same 20-40 s per job the
#             rest of this image exists to remove — and on 2026-08-04 it was
#             worse than slow: archive.ubuntu.com was unreachable, the step
#             exited 100, every probe skipped its tests, and the required
#             editor-smoke gate went red because of an Ubuntu mirror.
RUN apt-get update -qq \
    && apt-get install -y --no-install-recommends file python3 zip unzip curl \
        r-base python3-pandas python3-matplotlib lua5.4 octave \
        gnuplot-nox fonts-freefont-otf g++ racket default-jdk \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Node from nodejs.org, NOT from apt.
#
# Ubuntu noble ships Node 18.19.1, and Playwright dropped Node 18 at 1.63:
# `npx playwright install` exits 1 with "Playwright requires Node.js 20 or
# higher" before a single probe runs. Every probe job that runs INSIDE this
# container broke on the 1.63 bump while the host-based smoke jobs stayed green,
# because those run on ubuntu-latest — which is exactly the shape that makes
# this look like a code failure rather than an image one.
#
# Pinning the official tarball rather than adding the NodeSource apt repo keeps
# the version explicit here (apt would float it, which is how we got 18 without
# choosing it) and avoids a second third-party apt source on the least reliable
# step in the build.
ARG NODE_VERSION=24.21.0
RUN curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.gz" \
        -o /tmp/node.tar.gz \
    && tar -xzf /tmp/node.tar.gz -C /usr/local --strip-components=1 \
        --exclude=CHANGELOG.md --exclude=LICENSE --exclude=README.md \
    && rm /tmp/node.tar.gz \
    && node --version \
    && npm --version
# octave     — provides /usr/bin/octave-cli for the Octave execution-path
#              suites. Same silent-skip trap as r-base and lua5.4 (audit F2):
#              without it every Octave execution test guards on availability
#              and skips, and "green" means nothing ever ran the generated
#              Octave. ~338 MB installed (no CLI-only package exists — octave
#              hard-depends on Qt5 even with --no-install-recommends).
# gnuplot-nox + fonts-freefont-otf — headless figure creation for the
#              figureCount execution tests; without them figure() errors and
#              the tests would skip or fail for reasons unrelated to the code.
# racket     — the interpreter for the Racket execution-path suites
#              (RacketRendererExecutionTests, the conformance matrix's Racket
#              arm). The Debian package includes the HtDP teaching-language
#              collections, which is the requirement rather than a bonus:
#              CS 135/115 submissions are `#lang htdp/bsl` and a minimal
#              Racket would reject every one of them. Same silent-skip trap as
#              r-base and lua5.4 — the suites guard on `racket --version` and
#              pass vacuously without it, which `racketIsPresentInCI` exists to
#              catch.
#
# g++        — the C++ toolchain for the C++ execution-path suites (generated
#              .sh wrappers compile a single TU per test) and the C++
#              personalization-driver tests. Same silent-skip trap as the
#              interpreters above.
