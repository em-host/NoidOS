#!/usr/bin/env python3
"""Nix Actions -> App install locations: move installed Flatpak apps between drives.

    app-drives          choose an app and a drive (windows)
    app-drives move     do the move chosen there (run in a terminal by app-drives.sh)
"""
import json
import os
import shutil
import subprocess
import sys

SETTINGS = json.loads(r"""@settings@""")  # zenity, flatpak, locations {id: {name, path, mountPoint}}, declared, mover
TITLE = "App install locations"
PENDING = os.path.join(os.environ.get("XDG_RUNTIME_DIR") or "/tmp", "noid-app-move.json")
MAIN = "system"


def zenity(*args):
    result = subprocess.run([SETTINGS["zenity"], f"--title={TITLE}", *args], capture_output=True, text=True)
    return result.returncode, result.stdout.strip()


def info(text):
    zenity("--info", "--no-markup", "--width=480", f"--text={text}")


def error(text):
    zenity("--error", "--no-markup", "--width=480", f"--text={text}")


def flags(place):
    return ["--system"] if place == MAIN else [f"--installation={place}"]


def flatpak(place, *args, capture=True):
    cmd = [SETTINGS["flatpak"], *args[:1], *flags(place), *args[1:]]
    if capture:
        return subprocess.run(cmd, capture_output=True, text=True)
    return subprocess.run(cmd)


def places():
    """-> [(id, name, folder)] of the locations that can be used right now."""
    found = [(MAIN, "Main drive", "/var/lib/flatpak")]
    for place, loc in sorted(SETTINGS["locations"].items(), key=lambda kv: kv[1]["name"].lower()):
        mount = loc.get("mountPoint")
        if mount and not os.path.ismount(mount):
            continue
        if os.path.isdir(os.path.join(loc["path"], "repo")):
            found.append((place, loc["name"], loc["path"]))
    return found


def free_space(folder):
    try:
        return f"{shutil.disk_usage(folder).free / 1e9:.0f} GB free"
    except OSError:
        return ""


def installed(place):
    """-> [{app, name, ref, origin, size}] of the apps in one location."""
    result = flatpak(place, "list", "--app", "--columns=application,name,ref,origin,size")
    apps = []
    for line in result.stdout.splitlines():
        fields = line.split("\t")
        if len(fields) >= 5:
            apps.append(dict(zip(("app", "name", "ref", "origin", "size"), fields[:5], strict=True)))
    return apps


def choose(text, columns, rows, ok):
    args = ["--list", "--width=720", "--height=420", f"--text={text}", f"--ok-label={ok}",
            "--cancel-label=Close", "--hide-column=1", "--print-column=1"]
    for column in ["id", *columns]:
        args.append(f"--column={column}")
    for row in rows:
        args.extend(row)
    code, out = zenity(*args)
    return out.split("|")[0] if code == 0 and out else None


def gui():
    available = places()
    if len(available) < 2:
        info("There is no other drive to put apps on yet.\n\n"
             "Apps can go on any Linux-formatted drive (ext4, btrfs, xfs) that opens every time the "
             "computer starts: add one with Nix Actions -> Drives, then Rebuild. "
             "Drives formatted for Windows (NTFS, exFAT) cannot hold apps.")
        return 0
    names = {place: name for place, name, _ in available}

    apps = {}
    rows = []
    for place, name, _ in available:
        for app in installed(place):
            key = f"{place}:{app['app']}"
            apps[key] = dict(app, place=place)
            rows.append([key, app["name"] or app["app"], name, app["size"]])
    if not rows:
        info("No Flatpak apps are installed yet.")
        return 0
    rows.sort(key=lambda r: r[1].lower())
    key = choose("Which app do you want to move?", ["App", "Where it is", "Size"], rows, "Next")
    if not key:
        return 0
    app = apps[key]

    if app["place"] == MAIN and app["app"] in SETTINGS["declared"]:
        info(f"{app['name']} is listed in this computer's settings "
             "(module.app-store.flatpak.apps), so it stays on the main drive.")
        return 0

    targets = [[place, name, free_space(folder)] for place, name, folder in available if place != app["place"]]
    target = choose(f"Move {app['name']} ({app['size']}) to:", ["Drive", "Space"], targets, "Next")
    if not target:
        return 0

    code, _ = zenity("--question", "--no-markup", "--width=520",
                     f"--text=Move {app['name']} from {names[app['place']]} to {names[target]}?\n\n"
                     f"It is downloaded again onto {names[target]}, then removed from {names[app['place']]}. "
                     "Its saves and settings stay where they are.",
                     "--ok-label=Move", "--cancel-label=Not now")
    if code != 0:
        return 0
    with open(PENDING, "w", encoding="utf-8") as f:
        json.dump({"name": app["name"] or app["app"], "ref": app["ref"], "origin": app["origin"],
                   "source": app["place"], "target": target,
                   "sourceName": names[app["place"]], "targetName": names[target]}, f)
    os.execv(SETTINGS["mover"], [SETTINGS["mover"]])


def move():
    try:
        with open(PENDING, encoding="utf-8") as f:
            job = json.load(f)
    except (OSError, ValueError):
        print("There is nothing to move. Open Nix Actions and choose App install locations.")
        return 1
    os.unlink(PENDING)
    name, ref, origin = job["name"], job["ref"], job["origin"]
    print(f"Moving {name} from {job['sourceName']} to {job['targetName']}.\n")

    remotes = flatpak(job["target"], "remotes", "--columns=name").stdout.split()
    if origin not in remotes:
        print(f"{job['targetName']} cannot install from \"{origin}\", where {name} comes from.")
        print("Nothing was changed.")
        return 1

    print(f"Step 1 of 2: installing {name} on {job['targetName']}...")
    if flatpak(job["target"], "install", "--noninteractive", "-y", origin, ref, capture=False).returncode != 0:
        print(f"\nInstalling on {job['targetName']} did not work (see above). Nothing was changed.")
        return 1

    print(f"\nStep 2 of 2: removing it from {job['sourceName']}...")
    if flatpak(job["source"], "uninstall", "--noninteractive", "-y", ref, capture=False).returncode != 0:
        print(f"\n{name} is on both drives now. Remove the copy on {job['sourceName']} in the app store.")
        return 1
    flatpak(job["source"], "uninstall", "--noninteractive", "-y", "--unused", capture=False)

    print(f"\nDone. {name} is on {job['targetName']} now; its saves and settings stayed where they were.")
    return 0


def main(argv):
    command = argv[1] if len(argv) > 1 else "gui"
    if command == "gui":
        return gui()
    if command == "move":
        return move()
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
