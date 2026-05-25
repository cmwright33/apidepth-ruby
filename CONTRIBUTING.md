# Contributing to apidepth (Ruby gem)

## Prerequisites

- Ruby >= 2.7
- Bundler

```bash
bundle install
```

## Running tests

```bash
bundle exec rspec
```

## Making changes

**All changes to `main` must go through a pull request.** Direct pushes are blocked.

### Commit / PR title format

PR titles must follow [Conventional Commits](https://www.conventionalcommits.org/) — the title becomes the squash-merge commit message that drives automated versioning:

```
feat: add timeout configuration
fix: handle 429 response when retry-after header is missing
docs: clarify rate limit tracking behaviour
chore: update dependencies
```

Use `feat!:` or put `BREAKING CHANGE: <description>` in the PR body for breaking changes (triggers a major version bump).

The `PR Title` check will fail and block merge if the format isn't followed.

## Release process

Releases are fully automated via [release-please](https://github.com/googleapis/release-please). You do not manually bump versions or tag releases.

1. **Merge your PR** — release-please reads the commit message and accumulates changes.
2. **A "Release PR" appears** — release-please opens a `chore: release X.Y.Z` PR that bumps `lib/apidepth/version.rb` and updates `CHANGELOG.md`. This PR stays open and updates itself as more commits land.
3. **Merge the Release PR** — triggers the publish job, which builds the gem and pushes it to RubyGems.

### Version semantics

| Commit type | Version bump |
|---|---|
| `feat:` | minor |
| `fix:` | patch |
| `feat!:` or `BREAKING CHANGE` in body | major |
| `chore:`, `docs:`, `refactor:`, `test:` | no release |

### Do not edit `lib/apidepth/version.rb` manually

release-please owns that file. Manual edits will cause the manifest to drift and break the next automated release.

## CI

Tests run on Ruby 3.1, 3.2, and 3.3. All three matrix jobs must pass before a PR can merge.

The test suite checks out fixtures from `apidepth-io/apidepth-collector` using the `GH_PAT` secret — this is pre-configured in the repo and you do not need to set it up locally.

## Secrets (maintainers only)

| Secret | Where to get it |
|---|---|
| `RUBYGEMS_API_KEY` | rubygems.org → Your profile → API keys → New key (scope: push) |
| `GH_PAT` | GitHub personal access token with `repo` scope |
