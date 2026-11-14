#!/usr/bin/env bash
set -euo pipefail
set +m

# Locate the repository even when invoked through a symlink in PATH.
SCRIPT_PATH=$(readlink -f -- "${BASH_SOURCE[0]}")
ROOT=$(dirname -- "$SCRIPT_PATH")
STATE_DIR="$ROOT/target"
PID_FILE="$STATE_DIR/iwan-http.pid"
STAMP_FILE="$STATE_DIR/iwan-http.starttime"
SERVER_FILE="$STATE_DIR/iwan-http.server"
LISTEN_FILE="$STATE_DIR/iwan-http.listen"
LOG_FILE="$STATE_DIR/iwan-http.log"
DNS_FILE="$STATE_DIR/iwan-http.dns"
BIND_FILE="$STATE_DIR/iwan-http.bind"
CONFIG_FILE="$STATE_DIR/iwan-http.config-dir"
WATCH_PID_FILE="$STATE_DIR/iwan-http.watch.pid"
WATCH_STAMP_FILE="$STATE_DIR/iwan-http.watch.starttime"
WATCH_LOG_FILE="$STATE_DIR/iwan-http.watch.log"
PID= ACTIVE_SERVER= ACTIVE_LISTEN= START_TIME=
WATCH_PID= WATCH_STAMP= WATCH_TARGET= PROBE_PID= PROBE_FILE=
ACTIVE_DNS= ACTIVE_BIND= ACTIVE_CONFIG_DIR=
SERVER_ROWS=

die() { printf '错误：%s\n' "$*" >&2; exit 1; }

usage() {
    printf '用法：%s <命令> [参数]\n\n' "${0##*/}"
    cat <<'EOF'
  auth               通过 OIDC 登录并保存线路配置（前台交互）
  start [线路]       后台启动代理和巡检；默认使用上次成功的线路
  stop               关闭代理和巡检；重复执行无害
  restart [线路]     重启代理和巡检，可同时指定新线路
  status             查看 PID、线路、监听地址和日志位置；未运行时退出码为 3
  list               列出已认证的线路
  switch <线路>      按编号或名称关键词切换，失败时尝试恢复原线路
  test [all|线路]    测试协议 PING 可达性和延迟，默认测试全部线路
  check [URL]        通过当前代理访问网页，默认检查 HTTP 和 HTTPS
  ensure [URL]       检查转发；失败时重连当前线路一次，并再次验证
  watch [URL]        前台持续检查，连续失败后自动重连；Ctrl+C 结束巡检
  logs [-f]          查看最近 40 行日志，-f 持续跟踪

环境变量：
  IWAN_BIN           指定 iwan-client-oidc 路径；默认优先 release，再 debug
  IWAN_CONFIG_DIR    认证配置目录，默认 ~/.config/iwan
  IWAN_HTTP_LISTEN   启动时的监听地址，默认沿用上次地址或 127.0.0.1:8080
  IWAN_DNS           可选的 --dns 参数
  IWAN_BIND          可选的 --bind 参数（也用于线路 PING）
  IWAN_CHECK_TIMEOUT 检查的总超时秒数，默认 40
  IWAN_WATCH_INTERVAL 巡检间隔秒数，默认 60
  IWAN_WATCH_FAILURES 连续失败多少次后重连，默认 3
  IWAN_WATCH_COOLDOWN 两次自动重连至少间隔多少秒，默认 300
  IWAN_WATCH_URL     自动巡检目标，默认 https://example.com/
  IWAN_AUTO_WATCH    启动代理时自动启动巡检，默认 1；设为 0 关闭

依赖 Linux、Bash 4.4+、nohup、setsid、flock；自动巡检及转发检查需要 curl。
运行文件保存在仓库 target/ 下。退出终端后继续运行，机器重启后需手动启动。
EOF
}

find_binary() {
    local candidate
    for candidate in "$ROOT/target/release/$1" "$ROOT/target/debug/$1" "$ROOT/$1"; do
        if [[ -x "$candidate" ]]; then printf '%s\n' "$candidate"; return; fi
    done
    printf '%s\n' "$ROOT/target/debug/$1"
}

