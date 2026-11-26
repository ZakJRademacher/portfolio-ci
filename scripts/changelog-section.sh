#!/usr/bin/env bash
# Print one version's section of a Keep a Changelog style CHANGELOG.
#
#   changelog-section.sh <version> [CHANGELOG.md]
#
# Accepts headings "## [1.2.0]", "## 1.2.0", "## v1.2.0", each optionally followed
# by " - 2026-11-24" or similar. A leading "v" on <version> is ignored.
# The section runs until the next "## " heading or a link-reference block.
# Exit 1 if the section is missing or has no text.
set -uo pipefail

version=${1:?usage: changelog-section.sh <version> [file]}
file=${2:-CHANGELOG.md}
version=${version#v}

if [ ! -f "$file" ]; then echo "::error title=changelog::$file not found" >&2; exit 1; fi

body=$(tr -d '\r' < "$file" | V="$version" awk '
    BEGIN { v = ENVIRON["V"] }
    /^## / {
        if (on) exit
        h = substr($0, 4)
        sub(/^[[:space:]]*\[?v?/, "", h)
        if (index(h, v) == 1) {
            rest = substr(h, length(v) + 1)
            if (rest == "" || rest ~ /^(\]|[[:space:]]|$)/) { on = 1; next }
        }
    }
    on && /^\[[^]]+\]:[[:space:]]/ { exit }   # link references at the end of the file
    on { print }
')

# Trim leading and trailing blank lines.
body=$(printf '%s\n' "$body" | sed -e '/./,$!d' | sed -e ':a' -e '/^\n*$/{$d;N;ba' -e '}')

if [ -z "$(printf '%s' "$body" | tr -d '[:space:]')" ]; then
    echo "::error title=changelog::no section (or an empty one) for $version in $file. Add a \"## [$version]\" section." >&2
    exit 1
fi
printf '%s\n' "$body"
