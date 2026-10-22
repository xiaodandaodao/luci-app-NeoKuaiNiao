#!/bin/sh
# =============================================================================
# kpn.sh —— NeoKuaiNiao 核心：迅雷快鸟宽带提速守护（OpenWrt / QWRT）
#
# 设计原则
#   1. 只做控制面：登录态续期 → 查询带宽 → 下发提速 → 心跳保活 → 恢复。
#      提速发生在运营商侧的带宽模板，不碰数据面、不需要内核模块。
#   2. 两条取凭证的路：
#      a) 页面内直接登录：账号密码 + 图形验证码（本机出口 IP 就是宽带 IP，最可靠）；
#         密码只落在 tmpfs，登录成功/取消/超时（10 分钟）立即删除，不写 flash。
#      b) 凭证导入式：在电脑上跑 kp-login.sh 拿到 loginKey，粘贴到页面导入。
#      日常运行都只靠 loginKey 走 /loginkey 静默续期，不再碰密码与验证码。
#   3. 不硬绑 curl：QWRT 自带 curl 与 libcurl 版本不匹配会 "Error relocating" 崩，
#      HTTP 走 uclient-fetch/wget/nc，HTTPS 走 openssl s_client。
#
# 前提：你本人已购买快鸟 / 超级会员权益，且线路官方客户端可提速。
#       本程序不提供、也不得用于绕过付费权益、共享账号或免会员提速。
#
# 子命令：
#   kpn.sh status      查询带宽并刷新状态文件
#   kpn.sh up          下发提速
#   kpn.sh down        恢复带宽（不删凭证）
#   kpn.sh renew       用 loginKey 静默续期 sessionID
#   kpn.sh run-once    一轮完整流程（探测 → 提速 → 心跳），供手动触发
#   kpn.sh daemon      常驻守护（init.d 调用）
#   kpn.sh state       打印状态 JSON（供 LuCI 读取）
#   kpn.sh login-prepare <账号>   提交登录并取验证码图（密码取自 /var/run/neokuainiao/login.pw）
#   kpn.sh login-submit <验证码>  提交验证码，成功即写入凭证
#   kpn.sh login-refresh          换一张验证码
#   kpn.sh login-cancel           清除临时登录会话（含内存中的密码）
# =============================================================================

set -u

CONF=neokuainiao
# 路径可用环境变量覆盖，便于在开发机上用桩程序做端到端验证
CRED_DIR="${KPN_CRED_DIR:-/etc/neokuainiao}"
CRED="$CRED_DIR/cred.env"
RUN_DIR="${KPN_RUN_DIR:-/var/run/neokuainiao}"
ST_FILE="$RUN_DIR/status.json"
LOG_TAG=neokuainiao

# ------------------------------- 协议常量 ------------------------------------
LOGIN_RENEW_URL="https://mobile-login.xunlei.com/loginkey"
PORTAL_HOST="api.portal.swjsq.vip.xunlei.com"
PORTAL_PORT=81
PROTOCOL_VER=200
APP_VER=2.4.1.3
SDK_VERSION=177662
DEV_MODEL=R1
DEV_NAME="SmallRice R1"
OS_VERSION=5.0.1
OS_API_LEVEL=24
OS_FIELD="android-${OS_VERSION}.${OS_API_LEVEL}${DEV_MODEL}"
UA="android-async-http/xl-acc-sdk/version-2.1.1.177662"
PKG_NAME_APP="com.xunlei.vip.swjsq"
BUSINESS_TYPE=68

KP_USERID="${KP_USERID:-}"
KP_LOGINKEY="${KP_LOGINKEY:-}"
KP_SESSION="${KP_SESSION:-}"
KP_PEERID="${KP_PEERID:-}"
KP_DEVICESIGN="${KP_DEVICESIGN:-}"
KP_PORTAL_IP="${KP_PORTAL_IP:-}"
KP_PORTAL_API_PORT="${KP_PORTAL_API_PORT:-}"
KP_DIAL="${KP_DIAL:-}"

# 运行态
CUR_DOWN=0; MAX_DOWN=0; UP_CUR=0; UP_SUPPORTED=0
ERRNO=""; MSG=""; PROVINCE=""; SP=""
LAST_UP=0
# 服务端把 upgrade / keepalive 视为同一类「点击」请求，有最小间隔限制：被限流时
# 响应里明示 button_data.can_click_time=120（秒）。实测（2026-10-23 路由器日志）：
# 提速成功后同一秒发心跳 100% 被 711 拒——心跳白发、加速状态没人保，反而引发
# 「掉速(513)→重提→2204 风暴」死循环。故：
#   CLICK_GAP_SEC   任意两次点击类请求的最小间隔（120 + 余量）；
#   RECONFIRM_SEC   距上次成功提速超过该时长，兜底强制重新确认一次；
#   RETRY_SEC       一轮失败（掉速/瞬时错误/网络问题）后的重试间隔；
#   BOOST_OK=1      本会话已确认在提速状态，跳过重复下发；跨进程从 status.json
#                   继承（仅上一轮 state=running 时才继承，见 _inherit_state）。
CLICK_GAP_SEC=130
RECONFIRM_SEC=10800
RETRY_SEC=300
BOOST_OK=0

# ------------------------------- 日志 ----------------------------------------
_log()  { echo "[neokuainiao] $*"; logger -t "$LOG_TAG" "$*" 2>/dev/null; }
_warn() { echo "[neokuainiao] $*" >&2; logger -t "$LOG_TAG" "WARN: $*" 2>/dev/null; }
_die()  { _warn "错误：$*"; exit 1; }

# ------------------------------- 配置 ----------------------------------------
# QWRT 的 uci **不支持**省略 section 名的简写：`uci get neokuainiao.enabled`
# 会直接失败（rc=1），必须写全 `neokuainiao.<section>.<option>`。
# 而 section 名随版本可能不同（config / main），所以启动时探测一次并缓存。
# 注意：`uci get <cfg>.@<type>[0]` 在 QWRT 上返回的是 **type 而不是 section 名**，
# 不能直接用；改为遍历 uci show 的 section，取第一个带 enabled 选项的。
CFG_SECTION=""
_cfg_section() {
  [ -n "$CFG_SECTION" ] && { printf '%s' "$CFG_SECTION"; return 0; }
  local s="" name
  for name in $(uci show "$CONF" 2>/dev/null | grep -E "^${CONF}\.[^.=]+=" | cut -d. -f2 | cut -d= -f1); do
    if uci -q get "${CONF}.${name}.enabled" >/dev/null 2>&1; then s="$name"; break; fi
  done
  [ -z "$s" ] && s=$(uci show "$CONF" 2>/dev/null | grep -E "^${CONF}\.[^.=]+=" | head -1 | cut -d. -f2 | cut -d= -f1)
  CFG_SECTION="$s"
  printf '%s' "$s"
}
_cfg() {
  local s; s=$(_cfg_section)
  [ -n "$s" ] || return 1
  uci -q get "${CONF}.${s}.$1" 2>/dev/null
}
_cfg_def(){ local v; v=$(_cfg "$1"); [ -n "$v" ] && echo "$v" || echo "$2"; }

