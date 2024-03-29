{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.services.log-archiver;
in {
  options.services.log-archiver = {
    enable = mkEnableOption "Log archiver";

    user = mkOption {
      type = types.str;
      description = "user to save logs as";
    };

    databaseUrlFile = mkOption {
      type = types.str;
      description = "file containg DATABASE_URL variable";
    };

    baseUrl = mkOption {
      type = types.str;
      default = "https://logs.tf";
      description = "logs.tf base url";
    };

    target = mkOption {
      type = types.str;
      description = "path to store logs to";
    };

    package = mkOption {
      type = types.package;
      description = "package to use";
    };
  };

  config = mkIf cfg.enable {
    systemd.services."log-archiver" = {
      wantedBy = ["multi-user.target"];
      environment = {
        API_BASE = cfg.baseUrl;
        LOG_TARGET = cfg.target;
      };

      serviceConfig = {
        EnvironmentFile = cfg.databaseUrlFile;
        ExecStart = "${cfg.package}/bin/log-archiver";
        Restart = "on-failure";
        User = cfg.user;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ReadWritePaths = cfg.target;
        ProtectHome = true;
        NoNewPrivileges = true;
        PrivateDevices = true;
        ProtectClock = true;
        CapabilityBoundingSet = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        SystemCallArchitectures = "native";
        ProtectKernelModules = true;
        RestrictNamespaces = true;
        MemoryDenyWriteExecute = true;
        ProtectHostname = true;
        LockPersonality = true;
        ProtectKernelTunables = true;
        RestrictAddressFamilies = "AF_INET AF_INET6 AF_UNIX";
        RestrictRealtime = true;
        ProtectProc = "noaccess";
        SystemCallFilter = ["@system-service" "~@resources" "~@privileged"];
        IPAddressDeny = "multicast";
        PrivateUsers = true;
        ProcSubset = "pid";
      };
    };
  };
}
