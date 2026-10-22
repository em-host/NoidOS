# builtins only (no nixpkgs lib): nixos-flakes loads this file with a plain `nix eval`.
let
  inherit (builtins)
    all
    attrNames
    concatLists
    concatStringsSep
    elem
    filter
    foldl'
    isAttrs
    isFunction
    isList
    isString
    length
    listToAttrs
    map
    mapAttrs
    match
    pathExists
    readDir
    stringLength
    substring
    toJSON
    ;

  settings = [ "url" "packages" "overlays" "modules" "cache" "config" ];

  reserved = [ "enable" "package" "nixpkgs" "self" ];

  # /nix/store/<hash>-source/hosts/flakes/x.nix -> hosts/flakes/x.nix
  show = file:
    let
      s = toString file;
      m = match "/nix/store/[^/]*-source/(.*)" s;
    in
    if m == null then s else builtins.head m;

  startsWith = prefix: s: substring 0 (stringLength prefix) s == prefix;
  hasSuffix = suffix: s:
    let
      n = stringLength s;
      m = stringLength suffix;
    in
    n >= m && substring (n - m) m s == suffix;
  removeSuffix = suffix: s:
    if hasSuffix suffix s then substring 0 (stringLength s - stringLength suffix) s else s;

  ignored = name: name == "default.nix" || startsWith "_" name || !(hasSuffix ".nix" name);

  safe = ''[^[:space:]"\\$]+'';

  # A plain set with `url` is a flake file; anything else is imported as a NixOS module.
  scanDir = dir:
    if !(pathExists dir) then
      { specs = { }; modules = [ ]; }
    else
      let
        entries = readDir dir;
        files = filter
          (n: (entries.${n} == "regular" || entries.${n} == "symlink") && !(ignored n))
          (attrNames entries);
        loaded = map (n: { name = n; path = dir + "/${n}"; value = import (dir + "/${n}"); }) files;
        isSpec = f: isAttrs f.value && f.value ? url;
      in
      {
        specs = listToAttrs (map
          (f: { name = removeSuffix ".nix" f.name; value = { file = f.path; raw = f.value; }; })
          (filter isSpec loaded));
        modules = map (f: f.path) (filter (f: !(isSpec f)) loaded);
      };

  normalize = name: file: raw:
    let
      problem = msg: throw "\n\nThere is a problem in ${show file}:\n  ${msg}\n";

      listOf = key:
        let v = raw.${key} or [ ];
        in
        if isList v && all isString v then v
        else problem "\"${key}\" must be a list of names in quotes, like [ \"default\" ].";

      unknown = filter (k: !(elem k settings)) (attrNames raw);

      cache = raw.cache or null;
      cacheOk = c:
        isAttrs c
        && attrNames c == [ "keys" "substituters" ]
        && isList c.substituters && c.substituters != [ ]
        && all (u: isString u && match "https?://${safe}" u != null) c.substituters
        && isList c.keys && c.keys != [ ]
        && all (k: isString k && match "[^[:space:]\"\\\\$:]+:${safe}" k != null) c.keys;

      config = raw.config or { };
    in
    if match "[a-z][a-z0-9-]*" name == null then
      throw ''
        "${name}.nix" can't be used as the name of a flake (${show file}).
          Use lowercase letters, numbers and dashes, starting with a letter,
          for example "zen-browser.nix".
      ''
    else if elem name reserved then
      throw ''
        "${name}" is not allowed as the name of a flake (${show file}).
          Rename the file to something else.
      ''
    else if unknown != [ ] then
      problem ''
        unknown setting${if length unknown > 1 then "s" else ""}: ${concatStringsSep ", " unknown}
          A flake file may only contain: ${concatStringsSep ", " settings}.''
    else if !(isString raw.url && match safe raw.url != null) then
      problem "\"url\" must be the flake's link in quotes, like \"github:owner/repository\"."
    else if !(cache == null || cacheOk cache) then
      problem ''
        "cache" must look like this:
            cache = {
              substituters = [ "https://example.cachix.org" ];
              keys = [ "example.cachix.org-1:AAAA..." ];
            };''
    else if !(isAttrs config || isFunction config) then
      problem "\"config\" must be a set of NixOS settings (or a function that returns one)."
    else
      {
        inherit name file cache config;
        url = raw.url;
        packages = listOf "packages";
        overlays = listOf "overlays";
        modules = listOf "modules";
      };

  specs = dirs:
    let
      add = acc: found:
        foldl'
          (acc': name:
            if acc' ? ${name} then
              throw ''
                The flake "${name}" is defined twice:
                  ${show acc'.${name}.file}
                  ${show found.${name}.file}
                Delete or rename one of them.
              ''
            else
              acc' // { ${name} = found.${name}; })
          acc
          (attrNames found);
      everything = foldl' add { } (map (d: (scanDir d).specs) dirs);
    in
    mapAttrs (name: s: normalize name s.file s.raw) everything;

  moduleFiles = dirs: concatLists (map (d: (scanDir d).modules) dirs);

  registryText = found:
    concatStringsSep "\n" (
      [
        "# GENERATED by the nixos-flakes command. Do not edit this file: it is"
        "# rewritten from the flake files next to it whenever something changes."
        "{"
        "  description = \"Flakes added to this computer\";"
        ""
        "  inputs = {"
      ]
      ++ map (name: "    ${name}.url = ${toJSON found.${name}.url};") (attrNames found)
      ++ [
        "  };"
        ""
        "  outputs = _: { };"
        "}"
        ""
      ]
    );

  describe = found:
    mapAttrs
      (_: s: {
        inherit (s) url packages overlays modules cache;
        file = toString s.file;
        hasConfig = s.config != { };
      })
      found;
in
{
  inherit specs moduleFiles registryText describe show;

  forTool = dirs:
    let found = specs dirs;
    in { specs = describe found; registry = registryText found; };
}
