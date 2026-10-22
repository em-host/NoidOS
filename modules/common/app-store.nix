{ mod, config, lib, pkgs, inputs, ... }:

# ---------------------------------------------------------------------------
# App store: one place for Flatpak apps and AppImage apps.
#
# FLATPAK
#   * Flathub is set up, and the desktop's own store (KDE Discover, GNOME
#     Software or COSMIC Store) is the place to search, install, update and
#     remove apps.
#   * Double-clicking a .flatpak, .flatpakref or .flatpakrepo file opens that
#     store, ready to install it.
#   * Apps listed in `module.app-store.flatpak.apps` are installed for you and
#     kept up to date. Apps installed by hand from the store are left alone.
#
# APPIMAGE
#   * Double-click an .AppImage and it asks: "Add to app menu" (moves it into
#     ~/Applications and opens it) or "Just run it". Added apps appear in the
#     app menu with their own name and icon; right-click one and choose
#     "Remove this app" to delete it. Dropping files into ~/Applications by
#     hand works too, and so does deleting them.
#   * AppImages can also be listed in `module.app-store.appimage.apps`, which
#     installs them for everybody and pins them by hash.
#
# All of it is on by default. Examples (hosts/users/user.nix):
#
#   module.app-store = {
#     flatpak.apps = [ "org.mozilla.firefox" "com.github.tchx84.Flatseal" ];
#     appimage.apps.my-app = {
#       url = "https://example.com/My-App-1.0-x86_64.AppImage";
#       hash = lib.fakeHash; # rebuild once, then paste the hash Nix reports
#     };
#   };
#
# Everything the module needs lives in ./app-store/.
# ---------------------------------------------------------------------------

let
  cfg = config.module.app-store;
  fp = cfg.flatpak;
  ai = cfg.appimage;

  assets = ./app-store;

  # ---- AppImage: the program that runs them ------------------------------
  appimageRun = pkgs.appimage-run.override {
    extraPkgs = _: ai.extraLibraries;
  };

  # ---- AppImage: apps installed declaratively ----------------------------
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

  # ---- AppImage: menu entries for AppImages dropped into ~/Applications ---
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
          binutils # readelf
          squashfs-tools # unsquashfs
          libarchive # bsdtar
          inotify-tools
          desktop-file-utils
          xdg-utils
        ]))
        (lib.escapeShellArg ai.folder)
      ]
      (builtins.readFile (assets + "/appimage-integrate.sh"))
  );

  # ---- AppImage: what runs when an AppImage is opened --------------------
  # Wraps appimage-run: a double-clicked AppImage gets the "Add to app menu?"
  # question first; everything else (terminal, scripts, menu entries) runs
  # straight away.
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

  # The store that opens Flatpak files, by file type. COSMIC Store only opens
  # .flatpakref files (the kind Flathub's "Install" button hands out).
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
  # nix-flatpak provides the declarative Flatpak options. Importing it here
  # keeps flake.nix free of module imports.
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

    # -----------------------------------------------------------------------
    # Flatpak
    # -----------------------------------------------------------------------
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

      # Flatpak needs the desktop portals. The desktop modules turn them on
      # already; this covers anything that doesn't.
      xdg.portal.enable = lib.mkDefault true;

      # Double-clicking a .flatpak / .flatpakref / .flatpakrepo file opens the store.
      xdg.mime.defaultApplications = flatpakFileHandlers;

      # The store itself comes with the desktop: KDE Discover (plus the
      # Flatpak permissions page in System Settings), GNOME Software and
      # COSMIC Store are installed automatically once Flatpak is on.
    })

    # -----------------------------------------------------------------------
    # AppImage
    # -----------------------------------------------------------------------
    (lib.mkIf ai.enable {
      # Run AppImages directly: double-click, or ./Some.AppImage in a terminal.
      programs.appimage = {
        enable = true;
        binfmt = true;
        # With the prompt on, the opener sits in front of appimage-run.
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
