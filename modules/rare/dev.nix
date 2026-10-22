{ mod, pkgs, config, lib, ... }:

mod.mkModule config lib "dev" "Development suite" {

  environment.systemPackages = with pkgs; [
    git vim wget curl gcc gnumake
    python3 nodejs
  ];

  services.getty.helpLine = "Happy Hacking!";
  programs.direnv.enable = true;
}
