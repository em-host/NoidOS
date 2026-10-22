#!/usr/bin/env python3
"""nixos-flakes: add flakes (programs and settings that someone publishes
online) to this NixOS configuration, without writing any Nix by hand.

    nixos-flakes gui               the "Add a Flake" window (Nix Actions opens it)
    nixos-flakes add LINK          add a flake from a link
    nixos-flakes inspect LINK      show what a flake offers, without adding it
    nixos-flakes remove NAME       take a flake away again
    nixos-flakes list              show the flakes that are added
    nixos-flakes sync              bring the generated registry in line with the
                                   flake files (Nix Actions runs this before a rebuild)
    nixos-flakes update            fetch newer versions of all added flakes
    nixos-flakes caches            print the authors' download servers (Nix Actions hands
                                   them to the rebuild, so they work the very first time)

A flake is one small file in hosts/flakes/ (see modules/flakes/_template.nix).
Nix needs every flake link written down as an "input", so the links are also
collected in hosts/flakes/registry/flake.nix, which this command writes. See
modules/flakes/default.nix for how the pieces fit together.
"""

from __future__ import annotations

import argparse
import contextlib
import datetime
import html
import json
import os
import platform
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import textwrap
from dataclasses import dataclass, field
from pathlib import Path

# The module (modules/flakes/default.nix) fills these in. Run straight from
# the source folder they are left alone, and the programs come from PATH.


def _tool(filled_in: str, env_name: str, fallback: str) -> str:
    return os.environ.get(env_name) or (fallback if filled_in.startswith("@") else filled_in)


NIX = _tool("@nix@", "NIXOS_FLAKES_NIX", "nix")
GIT = _tool("@git@", "NIXOS_FLAKES_GIT", "git")
ZENITY = _tool("@zenity@", "NIXOS_FLAKES_ZENITY", "zenity")
DEFAULT_DIR = _tool("@flakeDir@", "NIXOS_FLAKES_DIR", str(Path.home() / "NixOS"))
REBUILD_COMMAND = shlex.split(os.environ.get("NIXOS_FLAKES_REBUILD", "nix-actions rebuild"))

RESERVED_NAMES = {"enable", "package", "nixpkgs", "self"}


class Problem(Exception):
    """Something went wrong that the person can understand and act on."""


# ---------------------------------------------------------------------------
# Running programs
# ---------------------------------------------------------------------------


def _env() -> dict[str, str]:
    env = os.environ.copy()
    env["GIT_TERMINAL_PROMPT"] = "0"  # never wait for a password nobody can type
    git_dir = os.path.dirname(GIT)
    if git_dir:  # `git+https:` links need git on PATH even if it is not installed
        env["PATH"] = git_dir + os.pathsep + env.get("PATH", "")
    return env


def run(cmd: list[str], *, cwd: Path | None = None, stream: bool = False):
    """Run a program. With stream=True its output goes straight to the screen."""
    try:
        if stream:
            return subprocess.run(cmd, cwd=cwd, env=_env(), text=True)
        return subprocess.run(cmd, cwd=cwd, env=_env(), text=True, capture_output=True)
    except FileNotFoundError as exc:
        raise Problem(f"Could not run {cmd[0]}: {exc.strerror}.") from exc


def nix(args: list[str], *, cwd: Path | None = None, stream: bool = False):
    base = [
        NIX,
        "--extra-experimental-features",
        "nix-command flakes",
        "--option",
        "warn-dirty",
        "false",
    ]
    return run(base + args, cwd=cwd, stream=stream)


ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")


def clean(text: str) -> str:
    return ANSI.sub("", text or "")


def innermost_error(text: str) -> str:
    """The reason Nix gives at the bottom of its (often nested) error."""
    last = None
    for match in re.finditer(r"^[ \t]*error:[ \t]*", text, re.MULTILINE):
        last = match
    if last is None:
        lines = [line for line in text.strip().splitlines() if line.strip()]
        return "\n".join(lines[-8:])
    first, _, others = text[last.end():].partition("\n")
    body = textwrap.dedent(others).strip("\n")
    # Nix adds a source excerpt ("at file:line:column:") after some messages.
    where = re.search(r"^[ \t]*at ([^\n]*?):(\d+):\d+:?[ \t]*$", body, re.MULTILINE)
    note = ""
    if where:
        body = body[: where.start()]
        if not where.group(1).startswith("/nix/store/"):  # a file of the person's own
            note = f"\n(in {where.group(1)}, line {where.group(2)})"
    return (first.strip() + "\n" + body).strip() + note


