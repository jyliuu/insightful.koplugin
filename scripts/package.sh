#!/bin/sh
set -eu

plugin_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
version=$("$plugin_root/scripts/check-version.sh")
output_dir=${1:-"$plugin_root/dist"}
archive_name="insightful.koplugin-v$version.zip"

case "$output_dir" in
    /*) ;;
    *) output_dir="$(pwd)/$output_dir" ;;
esac

stage_root=$(mktemp -d "${TMPDIR:-/tmp}/insightful-package.XXXXXX")
package_root="$stage_root/insightful.koplugin"
archive_path="$output_dir/$archive_name"
trap 'rm -rf "$stage_root"' EXIT HUP INT TERM

mkdir -p "$package_root/providers" "$output_dir"

for source in "$plugin_root"/*.lua; do
    name=${source##*/}
    [ "$name" = "configuration.lua" ] && continue
    cp "$source" "$package_root/$name"
done

for source in "$plugin_root"/providers/*.lua; do
    cp "$source" "$package_root/providers/${source##*/}"
done

for name in VERSION LICENSE NOTICE configuration.lua.sample; do
    [ -f "$plugin_root/$name" ] || {
        printf '%s\n' "package failed: $name is missing" >&2
        exit 1
    }
    cp "$plugin_root/$name" "$package_root/$name"
done

find "$package_root" -exec touch -t 198001010000 {} +
rm -f "$archive_path"
(
    cd "$stage_root"
    find insightful.koplugin -type f -print | LC_ALL=C sort | zip -X -q "$archive_path" -@
)

unzip -Z1 "$archive_path" | grep -Eq '^insightful\.koplugin/_meta\.lua$' || {
    printf '%s\n' "package failed: _meta.lua is missing from the archive" >&2
    exit 1
}
unzip -Z1 "$archive_path" | grep -Eq '^insightful\.koplugin/main\.lua$' || {
    printf '%s\n' "package failed: main.lua is missing from the archive" >&2
    exit 1
}
unzip -Z1 "$archive_path" | grep -Eq '^insightful\.koplugin/providers/registry\.lua$' || {
    printf '%s\n' "package failed: providers/registry.lua is missing from the archive" >&2
    exit 1
}
if unzip -Z1 "$archive_path" | grep -Ev '^insightful\.koplugin/([^/]+|providers/[^/]+\.lua)$' >/dev/null; then
    printf '%s\n' "package failed: the archive contains an unexpected path" >&2
    exit 1
fi
if unzip -Z1 "$archive_path" | grep -Eq '(^|/)configuration\.lua$'; then
    printf '%s\n' "package failed: the private configuration file is present" >&2
    exit 1
fi

printf '%s\n' "$archive_path"
