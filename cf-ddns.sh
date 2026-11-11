#!/usr/bin/env bash
# ====================================================
# 多平台轻量级 DDNS 脚本 (Cloudflare 纯Shell极速版 & 华为云 TTL=1 | IPv4 来源选择与持久化版)
# 特性：内存自重构固化技术，无视启动方式、无视路径变动、支持管道直接运行
# ====================================================

# 若用户使用 sh 启动，自动无缝切换至 bash 执行，防止语法报错
if [ -z "${BASH_VERSION:-}" ]; then
    exec /usr/bin/env bash "$0" "$@"
fi

# 确保 HOME 变量在 Systemd 或特殊环境下始终有效
if [ -z "$HOME" ] || [ "$HOME" = "/" ]; then
    HOME=$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f6)
    [ -z "$HOME" ] && HOME="/root"
fi

SERVICE_FILE="/etc/systemd/system/cf-ddns.service"

# 防止前后权限不一致导致配置目录分裂：若 Systemd 服务已存在且当前用户有权限读写，优先沿用其配置目录
if [ -z "${CONFIG_DIR:-}" ] && [ -f "$SERVICE_FILE" ]; then
    _svc_dir=$(grep '^Environment="CONFIG_DIR=' "$SERVICE_FILE" 2>/dev/null | head -n 1 | cut -d'=' -f3 | tr -d '"')
    if [ -n "$_svc_dir" ]; then
        if [ -w "$_svc_dir" ] || [ "$(id -u)" -eq 0 ]; then
            CONFIG_DIR="$_svc_dir"
        else
            echo -e "\033[33m提示：检测到系统已安装 root 级后台服务，建议使用 sudo 或 root 权限运行本脚本以保持配置同步！\033[0m"
        fi
    fi
fi

CONFIG_DIR="${CONFIG_DIR:-$HOME/.cf_ddns}"
CONFIG_FILE="$CONFIG_DIR/config.conf"
INTERVAL_FILE="$CONFIG_DIR/interval.conf"
LOG_FILE="$CONFIG_DIR/ddns.log"
IP_CACHE_FILE="$CONFIG_DIR/last_ip.txt"
LAST_CHECK_FILE="$CONFIG_DIR/last_check.txt"
PID_FILE="$CONFIG_DIR/ddns.pid"
# 固定守护脚本路径（永远存放在配置目录内，无视外部脚本位置变化）
SCRIPT_PATH="$CONFIG_DIR/cf-ddns.sh"

mkdir -p "$CONFIG_DIR" 2>/dev/null

# 颜色定义
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

# ==================== 核心技术：内存自导出固化 ====================
# 无论用户是通过 bash <(curl ...) 管道运行、还是把脚本放在任意目录甚至运行后删除，
# 直接从当前 Bash 进程内存中提取完整脚本代码并固化到 $SCRIPT_PATH，零外部依赖！
persist_self() {
    local raw_self=""
    if [ -f "$0" ] && [[ "$0" != *"/dev/fd/"* ]] && [[ "$0" != *"/proc/"* ]]; then
        raw_self="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")"
    fi

    # 若当前运行的就是已固化的脚本自身，无需重复写入
    if [ "$raw_self" = "$SCRIPT_PATH" ] && [ -s "$SCRIPT_PATH" ]; then
        chmod +x "$SCRIPT_PATH" 2>/dev/null || true
        return 0
    fi

    # 情况1：若 $0 是真实的普通磁盘文件且包含完整代码，剥离 CRLF 后直接复制
    if [ -n "$raw_self" ] && [ -s "$raw_self" ] && grep -q "ensure_dependencies" "$raw_self" 2>/dev/null; then
        tr -d '\r' < "$raw_self" > "$SCRIPT_PATH" 2>/dev/null
        chmod +x "$SCRIPT_PATH" 2>/dev/null
        return 0
    fi

    # 情况2：通过管道 bash <(curl ...) 或 $0 已被删除时，直接从 Bash 内存导出所有函数重构完整脚本
    {
        printf '%s\n' '#!/usr/bin/env bash'
        printf '%s\n' 'if [ -z "${BASH_VERSION:-}" ]; then exec /usr/bin/env bash "$0" "$@"; fi'
        printf '%s\n' 'if [ -z "$HOME" ] || [ "$HOME" = "/" ]; then'
        printf '%s\n' '    HOME=$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f6)'
        printf '%s\n' '    [ -z "$HOME" ] && HOME="/root"'
        printf '%s\n' 'fi'
        printf '%s\n' 'SERVICE_FILE="/etc/systemd/system/cf-ddns.service"'
        printf '%s\n' 'if [ -z "${CONFIG_DIR:-}" ] && [ -f "$SERVICE_FILE" ]; then'
        printf '%s\n' '    _svc_dir=$(grep '\''^Environment="CONFIG_DIR='\'' "$SERVICE_FILE" 2>/dev/null | head -n 1 | cut -d'\''='\'' -f3 | tr -d '\''"'\'')'
        printf '%s\n' '    if [ -n "$_svc_dir" ] && { [ -w "$_svc_dir" ] || [ "$(id -u)" -eq 0 ]; }; then'
        printf '%s\n' '        CONFIG_DIR="$_svc_dir"'
        printf '%s\n' '    fi'
        printf '%s\n' 'fi'
        printf '%s\n' 'CONFIG_DIR="${CONFIG_DIR:-$HOME/.cf_ddns}"'
        printf '%s\n' 'CONFIG_FILE="$CONFIG_DIR/config.conf"'
        printf '%s\n' 'INTERVAL_FILE="$CONFIG_DIR/interval.conf"'
        printf '%s\n' 'LOG_FILE="$CONFIG_DIR/ddns.log"'
        printf '%s\n' 'IP_CACHE_FILE="$CONFIG_DIR/last_ip.txt"'
        printf '%s\n' 'LAST_CHECK_FILE="$CONFIG_DIR/last_check.txt"'
        printf '%s\n' 'PID_FILE="$CONFIG_DIR/ddns.pid"'
        printf '%s\n' 'SCRIPT_PATH="$CONFIG_DIR/cf-ddns.sh"'
        printf '%s\n' 'mkdir -p "$CONFIG_DIR" 2>/dev/null'
        printf '%s\n' 'GREEN="\033[32m"; RED="\033[31m"; YELLOW="\033[33m"; CYAN="\033[36m"; RESET="\033[0m"'

        declare -f \
            persist_self \
            ensure_dependencies \
            pause_return \
            wakeup_daemon \
            log_msg \
            is_valid_ip \
            get_legacy_public_ip \
            get_direct_ipv4 \
            read_ipv4_source \
            choose_ipv4_source \
            configure_ipv4_source \
            get_public_ip \
            cf_api \
            verify_and_save_cf \
            hw_api \
            hw_parse_id \
            verify_and_save_hw \
            configure_ddns \
            modify_config_menu \
            update_ddns \
            run_daemon \
            stop_timer \
            setup_timer \
            show_status \
            uninstall_ddns \
            main_menu

        printf '%s\n' 'if [ "${1:-}" = "--daemon" ]; then'
        printf '%s\n' '    run_daemon "${2:-}"'
        printf '%s\n' '    exit 0'
        printf '%s\n' 'fi'
        printf '%s\n' 'main_menu "$@"'
    } > "${SCRIPT_PATH}.tmp"

    mv -f "${SCRIPT_PATH}.tmp" "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH" 2>/dev/null
}

