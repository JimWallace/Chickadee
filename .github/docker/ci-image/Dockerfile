# CI test image: the mirrored Swift toolchain plus the system packages the
# test jobs need.  Before this image, every test job apt-get installed these
# at job start — 20–40 s per job per run, plus 3×15 s retry loops whenever an
# Ubuntu mirror flaked.  Built and pushed by mirror-images.yml (weekly, on
# demand, and on PRs that touch this file or that workflow), immediately
# after the base mirror refreshes, so the toolchain inside always matches
# ghcr.io/<owner>/chickadee/swift:6.3-noble.
#
# BASE_IMAGE defaults to the GHCR mirror, not docker.io, so building never
# hits Docker Hub rate limits (the reason the mirror exists — see
# mirror-images.yml). The workflow overrides it with the lowercased owner.
#
# Toolchain identity is unchanged — `swift --version` is byte-identical to
# the base image, so the `.build` cache keys shared with jobs still on the
# plain mirror keep matching.
ARG BASE_IMAGE=ghcr.io/jimwallace/chickadee/swift:6.3-noble
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
# python3-pandas / python3-matplotlib — NotebookCheckRuntimeState tests that
#             exercise dataframe/plot check kinds against a real interpreter
# nodejs/npm/ca-certificates — the browser probe jobs (editor smoke, exec-hang,
#             grading-hang, lifecycle, reset, bridge, visual) run the
#             Playwright harness in Tools/editor-smoke-test. They used to
#             apt-get these at job start, which is the same 20-40 s per job the
#             rest of this image exists to remove — and on 2026-08-04 it was
#             worse than slow: archive.ubuntu.com was unreachable, the step
#             exited 100, every probe skipped its tests, and the required
#             editor-smoke gate went red because of an Ubuntu mirror.
RUN apt-get update -qq \
    && apt-get install -y --no-install-recommends file python3 zip unzip curl \
        r-base python3-pandas python3-matplotlib \
        nodejs npm ca-certificates \
    && rm -rf /var/lib/apt/lists/*
