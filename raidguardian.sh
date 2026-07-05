#!/bin/sh
# ============================================================================
# RAID Guardian v4.0 - Multi-Vendor Edition (Temperature & Health Monitoring)
# Developer: Ayham Brimo
#
# Supports:
#   - HPE Smart Array / SSA    -> ssacli
#   - Dell PERC                -> perccli / perccli64
#   - LSI / Broadcom / Avago   -> storcli / storcli64
#   - Adaptec / Microsemi/HBA  -> arcconf
#
# Adds: controller + per-drive temperature thresholds, battery/cache health,
# drive-count summaries, optional webhook/email alerting.
#
# Written for POSIX sh (busybox ash) so it runs unmodified on ESXi's
# built-in shell, no bash required.
# ============================================================================

VERSION="4.0"
LOG_FILE="/var/log/raidguardian.log"
LOCK_DIR="/var/run/raidguardian.lock"
MAX_LOG_LINES=2000
CONFIG_FILE="/etc/raidguardian.conf"

STATE_OK=0
STATE_WARN=1
STATE_CRIT=2

# ----------------------------------------------------------------------------
# Defaults (override any of these in /etc/raidguardian.conf)
# ----------------------------------------------------------------------------
TEMP_WARN_C=45      # controller/drive temp (C) that triggers WARN
TEMP_CRIT_C=58      # controller/drive temp (C) that triggers CRIT
ALERT_WEBHOOK_URL=""   # e.g. Slack/Teams incoming webhook URL - blank = disabled
ALERT_EMAIL=""         # e.g. storage-team@example.com - blank = disabled, requires 'mail'/'sendmail' on host

# shellcheck disable=SC1090
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"

# ----------------------------------------------------------------------------
# Colors (auto-disabled when not an interactive tty, e.g. cron/log redirect)
# ----------------------------------------------------------------------------
if [ -t 1 ]; then
    C_RED='\033[0;31m'; C_GRN='\033[0;32m'; C_YEL='\033[1;33m'
    C_BLU='\033[0;34m'; C_NC='\033[0m'
else
    C_RED=''; C_GRN=''; C_YEL=''; C_BLU=''; C_NC=''
fi

WORST_STATE=$STATE_OK
REPORT=""
JSON_ITEMS=""

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------