# 按需检测并自动安装缺失环境 (保持 Cloudflare 纯净轻量，仅在需要时安装对应依赖)
ensure_dependencies() {
    local missing_pkgs=()
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || missing_pkgs+=("$cmd")
    done

    if [ ${#missing_pkgs[@]} -eq 0 ]; then
        return 0
    fi

    echo -e "${YELLOW}检测到系统缺少必要组件: ${missing_pkgs[*]}，正在尝试自动安装...${RESET}"

    local pm=""
    if command -v apt-get >/dev/null 2>&1; then
        pm="apt"
    elif command -v dnf >/dev/null 2>&1; then
        pm="dnf"
    elif command -v yum >/dev/null 2>&1; then
        pm="yum"
    elif command -v pacman >/dev/null 2>&1; then
        pm="pacman"
    elif command -v apk >/dev/null 2>&1; then
        pm="apk"
    elif command -v opkg >/dev/null 2>&1; then
        pm="opkg"
    fi

    if [ -z "$pm" ]; then
        echo -e "${RED}未找到支持的包管理器，请手动安装: ${missing_pkgs[*]}${RESET}"
        return 1
    fi

    local SUDO=""
    if [ "$(id -u)" -ne 0 ]; then
        if command -v sudo >/dev/null 2>&1; then
            SUDO="sudo"
        else
            echo -e "${RED}当前非 root 用户且未安装 sudo，无法自动安装: ${missing_pkgs[*]}${RESET}"
            return 1
        fi
    fi

    case "$pm" in
        apt)
            $SUDO apt-get update -y >/dev/null 2>&1
            $SUDO apt-get install -y "${missing_pkgs[@]}" >/dev/null 2>&1
            ;;
        dnf)
            $SUDO dnf install -y "${missing_pkgs[@]}" >/dev/null 2>&1
            ;;
        yum)
            $SUDO yum install -y "${missing_pkgs[@]}" >/dev/null 2>&1
            ;;
        pacman)
            $SUDO pacman -Sy --noconfirm "${missing_pkgs[@]}" >/dev/null 2>&1
            ;;
        apk)
            $SUDO apk update >/dev/null 2>&1
            $SUDO apk add --no-cache "${missing_pkgs[@]}" >/dev/null 2>&1
            ;;
        opkg)
            $SUDO opkg update >/dev/null 2>&1
            $SUDO opkg install "${missing_pkgs[@]}" >/dev/null 2>&1
            if [[ " ${missing_pkgs[*]} " == *" python3 "* ]]; then
                $SUDO opkg install python3-urllib python3-openssl >/dev/null 2>&1
            fi
            ;;
    esac

    local failed=()
    for pkg in "${missing_pkgs[@]}"; do
        command -v "$pkg" >/dev/null 2>&1 || failed+=("$pkg")
    done

    if [ ${#failed[@]} -gt 0 ]; then
        echo -e "${RED}组件安装失败: ${failed[*]}，请检查网络源或手动安装！${RESET}"
        return 1
    else
        echo -e "${GREEN}组件 ${missing_pkgs[*]} 已自动安装就绪！${RESET}"
        return 0
    fi
}

# 按任意键返回 (清空输入缓冲区，防止方向键或回车符漏入主菜单)
pause_return() {
    echo ""
    echo -ne "${YELLOW}按任意键返回菜单...${RESET}"
    if ! read -r -n 1 -s _; then
        read -r _
    fi
    read -r -t 0.1 -n 10000 _ 2>/dev/null || true
    echo ""
}

# 唤醒正在休眠的后台守护进程 (使配置修改立即生效)
wakeup_daemon() {
    if [ -f "$PID_FILE" ]; then
        local pid
        pid=$(tr -cd '0-9' < "$PID_FILE")
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            pkill -P "$pid" sleep 2>/dev/null || true
        fi
    fi
}

# 写入日志 (自动保留最近200行)
log_msg() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg" >> "$LOG_FILE"
    if [ -f "$LOG_FILE" ] && [ "$(wc -l < "$LOG_FILE")" -gt 200 ]; then
        tail -n 200 "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
    fi
}

# 纯 Bash 内置零开销校验 IPv4 / IPv6 合法性 (不启动任何外部进程，保护超低配 VPS)
is_valid_ip() {
    local ip_str="$1"
    local ip_type="$2"
    [ -z "$ip_str" ] && return 1

    if [ "$ip_type" = "AAAA" ]; then
        if [[ "$ip_str" == *:*:* ]] && [[ "$ip_str" =~ ^[0-9a-fA-F:]+$ ]]; then
            return 0
        fi
        return 1
    else
        if [[ "$ip_str" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
            local i
            for i in 1 2 3 4; do
                if [ "${BASH_REMATCH[$i]}" -gt 255 ]; then
                    return 1
                fi
            done
            return 0
        fi
        return 1
    fi
}

# 获取本机公网 IP (国际纯文本源优先 -> 失败自动切换国内纯文本源)
get_legacy_public_ip() {
    local type="$1"
    local ip=""

    if [ "$type" = "AAAA" ]; then
        for url in "https://ipv6.icanhazip.com" "https://api6.ipify.org" "https://v6.ident.me"; do
            ip=$(curl -s -6 --max-time 3 "$url" | tr -d '[:space:]')
            if is_valid_ip "$ip" "AAAA"; then
                echo "$ip"
                return 0
            fi
        done
        for url in "https://6.ipw.cn" "https://v6.myip.la" "https://speed.neu6.edu.cn/getIP.php"; do
            ip=$(curl -s -6 --max-time 4 "$url" | tr -d '[:space:]')
            if is_valid_ip "$ip" "AAAA"; then
                echo "$ip"
                return 0
            fi
        done
    else
        for url in "https://ipv4.icanhazip.com" "https://api.ipify.org" "https://ident.me"; do
            ip=$(curl -s -4 --max-time 3 "$url" | tr -d '[:space:]')
            if is_valid_ip "$ip" "A"; then
                echo "$ip"
                return 0
            fi
        done
        for url in "https://4.ipw.cn" "https://ip.3322.net" "https://v4.myip.la"; do
            ip=$(curl -s -4 --max-time 4 "$url" | tr -d '[:space:]')
            if is_valid_ip "$ip" "A"; then
                echo "$ip"
                return 0
            fi
        done
    fi

    echo ""
    return 1
}

get_direct_ipv4() {
    local ip=""
        # IPv4 仅使用指定网卡直连检测，不回退到可能经过代理的检测源。
        # 网卡不是 eth0 时，修改下面这一行；该设置也会随后台脚本一起保存。
        local interface="eth0"
        local trace=""
        # -q 必须放在首位，避免 ~/.curlrc 中的代理、重定向等设置干扰检测。
        # '*' 不要写成 '\*'，否则不能表示绕过所有代理。
        if ! trace=$(curl -q -fsS -4 --interface "$interface" --noproxy '*' \
            --max-time 10 "https://1.1.1.1/cdn-cgi/trace" 2>/dev/null); then
            return 1
        fi
        # trace 是多行文本，仅提取 ip= 字段；重复字段会被后续校验拒绝。
        ip=$(printf '%s\n' "$trace" | sed -n 's/^ip=//p' | tr -d '\r')
        if is_valid_ip "$ip" "A"; then
            printf '%s\n' "$ip"
            return 0
        fi
    return 1
}

# 独立配置文件，不受原脚本重新保存域名/API 配置影响。
read_ipv4_source() {
    local source=""
    if [ -f "$CONFIG_DIR/ipv4-source.conf" ]; then
        IFS= read -r source < "$CONFIG_DIR/ipv4-source.conf"
    fi
    case "$source" in
        direct|normal) printf '%s\n' "$source" ;;
        *) return 1 ;;
    esac
}

