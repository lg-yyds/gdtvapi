#!/usr/bin/env bash
set -u

# =============================================================
# Clean Argo Node v10: Xray + cloudflared + Chinese news + node page
# 单文件版：开机自启 / 后台保活 / 定时重启都在这一个文件里，
# 不需要额外的 .service 或安装脚本。
#   bash start-one.sh install    一键装开机自启（有 systemd 装 service，
#                               没有就用 cron @reboot + 每 5 分钟 check 兜底）
#   bash start-one.sh uninstall 拆掉开机自启（service + cron 都清掉）
#   bash start-one.sh start      后台启动（守护循环，崩溃自动重启）
#   bash start-one.sh stop | restart | status | check
#   bash start-one.sh run        前台运行（默认，systemd 用的就是它）
# Edit this top section only.
# =============================================================

# Fixed Cloudflare Tunnel mode:
#   ARGO_TOKEN="your tunnel token"
#   ARGO_DOMAIN="your.domain.com"
#   ALLOW_TEMP_TUNNEL="0"
# Temporary trycloudflare mode:
#   ARGO_TOKEN=""
#   ARGO_DOMAIN=""
#   ALLOW_TEMP_TUNNEL="1"
ARGO_TOKEN="eyJhIjoiODI5YTk4Y2NkMDFlMmJlZDk1MGM3NTgwYjdjZmQwMDkiLCJ0IjoiNTEwZTYwNzQtZWUzOC00ZmI0LWFkNGMtMDg2MDA5N2NmMjRjIiwicyI6IlpETTFabVUxWWpJdFltSXdNeTAwTVRkaUxUbGxPR0V0TkdRMk1ESmtOamd5WW1OayJ9"
ARGO_DOMAIN="hk.euss.eu.org"
ALLOW_TEMP_TUNNEL="1"

UUID="b1daf633-8044-4e16-ac35-a19ba7151121"
VPATH="vls"
XRAY_PORT="8080"

# Optional Cloudflare preferred IP/domain used as VLESS Address.
# Host/SNI will still be the real Argo domain.
CF_PREFERRED=""

# Protocol used by cloudflared to reach Cloudflare edge: quic or http2.
ARGO_PROTOCOL="http2"

# Update cloudflared on every restart:
#   "1" = check the latest GitHub release before starting, download only
#         if it is newer than the installed binary. If the check or the
#         download fails, keep the old binary and warn instead of exiting,
#         so a network hiccup never takes the node down.
#   "0" = old behaviour: reuse the installed binary forever.
# Note: cloudflared is started below with --no-autoupdate, so this check
# is the only update path; without it the binary would never be updated.
UPDATE_CLOUDFLARED="1"
#   "1" = re-download on every restart even when the version is unchanged.
#         Slower, but also repairs a corrupted binary. Normally leave "0".
FORCE_UPDATE_CLOUDFLARED="0"

# ---- 开机自启 / 后台保活 / 定时重启（新增，可改）----
# 定时重启：每隔多少小时整机重启一次，重启时顺带检查更新 cloudflared。
#   "24" = 每天重启一次；"0" = 关闭定时重启，只在崩溃时重启。
AUTO_RESTART_HOURS="24"
# 监控间隔（秒）：每隔多久检查一次 Xray / cloudflared 是否还活着。
CHECK_INTERVAL="30"
# 子进程崩溃 / 定时重启后，等待多少秒再拉起来。
RESTART_BACKOFF="5"

# =============================================================
# Do not edit below unless you know what you are doing.
# =============================================================

ROOT="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$ROOT/bin"
RUNTIME_DIR="$ROOT/runtime"
LOG_DIR="$ROOT/logs"
XRAY_BIN="$BIN_DIR/xray"
CLOUDFLARED_BIN="$BIN_DIR/cloudflared"
XRAY_CONFIG="$RUNTIME_DIR/xray-config.json"
CLIENT_LINK_FILE="$RUNTIME_DIR/client-link.txt"
CLIENT_CONFIG_FILE="$RUNTIME_DIR/client-config.txt"
STATUS_FILE="$RUNTIME_DIR/status.json"
XRAY_LOG="$LOG_DIR/xray.log"
CF_LOG="$LOG_DIR/cloudflared.log"
PID_FILE="$RUNTIME_DIR/argo-node.pid"
NODE_PID_FILE="$RUNTIME_DIR/argo-node.node.pid"
DAEMON_LOG="$LOG_DIR/daemon.log"
SCRIPT_SELF="$ROOT/$(basename "${BASH_SOURCE[0]:-$0}")"

