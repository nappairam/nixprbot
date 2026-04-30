flake: { config, lib, pkgs, ... }:

let
  cfg = config.services.nixprbot;
  pkg = flake.packages.${pkgs.system}.nixprbot;
in
{
  options.services.nixprbot = {
    enable = lib.mkEnableOption "nixpkgs PR Telegram tracker bot";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkg;
      description = "The nixprbot package to run.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "nixprbot";
      description = "User the service runs as.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "nixprbot";
      description = "Group the service runs as.";
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/nixprbot";
      description = "Where the SQLite database lives.";
    };

    repo = lib.mkOption {
      type = lib.types.str;
      default = "NixOS/nixpkgs";
      description = "owner/repo to track.";
    };

    pollIntervalSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 900;
      description = "How often to poll GitHub for tracked PR status.";
    };

    branches = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "staging-next"
        "master"
        "nixpkgs-unstable"
        "nixos-unstable-small"
        "nixos-unstable"
      ];
      description = "Channel branches to check for PR propagation, in display order.";
    };

    environmentFile = lib.mkOption {
      type = lib.types.path;
      description = ''
        Path to a file containing NIXPRBOT_TOKEN=... and optionally
        NIXPRBOT_GITHUB_TOKEN=... — read by systemd via EnvironmentFile so
        secrets do not end up in the Nix store.
      '';
      example = "/run/secrets/nixprbot.env";
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
      home = cfg.stateDir;
      createHome = false;
    };
    users.groups.${cfg.group} = { };

    systemd.services.nixprbot = {
      description = "nixpkgs PR tracker Telegram bot";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      environment = {
        NIXPRBOT_DB_PATH = "${cfg.stateDir}/nixprbot.sqlite";
        NIXPRBOT_REPO = cfg.repo;
        NIXPRBOT_POLL_INTERVAL_SEC = toString cfg.pollIntervalSeconds;
        NIXPRBOT_BRANCHES = lib.concatStringsSep "," cfg.branches;
      };

      serviceConfig = {
        ExecStart = "${lib.getExe cfg.package}";
        EnvironmentFile = cfg.environmentFile;
        User = cfg.user;
        Group = cfg.group;
        StateDirectory = "nixprbot";
        StateDirectoryMode = "0750";
        Restart = "on-failure";
        RestartSec = "10s";

        # Hardening
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictNamespaces = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        RestrictRealtime = true;
        SystemCallArchitectures = "native";
      };
    };
  };
}
