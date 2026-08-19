#!/bin/sh
set -eu

plugin_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

"$plugin_root/scripts/check-version.sh" >/dev/null

for lua_file in "$plugin_root"/*.lua "$plugin_root"/providers/*.lua "$plugin_root"/tests/*.lua; do
    luac -p "$lua_file"
done
luac -p "$plugin_root/configuration.lua.sample"

# A file that binds `_` to gettext must not rebind `_` as a loop variable,
# local, or parameter. The inner `_` shadows the translation function, so a
# later _("...") call in that scope tries to call a non-function and crashes.
shadowed=""
for lua_file in "$plugin_root"/*.lua "$plugin_root"/providers/*.lua; do
    grep -q 'require("gettext")' "$lua_file" || continue
    hits=$(grep -n 'for[[:space:]]\+_[[:space:]]*[,)]\|local[[:space:]]\+_[[:space:]]*[,=]\|function[^)]*([[:space:]]*_[[:space:]]*[,)]' "$lua_file" \
        | grep -v 'local _ = require("gettext")' || true)
    [ -n "$hits" ] || continue
    shadowed="$shadowed$lua_file\n$hits\n"
done
if [ -n "$shadowed" ]; then
    printf '%s\n' "gettext check failed: these bindings shadow the _ translation function:" >&2
    printf "$shadowed" >&2
    exit 1
fi

luajit "$plugin_root/tests/run.lua"
lua "$plugin_root/tests/run.lua"
