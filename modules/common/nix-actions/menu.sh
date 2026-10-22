set -euo pipefail

window=@window@
rebuild=@rebuild@
update=@update@
cleanup=@cleanup@
drives=@drives@      # empty when the drives module is switched off
passwords=@passwords@ # empty when no secrets are declared
app_drives=@appDrives@ # empty when there is no other drive for apps
releases=@releases@   # Noid-OS Update (empty on the computer that publishes them)
publish=@publish@     # Publish changes (only on the computer that publishes releases)
flakes_tool=@flakes@ # empty when the flakes module is switched off

usage() {
  cat <<'EOF'
Usage: nix-actions [ACTION]

Without an action, the Nix Actions window opens. The actions:

  rebuild   Apply your settings as they are now.
  update    Get the newest versions of everything first, then rebuild.
  release   See whether a new release of this system is out, and install it
            ("Noid-OS Update").
  go-back   Go back to the release this computer had before.
  publish   Publish your changes as a new release ("Publish changes"; only on
            the computer that publishes releases).
  flake     Add programs or settings from a link ("Add a Flake").
  drives    Open another drive at a fixed folder every time ("Drives").
  passwords Type in the passwords the configuration needs ("Passwords").
  apps      Move installed apps to another drive ("App install locations").
  cleanup   Free disk space.
EOF
}

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
    apps)
      if [ -z "$app_drives" ]; then
        echo 'There is no other drive for apps (add a Linux-formatted one with Drives).' >&2
        exit 1
      fi
      exec "$app_drives"
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

case "${1:-menu}" in
  menu)
    if [ -z "${WAYLAND_DISPLAY:-}${DISPLAY:-}" ]; then
      echo "There is no screen to show the menu on. Pick an action instead:" >&2
      echo >&2
      usage >&2
      exit 1
    fi
    exec "$window"
    ;;
  -h | --help | help)
    usage
    ;;
  *)
    run "$1"
    ;;
esac
