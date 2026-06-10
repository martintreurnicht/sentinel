#!/usr/bin/env bash
# Notarize a DMG with Apple's notary service and staple the ticket to it.
# A single submission of the DMG covers the app inside it — the notary service
# scans nested code and issues tickets for both.
#
# Auth via App Store Connect API key, from the environment:
#   NOTARY_KEY            base64-encoded .p8 private key
#   NOTARY_KEY_ID         key ID
#   NOTARY_KEY_ISSUER_ID  issuer ID
set -euo pipefail

DMG="${1:?usage: scripts/notarize.sh path/to/Sentinel.dmg}"
: "${NOTARY_KEY:?}" "${NOTARY_KEY_ID:?}" "${NOTARY_KEY_ISSUER_ID:?}"

KEY_FILE="$(mktemp -t notary-key).p8"
SUBMIT_LOG="$(mktemp -t notary-submit)"
trap 'rm -f "$KEY_FILE" "$SUBMIT_LOG"' EXIT
printf '%s' "$NOTARY_KEY" | base64 --decode > "$KEY_FILE"
AUTH=(--key "$KEY_FILE" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_KEY_ISSUER_ID")

echo "Submitting $DMG for notarization..."
xcrun notarytool submit "$DMG" "${AUTH[@]}" --wait --timeout 30m 2>&1 | tee "$SUBMIT_LOG"

# notarytool submit --wait can exit 0 even when the verdict is Invalid, so
# check the reported status and surface the per-file issue log on failure.
id=$(awk '/^ *id:/ {print $2; exit}' "$SUBMIT_LOG")
status=$(awk '/^ *status:/ {s=$2} END {print s}' "$SUBMIT_LOG")
if [ "$status" != "Accepted" ]; then
  echo "Notarization failed (status: ${status:-unknown})" >&2
  [ -n "$id" ] && xcrun notarytool log "$id" "${AUTH[@]}" >&2
  exit 1
fi

xcrun stapler staple "$DMG"
