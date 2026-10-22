# The start that rebuild.sh and cleanup.sh have in common: get into a terminal
# window, and never run two actions at once. ../nix-actions.nix pastes this
# file into each of them, in the place marked "common" at their top, and fills
# in the gaps between @ signs.

terminal=(@terminal@)
flock=@flock@

pause() {
  echo
  read -r -p "Press Enter to close this window..." _ || true
}

# For anyone who has never typed a password into a terminal: it stays invisible.
password_hint() {
  echo "If it asks for your password, type it and press Enter."
  echo "Nothing shows while you type. That is normal."
}

# Say what went wrong, wait for Enter, and end with an error.
stop() {
  echo
  echo "$1"
  pause
  exit 1
}

# Started from the menu or a panel button, so there is no terminal yet. Run
# this same script again inside a terminal window, so the progress can be seen
# and the password typed when sudo asks for it.
if [ ! -t 0 ] || [ ! -t 1 ]; then
  exec "${terminal[@]}" "$0"
fi

# Never two at once (a double click, or a cleanup in the middle of a rebuild).
exec 9>"${XDG_RUNTIME_DIR:-/tmp}/nix-actions.lock"
if ! "$flock" -n 9; then
  echo "Another Nix action is already running in another window."
  pause
  exit 0
fi
