{ mod, config, lib, pkgs, inputs, ... }:

let
  cfg = config.module.app-store;
  fp = cfg.flatpak;
  ai = cfg.appimage;

  assets = ./app-store;

  appimageRun = pkgs.appimage-run.override {
    extraPkgs = _: ai.extraLibraries;
  };

  mkAppImage = name: app:
    let
      src = pkgs.fetchurl {
        name = "${name}-${app.version}.AppImage";
        inherit (app) url hash;
      };
      contents = pkgs.appimageTools.extract {
        pname = name;
        inherit (app) version;
        inherit src;
      };
    in
    pkgs.appimageTools.wrapType2 {
      pname = name;
      inherit (app) version;
      inherit src;
      extraPkgs = _: ai.extraLibraries ++ app.extraLibraries;
      extraInstallCommands = builtins.replaceStrings
        [ "@name@" "@contents@" ]
        [ name (toString contents) ]
        (builtins.readFile (assets + "/install-appimage-extras.sh"));
    };

  appimageSubmodule = _: {
    options = {
      url = lib.mkOption {
        type = lib.types.str;
        description = "Direct download link of the .AppImage file.";
      };
      hash = lib.mkOption {
        type = lib.types.str;
        example = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
        description = ''
          Hash of the downloaded file. Use `lib.fakeHash` the first time: the
          rebuild stops and tells you the real hash to paste in here.
        '';
      };
      version = lib.mkOption {
        type = lib.types.str;
        default = "1";
        description = "Version label. Only used in the package name.";
      };
      extraLibraries = lib.mkOption {
        type = lib.types.listOf lib.types.package;
        default = [ ];
        example = lib.literalExpression "[ pkgs.ffmpeg ]";
        description = "Extra libraries or programs this one AppImage needs.";
      };
    };
  };

  integrate = pkgs.writeShellScriptBin "appimage-integrate" (
    builtins.replaceStrings
      [ "@path@" "@folder@" ]
      [
        (lib.makeBinPath (with pkgs; [
          coreutils
          findutils
          gawk
          gnugrep
          gnused
          binutils
          squashfs-tools
          libarchive
          inotify-tools
          desktop-file-utils
          xdg-utils
        ]))
        (lib.escapeShellArg ai.folder)
      ]
      (builtins.readFile (assets + "/appimage-integrate.sh"))
  );

  appimageOpen = pkgs.writeShellScriptBin "appimage-open" (
    builtins.replaceStrings
      [ "@path@" "@folder@" "@appimageRun@" "@integrate@" "@ask@" ]
      [
        (lib.makeBinPath (with pkgs; [ coreutils gnugrep zenity ]))
        (lib.escapeShellArg ai.folder)
        (lib.escapeShellArg "${appimageRun}/bin/appimage-run")
        (lib.escapeShellArg "${integrate}/bin/appimage-integrate")
        (if ai.promptOnOpen then "1" else "0")
      ]
      (builtins.readFile (assets + "/appimage-open.sh"))
  );

  appimageMimeTypes = [ "application/vnd.appimage" "application/x-iso9660-appimage" ];

  openHandler = pkgs.makeDesktopItem {
    name = "appimage-open";
    desktopName = "AppImage Opener";
    comment = "Run an AppImage, or add it to the app menu";
    exec = "${appimageOpen}/bin/appimage-open %f";
    noDisplay = true;
    mimeTypes = appimageMimeTypes;
    categories = [ "PackageManager" "Utility" ];
  };

  # COSMIC Store only handles .flatpakref.
  flatpakMimeTypes = [
    "application/vnd.flatpak"
    "application/vnd.flatpak.ref"
    "application/vnd.flatpak.repo"
  ];
  flatpakFileHandlers =
    if config.myOS.DE == "gnome" then lib.genAttrs flatpakMimeTypes (_: "org.gnome.Software.desktop")
    else if config.myOS.DE == "plasma" then lib.genAttrs flatpakMimeTypes (_: "org.kde.discover.desktop")
    else if config.myOS.DE == "cosmic" then { "application/vnd.flatpak.ref" = "com.system76.CosmicStore.desktop"; }
    else { };

  flatpak = "${config.services.flatpak.package or pkgs.flatpak}/bin/flatpak";

  linuxTypes = [ "ext4" "ext3" "ext2" "btrfs" "xfs" "f2fs" ];
  slug = text: lib.concatMapStrings (c: if builtins.match "[a-z0-9]" c != null then c else "-")
    (lib.stringToCharacters (lib.toLower (lib.removePrefix "/" text)));

  driveLocations = lib.mapAttrs'
    (folder: d: lib.nameValuePair (slug folder) {
      path = "${folder}/flatpak";
      name = if d.label != null then d.label else "Drive at ${folder}";
      mountPoint = folder;
    })
    (lib.filterAttrs (_: d: d.apps && lib.elem d.fsType linuxTypes) (config.myOS.drives or { }));

  locations = lib.optionalAttrs fp.driveLocations driveLocations
    // lib.mapAttrs (_: l: l // { mountPoint = null; }) fp.locations;

  folderLauncher = pkgs.makeDesktopItem {
    name = "appimage-folder";
    desktopName = "AppImages Folder";
    comment = "Drop .AppImage files in here to add them to the app menu";
    exec = "${integrate}/bin/appimage-integrate --open-folder";
    icon = "system-software-install";
    categories = [ "System" "Utility" ];
  };
