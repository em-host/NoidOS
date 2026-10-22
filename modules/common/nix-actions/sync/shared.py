#!/usr/bin/env python3
"""What of the configuration folder is shared, and how a shared copy is made.

The folder has two halves:

  shared     flake.nix, flake.lock, release.json, lib/, modules/
             The same on every computer. Written by whoever publishes releases,
             handed out on the install ISO and with every release.
  this computer's own
             hosts/ (hardware, drives, the user's choices, added flakes) and
             anything else in the folder. Never shared, never replaced.

    shared.py export <folder> <into>     a shared copy of <folder> (what the ISO
                                         carries and what a release contains)
    shared.py manifest <folder>          the fingerprints of its shared files

A shared copy has
  * the shared files, without Python's cache files and editor leftovers,
  * flake.lock trimmed: flakes added with "Add a Flake" are this computer's own
    (hosts/flakes), so the lock's `flakes` entry loses its inputs, and every entry
    nothing reaches any more is dropped. Each computer locks its own added flakes
    again (nixos-flakes sync, before every rebuild),
  * release.json with the fingerprint of every shared file ("files"), so a computer
    can tell later which of them were changed on it.

Used by iso/payload.nix and sync.py. Plain Python, nothing to install.
"""
import hashlib
import json
import os
import shutil
import sys

SHARED_FILES = ("flake.nix", "flake.lock", "release.json")
SHARED_DIRS = ("lib", "modules")
SHARED = SHARED_FILES + SHARED_DIRS

# Never part of a shared copy, wherever they are.
SKIP_DIRS = {"__pycache__", ".git", ".direnv", ".mypy_cache", ".pytest_cache"}
SKIP_SUFFIXES = (".pyc", ".pyo", "~", ".swp", ".swo", ".orig", ".rej")
SKIP_NAMES = {".DS_Store"}

RELEASE_ABOUT = ("Release information of this Noid-OS configuration, written by Nix Actions "
                 "-> Publish changes. Do not edit it by hand.")


def skipped(name, folder=False):
    """Never shared: caches, editor leftovers, and hidden folders (.git, .vscode, .ruff_cache...)."""
    return (name in SKIP_DIRS or name in SKIP_NAMES or name.endswith(SKIP_SUFFIXES)
            or (folder and name.startswith(".")))


def shared_files(root):
    """-> sorted relative paths of the shared files under `root` (symbolic links left out)."""
    found = []
    for name in SHARED_FILES:
        path = os.path.join(root, name)
        if os.path.isfile(path) and not os.path.islink(path):
            found.append(name)
    for top in SHARED_DIRS:
        base = os.path.join(root, top)
        if not os.path.isdir(base) or os.path.islink(base):
            continue
        for dirpath, dirs, files in os.walk(base):
            dirs[:] = sorted(d for d in dirs
                             if not skipped(d, folder=True) and not os.path.islink(os.path.join(dirpath, d)))
            for name in sorted(files):
                path = os.path.join(dirpath, name)
                if skipped(name) or os.path.islink(path):
                    continue
                found.append(os.path.relpath(path, root))
    return sorted(found)


def fingerprint(path):
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 16), b""):
            digest.update(block)
    return digest.hexdigest()


def manifest(root):
    """{relative path: sha256} of the shared files, release.json itself left out
    (it cannot hold its own fingerprint)."""
    return {rel: fingerprint(os.path.join(root, rel))
            for rel in shared_files(root) if rel != "release.json"}


# ---------------------------------------------------------------------------
# release.json
# ---------------------------------------------------------------------------


