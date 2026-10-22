{ mod, ... }:

# Imports every .nix file in this folder (see importDir in lib/default.nix).
{
  imports = mod.importDir ./.;
}
