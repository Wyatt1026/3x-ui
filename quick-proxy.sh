#!/usr/bin/env bash

set -Eeuo pipefail

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
blue='\033[0;34m'
plain='\033[0m'

APP_NAME="xray-node-manager"
SCRIPT_VERSION="2026.04.29.3"
XRAY_BIN="/usr/local/bin/xray"
CONFIG_DIR="/usr/local/etc/${APP_NAME}"
CONFIG_FILE="${CONFIG_DIR}/config.json"
NODES_FILE="${CONFIG_DIR}/nodes.db"
HOST_FILE="${CONFIG_DIR}/host"
QUICK_PROXY_CMD="/usr/local/bin/quick-proxy"
SERVICE_NAME="${APP_NAME}"
SYSTEMD_SERVICE="/etc/systemd/system/${SERVICE_NAME}.service"
OPENRC_SERVICE="/etc/init.d/${SERVICE_NAME}"
SCRIPT_SOURCE_URL="https://raw.githubusercontent.com/Wyatt1026/3x-ui/main/quick-proxy.sh"
OFFICIAL_XRAY_LATEST="https://github.com/XTLS/Xray-core/releases/latest/download"
OFFICIAL_INSTALL_SCRIPT="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"
MAX_NODES="${XRAY_NODE_MAX_NODES:-200}"

log_i() { echo -e "${green}[INF]${plain} $*"; }
log_w() { echo -e "${yellow}[WRN]${plain} $*"; }
log_e() { echo -e "${red}[ERR]${plain} $*"; }

pause() {
    echo
    read -r -p "按回车返回菜单: " _
}

need_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        log_e "请使用 root 运行此脚本。"
        exit 1
    fi
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1
}

install_pkg() {
    local pkg="$1"
    local detector="${2:-$1}"
    need_cmd "$detector" && return 0

    log_i "正在安装依赖: ${pkg}"
    if need_cmd apt-get; then
        DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null
        DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" >/dev/null
    elif need_cmd dnf; then
        dnf install -y "$pkg" >/dev/null
    elif need_cmd yum; then
        yum install -y "$pkg" >/dev/null
    elif need_cmd apk; then
        apk add --no-cache "$pkg" >/dev/null
    elif need_cmd pacman; then
        pacman -Sy --noconfirm "$pkg" >/dev/null
    else
        log_e "未找到可用包管理器，请先手动安装 ${pkg}。"
        return 1
    fi
}

copy_script_file() {
    local source_path="$1"
    local target_path="$2"
    local tmp_target
    [[ -f "$source_path" && -r "$source_path" ]] || return 1
    mkdir -p "$(dirname "$target_path")"
    tmp_target="${target_path}.tmp.$$"
    if cp "$source_path" "$tmp_target" && chmod 755 "$tmp_target" && mv "$tmp_target" "$target_path"; then
        return 0
    fi
    rm -f "$tmp_target"
    return 1
}

download_panel_script() {
    local output_path="$1"
    need_cmd curl || install_pkg curl curl || return 1
    curl -fsSL --retry 3 --connect-timeout 10 --max-time 60 \
        -H 'Cache-Control: no-cache' \
        -o "$output_path" \
        "${SCRIPT_SOURCE_URL}?ts=$(date +%s)"
}

install_quick_proxy_command() {
    local source_path real_source real_target tmp_script
    source_path="${BASH_SOURCE[0]:-$0}"
    real_source="$(readlink -f "$source_path" 2>/dev/null || true)"
    real_target="$(readlink -f "$QUICK_PROXY_CMD" 2>/dev/null || true)"

    if [[ -n "$real_source" && -n "$real_target" && "$real_source" == "$real_target" ]]; then
        chmod 755 "$QUICK_PROXY_CMD" 2>/dev/null || true
        return 0
    fi

    if copy_script_file "$source_path" "$QUICK_PROXY_CMD" 2>/dev/null; then
        log_i "已安装快捷命令: quick-proxy"
        return 0
    fi

    tmp_script="$(mktemp)"
    if download_panel_script "$tmp_script" && bash -n "$tmp_script" && copy_script_file "$tmp_script" "$QUICK_PROXY_CMD"; then
        rm -f "$tmp_script"
        log_i "已安装快捷命令: quick-proxy"
        return 0
    fi

    rm -f "$tmp_script"
    log_w "未能安装快捷命令 quick-proxy，可稍后通过菜单更新面板重试。"
    return 1
}

