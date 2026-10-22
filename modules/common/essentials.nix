{ mod, config, lib, pkgs, ... }:

let
  cfg = config.module.essentials;
  default = lib.mkDefault;
in
{
  options.module.essentials = {
    enable = mod.enableByDefault
      "the basics every computer needs (sound, Bluetooth, fonts, firmware updates, ...)";

    timeZone = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "America/New_York";
      description = ''
        null (the default): the time zone is worked out automatically from
        where the computer is, and follows it when you travel. This asks a
        public location service (beacondb.net) about the Wi-Fi networks nearby.

        A name such as "America/New_York" turns that off and always uses that
        time zone. Pick this if you would rather not have any location lookup.
      '';
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      nix.settings.experimental-features = [ "nix-command" "flakes" ];

      # Plain value: nixpkgs.config does not merge mkDefault.
      nixpkgs.config.allowUnfree = true;

      users.users.${config.myOS.username} = {
        isNormalUser = default true;
        description = default config.myOS.fullName;
        extraGroups = [ "networkmanager" "wheel" "tty" "video" "render" ];
      };
    }

    {
      environment.shellAliases.rebuild = default
        "sudo nixos-rebuild switch --flake ${config.myOS.flakeDir}#${config.networking.hostName}";
    }

    {
      i18n.defaultLocale = default "en_US.UTF-8";
      i18n.extraLocaleSettings = lib.genAttrs [
        "LC_ADDRESS"
        "LC_IDENTIFICATION"
        "LC_MEASUREMENT"
        "LC_MONETARY"
        "LC_NAME"
        "LC_NUMERIC"
        "LC_PAPER"
        "LC_TELEPHONE"
        "LC_TIME"
      ] (_: default config.i18n.defaultLocale);

      services.automatic-timezoned.enable = cfg.timeZone == null;
      time.timeZone = lib.mkIf (cfg.timeZone != null) cfg.timeZone;

      # Windows keeps the hardware clock in local time; match it for dual boot.
      time.hardwareClockInLocalTime = default true;

      services.xserver.enable = default true;
    }

    {
      services.pulseaudio.enable = default false;
      security.rtkit.enable = default true;
      services.pipewire = {
        enable = default true;
        alsa.enable = default true;
        alsa.support32Bit = default true;
        pulse.enable = default true;
      };

      hardware.bluetooth.enable = default true;

      services.printing.enable = default true;
    }

    {
      fonts.enableDefaultPackages = default true;
      fonts.packages = with pkgs; [
        noto-fonts
        noto-fonts-cjk-sans
        noto-fonts-color-emoji
      ];
    }

    {
      hardware.enableRedistributableFirmware = default true;

      services.fwupd.enable = default true;

      services.fstrim.enable = default true;

      zramSwap.enable = default true;

      services.earlyoom = {
        enable = default true;
        enableNotifications = default true;
      };
    }
  ]);
}
