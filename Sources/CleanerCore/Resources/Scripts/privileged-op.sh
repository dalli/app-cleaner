#!/bin/sh
# privileged-op.sh — App Cleaner 관리자 작업 고정 스크립트 (plan.md 5.3 "MVP 임시 방식")
#
# 앱은 이 파일의 SHA-256을 Swift 코드에 컴파일된 상수와 비교한 뒤에만 실행한다.
# 실행 경로: osascript `do shell script … with administrator privileges` (GUI) 또는 sudo (CLI).
# 인자는 모두 `quoted form of`로 전달되며, 이 스크립트는 어떤 인자도 eval/재해석하지 않는다.
#
# 작업:
#   move-to-holding      <session> <path>
#   restore-from-holding <session> <original-path> [<restore-to>]
#   bootout-system       <label>
#   bootstrap-system     <plist>
#   pkg-forget           <pkg-id>
#   purge-holding        <session>
#   batch                <ops-file>     (한 줄에 작업 1개, 필드는 TAB 구분 — 한 번의 인증으로 묶어 실행)
#
# 출력: 작업마다 한 줄 — "ok<TAB><번호><TAB><메시지>" 또는 "fail<TAB><번호><TAB><사유 코드>"
#
# 권한 상승된 쪽에서 다시 검증한다 (앱의 판단을 신뢰하지 않음):
#   - 허용 루트 화이트리스트 하위만 (루트 자체는 불가)
#   - 절대 경로, 빈·`.`·`..` 구성요소 금지
#   - 경로의 모든 구성요소에 대해 `[ -L ]` 검사 (심볼릭 링크 금지)
#   - 보호 목록 재적용 (com.apple.*, 본 앱 폴더, 시스템 경로)
#   - 레이블·패키지 ID는 [A-Za-z0-9._-]만
#
# 알려진 제한 (plan.md 5.3): 검사와 mv 사이에 사용자 쓰기 가능한 상위 디렉토리가 심볼릭 링크로
# 바뀌는 경쟁 조건(TOCTOU)을 완전히 막지 못한다. fd 기반(openat O_NOFOLLOW + renameatx_np) 검증은
# Phase 3 권한 헬퍼에서 해소한다.
#
# 루트 접두사: uid 0이면 항상 "/" (APPCLEANER_TEST_ROOT 무시). 일반 사용자로 실행하면(테스트 전용)
# APPCLEANER_TEST_ROOT 아래에서만 동작하고 launchctl·pkgutil은 실행하지 않는다.

set -eu
umask 077
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
LC_ALL=C
export LC_ALL

TAB=$(printf '\t')
IDX=0
REASON=""

if [ "$(/usr/bin/id -u)" -eq 0 ]; then
    ROOT=""
    TEST_MODE=0
else
    TEST_MODE=1
    ROOT="${APPCLEANER_TEST_ROOT:-}"
    case "$ROOT" in
        /*) ;;
        *) printf 'fail\t0\tnot-root\n'; exit 77 ;;
    esac
    while [ "${ROOT%/}" != "$ROOT" ]; do ROOT=${ROOT%/}; done
    if [ -z "$ROOT" ] || [ ! -d "$ROOT" ]; then printf 'fail\t0\tbad-test-root\n'; exit 77; fi
fi

HOLD_PARENT="$ROOT/Library/Application Support/AppCleaner"
HOLD="$HOLD_PARENT/Holding"

ok() { printf 'ok\t%s\t%s\n' "$IDX" "$1"; }
fail() { printf 'fail\t%s\t%s\n' "$IDX" "$1"; }
reject() { REASON=$1; return 1; }
lower() { printf '%s' "$1" | /usr/bin/tr 'A-Z' 'a-z'; }

# --- 검증 -------------------------------------------------------------------

check_syntax() {
    case "$1" in
        /*) ;;
        *) reject "not-absolute"; return 1 ;;
    esac
    case "$1" in
        */./*|*/../*|*/.|*/..) reject "dotdot"; return 1 ;;
    esac
    case "$1" in
        *//*|*/) reject "bad-path"; return 1 ;;
    esac
    case "$1" in
        *"$TAB"*) reject "bad-char"; return 1 ;;
    esac
    return 0
}

check_allowed_root() {
    case "$1" in
        /Library/LaunchDaemons/?*|/Library/LaunchAgents/?*|/Library/PrivilegedHelperTools/?*) return 0 ;;
        "/Library/Application Support/"?*|/Library/Caches/?*|/Library/Preferences/?*|/Library/Logs/?*) return 0 ;;
        /Applications/?*) return 0 ;;
    esac
    reject "outside-allowed-root"
    return 1
}

