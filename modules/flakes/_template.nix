# Copy into hosts/flakes/<name>.nix (files starting with "_" are ignored), then Rebuild.
{
  url = "github:owner/repository";

  packages = [ "default" ];

  # overlays = [ "default" ];

  # modules = [ "default" ];

  # Binary cache of the flake's author; only add one you trust.
  # cache = {
  #   substituters = [ "https://example.cachix.org" ];
  #   keys = [ "example.cachix.org-1:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" ];
  # };

  # A set, or a function taking { pkgs, ... }.
  # config = { };
}