init_store() {
    mkdir -p "$CONFIG_DIR"
    touch "$NODES_FILE"
    chmod 700 "$CONFIG_DIR"
    chmod 600 "$NODES_FILE"
}

json_escape() {
    local s="${1:-}"
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\n'/}
    s=${s//$'\r'/}
    printf '%s' "$s"
}

urlencode() {
    local s="${1:-}"
    local LC_ALL=C
    local out="" c hex ord i
    for ((i = 0; i < ${#s}; i++)); do
        c="${s:i:1}"
        case "$c" in
        [a-zA-Z0-9.~_-]) out+="$c" ;;
        ' ') out+="%20" ;;
        *)
            printf -v ord '%d' "'$c"
            printf -v hex '%%%02X' "$((ord & 255))"
            out+="$hex"
            ;;
        esac
    done
    printf '%s' "$out"
}

b64() {
    base64 | tr -d '\n'
}

b64_url_nopad() {
    base64 | tr -d '\n' | tr '+/' '-_' | sed 's/=*$//'
}

random_password() {
    if need_cmd openssl; then
        openssl rand -base64 24 | tr -d '\n'
    else
        random_hex 32
    fi
}

random_hex() {
    local len="$1"
    local out=""
    while ((${#out} < len)); do
        out+="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
    done
    printf '%s' "${out:0:len}"
}

random_uuid() {
    if need_cmd uuidgen; then
        uuidgen | tr 'A-Z' 'a-z'
    elif [[ -r /proc/sys/kernel/random/uuid ]]; then
        cat /proc/sys/kernel/random/uuid
    else
        local h
        h="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
        printf '%s-%s-%s-%s-%s\n' "${h:0:8}" "${h:8:4}" "${h:12:4}" "${h:16:4}" "${h:20:12}"
    fi
}

sanitize_field() {
    local s="${1:-}"
    s=${s//$'\r'/}
    s=${s//$'\n'/}
    s=${s//$'\t'/ }
    s=${s//|/-}
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

valid_port() {
    local port="${1:-}"
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    ((port >= 1 && port <= 65535))
}

valid_ipv4() {
    local ip="${1:-}" octet
    local -a octets
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS='.' read -r -a octets <<<"$ip"
    for octet in "${octets[@]}"; do
        ((10#$octet <= 255)) || return 1
    done
}

valid_domain() {
    local domain="${1:-}" label last_label=""
    local -a labels
    (( ${#domain} >= 1 && ${#domain} <= 253 )) || return 1
    [[ "$domain" =~ ^[A-Za-z0-9.-]+$ ]] || return 1
    [[ "$domain" != .* && "$domain" != *. && "$domain" != *..* ]] || return 1
    [[ ! "$domain" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1

    IFS='.' read -r -a labels <<<"$domain"
    for label in "${labels[@]}"; do
        ((${#label} >= 1 && ${#label} <= 63)) || return 1
        [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
        last_label="$label"
    done
    [[ "$last_label" =~ [A-Za-z] ]]
}

valid_entry_host() {
    valid_ipv4 "$1" || valid_domain "$1"
}

port_exists_in_nodes() {
    local port="$1"
    awk -F'|' -v p="$port" 'NF >= 5 && $5 == p { found = 1 } END { exit found ? 0 : 1 }' "$NODES_FILE"
}

node_count_file() {
    local file="$1"
    awk -F'|' 'NF >= 5 && $1 !~ /^#/ { c++ } END { print c + 0 }' "$file" 2>/dev/null || echo 0
}

port_in_use() {
    local port="$1"
    if need_cmd ss; then
        ss -lntup 2>/dev/null | awk -v p=":${port}$" '$5 ~ p { found = 1 } END { exit found ? 0 : 1 }'
        return $?
    fi
    if need_cmd netstat; then
        netstat -lntup 2>/dev/null | awk -v p=":${port}$" '$4 ~ p { found = 1 } END { exit found ? 0 : 1 }'
        return $?
    fi
    if need_cmd lsof; then
        lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1 && return 0
    fi
    return 1
}

detect_arch() {
    case "$(uname -m)" in
    x86_64 | amd64) echo "64" ;;
    aarch64 | arm64) echo "arm64-v8a" ;;
    armv7l) echo "arm32-v7a" ;;
    armv6l) echo "arm32-v6" ;;
    i386 | i686) echo "32" ;;
    *)
        log_e "暂不支持当前架构: $(uname -m)"
        return 1
        ;;
    esac
}

install_xray_from_release() {
    install_pkg curl curl
    install_pkg unzip unzip

    local arch tmp zip url
    arch="$(detect_arch)"
    tmp="$(mktemp -d)"
    zip="${tmp}/xray.zip"
    url="${OFFICIAL_XRAY_LATEST}/Xray-linux-${arch}.zip"

    log_i "从 XTLS/Xray-core 官方 release 下载 Xray: ${url}"
    curl -fL --retry 3 --connect-timeout 10 --max-time 180 -o "$zip" "$url"
    if need_cmd sha256sum && curl -fsSL --connect-timeout 10 --max-time 60 -o "${zip}.dgst" "${url}.dgst"; then
        local checksum localsum
        checksum="$(awk -F '= ' '/256=/ { print $2; exit }' "${zip}.dgst")"
        localsum="$(sha256sum "$zip" | awk '{ print $1 }')"
        if [[ -n "$checksum" && "$checksum" != "$localsum" ]]; then
            rm -rf "$tmp"
            log_e "Xray 压缩包校验失败，已中止安装。"
            return 1
        fi
    else
        log_w "未完成 sha256 校验，将继续使用 GitHub 官方下载文件。"
    fi
    unzip -q "$zip" -d "$tmp"
    install -m 755 "${tmp}/xray" "$XRAY_BIN"
    rm -rf "$tmp"
}

install_xray_with_official_script() {
    install_pkg curl curl
    log_i "尝试使用 XTLS/Xray-install 官方脚本安装 Xray。"
    bash -c "$(curl -fL --retry 3 --connect-timeout 10 --max-time 180 "$OFFICIAL_INSTALL_SCRIPT")" @ install --without-geodata --without-logfiles
    if need_cmd systemctl; then
        systemctl disable --now xray >/dev/null 2>&1 || true
    fi
}

ensure_xray() {
    if [[ -x "$XRAY_BIN" ]]; then
        return 0
    fi
    if need_cmd xray; then
        XRAY_BIN="$(command -v xray)"
        return 0
    fi

    log_w "未检测到 Xray，开始自动安装。"
    if need_cmd systemctl; then
        install_xray_with_official_script || install_xray_from_release
    else
        install_xray_from_release
    fi

    if [[ ! -x "$XRAY_BIN" ]]; then
        log_e "Xray 安装失败，未找到 ${XRAY_BIN}。"
        exit 1
    fi
}

render_config_from_nodes() {
    local nodes_path="$1"
    local output_path="$2"
    local first=1
    local node_id protocol remark listen port method password uuid created entry_host

    {
        cat <<'JSON_HEAD'
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
JSON_HEAD

        while IFS='|' read -r node_id protocol remark listen port method password uuid created entry_host; do
            [[ -z "${node_id:-}" || "${node_id:0:1}" == "#" ]] && continue
            [[ "$protocol" == "ss" || "$protocol" == "vless" ]] || continue

            if [[ "$first" -eq 0 ]]; then
                printf ',\n'
            fi
            first=0

            local tag safe_remark safe_listen safe_method safe_password safe_uuid
            safe_remark="$(json_escape "$remark")"
            safe_listen="$(json_escape "${listen:-0.0.0.0}")"
            tag="$(json_escape "${protocol}-${remark}-${port}")"

            if [[ "$protocol" == "ss" ]]; then
                safe_method="$(json_escape "$method")"
                safe_password="$(json_escape "$password")"
                cat <<JSON_SS
    {
      "tag": "${tag}",
      "listen": "${safe_listen}",
      "port": ${port},
      "protocol": "shadowsocks",
      "settings": {
        "method": "${safe_method}",
        "password": "${safe_password}",
        "network": "tcp,udp"
      },
      "sniffing": {
        "enabled": false
      }
    }
JSON_SS
            else
                safe_uuid="$(json_escape "$uuid")"
                cat <<JSON_VLESS
    {
      "tag": "${tag}",
      "listen": "${safe_listen}",
      "port": ${port},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${safe_uuid}",
            "email": "${safe_remark}"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "none",
        "tcpSettings": {
          "header": {
            "type": "none"
          }
        }
      },
      "sniffing": {
        "enabled": false
      }
    }
JSON_VLESS
            fi
        done <"$nodes_path"

        cat <<'JSON_TAIL'

  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom"
    },
    {
      "tag": "block",
      "protocol": "blackhole"
    }
  ]
}
JSON_TAIL
    } >"$output_path"
}

validate_config() {
    local file="$1"
    "$XRAY_BIN" test -config "$file" >/tmp/${APP_NAME}-xray-test.log 2>&1 && return 0
    "$XRAY_BIN" run -test -config "$file" >/tmp/${APP_NAME}-xray-test.log 2>&1 && return 0
    cat "/tmp/${APP_NAME}-xray-test.log" >&2 || true
    return 1
}

make_tmp_config() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    printf '%s/config.json' "$tmp_dir"
}

cleanup_tmp_config() {
    local file="${1:-}"
    [[ -n "$file" ]] || return 0
    rm -f "$file"
    rmdir "$(dirname "$file")" 2>/dev/null || true
}

service_backend() {
    if [[ -d /run/systemd/system ]] && need_cmd systemctl; then
        echo "systemd"
    elif need_cmd rc-service && [[ -d /etc/init.d ]]; then
        echo "openrc"
    else
        echo "none"
    fi
}

install_service() {
    local backend
    backend="$(service_backend)"

    case "$backend" in
    systemd)
        cat >"$SYSTEMD_SERVICE" <<EOF
[Unit]
Description=Standalone Xray Node Manager
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${XRAY_BIN} run -config ${CONFIG_FILE}
Restart=on-failure
RestartSec=3s
LimitNOFILE=65535
Nice=5
OOMScoreAdjust=100
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable "$SERVICE_NAME" >/dev/null
        ;;
    openrc)
        cat >"$OPENRC_SERVICE" <<EOF
#!/sbin/openrc-run

description="Standalone Xray Node Manager"
command="${XRAY_BIN}"
command_args="run -config ${CONFIG_FILE}"
command_background=true
pidfile="/run/${SERVICE_NAME}.pid"

depend() {
    need net
}
EOF
        chmod +x "$OPENRC_SERVICE"
        rc-update add "$SERVICE_NAME" default >/dev/null 2>&1 || true
        ;;
    *)
        log_e "未检测到 systemd 或 OpenRC，无法创建后台服务。"
        return 1
        ;;
    esac
}

restart_service() {
    local backend
    backend="$(service_backend)"

    case "$backend" in
    systemd)
        systemctl restart "$SERVICE_NAME"
        ;;
    openrc)
        rc-service "$SERVICE_NAME" restart >/dev/null 2>&1 || rc-service "$SERVICE_NAME" start
        ;;
    *)
        return 1
        ;;
    esac
}

stop_service() {
    local backend
    backend="$(service_backend)"

    case "$backend" in
    systemd)
        systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
        ;;
    openrc)
        rc-service "$SERVICE_NAME" stop >/dev/null 2>&1 || true
        ;;
    esac
}

service_status() {
    local backend
    backend="$(service_backend)"

    case "$backend" in
    systemd)
        if systemctl is-active --quiet "$SERVICE_NAME"; then
            echo "running"
        else
            echo "not running"
        fi
        ;;
    openrc)
        if rc-service "$SERVICE_NAME" status 2>/dev/null | grep -q "status: started"; then
            echo "running"
        else
            echo "not running"
        fi
        ;;
    *)
        echo "unknown"
        ;;
    esac
}

