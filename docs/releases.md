# Main-branch releases

Every push to `main` runs the existing **Release** workflow. Tag pushes and
manual dispatch no longer run a second release path. There are no path filters
or shared concurrency groups, so documentation-only pushes and concurrent pushes
also get their own release.

Each run publishes a normal, non-draft, non-prerelease GitHub release tagged
`main-<run_id>-<full pushed SHA>`. Retrying a run reuses that tag and release.
The tag is created at the exact pushed commit, never a moving branch reference.
Existing tags or assets with different contents cause a failure rather than
being overwritten. An already uploaded identical ZIP is reused on reruns.
A release is initially created without becoming latest. After uploading its ZIP,
only a run whose SHA still equals the live `main` tip requests latest status.
Older runs still publish their releases without changing the latest selection.

The release asset is **xray.koplugin.zip**, not GitHub's whole-repository source
archive. Extract it into KOReader's `plugins/` directory to produce
`plugins/xray.koplugin/main.lua` and `plugins/xray.koplugin/_meta.lua`.

`tools/package_release.py` packages only committed plugin source modules,
public certificates/notices, SVG assets, translations and prompts under the
single `xray.koplugin/` root. It never reads working-tree files for the payload.
Hidden files, runtime directories and non-source types such as JSON backups,
databases, logs, private keys and Python caches are excluded by pathname.
The committed `xray.koplugin/xray_config.lua` is the public blank-key template
and remains included. Do not commit personalized versions of that template.
New asset directories or types must be added explicitly to the packager.

To reproduce a release locally with Python 3.11 or newer:

```sh
python3 tools/package_release.py "$(git rev-parse HEAD)" xray.koplugin.zip
```

Packaging validates required Lua entrypoints, ZIP integrity, paths and bytes
against the Git commit. Fixed ZIP metadata and stored entries make reruns
byte-identical. Only `contents: write` is granted to the workflow's automatic
`GITHUB_TOKEN`. No personal token or repository secret needs configuring.

This does not change the fork's in-app updater, its `openai-subscription` branch,
plugin metadata version, device settings or account state. `tools/release.py`
is an older manual version/tag helper and is not needed for these releases.
