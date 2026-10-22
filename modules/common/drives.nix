{ mod, config, lib, pkgs, utils, ... }:

# ---------------------------------------------------------------------------
# Drives: more disks, opened at a fixed folder every time the computer starts.
#
# EASIEST  Nix Actions -> Drives. It lists the drives this computer does not use
#          yet, asks for a folder (e.g. /mnt/games), writes hosts/drives.nix and
#          rebuilds. The same place removes one again.
#
# BY HAND  hosts/drives.nix (or myOS.drives in hosts/users/user.nix):
#
#            { "/mnt/games" = { uuid = "1234-ABCD..."; fsType = "ext4"; label = "Games"; }; }
#
#          The UUID and type are shown by  lsblk -f
#
# A drive that is missing (unplugged, broken) does not stop the computer from
# starting; it is simply not there. Linux drives (ext4, btrfs, xfs, f2fs) are
# given to you the first time, so you can write to them without sudo; Windows and
# USB-stick drives (NTFS, exFAT, FAT) open as yours anyway.
#
# Not hardware-configuration.nix on purpose: that file comes from the hardware
# scan, and scanning again would also write down whatever happened to be plugged
# in at the time.
# ---------------------------------------------------------------------------
let
  cfg = config.myOS.drives;
  file = ../../hosts/drives.nix;
  fromFile = if builtins.pathExists file then import file else { };

  user = config.myOS.username;
  account = config.users.users.${user};
  uid = toString (if account.uid != null then account.uid else 1000);
  gid = toString config.users.groups.${account.group}.gid;

  linuxTypes = [ "ext4" "ext3" "ext2" "btrfs" "xfs" "f2fs" ];

  # Windows' and USB sticks' file systems have no owners of their own: say who
  # owns everything on them.
  windowsOptions = [ "uid=${uid}" "gid=${gid}" "umask=022" ];

  mountOptions = d:
    [
      "nofail" # missing drive: start anyway
      "x-systemd.device-timeout=10s" # and do not wait long for it
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

    # A new Linux drive's top folder belongs to root. Hand it over once; a folder
    # that already belongs to someone is left alone.
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