mkdir -p "$BIN_DIR" "$RUNTIME_DIR" "$LOG_DIR"
: > "$XRAY_LOG"
: > "$CF_LOG"

log() { echo "$*"; }
json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
urlencode_path() {
  local p="$1"
  p="${p#/}"
  printf '%%2F%s' "$p"
}

write_status() {
  local state="$1"
  local argo_domain="${2:-}"
  local xpid="${XRAY_PID:-}"
  local cpid="${CF_PID:-}"
  cat > "$STATUS_FILE" <<EOF_STATUS
{
  "state": "$(json_escape "$state")",
  "time": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "xray_pid": "$(json_escape "$xpid")",
  "cloudflared_pid": "$(json_escape "$cpid")",
  "xray_port": "$(json_escape "$XRAY_PORT")",
  "vpath": "$(json_escape "$VPATH")",
  "argo_domain": "$(json_escape "$argo_domain")",
  "preferred_address": "$(json_escape "$CF_PREFERRED")"
}
EOF_STATUS
}

arch="$(uname -m)"
case "$arch" in
  x86_64|amd64)
    XRAY_ZIP_URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip"
    CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
    ;;
  aarch64|arm64)
    XRAY_ZIP_URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-arm64-v8a.zip"
    CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64"
    ;;
  *)
    log "[ERROR] unsupported architecture: $arch"
    exit 1
    ;;
esac

if ! command -v curl >/dev/null 2>&1; then
  log "[ERROR] curl not found"
  exit 1
fi
if ! command -v unzip >/dev/null 2>&1; then
  log "[ERROR] unzip not found"
  exit 1
fi

install_xray() {
  if [ -x "$XRAY_BIN" ]; then
    log "[xray] found: $XRAY_BIN"
    return
  fi
  log "[xray] downloading official Xray-core for $arch..."
  tmpzip="$RUNTIME_DIR/xray.zip"
  tmpdir="$RUNTIME_DIR/xray-unzip"
  rm -rf "$tmpdir" "$tmpzip"
  mkdir -p "$tmpdir"
  curl -L --fail --connect-timeout 15 --max-time 120 -o "$tmpzip" "$XRAY_ZIP_URL" || exit 1
  unzip -q "$tmpzip" -d "$tmpdir" || exit 1
  found="$(find "$tmpdir" -type f -name xray | head -n 1 || true)"
  if [ -z "$found" ]; then
    log "[ERROR] xray binary not found in archive"
    exit 1
  fi
  cp "$found" "$XRAY_BIN"
  chmod +x "$XRAY_BIN"
  log "[xray] installed: $XRAY_BIN"
}

cloudflared_version() {
  # Prints e.g. 2025.8.1, or nothing if the binary is missing/broken.
  if [ ! -x "$1" ]; then
    return 0
  fi
  "$1" --version 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 || true
}

latest_cloudflared_version() {
  # No GitHub API token needed: /releases/latest redirects to /tag/vX.Y.Z.
  # Using the redirect avoids the unauthenticated API rate limit (60/hr).
  local final_url tag
  final_url="$(curl -fsSL --connect-timeout 10 --max-time 20 -o /dev/null -w '%{url_effective}' \
    'https://github.com/cloudflare/cloudflared/releases/latest' 2>/dev/null || true)"
  tag="${final_url##*/}"
  tag="${tag#v}"
  case "$tag" in
    [0-9]*.[0-9]*.[0-9]*) printf '%s' "$tag" ;;
    *) printf '' ;;
  esac
}

download_cloudflared() {
  # Download to a temp file in the same directory, verify it runs, then
  # move it over the old binary. A failed download never clobbers the
  # working binary, because the old file is only replaced on success.
  local tmp="$BIN_DIR/cloudflared.new"
  rm -f "$tmp"
  if ! curl -L --fail --connect-timeout 15 --max-time 120 -o "$tmp" "$CF_URL"; then
    rm -f "$tmp"
    return 1
  fi
  chmod +x "$tmp"
  if ! "$tmp" --version >/dev/null 2>&1; then
    log "[cloudflared] downloaded file failed its version check, discarding it"
    rm -f "$tmp"
    return 1
  fi
  if [ -x "$CLOUDFLARED_BIN" ]; then
    cp "$CLOUDFLARED_BIN" "$CLOUDFLARED_BIN.bak" 2>/dev/null || true
  fi
  mv "$tmp" "$CLOUDFLARED_BIN"
  chmod +x "$CLOUDFLARED_BIN"
  return 0
}

