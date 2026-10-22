{ lib, ... }:

# Everything modules reach through the `mod` argument.
(import ./hot-swap.nix { inherit lib; })
// (import ./hardware.nix { inherit lib; })
// {
  flakes = import ./flakes.nix;

  # Every .nix file in a folder except default.nix, for a folder's `imports`:
  #
  #   { mod, ... }: { imports = mod.importDir ./.; }
  #
  # (Adding a module is dropping a file into the folder.)
  importDir = dir:
    map (name: dir + "/${name}") (lib.attrNames (lib.filterAttrs
      (name: type: type == "regular" && name != "default.nix" && lib.hasSuffix ".nix" name)
      (builtins.readDir dir)));
}