choose_ipv4_source() {
    local normal_ip="$1" direct_ip="$2" choice source tmp
    printf '\nIPv4 检测结果：\n  1. 普通查询：%s\n  2. eth0 直连 1.1.1.1：%s\n  0. 取消，保留原 DNS 记录\n' \
        "${normal_ip:-检测失败}" "${direct_ip:-检测失败}" >&2
    printf '选择后会记住获取方式，今后 IP 变化时自动跟随该方式更新。\n' >&2
    while true; do
        IFS= read -rp '请选择 DDNS 使用的来源 [1/2/0]: ' choice || return 1
        case "$choice" in
            1) source=normal; [ -n "$normal_ip" ] && break ;;
            2) source=direct; [ -n "$direct_ip" ] && break ;;
            0) return 1 ;;
        esac
        printf '该选项无效或检测失败，请重新选择。\n' >&2
    done
    # 原子保存：后台只会读到完整的 normal 或 direct，不执行配置内容。
    tmp=$(mktemp "$CONFIG_DIR/ipv4-source.conf.XXXXXX") || return 1
    if ! printf '%s\n' "$source" > "$tmp" || ! mv -f "$tmp" "$CONFIG_DIR/ipv4-source.conf"; then
        rm -f "$tmp"
        printf '保存来源失败，已取消本次更新。\n' >&2
        return 1
    fi
    rm -f "$IP_CACHE_FILE"
    printf '已保存 IPv4 获取方式：%s\n' "$source" >&2
    if [ "$source" = direct ]; then
        printf '%s\n' "$direct_ip"
    else
        printf '%s\n' "$normal_ip"
    fi
}

get_public_ip() {
    local type="$1" mode="${2:-daemon}" source normal_ip direct_ip
    if [ "$type" = AAAA ]; then
        get_legacy_public_ip AAAA
        return $?
    fi
    source=$(read_ipv4_source)
    case "$source" in
        direct) get_direct_ipv4; return $? ;;
        normal) get_legacy_public_ip A; return $? ;;
    esac
    normal_ip=$(get_legacy_public_ip A)
    direct_ip=$(get_direct_ipv4)
    if [ -n "$normal_ip" ] && [ "$normal_ip" = "$direct_ip" ]; then
        printf '%s\n' "$normal_ip"
        return 0
    fi
    if [ -z "$normal_ip" ] && [ -z "$direct_ip" ]; then
        return 1
    fi
    if [ "$mode" = interactive ]; then
        choose_ipv4_source "$normal_ip" "$direct_ip"
        return $?
    fi
    log_msg "IPv4 来源尚未选择，普通=${normal_ip:-失败}，直连=${direct_ip:-失败}；请运行菜单 [8] 选择，已保留原 DNS 记录"
    return 1
}

configure_ipv4_source() {
    local normal_ip direct_ip selected_ip
    normal_ip=$(get_legacy_public_ip A)
    direct_ip=$(get_direct_ipv4)
    if [ -z "$normal_ip" ] && [ -z "$direct_ip" ]; then
        echo '两个 IPv4 来源均检测失败，保留原有来源设置。'
        return 1
    fi
    if selected_ip=$(choose_ipv4_source "$normal_ip" "$direct_ip"); then
        echo "所选来源当前 IPv4：$selected_ip"
        if [ -f "$CONFIG_FILE" ]; then
            update_ddns interactive
            wakeup_daemon
        fi
    fi
}

# ==================== Cloudflare 专用模块 (纯 Shell 物理隔离) ====================
cf_api() {
    local method="$1"
    local endpoint="$2"
    local data="$3"
    local auth_mode="${AUTH_MODE:-Bearer}"

    if [ "$auth_mode" = "Bearer" ]; then
        if [ -n "$data" ]; then
            curl -s -X "$method" "https://api.cloudflare.com/client/v4${endpoint}" \
                -H "Authorization: Bearer ${CF_TOKEN}" \
                -H "Content-Type: application/json" \
                --data "$data"
        else
            curl -s -X "$method" "https://api.cloudflare.com/client/v4${endpoint}" \
                -H "Authorization: Bearer ${CF_TOKEN}" \
                -H "Content-Type: application/json"
        fi
    else
        if [ -n "$data" ]; then
            curl -s -X "$method" "https://api.cloudflare.com/client/v4${endpoint}" \
                -H "X-Auth-Email: ${CF_EMAIL}" \
                -H "X-Auth-Key: ${CF_TOKEN}" \
                -H "Content-Type: application/json" \
                --data "$data"
        else
            curl -s -X "$method" "https://api.cloudflare.com/client/v4${endpoint}" \
                -H "X-Auth-Email: ${CF_EMAIL}" \
                -H "X-Auth-Key: ${CF_TOKEN}" \
                -H "Content-Type: application/json"
        fi
    fi
}

verify_and_save_cf() {
    local v_email="$1"
    local v_domain="$2"
    local v_token="$3"
    local v_type="$4"
    local v_proxy="$5"

    CF_EMAIL="$v_email"
    CF_TOKEN="$v_token"
    AUTH_MODE="Bearer"

    echo -e "${YELLOW}正在通过 Token 验证 Cloudflare 权限...${RESET}"
    local test_resp
    test_resp=$(cf_api "GET" "/zones?per_page=1")
    if ! echo "$test_resp" | grep -q '"success":true'; then
        AUTH_MODE="Key"
        test_resp=$(cf_api "GET" "/zones?per_page=1")
        if ! echo "$test_resp" | grep -q '"success":true'; then
            echo -e "${RED}验证失败！请检查邮箱或 Token 是否正确，或是否具备 DNS 编辑权限。${RESET}"
            return 1
        fi
    fi

    local candidate="$v_domain"
    local zone_id=""
    local zone_name=""
    local zone_resp

    while true; do
        zone_resp=$(cf_api "GET" "/zones?name=${candidate}")
        if echo "$zone_resp" | grep -q '"success":true'; then
            zone_id=$(echo "$zone_resp" | grep -o '"id":"[^"]*"' | head -n 1 | cut -d'"' -f4)
            if [ -n "$zone_id" ]; then
                zone_name="$candidate"
                break
            fi
        fi
        local next_cand="${candidate#*.}"
        if [ "$next_cand" = "$candidate" ] || [[ "$next_cand" != *.* ]]; then
            break
        fi
        candidate="$next_cand"
    done

    if [ -z "$zone_id" ]; then
        echo -e "${RED}未能自动匹配到域名 ${v_domain} 所属的站点，请确认该域名已托管在当前 Cloudflare 账号下！${RESET}"
        return 1
    fi

    local record_resp record_id=""
    record_resp=$(cf_api "GET" "/zones/${zone_id}/dns_records?type=${v_type}&name=${v_domain}")
    if echo "$record_resp" | grep -q '"success":true'; then
        record_id=$(echo "$record_resp" | grep -o '"id":"[^"]*"' | head -n 1 | cut -d'"' -f4)
    fi

    {
        printf 'PROVIDER="cloudflare"\n'
        printf 'CF_EMAIL="%s"\n' "${v_email}"
        printf 'CF_TOKEN="%s"\n' "${v_token}"
        printf 'AUTH_MODE="%s"\n' "${AUTH_MODE}"
        printf 'ZONE_NAME="%s"\n' "${zone_name}"
        printf 'ZONE_ID="%s"\n' "${zone_id}"
        printf 'RECORD_NAME="%s"\n' "${v_domain}"
        printf 'RECORD_TYPE="%s"\n' "${v_type}"
        printf 'RECORD_ID="%s"\n' "${record_id}"
        printf 'PROXIED="%s"\n' "${v_proxy}"
    } > "$CONFIG_FILE"

    chmod 600 "$CONFIG_FILE"
    rm -f "$IP_CACHE_FILE"
    echo -e "${GREEN}验证成功！已自动绑定 Cloudflare 主域名: ${zone_name}${RESET}"
    update_ddns "interactive"
    wakeup_daemon
    return 0
}

