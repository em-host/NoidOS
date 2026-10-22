{
  description = "Noid-OS: a NixOS configuration for everyone";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixos-hardware.url = "github:NixOS/nixos-hardware/master";
    nix-flatpak.url = "github:gmodena/nix-flatpak";
    minegrub-world-sel-theme = {
      url = "github:Lxtharia/minegrub-world-sel-theme";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    zen-browser.url = "github:0xc000022070/zen-browser-flake";
    # ComfyUI, for module.ai.media (modules/legendary/ai.nix). It keeps its own
    # nixpkgs on purpose: its download servers have ready-made builds for that one.
    # Only downloaded on computers that use it (and when updating).
    comfyui.url = "github:utensils/comfyui-nix";

    # Flakes added with the "Add a Flake" app, or by hand in hosts/flakes/,
    # are collected in this small generated flake. Nothing here ever needs
    # editing: the nixos-flakes command rewrites it. See modules/flakes/default.nix.
    flakes.url = "path:./hosts/flakes/registry";
  };

  outputs = { self, nixpkgs, ... }@inputs:
    let
      # Only in the original copy of this folder: the install ISO (see iso/README.md).
      # The iso/ folder is not handed out with the configuration, and without it these
      # outputs are simply not there.
      hasInstaller = builtins.pathExists ./iso;
    in
    {
      nixosConfigurations = {
        Noid-OS = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          specialArgs = {
            # Every module can use the flake inputs (`inputs`) and the helpers in lib/ (`mod`).
            inherit inputs;
            mod = import ./lib { inherit (nixpkgs) lib; };
          };

          # This computer (hosts/), everything shared (modules/), and the myOS.* options.
          # Modules that come from other flakes are imported where they are used
          # (nix-flatpak in app-store.nix, the GRUB theme in boot.nix).
          modules = [
            ./hosts/configuration.nix
            ./modules/default.nix
            ./lib/options.nix
          ];
        };
      } // nixpkgs.lib.optionalAttrs hasInstaller {
        Noid-OS-installer = import ./iso { inherit nixpkgs; };
      };

      packages = nixpkgs.lib.optionalAttrs hasInstaller {
        x86_64-linux.iso = self.nixosConfigurations.Noid-OS-installer.config.system.build.isoImage;
      };
    };
}
