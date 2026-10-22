{ mod, config, lib, pkgs, ... }:
let
  cfg = config.module.garbage-clean;
in
{
  options.module.garbage-clean = {
    enable = mod.enableByDefault "automatic cleanup of old system versions and leftovers";

    keepDays = lib.mkOption {
      type = lib.types.ints.positive;
      default = 14;
      description = "Old system versions younger than this many days are kept.";
    };

    schedule = lib.mkOption {
      type = lib.types.str;
      default = "weekly";
      example = "daily";
      description = ''
        How often to clean (systemd calendar syntax). A computer that was off at
        that time cleans the next time it is on.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    nix.gc = {
      automatic = lib.mkDefault true;
      dates = lib.mkDefault cfg.schedule;
      # (There is no flag to cap the *number* of versions; age is all Nix offers.)
      options = lib.mkDefault "--delete-older-than ${toString cfg.keepDays}d";
      randomizedDelaySec = lib.mkDefault "30min";
    };

    # Weekly instead of auto-optimise-store, which slows every build.
    nix.optimise.automatic = lib.mkDefault true;

    nix.settings = {
      min-free = lib.mkDefault (2 * 1024 * 1024 * 1024);
      max-free = lib.mkDefault (8 * 1024 * 1024 * 1024);
    };

    services.journald.settings.Journal = {
      SystemMaxUse = lib.mkDefault "500M";
      MaxRetentionSec = lib.mkDefault "1month";
    };
    boot.tmp.cleanOnBoot = lib.mkDefault true;

    services.flatpak.uninstallUnused = lib.mkIf config.services.flatpak.enable (lib.mkDefault true);
  };
}
