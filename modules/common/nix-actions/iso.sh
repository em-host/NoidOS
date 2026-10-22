set -euo pipefail

flake_dir=@flakeDir@
nix=@nix@
python=@python@
shared=@shared@
xdg_open=@xdgOpen@
target="$HOME/Noid-OS ISO"

@common@

echo "Generating the install ISO"
echo "Config folder: $flake_dir"
echo

[ -d "$flake_dir/iso" ] || stop "There is no iso/ folder in $flake_dir, so there is no installer to build."
cd "$flake_dir"

# The ISO carries release.json: its channel is where installed computers look for updates, and
# its file fingerprints tell whether this folder has changes that were never published.
read -r release channel unpublished < <("$python" - "$shared" "$flake_dir" <<'EOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("shared", sys.argv[1])
shared = importlib.util.module_from_spec(spec)
spec.loader.exec_module(shared)
info = shared.read_release(sys.argv[2])
recorded = info.get("files")
changed = isinstance(recorded, dict) and recorded != shared.release_manifest(sys.argv[2])
print(shared.release_number(info), info.get("channel") or "-", "yes" if changed else "no")
EOF
)

if [ "$channel" = "-" ]; then
  echo "Nothing has been published yet, so computers installed from this ISO will not"
  echo "know where updates come from (they ask for the address the first time)."
  echo "Publish changes first to avoid that."
  echo
  read -r -p "Build it anyway? [y/N] " answer
  [[ $answer == [yY]* ]] || stop "Nothing was built."
elif [ "$unpublished" = yes ]; then
  echo "This folder has changes that are not published yet. The ISO would contain them"
  echo "but call itself release $release, so its computers would not see them as new."
  echo "Publish changes first to avoid that."
  echo
  read -r -p "Build it anyway? [y/N] " answer
  [[ $answer == [yY]* ]] || stop "Nothing was built."
fi

free_kb=$(df -Pk /nix/store | awk 'NR == 2 { print $4 }')
if [ "$free_kb" -lt $((15 * 1024 * 1024)) ]; then
  echo "Less than 15 GB is free on the drive that holds /nix/store; the build may run out of space."
  echo
fi

echo "Building (this takes a while; programs are downloaded and the image is packed here)..."
out=$("$nix" --extra-experimental-features "nix-command flakes" --option warn-dirty false \
  build ".#iso" --no-link --print-out-paths) || stop "The ISO could not be built (see above)."

iso=$(find "$out/iso" -maxdepth 1 -name '*.iso' | head -n 1)
[ -n "$iso" ] || stop "The build finished but produced no .iso file."

mkdir -p "$target"
name="noid-os-release-$release-$(date +%Y-%m-%d).iso"
echo
echo "Copying it to $target..."
cp --reflink=auto -- "$iso" "$target/$name.part"
chmod 644 "$target/$name.part"
mv -f -- "$target/$name.part" "$target/$name"

echo
echo "Done: $target/$name ($(du -h "$target/$name" | cut -f1))"
echo "Write it to a USB stick with a tool such as Impression or Fedora Media Writer."
"$xdg_open" "$target" >/dev/null 2>&1 &
pause
