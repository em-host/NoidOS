#!/usr/bin/env python3
"""What "AI Chat" and "ComfyUI" in the app menu run.

    ai-launcher chat         start the AI, fetch its model the first time, open the chat
    ai-launcher chat-stop    stop it again (frees the memory and the graphics card)
    ai-launcher media        start ComfyUI and open it
    ai-launcher media-stop   stop ComfyUI
    ai-launcher which-model  print the model this computer gets, and why

The @...@ gaps are filled in by ../ai.nix.
"""
import glob
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request

ZENITY = "@zenity@"
SYSTEMCTL = "@systemctl@"
XDG_OPEN = "@xdgOpen@"
SETTINGS = json.loads(r"""@settings@""")
# SETTINGS: ollamaUrl, webuiUrl, comfyUrl, startUnits, stopUnits, model ("auto" or a
# name), modelSizes [{vram|ram, model}], alias, gpu (myOS.GPU)

TITLE = {"chat": "AI Chat", "media": "ComfyUI"}


class Problem(Exception):
    pass


class Cancelled(Exception):
    pass


# ---------------------------------------------------------------------------
# A progress window
# ---------------------------------------------------------------------------


class Progress:
    def __init__(self, title, text, pulsate=True):
        args = [ZENITY, "--progress", f"--title={title}", f"--text={text}", "--width=480", "--auto-close"]
        if pulsate:
            args.append("--pulsate")
        self.proc = subprocess.Popen(args, stdin=subprocess.PIPE, text=True)

    def _send(self, line):
        if self.proc.poll() is not None:  # the window was closed or Cancel pressed
            raise Cancelled()
        try:
            self.proc.stdin.write(line + "\n")
            self.proc.stdin.flush()
        except BrokenPipeError:
            raise Cancelled()

    def say(self, text):
        self._send("# " + text)

    def percent(self, value):
        self._send(str(max(0, min(99, int(value)))))

    def close(self):
        if self.proc.poll() is None:
            self.proc.terminate()
            self.proc.wait()


def show_error(title, text):
    subprocess.run([ZENITY, "--error", "--no-markup", "--width=480", f"--title={title}", f"--text={text}"])


# ---------------------------------------------------------------------------
# Talking to the services
# ---------------------------------------------------------------------------