_interval() { local v; v=$(_cfg_def interval 300); echo "$v"; }
_enabled()  { [ "$(_cfg_def enabled 0)" = "1" ]; }

# ------------------------------- 凭证 ----------------------------------------
_load_cred() {
  [ -f "$CRED" ] && . "$CRED" >/dev/null 2>&1
  KP_USERID="${KP_USERID:-${USERID:-}}"
  KP_LOGINKEY="${KP_LOGINKEY:-${LOGINKEY:-}}"
  KP_SESSION="${KP_SESSION:-${SESSIONID:-}}"
  KP_PEERID="${KP_PEERID:-${PEERID:-}}"
  KP_DEVICESIGN="${KP_DEVICESIGN:-${DEVICESIGN:-}}"
  KP_PORTAL_IP="${KP_PORTAL_IP:-${INTERFACE_IP:-}}"
  KP_PORTAL_API_PORT="${KP_PORTAL_API_PORT:-${INTERFACE_PORT:-}}"
  KP_DIAL="${KP_DIAL:-${DIAL_ACCOUNT:-}}"
}

_save_cred() {
  mkdir -p "$CRED_DIR"
  umask 077
  {
    echo "# NeoKuaiNiao 凭证 —— 等同账号凭证，勿外传、勿打包进配置备份"
    echo "KP_USERID='${KP_USERID:-}'"
    echo "KP_LOGINKEY='${KP_LOGINKEY:-}'"
    echo "KP_SESSION='${KP_SESSION:-}'"
    echo "KP_PEERID='${KP_PEERID:-}'"
    echo "KP_DEVICESIGN='${KP_DEVICESIGN:-}'"
    echo "KP_PORTAL_IP='${KP_PORTAL_IP:-}'"
    echo "KP_PORTAL_API_PORT='${KP_PORTAL_API_PORT:-}'"
    echo "KP_DIAL='${KP_DIAL:-}'"
  } > "$CRED"
  chmod 600 "$CRED" 2>/dev/null
}

# --------------------------- 状态文件（给 LuCI） ------------------------------
# 从上一份状态文件里继承「最近提速时间」：CLI 单次调用（run-once / up）是新进程，
# LAST_UP 从 0 开始，不继承就会重复点击、把页面「最近提速」冲掉。
# 注意只继承 last_up、不继承 boost_ok：_state_write 也会调它，若连 boost_ok 一起
# 继承，心跳刚失败（513）清掉 BOOST_OK 后写状态时会把旧的 boost_ok=1 复活，
# 下一轮就不重试了（实测过的坑）。
_inherit_last_up() {
  [ "${LAST_UP:-0}" = "0" ] && [ -f "$ST_FILE" ] || return 0
  local prev
  prev=$(sed -n 's/.*"last_up":\([0-9][0-9]*\).*/\1/p' "$ST_FILE" 2>/dev/null | head -1)
  [ -n "$prev" ] && LAST_UP="$prev"
  return 0
}

# 进程入口（do_run_once / do_up）调用：除 last_up 外还继承「已确认提速」标记。
# CLI 单次调用是新进程，BOOST_OK 从 0 开始，不继承就会在服务端已提速的状态下
# 重复点击 upgrade（实测 07:31 手动 run-once 又点了一次）。
# last_up 在这里**强制**继承（覆盖内存值）：守护进程要能看到手动 run-once / up
# 的点击，共享同一个 130 秒点击窗口，否则手动点完速守护进程下一轮又发心跳撞 711。
# BOOST_OK 仅在上一轮 state=running 时继承——心跳刚失败（keepalive_fail）说明
# 提速状态可能已丢，新进程必须重新点击，不能沿用旧的确认标记。
_inherit_state() {
  [ -f "$ST_FILE" ] || return 0
  local prev st
  prev=$(sed -n 's/.*"last_up":\([0-9][0-9]*\).*/\1/p' "$ST_FILE" 2>/dev/null | head -1)
  [ -n "$prev" ] && LAST_UP="$prev"
  [ "${BOOST_OK:-0}" = "0" ] || return 0
  st=$(sed -n 's/.*"state":"\([^"]*\)".*/\1/p' "$ST_FILE" 2>/dev/null | head -1)
  [ "$st" = "running" ] || return 0
  prev=$(sed -n 's/.*"boost_ok":\([01]\).*/\1/p' "$ST_FILE" 2>/dev/null | head -1)
  [ "$prev" = "1" ] && BOOST_OK=1
  return 0
}

_state_write() {
  local state="$1" msg="${2:-}"
  _inherit_last_up
  # 去掉会破坏 JSON 的引号/反斜杠/换行
  msg=$(printf '%s' "$msg" | tr -d '"\\' | tr '\n' ' ')
  local dial; dial=$(printf '%s' "${KP_DIAL:-}" | tr -d '"\\')
  mkdir -p "$RUN_DIR"
  cat > "$ST_FILE.$$" <<EOF
{"ts":$(date +%s),"state":"${state}","cur_down":${CUR_DOWN:-0},"max_down":${MAX_DOWN:-0},"up_cur":${UP_CUR:-0},"up_supported":${UP_SUPPORTED:-0},"errno":"${ERRNO}","msg":"${msg}","province":"${PROVINCE}","sp":"${SP}","dial":"${dial}","userid":"${KP_USERID:-}","has_session":"$([ -n "${KP_SESSION:-}" ] && echo 1 || echo 0)","last_up":${LAST_UP:-0},"boost_ok":${BOOST_OK:-0}}
EOF
  mv "$ST_FILE.$$" "$ST_FILE" 2>/dev/null
  chmod 644 "$ST_FILE" 2>/dev/null
}

do_state() {
  _load_cred
  [ -f "$ST_FILE" ] && cat "$ST_FILE" || echo '{"ts":0,"state":"unknown","cur_down":0,"max_down":0,"up_cur":0,"up_supported":0,"errno":"","msg":"","province":"","sp":"","dial":"","userid":"","has_session":0,"last_up":0,"boost_ok":0}'
}

