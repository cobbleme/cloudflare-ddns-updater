#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
CONFIG_FILE="$SCRIPT_DIR/config.conf"
API_BASE="https://api.cloudflare.com/client/v4"
IPV4=""
IPV6=""
ZONE_NAME=""
declare -a RECORD_TYPES=()
declare -a RECORD_NAMES=()
declare -a CONTENT_RULES=()

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

die() {
    log "錯誤：$*" >&2
    exit 1
}

on_exit() {
    local status=$?
    if (( status == 0 )); then
        log "更新流程完成。"
    else
        log "更新流程中止（exit code: $status）。" >&2
    fi
}
trap on_exit EXIT

trim() {
    local value=$1
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

strip_quotes() {
    local value=$1
    if (( ${#value} >= 2 )); then
        if [[ ${value:0:1} == '"' && ${value: -1} == '"' ]] || [[ ${value:0:1} == "'" && ${value: -1} == "'" ]]; then
            value=${value:1:${#value}-2}
        fi
    fi
    printf '%s' "$value"
}

load_env() {
    local line key value
    [[ -f $ENV_FILE ]] || die "找不到 $ENV_FILE，請從 .env.example 複製並填入設定。"

    while IFS= read -r line || [[ -n $line ]]; do
        line=${line%$'\r'}
        line=$(trim "$line")
        [[ -z $line || $line == \#* ]] && continue
        [[ $line == export\ * ]] && line=$(trim "${line#export }")
        [[ $line == *=* ]] || die ".env 格式錯誤：$line"
        key=$(trim "${line%%=*}")
        value=$(strip_quotes "$(trim "${line#*=}")")
        case $key in
            CF_API_TOKEN) CF_API_TOKEN=$value ;;
            ZONE_ID) ZONE_ID=$value ;;
        esac
    done < "$ENV_FILE"

    [[ -n ${CF_API_TOKEN:-} ]] || die ".env 缺少 CF_API_TOKEN。"
    [[ -n ${ZONE_ID:-} ]] || die ".env 缺少 ZONE_ID。"
}

load_config() {
    local line key value
    local -A record=()

    [[ -f $CONFIG_FILE ]] || die "找不到設定檔：$CONFIG_FILE"

    while IFS= read -r line || [[ -n $line ]]; do
        line=${line%$'\r'}
        line=$(trim "$line")
        if [[ -z $line ]]; then
            if (( ${#record[@]} > 0 )); then
                append_record record
                record=()
            fi
            continue
        fi
        [[ $line == \#* ]] && continue
        [[ $line == *:* ]] || die "config.conf 格式錯誤（缺少冒號）：$line"
        key=$(trim "${line%%:*}")
        value=$(strip_quotes "$(trim "${line#*:}")")
        case $key in
            Type|Name|Content_Rule) ;;
            *) die "config.conf 不支援欄位 '$key'。" ;;
        esac
        [[ -z ${record[$key]+set} ]] || die "config.conf 記錄欄位重複：$key"
        record[$key]=$value
    done < "$CONFIG_FILE"
    if (( ${#record[@]} > 0 )); then
        append_record record
    fi
    (( ${#RECORD_TYPES[@]} > 0 )) || die "config.conf 沒有可載入的 DNS 記錄。"
}

append_record() {
    local -n record_ref=$1
    local type=${record_ref[Type]:-}
    local name=${record_ref[Name]:-}
    local rule=${record_ref[Content_Rule]:-}

    [[ -n $type && -n $name && -n $rule ]] || die "config.conf 每筆記錄都必須包含 Type、Name、Content_Rule。"
    case $type in
        A|AAAA|TXT) ;;
        *) die "不支援的 DNS Type：$type（目前支援 A、AAAA、TXT）。" ;;
    esac
    RECORD_TYPES+=("$type")
    RECORD_NAMES+=("$name")
    CONTENT_RULES+=("$rule")
}

api_request() {
    local method=$1 url=$2 payload=${3:-}
    local response status body
    local -a curl_args=(--silent --show-error --max-time 30 -H "Authorization: Bearer $CF_API_TOKEN" -H 'Accept: application/json' -w $'\n%{http_code}')
    if [[ $method == GET ]]; then
        curl_args+=(--get)
    else
        curl_args+=(-X "$method" -H 'Content-Type: application/json' --data "$payload")
    fi

    if ! response=$(curl "${curl_args[@]}" "$url"); then
        die "Cloudflare API 請求失敗（$method $url）。"
    fi
    status=${response##*$'\n'}
    body=${response%$'\n'*}
    if [[ ! $status =~ ^2[0-9][0-9]$ ]]; then
        local detail
        detail=$(jq -r '(.errors // [] | map(.message) | join("; ")) // empty' <<< "$body" 2>/dev/null || true)
        die "Cloudflare API 回應 HTTP $status：${detail:-$body}"
    fi
    if ! jq -e '.success == true' >/dev/null <<< "$body"; then
        local detail
        detail=$(jq -r '(.errors // [] | map(.message) | join("; ")) // empty' <<< "$body" 2>/dev/null || true)
        die "Cloudflare API 回報失敗：${detail:-$body}"
    fi
    printf '%s' "$body"
}

get_zone_name() {
    local response
    response=$(api_request GET "$API_BASE/zones/$ZONE_ID")
    ZONE_NAME=$(jq -r '.result.name // empty' <<< "$response")
    [[ -n $ZONE_NAME ]] || die "無法從 Cloudflare 取得 Zone 名稱，請檢查 ZONE_ID 和 API Token 權限。"
}

get_public_ips() {
    local value
    value=$(curl --silent --show-error --fail --max-time 20 -4 https://api.ipify.org) || die "無法取得公網 IPv4。"
    value=$(trim "$value")
    [[ $value =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "取得的 IPv4 格式無效：$value"
    IPV4=$value

    if value=$(curl --silent --show-error --fail --max-time 20 -6 https://api6.ipify.org 2>/dev/null); then
        value=$(trim "$value")
        if [[ $value == *:* && $value =~ ^[0-9A-Fa-f:]+$ ]]; then
            IPV6=$value
        fi
    fi
}

fqdn_for() {
    local name=$1
    if [[ $name == @ || $name == "$ZONE_NAME" ]]; then
        printf '%s' "$ZONE_NAME"
    elif [[ $name == *."$ZONE_NAME" ]]; then
        printf '%s' "$name"
    else
        printf '%s.%s' "$name" "$ZONE_NAME"
    fi
}

update_record() {
    local type=$1 name=$2 content=$3
    local response id current payload url
    url="$API_BASE/zones/$ZONE_ID/dns_records"
    if ! response=$(curl --silent --show-error --max-time 30 --get \
        -H "Authorization: Bearer $CF_API_TOKEN" -H 'Accept: application/json' \
        --data-urlencode "type=$type" --data-urlencode "name=$name" \
        -w $'\n%{http_code}' "$url"); then
        die "查詢 DNS 記錄失敗：$name ($type)"
    fi
    local status=${response##*$'\n'}
    local body=${response%$'\n'*}
    [[ $status =~ ^2[0-9][0-9]$ ]] || die "查詢 DNS 記錄回應 HTTP $status：$body"
    jq -e '.success == true' >/dev/null <<< "$body" || die "Cloudflare 無法查詢 DNS 記錄：$body"

    id=$(jq -r '.result[0].id // empty' <<< "$body")
    current=$(jq -r '.result[0].content // empty' <<< "$body")
    if [[ -n $id ]]; then
        if [[ $current == "$content" ]]; then
            log "未變更：$type $name ($content)"
            return
        fi
        payload=$(jq -n --arg content "$content" '{content: $content}')
        response=$(api_request PATCH "$url/$id" "$payload")
        log "已更新：$type $name ($content)"
    else
        if [[ $type == TXT ]]; then
            payload=$(jq -n --arg type "$type" --arg name "$name" --arg content "$content" \
                '{type: $type, name: $name, content: $content, ttl: 1}')
        else
            payload=$(jq -n --arg type "$type" --arg name "$name" --arg content "$content" \
                '{type: $type, name: $name, content: $content, ttl: 1, proxied: false}')
        fi
        response=$(api_request POST "$url" "$payload")
        log "已建立：$type $name ($content)"
    fi
}

log "啟動 Cloudflare DDNS updater。"
log "[1/6] 檢查必要工具。"
command -v curl >/dev/null 2>&1 || die "缺少 curl，請先安裝。"
command -v jq >/dev/null 2>&1 || die "缺少 jq，請先安裝。"

log "[2/6] 載入 .env。"
CF_API_TOKEN=""
ZONE_ID=""
load_env

log "[3/6] 載入 config.conf。"
load_config
log "已載入 ${#RECORD_TYPES[@]} 筆 DNS 設定。"

log "[4/6] 取得 Cloudflare Zone 資訊。"
get_zone_name
log "Zone：$ZONE_NAME"

log "[5/6] 偵測公網 IP。"
get_public_ips
log "IPv4：$IPV4"
if [[ -n $IPV6 ]]; then
    log "IPv6：$IPV6"
else
    log "IPv6：目前無法取得，依賴 {IPV6} 的記錄將略過。"
fi

log "[6/6] 更新 DNS 記錄。"
for index in "${!RECORD_TYPES[@]}"; do
    type=${RECORD_TYPES[$index]}
    name=$(fqdn_for "${RECORD_NAMES[$index]}")
    rule=${CONTENT_RULES[$index]}
    if [[ $rule == *'{IPV6}'* && -z $IPV6 ]]; then
        log "略過：$type $name 需要 IPv6，但目前沒有可用的 IPv6。"
        continue
    fi
    content=${rule//\{IPV4\}/$IPV4}
    content=${content//\{IPV6\}/$IPV6}
    update_record "$type" "$name" "$content"
done
