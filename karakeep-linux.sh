#!/usr/bin/env bash

# v2.2
# Copyright 2024-2025
# Author: vhsdream
# Adapted from: The Karakeep installation script from https://github.com/community-scripts/ProxmoxVE
# License: MIT

set -Eeuo pipefail
trap 'catch $LINENO "$BASH_COMMAND"' SIGINT SIGTERM ERR
verbose=0

usage() {
  cat <<EOF
Usage: bash $(basename "${BASH_SOURCE[0]}") [-h] [-v] [install|update|migrate]

This script has three functions:

'install'   Installs Karakeep on a clean Debian 12/Ubuntu 24.04 system
'update'    Checks for, and installs updates for Karakeep on a system that previously installed Karakeep by running this script
'migrate'   Migrates an existing Hoarder installation that was installed by this script before the name change

This script WILL NOT update or migrate a Karakeep/Hoarder install that was installed in any other way

If you encounter any errors please create a GitHub issue (https://github.com/karakeep-app/karakeep/issues) and tag vhsdream

Available options:

-h, --help      Print this help and exit
-v, --verbose   Print script StandardOutput
--no-color      Disable colours
EOF
  exit
}

# Handling output suppression
set_verbosity() {
  if [ "$verbose" -eq 1 ]; then
    shh=""
  else
    shh="silent_running"
  fi
}

silent_running() {
  "$@" >/dev/null 2>&1
}

set_verbosity

# Colour handling
setup_colours() {
  if [[ -t 2 ]] && [[ -z "${NO_COLOR-}" ]] && [[ "${TERM-}" != "dumb" ]]; then
    CLR='\033[0m' GREEN='\033[0;32m' PURPLE='\033[0;35m' CYAN='\033[0;36m' YELLOW='\033[1;33m'
  else
    CLR='' GREEN='' PURPLE='' CYAN='' YELLOW=''
  fi
}

# Exception and error handling
msg_err() {
  if [ -n "$SPINNER_PID" ] && ps -p "$SPINNER_PID" >/dev/null; then kill "$SPINNER_PID" >/dev/null; fi
  echo >&2 -e "\033[0;31m${1-}\033[0m"
}

die() {
  local err=$1
  local code=${2-1}
  msg_err "$err"
  exit "$code"
}

catch() {
  local code=$?
  local line=$1
  local command=$2
  msg_err "Caught error in line $line: exit code $code: while executing $command"
}

parse_params() {
  while :; do
    case "${1-}" in
    -h | --help) usage ;;
    -v | --verbose) verbose=1 && set_verbosity ;;
    --no-color) NO_COLOR=1 ;;
    -?*) die "Unknown flag: $1. Use -h|--help for help" ;;
    *) break ;;
    esac
    shift
  done

  args=("$@")
  [[ ${#args[@]} -eq 0 ]] && die "Missing script arguments. Use -h|--help for help"
  return 0
}

parse_params "$@"
setup_colours

spinner() {
  local frames=('▹▹▹▹▹' '▸▹▹▹▹' '▹▸▹▹▹' '▹▹▸▹▹' '▹▹▹▸▹' '▹▹▹▹▸')
  local spin_i=0
  local interval=0.1
  printf "\e[?25l"

  while true; do
    printf "\r${PURPLE}%s${CLR}" "${frames[spin_i]}"
    spin_i=$(((spin_i + 1) % ${#frames[@]}))
    sleep "$interval"
  done
}

msg_start() {
  printf "      "
  echo >&1 -ne "${CYAN}${1-}${CLR}"
  spinner &
  SPINNER_PID=$!
}

msg_done() {
  if [ -n "$SPINNER_PID" ] && ps -p "$SPINNER_PID" >/dev/null; then kill "$SPINNER_PID" >/dev/null; fi
  printf "\e[?25h"
  local msg="${1-}"
  echo -e "\r"
  echo >&1 -e "✔     ${GREEN}${msg}${CLR}"
}

msg_info() {
  echo -e "\r"
  echo >&1 -ne "${YELLOW}${1-}${CLR}"
}

OS="$(awk -F'=' '/^VERSION_CODENAME=/{ print $NF }' /etc/os-release)"
INSTALL_DIR=/opt/karakeep
export DATA_DIR=/var/lib/karakeep
CONFIG_DIR=/etc/karakeep
LOG_DIR=/var/log/karakeep
ENV_FILE=${CONFIG_DIR}/karakeep.env

install() {
  echo "Karakeep installation for Debian 12/Ubuntu 24.04" && sleep 4
  msg_start "Updating OS..." && sleep 1
  $shh apt-get update
  $shh apt-get dist-upgrade -y
  msg_start "Installing Dependencies..." && sleep 1
  $shh apt-get install --no-install-recommends -y \
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
    $shh apt-get install -y software-properties-common
    $shh add-apt-repository ppa:xtradeb/apps -y
    $shh apt-get install --no-install-recommends -y ungoogled-chromium yt-dlp
    ln -s /usr/bin/ungoogled-chromium /usr/bin/chromium
  else
    $shh apt-get install --no-install-recommends -y chromium
    $shh wget -q https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_linux -O /usr/bin/yt-dlp && chmod +x /usr/bin/yt-dlp
  fi

  wget -q https://github.com/Y2Z/monolith/releases/latest/download/monolith-gnu-linux-x86_64 -O /usr/bin/monolith && chmod +x /usr/bin/monolith
  wget -q https://github.com/meilisearch/meilisearch/releases/latest/download/meilisearch.deb &&
    $shh DEBIAN_FRONTEND=noninteractive dpkg -i meilisearch.deb && rm meilisearch.deb
  msg_done "Installed Dependencies" && sleep 1

  msg_start "Installing Node.js..."
  mkdir -p /etc/apt/keyrings
  curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
  echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" >/etc/apt/sources.list.d/nodesource.list
  $shh apt-get update
  $shh apt-get install -y nodejs
  # https://github.com/karakeep-app/karakeep/issues/967
  $shh npm install -g corepack@0.31.0
  msg_done "Installed Node.js" && sleep 1

  msg_start "Installing Karakeep..."
  mkdir -p "$DATA_DIR"
  mkdir -p "$CONFIG_DIR"
  mkdir -p "$LOG_DIR"
  M_DATA_DIR=/var/lib/meilisearch
  M_CONFIG_FILE=/etc/meilisearch.toml
  RELEASE=$(curl -s https://api.github.com/repos/karakeep-app/karakeep/releases/latest | grep "tag_name" | awk '{print substr($2, 3, length($2)-4) }')
  cd /tmp
  wget -q "https://github.com/karakeep-app/karakeep/archive/refs/tags/v${RELEASE}.zip"
  unzip -q v"$RELEASE".zip
  mv karakeep-"$RELEASE" "$INSTALL_DIR" && cd "$INSTALL_DIR"/apps/web
  corepack enable
  export NEXT_TELEMETRY_DISABLED=1
  export PUPPETEER_SKIP_DOWNLOAD="true"
  export CI="true"
  $shh pnpm i --frozen-lockfile
  $shh pnpm exec next build --experimental-build-mode compile
  cd "$INSTALL_DIR"/apps/workers
  $shh pnpm i --frozen-lockfile
  cd "$INSTALL_DIR"/apps/cli
  $shh pnpm i --frozen-lockfile
  $shh pnpm build
  cd "$INSTALL_DIR"/packages/db
  $shh pnpm migrate
  msg_done "Installed Karakeep" && sleep 1

  msg_start "Creating configuration files..."
  cd "$INSTALL_DIR"
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
BROWSER_WEB_URL="http://127.0.0.1:9222"
# CRAWLER_VIDEO_DOWNLOAD=true
# CRAWLER_VIDEO_DOWNLOAD_MAX_SIZE=
# OPENAI_API_KEY=
# OLLAMA_BASE_URL=
# INFERENCE_TEXT_MODEL=
# INFERENCE_IMAGE_MODEL=
EOF
  chmod 600 "$ENV_FILE"
  msg_start "$RELEASE" >"$INSTALL_DIR"/version.txt
  msg_done "Configuration complete" && sleep 1

  msg_start "Creating users and modifying permissions..."
  useradd -U -s /usr/sbin/nologin -r -m -d "$M_DATA_DIR" meilisearch
  useradd -U -s /usr/sbin/nologin -r -M -d "$INSTALL_DIR" karakeep
  chown meilisearch:meilisearch "$M_CONFIG_FILE"
  chown -R karakeep:karakeep "$INSTALL_DIR" "$CONFIG_DIR" "$DATA_DIR" "$LOG_DIR"
  msg_done "Users created, permissions modified" && sleep 1

  msg_start "Creating service files..."
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

  cat <<EOF >/etc/systemd/system/karakeep-browser.service
[Unit]
Description=Karakeep headless browser
After=network.target

[Service]
User=root
Restart=on-failure
ExecStart=/usr/bin/chromium --headless --no-sandbox --disable-gpu --disable-dev-shm-usage --remote-debugging-address=127.0.0.1 --remote-debugging-port=9222 --hide-scrollbars
TimeoutStopSec=5
SyslogIdentifier=karakeep-browser

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
  msg_done "Service files created" && sleep 1

  msg_start "Enabling and starting services, please wait..." && sleep 3
  systemctl enable -q --now meilisearch.service karakeep.target
  msg_done "Done" && sleep 1

  msg_start "Cleaning up" && sleep 1
  rm /tmp/v"$RELEASE".zip
  $shh apt -y autoremove
  $shh apt -y autoclean
  msg_done "Cleaned" && sleep 1

  msg_done "OK, Karakeep should be accessible on port 3000 of this device's IP address!" && sleep 4
  exit 0
}

update() {
  echo "Checking for an update..." && sleep 1
  if [[ ! -d ${INSTALL_DIR} ]]; then
    die "Is Karakeep even installed?"
  fi
  RELEASE=$(curl -s https://api.github.com/repos/karakeep-app/karakeep/releases/latest | grep "tag_name" | awk '{print substr($2, 3, length($2)-4) }')
  PREV_RELEASE=$(cat "$INSTALL_DIR"/version.txt)
  if [[ "$RELEASE" != "$PREV_RELEASE" ]]; then
    if [[ "$(systemctl is-active karakeep-web)" == "active" ]]; then
      msg_start "Stopping affected services..." && sleep 1
      systemctl stop karakeep-web karakeep-workers
      msg_done "Stopped services" && sleep 1
    fi
    msg_start "Updating Karakeep to v${RELEASE}..." && sleep 1
    sed -i "s|SERVER_VERSION=${PREV_RELEASE}|SERVER_VERSION=${RELEASE}|" "$ENV_FILE"
    rm -R "$INSTALL_DIR"
    cd /tmp
    wget -q "https://github.com/karakeep-app/karakeep/archive/refs/tags/v${RELEASE}.zip"
    unzip -q v"$RELEASE".zip
    mv karakeep-"$RELEASE" "$INSTALL_DIR"
    # https://github.com/karakeep-app/karakeep/issues/967
    if [[ $(corepack -v) < "0.31.0" ]]; then
      $shh npm install -g corepack@0.31.0
    fi
    corepack enable
    export NEXT_TELEMETRY_DISABLED=1
    export PUPPETEER_SKIP_DOWNLOAD="true"
    export CI="true"
    cd "$INSTALL_DIR"/apps/web && $shh pnpm i --frozen-lockfile
    $shh pnpm exec next build --experimental-build-mode compile
    cd "$INSTALL_DIR"/apps/workers && $shh pnpm i --frozen-lockfile
    cd "$INSTALL_DIR"/apps/cli && $shh pnpm i --frozen-lockfile
    $shh pnpm build
    cd "$INSTALL_DIR"/packages/db && $shh pnpm migrate
    echo "$RELEASE" >"$INSTALL_DIR"/version.txt
    chown -R karakeep:karakeep "$INSTALL_DIR" "$DATA_DIR"
    msg_done "Updated Karakeep to v${RELEASE}" && sleep 1
    msg_start "Restarting services and cleaning up..." && sleep 1
    systemctl start karakeep-workers karakeep-web
    rm /tmp/v"$RELEASE".zip
    msg_done "Ready!"
  else
    msg_done "No update required."
  fi
  exit 0
}

migrate() {
  if [[ ! -d /opt/karakeep ]]; then
    msg_start "Migrating your Hoarder installation to Karakeep, then checking for an update..." && sleep 3
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
    msg_done "Migration complete!" && sleep 2
  else
    die "There is no need for a migration: Karakeep is already installed."
  fi
}

[ "$(id -u)" -ne 0 ] && die "This script requires root privileges. Please run with sudo or as the root user."

case "${args[0]}" in
install)
  install_karakeep
  ;;
update)
  update_karakeep
  ;;
migrate)
  migrate_karakeep && update_karakeep
  ;;
*)
  die "Unknown command. Choose 'install', 'update' or 'migrate.'"
  ;;
esac
