#!/usr/bin/env bash
set -euo pipefail

SCRIPT_URL="${MINIAGENT_SCRIPT_URL:-https://miniagent.sh}"
INSTALL_DIR="${MINIAGENT_INSTALL_DIR:-$HOME/.local/bin}"
TARGET="$INSTALL_DIR/miniagent"

say() { printf 'miniagent: %s\n' "$*" >&2; }
die() { say "$*"; exit 1; }
has() { command -v "$1" >/dev/null 2>&1; }

run_as_root() {
  if [[ $(id -u) -eq 0 ]]; then
    "$@"
  elif has sudo; then
    sudo "$@"
  else
    die "installing dependencies requires root access or sudo"
  fi
}

missing_has() {
  local wanted item
  wanted=$1
  for item in "${MISSING[@]}"; do
    [[ "$item" == "$wanted" ]] && return 0
  done
  return 1
}

add_package() {
  local wanted item
  wanted=$1
  for item in "${PACKAGES[@]}"; do
    [[ "$item" == "$wanted" ]] && return 0
  done
  PACKAGES+=("$wanted")
}

install_dependencies() {
  local command_name os manager core_command
  local -a required_commands
  required_commands=(
    bash curl jq awk base64 cat chmod cp date find head mkdir mktemp mv rm sort
    stty tail tr uname wc sed nl
  )
  MISSING=()
  for command_name in "${required_commands[@]}"; do
    has "$command_name" || MISSING+=("$command_name")
  done

  [[ ${#MISSING[@]} -gt 0 ]] || return 0
  say "installing missing dependencies: ${MISSING[*]}"

  os=$(uname -s)
  manager=""
  if [[ "$os" == "Darwin" ]]; then
    has brew || die "Homebrew is required to install: ${MISSING[*]} (https://brew.sh)"
    manager=brew
  elif [[ "$os" == "Linux" ]]; then
    for manager in apt-get dnf yum pacman apk zypper; do
      has "$manager" && break
      manager=""
    done
    [[ -n "$manager" ]] || die "no supported package manager found for: ${MISSING[*]}"
  else
    die "automatic dependency installation is not supported on $os"
  fi

  PACKAGES=()
  missing_has jq && add_package jq
  missing_has awk && add_package gawk
  missing_has find && add_package findutils
  if missing_has sed; then
    [[ "$manager" == "brew" ]] && add_package gnu-sed || add_package sed
  fi
  for core_command in base64 cat chmod cp date head mkdir mktemp mv rm sort stty tail tr uname wc nl; do
    if missing_has "$core_command"; then
      add_package coreutils
      break
    fi
  done
  missing_has bash && add_package bash
  missing_has curl && add_package curl

  case "$manager" in
    brew) brew install "${PACKAGES[@]}" ;;
    apt-get)
      run_as_root apt-get update
      run_as_root apt-get install -y "${PACKAGES[@]}"
      ;;
    dnf) run_as_root dnf install -y "${PACKAGES[@]}" ;;
    yum) run_as_root yum install -y "${PACKAGES[@]}" ;;
    pacman) run_as_root pacman -Sy --needed --noconfirm "${PACKAGES[@]}" ;;
    apk) run_as_root apk add --no-cache "${PACKAGES[@]}" ;;
    zypper) run_as_root zypper --non-interactive install "${PACKAGES[@]}" ;;
  esac

  MISSING=()
  for command_name in "${required_commands[@]}"; do
    has "$command_name" || MISSING+=("$command_name")
  done
  [[ ${#MISSING[@]} -eq 0 ]] || die "still missing after package installation: ${MISSING[*]}"
}

if [[ ${BASH_VERSINFO[0]} -lt 3 ]]; then
  die "Bash 3.2 or newer is required"
fi

if [[ "${MINIAGENT_SKIP_DEPENDENCY_INSTALL:-0}" != "1" ]]; then
  install_dependencies
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