# find_binary "name1" "path1" "path2" ... -> echoes first match, empty if none
find_binary() {
    for p in "$@"; do
        if [ -x "$p" ]; then
            echo "$p"; return 0
        fi
    done
    for p in "$@"; do
        case "$p" in
            */*) : ;;
            *)
                found=$(command -v "$p" 2>/dev/null)
                if [ -n "$found" ]; then echo "$found"; return 0; fi
                ;;
        esac
    done
    echo ""
}

# raise_state <candidate_state>  -- keeps track of the worst status seen
raise_state() {
    [ "$1" -gt "$WORST_STATE" ] && WORST_STATE=$1
}

# analyze_status "<blob of text>" -> prints colored line, returns state code
analyze_status() {
    STAT="$1"
    if echo "$STAT" | grep -qiE "Failed|Missing|Disabled|Foreign|Offline|Error"; then
        printf "${C_RED}[FAIL] Critical problem detected${C_NC}\n"
        return $STATE_CRIT
    elif echo "$STAT" | grep -qiE "Degraded|Recovering|Rebuild|Interim|Partially|Predictive"; then
        printf "${C_YEL}[WARN] RAID not optimal${C_NC}\n"
        return $STATE_WARN
    elif echo "$STAT" | grep -qiE "Optimal|OK|Online|Ready|Spun Up"; then
        printf "${C_GRN}[PASS] RAID Healthy${C_NC}\n"
        return $STATE_OK
    else
        printf "${C_YEL}[INFO] Unknown status - please verify manually${C_NC}\n"
        return $STATE_WARN
    fi
}

state_word() {
    case "$1" in
        $STATE_OK)   echo "OK" ;;
        $STATE_WARN) echo "WARN" ;;
        $STATE_CRIT) echo "CRIT" ;;
        *)           echo "UNKNOWN" ;;
    esac
}

# check_temp <value_or_empty> -> prints colored "NNC" (or "n/a") to stdout, returns state code
# thresholds compared as integers; non-numeric input is treated as "n/a" and never fails the check
check_temp() {
    raw="$1"
    val=$(echo "$raw" | grep -oE '[0-9]+' | head -1)
    if [ -z "$val" ]; then
        printf "n/a"
        return $STATE_OK
    fi
    if [ "$val" -ge "$TEMP_CRIT_C" ]; then
        printf "${C_RED}%sC [CRIT]${C_NC}" "$val"
        return $STATE_CRIT
    elif [ "$val" -ge "$TEMP_WARN_C" ]; then
        printf "${C_YEL}%sC [WARN]${C_NC}" "$val"
        return $STATE_WARN
    else
        printf "${C_GRN}%sC${C_NC}" "$val"
        return $STATE_OK
    fi
}

# drive_summary "<physical drive block>" -> prints "N total, N healthy, N need attention"
drive_summary() {
    block="$1"
    total=$(echo "$block" | grep -icE "physicaldrive|^Drive |EID:Slt")
    bad=$(echo "$block" | grep -icE "Failed|Predictive Failure|Degraded|Offline")
    good=$((total - bad))
    [ "$good" -lt 0 ] && good=0
    printf "%s total, %s healthy, %s need attention" "$total" "$good" "$bad"
}

add_json_item() {
    # add_json_item <vendor> <controller_id> <state_word> <ctrl_temp> <max_drive_temp> <battery_status>
    item="{\"vendor\":\"$1\",\"controller\":\"$2\",\"status\":\"$3\",\"controller_temp_c\":\"$4\",\"max_drive_temp_c\":\"$5\",\"battery_status\":\"$6\"}"
    if [ -z "$JSON_ITEMS" ]; then
        JSON_ITEMS="$item"
    else
        JSON_ITEMS="$JSON_ITEMS,$item"
    fi
}

# strip_color <text> -> removes ANSI escape sequences (for clean JSON/log values)
strip_color() {
    printf '%s' "$1" | sed 's/\x1b\[[0-9;]*m//g'
}

# ----------------------------------------------------------------------------
# Vendor-specific checks
# ----------------------------------------------------------------------------

check_ssacli() {
    bin="$1"
    REPORT="$REPORT\n${C_BLU}--- HPE Smart Array (ssacli) ---${C_NC}\n"

    header=$("$bin" ctrl all show 2>/dev/null)
    slot=$(echo "$header" | grep -oE "Slot [0-9]+" | head -1 | awk '{print $2}')
    [ -z "$slot" ] && slot=0

    raw=$("$bin" ctrl all show config 2>/dev/null)
    ld=$(echo "$raw" | grep -i "logicaldrive")
    pd=$(echo "$raw" | grep -i "physicaldrive")

    # Firmware is NOT in "ctrl all show" - it only appears in "show detail"
    ctrl_detail=$("$bin" ctrl slot="$slot" show detail 2>/dev/null)
    fw=$(echo "$ctrl_detail" | grep -i "Firmware Version" | head -1 | awk -F: '{print $2}' | sed 's/^ *//')
    ctrl_temp_raw=$(echo "$ctrl_detail" | grep -i "Controller Temperature" | awk -F: '{print $2}')
    cache_temp_raw=$(echo "$ctrl_detail" | grep -i "Cache Module Temperature" | awk -F: '{print $2}')
    battery=$(echo "$ctrl_detail" | grep -iE "Battery/Capacitor Status|Cache Status" | head -1 | awk -F: '{print $2}' | sed 's/^ *//')
    [ -z "$battery" ] && battery="n/a"

    # Per-drive temperature (best effort - field name confirmed on HPE Gen9/Gen10)
    drive_detail=$("$bin" ctrl slot="$slot" physicaldrive all show detail 2>/dev/null)
    drive_temps=$(echo "$drive_detail" | awk '
        /^\s*physicaldrive/ {drive=$0; sub(/^[ \t]*/,"",drive)}
        /Current Temperature \(C\)/ {t=$0; sub(/.*: */,"",t); print drive ": " t "C"}
    ')
    max_drive_temp=$(echo "$drive_temps" | grep -oE '[0-9]+C' | grep -oE '[0-9]+' | sort -n | tail -1)

    ctrl_temp_line=$(check_temp "$ctrl_temp_raw"); ctrl_temp_rc=$?
    cache_temp_line=$(check_temp "$cache_temp_raw"); cache_temp_rc=$?
    drive_temp_line=$(check_temp "$max_drive_temp"); drive_temp_rc=$?
    dsum=$(drive_summary "$pd")

    REPORT="$REPORT Firmware       : ${fw:-unknown}\n"
    REPORT="$REPORT Controller Temp: $ctrl_temp_line\n"
    REPORT="$REPORT Cache Module Temp: $cache_temp_line\n"
    REPORT="$REPORT Battery/Cache  : $battery\n"
    REPORT="$REPORT Drive Summary  : $dsum\n"
    REPORT="$REPORT Max Drive Temp : $drive_temp_line\n"
    REPORT="$REPORT Logical Drives:\n${ld:-  none found}\n"
    REPORT="$REPORT Physical Drives:\n${pd:-  none found}\n"
    [ -n "$drive_temps" ] && REPORT="$REPORT Drive Temperatures:\n${drive_temps}\n"

    line=$(analyze_status "$raw")
    rc=$?
    REPORT="$REPORT Status         : $line\n"

    echo "$battery" | grep -qiE "Failed|Missing|Weak" && rc=$STATE_CRIT

    raise_state "$rc"
    raise_state "$ctrl_temp_rc"
    raise_state "$cache_temp_rc"
    raise_state "$drive_temp_rc"

    final_rc=$rc
    [ "$ctrl_temp_rc" -gt "$final_rc" ] && final_rc=$ctrl_temp_rc
    [ "$cache_temp_rc" -gt "$final_rc" ] && final_rc=$cache_temp_rc
    [ "$drive_temp_rc" -gt "$final_rc" ] && final_rc=$drive_temp_rc

    add_json_item "HPE" "slot$slot" "$(state_word $final_rc)" "$(strip_color "$ctrl_temp_line")" "$(strip_color "$drive_temp_line")" "$battery"
}

# Shared logic for perccli (Dell) and storcli (LSI/Broadcom) - same CLI grammar
check_megaraid_cli() {
    vendor="$1"   # "Dell" or "LSI/Broadcom"
    bin="$2"
    REPORT="$REPORT\n${C_BLU}--- $vendor (${bin##*/}) ---${C_NC}\n"

    ctrl_count=$("$bin" show ctrlcount 2>/dev/null | grep -i "Controller Count" | awk -F= '{print $2}' | tr -d ' \r')
    case "$ctrl_count" in
        ''|*[!0-9]*) ctrl_count=1 ;;
    esac

    i=0
    while [ "$i" -lt "$ctrl_count" ]; do
        cid="/c$i"
        ctrl_all=$("$bin" "$cid" show all 2>/dev/null)
        fw=$(echo "$ctrl_all" | grep -iE "FW Package Build|Firmware Version" | head -1 | awk -F= '{print $2}' | sed 's/^ *//')
        ctrl_temp_raw=$(echo "$ctrl_all" | grep -i "ROC temperature" | head -1 | grep -oE '[0-9]+')
        bbu=$("$bin" "$cid/cv" show 2>/dev/null | grep -iE "^State" | head -1 | awk -F= '{print $2}' | sed 's/^ *//')
        [ -z "$bbu" ] && bbu=$("$bin" "$cid/bbu" show status 2>/dev/null | grep -iE "^Battery State" | head -1 | awk -F= '{print $2}' | sed 's/^ *//')
        [ -z "$bbu" ] && bbu="n/a"

        vd=$("$bin" "$cid/vall" show 2>/dev/null)
        pd=$("$bin" "$cid/eall/sall" show 2>/dev/null)
        pd_temps_raw=$("$bin" "$cid/eall/sall" show all 2>/dev/null | grep -i "Drive Temperature")
        max_drive_temp=$(echo "$pd_temps_raw" | grep -oE '[0-9]+C' | grep -oE '[0-9]+' | sort -n | tail -1)

        ctrl_temp_line=$(check_temp "$ctrl_temp_raw"); ctrl_temp_rc=$?
        drive_temp_line=$(check_temp "$max_drive_temp"); drive_temp_rc=$?
        dsum=$(drive_summary "$pd")

        REPORT="$REPORT Controller $i Firmware : ${fw:-unknown}\n"
        REPORT="$REPORT Controller $i Temp     : $ctrl_temp_line\n"
        REPORT="$REPORT Battery/CacheVault (c$i): $bbu\n"
        REPORT="$REPORT Drive Summary (c$i)    : $dsum\n"
        REPORT="$REPORT Max Drive Temp (c$i)   : $drive_temp_line\n"
        REPORT="$REPORT Virtual Drives (c$i):\n${vd:-  none found}\n"
        REPORT="$REPORT Physical Drives (c$i):\n${pd:-  none found}\n"

        combined="$vd
$pd"
        line=$(analyze_status "$combined")
        rc=$?
        REPORT="$REPORT Status (c$i)  : $line\n"

        echo "$bbu" | grep -qiE "Failed|Missing|Bad" && rc=$STATE_CRIT

        raise_state "$rc"
        raise_state "$ctrl_temp_rc"
        raise_state "$drive_temp_rc"

        final_rc=$rc
        [ "$ctrl_temp_rc" -gt "$final_rc" ] && final_rc=$ctrl_temp_rc
        [ "$drive_temp_rc" -gt "$final_rc" ] && final_rc=$drive_temp_rc

        add_json_item "$vendor" "c$i" "$(state_word $final_rc)" "$(strip_color "$ctrl_temp_line")" "$(strip_color "$drive_temp_line")" "$bbu"

        i=$((i + 1))
    done
}

