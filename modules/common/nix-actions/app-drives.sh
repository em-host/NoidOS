set -euo pipefail

tool=@tool@

@common@

status=0
"$tool" move || status=$?
pause
exit "$status"