# ==================== 华为云 专用模块 (按需调用 Python3 签名) ====================
hw_api() {
    local method="$1"
    local uri="$2"
    local body="$3"

    python3 -c '
import sys, hmac, hashlib, datetime, urllib.request, urllib.error, urllib.parse, json

method = sys.argv[1].upper()
raw_uri = sys.argv[2]
body = sys.argv[3] if len(sys.argv) > 3 else ""
ak = sys.argv[4]
sk = sys.argv[5]

host = "dns.myhuaweicloud.com"
parsed = urllib.parse.urlsplit(raw_uri)
path = parsed.path

canonical_uri = path if path.endswith("/") else path + "/"

qsl = urllib.parse.parse_qsl(parsed.query, keep_blank_values=True)
qsl.sort(key=lambda x: (x[0], x[1]))
safe_chars = "-~."
canonical_query = "&".join(
    urllib.parse.quote(k, safe=safe_chars) + "=" + urllib.parse.quote(v, safe=safe_chars)
    for k, v in qsl
)

actual_uri = path + ("?" + canonical_query if canonical_query else "")
endpoint = "https://" + host + actual_uri

t = datetime.datetime.now(datetime.timezone.utc)
sdk_date = t.strftime("%Y%m%dT%H%M%SZ")

body_bytes = body.encode("utf-8")
payload_hash = hashlib.sha256(body_bytes).hexdigest()

signed_headers = "content-type;host;x-sdk-date"
canonical_headers = f"content-type:application/json\nhost:{host}\nx-sdk-date:{sdk_date}\n"

canonical_request = f"{method}\n{canonical_uri}\n{canonical_query}\n{canonical_headers}\n{signed_headers}\n{payload_hash}"
req_hash = hashlib.sha256(canonical_request.encode("utf-8")).hexdigest()
string_to_sign = f"SDK-HMAC-SHA256\n{sdk_date}\n{req_hash}"

signature = hmac.new(sk.encode("utf-8"), string_to_sign.encode("utf-8"), hashlib.sha256).hexdigest()
auth_header = f"SDK-HMAC-SHA256 Access={ak}, SignedHeaders={signed_headers}, Signature={signature}"

req = urllib.request.Request(endpoint, data=body_bytes if body else None, method=method)
req.add_header("Authorization", auth_header)
req.add_header("Host", host)
req.add_header("X-Sdk-Date", sdk_date)
req.add_header("Content-Type", "application/json")

try:
    with urllib.request.urlopen(req, timeout=8) as response:
        print(response.read().decode("utf-8"))
except urllib.error.HTTPError as e:
    print(e.read().decode("utf-8"))
except Exception as e:
    print(json.dumps({"error": str(e)}))
' "$method" "$uri" "$body" "$HW_AK" "$HW_SK"
}

hw_parse_id() {
    local json_str="$1"
    local list_key="$2"
    local target_name="$3"
    local target_type="$4"

    python3 -c '
import sys, json
try:
    data = json.loads(sys.argv[1])
    key = sys.argv[2]
    t_name = sys.argv[3]
    t_type = sys.argv[4]
    if key == "direct":
        print(data.get("id", ""))
    else:
        for item in data.get(key, []):
            if t_name and item.get("name") != t_name:
                continue
            if t_type and item.get("type") != t_type:
                continue
            print(item.get("id", ""))
            break
except Exception:
    pass
' "$json_str" "$list_key" "$target_name" "$target_type"
}

verify_and_save_hw() {
    local v_ak="$1"
    local v_sk="$2"
    local v_domain="$3"
    local v_type="$4"
    local v_ttl="${5:-1}"

    if ! ensure_dependencies "python3"; then
        return 1
    fi

    HW_AK="$v_ak"
    HW_SK="$v_sk"

    echo -e "${YELLOW}正在验证华为云 AK/SK 权限...${RESET}"
    local test_resp
    test_resp=$(hw_api "GET" "/v2/zones?limit=1" "")
    if ! echo "$test_resp" | grep -q '"zones"'; then
        echo -e "${RED}验证失败！请检查 AK/SK 是否正确，返回信息: ${test_resp}${RESET}"
        return 1
    fi

    echo -e "${YELLOW}正在自动向上匹配华为云托管主域名...${RESET}"
    local candidate="$v_domain"
    local zone_id=""
    local zone_name=""

    while true; do
        local check_name="${candidate}."
        local resp
        resp=$(hw_api "GET" "/v2/zones?name=${check_name}" "")
        zone_id=$(hw_parse_id "$resp" "zones" "$check_name" "")
        if [ -n "$zone_id" ]; then
            zone_name="$candidate"
            break
        fi
        local next_cand="${candidate#*.}"
        if [ "$next_cand" = "$candidate" ] || [[ "$next_cand" != *.* ]]; then
            break
        fi
        candidate="$next_cand"
    done

    if [ -z "$zone_id" ]; then
        echo -e "${RED}未能自动匹配到域名 ${v_domain} 在华为云公网解析中的 Zone！请确认该域名已在华为云创建公网域名。${RESET}"
        return 1
    fi

    local query_name="${v_domain}."
    local record_resp record_id
    record_resp=$(hw_api "GET" "/v2/zones/${zone_id}/recordsets?name=${query_name}&type=${v_type}" "")
    record_id=$(hw_parse_id "$record_resp" "recordsets" "$query_name" "$v_type")

    {
        printf 'PROVIDER="huawei"\n'
        printf 'HW_AK="%s"\n' "${v_ak}"
        printf 'HW_SK="%s"\n' "${v_sk}"
        printf 'ZONE_NAME="%s"\n' "${zone_name}"
        printf 'ZONE_ID="%s"\n' "${zone_id}"
        printf 'RECORD_NAME="%s"\n' "${v_domain}"
        printf 'RECORD_TYPE="%s"\n' "${v_type}"
        printf 'RECORD_ID="%s"\n' "${record_id}"
        printf 'HW_TTL="%s"\n' "${v_ttl}"
    } > "$CONFIG_FILE"

    chmod 600 "$CONFIG_FILE"
    rm -f "$IP_CACHE_FILE"
    echo -e "${GREEN}验证成功！已绑定华为云主域名: ${zone_name} (TTL: ${v_ttl}秒)${RESET}"
    update_ddns "interactive"
    wakeup_daemon
    return 0
}

