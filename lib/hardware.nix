{ lib, ... }:

# Picks NixOS-Hardware profiles by name, for a host's `imports`:
#
#   imports = mod.hardware inputs [ "framework-16-7040-amd" ];
#
# Names are the ones in https://github.com/NixOS/nixos-hardware (see its flake.nix).
{
  hardware = inputs: names:
    map (name:
      inputs.nixos-hardware.nixosModules.${name} or (throw ''
        There is no NixOS-Hardware profile called "${name}".
        Check the exact name in https://github.com/NixOS/nixos-hardware/blob/master/flake.nix
        (or use an empty list: imports = mod.hardware inputs [ ];)'')
    ) names;
}