update_cloudflared() {
  # Only called when a binary already exists. Never fatal: on any failure
  # the old binary stays in place and the node still starts.
  if [ "$UPDATE_CLOUDFLARED" != "1" ]; then
    log "[cloudflared] update check disabled (UPDATE_CLOUDFLARED != 1)"
    return 0
  fi
  if [ "$FORCE_UPDATE_CLOUDFLARED" = "1" ]; then
    log "[cloudflared] forced re-download on restart..."
    if download_cloudflared; then
      log "[cloudflared] updated to: $(cloudflared_version "$CLOUDFLARED_BIN")"
    else
      log "[WARN] forced cloudflared re-download failed; keeping existing binary"
    fi
    return 0
  fi
  local current latest
  current="$(cloudflared_version "$CLOUDFLARED_BIN")"
  latest="$(latest_cloudflared_version)"
  if [ -z "$latest" ]; then
    log "[WARN] could not check latest cloudflared release; keeping ${current:-unknown version}"
    return 0
  fi
  if [ "$current" = "$latest" ]; then
    log "[cloudflared] already latest: $current"
    return 0
  fi
  log "[cloudflared] updating: ${current:-unknown} -> $latest ..."
  if download_cloudflared; then
    log "[cloudflared] updated to: $(cloudflared_version "$CLOUDFLARED_BIN")"
  else
    log "[WARN] cloudflared update failed; keeping ${current:-existing binary}"
  fi
  return 0
}

install_cloudflared() {
  if [ -x "$CLOUDFLARED_BIN" ]; then
    log "[cloudflared] found: $CLOUDFLARED_BIN (version $(cloudflared_version "$CLOUDFLARED_BIN"))"
    update_cloudflared
    return
  fi
  log "[cloudflared] downloading official cloudflared for $arch..."
  download_cloudflared || exit 1
  log "[cloudflared] installed: $CLOUDFLARED_BIN (version $(cloudflared_version "$CLOUDFLARED_BIN"))"
}

write_xray_config() {
  local path_clean="/${VPATH#/}"
  cat > "$XRAY_CONFIG" <<EOF_JSON
{
  "log": {"loglevel": "warning"},
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": $XRAY_PORT,
      "protocol": "vless",
      "settings": {
        "clients": [{"id": "$UUID", "flow": ""}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {"path": "$path_clean"}
      }
    }
  ],
  "outbounds": [{"protocol": "freedom", "tag": "direct"}]
}
EOF_JSON
}

