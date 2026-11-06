# Manuscript Sync

A one-button macOS app that syncs a manuscript folder (a git clone of an Overleaf project) with Overleaf.

Sync = commit every local change (message `Sync YYYY-MM-DD HH:mm`), pull, push.
If the pull brought someone else's edits, "View changes" shows them as a word diff.
On a conflict it stops and names the file; fix the markers, then click Sync again.

The cloud button clones a new manuscript: paste the Overleaf Git link, the project's browser address,
or a whole `git clone <link> <folder>` command, pick a folder name and location, and it is added to the list.
It can also drop in a LaTeX `.gitignore`, which is sent with the next sync.

- Build and install to `~/Applications`: `./build.sh --install`
- Run the git tests (throwaway local repos, never Overleaf): `./test.sh`
- New icon: replace `Resources/icon-source.png`, run
  `python3 Resources/make_icon.py Resources/icon-source.png Resources/AppIcon.png [left,top,right,bottom]`
  (the crop box trims any border drawn in the artwork; the current one uses `16,20,1238,1242`), then rebuild.

Login uses the Overleaf Git token already saved in the macOS Keychain by `git push` in Terminal.
The scripts compile with Xcode.app's toolchain because the Command Line Tools Swift on this Mac doesn't match its SDK.
