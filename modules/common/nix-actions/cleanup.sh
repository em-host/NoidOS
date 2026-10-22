set -euo pipefail

# The @...@ placeholders below are filled in by ../nix-actions.nix.
#
# Frees disk space on request. It does what the weekly automatic cleanup does
# (see modules/common/garbage-clean.nix), only right now:
#
#   1. removes old system versions and programs nothing uses any more
#   2. updates the boot menu, so it does not offer versions that are now gone
#   3. makes identical files share their disk space
gc_options=@gcOptions@ # e.g. "--delete-older-than 14d"; empty: only unused programs go
policy=@policy@        # the same thing in words
collect_garbage=@collectGarbage@
nix_store=@nixStore@
switch_config=/nix/var/nix/profiles/system/bin/switch-to-configuration
df=@df@
numfmt=@numfmt@

@common@

# How many bytes are free on the disk that holds the Nix store.
free_bytes() {
  "$df" --output=avail -B1 /nix/store | tail -n 1 | tr -d ' '
}

echo "Cleaning up NixOS"
echo "$policy"
echo
password_hint
echo

free_before=$(free_bytes)

# --- Step 1: old versions and unused programs --------------------------------
echo "Step 1 of 3: removing old system versions and programs nobody uses..."
read -r -a gc_args <<<"$gc_options" # a list of options, so split it into words
/run/wrappers/bin/sudo "$collect_garbage" "${gc_args[@]}" ||
  stop "Cleaning up failed. Scroll up to see why. Nothing else was done."
echo

# --- Step 2: the boot menu ----------------------------------------------------
# It lists the system versions that exist, so it has to be written again now
# that some are gone.
echo "Step 2 of 3: updating the boot menu..."
if ! /run/wrappers/bin/sudo "$switch_config" boot; then
  echo "The boot menu could not be updated. It will be updated the next time you rebuild."
fi
echo

# --- Step 3: share identical files -------------------------------------------
echo "Step 3 of 3: letting identical files share their space (this can take a few minutes)..."
status=0
/run/wrappers/bin/sudo "$nix_store" --optimise || status=$?
echo

# --- The result ---------------------------------------------------------------
freed=$(($(free_bytes) - free_before))
if [ "$freed" -lt 0 ]; then
  freed=0 # something else wrote to the disk in the meantime
fi

if [ "$status" -ne 0 ]; then
  echo "The last step did not finish (exit code $status). Scroll up to see why."
elif [ "$freed" -gt 0 ]; then
  size=$("$numfmt" --to=iec-i --suffix=B --format=%.1f "$freed") # like 3.5GiB
  if [[ $size =~ ^([0-9.,]+)(.*)$ ]]; then
    size="${BASH_REMATCH[1]} ${BASH_REMATCH[2]}" # 3.5 GiB
  fi
  echo "Done. $size freed."
else
  echo "Done. There was hardly anything to clean up."
fi

pause
exit "$status"