def nix_error(stderr: str) -> str:
    """Turn a Nix error into something a person can read."""
    text = clean(stderr)
    lowered = text.lower()

    def has(*needles: str) -> bool:
        return any(n in lowered for n in needles)

    if has("flake.nix' does not exist", "does not contain a 'flake.nix'", "does not contain a flake.nix"):
        return "That link does not lead to a flake: there is no flake.nix in it."
    if has("http error 404", "returned error: 404", "repository not found", "does not exist (404)") \
            or re.search(r"repository '[^']*' not found", lowered):
        return "That address does not exist (error 404). Check the link for typos."
    if has("http error 401", "http error 403", "permission denied (publickey)",
           "authentication failed", "terminal prompts disabled", "could not read username"):
        return "That address is private or needs a login, so it cannot be used."
    if has("could not resolve host", "couldn't resolve host", "could not resolve hostname",
           "unable to download", "network is unreachable", "connection refused", "timed out",
           "failed to connect", "temporary failure in name resolution", "connect tunnel failed"):
        return ("Could not download from that address. Check your internet connection and "
                "the link, then try again.")
    if re.search(r"git repository \"[^\"]*\" does not exist", lowered) \
            or re.search(r"path '[^']*' does not exist", lowered):
        return "That folder or file does not exist."
    return innermost_error(text) or "Nix stopped without saying why."


def need(result, what: str):
    if result.returncode != 0:
        raise Problem(f"{what}\n\n{nix_error(result.stderr)}")
    return result


# ---------------------------------------------------------------------------
# Links
# ---------------------------------------------------------------------------

SCHEMES = (
    "github:", "gitlab:", "sourcehut:", "git+https:", "git+http:", "git+ssh:", "git+file:",
    "path:", "tarball+", "file+", "hg+", "mercurial+", "indirect:",
)


def normalize_link(text: str) -> str:
    """Turn whatever was pasted into a flake link Nix understands.

    A page address like https://github.com/owner/repo becomes github:owner/repo.
    """
    s = (text or "").strip().strip("<>\"'`").strip()
    s = re.sub(r"^git\s+clone\s+", "", s).strip()
    if not s:
        raise Problem("Paste the link of a flake first.")
    if re.search(r"\s", s):
        raise Problem("A link cannot contain spaces. Paste just the link.")

    if s.startswith(SCHEMES):
        return s

    # git@github.com:owner/repo.git
    m = re.match(r"^git@([^:/]+):(.+?)(?:\.git)?/?$", s)
    if m:
        s = f"https://{m.group(1)}/{m.group(2)}"

    # owner/repo on its own means GitHub
    if re.fullmatch(r"[\w.-]+/[\w.-]+", s) and "." not in s.split("/")[0]:
        return f"github:{s.removesuffix('.git')}"

    m = re.match(r"^(?:https?://)?(?:www\.)?([^/?#]+)/([^?#]*)", s)
    if not m:
        raise Problem("That does not look like a link. Paste the address of the flake's page.")
    host, path = m.group(1).lower(), m.group(2).strip("/")
    parts = [p for p in path.split("/") if p]

    if host == "github.com":
        if len(parts) < 2:
            raise Problem("A GitHub link needs an owner and a project: github.com/owner/project")
        owner, repo = parts[0], parts[1].removesuffix(".git")
        ref = ""
        if len(parts) >= 4 and parts[2] in ("tree", "commit"):
            ref = "/" + "/".join(parts[3:])
        return f"github:{owner}/{repo}{ref}"

    if host == "gitlab.com":
        before_dash = path.split("/-/")[0].strip("/")
        parts = [p for p in before_dash.split("/") if p]
        if len(parts) < 2:
            raise Problem("A GitLab link needs an owner and a project: gitlab.com/owner/project")
        repo = parts[-1].removesuffix(".git")
        owner = "%2F".join(parts[:-1])
        return f"gitlab:{owner}/{repo}"

    if host == "git.sr.ht":
        if len(parts) < 2:
            raise Problem("A Sourcehut link needs an owner and a project: git.sr.ht/~owner/project")
        return f"sourcehut:{parts[0]}/{parts[1]}"

    if re.search(r"\.(tar\.gz|tgz|tar\.xz|tar\.bz2|zip)$", path):
        return f"https://{host}/{path}"

    if len(parts) >= 2:
        # Codeberg, a company's own server, ...: any git repository works.
        base = "/".join(parts[:2])
        if parts[1].endswith(".git"):
            base = "/".join([parts[0], parts[1]])
        return f"git+https://{host}/{base}"

    raise Problem("That link does not point at a project. Paste the address of the flake's page.")


