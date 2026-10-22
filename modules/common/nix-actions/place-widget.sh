set -u

# The @...@ placeholders below are filled in by ../nix-actions.nix.
busctl=@busctl@
script_file=@scriptFile@

js="$(cat "$script_file")"

# Ask the running Plasma shell to run place-widget.js.
# Prints what the script reported: added / present / no-panel / unknown-widget
run_in_plasma() {
  "$busctl" --user call org.kde.plasmashell /PlasmaShell \
    org.kde.PlasmaShell evaluateScript s "$js" 2>/dev/null || true
}

refreshed_cache=0

# Plasma needs a moment after login before its panel exists, so keep trying.
for _ in $(seq 1 90); do
  result="$(run_in_plasma)"

  case "$result" in
    *added* | *present*)
      exit 0
      ;;
    *unknown-widget*)
      # Plasma has not noticed the new widget yet: refresh its plugin cache, once.
      if [ "$refreshed_cache" -eq 0 ] && command -v kbuildsycoca6 >/dev/null 2>&1; then
        kbuildsycoca6 --noincremental >/dev/null 2>&1 || true
        refreshed_cache=1
      fi
      ;;
  esac

  sleep 2
done

echo "Gave up: could not add the Nix Actions widget to the Plasma panel." >&2
exit 1