check_protected() {
    lp=$(lower "$1")
    case "$lp" in
        "/library/application support/appcleaner"|"/library/application support/appcleaner/"*) reject "protected"; return 1 ;;
        "/library/application support/apple"|"/library/application support/apple/"*) reject "protected"; return 1 ;;
        "/library/application support/mobilesync"|"/library/application support/mobilesync/"*) reject "protected"; return 1 ;;
        /library/logs/diagnosticreports|/applications/utilities) reject "protected"; return 1 ;;
        */com.apple.*|*/group.com.apple.*|*/com.dallisoft.appcleaner|*/com.dallisoft.appcleaner.*) reject "protected"; return 1 ;;
    esac
    case "$lp" in
        *.app)
            info="$ROOT$1/Contents/Info.plist"
            if [ -f "$info" ] && [ ! -L "$info" ]; then
                bid=$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$info" 2>/dev/null || true)
                bid=$(lower "$bid")
                case "$bid" in
                    com.apple.*|com.dallisoft.appcleaner|com.dallisoft.appcleaner.*) reject "protected"; return 1 ;;
                esac
            fi
            ;;
    esac
    return 0
}

# $1 = 논리 경로, $2 = all | parents  (ROOT 접두사 자체는 검사하지 않음 — 운영 환경에서 ROOT는 빈 문자열)
check_no_symlinks() {
    rest=${1#/}
    cur=$ROOT
    while [ -n "$rest" ]; do
        comp=${rest%%/*}
        if [ "$comp" = "$rest" ]; then rest=""; else rest=${rest#*/}; fi
        cur="$cur/$comp"
        if [ -z "$rest" ] && [ "$2" = "parents" ]; then break; fi
        if [ -L "$cur" ]; then reject "symlink"; return 1; fi
    done
    return 0
}

check_session() {
    case "$1" in
        ""|*[!A-Fa-f0-9-]*) reject "bad-session"; return 1 ;;
    esac
    if [ "${#1}" -ne 36 ]; then reject "bad-session"; return 1; fi
    return 0
}

check_identifier() {
    case "$1" in
        ""|-*|.*|*[!A-Za-z0-9._-]*) reject "bad-identifier"; return 1 ;;
    esac
    if [ "${#1}" -gt 255 ]; then reject "bad-identifier"; return 1; fi
    case "$(lower "$1")" in
        com.apple.*) reject "protected"; return 1 ;;
    esac
    return 0
}

check_target_path() {
    check_syntax "$1" || return 1
    check_allowed_root "$1" || return 1
    check_protected "$1" || return 1
    return 0
}

ensure_holding() {
    for d in "$ROOT/Library" "$ROOT/Library/Application Support"; do
        if [ -L "$d" ]; then reject "holding-unsafe"; return 1; fi
    done
    if [ ! -d "$ROOT/Library/Application Support" ]; then
        /bin/mkdir -p -- "$ROOT/Library/Application Support" || { reject "mkdir-failed"; return 1; }
    fi
    for d in "$HOLD_PARENT" "$HOLD" "$HOLD/$1"; do
        if [ -L "$d" ]; then reject "holding-unsafe"; return 1; fi
        if [ ! -d "$d" ]; then
            /bin/mkdir -m 0700 -- "$d" || { reject "mkdir-failed"; return 1; }
        fi
        if [ "$TEST_MODE" -eq 0 ]; then
            /usr/sbin/chown root:wheel "$d" || { reject "chown-failed"; return 1; }
        fi
    done
    /bin/chmod 0755 "$HOLD_PARENT" || { reject "chmod-failed"; return 1; }
    /bin/chmod 0700 "$HOLD" "$HOLD/$1" || { reject "chmod-failed"; return 1; }
    return 0
}

# --- 작업 -------------------------------------------------------------------

