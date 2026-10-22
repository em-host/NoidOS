{ config, lib, ... }:

{
  # Old name of myOS.flakeDir.
  imports = [
    (lib.mkAliasOptionModule [ "myOS" "rebuildButton" "flakeDir" ] [ "myOS" "flakeDir" ])
  ];

  options.myOS = {
    username = lib.mkOption {
      type = lib.types.str;
      description = "The username for the primary user";
    };

    fullName = lib.mkOption {
      type = lib.types.str;
      description = "The full name of the primary user";
    };

    flakeDir = lib.mkOption {
      type = lib.types.str;
      default = "${config.users.users.${config.myOS.username}.home}/NixOS";
      defaultText = lib.literalExpression ''"/home/<myOS.username>/NixOS"'';
      description = "The folder that contains flake.nix (this configuration).";
    };
  };
}
