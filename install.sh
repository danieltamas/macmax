#!/usr/bin/env bash
# Installs MacMax on this Mac. Today it installs a local build:
#
#   install.sh --app <path to MacMax.app>     (scripts/install-from-source.sh)
#
# Downloading and verifying a published release is added with the release unit (docs/RELEASE.md).
# Everything runs from main, called on the last line: a download cut short defines nothing and
# runs nothing.
set -euo pipefail

fail() { echo "macmax: $*" >&2; exit 1; }

# /Applications when this user can write it, else ~/Applications, so a non-admin installs without
# a password. An existing install keeps its location.
destination() {
  if [[ -d /Applications/MacMax.app ]]; then echo /Applications
  elif [[ -d $HOME/Applications/MacMax.app ]]; then echo "$HOME/Applications"
  elif [[ -w /Applications ]]; then echo /Applications
  else mkdir -p "$HOME/Applications" && echo "$HOME/Applications"
  fi
}

# Pids of the processes running exactly $1 (a fixed-string match on the command, not a regex).
# Fails when the process list cannot be read: "nobody runs it" is never assumed.
running_pids() {
  local list
  list=$(ps -axo pid=,command=) || return 1
  awk -v bin="$1" '{ pid = $1; $1 = ""; sub(/^ /, ""); if ($0 == bin || index($0, bin " ") == 1) print pid }' <<< "$list"
}

# Quits the app running from $1 and waits until it is gone (10 s, then KILL and 5 s more). Returns 1
# when it is still there or the process list cannot be read, so the installer stops before touching
# the install.
stop_running() {
  local binary=$1/Contents/MacOS/MacMax pids deadline
  pids=$(running_pids "$binary") || return 1
  [[ -n $pids ]] || return 0
  kill $pids 2>/dev/null || true
  deadline=$((SECONDS + 10))
  while ((SECONDS < deadline)); do
    pids=$(running_pids "$binary") || return 1
    [[ -z $pids ]] && return 0
    sleep 0.2
  done
  kill -KILL $pids 2>/dev/null || true
  deadline=$((SECONDS + 5))
  while ((SECONDS < deadline)); do
    pids=$(running_pids "$binary") || return 1
    [[ -z $pids ]] && return 0
    sleep 0.2
  done
  return 1
}

# The CLI is only ever copied over a previous MacMax CLI. Checked before the app is touched, so a
# refusal leaves the old install as it was. The CLI carries the marker `macmax-cli:`.
cli_link=$HOME/.local/bin/macmax
check_cli_slot() {
  local text
  # Read in full before matching: grep -q closing the pipe early would fail the pipeline.
  [[ -e $cli_link ]] && text=$(strings "$cli_link" 2>/dev/null || true)
  # -L too: a dangling link is somebody's file, not ours to replace.
  if [[ -e $cli_link || -L $cli_link ]] && [[ ${text:-} != *'macmax-cli:'* ]]; then
    fail "$cli_link exists and is not the MacMax command: remove it and run this again"
  fi
}

# The CLI is staged beside its final name before the app is swapped, so a full disk or a bad
# permission stops the install while the old app and CLI are still a consistent pair; the final
# step is one rename.
stage_cli() {
  mkdir -p "$HOME/.local/bin"
  install -m 755 "$1/Contents/Resources/macmax" "$cli_link.new" || fail "could not stage the macmax command in ~/.local/bin"
}

# One install at a time: two would share the staged and the previous app. The lock is a link
# naming the install's pid, made in one step. A lock whose install is gone is taken over by one
# installer only: the takeover is itself a directory made in one step, and the lock is read again
# inside it.
take_lock() {
  lock="${TMPDIR:-/tmp}/macmax-install.lock"
  ln -s "$$" "$lock" 2>/dev/null && return
  mkdir "$lock.takeover" 2>/dev/null || fail "another MacMax install is running"
  local other
  other=$(readlink "$lock" || true)
  if [[ $other =~ ^[0-9]+$ ]] && kill -0 "$other" 2>/dev/null; then
    rmdir "$lock.takeover"
    fail "another MacMax install is running"
  fi
  rm -f "$lock"
  ln -s "$$" "$lock" 2>/dev/null || { rmdir "$lock.takeover"; fail "another MacMax install is running"; }
  rmdir "$lock.takeover"
}

# Removes the lock only while it is this install's, and the staged CLI.
cleanup() {
  if [[ $(readlink "${lock:-}" 2>/dev/null) == "$$" ]]; then rm -f "$lock"; fi
  rm -f "$cli_link.new"
}

main() {
  [[ $(uname -s) == Darwin ]] || fail "MacMax runs on macOS only"
  (($(sw_vers -productVersion | cut -d. -f1) >= 14)) || fail "MacMax needs macOS 14 or newer"
  [[ ${1:-} == --app && -d ${2:-} ]] || fail "usage: install.sh --app <path to MacMax.app>"
  local app=$2
  [[ -x $app/Contents/MacOS/MacMax && -x $app/Contents/Resources/macmax ]] || fail "$app is not a MacMax.app"

  take_lock
  trap cleanup EXIT
  check_cli_slot
  local root target staged previous
  root=$(destination)
  target=$root/MacMax.app staged=$target.new previous=$target.old
  # An install interrupted between its two moves left only the previous app: put it back first.
  if [[ ! -e $target && -e $previous ]]; then mv "$previous" "$target"; fi
  rm -rf "$staged" "$previous"
  stage_cli "$app"
  ditto "$app" "$staged" || { rm -rf "$staged"; fail "could not copy MacMax.app to $root"; }
  stop_running "$target" || { rm -rf "$staged"; fail "could not quit the running MacMax: quit it and run this again"; }
  if [[ -e $target ]]; then mv "$target" "$previous"; fi
  if ! mv "$staged" "$target"; then
    if [[ -e $previous ]]; then mv "$previous" "$target"; fi
    fail "could not replace $target"
  fi
  rm -rf "$previous"
  mv -f "$cli_link.new" "$cli_link" || fail "could not install the macmax command; run this again"
  open "$target"

  echo "Installed MacMax: it lives in the menu bar."
  case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) echo "Add ~/.local/bin to PATH to use the macmax command." ;;
  esac
}

main "$@"
