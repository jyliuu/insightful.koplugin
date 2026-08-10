#!/bin/sh
set -eu

plugin_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
changelog="$plugin_root/CHANGELOG.md"
request=${1:-}
release_date=${2:-$(date '+%Y-%m-%d')}

usage() {
    printf '%s\n' "usage: $0 X.Y.Z[-prerelease] [YYYY-MM-DD]" >&2
    exit 2
}

[ -n "$request" ] || usage
version=${request#v}

semver_pattern='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$'
date_pattern='^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
printf '%s\n' "$version" | grep -Eq "$semver_pattern" || usage
printf '%s\n' "$release_date" | grep -Eq "$date_pattern" || usage

[ -f "$changelog" ] || {
    printf '%s\n' "changelog update failed: CHANGELOG.md is missing" >&2
    exit 1
}

if grep -Eq "^## $version \\(" "$changelog"; then
    printf '%s\n' "CHANGELOG.md already contains $version"
    exit 0
fi

previous_version=$(sed -nE 's/^## ([^ ]+) \(.*/\1/p' "$changelog" | sed -n '1p')
[ -n "$previous_version" ] || {
    printf '%s\n' "changelog update failed: no previous version was found" >&2
    exit 1
}

base_commit=
if git -C "$plugin_root" rev-parse --verify --quiet "v$previous_version^{commit}" >/dev/null; then
    base_commit="v$previous_version"
else
    for commit in $(git -C "$plugin_root" rev-list --first-parent HEAD); do
        commit_version=$(git -C "$plugin_root" show "$commit:VERSION" 2>/dev/null || true)
        [ "$commit_version" = "$previous_version" ] || continue

        parent=$(git -C "$plugin_root" rev-parse "$commit^" 2>/dev/null || true)
        parent_version=
        if [ -n "$parent" ]; then
            parent_version=$(git -C "$plugin_root" show "$parent:VERSION" 2>/dev/null || true)
        fi
        if [ "$parent_version" != "$previous_version" ]; then
            base_commit=$commit
            break
        fi
    done
fi

[ -n "$base_commit" ] || {
    printf '%s\n' "changelog update failed: could not find the $previous_version release commit" >&2
    exit 1
}

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/insightful-changelog.XXXXXX")
subjects="$work_dir/subjects"
added="$work_dir/added"
fixed="$work_dir/fixed"
changed="$work_dir/changed"
section="$work_dir/section"
updated="$work_dir/CHANGELOG.md"
trap 'rm -rf "$work_dir"' EXIT HUP INT TERM

git -C "$plugin_root" log --reverse --no-merges --format='%s' "$base_commit..HEAD" > "$subjects"
: > "$added"
: > "$fixed"
: > "$changed"

while IFS= read -r subject; do
    case "$subject" in
        build:*|build\(*\):*|chore:*|chore\(*\):*|ci:*|ci\(*\):*|docs:*|docs\(*\):*|refactor:*|refactor\(*\):*|style:*|style\(*\):*|test:*|test\(*\):*)
            continue
            ;;
        feat:*|feat\(*\):*|feat!:*|feat\(*\)!:*)
            target=$added
            ;;
        fix:*|fix\(*\):*|fix!:*|fix\(*\)!:*)
            target=$fixed
            ;;
        *)
            target=$changed
            ;;
    esac

    description=${subject#*: }
    description=$(printf '%s\n' "$description" | awk '{print toupper(substr($0, 1, 1)) substr($0, 2)}')
    printf '* %s\n' "$description" >> "$target"
done < "$subjects"

[ -s "$added" ] || [ -s "$fixed" ] || [ -s "$changed" ] || {
    printf '%s\n' "changelog update failed: no changes were found after $previous_version" >&2
    exit 1
}

{
    printf '## %s (%s)\n\n' "$version" "$release_date"
    for entry in "Added:$added" "Fixed:$fixed" "Changed:$changed"; do
        title=${entry%%:*}
        file=${entry#*:}
        [ -s "$file" ] || continue
        printf '### %s\n\n' "$title"
        sed -n 'p' "$file"
        printf '\n'
    done
} > "$section"

awk -v section="$section" '
    !inserted && /^## / {
        while ((getline line < section) > 0) {
            print line
        }
        close(section)
        inserted = 1
    }
    { print }
    END {
        if (!inserted) {
            while ((getline line < section) > 0) {
                print line
            }
            close(section)
        }
    }
' "$changelog" > "$updated"

chmod 644 "$updated"
mv "$updated" "$changelog"
trap - EXIT HUP INT TERM
rm -rf "$work_dir"

printf '%s\n' "added $version to CHANGELOG.md"
