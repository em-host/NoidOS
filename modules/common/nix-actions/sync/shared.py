#!/usr/bin/env python3
"""
    shared.py export <folder> <into>     a shared copy (flake.lock trimmed, fingerprints in release.json)
    shared.py manifest <folder>          fingerprints of the shared files
"""
import hashlib
import json
import os
import shutil
import sys

SHARED_FILES = ("flake.nix", "flake.lock", "release.json")
SHARED_DIRS = ("lib", "modules")
SHARED = SHARED_FILES + SHARED_DIRS

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

def release_manifest(root):
    """manifest() of the copy export() would make: flake.lock fingerprinted as trimmed."""
    found = manifest(root)
    lock_path = os.path.join(root, "flake.lock")
    if "flake.lock" in found:
        with open(lock_path, encoding="utf-8") as f:
            text = lock_text(trim_lock(json.load(f)))
        found["flake.lock"] = hashlib.sha256(text.encode()).hexdigest()
    return found


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
