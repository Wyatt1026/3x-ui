#!/usr/bin/env bash

set -Eeuo pipefail

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
blue='\033[0;34m'
plain='\033[0m'

APP_NAME="xray-node-manager"
SCRIPT_VERSION="2026.04.29.7"
DEFAULT_PROXY_CORE="singbox"
XRAY_BIN_DEFAULT="/usr/local/bin/xray"
SINGBOX_BIN_DEFAULT="/usr/local/bin/sing-box"
SINGBOX_INSTALL_DIR="/usr/local/lib/sing-box"
CONFIG_DIR="/usr/local/etc/${APP_NAME}"
CONFIG_FILE="${CONFIG_DIR}/config.json"
NODES_FILE="${CONFIG_DIR}/nodes.db"
HOST_FILE="${CONFIG_DIR}/host"
CORE_FILE="${CONFIG_DIR}/core"
QUICK_PROXY_CMD="/usr/local/bin/quick-proxy"
SERVICE_NAME="${APP_NAME}"
SYSTEMD_SERVICE="/etc/systemd/system/${SERVICE_NAME}.service"
OPENRC_SERVICE="/etc/init.d/${SERVICE_NAME}"
SCRIPT_SOURCE_URL="https://raw.githubusercontent.com/Wyatt1026/3x-ui/main/quick-proxy.sh"
OFFICIAL_XRAY_LATEST="https://github.com/XTLS/Xray-core/releases/latest/download"
SINGBOX_RELEASE_API="https://api.github.com/repos/SagerNet/sing-box/releases/latest"
SINGBOX_RELEASE_BASE="https://github.com/SagerNet/sing-box/releases/download"
OFFICIAL_XRAY_SYSTEMD_SERVICE="/etc/systemd/system/xray.service"
OFFICIAL_XRAY_OPENRC_SERVICE="/etc/init.d/xray"
SERVICE_LOG_FILE="/var/log/${SERVICE_NAME}.log"
MAX_NODES="${XRAY_NODE_MAX_NODES:-200}"
PROXY_CORE=""
PROXY_NAME="Xray"
PROXY_BIN="${XRAY_BIN_DEFAULT}"

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

normalize_proxy_core() {
    case "${1:-}" in
    singbox | sing-box | sb)
        printf 'singbox\n'
        ;;
    xray)
        printf 'xray\n'
        ;;
    *)
        return 1
        ;;
    esac
}

set_core_runtime_vars() {
    case "$1" in
    singbox)
        PROXY_CORE="singbox"
        PROXY_NAME="sing-box"
        PROXY_BIN="$SINGBOX_BIN_DEFAULT"
        ;;
    xray)
        PROXY_CORE="xray"
        PROXY_NAME="Xray"
        PROXY_BIN="$XRAY_BIN_DEFAULT"
        ;;
    *)
        log_e "不支持的代理核心: $1"
        return 1
        ;;
    esac
}

load_selected_core() {
    local saved_core=""
    if [[ -s "$CORE_FILE" ]]; then
        saved_core="$(tr -d '\r\n' <"$CORE_FILE")"
    fi

    if ! saved_core="$(normalize_proxy_core "$saved_core" 2>/dev/null)"; then
        saved_core="$DEFAULT_PROXY_CORE"
    fi

    set_core_runtime_vars "$saved_core"
}

persist_selected_core() {
    [[ -n "$PROXY_CORE" ]] || return 1
    printf '%s\n' "$PROXY_CORE" >"$CORE_FILE"
    chmod 600 "$CORE_FILE"
}

detect_existing_core_from_config() {
    [[ -s "$CONFIG_FILE" ]] || return 1

    if grep -q '"listen_port"[[:space:]]*:' "$CONFIG_FILE"; then
        printf 'singbox\n'
        return 0
    fi

    if grep -q '"loglevel"[[:space:]]*:' "$CONFIG_FILE"; then
        printf 'xray\n'
        return 0
    fi

    return 1
}

