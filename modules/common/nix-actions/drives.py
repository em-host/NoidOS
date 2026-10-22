#!/usr/bin/env python3
"""Nix Actions -> Drives: open another drive at a fixed folder on every start.

Lists the drives this computer does not use yet (the way the hardware scan finds
them), asks for a folder, writes hosts/drives.nix (read by
modules/common/drives.nix) and offers to rebuild. Removes one again the same way.
Runs as you: nothing here needs the password, the rebuild asks for it.

The @...@ gaps are filled in by ../nix-actions.nix.
"""
import json
import os
import re
import subprocess
import sys

SETTINGS = json.loads(r"""@settings@""")  # zenity, lsblk, nix, git, flakeDir, rebuild, user
TITLE = "Drives"
SUPPORTED = {"ext4", "ext3", "ext2", "btrfs", "xfs", "f2fs", "ntfs", "exfat", "vfat"}
# Partitions that belong to the boot process or to Windows itself.
SYSTEM_PARTITIONS = {
    "EFI System",
    "BIOS boot",
    "Microsoft reserved",
    "Windows recovery environment",
    "Linux swap",
}
SYSTEM_FOLDERS = ["/boot", "/nix", "/etc", "/usr", "/var", "/run", "/tmp", "/proc", "/sys",
                  "/dev", "/root", "/bin", "/sbin", "/lib", "/lib64"]
HEADER = """\
# Drives added with "Drives" in Nix Actions (see modules/common/drives.nix).
# Each one is opened at its folder every time the computer starts; a missing one
# does not stop the computer from starting. To remove one: Nix Actions -> Drives,
# or delete its lines here and Rebuild.
"""


class Problem(Exception):
    pass


# ---------------------------------------------------------------------------
# Windows
# ---------------------------------------------------------------------------


def zenity(*args):
    result = subprocess.run([SETTINGS["zenity"], f"--title={TITLE}", *args], capture_output=True, text=True)
    return result.returncode, result.stdout.strip()


def info(text):
    zenity("--info", "--no-markup", "--width=480", f"--text={text}")


def error(text):
    zenity("--error", "--no-markup", "--width=480", f"--text={text}")


def ask(text, ok="Yes", cancel="No"):
    code, _ = zenity("--question", "--no-markup", "--width=480", f"--text={text}",
                     f"--ok-label={ok}", f"--cancel-label={cancel}")
    return code == 0


def choose(text, columns, rows, ok="Next"):
    """rows: lists of strings, the first one hidden (it is what comes back)."""
    args = ["--list", "--width=760", "--height=360", f"--text={text}", f"--ok-label={ok}",
            "--cancel-label=Close", "--hide-column=1", "--print-column=1"]
    for column in ["id", *columns]:
        args.append(f"--column={column}")
    for row in rows:
        args.extend(row)
    code, out = zenity(*args)
    return out.split("|")[0] if code == 0 and out else None


# ---------------------------------------------------------------------------
# What is there, and what is already used
# ---------------------------------------------------------------------------


def size_text(size):
    size = int(size or 0)
    for unit, step in (("TB", 1000**4), ("GB", 1000**3), ("MB", 1000**2)):
        if size >= step:
            return f"{size / step:.1f} {unit}" if size < 10 * step else f"{size / step:.0f} {unit}"
    return f"{size} B"


def flatten(devices, disk=None):
    for device in devices or []:
        here = disk
        if device.get("type") == "disk":
            here = device
        yield device, here
        yield from flatten(device.get("children"), here)


def fstab_entries(path="/etc/fstab"):
    """-> (devices, folders) named in fstab: devices as UUID=, /dev/... or LABEL=."""
    devices, folders = set(), set()
    try:
        with open(path) as f:
            for line in f:
                fields = line.split()
                if len(fields) >= 2 and not fields[0].startswith("#"):
                    devices.add(fields[0])
                    folders.add(fields[1])
    except OSError:
        pass
    return devices, folders


def in_use(device, fstab_devices):
    uuid, label, path = device.get("uuid"), device.get("label"), device.get("path")
    names = {f"UUID={uuid}", f"/dev/disk/by-uuid/{uuid}", path}
    if label:
        names |= {f"LABEL={label}", f"/dev/disk/by-label/{label}"}
    if names & fstab_devices:
        return True
    system = {"/", "/boot", "/nix", "/home", "[SWAP]"}
    return any(m in system for m in (device.get("mountpoints") or []) if m)


