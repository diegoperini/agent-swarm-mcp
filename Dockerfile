# agent-swarm-mcp, remote instance: the same PowerShell script as on Windows,
# run by PowerShell 7 on Ubuntu. Built and started by run.sh (see README).
FROM ubuntu:22.04

# PowerShell release to install (https://github.com/PowerShell/PowerShell/releases).
ARG PWSH_VERSION=7.6.9

ENV DEBIAN_FRONTEND=noninteractive \
    POWERSHELL_TELEMETRY_OPTOUT=1 \
    POWERSHELL_UPDATECHECK=Off \
    DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    HOME=/tmp \
    SWARM_MODE=remote \
    SWARM_STATE_DIR=/app/state \
    SWARM_LISTEN=http://+:8780/

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl libicu70 libssl3 tzdata \
 && rm -rf /var/lib/apt/lists/*

RUN set -eu; \
    case "$(dpkg --print-architecture)" in \
      amd64) arch=x64 ;; \
      arm64) arch=arm64 ;; \
      *) echo "unsupported CPU architecture: $(dpkg --print-architecture)" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/pwsh.tgz "https://github.com/PowerShell/PowerShell/releases/download/v${PWSH_VERSION}/powershell-${PWSH_VERSION}-linux-${arch}.tar.gz"; \
    mkdir -p /opt/microsoft/powershell; \
    tar -xzf /tmp/pwsh.tgz -C /opt/microsoft/powershell; \
    chmod 755 /opt/microsoft/powershell/pwsh; \
    ln -s /opt/microsoft/powershell/pwsh /usr/bin/pwsh; \
    rm /tmp/pwsh.tgz; \
    pwsh -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'

WORKDIR /app
COPY mcp-server.ps1 system-prompt.md LICENSE NOTICE ./
COPY lib/ lib/
COPY context/ context/
# Read-only reference for agents asked about agent-swarm itself (swarm_files):
# the README, settings examples and deploy files. No secrets are among them.
COPY README.md .env.example config.env.example mcp-server.bat open-webview.bat Dockerfile docker-compose.yml docker-compose.bundled-caddy.yml docker-compose.shared-caddy.yml run.sh deploy.sh key.sh .gitattributes .gitignore .dockerignore ./
COPY caddy/Caddyfile caddy/site.caddy.example caddy/

# Plain HTTP inside the container only: Caddy terminates HTTPS in front of it.
EXPOSE 8780
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s CMD curl -fsS http://127.0.0.1:8780/_health || exit 1
# umask 077: state files (transcripts, keys, sign-ins) are readable by their owner only.
CMD ["/bin/sh", "-c", "umask 077 && exec pwsh -NoLogo -NoProfile -NonInteractive -File /app/mcp-server.ps1"]
