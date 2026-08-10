#!/bin/sh
set -eu

plugin_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

"$plugin_root/scripts/check-version.sh" >/dev/null

for lua_file in "$plugin_root"/*.lua "$plugin_root"/providers/*.lua "$plugin_root"/tests/*.lua; do
    luac -p "$lua_file"
done
luac -p "$plugin_root/configuration.lua.sample"

luajit "$plugin_root/tests/run.lua"
lua "$plugin_root/tests/run.lua"
