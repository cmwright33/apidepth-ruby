# Claude Code Context — apidepth (Ruby gem)

## Release flow

This repo uses **release-please** for automated releases. Merging to `main` is how things get shipped — but it is a two-step process, not instant.

**Never push directly to `main`.** All changes must come in via a PR.

### Step 1 — merge your feature/fix PR

PR titles must follow [Conventional Commits](https://www.conventionalcommits.org/). The title becomes the squash-merge commit message, which release-please reads to determine the next version:

| Title prefix | Version bump |
|---|---|
| `feat: ...` | minor (1.x.0) |
| `fix: ...` | patch (1.0.x) |
| `feat!:` or `BREAKING CHANGE` in body | major (x.0.0) |
| `chore:`, `docs:`, `refactor:`, `test:` | none |

A PR whose title doesn't match this format is blocked by the `PR Title` required status check.

### Step 2 — merge the release PR

After step 1, release-please opens a `chore: release X.Y.Z` PR automatically. That PR:
- bumps the version in `lib/apidepth/version.rb`
- updates `CHANGELOG.md`

Merging it triggers the `publish` job in `.github/workflows/release-please.yml`, which builds the gem and pushes it to RubyGems.

## Version file

`lib/apidepth/version.rb` is the single source of truth. **Do not edit it manually** — release-please owns it. If you change it by hand the manifest will drift and the next release will be wrong.

## Branch protection

- PRs required; 1 approval minimum
- `PR Title` check must pass (conventional commit format)
- `Test (3.3)` CI check must pass
- `strict` branch protection — your branch must be up to date with `main` before merge
- Force pushes and branch deletions blocked, including for admins

## CI

Tests run via `.github/workflows/ci.yml` across Ruby 3.1, 3.2, 3.3. The test suite requires a `GH_PAT` secret to check out fixtures from `apidepth-io/apidepth-collector`.

## GitHub Actions secrets

| Secret / config | Used for |
|---|---|
| `GH_PAT` | Checking out test fixtures from apidepth-collector |
| RubyGems Trusted Publisher | Pushes to RubyGems — configured on RubyGems' side (no GitHub secret needed) |

See `CONTRIBUTING.md` for the full contributor guide.
