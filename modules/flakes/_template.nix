# ---------------------------------------------------------------------------
# ADD A FLAKE BY HAND  ("Add a Flake" in the Nix Actions menu does all of this
# for you: you only paste the link)
#
# A "flake" is a program, or a set of settings, that somebody publishes online.
# To use one:
#
#   1. Copy this file into the folder  hosts/flakes/  (that is for this
#      computer only). Name the copy after the flake, for example
#      zen-browser.nix: lowercase letters, numbers and dashes. The part before
#      ".nix" is the flake's name.
#   2. Fill in the link below, and list what you want from the flake.
#   3. Open Nix Actions and choose Rebuild. That is all.
#
# To remove it again, delete the file (or set module.flakes.<name>.enable =
# false in hosts/users/user.nix to switch it off but keep the file).
#
# Files that start with an underscore, like this one, are ignored.
# ---------------------------------------------------------------------------
{
  # The link of the flake. Usually "github:owner/repository".
  url = "github:owner/repository";

  # Programs to install. The flake's page lists them as "packages"; most
  # flakes have one called "default".
  packages = [ "default" ];

  # --- Less common. Remove the "#" in front of a line to use it. -----------

  # Overlays: change or add programs in the system's package list.
  # overlays = [ "default" ];

  # NixOS modules: extra settings the flake adds to NixOS (they come with
  # their own on/off switches, which you set in hosts/users/user.nix).
  # modules = [ "default" ];

  # A download server run by the flake's author, so big programs arrive
  # ready-made instead of being built on your computer. Only add one from an
  # author you trust; the flake's page usually shows these two lines.
  # cache = {
  #   substituters = [ "https://example.cachix.org" ];
  #   keys = [ "example.cachix.org-1:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" ];
  # };

  # Anything else NixOS should do when this flake is on. Either a set:
  #   config = { services.something.enable = true; };
  # or a function, if it needs the package set:
  #   config = { pkgs, ... }: { environment.systemPackages = [ pkgs.vim ]; };
  # config = { };
}
