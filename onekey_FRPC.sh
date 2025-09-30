#!/usr/bin/env bash
set -euo pipefail

FRP_DIR="$HOME/.frp"
CONF="$FRP_DIR/frpc.ini"
LOG_DIR="$FRP_DIR/logs"
PID_FILE="$FRP_DIR/frpc.pid"

DEFAULT_VERSION="0.61.0"   # 如获取最新版本失败将回退到它
RELEASE_BASE="https://github.com/fatedier/frp/releases/download"

bold() { printf "\033[1m%s\033[0m\n" "$*"; }
info() { printf "[INFO] %s\n" "$*"; }
warn() { printf "[WARN] %s\n" "$*"; }
err()  { printf "[ERR ] %s\n" "$*" >&2; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { err "需要命令 $1，但未找到。"; exit 1; }
}

fetch() {
  local url="$1" out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 -o "$out" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$out" "$url"
  else
    err "既没有 curl 也没有 wget，无法下载。"
    exit 1
  fi
}

detect_arch() {
  local uos uarch pkg_arch
  uos="$(uname -s | tr '[:upper:]' '[:lower:]')"
  uarch="$(uname -m)"
  case "$uos" in
    linux) os="linux" ;;
    darwin) os="darwin" ;;  # 万一在 mac 上试验
    *) err "不支持的系统：$uos"; exit 1 ;;
  esac

  case "$uarch" in
    x86_64|amd64)   arch="amd64" ;;
    aarch64|arm64)  arch="arm64" ;;
    armv7l|armv7)   arch="arm" ;;
    i386|i686)      arch="386" ;;
    *) err "不支持的架构：$uarch"; exit 1 ;;
  esac

  echo "${os}_${arch}"
}

latest_version_or_default() {
  # 尝试获取最新 release tag；失败则回退 DEFAULT_VERSION
  local latest
  if command -v curl >/dev/null 2>&1; then
    latest="$(curl -s https://api.github.com/repos/fatedier/frp/releases/latest \
      | grep -Eo '"tag_name":\s*"v[0-9]+\.[0-9]+\.[0-9]+"' \
      | head -n1 | sed -E 's/.*"v([^"]+)".*/\1/')"
    if [[ -n "${latest:-}" ]]; then
      echo "$latest"
      return
    fi
  fi
  echo "$DEFAULT_VERSION"
}

download_frpc() {
  mkdir -p "$FRP_DIR" "$LOG_DIR"
  local pkg_arch version tarball url tmp
  pkg_arch="$(detect_arch)"
  read -r -p "下载版本（回车=最新，或填例如 0.61.0）: " version_input
  if [[ -z "${version_input:-}" ]]; then
    version="$(latest_version_or_default)"
  else
    version="$version_input"
  fi
  tarball="frp_${version}_${pkg_arch}.tar.gz"
  url="$RELEASE_BASE/v${version}/${tarball}"
  tmp="$(mktemp -d)"
  info "准备下载：$url"
  fetch "$url" "$tmp/$tarball"
  tar -xzf "$tmp/$tarball" -C "$tmp"
  # 解包目录名形如 frp_0.61.0_linux_amd64
  local unpack="$tmp/frp_${version}_${pkg_arch}"
  if [[ ! -x "$unpack/frpc" ]]; then
    err "解压后未发现 frpc 可执行文件。"
    exit 1
  fi
  install -m 0755 "$unpack/frpc" "$FRP_DIR/frpc"
  info "frpc 已安装到 $FRP_DIR/frpc"
  rm -rf "$tmp"
}

ask_common() {
  bold "== 配置 [common] =="
  read -r -p "server_addr (必填，例如 1.2.3.4 或 frps.example.com): " server_addr
  while [[ -z "$server_addr" ]]; do read -r -p "server_addr 不能为空，请重新输入: " server_addr; done

  read -r -p "server_port (默认7000): " server_port
  server_port="${server_port:-7000}"

  read -r -p "token (可空): " token
  read -r -p "login_user (可空): " login_user
  read -r -p "login_pwd (可空): " login_pwd
  read -r -p "metas（形如 k1=v1,k2=v2，可空）: " metas
  read -r -p "是否启用控制台面板 dashboard? (y/N): " dash_yn
  local dash_port dash_user dash_pwd
  if [[ "${dash_yn,,}" == "y" ]]; then
    read -r -p "dashboard_port (默认7500): " dash_port; dash_port="${dash_port:-7500}"
    read -r -p "dashboard_user (默认admin): " dash_user; dash_user="${dash_user:-admin}"
    read -r -p "dashboard_pwd  (默认admin): " dash_pwd;  dash_pwd="${dash_pwd:-admin}"
  fi

  {
    echo "[common]"
    echo "server_addr = $server_addr"
    echo "server_port = $server_port"
    [[ -n "$token" ]]      && echo "token = $token"
    [[ -n "$login_user" ]] && echo "user = $login_user"
    [[ -n "$login_pwd"  ]] && echo "passwd = $login_pwd"
    if [[ -n "$metas" ]]; then
      # 逗号分隔转成多行 metas.k=v
      IFS=',' read -ra kvs <<< "$metas"
      for kv in "${kvs[@]}"; do
        echo "metas.${kv// /}"
      done
    fi
    if [[ "${dash_yn,,}" == "y" ]]; then
      echo "dashboard_port = $dash_port"
      echo "dashboard_user = $dash_user"
      echo "dashboard_pwd = $dash_pwd"
    fi
    echo
  } > "$CONF"
}

add_proxy() {
  bold "== 添加一个代理条目 =="
  local name type
  while true; do
    read -r -p "代理名称（字母数字下划线，例如 ssh 或 web1）: " name
    [[ "$name" =~ ^[A-Za-z0-9_]+$ ]] && break || echo "名称不合法，请重输。"
  done

  while true; do
    echo "选择类型: 1) tcp  2) http  3) https  4) udp"
    read -r -p "输入数字 1/2/3/4: " sel
    case "$sel" in
      1) type="tcp"; break ;;
      2) type="http"; break ;;
      3) type="https"; break ;;
      4) type="udp"; break ;;
      *) echo "无效选择" ;;
    esac
  done

  if [[ "$type" == "tcp" || "$type" == "udp" ]]; then
    read -r -p "local_ip (默认127.0.0.1): " local_ip; local_ip="${local_ip:-127.0.0.1}"
    read -r -p "local_port (例如 22): " local_port
    while [[ -z "$local_port" ]]; do read -r -p "local_port 不能为空: " local_port; done
    read -r -p "remote_port（服务器暴露端口，例如 6000；留空=由 frps 分配，仅在支持时）: " remote_port
    {
      echo "[$name]"
      echo "type = $type"
      echo "local_ip = $local_ip"
      echo "local_port = $local_port"
      [[ -n "$remote_port" ]] && echo "remote_port = $remote_port"
      echo
    } >> "$CONF"

  elif [[ "$type" == "http" || "$type" == "https" ]]; then
    read -r -p "local_ip (默认127.0.0.1): " local_ip; local_ip="${local_ip:-127.0.0.1}"
    read -r -p "local_port (例如 8080): " local_port
    while [[ -z "$local_port" ]]; do read -r -p "local_port 不能为空: " local_port; done
    read -r -p "custom_domains（域名，多个用逗号分隔）: " custom_domains
    read -r -p "locations（可空，path 前缀，多个逗号分隔）: " locations
    read -r -p "host_header_rewrite（可空）: " hosthdr
    {
      echo "[$name]"
      echo "type = $type"
      echo "local_ip = $local_ip"
      echo "local_port = $local_port"
      [[ -n "$custom_domains" ]] && echo "custom_domains = ${custom_domains// /}"
      [[ -n "$locations" ]]      && echo "locations = ${locations// /}"
      [[ -n "$hosthdr" ]]        && echo "host_header_rewrite = $hosthdr"
      echo
    } >> "$CONF"
  fi

  # 可选：额外 header/健康检查/带宽等进阶设置，你可后续手动编辑 $CONF
}

