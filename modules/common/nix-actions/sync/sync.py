#!/usr/bin/env python3
"""Releases: the shared half of the configuration, from one computer to all the others.

One computer is where the configuration is worked on (myOS.sync.publish = true in
its hosts/users/user.nix). There, Nix Actions -> Publish changes sends the shared
parts (flake.nix, flake.lock, lib/, modules/; see shared.py) to a public Git
repository as a numbered release with a note. Every other computer gets Nix
Actions -> Get the latest release, which shows what is new and installs it when
its owner wants. hosts/, each computer's own half, is never published and never
replaced.

    noid-sync gui        Get the latest release (windows; installs through the
                         terminal action below)
    noid-sync back       go back to the release this computer had before
    noid-sync publish    Publish changes (in a terminal)
    noid-sync status     what this computer has, as JSON

  run by Nix Actions' rebuild in its "new release" mode (rebuild.sh):
    noid-sync apply      put the waiting release's files in place (after a copy
                         of the current ones)
    noid-sync restore    the rebuild failed: put that copy back
    noid-sync finish     the rebuild worked: keep the copy as "the release before"

Where things are kept (all of it this user's own):
    ~/.local/state/noid-sync/  pending.json, incoming/ (a release about to be
                               installed), backup/ (the files as they were before
                               it), previous/ (the release before the current one)
    ~/.local/share/noid-sync/  channel/ (publishing only: a copy of the repository)

The @...@ gaps are filled in by ../../nix-actions.nix.
"""
import contextlib
import datetime
import fcntl
import html
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

SETTINGS = json.loads(r"""@settings@""")
# lib (this folder), zenity, nix, git, gh (publishing only), flakeDir, flakeHost,
# publisher, install (the rebuild in "new release" mode; windows only)
sys.path.insert(0, SETTINGS["lib"])
import privacy_check  # noqa: E402
import shared  # noqa: E402

FLAKE = os.path.expanduser(SETTINGS["flakeDir"])
NIX = [SETTINGS["nix"], "--extra-experimental-features", "nix-command flakes"]
TITLE = "Get the latest release"
GENERATED = ("hosts/flakes/registry/flake.nix", "hosts/flakes/registry/flake.lock")
NOTES_KEPT = 50
DEFAULT_REPO = "noid-os"
COMMITTER = ["-c", "user.name=Noid-OS", "-c", "user.email=publish@noid-os.invalid",
             "-c", "commit.gpgsign=false"]


def _xdg(variable, fallback):
    base = os.environ.get(variable) or os.path.expanduser(fallback)
    return os.path.join(base, "noid-sync")


STATE = _xdg("XDG_STATE_HOME", "~/.local/state")
DATA = _xdg("XDG_DATA_HOME", "~/.local/share")
PENDING = os.path.join(STATE, "pending.json")
INCOMING = os.path.join(STATE, "incoming")
BACKUP = os.path.join(STATE, "backup")
PREVIOUS = os.path.join(STATE, "previous")
MIRROR = os.path.join(DATA, "channel")
PUBLISH_SETTINGS = os.path.join(DATA, "publish.json")


class Problem(Exception):
    pass


class Stopped(Exception):
    """The person said no. Not an error."""


def run(cmd, **kwargs):
    kwargs.setdefault("capture_output", True)
    kwargs.setdefault("text", True)
    return subprocess.run(cmd, **kwargs)


def last_lines(text, count=12):
    text = re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", text or "")
    lines = [line for line in text.strip().splitlines() if line.strip()]
    return "\n".join(lines[-count:])


# ---------------------------------------------------------------------------
# Files
# ---------------------------------------------------------------------------


def remove(path):
    if os.path.islink(path) or os.path.isfile(path):
        os.unlink(path)
    elif os.path.isdir(path):
        shutil.rmtree(path)


def write_atomic(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    handle, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=f".{os.path.basename(path)}.")
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as out:
            out.write(text)
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(tmp)
        raise


def copy_shared(src, dst, extra=()):
    """Copies the shared files of folder `src` (and the files `extra`, where they
    exist) into the new folder `dst`."""
    if os.path.lexists(dst):
        remove(dst)
    os.makedirs(dst)
    for rel in [*shared.shared_files(src), *extra]:
        source = os.path.join(src, rel)
        if os.path.isfile(source):
            shared.copy_file(source, os.path.join(dst, rel))