# ------------------------------- 工具 ----------------------------------------
# 轻量 JSON 取值：先试字符串 "k":"v"，再试数字 "k":n
_jget() {
  local k="$1" j="$2" v
  v=$(printf '%s' "$j" | sed -n "s/.*\"$k\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1)
  if [ -z "$v" ]; then
    v=$(printf '%s' "$j" | sed -n "s/.*\"$k\"[[:space:]]*:[[:space:]]*\([0-9a-fA-F.:,-]*\)[},].*/\1/p" | head -1)
  fi
  printf '%s' "$v"
}
# 注意必须走 stderr：_do_upgrade/_do_keepalive 的 stdout 要被 `$(...)` 捕获当返回值，
# 诊断信息混进 stdout 会污染 errno（曾导致 msg 变成 "errno=[neokuainiao] raw: {...} 711"）
_vraw() { [ "${KPN_VERBOSE:-0}" = "1" ] && _log "raw: $1" >&2; }

# --------------------------- HTTP 客户端抽象 ---------------------------------
_curl_works=0
if command -v curl >/dev/null 2>&1 && curl --version >/dev/null 2>&1; then
  _curl_works=1
fi

_bind_iface() {
  local i; i=$(_cfg_def iface "")
  [ -n "$i" ] && printf '%s' "--interface $i"
}

# 明文 HTTP GET（portal 全部走 HTTP）
_get() {
  local url="$1" iface_arg
  if [ "$_curl_works" = "1" ]; then
    iface_arg=$(_bind_iface)
    curl -s --max-time 20 $iface_arg "$url"
    return
  fi
  if command -v uclient-fetch >/dev/null 2>&1; then
    uclient-fetch -O - "$url" 2>/dev/null; return
  fi
  if command -v wget >/dev/null 2>&1; then
    wget -q -O - "$url" 2>/dev/null; return
  fi
  _die "缺少 HTTP 客户端（curl / uclient-fetch / wget 均不可用）"
}

_strip_body() { awk 'BEGIN{s=0} /^[[:space:]]*$/{s=1;next} s{print}' | tr -d '\r'; }

# HTTPS 上 JSON POST（仅 loginKey 续期用）
_post_json() {
  local url="$1" body="$2" rest host path len
  if [ "$_curl_works" = "1" ]; then
    curl -s --max-time 20 -A "$UA" -X POST -H "Content-Type: application/json" --data "$body" "$url"
    return
  fi
  rest="${url#https://}"
  case "$rest" in
    */*) host="${rest%%/*}"; path="/${rest#*/}" ;;
    *)   host="$rest"; path="/" ;;
  esac
  len="${#body}"
  printf 'POST %s HTTP/1.0\015\012Host: %s\015\012Content-Type: application/json\015\012Content-Length: %d\015\012User-Agent: %s\015\012Connection: close\015\012\015\012%s' \
    "$path" "$host" "$len" "$UA" "$body" \
    | openssl s_client -connect "${host}:443" -quiet 2>/dev/null \
    | _strip_body
}

# --------------------------- portal 各步 -------------------------------------
_ensure_portal() {
  [ -n "$KP_PORTAL_IP" ] && [ -n "$KP_PORTAL_API_PORT" ] && return 0
  local r
  r=$(_get "http://${PORTAL_HOST}:${PORTAL_PORT}/v2/queryportal")
  _vraw "$r"
  local e; e=$(_jget errno "$r")
  if [ "$e" != "0" ]; then
    ERRNO="$e"; MSG="queryportal 失败"
    _warn "portal 发现失败 errno=${e}（检查是否有代理/旁路由改变源 IP）"
    return 1
  fi
  KP_PORTAL_IP=$(_jget interface_ip "$r")
  KP_PORTAL_API_PORT=$(_jget interface_port "$r")
  PROVINCE=$(_jget province_name "$r")
  SP=$(_jget sp_name "$r")
  [ -z "$KP_PORTAL_IP" ] && { ERRNO=""; MSG="portal 无 interface_ip"; return 1; }
  _save_cred
  return 0
}

# 查询带宽：设置 CUR_DOWN / MAX_DOWN / UP_CUR / UP_SUPPORTED / KP_DIAL
_query_bandwidth() {
  _ensure_portal || return 1
  local ts; ts="$(date +%s)000"
  local r
  r=$(_get "http://${KP_PORTAL_IP}:${KP_PORTAL_API_PORT}/v2/bandwidth?peerid=${KP_PEERID}&userid=${KP_USERID}&client_type=android-swjsq-${APP_VER}&time_and=${ts}&client_version=androidswjsq-${APP_VER}&os=${OS_FIELD}")
  _vraw "$r"
  local cu; cu=$(_jget can_upgrade "$r")
  KP_DIAL=$(_jget dial_account "$r")
  PROVINCE=$(_jget province_name "$r"); SP=$(_jget sp_name "$r")
  CUR_DOWN=$(printf '%s' "$r" | sed -n 's/.*"bandwidth":{\([^}]*\)}.*/\1/p' | sed -n 's/.*"downstream":\([0-9]*\).*/\1/p' | head -1)
  MAX_DOWN=$(printf '%s' "$r" | sed -n 's/.*"max_bandwidth":{\([^}]*\)}.*/\1/p' | sed -n 's/.*"downstream":\([0-9]*\).*/\1/p' | head -1)
  UP_CUR=$(printf '%s' "$r" | sed -n 's/.*"bandwidth":{\([^}]*\)}.*/\1/p' | sed -n 's/.*"upstream":\([0-9]*\).*/\1/p' | head -1)
  UP_SUPPORTED=$(_jget can_upspeedup "$r")
  [ -z "$CUR_DOWN" ] && CUR_DOWN=0
  [ -z "$MAX_DOWN" ] && MAX_DOWN=0
  [ -z "$UP_CUR" ] && UP_CUR=0
  [ -z "$UP_SUPPORTED" ] && UP_SUPPORTED=0
  _save_cred
  if [ "$cu" != "1" ]; then
    ERRNO=""; MSG="can_upgrade=${cu}"
    _warn "can_upgrade=${cu} —— 线路被判不可提速 / 账号未绑定此宽带"
    return 1
  fi
  ERRNO=""; MSG=""
  return 0
}

# 下发提速：返回 0 成功；1 失败。errno 放在全局 ERRNO / MSG。
# **不要用 `e=$(_do_upgrade)` 捕获**：`$()` 会 fork 子 shell，函数内对全局变量的
# 赋值全部丢在子 shell 里，父进程读到的 ERRNO 还是旧值——曾因此把 errno=711
# 的限流误判成"已提速"，LAST_UP 也永远更新不了。
_do_upgrade() {
  local ts; ts="$(date +%s)000"
  local r
  r=$(_get "http://${KP_PORTAL_IP}:${KP_PORTAL_API_PORT}/v2/upgrade?peerid=${KP_PEERID}&userid=${KP_USERID}&sessionid=${KP_SESSION}&user_type=1&client_type=android-swjsq-${APP_VER}&time_and=${ts}&client_version=androidswjsq-${APP_VER}&os=${OS_FIELD}&dial_account=${KP_DIAL}")
  _vraw "$r"
  local e; e=$(_jget errno "$r")
  ERRNO="$e"; MSG=$(_jget message "$r")
  if [ "$e" = "0" ] || [ "$e" = "812" ]; then
    LAST_UP=$(date +%s)
    return 0
  fi
  return 1
}

