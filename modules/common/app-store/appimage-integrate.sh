set -euo pipefail

# The @...@ placeholders below are filled in by ../app-store.nix.
export PATH="@path@:$PATH"
folder=@folder@

apps_dir="$HOME/$folder"
data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
desktop_dir="$data_home/applications"
icon_dir="$data_home/appimage-integration/icons"
cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}"
marker="X-AppImage-Integration-Source"

log() { printf '[appimage-integrate] %s\n' "$*" >&2; }

# "My App-1.2_x86_64.AppImage" -> "my-app-1-2-x86-64"
slug() {
  basename "$1" \
    | sed -E 's/\.appimage$//I' \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g'
}

# Copy the menu entry and icons out of an AppImage into the directory $2.
# Works the same way as appimage-run does (see nixpkgs appimage-exec.sh).
extract_metadata() {
  local app="$1" out="$2" header signature type offset
  header="$(LC_ALL=C readelf -h "$app" 2>/dev/null)" || return 1

  signature="$(printf '%s\n' "$header" | awk 'NR==2{print $10$11;}')"
  [ "$signature" = "4149" ] || return 1 # not an AppImage

  type="$(printf '%s\n' "$header" | awk 'NR==2{print $12;}')"
  case "$type" in
    02)
      offset="$(printf '%s\n' "$header" \
        | awk 'NR==13{e_shoff=$5} NR==18{e_shentsize=$5} NR==19{e_shnum=$5} END{print e_shoff+e_shentsize*e_shnum}')"
      unsquashfs -q -f -d "$out" -o "$offset" "$app" \
        '*.desktop' '.DirIcon' '*.png' '*.svg' 'usr/share/icons' >/dev/null 2>&1 || true
      if ! find "$out" -maxdepth 1 -name '*.desktop' | grep -q .; then
        # Unusual layout: fall back to unpacking everything.
        unsquashfs -q -f -d "$out" -o "$offset" "$app" >/dev/null 2>&1 || true
      fi
      ;;
    01)
      bsdtar -x -C "$out" -f "$app" '*.desktop' '.DirIcon' '*.png' '*.svg' 2>/dev/null || true
      ;;
    *)
      return 1
      ;;
  esac
}

# Print the best icon file found in the extracted directory $1, for the icon
# name $2 taken from the .desktop file. Prints nothing if there is none.
find_icon() {
  local dir="$1" name="$2" f

  if [ -n "$name" ]; then
    for f in "$dir/$name.svg" "$dir/$name.png" "$dir/$name.xpm"; do
      if [ -f "$f" ]; then printf '%s\n' "$f"; return; fi
    done
    # The biggest matching file under usr/share/icons.
    f="$(find "$dir/usr/share/icons" -type f \( -name "$name.svg" -o -name "$name.png" \) \
          -printf '%s %p\n' 2>/dev/null | sort -rn | head -n 1 | cut -d' ' -f2-)"
    if [ -n "$f" ]; then printf '%s\n' "$f"; return; fi
  fi

  if [ -e "$dir/.DirIcon" ]; then
    f="$(readlink -f "$dir/.DirIcon" 2>/dev/null || true)"
    case "$f" in
      "$dir"/*) if [ -f "$f" ]; then printf '%s\n' "$f"; return; fi ;;
    esac
  fi

  f="$(find "$dir" -maxdepth 1 -type f \( -name '*.svg' -o -name '*.png' \) | sort | head -n 1)"
  if [ -n "$f" ]; then printf '%s\n' "$f"; fi
}

# Write the menu entry $4 for the AppImage $1, from the AppImage's own .desktop
# file $2 (may be empty) and icon $3 (may be empty). Every entry also gets a
# "Remove this app" action (right-click the app in the menu).
write_entry() {
  local app="$1" source_desktop="$2" icon="$3" dest="$4" fallback_name has_actions=0
  if [ -n "$source_desktop" ]; then
    if grep -q '^Actions=' "$source_desktop"; then has_actions=1; fi
    APP="$app" ICON="$icon" MARKER="$marker" HAS_ACTIONS="$has_actions" awk '
      BEGIN { first = 1; app = ENVIRON["APP"]; icon = ENVIRON["ICON"]; marker = ENVIRON["MARKER"]
              has = ENVIRON["HAS_ACTIONS"]; gsub(/%/, "%%", app) }
      /^Exec=/ { rest = $0; sub(/^Exec=[^ ]*/, "", rest); print "Exec=\"" app "\"" rest; next }
      /^Icon=/ && icon != "" { print "Icon=" icon; next }
      /^(TryExec|X-AppImage-)/ { next }
      /^Actions=/ { acts = $0; sub(/^Actions=/, "", acts); if (acts !~ /;$/) acts = acts ";"
                    print "Actions=" acts "remove-appimage;"; next }
      { print }
      /^\[Desktop Entry\]/ && first { print marker "=" ENVIRON["APP"]
                                       if (has != "1") print "Actions=remove-appimage;"; first = 0 }
      END { print ""; print "[Desktop Action remove-appimage]"
            print "Name=Remove this app (deletes the AppImage)"; print "Icon=edit-delete"
            print "Exec=appimage-open --remove \"" app "\"" }
    ' "$source_desktop" > "$dest.tmp"
  else
    # The AppImage ships no menu entry: make a plain one.
    fallback_name="$(basename "$app")"
    fallback_name="${fallback_name%.[Aa]pp[Ii]mage}"
    {
      printf '[Desktop Entry]\nType=Application\n'
      printf 'Name=%s\n' "$fallback_name"
      printf 'Exec="%s" %%U\n' "${app//%/%%}"
      [ -z "$icon" ] || printf 'Icon=%s\n' "$icon"
      printf 'Categories=Utility;\nTerminal=false\nActions=remove-appimage;\n'
      printf '%s=%s\n' "$marker" "$app"
      printf '\n[Desktop Action remove-appimage]\nName=Remove this app (deletes the AppImage)\nIcon=edit-delete\n'
      printf 'Exec=appimage-open --remove "%s"\n' "${app//%/%%}"
    } > "$dest.tmp"
  fi
  mv -f "$dest.tmp" "$dest"
}

