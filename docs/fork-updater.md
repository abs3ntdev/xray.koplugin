# Fork updater

This build updates itself from **`abs3ntdev/xray.koplugin`, branch `main`**. It does not use GitHub releases, version numbers, or the upstream repository. The old beta/stable channel setting was removed because a fixed branch has no channels.

## What it does

- **Check for Updates** (Maintenance menu or About X-Ray) asks `api.github.com` for the branch's head commit SHA and compares it with the installed SHA. The prompt shows the source repo and branch.
- **Weekly background check** only shows a prompt when a newer commit exists and the installed commit is known. It never installs anything by itself and stays silent when the installed build is unknown.
- **Download and install** fetches the archive of that exact commit from `codeload.github.com/abs3ntdev/xray.koplugin/zip/<sha>` and installs only the `xray.koplugin/` subtree into the current plugin directory.

Both hosts are reached through the verified TLS transport (`xray_secure_http.lua`, `requestPublic`). This is a separate policy from the subscription sign-in hosts: GET only, no redirects, no body, `Authorization`/`Cookie` headers are rejected, and responses are capped at 24 MB.

## Installed marker

After a successful install the updater writes `xray.koplugin/.xray_fork_commit`, exactly:

```
source=github:abs3ntdev/xray.koplugin@main
commit=<40 lowercase hex characters>
```

A missing, malformed, or different-source marker means **unknown**. It is never treated as up to date. The marker is written last and only after every file is in place.

## Safety

- The archive is inspected in Lua before anything is extracted. Every entry must be a Unix regular file or directory (symlinks and other types reject the whole archive), use only `[A-Za-z0-9._/-]` with no `.`/`..` segments, be unique, sit under the single root `xray.koplugin-<sha>/`, be unencrypted, non-ZIP64, stored or deflated, and agree with its local header. Entry count, per-file size (8 MB) and total plugin size (32 MB) are capped. Files outside the plugin subtree (README, spec, docs) are validated and skipped.
- Each plugin file is read with `unzip -p` in 64 KB chunks into a flat numbered staging file under KOReader's settings directory. Reading stops as soon as the declared size is exceeded, and the size and CRC-32 must match. The archive never creates paths or links itself. A missing or incompatible `unzip` fails without changing anything.
- The payload's `xray_updater.lua` must contain the capability token `XRAY_FORK_UPDATER_V1`. Otherwise installation is refused ("The published build does not support the fork updater yet") so the updater cannot downgrade itself to one that tracks another source.
- Every component of the plugin and settings directory paths (from `/` or `.` down), and every target directory/file, must be a real (non-symlink) directory/file. `..` is rejected. Relative KOReader paths such as `./plugins/xray.koplugin` work.
- The install has two phases. **Download and staging** is dismissable and never touches the plugin directory. Every staged file is written with checked writes and then re-read from disk and checked against the archive size and CRC-32. **The swap** runs afterwards in KOReader's main process and cannot be cancelled. It re-verifies each staged file, moves the old marker aside first, then per file writes `<file>.xray-new` (verified again), renames the old file to `<file>.xray-bak`, and renames the new file into place.
- The old marker is moved to `.xray_fork_commit.xray-old`. Any failure restores every replaced file, then the old marker, and reports "The previous version was kept". If any file restore fails, the updater says so, leaves the `*.xray-bak` files for manual recovery, and does **not** restore the old marker, so the mixed build reads as unknown. It never claims nothing changed. Backups are removed only after the new marker is written.
- This is not power-loss atomic. A power cut during the swap can leave a mix of old and new files and `*.xray-bak` files, but the marker has already been moved aside, so the build then reads as **unknown**, never as a specific commit.
- `xray_config.lua` is never overwritten when it exists. Files not in the archive are never deleted. Settings, sign-in data, and book data live outside the plugin directory and are not touched.

## One-time migration from `openai-subscription`

Older builds, including commit `3fc6bda` and release `v26.10.0`, check the old
`openai-subscription` branch. They cannot discover this `main`-branch change
through their existing update check. There is no branch selector in the UI.

After this fix is on `main`, the smallest migration is:

1. Exit KOReader and connect the reader to a computer. Back up
   `koreader/plugins/xray.koplugin/` and `koreader/settings/xray/`.
2. In `koreader/plugins/xray.koplugin/xray_updater.lua`, change only the branch
   string in `local OWNER, REPO, BRANCH = "abs3ntdev", "xray.koplugin", "openai-subscription"`
   from `"openai-subscription"` to `"main"`. Save the file, safely eject the
   reader, and start KOReader.
3. Open **X-Ray → Maintenance → Check for Updates** (also available in **About X-Ray**).
   The installed build will say **unknown**, because the old marker identifies
   a different branch. Confirm the source says **abs3ntdev/xray.koplugin (main)**,
   then choose **Download and install** and **Restart**.
4. Check again: it should report the installed `main` commit as up to date.
   The installer preserves `xray_config.lua`, settings, saved sign-ins and book
   data, and writes the new `@main` marker only after a successful installation.

Alternatively, download **xray.koplugin.zip** from a newer fixed
[release](https://github.com/abs3ntdev/xray.koplugin/releases/latest), not the
whole-repository source archive. With KOReader closed and the same backups made,
extract it on your computer and merge its `xray.koplugin/` contents into the
existing `koreader/plugins/xray.koplugin/` directory. Keep the existing
`xray_config.lua` instead of replacing it with the archive's blank template;
leave `koreader/settings/xray/` and book data untouched. Do not nest one
`xray.koplugin` folder inside another. Restart KOReader, then follow steps 3–4
to establish the new commit marker. Do not edit the marker to claim a commit
that has not actually been installed.

The updater downloads raw branch source, so the commit shown by **Check for
Updates** is authoritative for this channel; the release ZIP's stamped **About**
version and the source metadata version may differ.

## One-time bootstrap

A device running an older build still has the old release-based updater, so the first install of this updater is manual: copy the `xray.koplugin` directory from this branch onto the reader (keeping the existing `xray_config.lua`), then restart KOReader. The first check will say the installed build is unknown. You can either press **Download and install** once (it installs the current head and writes the marker), or write the marker yourself using the exact format above with the commit you copied.
