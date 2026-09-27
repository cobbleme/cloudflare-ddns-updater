# Cloudflare DDNS Updater

適用於 Ubuntu 的輕量 Cloudflare DDNS 更新工具。腳本會偵測主機的公網 IP，依照 `config.conf` 建立或更新 Cloudflare DNS 記錄，並可透過 cron 定期執行。

## 功能

- 支援 A、AAAA、TXT 記錄及 `{IPV4}`、`{IPV6}` 內容佔位符。
- 從 `.env` 讀取 Cloudflare API Token 與 Zone ID，不需將憑證寫進腳本。
- 支援 `#` 開頭的註解行，並以逐步訊息輸出執行進度。
- IPv6 無法取得時，略過使用 `{IPV6}` 的規則，其餘規則仍會繼續處理。
- 可互動設定 cron 更新間隔；預設每小時執行。

## 系統需求

- Ubuntu 或其他使用 Bash 的 Linux 發行版
- Bash 4.3 或更新版本
- `curl`、`jq`、`cron`
- 可連線至 Cloudflare API 與 `api.ipify.org` 的網路

## 安裝

```bash
git clone https://github.com/<OWNER>/<REPOSITORY>.git
cd <REPOSITORY>
sudo apt update
sudo apt install -y curl jq cron
chmod +x ddns-update.sh setup-cron.sh
```

將 clone 指令中的 `<OWNER>` 和 `<REPOSITORY>` 換成此 GitHub 專案的擁有者與 repository 名稱。

## Cloudflare API Token

在 Cloudflare 建立 API Token，授予以下權限，並將資源限制在要更新的 Zone：

- `Zone / Zone / Read`
- `Zone / DNS / Edit`

複製範例檔並填入 Token 和 Zone ID：

```bash
cp .env.example .env
nano .env
chmod 600 .env
```

`.env` 格式如下：

```dotenv
CF_API_TOKEN=你的Cloudflare_API_Token
ZONE_ID=你的Cloudflare_Zone_ID
```

Zone ID 可在 Cloudflare 該網域的 Overview 頁面找到。請勿將 `.env` 提交到 GitHub；此 repository 的 `.gitignore` 已忽略 `.env` 與執行日誌。

## DNS 設定

編輯 `config.conf`。每筆記錄由 `Type`、`Name`、`Content_Rule` 組成，筆與筆之間以空行分隔：

```conf
# 網站 IPv4
Type: A
Name: www
Content_Rule: "{IPV4}"

# 網站 IPv6
Type: AAAA
Name: www
Content_Rule: "{IPV6}"

# 根網域 TXT
Type: TXT
Name: @
Content_Rule: "v=spf1 ip4:{IPV4} ip6:{IPV6} mx ~all"
```

設定說明：

- 目前支援 `A`、`AAAA`、`TXT`。
- `Name: @` 代表 Zone 根網域；`Name: www` 會解析為 `www.<Zone>`。也可直接填入完整網域名稱。
- `Content_Rule` 中的 `{IPV4}`、`{IPV6}` 會替換成偵測到的公網 IP。
- 以 `#` 開頭的整行會視為註解並忽略；欄位可加上單引號或雙引號。
- 若目前沒有 IPv6，任何包含 `{IPV6}` 的整筆設定都會略過。例如範例 SPF TXT 規則包含 `{IPV6}`，因此在沒有 IPv6 時不會建立或更新該 TXT 記錄。
- 建立 A/AAAA 記錄時會使用 Cloudflare DNS only（不啟用 Proxy）；更新既有記錄時只修改內容，不改動其 TTL 或 Proxy 設定。

## 手動執行

```bash
./ddns-update.sh
```

腳本會輸出各階段進度，以及每筆 DNS 記錄是已建立、已更新、未變更或略過。若記錄內容已符合目前 IP，會顯示「未變更」，不會重複寫入 Cloudflare。

## 設定定期更新

執行 cron 設定腳本：

```bash
./setup-cron.sh
```

輸入每隔幾小時執行一次，直接按 Enter 使用預設的 1 小時。也可以直接指定間隔，例如：

```bash
./setup-cron.sh 3
```

支援 1 到 24 小時。設定後可用以下指令檢查目前使用者的排程：

```bash
crontab -l
```

cron 執行紀錄會寫入 `ddns-update.log`。重新執行 `setup-cron.sh` 只會替換本工具標記的排程，不會刪除其他 cron 工作。若要移除排程，執行 `crontab -e` 並刪除包含 `cloudflare-ddns-updater-managed` 的那一行。

## 疑難排解

- `HTTP 403: Unauthorized to access requested resource`：確認 Token 有 `Zone / Zone / Read` 和 `Zone / DNS / Edit` 權限，資源範圍包含目標網域，且 `.env` 中的 Zone ID 正確。
- `缺少 jq` 或 `缺少 curl`：執行 `sudo apt install -y curl jq`。
- IPv6 顯示無法取得：若主機或網路沒有可用 IPv6，這是預期訊息；含 `{IPV6}` 的記錄會略過。
- 檢查 `.env` 權限：執行 `chmod 600 .env`。不要在 Issue、Pull Request 或終端輸出中公開 API Token。

## 安全提醒

`.env` 含有可修改 DNS 的憑證，請勿提交、分享或放入公開日誌。如果 Token 曾經公開，請立即在 Cloudflare 撤銷並重新建立。建議只授予必要權限，並將 Token 限制在單一 Zone。
