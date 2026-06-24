#!/usr/bin/env bash
# Shared helpers for devspace-kit.

set -euo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="${DEVSPACE_KIT_STATE:-$KIT_ROOT/state}"
TUNNEL_LOG="$STATE_DIR/tunnel.log"
SERVE_LOG="$STATE_DIR/serve.log"
TUNNEL_PID_FILE="$STATE_DIR/tunnel.pid"
SERVE_PID_FILE="$STATE_DIR/serve.pid"
URL_FILE="$STATE_DIR/public_url"
PORT="${DEVSPACE_PORT:-7676}"

mkdir -p "$STATE_DIR"

log()  { printf '\033[1;36m[devspace-kit]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[devspace-kit]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31m[devspace-kit]\033[0m %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

load_nvm() {
  export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
  # shellcheck disable=SC1091
  [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" >/dev/null 2>&1 || true
}

have() { command -v "$1" >/dev/null 2>&1; }

pid_alive() { [ -n "${1:-}" ] && kill -0 "$1" >/dev/null 2>&1; }

read_pid() { [ -f "$1" ] && cat "$1" 2>/dev/null || true; }