BIN=$(find_binary iwan-client-oidc)
if [[ -n ${IWAN_BIN:-} ]]; then BIN=$(readlink -m -- "$IWAN_BIN"); fi
PING_BIN=$(find_binary iwan-client)

read_value() {
    local value=
    if [[ -f "$1" ]]; then IFS= read -r value < "$1" || true; fi
    printf '%s\n' "${value:-$2}"
}

CONFIG_DIR=${IWAN_CONFIG_DIR:-$(read_value "$CONFIG_FILE" "${HOME}/.config/iwan")}
CHECK_TIMEOUT=${IWAN_CHECK_TIMEOUT:-40}
WATCH_INTERVAL=${IWAN_WATCH_INTERVAL:-60}
WATCH_FAILURES=${IWAN_WATCH_FAILURES:-3}
WATCH_COOLDOWN=${IWAN_WATCH_COOLDOWN:-300}
WATCH_URL=${IWAN_WATCH_URL:-https://example.com/}
AUTO_WATCH=${IWAN_AUTO_WATCH:-1}

write_value() {
    printf '%s\n' "$2" > "$1.tmp.$$"
    mv -- "$1.tmp.$$" "$1"
}

process_stamp() {
    local stat rest
    local -a fields
    [[ -r /proc/$1/stat ]] || return 1
    # The process may exit between the check and open; redirect stderr first.
    IFS= read -r stat 2>/dev/null < "/proc/$1/stat" || return 1
    rest=${stat##*) }
    read -r -a fields <<< "$rest"
    [[ ${fields[0]:-Z} != Z && ${fields[19]:-} =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "${fields[19]}"
}

get_running() {
    local stamp executable cwd arg has_http=0 has_connect=0 i
    local -a args
    PID=$(read_value "$PID_FILE" '')
    [[ "$PID" =~ ^[1-9][0-9]*$ && ${#PID} -le 10 ]] || return 1
    (( PID > 1 )) || return 1
    stamp=$(process_stamp "$PID") || return 1
    if [[ -f "$STAMP_FILE" ]]; then
        [[ "$stamp" == "$(read_value "$STAMP_FILE" '')" ]] || return 1
    fi
    mapfile -d '' -t args 2>/dev/null < "/proc/$PID/cmdline" || return 1
    [[ ${#args[@]} -gt 0 ]] || return 1
    executable=${args[0]}
    if [[ "$executable" != /* ]]; then
        cwd=$(readlink -- "/proc/$PID/cwd") || return 1
        executable=$(readlink -m -- "$cwd/$executable")
    fi
    # Accept the previous nohup process, but never signal an unrelated PID.
    case "$executable" in
        "$BIN"|"$ROOT/target/debug/iwan-client-oidc"|"$ROOT/target/release/iwan-client-oidc"|"$ROOT/iwan-client-oidc") ;;
        *) return 1 ;;
    esac
    ACTIVE_SERVER=1 ACTIVE_LISTEN=127.0.0.1:8080
    ACTIVE_DNS= ACTIVE_BIND= ACTIVE_CONFIG_DIR=$CONFIG_DIR
    for ((i=1; i<${#args[@]}; i++)); do
        arg=${args[i]}
        case "$arg" in
            --http) has_http=1 ;;
            --connect) has_connect=1 ;;
            --server) ACTIVE_SERVER=${args[i+1]:-} ;;
            --http-listen) ACTIVE_LISTEN=${args[i+1]:-} ;;
            --dns) ACTIVE_DNS=${args[i+1]:-} ;;
            --bind) ACTIVE_BIND=${args[i+1]:-} ;;
            --config-dir) ACTIVE_CONFIG_DIR=${args[i+1]:-} ;;
        esac
    done
    (( has_http && has_connect )) || return 1
    START_TIME=$stamp
}

get_watcher() {
    local stamp i script cwd
    local -a args
    WATCH_PID=$(read_value "$WATCH_PID_FILE" '')
    WATCH_STAMP=$(read_value "$WATCH_STAMP_FILE" '')
    [[ "$WATCH_PID" =~ ^[1-9][0-9]{0,9}$ && "$WATCH_STAMP" =~ ^[0-9]+$ ]] || return 1
    (( WATCH_PID > 1 )) || return 1
    stamp=$(process_stamp "$WATCH_PID") || return 1
    [[ "$stamp" == "$WATCH_STAMP" ]] || return 1
    mapfile -d '' -t args 2>/dev/null < "/proc/$WATCH_PID/cmdline" || return 1
    cwd=$(readlink -- "/proc/$WATCH_PID/cwd") || return 1
    for ((i=0; i+1<${#args[@]}; i++)); do
        [[ "${args[i+1]}" == watch ]] || continue
        script=${args[i]}
        if [[ "$script" != /* ]]; then script="$cwd/$script"; fi
        [[ $(readlink -f -- "$script") == "$SCRIPT_PATH" ]] || continue
        WATCH_TARGET=${args[i+2]:-$WATCH_URL}
        return 0
    done
    return 1
}

stop_watcher() {
    local original_pid original_stamp i
    if ! get_watcher; then return 0; fi
    original_pid=$WATCH_PID original_stamp=$WATCH_STAMP
    kill -TERM -- "$original_pid" || return 1
    for ((i=0; i<50; i++)); do
        if [[ $(process_stamp "$original_pid" || true) != "$original_stamp" ]]; then
            printf '已关闭巡检：PID=%s\n' "$original_pid"
            return 0
        fi
        sleep 0.1
    done
    printf '错误：巡检尚未退出，请稍后重试。\n' >&2
    return 1
}

validate_auto_watch() {
    [[ "$AUTO_WATCH" == 0 || "$AUTO_WATCH" == 1 ]] || die 'IWAN_AUTO_WATCH 须为 0 或 1。'
    if [[ "$AUTO_WATCH" == 1 ]]; then validate_checks "$WATCH_URL"; fi
}

start_watcher() {
    local child i
    if [[ "$AUTO_WATCH" == 0 ]]; then return 0; fi
    if get_watcher; then
        printf '巡检运行中：PID=%s，目标=%s\n' "$WATCH_PID" "$WATCH_TARGET"
        return 0
    fi
    if [[ -f "$WATCH_LOG_FILE" ]]; then mv -f -- "$WATCH_LOG_FILE" "$WATCH_LOG_FILE.previous"; fi
    nohup setsid bash "$SCRIPT_PATH" watch "$WATCH_URL" \
        < /dev/null > "$WATCH_LOG_FILE" 2>&1 8>&- 9>&- &
    child=$!
    for ((i=0; i<50; i++)); do
        if get_watcher && [[ "$WATCH_PID" == "$child" ]]; then
            printf '已后台启动巡检：PID=%s，目标=%s\n日志：%s\n' "$WATCH_PID" "$WATCH_TARGET" "$WATCH_LOG_FILE"
            return 0
        fi
        if ! kill -0 "$child" 2>/dev/null; then break; fi
        sleep 0.1
    done
    printf '错误：自动巡检启动失败，代理可能仍在运行，请查看 %s。\n' "$WATCH_LOG_FILE" >&2
    return 1
}

lock_manager() {
    mkdir -p -- "$STATE_DIR"
    exec 9> "$STATE_DIR/iwan-http.lock"
    flock -n 9 || die '另一个管理命令正在执行，请稍后重试。'
}

load_servers() {
    [[ -x "$BIN" ]] || die '未找到客户端，请先运行 cargo build --locked --bins。'
    local listing
    listing=$("$BIN" --config-dir "$CONFIG_DIR" --list) || return 1
    SERVER_ROWS=$(awk '
        /^[[:space:]]*[0-9]+\./ {
            index_number=$1; sub(/\.$/, "", index_number)
            name=$2; for (i=3; i<NF; i++) name=name " " $i
            host=$NF; sub(/:[^:]*$/, "", host)
            port=$NF; sub(/^.*:/, "", port)
            printf "%s\t%s\t%s\t%s\n", index_number, name, host, port
        }' <<< "$listing")
    [[ -n "$SERVER_ROWS" ]] || die '配置中没有线路，请先运行 auth。'
}

resolve_server() {
    local index_number name host port
    while IFS=$'\t' read -r index_number name host port; do
        if [[ "$1" == "$index_number" ]] || { [[ ! "$1" =~ ^[0-9]+$ && -n "$1" ]] && [[ "$name" == *"$1"* ]]; }; then
            printf '%s\n' "$index_number"
            return
        fi
    done <<< "$SERVER_ROWS"
    printf '错误：找不到线路 %s，请用 list 查看。\n' "$1" >&2
    return 1
}

show_status() {
    if get_running; then
        printf '运行中：PID=%s\n线路：%s\nHTTP 代理：http://%s\n日志：%s\n' \
            "$PID" "$ACTIVE_SERVER" "$ACTIVE_LISTEN" "$LOG_FILE"
        printf '转发状态：未检查，请用 check 或 ensure 验证。\n'
        if get_watcher; then
            printf '自动巡检：运行中，PID=%s，目标=%s\n巡检日志：%s\n' "$WATCH_PID" "$WATCH_TARGET" "$WATCH_LOG_FILE"
        else
            printf '自动巡检：未运行。\n'
        fi
    else
        printf '未运行（无有效的代理 PID）。\n日志：%s\n' "$LOG_FILE"
        return 3
    fi
}

clear_pid() { rm -f -- "$PID_FILE" "$STAMP_FILE"; }

stop_proxy() {
    local original_pid i
    if ! get_running; then clear_pid; printf '代理未运行。\n'; return; fi
    original_pid=$PID
    write_value "$STAMP_FILE" "$START_TIME"
    kill -INT -- "$original_pid" || return 1
    for ((i=0; i<50; i++)); do
        if ! get_running; then clear_pid; printf '已关闭：PID=%s\n' "$original_pid"; return; fi
        sleep 0.1
    done
    # Recheck identity before escalating from graceful shutdown to SIGTERM.
    if get_running; then kill -TERM -- "$PID" || return 1; fi
    for ((i=0; i<20; i++)); do
        if ! get_running; then clear_pid; printf '已关闭：PID=%s\n' "$original_pid"; return; fi
        sleep 0.1
    done
    printf '错误：进程未退出，保留 PID 文件，请检查日志。\n' >&2
    return 1
}

start_proxy() {
    local server=$1 listen child stamp i dns bind
    local -a args
    if get_running; then show_status; return; fi
    listen=${IWAN_HTTP_LISTEN:-$(read_value "$LISTEN_FILE" 127.0.0.1:8080)}
    args=(--config-dir "$CONFIG_DIR" --connect --http --server "$server" --http-listen "$listen")
    dns=${IWAN_DNS-$(read_value "$DNS_FILE" '')}
    bind=${IWAN_BIND-$(read_value "$BIND_FILE" '')}
    if [[ -n "$dns" ]]; then args+=(--dns "$dns"); fi
    if [[ -n "$bind" ]]; then args+=(--bind "$bind"); fi
    if [[ -f "$LOG_FILE" ]]; then mv -f -- "$LOG_FILE" "$LOG_FILE.previous"; fi
    # Close the manager lock in the daemon and detach it from the terminal session.
    env -u IWAN_DEBUG nohup setsid "$BIN" "${args[@]}" < /dev/null > "$LOG_FILE" 2>&1 9>&- 8>&- &
    child=$!
    write_value "$PID_FILE" "$child"
    if stamp=$(process_stamp "$child"); then write_value "$STAMP_FILE" "$stamp"; else clear_pid; fi
    for ((i=0; i<100; i++)); do
        if ! kill -0 "$child" 2>/dev/null; then break; fi
        if get_running && grep -Fq -- "HTTP listening on $listen" "$LOG_FILE"; then
            write_value "$STAMP_FILE" "$START_TIME"
            write_value "$SERVER_FILE" "$server"
            write_value "$LISTEN_FILE" "$listen"
            write_value "$DNS_FILE" "$dns"
            write_value "$BIND_FILE" "$bind"
            write_value "$CONFIG_FILE" "$CONFIG_DIR"
            printf '已后台启动。\n'
            show_status
            return
        fi
        sleep 0.2
    done
    printf '错误：代理启动失败或等待超时，详情：%s\n' "$LOG_FILE" >&2
    tail -n 12 -- "$LOG_FILE" >&2
    if grep -Fq -- "bind HTTP listener $listen" "$LOG_FILE"; then
        printf '无法监听 %s。若日志提示 Address already in use，说明端口被占用。\n' "$listen" >&2
        printf '可用 ss -ltnp 查看占用进程，或换用空闲端口，例如：IWAN_HTTP_LISTEN=127.0.0.1:8081 %q start %q\n' "$SCRIPT_PATH" "$server" >&2
    fi
    stop_proxy || return 1
    return 1
}

change_server() {
    local request=${1:-} previous= was_running=0 selected
    local dns=${IWAN_DNS-$(read_value "$DNS_FILE" '')}
    local bind=${IWAN_BIND-$(read_value "$BIND_FILE" '')}
    local CONFIG_DIR=$CONFIG_DIR
    if get_running; then
        previous=$ACTIVE_SERVER; was_running=1
        # Import options from daemons started before option persistence existed.
        if [[ ! ${IWAN_DNS+x} ]]; then dns=$ACTIVE_DNS; fi
        if [[ ! ${IWAN_BIND+x} ]]; then bind=$ACTIVE_BIND; fi
        CONFIG_DIR=${IWAN_CONFIG_DIR:-$ACTIVE_CONFIG_DIR}
    fi
    local IWAN_DNS=$dns IWAN_BIND=$bind
    request=${request:-${previous:-$(read_value "$SERVER_FILE" 1)}}
    load_servers
    selected=$(resolve_server "$request") || return 1
    stop_proxy || return 1
    if start_proxy "$selected"; then return; fi
    if (( was_running )) && [[ "$previous" != "$selected" ]]; then
        printf '尝试恢复原线路 %s……\n' "$previous" >&2
        if ! start_proxy "$previous"; then printf '恢复失败，请检查日志并手动启动。\n' >&2; fi
    fi
    return 1
}

test_servers() {
    local request=${1:-all} selected= index_number name host port output failures=0
    local bind=${IWAN_BIND-$(read_value "$BIND_FILE" '')}
    local -a bind_args=()
    [[ -x "$PING_BIN" ]] || die '未找到 iwan-client，请先运行 cargo build --locked --bin iwan-client。'
    load_servers
    if [[ "$request" != all ]]; then selected=$(resolve_server "$request") || return 1; fi
    if [[ -n "$bind" ]]; then bind_args=(--bind "$bind"); fi
    while IFS=$'\t' read -r index_number name host port; do
        [[ -z "$selected" || "$selected" == "$index_number" ]] || continue
        printf '\n[%s] %s (%s:%s)\n' "$index_number" "$name" "$host" "$port"
        if output=$("$PING_BIN" ping --server "$host" --port "$port" "${bind_args[@]}" 2>&1); then
            printf '%s\n' "$output"
        else
            printf '不可达：%s\n' "$output"
            failures=$((failures + 1))
        fi
    done <<< "$SERVER_ROWS"
    printf '\n线路测试完成，失败 %s 条。PING 不代表认证或 HTTP 转发成功，可另用 check 检查当前代理。\n' "$failures"
    (( failures == 0 ))
}

check_proxy() {
    local proxy url
    local -a urls=(http://example.com/ https://example.com/)
    get_running || die '代理未运行，请先 start。'
    command -v curl >/dev/null || die 'check 需要 curl。'
    proxy=$ACTIVE_LISTEN
    case "$proxy" in
        0.0.0.0:*) proxy="127.0.0.1:${proxy##*:}" ;;
        '[::]':*) proxy="[::1]:${proxy##*:}" ;;
    esac
    if (( $# )); then urls=("$1"); fi
    for url in "${urls[@]}"; do
        curl --disable --proxy "http://$proxy" --noproxy '' --connect-timeout "$CHECK_TIMEOUT" --max-time "$CHECK_TIMEOUT" \
            --silent --show-error --fail --output /dev/null \
            --write-out 'HTTP %{http_code}, CONNECT %{http_connect}, 总耗时 %{time_total}s\n' "$url" || return 1
    done
}

validate_checks() {
    local value
    command -v curl >/dev/null || die '转发检查需要 curl。'
    for value in "$CHECK_TIMEOUT" "$WATCH_INTERVAL" "$WATCH_FAILURES" "$WATCH_COOLDOWN"; do
        [[ "$value" =~ ^[1-9][0-9]{0,5}$ ]] || die '检查与巡检参数须为 1 到 999999 的整数。'
    done
    if (( $# )); then
        [[ "$1" == http://* || "$1" == https://* ]] || die '检查地址须以 http:// 或 https:// 开头。'
    fi
}

probe_proxy() {
    local proxy url code
    local -a urls=("$WATCH_URL")
    get_running || return 1
    proxy=$ACTIVE_LISTEN
    case "$proxy" in
        0.0.0.0:*) proxy="127.0.0.1:${proxy##*:}" ;;
        '[::]':*) proxy="[::1]:${proxy##*:}" ;;
    esac
    if (( $# )); then urls=("$1"); fi
    # Any reachable target suffices. Authentication errors still prove forwarding.
    for url in "${urls[@]}"; do
        PROBE_FILE=$(mktemp "$STATE_DIR/iwan-http.probe.XXXXXX") || return 1
        curl --disable --proxy "http://$proxy" --noproxy '' \
            --connect-timeout "$CHECK_TIMEOUT" --max-time "$CHECK_TIMEOUT" \
            --silent --output /dev/null --write-out '%{http_code}' "$url" > "$PROBE_FILE" 8>&- 9>&- &
        PROBE_PID=$!
        local result=0
        wait "$PROBE_PID" || result=$?
        PROBE_PID=
        code=$(< "$PROBE_FILE")
        rm -f -- "$PROBE_FILE"
        PROBE_FILE=
        if (( result == 0 )) && [[ "$code" =~ ^[234][0-9][0-9]$ ]]; then
            printf '转发正常：HTTP %s\n' "$code"
            return 0
        fi
    done
    printf '转发检查失败（进程存在不代表隧道可用；目标服务故障也可能导致检查失败）。\n' >&2
    return 1
}

ensure_proxy() {
    if probe_proxy "$@"; then return; fi
    # Recheck under the manager lock to avoid racing stop/switch/another recovery.
    lock_manager
    if probe_proxy "$@"; then return; fi
    printf '重新连接当前/上次成功的线路……\n'
    stop_watcher || return 1
    local result=0
    change_server || result=$?
    if get_running; then start_watcher || return 1; fi
    if (( result != 0 )); then return "$result"; fi
    if probe_proxy "$@"; then return; fi
    printf '错误：重连后检查仍失败，请查看日志或检查目标服务；不会继续重启。\n' >&2
    return 1
}

watch_proxy() {
    local failures=0 last_recovery=-$WATCH_COOLDOWN watched_pid watched_stamp result sleeper=
    # A separate lock prevents duplicate foreground or nohup watchers.
    mkdir -p -- "$STATE_DIR"
    exec 8> "$STATE_DIR/iwan-http.watch.lock"
    flock -n 8 || die '已有巡检进程在运行。'
    get_running || die '代理未运行，请先 start。'
    watched_pid=$PID watched_stamp=$START_TIME
    trap 'exit 0' INT TERM
    trap 'cleanup_watcher' EXIT
    write_value "$WATCH_PID_FILE" "$$"
    write_value "$WATCH_STAMP_FILE" "$(process_stamp "$$")"
    printf '巡检已启动：间隔 %ss，连续 %s 次失败后重连，冷却 %ss。\n' \
        "$WATCH_INTERVAL" "$WATCH_FAILURES" "$WATCH_COOLDOWN"
    while get_running && [[ "$PID:$START_TIME" == "$watched_pid:$watched_stamp" ]]; do
        if probe_proxy "$@"; then
            failures=0
        else
            failures=$((failures + 1))
            printf '连续检查失败：%s/%s\n' "$failures" "$WATCH_FAILURES" >&2
            if (( failures >= WATCH_FAILURES && SECONDS - last_recovery >= WATCH_COOLDOWN )); then
                # Keep a manual stop or switch authoritative, including during a probe.
                result=0
                (
                    lock_manager
                    get_running && [[ "$PID:$START_TIME" == "$watched_pid:$watched_stamp" ]] || exit 75
                    printf '巡检恢复：重新连接当前线路……\n'
                    change_server && probe_proxy "$@"
                ) || result=$?
                if (( result == 75 )); then break; fi
                if (( result != 0 )); then printf '巡检恢复失败，冷却后再试。\n' >&2; fi
                last_recovery=$SECONDS failures=0
                if ! get_running; then break; fi
                watched_pid=$PID watched_stamp=$START_TIME
            fi
        fi
        # Do not let the child sleep retain the watcher lock after termination.
        sleep "$WATCH_INTERVAL" 8>&- &
        sleeper=$!
        wait "$sleeper" || true
        sleeper=
    done
    printf '代理已停止或被替换，结束巡检。\n'
}

cleanup_watcher() {
    # Recovery subshells must not remove their parent's registration.
    if [[ "$BASHPID" != "$$" ]]; then return; fi
    if [[ -n "$PROBE_PID" ]]; then kill "$PROBE_PID" 2>/dev/null || true; fi
    if [[ -n "${sleeper:-}" ]]; then kill "$sleeper" 2>/dev/null || true; fi
    if [[ -n "$PROBE_FILE" ]]; then rm -f -- "$PROBE_FILE"; fi
    if [[ $(read_value "$WATCH_PID_FILE" '') == "$$" ]]; then
        rm -f -- "$WATCH_PID_FILE" "$WATCH_STAMP_FILE"
    fi
}

command_name=${1:-help}
if (( $# )); then shift; fi
if [[ "$command_name" == help || "$command_name" == --help || "$command_name" == -h ]]; then usage; exit; fi
[[ $(uname -s) == Linux ]] || die '此后台管理脚本仅支持 Linux；其他平台请直接使用客户端。'
(( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )) || die '需要 Bash 4.4 或更新版本。'
(( $# <= 1 )) || die '参数过多，请用 --help 查看用法。'

case "$command_name" in
    auth)
        (( $# == 0 )) || die 'auth 不接受参数。'
        [[ -x "$BIN" ]] || die '未找到客户端，请先 cargo build --locked --bins。'
        lock_manager
        "$BIN" --config-dir "$CONFIG_DIR" --fetch
        ;;
    start)
        validate_auto_watch
        lock_manager
        if get_running; then
            if (( $# )); then
                load_servers
                selected=$(resolve_server "$1")
                [[ "$selected" == "$ACTIVE_SERVER" ]] || die '代理已运行，切换线路请用 switch。'
            fi
            show_status
        else
            load_servers
            selected=$(resolve_server "${1:-$(read_value "$SERVER_FILE" 1)}")
            start_proxy "$selected"
        fi
        start_watcher
        ;;
    stop) (( $# == 0 )) || die 'stop 不接受参数。'; lock_manager; stop_watcher; stop_proxy ;;
    restart|switch)
        if [[ "$command_name" == switch ]]; then (( $# == 1 )) || die 'switch 需要线路编号或名称。'; fi
        validate_auto_watch
        lock_manager
        stop_watcher
        result=0
        change_server "${1:-}" || result=$?
        if get_running; then start_watcher || exit 1; fi
        exit "$result"
        ;;
    status) (( $# == 0 )) || die 'status 不接受参数。'; show_status ;;
    list) (( $# == 0 )) || die 'list 不接受参数。'; [[ -x "$BIN" ]] || die '未找到客户端，请先 cargo build --locked --bins。'; "$BIN" --config-dir "$CONFIG_DIR" --list ;;
    test) test_servers "${1:-all}" ;;
    check) validate_checks "$@"; check_proxy "$@" ;;
    ensure) validate_checks "$@"; ensure_proxy "$@" ;;
    watch) validate_checks "$@"; watch_proxy "$@" ;;
    logs)
        [[ -f "$LOG_FILE" ]] || die '尚无日志，请先 start。'
        if (( $# == 0 )); then tail -n 40 -- "$LOG_FILE"
        elif [[ "$1" == -f ]]; then tail -n 40 -f -- "$LOG_FILE"
        else die 'logs 只接受 -f 参数。'; fi
        ;;
    *) die "未知命令：$command_name，请用 --help 查看用法。" ;;
esac