integrate_one() {
  local app="$1" id="$2" tmp desktop icon_name icon_src ext icon_dest=""

  mkdir -p "$cache_dir"
  tmp="$(mktemp -d -p "$cache_dir" appimage-integrate.XXXXXX)"

  if ! extract_metadata "$app" "$tmp"; then
    chmod -R u+w "$tmp" 2>/dev/null || true
    rm -rf "$tmp"
    return 1
  fi

  desktop="$(find "$tmp" -maxdepth 1 -name '*.desktop' | sort | head -n 1)"
  icon_name=""
  if [ -n "$desktop" ]; then
    icon_name="$(sed -n 's/^Icon=//p' "$desktop" | head -n 1)"
  fi

  icon_src="$(find_icon "$tmp" "$icon_name")"
  if [ -n "$icon_src" ]; then
    ext="${icon_src##*.}"
    case "$ext" in png | svg | xpm) ;; *) ext=png ;; esac
    rm -f "$icon_dir/$id".*
    cp -L "$icon_src" "$icon_dir/$id.$ext"
    icon_dest="$icon_dir/$id.$ext"
  fi

  write_entry "$app" "$desktop" "$icon_dest" "$desktop_dir/appimage-$id.desktop"

  chmod -R u+w "$tmp" 2>/dev/null || true
  rm -rf "$tmp"
  log "added $(basename "$app") to the app menu"
}

# Remove menu entries whose AppImage has been deleted. Prints 1 if it removed any.
cleanup() {
  local entry source id removed=0
  for entry in "$desktop_dir"/appimage-*.desktop; do
    [ -f "$entry" ] || continue
    source="$(sed -n "s/^$marker=//p" "$entry" | head -n 1)"
    [ -n "$source" ] || continue # not one of ours
    if [ ! -f "$source" ]; then
      id="$(basename "$entry" .desktop)"
      id="${id#appimage-}"
      rm -f "$entry" "$icon_dir/$id".*
      log "removed the menu entry for $(basename "$source")"
      removed=1
    fi
  done
  printf '%s' "$removed"
}

sync_all() {
  local app id dest changed=0 removed
  mkdir -p "$apps_dir" "$desktop_dir" "$icon_dir"

  shopt -s nullglob nocaseglob
  for app in "$apps_dir"/*.AppImage; do
    [ -f "$app" ] || continue
    [ -x "$app" ] || chmod +x "$app" 2>/dev/null || true

    id="$(slug "$app")"
    [ -n "$id" ] || continue
    dest="$desktop_dir/appimage-$id.desktop"

    # Already done, and the AppImage has not been replaced since.
    if [ -f "$dest" ] && [ ! "$app" -nt "$dest" ]; then continue; fi

    if integrate_one "$app" "$id"; then
      changed=1
    else
      log "could not read $(basename "$app"); is it a complete AppImage?"
    fi
  done
  shopt -u nullglob nocaseglob

  shopt -s nullglob
  removed="$(cleanup)"
  shopt -u nullglob
  [ "$removed" = "0" ] || changed=1

  if [ "$changed" = "1" ]; then
    update-desktop-database "$desktop_dir" >/dev/null 2>&1 || true
  fi
}

case "${1:-}" in
  --open-folder)
    mkdir -p "$apps_dir"
    exec xdg-open "$apps_dir"
    ;;
  --watch)
    sync_all
    # Wait for changes in the folder; events that arrive close together are
    # handled in one go (a download or copy produces several).
    inotifywait -m -q -e close_write -e moved_to -e moved_from -e delete "$apps_dir" |
      while read -r _; do
        while read -r -t 2 _; do :; done
        sync_all
      done
    ;;
  "" | --once)
    sync_all
    ;;
  *)
    echo "Usage: appimage-integrate [--once | --watch | --open-folder]" >&2
    exit 2
    ;;
esac