print_client_link() {
  local argo_url="$1"
  local domain="${argo_url#https://}"
  domain="${domain#http://}"
  domain="${domain%%/*}"
  local address="$domain"
  local note="direct Argo address"
  if [ -n "$CF_PREFERRED" ]; then
    address="$CF_PREFERRED"
    note="using preferred Cloudflare address; Host/SNI keep the real Argo domain"
  fi
  local path_enc
  path_enc="$(urlencode_path "$VPATH")"
  local link="vless://${UUID}@${address}:443?encryption=none&security=tls&type=ws&host=${domain}&sni=${domain}&path=${path_enc}#KataBump-Argo-VLESS"

  cat > "$CLIENT_LINK_FILE" <<EOF_LINK
$link
EOF_LINK
  cat > "$CLIENT_CONFIG_FILE" <<EOF_CONF
Protocol : VLESS
Address  : $address
Port     : 443
UUID     : $UUID
Network  : ws
Security : tls
Host     : $domain
SNI      : $domain
Path     : /${VPATH#/}
Note     : $note
EOF_CONF

  log "[client] temporary/fixed domain detected: https://$domain"
  log "======================== CLIENT LINK ========================"
  log "$link"
  log "Manual config:"
  cat "$CLIENT_CONFIG_FILE"
  log "============================================================="
}

start_xray() {
  write_xray_config
  log "[xray] starting on 127.0.0.1:$XRAY_PORT path=/${VPATH#/}"
  "$XRAY_BIN" run -config "$XRAY_CONFIG" >> "$XRAY_LOG" 2>&1 &
  XRAY_PID=$!
  sleep 1
  if ! kill -0 "$XRAY_PID" >/dev/null 2>&1; then
    log "[ERROR] Xray failed to start. Log:"
    cat "$XRAY_LOG"
    exit 1
  fi
  cat "$XRAY_LOG" || true
}

start_cloudflared() {
  : > "$CF_LOG"
  if [ -n "$ARGO_TOKEN" ]; then
    log "[cloudflared] starting named tunnel with token..."
    "$CLOUDFLARED_BIN" tunnel --no-autoupdate run --token "$ARGO_TOKEN" >> "$CF_LOG" 2>&1 &
    CF_PID=$!
    if [ -n "$ARGO_DOMAIN" ]; then
      print_client_link "https://$ARGO_DOMAIN"
    else
      log "[client] ARGO_DOMAIN not set; fixed tunnel link cannot be printed automatically."
    fi
  else
    if [ "$ALLOW_TEMP_TUNNEL" != "1" ]; then
      log "[ERROR] ARGO_TOKEN is empty and ALLOW_TEMP_TUNNEL is not 1"
      exit 1
    fi
    log "[cloudflared] ARGO_TOKEN is empty. Starting temporary trycloudflare tunnel..."
    "$CLOUDFLARED_BIN" tunnel --url "http://127.0.0.1:$XRAY_PORT" --protocol "$ARGO_PROTOCOL" --no-autoupdate --ha-connections 1 >> "$CF_LOG" 2>&1 &
    CF_PID=$!
    log "[cloudflared] Waiting for https://xxxx.trycloudflare.com in logs..."
    (
      printed=0
      for _ in $(seq 1 120); do
        if [ ! -f "$CF_LOG" ]; then sleep 1; continue; fi
        domain_line="$(grep -Eo 'https://[-a-z0-9]+\.trycloudflare\.com' "$CF_LOG" | head -n 1 || true)"
        if [ -n "$domain_line" ]; then
          print_client_link "$domain_line"
          printed=1
          break
        fi
        sleep 1
      done
      if [ "$printed" != "1" ]; then
        log "[WARN] did not detect trycloudflare domain within timeout. Check /logs."
      fi
    ) &
  fi
  sleep 1
  if ! kill -0 "$CF_PID" >/dev/null 2>&1; then
    log "[ERROR] cloudflared failed to start. Log:"
    cat "$CF_LOG"
    exit 1
  fi
}

cleanup() {
  log "[system] stopping..."
  [ -n "${CF_PID:-}" ] && kill "$CF_PID" >/dev/null 2>&1 || true
  [ -n "${XRAY_PID:-}" ] && kill "$XRAY_PID" >/dev/null 2>&1 || true
  if [ -f "$NODE_PID_FILE" ] && [ "$(cat "$NODE_PID_FILE" 2>/dev/null || true)" = "$$" ]; then
    rm -f "$NODE_PID_FILE" 2>/dev/null || true
  fi
}
# Intentional stop: exit code 10 tells the supervisor / systemd wrapper
# not to restart. Any other exit (crash, scheduled restart 42) restarts.
on_term() {
  trap - EXIT
  cleanup
  exit 10
}
# NOTE: traps are installed only in `run` mode, after the command
# dispatch below. Installing them here would make `status` / `check`
# delete the node pid file and print "[system] stopping..." on exit.

is_alive() { [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null; }

wait_for_exit() {
  local pid="$1" i
  for i in $(seq 1 10); do
    is_alive "$pid" || return 0
    sleep 1
  done
  kill -9 "$pid" >/dev/null 2>&1 || true
  return 0
}

daemon_status() {
  local alive=0 pid=""
  if [ -f "$PID_FILE" ]; then
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if is_alive "$pid"; then log "[status] supervisor running, pid $pid"; alive=1; else log "[status] supervisor pid file stale: $pid"; fi
  fi
  if [ -f "$NODE_PID_FILE" ]; then
    pid="$(cat "$NODE_PID_FILE" 2>/dev/null || true)"
    if is_alive "$pid"; then log "[status] node running, pid $pid"; alive=1; else log "[status] node pid file stale: $pid"; fi
  fi
  if [ -f "$STATUS_FILE" ]; then
    log "[status] $(cat "$STATUS_FILE" 2>/dev/null | tr -d '\n ' || true)"
  fi
  if [ "$alive" = "1" ]; then return 0; fi
  log "[status] not running"
  return 1
}

daemon_start() {
  local oldpid="" pid="" bgpid=""
  if [ -f "$PID_FILE" ]; then
    oldpid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if is_alive "$oldpid"; then log "[daemon] already running, supervisor pid $oldpid"; return 0; fi
    log "[daemon] removing stale supervisor pid file: $oldpid"
    rm -f "$PID_FILE"
  fi
  if [ -f "$NODE_PID_FILE" ]; then
    oldpid="$(cat "$NODE_PID_FILE" 2>/dev/null || true)"
    if is_alive "$oldpid"; then log "[daemon] node already running, pid $oldpid (maybe systemd)"; return 0; fi
    log "[daemon] removing stale node pid file: $oldpid"
    rm -f "$NODE_PID_FILE"
  fi

  log "[daemon] starting in background, log: $DAEMON_LOG"
  # 注意：BusyBox 的 setsid 不支持 --wait，直接 nohup 更通用。
  # supervise_loop 内部会 echo $$ > PID_FILE，所以最终 PID 会被写成正确值。
  nohup bash "$SCRIPT_SELF" supervise >> "$DAEMON_LOG" 2>&1 < /dev/null &
  bgpid=$!
  sleep 2

  # 优先用 supervise 自己写下的 PID
  if [ -f "$PID_FILE" ]; then
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if is_alive "$pid"; then
      log "[daemon] started, supervisor pid $pid"
      daemon_status || true
      return 0
    fi
  fi
  # 兜底：如果 nohup 直接 exec 了，$! 就是 supervise 的 PID
  if is_alive "$bgpid"; then
    echo "$bgpid" > "$PID_FILE"
    log "[daemon] started, supervisor pid $bgpid"
    daemon_status || true
    return 0
  fi

  log "[ERROR] daemon failed to start, check $DAEMON_LOG"
  tail -n 50 "$DAEMON_LOG" 2>/dev/null || true
  return 1
}

daemon_stop() {
  local pid=""
  if [ -f "$PID_FILE" ]; then
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if is_alive "$pid"; then log "[daemon] stopping supervisor pid $pid..."; kill "$pid" >/dev/null 2>&1 || true; wait_for_exit "$pid"; fi
    rm -f "$PID_FILE"
  fi
  if [ -f "$NODE_PID_FILE" ]; then
    pid="$(cat "$NODE_PID_FILE" 2>/dev/null || true)"
    if is_alive "$pid"; then log "[daemon] stopping node pid $pid..."; kill "$pid" >/dev/null 2>&1 || true; wait_for_exit "$pid"; fi
    rm -f "$NODE_PID_FILE"
  fi
  log "[daemon] stopped"
  return 0
}

# Cron watchdog, every 5 min: if nothing is alive, start the daemon.
# If the supervisor is alive but the node just died, the supervisor
# restarts it within RESTART_BACKOFF seconds, so do nothing here.
watchdog_check() {
  local pid=""
  if [ -f "$NODE_PID_FILE" ]; then
    pid="$(cat "$NODE_PID_FILE" 2>/dev/null || true)"
    if is_alive "$pid"; then log "[check] node running, pid $pid"; return 0; fi
  fi
  if [ -f "$PID_FILE" ]; then
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if is_alive "$pid"; then log "[check] supervisor running, node restarting..."; return 0; fi
  fi
  log "[check] node not running, starting daemon..."
  daemon_start
}

# Internal mode, launched by `start`. Loops `run` forever, except on
# intentional stop (exit 10). 5 quick crashes in a row -> cool down 60s.
supervise_loop() {
  echo $$ > "$PID_FILE"
  local consecutive=0 start_ts end_ts elapsed rc
  # 兜底：supervisor 被 kill 时把当前 run 子进程也带走，避免孤儿进程占 8080
  trap 'kill ${CUR_RUN_PID:-0} 2>/dev/null || true; rm -f "$PID_FILE"' EXIT
  while true; do
    start_ts="$(date +%s)"
    bash "$SCRIPT_SELF" run &
    CUR_RUN_PID=$!
    wait "$CUR_RUN_PID"; rc=$?
    CUR_RUN_PID=""
    if [ "$rc" = "10" ]; then
      log "[supervise] intentional stop (code 10), exiting supervisor"
      rm -f "$PID_FILE"
      return 0
    fi
    end_ts="$(date +%s)"
    elapsed=$((end_ts - start_ts))
    if [ "$elapsed" -lt 60 ]; then consecutive=$((consecutive + 1)); else consecutive=0; fi
    if [ "$consecutive" -ge 5 ]; then
      log "[supervise] 5 quick failures in a row, cooling down 60s before retry"
      sleep 60
      consecutive=0
    else
      sleep "$RESTART_BACKOFF"
    fi
    log "[supervise] restarting node (last exit $rc)..."
  done
}

# ---- 一键安装 / 卸载开机自启（单文件版，替代原来的 install-autostart.sh）----
install_autostart() {
  local sudo_cmd="" unit_path="${ARGO_SERVICE_PATH:-/etc/systemd/system/argo-node.service}"
  mkdir -p "$LOG_DIR" "$RUNTIME_DIR"
  if [ "$(id -u)" != "0" ] && sudo -n true 2>/dev/null; then sudo_cmd="sudo"; fi
  if command -v systemctl >/dev/null 2>&1 && { [ "$(id -u)" = "0" ] || [ -n "$sudo_cmd" ]; }; then
    log "[install] 检测到 systemd，安装 argo-node.service ..."
    local tmp_unit="$RUNTIME_DIR/argo-node.service"
    cat > "$tmp_unit" <<EOF_UNIT
[Unit]
Description=Clean Argo Node - Xray + cloudflared
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$ROOT
ExecStart=/bin/bash $SCRIPT_SELF run
Restart=always
RestartSec=10
StartLimitIntervalSec=0
KillMode=control-group
TimeoutStopSec=15
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF_UNIT
    if [ -n "$sudo_cmd" ]; then $sudo_cmd cp "$tmp_unit" "$unit_path"; else cp "$tmp_unit" "$unit_path"; fi
    $sudo_cmd systemctl daemon-reload
    $sudo_cmd systemctl enable argo-node.service
    # 先停掉之前手动后台跑的那份，避免和 systemd 抢 8080 端口
    daemon_stop >/dev/null 2>&1 || true
    $sudo_cmd systemctl restart argo-node.service
    sleep 2
    $sudo_cmd systemctl status argo-node.service --no-pager || true
    log "[install] 已开机自启。查看日志：sudo journalctl -u argo-node -f"
    log "[install] 手动重启：sudo systemctl restart argo-node；停止：sudo systemctl stop argo-node"
    return 0
  fi

  log "[install] 没有可用的 systemd/root 权限，走 cron 兜底 ..."
  if ! command -v crontab >/dev/null 2>&1; then
    log "[WARN] 没有 crontab，只能手动后台启动：bash $SCRIPT_SELF start"
    log "[WARN] 并在面板/主机设置里把开机命令设为：bash $SCRIPT_SELF start"
    daemon_start
    return $?
  fi

  # 用当前脚本的绝对路径做标记，避免旧版硬编码 start-3.sh 造成的重复条目
  local marker="bash $SCRIPT_SELF"
  ( crontab -l 2>/dev/null | grep -vF "$marker" || true
    echo "@reboot sleep 10 && bash $SCRIPT_SELF start >> $DAEMON_LOG 2>&1"
    echo "*/5 * * * * bash $SCRIPT_SELF check >> $DAEMON_LOG 2>&1"
  ) | crontab -

  log "[install] cron 已写入："
  crontab -l 2>/dev/null | grep -F "$marker" || true

  if daemon_start; then
    daemon_status || true
    log "[install] 已后台启动。重启服务器后会自动拉起，每 5 分钟还会自查一次。"
    log "[install] 手动重启：bash $SCRIPT_SELF restart；停止：bash $SCRIPT_SELF stop"
    return 0
  else
    log "[ERROR] cron 已写入，但本次后台启动失败，请检查 $DAEMON_LOG"
    log "[install] 手动启动：bash $SCRIPT_SELF start"
    return 1
  fi
}

uninstall_autostart() {
  local sudo_cmd="" unit_path="${ARGO_SERVICE_PATH:-/etc/systemd/system/argo-node.service}"
  if [ "$(id -u)" != "0" ] && sudo -n true 2>/dev/null; then sudo_cmd="sudo"; fi
  daemon_stop >/dev/null 2>&1 || true
  if command -v systemctl >/dev/null 2>&1 && { [ "$(id -u)" = "0" ] || [ -n "$sudo_cmd" ]; }; then
    $sudo_cmd systemctl disable --now argo-node.service >/dev/null 2>&1 || true
    if [ -n "$sudo_cmd" ]; then $sudo_cmd rm -f "$unit_path"; else rm -f "$unit_path"; fi
    $sudo_cmd systemctl daemon-reload >/dev/null 2>&1 || true
    log "[uninstall] systemd service 已拆除"
  fi
  if command -v crontab >/dev/null 2>&1; then
    local marker="bash $SCRIPT_SELF"
    ( crontab -l 2>/dev/null | grep -vF "$marker" || true ) | crontab - 2>/dev/null || true
    log "[uninstall] cron 里的 $(basename "$SCRIPT_SELF") 条目已清除"
  fi
  log "[uninstall] 完成，节点已停止且不再开机自启"
  return 0
}

# ---- 命令：run（前台，默认）/ start / stop / restart / status / check / install / uninstall ----
MODE="${1:-run}"
case "$MODE" in
  start)   daemon_start; exit $? ;;
  stop)    daemon_stop; exit $? ;;
  restart) daemon_stop; sleep 1; daemon_start; exit $? ;;
  status)  daemon_status; exit $? ;;
  check)   watchdog_check; exit $? ;;
  supervise) supervise_loop; exit $? ;;
  install)   install_autostart; exit $? ;;
  uninstall) uninstall_autostart; exit $? ;;
  run|"")  ;;
  *) log "Usage: bash $0 {run|start|stop|restart|status|check|install|uninstall}"; exit 2 ;;