check_arcconf() {
    bin="$1"
    REPORT="$REPORT\n${C_BLU}--- Adaptec/Microsemi (arcconf) ---${C_NC}\n"

    ctrl_count=$("$bin" GETVERSION 2>/dev/null | grep -ci "Controller #")
    [ "$ctrl_count" -lt 1 ] 2>/dev/null && ctrl_count=1

    i=1
    while [ "$i" -le "$ctrl_count" ]; do
        ad=$("$bin" GETCONFIG "$i" AD 2>/dev/null)
        ctrl_temp_raw=$(echo "$ad" | grep -i "Temperature" | head -1 | grep -oE '[0-9]+')
        battery=$(echo "$ad" | grep -iE "^\s*Status\s*:" | grep -i -A1 "Battery" | tail -1 | sed 's/^ *//')
        [ -z "$battery" ] && battery="n/a"

        ld=$("$bin" GETCONFIG "$i" LD 2>/dev/null | grep -iE "Status of logical device|Logical device name")
        pd_full=$("$bin" GETCONFIG "$i" PD 2>/dev/null)
        pd=$(echo "$pd_full" | grep -iE "^\s*State|Reported Channel")
        pd_temps_raw=$(echo "$pd_full" | grep -i "Temperature")
        max_drive_temp=$(echo "$pd_temps_raw" | grep -oE '[0-9]+ C' | grep -oE '[0-9]+' | sort -n | tail -1)

        ctrl_temp_line=$(check_temp "$ctrl_temp_raw"); ctrl_temp_rc=$?
        drive_temp_line=$(check_temp "$max_drive_temp"); drive_temp_rc=$?
        dsum=$(drive_summary "$pd_full")

        REPORT="$REPORT Controller $i Temp     : $ctrl_temp_line\n"
        REPORT="$REPORT Battery (ctrl $i)      : $battery\n"
        REPORT="$REPORT Drive Summary (ctrl $i): $dsum\n"
        REPORT="$REPORT Max Drive Temp (ctrl $i): $drive_temp_line\n"
        REPORT="$REPORT Logical Devices (ctrl $i):\n${ld:-  none found}\n"
        REPORT="$REPORT Physical Devices (ctrl $i):\n${pd:-  none found}\n"

        combined="$ld
$pd"
        line=$(analyze_status "$combined")
        rc=$?
        REPORT="$REPORT Status (ctrl $i): $line\n"

        echo "$battery" | grep -qiE "Failed|Missing|Bad" && rc=$STATE_CRIT

        raise_state "$rc"
        raise_state "$ctrl_temp_rc"
        raise_state "$drive_temp_rc"

        final_rc=$rc
        [ "$ctrl_temp_rc" -gt "$final_rc" ] && final_rc=$ctrl_temp_rc
        [ "$drive_temp_rc" -gt "$final_rc" ] && final_rc=$drive_temp_rc

        add_json_item "Adaptec" "$i" "$(state_word $final_rc)" "$(strip_color "$ctrl_temp_line")" "$(strip_color "$drive_temp_line")" "$battery"

        i=$((i + 1))
    done
}

