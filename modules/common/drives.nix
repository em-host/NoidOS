{ mod, config, lib, pkgs, utils, ... }:

let
  cfg = config.myOS.drives;
  file = ../../hosts/drives.nix;
  fromFile = if builtins.pathExists file then import file else { };

  user = config.myOS.username;
  account = config.users.users.${user};
  uid = toString (if account.uid != null then account.uid else 1000);
  gid = toString config.users.groups.${account.group}.gid;

  linuxTypes = [ "ext4" "ext3" "ext2" "btrfs" "xfs" "f2fs" ];

  windowsOptions = [ "uid=${uid}" "gid=${gid}" "umask=022" ];

  mountOptions = d:
    [
      "nofail"
      "x-systemd.device-timeout=10s"
    ]
    ++ lib.optionals (lib.elem d.fsType [ "ntfs" "ntfs3" "exfat" "vfat" ]) windowsOptions
    ++ d.options;

  fsTypeOf = t: if t == "ntfs" then "ntfs3" else t; # the kernel's own NTFS driver

  linuxDrives = lib.filterAttrs (_: d: lib.elem d.fsType linuxTypes) cfg;

  driveType = lib.types.submodule {
    options = {
      uuid = lib.mkOption {
        type = lib.types.strMatching "[A-Za-z0-9-]+";
        description = "The file system's UUID (lsblk -f).";
      };
      fsType = lib.mkOption {
        type = lib.types.str;
        example = "ext4";
        description = "The file system (lsblk -f): ext4, btrfs, xfs, f2fs, ntfs, exfat, vfat.";
      };
      label = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "What the drive is called. Only a note for people.";
      };
      options = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Extra mount options.";
      };
      apps = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Flatpak apps can be installed on this drive (Linux file systems only).";
      };
    };
  };
in
{
  options.module.drives.enable = mod.enableByDefault "extra drives from hosts/drives.nix (Nix Actions -> Drives)";

  options.myOS.drives = lib.mkOption {
    type = lib.types.attrsOf driveType;
    default = { };
    example = { "/mnt/games" = { uuid = "0b410126-3795-4a6c-b513-b9e04b87d5a2"; fsType = "ext4"; }; };
    description = "Drives to open at a folder every time the computer starts, by folder.";
  };

  config = lib.mkIf config.module.drives.enable {
    myOS.drives = fromFile;

    fileSystems = lib.mapAttrs (_: d: {
      device = "/dev/disk/by-uuid/${d.uuid}";
      fsType = fsTypeOf d.fsType;
      options = mountOptions d;
    }) cfg;

    # Hand a root-owned top folder of a Linux file system to the user, once.
    systemd.services = lib.mapAttrs' (folder: _:
      let mountUnit = "${utils.escapeSystemdPath folder}.mount";
      in lib.nameValuePair "drive-owner-${utils.escapeSystemdPath folder}" {
        description = "Give ${folder} to ${user}";
        wantedBy = [ "multi-user.target" ];
        after = [ mountUnit ];
        unitConfig.ConditionPathIsMountPoint = folder;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          if [ "$(${pkgs.coreutils}/bin/stat -c %u ${lib.escapeShellArg folder})" = 0 ]; then
            ${pkgs.coreutils}/bin/chown ${lib.escapeShellArg "${user}:${account.group}"} ${lib.escapeShellArg folder}
          fi
        '';
      }) linuxDrives;
  };
}
