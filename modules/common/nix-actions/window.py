#!/usr/bin/env python3
"""The Nix Actions window (GTK 4 / libadwaita)."""
import datetime
import json
import os
import shutil
import subprocess
import sys
import threading

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gdk, Gio, GLib, GObject, Gtk, Pango  # noqa: E402

SETTINGS = json.loads(r"""@settings@""")
# flakeDir, sync, publisher, scripts {rebuild, update, cleanup, install, publish}, cleanupText,
# flakes, drives, appDrives, passwords, driveList {folder: {label, fsType, apps}}, locations [names]
FLAKE = os.path.expanduser(SETTINGS["flakeDir"])
USER_FILE = os.path.join(FLAKE, "hosts", "users", "user.nix")


def launch(command):
    """Starts a program that lives on by itself (a terminal action or a dialog)."""
    subprocess.Popen(command, start_new_session=True, stdin=subprocess.DEVNULL)


def in_background(work, done):
    """Runs work() in a thread and hands its result to done() back in the main loop."""
    def runner():
        try:
            result = work()
        except Exception as e:  # noqa: BLE001 (shown in the window instead)
            result = e
        GLib.idle_add(lambda: done(result) and False)
    threading.Thread(target=runner, daemon=True).start()


def sync(*args):
    return subprocess.run([SETTINGS["sync"], *args], capture_output=True, text=True)


def free_space(path="/nix/store"):
    try:
        return shutil.disk_usage(path).free
    except OSError:
        return None


def size_text(size):
    if size is None:
        return ""
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if size < 1000 or unit == "TB":
            return f"{size:.0f} {unit}" if unit in ("B", "KB") else f"{size:.1f} {unit}"
        size /= 1000


def when(stamp):
    try:
        moment = datetime.datetime.fromisoformat(stamp)
    except (TypeError, ValueError):
        return None
    today = datetime.date.today()
    if moment.date() == today:
        return f"today at {moment:%H:%M}"
    if moment.date() == today - datetime.timedelta(days=1):
        return f"yesterday at {moment:%H:%M}"
    return f"{moment:%d %B %Y}"


def button(label, on_click, *classes, icon=None, tooltip=None):
    b = Gtk.Button(valign=Gtk.Align.CENTER)
    if icon and not label:
        b.set_icon_name(icon)
    elif icon:
        b.set_child(Adw.ButtonContent(icon_name=icon, label=label))
    else:
        b.set_label(label)
    for c in classes:
        b.add_css_class(c)
    if tooltip:
        b.set_tooltip_text(tooltip)
    b.connect("clicked", lambda *_: on_click())
    return b


# Rows, expander rows and toasts read their text as Pango markup unless told not to;
# a "&" (as in "Rebuild & Update") or "<" in a release note would blank it.
def action_row(title, subtitle, icon, label, on_click, *classes):
    row = Adw.ActionRow(use_markup=False, title=title, subtitle=subtitle)
    row.set_subtitle_lines(0)
    row.add_prefix(Gtk.Image(icon_name=icon))
    b = button(label, on_click, *classes)
    row.add_suffix(b)
    row.set_activatable_widget(b)
    return row, b


def label(text, *classes, wrap=True, xalign=0.0):
    w = Gtk.Label(label=text, xalign=xalign, wrap=wrap, selectable=False)
    w.set_wrap_mode(Pango.WrapMode.WORD_CHAR)
    for c in classes:
        w.add_css_class(c)
    return w


