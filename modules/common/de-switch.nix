{ mod, config, lib, pkgs, ... }:

# ---------------------------------------------------------------------------
# Desktop environment switch.
#
#   myOS.DE = "plasma" | "gnome" | "cosmic";
#
# Everything that every desktop needs lives in the first block. Anything that
# only makes sense for one desktop lives in that desktop's block, so switching
# DE never drags the other desktop's libraries onto the machine.
# ---------------------------------------------------------------------------

let
  cfg = config.myOS;
  isPlasma = cfg.DE == "plasma";
  isGnome = cfg.DE == "gnome";
  isCosmic = cfg.DE == "cosmic";
in
{
  options.module.de-switch.enable = mod.enableByDefault "the desktop environment";

  options.myOS.DE = lib.mkOption {
    type = lib.types.enum [ "plasma" "gnome" "cosmic" ];
    default = "plasma";
    description = "Which desktop environment to install.";
  };

  # Any module can add a GNOME Shell extension here. They are all installed and
  # switched on for every user automatically (see the GNOME block below), so
  # an extension never needs to be turned on by hand.
  options.myOS.gnomeExtensions = lib.mkOption {
    type = lib.types.listOf lib.types.package;
    default = [ ];
    description = "GNOME Shell extensions to install and enable (only used when myOS.DE = \"gnome\").";
  };

  config = lib.mkIf config.module.de-switch.enable (lib.mkMerge [

    # -----------------------------------------------------------------------
    # Every desktop
    # -----------------------------------------------------------------------
    {
      environment.systemPackages = with pkgs; [
        tree
        gparted
        baobab
      ];
      # (File-opening defaults live in default-apps.nix.)
    }

    # -----------------------------------------------------------------------
    # KDE Plasma
    # -----------------------------------------------------------------------
    (lib.mkIf isPlasma {
      services.desktopManager.plasma6.enable = true;
      services.displayManager.sddm.enable = true;
      services.displayManager.sddm.wayland.enable = true;

      # Using the NixOS module (not just the package) also opens the firewall
      # ports KDE Connect needs. Installing the package alone leaves it unable
      # to find your phone.
      programs.kdeconnect.enable = true;

      environment.systemPackages = with pkgs.kdePackages; [
        ark
        kcalc
        plasma-systemmonitor
      ];
    })

    # -----------------------------------------------------------------------
    # GNOME
    # -----------------------------------------------------------------------
    (lib.mkIf isGnome {
      services.desktopManager.gnome.enable = true;
      services.displayManager.gdm.enable = true;

      myOS.gnomeExtensions = with pkgs.gnomeExtensions; [
        dash-to-panel
        appindicator
        arcmenu
        blur-my-shell
      ];

      # (Archives open in Ark, see default-apps.nix; the Files app packs and
      # unpacks them by itself.)
      environment.systemPackages = [
        pkgs.gnome-tweaks
      ] ++ cfg.gnomeExtensions;

      # Installing an extension only makes it *available*. This is what
      # actually switches them on, so a fresh user gets them without having to
      # open the Extensions app.
      programs.dconf.enable = true;
      programs.dconf.profiles.user.databases = [{
        settings."org/gnome/shell".enabled-extensions =
          map (extension: extension.extensionUuid) cfg.gnomeExtensions;
      }];
    })

    # -----------------------------------------------------------------------
    # COSMIC
    # -----------------------------------------------------------------------
    (lib.mkIf isCosmic {
      services.desktopManager.cosmic.enable = true;
      services.displayManager.cosmic-greeter.enable = true;
    })
  ]);
}