detect_public_host() {
    if [[ -n "${XRAY_NODE_HOST:-}" ]]; then
        if valid_entry_host "$XRAY_NODE_HOST"; then
            printf '%s' "$XRAY_NODE_HOST"
            return 0
        fi
        log_w "XRAY_NODE_HOST 不是 IPv4 或域名，已忽略。"
    fi
    if [[ -s "$HOST_FILE" ]]; then
        local saved_host
        saved_host="$(tr -d '\r\n' <"$HOST_FILE")"
        if valid_entry_host "$saved_host"; then
            printf '%s' "$saved_host"
            return 0
        fi
    fi

    local host="" candidate
    if need_cmd curl; then
        host="$(curl -4fsS --connect-timeout 3 --max-time 5 https://api.ipify.org 2>/dev/null || true)"
        [[ -z "$host" ]] && host="$(curl -4fsS --connect-timeout 3 --max-time 5 https://ifconfig.me/ip 2>/dev/null || true)"
        valid_ipv4 "$host" || host=""
    fi
    if [[ -z "$host" ]] && need_cmd hostname; then
        for candidate in $(hostname -I 2>/dev/null || true); do
            if valid_ipv4 "$candidate"; then
                host="$candidate"
                break
            fi
        done
    fi
    [[ -z "$host" ]] && host="YOUR_SERVER_IP"
    [[ "$host" != "YOUR_SERVER_IP" ]] && printf '%s' "$host" >"$HOST_FILE"
    printf '%s' "$host"
}

