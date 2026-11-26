# Changelog

All notable changes to portfolio-ci are documented here. The format follows [Keep a Changelog](https://keepachangelog.com), and versions follow [Semantic Versioning](https://semver.org).

## [1.0.0] - 2026-11-24

### Added
- `attribution.yml`: fails when a commit in a push or pull request credits Claude or Anthropic (co-author lines, `Claude-Session` trailers, "Generated with Claude Code", author or committer identities).
- `site-quality.yml`: lychee link check, social preview tags (og:title, og:image that loads, description), and Lighthouse CI with thresholds passed in as inputs, scored on the median of several runs.
- `hygiene.yml`: merged and stale branches (including squash-merged ones), and a README that opens with a screenshot and a live link.
- `release.yml`: on a `v*` tag, publishes a GitHub Release from that version's CHANGELOG section, and fails if the section is missing.
- `scorecard.yml`: OpenSSF Scorecard, with results uploaded to code scanning as SARIF and an optional minimum score.
- `blocked-names.yml`: fails when a name from a private block list (passed in as a secret) appears in files, paths, commit messages, refs, tags or PR text. Review stems only warn. Private repos are exempt, and anything not confirmed private counts as public. Terms are masked and never printed. `release.yml` and `site-quality.yml` check release notes and live pages against the same lists.
- `templates/`: caller workflows and a Dependabot config for adopting the checks in a repo.
- Least-privilege permissions: `contents: read` at the top of every workflow, with more granted per job only where needed.
- `self-test.yml`: script tests with fixtures, actionlint and shellcheck, and a real run of each reusable workflow.

[1.0.0]: https://github.com/ZakJRademacher/portfolio-ci/releases/tag/v1.0.0
