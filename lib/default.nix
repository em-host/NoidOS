{ lib, ... }:
(import ./hot-swap.nix { inherit lib; })
// (import ./hardware.nix { inherit lib; })
// {
  flakes = import ./flakes.nix;

  # Every .nix file in a folder except default.nix:  { mod, ... }: { imports = mod.importDir ./.; }
  importDir = dir:
    map (name: dir + "/${name}") (lib.attrNames (lib.filterAttrs
      (name: type: type == "regular" && name != "default.nix" && lib.hasSuffix ".nix" name)
      (builtins.readDir dir)));
}
