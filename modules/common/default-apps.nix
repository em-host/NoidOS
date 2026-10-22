{ mod, config, lib, pkgs, ... }:

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

    # Breeze icons so Kate's buttons are not blank outside Plasma.
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
      # Ark's backends; without them whole formats are missing.
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

  active = lib.filterAttrs (name: _: cfg.apps.${name}.package != null) categories;

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
      # Also offer the app for types its desktop file does not list (alternate MIME spellings).
      addedAssociations = associations (d: lib.mkDefault d);
      defaultApplications = associations (d: lib.mkDefault d);
    };

    programs.dconf.enable = lib.mkDefault true;
  };
}