node_link() {
    local protocol="$1" remark="$2" port="$3" method="$4" password="$5" uuid="$6" entry_host="${7:-}"
    local host encoded_remark
    host="${entry_host:-$(detect_public_host)}"
    encoded_remark="$(urlencode "$remark")"

    if [[ "$protocol" == "ss" ]]; then
        local userinfo
        userinfo="$(printf '%s' "${method}:${password}" | b64_url_nopad)"
        printf 'ss://%s@%s:%s#%s\n' "$userinfo" "$host" "$port" "$encoded_remark"
    else
        printf 'vless://%s@%s:%s?encryption=none&security=none&type=tcp&headerType=none#%s\n' "$uuid" "$host" "$port" "$encoded_remark"
    fi
}

print_node_line() {
    local node_id="$1" protocol="$2" remark="$3" listen="$4" port="$5" method="$6" password="$7" uuid="$8" created="$9" entry_host="${10:-}"
    local proto_name display_host
    [[ "$protocol" == "ss" ]] && proto_name="Shadowsocks" || proto_name="VLESS + TCP"
    display_host="${entry_host:-$(detect_public_host)}"

    echo -e "${blue}--------------------------------------------------${plain}"
    echo "ID: ${node_id}"
    echo "协议: ${proto_name}"
    echo "备注: ${remark}"
    echo "入口地址: ${display_host}"
    echo "监听: ${listen}"
    echo "端口: ${port}"
    if [[ "$protocol" == "ss" ]]; then
        echo "加密: ${method}"
        echo "密码: ${password}"
    else
        echo "UUID: ${uuid}"
        echo "传输: TCP (RAW)"
        echo "加密: none"
    fi
    echo "创建时间: ${created}"
    echo "链接:"
    node_link "$protocol" "$remark" "$port" "$method" "$password" "$uuid" "$entry_host"
}

