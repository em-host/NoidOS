set -euo pipefail

# The @...@ placeholders below are filled in by ../nix-actions.nix.
#
# mode is "rebuild" (apply the configuration with the versions already locked
# in flake.lock), "update" (first fetch the newest versions of everything) or
# "sync" (first put a new release's shared files in place: Get the latest
# release, see sync/sync.py).
mode=@mode@
flake_dir=@flakeDir@
flake_host=@flakeHost@
nix=@nix@
flakes_tool=@flakes@ # empty when the flakes module is switched off
sync=@sync@          # the release tool; only in "sync" mode

@common@

# --- Step 1: look at the config folder ---------------------------------------
case "$mode" in
  update) echo "Updating and rebuilding NixOS" ;;
  sync) echo "Installing a new release" ;;
  *) echo "Rebuilding NixOS" ;;
esac
echo "Config folder: $flake_dir"
echo
password_hint
echo

if [ ! -f "$flake_dir/flake.nix" ]; then
  echo "Could not find flake.nix in $flake_dir"
  echo "The NixOS config folder needs to live at exactly that location."
  pause
  exit 1
fi

cd "$flake_dir"

# Everything up to the rebuild itself runs as you, not as root, so the files in
# the config folder (flake.lock in particular) always stay yours.

# What Update & Rebuild and a new release change is put back when what comes
# after fails (see below), so Rebuild keeps working as before.
lock_files=("$flake_dir/flake.lock" "$flake_dir/hosts/flakes/registry/flake.lock")
saved_locks=$(mktemp -d)
trap 'rm -rf "$saved_locks"' EXIT

restore_locks() {
  local i=0 file
  for file in "${lock_files[@]}"; do
    if [ -f "$saved_locks/$i" ]; then
      cp -p -- "$saved_locks/$i" "$file"
    fi
    i=$((i + 1))
  done
}

undo_changes() {
  case "$mode" in
    update) restore_locks ;;
    sync) "$sync" restore || true ;;
  esac
}

# --- Step 1b (new release only): its files ------------------------------------
# A copy of the files it replaces is made first (and put back if anything below
# fails). hosts/ is left as it is.
if [ "$mode" = sync ]; then
  "$sync" apply || stop "The new release could not be put in place. Nothing was changed."
  echo
fi

# --- Step 2: flakes added with "Add a Flake" ---------------------------------
# Brings hosts/flakes/registry and the lock files in line with the flake files
# (see modules/flakes/). Does nothing when nothing changed.
if [ -n "$flakes_tool" ]; then
  "$flakes_tool" --dir "$flake_dir" sync || {
    undo_changes
    stop "The added flakes could not be made ready, so nothing was rebuilt."
  }
fi

# --- Step 3 (Update & Rebuild only): fetch the newest versions ---------------
# The locks are copied first: if the new versions turn out not to build, the
# old ones are put back.

if [ "$mode" = update ]; then
  i=0
  for file in "${lock_files[@]}"; do
    if [ -f "$file" ]; then
      cp -p -- "$file" "$saved_locks/$i"
    fi
    i=$((i + 1))
  done

  echo "Fetching the newest versions of everything..."
  update_ok=0
  if [ -n "$flakes_tool" ]; then
    "$flakes_tool" --dir "$flake_dir" update || update_ok=$?
  else
    "$nix" --extra-experimental-features "nix-command flakes" flake update || update_ok=$?
  fi
  if [ "$update_ok" -ne 0 ]; then
    restore_locks
    stop "The updates could not be fetched. Check your internet connection. Nothing was changed."
  fi
  echo
fi

# --- Step 4: complete the lock file ------------------------------------------
# Adds whatever is still missing from flake.lock (nothing, normally). Done here,
# as you, because the rebuild below runs as root and would otherwise leave a
# flake.lock behind that you can no longer change.
"$nix" --extra-experimental-features "nix-command flakes" --option warn-dirty false flake lock ||
  {
    undo_changes
    stop "The lock file could not be completed. Check your internet connection."
  }

# --- Step 5: the actual rebuild ----------------------------------------------
# Download servers that the configuration adds (an added flake's, or ComfyUI's for
# module.ai.media) only become part of the system's Nix settings once a rebuild
# has finished. The new configuration is asked for them first and they are handed
# to the rebuild itself, so even the rebuild that adds them downloads ready-made
# programs instead of compiling them. (If that question fails, the rebuild runs
# without them and shows the real problem.)
echo "Checking which download servers the configuration uses..."
cache_args=()
caches=$("$nix" --extra-experimental-features "nix-command flakes" --option warn-dirty false \
  eval --raw ".#nixosConfigurations.\"$flake_host\".config.nix.settings" --apply '
    s: let l = n: s.${n} or [ ]; in
    builtins.concatStringsSep " " (l "extra-substituters" ++ l "substituters") + "\n"
    + builtins.concatStringsSep " " (l "extra-trusted-public-keys" ++ l "trusted-public-keys")' \
  2>/dev/null) || caches=""
substituters="${caches%%$'\n'*}" # first line
keys="${caches#*$'\n'}"           # second line
if [[ $caches == *$'\n'* ]] && [ -n "$substituters" ] && [ -n "$keys" ]; then
  cache_args=(--option extra-substituters "$substituters" --option extra-trusted-public-keys "$keys")
fi
echo

# Which system is installed before and after. A rebuild can fail at two points:
# while building (nothing is installed, the old system stays) or while switching
# over (the new system IS installed and is what starts from now on; a background
# service just had trouble starting, which nixos-rebuild reports as exit code 4).
# Only in the first case are the old versions put back.
system_profile=/nix/var/nix/profiles/system
installed_before=$(readlink "$system_profile" 2>/dev/null || true)

status=0
/run/wrappers/bin/sudo nixos-rebuild switch --flake ".#$flake_host" "${cache_args[@]}" || status=$?

installed_after=$(readlink "$system_profile" 2>/dev/null || true)

echo
if [ "$status" -eq 0 ]; then
  case "$mode" in
    update) echo "Done. Everything is updated and your system is up to date." ;;
    sync) "$sync" finish || true ;;
    *) echo "Done. Your system is up to date." ;;
  esac
elif [ "$installed_after" != "$installed_before" ] || [ "$status" -eq 2 ] || [ "$status" -eq 4 ]; then
  # (Exit codes 2 and 4 only come from the switching-over step, which runs once
  # the new system is built and installed. The installed system can also look
  # unchanged when this exact system was already installed by an earlier try.)
  # Switched over, with a problem along the way: keep everything as it now is.
  case "$mode" in
    update) echo "Done. Everything is updated and the new system is installed." ;;
    sync) "$sync" finish || true ;;
    *) echo "Done. The new system is installed." ;;
  esac
  echo
  echo "Something had a problem while switching over (exit code $status; above, look"
  echo "for \"the following units failed\"). That is usually only a hiccup of the"
  echo "moment and gone after a restart. The computer is fine to use; if the same"
  echo "problem shows up again after a restart, it needs a look."
  status=0
else
  case "$mode" in
    update)
      restore_locks
      echo "The rebuild failed (exit code $status). Scroll up to see why."
      echo "The new versions were not kept: your previous versions are back in place,"
      echo "so Rebuild keeps working as before."
      ;;
    sync)
      echo "The new release did not work on this computer (exit code $status). Scroll up to"
      echo "see why."
      "$sync" restore || true
      echo "Let whoever looks after this system know; a photo of the error above helps."
      ;;
    *)
      echo "The rebuild failed (exit code $status). Scroll up to see why."
      ;;
  esac
fi

pause
exit "$status"
