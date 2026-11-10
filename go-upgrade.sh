#!/usr/bin/env bash
# ==============================================================================
# STANDALONE POST-INSTALL UPGRADER FOR GO-INSTALLER (3x-ui + Nginx + MyFakeSite)
# Usage:
#   bash go-upgrade.sh                 # Default: Reality Self-Steal on main SNI
#   bash go-upgrade.sh --mode=tls      # Keep legacy TLS on main SNI + add Reality
# ==============================================================================
set -e

MODE="reality"
for arg in "$@"; do
    case $arg in
        --mode=tls) MODE="tls" ;;
        --mode=reality) MODE="reality" ;;
    esac
done

BACKUP_DIR="/root/backup-goupgrade-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"

echo "[1/7] Создание резервной копии в $BACKUP_DIR..."
cp -a /etc/nginx "$BACKUP_DIR/nginx"
cp -a /etc/x-ui/x-ui.db "$BACKUP_DIR/x-ui.db"

rollback() {
    echo "❌ [ОШИБКА] Сбой при настройке! Выполняется откат из $BACKUP_DIR..."
    cp -a "$BACKUP_DIR/x-ui.db" /etc/x-ui/x-ui.db
    rm -rf /etc/nginx
    cp -a "$BACKUP_DIR/nginx" /etc/nginx
    systemctl restart x-ui || true
    systemctl restart nginx || true
    echo "✅ Откат выполнен."
    exit 1
}
trap rollback ERR

echo "[2/7] Проверка зависимостей и модуля Nginx Stream..."
if [ ! -f /usr/lib/nginx/modules/ngx_stream_module.so ]; then
    apt-get update -y && apt-get install -y libnginx-mod-stream python3 sqlite3
fi

if ! grep -q "ngx_stream_module.so" /etc/nginx/nginx.conf && [ ! -f /etc/nginx/modules-enabled/50-mod-stream.conf ]; then
    sed -i '1i load_module /usr/lib/nginx/modules/ngx_stream_module.so;' /etc/nginx/nginx.conf
fi

