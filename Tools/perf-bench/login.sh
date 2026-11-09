#!/usr/bin/env bash
# Usage: login.sh ACTION(login|register) USERNAME PASSWORD JAR
# Fetches the form for its CSRF token, posts it, and keeps the session in JAR.
set -euo pipefail
. "$(dirname "$0")/env.sh"
ACTION=$1; USERNAME=$2; PASSWORD=$3; JAR=$4
rm -f "$JAR"
PAGE=$(curl -s -c "$JAR" -b "$JAR" "$BASE/$ACTION")
TOKEN=$(printf '%s' "$PAGE" | grep -o 'name="_csrf" value="[^"]*"' | head -1 | sed 's/.*value="//; s/"$//')
curl -s -o /dev/null -w "$ACTION $USERNAME -> %{http_code} %{redirect_url}\n" -c "$JAR" -b "$JAR" \
  --data-urlencode "_csrf=$TOKEN" --data-urlencode "username=$USERNAME" --data-urlencode "password=$PASSWORD" \
  "$BASE/$ACTION"
