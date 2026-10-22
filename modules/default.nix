{ config, pkgs, ... }:

{
  imports = [
    ./common/default.nix
    ./rare/default.nix
    ./legendary/default.nix
    ./flakes/default.nix
  ];
}
