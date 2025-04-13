#!/usr/bin/env bash

set -Eeuo pipefail

# v2.2
# Copyright 2024-2025
# Author: vhsdream
# Adapted from: The Karakeep installation script from https://github.com/community-scripts/ProxmoxVE
# License: MIT

# Basic error handling
trap 'catch $?' ERR

catch() {
  echo "Caught error $1 on line ${BASH_LINENO[0]}"
}

# Global Vars
OS="$(awk -F'=' '/^VERSION_CODENAME=/{ print $NF }' /etc/os-release)"
INSTALL_DIR=/opt/karakeep
export DATA_DIR=/var/lib/karakeep
CONFIG_DIR=/etc/karakeep
LOG_DIR=/var/log/karakeep
ENV_FILE=${CONFIG_DIR}/karakeep.env
BRWSR_URL="http://127.0.0.1:9222"
BRWSR_RELEASE=$(curl -s https://api.github.com/repos/browserless/browserless/tags?per_page=1 | grep "name" | awk '{print substr($2, 3, length($2)-4) }')
BRWSR_INSTALL=/opt/browserless
BRWSR_ENV="$BRWSR_INSTALL"/.env

# Functions
browserless_build() {
  tmp_file=$(mktemp)
  wget -q https://github.com/browserless/browserless/archive/refs/tags/v"${BRWSR_RELEASE}".zip -O "$tmp_file"
  unzip -q "$tmp_file"
  mv browserless-"${BRWSR_RELEASE}" "$BRWSR_INSTALL"
  cd "$BRWSR_INSTALL" && npm install
  rm -rf ./src/routes/{chrome,edge,firefox,webkit}
  echo "Installing Chromium browser" && sleep 1
  export PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers
  ./node_modules/playwright-core/cli.js install --with-deps chromium
  echo "Chromium browser installed" && sleep 1
  npm run build
  npm run build:function
  npm prune production
  rm -f "$tmp_file"
}

browserless_post() {
  cd "$BRWSR_INSTALL"
  if ! grep -q ONDEMAND "$ENV_FILE"; then
    sed -i "/BROWSER_WEB/a BROWSER_CONNECT_ONDEMAND=true" "$ENV_FILE"
  else
    sed -i "s/ONDEMAND=false/ONDEMAND=true/" "$ENV_FILE"
  fi

  cat <<EOF >"$BRWSR_ENV"
DEBUG=browserless*,-**:verbose
HOST=127.0.0.1
PORT=9222
PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers
EOF

  cat <<EOF >/etc/systemd/system/karakeep-browser.service
[Unit]
Description=Karakeep Browserless service
After=network.target

[Service]
User=browserless
Group=browserless
Restart=unless-stopped
WorkingDirectory=${BRWSR_INSTALL}
EnvironmentFile=${BRWSR_ENV}
ExecStart=/usr/bin/npm run start
TimeoutStopSec=5
SyslogIdentifier=karakeep-browser

[Install]
WantedBy=multi-user.target
EOF

  useradd -U -s /usr/sbin/nologin -r -M -d /opt/browserless browserless
  echo "$BRWSR_RELEASE" >/opt/browserless/version.txt
  chown -R browserless:browserless "$BRWSR_INSTALL" /opt/pw-browsers
}

install() {
  echo "Karakeep installation for Debian 12/Ubuntu 24.04" && sleep 4
  echo "Installing Dependencies..." && sleep 1
  apt-get install --no-install-recommends -y \
    g++ \
    curl \
    build-essential \
    sudo \
    unzip \
    gnupg \
    graphicsmagick \
    ghostscript \
    ca-certificates
  if [[ "$OS" == "noble" ]]; then
    apt-get install -y yt-dlp
  else
    wget -q https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_linux -O /usr/bin/yt-dlp && chmod +x /usr/bin/yt-dlp
  fi

  wget -q https://github.com/Y2Z/monolith/releases/latest/download/monolith-gnu-linux-x86_64 -O /usr/bin/monolith && chmod +x /usr/bin/monolith
  wget -q https://github.com/meilisearch/meilisearch/releases/latest/download/meilisearch.deb &&
    DEBIAN_FRONTEND=noninteractive dpkg -i meilisearch.deb && rm meilisearch.deb
  echo "Installed Dependencies" && sleep 1

  echo "Installing Node.js..."
  mkdir -p /etc/apt/keyrings
  curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
  echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" >/etc/apt/sources.list.d/nodesource.list
  apt-get update
  apt-get install -y nodejs
  # https://github.com/karakeep-app/karakeep/issues/967
  npm install -g corepack@0.31.0
  echo "Installed Node.js" && sleep 1

  echo "Installing Karakeep..."
  mkdir -p "$DATA_DIR"
  mkdir -p "$CONFIG_DIR"
  mkdir -p "$LOG_DIR"
  M_DATA_DIR=/var/lib/meilisearch
  M_CONFIG_FILE=/etc/meilisearch.toml
  RELEASE=$(curl -s https://api.github.com/repos/karakeep-app/karakeep/releases/latest | grep "tag_name" | awk '{print substr($2, 3, length($2)-4) }')
  cd /tmp
  wget -q "https://github.com/karakeep-app/karakeep/archive/refs/tags/v${RELEASE}.zip"
  unzip -q v"$RELEASE".zip
  mv karakeep-"$RELEASE" "$INSTALL_DIR"
  cd "$INSTALL_DIR"/apps/web
  corepack enable
  export NEXT_TELEMETRY_DISABLED=1
  export PUPPETEER_SKIP_DOWNLOAD="true"
  export CI="true"
  pnpm i --frozen-lockfile
  pnpm build
  cd "$INSTALL_DIR"/apps/workers
  pnpm i --frozen-lockfile
  cd "$INSTALL_DIR"/apps/cli
  pnpm i --frozen-lockfile
  pnpm build
  cd "$INSTALL_DIR"/packages/db
  pnpm migrate
  echo "Installed Karakeep" && sleep 1

  echo "Installing Browserless" && sleep 1
  browserless_build
  echo "Installed Browserless" && sleep 1

  echo "Creating configuration files..." && sleep 1
  MASTER_KEY="$(openssl rand -base64 12)"
  cat <<EOF >${M_CONFIG_FILE}
env = "production"
master_key = "$MASTER_KEY"
db_path = "${M_DATA_DIR}/data"
dump_dir = "${M_DATA_DIR}/dumps"
snapshot_dir = "${M_DATA_DIR}/snapshots"
no_analytics = true
EOF
  chmod 600 "$M_CONFIG_FILE"

  karakeep_SECRET="$(openssl rand -base64 36 | cut -c1-24)"
  cat <<EOF >${ENV_FILE}
NODE_ENV=production
SERVER_VERSION=${RELEASE}
NEXTAUTH_SECRET="${karakeep_SECRET}"
NEXTAUTH_URL="http://localhost:3000"
DATA_DIR=${DATA_DIR}
MEILI_ADDR="http://127.0.0.1:7700"
MEILI_MASTER_KEY="${MASTER_KEY}"
BROWSER_WEB_URL=${BRWSR_URL}
BROWSER_CONNECT_ONDEMAND=true
# CRAWLER_VIDEO_DOWNLOAD=true
# CRAWLER_VIDEO_DOWNLOAD_MAX_SIZE=
# OPENAI_API_KEY=
# OLLAMA_BASE_URL=
# INFERENCE_TEXT_MODEL=
# INFERENCE_IMAGE_MODEL=
EOF
  chmod 600 "$ENV_FILE"

  echo "$RELEASE" >"$INSTALL_DIR"/version.txt
  browserless_post
  echo "Configuration complete" && sleep 1

  echo "Creating users and modifying permissions..."
  useradd -U -s /usr/sbin/nologin -r -m -d "$M_DATA_DIR" meilisearch
  useradd -U -s /usr/sbin/nologin -r -M -d "$INSTALL_DIR" karakeep
  chown meilisearch:meilisearch "$M_CONFIG_FILE"
  touch "$LOG_DIR"/{karakeep-workers.log,karakeep-web.log}
  chown -R karakeep:karakeep "$INSTALL_DIR" "$CONFIG_DIR" "$DATA_DIR" "$LOG_DIR"
  echo "Users created, permissions modified" && sleep 1

  echo "Creating service files..."
  cat <<EOF >/etc/systemd/system/meilisearch.service
[Unit]
Description=MeiliSearch is a RESTful search API
Documentation=https://docs.meilisearch.com/
After=network.target

[Service]
User=meilisearch
Group=meilisearch
Restart=on-failure
WorkingDirectory=${M_DATA_DIR}
ExecStart=/usr/bin/meilisearch --config-file-path ${M_CONFIG_FILE}
NoNewPrivileges=true
ProtectHome=true
ReadWritePaths=${M_DATA_DIR}
ProtectSystem=full
ProtectHostname=true
ProtectControlGroups=true
ProtectKernelModules=true
ProtectKernelTunables=true
ProtectKernelLogs=true
ProtectClock=true
LockPersonality=true
RestrictRealtime=yes
RestrictNamespaces=yes
MemoryDenyWriteExecute=yes
PrivateDevices=yes
PrivateTmp=true
CapabilityBoundingSet=
RemoveIPC=true

[Install]
WantedBy=multi-user.target
EOF

  cat <<EOF >/etc/systemd/system/karakeep-workers.service
[Unit]
Description=Karakeep workers
Wants=network.target karakeep-browser.service meilisearch.service
After=network.target karakeep-browser.service meilisearch.service

[Service]
User=karakeep
Group=karakeep
Restart=always
EnvironmentFile=${ENV_FILE}
WorkingDirectory=${INSTALL_DIR}/apps/workers
ExecStart=/usr/bin/pnpm run start:prod
StandardOutput=file:${LOG_DIR}/karakeep-workers.log
StandardError=file:${LOG_DIR}/karakeep-workers.log
TimeoutStopSec=5
SyslogIdentifier=karakeep-workers

[Install]
WantedBy=multi-user.target
EOF

  cat <<EOF >/etc/systemd/system/karakeep-web.service
[Unit]
Description=Karakeep web
Wants=network.target karakeep-workers.service
After=network.target karakeep-workers.service

[Service]
User=karakeep
Group=karakeep
Restart=on-failure
EnvironmentFile=${ENV_FILE}
WorkingDirectory=${INSTALL_DIR}/apps/web
ExecStart=/usr/bin/pnpm start
StandardOutput=file:${LOG_DIR}/karakeep-web.log
StandardError=file:${LOG_DIR}/karakeep-web.log
TimeoutStopSec=5
SyslogIdentifier=karakeep-web

[Install]
WantedBy=multi-user.target
EOF

  cat <<EOF >/etc/systemd/system/karakeep.target
[Unit]
Description=Karakeep Services
After=network-online.target
Wants=meilisearch.service karakeep-browser.service karakeep-workers.service karakeep-web.service

[Install]
WantedBy=multi-user.target
EOF
  echo "Service files created" && sleep 1

  echo "Cleaning up" && sleep 1
  rm /tmp/v"$RELEASE".zip
  apt -y autoremove
  apt -y autoclean
  echo "Cleaned" && sleep 1

  echo "Enabling and starting services, please wait..." && sleep 3
  systemctl enable -q --now karakeep.target
  service_check install
}

update() {
  if [[ ! -d ${INSTALL_DIR} ]]; then
    echo "Is Karakeep even installed?"
    exit 1
  fi
  RELEASE=$(curl -s https://api.github.com/repos/karakeep-app/karakeep/releases/latest | grep "tag_name" | awk '{print substr($2, 3, length($2)-4) }')
  PREV_RELEASE=$(cat "$INSTALL_DIR"/version.txt)
  if [[ "$RELEASE" != "$PREV_RELEASE" ]]; then
    if [[ "$(systemctl is-active karakeep-web)" == "active" ]]; then
      echo "Stopping affected services..." && sleep 1
      systemctl stop karakeep-web karakeep-workers
      echo "Stopped services" && sleep 1
    fi
    if [[ "$OS" == "bookworm" ]]; then
      yt-dlp -U
    fi
    echo "Updating Karakeep to v${RELEASE}..." && sleep 1
    sed -i "s|SERVER_VERSION=${PREV_RELEASE}|SERVER_VERSION=${RELEASE}|" "$ENV_FILE"
    rm -R "$INSTALL_DIR"
    cd /tmp
    wget -q "https://github.com/karakeep-app/karakeep/archive/refs/tags/v${RELEASE}.zip"
    unzip -q v"$RELEASE".zip
    mv karakeep-"$RELEASE" "$INSTALL_DIR"
    # https://github.com/karakeep-app/karakeep/issues/967
    if [[ $(corepack -v) < "0.31.0" ]]; then
      npm install -g corepack@0.31.0
    fi
    corepack enable
    export NEXT_TELEMETRY_DISABLED=1
    export PUPPETEER_SKIP_DOWNLOAD="true"
    export CI="true"
    cd "$INSTALL_DIR"/apps/web && pnpm i --frozen-lockfile
    pnpm build
    cd "$INSTALL_DIR"/apps/workers && pnpm i --frozen-lockfile
    cd "$INSTALL_DIR"/apps/cli && pnpm i --frozen-lockfile
    pnpm build
    cd "$INSTALL_DIR"/packages/db && pnpm migrate
    echo "$RELEASE" >"$INSTALL_DIR"/version.txt
    chown -R karakeep:karakeep "$INSTALL_DIR" "$DATA_DIR"
    echo "Updated Karakeep to v${RELEASE}" && sleep 1
    echo "Restarting services..." && sleep 1
    rm /tmp/v"$RELEASE".zip
    systemctl restart karakeep.target
    service_check update
  else
    echo "No Karakeep update required."
  fi

  if [[ -d /opt/browserless ]]; then BRWSR_INSTALLED=1; else BRWSR_INSTALLED=0; fi
  if [[ "$BRWSR_INSTALLED" == 0 ]]; then
    echo "Browserless is not installed! Installing it now" && sleep 1
    systemctl stop karakeep-workers karakeep-browser karakeep-web
    if [[ $OS == "noble" ]]; then apt-get autoremove -y ungoogled-chromium; else apt-get autoremove -y chromium; fi
    browserless_build
    browserless_post
    systemctl daemon-reload
    systemctl start karakeep-web karakeep-browser
    sleep 5 && systemctl start karakeep-workers
    echo "Finished installing & configuring Browserless!" && sleep 1
  elif [[ "$BRWSR_INSTALLED" == 1 ]] && [[ "$BRWSR_RELEASE" != $(cat /opt/browserless/version.txt) ]]; then
    echo "Updating Browserless..." && sleep 1
    systemctl stop karakeep-browser karakeep-workers
    cp /opt/browserless/.env /opt/browserless.env
    rm -rf /opt/browserless
    browserless_build
    mv /opt/browserless.env /opt/browserless/.env
    systemctl start karakeep-browser karakeep-workers
    echo "Browserless updated!" && sleep 1
  else
    echo "No updates for Browserless" && sleep 1
  fi
  echo "Operations complete"
  exit 0
}

migrate() {
  if [[ ! -d /opt/karakeep ]]; then
    echo "Migrating your Hoarder installation to Karakeep, then checking for an update..." && sleep 2
    systemctl stop hoarder-browser hoarder-workers hoarder-web
    sed -i -e "s|hoarder|karakeep|g" /etc/hoarder/hoarder.env /etc/systemd/system/hoarder-{browser,web,workers}.service /etc/systemd/system/hoarder.target \
      -e "s|Hoarder|Karakeep|g" /etc/systemd/system/hoarder-{browser,web,workers}.service /etc/systemd/system/hoarder.target
    for path in /etc/systemd/system/hoarder*.service; do
      new_path="${path//hoarder/karakeep}"
      mv "$path" "$new_path"
    done
    mv /etc/systemd/system/hoarder.target /etc/systemd/system/karakeep.target
    mv /opt/hoarder "$INSTALL_DIR"
    mv /var/lib/hoarder "$DATA_DIR"
    mv /etc/hoarder "$CONFIG_DIR"
    mv /var/log/hoarder "$LOG_DIR"
    mv "$CONFIG_DIR"/hoarder.env "$ENV_FILE"
    mv "$LOG_DIR"/hoarder-web.log "$LOG_DIR"/karakeep-web.log
    mv "$LOG_DIR"/hoarder-workers.log "$LOG_DIR"/karakeep-workers.log
    usermod -l karakeep hoarder -d "$INSTALL_DIR"
    groupmod -n karakeep hoarder
    chown -R karakeep:karakeep "$INSTALL_DIR" "$CONFIG_DIR" "$DATA_DIR" "$LOG_DIR"
    systemctl daemon-reload
    systemctl -q enable --now karakeep.target
    service_check migrate
  else
    echo "There is no need for a migration: Karakeep is already installed."
    exit 1
  fi
}

service_check() {
  local services=("karakeep-browser" "karakeep-workers" "karakeep-web")
  local status=""
  readarray -t status < <(for service in "${services[@]}"; do
    systemctl is-active "$service" | grep "^active" -
  done)
  if [[ "${#status[@]}" -eq 3 ]]; then
    if [[ "$1" == "install" ]]; then
      echo "Karakeep is running!"
      sleep 1
      LOCAL_IP="$(hostname -I | awk '{print $1}')"
      echo "Go to http://$LOCAL_IP:3000 to create your account"
      exit 0
    elif [[ "$1" == "update" ]]; then
      echo "Karakeep is updated and running!"
      sleep 1
      exit 0
    elif [[ "$1" == "migrate" ]]; then
      echo "Karakeep migration complete!"
      sleep 1
      exit 0
    fi
  else
    echo "Some services have failed. Check 'journalctl -xeu <service-name>' to see what is going on"
    exit 1
  fi
}

[ "$(id -u)" -ne 0 ] && echo "This script requires root privileges. Please run with sudo or as the root user." && exit 1
command="${1:-}"
if [ "$command" = "" ]; then
  echo -e "\nRun script with:\r
parameter 'install' to install Karakeep\r
parameter 'update' to update Karakeep\r
parameter 'migrate' to migrate your Hoarder install to Karakeep\n
Note: 'migrate' will also update to the latest version if necessary" && exit 1
fi

case "$command" in
install)
  install
  ;;
update)
  update
  ;;
migrate)
  migrate && update
  ;;
*)
  echo -e "Unknown command. Choose 'install', 'update' or 'migrate'." && exit 1
  ;;
esac