def suggest_name(ref: str) -> str:
    """A good file name for a flake, from its link: zen-browser-flake -> zen-browser."""
    body = re.sub(r"^[a-z+]+:(//)?", "", ref.split("?")[0])
    segments = [p for p in re.split(r"[/:]", body) if p]
    if ref.startswith(("github:", "gitlab:", "sourcehut:")):
        segments = segments[:2]
    repo = segments[-1] if segments else "flake"
    repo = repo.removesuffix(".git")
    repo = re.sub(r"\.(tar\.gz|tgz|tar\.xz|tar\.bz2|zip)$", "", repo, flags=re.IGNORECASE)
    name = repo.lower()
    for suffix in ("-flake", ".flake", "-nixos", "-nix", ".nix"):
        if name.endswith(suffix) and len(name) > len(suffix):
            name = name[: -len(suffix)]
    name = re.sub(r"[^a-z0-9]+", "-", name).strip("-")
    if not name:
        name = "flake"
    if not name[0].isalpha():
        name = "f-" + name
    if name in RESERVED_NAMES:
        name += "-flake"
    return name


def valid_name(name: str) -> bool:
    return bool(re.fullmatch(r"[a-z][a-z0-9-]*", name)) and name not in RESERVED_NAMES


def nix_string(value: str) -> str:
    """A Nix string literal."""
    escaped = (
        value.replace("\\", "\\\\").replace('"', '\\"').replace("${", "\\${")
        .replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t")
    )
    return f'"{escaped}"'


# ---------------------------------------------------------------------------
# What a flake offers
# ---------------------------------------------------------------------------


@dataclass
class Offer:
    ref: str
    locked: str
    description: str = ""
    packages: dict[str, str] = field(default_factory=dict)  # name -> description
    overlays: list[str] = field(default_factory=list)
    modules: list[str] = field(default_factory=list)
    cache: dict[str, list[str]] | None = None

    def as_json(self) -> dict:
        return {
            "ref": self.ref,
            "locked": self.locked,
            "description": self.description,
            "packages": [{"name": n, "description": d} for n, d in self.packages.items()],
            "overlays": self.overlays,
            "modules": self.modules,
            "cache": self.cache,
        }


def host_system() -> str:
    machine = platform.machine().lower()
    arch = {"amd64": "x86_64", "arm64": "aarch64"}.get(machine, machine)
    return f"{arch}-linux"


PACKAGES_APPLY = """
ps:
let
  names = builtins.attrNames ps;
  text = p: attr: sub:
    let
      r = builtins.tryEval (
        if builtins.isAttrs p && p ? ${attr} && (sub == null || (builtins.isAttrs p.${attr} && p.${attr} ? ${sub}))
        then (if sub == null then p.${attr} else p.${attr}.${sub})
        else ""
      );
    in
    if r.success && builtins.isString r.value then r.value else "";
  describe = p: {
    description = text p "meta" "description";
    name = text p "name" null;
  };
in
if builtins.length names > 60
then builtins.listToAttrs (map (n: { name = n; value = { description = ""; name = ""; }; }) names)
else builtins.mapAttrs (_: describe) ps
"""

NIX_CONFIG_EXPR = """
let
  f = import "%s/flake.nix";
  c = f.nixConfig or { };
in {
  substituters = c.extra-substituters or c.substituters or [ ];
  keys = c.extra-trusted-public-keys or c.trusted-public-keys or [ ];
}
"""


def _extra_eval_args() -> list[str]:
    # For testing only: e.g. --override-input, so inputs that cannot be reached
    # from here can be replaced by local copies.
    return os.environ.get("NIXOS_FLAKES_NIX_ARGS", "").split()


def _output_names(ref: str, attr: str, apply: str) -> dict | list:
    result = nix(
        ["eval", "--json", f"{ref}#{attr}", "--apply", apply] + _extra_eval_args()
    )
    if result.returncode == 0:
        return json.loads(result.stdout)
    if "does not provide attribute" in clean(result.stderr):
        return {} if apply == PACKAGES_APPLY else []
    raise Problem(f"Could not look inside that flake.\n\n{nix_error(result.stderr)}")


def inspect(link: str) -> Offer:
    ref = normalize_link(link)
    meta = need(
        nix(["flake", "metadata", "--json", ref]),
        "Could not open that link.",
    )
    info = json.loads(meta.stdout)
    locked = info.get("url") or ref
    offer = Offer(ref=ref, locked=locked,
                  description=" ".join((info.get("description") or "").split()))

    system = host_system()
    packages = _output_names(locked, f"packages.{system}", PACKAGES_APPLY)
    offer.packages = {
        n: " ".join((info_.get("description") or info_.get("name") or "").split())
        for n, info_ in sorted(packages.items())
    }
    offer.overlays = sorted(_output_names(locked, "overlays", "builtins.attrNames"))
    offer.modules = sorted(_output_names(locked, "nixosModules", "builtins.attrNames"))

    # The author's download servers, if the flake names any.
    store_path = info.get("path")
    if store_path:
        conf = nix(["eval", "--json", "--impure", "--expr", NIX_CONFIG_EXPR % store_path])
        if conf.returncode == 0:
            try:
                data = json.loads(conf.stdout)
            except json.JSONDecodeError:
                data = {}
            subs, keys = data.get("substituters") or [], data.get("keys") or []
            if (subs and keys and all(isinstance(x, str) for x in subs + keys)
                    and all(re.fullmatch(r"https?://[^\s\"\\$]+", s) for s in subs)
                    and all(re.fullmatch(r"[^\s\"\\$:]+:[^\s\"\\$]+", k) for k in keys)):
                offer.cache = {"substituters": subs, "keys": keys}
    return offer


