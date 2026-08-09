#!/bin/sh
set -eu

plugin_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
current=$("$plugin_root/scripts/check-version.sh")
request=${1:-}

usage() {
    printf '%s\n' "usage: $0 patch|minor|major|X.Y.Z[-prerelease]" >&2
    exit 2
}

[ -n "$request" ] || usage

base=${current%%-*}
major=${base%%.*}
rest=${base#*.}
minor=${rest%%.*}
patch=${rest#*.}

case "$request" in
    patch)
        next="$major.$minor.$((patch + 1))"
        ;;
    minor)
        next="$major.$((minor + 1)).0"
        ;;
    major)
        next="$((major + 1)).0.0"
        ;;
    *)
        next=${request#v}
        ;;
esac

semver_pattern='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$'
printf '%s\n' "$next" | grep -Eq "$semver_pattern" || usage
[ "$next" != "$current" ] || {
    printf '%s\n' "version is already $current" >&2
    exit 1
}

version_tmp=$(mktemp "${TMPDIR:-/tmp}/insightful-version.XXXXXX")
meta_tmp=$(mktemp "${TMPDIR:-/tmp}/insightful-meta.XXXXXX")
trap 'rm -f "$version_tmp" "$meta_tmp"' EXIT HUP INT TERM

printf '%s\n' "$next" > "$version_tmp"
sed -E "s/^([[:space:]]*version[[:space:]]*=[[:space:]]*)\"[^\"]+\"/\\1\"$next\"/" \
    "$plugin_root/_meta.lua" > "$meta_tmp"

next_meta_version=$(sed -nE 's/^[[:space:]]*version[[:space:]]*=[[:space:]]*"([^"]+)"[[:space:]]*,?[[:space:]]*$/\1/p' "$meta_tmp")
[ "$next_meta_version" = "$next" ] || {
    printf '%s\n' "could not update the version in _meta.lua" >&2
    exit 1
}

chmod 644 "$version_tmp" "$meta_tmp"

mv "$version_tmp" "$plugin_root/VERSION"
mv "$meta_tmp" "$plugin_root/_meta.lua"
trap - EXIT HUP INT TERM

"$plugin_root/scripts/check-version.sh" "$next" >/dev/null
printf '%s\n' "updated Insightful from $current to $next"
printf '%s\n' "commit VERSION and _meta.lua, then tag that commit as v$next"