echo "[3/7] Модернизация базы 3x-ui (TLS 8443 + Reality Self-Steal 8444)..."
read -r DOMAIN CERT_FILE KEY_FILE WEB_PORT WEB_PATH SUB_PORT SUB_PATH PUB_KEY SHORT_ID < <(python3 - << 'PYEOF'
import sqlite3, json, subprocess, secrets, re, os, sys

db_path = "/etc/x-ui/x-ui.db"
conn = sqlite3.connect(db_path)
c = conn.cursor()

c.execute("SELECT key, value FROM settings")
cfg = dict(c.fetchall())

web_port = cfg.get("webPort", "59203")
web_path = cfg.get("webBasePath", "/panel/")
sub_port = cfg.get("subPort", "57054")
sub_path = cfg.get("subPath", "/sub/")

if not web_path.startswith("/"): web_path = "/" + web_path
if not web_path.endswith("/"): web_path += "/"
if not sub_path.startswith("/"): sub_path = "/" + sub_path
if not sub_path.endswith("/"): sub_path += "/"

c.execute("SELECT id, settings, stream_settings, sniffing FROM inbounds WHERE port IN (443, 8443) ORDER BY id ASC LIMIT 1")
row = c.fetchone()
if not row:
    sys.exit("Inbound 443/8443 not found")

inb_id, set_str, str_str, sniff_str = row
settings = json.loads(set_str)
stream = json.loads(str_str)

domain = stream.get("tlsSettings", {}).get("serverName", "")
certs = stream.get("tlsSettings", {}).get("certificates", [{}])
cert_file = certs[0].get("certificateFile", "") if certs else ""
key_file = certs[0].get("keyFile", "") if certs else ""

if not domain and os.path.exists("/etc/nginx/sites-enabled/govless"):
    with open("/etc/nginx/sites-enabled/govless") as f:
        for m in re.finditer(r"server_name\s+([^\s;_]+);", f.read()):
            domain = m.group(1)
            break

if not cert_file or not os.path.exists(cert_file):
    cert_file = f"/etc/letsencrypt/live/{domain}/fullchain.pem"
    key_file = f"/etc/letsencrypt/live/{domain}/privkey.pem"

# Патч инбаунда 8443 (VLESS-TCP-TLS)
stream.setdefault("tlsSettings", {})["alpn"] = ["h2", "http/1.1"]
stream.setdefault("sockopt", {})["acceptProxyProtocol"] = True
stream.setdefault("tcpSettings", {})["acceptProxyProtocol"] = True
settings["fallbacks"] = [{"name": "", "alpn": "", "path": "", "dest": 8080, "xver": 1}]

c.execute(
    "UPDATE inbounds SET listen='127.0.0.1', port=8443, stream_settings=?, settings=? WHERE id=?",
    (json.dumps(stream, indent=2), json.dumps(settings, indent=2), inb_id)
)

# Генерация или обновление инбаунда 8444 (VLESS-Reality Self-Steal)
out = subprocess.check_output(["/usr/local/x-ui/bin/xray-linux-amd64", "x25519"], text=True)
priv_key = pub_key = ""
for line in out.splitlines():
    if "Private" in line: priv_key = line.split(":")[1].strip()
    if "Public" in line or "Password" in line: pub_key = line.split(":")[1].strip()
short_id = secrets.token_hex(4)

r_clients = []
for cl in settings.get("clients", []):
    new_cl = dict(cl)
    new_cl["flow"] = "xtls-rprx-vision"
    base_email = re.sub(r"-reality$", "", cl.get("email", "user"))
    new_cl["email"] = base_email + "-reality"
    r_clients.append(new_cl)

r_settings = {"clients": r_clients, "decryption": "none", "fallbacks": []}
r_stream = {
    "network": "tcp",
    "security": "reality",
    "externalProxy": [{"forceTls": "same", "dest": domain, "port": 443, "remark": ""}],
    "realitySettings": {
        "show": False,
        "xver": 1,
        "dest": "127.0.0.1:9443",
        "serverNames": [domain],
        "privateKey": priv_key,
        "minClient": "",
        "maxClient": "",
        "maxTimediff": 0,
        "shortIds": [short_id],
        "settings": {"publicKey": pub_key, "fingerprint": "chrome", "serverName": "", "spiderX": "/"}
    },
    "tcpSettings": {"acceptProxyProtocol": True, "header": {"type": "none"}}
}

c.execute("DELETE FROM inbounds WHERE port=8444")
c.execute("""INSERT INTO inbounds (user_id, up, down, total, remark, enable, expiry_time, listen, port, protocol, settings, stream_settings, tag, sniffing)
VALUES (1, 0, 0, 0, 'in-443-reality', 1, 0, '127.0.0.1', 8444, 'vless', ?, ?, 'inbound-127.0.0.1:8444', ?)""",
(json.dumps(r_settings, indent=2), json.dumps(r_stream, indent=2), sniff_str))

new_inb_id = c.lastrowid
for cl in r_clients:
    c.execute("DELETE FROM client_traffics WHERE email=?", (cl["email"],))
    c.execute("INSERT INTO client_traffics (inbound_id, enable, email, up, down, expiry_time, total, reset) VALUES (?, ?, ?, 0, 0, ?, ?, 0)",
              (new_inb_id, 1 if cl.get("enable", True) else 0, cl["email"], cl.get("expiryTime", 0), cl.get("totalGB", 0)))

for k, v in [("webListen", "127.0.0.1"), ("subListen", "127.0.0.1"), ("subURI", f"https://{domain}{sub_path}")]:
    c.execute("DELETE FROM settings WHERE key=?", (k,))
    c.execute("INSERT INTO settings (key, value) VALUES (?, ?)", (k, v))

conn.commit()
conn.close()
print(f"{domain} {cert_file} {key_file} {web_port} {web_path} {sub_port} {sub_path} {pub_key} {short_id}")
PYEOF
)

echo "[4/7] Перезапуск 3x-ui..."
systemctl restart x-ui
sleep 2

TARGET_PORT="8444"
if [ "$MODE" = "tls" ]; then
    TARGET_PORT="8443"
fi

echo "[5/7] Конфигурация Nginx Stream (режим: $MODE -> 127.0.0.1:$TARGET_PORT) и виртуального хоста..."
sed -i 's/ssl_protocols TLSv1 TLSv1.1 TLSv1.2 TLSv1.3;/ssl_protocols TLSv1.2 TLSv1.3;/g' /etc/nginx/nginx.conf
sed -i '/# === STREAM ===/,/# === END ===/d' /etc/nginx/nginx.conf

cat << EOF >> /etc/nginx/nginx.conf