choose_core_if_needed() {
    local choice selected_core detected_core

    if [[ -s "$CORE_FILE" ]]; then
        load_selected_core
        return 0
    fi

    if [[ -s "$CONFIG_FILE" ]] || (( $(node_count_file "$NODES_FILE") > 0 )); then
        if detected_core="$(detect_existing_core_from_config 2>/dev/null)"; then
            set_core_runtime_vars "$detected_core"
            persist_selected_core
            log_i "检测到已有节点配置，已沿用历史核心: ${PROXY_NAME}"
            return 0
        fi

        log_w "检测到已有节点配置，但无法自动识别历史核心，请手动确认。"
    fi

    echo "请选择代理核心:"
    echo "1. sing-box (默认)"
    echo "2. Xray"
    read -r -p "请输入 [1-2]，直接回车默认 sing-box: " choice
    choice="$(sanitize_field "$choice")"

    case "$choice" in
    "" | 1)
        selected_core="singbox"
        ;;
    2)
        selected_core="xray"
        ;;
    singbox | sing-box | sb | xray)
        selected_core="$(normalize_proxy_core "$choice")"
        ;;
    *)
        log_w "输入无效，已默认选择 sing-box。"
        selected_core="$DEFAULT_PROXY_CORE"
        ;;
    esac

    set_core_runtime_vars "$selected_core"
    persist_selected_core
    log_i "已选择代理核心: ${PROXY_NAME}"
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

random_base64_bytes() {
    local byte_len="$1"
    if need_cmd openssl; then
        openssl rand -base64 "$byte_len" | tr -d '\n'
        return 0
    fi
    if need_cmd base64; then
        dd if=/dev/urandom bs=1 count="$byte_len" 2>/dev/null | b64
        return 0
    fi
    return 1
}

random_password() {
    local method="${1:-}"

    case "$method" in
    2022-blake3-aes-128-gcm)
        random_base64_bytes 16 && return 0
        ;;
    2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305)
        random_base64_bytes 32 && return 0
        ;;
    esac

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

detect_xray_arch() {
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

detect_singbox_arch() {
    case "$(uname -m)" in
    x86_64 | amd64) echo "amd64" ;;
    aarch64 | arm64) echo "arm64" ;;
    armv7l) echo "armv7" ;;
    armv6l) echo "armv6" ;;
    i386 | i686) echo "386" ;;
    *)
        log_e "暂不支持当前架构: $(uname -m)"
        return 1
        ;;
    esac
}

detect_libc_variant() {
    local ldd_output=""

    if [[ -f /etc/alpine-release ]]; then
        printf 'musl\n'
        return 0
    fi

    if need_cmd ldd; then
        ldd_output="$(ldd --version 2>&1 || true)"
        case "$ldd_output" in
        *musl*)
            printf 'musl\n'
            return 0
            ;;
        *glibc* | *"GNU C Library"* | *"GNU libc"* | *"GNU Libc"* | *"ldd (GNU libc)"*)
            printf 'glibc\n'
            return 0
            ;;
        esac
    fi

    if need_cmd getconf && getconf GNU_LIBC_VERSION >/dev/null 2>&1; then
        printf 'glibc\n'
    else
        printf 'unknown\n'
    fi
}

singbox_asset_suffixes() {
    local arch="$1"
    local libc_variant="$2"

    case "$arch" in
    amd64 | arm64 | armv7 | 386)
        case "$libc_variant" in
        musl)
            printf '%s\n' '-musl' '' '-glibc'
            ;;
        glibc)
            printf '%s\n' '-glibc' '' '-musl'
            ;;
        *)
            printf '%s\n' '' '-glibc' '-musl'
            ;;
        esac
        ;;
    *)
        printf '%s\n' ''
        ;;
    esac
}

verify_singbox_binary_path() {
    local binary_path="$1"
    local binary_dir version_log
    binary_dir="$(dirname "$binary_path")"
    version_log="/tmp/${APP_NAME}-singbox-candidate.log"

    LD_LIBRARY_PATH="${binary_dir}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" "$binary_path" version >"$version_log" 2>&1 && return 0
    cat "$version_log" >&2 || true
    return 1
}

