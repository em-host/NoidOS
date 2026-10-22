#!/usr/bin/env python3
"""Stops the shared configuration from leaving this computer when it carries something private.

    privacy_check.py <what is about to be shared> [<this computer's hosts/ folder>]

Runs before anything is handed out: when the install ISO is built (iso/payload.nix)
and before Publish changes sends a release online (sync.py). Both carry only the
shared parts, flake.nix, flake.lock, lib/ and modules/ (shared.py). Everything that
belongs to one computer or one person lives in hosts/, which is never shared,
and secrets live outside the folder altogether (modules/common/secrets.nix). This
looks for what slipped through anyway:

  * addresses of private networks (10.x, 192.168.x, 172.16-31.x) and network
    shares (//server/share, smb://)  (privacy-check: ok)
  * share logins (credentials=...), password hashes, private keys,  (privacy-check: ok)
    passwords written into a setting (password = "...")  (privacy-check: ok)
  * anything taken from this computer's own hosts/ files: its IP addresses,
    share addresses, home folder and disk IDs

A line that is fine after all (an example in a comment, say) can carry the
words "privacy-check: ok".
"""
import os
import re
import sys

ALLOW = "privacy-check: ok"
TEXT_SUFFIXES = (".nix", ".py", ".sh", ".js", ".qml", ".json", ".md", ".txt", ".conf", ".lock", ".svg")

IPV4 = r"(?<![\w.])(?:\d{1,3}\.){3}\d{1,3}(?![\w.])"
GENERAL = [
    ("an address of a private network",
     re.compile(r"(?<![\w.])(?:10\.\d{1,3}|192\.168|172\.(?:1[6-9]|2\d|3[01])\.\d{1,3})\.\d{1,3}(?:\.\d{1,3})?(?![\w.])")),
    ("a network share address", re.compile(r"(?<![:\w/])//[A-Za-z0-9][\w.-]*/[^\s\"'`)]+|\bsmb://|\bcifs://")),
    ("a share login file (credentials=)", re.compile(r"credentials=")),  # privacy-check: ok
    ("a password hash", re.compile(r"\$(?:6|5|y|2[aby])\$[./A-Za-z0-9]{2,}")),
    ("a private key", re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----")),
    ("a password written into a setting",
     re.compile(r"\b(?:hashedPassword|initialPassword|initialHashedPassword|password)\s*=\s*\"[^\"$]+\"", re.I)),
]


def private_values(hosts):
    """Exact strings from this computer's hosts/ files that must not travel."""
    found = {}
    if not hosts or not os.path.isdir(hosts):
        return found
    for dirpath, _dirs, files in os.walk(hosts):
        for name in files:
            if not name.endswith(".nix"):
                continue
            path = os.path.join(dirpath, name)
            try:
                text = open(path, encoding="utf-8", errors="replace").read()
            except OSError:
                continue
            # (comments too: they are this computer's)
            for ip in re.findall(IPV4, text):
                if ip not in ("127.0.0.1", "0.0.0.0"):
                    found[ip] = "an IP address from this computer's hosts/ files"
            for share in re.findall(r"(?<![:\w/])//[A-Za-z0-9][\w.-]*/[^\s\"';]+", text):
                found[share] = "a share address from this computer's hosts/ files"
            for user in re.findall(r"\busername\s*=\s*\"([^\"]+)\"", text):
                found[f"/home/{user}"] = "this computer's home folder"
            for uuid in re.findall(r"by-uuid/([0-9A-Fa-f-]{8,})", text):
                found[uuid] = "a disk ID of this computer"
    return found


def check(root, hosts=None):
    """-> list of (file, line number, what, the line)."""
    exact = private_values(hosts)
    problems = []
    for dirpath, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if d not in (".git", "__pycache__")]
        for name in sorted(files):
            if not name.endswith(TEXT_SUFFIXES):
                continue
            path = os.path.join(dirpath, name)
            rel = os.path.relpath(path, root)
            try:
                lines = open(path, encoding="utf-8", errors="replace").read().splitlines()
            except OSError:
                continue
            for number, line in enumerate(lines, 1):
                if ALLOW in line:
                    continue
                for what, pattern in GENERAL:
                    # flake.lock only names download links and content hashes
                    if name == "flake.lock" and what != "a private key":
                        continue
                    if pattern.search(line):
                        problems.append((rel, number, what, line.strip()))
                for value, what in exact.items():
                    if value in line:
                        problems.append((rel, number, what, line.strip()))
    return problems


def report(problems, stopped, out=sys.stderr):
    """Prints what was found. `stopped`: what did not happen because of it."""
    print(f"\n{stopped}: what would be shared carries something that looks private.\n", file=out)
    for rel, number, what, line in problems:
        print(f"  {rel}:{number}: {what}\n      {line[:160]}", file=out)
    print("\nMove these into hosts/ (never shared) or into a secret "
          "(modules/common/secrets.nix). A line that is fine after all can carry the words "
          f"\"{ALLOW}\".\n", file=out)


def main(argv):
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    problems = check(argv[1], argv[2] if len(argv) > 2 else None)
    if not problems:
        print("privacy check: nothing private found in what is shared")
        return 0
    report(problems, "The ISO was NOT built")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
