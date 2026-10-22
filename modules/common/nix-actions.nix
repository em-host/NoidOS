{ mod, config, lib, pkgs, ... }:

let
  cfg = config.module.nix-actions;
  opts = config.myOS.nixActions;
  de = config.myOS.DE;
  isPlasma = de == "plasma";
  isGnome = de == "gnome";
  isCosmic = de == "cosmic";

  assets = ./nix-actions;

  terminal =
    if isPlasma then [ "${pkgs.kdePackages.konsole}/bin/konsole" "-e" ]
    else if isCosmic then [ "${pkgs.cosmic-term}/bin/cosmic-term" "-e" ]
    else [ "${pkgs.gnome-console}/bin/kgx" "-e" ];

  flakesTool = config.module.flakes.package or null;
  flakesCommand = lib.optionalString (flakesTool != null) "${flakesTool}/bin/nixos-flakes";

  nix = config.nix.package;
  q = lib.escapeShellArg;

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

  # One script per mode: a script that re-executes itself inside a terminal loses its arguments.
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

  syncOn = config.module.sync.enable;
  publisher = config.myOS.sync.publish;
  syncDir = assets + "/sync";

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

  isoOn = publisher && builtins.pathExists ../../iso;
  isoBuilder = terminalScript "nix-actions-iso" "iso.sh" {
    "@flakeDir@" = q config.myOS.flakeDir;
    "@nix@" = q "${nix}/bin/nix";
    "@python@" = q "${pkgs.python3}/bin/python3";
    "@shared@" = q "${syncDir + "/shared.py"}";
    "@xdgOpen@" = q "${pkgs.xdg-utils}/bin/xdg-open";
  };

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

  secretsManifest = if config.module.secrets.enable or false then config.module.secrets.manifest else { };
  passwordsOn = secretsManifest != { };

  # Runs as root through pkexec; writes stdin to one declared secret only.
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

  appStore = config.module.app-store.flatpak or { };
  appLocations = appStore.locationsManifest or { };
  appDrivesOn = appLocations != { };

  appDrivesScript = name: mover: pkgs.writeScript name (
    builtins.replaceStrings
      [ "#!/usr/bin/env python3" "@settings@" ]
      [
        "#!${pkgs.python3}/bin/python3"
        (builtins.toJSON {
          zenity = "${pkgs.zenity}/bin/zenity";
          flatpak = "${config.services.flatpak.package or pkgs.flatpak}/bin/flatpak";
          locations = appLocations;
          declared = map (a: if builtins.isString a then a else a.appId or "")
            ((appStore.apps or [ ]) ++ (appStore.extraPackages or [ ]));
          inherit mover;
        })
      ]
      (builtins.readFile (assets + "/app-drives.py"))
  );
  appDrivesTool = appDrivesScript "noid-app-drives" null;
  appMover = terminalScript "nix-actions-app-drives" "app-drives.sh" { "@tool@" = q "${appDrivesTool}"; };
  appDrives = appDrivesScript "nix-actions-app-drives-window" "${appMover}";

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

  windowScript = pkgs.writeScript "nix-actions-window" (
    builtins.replaceStrings
      [ "#!/usr/bin/env python3" "@settings@" ]
      [
        "#!${pkgs.python3.withPackages (ps: [ ps.pygobject3 ])}/bin/python3"
        (builtins.toJSON {
          flakeDir = config.myOS.flakeDir;
          icons = "${assets + "/icons"}";
          sync = if syncOn then "${syncTool}" else null;
          inherit publisher cleanupText;
          scripts = {
            rebuild = "${rebuild}";
            update = "${update}";
            cleanup = "${cleanup}";
            install = "${installRelease}";
            publish = if syncOn && publisher then "${publish}" else null;
            iso = if isoOn then "${isoBuilder}" else null;
          };
          flakes = flakesCommand;
          drives = lib.optionalString drivesOn "${drives}";
          appDrives = lib.optionalString appDrivesOn "${appDrives}";
          passwords = lib.optionalString passwordsOn "${passwords}";
          driveList = lib.mapAttrs (_: d: { inherit (d) label fsType apps; }) (config.myOS.drives or { });
          locations = lib.mapAttrsToList (_: l: l.name) appLocations;
        })
      ]
      (builtins.readFile (assets + "/window.py"))
  );

  window = pkgs.stdenvNoCC.mkDerivation {
    pname = "nix-actions-window";
    version = "1";
    dontUnpack = true;
    nativeBuildInputs = [ pkgs.wrapGAppsHook4 pkgs.gobject-introspection ];
    buildInputs = [ pkgs.gtk4 pkgs.libadwaita ];
    installPhase = ''
      install -Dm755 ${windowScript} $out/bin/nix-actions-window
    '';
  };

  menuCommand = lib.extendDerivation true
    { scripts = { inherit rebuild update cleanup drives passwords secretWriter installRelease syncTool releases publish appDrivesTool appMover appDrives window windowScript isoBuilder; }; }
    (pkgs.writeShellScriptBin "nix-actions" (fill
      {
        "@window@" = q "${window}/bin/nix-actions-window";
        "@rebuild@" = q "${rebuild}";
        "@update@" = q "${update}";
        "@cleanup@" = q "${cleanup}";
        "@drives@" = q (lib.optionalString drivesOn "${drives}");
        "@passwords@" = q (lib.optionalString passwordsOn "${passwords}");
        "@appDrives@" = q (lib.optionalString appDrivesOn "${appDrives}");
        "@releases@" = q (lib.optionalString (syncOn && !publisher) "${releases}");
        "@publish@" = q (lib.optionalString (syncOn && publisher) "${publish}");
        "@flakes@" = q flakesCommand;
      }
      (builtins.readFile (assets + "/menu.sh"))));

  # Named after the window's application id, so docks and task switchers match it to this entry.
  launcher = pkgs.makeDesktopItem {
    name = "org.noid.NixActions";
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

  placeWidget = pkgs.writeShellScript "place-nix-actions-widget" (
    builtins.replaceStrings
      [ "@busctl@" "@scriptFile@" ]
      [
        (q "${config.systemd.package}/bin/busctl")
        (q "${assets + "/place-widget.js"}")
      ]
      (builtins.readFile (assets + "/place-widget.sh"))
  );

  # cosmic-panel-button <id> shows the icon of desktop file <id> and runs it.
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
    icon = "nix-actions-symbolic";
    terminal = false;
    noDisplay = true;
  };

  # COSMIC's own default panel layout with the button inserted before the power applet,
  # copied at build time so it follows COSMIC updates. hiPrio: cosmic-panel ships the same file.
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
  # Old option names from when this was only the Rebuild button.
  imports = [
    (lib.mkAliasOptionModule [ "module" "rebuild-button" "enable" ] [ "module" "nix-actions" "enable" ])
    (lib.mkAliasOptionModule [ "myOS" "rebuildButton" "plasmaAutoPlace" ] [ "myOS" "nixActions" "plasmaAutoPlace" ])
  ];

  options.module.nix-actions.enable =
    mod.enableByDefault "the \"Nix Actions\" menu (rebuild, update, add a flake, clean up) and its panel button";

  options.module.sync.enable =
    mod.enableByDefault "releases in Nix Actions: Noid-OS Update (or Publish changes, see myOS.sync.publish)";

  options.myOS.sync.publish = lib.mkOption {
    type = lib.types.bool;
    default = false;
    example = true;
    description = ''
      This is the computer where the configuration is worked on: Nix Actions
      offers "Publish changes" (send flake.nix, flake.lock, lib/ and modules/ to
      the other computers as a new release) instead of "Noid-OS Update".
      Set it in hosts/users/user.nix of that one computer only.
    '';
  };

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
