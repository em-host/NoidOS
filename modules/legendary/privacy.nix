{ config, lib, pkgs, ... }:

# ---------------------------------------------------------------------------
# Privacy & security: one switch (module.privacy.enable = true;) that turns on
# every protection which does not get in the way of everyday use, games, VR
# and Windows programs. Protections that do get in the way are separate
# switches that stay OFF until someone asks for them.
#
# WHAT THE SWITCH DOES
#
#   Names and locations
#     * DNS (the "phone book" of the internet) is asked over an encrypted
#       connection (Quad9: no logging, blocks known malware sites). Nobody on
#       the Wi-Fi, and not your internet provider, can read those lookups, and
#       nothing falls back to unencrypted servers. (The addresses you then
#       connect to are still visible to the network. Hiding those is what a
#       VPN or Tor Browser is for.)
#     * The time zone is not worked out from where the computer is (that asks
#       an online service about the Wi-Fi networks nearby), and the location
#       service is switched off.
#     * The computer's name on the network is random (networking.nix); it is
#       also never sent to routers when connecting.
#     * Hardware address (MAC address) of Wi-Fi is random (networking.nix) and
#       so is the one used while merely scanning for networks. Cabled
#       connections use a different address per network.
#     * Temporary IPv6 addresses, so a website cannot recognise the computer
#       by its address. No LLMNR / mDNS name broadcasts.
#
#   Network
#     * The firewall is on, answers no pings, and nothing is open that you did
#       not open yourself (Steam Remote Play and the like still work, they open
#       their own ports).
#     * The kernel ignores network tricks it has no use for (redirects,
#       source-routed packets, ...) and hides its internals from programs.
#     * The clock is set over NTS, a protected version of the usual time
#       protocol, so a network cannot feed the computer a wrong time.
#
#   The system itself
#     * Memory is wiped when it is handed out, and rare network protocols and
#       old network/hardware features that only ever get used in attacks
#       (DCCP, SCTP, FireWire, ...) are not loaded.
#     * No "core dump" files (a crashed program's memory, passwords included).
#     * Only administrators may run sudo or use Nix; /tmp is emptied at boot;
#       your home folder is private to you.
#     * The printer-discovery service (cups-browsed), which listens on the
#       network and has had serious flaws, is off.
#
#   Programs (module.privacy.apps)
#     Tor Browser, LibreWolf (a hardened Firefox), KeePassXC (passwords),
#     Cryptomator (encrypted folders for cloud storage), Metadata Cleaner
#     (removes who/where/when from photos and documents) and Signal.
#     The hardened Zen Browser is its own switch: module.zen.enable.
#
# WHAT IT LEAVES ALONE ON PURPOSE (each of these breaks something)
#   * User namespaces, which Flatpak, Steam and Wine need.
#   * Hibernation (protectKernelImage), unsigned graphics drivers (kernel
#     lockdown), and CPU protections that cost a lot of speed (mitigations).
#   * The custom kernel from boot.nix (a "hardened" kernel breaks NVIDIA and
#     games).
#   * The VR adapter's real hardware address (modules/rare/vr.nix): the Steam
#     Frame needs it.
#
# EXTRA SWITCHES (off unless you turn them on)
#   module.privacy.vpn             "proton", "mullvad" or "ivpn": that provider's
#                                  program and background service.
#   module.privacy.tor.daemon      a Tor connection for the whole computer, for
#                                  programs that use torsocks.
#   module.privacy.appFirewall     OpenSnitch: asks before any program may
#                                  connect to the internet. Very safe, but
#                                  you get a question for every new program.
#   module.privacy.antivirus       ClamAV (uses about 1 GB of memory).
#
# NOT DONE HERE, because it cannot be done afterwards or has a price
#   * Disk encryption: choose "Encrypt system" while installing. A rebuild
#     shows a notice while the disk is not encrypted.
#   * USBGuard (blocks every new USB device until approved): it would block
#     the VR adapter, game controllers and USB sticks.
#   * Secure Boot: needs systemd-boot, and this configuration uses GRUB.
#
# Examples (hosts/users/user.nix):
#
#   module.privacy = {
#     enable = true;
#     vpn = "mullvad";
#     timeZone = "Europe/Berlin";   # otherwise set it in the system settings
#     dns.strict = false;           # for hotel and school Wi-Fi, see below
#   };
# ---------------------------------------------------------------------------

