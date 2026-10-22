{ pkgs, config, lib, ... }:

let
  cfg = config.module.vr;
  dongleDriver = "rtw89_8852cu";
in
{
  options.module.vr = {
    enable = lib.mkEnableOption "Virtual Reality Support (Steam Frame / SteamVR)";

    wifiCountry = lib.mkOption {
      type = lib.types.strMatching "[A-Z]{2}";
      default = "US";
      example = "GB";
      description = ''
        Two-letter code of the country this computer is in. Wi-Fi radios use it
        to know which channels are legal there. Without it, Linux falls back to
        a cautious "world" setting that switches 6 GHz off, and the Steam Frame
        adapter only talks to the headset over 6 GHz.
      '';
    };
  };

  config = lib.mkIf cfg.enable {

    programs.steam.remotePlay.openFirewall = true;
    hardware.enableRedistributableFirmware = true;
    hardware.wirelessRegulatoryDatabase = true;

    boot.extraModprobeConfig = ''
      options cfg80211 ieee80211_regdom=${cfg.wifiCountry}
    '';
    services.udev.extraRules = ''
      ACTION=="add|change", SUBSYSTEM=="usb", ATTR{idVendor}=="28de", ATTR{idProduct}=="2432", TEST=="power/control", ATTR{power/control}="on"
      ACTION=="add|change", SUBSYSTEM=="usb", ATTR{idVendor}=="28de", ATTR{idProduct}=="2432", TEST=="power/autosuspend_delay_ms", ATTR{power/autosuspend_delay_ms}="-1"
    '';
    networking.networkmanager.settings = {
      "connection-50-steam-frame-adapter" = {
        match-device = "driver:${dongleDriver},interface-name:wlp*u*";
        "wifi.cloned-mac-address" = "permanent";
        "wifi.powersave" = 2;
      };
    };
    environment.systemPackages = [ pkgs.usbutils pkgs.iw ];
  };
}