class UpdateCard(Gtk.Box):
    """The large Noid-OS Update element at the top of the Updates page."""

    def __init__(self, window):
        super().__init__(orientation=Gtk.Orientation.VERTICAL)
        self.window = window
        self.add_css_class("card")

        inner = Gtk.Box(spacing=24, margin_top=24, margin_bottom=24, margin_start=24, margin_end=24)
        self.append(inner)

        self.art = Gtk.Stack(valign=Gtk.Align.CENTER)
        self.icon = Gtk.Image(pixel_size=64)
        self.spinner = Adw.Spinner(width_request=64, height_request=64)
        self.art.add_named(self.icon, "icon")
        self.art.add_named(self.spinner, "spinner")
        inner.append(self.art)

        text = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6, hexpand=True, valign=Gtk.Align.CENTER)
        text.append(label("Noid-OS Update", "title-2"))
        self.status = label("", "title-4")
        self.detail = label("", "dim-label")
        text.append(self.status)
        text.append(self.detail)
        inner.append(text)

        buttons = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6, valign=Gtk.Align.CENTER)
        self.primary = Gtk.Button(valign=Gtk.Align.CENTER)
        self.primary.add_css_class("pill")
        self.primary.connect("clicked", lambda *_: self.on_primary())
        self.secondary = Gtk.Button(valign=Gtk.Align.CENTER)
        self.secondary.add_css_class("flat")
        self.secondary.connect("clicked", lambda *_: self.on_secondary())
        buttons.append(self.primary)
        buttons.append(self.secondary)
        inner.append(buttons)

        self.on_primary = lambda: None
        self.on_secondary = lambda: None

    def show(self, icon, colour, status, detail, primary=None, secondary=None, busy=False):
        self.art.set_visible_child_name("spinner" if busy else "icon")
        self.icon.set_from_icon_name(icon)
        for c in ("accent", "success", "warning", "error"):
            self.icon.remove_css_class(c)
        if colour:
            self.icon.add_css_class(colour)
        self.status.set_label(status)
        self.detail.set_label(detail)
        self.detail.set_visible(bool(detail))
        for widget, spec, attr in ((self.primary, primary, "on_primary"), (self.secondary, secondary, "on_secondary")):
            widget.set_visible(spec is not None)
            if spec:
                text, callback, suggested = spec
                widget.set_label(text)
                widget.set_sensitive(not busy)
                if suggested:
                    widget.add_css_class("suggested-action")
                else:
                    widget.remove_css_class("suggested-action")
                setattr(self, attr, callback)


