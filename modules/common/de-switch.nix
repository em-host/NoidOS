{ mod, config, lib, pkgs, ... }:

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

  options.myOS.gnomeExtensions = lib.mkOption {
    type = lib.types.listOf lib.types.package;
    default = [ ];
    description = "GNOME Shell extensions to install and enable (only used when myOS.DE = \"gnome\").";
  };

  config = lib.mkIf config.module.de-switch.enable (lib.mkMerge [
    {
      environment.systemPackages = with pkgs; [
        tree
        gparted
        baobab
      ];
    }

    (lib.mkIf isPlasma {
      services.desktopManager.plasma6.enable = true;
      services.displayManager.sddm.enable = true;
      services.displayManager.sddm.wayland.enable = true;

      # The module (not just the package) opens the firewall ports KDE Connect needs.
      programs.kdeconnect.enable = true;

      environment.systemPackages = with pkgs.kdePackages; [
        ark
        kcalc
        plasma-systemmonitor
      ];
    })

    (lib.mkIf isGnome {
      services.desktopManager.gnome.enable = true;
      services.displayManager.gdm.enable = true;

      myOS.gnomeExtensions = with pkgs.gnomeExtensions; [
        dash-to-panel
        appindicator
        arcmenu
        blur-my-shell
      ];

      environment.systemPackages = [
        pkgs.gnome-tweaks
      ] ++ cfg.gnomeExtensions;

      # Installed extensions are not enabled until listed in dconf.
      programs.dconf.enable = true;
      programs.dconf.profiles.user.databases = [{
        settings."org/gnome/shell".enabled-extensions =
          map (extension: extension.extensionUuid) cfg.gnomeExtensions;
      }];
    })

    (lib.mkIf isCosmic {
      services.desktopManager.cosmic.enable = true;
      services.displayManager.cosmic-greeter.enable = true;
    })
  ]);
}
