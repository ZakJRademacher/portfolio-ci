# Security policy

## Supported versions

Only the latest release of portfolio-ci gets security fixes. Callers should pin a release by its full commit SHA and let Dependabot move them forward.

| Version | Supported |
| --- | --- |
| 1.x (latest) | Yes |
| Older | No |

## Reporting a vulnerability

Please report security problems privately, not in a public issue.

1. Go to the repository's **Security** tab and choose **Report a vulnerability**. This opens a private advisory that only the maintainer can see.
2. Describe the problem, the affected workflow or script, and how to reproduce it.

You should get a reply within 7 days. Once a fix is released, the advisory is published with credit to you, unless you'd rather stay anonymous.

## Scope

These are in scope:

- The reusable workflows in `.github/workflows/`, and the scripts they run from `scripts/`.
- Anything that could leak a caller's secrets, including the block lists passed to `blocked-names.yml`, or that could let untrusted pull request content run code.
- Pinned third-party actions or tools that this repo pulls in.

Out of scope are problems in a calling repository's own code, and findings that need the caller to have misconfigured their own secrets or permissions.
