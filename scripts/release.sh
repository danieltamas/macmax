#!/usr/bin/env bash
# Builds the release zip for a tag: universal, ad hoc signed (docs/RELEASE.md, decision D1), the same
# bytes every time. Writes dist/MacMax-X.Y.Z.zip and dist/SHA256SUMS; publishing is the owner's step.
#   release.sh <X.Y.Z> [--verify] [--out <dir>] [--scratch <dir>] [--ref <rev>]
#   --verify   builds a second time somewhere else and fails if one byte differs
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
out=$repo/dist
scratch=$HOME/.cache/macmax-release
ref=v$version
while (($#)); do
  case $1 in
    --verify) verify=1 ;;
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

epoch=$(git log -1 --format=%ct "$commit")
number=$(git rev-list --count "$commit")
stamp=$(TZ=UTC date -r "$epoch" +%Y%m%d%H%M.%S)

# One build from a clean export of the revision, in $1. Prints the zip path.
build_zip() {
  local dir=$1 app zip
  rm -rf "$dir"
  mkdir -p "$dir/src"
  git archive "$commit" | tar -x -C "$dir/src"
  app=$(cd "$dir/src" && SOURCE_DATE_EPOCH=$epoch scripts/bundle.sh --universal --version "$version" --build "$number" \
    --source "$ref" --scratch "$dir/scratch" --out "$dir/out") || fail "the build failed"
  [[ -d $app ]] || fail "the build produced no app"
  chmod -R u=rwX,go=rX "$app"
  xattr -cr "$app"
  find "$app" -print0 | TZ=UTC xargs -0 touch -h -t "$stamp"
  zip=$dir/MacMax-$version.zip
  # Sorted entries, no extra attributes and no directory entries: the same input gives the same zip.
  (cd "$(dirname "$app")" && find MacMax.app | LC_ALL=C sort | TZ=UTC zip -q -X -D -y "$zip" -@)
  echo "$zip"
}

first=$(build_zip "$scratch/a")
if ((verify)); then
  second=$(build_zip "$scratch/b")
  cmp "$first" "$second" || fail "two builds of $ref differ: the release is not reproducible"
  echo "release: two builds are identical"
fi

mkdir -p "$out"
cp "$first" "$out/MacMax-$version.zip"
(cd "$out" && shasum -a 256 "MacMax-$version.zip" > SHA256SUMS)
echo "release: $out/MacMax-$version.zip"
cat "$out/SHA256SUMS"
[[ $ref == "v$version" ]] || echo "release: NOT A RELEASE: built from $ref, not the tag v$version" >&2