in
{
  imports = [ inputs.nix-flatpak.nixosModules.nix-flatpak ];

  options.module.app-store = {
    enable = mod.enableByDefault "the app store (Flatpak and AppImage support)";

    flatpak = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Flatpak support, with Flathub and the desktop's app store.";
      };

      apps = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "org.mozilla.firefox" "com.github.tchx84.Flatseal" ];
        description = ''
          Flatpak apps to install from Flathub, by app ID (the "Application
          ID" on the app's Flathub page).
        '';
      };

      extraPackages = lib.mkOption {
        type = lib.types.listOf lib.types.raw;
        default = [ ];
        example = lib.literalExpression ''
          [
            { appId = "com.example.App"; bundle = "''${pkgs.fetchurl { ... }}"; sha256 = "..."; }
            { appId = "org.gimp.GIMP"; commit = "<commit hash>"; }
          ]
        '';
        description = ''
          Advanced entries passed straight to services.flatpak.packages:
          a different remote, a pinned commit, or a downloaded .flatpak bundle.
        '';
      };

      autoUpdate = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Keep Flatpak apps up to date in the background.";
      };

      updateSchedule = lib.mkOption {
        type = lib.types.str;
        default = "weekly";
        description = "How often to update (a systemd calendar expression, e.g. \"daily\").";
      };

      driveLocations = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Drives marked for apps (myOS.drives.<folder>.apps, asked by Nix Actions ->
          Drives) become places to install Flatpak apps: the store offers each as
          another source, and Nix Actions -> App install locations moves apps there.
        '';
      };

      locations = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule {
          options = {
            path = lib.mkOption {
              type = lib.types.strMatching "/[^[:space:]]+";
              description = "Folder the apps are installed into.";
            };
            name = lib.mkOption {
              type = lib.types.str;
              description = "Name shown in the store and in App install locations.";
            };
          };
        });
        default = { };
        example = { games = { path = "/data/flatpak"; name = "Games"; }; };
        description = "Further Flatpak install locations, by id.";
      };

      locationsManifest = lib.mkOption {
        type = lib.types.attrs;
        internal = true;
        readOnly = true;
        default = if cfg.enable && fp.enable then locations else { };
        description = "The install locations, for Nix Actions -> App install locations.";
      };

      removeUnlisted = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Uninstall any Flatpak app that is not listed here on the next
          rebuild. Off by default so apps installed from the store stay.
        '';
      };
    };

    appimage = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "AppImage support.";
      };

      integrate = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Watch the AppImages folder and add every AppImage in it to the app
          menu (and remove the entry again when the file is deleted).
        '';
      };

      promptOnOpen = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Double-clicking an AppImage asks whether to add it to the app menu
          or just run it. Turn off to always just run it.
        '';
      };

      folder = lib.mkOption {
        type = lib.types.str;
        default = "Applications";
        description = "Folder in the home directory to drop AppImages into.";
      };

      extraLibraries = lib.mkOption {
        type = lib.types.listOf lib.types.package;
        default = [ pkgs.icu pkgs.libxcrypt-legacy ];
        defaultText = lib.literalExpression "[ pkgs.icu pkgs.libxcrypt-legacy ]";
        description = "Libraries made available to every AppImage, for apps that expect them.";
      };

      apps = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule appimageSubmodule);
        default = { };
        description = ''
          AppImages to install for every user, by command name. Each gets a
          command and a menu entry, and is pinned by hash.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    (lib.mkIf fp.enable {
      services.flatpak = {
        enable = true;
        packages = fp.apps ++ fp.extraPackages;
        update.auto = {
          enable = fp.autoUpdate;
          onCalendar = fp.updateSchedule;
        };
        uninstallUnmanaged = fp.removeUnlisted;
      };

      xdg.portal.enable = lib.mkDefault true;

      xdg.mime.defaultApplications = flatpakFileHandlers;
    })

    (lib.mkIf (fp.enable && locations != { }) {
      environment.etc = lib.mapAttrs' (id: l: lib.nameValuePair "flatpak/installations.d/${id}.conf" {
        text = ''
          [Installation "${id}"]
          Path=${l.path}
          DisplayName=${l.name}
          StorageType=harddisk
        '';
      }) locations;

      # NixOS only adds the default installations' exports to XDG_DATA_DIRS.
      environment.profiles = lib.mkAfter (lib.mapAttrsToList (_: l: "${l.path}/exports") locations);

      systemd.services = lib.mapAttrs' (id: l: lib.nameValuePair "flatpak-location-${id}" {
        description = "Flatpak install location ${l.name}";
        wantedBy = [ "multi-user.target" ];
        wants = [ "network-online.target" ];
        after = [ "network-online.target" ];
        # Never create the folder on the main drive while the drive is missing.
        unitConfig = { RequiresMountsFor = [ l.path ]; }
          // lib.optionalAttrs (l.mountPoint != null) { ConditionPathIsMountPoint = l.mountPoint; };
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          Restart = "on-failure";
          RestartSec = 60;
        };
        script = ''
          install -d -m 755 ${lib.escapeShellArg l.path}
        '' + lib.concatMapStrings (r: ''
          ${flatpak} remote-add --installation=${id} --if-not-exists ${lib.optionalString (r.args or null != null) r.args} \
            ${lib.optionalString (r.gpg-import or null != null) "--gpg-import=${r.gpg-import}"} ${lib.escapeShellArg r.name} ${lib.escapeShellArg r.location}
        '') config.services.flatpak.remotes;
      }) locations
      // lib.optionalAttrs fp.autoUpdate {
        flatpak-locations-update = {
          description = "Update Flatpak apps on other drives";
          wants = [ "network-online.target" ];
          after = [ "network-online.target" ];
          serviceConfig.Type = "oneshot";
          script = lib.concatStrings (lib.mapAttrsToList (id: l: ''
            if [ -d ${lib.escapeShellArg "${l.path}/repo"} ]; then
              ${flatpak} update --installation=${id} --noninteractive -y || true
            fi
          '') locations);
        };
      };

      systemd.timers.flatpak-locations-update = lib.mkIf fp.autoUpdate {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = fp.updateSchedule;
          Persistent = true;
        };
      };
    })

    (lib.mkIf ai.enable {
      programs.appimage = {
        enable = true;
        binfmt = true;
        package = if ai.integrate then appimageOpen else appimageRun;
      };

      environment.systemPackages = [ appimageRun ] ++ lib.mapAttrsToList mkAppImage ai.apps;
    })

    (lib.mkIf (ai.enable && ai.integrate) {
      environment.systemPackages = [ integrate folderLauncher openHandler ];

      xdg.mime.defaultApplications = lib.genAttrs appimageMimeTypes (_: "appimage-open.desktop");

      systemd.user.services.appimage-integration = {
        description = "Add AppImages from the AppImages folder to the app menu";
        wantedBy = [ "default.target" ];
        serviceConfig = {
          ExecStart = "${integrate}/bin/appimage-integrate --watch";
          Restart = "on-failure";
          RestartSec = 10;
        };
      };
    })
  ]);
}