interactive_build_config() {
  ask_common
  while true; do
    add_proxy
    read -r -p "继续添加下一个代理？(Y/n): " yn
    [[ "${yn,,}" == "n" ]] && break
  done
  bold "已写入配置：$CONF"
  echo "----------"
  sed -n '1,200p' "$CONF"
  echo "----------"
}

is_running() {
  if [[ -f "$PID_FILE" ]]; then
    local p; p="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null; then
      return 0
    fi
  fi
  return 1
}

start_frpc() {
  if is_running; then
    info "frpc 已在运行 (pid $(cat "$PID_FILE"))."
    return
  fi
  mkdir -p "$LOG_DIR"
  nohup "$FRP_DIR/frpc" -c "$CONF" >>"$LOG_DIR/frpc.log" 2>&1 &
  echo $! > "$PID_FILE"
  info "frpc 已启动。pid=$(cat "$PID_FILE")，日志：$LOG_DIR/frpc.log"
}

stop_frpc() {
  if is_running; then
    local p; p="$(cat "$PID_FILE")"
    kill "$p" || true
    sleep 0.5
    if kill -0 "$p" 2>/dev/null; then
      warn "进程仍存活，尝试强杀。"
      kill -9 "$p" || true
    fi
    rm -f "$PID_FILE"
    info "frpc 已停止。"
  else
    info "frpc 未在运行。"
  fi
}

status_frpc() {
  if is_running; then
    info "frpc 运行中 (pid $(cat "$PID_FILE")). 最近日志："
    tail -n 20 "$LOG_DIR/frpc.log" || true
  else
    info "frpc 未在运行。"
    [[ -f "$LOG_DIR/frpc.log" ]] && tail -n 20 "$LOG_DIR/frpc.log" || true
  fi
}

install_cron() {
  read -r -p "是否添加开机自启（crontab @reboot）？(y/N): " yn
  if [[ "${yn,,}" != "y" ]]; then
    return
  fi
  local line="@reboot nohup $FRP_DIR/frpc -c $CONF >> $LOG_DIR/frpc.log 2>&1 &"
  # 避免重复添加
  local tmp; tmp="$(mktemp)"
  crontab -l 2>/dev/null | grep -vF "$FRP_DIR/frpc -c $CONF" > "$tmp" || true
  echo "$line" >> "$tmp"
  crontab "$tmp"
  rm -f "$tmp"
  info "已写入 crontab 自启。"
}

menu() {
  bold "=== frpc 无 root 交互式部署脚本 ==="
  echo "工作目录   : $FRP_DIR"
  echo "配置文件   : $CONF"
  echo "日志目录   : $LOG_DIR"
  echo

  PS3="请选择功能(输入序号): "
  select opt in \
    "下载/更新 frpc" \
    "交互式生成/修改配置" \
    "启动 frpc" \
    "停止 frpc" \
    "查看状态/日志" \
    "写入开机自启 (@reboot)" \
    "退出"
  do
    case "$REPLY" in
      1) download_frpc ;;
      2) interactive_build_config ;;
      3) start_frpc ;;
      4) stop_frpc ;;
      5) status_frpc ;;
      6) install_cron ;;
      7) exit 0 ;;
      *) echo "无效选择";;
    esac
  done
}

main() {
  mkdir -p "$FRP_DIR" "$LOG_DIR"
  menu
}

main "$@"
