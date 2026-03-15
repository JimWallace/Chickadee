# ============================================================
# Stage 1 — Build
# To update Swift: change the version tag here and in Stage 2.
# Current: Swift 6.0 on Ubuntu 22.04 (jammy)
# ============================================================
FROM swift:6.0-jammy AS build

WORKDIR /build

# Resolve dependencies in a dedicated layer.
# Only re-fetches when Package.swift or Package.resolved changes —
# source edits don't bust this cache.
COPY Package.swift Package.resolved ./
RUN swift package resolve --skip-update

# Copy sources and build both release binaries.
# --static-swift-stdlib embeds the Swift stdlib so the runtime image
# doesn't need Swift's shared libraries.
COPY Sources ./Sources
RUN swift build -c release \
    --static-swift-stdlib \
    --product chickadee-server \
    --product chickadee-runner

# ============================================================
# Stage 2 — Runtime
# Must use the same Ubuntu version as the build stage (jammy).
# ============================================================
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# Install C runtime dependencies only (Swift stdlib is statically linked).
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        tzdata \
        libsqlite3-0 \
        libssl3 \
        libcurl4 \
    && rm -rf /var/lib/apt/lists/*

# Non-root user for the application processes.
RUN useradd --system --user-group --create-home chickadee

WORKDIR /app

# Compiled binaries.
COPY --from=build /build/.build/release/chickadee-server  ./chickadee-server
COPY --from=build /build/.build/release/chickadee-runner  ./chickadee-runner

# Static assets — the server reads these from its working directory at runtime.
# The entrypoint script syncs them to the data volume (/data) on each startup,
# so updates to templates or JupyterLite are always picked up on redeploy.
COPY Public     ./Public
COPY Resources  ./Resources

# Startup script (server only; runner uses its binary directly).
COPY deploy/docker-entrypoint.sh ./docker-entrypoint.sh
RUN chmod +x ./docker-entrypoint.sh

RUN chown -R chickadee:chickadee /app

USER chickadee

EXPOSE 8080

# Healthcheck uses the /health endpoint built into Chickadee.
HEALTHCHECK --interval=15s --timeout=5s --start-period=30s --retries=3 \
    CMD curl -sf http://localhost:8080/health || exit 1

ENTRYPOINT ["./docker-entrypoint.sh"]
