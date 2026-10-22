{ mod, config, lib, pkgs, ... }:

# ---------------------------------------------------------------------------
# Default apps: what opens when you double-click a file.
#
# Rules for the picks, so that they look and behave the same on every desktop
# (Plasma, GNOME, COSMIC):
#   1. GTK4 / libadwaita apps first. They draw their own modern window and follow
#      the system light/dark setting through the desktop portal on every desktop.
#      Qt apps look out of place on GNOME and the reverse, so they are only used
#      where nothing better exists (LibreOffice, qBittorrent).
#   2. Plays or opens everything. A default that fails on a file is worse than
#      an old-looking one.
#   3. Simple. These are for people who just want to open the thing.
#
# Two deliberate exceptions to rule 1, both from KDE: Kate (text files) and Ark
# (archives). The GTK alternatives were less useful: GNOME Text Editor has no
# line numbers by default and little else for finding what is wrong in a file, and
# File Roller cannot match Ark's drag and drop and its way of showing what is
# inside an archive. On GNOME and COSMIC they keep their own look (and their own
# light/dark setting, in Settings -> Appearance inside the app).
#
# Change or remove any of them from hosts/users/user.nix, for example:
#
#   module.default-apps.apps.video = { package = pkgs.celluloid;
#                                       desktopFile = "io.github.celluloid_player.Celluloid.desktop"; };
#   module.default-apps.apps.torrent.package = null;     # no torrent app at all
#
# (The desktop file name is the one in <package>/share/applications.)
# A person's own choice in "Open With -> Always" is stored in their home folder
# and always wins over what is set here.
# ---------------------------------------------------------------------------

