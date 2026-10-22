{ config, pkgs, inputs, lib, ... }:

let
  cfg = config.module.zen;
  system = pkgs.stdenv.hostPlatform.system;

  # Fetch Zen Browser from the flake and inject strict privacy policies
  hardened-zen = inputs.zen-browser.packages.${system}.default.override {

    # FIXED: The low-level wrapper requires 'extraPolicies', not 'policies'
    extraPolicies = {

      # === 1. BRAVE PARITY: CORE PRIVACY & TELEMETRY ===
      DisableTelemetry = true;
      DisableFirefoxStudies = true;
      DisablePocket = true;
      DisableProfileImport = true; # Prevent grabbing data from your other browsers
      OfferToSaveLogins = false; # Encourage use of a real password manager
      PasswordManagerEnabled = false;

      # === 2. BRAVE PARITY: SHIELDS (Anti-Tracking & Fingerprinting) ===
      EnableTrackingProtection = {
        Value = true;
        Locked = true;
        Cryptomining = true;
        Fingerprinting = true;
      };

      # Lock down strict under-the-hood preferences
      Preferences = {
        # Block 3rd party cookies completely (Brave default)
        "network.cookie.cookieBehavior" = 5;

        # HTTPS-Only Mode (Brave's HTTPS Everywhere)
        "dom.security.https_only_mode" = true;
        "dom.security.https_only_mode_ever_enabled" = true;

        # Disable hyperlink auditing (Pings tracking your clicks)
        "browser.send_pings" = false;

        # Enable Global Privacy Control (GPC) & Do Not Track
        "privacy.globalprivacycontrol.enabled" = true;
        "privacy.donottrackheader.enabled" = true;

        # Disable DNS prefetching and speculative connections
        "network.dns.disablePrefetch" = true;
        "network.predictor.enabled" = false;
        "network.prefetch-next" = false;

        # WebRTC IP Leak Protection (Forces traffic through your Tier 3 Tor / Tier 1 VPN)
        "media.peerconnection.ice.default_address_only" = true;
      };

      # === 3. BRAVE PARITY: AD BLOCKING ===
      # Brave has a native adblocker. We force-install uBlock Origin to match/exceed it.
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
    # Add the customized browser to system packages
    environment.systemPackages = [ hardened-zen ];
  };
}
