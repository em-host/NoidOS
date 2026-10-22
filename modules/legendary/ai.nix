{ mod, config, lib, pkgs, inputs, ... }:

let
  cfg = config.module.ai;
  gpu = config.myOS.GPU;
  has = g: lib.elem g gpu;
  anyNvidia = has "nvidia" || has "nvidia-legacy";
  system = pkgs.stdenv.hostPlatform.system;
  user = config.myOS.username;
  assets = ./ai;

  chatDir = cfg.chatbot.dataDir;
  mediaDir = cfg.media.dataDir;
  underHome = dir: lib.hasPrefix "/home/" dir;

  # (No spaces: systemd's mount and folder settings would split the path there.)
  absolutePath = lib.types.strMatching "/[^[:space:]]+" // {
    description = "a full folder path (starting with /, without spaces)";
  };
  part = { description, default, extraOptions }: lib.mkOption {
    type = lib.types.coercedTo lib.types.bool (enable: { inherit enable; }) (lib.types.submodule {
      options = {
        enable = lib.mkOption {
          type = lib.types.bool;
          inherit default;
          inherit description;
        };
      } // extraOptions;
    });
    default = { };
    inherit description;
  };

  # First row whose minimum is met: "vram" = graphics memory in GiB, otherwise "ram".
  qwen38 = "huihui_ai/Qwen3.8-abliterated";
  qwen35 = "huihui_ai/qwen3.5-abliterated";
  modelSizes = [
    { vram = 22; model = "${qwen38}:27b"; }
    { vram = 15.5; model = "${qwen38}:27b-q3_K"; }
    { vram = 7.5; model = "${qwen35}:9b"; }
    { vram = 3.8; model = "${qwen35}:4B"; }
    { ram = 15; model = "${qwen35}:4B"; }
    { ram = 7.5; model = "${qwen35}:2B"; }
    { ram = 0; model = "${qwen35}:0.8B"; }
  ];
  alias = "assistant";

  # nixpkgs workaround (Oct 2026): open-webui passes "--set FRONTEND_BUILD_DIR <dir>" as one
  # makeWrapperArgs element, which __structuredAttrs no longer splits. Split it here; this
  # is a no-op once nixpkgs is fixed.
  openWebui =
    let pkg = pkgs.open-webui;
    in if lib.any (lib.hasInfix " ") (pkg.makeWrapperArgs or [ ]) then
      pkg.overridePythonAttrs (old: {
        makeWrapperArgs = lib.concatMap (lib.splitString " ") old.makeWrapperArgs;
      })
    else pkg;

  ollamaUrl = "http://127.0.0.1:${toString config.services.ollama.port}";
  webuiPort = config.services.open-webui.port;
  readerPort = 8099;
  comfyPort = 8188;

  ollamaFor =
    if anyNvidia then pkgs.ollama-vulkan # NVIDIA's CUDA build is never ready-made (unfree)
    else if has "amd" then pkgs.ollama-rocm
    else if has "intel" || has "intel-arc" then pkgs.ollama-vulkan
    else pkgs.ollama-cpu;

  systemPrompt = lib.concatStringsSep " " ([
    "You are the assistant on this computer, which runs Noid-OS, a NixOS configuration."
    "The person you are talking to may not be technical: answer plainly and step by step."
  ] ++ lib.optionals cfg.agentic [
    "The whole setup of this computer is described by its NixOS configuration, in the folder ${config.myOS.flakeDir}."
    "You can look at it with the tools list_files, read_file and search_files (read only: you cannot change anything)."
    "When asked about this computer, or when something does not work, look at the configuration before answering instead of guessing."
    "When a change is needed, say exactly which file and which lines to change and what to write,"
    "and that it takes effect after choosing Rebuild in the Nix Actions menu."
    "Computer-specific settings belong in hosts/users/user.nix."
  ]);

  readerUnit = "nixos-config-reader.service";
  chatUnits = [ "open-webui.service" "ollama.service" ] ++ lib.optional cfg.agentic readerUnit;

  mediaBackend =
    if cfg.mediaBackend != "auto" then cfg.mediaBackend
    else if has "nvidia" then "cuda" # (the CUDA build needs Turing or newer: not nvidia-legacy)
    else if has "amd" then "rocm"
    else if has "intel-arc" then "xpu"
    else "cpu";
  comfyPackages = (inputs.comfyui or (throw ''
    module.ai.media needs the flake input "comfyui" in flake.nix:
      comfyui.url = "github:utensils/comfyui-nix";'')).packages.${system};
  comfyPackage = {
    cpu = comfyPackages.default;
    inherit (comfyPackages) cuda rocm xpu;
  }.${mediaBackend};

  launcher = pkgs.writeScriptBin "ai-launcher" (
    builtins.replaceStrings
      [ "#!/usr/bin/env python3" "@zenity@" "@systemctl@" "@xdgOpen@" "@settings@" ]
      [
        "#!${pkgs.python3}/bin/python3"
        "${pkgs.zenity}/bin/zenity"
        "${config.systemd.package}/bin/systemctl"
        "${pkgs.xdg-utils}/bin/xdg-open"
        (builtins.toJSON {
          inherit ollamaUrl modelSizes alias gpu;
          webuiUrl = "http://127.0.0.1:${toString webuiPort}";
          comfyUrl = "http://127.0.0.1:${toString comfyPort}";
          startUnits = [ "open-webui.service" ];
          stopUnits = chatUnits;
          model = cfg.model;
        })
      ]
      (builtins.readFile (assets + "/launcher.py"))
  );

  chatItem = pkgs.makeDesktopItem {
    name = "ai-chat";
    desktopName = "AI Chat";
    genericName = "Chat with an AI that runs on this computer";
    comment = "A private chat assistant: nothing leaves this computer";
    exec = "${launcher}/bin/ai-launcher chat";
    icon = "internet-chat";
    terminal = false;
    categories = [ "Utility" ];
    keywords = [ "AI" "chat" "assistant" "LLM" "Ollama" "Qwen" ];
    actions.stop = {
      name = "Stop the AI (frees memory)";
      exec = "${launcher}/bin/ai-launcher chat-stop";
    };
  };

  mediaItem = pkgs.makeDesktopItem {
    name = "comfyui";
    desktopName = "ComfyUI";
    genericName = "Make pictures with AI";
    comment = "Image generation that runs on this computer";
    exec = "${launcher}/bin/ai-launcher media";
    icon = "applications-graphics";
    terminal = false;
    categories = [ "Graphics" ];
    keywords = [ "AI" "image" "Stable Diffusion" "Flux" "ComfyUI" ];
    actions.stop = {
      name = "Stop ComfyUI (frees memory)";
      exec = "${launcher}/bin/ai-launcher media-stop";
    };
  };
