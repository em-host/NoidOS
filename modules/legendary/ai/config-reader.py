#!/usr/bin/env python3
"""A read-only view of the NixOS configuration folder, for the AI chat.

Open WebUI reads /openapi.json from here and offers the three operations below
to the model as tools. Nothing here can change a file: there is no operation
that writes, and ../ai.nix runs this sandboxed with only the configuration
folder visible, read-only.

    config-reader.py --root /home/me/NixOS --port 8099
"""
import argparse
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

# Folders that are never shown: version control, build results, caches.
SKIP_DIRS = {".git", "result", "__pycache__", ".direnv"}
MAX_FILE_BYTES = 1024 * 1024  # bigger files are not text configuration
MAX_LIST = 1000
MAX_LINES = 400  # per read_file call
MAX_MATCHES = 200

ROOT = ""


class Problem(Exception):
    pass


def resolve(relative):
    """A path inside the folder, from what the model asked for. Never outside it."""
    relative = (relative or "").strip().lstrip("/")
    full = os.path.realpath(os.path.join(ROOT, relative))
    if full != ROOT and not full.startswith(ROOT + os.sep):
        raise Problem("That is outside the configuration folder.")
    return full


def shown(full):
    rel = os.path.relpath(full, ROOT)
    return "" if rel == "." else rel


def is_text(full):
    try:
        if os.path.getsize(full) > MAX_FILE_BYTES:
            return False
        with open(full, "rb") as f:
            return b"\0" not in f.read(8192)
    except OSError:
        return False


def walk(start):
    for dirpath, dirnames, filenames in os.walk(start):
        dirnames[:] = sorted(d for d in dirnames if d not in SKIP_DIRS)
        for name in sorted(filenames):
            yield os.path.join(dirpath, name)


def list_files(folder=""):
    start = resolve(folder)
    if not os.path.isdir(start):
        raise Problem(f"There is no folder called {folder!r}.")
    files = []
    for full in walk(start):
        try:
            size = os.path.getsize(full)
        except OSError:
            continue
        files.append({"path": shown(full), "bytes": size})
        if len(files) >= MAX_LIST:
            break
    return {"folder": shown(start) or ".", "files": files, "truncated": len(files) >= MAX_LIST}


def read_file(path, start_line=1, max_lines=MAX_LINES):
    full = resolve(path)
    if not os.path.isfile(full):
        raise Problem(f"There is no file called {path!r}. Use list_files to see what there is.")
    if not is_text(full):
        raise Problem(f"{path} is not a text file (or is bigger than 1 MB).")
    start_line = max(1, int(start_line))
    max_lines = max(1, min(int(max_lines), MAX_LINES))
    with open(full, encoding="utf-8", errors="replace") as f:
        lines = f.read().splitlines()
    chosen = lines[start_line - 1:start_line - 1 + max_lines]
    numbered = "\n".join(f"{start_line + i:5d}  {line}" for i, line in enumerate(chosen))
    end = start_line + len(chosen) - 1
    return {
        "path": shown(full),
        "total_lines": len(lines),
        "start_line": start_line,
        "end_line": end,
        "more_after": end < len(lines),
        "content": numbered,
    }


def search_files(text, folder=""):
    if not text:
        raise Problem("Give some text to search for.")
    needle = text.lower()
    start = resolve(folder)
    matches = []
    for full in walk(start):
        if not is_text(full):
            continue
        try:
            with open(full, encoding="utf-8", errors="replace") as f:
                for number, line in enumerate(f, 1):
                    if needle in line.lower():
                        matches.append({"path": shown(full), "line": number, "text": line.rstrip()[:300]})
                        if len(matches) >= MAX_MATCHES:
                            return {"text": text, "matches": matches, "truncated": True}
        except OSError:
            continue
    return {"text": text, "matches": matches, "truncated": False}


def query(name, description, kind="string", required=False, default=None):
    schema = {"type": kind, "description": description}
    if default is not None:
        schema["default"] = default
    return {"name": name, "in": "query", "required": required, "description": description, "schema": schema}


SPEC = {
    "openapi": "3.1.0",
    "info": {
        "title": "NixOS configuration",
        "version": "1",
        "description": "Read the files of this computer's NixOS configuration (read only).",
    },
    "paths": {
        "/list_files": {
            "get": {
                "operationId": "list_files",
                "description": "List every file of this computer's NixOS configuration (or of one folder in it), "
                "with paths relative to the configuration folder. Start here.",
                "parameters": [query("folder", "A folder inside the configuration, e.g. 'modules/common'. Empty for all.")],
            }
        },
        "/read_file": {
            "get": {
                "operationId": "read_file",
                "description": "Read a file of the NixOS configuration, with line numbers. Long files come in parts: "
                f"at most {MAX_LINES} lines at a time, continue with start_line.",
                "parameters": [
                    query("path", "The file, relative to the configuration folder, e.g. 'hosts/users/user.nix'.", required=True),
                    query("start_line", "The first line to read.", kind="integer", default=1),
                    query("max_lines", f"How many lines to read (at most {MAX_LINES}).", kind="integer", default=MAX_LINES),
                ],
            }
        },
        "/search_files": {
            "get": {
                "operationId": "search_files",
                "description": "Find where a piece of text appears in the NixOS configuration (not case-sensitive). "
                "Returns file, line number and the line.",
                "parameters": [
                    query("text", "The text to look for, e.g. 'timeZone' or 'steam'.", required=True),
                    query("folder", "Only look inside this folder. Empty for all."),
                ],
            }
        },
    },
}

OPERATIONS = {"/list_files": list_files, "/read_file": read_file, "/search_files": search_files}


class Handler(BaseHTTPRequestHandler):
    def reply(self, status, body):
        data = json.dumps(body).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        url = urlparse(self.path)
        if url.path == "/openapi.json":
            return self.reply(200, SPEC)
        operation = OPERATIONS.get(url.path)
        if operation is None:
            return self.reply(404, {"error": "No such operation."})
        args = {key: values[-1] for key, values in parse_qs(url.query).items()}
        try:
            return self.reply(200, operation(**args))
        except Problem as e:
            return self.reply(400, {"error": str(e)})
        except (TypeError, ValueError) as e:
            return self.reply(400, {"error": f"Wrong parameters: {e}"})

    def log_message(self, fmt, *args):  # one short line per request in the journal
        sys.stderr.write("%s\n" % (fmt % args))


def main():
    global ROOT
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8099)
    opts = parser.parse_args()
    ROOT = os.path.realpath(opts.root)
    if not os.path.isdir(ROOT):
        print(f"The configuration folder {ROOT} is not there.", file=sys.stderr)
    ThreadingHTTPServer((opts.host, opts.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
