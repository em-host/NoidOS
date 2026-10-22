set -euo pipefail

sync=@sync@

@common@

status=0
"$sync" publish || status=$?
pause
exit "$status"