install_singbox_payload() {
    local source_dir="$1"
    local staging wrapper_tmp

    [[ -x "${source_dir}/sing-box" ]] || return 1

    mkdir -p "$(dirname "$SINGBOX_INSTALL_DIR")" "$(dirname "$SINGBOX_BIN_DEFAULT")"
    staging="${SINGBOX_INSTALL_DIR}.tmp.$$"
    wrapper_tmp="${SINGBOX_BIN_DEFAULT}.tmp.$$"
    rm -rf "$staging" "$wrapper_tmp"
    mkdir -p "$staging"

    cp -R "${source_dir}/." "$staging"/
    chmod 755 "${staging}/sing-box"

    cat >"$wrapper_tmp" <<EOF
#!/usr/bin/env sh
SINGBOX_DIR="${SINGBOX_INSTALL_DIR}"
export LD_LIBRARY_PATH="\${SINGBOX_DIR}\${LD_LIBRARY_PATH:+:\${LD_LIBRARY_PATH}}"
exec "\${SINGBOX_DIR}/sing-box" "\$@"
EOF
    chmod 755 "$wrapper_tmp"

    rm -rf "$SINGBOX_INSTALL_DIR"
    mv "$staging" "$SINGBOX_INSTALL_DIR"
    mv "$wrapper_tmp" "$SINGBOX_BIN_DEFAULT"
}

latest_singbox_version() {
    install_pkg curl curl || return 1

    local response tag
    response="$(curl -fsSL --retry 3 --connect-timeout 10 --max-time 60 "$SINGBOX_RELEASE_API")" || return 1
    tag="$(printf '%s' "$response" | awk -F'"' '/"tag_name":/ { print $4; exit }')"
    [[ -n "$tag" ]] || return 1
    printf '%s\n' "${tag#v}"
}

install_xray_from_release() {
    install_pkg curl curl
    install_pkg unzip unzip

    local arch tmp zip url
    arch="$(detect_xray_arch)"
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
    install -m 755 "${tmp}/xray" "$XRAY_BIN_DEFAULT"
    rm -rf "$tmp"
}

install_singbox_from_release() {
    install_pkg curl curl || return 1
    need_cmd tar || install_pkg tar tar || return 1

    local arch version tmp archive binary_path libc_variant suffix candidate_url candidate_tmp
    local candidate_index=0
    local found_asset=0
    arch="$(detect_singbox_arch)"
    version="$(latest_singbox_version)" || {
        log_e "获取 sing-box 最新版本失败。"
        return 1
    }
    libc_variant="$(detect_libc_variant)"

    tmp="$(mktemp -d)"

    while IFS= read -r suffix; do
        candidate_index=$((candidate_index + 1))
        candidate_tmp="${tmp}/candidate-${candidate_index}"
        archive="${candidate_tmp}/sing-box.tar.gz"
        candidate_url="${SINGBOX_RELEASE_BASE}/v${version}/sing-box-${version}-linux-${arch}${suffix}.tar.gz"
        mkdir -p "$candidate_tmp"

        log_i "检测到系统 libc: ${libc_variant}"
        log_i "尝试下载 sing-box release 资产: ${candidate_url}"
        if ! curl -fL --retry 3 --connect-timeout 10 --max-time 180 -o "$archive" "$candidate_url"; then
            log_w "该 sing-box release 资产不可用，继续尝试下一个。"
            continue
        fi
        found_asset=1

        if ! tar -xzf "$archive" -C "$candidate_tmp"; then
            log_w "该 sing-box 压缩包解压失败，继续尝试下一个。"
            continue
        fi

        binary_path="$(find "$candidate_tmp" -type f -name 'sing-box' 2>/dev/null | sed -n '1p')"
        if [[ -z "$binary_path" || ! -f "$binary_path" ]]; then
            log_w "该 sing-box 压缩包中未找到可执行文件，继续尝试下一个。"
            continue
        fi
        chmod 755 "$binary_path" 2>/dev/null || true

        if ! verify_singbox_binary_path "$binary_path"; then
            log_w "该 sing-box 二进制无法在当前系统执行，继续尝试下一个。"
            continue
        fi

        if ! install_singbox_payload "$(dirname "$binary_path")"; then
            rm -rf "$tmp"
            log_e "安装 sing-box 文件失败。"
            return 1
        fi
        rm -rf "$tmp"
        log_i "sing-box 已安装到 ${SINGBOX_BIN_DEFAULT}"
        return 0
    done < <(singbox_asset_suffixes "$arch" "$libc_variant")

    rm -rf "$tmp"

    if [[ "$found_asset" -eq 0 ]]; then
        log_e "未找到适用于当前系统的 sing-box release 资产（arch=${arch}, libc=${libc_variant}）。"
    else
        log_e "已找到 sing-box release 资产，但没有可在当前系统执行的版本。"
    fi
    return 1
}

