#!/usr/bin/env bash
# Self-steal для Reality рядом с remnanode: отдельный Caddy в Docker
# отдаёт сайт с настоящим сертификатом Let's Encrypt на 127.0.0.1:9443,
# а Xray (remnanode) в realitySettings указывает target на этот порт.
#
#   curl -fsSL https://raw.githubusercontent.com/denny4-user/node-selfsteal/main/selfsteal.sh | bash -s -- cdn.example.com
#   ... | bash -s -- --status
#   ... | bash -s -- --uninstall
set -euo pipefail

DIR=/opt/selfsteal
PORT=9443
DOMAIN=""
SKIP_DNS=0
ACTION=install

c_ok()   { printf '\033[32m✓\033[0m %s\n' "$*"; }
c_warn() { printf '\033[33m!\033[0m %s\n' "$*"; }
die()    { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

usage() {
	cat <<'EOF'
Использование:
  selfsteal.sh <домен> [--port 9443] [--skip-dns-check]   установить или сменить домен
  selfsteal.sh --status                                   состояние и срок сертификата
  selfsteal.sh --uninstall                                удалить Caddy и /opt/selfsteal
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--port) PORT="${2:-}"; shift 2 ;;
		--skip-dns-check) SKIP_DNS=1; shift ;;
		--status) ACTION=status; shift ;;
		--uninstall) ACTION=uninstall; shift ;;
		-h|--help) usage; exit 0 ;;
		-*) usage; die "неизвестный параметр: $1" ;;
		*) DOMAIN="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"; shift ;;
	esac
done

[ "$(id -u)" -eq 0 ] || die "запускайте от root"
command -v docker >/dev/null || die "docker не найден"
if docker compose version >/dev/null 2>&1; then
	COMPOSE=(docker compose)
elif command -v docker-compose >/dev/null; then
	COMPOSE=(docker-compose)
else
	die "нет docker compose"
fi

# кто слушает TCP-порт: пусто, если свободен
port_owner() { ss -ltnpH "sport = :$1" 2>/dev/null | sed -n 's/.*users:(("\([^"]*\)".*/\1/p' | head -1; }

cert_info() {
	echo | openssl s_client -connect "127.0.0.1:$PORT" -servername "$1" 2>/dev/null \
		| openssl x509 -noout -issuer -enddate 2>/dev/null || true
}

if [ "$ACTION" = status ]; then
	[ -f "$DIR/domain" ] || die "self-steal не установлен ($DIR/domain нет)"
	d="$(cat "$DIR/domain")"; PORT="$(cat "$DIR/port" 2>/dev/null || echo "$PORT")"
	echo "домен: $d   порт: 127.0.0.1:$PORT"
	docker ps --filter name=selfsteal-caddy --format 'контейнер: {{.Names}} {{.Status}}'
	cert_info "$d"
	exit 0
fi

if [ "$ACTION" = uninstall ]; then
	if [ -d "$DIR" ]; then
		(cd "$DIR" && "${COMPOSE[@]}" down) || true
		rm -rf "$DIR"
	fi
	c_ok "self-steal удалён. Не забудьте вернуть target в профиле Reality на внешний сайт, иначе нода перестанет принимать подключения."
	exit 0
fi

# ---------- установка ----------
[ -n "$DOMAIN" ] || { usage; die "не указан домен"; }
printf '%s' "$DOMAIN" | grep -Eq '^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$' || die "странный домен: $DOMAIN"
case "$PORT" in ''|*[!0-9]*) die "порт должен быть числом" ;; esac
if printf '%s' "$DOMAIN" | grep -Eq 'vpn|proxy|node|xray|vless|reality|tunnel|marzban|remna'; then
	c_warn "в домене есть слово, по которому ТСПУ ищет VPN (vpn, proxy, node и т.п.); лучше взять нейтральное имя"
fi

# 1. DNS: домен должен указывать на эту машину, иначе Let's Encrypt не выдаст сертификат
MYIP="$(curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null || curl -4 -fsS --max-time 8 https://ifconfig.me 2>/dev/null || true)"
[ -n "$MYIP" ] || die "не удалось узнать внешний IPv4 этой машины"
if [ "$SKIP_DNS" -eq 0 ]; then
	DNSIPS="$(curl -fsS --max-time 8 -H 'accept: application/dns-json' "https://1.1.1.1/dns-query?name=$DOMAIN&type=A" 2>/dev/null \
		| grep -oE '"data":"[0-9.]+"' | cut -d'"' -f4 || true)"
	[ -n "$DNSIPS" ] || DNSIPS="$(getent ahostsv4 "$DOMAIN" | awk '{print $1}' | sort -u || true)"
	[ -n "$DNSIPS" ] || die "у $DOMAIN нет A-записи. Добавьте A $DOMAIN → $MYIP (в Cloudflare — без проксирования, серое облако)"
	printf '%s\n' "$DNSIPS" | grep -qx "$MYIP" \
		|| die "$DOMAIN указывает на ${DNSIPS//$'\n'/ }, а эта машина $MYIP. Поправьте A-запись (или --skip-dns-check)"
	c_ok "DNS: $DOMAIN → $MYIP"
