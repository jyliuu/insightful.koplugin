#!/bin/sh
set -eu

plugin_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
version_file="$plugin_root/VERSION"
meta_file="$plugin_root/_meta.lua"

fail() {
    printf '%s\n' "version check failed: $*" >&2
    exit 1
}

[ -f "$version_file" ] || fail "VERSION is missing"
[ -f "$meta_file" ] || fail "_meta.lua is missing"

version=$(sed -n '1p' "$version_file")
[ -n "$version" ] || fail "VERSION is empty"
[ "$(wc -l < "$version_file" | tr -d ' ')" = "1" ] || fail "VERSION must contain one line"

semver_pattern='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$'
printf '%s\n' "$version" | grep -Eq "$semver_pattern" || fail "VERSION must use X.Y.Z or X.Y.Z-prerelease"

meta_version=$(sed -nE 's/^[[:space:]]*version[[:space:]]*=[[:space:]]*"([^"]+)"[[:space:]]*,?[[:space:]]*$/\1/p' "$meta_file")
[ -n "$meta_version" ] || fail "could not read the version from _meta.lua"
[ "$version" = "$meta_version" ] || fail "VERSION is $version but _meta.lua is $meta_version"

if [ "$#" -gt 0 ]; then
    expected=${1#v}
    [ "$version" = "$expected" ] || fail "the release tag expects $expected but VERSION is $version"
fi

printf '%s\n' "$version"
