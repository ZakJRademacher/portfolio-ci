#!/usr/bin/env bash
# Scan commits for messages or identities that credit Claude/Anthropic.
# Same patterns as the optional local git guard (attribution-guard.sh).
#
#   attribution-scan.sh <git rev-list args...>
#   attribution-scan.sh origin/main..HEAD
#   attribution-scan.sh --all              # whole history of every ref
#
# Exit 0 when clean, 1 when something is found, 2 when the commits cannot be read.
set -uo pipefail

if [ $# -eq 0 ]; then echo "usage: attribution-scan.sh <rev-list args>" >&2; exit 2; fi

MSG_RE='^[[:space:]]*co-authored-by:.*([^[:alnum:]]claude([^[:alnum:]]|$)|[@.]anthropic\.com)|^[[:space:]]*claude-session:|generated (with|by) \[?claude code'
EMAIL_RE='[@.]anthropic\.com>?$|(^|[+<])claude(\[bot\])?@users\.noreply\.github\.com>?$'
NAME_RE='(^|[^[:alnum:]])claude([^[:alnum:]]|$)'

if ! count=$(git rev-list --count "$@"); then
    echo "::error title=attribution scan::could not read commits for: $*"
    exit 2
fi

found=$(
    {
        git --no-replace-objects log --format='%H%x1fauthor%x1f%an%x1f%ae' "$@"
        git --no-replace-objects log --format='%H%x1fcommitter%x1f%cn%x1f%ce' "$@"
    } | NAME_RE="$NAME_RE" EMAIL_RE="$EMAIL_RE" awk -F '\037' '
        { n = tolower($3); e = tolower($4)
          if (e ~ ENVIRON["EMAIL_RE"]) print $1 "\t" $2 " email is " $4
          if (n ~ ENVIRON["NAME_RE"])  print $1 "\t" $2 " name is \"" $3 "\"" }'
    git --no-replace-objects log --format='%x1e%H%n%B' "$@" | MSG_RE="$MSG_RE" awk '
        /^\036/ { h = substr($0, 2); next }
        { if (tolower($0) ~ ENVIRON["MSG_RE"]) print h "\tmessage line: " $0 }'
)

echo "Scanned $count commit(s)."
if [ -z "$found" ]; then
    echo "No Claude/Anthropic attribution found."
    [ -n "${GITHUB_STEP_SUMMARY:-}" ] && echo "Attribution scan: $count commit(s), nothing found." >> "$GITHUB_STEP_SUMMARY"
    exit 0
fi

echo
echo "Commits that credit Claude/Anthropic:"
while IFS=$'\t' read -r sha what; do
    echo "  ${sha:0:12}  $what"
    echo "::error title=attribution scan::commit ${sha:0:12}: $what"
done <<< "$found"
echo
echo "Reword these commits (git rebase -i) and force-push the branch, or close the PR."
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
        echo "### Attribution scan failed"
        echo
        echo "| Commit | Problem |"
        echo "| --- | --- |"
        while IFS=$'\t' read -r sha what; do echo "| \`${sha:0:12}\` | ${what//|/\\|} |"; done <<< "$found"
    } >> "$GITHUB_STEP_SUMMARY"
fi
exit 1
