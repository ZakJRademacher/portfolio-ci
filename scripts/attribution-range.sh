#!/usr/bin/env bash
# Print the git rev-list arguments attribution.yml should scan, then a reason on stderr.
# Inputs come from the environment (set from the GitHub event):
#   FULL      "true" to scan every ref's history
#   PR_BASE   pull request base SHA     PR_HEAD  pull request head SHA
#   EVENT     github.event_name         REF_TYPE branch | tag
#   BEFORE    github.event.before       AFTER    github.sha
set -euo pipefail
zero=0000000000000000000000000000000000000000

if [ "${FULL:-}" = "true" ]; then
    echo "--all"; echo "full history (full-history: true)" >&2
elif [ -n "${PR_BASE:-}" ] && [ -n "${PR_HEAD:-}" ]; then
    if ! git cat-file -e "$PR_HEAD^{commit}" 2>/dev/null || ! git cat-file -e "$PR_BASE^{commit}" 2>/dev/null; then
        git fetch --no-tags -q origin "$PR_HEAD" "$PR_BASE" >&2 || true
    fi
    echo "$PR_BASE..$PR_HEAD"; echo "pull request commits" >&2
elif [ "${EVENT:-}" = "push" ] && [ "${REF_TYPE:-}" = "branch" ] && [ -n "${BEFORE:-}" ] && [ "$BEFORE" != "$zero" ] \
     && git cat-file -e "$BEFORE^{commit}" 2>/dev/null && git merge-base --is-ancestor "$BEFORE" "$AFTER"; then
    echo "$BEFORE..$AFTER"; echo "commits added by this push" >&2
else
    # New branch or tag, force push, or any other event: scan everything reachable.
    echo "${AFTER:?AFTER (github.sha) is required}"
    echo "everything reachable from $AFTER (new ref, force push, tag or ${EVENT:-other event})" >&2
fi
