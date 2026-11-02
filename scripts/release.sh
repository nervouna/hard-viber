#!/bin/bash
# Builds a Developer ID signed, notarized and stapled Quota.app, archives it in build/release/ and
# installs it in ~/Applications.
#
# Usage: scripts/release.sh [--skip-notarize] [--no-install]
#
# Steps: a clean working tree, scripts/test.sh, a Developer ID build (hardened runtime, secure
# timestamp, no entitlements), signature checks, notarization (notarytool submit --wait), stapling,
# a Gatekeeper check, a zip of the stapled app with its SHA-256, and scripts/install.sh.
# --skip-notarize stops after the signature checks, to rehearse without uploading; nothing is
# archived or installed. --no-install leaves the installed copy alone.
#
# Signing and notary settings come from $QUOTA_SIGNING_ENV, by default
# ${XDG_CONFIG_HOME:-~/.config}/quota/signing.env, which is never part of the repository:
#   QUOTA_CODESIGN_IDENTITY   "Developer ID Application: <name> (<team>)"
#   QUOTA_NOTARY_KEY          path of the App Store Connect API key (.p8)
#   QUOTA_NOTARY_KEY_ID       the key's ID
#   QUOTA_NOTARY_ISSUER_FILE  path of a file that holds the issuer ID
# The key is passed to notarytool by path and never read here; the issuer ID is never printed.
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
app="$project_dir/build/Quota.app"
release_dir="$project_dir/build/release"

log() { printf '==> %s\n' "$*" >&2; }
die() { printf 'release: %s\n' "$*" >&2; exit 1; }

skip_notarize=false
install=true
for argument in "$@"; do
  case "$argument" in
    --skip-notarize) skip_notarize=true ;;
    --no-install) install=false ;;
    *) die "unknown option $argument (usage: scripts/release.sh [--skip-notarize] [--no-install])" ;;
  esac
done

# --- Settings. ---------------------------------------------------------------------------------

signing_env="${QUOTA_SIGNING_ENV:-${XDG_CONFIG_HOME:-$HOME/.config}/quota/signing.env}"
[ -r "$signing_env" ] || die "no signing settings at $signing_env (see the header of this script)"
# Values inherited from the caller's environment must not override the file.
unset QUOTA_CODESIGN_IDENTITY QUOTA_NOTARY_KEY QUOTA_NOTARY_KEY_ID QUOTA_NOTARY_ISSUER_FILE
# shellcheck source=/dev/null
source "$signing_env"
[ -n "${QUOTA_CODESIGN_IDENTITY:-}" ] || die "QUOTA_CODESIGN_IDENTITY is not set in $signing_env"
security find-identity -v -p codesigning | grep -qF "\"$QUOTA_CODESIGN_IDENTITY\"" \
  || die "the keychain has no valid identity named $QUOTA_CODESIGN_IDENTITY"
if ! $skip_notarize; then
  [ -n "${QUOTA_NOTARY_KEY_ID:-}" ] || die "QUOTA_NOTARY_KEY_ID is not set in $signing_env"
  [ -r "${QUOTA_NOTARY_KEY:-}" ] || die "QUOTA_NOTARY_KEY does not name a readable file"
  [ -r "${QUOTA_NOTARY_ISSUER_FILE:-}" ] || die "QUOTA_NOTARY_ISSUER_FILE does not name a readable file"
  issuer="$(tr -d '[:space:]' < "$QUOTA_NOTARY_ISSUER_FILE")"
  [ -n "$issuer" ] || die "the file named by QUOTA_NOTARY_ISSUER_FILE is empty"
fi

# The bundle's version and build number come from VERSION and the commit count, so a release must
# be exactly a commit.
[ -z "$(git -C "$project_dir" status --porcelain)" ] || die "the working tree has uncommitted changes"
version="$(tr -d '[:space:]' < "$project_dir/VERSION")"
build="$(git -C "$project_dir" rev-list --count HEAD)"
name="Quota-$version-$build"

# --- Helpers. ----------------------------------------------------------------------------------