in
{
  options.module.ai = {
    enable = lib.mkEnableOption "local AI (Ollama; see chatbot, agentic, media and scripting)";

    dataDir = lib.mkOption {
      type = lib.types.nullOr absolutePath;
      default = null;
      example = "/mnt/storage/ai";
      description = ''
        A folder, usually on a bigger drive, for the AI models: the chat's in
        <dataDir>/ollama, ComfyUI's in <dataDir>/comfyui. null: the usual places.
        chatbot.dataDir and media.dataDir move one of them on its own.
      '';
    };

    chatbot = part {
      description = ''"AI Chat": Open WebUI in the browser, with a model sized for this computer.'';
      default = true;
      extraOptions.dataDir = lib.mkOption {
        type = lib.types.nullOr absolutePath;
        default = if cfg.dataDir != null then "${cfg.dataDir}/ollama" else null;
        defaultText = lib.literalExpression ''"''${module.ai.dataDir}/ollama", or null'';
        example = "/mnt/storage/ollama";
        description = "Where Ollama keeps the chat's models. null: /var/lib/ollama/models.";
      };
    };

    agentic = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Let the chat read (never change) this NixOS configuration (myOS.flakeDir).";
    };

    media = part {
      description = ''"ComfyUI": image generation, built for this computer's graphics card.'';
      default = false;
      extraOptions.dataDir = lib.mkOption {
        type = lib.types.nullOr absolutePath;
        default = if cfg.dataDir != null then "${cfg.dataDir}/comfyui" else null;
        defaultText = lib.literalExpression ''"''${module.ai.dataDir}/comfyui", or null'';
        example = "/mnt/storage/comfyui";
        description = ''
          ComfyUI's folder: models, pictures it made, workflows, custom nodes.
          null: ~/.config/comfy-ui.
        '';
      };
    };

    scripting = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Python with the ollama and playwright libraries (and its browsers), and statix.";
    };

    model = lib.mkOption {
      type = lib.types.str;
      default = "auto";
      example = "huihui_ai/Qwen3.8-abliterated:27b";
      description = ''
        The chat's model, as an ollama.com name. "auto": the biggest Qwen 3.8 or
        3.5 that fits this computer, picked when the chat starts (modelSizes in
        modules/legendary/ai.nix).
      '';
    };

    rocmGfx = lib.mkOption {
      type = lib.types.nullOr (lib.types.strMatching "[0-9]+\\.[0-9]+\\.[0-9]+");
      default = null;
      example = "11.0.2";
      description = ''
        AMD only: the ROCm GPU version Ollama reports, for cards ROCm does not
        support officially. null: use the card as it is.
      '';
    };

    mediaBackend = lib.mkOption {
      type = lib.types.enum [ "auto" "cpu" "cuda" "rocm" "xpu" ];
      default = "auto";
      description = ''Which ComfyUI build to use. "auto" goes by myOS.GPU.'';
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      assertions = [{
        assertion = cfg.agentic -> cfg.chatbot.enable;
        message = "module.ai.agentic gives the chat access to the configuration, so it needs module.ai.chatbot = true.";
      }];

      services.ollama = {
        enable = true;
        package = lib.mkDefault ollamaFor;
        rocmOverrideGfx = lib.mkIf (cfg.rocmGfx != null) cfg.rocmGfx;
        environmentVariables = {
          OLLAMA_NUM_PARALLEL = lib.mkDefault "1";
        } // lib.optionalAttrs (has "amd") {
          ROCR_VISIBLE_DEVICES = lib.mkDefault "0";
          HIP_VISIBLE_DEVICES = lib.mkDefault "0";
        } // lib.optionalAttrs (has "amd" && cfg.rocmGfx != null) {
          HCC_AMDGPU_TARGET = lib.mkDefault ("gfx" + lib.concatStrings (lib.splitString "." cfg.rocmGfx));
        };
      };
      # Not at boot: it holds on to memory while it runs. "AI Chat" starts it.
      systemd.services.ollama.wantedBy = lib.mkForce [ ];
    }

    # Ollama's DynamicUser cannot own a folder outside /var/lib: use a static user instead.
    (lib.mkIf (chatDir != null) {
      services.ollama = {
        user = "ollama";
        modelsDir = chatDir;
      };
      systemd.tmpfiles.settings."10-noid-ai".${chatDir}.d = {
        user = "ollama";
        group = "ollama";
        mode = "0750";
      };
      systemd.services.ollama = {
        unitConfig.RequiresMountsFor = [ chatDir ];
        # ProtectHome hides /home: show an empty one with only this folder bound in.
        serviceConfig = lib.mkIf (underHome chatDir) {
          ProtectHome = lib.mkForce "tmpfs";
          BindPaths = [ chatDir ];
          ReadWritePaths = lib.mkForce [ config.services.ollama.home ];
        };
      };
    })

    (lib.mkIf cfg.chatbot.enable {
      services.open-webui = {
        enable = true;
        package = lib.mkDefault openWebui;
        port = lib.mkDefault 8080;
        environment = {
          SCARF_NO_ANALYTICS = "True";
          DO_NOT_TRACK = "True";
          ANONYMIZED_TELEMETRY = "False";
          ENABLE_VERSION_UPDATE_CHECK = "False";
          WEBUI_AUTH = "False";
          OLLAMA_BASE_URL = ollamaUrl;
          ENABLE_OLLAMA_API = "True";
          ENABLE_OPENAI_API = "False";
          # Settings below win on every start over ones saved from the admin page.
          ENABLE_PERSISTENT_CONFIG = "False";
          DEFAULT_MODELS = "${alias}:latest";
          DEFAULT_MODEL_PARAMS = builtins.toJSON {
            system = systemPrompt;
            num_ctx = 16384;
          };
        } // lib.optionalAttrs cfg.agentic {
          TOOL_SERVER_CONNECTIONS = builtins.toJSON [{
            type = "openapi";
            url = "http://127.0.0.1:${toString readerPort}";
            path = "/openapi.json";
            auth_type = "none";
            key = "";
            config.enable = true;
            info = {
              id = "nixos-config";
              name = "NixOS configuration";
              description = "Read the files of this computer's NixOS configuration (read only).";
            };
          }];
          DEFAULT_MODEL_METADATA = builtins.toJSON { toolIds = [ "server:nixos-config" ]; };
        };
      };

      systemd.services.open-webui = {
        wantedBy = lib.mkForce [ ];
        wants = [ "ollama.service" ] ++ lib.optional cfg.agentic readerUnit;
        after = [ "ollama.service" ] ++ lib.optional cfg.agentic readerUnit;
      };

      security.polkit.extraConfig = ''
        polkit.addRule(function (action, subject) {
          if (action.id == "org.freedesktop.systemd1.manage-units" &&
              subject.user == ${builtins.toJSON user} &&
              ${builtins.toJSON chatUnits}.indexOf(action.lookup("unit")) >= 0 &&
              ["start", "stop", "restart"].indexOf(action.lookup("verb")) >= 0) {
            return polkit.Result.YES;
          }
        });
      '';

      environment.systemPackages = [ launcher chatItem ];
    })

    (lib.mkIf (cfg.chatbot.enable && cfg.agentic) {
      systemd.services.nixos-config-reader = {
        description = "Read-only view of the NixOS configuration for AI Chat";
        serviceConfig = {
          ExecStart = lib.escapeShellArgs [
            "${pkgs.python3}/bin/python3" "${assets + "/config-reader.py"}"
            "--root" config.myOS.flakeDir "--port" (toString readerPort)
          ];
          # Runs as the user (only they can read their home), sandboxed to the read-only flake folder.
          User = user;
          Group = config.users.users.${user}.group;
          ProtectHome = "tmpfs";
          BindReadOnlyPaths = [ "-${config.myOS.flakeDir}" ];
          ProtectSystem = "strict";
          PrivateTmp = true;
          PrivateDevices = true;
          NoNewPrivileges = true;
          CapabilityBoundingSet = "";
          RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
          IPAddressDeny = "any";
          IPAddressAllow = "localhost";
          ProtectKernelTunables = true;
          ProtectKernelModules = true;
          ProtectKernelLogs = true;
          ProtectControlGroups = true;
          ProtectClock = true;
          ProtectHostname = true;
          RestrictNamespaces = true;
          RestrictRealtime = true;
          RestrictSUIDSGID = true;
          LockPersonality = true;
          SystemCallArchitectures = "native";
          SystemCallFilter = [ "@system-service" "~@privileged" ];
        };
      };
    })

    (lib.mkIf cfg.media.enable {
      systemd.user.services.comfyui = {
        description = "ComfyUI (image generation)";
        # ROCm: the flake ships xformers (CUDA-only kernels) and ComfyUI picks it, failing with
        # "No operator found for memory_efficient_attention_forward"; use PyTorch attention.
        # rocminfo lets ComfyUI detect the GPU architecture.
        path = lib.optional (mediaBackend == "rocm") pkgs.rocmPackages.rocminfo;
        serviceConfig = {
          ExecStart = lib.escapeShellArgs ([ "${comfyPackage}/bin/comfy-ui" "--port" (toString comfyPort) ]
            ++ lib.optionals (mediaDir != null) [ "--base-directory" mediaDir ]
            ++ lib.optional (mediaBackend == "rocm") "--use-pytorch-cross-attention");
          Restart = "no";
        };
      };

      systemd.tmpfiles.settings."10-noid-ai" = lib.mkIf (mediaDir != null) {
        ${mediaDir}.d = {
          inherit user;
          group = config.users.users.${user}.group;
          mode = "0750";
        };
      };

      nix.settings = {
        extra-substituters = [
          "https://comfyui.cachix.org"
          "https://nix-community.cachix.org"
        ] ++ lib.optional (mediaBackend == "cuda") "https://cache.nixos-cuda.org";
        extra-trusted-public-keys = [
          "comfyui.cachix.org-1:33mf9VzoIjzVbp0zwj+fT51HG0y31ZTK3nzYZAX0rec="
          "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
        ] ++ lib.optional (mediaBackend == "cuda") "cache.nixos-cuda.org:74DUi4Ye579gUqzH4ziL9IyiJBlDpMRn9MBN8oNan9M=";
      };

      environment.systemPackages = [ comfyPackage launcher mediaItem ];
    })

    (lib.mkIf cfg.scripting {
      environment.systemPackages = with pkgs; [
        (python3.withPackages (ps: with ps; [
          pydantic
          ollama
          playwright
        ]))
        playwright-driver.browsers
        statix
      ];

      environment.variables = {
        PLAYWRIGHT_BROWSERS_PATH = "${pkgs.playwright-driver.browsers}";
        PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS = "true";
      };
    })
  ]);
}