def http(url, body=None, method=None, timeout=10):
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(
        url, data=data, method=method or ("POST" if data is not None else "GET"),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        raw = response.read()
    return json.loads(raw) if raw.strip() else {}


def answers(url):
    try:
        urllib.request.urlopen(url, timeout=3).close()
        return True
    except (urllib.error.URLError, OSError):
        return False


def systemctl(*args):
    result = subprocess.run([SYSTEMCTL, *args], capture_output=True, text=True)
    if result.returncode != 0:
        raise Problem((result.stderr or result.stdout).strip() or f"systemctl {' '.join(args)} failed")


def wait_for(url, seconds, progress, text, unit=None, user=False):
    progress.say(text)
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if answers(url):
            return
        if unit:
            state = subprocess.run(
                [SYSTEMCTL, *(["--user"] if user else []), "is-failed", "--quiet", unit]
            )
            if state.returncode == 0:
                raise Problem(f"{unit} stopped with an error. Details: journalctl {'--user ' if user else ''}-u {unit}")
        progress.say(text)  # also notices a closed window
        time.sleep(1)
    raise Problem(f"It did not start within {seconds // 60} minutes.")


# ---------------------------------------------------------------------------
# Which model fits this computer
# ---------------------------------------------------------------------------


def gpu_memory_gib():
    """The memory of the biggest graphics card, in GiB (0 when there is none)."""
    best = 0.0
    smi = shutil.which("nvidia-smi") or "/run/current-system/sw/bin/nvidia-smi"
    if os.path.exists(smi):
        try:
            out = subprocess.run([smi, "--query-gpu=memory.total", "--format=csv,noheader,nounits"],
                                 capture_output=True, text=True, timeout=20).stdout
            for line in out.splitlines():
                best = max(best, float(line.strip()) / 1024)  # MiB
        except (OSError, ValueError, subprocess.SubprocessError):
            pass
    for path in glob.glob("/sys/class/drm/card*/device/mem_info_vram_total"):  # AMD
        try:
            with open(path) as f:
                best = max(best, int(f.read().strip()) / 1024**3)
        except (OSError, ValueError):
            pass
    if best == 0 and "intel-arc" in SETTINGS["gpu"]:
        best = 8.0  # Intel does not say; Arc cards have 6 to 16 GB
    return best


def ram_gib():
    with open("/proc/meminfo") as f:
        for line in f:
            if line.startswith("MemTotal:"):
                return int(line.split()[1]) / 1024**2
    return 0.0


def pick_model():
    """-> (model name, why)"""
    if SETTINGS["model"] != "auto":
        return SETTINGS["model"], "set in the configuration (module.ai.model)"
    vram, ram = gpu_memory_gib(), ram_gib()
    for size in SETTINGS["modelSizes"]:
        if "vram" in size and vram >= size["vram"]:
            return size["model"], f"graphics card memory {vram:.1f} GiB"
        if "ram" in size and ram >= size["ram"]:
            return size["model"], f"no big enough graphics card ({vram:.1f} GiB), RAM {ram:.1f} GiB"
    raise Problem("No model size fits this computer.")


# ---------------------------------------------------------------------------
# Getting the model
# ---------------------------------------------------------------------------
# The chat page always opens with the model called SETTINGS["alias"] ("assistant").
# The model picked for this computer is downloaded once and renamed to that, so
# the chat's list shows one model and the default never has to change.


def marker_path():
    state = os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state")
    return os.path.join(state, "noid-ai", "model")


def installed():
    tags = http(SETTINGS["ollamaUrl"] + "/api/tags")
    return {m.get("name") for m in tags.get("models", [])} | {m.get("model") for m in tags.get("models", [])}


def alias_tag():
    return SETTINGS["alias"] + ":latest"


def have_model(name):
    try:
        with open(marker_path()) as f:
            recorded = f.read().strip()
    except OSError:
        recorded = None
    return recorded == name and alias_tag() in installed()


def download(name, progress):
    request = urllib.request.Request(
        SETTINGS["ollamaUrl"] + "/api/pull",
        data=json.dumps({"model": name, "stream": True}).encode(),
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            for raw in response:
                if not raw.strip():
                    continue
                message = json.loads(raw)
                if "error" in message:
                    raise Problem(f"The model could not be downloaded: {message['error']}")
                total, done = message.get("total"), message.get("completed")
                if total and done is not None:
                    progress.percent(100 * done / total)
                    progress.say(f"Downloading the AI model, {done / 1024**3:.1f} of {total / 1024**3:.1f} GB "
                                 "(only the first time)...")
                elif message.get("status"):
                    progress.say(f"Downloading the AI model: {message['status']}...")
    except urllib.error.URLError as e:
        raise Problem(f"The model could not be downloaded. Check the internet connection. ({e.reason})")


def make_default(name):
    """Rename the downloaded model to the alias (the old one's space is freed)."""
    if alias_tag() in installed():
        http(SETTINGS["ollamaUrl"] + "/api/delete", {"model": alias_tag()}, method="DELETE")
    http(SETTINGS["ollamaUrl"] + "/api/copy", {"source": name, "destination": alias_tag()})
    http(SETTINGS["ollamaUrl"] + "/api/delete", {"model": name}, method="DELETE")
    os.makedirs(os.path.dirname(marker_path()), exist_ok=True)
    with open(marker_path(), "w") as f:
        f.write(name + "\n")


# ---------------------------------------------------------------------------
# The actions
# ---------------------------------------------------------------------------


def chat():
    title = TITLE["chat"]
    progress = Progress(title, "Starting the AI...")
    try:
        systemctl("start", *SETTINGS["startUnits"])
        wait_for(SETTINGS["ollamaUrl"] + "/api/version", 120, progress, "Starting the AI...", unit="ollama.service")
        name, _why = pick_model()
        if not have_model(name):
            progress.close()
            progress = Progress(title, "Downloading the AI model (only the first time)...", pulsate=False)
            download(name, progress)
            make_default(name)
            progress.close()
            progress = Progress(title, "Opening the chat...")
        wait_for(SETTINGS["webuiUrl"] + "/health", 600, progress,
                 "Opening the chat (the very first time this takes a few minutes)...", unit="open-webui.service")
    finally:
        progress.close()
    subprocess.Popen([XDG_OPEN, SETTINGS["webuiUrl"]], start_new_session=True)


def media():
    title = TITLE["media"]
    progress = Progress(title, "Starting ComfyUI...")
    try:
        systemctl("--user", "start", "comfyui.service")
        wait_for(SETTINGS["comfyUrl"], 900, progress,
                 "Starting ComfyUI (the very first time this takes a few minutes)...",
                 unit="comfyui.service", user=True)
    finally:
        progress.close()
    subprocess.Popen([XDG_OPEN, SETTINGS["comfyUrl"]], start_new_session=True)


def main(argv):
    action = argv[1] if len(argv) > 1 else "chat"
    try:
        if action == "chat":
            chat()
        elif action == "chat-stop":
            systemctl("stop", *SETTINGS["stopUnits"])
        elif action == "media":
            media()
        elif action == "media-stop":
            systemctl("--user", "stop", "comfyui.service")
        elif action == "which-model":
            name, why = pick_model()
            print(f"{name}  ({why})")
        else:
            print(__doc__, file=sys.stderr)
            return 2
    except Cancelled:
        return 0
    except Problem as e:
        title = TITLE["media"] if action.startswith("media") else TITLE["chat"]
        if os.environ.get("WAYLAND_DISPLAY") or os.environ.get("DISPLAY"):
            show_error(title, str(e))
        print(e, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
