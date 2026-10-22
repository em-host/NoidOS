{ mod, config, lib, pkgs, ... }:

# These copy a secret into the world-readable /nix/store:
#   password = "hunter2";            builtins.readFile ./secret     (privacy-check: ok)
#   passwordFile = ./secret;         (a path without quotes)
# A quoted path string is fine.
let
  cfg = config.myOS.secrets;
  dir = "/var/lib/noid-secrets";

  secretType = lib.types.submodule ({ name, ... }: {
    options = {
      description = lib.mkOption {
        type = lib.types.str;
        example = "Password of the music server";
        description = "What it is, in words. Shown in Nix Actions -> Passwords.";
      };
      kind = lib.mkOption {
        type = lib.types.enum [ "password" "login" "text" ];
        default = "password";
        description = ''
          "password": one line. "login": user name, password and an optional domain,
          as username=/password=/domain= lines (what network shares read). "text": anything.
        '';
      };
      owner = lib.mkOption {
        type = lib.types.str;
        default = "root";
        description = "The user that may read it.";
      };
      group = lib.mkOption {
        type = lib.types.str;
        default = "root";
        description = "The group that may read it (with mode 0440).";
      };
      mode = lib.mkOption {
        type = lib.types.strMatching "0[0-7]{3}";
        default = "0400";
        description = "File permissions. 0400: only the owner may read it.";
      };
      path = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        default = "${dir}/${name}";
        defaultText = lib.literalExpression ''"${dir}/<name>"'';
        description = "Where the secret is. Hand this to the program that needs it.";
      };
    };
  });

  manifest = lib.mapAttrs (_: s: { inherit (s) description kind owner group mode path; }) cfg;
in
{
  options.module.secrets.enable = mod.enableByDefault "secrets kept outside the configuration (Nix Actions -> Passwords)";

  options.myOS.secrets = lib.mkOption {
    type = lib.types.attrsOf secretType;
    default = { };
    description = "Secrets this computer needs, by name. See modules/common/secrets.nix.";
  };

  options.module.secrets.manifest = lib.mkOption {
    type = lib.types.attrs;
    internal = true;
    readOnly = true;
    default = manifest;
    description = "The secrets' names, kinds and owners, for Nix Actions -> Passwords.";
  };

  config = lib.mkIf config.module.secrets.enable {
    assertions = lib.mapAttrsToList (name: _: {
      assertion = builtins.match "[a-z0-9][a-z0-9_-]*" name != null;
      message = ''myOS.secrets: "${name}" cannot be a secret's name. Use lowercase letters, numbers, - and _.'';
    }) cfg;

    # 0711: owners can reach their own secret but not list the folder.
    systemd.tmpfiles.settings."10-noid-secrets" = {
      ${dir}.d = { user = "root"; group = "root"; mode = "0711"; };
    } // lib.mapAttrs' (_: s: lib.nameValuePair s.path {
      # "z" only fixes existing files, never creates empty secrets.
      z = { user = s.owner; group = s.group; inherit (s) mode; };
    }) cfg;

    system.activationScripts.noid-secrets = lib.mkIf (cfg != { }) {
      deps = [ "users" "groups" ];
      text = ''
        missing=()
        ${lib.concatMapStrings (s: ''
          [ -s ${lib.escapeShellArg s.path} ] || missing+=(${lib.escapeShellArg s.description})
        '') (lib.attrValues cfg)}
        if [ "''${#missing[@]}" -gt 0 ]; then
          echo "These passwords have not been typed in yet:" >&2
          printf '  - %s\n' "''${missing[@]}" >&2
          echo "Open Nix Actions and choose Passwords." >&2
        fi
      '';
    };
  };
}
