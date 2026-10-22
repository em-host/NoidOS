desktop="$(find "@contents@" -maxdepth 1 -name '*.desktop' | sort | head -n 1)"

mkdir -p "$out/share/applications"
if [ -n "$desktop" ]; then
  # Point the menu entry at our wrapper command instead of AppRun.
  awk '
    /^Exec=/ { rest = $0; sub(/^Exec=[^ ]*/, "", rest); print "Exec=@name@" rest; next }
    /^(TryExec|X-AppImage-)/ { next }
    { print }
  ' "$desktop" > "$out/share/applications/@name@.desktop"
else
  printf '[Desktop Entry]\nType=Application\nName=@name@\nExec=@name@ %%U\nCategories=Utility;\n' \
    > "$out/share/applications/@name@.desktop"
fi

if [ -d "@contents@/usr/share/icons" ]; then
  mkdir -p "$out/share"
  cp -r --no-preserve=mode "@contents@/usr/share/icons" "$out/share/"
  find "$out/share/icons" -xtype l -delete # drop links that point outside the package
fi

icon_name="$(sed -n 's/^Icon=//p' "$out/share/applications/@name@.desktop" | head -n 1)"
if [ -n "$icon_name" ]; then
  if [ -f "@contents@/$icon_name.png" ]; then
    install -Dm444 "@contents@/$icon_name.png" "$out/share/icons/hicolor/256x256/apps/$icon_name.png"
  fi
  if [ -f "@contents@/$icon_name.svg" ]; then
    install -Dm444 "@contents@/$icon_name.svg" "$out/share/icons/hicolor/scalable/apps/$icon_name.svg"
  fi
fi