def default_choice(offer: Offer) -> dict:
    """What to tick by default: the main program, and the download server."""
    names = list(offer.packages)
    if "default" in names:
        chosen = ["default"]
    elif len(names) == 1:
        chosen = names
    else:
        chosen = []
    return {"packages": chosen, "overlays": [], "modules": [], "cache": offer.cache is not None}


# ---------------------------------------------------------------------------
# The configuration folder
# ---------------------------------------------------------------------------


class Config:
    def __init__(self, root: str | Path, *, stream: bool = False):
        self.root = Path(os.path.abspath(os.path.expanduser(str(root))))
        self.stream = stream  # show Nix's own progress (terminal) instead of hiding it (window)
        self.host_dir = self.root / "hosts" / "flakes"
        self.shared_dir = self.root / "modules" / "flakes"
        self.registry_dir = self.host_dir / "registry"
        self.registry = self.registry_dir / "flake.nix"
        self.registry_lock = self.registry_dir / "flake.lock"
        self.lock = self.root / "flake.lock"
        self.lib = self.root / "lib" / "flakes.nix"

    def check(self) -> None:
        if not (self.root / "flake.nix").is_file():
            raise Problem(
                f"Could not find your NixOS configuration in {self.root}\n"
                "(there is no flake.nix there). It needs to live in your home folder, "
                "in a folder called NixOS."
            )
        if not self.lib.is_file():
            raise Problem(f"{self.lib} is missing, so this configuration is incomplete.")

    # ---- the flake files ----------------------------------------------------

    def load(self) -> dict:
        """Read and check every flake file. Returns {"specs": {...}, "registry": text}."""
        self.check()
        expr = (
            f"let f = import {nix_string(str(self.lib))}; "
            f"in f.forTool [ {nix_string(str(self.shared_dir))} {nix_string(str(self.host_dir))} ]"
        )
        result = nix(["eval", "--json", "--impure", "--expr", expr])
        if result.returncode != 0:
            raise Problem(nix_error(result.stderr))
        return json.loads(result.stdout)

    def spec_path(self, name: str) -> Path:
        return self.host_dir / f"{name}.nix"

    def is_local(self, path: Path) -> bool:
        """Is this flake file one of this computer's own (hosts/flakes), not a shared one?"""
        try:
            Path(path).resolve().relative_to(self.host_dir.resolve())
        except ValueError:
            return False
        return True

    # ---- git ----------------------------------------------------------------

    def in_git(self) -> bool:
        probe = run([GIT, "-C", str(self.root), "rev-parse", "--is-inside-work-tree"])
        return probe.returncode == 0 and probe.stdout.strip() == "true"

    def track(self, *paths: Path) -> None:
        """Nix only sees files Git knows about, when the folder is a Git repository."""
        if not self.in_git():
            return
        existing = [str(p) for p in paths if p.exists()]
        if existing:
            run([GIT, "-C", str(self.root), "add", "--intent-to-add", "--force", "--", *existing])

    def untrack(self, path: Path) -> None:
        if self.in_git():
            run([GIT, "-C", str(self.root), "rm", "--cached", "--quiet", "--ignore-unmatch",
                 "--", str(path)])


def write_atomic(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    handle, tmp = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.")
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as out:
            out.write(text)
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(tmp)
        raise


def lock_inputs(lock_file: Path, *, under_flakes: bool) -> set[str] | None:
    """Names of the inputs recorded in a lock file (None if there is no such record)."""
    try:
        data = json.loads(lock_file.read_text(encoding="utf-8"))
        nodes = data["nodes"]
        node = nodes[data["root"]]
        if under_flakes:
            key = node.get("inputs", {}).get("flakes")
            if not isinstance(key, str) or key not in nodes:
                return None
            node = nodes[key]
        return set(node.get("inputs", {}))
    except (OSError, ValueError, KeyError):
        return None


@contextlib.contextmanager
def undo_on_failure(cfg: Config, *touched: Path):
    """If anything inside fails, put every file it may have touched back as it was.

    `touched` are the flake files that are about to be created or deleted. Files
    that Git has to know about are shown to Git again (or forgotten), so Nix
    keeps seeing exactly what it saw before.
    """
    visible = {cfg.registry, cfg.registry_lock, *touched}
    saved = {p: (p.read_bytes() if p.exists() else None)
             for p in (cfg.registry, cfg.registry_lock, cfg.lock, *touched)}
    try:
        yield
    except BaseException:
        for path, data in saved.items():
            if data is None:
                with contextlib.suppress(OSError):
                    path.unlink()
                cfg.untrack(path)
            else:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)
                if path in visible:
                    cfg.track(path)
        raise


