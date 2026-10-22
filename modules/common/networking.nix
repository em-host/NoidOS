{ mod, config, lib, pkgs, ... }:

let
  cfg = config.module.networking;
in
{
  options.module.networking.enable = mod.enableByDefault
    "networking (NetworkManager with VPN plugins, Quad9 DNS, a random host name on every boot)";

  config = lib.mkMerge [
    {
      # The flake output name (Nix Actions uses it); the network sees randomize-hostname's.
      networking.hostName = lib.mkDefault "Noid-OS";
    }

    (lib.mkIf cfg.enable {
      services.resolved.enable = true;
      networking = {
        nameservers = [ "9.9.9.9" ];

        wireguard.enable = true;

        networkmanager = {
          enable = true;
          wifi.backend = "wpa_supplicant";
          wifi.macAddress = "random";
          wifi.scanRandMacAddress = false;
          plugins = with pkgs; [
            networkmanager-openvpn
            networkmanager-strongswan
            networkmanager-openconnect
          ];
        };
      };

      # NetworkManager runs Wi-Fi through networking.wireless (wpa_supplicant), and
      # NixOS restarts wpa_supplicant whenever a Wi-Fi device is plugged in or out.
      # That drops the Wi-Fi connection, e.g. every time a USB Wi-Fi adapter such as
      # the Steam Frame's is plugged in. NetworkManager notices new devices by
      # itself, so the restart is replaced with "do nothing" (:= wins over +=).
      services.udev.extraRules =
        let w = config.networking.wireless;
        in lib.mkIf (w.enable && w.dbusControlled && !w.autoDetectInterfaces) (lib.mkBefore ''
          ACTION=="add|remove", SUBSYSTEM=="net", ENV{DEVTYPE}=="wlan", RUN:="${pkgs.coreutils}/bin/true"
        '');

      # Set before the network comes up; sudo keeps working through nss-myhostname.
      systemd.services.randomize-hostname = {
        description = "Random hostname for this boot";
        wantedBy = [ "multi-user.target" "network-pre.target" ];
        before = [ "network-pre.target" "NetworkManager.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          echo "pc-$(${pkgs.util-linux}/bin/uuidgen | cut -d- -f1)" > /proc/sys/kernel/hostname
        '';
      };
    })
  ];
}