verify_proxy_binary() {
    local version_log
    version_log="/tmp/${APP_NAME}-version.log"

    "$PROXY_BIN" version >"$version_log" 2>&1 && return 0
    cat "$version_log" >&2 || true
    return 1
}

ensure_proxy_binary() {
    choose_core_if_needed

    if [[ -x "$PROXY_BIN" ]]; then
        if verify_proxy_binary; then
            return 0
        fi
        log_w "检测到现有 ${PROXY_NAME} 二进制不可执行，尝试重新安装。"
        set_core_runtime_vars "$PROXY_CORE"
    fi

    case "$PROXY_CORE" in
    singbox)
        if need_cmd sing-box; then
            PROXY_BIN="$(command -v sing-box)"
            if verify_proxy_binary; then
                return 0
            fi
            log_w "PATH 中的 ${PROXY_NAME} 二进制不可执行，将改为重新安装。"
            PROXY_BIN="$SINGBOX_BIN_DEFAULT"
        fi
        log_w "未检测到 ${PROXY_NAME}，开始自动安装。"
        install_singbox_from_release
        ;;
    xray)
        if need_cmd xray; then
            PROXY_BIN="$(command -v xray)"
            if verify_proxy_binary; then
                return 0
            fi
            log_w "PATH 中的 ${PROXY_NAME} 二进制不可执行，将改为重新安装。"
            PROXY_BIN="$XRAY_BIN_DEFAULT"
        fi
        log_w "未检测到 ${PROXY_NAME}，开始自动安装。"
        install_xray_from_release
        ;;
    *)
        log_e "未知代理核心: ${PROXY_CORE}"
        exit 1
        ;;
    esac

    if [[ ! -x "$PROXY_BIN" ]]; then
        log_e "${PROXY_NAME} 安装失败，未找到 ${PROXY_BIN}。"
        exit 1
    fi

    if ! verify_proxy_binary; then
        if [[ "$PROXY_CORE" == "singbox" ]]; then
            log_e "${PROXY_NAME} 安装后仍无法执行，可能是与当前系统的 libc 或架构不匹配。"
        else
            log_e "${PROXY_NAME} 安装后仍无法执行。"
        fi
        exit 1
    fi
}

render_xray_config_from_nodes() {
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

render_singbox_config_from_nodes() {
    local nodes_path="$1"
    local output_path="$2"
    local first=1
    local node_id protocol remark listen port method password uuid created entry_host

    {
        cat <<'JSON_HEAD'
{
  "log": {
    "level": "warn"
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
      "type": "shadowsocks",
      "tag": "${tag}",
      "listen": "${safe_listen}",
      "listen_port": ${port},
      "method": "${safe_method}",
      "password": "${safe_password}"
    }
JSON_SS
            else
                safe_uuid="$(json_escape "$uuid")"
                cat <<JSON_VLESS
    {
      "type": "vless",
      "tag": "${tag}",
      "listen": "${safe_listen}",
      "listen_port": ${port},
      "users": [
        {
          "name": "${safe_remark}",
          "uuid": "${safe_uuid}"
        }
      ]
    }
JSON_VLESS
            fi
        done <"$nodes_path"

        cat <<'JSON_TAIL'

  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ]
}
JSON_TAIL
    } >"$output_path"
}

