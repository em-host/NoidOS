set -euo pipefail

export PATH="@path@:$PATH"
folder=@folder@
appimage_run=@appimageRun@
integrate=@integrate@

apps_dir="$HOME/$folder"
state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/appimage-integration"
seen_file="$state_dir/seen"

if [ "${1:-}" = "--remove" ]; then
  file="${2:?usage: appimage-open --remove FILE}"
  name="$(basename "$file")"
  if zenity --question --no-markup --width=440 --title="Remove $name" \
       --text="Remove this app and delete its file?"$'\n\n'"$name"$'\n\n'"This cannot be undone." \
       --ok-label="Remove" --cancel-label="Keep"; then
    rm -f -- "$file"
    "$integrate" --once
  fi
  exit 0
fi

file="${1:-}"
if [ -z "$file" ]; then
  echo "Usage: appimage-open FILE.AppImage [ARGS...]" >&2
  exit 2
fi
shift
real="$(realpath -- "$file")"
name="$(basename "$real")"

# Only ask for a plain double-click: not from a terminal or script, not with arguments,
# not for files already in ~/Applications or marked "just run".
ask=@ask@
if [ -t 0 ] || [ -t 1 ]; then ask=0; fi
if [ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then ask=0; fi
if [ -n "${APPIMAGE_NO_PROMPT:-}" ] || [ "$#" -gt 0 ]; then ask=0; fi
if [ "$(dirname "$real")" = "$(realpath -m -- "$apps_dir")" ]; then ask=0; fi
if grep -qxF -- "$real" "$seen_file" 2>/dev/null; then ask=0; fi

if [ "$ask" = "1" ]; then
  rc=0
  choice="$(zenity --question --no-markup --width=460 --title="Add $name?" \
    --text="Add this app to your app menu?"$'\n\n'"$name"$'\n\n'"\"Add\" moves it to your $folder folder, so it shows up with the other apps and can be removed later." \
    --ok-label="Add to app menu" --extra-button="Just run it" --cancel-label="Cancel")" || rc=$?

  if [ "$rc" -eq 0 ]; then
    mkdir -p "$apps_dir"
    dest="$apps_dir/$name"
    if [ "$real" != "$dest" ]; then
      mv -f -- "$real" "$dest" 2>/dev/null || cp -f -- "$real" "$dest"
    fi
    chmod +x "$dest"
    "$integrate" --once
    exec "$appimage_run" "$dest"
  elif [ "$choice" = "Just run it" ]; then
    mkdir -p "$state_dir"
    printf '%s\n' "$real" >> "$seen_file"
  else
    exit 0
  fi
fi

exec "$appimage_run" "$real" "$@"
