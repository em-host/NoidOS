{ mod, config, lib, pkgs, ... }:

# ---------------------------------------------------------------------------
# Nix Actions: one menu for looking after the system. No terminal knowledge
# needed. It opens from
#
#   * the app menu ("Nix Actions"), on every desktop
#   * a panel button: in the system menu next to the power button on GNOME,
#     a widget in the panel on KDE Plasma, a button in the top panel next to
#     the power button on COSMIC
#   * a terminal:  nix-actions   (or  nix-actions rebuild | update | flake | cleanup)
#
# and offers
#
#   Rebuild            applies your configuration with the versions of
#                      everything that are already locked in flake.lock:
#                          sudo nixos-rebuild switch --flake .#<hostname>
#   Update & Rebuild   first fetches the newest versions of everything
#                      (nix flake update), then does the same. If the new
#                      versions do not build, the old ones are put back.
#   Get the latest release
#                      shows what is new in this system since this computer's
#                      release and installs it when its owner wants (the
#                      shared parts only: hosts/ stays as it is). If it does
#                      not build, everything is put back. Can go back one release.
#   Publish changes    only on the computer where the configuration is worked on
#                      (myOS.sync.publish = true): sends flake.nix, flake.lock,
#                      lib/ and modules/ to a public Git repository as the next
#                      release, after the privacy check. See ./nix-actions/sync/.
#   Add a Flake        adds programs or settings from a link (modules/flakes/).
#                      Only shown while that module is on.
#   Drives             opens another drive at a fixed folder on every start, or
#                      stops doing so (hosts/drives.nix, modules/common/drives.nix).
#   Passwords          types in the secrets the configuration needs (a network
#                      share's login...), see modules/common/secrets.nix. Only
#                      shown when there are any.
#   Clean up           frees disk space right now: removes old system versions
#                      and unused programs (as set in modules/common/garbage-clean.nix),
#                      updates the boot menu, and lets identical files share space.
#
# Rebuild, Update and Clean up open a terminal window that shows the progress
# and takes the password when sudo asks for it. Before a rebuild, flakes added
# with "Add a Flake" are made ready.
#
# Everything the actions need lives in ./nix-actions/:
#   menu.sh                        the menu and the nix-actions command
#   rebuild.sh, cleanup.sh         the actions that run in a terminal
#   sync/                          releases: sync.py (Get the latest release,
#                                  Publish changes), shared.py (what is shared),
#                                  privacy_check.py, publish.sh
#   drives.py                      Drives (windows only, no terminal)
#   passwords.py                   Passwords (windows only; a root helper writes the files)
#   common.sh                      the start they share (open a terminal, one at a time)
#   gnome/, plasma/, place-widget  the GNOME and Plasma panel buttons
#   cosmic/                        the icons of the COSMIC button
#
# (The panel buttons keep the names they had when they only did Rebuild, so the
# button that is already in a Plasma panel or GNOME menu keeps working.)
#
# COSMIC: the button is one of COSMIC's own "panel button" applets (the kind
# that opens an app when pressed), so no program has to be built for it. It is
# put into the top panel's default layout, just left of the power button. A
# panel that has been rearranged in COSMIC Settings keeps its own layout; there
# the button is added by hand: Settings -> Desktop -> Panel -> Configure panel
# applets -> "Nix Actions".
# ---------------------------------------------------------------------------

