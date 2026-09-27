#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
UPDATER="$SCRIPT_DIR/ddns-update.sh"
MARKER='# cloudflare-ddns-updater-managed'

if ! command -v crontab >/dev/null 2>&1; then
    printf '錯誤：找不到 crontab，請先安裝 cron 套件。\n' >&2
    exit 1
fi
if [[ ! -f $UPDATER ]]; then
    printf '錯誤：找不到更新腳本：%s\n' "$UPDATER" >&2
    exit 1
fi

hours=${1:-}
if [[ -z $hours ]]; then
    read -r -p '更新間隔幾小時？[1]: ' hours
    hours=${hours:-1}
fi
if [[ ! $hours =~ ^[0-9]+$ ]]; then
    printf '錯誤：更新間隔必須是 1 到 24 的整數小時。\n' >&2
    exit 1
fi
while [[ ${#hours} -gt 1 && $hours == 0* ]]; do
    hours=${hours#0}
done
if [[ ${#hours} -gt 2 ]]; then
    printf '錯誤：更新間隔必須是 1 到 24 的整數小時。\n' >&2
    exit 1
fi
if (( hours < 1 || hours > 24 )); then
    printf '錯誤：更新間隔必須是 1 到 24 的整數小時。\n' >&2
    exit 1
fi

if (( hours == 24 )); then
    schedule='0 0 * * *'
else
    schedule="0 */$hours * * *"
fi

# Bash escaping with %q produces shell-safe paths, including spaces.
printf -v quoted_dir '%q' "$SCRIPT_DIR"
printf -v quoted_updater '%q' "$UPDATER"
job="$schedule cd -- $quoted_dir && /bin/bash $quoted_updater >> ddns-update.log 2>&1 $MARKER"

tmp_file=$(mktemp)
trap 'rm -f "$tmp_file"' EXIT
existing=$(crontab -l 2>/dev/null || true)
if [[ -n $existing ]]; then
    while IFS= read -r line || [[ -n $line ]]; do
        [[ $line == *"$MARKER"* ]] || printf '%s\n' "$line" >> "$tmp_file"
    done <<< "$existing"
fi
printf '%s\n' "$job" >> "$tmp_file"
crontab "$tmp_file"

printf '已設定 Cloudflare DDNS cron：每 %s 小時執行一次。\n' "$hours"
printf '執行紀錄：%s/ddns-update.log\n' "$SCRIPT_DIR"