render_config_from_nodes() {
    choose_core_if_needed
    case "$PROXY_CORE" in
    singbox)
        render_singbox_config_from_nodes "$1" "$2"
        ;;
    xray)
        render_xray_config_from_nodes "$1" "$2"
        ;;
    *)
        log_e "未知代理核心: ${PROXY_CORE}"
        return 1
        ;;
    esac
}

validate_xray_config() {
    local file="$1"
    "$PROXY_BIN" test -config "$file" >/tmp/${APP_NAME}-config-test.log 2>&1 && return 0
    "$PROXY_BIN" run -test -config "$file" >/tmp/${APP_NAME}-config-test.log 2>&1 && return 0
    cat "/tmp/${APP_NAME}-config-test.log" >&2 || true
    return 1
}

validate_singbox_config() {
    local file="$1"
    "$PROXY_BIN" check -c "$file" >/tmp/${APP_NAME}-config-test.log 2>&1 && return 0
    cat "/tmp/${APP_NAME}-config-test.log" >&2 || true
    return 1
}

validate_config() {
    local file="$1"
    choose_core_if_needed

    case "$PROXY_CORE" in
    singbox)
        validate_singbox_config "$file"
        ;;
    xray)
        validate_xray_config "$file"
        ;;
    *)
        log_e "未知代理核心: ${PROXY_CORE}"
        return 1
        ;;
    esac
}

proxy_run_args() {
    choose_core_if_needed

    case "$PROXY_CORE" in
    singbox)
        printf 'run -c %s' "$CONFIG_FILE"
        ;;
    xray)
        printf 'run -config %s' "$CONFIG_FILE"
        ;;
    *)
        return 1
        ;;
    esac
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
    local backend exec_args
    backend="$(service_backend)"
    choose_core_if_needed
    exec_args="$(proxy_run_args)"

    case "$backend" in
    systemd)
        cat >"$SYSTEMD_SERVICE" <<EOF
[Unit]
Description=Standalone Proxy Node Manager (${PROXY_NAME})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${PROXY_BIN} ${exec_args}
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

description="Standalone Proxy Node Manager (${PROXY_NAME})"
command="${PROXY_BIN}"
command_args="${exec_args}"
command_background=true
pidfile="/run/${SERVICE_NAME}.pid"
output_log="${SERVICE_LOG_FILE}"
error_log="${SERVICE_LOG_FILE}"

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

start_service() {
    local backend
    backend="$(service_backend)"

    case "$backend" in
    systemd)
        systemctl start "$SERVICE_NAME"
        ;;
    openrc)
        rc-service "$SERVICE_NAME" start
        ;;
    *)
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

format_service_status() {
    local status="${1:-$(service_status)}"

    case "$status" in
    running)
        printf '%b运行中%b' "$green" "$plain"
        ;;
    "not running")
        printf '%b已停止%b' "$red" "$plain"
        ;;
    unknown)
        printf '%b未知%b' "$yellow" "$plain"
        ;;
    *)
        printf '%s' "$status"
        ;;
    esac
}

start_proxy_service() {
    init_store

    if [[ ! -s "$CONFIG_FILE" ]]; then
        log_w "未找到配置文件，请先创建节点。"
        return 0
    fi

    if (( $(node_count_file "$NODES_FILE") == 0 )); then
        log_w "当前没有节点，服务无需启动。"
        return 0
    fi

    ensure_proxy_binary

    if ! validate_config "$CONFIG_FILE"; then
        log_e "当前 ${PROXY_NAME} 配置未通过校验，未启动服务。"
        return 1
    fi

    install_service || return 1

    if start_service; then
        log_i "服务已启动。"
        echo "服务状态: $(format_service_status)"
        return 0
    fi

    log_e "服务启动失败，请通过菜单查看服务日志。"
    return 1
}

