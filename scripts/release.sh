#!/usr/bin/env bash
# Builds the release zips for a tag (docs/RELEASE.md, decision D1): MacMax-X.Y.Z-adhoc.zip, universal and ad hoc
# signed, the same bytes every time; and MacMax-X.Y.Z.zip, the same app signed with the pinned certificate
# (Support/toolchain), which users install so Full Disk Access outlives updates. A signature carries its signing
# time, so only the ad hoc zip is reproducible. Writes both and dist/SHA256SUMS; publishing is the owner's step.
#   release.sh <X.Y.Z> [--verify] [--adhoc-only] [--out <dir>] [--scratch <dir>] [--ref <rev>]
#   --verify   builds a second time somewhere else and fails if one byte of the ad hoc zip differs
#   --adhoc-only  only the reproducible zip, no certificate needed: for anyone checking a release (CI included)
#   --out      where the zip and SHA256SUMS go (default dist/)
#   --scratch  where the build trees go (default $HOME/.cache/macmax-release; never inside the repo)
#   --ref      build this revision instead of the tag vX.Y.Z (a trial run: the output says it is not a release)
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd -P)
cd "$repo"

fail() { echo "release: $*" >&2; exit 1; }

version=${1:-}
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "usage: release.sh <X.Y.Z> [--verify] [--out <dir>] [--scratch <dir>] [--ref <rev>]"
shift
verify=0
adhoc_only=0
out=$repo/dist
scratch=$HOME/.cache/macmax-release
ref=v$version
while (($#)); do
  case $1 in
    --verify) verify=1 ;;
    --adhoc-only) adhoc_only=1 ;;
    --out) out=$2; shift ;;
    --scratch) scratch=$2; shift ;;
    --ref) ref=$2; shift ;;
    *) fail "unknown option $1" ;;
  esac
  shift
done

[[ -z $(git status --porcelain) ]] || fail "the working tree is not clean"
[[ $(git rev-parse --is-shallow-repository) == false ]] || fail "a shallow clone gives another build number: fetch the full history"
commit=$(git rev-parse --verify "$ref^{commit}" 2>/dev/null) || fail "$ref does not exist"
[[ $commit == "$(git rev-parse HEAD)" ]] || fail "HEAD is not $ref: check out the revision to release"
pin=$(awk '$1 == "xcode-build" { print $2 }' Support/toolchain)
have=$(xcodebuild -version | awk '/^Build version/ { print $3 }')
[[ -n $pin && $pin == "$have" ]] || fail "Xcode build is '$have', this release is pinned to '$pin' (Support/toolchain)"
certificate=$(awk '$1 == "signing-certificate" { print $2 }' Support/toolchain)
[[ $certificate =~ ^[0-9A-F]{40}$ ]] || fail "Support/toolchain pins no signing-certificate"
if ((!adhoc_only)); then
  # Captured first: grep -q closing the pipe early would fail the pipeline under pipefail.
  identities=$(security find-identity -p codesigning 2>/dev/null || true)
  [[ $identities == *"$certificate"* ]] || fail "the signing certificate $certificate is not in this keychain: a release signed with another one would make every user grant Full Disk Access again"
fi

epoch=$(git log -1 --format=%ct "$commit")
number=$(git rev-list --count "$commit")
stamp=$(TZ=UTC date -r "$epoch" +%Y%m%d%H%M.%S)

# Fixed modes, no extended attributes, the tag's time on every file, then a zip with sorted entries, no extra
# attributes and no directory entries: the same input gives the same zip. $1 the app, $2 the zip.
pack() {
  local app=$1 zip=$2
  chmod -R u=rwX,go=rX "$app"
  xattr -cr "$app"
  find "$app" -print0 | TZ=UTC xargs -0 touch -h -t "$stamp"
  rm -f "$zip"
  (cd "$(dirname "$app")" && find MacMax.app | LC_ALL=C sort | TZ=UTC zip -q -X -D -y "$zip" -@)
}

# One build from a clean export of the revision, in $1. Prints the zip path.
build_zip() {
  local dir=$1 app zip
  rm -rf "$dir"
  mkdir -p "$dir/src"
  git archive "$commit" | tar -x -C "$dir/src"
  app=$(cd "$dir/src" && SOURCE_DATE_EPOCH=$epoch scripts/bundle.sh --universal --version "$version" --build "$number" \
    --source "$ref" --scratch "$dir/scratch" --out "$dir/out") || fail "the build failed"
  [[ -d $app ]] || fail "the build produced no app"
  zip=$dir/MacMax-$version-adhoc.zip
  pack "$app" "$zip"
  echo "$zip"
}

# The ad hoc zip's app signed with the pinned certificate, CLI first, as bundle.sh signs. Prints the zip path.
sign_zip() {
  local adhoc=$1 dir=$2 app zip requirement
  rm -rf "$dir"
  mkdir -p "$dir"
  ditto -x -k "$adhoc" "$dir" || fail "could not unpack $adhoc"
  app=$dir/MacMax.app
  codesign --force --timestamp=none --sign "$certificate" "$app/Contents/Resources/macmax" >&2 || fail "could not sign the CLI"
  codesign --force --timestamp=none --sign "$certificate" "$app" >&2 || fail "could not sign the app"
  codesign --verify --strict --deep "$app" || fail "the signed app does not verify"
  requirement=$(codesign -d -r- "$app" 2>&1)
  [[ $requirement == *"certificate leaf = H\"$(tr 'A-F' 'a-f' <<< "$certificate")\""* ]] \
    || fail "the signed app's designated requirement does not name the pinned certificate"
  zip=$dir/MacMax-$version.zip
  pack "$app" "$zip"
  echo "$zip"
}

first=$(build_zip "$scratch/a")
if ((verify)); then
  second=$(build_zip "$scratch/b")
  cmp "$first" "$second" || fail "two builds of $ref differ: the release is not reproducible"
  echo "release: two builds are identical"
fi

mkdir -p "$out"
cp "$first" "$out/MacMax-$version-adhoc.zip"
if ((adhoc_only)); then
  # No MacMax-X.Y.Z.zip at all: a leftover from an earlier run must not sit beside these sums.
  rm -f "$out/MacMax-$version.zip"
  (cd "$out" && shasum -a 256 "MacMax-$version-adhoc.zip" > SHA256SUMS)
  echo "release: $out/MacMax-$version-adhoc.zip (reproducible; not signed, not for publishing)"
else
  signed=$(sign_zip "$first" "$scratch/signed")
  cp "$signed" "$out/MacMax-$version.zip"
  (cd "$out" && shasum -a 256 "MacMax-$version.zip" "MacMax-$version-adhoc.zip" > SHA256SUMS)
  echo "release: $out/MacMax-$version.zip (signed), $out/MacMax-$version-adhoc.zip (reproducible)"
fi
cat "$out/SHA256SUMS"
[[ $ref == "v$version" ]] || echo "release: NOT A RELEASE: built from $ref, not the tag v$version" >&2