# ==================== 初次配置向导 ====================
configure_ddns() {
    echo -e "\n${CYAN}--- 选择 DNS 服务商 ---${RESET}"
    echo "  1. Cloudflare (纯 Shell 超轻量模式，适合所有机型)"
    echo "  2. 华为云 (支持 TTL=1 秒极速生效，需 Python3 环境)"
    read -rp "请选择服务商 [1-2，默认1]: " prov_choice

    if [ "$prov_choice" = "2" ]; then
        echo -e "\n${CYAN}--- 配置 华为云 DDNS ---${RESET}"
        read -rp "1. 请输入华为云 Access Key ID (AK): " input_ak
        read -rp "2. 请输入华为云 Secret Access Key (SK): " input_sk
        read -rp "3. 请输入 DDNS 域名 (如 ddns.example.com): " input_domain
        read -rp "4. 解析类型 [1: IPv4(默认) / 2: IPv6]: " type_choice
        [ "$type_choice" = "2" ] && input_type="AAAA" || input_type="A"

        read -rp "5. 请输入 TTL 秒数 (默认 1 秒，极速生效): " input_ttl
        input_ttl=$(echo "$input_ttl" | tr -cd '0-9')
        input_ttl=${input_ttl:-1}
        [ "$input_ttl" -lt 1 ] && input_ttl=1

        input_ak=$(echo "$input_ak" | tr -d '[:space:]')
        input_sk=$(echo "$input_sk" | tr -d '[:space:]')
        input_domain=$(echo "$input_domain" | tr -d '[:space:]')
        input_domain="${input_domain%.}"

        if [ -z "$input_ak" ] || [ -z "$input_sk" ] || [ -z "$input_domain" ]; then
            echo -e "${RED}错误：AK、SK 和域名均不能为空！${RESET}"
            return 1
        fi
        verify_and_save_hw "$input_ak" "$input_sk" "$input_domain" "$input_type" "$input_ttl"
    else
        echo -e "\n${CYAN}--- 配置 Cloudflare DDNS ---${RESET}"
        read -rp "1. 请输入 Cloudflare 邮箱: " input_email
        read -rp "2. 请输入 DDNS 域名 (如 ddns.example.com): " input_domain
        read -rp "3. 请输入 Cloudflare API Token: " input_token
        read -rp "4. 解析类型 [1: IPv4(默认) / 2: IPv6]: " type_choice
        [ "$type_choice" = "2" ] && input_type="AAAA" || input_type="A"
        read -rp "5. 是否开启小黄云 CDN 代理 [1: 关闭(默认) / 2: 开启]: " proxy_choice
        [ "$proxy_choice" = "2" ] && input_proxy="true" || input_proxy="false"

        input_email=$(echo "$input_email" | tr -d '[:space:]')
        input_domain=$(echo "$input_domain" | tr -d '[:space:]')
        input_domain="${input_domain%.}"
        input_token=$(echo "$input_token" | tr -d '[:space:]')

        if [ -z "$input_email" ] || [ -z "$input_domain" ] || [ -z "$input_token" ]; then
            echo -e "${RED}错误：邮箱、域名和 Token 均不能为空！${RESET}"
            return 1
        fi
        verify_and_save_cf "$input_email" "$input_domain" "$input_token" "$input_type" "$input_proxy"
    fi
}

# ==================== 二级菜单：按需修改现有配置 ====================
modify_config_menu() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "\n${RED}未检测到配置文件，请先选择 [1] 完成初次配置！${RESET}"
        pause_return
        return 1
    fi

    while true; do
        # shellcheck source=/dev/null
        . "$CONFIG_FILE"
        PROVIDER="${PROVIDER:-cloudflare}"

        echo -e "\n${CYAN}=========================================${RESET}"
        echo -e "${CYAN}     修改 DDNS 配置 (服务商: ${PROVIDER})   ${RESET}"
        echo -e "${CYAN}=========================================${RESET}"

        if [ "$PROVIDER" = "huawei" ]; then
            local masked_sk="已配置"
            [ ${#HW_SK} -gt 8 ] && masked_sk="${HW_SK:0:4}****${HW_SK: -4}"
            echo -e "  1. 修改华为云 AK        [当前: ${YELLOW}${HW_AK}${RESET}]"
            echo -e "  2. 修改华为云 SK        [当前: ${YELLOW}${masked_sk}${RESET}]"
            echo -e "  3. 修改 DDNS 域名       [当前: ${GREEN}${RECORD_NAME}${RESET}]"
            echo -e "  4. 切换解析类型(A/AAAA) [当前: ${CYAN}${RECORD_TYPE}${RESET}]"
            echo -e "  5. 修改 TTL 缓存时间    [当前: ${GREEN}${HW_TTL:-1}秒${RESET}]"
            echo -e "  0. 返回主菜单"
            echo -e "${CYAN}=========================================${RESET}"
            read -rp "请输入要修改的选项 [0-5]: " sub_choice

            case "$sub_choice" in
                1)
                    read -rp "请输入新的 AK: " new_ak
                    new_ak=$(echo "$new_ak" | tr -d '[:space:]')
                    [ -z "$new_ak" ] && echo -e "${RED}AK 不能为空，已取消修改！${RESET}" || verify_and_save_hw "$new_ak" "$HW_SK" "$RECORD_NAME" "$RECORD_TYPE" "$HW_TTL"
                    pause_return ;;
                2)
                    read -rp "请输入新的 SK: " new_sk
                    new_sk=$(echo "$new_sk" | tr -d '[:space:]')
                    [ -z "$new_sk" ] && echo -e "${RED}SK 不能为空，已取消修改！${RESET}" || verify_and_save_hw "$HW_AK" "$new_sk" "$RECORD_NAME" "$RECORD_TYPE" "$HW_TTL"
                    pause_return ;;
                3)
                    read -rp "请输入新的域名: " new_domain
                    new_domain=$(echo "$new_domain" | tr -d '[:space:]')
                    new_domain="${new_domain%.}"
                    [ -z "$new_domain" ] && echo -e "${RED}域名不能为空，已取消修改！${RESET}" || verify_and_save_hw "$HW_AK" "$HW_SK" "$new_domain" "$RECORD_TYPE" "$HW_TTL"
                    pause_return ;;
                4)
                    read -rp "请选择解析类型 [1: IPv4(A) / 2: IPv6(AAAA)]: " new_type_c
                    if [ "$new_type_c" = "1" ]; then
                        verify_and_save_hw "$HW_AK" "$HW_SK" "$RECORD_NAME" "A" "$HW_TTL"
                    elif [ "$new_type_c" = "2" ]; then
                        verify_and_save_hw "$HW_AK" "$HW_SK" "$RECORD_NAME" "AAAA" "$HW_TTL"
                    else
                        echo -e "${RED}输入无效，已取消修改！${RESET}"
                    fi
                    pause_return ;;
                5)
                    read -rp "请输入新的 TTL 秒数 (默认 1): " new_ttl
                    new_ttl=$(echo "$new_ttl" | tr -cd '0-9')
                    new_ttl=${new_ttl:-1}
                    [ "$new_ttl" -lt 1 ] && new_ttl=1
                    verify_and_save_hw "$HW_AK" "$HW_SK" "$RECORD_NAME" "$RECORD_TYPE" "$new_ttl"
                    pause_return ;;
                0) break ;;
                *) echo -e "${RED}无效选项，请重新输入！${RESET}"; pause_return ;;
            esac
        else
            local proxy_str="${YELLOW}关闭 (false)${RESET}"
            [ "$PROXIED" = "true" ] && proxy_str="${GREEN}开启 (true)${RESET}"
            local masked_token="已配置"
            [ ${#CF_TOKEN} -gt 8 ] && masked_token="${CF_TOKEN:0:4}****${CF_TOKEN: -4}"
            echo -e "  1. 修改 CF 邮箱         [当前: ${YELLOW}${CF_EMAIL}${RESET}]"
            echo -e "  2. 修改 DDNS 域名       [当前: ${GREEN}${RECORD_NAME}${RESET}]"
            echo -e "  3. 修改 API Token       [当前: ${YELLOW}${masked_token}${RESET}]"
            echo -e "  4. 切换解析类型(A/AAAA) [当前: ${CYAN}${RECORD_TYPE}${RESET}]"
            echo -e "  5. 切换小黄云代理开关   [当前: ${proxy_str}]"
            echo -e "  0. 返回主菜单"
            echo -e "${CYAN}=========================================${RESET}"
            read -rp "请输入要修改的选项 [0-5]: " sub_choice

            case "$sub_choice" in
                1)
                    read -rp "请输入新的 CF 邮箱: " new_email
                    new_email=$(echo "$new_email" | tr -d '[:space:]')
                    [ -z "$new_email" ] && echo -e "${RED}邮箱不能为空，已取消修改！${RESET}" || verify_and_save_cf "$new_email" "$RECORD_NAME" "$CF_TOKEN" "$RECORD_TYPE" "$PROXIED"
                    pause_return ;;
                2)
                    read -rp "请输入新的域名: " new_domain
                    new_domain=$(echo "$new_domain" | tr -d '[:space:]')
                    new_domain="${new_domain%.}"
                    [ -z "$new_domain" ] && echo -e "${RED}域名不能为空，已取消修改！${RESET}" || verify_and_save_cf "$CF_EMAIL" "$new_domain" "$CF_TOKEN" "$RECORD_TYPE" "$PROXIED"
                    pause_return ;;
                3)
                    read -rp "请输入新的 Token: " new_token
                    new_token=$(echo "$new_token" | tr -d '[:space:]')
                    [ -z "$new_token" ] && echo -e "${RED}Token 不能为空，已取消修改！${RESET}" || verify_and_save_cf "$CF_EMAIL" "$RECORD_NAME" "$new_token" "$RECORD_TYPE" "$PROXIED"
                    pause_return ;;
                4)
                    read -rp "请选择解析类型 [1: IPv4(A) / 2: IPv6(AAAA)]: " new_type_c
                    if [ "$new_type_c" = "1" ]; then
                        verify_and_save_cf "$CF_EMAIL" "$RECORD_NAME" "$CF_TOKEN" "A" "$PROXIED"
                    elif [ "$new_type_c" = "2" ]; then
                        verify_and_save_cf "$CF_EMAIL" "$RECORD_NAME" "$CF_TOKEN" "AAAA" "$PROXIED"
                    else
                        echo -e "${RED}输入无效，已取消修改！${RESET}"
                    fi
                    pause_return ;;
                5)
                    read -rp "请选择小黄云状态 [1: 关闭(false) / 2: 开启(true)]: " new_proxy_c
                    local new_p=""
                    if [ "$new_proxy_c" = "1" ]; then
                        new_p="false"
                    elif [ "$new_proxy_c" = "2" ]; then
                        new_p="true"
                    else
                        echo -e "${RED}输入无效，已取消修改！${RESET}"
                        pause_return
                        continue
                    fi
                    sed -i "s/^PROXIED=.*/PROXIED=\"${new_p}\"/" "$CONFIG_FILE"
                    rm -f "$IP_CACHE_FILE"
                    echo -e "${GREEN}小黄云状态已更新为: ${new_p}，正在同步...${RESET}"
                    update_ddns "interactive"
                    wakeup_daemon
                    pause_return ;;
                0) break ;;
                *) echo -e "${RED}无效选项，请重新输入！${RESET}"; pause_return ;;
            esac
        fi
    done
}