let
  cfg = config.module.privacy;
  hardening = cfg.hardening;

  # Zone chosen on purpose, here or in essentials.nix.
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

    # -----------------------------------------------------------------------
    # Names: encrypted DNS, no leaks to other servers
    # -----------------------------------------------------------------------
    {
      services.resolved.settings.Resolve = {
        # Only these servers, never the ones the Wi-Fi hands out for everything
        # (those stay in use for names that only that network knows) ...
        DNS = cfg.dns.servers;
        Domains = [ "~." ];
        # ... and never the ones built into systemd (Cloudflare, Google).
        FallbackDNS = [ ];
        DNSOverTLS = if cfg.dns.strict then "true" else "opportunistic";
        # "allow-downgrade": checks signatures where there are some, and still
        # works for the many names that have none.
        DNSSEC = "allow-downgrade";
        # Name broadcasts on the local network: they tell everyone the
        # computer's name and can be answered by anyone with a lie.
        LLMNR = "false";
        MulticastDNS = "false";
      };
    }

    # -----------------------------------------------------------------------
    # Location and clock
    # -----------------------------------------------------------------------
    {
      # essentials.nix turns this on when no time zone is chosen. It asks an
      # online service about the Wi-Fi networks nearby.
      services.automatic-timezoned.enable = lib.mkForce false;
      # The desktops switch this on for "find my location" features.
      services.geoclue2.enable = false;

      time.timeZone = lib.mkIf (cfg.timeZone != null) (lib.mkForce cfg.timeZone);

      # Without any chosen zone the system settings can set it (time.timeZone
      # stays unset, which allows that).
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

    # -----------------------------------------------------------------------
    # Network
    # -----------------------------------------------------------------------
    (lib.mkIf hardening.network {
      networking.networkmanager = {
        # Wi-Fi: networking.nix picks a random address per connection. While
        # only looking for networks, the address was left real there; that is
        # what gives a computer away in a crowd.
        wifi.scanRandMacAddress = lib.mkForce true;
        # Cable: a different address on every network, the same one on a
        # network you come back to.
        ethernet.macAddress = lib.mkDefault "stable";

        connectionConfig = {
          # Do not tell the router what the computer is called.
          "ipv4.dhcp-send-hostname" = false;
          "ipv6.dhcp-send-hostname" = false;
          # Temporary IPv6 addresses for outgoing connections.
          "ipv6.ip6-privacy" = 2;
          "ipv6.addr-gen-mode" = "stable-privacy";
        };

        # NetworkManager must never rename the computer from what a router
        # says (the random name comes from networking.nix).
        settings.main.hostname-mode = "none";
      };

      networking.firewall = {
        enable = true;
        allowPing = false;
        logRefusedConnections = false; # a scan would fill the logs
        # VPNs (WireGuard, Mullvad, ...) do not work with the strict setting.
        checkReversePath = "loose";
      };

      # Network settings of the kernel. Linux accepts a lot that nobody
      # needs and attackers like: packets that dictate their own route,
      # "redirects" that change where traffic goes, answers to broadcast pings.
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

      # Only a printer that was set up by hand is used. (cups-browsed finds
      # printers by listening to the network; it needs avahi, which this
      # configuration does not run, and it is a way in.)
      services.printing.browsed.enable = lib.mkForce false;
    })

    # -----------------------------------------------------------------------
    # The system itself
    # -----------------------------------------------------------------------
    (lib.mkIf hardening.kernel {
      boot.kernel.sysctl = {
        # Memory addresses and kernel messages are only for administrators.
        "kernel.kptr_restrict" = 2;
        "kernel.dmesg_restrict" = 1;
        # A program may only inspect programs it started itself. (Debuggers
        # started with sudo still can attach to anything.)
        "kernel.yama.ptrace_scope" = 1;
        # Ordinary users cannot run code inside the kernel (eBPF), and what
        # runs there is hardened.
        "kernel.unprivileged_bpf_disabled" = 1;
        "net.core.bpf_jit_harden" = 2;
        # Nothing can replace the running kernel, and programs that run with
        # extra rights never write their memory to a file.
        "kernel.kexec_load_disabled" = 1;
        "fs.suid_dumpable" = 0;
        # Stops tricks with files in shared folders like /tmp.
        "fs.protected_fifos" = 2;
        "fs.protected_regular" = 2;
        # No automatic loading of obscure terminal drivers.
        "dev.tty.ldisc_autoload" = 0;
        # Deliberately NOT set: user.max_user_namespaces. Flatpak, Steam and
        # Wine could no longer start their sandboxes.
      };

      boot.kernelParams = [
        "slab_nomerge" # separate memory pools per kind of data
        "init_on_alloc=1" # memory is wiped when handed out
        "page_alloc.shuffle=1"
        "randomize_kstack_offset=on"
      ];

      # Attacks on the kernel often start by making it load a module for a
      # protocol or device nobody uses. These are not loaded unless asked for
      # by name. (Thunderbolt and Bluetooth stay: docks and headphones.)
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

      # A crashed program's memory (passwords, keys) is not written to disk.
      systemd.coredump.enable = false;
      security.pam.loginLimits = [
        { domain = "*"; type = "hard"; item = "core"; value = "0"; }
      ];

      security.sudo.execWheelOnly = true;
      nix.settings.allowed-users = [ "@wheel" ];
      boot.tmp.cleanOnBoot = true;
      users.users.${config.myOS.username}.homeMode = lib.mkDefault "700";

      # What this module cannot do afterwards: encrypt a disk that is not.
      warnings = lib.optional (config.boot.initrd.luks.devices == { }) ''
        Privacy: this computer's disk is not encrypted, so anyone who holds
        the computer can read everything on it. It can only be turned on by
        installing again (choose "Encrypt system" in the installer).
      '';
    })

    # -----------------------------------------------------------------------
    # Programs
    # -----------------------------------------------------------------------
    (lib.mkIf cfg.apps.enable {
      environment.systemPackages = with pkgs; [
        tor-browser
        librewolf
        keepassxc
        cryptomator
        metadata-cleaner
      ];
    })

    # -----------------------------------------------------------------------
    # VPN
    # -----------------------------------------------------------------------
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

    # -----------------------------------------------------------------------
    # Extra switches
    # -----------------------------------------------------------------------
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