# 心跳：同样只用全局 ERRNO / MSG，不用 $() 捕获
_do_keepalive() {
  local ts; ts="$(date +%s)000"
  local r
  r=$(_get "http://${KP_PORTAL_IP}:${KP_PORTAL_API_PORT}/v2/keepalive?peerid=${KP_PEERID}&userid=${KP_USERID}&sessionid=${KP_SESSION}&client_type=android-swjsq-${APP_VER}&time_and=${ts}&client_version=androidswjsq-${APP_VER}&os=${OS_FIELD}&dial_account=${KP_DIAL}")
  _vraw "$r"
  local e; e=$(_jget errno "$r")
  ERRNO="$e"; MSG=$(_jget message "$r")
  [ "$e" = "0" ] && return 0
  return 1
}

_do_recover() {
  local ts; ts="$(date +%s)000"
  _get "http://${KP_PORTAL_IP}:${KP_PORTAL_API_PORT}/v2/recover?peerid=${KP_PEERID}&userid=${KP_USERID}&sessionid=${KP_SESSION}&client_type=android-swjsq-${APP_VER}&time_and=${ts}&client_version=androidswjsq-${APP_VER}&os=${OS_FIELD}&dial_account=${KP_DIAL}" >/dev/null 2>&1
}

# 用 loginKey 续期 sessionID（不碰密码/验证码）
_renew_session() {
  [ -z "$KP_LOGINKEY" ] && { MSG="无 loginKey，无法续期"; return 1; }
  local body r e
  body=$(printf '{"protocolVersion":"%s","sequenceNo":"1000001","platformVersion":"2","sdkVersion":"%s","peerID":"%s","businessType":"68","clientVersion":"%s","devicesign":"%s","isCompressed":"0","userName":"%s","loginKey":"%s","appName":"ANDROID-%s","deviceModel":"%s","deviceName":"%s","OSVersion":"%s"}' \
    "$PROTOCOL_VER" "$SDK_VERSION" "$KP_PEERID" "$APP_VER" "$KP_DEVICESIGN" "$KP_USERID" "$KP_LOGINKEY" "$PKG_NAME_APP" "$DEV_MODEL" "$DEV_NAME" "$OS_VERSION")
  r=$(_post_json "$LOGIN_RENEW_URL" "$body")
  _vraw "$r"
  e=$(_jget errorCode "$r"); [ -z "$e" ] && e=$(_jget errno "$r")
  if [ "$e" = "0" ] || [ -z "$e" ]; then
    local sid; sid=$(_jget sessionID "$r"); [ -z "$sid" ] && sid=$(_jget sessionId "$r")
    if [ -n "$sid" ]; then
      KP_SESSION="$sid"; _save_cred
      _log "sessionID 续期成功"
      return 0
    fi
  fi
  ERRNO="$e"; MSG="续期失败 errorCode=${e}"
  _warn "sessionID 续期失败 errorCode=${e}（loginKey 可能已失效，需在电脑上重新导入）"
  return 1
}

# ------------------------- 账号密码 + 图形验证码登录 --------------------------
# 与 kp-login.sh 同一协议（已实测可拿到 sessionID），但整套跑在路由器本地：
#   本机出口 IP 就是宽带 IP，登录时服务端看到的源 IP 与提速时一致，最不容易被判「宽带不支持」。
# 密码只经 tmpfs（/var/run/neokuainiao/login，0700），登录成功/取消/超时立即删除，绝不写入 /etc。
LOGIN_URL="https://mobile-login.xunlei.com/login"
IMG_URL="http://verify2.xunlei.com/image?t=MEA"
IMG_HOST="verify2.xunlei.com"
IMG_PATH="/image?t=MEA"
DEV_SIGN_SALT="c7f21687eed3cdb400ca11fc2263c998"
LGN_DIR="$RUN_DIR/login"
LGN_TTL=600

LGN_USER=""; LGN_PW=""; PEERID=""; DSIGN=""; LGN_TS=0

_lgn_reset()  { rm -rf "$LGN_DIR"; }
_lgn_ensure() { mkdir -p "$LGN_DIR"; chmod 700 "$LGN_DIR"; }

# 单行化 + 截断，供 KEY=VALUE 输出（LuCI 逐行解析）
_oneline() { printf '%s' "${1:-}" | tr -d '\r\n' | cut -c1-300; }

_out_err() {
  echo "STAGE=error"
  echo "ERRORCODE=${1:-}"
  echo "MSG=$(_oneline "${2:-未知错误}")"
  return 1
}

_md5() { md5sum 2>/dev/null | awk '{print $1}'; }

# peerID = <12 位大写 MAC>004V；取默认出口网卡的 MAC
_gen_peerid() {
  local iface mac
  iface=$(ip route get 223.5.5.5 2>/dev/null | sed -n 's/.*dev \([^ ]*\).*/\1/p' | head -1)
  [ -z "$iface" ] && iface=$(_cfg_def iface "")
  [ -z "$iface" ] && iface=eth0
  mac=$(cat "/sys/class/net/${iface}/address" 2>/dev/null | tr -d ':\n' | tr 'a-f' 'A-F')
  case "$mac" in
    [0-9A-F][0-9A-F][0-9A-F][0-9A-F]*) : ;;
    *) mac="001122334455" ;;
  esac
  printf '%s004V' "$mac"
}

# devicesign = div101.<did><md5(sha1(did + pkg + businessType + salt))>
#   did = md5("msfdc" + 密码 + "23333")
_gen_dsign() {
  local did sha
  did=$(printf 'msfdc%s23333' "$1" | _md5)
  sha=$(printf '%s' "${did}${PKG_NAME_APP}${BUSINESS_TYPE}${DEV_SIGN_SALT}" \
        | openssl dgst -sha1 2>/dev/null | awk '{print $NF}')
  printf 'div101.%s%s' "$did" "$(printf '%s' "$sha" | _md5)"
}

# JSON 字符串转义（密码可能含 " 或 \）
_jes() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# 从响应头收集 Set-Cookie，追加到 cookie 罐
# 注意：wget -S 输出的每个头前面带两个空格，必须允许前导空白
_cookie_add() {
  local hdr="$1"
  [ -s "$hdr" ] || return 0
  sed -n 's/^[[:space:]]*[Ss]et-[Cc]ookie:[[:space:]]*\([^=;[:space:]]\{1,\}\)=[[:space:]]*\([^;]*\).*/\1=\2/p' "$hdr" \
    | tr -d '\r' | sed 's/[[:space:]]*$//' >> "$LGN_DIR/cookies"
}

