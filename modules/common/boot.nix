{ mod, config, pkgs, lib, inputs, ... }:

let
  cfg = config.module.boot;
  bios = cfg.biosDevice != null;

  # nixpkgs workaround (Oct 2026): aggregateModules expects a <module>.ko.cer next to every
  # out-of-tree module, but packages that install .ko files by hand (framework-laptop-kmod,
  # broadcom-sta) ship none: "cat: extra/framework_laptop.ko.cer: No such file or directory".
  # Sign those with kmodigest before aggregation; no-op without kmodigest. Remove once fixed.
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
          useOSProber = lib.mkDefault true;

          # The theme is laid out for 1080p.
          gfxmodeEfi = lib.mkDefault "1920x1080,auto";
          gfxmodeBios = lib.mkDefault "1920x1080,auto";

          # The default of 100 entries can fill a small boot partition.
          configurationLimit = lib.mkDefault 10;

          minegrub-world-sel.enable = lib.mkDefault true;

          # Not mkDefault: hosts append their own entries to this list.
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
