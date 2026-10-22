{ config, pkgs, inputs, lib, ... }:

let
  cfg = config.module.zen;
  system = pkgs.stdenv.hostPlatform.system;

  hardened-zen = inputs.zen-browser.packages.${system}.default.override {
    # The wrapper takes extraPolicies, not policies.
    extraPolicies = {
      DisableTelemetry = true;
      DisableFirefoxStudies = true;
      DisablePocket = true;
      DisableProfileImport = true;
      OfferToSaveLogins = false;
      PasswordManagerEnabled = false;

      EnableTrackingProtection = {
        Value = true;
        Locked = true;
        Cryptomining = true;
        Fingerprinting = true;
      };

      Preferences = {
        # 5: Total Cookie Protection
        "network.cookie.cookieBehavior" = 5;

        "dom.security.https_only_mode" = true;
        "dom.security.https_only_mode_ever_enabled" = true;

        "browser.send_pings" = false;

        "privacy.globalprivacycontrol.enabled" = true;
        "privacy.donottrackheader.enabled" = true;

        "network.dns.disablePrefetch" = true;
        "network.predictor.enabled" = false;
        "network.prefetch-next" = false;

        "media.peerconnection.ice.default_address_only" = true;
      };

      ExtensionSettings = {
        # uBlock Origin
        "uBlock0@raymondhill.net" = {
          install_url = "https://addons.mozilla.org/firefox/downloads/latest/ublock-origin/latest.xpi";
          installation_mode = "force_installed";
        };
        # ClearURLs (Strips tracking parameters like ?utm_source= from links)
        "{74145f27-f039-47ce-a470-a662b129930a}" = {
          install_url = "https://addons.mozilla.org/firefox/downloads/latest/clearurls/latest.xpi";
          installation_mode = "force_installed";
        };
      };
    };
  };

in {
  options.module.zen = {
    enable = lib.mkEnableOption "Hardened Zen Browser (Brave Parity)";
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ hardened-zen ];
  };
}
