#!/usr/bin/env python3
"""Nix Actions -> Passwords: type in the secrets this computer needs.

The configuration says which secrets exist (myOS.secrets, see
modules/common/secrets.nix); this asks for their values and hands them to a
small helper that runs as root (after the usual password question) and writes
each one to its own file in /var/lib/noid-secrets, readable only by whoever it
is meant for. The value goes straight from the window to that helper: it is
never written into the configuration folder, the Nix store or a command line.

The @...@ gaps are filled in by ../nix-actions.nix.
"""
import json
import os
import subprocess
import sys

SETTINGS = json.loads(r"""@settings@""")  # zenity, pkexec, writer, secrets {name: {description, kind, path}}
TITLE = "Passwords"
SEP = "\x1f"  # between form fields (a character nobody types)


def zenity(*args, stdin=None):
    result = subprocess.run([SETTINGS["zenity"], f"--title={TITLE}", *args],
                            capture_output=True, text=True, input=stdin)
    return result.returncode, result.stdout.rstrip("\n")


def info(text):
    zenity("--info", "--no-markup", "--width=480", f"--text={text}")


def error(text):
    zenity("--error", "--no-markup", "--width=480", f"--text={text}")


def is_set(secret):
    try:
        return os.path.getsize(secret["path"]) > 0
    except OSError:
        return False


def ask_value(secret):
    """-> the file's content, or None when cancelled."""
    kind, what = secret["kind"], secret["description"]
    while True:
        if kind == "login":
            code, out = zenity("--forms", "--width=480", f"--text={what}", f"--separator={SEP}",
                               "--add-entry=User name", "--add-password=Password",
                               "--add-entry=Domain (leave empty if there is none)")
            if code != 0:
                return None
            fields = (out.split(SEP) + ["", "", ""])[:3]
            user, password, domain = (f.strip() if i != 1 else f for i, f in enumerate(fields))
            if not user or not password:
                error("Both the user name and the password are needed.")
                continue
            return f"username={user}\npassword={password}\n" + (f"domain={domain}\n" if domain else "")
        if kind == "password":
            code, out = zenity("--forms", "--width=480", f"--text={what}", f"--separator={SEP}",
                               "--add-password=Password", "--add-password=The same again")
            if code != 0:
                return None
            first, second = (out.split(SEP) + ["", ""])[:2]
            if not first:
                error("The password is empty.")
                continue
            if first != second:
                error("The two did not match. Please type it again.")
                continue
            return first + "\n"
        code, out = zenity("--text-info", "--editable", "--width=560", "--height=360",
                           f"--text={what}", stdin="")
        if code != 0:
            return None
        return out + "\n"


def save(name, content):
    """Hand the value to the root helper on its standard input. -> True when saved."""
    result = subprocess.run([SETTINGS["pkexec"], SETTINGS["writer"], name],
                            input=content, capture_output=True, text=True)
    if result.returncode == 0:
        return True
    if result.returncode in (126, 127):  # the password question was cancelled or refused
        info("Nothing was saved.")
        return False
    error(f"It could not be saved: {result.stderr.strip() or result.returncode}")
    return False


def main():
    secrets = SETTINGS["secrets"]
    if not secrets:
        info("This computer needs no passwords at the moment.\n\n"
             "They appear here when the configuration asks for one, for example for a network share.")
        return 0
    while True:
        rows = []
        for name in sorted(secrets, key=lambda n: (is_set(secrets[n]), secrets[n]["description"].lower())):
            s = secrets[name]
            rows += [name, s["description"], "Saved" if is_set(s) else "Not typed in yet"]
        code, name = zenity("--list", "--width=720", "--height=340",
                            "--text=Which one would you like to type in (or change)?",
                            "--column=id", "--column=For", "--column=Status",
                            "--hide-column=1", "--print-column=1", "--ok-label=Type it in",
                            "--cancel-label=Close", *rows)
        name = name.split("|")[0]
        if code != 0 or name not in secrets:
            return 0
        content = ask_value(secrets[name])
        if content is None:
            continue
        if save(name, content):
            info(f"Saved: {secrets[name]['description']}.\n\nIt is used from now on "
                 "(a network share: the next time its folder is opened).")


if __name__ == "__main__":
    sys.exit(main())