list_nodes() {
    init_store
    local node_id protocol remark listen port method password uuid created entry_host

    if [[ ! -s "$NODES_FILE" ]]; then
        log_w "还没有创建任何节点。"
        return 0
    fi

    while IFS='|' read -r node_id protocol remark listen port method password uuid created entry_host; do
        [[ -z "${node_id:-}" || "${node_id:0:1}" == "#" ]] && continue
        print_node_line "$node_id" "$protocol" "$remark" "$listen" "$port" "$method" "$password" "$uuid" "$created" "$entry_host"
    done <"$NODES_FILE"
    echo -e "${blue}--------------------------------------------------${plain}"
    echo "服务状态: $(service_status)"
}

ask_remark_and_port() {
    local remark port
    if (( $(node_count_file "$NODES_FILE") >= MAX_NODES )); then
        log_e "当前节点数量已达到上限 ${MAX_NODES}，为避免监听端口过多导致资源压力，已拒绝继续创建。"
        return 1
    fi

    while true; do
        read -r -p "请输入备注: " remark
        remark="$(sanitize_field "$remark")"
        [[ -n "$remark" ]] && break
        log_w "备注不能为空。"
    done

    while true; do
        read -r -p "请输入端口 [1-65535]: " port
        port="$(sanitize_field "$port")"
        if ! valid_port "$port"; then
            log_w "端口必须是 1-65535 的数字。"
            continue
        fi
        if port_exists_in_nodes "$port"; then
            log_w "端口 ${port} 已被本脚本创建的节点使用。"
            continue
        fi
        if port_in_use "$port"; then
            log_w "端口 ${port} 当前已有进程监听，请换一个端口。"
            continue
        fi
        break
    done

    REPLY_REMARK="$remark"
    REPLY_PORT="$port"
}

