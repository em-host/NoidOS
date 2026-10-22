# Pasted into the terminal scripts by ../nix-actions.nix.

terminal=(@terminal@)
flock=@flock@

pause() {
  echo
  read -r -p "Press Enter to close this window..." _ || true
}

password_hint() {
  echo "If it asks for your password, type it and press Enter."
  echo "Nothing shows while you type. That is normal."
}

stop() {
  echo
  echo "$1"
  pause
  exit 1
}

# Started from the menu: re-run inside a terminal so progress and sudo are visible.
if [ ! -t 0 ] || [ ! -t 1 ]; then
  exec "${terminal[@]}" "$0"
fi

exec 9>"${XDG_RUNTIME_DIR:-/tmp}/nix-actions.lock"
if ! "$flock" -n 9; then
  echo "Another Nix action is already running in another window."
  pause
  exit 0
fi