let
  cfg = config.module.nix-actions;
  opts = config.myOS.nixActions;
  de = config.myOS.DE;
  isPlasma = de == "plasma";
  isGnome = de == "gnome";
  isCosmic = de == "cosmic";

  assets = ./nix-actions;

  # The terminal the actions open. (KDE and COSMIC have their own; GNOME gets
  # GNOME Console, which works anywhere.)
  terminal =
    if isPlasma then [ "${pkgs.kdePackages.konsole}/bin/konsole" "-e" ]
    else if isCosmic then [ "${pkgs.cosmic-term}/bin/cosmic-term" "-e" ]
    else [ "${pkgs.gnome-console}/bin/kgx" "-e" ];

  # The "Add a Flake" command, or null when that module is switched off or not
  # there at all (then Update just runs plain `nix flake update`).
  flakesTool = config.module.flakes.package or null;
  flakesCommand = lib.optionalString (flakesTool != null) "${flakesTool}/bin/nixos-flakes";

  nix = config.nix.package;
  q = lib.escapeShellArg;

  # ---- the scripts -----------------------------------------------------------
  # Each script is a plain file in ./nix-actions with @...@ gaps that are filled
  # in here. The ones that run in a terminal start with common.sh (@common@).
  fill = values: text:
    builtins.replaceStrings (builtins.attrNames values) (builtins.attrValues values) text;

  common = builtins.readFile (assets + "/common.sh");

  terminalScript = name: file: values:
    pkgs.writeShellScript name (fill
      ({
        "@terminal@" = lib.escapeShellArgs terminal;
        "@flock@" = q "${pkgs.util-linux}/bin/flock";
      } // values)
      (builtins.replaceStrings [ "@common@" ] [ common ]
        (builtins.readFile (assets + "/${file}"))));

  # One copy per mode, because a script that starts itself again inside a
  # terminal cannot rely on being handed an argument.
  rebuildScript = mode: terminalScript "nix-actions-${mode}" "rebuild.sh" {
    "@mode@" = mode;
    "@flakeDir@" = q config.myOS.flakeDir;
    "@flakeHost@" = q config.networking.hostName;
    "@nix@" = q "${nix}/bin/nix";
    "@flakes@" = q flakesCommand;
    "@sync@" = q (lib.optionalString (mode == "sync") "${syncTool}");
  };
  rebuild = rebuildScript "rebuild";
  update = rebuildScript "update";
  installRelease = rebuildScript "sync";

  # ---- Releases: Get the latest release / Publish changes (./nix-actions/sync) ----
  syncOn = config.module.sync.enable;
  publisher = config.myOS.sync.publish;
  syncDir = assets + "/sync";

  # The same tool twice: as the rebuild above runs it (apply, restore, finish,
  # and publish), and as the menu runs it, which also needs to know that rebuild.
  syncScript = name: extra: pkgs.writeScript name (
    builtins.replaceStrings
      [ "#!/usr/bin/env python3" "@settings@" ]
      [
        "#!${pkgs.python3}/bin/python3"
        (builtins.toJSON ({
          lib = "${syncDir}";
          zenity = "${pkgs.zenity}/bin/zenity";
          nix = "${nix}/bin/nix";
          git = "${pkgs.git}/bin/git";
          gh = if publisher then "${pkgs.gh}/bin/gh" else null;
          flakeDir = config.myOS.flakeDir;
          flakeHost = config.networking.hostName;
          inherit publisher;
          install = null;
        } // extra))
      ]
      (builtins.readFile (syncDir + "/sync.py"))
  );
  syncTool = syncScript "noid-sync" { };
  releases = syncScript "nix-actions-releases" { install = "${installRelease}"; };
  publish = terminalScript "nix-actions-publish" "sync/publish.sh" { "@sync@" = q "${syncTool}"; };

  # ---- Clean up: what the automatic cleanup is set to, in words ---------------
  # (nix.gc.options is what garbage-clean.nix sets, e.g. "--delete-older-than 14d".)
  gcOptions = config.nix.gc.options;
  olderThan = builtins.match ".*--delete-older-than ([0-9]+)d.*" gcOptions;
  deleteAll = builtins.match "(.* )?(-d|--delete-old)( .*)?" gcOptions != null;

  policy =
    if olderThan != null then
      "System versions from the last ${builtins.head olderThan} days are kept, so you can still go back to them."
    else if deleteAll then
      "Old system versions are removed. Only the one you are running is kept."
    else
      "Old system versions are kept, so you can still go back to them.";

  cleanupText =
    "Free disk space: removes "
    + (
      if olderThan != null then "system versions older than ${builtins.head olderThan} days and programs nobody uses"
      else if deleteAll then "old system versions and programs nobody uses"
      else "programs nobody uses"
    )
    + ", then lets identical files share space. Can take a few minutes.";

  cleanup = terminalScript "nix-actions-cleanup" "cleanup.sh" {
    "@gcOptions@" = q gcOptions;
    "@policy@" = q policy;
    "@collectGarbage@" = q "${nix}/bin/nix-collect-garbage";
    "@nixStore@" = q "${nix}/bin/nix-store";
    "@df@" = q "${pkgs.coreutils}/bin/df";
    "@numfmt@" = q "${pkgs.coreutils}/bin/numfmt";
  };

  # ---- Drives: another disk at a fixed folder (modules/common/drives.nix) -----------
  drives = pkgs.writeScript "nix-actions-drives" (
    builtins.replaceStrings
      [ "#!/usr/bin/env python3" "@settings@" ]
      [
        "#!${pkgs.python3}/bin/python3"
        (builtins.toJSON {
          zenity = "${pkgs.zenity}/bin/zenity";
          lsblk = "${pkgs.util-linux}/bin/lsblk";
          nix = "${nix}/bin/nix";
          git = "${pkgs.git}/bin/git";
          flakeDir = config.myOS.flakeDir;
          rebuild = "${rebuild}";
          user = config.myOS.username;
        })
      ]
      (builtins.readFile (assets + "/drives.py"))
  );
  drivesOn = config.module.drives.enable or false;

  # ---- Passwords: type in the secrets of modules/common/secrets.nix ---------------
  secretsManifest = if config.module.secrets.enable or false then config.module.secrets.manifest else { };
  passwordsOn = secretsManifest != { };

  # Runs as root (through pkexec, which asks for the password): takes ONE secret's
  # value on its standard input and writes it to that secret's file, with that
  # secret's owner and permissions. Only names the configuration declares.
  secretWriter = pkgs.writeShellScript "noid-secret-write" ''
    set -euo pipefail
    export PATH=${lib.makeBinPath [ pkgs.coreutils ]}
    name="''${1:-}"
    case "$name" in
    ${lib.concatStrings (lib.mapAttrsToList (name: s: ''
      ${lib.escapeShellArg name}) owner=${lib.escapeShellArg s.owner}; group=${lib.escapeShellArg s.group}; mode=${lib.escapeShellArg s.mode}; target=${lib.escapeShellArg s.path} ;;
    '') secretsManifest)}
      *) echo "There is no secret called '$name' in the configuration." >&2; exit 2 ;;
    esac
    dir=$(dirname "$target")
    umask 077
    install -d -m 0711 -o root -g root "$dir"
    tmp=$(mktemp "$dir/.new.XXXXXX")
    trap 'rm -f "$tmp"' EXIT
    cat > "$tmp"
    [ -s "$tmp" ] || { echo "Nothing was typed in." >&2; exit 3; }
    chown "$owner:$group" "$tmp"
    chmod "$mode" "$tmp"
    mv -f "$tmp" "$target"
    trap - EXIT
  '';

  passwords = pkgs.writeScript "nix-actions-passwords" (
    builtins.replaceStrings
      [ "#!/usr/bin/env python3" "@settings@" ]
      [
        "#!${pkgs.python3}/bin/python3"
        (builtins.toJSON {
          zenity = "${pkgs.zenity}/bin/zenity";
          pkexec = "/run/wrappers/bin/pkexec";
          writer = "${secretWriter}";
          secrets = lib.mapAttrs (_: s: { inherit (s) description kind path; }) secretsManifest;
        })
      ]
      (builtins.readFile (assets + "/passwords.py"))
  );

  # ---- the menu ---------------------------------------------------------------
  menuCommand = lib.extendDerivation true
    # (the scripts are also reachable from here, for looking at what was generated)
    { scripts = { inherit rebuild update cleanup drives passwords secretWriter installRelease syncTool releases publish; }; }
    (pkgs.writeShellScriptBin "nix-actions" (fill
      {
        "@zenity@" = q "${pkgs.zenity}/bin/zenity";
        "@rebuild@" = q "${rebuild}";
        "@update@" = q "${update}";
        "@cleanup@" = q "${cleanup}";
        "@drives@" = q (lib.optionalString drivesOn "${drives}");
        "@passwords@" = q (lib.optionalString passwordsOn "${passwords}");
        "@releases@" = q (lib.optionalString (syncOn && !publisher) "${releases}");
        "@publish@" = q (lib.optionalString (syncOn && publisher) "${publish}");
        "@flakes@" = q flakesCommand;
        "@cleanupText@" = q cleanupText;
      }
      (builtins.readFile (assets + "/menu.sh"))));

  launcher = pkgs.makeDesktopItem {
    name = "nix-actions";
    desktopName = "Nix Actions";
    genericName = "Rebuild, update, add programs, clean up";
    comment = "Rebuild or update NixOS, get the latest release, add programs from a link, free up disk space";
    exec = "${menuCommand}/bin/nix-actions";
    # (COSMIC's icon themes have no "system-software-update"; see below.)
    icon = if isCosmic then "nix-actions" else "system-software-update";
    terminal = false;
    categories = [ "System" "Settings" "PackageManager" ];
    keywords = [ "nix" "nixos" "rebuild" "update" "upgrade" "release" "publish" "flake" "clean" "garbage" "disk space" ];
  };

  # ---- GNOME: shell extension ---------------------------------------------------
  gnomeExtensionUuid = "nixos-rebuild-button@nixos-config";

  gnomeExtension = pkgs.stdenvNoCC.mkDerivation {
    pname = "gnome-shell-extension-nixos-rebuild-button";
    version = "2";
    src = assets + "/gnome";
    dontConfigure = true;
    dontBuild = true;
    installPhase = ''
      runHook preInstall
      install -Dm444 metadata.json extension.js \
        -t "$out/share/gnome-shell/extensions/${gnomeExtensionUuid}"
      runHook postInstall
    '';
    passthru.extensionUuid = gnomeExtensionUuid;
  };

  # ---- Plasma: panel widget --------------------------------------------------
  plasmoidId = "org.nixos.rebuildbutton";

  plasmoid = pkgs.stdenvNoCC.mkDerivation {
    pname = "plasma-applet-nixos-rebuild-button";
    version = "2.0";
    src = assets + "/plasma";
    dontConfigure = true;
    dontBuild = true;
    installPhase = ''
      runHook preInstall
      mkdir -p "$out/share/plasma/plasmoids/${plasmoidId}"
      cp -r metadata.json contents "$out/share/plasma/plasmoids/${plasmoidId}/"
      runHook postInstall
    '';
  };

  # Adds the widget to the panel once Plasma has started (see place-widget.js).
  placeWidget = pkgs.writeShellScript "place-nix-actions-widget" (
    builtins.replaceStrings
      [ "@busctl@" "@scriptFile@" ]
      [
        (q "${config.systemd.package}/bin/busctl")
        (q "${assets + "/place-widget.js"}")
      ]
      (builtins.readFile (assets + "/place-widget.sh"))
  );

  # ---- COSMIC: panel button -----------------------------------------------------
  # cosmic-panel starts an "applet" for every id in its layout, from the desktop
  # file of that name, and COSMIC ships one applet that does nothing but show an
  # icon and open an app when pressed (cosmic-panel-button <desktop file id>).
  # Three small pieces make the button:
  #
  #   cosmicApplet   the applet entry the panel is told to show (X-CosmicApplet
  #                  also makes it appear in Settings -> Panel -> applets)
  #   cosmicTarget   what that applet looks like (the icon) and runs
  #   the icons      COSMIC's icon themes have no software-update icon
  cosmicApplet = "org.nixos.NixActionsButton";
  cosmicTarget = "org.nixos.NixActionsPanel";

  cosmicAppletItem = pkgs.makeDesktopItem {
    name = cosmicApplet;
    desktopName = "Nix Actions";
    comment = "Rebuild or update NixOS, add programs from a link, free up disk space";
    exec = "${pkgs.cosmic-applets}/bin/cosmic-panel-button ${cosmicTarget}";
    icon = "nix-actions";
    terminal = false;
    noDisplay = true;
    startupNotify = true;
    keywords = [ "COSMIC" "Applet" "Nix" "NixOS" "Rebuild" "Update" ];
    extraConfig = {
      "X-CosmicApplet" = "true";
      "X-OverflowPriority" = "10";
    };
  };

  cosmicTargetItem = pkgs.makeDesktopItem {
    name = cosmicTarget;
    desktopName = "Nix Actions";
    comment = "Open the Nix Actions menu";
    exec = "${menuCommand}/bin/nix-actions";
    icon = "nix-actions-symbolic"; # "-symbolic": the panel colours it like its other icons
    terminal = false;
    noDisplay = true;
  };

  # The icons, and the top panel's default layout with the button added just
  # left of the power button. The layout is the one COSMIC itself ships, copied
  # at build time with one id inserted, so it stays what COSMIC says it should
  # be after COSMIC updates. If that file is not as expected, the layout is
  # left alone and only the button is missing; nothing else is affected.
  # (hiPrio: the same file also comes from cosmic-panel, and this one wins.)
  cosmicDefaults = lib.hiPrio (pkgs.runCommand "nix-actions-cosmic-defaults" { } ''
    icons=$out/share/icons/hicolor/scalable/apps
    install -Dm444 ${assets + "/cosmic/nix-actions.svg"} $icons/nix-actions.svg
    install -Dm444 ${assets + "/cosmic/nix-actions-symbolic.svg"} $icons/nix-actions-symbolic.svg
    ${lib.optionalString opts.cosmicAutoPlace ''
      key=com.system76.CosmicPanel.Panel/v1/plugins_wings
      stock=${pkgs.cosmic-panel}/share/cosmic/$key
      if [ -f "$stock" ] && grep -q '"com.system76.CosmicAppletPower"' "$stock"; then
        install -dm755 "$out/share/cosmic/$(dirname "$key")"
        sed 's/"com.system76.CosmicAppletPower"/"${cosmicApplet}", "com.system76.CosmicAppletPower"/' \
          "$stock" > "$out/share/cosmic/$key"
        grep -q '"${cosmicApplet}"' "$out/share/cosmic/$key"
      else
        echo "nix-actions: COSMIC's panel layout is not what was expected, so the button is not added to it. Add it in Settings -> Desktop -> Panel." >&2
      fi
    ''}
  '');
in
{
  # The names this had when it was only the Rebuild button. Still work.
  imports = [
    (lib.mkAliasOptionModule [ "module" "rebuild-button" "enable" ] [ "module" "nix-actions" "enable" ])
    (lib.mkAliasOptionModule [ "myOS" "rebuildButton" "plasmaAutoPlace" ] [ "myOS" "nixActions" "plasmaAutoPlace" ])
  ];

  options.module.nix-actions.enable =
    mod.enableByDefault "the \"Nix Actions\" menu (rebuild, update, add a flake, clean up) and its panel button";

  options.module.sync.enable =
    mod.enableByDefault "releases in Nix Actions: Get the latest release (or Publish changes, see myOS.sync.publish)";

  options.myOS.sync.publish = lib.mkOption {
    type = lib.types.bool;
    default = false;
    example = true;
    description = ''
      This is the computer where the configuration is worked on: Nix Actions
      offers "Publish changes" (send flake.nix, flake.lock, lib/ and modules/ to
      the other computers as a new release) instead of "Get the latest release".
      Set it in hosts/users/user.nix of that one computer only.
    '';
  };

  # (The folder it works in is myOS.flakeDir, see lib/options.nix.)
  options.myOS.nixActions.plasmaAutoPlace = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = ''
      Plasma only: add the Nix Actions widget to the panel automatically at
      login. With this off, the widget is still installed and can be added by
      hand from "Add Widgets...".
    '';
  };

  options.myOS.nixActions.cosmicAutoPlace = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = ''
      COSMIC only: put the Nix Actions button into the top panel's default
      layout. With this off, the button is still installed and can be added by
      hand in Settings -> Desktop -> Panel -> Configure panel applets. (A panel
      that was already rearranged in COSMIC Settings keeps its own layout
      either way.)
    '';
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      environment.systemPackages = [ menuCommand launcher ];
    }

    (lib.mkIf isCosmic {
      environment.systemPackages = [ cosmicAppletItem cosmicTargetItem cosmicDefaults ];
    })

    (lib.mkIf isGnome {
      # de-switch.nix installs this and switches it on for every user.
      myOS.gnomeExtensions = [ gnomeExtension ];
    })

    (lib.mkIf isPlasma {
      environment.systemPackages = [ plasmoid ];

      environment.etc."xdg/autostart/nix-actions-button-placer.desktop" =
        lib.mkIf opts.plasmaAutoPlace {
          text = ''
            [Desktop Entry]
            Type=Application
            Name=Place the Nix Actions button
            Exec=${placeWidget}
            OnlyShowIn=KDE;
            NoDisplay=true
          '';
        };
    })
  ]);
}