op_move_to_holding() {
    check_session "$1" || return 1
    check_target_path "$2" || return 1
    check_no_symlinks "$2" all || return 1
    src="$ROOT$2"
    if [ ! -e "$src" ]; then reject "missing"; return 1; fi
    ensure_holding "$1" || return 1
    dest="$HOLD/$1$2"
    destdir=${dest%/*}
    /bin/mkdir -p -- "$destdir" || { reject "mkdir-failed"; return 1; }
    if [ -e "$dest" ] || [ -L "$dest" ]; then reject "exists"; return 1; fi
    /bin/mv -n -- "$src" "$dest" || { reject "move-failed"; return 1; }
    if [ ! -e "$dest" ] && [ ! -L "$dest" ]; then reject "move-failed"; return 1; fi
    if [ -e "$src" ] || [ -L "$src" ]; then reject "move-failed"; return 1; fi
    ok "$dest"
}

op_restore_from_holding() {
    check_session "$1" || return 1
    check_target_path "$2" || return 1
    target=${3:-$2}
    if [ "$target" != "$2" ]; then
        check_target_path "$target" || return 1
        if [ "${target%/*}" != "${2%/*}" ]; then reject "bad-restore-target"; return 1; fi
    fi
    check_no_symlinks "$target" parents || return 1
    for d in "$HOLD_PARENT" "$HOLD" "$HOLD/$1"; do
        if [ -L "$d" ]; then reject "holding-unsafe"; return 1; fi
    done
    src="$HOLD/$1$2"
    if [ ! -e "$src" ] && [ ! -L "$src" ]; then reject "missing"; return 1; fi
    dst="$ROOT$target"
    if [ -e "$dst" ] || [ -L "$dst" ]; then reject "exists"; return 1; fi
    parent=${dst%/*}
    if [ ! -d "$parent" ]; then
        /bin/mkdir -p -- "$parent" || { reject "mkdir-failed"; return 1; }
        /bin/chmod 0755 "$parent" || true
    fi
    /bin/mv -n -- "$src" "$dst" || { reject "move-failed"; return 1; }
    if [ ! -e "$dst" ] && [ ! -L "$dst" ]; then reject "move-failed"; return 1; fi
    ok "$dst"
}

op_purge_holding() {
    check_session "$1" || return 1
    for d in "$HOLD_PARENT" "$HOLD" "$HOLD/$1"; do
        if [ -L "$d" ]; then reject "holding-unsafe"; return 1; fi
    done
    if [ -d "$HOLD/$1" ]; then
        /bin/rm -rf -- "$HOLD/$1" || { reject "remove-failed"; return 1; }
    fi
    ok "purged"
}

op_bootout_system() {
    check_identifier "$1" || return 1
    if [ "$TEST_MODE" -eq 1 ]; then ok "test-mode"; return 0; fi
    rc=0
    /bin/launchctl bootout "system/$1" >/dev/null 2>&1 || rc=$?
    case "$rc" in
        0|3|113) ok "bootout" ;;
        *) reject "launchctl-$rc"; return 1 ;;
    esac
}

op_bootstrap_system() {
    check_syntax "$1" || return 1
    case "$1" in
        /Library/LaunchDaemons/?*.plist) ;;
        *) reject "outside-allowed-root"; return 1 ;;
    esac
    check_protected "$1" || return 1
    check_no_symlinks "$1" all || return 1
    if [ ! -f "$ROOT$1" ]; then reject "missing"; return 1; fi
    if [ "$TEST_MODE" -eq 1 ]; then ok "test-mode"; return 0; fi
    rc=0
    /bin/launchctl bootstrap system "$1" >/dev/null 2>&1 || rc=$?
    case "$rc" in
        0) ok "bootstrap" ;;
        *) reject "launchctl-$rc"; return 1 ;;
    esac
}

op_pkg_forget() {
    check_identifier "$1" || return 1
    if [ "$TEST_MODE" -eq 1 ]; then ok "test-mode"; return 0; fi
    rc=0
    /usr/sbin/pkgutil --forget "$1" >/dev/null 2>&1 || rc=$?
    case "$rc" in
        0) ok "forgot" ;;
        *) reject "pkgutil-$rc"; return 1 ;;
    esac
}

# $1 = 작업 이름, $2.. = 인자. 성공 시 ok는 각 작업이 출력하고, 실패 시 여기서 fail을 출력한다.
run_one() {
    REASON=""
    op=$1
    a1=${2:-}
    a2=${3:-}
    a3=${4:-}
    case "$op" in
        move-to-holding)
            if op_move_to_holding "$a1" "$a2"; then return 0; fi ;;
        restore-from-holding)
            if op_restore_from_holding "$a1" "$a2" "$a3"; then return 0; fi ;;
        purge-holding)
            if op_purge_holding "$a1"; then return 0; fi ;;
        bootout-system)
            if op_bootout_system "$a1"; then return 0; fi ;;
        bootstrap-system)
            if op_bootstrap_system "$a1"; then return 0; fi ;;
        pkg-forget)
            if op_pkg_forget "$a1"; then return 0; fi ;;
        *)
            REASON="unknown-op" ;;
    esac
    fail "${REASON:-error}"
    return 1
}

op_batch() {
    if [ ! -f "$1" ] || [ -L "$1" ]; then printf 'fail\t0\tbad-ops-file\n'; return 1; fi
    status=0
    exec 3< "$1"
    while IFS= read -r line <&3 || [ -n "$line" ]; do
        IDX=$((IDX + 1))
        if [ -z "$line" ]; then fail "empty"; status=1; continue; fi
        f_op=${line%%"$TAB"*}
        rest=${line#"$f_op"}
        rest=${rest#"$TAB"}
        f_a1=${rest%%"$TAB"*}
        rest=${rest#"$f_a1"}
        rest=${rest#"$TAB"}
        f_a2=${rest%%"$TAB"*}
        rest=${rest#"$f_a2"}
        rest=${rest#"$TAB"}
        f_a3=$rest
        if [ "$f_op" = "batch" ]; then fail "unknown-op"; status=1; continue; fi
        if run_one "$f_op" "$f_a1" "$f_a2" "$f_a3"; then :; else status=1; fi
    done
    exec 3<&-
    return $status
}

# --- 진입점 -----------------------------------------------------------------

if [ "$#" -lt 1 ]; then printf 'fail\t0\tusage\n'; exit 64; fi
cmd=$1
shift
if [ "$cmd" = "batch" ]; then
    if [ "$#" -ne 1 ]; then printf 'fail\t0\tusage\n'; exit 64; fi
    if op_batch "$1"; then exit 0; else exit 1; fi
fi
IDX=1
if run_one "$cmd" "$@"; then exit 0; else exit 1; fi
