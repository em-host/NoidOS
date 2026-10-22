{ lib, ... }:

# Helpers for writing modules with a simple on/off switch at `module.<name>.enable`.
#
#   mkModule        -> OFF unless switched on. Used by modules/rare and modules/legendary.
#   mkCommonModule  -> ON unless switched off. Used by modules/common.
#   enableByDefault -> just the option, for modules that define their own extra options.
{
  # mod.mkModule config lib "<name>" "<what it is>" { <settings when on> }
  mkModule = config: lib: name: description: extraConfig:
    let
      cfg = config.module.${name};
    in {
      options.module.${name}.enable = lib.mkEnableOption description;

      config = lib.mkIf cfg.enable extraConfig;
    };

  # An enable option that is true unless the user sets it to false.
  enableByDefault = description: lib.mkOption {
    type = lib.types.bool;
    default = true;
    example = false;
    description = "Whether to enable ${description}.";
  };

  # Same as mkModule, but on by default.
  mkCommonModule = config: lib: name: description: extraConfig:
    let
      cfg = config.module.${name};
    in {
      options.module.${name}.enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        example = false;
        description = "Whether to enable ${description}.";
      };

      config = lib.mkIf cfg.enable extraConfig;
    };
}