# 拼 Cookie 请求头：同名取最后一次出现的值
_cookie_hdr() {
  [ -s "$LGN_DIR/cookies" ] || return 1
  awk -F'=' '{ if ($1 in idx) arr[idx[$1]] = $0; else { idx[$1] = ++n; arr[n] = $0 } }
             END { for (i = 1; i <= n; i++) { if (i > 1) printf "; "; printf "%s", arr[i] } }' \
    "$LGN_DIR/cookies"
}

# 把「完整 HTTP 响应」拆成头文件 + 体文件（头是纯 ASCII，正文可能是二进制图片）
_split_http() {
  local raw="$1" hdr="$2" body="$3" hlen
  [ -s "$raw" ] || return 1
  hlen=$(head -c 8192 "$raw" | LC_ALL=C tr -d '\r' | LC_ALL=C tr -d '\000' \
         | awk 'BEGIN{n=0}{ n += length($0) + 2; if ($0 == "") { print n; exit } }')
  case "$hlen" in ''|*[!0-9]*) return 1 ;; esac
  [ "$hlen" -gt 0 ] || return 1
  head -c "$hlen" "$raw" > "$hdr"
  tail -c "+$((hlen + 1))" "$raw" > "$body"
  return 0
}

# 取验证码图：写 $LGN_DIR/captcha.jpg，VERIFY_KEY 落 $LGN_DIR/vkey
# 需要能读到响应头（Set-Cookie: VERIFY_KEY=...）——curl / wget / nc 均可，uclient-fetch 不行。
# 逐个客户端尝试，任何一个拿到 VERIFY_KEY 就停（不同固件的 busybox wget 参数支持不一）。
_fetch_captcha() {
  local out="$LGN_DIR/captcha.jpg" hdr="$LGN_DIR/img.hdr" raw="$LGN_DIR/img.raw" ck sz c vk=""
  ck=$(_cookie_hdr || true)
  : > "$LGN_DIR/cookies" 2>/dev/null

  for c in curl wget nc; do
    command -v "$c" >/dev/null 2>&1 || continue
    [ "$c" = "curl" ] && [ "$_curl_works" != "1" ] && continue
    rm -f "$out" "$hdr" "$raw"

    case "$c" in
      curl)
        if [ -n "$ck" ]; then
          curl -s -m 20 -A "$UA" -H "Cookie: $ck" -D "$hdr" -o "$out" "$IMG_URL" 2>/dev/null
        else
          curl -s -m 20 -A "$UA" -D "$hdr" -o "$out" "$IMG_URL" 2>/dev/null
        fi
        ;;
      wget)
        if [ -n "$ck" ]; then
          wget -S -O "$out" --header "Cookie: $ck" "$IMG_URL" 2>"$hdr"
        else
          wget -S -O "$out" "$IMG_URL" 2>"$hdr"
        fi
        ;;
      nc)
        if [ -n "$ck" ]; then
          printf 'GET %s HTTP/1.0\r\nHost: %s\r\nUser-Agent: %s\r\nCookie: %s\r\nConnection: close\r\n\r\n' \
            "$IMG_PATH" "$IMG_HOST" "$UA" "$ck" | nc "$IMG_HOST" 80 > "$raw" 2>/dev/null
        else
          printf 'GET %s HTTP/1.0\r\nHost: %s\r\nUser-Agent: %s\r\nConnection: close\r\n\r\n' \
            "$IMG_PATH" "$IMG_HOST" "$UA" | nc "$IMG_HOST" 80 > "$raw" 2>/dev/null
        fi
        _split_http "$raw" "$hdr" "$out" || true
        ;;
    esac

    _cookie_add "$hdr"
    vk=$(sed -n 's/^VERIFY_KEY=//p' "$LGN_DIR/cookies" 2>/dev/null | tail -1)
    [ -n "$vk" ] && [ -s "$out" ] && break
    _warn "用 ${c} 取验证码未拿到 VERIFY_KEY，换下一个客户端"
  done

  if [ -z "$vk" ]; then
    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1 \
       && ! command -v nc >/dev/null 2>&1; then
      _warn "缺少可读取响应头的 HTTP 客户端"
    fi
    _warn "取不到 VERIFY_KEY：请安装 wget（opkg install wget）或 curl；uclient-fetch 不返回响应头"
    return 1
  fi

  [ -s "$out" ] || { _warn "验证码图片为空（下载失败）"; return 1; }
  sz=$(wc -c < "$out" | tr -d ' ')
  if [ "${sz:-0}" -lt 500 ]; then
    # 有些客户端会把整个响应（含头）写进目标文件，兜底再拆一次
    _split_http "$out" "$hdr" "$out.body" && [ -s "$out.body" ] && mv "$out.body" "$out"
    sz=$(wc -c < "$out" | tr -d ' ')
  fi
  [ "${sz:-0}" -ge 500 ] || { _warn "验证码图片异常（${sz:-0} 字节）"; return 1; }

  printf '%s' "$vk" > "$LGN_DIR/vkey"
  chmod 600 "$LGN_DIR/vkey" 2>/dev/null
  printf '%s' "$sz" > "$LGN_DIR/captcha.size"
  return 0
}

# 输出验证码阶段的 KEY=VALUE（图片用 base64，前端直接塞 data URI）
_emit_captcha() {
  local ec="${1:-6}"
  echo "STAGE=captcha"
  echo "ERRORCODE=$ec"
  echo "PEERID=$PEERID"
  echo "IMAGE_BYTES=$(cat "$LGN_DIR/captcha.size" 2>/dev/null || echo 0)"
  echo "IMAGE_B64=$(openssl base64 -A -in "$LGN_DIR/captcha.jpg" 2>/dev/null | tr -d '\r\n')"
  echo "MSG=请输入图片中的 4 个字符"
}