# ==================== 统一更新逻辑 ====================
update_ddns() {
    local mode="$1"

    if [ ! -f "$CONFIG_FILE" ]; then
        [ "$mode" = "interactive" ] && echo -e "${RED}未找到配置文件，请先选择 [1] 进行配置！${RESET}"
        log_msg "错误: 配置文件不存在 ($CONFIG_FILE)"
        return 1
    fi

    # shellcheck source=/dev/null
    . "$CONFIG_FILE"
    PROVIDER="${PROVIDER:-cloudflare}"

    current_ip=$(get_public_ip "$RECORD_TYPE" "$mode")
    date '+%Y-%m-%d %H:%M:%S' > "$LAST_CHECK_FILE"

    if [ -z "$current_ip" ]; then
        log_msg "错误: 未获取到已确认来源的 ${RECORD_TYPE} 地址（检测失败、来源待选择或用户取消），已保留原记录"
        [ "$mode" = "interactive" ] && echo -e "${RED}未获取到已确认来源的 IP（检测失败、来源待选择或已取消；IPv4 可在菜单 [8] 选择），已安全保留原解析记录！${RESET}"
        return 1
    fi

    cached_ip=""
    [ -f "$IP_CACHE_FILE" ] && cached_ip=$(tr -d '[:space:]' < "$IP_CACHE_FILE")

    if [ "$current_ip" = "$cached_ip" ] && [ "$mode" != "interactive" ]; then
        return 0
    fi

    [ "$mode" = "interactive" ] && echo -e "当前公网 IP: ${CYAN}${current_ip}${RESET}，正在同步至 ${PROVIDER}..."

    if [ "$PROVIDER" = "huawei" ]; then
        local formatted_name="${RECORD_NAME}."
        local ttl_val="${HW_TTL:-1}"
        local update_resp
        local payload="{\"name\":\"${formatted_name}\",\"type\":\"${RECORD_TYPE}\",\"records\":[\"${current_ip}\"],\"ttl\":${ttl_val}}"

        if [ -z "$RECORD_ID" ]; then
            local find_resp
            find_resp=$(hw_api "GET" "/v2/zones/${ZONE_ID}/recordsets?name=${formatted_name}&type=${RECORD_TYPE}" "")
            RECORD_ID=$(hw_parse_id "$find_resp" "recordsets" "$formatted_name" "$RECORD_TYPE")
            [ -n "$RECORD_ID" ] && sed -i "s/^RECORD_ID=.*/RECORD_ID=\"${RECORD_ID}\"/" "$CONFIG_FILE"
        fi

        if [ -n "$RECORD_ID" ]; then
            update_resp=$(hw_api "PUT" "/v2/zones/${ZONE_ID}/recordsets/${RECORD_ID}" "$payload")
            if ! echo "$update_resp" | grep -q '"records"'; then
                RECORD_ID=""
                sed -i "s/^RECORD_ID=.*/RECORD_ID=\"\"/" "$CONFIG_FILE"
            fi
        fi

        if [ -z "$RECORD_ID" ]; then
            update_resp=$(hw_api "POST" "/v2/zones/${ZONE_ID}/recordsets" "$payload")
            RECORD_ID=$(hw_parse_id "$update_resp" "direct" "" "")
            [ -n "$RECORD_ID" ] && sed -i "s/^RECORD_ID=.*/RECORD_ID=\"${RECORD_ID}\"/" "$CONFIG_FILE"
        fi

        if echo "$update_resp" | grep -q '"records"'; then
            echo "$current_ip" > "$IP_CACHE_FILE"
            log_msg "更新成功(华为云): ${RECORD_NAME} -> ${current_ip} (TTL: ${ttl_val}s)"
            [ "$mode" = "interactive" ] && echo -e "${GREEN}华为云 DDNS 更新成功！${RECORD_NAME} -> ${current_ip} (TTL: ${ttl_val}秒)${RESET}"
        else
            log_msg "更新失败(华为云): ${update_resp}"
            [ "$mode" = "interactive" ] && echo -e "${RED}更新失败，返回信息: ${update_resp}${RESET}"
            return 1
        fi
    else
        local payload="{\"type\":\"${RECORD_TYPE}\",\"name\":\"${RECORD_NAME}\",\"content\":\"${current_ip}\",\"ttl\":60,\"proxied\":${PROXIED}}"
        local update_resp

        if [ -z "$RECORD_ID" ]; then
            record_resp=$(cf_api "GET" "/zones/${ZONE_ID}/dns_records?type=${RECORD_TYPE}&name=${RECORD_NAME}")
            if echo "$record_resp" | grep -q '"success":true'; then
                RECORD_ID=$(echo "$record_resp" | grep -o '"id":"[^"]*"' | head -n 1 | cut -d'"' -f4)
                [ -n "$RECORD_ID" ] && sed -i "s/^RECORD_ID=.*/RECORD_ID=\"${RECORD_ID}\"/" "$CONFIG_FILE"
            fi
        fi

        if [ -n "$RECORD_ID" ]; then
            update_resp=$(cf_api "PUT" "/zones/${ZONE_ID}/dns_records/${RECORD_ID}" "$payload")
            if ! echo "$update_resp" | grep -q '"success":true'; then
                RECORD_ID=""
                sed -i "s/^RECORD_ID=.*/RECORD_ID=\"\"/" "$CONFIG_FILE"
            fi
        fi

        if [ -z "$RECORD_ID" ]; then
            update_resp=$(cf_api "POST" "/zones/${ZONE_ID}/dns_records" "$payload")
        fi

        if echo "$update_resp" | grep -q '"success":true'; then
            new_id=$(echo "$update_resp" | grep -o '"id":"[^"]*"' | head -n 1 | cut -d'"' -f4)
            if [ -n "$new_id" ] && [ "$new_id" != "$RECORD_ID" ]; then
                sed -i "s/^RECORD_ID=.*/RECORD_ID=\"${new_id}\"/" "$CONFIG_FILE"
            fi
            echo "$current_ip" > "$IP_CACHE_FILE"
            log_msg "更新成功(Cloudflare): ${RECORD_NAME} (${RECORD_TYPE}) -> ${current_ip} (Proxied: ${PROXIED})"
            [ "$mode" = "interactive" ] && echo -e "${GREEN}Cloudflare DDNS 更新成功！${RECORD_NAME} -> ${current_ip} (小黄云: ${PROXIED})${RESET}"
        else
            log_msg "更新失败(Cloudflare): ${update_resp}"
            [ "$mode" = "interactive" ] && echo -e "${RED}更新失败，返回信息: ${update_resp}${RESET}"
            return 1
        fi
    fi
}