stop_proxy_service() {
    local backend status
    backend="$(service_backend)"

    if [[ "$backend" == "none" ]]; then
        log_e "未检测到 systemd 或 OpenRC，无法关闭后台服务。"
        return 1
    fi

    stop_service
    status="$(service_status)"
    if [[ "$status" == "running" ]]; then
        log_e "服务关闭失败，请通过菜单查看服务日志。"
        return 1
    fi

    log_i "服务已关闭。"
    echo "服务状态: $(format_service_status "$status")"
}

show_service_logs() {
    local backend lines log_file found_log=0
    backend="$(service_backend)"

    read -r -p "请输入显示日志行数，默认 100: " lines
    lines="$(sanitize_field "$lines")"
    if [[ -z "$lines" ]]; then
        lines=100
    elif ! [[ "$lines" =~ ^[0-9]+$ ]] || (( lines < 1 )); then
        log_w "日志行数无效，已使用默认 100 行。"
        lines=100
    fi

    case "$backend" in
    systemd)
        if ! need_cmd journalctl; then
            log_e "未找到 journalctl，无法查看 systemd 日志。"
            return 1
        fi
        journalctl -u "$SERVICE_NAME" -n "$lines" --no-pager -o short-iso
        ;;
    openrc)
        if [[ -r "$SERVICE_LOG_FILE" ]]; then
            echo "日志文件: ${SERVICE_LOG_FILE}"
            tail -n "$lines" "$SERVICE_LOG_FILE"
            return 0
        fi

        for log_file in /var/log/messages /var/log/syslog /var/log/daemon.log; do
            [[ -r "$log_file" ]] || continue
            found_log=1
            echo "日志文件: ${log_file}"
            grep -Ei "${SERVICE_NAME}|${PROXY_NAME}|sing-box|xray" "$log_file" | tail -n "$lines" || true
        done

        if [[ "$found_log" -eq 0 ]]; then
            log_w "未找到可读日志文件。可尝试执行: rc-service ${SERVICE_NAME} status"
        fi
        ;;
    *)
        log_e "未检测到 systemd 或 OpenRC，无法查看服务日志。"
        return 1
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
    echo "服务状态: $(format_service_status)"
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
        method="2022-blake3-aes-256-gcm"
        password="$(random_password "$method")" || {
            log_e "生成 Shadowsocks 密码失败，请确认系统已安装 openssl 或 base64。"
            return 1
        }
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
        log_e "生成的 ${PROXY_NAME} 配置未通过校验，已放弃写入。"
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
    ensure_proxy_binary
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

    ensure_proxy_binary

    local tmp_nodes tmp_config
    tmp_nodes="$(mktemp)"
    tmp_config="$(make_tmp_config)"
    awk -F'|' -v id="$target" '$1 != id' "$NODES_FILE" >"$tmp_nodes"
    if (( $(node_count_file "$tmp_nodes") > 0 )); then
        render_config_from_nodes "$tmp_nodes" "$tmp_config"
        if ! validate_config "$tmp_config"; then
            rm -f "$tmp_nodes"
            cleanup_tmp_config "$tmp_config"
            log_e "删除后的 ${PROXY_NAME} 配置未通过校验，已放弃写入。"
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

