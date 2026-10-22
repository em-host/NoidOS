{ config, lib, pkgs, ... }:

let
  cfg = config.module.privacy;
  hardening = cfg.hardening;

  chosenZone =
    if cfg.timeZone != null then cfg.timeZone else config.module.essentials.timeZone;
in
{
  options.module.privacy = {
    enable = lib.mkEnableOption "privacy and security protections";

    dns = {
      strict = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          true: names are only ever looked up over an encrypted connection. If
          a network blocks that, nothing opens until it is allowed.

          false: encrypted when the network allows it, otherwise plain. Choose
          this if you often use Wi-Fi that asks you to sign in first (hotels,
          cafes, schools): those networks block encrypted DNS until you have
          signed in, so the sign-in page cannot even be found. A network that
          wants to spy can also force the plain fallback, which is why this is
          not the default.
        '';
      };

      servers = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [
          "9.9.9.9#dns.quad9.net"
          "149.112.112.112#dns.quad9.net"
          "2620:fe::fe#dns.quad9.net"
          "2620:fe::9#dns.quad9.net"
        ];
        example = [ "194.242.2.2#dns.mullvad.net" ];
        description = ''
          The DNS servers to use, as "address#name" (the name is what the
          server must prove it is). The default is Quad9. Names that only exist
          on the local network (a school's or office's own) are still looked up
          on that network.
        '';
      };
    };

    timeZone = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "America/New_York";
      description = ''
        The time zone, e.g. "Europe/Berlin". null: use module.essentials.timeZone
        if that is set, and otherwise leave the choice to the system settings
        (Date & Time). The zone is never looked up from where the computer is.
      '';
    };

    hardening = {
      network = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Firewall without ping, random cabled-network address, no name
          broadcasts, no hostname sent to routers, and network settings of the
          kernel that ignore attacks.
        '';
      };

      kernel = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Kernel settings that hide its internals from programs, wipe memory
          when handed out, and keep rarely used network protocols and FireWire
          from loading. If a program ever refuses to work, try switching this
          one off first.
        '';
      };
    };

    ntp.nts = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Set the clock with protected time servers (NTS, through chrony). On a
        network that blocks it the clock simply keeps running on its own.
      '';
    };

    apps.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Install Tor Browser, LibreWolf, KeePassXC, Cryptomator, Metadata Cleaner and Signal.";
    };

    vpn = lib.mkOption {
      type = lib.types.enum [ "none" "proton" "mullvad" "ivpn" ];
      default = "none";
      description = ''
        Install and start the program of a VPN service. You still need an
        account with that service. (Any other provider that gives you a
        WireGuard or OpenVPN file works through the network settings, which
        already know both.)
      '';
    };

    tor.daemon.enable = lib.mkEnableOption ''
      a Tor connection for the whole computer. Tor Browser does not need this,
      it brings its own. This is for other programs: run them as
      "torsocks program"
    '';

    appFirewall.enable = lib.mkEnableOption ''
      OpenSnitch, which asks before any program may connect to the internet.
      Open "OpenSnitch" in the app menu to see the questions
    '';

    antivirus.enable = lib.mkEnableOption ''
      ClamAV, a virus scanner (it keeps itself up to date and uses about 1 GB
      of memory). Scan with "ClamTk" in the app menu. Mostly useful for files
      that come from Windows computers
    '';
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      services.resolved.settings.Resolve = {
        # "~.": every name goes to these; the network's own DNS only answers its local names.
        DNS = cfg.dns.servers;
        Domains = [ "~." ];
        # No fallback to systemd's built-in servers (Cloudflare, Google).
        FallbackDNS = [ ];
        DNSOverTLS = if cfg.dns.strict then "true" else "opportunistic";
        DNSSEC = "allow-downgrade";
        LLMNR = "false";
        MulticastDNS = "false";
      };
    }

    {
      # essentials.nix enables this when no zone is set; it sends nearby Wi-Fi networks to an online service.
      services.automatic-timezoned.enable = lib.mkForce false;
      services.geoclue2.enable = false;

      time.timeZone = lib.mkIf (cfg.timeZone != null) (lib.mkForce cfg.timeZone);

      warnings = lib.optional (chosenZone == null) ''
        Privacy: no time zone is chosen, so the clock shows UTC until you pick
        your zone in the system settings (Date & Time), or set
        module.privacy.timeZone = "America/New_York"; (your own zone) in
        hosts/users/user.nix.
      '';
    }

    (lib.mkIf cfg.ntp.nts {
      services.timesyncd.enable = lib.mkForce false;
      services.chrony = {
        enable = true;
        enableNTS = true;
        servers = [
          "time.cloudflare.com"
          "nts.netnod.se"
          "ptbtime1.ptb.de"
          "ptbtime2.ptb.de"
        ];
      };
    })

    (lib.mkIf hardening.network {
      networking.networkmanager = {
        wifi.scanRandMacAddress = lib.mkForce true;
        ethernet.macAddress = lib.mkDefault "stable";

        connectionConfig = {
          "ipv4.dhcp-send-hostname" = false;
          "ipv6.dhcp-send-hostname" = false;
          "ipv6.ip6-privacy" = 2;
          "ipv6.addr-gen-mode" = "stable-privacy";
        };

        # Keep the random hostname from networking.nix instead of the one DHCP offers.
        settings.main.hostname-mode = "none";
      };

      networking.firewall = {
        enable = true;
        allowPing = false;
        logRefusedConnections = false;
        # Strict breaks WireGuard-based VPNs.
        checkReversePath = "loose";
      };

      boot.kernel.sysctl = {
        "net.ipv4.conf.all.accept_redirects" = 0;
        "net.ipv4.conf.default.accept_redirects" = 0;
        "net.ipv4.conf.all.secure_redirects" = 0;
        "net.ipv4.conf.default.secure_redirects" = 0;
        "net.ipv6.conf.all.accept_redirects" = 0;
        "net.ipv6.conf.default.accept_redirects" = 0;
        "net.ipv4.conf.all.send_redirects" = 0;
        "net.ipv4.conf.default.send_redirects" = 0;
        "net.ipv4.conf.all.accept_source_route" = 0;
        "net.ipv4.conf.default.accept_source_route" = 0;
        "net.ipv6.conf.all.accept_source_route" = 0;
        "net.ipv6.conf.default.accept_source_route" = 0;
        "net.ipv4.icmp_echo_ignore_broadcasts" = 1;
        "net.ipv4.icmp_ignore_bogus_error_responses" = 1;
        "net.ipv4.tcp_syncookies" = 1;
        "net.ipv4.tcp_rfc1337" = 1;
      };

      # cups-browsed needs avahi (not run here) and has a history of remote flaws.
      services.printing.browsed.enable = lib.mkForce false;
    })

    (lib.mkIf hardening.kernel {
      boot.kernel.sysctl = {
        "kernel.kptr_restrict" = 2;
        "kernel.dmesg_restrict" = 1;
        "kernel.yama.ptrace_scope" = 1;
        "kernel.unprivileged_bpf_disabled" = 1;
        "net.core.bpf_jit_harden" = 2;
        "kernel.kexec_load_disabled" = 1;
        "fs.suid_dumpable" = 0;
        "fs.protected_fifos" = 2;
        "fs.protected_regular" = 2;
        "dev.tty.ldisc_autoload" = 0;
        # user.max_user_namespaces deliberately left alone: Flatpak, Steam and Wine sandboxes need them.
      };

      boot.kernelParams = [
        "slab_nomerge"
        "init_on_alloc=1"
        "page_alloc.shuffle=1"
        "randomize_kstack_offset=on"
      ];

      boot.blacklistedKernelModules = [
        "dccp"
        "sctp"
        "rds"
        "tipc"
        "ax25"
        "netrom"
        "rose"
        "firewire-core"
        "firewire-ohci"
        "firewire-sbp2"
      ];

      systemd.coredump.enable = false;
      security.pam.loginLimits = [
        { domain = "*"; type = "hard"; item = "core"; value = "0"; }
      ];

      security.sudo.execWheelOnly = true;
      nix.settings.allowed-users = [ "@wheel" ];
      boot.tmp.cleanOnBoot = true;
      users.users.${config.myOS.username}.homeMode = lib.mkDefault "700";

      warnings = lib.optional (config.boot.initrd.luks.devices == { }) ''
        Privacy: this computer's disk is not encrypted, so anyone who holds
        the computer can read everything on it. It can only be turned on by
        installing again (choose "Encrypt system" in the installer).
      '';
    })

    (lib.mkIf cfg.apps.enable {
      environment.systemPackages = with pkgs; [
        tor-browser
        librewolf
        keepassxc
        cryptomator
        metadata-cleaner
      ];
    })

    (lib.mkIf (cfg.vpn == "mullvad") {
      services.mullvad-vpn = {
        enable = true;
        gui.enable = true;
      };
    })
    (lib.mkIf (cfg.vpn == "ivpn") {
      services.ivpn.enable = true;
      environment.systemPackages = [ pkgs.ivpn pkgs.ivpn-ui ];
    })
    (lib.mkIf (cfg.vpn == "proton") {
      environment.systemPackages = [ pkgs.proton-vpn ];
    })

    (lib.mkIf cfg.tor.daemon.enable {
      services.tor = {
        enable = true;
        client.enable = true;
      };
      environment.systemPackages = [ pkgs.torsocks ];
    })

    (lib.mkIf cfg.appFirewall.enable {
      services.opensnitch.enable = true;
      environment.systemPackages = [ pkgs.opensnitch-ui ];
    })

    (lib.mkIf cfg.antivirus.enable {
      services.clamav = {
        daemon.enable = true;
        updater.enable = true;
      };
      environment.systemPackages = [ pkgs.clamtk ];
    })
  ]);
}