esac
trap on_term INT TERM
trap cleanup EXIT
echo $$ > "$NODE_PID_FILE"

log "============================================================="
log "Clean Argo Node v10 ZH NEWS + NODE PAGE for KataBump / generic Node.js hosting"
log "Official binaries only: cloudflared + Xray-core"
log "Address mode: preferred=${CF_PREFERRED:-none} | Host/SNI=real Argo domain"
log "Node status page: http://0.0.0.0:${NODE_STATUS_PORT:-unknown}"
log "============================================================="

install_xray
install_cloudflared
start_xray
start_cloudflared
write_status "running" "${ARGO_DOMAIN:-}"

log "[system] running. This loop monitors Xray/cloudflared every ${CHECK_INTERVAL}s; scheduled restart every ${AUTO_RESTART_HOURS}h (0 = off)."

NODE_START_EPOCH="$(date +%s)"
while true; do
  if [ "$AUTO_RESTART_HOURS" -gt 0 ] 2>/dev/null; then
    _now="$(date +%s)"
    _elapsed_h=$(( (_now - NODE_START_EPOCH) / 3600 ))
    if [ "$_elapsed_h" -ge "$AUTO_RESTART_HOURS" ]; then
      log "[system] scheduled restart after ${AUTO_RESTART_HOURS}h, restarting to refresh tunnel and update cloudflared..."
      write_status "scheduled_restart" "${ARGO_DOMAIN:-}"
      exit 42
    fi
  fi
  if ! kill -0 "$XRAY_PID" >/dev/null 2>&1; then
    log "[ERROR] Xray process exited. Last log:"
    tail -n 80 "$XRAY_LOG" || true
    write_status "xray_exited" "${ARGO_DOMAIN:-}"
    exit 1
  fi
  if ! kill -0 "$CF_PID" >/dev/null 2>&1; then
    log "[ERROR] cloudflared process exited. Last log:"
    tail -n 120 "$CF_LOG" || true
    write_status "cloudflared_exited" "${ARGO_DOMAIN:-}"
    exit 1
  fi
  detected_domain="$(grep -Eo 'https://[-a-z0-9]+\.trycloudflare\.com' "$CF_LOG" | head -n 1 || true)"
  write_status "running" "${ARGO_DOMAIN:-$detected_domain}"
  sleep "${CHECK_INTERVAL:-30}"
done