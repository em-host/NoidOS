{ mod, config, lib, pkgs, ... }:

# Keeps the disk from filling up with old system versions and leftovers.
#
#   module.garbage-clean.keepDays = 30;      # how long old system versions are kept
#   module.garbage-clean.schedule = "daily"; # when (systemd calendar syntax)
#
# Old versions are what "rollback" and the boot menu's older entries use, so
# keepDays is also how far back you can go. The version you are running is never removed.
#
# To do it right now instead of waiting: Nix Actions > Clean up (see nix-actions.nix).
# It follows these same settings.
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

    # Saves space by sharing identical files. Done once a week in the background
    # instead of on every build, which slows builds down.
    nix.optimise.automatic = lib.mkDefault true;

    # If a rebuild runs the disk low, Nix frees unused files by itself instead of failing.
    nix.settings = {
      min-free = lib.mkDefault (2 * 1024 * 1024 * 1024);
      max-free = lib.mkDefault (8 * 1024 * 1024 * 1024);
    };

    # Logs and /tmp
    services.journald.settings.Journal = {
      SystemMaxUse = lib.mkDefault "500M";
      MaxRetentionSec = lib.mkDefault "1month";
    };
    boot.tmp.cleanOnBoot = lib.mkDefault true;

    # Flatpak leaves behind runtimes nothing uses any more.
    services.flatpak.uninstallUnused = lib.mkIf config.services.flatpak.enable (lib.mkDefault true);
  };
}