# ----------------------------------------------------------------------------
# Alerting (only fires when overall status is WARN/CRIT and a channel is configured)
# ----------------------------------------------------------------------------
send_alerts() {
    [ "$WORST_STATE" -eq "$STATE_OK" ] && return 0

    plain_report=$(strip_color "$REPORT")
    subject="RAID Guardian [$FINAL_WORD] - $HOSTNAME"

    if [ -n "$ALERT_WEBHOOK_URL" ] && command -v curl >/dev/null 2>&1; then
        msg=$(printf '%s' "$plain_report" | tr '\n' ' ' | sed 's/"/\\"/g')
        curl -s -m 10 -X POST -H "Content-Type: application/json" \
            -d "{\"text\":\"*$subject*: $msg\"}" "$ALERT_WEBHOOK_URL" >/dev/null 2>&1
    fi

    if [ -n "$ALERT_EMAIL" ]; then
        if command -v mail >/dev/null 2>&1; then
            printf '%s\n' "$plain_report" | mail -s "$subject" "$ALERT_EMAIL" 2>/dev/null
        elif command -v sendmail >/dev/null 2>&1; then
            { printf 'Subject: %s\nTo: %s\n\n' "$subject" "$ALERT_EMAIL"; printf '%s\n' "$plain_report"; } | sendmail -t 2>/dev/null
        fi
    fi
}

