{ mod, config, lib, pkgs, ... }:

# ---------------------------------------------------------------------------
# Essentials: the basics every computer needs, so a machine's own host file
# only has to describe the machine itself.
#
#   * your user account
#   * Nix settings, "unfree" software allowed
#   * sound (PipeWire), Bluetooth, printing
#   * language, time zone, clock
#   * fonts that cover most languages and emoji
#   * firmware updates, SSD trimming, compressed swap in RAM, and an
#     out-of-memory guard (kills the one runaway program instead of letting
#     the whole computer freeze)
#
# Everything here is only a *default*. To change one thing for a single
# machine, set the normal NixOS option in hosts/users/user.nix; this file never
# needs editing. For example:
#
#   i18n.defaultLocale = "de_DE.UTF-8";          # language and formats
#   services.xserver.xkb.layout = "de";          # keyboard layout
#   module.essentials.timeZone = "Europe/Berlin"; # see below
#   hardware.bluetooth.enable = false;
#
# What is NOT here, because it is a fact about one machine: the disks
# (hardware-configuration.nix), system.stateVersion, the GPU and the desktop
# (myOS.GPU / myOS.DE).
#
# The switch (module.essentials.enable = false) removes ALL of the above, so the
# host file would have to provide the basics itself. Most often that is
# nixpkgs.config.allowUnfree = true; (the NVIDIA driver and Steam need it).
# To drop just one thing, set its own option instead, as in the examples above.
# ---------------------------------------------------------------------------

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

    # -----------------------------------------------------------------------
    # Nix and your account
    # -----------------------------------------------------------------------
    {
      # Flakes are how this whole configuration is built.
      nix.settings.experimental-features = [ "nix-command" "flakes" ];

      # Many everyday programs (Steam, Chrome, Discord, drivers...) are "unfree".
      # (Plain value on purpose: nixpkgs.config does not understand mkDefault.)
      nixpkgs.config.allowUnfree = true;

      users.users.${config.myOS.username} = {
        isNormalUser = default true;
        description = default config.myOS.fullName;
        # networkmanager: Wi-Fi settings. wheel: administrator (sudo).
        # video / render: graphics and GPU compute. tty: serial devices.
        extraGroups = [ "networkmanager" "wheel" "tty" "video" "render" ];
      };
    }

    # -----------------------------------------------------------------------
    # For anyone who does use a terminal
    # -----------------------------------------------------------------------
    {
      # "rebuild" applies this configuration. (Everyone else: Nix Actions.)
      environment.shellAliases.rebuild = default
        "sudo nixos-rebuild switch --flake ${config.myOS.flakeDir}#${config.networking.hostName}";
    }

    # -----------------------------------------------------------------------
    # Language, time and keyboard
    # -----------------------------------------------------------------------
    {
      i18n.defaultLocale = default "en_US.UTF-8";
      # Dates, numbers, paper size... follow the main language unless set otherwise.
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

      # Windows keeps its clock in local time, Linux in UTC. With both on one
      # computer, one of them shows the wrong time after every switch, unless
      # they agree. Most of these computers have Windows next to NixOS.
      time.hardwareClockInLocalTime = default true;

      # The keyboard layout is services.xserver.xkb.layout ("us" unless set).
      services.xserver.enable = default true;
    }

    # -----------------------------------------------------------------------
    # Sound, Bluetooth, printing
    # -----------------------------------------------------------------------
    {
      services.pulseaudio.enable = default false; # PipeWire replaces it
      security.rtkit.enable = default true;
      services.pipewire = {
        enable = default true;
        alsa.enable = default true;
        alsa.support32Bit = default true; # 32-bit games
        pulse.enable = default true;
      };

      hardware.bluetooth.enable = default true;

      # Stopgap until printing becomes a module of its own.
      services.printing.enable = default true;
    }

    # -----------------------------------------------------------------------
    # Fonts
    # -----------------------------------------------------------------------
    {
      fonts.enableDefaultPackages = default true;
      # Without these, text in many languages and emoji show up as empty boxes.
      fonts.packages = with pkgs; [
        noto-fonts
        noto-fonts-cjk-sans # Chinese, Japanese, Korean
        noto-fonts-color-emoji
      ];
    }

    # -----------------------------------------------------------------------
    # Keeping the hardware healthy
    # -----------------------------------------------------------------------
    {
      hardware.enableRedistributableFirmware = default true;

      # Firmware updates from the Linux Vendor Firmware Service. They show up
      # in the desktop's update tool (Discover / GNOME Software).
      services.fwupd.enable = default true;

      # Tells SSDs which blocks are free, once a week. Keeps them fast.
      services.fstrim.enable = default true;

      # Swap that lives in compressed RAM: far faster than swapping to disk,
      # and makes a computer with little memory feel much less cramped.
      zramSwap.enable = default true;

      # If memory runs out, close the biggest program (and say so) instead of
      # letting the whole computer freeze until someone holds the power button.
      services.earlyoom = {
        enable = default true;
        enableNotifications = default true;
      };
    }
  ]);
}
