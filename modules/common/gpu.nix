{ mod, config, options, lib, pkgs, ... }:

# "nvidia": Turing (GTX 1650 / RTX 20) and newer, open kernel modules.
# "nvidia-legacy": Maxwell to Volta (GTX 750 to 1080 Ti, Titan V), closed modules, 580 driver.
# Kepler and older: "none" (nouveau).
let
  cfg = config.myOS.GPU;
  has = gpu: lib.elem gpu cfg;

  # Priority below everything NixOS-Hardware uses (it uses mkDefault = 1000 and 990).
  weak = lib.mkOverride 1100;

  legacyNvidia = has "nvidia-legacy";
  anyNvidia = has "nvidia" || legacyNvidia;
  anyGpu = anyNvidia || lib.any has [ "amd" "intel" "intel-arc" ];
  hybrid = anyNvidia && (has "intel" || has "intel-arc" || has "amd");

  # NixOS-Hardware's Intel profile manages the Intel drivers itself.
  intelProfile = options.hardware ? intelgpu;

  prime = config.hardware.nvidia.prime;
  primeBusIdsKnown = prime.nvidiaBusId != "" && (prime.intelBusId != "" || prime.amdgpuBusId != "");
in
{
  options.module.gpu.enable = mod.enableByDefault "GPU driver setup";

  options.myOS.GPU = lib.mkOption {
    type = lib.types.coercedTo lib.types.str lib.singleton (lib.types.listOf (lib.types.enum [
      "amd" "nvidia" "nvidia-legacy" "intel" "intel-arc" "vm" "none"
    ]));
    default = throw "myOS.GPU is not set. Add it to hosts/users/user.nix, e.g. myOS.GPU = \"amd\"; (or \"nvidia\", \"nvidia-legacy\", \"intel\", \"intel-arc\", \"vm\", \"none\", or a list like [ \"intel\" \"nvidia\" ]).";
    defaultText = lib.literalMD "none (must be set)";
    example = [ "intel" "nvidia" ];
    description = ''
      The GPU(s) in this machine: one of "amd", "nvidia", "nvidia-legacy", "intel",
      "intel-arc", "vm" or "none". Use a list for machines with more than one GPU.
    '';
  };

  config = lib.mkIf config.module.gpu.enable (lib.mkMerge [
    {
      assertions = [
        {
          assertion = !(has "none") || cfg == [ "none" ];
          message = ''myOS.GPU: "none" cannot be combined with other values (got: ${lib.concatStringsSep ", " cfg}).'';
        }
        {
          assertion = !(has "nvidia" && legacyNvidia);
          message = ''myOS.GPU: pick one of "nvidia" and "nvidia-legacy"; one driver runs all NVIDIA cards in a computer.'';
        }
      ];
    }

    (lib.mkIf anyGpu {
      hardware.graphics = {
        enable = weak true;
        enable32Bit = weak true;
      };
      environment.systemPackages = [ pkgs.vulkan-tools ];
    })

    (lib.mkIf (has "amd") {
      services.xserver.videoDrivers = weak [ "amdgpu" ];
      hardware.amdgpu.initrd.enable = weak true;
    })

    (lib.mkIf anyNvidia {
      services.xserver.videoDrivers = weak (lib.optional hybrid "modesetting" ++ [ "nvidia" ]);

      hardware.nvidia = {
        modesetting.enable = weak true;
        powerManagement.enable = weak false;
        powerManagement.finegrained = weak false;
        # RTX 50 requires the open modules; pre-Turing cards only work with the closed ones.
        open = weak (!legacyNvidia);
        nvidiaSettings = weak true;
        package = weak (
          if legacyNvidia then config.boot.kernelPackages.nvidiaPackages.legacy_580
          else config.boot.kernelPackages.nvidiaPackages.stable
        );
      };

      # Load early so the login screen comes up on the right GPU.
      boot.initrd.kernelModules = [ "nvidia" "nvidia_modeset" "nvidia_uvm" "nvidia_drm" ];
    })

    # PRIME offload only when bus IDs are known and no profile chose sync. Priority 999:
    # above nixpkgs' default, below NixOS-Hardware's profiles.
    (lib.mkIf (hybrid && primeBusIdsKnown && !prime.sync.enable && !prime.reverseSync.enable) {
      hardware.nvidia.prime.offload.enable = lib.mkOverride 999 true;
      hardware.nvidia.prime.offload.enableOffloadCmd = lib.mkOverride 999 true;
    })

    (lib.mkIf (has "intel") {
      services.xserver.videoDrivers = weak (lib.optional (!hybrid) "modesetting");
    })

    (lib.mkIf (has "intel-arc") {
      services.xserver.videoDrivers = weak (lib.optional (!hybrid) "modesetting");
      boot.kernelParams = [
        "i915.force_probe=*" # Force support for newer cards on stable kernels
      ];
    })

    (lib.mkIf ((has "intel" || has "intel-arc") && !intelProfile) {
      boot.initrd.kernelModules = [ "i915" ];
      hardware.graphics.extraPackages = with pkgs; [
        intel-media-driver
        intel-vaapi-driver
        libvdpau-va-gl
        vpl-gpu-rt
        intel-compute-runtime
      ];
    })

    (lib.mkIf (has "vm") {
      hardware.graphics.enable = weak true;
      services.xserver.videoDrivers = weak [ "modesetting" ];
      services.qemuGuest.enable = weak true;
      services.spice-vdagentd.enable = weak true;
    })
  ]);
}
