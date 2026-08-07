flake: { config, lib, pkgs, ... }:

let
  cfg = config.services.nixprbot;
  pkg = flake.packages.${pkgs.system}.nixprbot;
  # StateDirectory= wants a name relative to /var/lib. An absolute stateDir
  # anywhere else would be unwritable under ProtectSystem=strict, so reject it
  # at eval time instead of shipping a crash loop.
  stateDirName = lib.removePrefix "/var/lib/" cfg.stateDir;
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
      description = "Where the SQLite database lives. Must be under /var/lib.";
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

    logLevel = lib.mkOption {
      type = lib.types.enum [ "debug" "info" "warn" "err" ];
      default = "info";
      description = "Runtime log verbosity.";
    };

    environmentFile = lib.mkOption {
      type = lib.types.path;
      description = ''
        Path to a file containing NIXPRBOT_TOKEN=... and
        NIXPRBOT_GITHUB_TOKEN=... (both required) — read by systemd via
        EnvironmentFile so secrets do not end up in the Nix store.
      '';
      example = "/run/secrets/nixprbot.env";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.hasPrefix "/var/lib/" cfg.stateDir && stateDirName != "";
        message = "services.nixprbot.stateDir must be a path under /var/lib (got ${cfg.stateDir}).";
      }
    ];

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
        NIXPRBOT_LOG = cfg.logLevel;
      };

      serviceConfig = {
        ExecStart = "${lib.getExe cfg.package}";
        EnvironmentFile = cfg.environmentFile;
        User = cfg.user;
        Group = cfg.group;
        StateDirectory = stateDirName;
        StateDirectoryMode = "0750";

        # The bot is crash-only: it exits on wedged transports and failure
        # budgets, and the watchdog reaps silent hangs (the longest legitimate
        # quiet stretch is the 30s Telegram long poll).
        Type = "notify";
        NotifyAccess = "main";
        WatchdogSec = 120;
        Restart = "on-failure";
        RestartSec = "5s";
        RestartSteps = 8;
        RestartMaxDelaySec = "10min";

        # Hardening
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        ProtectHostname = true;
        ProtectProc = "invisible";
        ProcSubset = "pid";
        RestrictNamespaces = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        RemoveIPC = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = [ "@system-service" ];
        # AF_UNIX is the sd_notify channel back to systemd.
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
        CapabilityBoundingSet = "";
        UMask = "0077";
      };
    };
  };
}