uninstall_panel() {
    local confirm backend script_path real_script real_quick
    script_path="${BASH_SOURCE[0]:-$0}"
    real_script="$(readlink -f "$script_path" 2>/dev/null || true)"
    real_quick="$(readlink -f "$QUICK_PROXY_CMD" 2>/dev/null || true)"

    if [[ -z "$PROXY_CORE" && -s "$CORE_FILE" ]]; then
        load_selected_core
    fi

    echo -e "${yellow}此操作将卸载独立代理节点管理器，并删除所有节点配置、服务、自启动项、快捷命令和脚本文件。${plain}"
    echo -e "${yellow}同时会移除本脚本安装的 /usr/local/bin/xray、/usr/local/bin/sing-box、/usr/local/lib/sing-box 及其相关服务残留。${plain}"
    read -r -p "确认一键卸载？[y/N]: " confirm
    confirm="$(sanitize_field "$confirm")"
    case "$confirm" in
    y | Y | yes | YES | Yes) ;;
    *)
        log_w "已取消卸载。"
        return 0
        ;;
    esac

    backend="$(service_backend)"
    case "$backend" in
    systemd)
        systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
        rm -f "$SYSTEMD_SERVICE"
        systemctl disable --now xray >/dev/null 2>&1 || true
        rm -f "$OFFICIAL_XRAY_SYSTEMD_SERVICE"
        systemctl daemon-reload >/dev/null 2>&1 || true
        ;;
    openrc)
        rc-service "$SERVICE_NAME" stop >/dev/null 2>&1 || true
        rc-update del "$SERVICE_NAME" default >/dev/null 2>&1 || true
        rm -f "$OPENRC_SERVICE"
        rc-service xray stop >/dev/null 2>&1 || true
        rc-update del xray default >/dev/null 2>&1 || true
        rm -f "$OFFICIAL_XRAY_OPENRC_SERVICE"
        ;;
    *)
        stop_service
        ;;
    esac

    rm -rf "$CONFIG_DIR"
    rm -rf /usr/local/etc/xray /usr/local/share/xray /var/log/xray
    rm -rf "$SINGBOX_INSTALL_DIR"
    rm -f "$XRAY_BIN_DEFAULT" "$SINGBOX_BIN_DEFAULT" /usr/local/bin/xray.sig
    rm -f "$QUICK_PROXY_CMD"

    if [[ -n "$real_script" && -f "$real_script" ]]; then
        if [[ -z "$real_quick" || "$real_script" != "$real_quick" ]]; then
            rm -f "$real_script"
        fi
    elif [[ -f "$script_path" ]]; then
        rm -f "$script_path"
    fi

    log_i "独立代理节点管理器已卸载。"
    exit 0
}

show_runtime_info() {
    local version_bin=""

    if [[ -z "$PROXY_CORE" ]]; then
        if [[ -s "$CORE_FILE" ]]; then
            load_selected_core
        else
            set_core_runtime_vars "$DEFAULT_PROXY_CORE"
        fi
    fi

    echo -e "${blue}独立代理节点管理脚本 v${SCRIPT_VERSION}${plain}"
    echo "当前核心: ${PROXY_NAME}"
    echo "配置目录: ${CONFIG_DIR}"
    echo "节点数量: $(awk -F'|' 'NF >= 5 { c++ } END { print c + 0 }' "$NODES_FILE" 2>/dev/null || echo 0)"
    echo "服务状态: $(format_service_status)"
    version_bin="$PROXY_BIN"
    if [[ ! -x "$version_bin" ]]; then
        case "$PROXY_CORE" in
        singbox)
            need_cmd sing-box && version_bin="$(command -v sing-box)"
            ;;
        xray)
            need_cmd xray && version_bin="$(command -v xray)"
            ;;
        esac
    fi
    if [[ -n "$version_bin" && -x "$version_bin" ]]; then
        "$version_bin" version 2>/dev/null | head -n 1 || true
    fi
    echo
}

