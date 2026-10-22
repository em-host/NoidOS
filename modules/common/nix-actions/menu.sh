set -euo pipefail

# The @...@ placeholders below are filled in by ../nix-actions.nix.
#
#   nix-actions            opens the menu
#   nix-actions rebuild    does one of the actions straight away
#
# To add an action: give it a row in menu() and a line in run(). The rest is
# the script that does the work.
zenity=@zenity@
rebuild=@rebuild@
update=@update@
cleanup=@cleanup@
drives=@drives@      # empty when the drives module is switched off
passwords=@passwords@ # empty when no secrets are declared
releases=@releases@   # Get the latest release (empty on the computer that publishes them)
publish=@publish@     # Publish changes (only on the computer that publishes releases)
flakes_tool=@flakes@ # empty when the flakes module is switched off
cleanup_text=@cleanupText@

usage() {
  cat <<'EOF'
Usage: nix-actions [ACTION]

Without an action, a menu opens. The actions:

  rebuild   Apply your settings as they are now.
  update    Get the newest versions of everything first, then rebuild.
  release   See whether a new release of this system is out, and install it
            ("Get the latest release").
  go-back   Go back to the release this computer had before.
  publish   Publish your changes as a new release ("Publish changes"; only on
            the computer that publishes releases).
  flake     Add programs or settings from a link ("Add a Flake").
  drives    Open another drive at a fixed folder every time ("Drives").
  passwords Type in the passwords the configuration needs ("Passwords").
  cleanup   Free disk space.
EOF
}

# Does one action. Replaces this script, so nothing below it runs afterwards.
run() {
  case "$1" in
    rebuild) exec "$rebuild" ;;
    update) exec "$update" ;;
    release | go-back)
      if [ -z "$releases" ]; then
        echo 'This computer publishes the releases (myOS.sync.publish), or releases are switched off.' >&2
        exit 1
      fi
      if [ "$1" = go-back ]; then exec "$releases" back; fi
      exec "$releases" gui
      ;;
    publish)
      if [ -z "$publish" ]; then
        echo 'This computer does not publish releases (set myOS.sync.publish = true in hosts/users/user.nix to change that).' >&2
        exit 1
      fi
      exec "$publish"
      ;;
    cleanup) exec "$cleanup" ;;
    flake)
      if [ -z "$flakes_tool" ]; then
        echo 'Add a Flake is switched off (module.flakes.enable = false).' >&2
        exit 1
      fi
      exec "$flakes_tool" gui
      ;;
    passwords)
      if [ -z "$passwords" ]; then
        echo 'This computer needs no passwords (none are declared in myOS.secrets).' >&2
        exit 1
      fi
      exec "$passwords"
      ;;
    drives)
      if [ -z "$drives" ]; then
        echo 'Drives is switched off (module.drives.enable = false).' >&2
        exit 1
      fi
      exec "$drives"
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
}

menu() {
  # id, name and what it does, three words to a row
  local rows=(
    rebuild "Rebuild" "Apply your settings as they are now."
    update "Update & Rebuild" "Get the newest versions of everything first. Takes longer, and programs may change."
  )
  if [ -n "$releases" ]; then
    rows+=(release "Get the latest release" "See what is new in this system (fixes, settings, programs) and install it if you want. Your own settings stay as they are.")
  fi
  if [ -n "$publish" ]; then
    rows+=(publish "Publish changes" "Send your changes to flake.nix, lib/ and modules/ to every computer that uses this system, as a new release. They choose when to install it.")
  fi
  if [ -n "$flakes_tool" ]; then
    rows+=(flake "Add a Flake" "Add programs or settings from a link. You can remove one there too.")
  fi
  if [ -n "$drives" ]; then
    rows+=(drives "Drives" "Use another drive: it opens at a folder of your choice every time the computer starts.")
  fi
  if [ -n "$passwords" ]; then
    rows+=(passwords "Passwords" "Type in the passwords this computer needs, for example a network share's login.")
  fi
  rows+=(cleanup "Clean up" "$cleanup_text")

  local choice tries=0
  while [ "$tries" -lt 3 ]; do
    tries=$((tries + 1))
    # Close, Escape or the window's X: zenity exits with an error and there is
    # nothing to do. (The first row is selected to begin with.)
    choice=$("$zenity" --list \
      --title="Nix Actions" --text="What would you like to do?" \
      --column=id --column=Action --column="What it does" \
      --hide-column=1 --print-column=1 --hide-header \
      --width=760 --height=420 \
      --ok-label=Go --cancel-label=Close \
      "${rows[@]}") || exit 0
    if [ -n "$choice" ]; then
      run "$choice"
    fi
  done
}

case "${1:-menu}" in
  menu)
    if [ -z "${WAYLAND_DISPLAY:-}${DISPLAY:-}" ]; then
      echo "There is no screen to show the menu on. Pick an action instead:" >&2
      echo >&2
      usage >&2
      exit 1
    fi
    menu
    ;;
  -h | --help | help)
    usage
    ;;
  *)
    run "$1"
    ;;
esac