# ---------------------------------------------------------------------------
# Keeping the registry and the lock files in line with the flake files
# ---------------------------------------------------------------------------


def sync(cfg: Config) -> bool:
    """Make hosts/flakes/registry (and both lock files) match the flake files.

    Returns True if anything had to change. If it fails, nothing is changed.
    """
    data = cfg.load()
    wanted = set(data["specs"])
    spec_files = [Path(s["file"]) for s in data["specs"].values()]

    changed = False
    with undo_on_failure(cfg):
        current = cfg.registry.read_text(encoding="utf-8") if cfg.registry.is_file() else None
        if current != data["registry"]:
            write_atomic(cfg.registry, data["registry"])
            changed = True
        cfg.track(cfg.registry, *spec_files)

        # Nix only looks at a flake's inputs again when asked to, so the registry's
        # own lock file is updated first (it keeps the versions of everything that
        # was added earlier), then the main one is told to take it over.
        if changed or lock_inputs(cfg.registry_lock, under_flakes=False) != wanted:
            need(nix(["flake", "lock"], cwd=cfg.registry_dir, stream=cfg.stream),
                 "Could not download the flakes.")
            cfg.track(cfg.registry_lock)
            changed = True

        if changed or lock_inputs(cfg.lock, under_flakes=True) != wanted:
            need(nix(["flake", "update", "flakes"], cwd=cfg.root, stream=cfg.stream),
                 "Could not update the lock file.")
            changed = True
    return changed


def update(cfg: Config) -> None:
    """Fetch newer versions of everything, the added flakes included."""
    sync(cfg)
    with undo_on_failure(cfg):
        if lock_inputs(cfg.registry_lock, under_flakes=False):
            need(nix(["flake", "update"], cwd=cfg.registry_dir, stream=cfg.stream),
                 "Could not fetch newer versions of the added flakes.")
        need(nix(["flake", "update"], cwd=cfg.root, stream=cfg.stream),
             "Could not fetch newer versions.")


# ---------------------------------------------------------------------------
# Adding and removing
# ---------------------------------------------------------------------------


def unique_name(cfg: Config, wanted: str, taken: set[str]) -> str:
    name, n = wanted, 2
    while name in taken or cfg.spec_path(name).exists():
        name = f"{wanted}-{n}"
        n += 1
    return name


def render_spec(offer: Offer, choice: dict, today: datetime.date | None = None) -> str:
    today = today or datetime.date.today()
    lines: list[str] = []
    if offer.description:
        lines.append("# " + " ".join(offer.description.split()))
    lines.append(f'# Added with "Add a Flake" on {today.isoformat()}.')
    page = re.match(r"^(github|gitlab):([^/]+)/([^/?]+)", offer.ref)
    if page:
        host = "github.com" if page.group(1) == "github" else "gitlab.com"
        lines.append(f"# More about it: https://{host}/{page.group(2)}/{page.group(3)}")
    lines += ["{", f"  url = {nix_string(offer.ref)};", ""]

    def block(key: str, items: list[str], comment: str) -> None:
        if items:
            body = " ".join(nix_string(i) for i in items)
            lines.extend([f"  # {comment}", f"  {key} = [ {body} ];", ""])
        else:
            lines.append(f"  # {key} = [ ];")

    block("packages", choice["packages"], "Programs to install.")
    block("overlays", choice["overlays"], "Overlays to apply.")
    block("modules", choice["modules"], "NixOS modules to import.")
    lines.append("")
    if choice.get("cache") and offer.cache:
        subs = "\n".join(f"      {nix_string(s)}" for s in offer.cache["substituters"])
        keys = "\n".join(f"      {nix_string(k)}" for k in offer.cache["keys"])
        lines += [
            "  # The author's download servers, so programs arrive ready-made.",
            "  cache = {",
            f"    substituters = [\n{subs}\n    ];",
            f"    keys = [\n{keys}\n    ];",
            "  };",
        ]
    lines.append("}")
    return "\n".join(lines) + "\n"