# 提交登录：$1=verifyKey $2=verifyCode，响应体打到 stdout
_post_login() {
  local vkey="$1" vcode="$2" body raw hdr host path blen ck
  ck=$(_cookie_hdr || true)
  body=$(printf '{"protocolVersion":"%s","sequenceNo":"1000001","platformVersion":"2","sdkVersion":"%s","peerID":"%s","businessType":"68","clientVersion":"%s","devicesign":"%s","isCompressed":"0","userName":"%s","passWord":"%s","sessionID":"","verifyKey":"%s","verifyCode":"%s","appName":"ANDROID-%s","deviceModel":"%s","deviceName":"%s","OSVersion":"%s"}' \
    "$PROTOCOL_VER" "$SDK_VERSION" "$PEERID" "$APP_VER" "$DSIGN" \
    "$(_jes "$LGN_USER")" "$(_jes "$LGN_PW")" "$vkey" "$vcode" \
    "$PKG_NAME_APP" "$DEV_MODEL" "$DEV_NAME" "$OS_VERSION")
  raw="$LGN_DIR/post.raw"; hdr="$LGN_DIR/post.hdr"
  rm -f "$raw" "$hdr"

  if [ "$_curl_works" = "1" ]; then
    if [ -n "$ck" ]; then
      curl -s -m 25 -A "$UA" -H "Content-Type: application/json" -H "Cookie: $ck" \
        -D "$hdr" -o "$raw" --data "$body" "$LOGIN_URL"
    else
      curl -s -m 25 -A "$UA" -H "Content-Type: application/json" \
        -D "$hdr" -o "$raw" --data "$body" "$LOGIN_URL"
    fi
  else
    host="${LOGIN_URL#https://}"; host="${host%%/*}"
    path="/${LOGIN_URL#https://*/}"
    blen=$(printf '%s' "$body" | wc -c | tr -d ' ')
    if [ -n "$ck" ]; then
      printf 'POST %s HTTP/1.0\r\nHost: %s\r\nContent-Type: application/json\r\nContent-Length: %s\r\nUser-Agent: %s\r\nCookie: %s\r\nConnection: close\r\n\r\n%s' \
        "$path" "$host" "$blen" "$UA" "$ck" "$body" \
        | openssl s_client -connect "${host}:443" -quiet 2>/dev/null > "$raw"
    else
      printf 'POST %s HTTP/1.0\r\nHost: %s\r\nContent-Type: application/json\r\nContent-Length: %s\r\nUser-Agent: %s\r\nConnection: close\r\n\r\n%s' \
        "$path" "$host" "$blen" "$UA" "$body" \
        | openssl s_client -connect "${host}:443" -quiet 2>/dev/null > "$raw"
    fi
    _split_http "$raw" "$hdr" "$raw.body" || { _warn "登录响应解析失败"; return 1; }
    mv "$raw.body" "$raw"
  fi

  _cookie_add "$hdr"
  cat "$raw"
}

# 读取登录会话（含密码，只在 tmpfs），过期自动清
_lgn_load() {
  [ -f "$LGN_DIR/session" ] || return 1
  . "$LGN_DIR/session" 2>/dev/null || return 1
  [ -f "$LGN_DIR/pw" ] || return 1
  LGN_PW=$(cat "$LGN_DIR/pw" 2>/dev/null)
  [ -n "${LGN_USER:-}" ] && [ -n "$LGN_PW" ] || return 1
  local now; now=$(date +%s)
  if [ $((now - ${LGN_TS:-0})) -ge "$LGN_TTL" ]; then
    _lgn_reset
    return 1
  fi
  return 0
}

_lgn_save() {
  _lgn_ensure
  {
    echo "LGN_USER='$(printf '%s' "$LGN_USER" | tr -d "'")'"
    echo "PEERID='$PEERID'"
    echo "DSIGN='$DSIGN'"
    echo "LGN_TS=$(date +%s)"
  } > "$LGN_DIR/session"
  chmod 600 "$LGN_DIR/session"
  printf '%s' "$LGN_PW" > "$LGN_DIR/pw"
  chmod 600 "$LGN_DIR/pw"
}

_login_ok() {
  local r="$1" uid lkey sid
  uid=$(_jget userID "$r")
  lkey=$(_jget loginKey "$r")
  sid=$(_jget sessionID "$r"); [ -z "$sid" ] && sid=$(_jget sessionId "$r")
  [ -z "$uid" ] && { _out_err "" "登录成功但响应缺少 userID（接口可能变动）"; return 1; }
  KP_USERID="$uid"; KP_LOGINKEY="$lkey"; KP_SESSION="$sid"
  KP_PEERID="$PEERID"; KP_DEVICESIGN="$DSIGN"
  _save_cred
  _lgn_reset
  _query_bandwidth >/dev/null 2>&1 || true
  echo "STAGE=ok"
  echo "USERID=$uid"
  echo "HAS_LOGINKEY=$([ -n "$lkey" ] && echo 1 || echo 0)"
  echo "HAS_SESSION=$([ -n "$sid" ] && echo 1 || echo 0)"
  echo "MSG=$(_oneline "登录成功 userID=$uid")"
  return 0
}

# 登录报错的可读诊断
_lgn_fail() {
  local ec="$1" r="$2" hint=""
  case "$ec" in
    "")   hint="空响应：网络/证书问题，或登录端点已变更" ;;
    3)    hint="账号或密码错误（3）" ;;
    13)   hint="身份校验失败（13）：peerID / devicesign / 密码 三者之一不对" ;;
    724)  hint="账号已被风控（724）：请停止尝试，等待 2 小时以上，或先用手机迅雷 APP 正常登录一次" ;;
    6)    hint="验证码未通过（6）" ;;
    *)    hint="登录失败 errorCode=$ec" ;;
  esac
  _lgn_reset
  _out_err "$ec" "$hint"
}

# 阶段1：提交一次登录（预期 6）→ 取验证码图
do_login_prepare() {
  local user="${1:-}" pwfile="$RUN_DIR/login.pw" pw r ec
  _load_cred
  [ -n "$user" ] || { _out_err "" "缺少账号"; return 1; }
  [ -f "$pwfile" ] || { _out_err "" "缺少密码（请从页面重新提交）"; return 1; }
  pw=$(head -c 512 "$pwfile" 2>/dev/null | tr -d '\r\n')
  rm -f "$pwfile"
  [ -n "$pw" ] || { _out_err "" "密码为空"; return 1; }

  _lgn_reset; _lgn_ensure
  LGN_USER="$user"; LGN_PW="$pw"
  PEERID="${KP_PEERID:-$(_gen_peerid)}"
  DSIGN=$(_gen_dsign "$pw")
  case "$DSIGN" in
    div101.*) : ;;
    *) _out_err "" "devicesign 计算失败（openssl 不可用？）"; return 1 ;;
  esac
  _lgn_save

  r=$(_post_login "" "")
  ec=$(_jget errorCode "$r")
  if [ "$ec" = "0" ]; then _login_ok "$r"; return $?; fi
  if [ "$ec" != "6" ]; then _lgn_fail "$ec" "$r"; return 1; fi

  _fetch_captcha || { _lgn_reset; _out_err "6" "取验证码失败（详见系统日志）"; return 1; }
  _emit_captcha 6
  return 0
}

