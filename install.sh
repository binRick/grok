#!/usr/bin/env bash
#
# install.sh — repo-local, non-invasive installer for Grok Build (`grok`).
#
# Downloads xAI's official prebuilt `grok` binary and installs it INSIDE this
# repository, under ./.grok/bin/. It does NOT modify your $HOME, your PATH, or
# your shell rc files — everything lives in this repo and is removed by
# `make uninstall`. Re-running upgrades in place (this is also `make update`).
#
# Usage:
#   ./install.sh                 # latest stable
#   ./install.sh 0.2.106         # pin a specific version
#   GROK_CHANNEL=alpha ./install.sh
#   GROK_BIN_DIR=/custom/dir ./install.sh
#
# Env:
#   GROK_CHANNEL   stable | alpha | enterprise   (default: stable)
#   GROK_VERSION   pin a version (same as the positional arg)
#   GROK_BIN_DIR   where to place the `grok`/`agent` symlinks
#                  (default: <repo>/.grok/bin)
#
set -euo pipefail

# --- locate this repo (works from any CWD) ---
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${GROK_BIN_DIR:-$SCRIPT_DIR/.grok/bin}"
DOWNLOAD_DIR="$SCRIPT_DIR/.grok/downloads"
CHANNEL="${GROK_CHANNEL:-stable}"
TARGET="${1:-${GROK_VERSION:-}}"

BASE_PRIMARY="https://x.ai/cli"
BASE_FALLBACK="https://storage.googleapis.com/grok-build-public-artifacts/cli"

info() { printf '\033[36m==>\033[0m %s\n' "$*" >&2; }
ok()   { printf '\033[32m ok\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

command -v curl >/dev/null 2>&1 || die "curl is required but not installed."

# --- detect platform ---
case "$(uname -s)" in
  Darwin) os="macos" ;;
  Linux)  os="linux" ;;
  MINGW*|MSYS*|CYGWIN*)
    die "Windows is not supported by this repo-local installer. Use the official one:
       irm https://x.ai/cli/install.ps1 | iex" ;;
  *) die "Unsupported OS: $(uname -s)" ;;
esac
case "$(uname -m)" in
  x86_64|amd64|AMD64)  arch="x86_64" ;;
  arm64|aarch64|ARM64) arch="aarch64" ;;
  *) die "Unsupported architecture: $(uname -m)" ;;
esac
platform="${os}-${arch}"

# --- pick a reachable base URL (x.ai first, GCS fallback) ---
probe="$(curl -fsSL "${BASE_PRIMARY}/${CHANNEL}" 2>/dev/null || true)"
if [ -n "$probe" ]; then
  BASE="$BASE_PRIMARY"
else
  info "${BASE_PRIMARY} unreachable — falling back to Google Cloud Storage."
  BASE="$BASE_FALLBACK"
  probe="$(curl -fsSL "${BASE}/${CHANNEL}" 2>/dev/null || true)"
fi

# --- resolve version ---
if [ -n "$TARGET" ]; then
  version="$TARGET"
else
  info "Resolving latest '${CHANNEL}' version..."
  version="$(printf '%s' "$probe" | tr -d '\r' | head -n1 | tr -d '[:space:]')"
  [ -n "$version" ] || die "could not fetch latest version from ${BASE_PRIMARY} or ${BASE_FALLBACK}."
fi
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9._]+)?$ ]] \
  || die "invalid version format: '$version' (expected X.Y.Z)."

# --- short-circuit if already at this version ---
stamp="$SCRIPT_DIR/.grok/version"
if [ -x "$BIN_DIR/grok" ] && [ -f "$stamp" ] && [ "$(cat "$stamp" 2>/dev/null)" = "$version" ]; then
  ok "grok $version ($platform) already installed at $BIN_DIR/grok"
  exit 0
fi

info "Installing Grok $version ($platform, channel=$CHANNEL)"
mkdir -p "$BIN_DIR" "$DOWNLOAD_DIR"

artifact="${BASE}/grok-${version}-${platform}"
dest="$DOWNLOAD_DIR/grok-${platform}"
tmp="${dest}.tmp.$$"
trap 'rm -f "$tmp"' EXIT

info "Downloading $artifact"
if ! curl -fL --progress-bar -o "$tmp" "$artifact"; then
  info "primary download failed — retrying from GCS fallback"
  curl -fL --progress-bar -o "$tmp" "${BASE_FALLBACK}/grok-${version}-${platform}" \
    || die "binary download failed for $platform (version $version)."
fi

chmod +x "$tmp"

# --- sanity check before we replace anything ---
info "Verifying the downloaded binary..."
if ! "$tmp" --version </dev/null >/dev/null 2>&1; then
  die "downloaded grok failed to run; keeping any existing install."
fi

mv -f "$tmp" "$dest"
trap - EXIT
ln -sf "$dest" "$BIN_DIR/grok"
ln -sf "$dest" "$BIN_DIR/agent"   # `agent` is the same binary, matching official installs
printf '%s\n' "$version" > "$stamp"

ok "Installed: $("$BIN_DIR/grok" --version 2>/dev/null || echo "grok $version")"
info "Binary:  $BIN_DIR/grok"
info "Run it:  ./bin/grok      (or)   make run"
