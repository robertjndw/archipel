#!/bin/bash
# Submits a zip, dmg or pkg to Apple's notary service and waits for the verdict.
# Expects NOTARY_KEY_PATH, NOTARY_KEY_ID and NOTARY_ISSUER_ID (an App Store
# Connect API key) in the environment.
#
# notarytool can exit 0 for a rejected submission, so this reads the status
# itself and prints Apple's log, which names the offending binary, on failure.
set -euo pipefail

file="$1"
result="$(xcrun notarytool submit "$file" \
  --key "$NOTARY_KEY_PATH" \
  --key-id "$NOTARY_KEY_ID" \
  --issuer "$NOTARY_ISSUER_ID" \
  --wait \
  --output-format json)"
echo "$result"

status="$(plutil -extract status raw -o - - <<< "$result")"
if [[ "$status" != "Accepted" ]]; then
  id="$(plutil -extract id raw -o - - <<< "$result")"
  xcrun notarytool log "$id" --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID"
  echo "error: notarization of $file finished with status $status" >&2
  exit 1
fi