# 阶段2：提交验证码
do_login_submit() {
  local code="${1:-}" vkey r ec
  [ -n "$code" ] || { _out_err "" "缺少验证码"; return 1; }
  code=$(printf '%s' "$code" | tr -d ' \r\n')
  _lgn_load || { _out_err "" "登录会话不存在或已过期（10 分钟），请重新获取验证码"; return 1; }
  vkey=$(cat "$LGN_DIR/vkey" 2>/dev/null)
  [ -n "$vkey" ] || { _lgn_reset; _out_err "" "缺少 verifyKey，请重新获取验证码"; return 1; }

  r=$(_post_login "$vkey" "$code")
  ec=$(_jget errorCode "$r")
  if [ "$ec" = "0" ]; then _login_ok "$r"; return $?; fi
  if [ "$ec" = "6" ]; then
    # 码错/过期：自动换一张，让页面接着输
    if _fetch_captcha; then
      _emit_captcha 6
      return 0
    fi
    _lgn_reset
    _out_err "6" "验证码未通过，且换图失败，请重新获取"
    return 1
  fi
  _lgn_fail "$ec" "$r"
  return 1
}

# 换一张验证码（不改会话）
do_login_refresh() {
  _lgn_load || { _out_err "" "登录会话不存在或已过期，请重新获取验证码"; return 1; }
  _fetch_captcha || { _out_err "6" "换图失败（详见系统日志）"; return 1; }
  _emit_captcha 6
  return 0
}

do_login_cancel() {
  _lgn_reset
  echo "STAGE=cancelled"
  echo "MSG=已清除临时登录会话"
  return 0
}

# ------------------------------- 子命令 --------------------------------------
do_status() {
  _load_cred
  [ -z "$KP_USERID" ] && { _warn "未导入凭证"; _state_write "no_cred" "未导入凭证"; return 1; }
  [ -z "$KP_PEERID" ] && { _warn "凭证缺少 peerID"; _state_write "no_cred" "缺少 peerID"; return 1; }
  if ! _query_bandwidth; then
    _state_write "no_upgrade" "${MSG}"
    _log "线路不可提速：${MSG}"
    return 1
  fi
  _state_write "ok" ""
  _log "线路：${PROVINCE}/${SP}  dial_account=${KP_DIAL}"
  _log "下行：当前 $(awk -v v="$CUR_DOWN" 'BEGIN{printf "%.0f", v/1024}') Mbps → 上限 $(awk -v v="$MAX_DOWN" 'BEGIN{printf "%.0f", v/1024}') Mbps"
  _log "上行：当前 $(awk -v v="$UP_CUR" 'BEGIN{printf "%.0f", v/1024}') Mbps（提速支持=${UP_SUPPORTED}）"
  return 0
}

do_up() {
  _load_cred
  _inherit_state
  [ -z "$KP_USERID" ] && _die "未导入凭证"
  [ -z "$KP_SESSION" ] && { _warn "无 sessionID，先尝试续期"; _renew_session || return 1; }
  _query_bandwidth >/dev/null 2>&1
  # 距上次点击不足服务端限流窗口（约 120s）时，点了也只能换来 711，稍等再点
  local now; now=$(date +%s)
  if [ $((now - ${LAST_UP:-0})) -lt "$CLICK_GAP_SEC" ]; then
    _log "距上次点击不足 ${CLICK_GAP_SEC} 秒（服务端限流窗口），稍后再试"
    _state_write "running" "点击太频繁，稍后再试"
    return 0
  fi
  if ! _do_upgrade; then
    case "$ERRNO" in
      715|717|718)
        _log "sessionID 失效（errno=${ERRNO}），自动续期后重试"
        _renew_session && _do_upgrade || { _state_write "up_fail" "${MSG}"; return 1; }
        ;;
      711)
        # 请求太频繁：服务端限流并承诺"稍后自动重新提速"，不是故障
        _log "被限流（errno=711 请求太频繁），稍后快鸟会自动重新提速"
        ERRNO=""
        _state_write "running" "限流中，稍后自动恢复"
        return 0
        ;;
      *) _state_write "up_fail" "${MSG}"; return 1 ;;
    esac
  fi
  _state_write "up" ""
  # errno=812 的 message 是 "speedup server already speed up"——服务器记录该线路
  # 已在提速中，属于成功，只是不必重复下发。别让它看起来像报错。
  if [ "$ERRNO" = "812" ]; then
    _log "服务器已在提速状态（errno=812），无需重复下发"
  else
    _log "提速已下发（errno=${ERRNO}）"
  fi
  return 0
}

do_down() {
  _load_cred
  [ -z "$KP_USERID" ] && { _warn "未导入凭证"; return 1; }
  [ -n "$KP_SESSION" ] && [ -n "$KP_PORTAL_IP" ] && _do_recover
  _state_write "down" "已恢复带宽"
  _log "已下发 recover（恢复带宽）"
  return 0
}

do_renew() {
  _load_cred
  _renew_session
}

