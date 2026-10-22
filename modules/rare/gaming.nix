{ mod, pkgs, config, lib, ... }:

mod.mkModule config lib "gaming" "Gaming Suite (Steam, Gamemode, Nero)" {

  programs.steam = {
    enable = true;
    extraPackages = with pkgs; [
      steamtinkerlaunch
    ];
    # Extra choices under Properties -> Compatibility in Steam. GE-Proton fixes
    # many games that plain Proton does not run, and comes with the system, so
    # nothing has to be downloaded by hand.
    extraCompatPackages = with pkgs; [
      steamtinkerlaunch
      proton-ge-bin
    ];
    gamescopeSession.enable = true;
    protontricks.enable = true;
  };

  programs.gamemode = {
    enable = true;
    settings = {
      general = {
        renice = 10;
      };
      custom = {
        start = "${pkgs.libnotify}/bin/notify-send 'GameMode Started'";
        end = "${pkgs.libnotify}/bin/notify-send 'GameMode Ended'";
      };
    };
  };

  environment.systemPackages = with pkgs; [
    mangohud
    protonup-qt
    umu-launcher
    nero-umu
    gamescope-wsi
    prismlauncher
  ];

  # (Steam finds Proton versions installed with ProtonUp-Qt in
  # ~/.steam/root/compatibilitytools.d by itself.)
}