# ----------------------------------------------------------------------------
# Log rotation (keep log file bounded on ESXi's small local storage)
# ----------------------------------------------------------------------------
rotate_log() {
    [ -f "$LOG_FILE" ] || return 0
    lines=$(wc -l < "$LOG_FILE" 2>/dev/null)
    [ -n "$lines" ] && [ "$lines" -gt "$MAX_LOG_LINES" ] || return 0
    tail -n "$((MAX_LOG_LINES / 2))" "$LOG_FILE" > "${LOG_FILE}.tmp" 2>/dev/null \
        && mv "${LOG_FILE}.tmp" "$LOG_FILE"
}

# ----------------------------------------------------------------------------
# Simple run-lock so cron can't overlap two runs on the same host
# ----------------------------------------------------------------------------
acquire_lock() {
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        echo "Another RAID Guardian run appears to be in progress ($LOCK_DIR). Exiting." >&2
        exit $STATE_WARN
    fi
    trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT INT TERM
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
HOSTNAME=$(hostname)
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

case "$1" in
    --version)
        echo "RAID Guardian v$VERSION | Dev: Ayham Brimo"
        exit 0
        ;;
    --help|-h)
        cat <<EOF
RAID Guardian v$VERSION
Usage: $0 [--json] [--version] [--help]
  (no args)   Full human-readable report
  --json      Machine-readable JSON summary
  --version   Print version and exit
  --help      Show this help