# 后台守护循环 (单实例互斥 + 实时读取间隔)
run_daemon() {
    local arg_interval="$1"

    if [ -f "$PID_FILE" ]; then
        local old_pid
        old_pid=$(tr -cd '0-9' < "$PID_FILE")
        if [ -n "$old_pid" ] && [ "$old_pid" != "$$" ] && kill -0 "$old_pid" 2>/dev/null; then
            pkill -P "$old_pid" 2>/dev/null || true
            kill "$old_pid" 2>/dev/null || true
        fi
    fi

    echo $$ > "$PID_FILE"
    trap 'kill $(jobs -p) 2>/dev/null; rm -f "$PID_FILE"; exit 0' TERM INT

    local init_interval="${arg_interval:-120}"
    if [ -f "$INTERVAL_FILE" ]; then
        local file_int
        file_int=$(tr -cd '0-9' < "$INTERVAL_FILE")
        [ -n "$file_int" ] && init_interval="$file_int"
    fi
    log_msg "后台定时任务已启动 (PID: $$ | 间隔: ${init_interval} 秒)"

    while true; do
        interval="${arg_interval:-120}"
        if [ -f "$INTERVAL_FILE" ]; then
            local tmp_int
            tmp_int=$(tr -cd '0-9' < "$INTERVAL_FILE")
            [ -n "$tmp_int" ] && interval="$tmp_int"
        fi
        update_ddns "daemon"
        sleep "$interval" &
        wait $! 2>/dev/null || true
    done
}

# 停止后台任务
stop_timer() {
    local quiet="$1"
    if [ "$(id -u)" -eq 0 ] && command -v systemctl >/dev/null 2>&1 && [ -f "$SERVICE_FILE" ]; then
        systemctl stop cf-ddns.service >/dev/null 2>&1
        systemctl disable cf-ddns.service >/dev/null 2>&1
        rm -f "$SERVICE_FILE"
        systemctl daemon-reload >/dev/null 2>&1
    fi

    if [ -f "$PID_FILE" ]; then
        local pid
        pid=$(tr -cd '0-9' < "$PID_FILE")
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            pkill -P "$pid" 2>/dev/null || true
            kill "$pid" 2>/dev/null || true
        fi
        rm -f "$PID_FILE"
    fi

    pkill -f "cf-ddns.sh --daemon" 2>/dev/null || true
    crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH" | crontab - 2>/dev/null || true
    [ "$quiet" != "quiet" ] && echo -e "${GREEN}已停止后台 DDNS 定时任务。${RESET}"
}

# 开启 / 修改后台定时任务 (按秒)
setup_timer() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}请先选择 [1] 完成配置！${RESET}"
        return 1
    fi

    echo -e "\n${CYAN}--- 设置后台定时任务 (按秒执行) ---${RESET}"
    read -rp "定时任务设置时间（默认120秒，支持最小5秒）：" raw_interval
    interval=$(echo "$raw_interval" | tr -d '[:space:]')
    interval=${interval:-120}

    case "$interval" in
        ''|*[!0-9]*)
            echo -e "${YELLOW}输入包含非数字字符，已使用默认值 120 秒。${RESET}"
            interval=120
            ;;
        *)
            if [ "$interval" -lt 5 ]; then
                echo -e "${YELLOW}输入小于 5 秒，已设为最小允许值 5 秒。${RESET}"
                interval=5
            fi
            ;;
    esac

    persist_self

    echo "$interval" > "$INTERVAL_FILE"
    stop_timer "quiet"

    if [ "$(id -u)" -eq 0 ] && command -v systemctl >/dev/null 2>&1; then
        {
            printf '[Unit]\n'
            printf 'Description=Lightweight Multi-Provider DDNS Service\n'
            printf 'After=network-online.target\n'
            printf 'Wants=network-online.target\n\n'
            printf '[Service]\n'
            printf 'Type=simple\n'
            printf 'Environment="HOME=%s"\n' "${HOME}"
            printf 'Environment="CONFIG_DIR=%s"\n' "${CONFIG_DIR}"
            printf 'ExecStart=/usr/bin/env bash "%s" --daemon %s\n' "${SCRIPT_PATH}" "${interval}"
            printf 'Restart=always\n'
            printf 'RestartSec=5\n\n'
            printf '[Install]\n'
            printf 'WantedBy=multi-user.target\n'
        } > "$SERVICE_FILE"

        systemctl daemon-reload
        systemctl enable --now cf-ddns.service >/dev/null 2>&1
        sleep 0.3
        echo -e "${GREEN}后台定时任务已启动 (Systemd 服务，支持开机自启)！检测间隔：每 ${interval} 秒。${RESET}"
    else
        nohup env HOME="$HOME" CONFIG_DIR="$CONFIG_DIR" /usr/bin/env bash "$SCRIPT_PATH" --daemon "$interval" >/dev/null 2>&1 &
        (crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH"; echo "@reboot env HOME=\"$HOME\" CONFIG_DIR=\"$CONFIG_DIR\" nohup /usr/bin/env bash \"${SCRIPT_PATH}\" --daemon ${interval} >/dev/null 2>&1 &") | crontab - 2>/dev/null
        sleep 0.3
        echo -e "${GREEN}后台定时任务已启动 (Nohup 守护进程)！检测间隔：每 ${interval} 秒。${RESET}"
    fi
}