fi

# 2. порты: 80 нужен для выпуска сертификата, $PORT — для сайта на localhost
for p in 80 "$PORT"; do
	owner="$(port_owner "$p")"
	if [ -n "$owner" ] && [ "$owner" != caddy ]; then
		die "порт $p занят процессом «$owner»"
	fi
done
c_ok "порты 80 и $PORT свободны"

if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q 'Status: active'; then
	ufw allow 80/tcp >/dev/null && c_ok "ufw: открыт 80/tcp"
fi

# 3. файлы
mkdir -p "$DIR/html" "$DIR/data" "$DIR/config"
echo "$DOMAIN" > "$DIR/domain"
echo "$PORT" > "$DIR/port"

cat > "$DIR/docker-compose.yml" <<EOF
services:
  caddy:
    image: caddy:2-alpine
    container_name: selfsteal-caddy
    restart: always
    network_mode: host
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - ./html:/srv:ro
      - ./data:/data
      - ./config:/config
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
EOF

cat > "$DIR/Caddyfile" <<EOF
{
	https_port $PORT
	default_bind 127.0.0.1
	auto_https disable_redirects
	servers {
		protocols h1 h2
	}
}

# снаружи открыт только 80: выпуск сертификата и редирект на https
http://$DOMAIN {
	bind 0.0.0.0
	redir https://$DOMAIN{uri} permanent
}

# сайт для Reality: сюда Xray отправляет всех, кто не прошёл проверку
https://$DOMAIN {
	# 443 занят Xray, поэтому TLS-ALPN-проверка не пройдёт: сертификат только через HTTP-01 на 80
	tls {
		issuer acme {
			disable_tlsalpn_challenge
		}
	}
	root * /srv
	file_server
	encode gzip
	header -Server
}

# любой другой SNI
:$PORT {
	tls internal
	respond 204
}
EOF

# нейтральная страница, у каждой ноды своя (чтобы не было одинакового отпечатка)
if [ ! -f "$DIR/html/index.html" ]; then
	TOKEN="$(head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n')"
	YEAR="$(date +%Y)"
	cat > "$DIR/html/index.html" <<EOF
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="build" content="$TOKEN">
<title>$DOMAIN</title>
<style>
body{margin:0;font:16px/1.6 system-ui,-apple-system,Segoe UI,Roboto,sans-serif;color:#1f2933;background:#f5f7fa}
main{max-width:640px;margin:15vh auto;padding:0 24px}
h1{font-size:28px;margin:0 0 8px}
p{color:#52606d}
footer{margin-top:48px;font-size:13px;color:#9aa5b1}
</style>
</head>
<body>
<main>
<h1>Static content delivery</h1>
<p>This host serves static assets for internal applications. There is nothing to browse here.</p>
<footer>&copy; $YEAR $DOMAIN</footer>
</main>
</body>
</html>
EOF
fi
printf 'User-agent: *\nDisallow: /\n' > "$DIR/html/robots.txt"
c_ok "файлы в $DIR"

# 4. запуск
(cd "$DIR" && "${COMPOSE[@]}" pull -q && "${COMPOSE[@]}" up -d --force-recreate) >/dev/null
c_ok "Caddy запущен (selfsteal-caddy)"

# 5. ждём настоящий сертификат: curl без -k пройдёт только с доверенным сертификатом
printf 'жду сертификат Let'"'"'s Encrypt'
ok=0
for _ in $(seq 1 40); do
	if curl -fsS --max-time 5 -o /dev/null --resolve "$DOMAIN:$PORT:127.0.0.1" "https://$DOMAIN:$PORT/" 2>/dev/null; then
		ok=1; break
	fi
	printf '.'; sleep 3
done
echo
if [ "$ok" -ne 1 ]; then
	docker logs --tail 30 selfsteal-caddy 2>&1 | grep -iE 'error|challenge|acme' | tail -10 || true
	die "сертификат не выдан за 2 минуты. Проверьте, что порт 80 открыт снаружи (фаервол хостера) и A-запись верная"
fi
c_ok "сертификат выдан:"
cert_info "$DOMAIN" | sed 's/^/    /'

cat <<EOF

Готово. Что поменять в панели Remnawave:

  профиль этой ноды, inbound → realitySettings:
      "target": "127.0.0.1:$PORT",
      "serverNames": ["$DOMAIN"],
      "xver": 0

  на стороне, которая подключается к этой ноде (хост или outbound):
      SNI / serverName: $DOMAIN

Проверка снаружи (после смены профиля): https://$DOMAIN открывает заглушку с сертификатом Let's Encrypt.
EOF
