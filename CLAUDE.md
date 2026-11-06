# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A one-window macOS SwiftUI app (macOS 14+, arm64) that syncs a local git clone of an Overleaf project: commit everything, pull, push. It also clones new Overleaf projects and shows the last sync's changes as a word diff. See README.md for the user-facing behavior.

## Commands

There is no Xcode project or Package.swift. Everything is built with plain `swiftc` from two shell scripts. Both set `DEVELOPER_DIR` to Xcode.app, because the Command Line Tools Swift on this Mac doesn't match its SDK. Use the scripts rather than calling `swiftc` directly.

- Build `build/Manuscript Sync.app`: `./build.sh`
- Build and install to `~/Applications`: `./build.sh --install`
- Run the tests: `./test.sh`
- Regenerate the icon after replacing `Resources/icon-source.png`: `python3 Resources/make_icon.py Resources/icon-source.png Resources/AppIcon.png 16,20,1238,1242`, then rebuild. The last argument is the crop box for the current artwork. The script needs Pillow.

`build.sh` writes `Info.plist` inline (bundle id `local.manuscript-sync`), builds the `.icns` from `Resources/AppIcon.png` with `sips`/`iconutil`, and ad-hoc codesigns the app. To change bundle metadata, edit the heredoc in `build.sh`.

### Tests

`Tests/main.swift` is a plain top-level script, not XCTest. `test.sh` compiles it together with `Sources/Engine.swift` only, then runs it against a scratch folder under `build/test-tmp/`. It sets up a local bare repo standing in for Overleaf (`overleaf.git`), plus two clones: `me` (the user's manuscript) and `boss` (a co-author). It never touches the network.

- No single-test filter exists. The sections run in order and share repo state: each scenario builds on the commits left by the one before. A new scenario must account for that state, or set up its own repos.
- `expect(cond, name)` prints `ok`/`FAIL` with the line number. The process exits 1 if anything failed.

## Architecture

Two source files, split along a hard boundary:

- **`Sources/Engine.swift`**: all git logic. It must stay Foundation-only (no AppKit/SwiftUI), because the test build compiles it without `App.swift`.
- **`Sources/App.swift`**: SwiftUI UI plus `AppModel`, a `@MainActor` `ObservableObject`. It is compiled with `-parse-as-library` because of `@main`.

### Git execution (`Git.run`)

The engine shells out to the git binary through `Process`. There is no libgit2.

- It prefers Homebrew's git over `/usr/bin/git`, so it uses the same credential helper and Keychain entry as Terminal. The app never handles Overleaf tokens itself.
- Every call sets `GIT_TERMINAL_PROMPT=0` (fail instead of hanging on a password prompt), `GIT_EDITOR=true`, `LC_ALL=C`, and `-c core.quotePath=false`.
- `LC_ALL=C` is required: `SyncEngine.classify` maps git's English stderr text to `SyncError` cases (`.auth`, `.network`, `.projectNotFound`, otherwise `.git(last lines)`).

### Sync flow (`SyncEngine.sync`)

1. Require a repo and an upstream branch.
2. If `MERGE_HEAD` exists, an earlier sync stopped on a conflict. Throw `.unresolved` while any conflicted file still contains `<<<<<<<` or `>>>>>>>`. Otherwise commit, which concludes the merge.
3. Run `add -A`, then commit with message `Sync yyyy-MM-dd HH:mm` when something is staged (or when finishing a merge).
4. Run `pull --no-rebase --ff --no-edit`. On a conflict, throw `.conflict(files)` and leave the repo mid-merge on purpose; step 2 picks it up on the next sync.
5. If ahead of upstream, push. A non-fast-forward rejection becomes `.remoteMoved`.

Each direction of a sync is recorded as a `ChangeRange` (start commit, end commit, file list):

- **sent** is `@{u}..HEAD`, taken just before the push.
- **received** runs from the local commit to the post-pull HEAD. When finishing a conflict, it starts from the pre-merge HEAD instead, so it covers only the co-author's side.

The two ranges are stored as a `SyncRecord`. Diffs are not stored: when the panel opens, they are recomputed from the commit hashes with `git diff --word-diff=porcelain`, chosen because a LaTeX paragraph is usually one long line. `parseWordDiff` turns that output into `DiffSegment`s, and `lines(of:)` groups them into editor-style lines numbered in the new file. A line holding only removed words gets `nil` for its number.

### App state

`AppModel` keeps everything in `UserDefaults`:

| Key | Contents |
|---|---|
| `repos` | Repo root paths |
| `selected` | The selected repo |
| `cloneParent` | Last folder used for clones |
| `lastSync.<path>` | Date of the last sync |
| `record.<path>` | JSON-encoded `SyncRecord` |

`incoming.<path>` is a legacy key that the app deletes after each sync.

Engine calls block, so they run in `Task.detached`. The model refreshes the local-change count whenever the app becomes active.

### Cloning

`parseCloneInput` accepts any of:

- an Overleaf Git URL
- a browser `…/project/<id>` URL
- a bare 24-hex-digit project id
- a whole `git clone <link> <folder>` command

Every form is normalized to `https://git.overleaf.com/<id>`. `clone` refuses an existing folder, deletes a half-made folder when the clone fails, and can add `latexGitignore`. That `.gitignore` is left uncommitted, so the next sync sends it.

## Conventions

- `SyncError.message` and the banner strings are read by non-technical co-authors. Keep them free of git jargon, and have each one say what to do next. New failure modes get a `SyncError` case with its own message, plus a `classify` rule if they're detected from stderr.
- Engine changes should come with a scenario in `Tests/main.swift` using the bare-repo setup.