ask_entry_host() {
    local custom entry_host
    read -r -p "是否自定义入口 IP/域名？默认否，自动使用出口 IP [y/N]: " custom
    custom="$(sanitize_field "$custom")"

    case "$custom" in
    y | Y | yes | YES | Yes)
        while true; do
            read -r -p "请输入入口 IPv4 或域名: " entry_host
            entry_host="$(sanitize_field "$entry_host")"
            if valid_entry_host "$entry_host"; then
                break
            fi
            log_w "入口地址格式不正确，请输入 IPv4 或域名。"
        done
        ;;
    *)
        entry_host="$(detect_public_host)"
        if [[ "$entry_host" == "YOUR_SERVER_IP" ]]; then
            log_w "未能自动检测出口 IP，链接中将暂用 YOUR_SERVER_IP。"
        else
            log_i "将使用出口 IP 作为入口地址: ${entry_host}"
        fi
        ;;
    esac

    REPLY_ENTRY_HOST="$entry_host"
}

commit_new_node() {
    local protocol="$1" remark="$2" port="$3" entry_host="$4"
    local node_id listen method password uuid created tmp_nodes tmp_config

    node_id="$(date +%s)-$(random_hex 5)"
    listen="0.0.0.0"
    method=""
    password=""
    uuid=""
    created="$(date '+%Y-%m-%d %H:%M:%S')"

    if [[ "$protocol" == "ss" ]]; then
        method="chacha20-ietf-poly1305"
        password="$(random_password)"
    else
        uuid="$(random_uuid)"
    fi

    tmp_nodes="$(mktemp)"
    tmp_config="$(make_tmp_config)"
    cat "$NODES_FILE" >"$tmp_nodes"
    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' "$node_id" "$protocol" "$remark" "$listen" "$port" "$method" "$password" "$uuid" "$created" "$entry_host" >>"$tmp_nodes"

    render_config_from_nodes "$tmp_nodes" "$tmp_config"
    if ! validate_config "$tmp_config"; then
        rm -f "$tmp_nodes"
        cleanup_tmp_config "$tmp_config"
        log_e "生成的 Xray 配置未通过校验，已放弃写入。"
        return 1
    fi

    mv "$tmp_config" "$CONFIG_FILE"
    cleanup_tmp_config "$tmp_config"
    mv "$tmp_nodes" "$NODES_FILE"
    chmod 600 "$NODES_FILE" "$CONFIG_FILE"

    install_service || return 1
    if ! restart_service; then
        log_e "服务重启失败，请检查端口占用或系统日志。"
        return 1
    fi

    log_i "节点创建成功。"
    print_node_line "$node_id" "$protocol" "$remark" "$listen" "$port" "$method" "$password" "$uuid" "$created" "$entry_host"
}

create_node() {
    local protocol="$1"
    init_store
    ensure_xray
    ask_remark_and_port || return 0
    ask_entry_host || return 0
    commit_new_node "$protocol" "$REPLY_REMARK" "$REPLY_PORT" "$REPLY_ENTRY_HOST"
}