# === STREAM ===
stream {
    map \$ssl_preread_server_name \$sni_b {
        $DOMAIN 127.0.0.1:$TARGET_PORT;
        default 127.0.0.1:9443;
    }
    server {
        listen 443 reuseport;
        listen [::]:443 reuseport;
        proxy_pass \$sni_b;
        proxy_protocol on;
        ssl_preread on;
    }
}
# === END ===
EOF

cat << EOF > /etc/nginx/sites-enabled/govless
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    listen 127.0.0.1:9443 ssl default_server proxy_protocol;
    server_name _;
    ssl_reject_handshake on;
    return 444;
}

server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    location ^~ /.well-known/acme-challenge/ { root /var/www/certbot; }
    location / { return 301 https://\$host\$request_uri; }
}

server {
    listen 127.0.0.1:8080 proxy_protocol http2;
    listen 127.0.0.1:9443 ssl http2 proxy_protocol;
    server_name $DOMAIN;

    ssl_certificate $CERT_FILE;
    ssl_certificate_key $KEY_FILE;

    set_real_ip_from 127.0.0.1;
    real_ip_header proxy_protocol;

    root /opt/myfakesite/data;
    index index.html;

    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Permissions-Policy "interest-cohort=()" always;
    add_header Content-Security-Policy "default-src 'self' https: data: blob: 'unsafe-inline' 'unsafe-eval'; img-src 'self' https: data: blob:; media-src 'self' https: data: blob:; worker-src 'self' blob:;" always;

    location ^~ $SUB_PATH {
        proxy_pass https://127.0.0.1:$SUB_PORT;
        proxy_ssl_verify off;
        proxy_ssl_server_name on;
        proxy_ssl_name $DOMAIN;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }

    location ^~ $WEB_PATH {
        proxy_pass https://127.0.0.1:$WEB_PORT;
        proxy_ssl_verify off;
        proxy_ssl_server_name on;
        proxy_ssl_name $DOMAIN;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }

    location / { try_files \$uri \$uri/ /index.html; }
    location = /api/status { default_type application/json; return 200 '{"status":"online","region":"eu-central","load":0.12}'; }
    location = /status.php { default_type application/json; return 200 '{"ok":true}'; }
    location = /api/auth { default_type application/json; return 401 '{"error":"Unauthorized","code":401}'; }
    location = /api/files { default_type application/json; return 403 '{"error":"Forbidden"}'; }
    location = /api/settings { default_type application/json; return 401 '{"error":"Session expired"}'; }
    location ~* \.(jpg|jpeg|png|gif|ico|css|js|svg|woff|woff2|ttf|eot)$ { expires 30d; add_header Cache-Control "public, no-transform"; }
    location ~ /\. { deny all; }
    location = /robots.txt { allow all; log_not_found off; access_log off; }
    location = /favicon.ico { log_not_found off; access_log off; }
    disable_symlinks on from=\$document_root;
}
EOF

nginx -t && systemctl restart nginx

echo "[6/7] Настройка хука Certbot и включение TCP BBR..."
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
printf '#!/bin/sh\nsystemctl reload nginx\nsystemctl restart x-ui\n' > /etc/letsencrypt/renewal-hooks/deploy/reload-vless.sh
chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-vless.sh

if ! grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf; then
    printf "\nnet.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n" >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1 || true
fi

echo "[7/7] Очистка открытых портов в UFW..."
ufw delete allow 22/tcp >/dev/null 2>&1 || true
ufw delete allow "$WEB_PORT" >/dev/null 2>&1 || true
ufw delete allow "$WEB_PORT"/tcp >/dev/null 2>&1 || true
ufw delete allow "$SUB_PORT" >/dev/null 2>&1 || true
ufw delete allow "$SUB_PORT"/tcp >/dev/null 2>&1 || true
ufw reload >/dev/null 2>&1 || true

echo "=================================================================="
echo "✅ АПГРЕЙД УСПЕШНО ЗАВЕРШЕН (Режим: $MODE -> порт $TARGET_PORT)"
echo "------------------------------------------------------------------"
echo "👉 Панель 3x-ui : https://${DOMAIN}${WEB_PATH}"
echo "👉 Подписки     : https://${DOMAIN}${SUB_PATH}<subId>"
echo "👉 Reality Key  : ${PUB_KEY} (ShortID: ${SHORT_ID})"
echo "👉 Бэкап        : ${BACKUP_DIR}"
echo "=================================================================="