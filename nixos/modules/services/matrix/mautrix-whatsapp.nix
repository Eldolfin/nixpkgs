{
  lib,
  config,
  pkgs,
  ...
}: let
  cfg = config.services.mautrix-whatsapp;
  dataDir = "/var/lib/mautrix-whatsapp";
  registrationFile = "${dataDir}/whatsapp-registration.yaml";
  settingsFile = "${dataDir}/config.json";
  settingsFileUnsubstituted = settingsFormat.generate "mautrix-whatsapp-config-unsubstituted.json" cfg.settings;
  settingsFormat = pkgs.formats.json {};
  appservicePort = 29318;
in {
  imports = [];
  options.services.mautrix-whatsapp = {
    enable = lib.mkEnableOption "mautrix-whatsapp, a puppeting/relaybot bridge between Matrix and WhatsApp.";

    settings = lib.mkOption {
      type = settingsFormat.type;
      default = {};
      description = lib.mdDoc ''
        {file}`config.yaml` configuration as a Nix attribute set.
        Configuration options should match those described in
        [example-config.yaml](https://github.com/mautrix/whatsapp/blob/master/example-config.yaml).
        Secret tokens should be specified using {option}`environmentFile`
        instead of this world-readable attribute set.
      '';
      example = {
        appservice = {
          database = {
            type = "postgres";
            uri = "postgresql:///mautrix_whatsapp?host=/run/postgresql";
          };
          id = "whatsapp";
          ephemeral_events = false;
        };
        bridge = {
          history_sync = {
            request_full_sync = true;
          };
          private_chat_portal_meta = true;
          mute_bridging = true;
          encryption = {
            allow = true;
            default = true;
            require = true;
          };
          provisioning = {
            shared_secret = "disable";
          };
          permissions = {
            "example.com" = "user";
          };
        };
      };
    };
    environmentFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = lib.mdDoc ''
        File containing environment variables to be passed to the mautrix-whatsapp service,
        in which secret tokens can be specified securely by optionally defining a value for
        `MAUTRIX_WHATSAPP_BRIDGE_LOGIN_SHARED_SECRET`.
      '';
    };

    serviceDependencies = lib.mkOption {
      type = with lib.types; listOf str;
      default = lib.optional config.services.matrix-synapse.enable "matrix-synapse.service";
      defaultText = lib.literalExpression ''
        optional config.services.matrix-synapse.enable "matrix-synapse.service"
      '';
      description = lib.mdDoc ''
        List of Systemd services to require and wait for when starting the application service.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.mautrix-whatsapp.settings = {
      homeserver = {
        domain = lib.mkDefault config.services.matrix-synapse.settings.server_name;
      };
      appservice = {
        address = lib.mkDefault "http://localhost:${toString appservicePort}";
        hostname = lib.mkDefault "[::]";
        port = lib.mkDefault appservicePort;
        database = {
          type = lib.mkDefault "sqlite3";
          uri = lib.mkDefault "${dataDir}/mautrix-whatsapp.db";
        };
        id = lib.mkDefault "whatsapp";
        bot = {
          username = lib.mkDefault "whatsappbot";
          displayname = lib.mkDefault "WhatsApp Bridge Bot";
        };
        as_token = lib.mkDefault "";
        hs_token = lib.mkDefault "";
      };
      bridge = {
        username_template = lib.mkDefault "whatsapp_{{.}}";
        displayname_template = lib.mkDefault "{{if .BusinessName}}{{.BusinessName}}{{else if .PushName}}{{.PushName}}{{else}}{{.JID}}{{end}} (WA)";
        double_puppet_server_map = lib.mkDefault {};
        login_shared_secret_map = lib.mkDefault {};
        command_prefix = lib.mkDefault "!wa";
        permissions."*" = lib.mkDefault "relay";
        relay.enabled = lib.mkDefault true;
      };
      logging = {
        min_level = lib.mkDefault "info";
        writers = [
          {
            type = lib.mkDefault "stdout";
            format = lib.mkDefault "pretty-colored";
          }
          {
            type = lib.mkDefault "file";
            format = lib.mkDefault "json";
          }
        ];
      };
    };

    systemd.services.mautrix-whatsapp = {
      description = "Mautrix-WhatsApp Service - A WhatsApp bridge for Matrix";

      wantedBy = ["multi-user.target"];
      wants = ["network-online.target"] ++ cfg.serviceDependencies;
      after = ["network-online.target"] ++ cfg.serviceDependencies;

      preStart = ''
        # substitute the settings file by environment variables
        # in this case read from EnvironmentFile
        test -f '${settingsFile}' && rm -f '${settingsFile}'
        old_umask=$(umask)
        umask 0177
        ${pkgs.envsubst}/bin/envsubst \
          -o '${settingsFile}' \
          -i '${settingsFileUnsubstituted}'
        umask $old_umask

        # generate the appservice's registration file if absent
        if [ ! -f '${registrationFile}' ]; then
          ${pkgs.mautrix-whatsapp}/bin/mautrix-whatsapp \
            --generate-registration \
            --config='${settingsFile}' \
            --registration='${registrationFile}'
        fi
        chmod 640 ${registrationFile}

        umask 0177
        ${pkgs.yq}/bin/yq -s '.[0].appservice.as_token = .[1].as_token
          | .[0].appservice.hs_token = .[1].hs_token
          | .[0]' '${settingsFile}' '${registrationFile}' \
          > '${settingsFile}.tmp'
        mv '${settingsFile}.tmp' '${settingsFile}'
        umask $old_umask
      '';

      serviceConfig = {
        DynamicUser = true;
        EnvironmentFile = cfg.environmentFile;
        StateDirectory = baseNameOf dataDir;
        WorkingDirectory = "${dataDir}";
        ExecStart = ''
          ${pkgs.mautrix-whatsapp}/bin/mautrix-whatsapp \
          --config='${settingsFile}' \
          --registration='${registrationFile}'
        '';
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateTmp = true;
        PrivateUsers = true;
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHome = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectSystem = "strict";
        Restart = "on-failure";
        RestartSec = "30s";
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        SystemCallArchitectures = "native";
        SystemCallErrorNumber = "EPERM";
        SystemCallFilter = ["@system-service"];
        Type = "simple";
        UMask = 0027;
      };
      restartTriggers = [settingsFileUnsubstituted];
    };
  };
  meta.maintainers = with lib.maintainers; [frederictobiasc];
}
