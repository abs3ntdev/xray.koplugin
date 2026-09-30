# Main-branch semantic releases

Every push to `main` triggers the existing **Release** workflow, including
workflow/documentation-only changes. It uses pinned npm `semantic-release` and
the official commit-analyzer, release-notes-generator, exec and GitHub plugins.
There are no release commits, npm package publishing, version-file rewrites or
tag-trigger loops. A separate read-only PR workflow tests the relay and plugin. The workflow checks out the exact pushed SHA.

## Version policy

Tags and release titles are `vMAJOR.MINOR.PATCH`. Commits since the last semantic
tag determine the highest applicable bump:

- `BREAKING CHANGE:` / `BREAKING-CHANGE:` footer or `type!:` / `type(scope)!:`: major.
- `feat:` / `feat(scope):`: minor.
- Anything else, including fixes, docs, CI and nonconventional messages: patch.

The catchall is explicit rather than semantic-release's usual no-release
behavior for documentation changes. Normal semantic-release exclusions still
apply, including release-skip markers, empty messages and fully reverted commit
pairs. A successful rerun with no new commits does not allocate another version.
An empty-tree commit with a normal message does count as a new commit.

## One-time baseline

Before enabling this configuration on `main`, a maintainer creates the baseline
**tag only** `v26.9.29` at `9fd6efb6e78ec32230694bc4d4759f76073ee130`.
That commit already has the published `Main 1` release and verified plugin ZIP.
The existing nonsemantic release and all historical tags remain untouched.

```sh
git tag v26.9.29 9fd6efb6e78ec32230694bc4d4759f76073ee130
git push origin refs/tags/v26.9.29
```

This preserves the `26.x` version line: the committed plugin metadata currently
says `26.9.29-beta`, while inherited stable tags such as `26.9.17` have no `v`
prefix and are not recognized by the new tag format. The workflow explicitly
checks the baseline tag and SHA, refusing to fall back silently to `1.0.0`.
The first CI-only migration commit after the baseline produces `v26.9.30`.

Release tags and installed metadata agree: the official exec `prepare` hook
packages only after semantic-release calculates `nextRelease.version`. It stamps
that version (without the tag's `v` prefix) into **the ZIP's `_meta.lua` only**.
Storefront compares this installed version to its catalog version, so leaving
the old `26.9.29-beta` value in a newer release would cause repeated update prompts.
The source/worktree `_meta.lua` stays unchanged and every other packaged file
remains byte-identical to its committed blob. No generated commit can retrigger
another release.

## Concurrency and reruns

The workflow uses GitHub's `queue: max` concurrency mode, with cancellation
disabled, to serialize version allocation. GitHub allows up to 100 pending runs
and cancels additional runs if the queue is full. Queue order follows when runs
begin waiting, not necessarily push order.

**There is not a strict one-release-per-push guarantee for overlapping pushes.**
Standard semantic-release intentionally skips a checkout that is behind remote
`main`. Rapid pushes can therefore be combined into the next release rather
than publishing each older SHA. We keep that safety guard and never substitute
a newer commit's files under an older push event. Ordinary sequential pushes
produce releases, and successful reruns are no-ops. The normal stable `main`
release becomes GitHub's latest release through the official GitHub plugin.

If publishing fails after a tag was pushed, a rerun does not automatically
repair an incomplete GitHub release: semantic-release sees the existing tag.
Inspect the failed run, tag SHA and release assets before maintainer recovery.
Do not delete/repoint published tags or force-push to recover.

## Installable asset and permissions

The published, non-draft, non-prerelease asset is **xray.koplugin.zip**, not
GitHub's whole-repository source archive. Extract it into KOReader's `plugins/`
directory to obtain `plugins/xray.koplugin/main.lua` and `_meta.lua`.
The GitHub plugin stages the upload as a draft, then publishes after upload.

`tools/package_release.py` packages only committed plugin source modules,
public certificates/notices, SVG assets, translations and prompts under the
single `xray.koplugin/` root. Hidden files, runtime directories and non-source
types such as JSON backups, databases, logs, private keys and Python caches are
excluded by pathname before blob reads. The public blank-key
`xray.koplugin/xray_config.lua` template stays included. Do not commit a
personalized template. New asset types/directories need explicit packaging support.

```sh
npm ci --ignore-scripts --no-audit --no-fund
npm run test:release
python3 tools/package_release.py "$(git rev-parse HEAD)" xray.koplugin.zip 26.9.31
```

Node 24.10+ and Python 3.11+ are required. The example version is explicit for
local reproduction; CI always passes semantic-release's calculated version.
Omitting that optional argument makes an unstamped source archive, not a release.
Packaging accepts only stable `MAJOR.MINOR.PATCH`, requires exactly one metadata
version field, and verifies entrypoints, ZIP integrity and every output byte
against the committed payload plus that one metadata substitution. Fixed ZIP
metadata and stored entries make identical-source/version reruns byte-identical.
The semantic-release job grants only `contents: write` to `GITHUB_TOKEN`.
The separate container image job grants `contents: read` and `packages: write`.
Both publishing jobs run only in the main-push Release workflow. GitHub issue creation,
comments, issue closure, labels and release references on PRs are disabled.
No personal token is needed.

This does not change the fork's in-app updater, its `openai-subscription` branch,
device settings or account state. `tools/release.py` is an older manual helper,
not part of semantic-release automation.


## Unraid relay image

Before semantic-release runs, the workflow passes the release-policy tests,
Node relay tests, Lua plugin suite and non-root read-only Docker smoke test.
After semantic-release succeeds, the workflow selects a published stable release
whose tag points to the exact pushed checkout. A separate image job checks out
that verified tag, checks its SHA again, and publishes the root Dockerfile to
`ghcr.io/abs3ntdev/xray.koplugin` for `linux/amd64`.

Every selected release publishes `vMAJOR.MINOR.PATCH` and `MAJOR.MINOR.PATCH`.
The mutable `latest` tag is included only when that release is still GitHub's
latest published stable release. No draft, prerelease, missing release or
mismatched checkout can select image tags. Using the same workflow is deliberate:
release events created with `GITHUB_TOKEN` do not start a separate release-event
workflow. Existing workflow concurrency covers both publishing jobs.

If only image publishing fails, rerun the failed image job. Rerunning the entire
workflow also reselects the published release at the exact checkout without
allocating a new plugin version. Main advancing does not suppress an already
published version's image. An older release rerun can repair its version tags
but does not move `latest` backwards. The image job rechecks the exact expected
release and latest eligibility before publication, including failed-job reruns.

The first GHCR publication may need the package owner to make the package
public for anonymous Unraid pulls. The workflow does not change visibility or
require a personal access token. See [Unraid setup](self-hosted-relay.md) for the
image name, ports, environment and Pangolin routing.