let
  cfg = config.module.default-apps;

  categories = {
    image = {
      description = "Pictures";
      package = pkgs.loupe;
      desktopFile = "org.gnome.Loupe.desktop";
      mimeTypes = [
        "image/jpeg" "image/png" "image/gif" "image/webp" "image/avif" "image/bmp"
        "image/svg+xml" "image/tiff" "image/heif" "image/heic" "image/jxl"
        "image/vnd.microsoft.icon" "image/x-icon" "image/x-tga" "image/qoi"
      ];
    };

    # Showtime is GNOME's video player. One settings button holds Repeat,
    # playback speed (0.5x to 2x), audio language and subtitles, so nothing is
    # hidden behind keyboard shortcuts. (Celluloid, the mpv front end, plays odder
    # files but has no speed or repeat buttons; swap it in below if you need it.)
    video = {
      description = "Video";
      package = pkgs.showtime;
      desktopFile = "org.gnome.Showtime.desktop";
      mimeTypes = [
        "video/mp4" "video/x-matroska" "video/webm" "video/x-flv" "video/quicktime"
        "video/x-msvideo" "video/vnd.avi" "video/mpeg" "video/ogg" "video/x-ms-wmv"
        "video/x-ms-asf" "video/3gpp" "video/3gpp2" "video/mp2t" "video/x-m4v"
        "video/x-ogm+ogg"
      ];
    };

    # Decibels is GNOME's own "open this one audio file" player: no library to set up.
    audio = {
      description = "Music and other audio";
      package = pkgs.decibels;
      desktopFile = "org.gnome.Decibels.desktop";
      mimeTypes = [
        "audio/mpeg" "audio/mp3" "audio/x-mp3" "audio/wav" "audio/x-wav" "audio/vnd.wave"
        "audio/flac" "audio/x-flac" "audio/ogg" "audio/x-vorbis+ogg" "audio/x-opus+ogg"
        "audio/opus" "audio/aac" "audio/x-aac" "audio/mp4" "audio/x-m4a" "audio/m4a"
        "audio/x-m4b" "audio/x-aiff" "audio/aiff" "audio/x-ape" "audio/x-wavpack"
        "audio/x-speex"
      ];
    };

    # Papers replaced Evince as GNOME's document viewer. Also opens comic books.
    pdf = {
      description = "PDF files and comic books";
      package = pkgs.papers;
      desktopFile = "org.gnome.Papers.desktop";
      mimeTypes = [
        "application/pdf" "application/x-pdf" "application/postscript"
        "image/vnd.djvu" "image/vnd.djvu+multipage"
        "application/vnd.comicbook+zip" "application/x-cbz" "application/vnd.comicbook-rar"
        "application/x-cbr" "application/x-cb7" "application/x-cbt"
      ];
    };

    ebook = {
      description = "E-books";
      package = pkgs.foliate;
      desktopFile = "com.github.johnfactotum.Foliate.desktop";
      mimeTypes = [
        "application/epub+zip" "application/x-mobipocket-ebook"
        "application/vnd.amazon.mobi8-ebook" "application/x-fictionbook+xml"
        "application/x-zip-compressed-fb2"
      ];
    };

    # Kate shows line numbers, colours code and config files by their type, and
    # has search and replace, which is what is wanted when reading a log or a
    # settings file to find out what is wrong. (Its Breeze icons are added so
    # the buttons are not blank on desktops other than Plasma.)
    text = {
      description = "Plain text, Markdown, logs, JSON, XML";
      package = pkgs.kdePackages.kate;
      desktopFile = "org.kde.kate.desktop";
      extraPackages = [ pkgs.kdePackages.breeze-icons ];
      mimeTypes = [
        "text/plain" "text/markdown" "text/x-log" "text/x-readme" "text/x-changelog"
        "application/json" "application/xml" "text/xml" "application/x-yaml"
        "application/yaml" "application/x-zerosize"
      ];
    };

    archive = {
      description = "Archives (zip, 7z, rar, tar...)";
      package = pkgs.kdePackages.ark;
      desktopFile = "org.kde.ark.desktop";
      # Ark hands the real work to these programs (it lists them as
      # recommended): 7z for 7z and zip, unrar for rar, zip and unzip for
      # making and opening zip files. Without them whole formats are missing.
      extraPackages = [
        pkgs.p7zip
        pkgs.unrar
        pkgs.zip
        pkgs.unzip
        pkgs.kdePackages.breeze-icons
      ];
      mimeTypes = [
        "application/zip" "application/x-7z-compressed" "application/vnd.rar"
        "application/x-rar" "application/x-tar" "application/x-compressed-tar"
        "application/x-bzip-compressed-tar" "application/x-bzip2-compressed-tar"
        "application/x-xz-compressed-tar" "application/x-zstd-compressed-tar"
        "application/x-lzma-compressed-tar" "application/gzip" "application/x-bzip2"
        "application/x-xz" "application/zstd" "application/x-cpio"
        "application/x-lzma" "application/x-lzip" "application/x-lrzip"
        "application/x-lrzip-compressed-tar" "application/vnd.ms-cab-compressed"
        "application/x-archive"
      ];
    };

    # LibreOffice is Qt/VCL and not as pretty as the others, but nothing else
    # opens Word, Excel and PowerPoint files faithfully.
    word = {
      description = "Word processor documents (.docx .doc .odt .rtf)";
      package = pkgs.libreoffice;
      desktopFile = "writer.desktop";
      mimeTypes = [
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        "application/msword" "application/vnd.oasis.opendocument.text" "application/rtf"
      ];
    };
    spreadsheet = {
      description = "Spreadsheets (.xlsx .xls .ods .csv)";
      package = pkgs.libreoffice;
      desktopFile = "calc.desktop";
      mimeTypes = [
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        "application/vnd.ms-excel" "application/vnd.oasis.opendocument.spreadsheet"
        "text/csv"
      ];
    };
    presentation = {
      description = "Presentations (.pptx .ppt .odp)";
      package = pkgs.libreoffice;
      desktopFile = "impress.desktop";
      mimeTypes = [
        "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        "application/vnd.ms-powerpoint" "application/vnd.oasis.opendocument.presentation"
      ];
    };

    torrent = {
      description = "Torrent files and magnet links";
      package = pkgs.qbittorrent;
      desktopFile = "org.qbittorrent.qBittorrent.desktop";
      mimeTypes = [ "application/x-bittorrent" "x-scheme-handler/magnet" ];
    };
  };

  appType = c: lib.types.submodule {
    options = {
      package = lib.mkOption {
        type = lib.types.nullOr lib.types.package;
        default = c.package;
        defaultText = lib.literalMD "see modules/common/default-apps.nix";
        description = "The app to install and use. null = install nothing and set no default.";
      };
      desktopFile = lib.mkOption {
        type = lib.types.str;
        default = c.desktopFile;
        description = "The app's .desktop file name. Must belong to `package`.";
      };
    };
  };

  # Only the categories that still have an app.
  active = lib.filterAttrs (name: _: cfg.apps.${name}.package != null) categories;

  # Every file type may belong to one category only, or one would silently beat the other.
  allTypes = lib.concatMap (c: c.mimeTypes) (lib.attrValues categories);

  perCategory = f: lib.concatMapAttrs f active;
  associations = pick: perCategory (name: c:
    lib.genAttrs c.mimeTypes (_: pick cfg.apps.${name}.desktopFile));
in
{
  options.module.default-apps = {
    enable = mod.enableByDefault "default apps for opening files";

    apps = lib.mapAttrs (name: c: lib.mkOption {
      type = appType c;
      default = { };
      description = "${c.description}: which app opens them.";
    }) categories;
  };

  config = lib.mkIf cfg.enable {
    assertions = [{
      assertion = lib.unique allTypes == allTypes;
      message = "modules/common/default-apps.nix: a file type is listed under two categories: ${
        lib.concatStringsSep ", " (lib.filter (t: lib.count (x: x == t) allTypes > 1) (lib.unique allTypes))}";
    }];

    environment.systemPackages =
      lib.concatMap (name: [ cfg.apps.${name}.package ] ++ (categories.${name}.extraPackages or [ ]))
        (lib.attrNames active);

    xdg.mime = {
      # "Added" makes sure the app is offered for the type even where its own
      # desktop file does not claim it (alternate spellings of a file type).
      addedAssociations = associations (d: lib.mkDefault d);
      defaultApplications = associations (d: lib.mkDefault d);
    };

    # GTK4 apps keep their settings (window size, volume...) in dconf.
    programs.dconf.enable = lib.mkDefault true;
  };
}