def replace_shared(src, dst):
    """Makes the shared files of folder `dst` those of `src`: lib/ and modules/
    exactly, flake.nix, flake.lock and release.json where `src` has them (one that
    is missing there is kept, so the folder never loses its lock or where its
    releases come from). Nothing else in `dst` (hosts/ in particular) is touched."""
    for name in shared.SHARED_FILES:
        source, target = os.path.join(src, name), os.path.join(dst, name)
        if os.path.isfile(source):
            tmp = target + ".noid-new"
            shared.copy_file(source, tmp)
            os.replace(tmp, target)
    wanted = shared.shared_files(src)
    for name in shared.SHARED_DIRS:
        target = os.path.join(dst, name)
        new, old = os.path.join(dst, f".{name}.noid-new"), os.path.join(dst, f".{name}.noid-old")
        for leftover in (new, old):
            if os.path.lexists(leftover):
                remove(leftover)
        os.makedirs(new)
        for rel in wanted:
            if rel.startswith(name + "/"):
                shared.copy_file(os.path.join(src, rel), os.path.join(new, rel[len(name) + 1:]))
        for dirpath, _dirs, _files in os.walk(new):
            os.chmod(dirpath, 0o755)
        if os.path.lexists(target):
            os.rename(target, old)
        os.rename(new, target)
        if os.path.lexists(old):
            remove(old)


def track_in_git(root):
    """When the folder is a Git repository, Nix only sees the files Git knows about."""
    git = SETTINGS.get("git")
    if not git:
        return
    probe = run([git, "-C", root, "rev-parse", "--is-inside-work-tree"])
    if probe.returncode == 0 and probe.stdout.strip() == "true":
        present = [name for name in shared.SHARED + GENERATED if os.path.exists(os.path.join(root, name))]
        run([git, "-C", root, "add", "--intent-to-add", "--force", "--", *present])


