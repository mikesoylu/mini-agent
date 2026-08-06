#!/usr/bin/env bash
# miniagent installer: https://github.com/mikesoylu/miniagent
set -euo pipefail

SCRIPT_URL="${MINIAGENT_SCRIPT_URL:-https://miniagent.sh}"
INSTALL_DIR="${MINIAGENT_INSTALL_DIR:-$HOME/.local/bin}"
DEPENDENCY_DIR="${MINIAGENT_DEPENDENCY_DIR:-${XDG_CACHE_HOME:-${HOME:-${TMPDIR:-/tmp}}/.cache}/miniagent/bin}"
TARGET="$INSTALL_DIR/miniagent"
JQ_VERSION="1.7.1"
MODE="install"

say() { printf 'miniagent: %s\n' "$*" >&2; }
die() { say "$*"; exit 1; }
has() { command -v "$1" >/dev/null 2>&1; }

case "${1:-}" in
  "") ;;
  --dependencies-only)
    MODE="dependencies-only"
    shift
    ;;
  -h|--help)
    printf '%s\n' "Usage: install.sh [--dependencies-only]"
    exit 0
    ;;
  *) die "unknown option: $1" ;;
esac
[[ $# -eq 0 ]] || die "unexpected arguments: $*"

download_jq() {
  local destination destination_dir os architecture asset url temporary_file
  destination=$1
  destination_dir=${destination%/*}
  os=$(uname -s)
  architecture=$(uname -m)

  case "$os:$architecture" in
    Linux:x86_64|Linux:amd64) asset="jq-linux-amd64" ;;
    Linux:aarch64|Linux:arm64) asset="jq-linux-arm64" ;;
    Darwin:x86_64|Darwin:amd64) asset="jq-macos-amd64" ;;
    Darwin:arm64|Darwin:aarch64) asset="jq-macos-arm64" ;;
    *) die "no prebuilt jq is available for $os/$architecture" ;;
  esac

  url="${MINIAGENT_JQ_URL:-https://github.com/jqlang/jq/releases/download/jq-$JQ_VERSION/$asset}"
  mkdir -p "$destination_dir"
  temporary_file=$(mktemp "$destination_dir/.jq.XXXXXX")
  trap 'rm -f "$temporary_file"' EXIT
  say "downloading jq $JQ_VERSION for $os/$architecture"
  curl -fsSL "$url" -o "$temporary_file"
  chmod 0755 "$temporary_file"
  "$temporary_file" --version >/dev/null 2>&1 || die "downloaded jq failed validation"
  mv -f "$temporary_file" "$destination"
  trap - EXIT
}

ensure_dependencies() {
  local command_name jq_destination
  local -a required_commands missing_commands
  required_commands=(
    bash curl awk base64 cat chmod cp date find head mkdir mktemp mv rm sort
    stty tail tr uname wc sed nl
  )
  missing_commands=()
  for command_name in "${required_commands[@]}"; do
    has "$command_name" || missing_commands+=("$command_name")
  done
  if [[ ${#missing_commands[@]} -gt 0 ]]; then
    die "required standard Unix commands not found: ${missing_commands[*]}"
  fi

  if has jq && [[ "${MINIAGENT_FORCE_LOCAL_JQ:-0}" != "1" ]]; then
    return 0
  fi

  if [[ "$MODE" == "dependencies-only" ]]; then
    jq_destination="$DEPENDENCY_DIR/jq"
  else
    jq_destination="$INSTALL_DIR/jq"
  fi
  if [[ ! -x "$jq_destination" ]] || ! "$jq_destination" --version >/dev/null 2>&1; then
    download_jq "$jq_destination"
  fi
}

if [[ ${BASH_VERSINFO[0]} -lt 3 ]]; then
  die "Bash 3.2 or newer is required"
fi

if [[ "${MINIAGENT_SKIP_DEPENDENCY_INSTALL:-0}" != "1" ]]; then
  ensure_dependencies
fi

if [[ "$MODE" == "dependencies-only" ]]; then
  say "dependencies are ready"
  exit 0
fi

mkdir -p "$INSTALL_DIR"
temporary_file=$(mktemp "$INSTALL_DIR/.miniagent.XXXXXX")
trap 'rm -f "$temporary_file"' EXIT

curl -fsSL "$SCRIPT_URL" -o "$temporary_file"
bash -n "$temporary_file" || die "downloaded script failed validation"
chmod 0755 "$temporary_file"
mv -f "$temporary_file" "$TARGET"
trap - EXIT

say "installed $TARGET"
case ":$PATH:" in
  *":$INSTALL_DIR:"*) ;;
  *) say "add $INSTALL_DIR to PATH to run: miniagent" ;;
esac