class Window(Adw.ApplicationWindow):
    def __init__(self, app):
        super().__init__(application=app, title="Nix Actions", default_width=980, default_height=720)
        self.set_size_request(360, 400)
        self.state = None
        self.started_something = False

        self.toasts = Adw.ToastOverlay()
        self.split = Adw.NavigationSplitView(min_sidebar_width=220, max_sidebar_width=280)
        self.toasts.set_child(self.split)
        self.set_content(self.toasts)

        breakpoint_ = Adw.Breakpoint.new(Adw.BreakpointCondition.parse("max-width: 640sp"))
        breakpoint_.add_setter(self.split, "collapsed", GObject.Value(GObject.TYPE_BOOLEAN, True))
        self.add_breakpoint(breakpoint_)

        self.pages = Gtk.Stack(transition_type=Gtk.StackTransitionType.CROSSFADE)

        content_view = Adw.ToolbarView()
        self.content_header = Adw.HeaderBar()
        content_view.add_top_bar(self.content_header)
        content_view.set_content(self.pages)
        self.content_page = Adw.NavigationPage(title="Updates", child=content_view)

        categories = [
            ("updates", "Updates", "noid-software-update-available-symbolic", self.build_updates()),
            ("nix", "Nix features", "noid-utilities-terminal-symbolic", self.build_nix()),
            ("setup", "Additional setup", "noid-preferences-system-symbolic", self.build_setup()),
        ]
        sidebar = Gtk.ListBox(selection_mode=Gtk.SelectionMode.SINGLE)
        sidebar.add_css_class("navigation-sidebar")
        self.titles = {}
        for name, title, icon, page in categories:
            self.pages.add_named(page, name)
            self.titles[name] = title
            row = Gtk.ListBoxRow()
            row.name = name
            box = Gtk.Box(spacing=12, margin_top=6, margin_bottom=6, margin_start=6, margin_end=6)
            box.append(Gtk.Image(icon_name=icon))
            box.append(Gtk.Label(label=title, xalign=0))
            row.set_child(box)
            sidebar.append(row)
        sidebar.connect("row-activated", lambda _, row: self.open_page(row.name))
        sidebar.select_row(sidebar.get_row_at_index(0))

        sidebar_view = Adw.ToolbarView()
        sidebar_view.add_top_bar(Adw.HeaderBar())
        scroller = Gtk.ScrolledWindow(hscrollbar_policy=Gtk.PolicyType.NEVER, child=sidebar)
        sidebar_view.set_content(scroller)
        self.split.set_sidebar(Adw.NavigationPage(title="Nix Actions", child=sidebar_view))
        self.split.set_content(self.content_page)

        self.connect("notify::is-active", self.on_focus)
        self.refresh_updates()
        self.refresh_flakes()

    def open_page(self, name):
        self.pages.set_visible_child_name(name)
        self.content_page.set_title(self.titles[name])
        self.split.set_show_content(True)

    def on_focus(self, *_):
        if self.is_active() and self.started_something:
            self.started_something = False
            self.refresh_updates(online=False)
            self.refresh_cleanup()
            self.refresh_flakes()

    def toast(self, text):
        self.toasts.add_toast(Adw.Toast(title=text, timeout=4, use_markup=False))

    def start(self, command, note=None):
        launch(command)
        self.started_something = True
        if note:
            self.toast(note)

    def confirm(self, heading, body, ok, on_ok, appearance=Adw.ResponseAppearance.SUGGESTED, extra=None):
        dialog = Adw.AlertDialog(heading=heading, body=body)
        dialog.add_response("cancel", "Cancel")
        if extra:
            dialog.add_response("extra", extra[0])
        dialog.add_response("ok", ok)
        dialog.set_response_appearance("ok", appearance)
        dialog.set_default_response("ok")
        dialog.set_close_response("cancel")

        def answered(_, response):
            if response == "ok":
                on_ok()
            elif response == "extra":
                extra[1]()
        dialog.connect("response", answered)
        dialog.present(self)

    # ---- Updates ---------------------------------------------------------------

    def build_updates(self):
        page = Adw.PreferencesPage()

        top = Adw.PreferencesGroup()
        self.card = UpdateCard(self)
        top.add(self.card)
        page.add(top)

        self.news = Adw.PreferencesGroup(visible=False)
        page.add(self.news)
        self.news_rows = []

        maintenance = Adw.PreferencesGroup(title="Maintenance")
        scripts = SETTINGS["scripts"]
        row, _ = action_row("Rebuild", "Apply your settings as they are now.", "noid-view-refresh-symbolic",
                            "Rebuild", lambda: self.start([scripts["rebuild"]], "Rebuild opened in a terminal window."))
        maintenance.add(row)
        row, _ = action_row("Rebuild & Update",
                            "Get the newest versions of every program first, then rebuild. Takes longer, and "
                            "programs may change.", "noid-emblem-synchronizing-symbolic", "Update",
                            lambda: self.start([scripts["update"]], "Rebuild & Update opened in a terminal window."))
        maintenance.add(row)
        self.cleanup_row, _ = action_row("Clean up", SETTINGS["cleanupText"], "noid-user-trash-symbolic", "Clean up",
                                         lambda: self.start([scripts["cleanup"]], "Clean up opened in a terminal window."))
        maintenance.add(self.cleanup_row)
        page.add(maintenance)
        self.refresh_cleanup()

        history = Adw.PreferencesGroup()
        self.history = Adw.ExpanderRow(use_markup=False, title="Release history", visible=False)
        self.history.add_prefix(Gtk.Image(icon_name="noid-document-open-recent-symbolic"))
        history.add(self.history)
        self.history_rows = []
        page.add(history)
        return page

    def refresh_cleanup(self):
        free = free_space()
        text = SETTINGS["cleanupText"]
        if free is not None:
            text += f"\n{size_text(free)} free right now."
        self.cleanup_row.set_subtitle(text)

    def refresh_updates(self, online=True):
        if not SETTINGS.get("sync"):
            self.card.show("noid-software-update-available-symbolic", "accent", "Releases are switched off",
                           "module.sync.enable is off on this computer.")
            return
        if online and not SETTINGS["publisher"]:
            self.card.show("noid-software-update-available-symbolic", None, "Checking for updates...", "",
                           primary=("Check for updates", lambda: None, True), busy=True)
        args = ("check",) if online else ("check", "--offline")
        in_background(lambda: sync(*args), self.show_updates)

    def show_updates(self, result):
        if isinstance(result, Exception) or result.returncode != 0:
            text = str(result) if isinstance(result, Exception) else (result.stderr or result.stdout).strip()
            self.card.show("noid-dialog-error-symbolic", "error", "Something went wrong", text[-400:],
                           primary=("Try again", self.refresh_updates, False))
            return
        state = json.loads(result.stdout)
        self.state = state
        have = state["release"]
        checked = when(state.get("lastCheck"))
        back = None
        if state.get("previous") is not None and not state["publisher"]:
            back = (f"Go back to release {state['previous']}", self.ask_back, False)

        unfinished = state.get("unfinished")

        self.show_news(None)
        self.show_history(state.get("history") or [])

        if state["publisher"]:
            where = state.get("shown") or "not set up yet"
            self.card.show("noid-send-to-symbolic", "accent", "This computer publishes the releases",
                           f"Release {have} · {where}",
                           primary=("Publish changes",
                                    lambda: self.start([SETTINGS["scripts"]["publish"]],
                                                       "Publish changes opened in a terminal window."), True))
        elif unfinished:
            self.card.show("noid-dialog-warning-symbolic", "warning",
                           f"Installing release {unfinished['release']} did not finish",
                           "Its window was closed, or the computer was turned off.",
                           primary=("Finish or undo", self.ask_unfinished, True))
        elif not state.get("channel"):
            self.card.show("noid-software-update-available-symbolic", None, "Not set up for updates yet",
                           "Ask whoever set up this system for the address of its releases.",
                           primary=("Enter address", self.ask_channel, True))
        elif state.get("error"):
            self.card.show("noid-network-offline-symbolic", "warning", "Could not check for updates",
                           state["error"].split("\n\n")[0] + (f"\nLast checked {checked}." if checked else ""),
                           primary=("Try again", self.refresh_updates, False), secondary=back)
        elif state.get("remote") and state["remote"]["release"] > have:
            remote = state["remote"]
            self.card.show("noid-software-update-available-symbolic", "accent",
                           f"Release {remote['release']} is available",
                           f"This computer has release {have}. Installing it rebuilds the system; your own "
                           "settings (hosts/) stay as they are, and if it does not work everything is put back.",
                           primary=(f"Install release {remote['release']}", self.install, True), secondary=back)
            self.show_news(remote)
        else:
            detail = f"Release {have}" + (f" · last checked {checked}" if checked else "")
            if state.get("remote") is None:
                self.card.show("noid-emblem-ok-symbolic", "success", f"Release {have} is installed",
                               f"Last checked {checked}" if checked else "",
                               primary=("Check for updates", self.refresh_updates, False), secondary=back)
            else:
                self.card.show("noid-emblem-ok-symbolic", "success", "You're up to date", detail,
                               primary=("Check for updates", self.refresh_updates, False), secondary=back)

    def show_news(self, remote):
        for row in self.news_rows:
            self.news.remove(row)
        self.news_rows = []
        self.news.set_visible(bool(remote))
        if not remote:
            return
        self.news.set_title(f"What's new in release {remote['release']}")
        for note in remote["notes"]:
            row = Adw.ActionRow(use_markup=False, title=f"Release {note['release']}" + (f" · {note['date']}" if note.get("date") else ""),
                                subtitle=note.get("note", ""))
            row.set_subtitle_lines(0)
            self.news.add(row)
            self.news_rows.append(row)
        if remote.get("changedHere"):
            row = Adw.ActionRow(use_markup=False, title="Changed on this computer, and replaced by the release",
                                subtitle="\n".join(remote["changedHere"][:12]))
            row.set_subtitle_lines(0)
            row.add_prefix(Gtk.Image(icon_name="noid-dialog-warning-symbolic", css_classes=["warning"]))
            self.news.add(row)
            self.news_rows.append(row)

    def show_history(self, notes):
        for row in self.history_rows:
            self.history.remove(row)
        self.history_rows = []
        self.history.set_visible(bool(notes))
        self.history.set_subtitle(f"{len(notes)} release{'s' if len(notes) != 1 else ''}")
        for note in notes:
            row = Adw.ActionRow(use_markup=False, title=f"Release {note['release']}" + (f" · {note['date']}" if note.get("date") else ""),
                                subtitle=note.get("note", ""))
            row.set_subtitle_lines(0)
            self.history.add_row(row)
            self.history_rows.append(row)

    def run_install(self, stage_args, note):
        def work():
            return sync(*stage_args)

        def done(result):
            if isinstance(result, Exception) or result.returncode != 0:
                self.toast("Could not get the release ready: "
                           + (str(result) if isinstance(result, Exception) else result.stdout.strip()[-200:]))
                return
            self.start([SETTINGS["scripts"]["install"]], note)
        in_background(work, done)

    def install(self):
        remote = self.state["remote"]
        self.run_install(("stage", remote["store"]),
                         f"Installing release {remote['release']} in a terminal window.")

    def ask_back(self):
        have, back = self.state["release"], self.state["previous"]
        self.confirm(f"Go back to release {back}?",
                     f"This computer has release {have}. The shared parts go back to how they were and the "
                     "system is rebuilt. Your own settings (hosts/) stay as they are.",
                     f"Go back to release {back}",
                     lambda: self.run_install(("stage-back",), f"Going back to release {back} in a terminal window."))

    def ask_unfinished(self):
        unfinished = (self.state or {}).get("unfinished") or {}
        release = unfinished.get("release", "")

        def undo():
            def done(result):
                ok = not isinstance(result, Exception) and result.returncode == 0
                self.toast("The old files are back. Rebuild to be sure the system matches them." if ok
                           else "The old files could not be put back.")
                self.refresh_updates(online=False)
            in_background(lambda: sync("restore"), done)

        self.confirm(f"Installing release {release} did not finish",
                     "Finish installing it now, or put back the files this computer had before.",
                     "Finish installing", lambda: self.start([SETTINGS["scripts"]["install"]],
                                                             f"Installing release {release} in a terminal window."),
                     extra=("Put the old files back", undo))

    def ask_channel(self):
        dialog = Adw.AlertDialog(heading="Where do updates come from?",
                                 body="Type the address whoever set up this system gave you, for example "
                                      "https://github.com/someone/noid-os")
        entry = Gtk.Entry(placeholder_text="https://github.com/someone/noid-os", activates_default=True)
        dialog.set_extra_child(entry)
        dialog.add_response("cancel", "Cancel")
        dialog.add_response("ok", "Save")
        dialog.set_response_appearance("ok", Adw.ResponseAppearance.SUGGESTED)
        dialog.set_default_response("ok")
        dialog.set_close_response("cancel")

        def answered(_, response):
            if response != "ok":
                return
            result = sync("set-channel", entry.get_text())
            if result.returncode != 0:
                self.toast(result.stdout.strip().splitlines()[-1] if result.stdout.strip() else "That address did not work.")
                return
            self.refresh_updates()
        dialog.connect("response", answered)
        dialog.present(self)

    # ---- Nix features ----------------------------------------------------------

    def build_nix(self):
        page = Adw.PreferencesPage()

        settings = Adw.PreferencesGroup(title="This computer's settings")
        row, _ = action_row("Open user.nix",
                            "hosts/users/user.nix: the desktop, graphics card, modules and programs of this computer. "
                            "Save it, then Rebuild.", "noid-document-edit-symbolic", "Open",
                            lambda: self.open_path(USER_FILE))
        settings.add(row)
        row, _ = action_row("Open the configuration folder", FLAKE, "noid-folder-symbolic", "Open",
                            lambda: self.open_path(FLAKE))
        settings.add(row)
        page.add(settings)

        flakes = Adw.PreferencesGroup(title="Flakes",
                                      description="Programs and settings that someone publishes as a flake.")
        if SETTINGS.get("flakes"):
            row, _ = action_row("Add a Flake", "Paste a link and pick what to install from it. Remove one there too.",
                                "noid-list-add-symbolic", "Add",
                                lambda: self.start([SETTINGS["flakes"], "gui"]))
            flakes.add(row)
            self.flake_rows = []
        else:
            flakes.add(Adw.ActionRow(use_markup=False, title="Add a Flake is switched off", subtitle="module.flakes.enable = false"))
        self.flakes_group = flakes
        page.add(flakes)
        return page

    def open_path(self, path):
        if not os.path.exists(path):
            self.toast(f"{path} does not exist.")
            return
        try:
            Gio.AppInfo.launch_default_for_uri(Gio.File.new_for_path(path).get_uri(), None)
        except GLib.Error as e:
            self.toast(f"Could not open it: {e.message}")

    def refresh_flakes(self):
        if not SETTINGS.get("flakes"):
            return

        def done(result):
            for row in self.flake_rows:
                self.flakes_group.remove(row)
            self.flake_rows = []
            try:
                specs = json.loads(result.stdout) if not isinstance(result, Exception) and result.returncode == 0 else {}
            except ValueError:
                specs = {}
            for name, spec in sorted(specs.items()):
                parts = spec.get("packages", []) + [f"overlay {o}" for o in spec.get("overlays", [])] \
                    + [f"module {m}" for m in spec.get("modules", [])]
                row = Adw.ActionRow(use_markup=False, title=name, subtitle=f"{spec.get('url', '')}\n{', '.join(parts) or 'settings only'}")
                row.set_subtitle_lines(0)
                row.add_prefix(Gtk.Image(icon_name="noid-application-x-addon-symbolic"))
                self.flakes_group.add(row)
                self.flake_rows.append(row)
        in_background(lambda: subprocess.run([SETTINGS["flakes"], "list", "--json"],
                                             capture_output=True, text=True), done)

    # ---- Additional setup ------------------------------------------------------

    def build_setup(self):
        page = Adw.PreferencesPage()

        drives = Adw.PreferencesGroup(title="Drives")
        if SETTINGS.get("drives"):
            row, _ = action_row("Drives",
                                "Open another drive at a folder every time the computer starts, and choose whether "
                                "apps can be installed on it.", "noid-drive-harddisk-symbolic", "Open",
                                lambda: self.start([SETTINGS["drives"]]))
            drives.add(row)
            for folder, d in sorted(SETTINGS.get("driveList", {}).items()):
                kind = (d.get("fsType") or "").upper()
                use = "files and apps" if d.get("apps") else "files"
                row = Adw.ActionRow(use_markup=False, title=d.get("label") or folder, subtitle=f"{folder} · {kind} · {use}")
                row.add_prefix(Gtk.Image(icon_name="noid-drive-harddisk-symbolic", css_classes=["dim-label"]))
                drives.add(row)
        else:
            drives.add(Adw.ActionRow(use_markup=False, title="Drives is switched off", subtitle="module.drives.enable = false"))
        page.add(drives)

        apps = Adw.PreferencesGroup(title="Apps")
        locations = SETTINGS.get("locations", [])
        if locations:
            subtitle = ("Move installed apps between the main drive and " + ", ".join(locations)
                        + ". The app store can also install straight onto these drives.")
        else:
            subtitle = "Apps can go on another drive once it is set up for apps in Drives (then Rebuild)."
        row, b = action_row("App install locations", subtitle, "noid-folder-download-symbolic", "Open",
                            lambda: self.start([SETTINGS["appDrives"]]))
        b.set_sensitive(bool(SETTINGS.get("appDrives")))
        apps.add(row)
        page.add(apps)

        if SETTINGS.get("passwords"):
            secrets = Adw.PreferencesGroup(title="Passwords")
            row, _ = action_row("Passwords", "Type in the passwords this computer needs, for example a network "
                                "share's login.", "noid-dialog-password-symbolic", "Open",
                                lambda: self.start([SETTINGS["passwords"]]))
            secrets.add(row)
            page.add(secrets)
        return page


class App(Adw.Application):
    def __init__(self):
        super().__init__(application_id="org.noid.NixActions", flags=Gio.ApplicationFlags.DEFAULT_FLAGS)
        self.connect("activate", self.on_activate)

    def on_activate(self, app):
        Gtk.IconTheme.get_for_display(Gdk.Display.get_default()).add_search_path(SETTINGS["icons"])
        window = self.get_active_window() or Window(self)
        window.present()


if __name__ == "__main__":
    sys.exit(App().run(sys.argv[:1]))