def add(cfg: Config, link: str, *, name: str | None = None, choice: dict | None = None,
        offer: Offer | None = None) -> str:
    """Add a flake. Returns its name. Nothing is left half done if it fails."""
    cfg.check()
    offer = offer or inspect(link)
    choice = choice or default_choice(offer)

    for key, offered in (("packages", offer.packages), ("overlays", offer.overlays),
                         ("modules", offer.modules)):
        missing = [n for n in choice[key] if n not in offered]
        if missing:
            raise Problem(
                f"That flake has no {key[:-1]} called {', '.join(missing)}.\n"
                f"It offers: {', '.join(offered) or 'nothing of that kind'}."
            )
    if not (choice["packages"] or choice["overlays"] or choice["modules"]):
        raise Problem("Nothing was chosen to add. Pick at least one program, overlay or module.")

    existing = cfg.load()["specs"]
    if name is None:
        name = unique_name(cfg, suggest_name(offer.ref), set(existing))
    elif not valid_name(name):
        raise Problem(
            f'"{name}" cannot be used as a name. Use lowercase letters, numbers and dashes, '
            "starting with a letter."
        )
    elif name in existing or cfg.spec_path(name).exists():
        raise Problem(f'There is already a flake called "{name}".')

    path = cfg.spec_path(name)
    with undo_on_failure(cfg, path):
        write_atomic(path, render_spec(offer, choice))
        cfg.track(path)
        sync(cfg)
    return name


def remove(cfg: Config, name: str) -> None:
    """Remove a flake. If it fails, the flake is still there afterwards."""
    specs = cfg.load()["specs"]
    if name not in specs:
        raise Problem(f'There is no flake called "{name}". Added flakes: '
                      f'{", ".join(sorted(specs)) or "none"}.')
    path = Path(specs[name]["file"])
    if not cfg.is_local(path):
        raise Problem(
            f'"{name}" is part of the shared configuration ({path}), so it is not removed from '
            "here.\nTo switch it off on this computer, put this in hosts/users/user.nix:\n"
            f"  module.flakes.{name}.enable = false;"
        )
    with undo_on_failure(cfg, path):
        path.unlink()
        cfg.untrack(path)
        sync(cfg)


# ---------------------------------------------------------------------------
# The window
# ---------------------------------------------------------------------------


def zenity(*args: str):
    return run([ZENITY, *args])


def markup(text: str) -> str:
    """Text that is safe inside a zenity message (it reads markup and backslash escapes)."""
    return html.escape(text, quote=False).replace("\\", "\\\\")


@contextlib.contextmanager
def busy(title: str, text: str):
    """A window with a moving bar, open while the work inside runs."""
    proc = subprocess.Popen(
        [ZENITY, "--progress", "--pulsate", "--no-cancel", "--auto-close",
         f"--title={title}", f"--text={markup(text)}", "--width=420"],
        stdin=subprocess.PIPE, text=True, env=_env(),
    )
    try:
        yield
    finally:
        with contextlib.suppress(OSError):
            if proc.stdin:
                proc.stdin.close()
        with contextlib.suppress(OSError):
            proc.terminate()
        with contextlib.suppress(Exception):
            proc.wait(timeout=5)


def show_error(text: str) -> None:
    zenity("--error", "--title=Add a Flake", "--no-markup", "--width=480", f"--text={text}")


def rebuild_hint() -> str:
    """How to say "rebuild" to this person: through Nix Actions if it is there."""
    return ("Open Nix Actions and choose Rebuild" if shutil.which("nix-actions")
            else "Rebuild NixOS")


