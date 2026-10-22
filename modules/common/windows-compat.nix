{ config, lib, pkgs, ... }:

let
  inherit (lib) mkOption mkIf mkDefault types;
  cfg = config.programs.universal-wine;

  # Bump this when the prefix layout / bootstrap logic below changes in a way
  # that requires existing prefixes to be rebuilt.
  prefixSchema = 2;

  # Changing the verb list (or the schema) changes this hash, which makes the
  # launcher rebuild the prefix on next use. Proton/nixpkgs upgrades do NOT:
  # Proton upgrades prefixes in place.
  configHash = builtins.hashString "sha256" (builtins.toJSON {
    schema = prefixSchema;
    verbs = cfg.winetricks;
  });

  windowsMimeTypes = [
    "application/x-ms-dos-executable"              # older shared-mime-info
    "application/vnd.microsoft.portable-executable" # newer shared-mime-info
    "application/x-msdownload"
    "application/x-dosexec"
    "application/x-msi"
  ];

  uniwine = pkgs.writeShellScriptBin "uniwine" ''
    set -euo pipefail
    export PATH=${lib.makeBinPath (with pkgs; [
      umu-launcher winetricks gamescope zenity libnotify
      coreutils findutils gawk util-linux xdg-utils
    ])}:$PATH

    CONFIG_HASH=${lib.escapeShellArg configHash}
    VERBS=(${lib.escapeShellArgs cfg.winetricks})
    GAMESCOPE_ENABLED=${if cfg.gamescope.enable then "1" else "0"}
    GAMESCOPE_ARGS=(${lib.escapeShellArgs cfg.gamescope.extraArgs})
    RESOLUTION=${lib.escapeShellArg (toString cfg.gamescope.resolution)}
    SAVES_NAME=${lib.escapeShellArg cfg.savesFolder}
    PROTON_PATH=${lib.escapeShellArg (toString cfg.protonPath)}
    ${lib.concatStringsSep "\n    " (lib.mapAttrsToList
      (name: value: "export ${name}=${lib.escapeShellArg value}") cfg.extraEnv)}

    # ---------------------------------------------------------------------------
    # Expected from the Nix-generated preamble:
    #   CONFIG_HASH  VERBS(array)  GAMESCOPE_ENABLED(0/1)  GAMESCOPE_ARGS(array)
    #   RESOLUTION   SAVES_NAME    PROTON_PATH
    # ---------------------------------------------------------------------------
    APP="Universal Wine"
    DATA_HOME="''${XDG_DATA_HOME:-$HOME/.local/share}"
    STATE_HOME="''${XDG_STATE_HOME:-$HOME/.local/state}"

    PREFIX="$DATA_HOME/universal-wine-prefix"
    PREVIOUS="$PREFIX.previous"
    HASH_FILE="$PREFIX/.nix_config_hash"
    SAVES_DIR="$HOME/$SAVES_NAME"
    REG_DIR="$SAVES_DIR/Registry"
    STATE_DIR="$STATE_HOME/uniwine"
    LOG_FILE="$STATE_DIR/uniwine.log"
    LOCK_FILE="$STATE_DIR/setup.lock"

    USE_GAMESCOPE="$GAMESCOPE_ENABLED"
    [ -z "''${UNIWINE_NO_GAMESCOPE:-}" ] || USE_GAMESCOPE=0

    usage() {
      cat <<USAGE
    Usage: uniwine [--no-gamescope] [--] PROGRAM.exe [ARGS...]
           uniwine --winecfg | --winetricks [VERB...] | --saves | --drive-c
           uniwine --reset | --log

    With no arguments a small menu is shown.
    USAGE
    }

    case "''${1:-}" in
      -h|--help) usage; exit 0 ;;
    esac

    mkdir -p "$STATE_DIR"
    if [ -f "$LOG_FILE" ] && [ "$(stat -c %s "$LOG_FILE")" -gt 5242880 ]; then
      mv -f "$LOG_FILE" "$LOG_FILE.old"
    fi
    exec > >(tee -a "$LOG_FILE") 2>&1

    log()    { printf '[uniwine %s] %s\n' "$(date +%T)" "$*"; }
    have()   { command -v "$1" >/dev/null 2>&1; }
    notify() { notify-send --app-name="$APP" --icon=applications-games "$1" "''${2:-}" >/dev/null 2>&1 || true; }

    # Progress window (zenity) driven through a coprocess so the text can be updated.
    ZEN_PID=""
    progress_start() {
      have zenity || return 0
      trap "" PIPE   # writing to a window the user closed must not kill us
      coproc ZEN { exec zenity --progress --pulsate --no-cancel --width=460 \
                     --title="$APP" --text="$1" >/dev/null 2>&1; }
    }
    progress_text() {
      [ -n "''${ZEN_PID:-}" ] || return 0
      printf '# %s\n' "$1" >&"''${ZEN[1]}" 2>/dev/null || true
    }
    progress_stop() {
      if [ -n "''${ZEN_PID:-}" ]; then
        kill "$ZEN_PID" 2>/dev/null || true
        wait "$ZEN_PID" 2>/dev/null || true
      fi
      ZEN_PID=""
      trap - PIPE
    }
    trap progress_stop EXIT

    fail() {
      log "ERROR: $*"
      progress_stop
      notify "$APP: something went wrong" "$*"
      if have zenity; then
        zenity --error --no-markup --width=460 --title="$APP" \
          --text="$*"$'\n\n'"Details: $LOG_FILE" >/dev/null 2>&1 || true
      fi
      exit 1
    }

    export WINEPREFIX="$PREFIX"
    export GAMEID="''${GAMEID:-umu-default}"
    [ -z "$PROTON_PATH" ] || export PROTONPATH="$PROTON_PATH"

    # Keep logging quiet: less IO, and DXVK won't drop .log files next to game exes.
    export WINEDEBUG="''${WINEDEBUG:--all}"
    export DXVK_LOG_LEVEL=none
    export DXVK_LOG_PATH=none
    export VKD3D_DEBUG=none
    export VKD3D_SHADER_DEBUG=none
    export VKD3D_DISABLE_EXTENSIONS=VK_EXT_debug_utils

    # Saves in HKCU\Software are kept as a plain copy of the prefix's user.reg and
    # re-imported into a freshly built prefix. Wine's own keys (Software\Wine,
    # Software\Valve) are deliberately NOT restored, so stale DLL overrides or
    # driver settings can't leak from an old prefix into a new one.
    backup_registry() {
      local src="$PREFIX/user.reg" latest="$REG_DIR/user.reg"
      [ -s "$src" ] || return 0
      mkdir -p "$REG_DIR"
      if [ -f "$latest" ] && ! cmp -s "$src" "$latest"; then
        cp -f "$latest" "$REG_DIR/user.reg.$(date +%Y%m%d-%H%M%S)"
      fi
      cp -f "$src" "$latest"
      # keep the 5 newest snapshots
      find "$REG_DIR" -maxdepth 1 -name 'user.reg.*' -printf '%T@ %p\n' \
        | sort -rn | tail -n +6 | cut -d' ' -f2- \
        | xargs -r -d '\n' rm -f --
    }

    restore_registry() {
      local src="$REG_DIR/user.reg" out="$PREFIX/drive_c/uniwine-restore.reg"
      [ -s "$src" ] || return 0
      awk '
        BEGIN { print "Windows Registry Editor Version 5.00"; keep = 0 }
        /^\[/ {
          key = $0
          sub(/\] [0-9 ]+$/, "", key)
          sub(/\]$/, "", key)
          sub(/^\[/, "", key)
          n = split(key, parts, "\\\\")          # Wine doubles every backslash
          key = ""
          for (i = 1; i <= n; i++) if (parts[i] != "") key = key (key == "" ? "" : "\\") parts[i]
          keep = (key ~ /^Software(\\|$)/) && (key !~ /^Software\\(Wine|Valve)(\\|$)/)
          if (keep) { print ""; print "[HKEY_CURRENT_USER\\" key "]" }
          next
        }
        /^(#|;)/ { next }
        keep { print }
      ' "$src" > "$out" || return 1
      # The file lives on C: because /tmp is private inside the Proton container.
      umu-run reg import 'C:\uniwine-restore.reg' || { rm -f "$out"; return 1; }
      rm -f "$out"
    }

    prefix_current() {
      [ -f "$HASH_FILE" ] && [ "$(cat "$HASH_FILE")" = "$CONFIG_HASH" ]
    }

    # Replace a folder inside the prefix with a link to a folder that survives
    # prefix rebuilds.
    link_persistent() {
      mkdir -p "$2"
      rm -rf "$1"
      ln -s "$2" "$1"
    }

    create_prefix() {
      local verb user_dir failed=()
      mkdir -p "$PREFIX" "$SAVES_DIR" || return 1

      progress_text "Downloading the Windows runtime and creating the prefix…"
      umu-run wineboot -u || return 1

      # One verb at a time: a single flaky redistributable must not sink the rest.
      for verb in "''${VERBS[@]}"; do
        progress_text "Installing $verb…"
        umu-run winetricks -q "$verb" || { log "winetricks verb failed: $verb"; failed+=("$verb"); }
      done

      user_dir="$PREFIX/drive_c/users/steamuser"
      [ -d "$user_dir" ] || { log "expected $user_dir to exist"; return 1; }

      progress_text "Linking your save folders…"
      link_persistent "$user_dir/AppData"     "$SAVES_DIR/AppData"
      link_persistent "$user_dir/Documents"   "$SAVES_DIR/Documents"
      link_persistent "$user_dir/Saved Games" "$SAVES_DIR/SavedGames"
      mkdir -p "$SAVES_DIR/AppData/Local" "$SAVES_DIR/AppData/LocalLow" "$SAVES_DIR/AppData/Roaming"

      progress_text "Restoring saved settings…"
      restore_registry || log "registry restore failed (non-fatal)"

      printf '%s\n' "$CONFIG_HASH" > "$HASH_FILE"
      if [ "''${#failed[@]}" -gt 0 ]; then
        notify "$APP" "Some components could not be installed: ''${failed[*]}. Programs may still work. See $LOG_FILE"
      fi
    }

    rebuild_prefix() {
      local replaced=0 text="Setting up Windows compatibility (first run only).
    This can take 10-20 minutes - please leave this window open."

      if [ -e "$PREFIX" ]; then
        log "Windows environment is out of date, rebuilding. Old copy kept at $PREVIOUS"
        backup_registry
        rm -rf "$PREVIOUS"
        mv "$PREFIX" "$PREVIOUS"
        replaced=1
        text="Updating the Windows environment.
    Your saves are kept. This can take 10-20 minutes."
      fi

      progress_start "$text"
      if create_prefix; then
        progress_stop
        notify "$APP is ready" "Windows programs will now open when you double-click them."
        return 0
      fi

      rm -rf "$PREFIX"
      progress_stop
      if [ "$replaced" = 1 ]; then
        mv "$PREVIOUS" "$PREFIX"
        notify "$APP" "Couldn't update the Windows environment (see $LOG_FILE). Using the previous one for now."
        return 0
      fi
      fail "Setting up the Windows environment failed. It needs an internet connection the first time - check it and try again."
    }

    ensure_prefix() {
      prefix_current && return 0
      exec 9>"$LOCK_FILE"
      if ! flock -n 9; then
        notify "$APP" "Setup is already running - waiting for it to finish."
        flock 9
      fi
      prefix_current || rebuild_prefix
      exec 9>&-   # never hand the lock to the game
    }

    detect_resolution() {
      local d res
      for d in /sys/class/drm/card*-*; do
        [ "$(cat "$d/status" 2>/dev/null)" = connected ] || continue
        [ "$(cat "$d/enabled" 2>/dev/null)" = enabled ] || continue
        res=$(head -n 1 "$d/modes" 2>/dev/null || true)
        if [[ $res =~ ^[0-9]+x[0-9]+$ ]]; then printf '%s' "$res"; return 0; fi
      done
      printf '1920x1080'
    }

    # Installers and helper tools look wrong inside a fullscreen gamescope.
    wants_gamescope() {
      local n
      [ "$USE_GAMESCOPE" = 1 ] || return 1
      n=$(basename -- "$1"); n="''${n,,}"
      case "$n" in *.msi|*.bat|*.cmd) return 1 ;; esac
      [[ $n =~ (^|[^a-z])(setup|install|installer|unins[0-9]*|uninstall|vc_?redist|dxsetup)([^a-z]|$) ]] && return 1
      return 0
    }

    run_program() {
      local exe dir share res w h status=0 started
      local -a cmd

      [ -n "''${1:-}" ] || fail "No program was given."
      exe=$(realpath -- "$1") || fail "Can't find: $1"
      shift
      [ -f "$exe" ] || fail "Not a file: $exe"
      dir=$(dirname -- "$exe")

      case "''${exe,,}" in
        *.msi|*.bat|*.cmd) cmd=(umu-run start /unix "$exe" "$@") ;;
        *)                 cmd=(umu-run "$exe" "$@") ;;
      esac

      if wants_gamescope "$exe"; then
        res="''${RESOLUTION:-$(detect_resolution)}"
        [[ $res =~ ^[0-9]+x[0-9]+$ ]] || res=1920x1080
        w="''${res%x*}"; h="''${res#*x}"
        cmd=(gamescope -W "$w" -H "$h" -f "''${GAMESCOPE_ARGS[@]}" -- "''${cmd[@]}")
      fi

      # Make sure the container can see the whole game (other drives) and saves.
      # Unreal games start in <Game>/Binaries/Win64 and read ../../../<Game>/<Game>.uproject,
      # so the folder ABOVE the game folder has to be visible, not just the exe's folder.
      share="$dir"
      case "$dir" in
        */[Bb]inaries/*) share=$(dirname -- "''${dir%%/[Bb]inaries/*}") ;;
      esac
      case "$share" in ""|/|"$HOME") share="$dir" ;; esac
      export PRESSURE_VESSEL_FILESYSTEMS_RW="''${PRESSURE_VESSEL_FILESYSTEMS_RW:+$PRESSURE_VESSEL_FILESYSTEMS_RW:}$SAVES_DIR:$share"

      cd "$dir" || fail "Can't open folder: $dir"   # many games load assets relative to cwd
      log "Launching: ''${cmd[*]}"
      started=$SECONDS
      "''${cmd[@]}" || status=$?
      backup_registry

      if [ "$status" -ne 0 ] && [ $((SECONDS - started)) -lt 10 ]; then
        notify "$APP" "$(basename -- "$exe") closed right away (exit code $status). Log: $LOG_FILE"
      fi
      return "$status"
    }

    pick_program() {
      have zenity || fail "No program given. Usage: uniwine program.exe"
      zenity --file-selection --title="Choose a Windows program" \
        --file-filter="Windows programs | *.[eE][xX][eE] *.[mM][sS][iI] *.[bB][aA][tT]" \
        --file-filter="All files | *" 2>/dev/null || exit 0
    }

    menu() {
      local choice
      have zenity || { usage; exit 1; }
      choice=$(zenity --list --title="$APP" --width=420 --height=360 \
        --text="What would you like to do?" --hide-header \
        --column=id --column=Action --hide-column=1 --print-column=1 \
        run     "Run a Windows program..." \
        saves   "Open my saves folder" \
        drive   "Open the Windows C: drive" \
        cfg     "Wine settings (winecfg)" \
        reset   "Rebuild the Windows environment" \
        log     "Show the log" 2>/dev/null) || exit 0
      case "$choice" in
        run)   ensure_prefix; run_program "$(pick_program)" ;;
        saves) mkdir -p "$SAVES_DIR"; xdg-open "$SAVES_DIR" ;;
        drive) ensure_prefix; xdg-open "$PREFIX/drive_c" ;;
        cfg)   ensure_prefix; umu-run winecfg ;;
        reset) do_reset ;;
        log)   xdg-open "$LOG_FILE" ;;
      esac
    }

    do_reset() {
      if have zenity; then
        zenity --question --width=460 --title="$APP" --no-markup \
          --text="Rebuild the Windows environment?

    Your saves in $SAVES_DIR are kept. Programs installed INSIDE the old environment are kept in a backup folder next to it (only the most recent backup is kept)." \
          || exit 0
      fi
      rm -f "$HASH_FILE"
      ensure_prefix
    }

    case "''${1:-}" in
      --no-gamescope) USE_GAMESCOPE=0; shift ;;
    esac

    case "''${1:-}" in
      "")          menu ;;
      --winecfg)   ensure_prefix; exec umu-run winecfg ;;
      --winetricks) shift; ensure_prefix; exec umu-run winetricks "$@" ;;
      --saves)     mkdir -p "$SAVES_DIR"; exec xdg-open "$SAVES_DIR" ;;
      --drive-c)   ensure_prefix; exec xdg-open "$PREFIX/drive_c" ;;
      --reset)     do_reset ;;
      --log)       exec xdg-open "$LOG_FILE" ;;
      --)          shift; ensure_prefix; run_program "$@" ;;
      *)           ensure_prefix; run_program "$@" ;;
    esac
  '';

  mkItem = { name, desktopName, args ? "", noDisplay ? false, withActions ? false }:
    pkgs.makeDesktopItem ({
      inherit name desktopName noDisplay;
      comment = "Run Windows programs and games in a shared Wine prefix";
      exec = "${uniwine}/bin/uniwine ${args}%f";
      icon = "applications-games";
      terminal = false;
      categories = [ "Game" ];
      mimeTypes = windowsMimeTypes;
    } // lib.optionalAttrs withActions {
      actions = {
        winecfg = { name = "Wine settings"; exec = "${uniwine}/bin/uniwine --winecfg"; };
        saves   = { name = "Open saves folder"; exec = "${uniwine}/bin/uniwine --saves"; };
        reset   = { name = "Rebuild Windows environment"; exec = "${uniwine}/bin/uniwine --reset"; };
      };
    });
in
{
  imports = [
    (lib.mkAliasOptionModule [ "module" "windows-compat" "enable" ] [ "programs" "universal-wine" "enable" ])
  ];

  options.programs.universal-wine = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = "Enable the universal Wine prefix and make it the default opener for Windows executables.";
    };

    winetricks = mkOption {
      type = types.listOf types.str;
      default = [ "corefonts" "vcrun2022" "d3dx9" "d3dcompiler_43" ];
      example = [ "corefonts" "vcrun2022" "dotnet48" ];
      description = ''
        Winetricks verbs installed (in order) when the prefix is built.
        Changing this list rebuilds the prefix on next launch; saves are kept.

        dotnet48 is left out by default: Proton ships wine-mono, which covers
        most .NET games, and installing real .NET 4.8 into a Proton prefix is
        slow and the most common cause of failed first-time setups.
      '';
    };

    protonPath = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "GE-Proton";
      description = ''
        Value for umu's PROTONPATH. null uses umu's default (latest UMU-Proton,
        downloaded on first run). Use "GE-Proton" for the latest GE-Proton, or
        a store path such as "''${pkgs.proton-ge-bin.steamcompattool}" to pin one.
      '';
    };

    savesFolder = mkOption {
      type = types.str;
      default = "Universal Wine Saves";
      description = "Folder name in $HOME that holds AppData, Documents, Saved Games and registry backups.";
    };

    gamescope = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Run games inside a fullscreen gamescope session. Installers (setup,
          install, .msi, ...) automatically skip it, and a second
          "no Gamescope" entry appears in the Open With menu.
        '';
      };
      resolution = mkOption {
        type = types.nullOr (types.strMatching "[0-9]+x[0-9]+");
        default = null;
        example = "2560x1440";
        description = "Output resolution for gamescope. null auto-detects the first active display.";
      };
      extraArgs = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [ "--force-grab-cursor" "-r" "144" ];
        description = "Extra arguments passed to gamescope.";
      };
    };

    extraEnv = mkOption {
      type = types.attrsOf types.str;
      default = { };
      example = { PROTON_ENABLE_WAYLAND = "1"; MANGOHUD = "1"; };
      description = "Extra environment variables exported before launching.";
    };
  };

  config = mkIf cfg.enable {
    hardware.graphics = {
      enable = mkDefault true;
      enable32Bit = mkDefault true;
    };

    # Several games crash with the kernel default of 65530 memory maps. The
    # weak priority lets nixpkgs or the user set their own value without a clash.
    boot.kernel.sysctl."vm.max_map_count" = lib.mkOverride 1010 2147483642;

    environment.systemPackages = [
      uniwine
      pkgs.umu-launcher
      pkgs.winetricks
      (mkItem { name = "uniwine"; desktopName = "Universal Wine (Windows programs)"; withActions = true; })
    ] ++ lib.optional cfg.gamescope.enable
      (mkItem { name = "uniwine-windowed"; desktopName = "Universal Wine (no Gamescope)"; args = "--no-gamescope "; });

    xdg.mime.defaultApplications = lib.genAttrs windowsMimeTypes (_: mkDefault "uniwine.desktop");
  };
}