def read_release(root):
    """-> the release information in `root` ({} when there is none or it is unreadable)."""
    try:
        with open(os.path.join(root, "release.json"), encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def release_number(info):
    number = info.get("release", 0)
    return number if isinstance(number, int) and number >= 0 else 0


def release_text(info):
    """release.json as written: a fixed order of keys, the fingerprints last."""
    ordered = {"about": RELEASE_ABOUT}
    for key in ("channel", "release", "date", "notes"):
        if key in info:
            ordered[key] = info[key]
    for key, value in info.items():
        if key not in ordered and key != "files":
            ordered[key] = value
    if "files" in info:
        ordered["files"] = info["files"]
    return json.dumps(ordered, indent=2, ensure_ascii=False) + "\n"


# ---------------------------------------------------------------------------
# flake.lock
# ---------------------------------------------------------------------------


def trim_lock(lock):
    """The lock without what flakes added on this computer pulled in.

    An entry can be reached by name or through a "follows" list (a path of names
    that starts at the root); whatever cannot be reached either way is dropped.
    """
    if lock.get("version") != 7 or lock.get("root") != "root":
        raise ValueError("flake.lock has a layout this does not know (expected version 7)")
    nodes = dict(lock["nodes"])
    if "flakes" in nodes:
        nodes["flakes"] = {k: v for k, v in nodes["flakes"].items() if k != "inputs"}

    def follow(path):
        key = "root"
        for step in path:
            target = nodes[key].get("inputs", {})[step]
            key = follow(target) if isinstance(target, list) else target
        return key

    seen, todo = set(), ["root"]
    while todo:
        key = todo.pop()
        if key in seen:
            continue
        seen.add(key)
        for target in nodes[key].get("inputs", {}).values():
            todo.append(follow(target) if isinstance(target, list) else target)
    return {"nodes": {k: v for k, v in nodes.items() if k in seen}, "root": "root", "version": 7}


def lock_text(lock):
    return json.dumps(lock, indent=2, sort_keys=True) + "\n"


# ---------------------------------------------------------------------------
# Making a shared copy
# ---------------------------------------------------------------------------


def copy_file(src, dst):
    """Copies a file so its owner can change the copy (files from the Nix store are read-only)."""
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copyfile(src, dst)
    os.chmod(dst, 0o755 if os.stat(src).st_mode & 0o111 else 0o644)


def export(src, dst, release=None):
    """Writes a shared copy of folder `src` into `dst` (which must not hold shared files yet).

    `release`: the release information to write (default: src's own release.json).
    Its "files" are always worked out anew. -> the release information written.
    """
    rels = [r for r in shared_files(src) if r not in ("flake.lock", "release.json")]
    if "flake.nix" not in rels:
        raise FileNotFoundError(f"{src} has no flake.nix")
    os.makedirs(dst, exist_ok=True)
    for rel in rels:
        copy_file(os.path.join(src, rel), os.path.join(dst, rel))
    for top in SHARED_DIRS:
        if os.path.isdir(os.path.join(dst, top)):
            for dirpath, _dirs, _files in os.walk(os.path.join(dst, top)):
                os.chmod(dirpath, 0o755)

    lock_path = os.path.join(src, "flake.lock")
    if os.path.isfile(lock_path):
        with open(lock_path, encoding="utf-8") as f:
            lock = json.load(f)
        with open(os.path.join(dst, "flake.lock"), "w", encoding="utf-8") as f:
            f.write(lock_text(trim_lock(lock)))

    info = dict(read_release(src) if release is None else release)
    info.pop("files", None)
    info.setdefault("release", 0)
    info["files"] = manifest(dst)
    with open(os.path.join(dst, "release.json"), "w", encoding="utf-8") as f:
        f.write(release_text(info))
    return info


def main(argv):
    if len(argv) == 4 and argv[1] == "export":
        if any(os.path.exists(os.path.join(argv[3], name)) for name in SHARED):
            print(f"{argv[3]} already holds shared files", file=sys.stderr)
            return 1
        info = export(argv[2], argv[3])
        print(f"shared copy: release {release_number(info)}, {len(info['files'])} files")
        return 0
    if len(argv) == 3 and argv[1] == "manifest":
        print(json.dumps(manifest(argv[2]), indent=2))
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
