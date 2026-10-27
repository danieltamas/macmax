#!/usr/bin/env bash
# Points the Homebrew cask (danieltamas/homebrew-tap, Casks/macmax.rb) at a published release:
# version and sha256 from dist/SHA256SUMS, checked against the bytes GitHub serves before anything
# is committed, one commit on the tap's main, then `brew fetch` proves the cask installs from the
# tap. Runs from the release's verify step (docs/RELEASE.md).
#   scripts/tap.sh <X.Y.Z> [--sums <file>] [--tap <dir>]
set -euo pipefail

fail() { echo "tap: $*" >&2; exit 1; }

version=${1:-}; shift || true
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "usage: tap.sh <X.Y.Z> [--sums <file>] [--tap <dir>]"
sums=dist/SHA256SUMS
tap=${MACMAX_TAP_DIR:-${TMPDIR:-/tmp}/macmax-tap}
while (($#)); do
  case $1 in
    --sums) sums=$2; shift ;;
    --tap) tap=$2; shift ;;
    *) fail "unknown option $1" ;;
  esac
  shift
done

asset=MacMax-$version.zip
url=https://github.com/danieltamas/macmax/releases/download/v$version/$asset
sha=$(awk -v name="$asset" '$2 == name { print $1 }' "$sums")
[[ $sha =~ ^[0-9a-f]{64}$ ]] || fail "no checksum for $asset in $sums"

# The pin is checked against what GitHub serves, not against the local build: a replaced asset or a
# stale SHA256SUMS must stop here, before the tap changes.
scratch=$(mktemp -d "${TMPDIR:-/tmp}/macmax-tap-check.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
curl -fsSL --retry 3 -o "$scratch/$asset" "$url" || fail "cannot download $url; publish the release first"
served=$(shasum -a 256 "$scratch/$asset" | awk '{ print $1 }')
[[ $served == "$sha" ]] || fail "$asset served by GitHub has sha256 $served, SHA256SUMS says $sha: not pinning"

if [[ -d $tap/.git ]]; then
  git -C "$tap" fetch -q origin main && git -C "$tap" reset -q --hard origin/main
else
  gh repo clone danieltamas/homebrew-tap "$tap" -- -q
fi
cask=$tap/Casks/macmax.rb
[[ -f $cask ]] || fail "$cask is missing"
# Only the two pinned lines change; the stanza order, comments and steps stay as reviewed.
sed -i '' -e "s/^  version \".*\"/  version \"$version\"/" -e "s/^  sha256 \".*\"/  sha256 \"$sha\"/" "$cask"
grep -q "version \"$version\"" "$cask" && grep -q "sha256 \"$sha\"" "$cask" || fail "the cask did not take the new pins"

if git -C "$tap" diff --quiet; then
  echo "tap: macmax $version already pinned"
else
  git -C "$tap" commit -q -am "macmax $version" --author "Daniel Tamas <hello@danieltamas.ro>"
  git -C "$tap" push -q origin main
  echo "tap: pushed macmax $version ($sha)"
fi

# What a user's Homebrew does with the pushed cask. Homebrew 7 loads a third-party cask outside
# `install` only once it is trusted; this is our own tap.
command -v brew >/dev/null || fail "brew is not installed here, so the cask was pushed but not fetched through Homebrew"
brew tap -q danieltamas/tap >/dev/null
# The local tap checkout is moved to the pushed commit itself: a stale checkout would make
# `brew fetch` validate the previous cask and call it a pass.
tapped=$(brew --repository danieltamas/tap)
git -C "$tapped" fetch -q origin main && git -C "$tapped" reset -q --hard origin/main \
  || fail "could not update Homebrew's checkout of the tap at $tapped"
grep -q "sha256 \"$sha\"" "$tapped/Casks/macmax.rb" || fail "Homebrew's checkout of the tap does not carry the pushed pin"
brew trust --cask danieltamas/tap/macmax >/dev/null
brew fetch -q --cask danieltamas/tap/macmax >/dev/null || fail "brew fetch rejected the pushed cask"
echo "tap: brew fetch ok: brew install --cask danieltamas/tap/macmax"
