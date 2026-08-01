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
RUN apt-get update -qq \
    && apt-get install -y --no-install-recommends file python3 zip unzip curl \
        r-base python3-pandas python3-matplotlib \
    && rm -rf /var/lib/apt/lists/*
