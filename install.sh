#!/usr/bin/env bash
# Installs MacMax on this Mac:
#
#   install.sh                                the latest release (MACMAX_VERSION=X.Y.Z pins one)
#   install.sh --app <path to MacMax.app>     a local build (scripts/install-from-source.sh)
#
# A release is downloaded with its SHA256SUMS and installed only when the checksum matches.
# Everything runs from main, called on the last line: a download cut short defines nothing and
# runs nothing.
set -euo pipefail

fail() { echo "macmax: $*" >&2; exit 1; }

# /Applications when this user can write it, else ~/Applications, so a non-admin installs without
# a password. An existing install keeps its location.
destination() {
  # The updater names the folder of the copy that is running, so the running copy is the one replaced.
  case ${MACMAX_INSTALL_ROOT:-} in
    /Applications|"$HOME/Applications") mkdir -p "${MACMAX_INSTALL_ROOT}" && echo "$MACMAX_INSTALL_ROOT"; return ;;
  esac
  if [[ -d /Applications/MacMax.app ]]; then echo /Applications
  elif [[ -d $HOME/Applications/MacMax.app ]]; then echo "$HOME/Applications"
  elif [[ -w /Applications ]]; then echo /Applications
  else mkdir -p "$HOME/Applications" && echo "$HOME/Applications"
  fi
}

repo=danieltamas/macmax
work=   # the download folder, global so the exit trap can remove it
fetch() { curl -fsSL --connect-timeout 20 --speed-limit 1024 --speed-time 60 "$@"; }

# The version to install: MACMAX_VERSION when set (X.Y.Z only), else the tag GitHub redirects "latest" to.
release_version() {
  local version=${MACMAX_VERSION:-} url
  if [[ -z $version ]]; then
    url=$(curl -fsSLI --connect-timeout 20 -o /dev/null -w '%{url_effective}' "https://github.com/$repo/releases/latest") \
      || fail "could not look up the latest release"
    version=${url##*/tag/v}
  fi
  [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "not a release version: $version"
  echo "$version"
}

# Downloads MacMax-X.Y.Z.zip and SHA256SUMS into $2, checks the zip against exactly one matching line, and unpacks it.
# Sets $app to the unpacked MacMax.app.
download_release() {
  local version=$1 dir=$2 base zip sums line
  base=https://github.com/$repo/releases/download/v$version
  zip=MacMax-$version.zip
  fetch -o "$dir/$zip" "$base/$zip" || fail "could not download $zip"
  fetch -o "$dir/SHA256SUMS" "$base/SHA256SUMS" || fail "could not download SHA256SUMS"
  line=$(awk -v zip="$zip" 'NF == 2 && $2 == zip && $1 ~ /^[0-9a-f]{64}$/' "$dir/SHA256SUMS" || true)
  [[ $(printf '%s\n' "$line" | grep -c .) -eq 1 ]] || fail "SHA256SUMS has no single line for $zip"
  [[ $(shasum -a 256 "$dir/$zip" | cut -d' ' -f1) == "${line%% *}" ]] || fail "$zip does not match its checksum: not installing"
  ditto -x -k "$dir/$zip" "$dir/unpacked" || fail "could not unpack $zip"
  app=$dir/unpacked/MacMax.app
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
# refusal leaves the old install as it was. The CLI carries the marker `macmax-cli:` (the first build kept it only inside the code, so its usage line is accepted too).
cli_link=$HOME/.local/bin/macmax
check_cli_slot() {
  local text
  # Read in full before matching: grep -q closing the pipe early would fail the pipeline.
  [[ -e $cli_link ]] && text=$(strings "$cli_link" 2>/dev/null || true)
  # -L too: a dangling link is somebody's file, not ours to replace.
  if [[ -e $cli_link || -L $cli_link ]] && [[ ${text:-} != *'macmax-cli:'* && ${text:-} != *'usage: macmax audit'* ]]; then
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
  mkdir "$lock.takeover" 2>/dev/null || fail "another MacMax install is running (or a crashed one left $lock*: remove it)"
  local other
  other=$(readlink "$lock" || true)
  if [[ $other =~ ^[0-9]+$ ]] && kill -0 "$other" 2>/dev/null; then
    rmdir "$lock.takeover"
    fail "another MacMax install is running (or a crashed one left $lock*: remove it)"
  fi
  rm -f "$lock"
  ln -s "$$" "$lock" 2>/dev/null || { rmdir "$lock.takeover"; fail "another MacMax install is running (or a crashed one left $lock*: remove it)"; }
  rmdir "$lock.takeover"
}

# Removes the lock only while it is this install's, and the staged CLI.
cleanup() {
  if [[ -n $work ]]; then rm -rf "$work"; fi
  if [[ $(readlink "${lock:-}" 2>/dev/null) == "$$" ]]; then rm -f "$lock"; fi
  rm -f "$cli_link.new"
}

main() {
  [[ $(uname -s) == Darwin ]] || fail "MacMax runs on macOS only"
  (($(sw_vers -productVersion | cut -d. -f1) >= 14)) || fail "MacMax needs macOS 14 or newer"
  local app
  if [[ ${1:-} == --app && -d ${2:-} ]]; then
    app=$2
  elif [[ $# -eq 0 ]]; then
    work=$(mktemp -d)
    trap cleanup EXIT
    download_release "$(release_version)" "$work"
  else
    fail "usage: install.sh [--app <path to MacMax.app>]"
  fi
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
