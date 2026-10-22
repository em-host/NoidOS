{ mod, config, lib, pkgs, ... }:

# ---------------------------------------------------------------------------
# Secrets: the passwords and logins this computer needs, kept out of the
# configuration.
#
# A secret (a network share's login, a service's password, an API key) must
# never be written into a .nix file. Everything in this folder can end up in
# other people's hands (a copy of the folder, the install ISO), and everything
# Nix builds lands in /nix/store, which every user of the computer can read.
#
# So a secret lives in its own file in /var/lib/noid-secrets, readable only by
# root (or by the one program it is meant for), and is typed in once on this
# computer: Nix Actions -> Passwords. The configuration only says that the secret
# exists and points programs to its file:
#
#   myOS.secrets.music-server = {
#     description = "Password of the music server";
#     owner = "navidrome";                        # who may read it (root if left out)
#   };
#   services.something.passwordFile = config.myOS.secrets.music-server.path;
#
# Kinds: "password" (one line), "login" (user name, password and an optional
# domain, written the way network shares expect them), "text" (anything).
#
# Never do any of these with a secret, they all copy it into /nix/store:
#   password = "hunter2";            builtins.readFile ./secret     (privacy-check: ok)
#   passwordFile = ./secret;         (a path without quotes)
# A path IN QUOTES ("/var/lib/noid-secrets/x") is fine: that is only its name.
#
# Missing secrets are listed at the end of every rebuild. Network shares
# (modules/common/shares.nix) ask for theirs by themselves.
# ---------------------------------------------------------------------------
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

  # What Nix Actions -> Passwords needs to know (never the secrets themselves).
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

    # The folder: root's. Others may reach a file in it they are allowed to read,
    # but cannot list what is there.
    systemd.tmpfiles.settings."10-noid-secrets" = {
      ${dir}.d = { user = "root"; group = "root"; mode = "0711"; };
    } // lib.mapAttrs' (_: s: lib.nameValuePair s.path {
      # Fix the owner and permissions of a secret that is there (never creates it).
      z = { user = s.owner; group = s.group; inherit (s) mode; };
    }) cfg;

    # At the end of every rebuild: which secrets still have to be typed in.
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