migrate_ss_nodes() {
    local old_method="${1:-chacha20-ietf-poly1305}"
    local new_method="${2:-2022-blake3-aes-256-gcm}"

    init_store

    if [[ ! -s "$NODES_FILE" ]]; then
        log_w "没有可迁移的节点。"
        return 0
    fi

    if [[ "$old_method" == "$new_method" ]]; then
        log_w "源加密方式与目标加密方式相同，无需迁移。"
        return 0
    fi

    local old_count
    old_count="$(awk -F'|' -v old="$old_method" '$2 == "ss" && $6 == old { c++ } END { print c+0 }' "$NODES_FILE")"

    if [[ "$old_count" -eq 0 ]]; then
        log_i "没有使用 ${old_method} 的 Shadowsocks 节点，无需迁移。"
        return 0
    fi

    echo "检测到 ${old_count} 个节点使用 ${old_method}，迁移后将切换为 ${new_method} 并自动生成新密码。"
    echo -e "${yellow}客户端需凭新密码重新连接。${plain}"
    read -r -p "确认迁移？[y/N]: " confirm
    confirm="$(sanitize_field "$confirm")"
    case "$confirm" in
    y | Y | yes | YES | Yes) ;;
    *)
        log_w "已取消迁移。"
        return 0
        ;;
    esac

    ensure_proxy_binary

    local tmp_nodes tmp_config raw_line migrated=0
    tmp_nodes="$(mktemp)"
    tmp_config="$(make_tmp_config)"

    while IFS= read -r raw_line; do
        if [[ -z "$raw_line" || "${raw_line:0:1}" == "#" ]]; then
            printf '%s\n' "$raw_line" >>"$tmp_nodes"
            continue
        fi

        local node_id protocol remark listen port method password uuid created entry_host
        IFS='|' read -r node_id protocol remark listen port method password uuid created entry_host <<<"$raw_line"

        if [[ "$protocol" == "ss" && "$method" == "$old_method" ]]; then
            local new_password
            new_password="$(random_password "$new_method")" || {
                log_e "生成新密码失败，迁移中止。"
                rm -f "$tmp_nodes"
                cleanup_tmp_config "$tmp_config"
                return 1
            }
            printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
                "$node_id" "$protocol" "$remark" "$listen" "$port" \
                "$new_method" "$new_password" "$uuid" "$created" "$entry_host" >>"$tmp_nodes"
            migrated=$((migrated + 1))
        else
            printf '%s\n' "$raw_line" >>"$tmp_nodes"
        fi
    done <"$NODES_FILE"

    render_config_from_nodes "$tmp_nodes" "$tmp_config"
    if ! validate_config "$tmp_config"; then
        rm -f "$tmp_nodes"
        cleanup_tmp_config "$tmp_config"
        log_e "迁移后的配置未通过校验，已放弃写入。"
        return 1
    fi

    mv "$tmp_config" "$CONFIG_FILE"
    cleanup_tmp_config "$tmp_config"
    mv "$tmp_nodes" "$NODES_FILE"
    chmod 600 "$NODES_FILE" "$CONFIG_FILE"

    install_service || return 1
    if ! restart_service; then
        log_e "服务重启失败，请检查系统日志。"
        return 1
    fi

    log_i "已成功迁移 ${migrated} 个节点到 ${new_method}，以下为更新后的节点信息："
    list_nodes
}

menu() {
    need_root
    init_store
    install_quick_proxy_command || true
    choose_core_if_needed
    while true; do
        clear 2>/dev/null || true
        show_runtime_info
        echo "1. 创建 Shadowsocks 节点"
        echo "2. 创建 VLESS + TCP 节点"
        echo "3. 查看已创建节点信息"
        echo "4. 删除节点"
        echo "5. 迁移 chacha20-ietf-poly1305 到 2022-blake3-aes-256-gcm"
        echo "6. 迁移 2022-blake3-aes-256-gcm 到 chacha20-ietf-poly1305"
        echo "7. 启动服务"
        echo "8. 关闭服务"
        echo "9. 查看服务日志"
        echo "10. 更新面板"
        echo "11. 一键卸载"
        echo "0. 退出"
        echo
        read -r -p "请选择功能 [0-11]: " choice
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
            delete_node || log_e "删除节点失败。"
            pause
            ;;
        5)
            migrate_ss_nodes "chacha20-ietf-poly1305" "2022-blake3-aes-256-gcm" || log_e "迁移节点失败。"
            pause
            ;;
        6)
            migrate_ss_nodes "2022-blake3-aes-256-gcm" "chacha20-ietf-poly1305" || log_e "迁移节点失败。"
            pause
            ;;
        7)
            start_proxy_service || log_e "启动服务失败。"
            pause
            ;;
        8)
            stop_proxy_service || log_e "关闭服务失败。"
            pause
            ;;
        9)
            show_service_logs || log_e "查看服务日志失败。"
            pause
            ;;
        10)
            update_panel || log_e "更新面板失败。"
            pause
            ;;
        11)
            uninstall_panel || log_e "一键卸载失败。"
            pause
            ;;
        0)
            exit 0
            ;;
        *)
            log_w "请输入 0-11。"
            sleep 1
            ;;
        esac
    done
}

menu "$@"