# 查看当前状态与日志
show_status() {
    echo -e "\n${CYAN}--- 当前配置与运行状态 ---${RESET}"
    if [ -f "$CONFIG_FILE" ]; then
        # shellcheck source=/dev/null
        . "$CONFIG_FILE"
        echo -e "DNS 服务商: ${CYAN}${PROVIDER:-cloudflare}${RESET}"
        echo -e "监控域名  : ${GREEN}${RECORD_NAME}${RESET} (${RECORD_TYPE})"
        if [ "${PROVIDER:-cloudflare}" = "huawei" ]; then
            echo -e "绑定 AK   : ${HW_AK}"
            echo -e "TTL 设定  : ${GREEN}${HW_TTL:-1} 秒 (极速生效)${RESET}"
        else
            echo -e "绑定邮箱  : ${CF_EMAIL}"
            echo -e "鉴权模式  : ${AUTH_MODE} Token"
            echo -e "CDN 代理  : ${PROXIED}"
        fi
        echo -e "缓存 IP   : ${YELLOW}$([ -f "$IP_CACHE_FILE" ] && cat "$IP_CACHE_FILE" || echo "尚无缓存")${RESET}"
        echo -e "最后检测  : ${CYAN}$([ -f "$LAST_CHECK_FILE" ] && cat "$LAST_CHECK_FILE" || echo "尚无记录")${RESET}"
    else
        echo -e "配置状态  : ${RED}尚未配置${RESET}"
    fi

    local ipv4_source
    ipv4_source=$(read_ipv4_source)
    case "$ipv4_source" in
        direct) echo 'IPv4 来源 : eth0 直连 1.1.1.1（已持久化）' ;;
        normal) echo 'IPv4 来源 : 普通查询（已持久化）' ;;
        *) echo 'IPv4 来源 : 尚未选择，两路结果一致时更新，不一致时需选择' ;;
    esac

    local cur_interval="120"
    if [ -f "$INTERVAL_FILE" ]; then
        local tmp_int
        tmp_int=$(tr -cd '0-9' < "$INTERVAL_FILE")
        [ -n "$tmp_int" ] && cur_interval="$tmp_int"
    fi

    local is_running=false
    local run_pid=""

    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet cf-ddns.service 2>/dev/null; then
        is_running=true
        run_pid=$(systemctl show -p MainPID --value cf-ddns.service 2>/dev/null)
        [ "$run_pid" = "0" ] && run_pid=""
    fi

    if [ "$is_running" = false ] && [ -f "$PID_FILE" ]; then
        local f_pid
        f_pid=$(tr -cd '0-9' < "$PID_FILE")
        if [ -n "$f_pid" ] && kill -0 "$f_pid" 2>/dev/null; then
            is_running=true
            run_pid="$f_pid"
        fi
    fi

    if [ "$is_running" = false ]; then
        run_pid=$(pgrep -f "cf-ddns.sh --daemon" 2>/dev/null | head -n 1)
        [ -n "$run_pid" ] && is_running=true
    fi

    if [ "$is_running" = true ]; then
        echo -e "定时状态  : ${GREEN}后台运行中${RESET} (PID: ${run_pid:-守护进程} | 间隔: ${cur_interval} 秒)"
    else
        echo -e "定时状态  : ${YELLOW}未运行${RESET}"
    fi

    echo -e "\n${CYAN}--- 最近 15 条运行日志 ---${RESET}"
    if [ -f "$LOG_FILE" ]; then
        tail -n 15 "$LOG_FILE"
    else
        echo "暂无日志记录。"
    fi
}

# 彻底卸载脚本
uninstall_ddns() {
    echo -e "\n${RED}=================== 警告 ===================${RESET}"
    echo -e "${YELLOW}即将彻底卸载 DDNS 脚本！该操作将：${RESET}"
    echo "  1. 停止并移除后台定时任务与开机自启服务"
    echo "  2. 删除所有配置文件、IP 缓存、守护脚本与运行日志 ($CONFIG_DIR)"
    echo -e "${RED}============================================${RESET}"
    read -rp "确认要彻底卸载吗？[y/N]: " confirm_uninst

    case "$confirm_uninst" in
        [yY][eE][sS]|[yY])
            stop_timer "quiet"
            local caller_script=""
            if [ -f "$0" ] && [[ "$0" != *"/dev/fd/"* ]] && [[ "$0" != *"/proc/"* ]]; then
                caller_script="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")"
            fi
            rm -rf "$CONFIG_DIR"
            [ -n "$caller_script" ] && rm -f "$caller_script" 2>/dev/null
            echo -e "${GREEN}卸载完成！所有服务、配置及脚本自身已彻底清除。${RESET}"
            exit 0
            ;;
        *)
            echo -e "${CYAN}已取消卸载操作。${RESET}"
            ;;
    esac
}

# 主交互菜单函数
main_menu() {
    ensure_dependencies "curl"
    persist_self

    while true; do
        echo -e "\n${CYAN}=========================================${RESET}"
        echo -e "${CYAN}     多平台轻量级 DDNS 管理脚本          ${RESET}"
        echo -e "${CYAN}=========================================${RESET}"
        echo "  1. 初次配置 DDNS (Cloudflare / 华为云)"
        echo "  2. 修改现有配置 (二级菜单单项修改)"
        echo "  3. 立即执行一次 DDNS 同步 (测试/强制刷新)"
        echo "  4. 开启 / 修改后台定时任务 (按秒设置)"
        echo "  5. 停止后台定时任务"
        echo "  6. 查看当前状态与运行日志"
        echo "  7. 彻底卸载脚本 (停止服务并清除所有文件)"
        echo "  8. 选择 / 更换 IPv4 获取方式（持久化）"
        echo "  0. 退出脚本"
        echo -e "${CYAN}=========================================${RESET}"
        read -rp "请输入数字选择功能 [0-8]: " choice

        case "$choice" in
            1) configure_ddns; pause_return ;;
            2) modify_config_menu ;;
            3) update_ddns "interactive"; pause_return ;;
            4) setup_timer; pause_return ;;
            5) stop_timer; pause_return ;;
            6) show_status; pause_return ;;
            7) uninstall_ddns; pause_return ;;
            8) configure_ipv4_source; pause_return ;;
            0) echo "已退出。"; exit 0 ;;
            *) echo -e "${RED}无效选项，请重新输入！${RESET}"; pause_return ;;
        esac
    done
}

# 入口路由
if [ "${1:-}" = "--daemon" ]; then
    run_daemon "${2:-}"
    exit 0
fi

main_menu "$@"
