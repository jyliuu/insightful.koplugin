#!/bin/sh
set -eu

plugin_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
request=${1:-}
changelog=${2:-"$plugin_root/CHANGELOG.md"}

[ -n "$request" ] || {
    printf '%s\n' "usage: $0 X.Y.Z[-prerelease] [changelog]" >&2
    exit 2
}

version=${request#v}

awk -v heading="## $version (" '
    index($0, heading) == 1 {
        found = 1
        next
    }
    found && /^## / {
        exit
    }
    found {
        print
    }
    END {
        if (!found) {
            exit 1
        }
    }
' "$changelog"