def ask_rebuild(name: str, verb: str) -> None:
    command = shutil.which(REBUILD_COMMAND[0]) if REBUILD_COMMAND else None
    if command:
        answer = zenity(
            "--question", "--title=Add a Flake", "--width=420",
            "--ok-label=Rebuild now", "--cancel-label=Later",
            f"--text=<b>{markup(name)}</b> has been {verb}.\n\n"
            "The change takes effect the next time NixOS is rebuilt. Rebuild now?",
        )
        if answer.returncode == 0:
            subprocess.Popen([command, *REBUILD_COMMAND[1:]], start_new_session=True, env=_env(),
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    else:
        zenity("--info", "--title=Add a Flake", "--width=420",
               f"--text=<b>{markup(name)}</b> has been {verb}.\n\n"
               "Rebuild NixOS to make the change take effect.")


def pick_things(name: str, offer: Offer) -> dict | None:
    """The tick list. Returns what was chosen, or None if cancelled."""
    defaults = default_choice(offer)
    rows: list[tuple[str, str, str, str]] = []  # (ticked, id, what, details)
    index: dict[str, tuple[str, str]] = {}
    for i, (pkg, desc) in enumerate(offer.packages.items()):
        key = f"p{i}"
        index[key] = ("packages", pkg)
        rows.append(("TRUE" if pkg in defaults["packages"] else "FALSE", key,
                     f"Program: {pkg}", desc or "A program you can run"))
    for i, ovl in enumerate(offer.overlays):
        key = f"o{i}"
        index[key] = ("overlays", ovl)
        rows.append(("FALSE", key, f"Overlay: {ovl}",
                     "Changes how some programs are built (advanced)"))
    for i, mod in enumerate(offer.modules):
        key = f"m{i}"
        index[key] = ("modules", mod)
        rows.append(("FALSE", key, f"NixOS module: {mod}",
                     "Adds extra system settings (advanced)"))
    if offer.cache:
        hosts = ", ".join(re.sub(r"^https?://", "", s) for s in offer.cache["substituters"])
        rows.append(("TRUE", "cache", "Faster downloads",
                     f"Use the author's download server ({hosts}) so big programs arrive ready-made"))

    if not index:
        show_error(f"{name} does not offer a program, overlay or module that can be added "
                   "this way.")
        return None

    text = f"<b>{markup(name)}</b>"
    if offer.description:
        text += f"\n{markup(offer.description)}"
    text += "\n\nTick what you want to add:"
    args = [
        "--list", "--checklist", "--title=Add a Flake", f"--text={text}",
        "--column=Add", "--column=ID", "--column=What", "--column=Details",
        "--hide-column=2", "--print-column=2", "--width=720", "--height=420",
        "--ok-label=Add", "--cancel-label=Cancel",
    ]
    for row in rows:
        args.extend(row)
    while True:
        answer = zenity(*args)
        if answer.returncode != 0:
            return None
        picked = [p for p in answer.stdout.strip().split("|") if p]
        chosen: dict = {"packages": [], "overlays": [], "modules": [],
                        "cache": "cache" in picked}
        for key in picked:
            if key in index:
                kind, item = index[key]
                chosen[kind].append(item)
        if chosen["packages"] or chosen["overlays"] or chosen["modules"]:
            return chosen
        show_error("Tick at least one program, overlay or module to add.")


def gui_add(cfg: Config, link: str) -> bool:
    """One round of 'paste a link, pick what you want, add it'. True if something was added."""
    try:
        ref = normalize_link(link)
        with busy("Add a Flake", f"Looking at {ref}\nThis can take a minute the first time."):
            offer = inspect(ref)
        name = unique_name(cfg, suggest_name(offer.ref), set(cfg.load()["specs"]))
        chosen = pick_things(name, offer)
        if chosen is None:
            return False
        with busy("Add a Flake", f"Adding {name}\nDownloading it and saving its version."):
            add(cfg, ref, name=name, choice=chosen, offer=offer)
    except Problem as problem:
        show_error(str(problem))
        return False
    ask_rebuild(name, "added")
    return True


def gui_remove(cfg: Config) -> bool:
    """Pick a flake and remove it. True if one was removed."""
    try:
        specs = {n: sp for n, sp in cfg.load()["specs"].items() if cfg.is_local(Path(sp["file"]))}
    except Problem as problem:
        show_error(str(problem))
        return False
    if not specs:
        zenity("--info", "--title=Remove a flake", "--width=380",
               "--text=No flakes have been added to this computer yet.")
        return False
    args = ["--list", "--title=Remove a flake", "--text=Which flake do you want to remove?",
            "--column=Name", "--column=Link", "--width=620", "--height=360",
            "--ok-label=Remove", "--cancel-label=Cancel"]
    for name, spec in sorted(specs.items()):
        args.extend([name, spec["url"]])
    answer = zenity(*args)
    name = answer.stdout.strip().split("|")[0] if answer.returncode == 0 else ""
    if not name:
        return False
    sure = zenity("--question", "--title=Remove a flake", "--width=420",
                  "--ok-label=Remove", "--cancel-label=Keep it",
                  f"--text=Remove <b>{markup(name)}</b>?\nIts file is deleted; the program goes away "
                  "the next time NixOS is rebuilt.")
    if sure.returncode != 0:
        return False
    try:
        with busy("Remove a flake", f"Removing {name}"):
            remove(cfg, name)
    except Problem as problem:
        show_error(str(problem))
        return False
    ask_rebuild(name, "removed")
    return True


def gui(cfg: Config, link: str | None = None) -> None:
    if not (os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY")) \
            and "NIXOS_FLAKES_ZENITY" not in os.environ:
        raise Problem("There is no screen to show the window on. "
                      "Use 'nixos-flakes add LINK' in a terminal instead.")
    try:
        cfg.check()
    except Problem as problem:
        show_error(str(problem))
        return
    previous = ""  # what was typed last time, so a typo can be fixed instead of retyped
    while True:
        if link is None:
            answer = zenity(
                "--entry", "--title=Add a Flake", "--width=560",
                "--text=Paste the link of the program or setting you want to add.\n\n"
                "For example:  https://github.com/someone/their-project",
                f"--entry-text={previous}",
                "--ok-label=Look it up", "--cancel-label=Close",
                "--extra-button=Remove a flake",
            )
            if answer.stdout.strip() == "Remove a flake":
                if gui_remove(cfg):
                    return
                continue
            if answer.returncode != 0:
                return
            link = answer.stdout.strip()
        previous, attempt = link, link
        link = None
        if gui_add(cfg, attempt):
            return


# ---------------------------------------------------------------------------
# The command line
# ---------------------------------------------------------------------------


def show_offer(offer: Offer) -> None:
    print(f"Link:         {offer.ref}")
    if offer.description:
        print(f"About:        {offer.description}")
    print("Programs:     " + (", ".join(offer.packages) or "none"))
    print("Overlays:     " + (", ".join(offer.overlays) or "none"))
    print("NixOS modules:" + " " + (", ".join(offer.modules) or "none"))
    if offer.cache:
        print("Download servers: " + ", ".join(offer.cache["substituters"]))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="nixos-flakes",
        description="Add flakes (programs and settings published online) to this NixOS "
                    "configuration.",
    )
    parser.add_argument("--dir", default=DEFAULT_DIR,
                        help="the NixOS configuration folder (default: %(default)s)")
    sub = parser.add_subparsers(dest="command")

    p = sub.add_parser("gui", help="open the Add a Flake window")
    p.add_argument("link", nargs="?")

    p = sub.add_parser("add", help="add a flake from a link")
    p.add_argument("link")
    p.add_argument("--name", help="name for it (default: made from the link)")
    p.add_argument("--package", action="append", default=[], metavar="NAME",
                   help="a program to install (repeat for several; 'all' for every one)")
    p.add_argument("--overlay", action="append", default=[], metavar="NAME")
    p.add_argument("--module", action="append", default=[], metavar="NAME")
    p.add_argument("--no-cache", action="store_true",
                   help="do not use the author's download server")

    p = sub.add_parser("inspect", help="show what a flake offers")
    p.add_argument("link")
    p.add_argument("--json", action="store_true")

    p = sub.add_parser("remove", help="remove a flake")
    p.add_argument("name")

    p = sub.add_parser("list", help="show the added flakes")
    p.add_argument("--json", action="store_true")

    sub.add_parser("caches", help="print the download servers of the added flakes")
    sub.add_parser("sync", help="bring the registry and lock files in line")
    sub.add_parser("update", help="fetch newer versions of all added flakes")

    args = parser.parse_args(argv)
    command = args.command or ("gui" if (os.environ.get("DISPLAY")
                                         or os.environ.get("WAYLAND_DISPLAY")) else None)
    if command is None:
        parser.print_help()
        return 2

    try:
        if os.geteuid() == 0 and not os.environ.get("NIXOS_FLAKES_ALLOW_ROOT"):
            raise Problem("Run this as your normal user, not as root or with sudo.\n"
                          "It would leave files in your configuration folder that you could "
                          "no longer change.")

        cfg = Config(args.dir, stream=(command != "gui" and sys.stderr.isatty()))

        if command == "gui":
            gui(cfg, getattr(args, "link", None))
        elif command == "inspect":
            offer = inspect(args.link)
            if args.json:
                print(json.dumps(offer.as_json(), indent=2))
            else:
                show_offer(offer)
        elif command == "add":
            offer = inspect(args.link)
            choice = default_choice(offer)
            if args.package:
                choice["packages"] = (list(offer.packages) if args.package == ["all"]
                                      else args.package)
            if args.overlay:
                choice["overlays"] = args.overlay
            if args.module:
                choice["modules"] = args.module
            if args.no_cache:
                choice["cache"] = False
            name = add(cfg, args.link, name=args.name, choice=choice, offer=offer)
            print(f'Added "{name}" ({cfg.spec_path(name)}).')
            print(f"{rebuild_hint()} to install it.")
        elif command == "remove":
            remove(cfg, args.name)
            print(f'Removed "{args.name}". {rebuild_hint()} to apply it.')
        elif command == "list":
            specs = cfg.load()["specs"]
            if args.json:
                print(json.dumps(specs, indent=2))
            elif not specs:
                print("No flakes have been added.")
            else:
                for name, spec in sorted(specs.items()):
                    use = spec["packages"] + [f"overlay:{o}" for o in spec["overlays"]] \
                        + [f"module:{m}" for m in spec["modules"]]
                    print(f"{name:<24} {spec['url']}   [{', '.join(use) or 'settings only'}]")
        elif command == "caches":
            # One "setting value value ..." line per Nix setting. A flake's download
            # server is only part of the system's Nix settings after the first
            # rebuild, so the very first build (of ComfyUI, say) would compile
            # everything from source. Handing these to that build avoids it.
            urls, keys = [], []
            for spec in cfg.load()["specs"].values():
                for cache in [spec.get("cache")]:
                    if cache:
                        urls += [u for u in cache["substituters"] if u not in urls]
                        keys += [k for k in cache["keys"] if k not in keys]
            if urls and keys:
                print("extra-substituters " + " ".join(urls))
                print("extra-trusted-public-keys " + " ".join(keys))
        elif command == "sync":
            if sync(cfg):
                print("Flakes brought up to date.")
        elif command == "update":
            update(cfg)
    except Problem as problem:
        print(f"nixos-flakes: {problem}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        return 130
    return 0


if __name__ == "__main__":
    sys.exit(main())
