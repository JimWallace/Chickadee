#!/bin/bash
#
# Installs the Swift toolchain into the Claude Code on the web sandbox so
# `swift build` / `swift test` work during the session.  Local Claude Code
# sessions skip this (the user manages their own toolchain on the laptop).
#
# Version pin must match Dockerfile (Stage 1 FROM swift:X.Y-jammy) and
# Package.swift (swift-tools-version).  Update all three together.

set -euo pipefail

# Skip on local Claude Code sessions — the developer's toolchain is on disk.
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
    exit 0
fi

SWIFT_VERSION="6.3"
SWIFT_PLATFORM="ubuntu24.04"
SWIFT_RELEASE="swift-${SWIFT_VERSION}-RELEASE"
SWIFT_DIR="${HOME}/swift/${SWIFT_RELEASE}-${SWIFT_PLATFORM}"
SWIFT_BIN="${SWIFT_DIR}/usr/bin"

if [ ! -x "${SWIFT_BIN}/swift" ]; then
    echo "Installing Swift ${SWIFT_VERSION} for ${SWIFT_PLATFORM}..."
    mkdir -p "${HOME}/swift"
    TARBALL_URL="https://download.swift.org/swift-${SWIFT_VERSION}-release/${SWIFT_PLATFORM/./}/${SWIFT_RELEASE}/${SWIFT_RELEASE}-${SWIFT_PLATFORM}.tar.gz"
    TMP_TARBALL="$(mktemp -t swift-XXXXXX.tar.gz)"
    trap 'rm -f "${TMP_TARBALL}"' EXIT
    curl -fL --retry 3 --retry-delay 5 -o "${TMP_TARBALL}" "${TARBALL_URL}"
    tar -xzf "${TMP_TARBALL}" -C "${HOME}/swift"
    rm -f "${TMP_TARBALL}"
    trap - EXIT
    echo "Swift installed at ${SWIFT_DIR}"
fi

"${SWIFT_BIN}/swift" --version

# Persist PATH for the session so subsequent shells see swift.
echo "export PATH=\"${SWIFT_BIN}:\$PATH\"" >> "${CLAUDE_ENV_FILE}"
