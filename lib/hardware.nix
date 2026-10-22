{ lib, ... }:
{
  hardware = inputs: names:
    map (name:
      inputs.nixos-hardware.nixosModules.${name} or (throw ''
        There is no NixOS-Hardware profile called "${name}".
        Check the exact name in https://github.com/NixOS/nixos-hardware/blob/master/flake.nix
        (or use an empty list: imports = mod.hardware inputs [ ];)'')
    ) names;
}