def candidates(lsblk_json, fstab_devices, configured_uuids):
    """The drives that could be added: [(uuid, label, size, kind, disk text, device)]."""
    found = []
    for device, disk in flatten(lsblk_json.get("blockdevices")):
        fstype, uuid = device.get("fstype"), device.get("uuid")
        if fstype not in SUPPORTED or not uuid or uuid in configured_uuids:
            continue
        if device.get("parttypename") in SYSTEM_PARTITIONS or in_use(device, fstab_devices):
            continue
        model = ((disk or {}).get("model") or (disk or {}).get("name") or "").strip()
        if (disk or {}).get("rm") or (disk or {}).get("hotplug"):
            model += " (USB / removable)"
        kind = {"ntfs": "Windows (NTFS)", "exfat": "exFAT", "vfat": "FAT"}.get(fstype, f"Linux ({fstype})")
        found.append((uuid, device.get("label") or "", size_text(device.get("size")), kind, model, device))
    return found


def scan():
    result = subprocess.run(
        [SETTINGS["lsblk"], "--json", "--bytes", "--output",
         "NAME,PATH,UUID,FSTYPE,LABEL,SIZE,TYPE,PARTTYPENAME,MOUNTPOINTS,MODEL,RM,HOTPLUG"],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        raise Problem(f"The drives could not be listed: {result.stderr.strip()}")
    return json.loads(result.stdout)


# ---------------------------------------------------------------------------
# hosts/drives.nix
# ---------------------------------------------------------------------------


def drives_file():
    return os.path.join(SETTINGS["flakeDir"], "hosts", "drives.nix")


def read_drives():
    path = drives_file()
    if not os.path.exists(path):
        return {}
    result = subprocess.run(
        [SETTINGS["nix"], "--extra-experimental-features", "nix-command", "eval", "--json", "--file", path],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        raise Problem(f"hosts/drives.nix has a mistake in it, so it was left alone:\n\n{result.stderr.strip()[-600:]}")
    return json.loads(result.stdout)


def nix_string(text):
    return '"' + str(text).replace("\\", "\\\\").replace('"', '\\"').replace("${", "\\${") + '"'


def render(drives):
    lines = [HEADER + "{"]
    for folder in sorted(drives):
        d = drives[folder]
        lines.append(f"  {nix_string(folder)} = {{")
        lines.append(f"    uuid = {nix_string(d['uuid'])};")
        lines.append(f"    fsType = {nix_string(d['fsType'])};")
        if d.get("label"):
            lines.append(f"    label = {nix_string(d['label'])};")
        if d.get("options"):
            lines.append("    options = [ " + " ".join(nix_string(o) for o in d["options"]) + " ];")
        lines.append("  };")
    lines.append("}")
    return "\n".join(lines) + "\n"


def write_drives(drives):
    path = drives_file()
    tmp = path + ".new"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(render(drives))
    os.replace(tmp, path)
    # Nix only sees files Git knows about, when the folder is a Git repository.
    root = SETTINGS["flakeDir"]
    probe = subprocess.run([SETTINGS["git"], "-C", root, "rev-parse", "--is-inside-work-tree"],
                           capture_output=True, text=True)
    if probe.returncode == 0 and probe.stdout.strip() == "true":
        subprocess.run([SETTINGS["git"], "-C", root, "add", "--intent-to-add", "--force", "--", path],
                       capture_output=True)


# ---------------------------------------------------------------------------
# The folder
# ---------------------------------------------------------------------------


def default_folder(label, device, taken):
    base = re.sub(r"[^A-Za-z0-9._-]+", "-", label or "").strip("-.").lower() or device.get("name", "drive")
    folder, n = f"/mnt/{base}", 2
    while folder in taken:
        folder, n = f"/mnt/{base}-{n}", n + 1
    return folder


def check_folder(text, taken, user):
    """-> the folder, cleaned up. Problem with the reason if it cannot be used."""
    folder = text.strip()
    if not folder.startswith("/"):
        raise Problem("The folder has to be a full path, starting with /, for example /mnt/games.")
    if re.search(r"\s", folder):
        raise Problem("The folder cannot contain spaces. Use - or _ instead, for example /mnt/my-games.")
    if not re.fullmatch(r"/[A-Za-z0-9._/-]+", folder):
        raise Problem("Use only letters, numbers, - _ . and / in the folder.")
    folder = os.path.normpath(folder)
    if folder in ("/", "/home", "/mnt", "/media", "/srv"):
        raise Problem(f"{folder} itself cannot be used. Pick a folder inside it, for example /mnt/games.")
    for system in SYSTEM_FOLDERS:
        if folder == system or folder.startswith(system + "/"):
            raise Problem(f"{folder} is a folder the system itself needs. Pick one under /mnt, for example /mnt/games.")
    if re.fullmatch(r"/home/[^/]+", folder):
        raise Problem(f"{folder} is a whole home folder. Pick one inside it, for example /home/{user}/Games, or one under /mnt.")
    for other in taken:
        if folder == other:
            raise Problem(f"{folder} is already used for another drive.")
        if folder.startswith(other + "/") or other.startswith(folder + "/"):
            raise Problem(f"{folder} would be inside {other} (or the other way round), which is used for another drive.")
    if os.path.isdir(folder) and not os.path.ismount(folder):
        try:
            if os.listdir(folder):
                raise Problem(f"{folder} already has files in it. They would be hidden behind the drive, so pick another folder.")
        except PermissionError:
            raise Problem(f"{folder} already exists and cannot be looked into. Pick another folder.")
    return folder


# ---------------------------------------------------------------------------
# The actions
# ---------------------------------------------------------------------------


def offer_rebuild(what):
    if ask(f"{what}\n\nIt takes effect after a rebuild. Rebuild now?", ok="Rebuild", cancel="Later"):
        os.execv(SETTINGS["rebuild"], [SETTINGS["rebuild"]])
    info("Saved. It takes effect the next time you choose Rebuild in Nix Actions.")


def add(drives):
    fstab_devices, fstab_folders = fstab_entries()
    found = candidates(scan(), fstab_devices, {d["uuid"] for d in drives.values()})
    if not found:
        info("There is no drive this computer does not use already.\n\n"
             "A drive shows up here once it is connected and has a partition with a file system on it. "
             "A brand-new, empty drive needs one first: open GParted, create a partition table and an "
             "ext4 partition (or NTFS / exFAT to share it with Windows), then come back here.")
        return
    rows = [[uuid, label or "(no name)", size, kind, disk] for uuid, label, size, kind, disk, _ in found]
    uuid = choose("Which drive should open at a folder every time the computer starts?",
                  ["Name", "Size", "Kind", "Disk"], rows)
    if not uuid:
        return
    _, label, size, kind, disk, device = next(f for f in found if f[0] == uuid)

    taken = set(drives) | {f for f in fstab_folders if f.startswith("/")}
    folder = default_folder(label, device, taken)
    while True:
        code, text = zenity("--entry", "--width=480",
                            f"--text=Which folder should {label or 'the drive'} ({size}) open at?\n"
                            "It stays the same every time; something under /mnt is usual.",
                            f"--entry-text={folder}", "--ok-label=Next", "--cancel-label=Close")
        if code != 0:
            return
        try:
            folder = check_folder(text, taken, SETTINGS["user"])
            break
        except Problem as e:
            error(str(e))
            folder = text.strip() or folder

    note = ""
    if device.get("fstype") == "ntfs":
        note = ("\n\nA Windows drive only opens when Windows was shut down completely. If it does not "
                "open: in Windows, turn off Fast Startup (Control Panel > Power Options), then shut down.")
    if device.get("mountpoints") and any(device["mountpoints"]):
        note += "\n\nIt is open somewhere else right now; after the rebuild it is at the new folder from the next start on."
    if not ask(f"{label or 'The drive'} ({size}, {kind}) will open at {folder} every time the computer starts.{note}",
               ok="Add it", cancel="Cancel"):
        return
    entry = {"uuid": uuid, "fsType": device["fstype"]}
    if label:
        entry["label"] = label
    write_drives({**drives, folder: entry})
    offer_rebuild(f"{label or 'The drive'} was added at {folder}.")


def remove(drives):
    rows = [[folder, folder, d.get("label") or "(no name)", d.get("fsType", "")] for folder, d in sorted(drives.items())]
    folder = choose("Which drive should no longer be opened?", ["Folder", "Name", "Kind"], rows, ok="Remove")
    if not folder:
        return
    if not ask(f"{folder} will no longer be opened when the computer starts.\n\n"
               "Nothing on the drive is deleted; it can be added again any time.", ok="Remove it", cancel="Cancel"):
        return
    rest = {f: d for f, d in drives.items() if f != folder}
    write_drives(rest)
    offer_rebuild(f"{folder} was removed.")


def main():
    try:
        if not os.path.isfile(os.path.join(SETTINGS["flakeDir"], "flake.nix")):
            raise Problem(f"Could not find the NixOS configuration in {SETTINGS['flakeDir']}.")
        drives = read_drives()
        if drives:
            choice = choose("What would you like to do?", ["Action"],
                            [["add", "Add a drive"], ["remove", "Remove a drive"]], ok="Go")
            if choice == "add":
                add(drives)
            elif choice == "remove":
                remove(drives)
        else:
            add(drives)
    except Problem as e:
        error(str(e))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