Exit codes: 0=OK 1=WARN 2=CRIT

Config file: $CONFIG_FILE (optional), example:
  TEMP_WARN_C=45
  TEMP_CRIT_C=58
  ALERT_WEBHOOK_URL="https://hooks.slack.com/services/xxx"
  ALERT_EMAIL="storage-team@example.com"
EOF
        exit 0
        ;;
esac

acquire_lock

SSACLI_BIN=$(find_binary "/opt/smartstorageadmin/ssacli/bin/ssacli" "ssacli")
PERCCLI_BIN=$(find_binary "/opt/lsi/perccli/perccli64" "/opt/lsi/perccli/perccli" \
                          "/opt/dell/perccli/perccli64" "/opt/dell/perccli/perccli" \
                          "perccli64" "perccli")
STORCLI_BIN=$(find_binary "/opt/lsi/storcli/storcli64" "/opt/lsi/storcli/storcli" \
                          "storcli64" "storcli")
ARCCONF_BIN=$(find_binary "/usr/StorMan/arcconf" "/opt/StorMan/arcconf" "arcconf")

FOUND_ANY=0
[ -n "$SSACLI_BIN" ]  && FOUND_ANY=1
[ -n "$PERCCLI_BIN" ] && FOUND_ANY=1
[ -n "$STORCLI_BIN" ] && FOUND_ANY=1
[ -n "$ARCCONF_BIN" ] && FOUND_ANY=1

if [ "$FOUND_ANY" -eq 0 ]; then
    if [ "$1" = "--json" ]; then
        echo "{\"host\":\"$HOSTNAME\",\"timestamp\":\"$TIMESTAMP\",\"status\":\"WARN\",\"message\":\"no supported RAID CLI found\",\"controllers\":[]}"
    else
        printf "${C_YEL}[WARN] No supported RAID management CLI found on this host (ssacli/perccli/storcli/arcconf).${C_NC}\n"
    fi
    echo "$TIMESTAMP | $HOSTNAME | Status: WARN | no RAID CLI found" >> "$LOG_FILE"
    exit $STATE_WARN
fi

[ -n "$SSACLI_BIN" ]  && check_ssacli "$SSACLI_BIN"
[ -n "$PERCCLI_BIN" ] && check_megaraid_cli "Dell" "$PERCCLI_BIN"
[ -n "$STORCLI_BIN" ] && check_megaraid_cli "LSI/Broadcom" "$STORCLI_BIN"
[ -n "$ARCCONF_BIN" ] && check_arcconf "$ARCCONF_BIN"

FINAL_WORD=$(state_word "$WORST_STATE")

if [ "$1" = "--json" ]; then
    echo "{\"host\":\"$HOSTNAME\",\"timestamp\":\"$TIMESTAMP\",\"status\":\"$FINAL_WORD\",\"temp_thresholds\":{\"warn_c\":$TEMP_WARN_C,\"crit_c\":$TEMP_CRIT_C},\"controllers\":[$JSON_ITEMS]}"
else
    printf "${C_BLU}==============================================================${C_NC}\n"
    printf " RAID Guardian v%s\n" "$VERSION"
    printf " Host      : %s\n" "$HOSTNAME"
    printf " Date      : %s\n" "$TIMESTAMP"
    printf " Temp Limits: WARN >= %sC | CRIT >= %sC\n" "$TEMP_WARN_C" "$TEMP_CRIT_C"
    printf "${C_BLU}==============================================================${C_NC}\n"
    printf "%b\n" "$REPORT"
    printf "${C_BLU}==============================================================${C_NC}\n"
    printf " Overall Status: %s\n" "$FINAL_WORD"
    printf "${C_BLU}==============================================================${C_NC}\n"
fi

send_alerts
rotate_log
echo "$TIMESTAMP | $HOSTNAME | Status: $FINAL_WORD" >> "$LOG_FILE"

exit "$WORST_STATE"