# 一轮完整流程：探测 → 需要则提速 → 心跳
# 时序规则（2026-10-23 据路由器日志 + 参考实现 swjsq.py 修正，详见 README）：
#   1. 服务端把 upgrade / keepalive 视为同一类「点击」请求，最小间隔约 120 秒
#      （711 响应里的 button_data.can_click_time）。**本轮只要点过 upgrade
#      （errno=0/812 成功、2204 失败都算——实测失败也会点亮窗口），就不再发心跳**：
#      0 秒后发必被 711 拒，保活白发；加速到期后反被 513 判掉速，陷入
#      「重提 → 711 → 掉速」死循环。心跳留给下一轮（间隔 ≥300 秒，必过窗口）。
#   2. 重新点击的条件：BOOST_OK 未确认 / 心跳判掉速（513、824，由心跳分支清标记）/
#      距上次成功提速超过 RECONFIRM_SEC 兜底；且距上次点击已过 CLICK_GAP_SEC。
#   3. 711 限流返回 2：不算失败，守护进程等过点击窗口（约 130 秒）重试。
do_run_once() {
  _load_cred
  _inherit_state
  [ -z "$KP_USERID" ] && { _warn "未导入凭证"; _state_write "no_cred" "未导入凭证"; return 1; }
  [ -z "$KP_SESSION" ] && _renew_session >/dev/null 2>&1
  if ! _query_bandwidth; then
    _state_write "no_upgrade" "${MSG}"
    return 1
  fi
  local now; now=$(date +%s)
  local attempted=0 up_failed=0 up_msg=""
  if [ "${CUR_DOWN:-0}" -lt "${MAX_DOWN:-0}" ]; then
    # 带宽接口恒返回签约带宽（当前 < 上限），是否重新点击不看它，看状态标记
    local need=0
    [ "${BOOST_OK:-0}" != "1" ] && need=1
    [ $((now - ${LAST_UP:-0})) -ge "$RECONFIRM_SEC" ] && need=1
    if [ "$need" = "1" ] && [ $((now - ${LAST_UP:-0})) -lt "$CLICK_GAP_SEC" ]; then
      _log "距上次点击不足 ${CLICK_GAP_SEC} 秒（服务端限流窗口），本轮只保活不点击"
      need=0
    fi
    if [ "$need" = "1" ]; then
      attempted=1
      local up_ok=0
      if ! _do_upgrade; then
        case "$ERRNO" in
          715|717|718)
            _log "sessionID 失效（errno=${ERRNO}），自动续期后重试"
            if _renew_session && _do_upgrade; then up_ok=1; fi
            ;;
          711)
            # 限流：不算失败，服务端承诺"稍后快鸟将自动为您重新提速"。
            # 返回 2 让守护进程等过点击窗口（约 130 秒）就重试，别干等一个
            # 完整轮询间隔——重启时 prerm 的 recover 刚点亮窗口，首轮必被 711。
            _log "被限流（errno=711 请求太频繁），稍后快鸟会自动重新提速"
            ERRNO=""
            _state_write "running" "限流中，稍后自动恢复"
            return 2
            ;;
        esac
        if [ "$up_ok" != "1" ]; then
          # 2204 等瞬时错误：清确认标记下轮重试；本轮不再发心跳（刚点过）
          BOOST_OK=0
          up_failed=1; up_msg="${MSG}"
          _warn "提速失败：errno=${ERRNO} ${MSG}（下轮重试）"
        fi
      else
        up_ok=1
      fi
      if [ "$up_ok" = "1" ]; then
        # errno=0/812 都说明服务端已确认提速状态
        BOOST_OK=1
        LAST_UP="$now"
        CUR_DOWN="$MAX_DOWN"
        # errno=812 = "speedup server already speed up"，服务器记录已在提速中，算成功
        if [ "$ERRNO" = "812" ]; then
          _log "服务器已在提速状态（errno=812），当前 $(awk -v v="$CUR_DOWN" 'BEGIN{printf "%.0f", v/1024}') Mbps → 上限 $(awk -v v="$MAX_DOWN" 'BEGIN{printf "%.0f", v/1024}') Mbps"
        else
          _log "已提速（errno=${ERRNO}），当前 $(awk -v v="$CUR_DOWN" 'BEGIN{printf "%.0f", v/1024}') Mbps → 上限 $(awk -v v="$MAX_DOWN" 'BEGIN{printf "%.0f", v/1024}') Mbps"
        fi
      fi
    fi
  fi
  # 本轮点过 upgrade（成败不论）就不再发心跳：服务端点击窗口约 120 秒，
  # 0 秒后发必被 711，发了也白发；下一轮的心跳才有效。
  if [ "$attempted" = "1" ]; then
    if [ "$up_failed" = "1" ]; then
      _state_write "up_fail" "${up_msg}"
      return 1
    fi
    _state_write "running" ""
    return 0
  fi
  if [ $((now - ${LAST_UP:-0})) -lt "$CLICK_GAP_SEC" ]; then
    # 刚（可能由别的进程）提过速：心跳同样等下一轮，不做无谓点击
    _log "距上次点击不足 ${CLICK_GAP_SEC} 秒（服务端限流窗口），本轮跳过心跳"
    _state_write "running" "点击窗口内，跳过本轮心跳"
    return 0
  fi
  if ! _do_keepalive; then
    # 711 = "client request too frequent"，服务端限流，明确说"稍后快鸟将自动为您重新提速"，
    # 属于正常节奏而非故障，不能计入 daemon 的失败计数。
    if [ "$ERRNO" = "711" ]; then
      _log "心跳被限流（errno=711 请求太频繁），稍后快鸟会自动重新提速"
      ERRNO=""
      _state_write "running" "限流中，稍后自动恢复"
      return 0
    fi
    _warn "心跳失败 errno=${ERRNO}（掉速或会话失效，下一轮会重试）"
    # 心跳被拒（非限流）说明提速状态可能已丢，清掉确认标记让下一轮重新下发
    BOOST_OK=0
    case "$ERRNO" in
      513|824)
        # speedup closed：服务端已关闭提速，下一轮重新下发
        _log "服务端已关闭提速（errno=${ERRNO}），下一轮重新提速"
        ;;
      715|717|718)
        _renew_session >/dev/null 2>&1
        ;;
    esac
    _state_write "keepalive_fail" "errno=${ERRNO}"
    return 1
  fi
  _state_write "running" ""
  return 0
}

do_daemon() {
  _log "守护启动 pid=$$"
  local interval failures limited
  failures=0; limited=0
  while :; do
    if ! _enabled; then
      _state_write "disabled" "已关闭"
      sleep 30
      continue
    fi
    interval=$(_interval)
    do_run_once >/dev/null 2>&1
    case "$?" in
      0)
        # 正常（含 711 心跳限流——服务端会自行重提）
        failures=0; limited=0
        sleep "$interval"
        ;;
      2)
        # errno=711 点击限流：等过服务端点击窗口尽快重试（对齐参考实现的
        # “睡 60 秒原状态重试”）；连续多次仍被限流则退回普通重试节奏
        limited=$((limited+1))
        if [ "$limited" -ge 3 ]; then
          _log "连续 ${limited} 次被限流，退回 ${RETRY_SEC} 秒重试"
          limited=0
          sleep "$RETRY_SEC"
        else
          _log "本轮被限流（errno=711），${CLICK_GAP_SEC} 秒后重试"
          sleep "$CLICK_GAP_SEC"
        fi
        ;;
      *)
        # 失败（掉速 513 / 瞬时错误 2204 / 网络问题）尽快重试，
        # 不让掉速状态干等一个完整轮询间隔
        failures=$((failures+1))
        _log "本轮失败（连续 ${failures} 次），${RETRY_SEC} 秒后重试"
        sleep "$RETRY_SEC"
        ;;
    esac
  done
}

# ------------------------------- 入口 ----------------------------------------
cmd="${1:-status}"
case "$cmd" in
  status|up|down|renew|run-once|daemon|state) "do_$(echo "$cmd" | tr '-' '_')" ;;
  login-prepare)  do_login_prepare "${2:-}" ;;
  login-submit)   do_login_submit "${2:-}" ;;
  login-refresh)  do_login_refresh ;;
  login-cancel)   do_login_cancel ;;
  *)
    echo "用法: $0 {status|up|down|renew|run-once|daemon|state}"
    echo "      $0 login-prepare <账号>   # 密码从 /var/run/neokuainiao/login.pw 读（页面写入）"
    echo "      $0 login-submit <验证码>"
    echo "      $0 login-refresh | login-cancel"
    exit 1 ;;
esac