def read_json(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def save_channel(channel):
    """Writes where releases come from into this folder's release.json."""
    info = shared.read_release(FLAKE)
    info["channel"] = channel
    write_atomic(os.path.join(FLAKE, "release.json"), shared.release_text(info))


def changed_here(info):
    """Shared files this computer changed since its release came in: [(path, how)].
    (flake.lock is left out: Update & Rebuild and added flakes change it, and that is fine.)"""
    recorded = info.get("files")
    if not isinstance(recorded, dict):
        return []
    now = shared.manifest(FLAKE)
    found = []
    for rel in sorted(set(recorded) | set(now)):
        if rel == "flake.lock":
            continue
        if rel not in now:
            found.append((rel, "removed here"))
        elif rel not in recorded:
            found.append((rel, "added here"))
        elif now[rel] != recorded[rel]:
            found.append((rel, "changed here"))
    return found


# ---------------------------------------------------------------------------
# Where releases come from
# ---------------------------------------------------------------------------


def normalize_channel(text):
    """What someone types (a GitHub page, a Git address) -> the address Nix downloads from."""
    t = text.strip().rstrip("/")
    if re.fullmatch(r"github:[\w.-]+/[\w.-]+", t):
        return t
    m = re.fullmatch(r"(?:https?://)?(?:www\.)?github\.com/([\w.-]+)/([\w.-]+?)(?:\.git)?", t)
    if m:
        return f"github:{m.group(1)}/{m.group(2)}"
    m = re.fullmatch(r"(?:ssh://)?git@([\w.-]+)[:/]([\w./-]+?)(?:\.git)?", t)
    if m:
        if m.group(1) == "github.com" and m.group(2).count("/") == 1:
            return f"github:{m.group(2)}"
        return f"git+https://{m.group(1)}/{m.group(2)}"
    if re.match(r"git\+(https?|ssh|file)://\S+$", t):
        return t
    if re.match(r"(https?|ssh|file)://\S+$", t):
        return "git+" + t
    if t.startswith("/") and " " not in t:
        return "git+file://" + t
    raise ValueError(f'"{text}" is not an address of a Git repository '
                     "(for example https://codeberg.org/someone/noid-os).")


def push_url(channel):
    if channel.startswith("github:"):
        return f"https://github.com/{channel[len('github:'):]}.git"
    if channel.startswith("git+"):
        return channel[len("git+"):].split("?", 1)[0]
    raise ValueError(f"cannot publish to {channel}")


def shown(channel):
    """The channel the way a person reads it."""
    if channel.startswith("github:"):
        return "github.com/" + channel[len("github:"):]
    return re.sub(r"^git\+(https?://|ssh://|file://)?", "", channel).split("?", 1)[0]


def fetch(channel):
    """Downloads the newest release. -> its folder in the Nix store."""
    result = run([*NIX, "flake", "prefetch", "--json", "--refresh", channel])
    if result.returncode != 0:
        raise Problem(f"Could not download from {shown(channel)}.\n\n"
                      "Check the internet connection and try again. What went wrong:\n"
                      + last_lines(result.stderr, 6))
    try:
        path = json.loads(result.stdout)["storePath"]
    except (ValueError, KeyError) as e:
        raise Problem(f"Nix answered something unexpected: {e}") from e
    if not os.path.isfile(os.path.join(path, "flake.nix")):
        raise Problem(f"{shown(channel)} does not hold a Noid-OS release (there is no flake.nix).")
    return path


# ---------------------------------------------------------------------------
# Windows (zenity)
# ---------------------------------------------------------------------------


def zenity(*args, stdin=None, title=TITLE):
    result = subprocess.run([SETTINGS["zenity"], f"--title={title}", *args],
                            capture_output=True, text=True, input=stdin)
    return result.returncode, result.stdout.strip()


def info(text):
    zenity("--info", "--no-markup", "--width=480", f"--text={text}")


def error(text):
    zenity("--error", "--no-markup", "--width=520", f"--text={text}")


@contextlib.contextmanager
def busy(text):
    """A window with a moving bar while the work inside runs."""
    proc = subprocess.Popen(
        [SETTINGS["zenity"], "--progress", "--pulsate", "--no-cancel", "--auto-close",
         f"--title={TITLE}", f"--text={html.escape(text, quote=False)}", "--width=420"],
        stdin=subprocess.PIPE, text=True)
    try:
        yield
    finally:
        with contextlib.suppress(OSError):
            proc.stdin.close()
        with contextlib.suppress(OSError):
            proc.terminate()
        with contextlib.suppress(Exception):
            proc.wait(timeout=5)


def another_action_running():
    """Is a Nix action (a rebuild, a cleanup...) busy right now? Same lock as common.sh."""
    path = os.path.join(os.environ.get("XDG_RUNTIME_DIR") or "/tmp", "nix-actions.lock")
    try:
        fd = os.open(path, os.O_CREAT | os.O_RDWR, 0o600)
    except OSError:
        return False
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        fcntl.flock(fd, fcntl.LOCK_UN)
        return False
    except OSError:
        return True
    finally:
        os.close(fd)


def notes_since(info, after):
    notes = [n for n in info.get("notes", []) if isinstance(n, dict)
             and isinstance(n.get("release"), int) and n["release"] > after]
    notes.sort(key=lambda n: n["release"], reverse=True)
    lines = []
    for n in notes[:20]:
        lines.append(f"Release {n['release']}" + (f", {n['date']}" if n.get("date") else ""))
        for line in str(n.get("note", "")).splitlines() or [""]:
            lines.append("    " + line)
        lines.append("")
    if len(notes) > 20:
        lines.append(f"(and {len(notes) - 20} earlier releases)")
        lines.append("")
    return lines


def describe(local, remote, here):
    have, new = shared.release_number(local), shared.release_number(remote)
    lines = [f"Release {new} is out. This computer has "
             + (f"release {have}." if have else "no numbered release yet."), ""]
    news = notes_since(remote, have)
    if news:
        lines += ["What is new:", "", *news]
    lines += [
        "Installing it:",
        "  - brings this system's shared parts (flake.nix, flake.lock, lib/ and modules/)",
        f"    to release {new} and rebuilds. A window shows how far it is; it can take as",
        "    long as Update & Rebuild.",
        "  - leaves this computer's own settings (hosts/: its hardware, drives and your",
        "    choices) as they are.",
        f"  - puts everything back as it was if release {new} does not work on this computer.",
        f"  - sets the versions of programs to the ones release {new} was tested with.",
        "",
        "You can go back to the release you have now afterwards (Nix Actions ->",
        "Get the latest release).",
    ]
    if here:
        lines += ["", "Changed on this computer, and replaced by the release (a copy is kept in",
                  f"{PREVIOUS}):"]
        lines += [f"  {rel}  ({how})" for rel, how in here[:15]]
        if len(here) > 15:
            lines.append(f"  and {len(here) - 15} more")
    return "\n".join(lines) + "\n"


def start_install(kind, source, release, channel=None, rev=None):
    """Hands over to the rebuild in "new release" mode. Does not come back."""
    os.makedirs(STATE, exist_ok=True)
    write_atomic(PENDING, json.dumps({"kind": kind, "source": source, "release": release,
                                      "channel": channel, "rev": rev}, indent=2) + "\n")
    install = SETTINGS.get("install")
    if not install:
        raise Problem("The install step is missing (this tool was started without it).")
    os.execv(install, [install])


def ask_channel():
    code, text = zenity(
        "--entry", "--width=560",
        "--text=This computer does not know yet where new releases come from.\n\n"
        "Ask whoever set up this system for the address, and type it in here\n"
        "(for example https://github.com/someone/noid-os):",
        "--ok-label=Look for a release", "--cancel-label=Close")
    if code != 0 or not text.strip():
        return None
    try:
        return normalize_channel(text)
    except ValueError as e:
        error(str(e))
        return None


def gui_check():
    if SETTINGS.get("publisher"):
        info("This computer is where releases are made: use Publish changes.")
        return 0
    if not os.path.isfile(os.path.join(FLAKE, "flake.nix")):
        error(f"Could not find the configuration in {FLAKE} (there is no flake.nix there).")
        return 1
    if another_action_running():
        info("Another Nix action is running right now. Try again once it is done.")
        return 0
    if unfinished():
        return gui_unfinished()

    local = shared.read_release(FLAKE)
    channel = local.get("channel")
    if not channel:
        channel = ask_channel()
        if not channel:
            return 0
    try:
        with busy(f"Looking for a new release at {shown(channel)}..."):
            store = fetch(channel)
    except Problem as e:
        error(str(e))
        return 1
    if not local.get("channel"):
        save_channel(channel)  # it worked: remember it
        local = shared.read_release(FLAKE)

    remote = shared.read_release(store)
    have, new = shared.release_number(local), shared.release_number(remote)
    if new <= have:
        previous = shared.read_release(PREVIOUS) if os.path.isdir(PREVIOUS) else None
        text = f"This computer has the latest release ({have})." if new == have else \
            f"This computer has release {have}; the newest one published is {new}."
        if previous is not None:
            back = f"Go back to release {shared.release_number(previous)}"
            code, out = zenity("--info", "--no-markup", "--width=480", f"--text={text}",
                               "--ok-label=Close", f"--extra-button={back}")
            if out == back:
                return gui_back()
        else:
            info(text)
        return 0

    code, _ = zenity("--text-info", "--width=640", "--height=520", "--font=monospace 10",
                     f"--ok-label=Install release {new}", "--cancel-label=Not now",
                     stdin=describe(local, remote, changed_here(local)))
    if code != 0:
        return 0
    try:
        copy_shared(store, INCOMING)
    except OSError as e:
        error(f"Could not get release {new} ready: {e}")
        return 1
    start_install("update", INCOMING, new, channel=channel)
    return 0


def unfinished():
    """-> the install that was started and did not finish (its files are in place, its
    copy of the old ones too), or None."""
    pending = read_json(PENDING)
    if pending and pending.get("backupDone") and os.path.isfile(os.path.join(BACKUP, "flake.nix")):
        return pending
    return None


def gui_unfinished():
    pending = unfinished()
    release = pending.get("release")
    again = "Put the old files back"
    code, out = zenity(
        "--question", "--no-markup", "--width=540",
        f"--text=Installing release {release} did not finish last time: its window was closed, "
        "or the computer was turned off.\n\nFinish installing it now? (Or put back the files "
        "this computer had before.)",
        f"--ok-label=Finish installing release {release}", "--cancel-label=Not now",
        f"--extra-button={again}")
    if code == 0:
        os.execv(SETTINGS["install"], [SETTINGS["install"]])
    if out == again:
        if restore() != 0:
            error(f"The old files could not be put back. They are kept in {BACKUP}.")
            return 1
        info("The old files are back. To be sure the system matches them, open Nix Actions and "
             "choose Rebuild.")
    return 0


def gui_back():
    if another_action_running():
        info("Another Nix action is running right now. Try again once it is done.")
        return 0
    if unfinished():
        return gui_unfinished()
    if not os.path.isfile(os.path.join(PREVIOUS, "flake.nix")):
        info("There is no earlier release to go back to on this computer.")
        return 0
    have = shared.release_number(shared.read_release(FLAKE))
    back = shared.release_number(shared.read_release(PREVIOUS))
    code, _ = zenity(
        "--question", "--no-markup", "--width=520",
        f"--text=Go back to release {back}? This computer has release {have}.\n\n"
        "The shared parts (flake.nix, flake.lock, lib/ and modules/) go back to how they were, "
        "and the system is rebuilt. This computer's own settings (hosts/) stay as they are.\n\n"
        f"You can install release {have} or a newer one again later with Get the latest release.",
        f"--ok-label=Go back to release {back}", "--cancel-label=Not now")
    if code != 0:
        return 0
    start_install("back", PREVIOUS, back)
    return 0


# ---------------------------------------------------------------------------
# The steps the rebuild runs (in its terminal window)
# ---------------------------------------------------------------------------


def apply():
    pending = read_json(PENDING)
    if not pending or not os.path.isfile(os.path.join(str(pending.get("source")), "flake.nix")):
        print("There is no release waiting to be installed. Open Nix Actions and choose")
        print("Get the latest release.")
        return 1
    source, release = pending["source"], pending.get("release")
    if not os.path.isfile(os.path.join(FLAKE, "flake.nix")):
        print(f"Could not find the configuration in {FLAKE}.")
        return 1

    if pending.get("backupDone") and os.path.isfile(os.path.join(BACKUP, "flake.nix")):
        # The install was started before and did not finish: the copy made then is
        # the one of the files as they were, so it stays.
        print("Continuing the install that did not finish last time.")
    else:
        # A copy of everything that is about to change, first. (The added flakes' list in
        # hosts/flakes/registry is rewritten by the rebuild; it is kept so it can go back too.)
        fresh = BACKUP + ".new"
        copy_shared(FLAKE, fresh, extra=GENERATED)
        if os.path.lexists(BACKUP):
            remove(BACKUP)
        os.rename(fresh, BACKUP)
        pending["backupDone"] = True
        write_atomic(PENDING, json.dumps(pending, indent=2) + "\n")

    try:
        replace_shared(source, FLAKE)
        track_in_git(FLAKE)
    except BaseException:
        print("The new files could not be put in place. Putting the old ones back...")
        restore()
        raise
    if pending.get("kind") == "back":
        print(f"Release {release}, the one this computer had before, is back in place:")
    else:
        print(f"Release {release} is in place:")
    print("flake.nix, flake.lock, lib/ and modules/ were replaced. This computer's own")
    print("settings (hosts/) were left as they are.")
    return 0


def restore():
    if not os.path.isfile(os.path.join(BACKUP, "flake.nix")):
        print("There is no copy to put back.")
        return 1
    try:
        replace_shared(BACKUP, FLAKE)
        for rel in GENERATED:
            if os.path.isfile(os.path.join(BACKUP, rel)):
                shared.copy_file(os.path.join(BACKUP, rel), os.path.join(FLAKE, rel))
        track_in_git(FLAKE)
    except OSError as e:
        print(f"Putting the previous files back did not work: {e}")
        print(f"They are kept in {BACKUP}.")
        return 1
    for path in (PENDING, INCOMING, BACKUP):
        if os.path.lexists(path):
            remove(path)
    print("Your previous files are back in place: this computer stays on the release it had.")
    return 0


def finish():
    pending = read_json(PENDING) or {}
    if os.path.isdir(BACKUP):
        if os.path.lexists(PREVIOUS):
            remove(PREVIOUS)
        os.rename(BACKUP, PREVIOUS)
    for path in (PENDING, INCOMING):
        if os.path.lexists(path):
            remove(path)
    release = pending.get("release", shared.release_number(shared.read_release(FLAKE)))
    if pending.get("kind") == "back":
        print(f"Done. This computer is back on release {release}.")
    else:
        print(f"Done. Release {release} is installed.")
    return 0


def status():
    local = shared.read_release(FLAKE)
    previous = shared.read_release(PREVIOUS) if os.path.isdir(PREVIOUS) else None
    print(json.dumps({
        "folder": FLAKE,
        "publisher": bool(SETTINGS.get("publisher")),
        "channel": local.get("channel"),
        "release": shared.release_number(local),
        "previous": shared.release_number(previous) if previous is not None else None,
        "pending": read_json(PENDING),
        "changedHere": [rel for rel, _ in changed_here(local)],
    }, indent=2))
    return 0


# ---------------------------------------------------------------------------
# Publish changes (in a terminal)
# ---------------------------------------------------------------------------


def ask(question):
    try:
        return input(question).strip()
    except EOFError:
        return ""


def yes(question):
    return ask(f"{question} [y/N] ").lower() in ("y", "yes")


def say(*lines):
    for line in lines:
        print(line)


def gh(*args, interactive=False):
    if interactive:
        return subprocess.run([SETTINGS["gh"], *args])
    return run([SETTINGS["gh"], *args])


def setup_github():
    if not SETTINGS.get("gh"):
        raise Problem("GitHub's own command (gh) is missing.")
    if gh("auth", "status", "--hostname", "github.com").returncode != 0:
        say("", "First, sign in to GitHub (only this once). Below, GitHub shows a code;",
            "press Enter, your browser opens github.com, and you type the code in there.",
            "Make an account there first if you have none.", "")
        if gh("auth", "login", "--hostname", "github.com", "--git-protocol", "https", "--web",
              interactive=True).returncode != 0:
            raise Problem("Signing in to GitHub did not work. Nothing was published.")
    login = gh("api", "user", "--jq", ".login").stdout.strip()
    if not login:
        raise Problem("Could not find out your GitHub user name. Nothing was published.")

    name = ask(f"\nName of the repository on GitHub [{DEFAULT_REPO}]: ") or DEFAULT_REPO
    if not re.fullmatch(r"[A-Za-z0-9._-]+", name):
        raise Problem(f'"{name}" cannot be a repository name (letters, numbers, ".", "-" and "_").')
    full = f"{login}/{name}"
    view = gh("repo", "view", full, "--json", "visibility,isEmpty")
    if view.returncode == 0:
        try:
            data = json.loads(view.stdout)
        except ValueError:
            data = {}
        if data.get("visibility", "PUBLIC") != "PUBLIC":
            raise Problem(f"github.com/{full} is private, so other computers cannot download from it.\n"
                          "Make it public on github.com (its Settings, at the bottom), or choose "
                          "another name.")
        if not data.get("isEmpty", True):
            say(f"\ngithub.com/{full} already exists and is not empty. Publishing replaces",
                "flake.nix, flake.lock, lib/ and modules/ in it; other files stay.")
            if not yes("Use it?"):
                raise Stopped()
    else:
        say(f"\nMaking the public repository github.com/{full}...")
        made = gh("repo", "create", full, "--public",
                  "--description", "The shared configuration of a Noid-OS system (Nix Actions -> Publish changes)",
                  interactive=True)
        if made.returncode != 0:
            raise Problem("The repository could not be made. Nothing was published.")
    return f"github:{full}", None


def setup_other():
    say("", "Type the repository's address. It must be public, so the other computers can",
        "download from it. For example:  https://codeberg.org/you/noid-os",
        "(An SSH address such as git@codeberg.org:you/noid-os.git works too: then that is",
        "used for publishing, and the https address for downloading.)")
    text = ask("Address: ")
    if not text:
        raise Stopped()
    try:
        channel = normalize_channel(text)
    except ValueError as e:
        raise Problem(str(e)) from e
    push = text.strip() if re.match(r"(ssh://)?git@", text.strip()) else None
    return channel, push


def setup_channel():
    say("Publishing needs a place on the internet that the other computers download",
        "releases from: a public Git repository. Only flake.nix, flake.lock, lib/ and",
        "modules/ ever go there, after the privacy check. hosts/ never does.", "",
        "  1  GitHub: you sign in once with your browser, and the repository is made",
        "     for you (the easiest)",
        "  2  Another place: a repository you made yourself (Codeberg, GitLab, your own",
        "     server), with the Git login you already use", "")
    choice = ask("Choose 1 or 2 (or just press Enter to stop): ")
    if choice == "1":
        channel, push = setup_github()
    elif choice == "2":
        channel, push = setup_other()
    else:
        raise Stopped()
    os.makedirs(DATA, exist_ok=True)
    write_atomic(PUBLISH_SETTINGS, json.dumps({"channel": channel, "push": push}, indent=2) + "\n")
    save_channel(channel)
    say("", f"Releases go to {shown(channel)}. (This is remembered; it is in release.json.)")
    return channel


class Mirror:
    """This computer's copy of the repository releases are published to."""

    def __init__(self, channel):
        settings = read_json(PUBLISH_SETTINGS) or {}
        self.url = (settings.get("push") if settings.get("channel") == channel and settings.get("push")
                    else push_url(channel))
        self.dir = MIRROR
        self.branch = "main"

    def git(self, *args, interactive=False):
        cmd = [SETTINGS["git"], "-C", self.dir]
        if SETTINGS.get("gh") and self.url.startswith("https://github.com/"):
            # GitHub's login, from the sign-in above (only for these commands).
            cmd += ["-c", "credential.https://github.com.helper=",
                    "-c", f"credential.https://github.com.helper=!{SETTINGS['gh']} auth git-credential"]
        cmd += list(args)
        if interactive:
            return subprocess.run(cmd)
        return run(cmd)

    def refresh(self):
        """Makes the copy exactly what is published now."""
        origin = self.git("remote", "get-url", "origin") if os.path.isdir(os.path.join(self.dir, ".git")) else None
        if origin is None or origin.returncode != 0 or origin.stdout.strip() != self.url:
            if os.path.lexists(self.dir):
                remove(self.dir)
            os.makedirs(os.path.dirname(self.dir), exist_ok=True)
            os.makedirs(self.dir)
            for args in (["init", "--quiet"], ["remote", "add", "origin", self.url]):
                if self.git(*args).returncode != 0:
                    raise Problem(f"Could not set up a copy of {self.url}.")
        fetched = self.git("fetch", "--quiet", "--prune", "origin", interactive=True)
        if fetched.returncode != 0:
            raise Problem(f"Could not reach {self.url}. Check the internet connection (and the address).")
        branches = self.git("for-each-ref", "--format=%(refname:short)", "refs/remotes/origin").stdout.split()
        branches = [b[len("origin/"):] for b in branches if b != "origin/HEAD" and b.startswith("origin/")]
        head = self.git("ls-remote", "--symref", "origin", "HEAD").stdout
        m = re.search(r"ref: refs/heads/(\S+)\s+HEAD", head)
        if m and m.group(1) in branches:
            self.branch = m.group(1)
        elif "main" in branches:
            self.branch = "main"
        elif branches:
            self.branch = sorted(branches)[0]
        if self.branch in branches:
            steps = (["checkout", "--quiet", "-B", self.branch, f"origin/{self.branch}"],
                     ["reset", "--quiet", "--hard", f"origin/{self.branch}"], ["clean", "-qfdx"])
        else:  # nothing published yet
            steps = (["symbolic-ref", "HEAD", f"refs/heads/{self.branch}"], ["clean", "-qfdx"])
        for args in steps:
            done = self.git(*args)
            if done.returncode != 0:
                raise Problem(f"Could not prepare the copy of the repository:\n{last_lines(done.stderr, 4)}")
        if self.branch not in branches:
            self.git("rm", "-r", "-q", "--cached", "--ignore-unmatch", ".")

    def take(self, stage):
        """Puts the release in folder `stage` into the copy. Other files in the
        repository (a licence, say) stay."""
        for name in (*shared.SHARED, "README.md", "hosts"):
            path = os.path.join(self.dir, name)
            if os.path.lexists(path):
                remove(path)
        for name in (*shared.SHARED, "README.md"):
            source = os.path.join(stage, name)
            if os.path.isdir(source):
                shutil.copytree(source, os.path.join(self.dir, name))
            elif os.path.isfile(source):
                shutil.copyfile(source, os.path.join(self.dir, name))

    def commit_and_push(self, message):
        for args in (["add", "-A"], [*COMMITTER, "commit", "--quiet", "-m", message]):
            done = self.git(*args)
            if done.returncode != 0:
                raise Problem(f"Git could not record the release:\n{last_lines(done.stderr + done.stdout, 6)}")
        say("", f"Sending it to {self.url}...")
        if self.git("push", "--quiet", "origin", f"HEAD:refs/heads/{self.branch}", interactive=True).returncode != 0:
            raise Problem("Sending did not work (see above), so nothing was published. Check the internet\n"
                          "connection, and that you may write to that repository.")


def merged_notes(*infos):
    by_number = {}
    for one in infos:
        for note in one.get("notes", []) if isinstance(one.get("notes"), list) else []:
            if isinstance(note, dict) and isinstance(note.get("release"), int):
                by_number.setdefault(note["release"], note)
    return [by_number[n] for n in sorted(by_number, reverse=True)][:NOTES_KEPT]


def list_changes(old, new):
    rows = [(rel, "new") for rel in sorted(set(new) - set(old))]
    rows += [(rel, "removed") for rel in sorted(set(old) - set(new))]
    rows += [(rel, "changed") for rel in sorted(set(old) & set(new)) if old[rel] != new[rel]]
    return sorted(rows)


def readme(info):
    latest = info["notes"][0] if info.get("notes") else {}
    return (
        "# Noid-OS: the shared configuration\n\n"
        "This repository is written by **Nix Actions → Publish changes**. Do not change it here: "
        "every release replaces `flake.nix`, `flake.lock`, `lib/` and `modules/`.\n\n"
        "Computers running Noid-OS install a new release with **Nix Actions → Get the latest "
        "release**. Each computer keeps its own `hosts/` folder (its hardware, drives and "
        "choices), which is never part of this repository.\n\n"
        f"Latest: release {info['release']} ({info.get('date', '')}): {latest.get('note', '')}\n"
    )


def works_here(stage, scratch):
    """Evaluates this computer's own system with the files about to be published.
    -> True when it is exactly the system running now."""
    check = os.path.join(scratch, "check")
    shutil.copytree(stage, check)
    hosts = os.path.join(FLAKE, "hosts")
    if os.path.isdir(hosts):
        shutil.copytree(hosts, os.path.join(check, "hosts"), symlinks=True)
    if os.path.isfile(os.path.join(FLAKE, "flake.lock")):
        # (this computer's own lock: the published one leaves its added flakes out)
        shutil.copyfile(os.path.join(FLAKE, "flake.lock"), os.path.join(check, "flake.lock"))
    def system_of(flake):
        return run([*NIX, "--option", "warn-dirty", "false", "eval", "--no-write-lock-file", "--raw",
                    f'{flake}#nixosConfigurations."{SETTINGS["flakeHost"]}".config.system.build.toplevel.outPath'])

    running = os.path.realpath("/run/current-system")
    say("", "Checking that your own system still works with these files (about a minute)...")
    result = system_of(f"path:{check}")
    if result.returncode != 0:
        say(last_lines(result.stderr, 25))
        raise Problem("Your own system does not work with these files (see above), so nothing was\n"
                      "published. Fix it, Rebuild, and publish again.")
    if result.stdout.strip() == running:
        return True
    # Leftovers that are never published (Python's cache files, editor backups) can
    # end up in a system built from the folder itself. So: is the running system the
    # folder exactly as Rebuild sees it? Then it differs from the release only in those.
    say("Not quite the same. Checking against your folder as Rebuild sees it...")
    folder = system_of(FLAKE)
    if folder.returncode == 0 and folder.stdout.strip() == running:
        say("It is: the only difference is leftover files that are never published.")
        return True
    return False


def publish():
    if os.geteuid() == 0 and not os.environ.get("NOID_SYNC_ALLOW_ROOT"):
        raise Problem("Publish as yourself, not as root.")
    if not os.path.isfile(os.path.join(FLAKE, "flake.nix")):
        raise Problem(f"Could not find the configuration in {FLAKE} (there is no flake.nix there).")
    say("Publishing changes", f"Config folder: {FLAKE}", "")

    local = shared.read_release(FLAKE)
    channel = local.get("channel") or setup_channel()
    local = shared.read_release(FLAKE)
    mirror = Mirror(channel)
    say(f"Looking at what {shown(channel)} has now...")
    mirror.refresh()
    remote = shared.read_release(mirror.dir)
    have_local, have_remote = shared.release_number(local), shared.release_number(remote)
    if have_remote > have_local:
        say("", f"{shown(channel)} already has release {have_remote}, which this folder has never",
            f"had (it has release {have_local}). Publishing replaces it with what is in this folder.")
        if not yes("Publish anyway?"):
            raise Stopped()

    scratch = tempfile.mkdtemp(prefix="noid-publish-")
    try:
        stage = os.path.join(scratch, "release")
        draft = shared.export(FLAKE, stage, release=local)
        old_files = remote.get("files") if isinstance(remote.get("files"), dict) else {}
        changes = list_changes(old_files, draft["files"])
        if remote and not changes:
            say("", f"Nothing has changed since release {have_remote}. Nothing was published.")
            return 0
        say("", f"What changed since release {have_remote}:" if remote else
            f"The first release: {len(draft['files'])} files.")
        if remote:
            for rel, how in changes[:40]:
                say(f"  {how:8} {rel}")
            if len(changes) > 40:
                say(f"  and {len(changes) - 40} more")

        say("", "In one line, what is new? The other computers show this before they",
            "install it. (For example: Steam works on NVIDIA again.) Leave it empty to stop.")
        note = ask("> ")
        if not note:
            raise Stopped()

        number = max(have_local, have_remote) + 1
        today = datetime.date.today().isoformat()
        release = {key: value for key, value in local.items() if key not in ("files", "about")}
        release.update(channel=channel, release=number, date=today,
                       notes=merged_notes({"notes": [{"release": number, "date": today, "note": note}]},
                                          remote, local))
        remove(stage)
        final = shared.export(FLAKE, stage, release=release)
        with open(os.path.join(stage, "README.md"), "w", encoding="utf-8") as f:
            f.write(readme(final))

        problems = privacy_check.check(stage, os.path.join(FLAKE, "hosts"))
        if problems:
            privacy_check.report(problems, "Nothing was published", out=sys.stdout)
            return 1
        say("Privacy check: nothing private found.")

        if works_here(stage, scratch):
            say("Your computer runs exactly these files.")
        else:
            say("", "Your computer is not running exactly these files yet: since your last Rebuild",
                "something changed what your own system would be. The other computers would get",
                "them untested. Best: Rebuild first, check that everything works, then publish.")
            if not yes("Publish anyway?"):
                raise Stopped()

        mirror.take(stage)
        mirror.commit_and_push(f"Release {number}: {note}")
        write_atomic(os.path.join(FLAKE, "release.json"), shared.release_text(final))
        say("", f"Release {number} is published at {shown(channel)}.",
            "The other computers find it in Nix Actions -> Get the latest release.")
        return 0
    finally:
        shutil.rmtree(scratch, ignore_errors=True)


# ---------------------------------------------------------------------------


def main(argv):
    command = argv[1] if len(argv) > 1 else "gui"
    try:
        if command == "gui":
            return gui_check()
        if command == "back":
            return gui_back()
        if command == "apply":
            return apply()
        if command == "restore":
            return restore()
        if command == "finish":
            return finish()
        if command == "status":
            return status()
        if command == "publish":
            return publish()
    except Stopped:
        print("\nStopped. Nothing was published." if command == "publish" else "Stopped.")
        return 1
    except (Problem, OSError) as e:
        if command in ("gui", "back"):
            error(str(e))
        else:
            print(f"\n{e}")
        return 1
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
