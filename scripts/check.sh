#!/usr/bin/env bash
# The gate every change passes: build, the full test suite, the 500-line limit on Swift files, and
# the plain-ASCII-punctuation lint on README.md, docs/ and Sources/.
#   --scratch <dir>  SwiftPM scratch path (default $HOME/.cache/macmax-build; never inside the repo)
#   --root <dir>     the tree to lint (default: this checkout), so tests can lint a fixture
#   --lint-only      skip the build and the tests
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd -P)
scratch=${SCRATCH:-$HOME/.cache/macmax-build}
root=$repo
lint_only=0
while (($#)); do
  case $1 in
    --scratch) scratch=$2; shift ;;
    --root) root=$2; shift ;;
    --lint-only) lint_only=1 ;;
    *) echo "usage: check.sh [--scratch <dir>] [--root <dir>] [--lint-only]" >&2; exit 2 ;;
  esac
  shift
done

failed=0
fail() { echo "check: $*" >&2; failed=1; }

# A Swift file over 500 lines is split before it is merged.
lint_size() {
  local dirs=() dir files file lines
  for dir in Sources Tests; do
    [[ -d $root/$dir ]] && dirs+=("$root/$dir")
  done
  ((${#dirs[@]})) || return 0
  files=$(find "${dirs[@]}" -name '*.swift' -type f -print0 | tr '\0' '\n') \
    || { fail "cannot list Swift files under $root"; return; }
  while IFS= read -r file; do
    [[ -n $file ]] || continue
    # awk counts a last line that has no trailing newline; wc -l does not.
    lines=$(awk 'END { print NR }' "$file")
    ((lines <= 500)) || fail "${file#"$root"/} has $lines lines (limit 500)"
  done <<< "$files"
}

# En and em dashes, curly quotes, the ellipsis, NBSP and invisible characters read as machine
# text and break copy-paste; user-facing text and docs use - " ' and ... only.
lint_ascii() {
  local targets=() path hits
  for path in README.md docs Sources; do
    [[ -e $root/$path ]] && targets+=("$root/$path")
  done
  ((${#targets[@]})) || return 0
  local list
  list=$(find "${targets[@]}" -type f \( -name '*.md' -o -name '*.swift' \) -print0 | tr '\0' '\n') \
    || { fail "cannot list the files to lint"; return; }
  # A failure of the scan itself fails the gate: only a clean run with no hits passes.
  hits=$(printf '%s\n' "$list" | tr '\n' '\0' | xargs -0 perl -CSD -ne 'print "$ARGV:$.: non-ASCII punctuation\n" if /[\x{2010}-\x{2015}\x{2018}-\x{201F}\x{2026}\x{00A0}\x{00AD}\x{200B}-\x{200F}\x{202A}-\x{202E}\x{2060}\x{FEFF}]/; close ARGV if eof') \
    || { fail "the punctuation scan failed"; return; }
  if [[ -n $hits ]]; then
    echo "${hits//"$root"\//}" >&2
    fail "non-ASCII punctuation found"
  fi
}

# Every image the README shows exists, and every install.sh option it names is one the script has: a broken
# picture or a command that fails is the first thing a new user meets.
lint_readme() {
  local readme=$root/README.md ref flag
  [[ -f $readme ]] || return 0
  while IFS= read -r ref; do
    [[ -n $ref ]] || continue
    [[ -f $root/$ref ]] || fail "README.md shows $ref, which does not exist"
  done < <(grep -oE 'docs/media/[A-Za-z0-9._-]+\.png' "$readme" | sort -u)
  [[ -f $root/install.sh ]] || return 0
  while IFS= read -r flag; do
    [[ -n $flag ]] || continue
    grep -q -- "$flag" "$root/install.sh" || fail "README.md names install.sh option $flag, which the script does not have"
  done < <(grep -E 'bash -s --|--uninstall|--purge' "$readme" | grep -oE -- '--[a-z-]+' | sort -u | grep -v -- '^--$')
}

lint_size
lint_ascii
lint_readme

if ((!lint_only)); then
  cd "$repo"
  swift build --build-tests --scratch-path "$scratch" || fail "build failed"
  swift test --skip-build --scratch-path "$scratch" || fail "tests failed"
fi

((!failed)) && echo "check: ok"
exit $failed
