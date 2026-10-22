{ mod, config, options, lib, pkgs, ... }:

# GPU drivers.
#
# Set `myOS.GPU` to what is in the machine. One GPU is a string, a laptop with
# two GPUs is a list:
#
#   myOS.GPU = "amd";
#   myOS.GPU = [ "intel" "nvidia" ];      # hybrid laptop
#
# Accepted values:
#   amd            AMD (Mesa / RADV)
#   nvidia         NVIDIA GTX 1650 / RTX 20 series and newer (NVIDIA's driver, with
#                  its open kernel modules, which the RTX 50 series needs)
#   nvidia-legacy  NVIDIA GTX 750 to GTX 1080 Ti and Titan V (Maxwell, Pascal,
#                  Volta). The newest driver no longer supports them, so these
#                  get the 580 driver, which NVIDIA supports until 2028.
#                  (Older cards, GTX 600/700 Kepler: use "none"; the built-in
#                  nouveau driver then runs them.)
#   intel          Intel integrated graphics (UHD / Iris Xe)
#   intel-arc      Intel Arc (dedicated)
#   vm             Virtual machine guest
#   none           No GPU setup (servers, or you configure everything yourself)
#
# NixOS-Hardware profiles (see hosts/users/user.nix) are fully supported. Everything
# this module sets for the drivers is a low-priority default, so whatever a
# NixOS-Hardware profile says about the drivers wins automatically. The
# profile can be anything: a laptop model, `common-gpu-nvidia`, `common-gpu-amd`, ...
let
  cfg = config.myOS.GPU;
  has = gpu: lib.elem gpu cfg;

  # Priority below everything NixOS-Hardware uses (it uses mkDefault = 1000 and 990).
  weak = lib.mkOverride 1100;

  legacyNvidia = has "nvidia-legacy";
  anyNvidia = has "nvidia" || legacyNvidia;
  anyGpu = anyNvidia || lib.any has [ "amd" "intel" "intel-arc" ];
  hybrid = anyNvidia && (has "intel" || has "intel-arc" || has "amd");

  # NixOS-Hardware's Intel profile brings its own `hardware.intelgpu` options and
  # takes care of the Intel drivers itself. When it is present we step aside.
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
    # No default on purpose: a wrong guess means no working graphics driver.
    # Evaluation stops with this message if the host does not say what it has.
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

    # ---------------------------------------------------------
    # Any real GPU: graphics stack (32-bit for Steam / Wine)
    # ---------------------------------------------------------
    (lib.mkIf anyGpu {
      hardware.graphics = {
        enable = weak true;
        enable32Bit = weak true;
      };
      # vulkaninfo: shows whether games can see the graphics card.
      environment.systemPackages = [ pkgs.vulkan-tools ];
    })

    # ---------------------------------------------------------
    # AMD (Mesa / RADV)
    # ---------------------------------------------------------
    (lib.mkIf (has "amd") {
      services.xserver.videoDrivers = weak [ "amdgpu" ];
      hardware.amdgpu.initrd.enable = weak true;
    })

    # ---------------------------------------------------------
    # NVIDIA (NVIDIA's own driver)
    # ---------------------------------------------------------
    (lib.mkIf anyNvidia {
      services.xserver.videoDrivers = weak (lib.optional hybrid "modesetting" ++ [ "nvidia" ]);

      hardware.nvidia = {
        modesetting.enable = weak true;
        powerManagement.enable = weak false;
        powerManagement.finegrained = weak false;
        # The open kernel modules are what NVIDIA recommends from the GTX 1650 / RTX 20
        # series on, and the only ones the RTX 50 series works with. Older cards
        # only work with the closed ones, and only up to the 580 driver.
        # (NixOS-Hardware's per-generation profiles still win over both.)
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

    # Hybrid laptop: render on the integrated GPU, run games on the NVIDIA one
    # with `nvidia-offload <program>`. Needs the bus IDs, which NixOS-Hardware
    # laptop profiles provide; without them this is skipped rather than failing.
    # (Priority 999: above nixpkgs' own default for this option, below NixOS-Hardware's
    # profiles. If a profile asked for PRIME sync instead, we leave it alone.)
    (lib.mkIf (hybrid && primeBusIdsKnown && !prime.sync.enable && !prime.reverseSync.enable) {
      hardware.nvidia.prime.offload.enable = lib.mkOverride 999 true;
      hardware.nvidia.prime.offload.enableOffloadCmd = lib.mkOverride 999 true;
    })

    # ---------------------------------------------------------
    # Intel integrated (UHD / Iris Xe)
    # ---------------------------------------------------------
    (lib.mkIf (has "intel") {
      services.xserver.videoDrivers = weak (lib.optional (!hybrid) "modesetting");
    })

    # ---------------------------------------------------------
    # Intel Arc (dedicated)
    # ---------------------------------------------------------
    (lib.mkIf (has "intel-arc") {
      services.xserver.videoDrivers = weak (lib.optional (!hybrid) "modesetting");
      boot.kernelParams = [
        "i915.force_probe=*" # Force support for newer cards on stable kernels
      ];
    })

    # Intel userspace drivers, unless the NixOS-Hardware Intel profile provides them.
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

    # ---------------------------------------------------------
    # Virtual machine guest
    # ---------------------------------------------------------
    (lib.mkIf (has "vm") {
      hardware.graphics.enable = weak true;
      services.xserver.videoDrivers = weak [ "modesetting" ];
      services.qemuGuest.enable = weak true;
      services.spice-vdagentd.enable = weak true;
    })
  ]);
}
