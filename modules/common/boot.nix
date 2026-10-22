{ mod, config, pkgs, lib, inputs, ... }:

# Bootloader (GRUB + Minecraft theme) and kernel.
#
# Everything here is a default (mkDefault), so a host can change any of it in
# hosts/users/user.nix without mkForce, e.g.
#
#   boot.kernelPackages = pkgs.linuxPackages_latest;
#   boot.loader.grub.configurationLimit = 20;
#
# Windows gets a themed entry here, since most people dual boot. Entries that only
# exist on one machine (a USB stick, another disk) go in user.nix instead, via
# `boot.loader.grub.extraEntries` and `boot.loader.grub.minegrub-world-sel.customIcons`
# (that list is added to, not replaced).
let
  cfg = config.module.boot;
  bios = cfg.biosDevice != null;

  # ---- kernel modules from outside the kernel need a certificate --------------
  # Since mid-October 2026 nixpkgs signs every kernel module (with kmodigest) and
  # gives each module that is not part of the kernel its own certificate file,
  # <module>.ko.cer. Packages that copy their module into place by hand instead
  # of using the kernel's install step come without one, and then the whole system
  # fails to build:
  #     cat: extra/framework_laptop.ko.cer: No such file or directory
  # Hit by the Framework laptop driver (NixOS-Hardware's Framework profiles) and
  # Broadcom Wi-Fi (wl, which the hardware scan adds by itself), among others.
  # This signs such modules the same way nixpkgs signs all others, just before
  # they are collected. Everything else is passed through unchanged (as links),
  # and with an older nixpkgs that does not sign modules, nothing happens at all.
  # It can go once nixpkgs fixes those packages.
  signModules = pkgs: pkg:
    if (pkg.outputName or "out") == "modules" then pkg # the kernel's own modules
    else
      pkgs.runCommand "${pkg.name or "kernel-module"}-signed"
        { nativeBuildInputs = [ pkgs.buildPackages.kmodigest ]; }
        ''
          cp -rs ${pkg} "$out"
          chmod -R u+w "$out"
          # A tree with modules.cer is a whole kernel's modules: already done.
          if [ -d "$out/lib/modules" ] && ! compgen -G "$out/lib/modules/*/modules.cer" >/dev/null; then
            find "$out/lib/modules" -name '*.ko' | while read -r ko; do
              if [ ! -e "$ko.cer" ]; then
                echo "signing $(basename "$ko") (it came without a certificate)"
                cp --remove-destination -- "$(readlink -f "$ko")" "$ko"
                chmod u+w "$ko"
                kmodigest "$ko"
              fi
            done
          fi
        '';
in
{
  imports = [ inputs.minegrub-world-sel-theme.nixosModules.default ];

  options.module.boot = {
    enable = mod.enableByDefault "the GRUB bootloader and kernel setup";

    biosDevice = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/dev/sda";
      description = ''
        Only for old computers that start in legacy BIOS mode instead of UEFI:
        the disk GRUB is installed to. Leave as null on any UEFI computer (almost
        everything made since ~2012).
      '';
    };
  };

  config = lib.mkMerge [
  {
    # Not tied to the switch: any kernel needs this (see signModules above).
    nixpkgs.overlays = [
      (final: prev: lib.optionalAttrs (prev ? kmodigest) {
        aggregateModules = modules: prev.aggregateModules (map (signModules final) modules);
      })
    ];
  }

  (lib.mkIf cfg.enable {
    boot = {
      kernelPackages = lib.mkDefault pkgs.linuxPackages_zen;

      loader = {
        efi.canTouchEfiVariables = lib.mkDefault (!bios);

        grub = {
          enable = lib.mkDefault true;
          efiSupport = lib.mkDefault (!bios);
          device = lib.mkDefault (if bios then cfg.biosDevice else "nodev");
          useOSProber = lib.mkDefault true; # lists Windows / other Linux installs

          # The theme is laid out for 1080p. Screens that cannot do it fall back
          # to their own resolution instead of failing.
          gfxmodeEfi = lib.mkDefault "1920x1080,auto";
          gfxmodeBios = lib.mkDefault "1920x1080,auto";

          # Each entry keeps a kernel + initrd on the boot partition. The default
          # of 100 can fill a small one, after which updates fail.
          configurationLimit = lib.mkDefault 10;

          minegrub-world-sel.enable = lib.mkDefault true;

          # Icon and text for Windows in the boot menu (found by os-prober above).
          # Not a default on purpose: a host's own entries are added to this list.
          minegrub-world-sel.customIcons = [
            {
              name = "Windows";
              lineTop = "Windows (Hardcore Mode)";
              lineBottom = "Boot into Windows";
              imgName = "windows";
            }
          ];
        };
      };
    };
  })
  ];
}