delete_node() {
    init_store
    if [[ ! -s "$NODES_FILE" ]]; then
        log_w "没有可删除的节点。"
        return 0
    fi

    echo "当前节点:"
    awk -F'|' 'NF >= 5 { printf "%s) [%s] %s : %s\n", $1, $2, $3, $5 }' "$NODES_FILE"
    echo
    read -r -p "请输入要删除的节点 ID: " target
    target="$(sanitize_field "$target")"
    if [[ -z "$target" ]]; then
        log_w "已取消。"
        return 0
    fi

    if ! awk -F'|' -v id="$target" '$1 == id { found = 1 } END { exit found ? 0 : 1 }' "$NODES_FILE"; then
        log_w "未找到节点 ID: ${target}"
        return 0
    fi

    local tmp_nodes tmp_config
    tmp_nodes="$(mktemp)"
    tmp_config="$(make_tmp_config)"
    awk -F'|' -v id="$target" '$1 != id' "$NODES_FILE" >"$tmp_nodes"
    if (( $(node_count_file "$tmp_nodes") > 0 )); then
        render_config_from_nodes "$tmp_nodes" "$tmp_config"
        if ! validate_config "$tmp_config"; then
            rm -f "$tmp_nodes"
            cleanup_tmp_config "$tmp_config"
            log_e "删除后的 Xray 配置未通过校验，已放弃写入。"
            return 1
        fi
        mv "$tmp_config" "$CONFIG_FILE"
        cleanup_tmp_config "$tmp_config"
        mv "$tmp_nodes" "$NODES_FILE"
        chmod 600 "$NODES_FILE" "$CONFIG_FILE"
        install_service || return 1
        if ! restart_service; then
            log_e "服务重启失败，请检查端口占用或系统日志。"
            return 1
        fi
    else
        render_config_from_nodes "$tmp_nodes" "$tmp_config"
        mv "$tmp_config" "$CONFIG_FILE"
        cleanup_tmp_config "$tmp_config"
        mv "$tmp_nodes" "$NODES_FILE"
        chmod 600 "$NODES_FILE" "$CONFIG_FILE"
        stop_service
    fi

    log_i "节点已删除。"
}

update_panel() {
    local tmp_script new_version
    tmp_script="$(mktemp)"

    log_i "正在下载最新面板脚本..."
    if ! download_panel_script "$tmp_script"; then
        rm -f "$tmp_script"
        log_e "下载面板脚本失败，请检查网络。"
        return 1
    fi

    if ! bash -n "$tmp_script"; then
        rm -f "$tmp_script"
        log_e "下载的面板脚本语法检查失败，已放弃更新。"
        return 1
    fi

    new_version="$(awk -F'"' '/^SCRIPT_VERSION=/ { print $2; exit }' "$tmp_script")"
    if ! copy_script_file "$tmp_script" "$QUICK_PROXY_CMD"; then
        rm -f "$tmp_script"
        log_e "安装快捷命令 quick-proxy 失败。"
        return 1
    fi
    rm -f "$tmp_script"

    log_i "面板已更新: v${new_version:-unknown}"
    log_i "快捷命令: quick-proxy"
    exec "$QUICK_PROXY_CMD"
}

show_runtime_info() {
    echo -e "${blue}独立 Xray 节点管理脚本 v${SCRIPT_VERSION}${plain}"
    echo "配置目录: ${CONFIG_DIR}"
    echo "节点数量: $(awk -F'|' 'NF >= 5 { c++ } END { print c + 0 }' "$NODES_FILE" 2>/dev/null || echo 0)"
    echo "服务状态: $(service_status)"
    if [[ -x "$XRAY_BIN" ]]; then
        "$XRAY_BIN" version 2>/dev/null | head -n 1 || true
    fi
    echo
}

menu() {
    need_root
    init_store
    install_quick_proxy_command || true
    while true; do
        clear 2>/dev/null || true
        show_runtime_info
        echo "1. 创建 Shadowsocks 节点"
        echo "2. 创建 VLESS + TCP 节点"
        echo "3. 查看已创建节点信息"
        echo "4. 删除节点"
        echo "5. 更新面板"
        echo "0. 退出"
        echo
        read -r -p "请选择功能 [0-5]: " choice
        case "$choice" in
        1)
            create_node "ss" || log_e "创建 Shadowsocks 节点失败。"
            pause
            ;;
        2)
            create_node "vless" || log_e "创建 VLESS + TCP 节点失败。"
            pause
            ;;
        3)
            list_nodes
            pause
            ;;
        4)
            ensure_xray
            delete_node || log_e "删除节点失败。"
            pause
            ;;
        5)
            update_panel || log_e "更新面板失败。"
            pause
            ;;
        0)
            exit 0
            ;;
        *)
            log_w "请输入 0-5。"
            sleep 1
            ;;
        esac
    done
}

menu "$@"
