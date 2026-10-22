{ mod, config, lib, pkgs, ... }:

let
  cfg = config.myOS.shares;
  user = config.myOS.username;
  account = config.users.users.${user};
  uid = toString (if account.uid != null then account.uid else 1000);
  gid = toString config.users.groups.${account.group}.gid;

  # "/mnt/work-share" -> "share-mnt-work-share"
  secretName = folder: "share" + lib.concatMapStrings
    (c: if builtins.match "[a-z0-9]" c != null then c else "-")
    (lib.stringToCharacters (lib.toLower folder));

  shareType = lib.types.submodule {
    options = {
      address = lib.mkOption {
        type = lib.types.strMatching "//[^[:space:]]+/[^[:space:]]+";
        example = "//nas.local/music"; # privacy-check: ok
        description = "The share, as //server/name (server name or IP address)."; # privacy-check: ok
      };
      guest = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "The share needs no login.";
      };
      options = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "vers=2.0" ];
        description = "Extra mount options, e.g. the SMB version an old server needs.";
      };
    };
  };
in
{
  options.module.shares.enable = mod.enableByDefault "network shares from myOS.shares (SMB)";

  options.myOS.shares = lib.mkOption {
    type = lib.types.attrsOf shareType;
    default = { };
    description = "Network shares to open at a folder, by folder. See modules/common/shares.nix.";
  };

  config = lib.mkIf (config.module.shares.enable && cfg != { }) {
    assertions = lib.mapAttrsToList (folder: _: {
      assertion = builtins.match "/[A-Za-z0-9._/-]+" folder != null;
      message = ''myOS.shares: "${folder}" must be a full folder path without spaces, e.g. /mnt/music.'';
    }) cfg;

    myOS.secrets = lib.mapAttrs' (folder: s: lib.nameValuePair (secretName folder) {
      description = "Login for the network share ${s.address} (${folder})";
      kind = "login";
    }) (lib.filterAttrs (_: s: !s.guest) cfg);

    fileSystems = lib.mapAttrs (folder: s: {
      device = s.address;
      fsType = "cifs";
      options = [
        "x-systemd.automount"
        "noauto"
        "x-systemd.idle-timeout=60"
        "x-systemd.device-timeout=5s"
        "x-systemd.mount-timeout=5s"
        "_netdev"
        "uid=${uid}"
        "gid=${gid}"
      ]
      ++ (if s.guest then [ "guest" ]
          else [ "credentials=${config.myOS.secrets.${secretName folder}.path}" ]) # privacy-check: ok (the file's name, not the login)
      ++ s.options;
    }) cfg;
  };
}
