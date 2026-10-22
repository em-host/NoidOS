{ lib, ... }:
{
  # mod.mkModule config lib "<name>" "<what it is>" { <settings when on> }
  mkModule = config: lib: name: description: extraConfig:
    let
      cfg = config.module.${name};
    in {
      options.module.${name}.enable = lib.mkEnableOption description;

      config = lib.mkIf cfg.enable extraConfig;
    };

  enableByDefault = description: lib.mkOption {
    type = lib.types.bool;
    default = true;
    example = false;
    description = "Whether to enable ${description}.";
  };

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
