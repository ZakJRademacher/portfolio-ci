#!/usr/bin/env bash
# List branches on origin that are merged or stale.
#
#   branch-hygiene.sh <default-branch> <stale-days> "<ignored branches>"
#
# Merged = an ancestor of the default branch, OR the head of a merged pull request
# whose branch still exists at that same commit (catches squash and rebase merges).
# Squash detection uses `gh` and GH_TOKEN; without them only ancestry is checked.
# Prints a Markdown table to stdout. Exit 0 when nothing is flagged, 3 when some
# branch is flagged (the workflow decides whether that fails the job).
set -uo pipefail

default=${1:?default branch}
days=${2:-90}
ignore=" ${3:-} $default HEAD "

now=$(date +%s)
cutoff=$((now - days * 86400))

declare -A merged_pr=()
note=''
if command -v gh >/dev/null 2>&1 && [ -n "${GH_TOKEN:-}" ]; then
    if prs=$(gh pr list --state merged --limit 300 --json headRefName,headRefOid,number,isCrossRepository \
                --jq '.[] | select(.isCrossRepository | not) | [.headRefName, .headRefOid, (.number|tostring)] | @tsv'); then
        while IFS=$'\t' read -r ref sha num; do
            [ -n "$ref" ] && merged_pr["$ref"]="$sha#$num"
        done <<< "$prs"
    else
        note="Could not list merged pull requests, so squash-merged branches were not checked."
        echo "::warning title=hygiene::$note" >&2
    fi
else
    note="No GH_TOKEN, so only ancestry was checked; squash-merged branches may be missed."
fi

rows=()
while IFS=$'\t' read -r ref sha ts; do
    name=${ref#refs/remotes/origin/}
    case "$ignore" in *" $name "*) continue ;; esac
    reasons=()
    if git merge-base --is-ancestor "$sha" "origin/$default" 2>/dev/null; then
        reasons+=("merged into $default")
    elif [ -n "${merged_pr[$name]:-}" ] && [ "${merged_pr[$name]%%#*}" = "$sha" ]; then
        reasons+=("PR #${merged_pr[$name]##*#} merged (squash/rebase)")
    fi
    if [ "$ts" -lt "$cutoff" ]; then
        reasons+=("no commits for $(( (now - ts) / 86400 )) days")
    fi
    if [ ${#reasons[@]} -gt 0 ]; then
        joined=$(IFS=';'; echo "${reasons[*]}"); rows+=("| \`$name\` | ${joined//;/, } |")
    fi
done < <(git for-each-ref --format='%(refname)%09%(objectname)%09%(committerdate:unix)' refs/remotes/origin/)

if [ -n "$note" ]; then echo "_${note}_"; echo; fi
if [ ${#rows[@]} -eq 0 ]; then
    echo "No merged or stale branches (stale = no commits for $days days)."
    exit 0
fi
echo "| Branch | Why |"
echo "| --- | --- |"
printf '%s\n' "${rows[@]}"
exit 3
