{ mod, config, lib, pkgs, inputs, ... }@args:

let
  cfg = config.module.flakes;
  flakeLib = mod.flakes;

  dirs = [ ./. ../../hosts/flakes ];
  found = flakeLib.specs dirs;

  system = pkgs.stdenv.hostPlatform.system;

  registry = inputs.flakes or (throw ''
    flake.nix has no "flakes" input.
    It needs:  flakes.url = "path:./hosts/flakes/registry";
    (see modules/flakes/default.nix)'');

  flakeOf = name:
    registry.inputs.${name} or (throw ''
      The flake "${name}" has not been registered yet.
      Open Nix Actions and choose Rebuild (or run "nixos-flakes sync") and try again.'');

  pick = name: spec: what: offered: wanted:
    map
      (n:
        offered.${n} or (throw ''
          The flake "${name}" has no ${what} called "${n}".
          It offers: ${
            if offered == { } then "nothing of that kind"
            else lib.concatStringsSep ", " (lib.attrNames offered)
          }
          Fix the list in ${flakeLib.show spec.file}''))
      wanted;

  programsOf = name: spec:
    pick name spec "program" ((flakeOf name).packages.${system} or { }) spec.packages;
  overlaysOf = name: spec:
    pick name spec "overlay" ((flakeOf name).overlays or { }) spec.overlays;
  modulesOf = name: spec:
    pick name spec "NixOS module" ((flakeOf name).nixosModules or { }) spec.modules;

  escape = lib.escape [ "\\" "\"" ];

  nixosFlakes = pkgs.writeScriptBin "nixos-flakes" (
    builtins.replaceStrings
      [ "#!/usr/bin/env python3" "@nix@" "@git@" "@zenity@" "@flakeDir@" ]
      [
        "#!${pkgs.python3}/bin/python3"
        "${config.nix.package}/bin/nix"
        "${pkgs.git}/bin/git"
        "${pkgs.zenity}/bin/zenity"
        (escape config.myOS.flakeDir)
      ]
      (builtins.readFile ./nixos-flakes.py)
  );

  ownLauncher = !(config.module.nix-actions.enable or false);

  launcher = pkgs.makeDesktopItem {
    name = "nixos-add-flake";
    desktopName = "Add a Flake";
    genericName = "Add programs and settings from a link";
    comment = "Paste the link of a flake and add it to this computer";
    exec = "${nixosFlakes}/bin/nixos-flakes gui";
    icon = "list-add";
    terminal = false;
    categories = [ "System" "Settings" "PackageManager" ];
    keywords = [ "flake" "nix" "install" "add" "program" ];
  };
in
{
  imports =
    flakeLib.moduleFiles dirs
    ++ lib.concatLists (lib.mapAttrsToList modulesOf found);

  options.module.flakes =
    {
      enable = mod.enableByDefault
        "flakes (programs and settings added from a link) and the \"Add a Flake\" app";

      package = lib.mkOption {
        type = lib.types.nullOr lib.types.package;
        default = null;
        internal = true;
        description = "The nixos-flakes command (Nix Actions runs it).";
      };
    }
    // lib.mapAttrs
      (name: spec: {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Whether to use the flake \"${name}\" (${flakeLib.show spec.file}).";
        };
      })
      found;

  config = lib.mkIf cfg.enable (lib.mkMerge (
    [
      {
        environment.systemPackages = [ nixosFlakes ] ++ lib.optional ownLauncher launcher;
        module.flakes.package = nixosFlakes;
      }
    ]
    ++ lib.mapAttrsToList
      (name: spec:
        lib.mkIf cfg.${name}.enable (lib.mkMerge [
          { environment.systemPackages = programsOf name spec; }
          { nixpkgs.overlays = overlaysOf name spec; }
          (lib.mkIf (spec.cache != null) {
            # "extra-" adds to the default (cache.nixos.org) instead of replacing it.
            nix.settings = {
              extra-substituters = spec.cache.substituters;
              extra-trusted-public-keys = spec.cache.keys;
            };
          })
          (if builtins.isFunction spec.config then spec.config args else spec.config)
        ]))
      found
  ));
}