# Copies stdin to stderr with the issuer ID and the key path blanked out.
redact() {
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "${issuer:-}" ] && line="${line//"$issuer"/<issuer>}"
    line="${line//"${QUOTA_NOTARY_KEY:-}"/<key>}"
    printf '%s\n' "$line" >&2
  done
}

notary() {
  local subcommand="$1"
  shift
  xcrun notarytool "$subcommand" "$@" \
    --key "$QUOTA_NOTARY_KEY" --key-id "$QUOTA_NOTARY_KEY_ID" --issuer "$issuer"
}

# The notary service rejects a bundle without the hardened runtime, a secure timestamp or a
# Developer ID signature, or with get-task-allow.
check_signature() {
  local details
  codesign --verify --strict --deep "$1" || die "signature verification failed for $1"
  details="$(codesign -dvv "$1" 2>&1)"
  grep -qF "Authority=$QUOTA_CODESIGN_IDENTITY" <<<"$details" || die "$1 is not signed by $QUOTA_CODESIGN_IDENTITY"
  grep -q 'flags=.*runtime' <<<"$details" || die "$1 lacks the hardened runtime"
  grep -q '^Timestamp=' <<<"$details" || die "$1 lacks a secure timestamp"
  if codesign -d --entitlements - "$1" 2>/dev/null | grep -q 'get-task-allow'; then
    die "$1 carries get-task-allow"
  fi
}

check_gatekeeper() {
  spctl -a -vv -t exec "$1" 2>&1 | grep -q 'source=Notarized Developer ID' \
    || die "Gatekeeper does not accept $1 as notarized"
}

# --- Build. ------------------------------------------------------------------------------------

# quiet <description> <command...>: runs the command and shows its output only when it fails.
quiet() {
  local description="$1" output
  shift
  output="$("$@" 2>&1)" || { printf '%s\n' "$output" >&2; die "$description failed"; }
}

log "Testing"
quiet "scripts/test.sh" bash "$project_dir/scripts/test.sh"

log "Building $name with $QUOTA_CODESIGN_IDENTITY"
quiet "scripts/build.sh" env CODESIGN_IDENTITY="$QUOTA_CODESIGN_IDENTITY" bash "$project_dir/scripts/build.sh"
check_signature "$app"

if $skip_notarize; then
  log "Signed $app; skipped notarization, archive and install"
  exit 0
fi

# --- Notarize and staple. ----------------------------------------------------------------------

mkdir -p "$release_dir"
submission="$release_dir/$name-notary.zip"
result="$release_dir/$name-notary.json"
rm -f "$submission" "$result"
ditto -c -k --keepParent "$app" "$submission"

log "Notarizing (usually a few minutes)"
notary submit "$submission" --wait --timeout 30m --output-format json >"$result" 2> >(redact) \
  || die "notarytool submit failed before a verdict"
submission_id="$(plutil -extract id raw -o - "$result")"
status="$(plutil -extract status raw -o - "$result")"
if [ "$status" != "Accepted" ]; then
  notary log "$submission_id" 2>&1 | redact
  die "notarization $submission_id ended as $status"
fi
rm -f "$submission"

# The ticket can reach Apple's CDN a little after the verdict.
log "Stapling ($submission_id)"
for attempt in 1 2 3 4 5 6; do
  xcrun stapler staple -q "$app" && break
  [ "$attempt" -lt 6 ] || die "could not staple the ticket to $app"
  sleep 10
done
xcrun stapler validate -q "$app" || die "the stapled ticket does not validate"
check_gatekeeper "$app"

archive="$release_dir/$name.zip"
rm -f "$archive"
ditto -c -k --keepParent "$app" "$archive"
(cd "$release_dir" && shasum -a 256 "$name.zip" >"$name.zip.sha256")

# --- Install. ----------------------------------------------------------------------------------

if $install; then
  log "Installing"
  installed="$(bash "$project_dir/scripts/install.sh" "$app")"
  check_gatekeeper "$installed"
fi

log "Released $name (notarization $submission_id)"
printf '%s\n' "$archive"
