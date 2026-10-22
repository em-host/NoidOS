set -euo pipefail

mode=@mode@
flake_dir=@flakeDir@
flake_host=@flakeHost@
nix=@nix@
flakes_tool=@flakes@ # empty when the flakes module is switched off
sync=@sync@          # the release tool; only in "sync" mode

@common@

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

# Everything before nixos-rebuild runs as the user, so flake.lock stays theirs.

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

if [ "$mode" = sync ]; then
  "$sync" apply || stop "The new release could not be put in place. Nothing was changed."
  echo
fi

if [ -n "$flakes_tool" ]; then
  "$flakes_tool" --dir "$flake_dir" sync || {
    undo_changes
    stop "The added flakes could not be made ready, so nothing was rebuilt."
  }
fi

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

# Lock as the user: the root rebuild would otherwise write a root-owned flake.lock.
"$nix" --extra-experimental-features "nix-command flakes" --option warn-dirty false flake lock ||
  {
    undo_changes
    stop "The lock file could not be completed. Check your internet connection."
  }

# Caches the new configuration adds only reach nix.conf after this rebuild, so pass them
# to it directly. If the evaluation fails, rebuild without them and show the real error.
echo "Checking which download servers the configuration uses..."
cache_args=()
caches=$("$nix" --extra-experimental-features "nix-command flakes" --option warn-dirty false \
  eval --raw ".#nixosConfigurations.\"$flake_host\".config.nix.settings" --apply '
    s: let l = n: s.${n} or [ ]; in
    builtins.concatStringsSep " " (l "extra-substituters" ++ l "substituters") + "\n"
    + builtins.concatStringsSep " " (l "extra-trusted-public-keys" ++ l "trusted-public-keys")' \
  2>/dev/null) || caches=""
substituters="${caches%%$'\n'*}"
keys="${caches#*$'\n'}"
if [[ $caches == *$'\n'* ]] && [ -n "$substituters" ] && [ -n "$keys" ]; then
  cache_args=(--option extra-substituters "$substituters" --option extra-trusted-public-keys "$keys")
fi
echo

# A failure while building leaves the old system (undo the changes); a failure while
# switching (exit 2/4) means the new system is installed (keep them).
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
  # The profile can look unchanged when an earlier try already installed this system.
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
