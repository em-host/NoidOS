set -euo pipefail

# Nix Actions -> Publish changes, in a terminal window (sync.py does the work).
# The @...@ placeholders are filled in by ../../nix-actions.nix.
sync=@sync@

@common@

status=0
"$sync" publish || status=$?
pause
exit "$status"
