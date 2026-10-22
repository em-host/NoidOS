# Releases: one computer changes the system, the others pick it up

The configuration folder has two halves:

| Shared (the same everywhere) | This computer's own |
| --- | --- |
| `flake.nix`, `flake.lock`, `release.json`, `lib/`, `modules/` | `hosts/`: hardware, drives, the user file with its choices, added flakes |

You change the shared half on your computer and publish it as a numbered **release**. The other computers
install a release when their owner wants. Their `hosts/` folder is never published and never replaced.

## On your computer (once)

1. In `hosts/users/user.nix`: `myOS.sync.publish = true;`, then Rebuild. Nix Actions now shows
   **Publish changes** instead of Noid-OS Update.
2. Nix Actions → Publish changes. The first time it asks where releases go:
   - **GitHub** (easiest): it signs you in through your browser (GitHub shows a code to type in), then makes
     a public repository called `noid-os` for you. You never type a Git command.
   - **Another place** (Codeberg, GitLab, your own server): a repository you made yourself, with the Git
     login you already use. An SSH address is used for sending, and the matching https address for
     downloading.
3. Build the ISO after that first release (`iso/README.md`), so the computers you install know where to look.

The repository must be **public**: the other computers download from it without logging in. Only the
shared half ever goes there, after the privacy check.

## Publishing a release

Change files in `lib/`, `modules/` or `flake.nix` (or run Update & Rebuild, for newer versions of
everything), Rebuild, check that everything works, then Nix Actions → Publish changes. In its window it:

1. gets what is published now, and lists what changed since then (nothing changed: nothing is published);
2. asks for a one-line note, which the other computers show before they install it;
3. runs the **privacy check** (private network addresses, share addresses and logins, password hashes,
   private keys, and anything from your own `hosts/` files) and stops if it finds something;
4. evaluates **your own system with exactly those files**. If it does not evaluate, nothing is published.
   If it is not the system you are running (you changed something since your last Rebuild), it asks first;
5. sends the release. Your folder's `release.json` gets the new number; nothing else in it changes.

Your folder does not need to be a Git repository. The copy that is sent lives in
`~/.local/share/noid-sync/channel` and is made exactly like the published repository before each release,
so there is never anything to merge.

## On the other computers

Nix Actions → **Noid-OS Update**:

- shows "Release 7 is out", with your notes since the release that computer has. **Install** or **Not now**;
- installing puts the release's shared files in place (after a copy of the old ones) and rebuilds in a
  terminal window, like Rebuild;
- if the rebuild fails, the old files go back by themselves and the computer stays on its release;
- shared files changed on that computer are listed before installing; they are replaced, and the old ones
  are kept in `~/.local/state/noid-sync/previous`;
- flakes added there with Add a Flake stay; they are locked again after the release's lock comes in.
  Everything else gets exactly the versions your release was tested with;
- when it is up to date, the same window offers **Go back to release N** (the release before), which is
  undone the same way;
- if the window was closed in the middle (or the power went), the next time it offers to finish
  installing, or to put the old files back.

## Keeping releases safe for computers that are not yours

A release has to work with every computer's own `hosts/` folder, which you never see:

- **Renaming or removing an option** that a user file may set breaks their rebuild (it goes back by itself,
  but they stay stuck). Leave the old name working: `lib.mkRenamedOptionModule [ "old" ] [ "new" ]`, or
  `lib.mkRemovedOptionModule` with a sentence on what to do.
- **New options get defaults.** Existing computers never get a new line in their `user.nix`; only fresh
  installs do (`iso/calamares/main.py`).
- **A module must not need a file in `hosts/`** that older installs do not have. Check with
  `builtins.pathExists` (as `drives.nix` does).
- Test on your own computer first: publishing checks that your system evaluates, not theirs.

## Where it lives

| What | File |
| --- | --- |
| Publish changes, Noid-OS Update, going back | `sync.py` |
| which files are shared, the trimmed lock, fingerprints in `release.json` | `shared.py` (also used by the ISO) |
| what counts as private | `privacy_check.py` (also used by the ISO) |
| the terminal window around Publish changes | `publish.sh` |
| installing in a terminal, with the copy and putting it back | `../rebuild.sh`, mode `sync` |
| the menu rows and the `myOS.sync.publish` / `module.sync.enable` switches | `../../nix-actions.nix` |
