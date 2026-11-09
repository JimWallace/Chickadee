#!/usr/bin/env bash
# Usage: post.sh JAR PATH [curl --data-urlencode args...]
# Reads the CSRF meta token from / and posts a form with it.
set -euo pipefail
. "$(dirname "$0")/env.sh"
JAR=$1; P=$2; shift 2
TOKEN=$(curl -s -b "$JAR" -c "$JAR" "$BASE/" | grep -o 'csrf-token" content="[^"]*"' | head -1 | sed 's/.*content="//; s/"$//')
curl -s -o /dev/null -w "POST $P -> %{http_code} %{redirect_url}\n" -b "$JAR" -c "$JAR" \
  --data-urlencode "_csrf=$TOKEN" "$@" "$BASE$P"
