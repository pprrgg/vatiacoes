#!/usr/bin/env bash
set -euo pipefail

# ============================================
# Setup stack IoT con ThingsBoard - pkserver
#
#   PostgreSQL  -> base de datos de ThingsBoard (solo red interna)
#   ThingsBoard -> plataforma IoT (web + MQTT de dispositivos)
#   Mosquitto   -> broker MQTT con usuario/contraseña (8883 con TLS hacia fuera)
#   Adminer     -> GUI web de PostgreSQL       (perfil "tools", 127.0.0.1)
#   MQTT Explorer -> GUI web de Mosquitto      (perfil "tools", 127.0.0.1)
#   Node-RED    -> integra/transforma: Mosquitto -> ThingsBoard (Gateway API)
#   Caddy       -> HTTPS en el 443 del servidor (certificado interno o Let's Encrypt)
#   pg-backup   -> copia diaria de PostgreSQL en backups/postgres
#   Homepage    -> portada de los servicios del servidor (LAN, puerto HOMEPAGE_PORT)
#   proman      -> web Astro de este repositorio (compilada y servida con nginx, LAN)
#
# Cambios respecto a la version con network_mode: host:
#  - Red bridge en lugar de network_mode: host. Solo se publican 80/443 (Caddy) y 8883 (MQTT con TLS).
#    Los servicios se hablan por nombre: postgres:5432, thingsboard:8080, thingsboard:1883, mosquitto:1883.
#  - Adminer, MQTT Explorer y el editor de Node-RED solo escuchan en 127.0.0.1 (acceso por túnel SSH).
#  - Adminer y MQTT Explorer pasan al perfil "tools": no arrancan en producción salvo que se pidan.
#  - Versiones fijadas por variable (nada de :latest).
#  - Copias de seguridad diarias de PostgreSQL.
#
# Variables nuevas en .env: NODERED_VERSION, NODERED_CREDENTIAL_SECRET (y el resto de *_VERSION)
# Ya no hacen falta: PG_PORT, TB_INTERNAL_PORT, TB_MQTT_PORT, ADMINER_PORT
#
# Carpeta del stack ($INSTALL_DIR), montada en los contenedores:
#   config/mosquitto/   mosquitto.conf + passwd + certs/ (TLS del 8883, ver mqtt-cert.sh)
#   config/caddy/       Caddyfile
#   config/nodered/     settings.js
#   data/postgres/      base de datos de ThingsBoard
#   data/thingsboard/   datos y logs de ThingsBoard
#   data/nodered/       flujos de Node-RED (flows.json), nodos instalados
#   data/mosquitto/     persistencia MQTT
#   data/caddy/         certificados
#   backups/postgres/   volcados diarios de PostgreSQL (se guardan 7 dias)
#   export/             JSON de ThingsBoard (tenants, clientes, usuarios,
#                       dispositivos, paneles, reglas) y flujos de Node-RED
#                       -> se regenera con ./export.sh
# ============================================

# Web Astro (proman) que se sirve en el stack: el repositorio que contiene este script
PROMAN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Todo el stack vive en esta carpeta del host (config, datos, exportaciones)
INSTALL_DIR="$HOME/iot-tb"
IP="localhost"          # IP wifi: la que usas para administrar (GUIs, Homepage)
SERVE_IP="192.168.1.134"    # IP cableada: el router redirige aqui 80/443 (HTTPS de TB y MQTT)
HOSTNAME_LAN="pkserver"
TZ="Europe/Madrid"

TB_VERSION="4.3.1.6"    # Community Edition (la 4.4.0 de tb-node pide activacion)
# Versiones fijadas de las demas imagenes (nada de :latest)
PG_VERSION="16.15"      # misma version mayor que los datos existentes
MOSQUITTO_VERSION="2.1.2-alpine"
NODERED_VERSION="5.0.8"
CADDY_VERSION="2.11.7"
ADMINER_VERSION="5.5.1"
MQTTX_VERSION="browser-1.0.3"
HOMEPAGE_VERSION="v2.4.0"
DUCKDNS_VERSION="version-d860cc34"

TB_LANG="es_ES"         # idioma de la interfaz para todos los usuarios
BRAND="VatiaCo"      # texto del logo que sustituye al de ThingsBoard
BRAND_WEB="https://VatiaCo.es/"   # icono "home" en la linea del titulo de los paneles
# Colores de la web VatiaCo (proman/src/pages/index.astro, tema oscuro)
COLOR_BG="#17181c"      # fondo de pagina y paneles
COLOR_NAV="#23262f"     # barras superiores y menu lateral
COLOR_ACCENT="#3369ff"  # acento
COLOR_TEXT="#edeef3"    # texto sobre fondo oscuro
# Puertos publicados en el host (el resto solo existe dentro de la red de Docker)
MQTTS_PORT="8883"       # Mosquitto con TLS (LAN e Internet)
NODERED_PORT="1880"     # editor de Node-RED, solo 127.0.0.1
ADMINER_PORT="8081"     # Adminer, solo 127.0.0.1 (perfil tools)
MQTTX_PORT="4000"       # MQTT Explorer, solo 127.0.0.1 (perfil tools)
HOMEPAGE_PORT="3000"    # Homepage (portada de servicios), LAN
PROMAN_PORT="8030"      # web Astro (proman), LAN
# Puertos internos de Mosquitto (no publicados)
MQTT_PORT="1883"        # MQTT sin TLS: Node-RED, MQTT Explorer
MQTT_WS_PORT="9001"     # WebSocket: Caddy lo publica como wss://<dominio>/mqtt

# HTTPS publico opcional: si se rellena, Caddy pide certificado a Let's Encrypt
# (hay que redirigir 80 y 443 TCP en el router). Vacio = solo HTTPS en la LAN.
TB_DOMAIN="VatiaCo.duckdns.org"
DUCKDNS_TOKEN=""        # si se rellena, se arranca un actualizador de DuckDNS
ACME_EMAIL=""

# Credenciales: un mismo usuario/contraseña para todos los servicios
IOT_USER="pk"
IOT_PASSWORD="pk"

# ThingsBoard solo admite emails como usuario
TB_SYSADMIN_PASSWORD="$IOT_PASSWORD"              # sysadmin@thingsboard.org
TB_TENANT_EMAIL="$IOT_USER@$HOSTNAME_LAN.local"   # administrador del tenant (sustituye a tenant@thingsboard.org)
TB_TENANT_PASSWORD="$IOT_PASSWORD"
NODERED_USER="$IOT_USER"
NODERED_PASSWORD="$IOT_PASSWORD"
MQTT_USER="$IOT_USER"
MQTT_PASSWORD="$IOT_PASSWORD"
PG_USER="$IOT_USER"
PG_PASSWORD="$IOT_PASSWORD"

# Dispositivo gateway que crea Node-RED en ThingsBoard
TB_GATEWAY_NAME="Node-RED Gateway"

# Clientes de ThingsBoard. Cada uno tiene su usuario, su dispositivo simulado en
# Node-RED (MQTT -> Mosquitto -> Node-RED -> ThingsBoard) y un panel propio:
# el usuario solo ve ese panel y ese dispositivo.
#   "Cliente|email de login|contraseña|dispositivo|panel|perfil"
#   perfil: ambiente (temperatura/humedad/potencia) | energia (generacion FV/consumo/red)
CLIENTES=(
  "Cliente Demo|cliente@$HOSTNAME_LAN.local|$IOT_PASSWORD|simulador-01|Panel simulador|ambiente"
)

# Comunidad energetica. Los datos de energia de cada socio son los de Datadis (curvas de
# carga y contrato descargados en DATADIS_DIR/<carpeta>); este script los carga en
# ThingsBoard con la suma horaria de la comunidad. Un unico panel estandar (mapa de
# socios + datos): el administrador ve los totales de la comunidad y, pulsando un rayo
# del mapa, los de cada socio; cada socio ve el mismo panel solo con sus datos.
CEC_NOMBRE="Comunidad Energética Churriana"
# Administrador de la comunidad: ve la comunidad y a todos los socios, pero solo en el
# panel de la comunidad (sin menu lateral). El administrador de ThingsBoard es TB_TENANT_EMAIL.
CEC_ADMIN_EMAIL="admin-cec@$HOSTNAME_LAN.local"
CEC_ADMIN_PASSWORD="cec"

# Carpeta con las descargas de Datadis: una subcarpeta por suministro con
# Consumo_*.csv (curva de carga) y Contrato_*.csv (formato de la descarga web)
DATADIS_DIR="$PROMAN_DIR/datadis"

# Socios: "Nombre|email de login|contraseña|carpeta de Datadis|latitud|longitud"
#   email vacio: socio sin usuario (solo lo ve el administrador)
#   carpeta: subcarpeta de DATADIS_DIR con sus datos (energia real de Datadis)
#   latitud/longitud: posicion ficticia de su rayo en el mapa del panel
#   Al quitar un socio de la lista, el script borra su cliente, su usuario y su dispositivo.
SOCIOS=(
  "Ana García|ana@$HOSTNAME_LAN.local|ana|sim_20td_fv_excedentes|36.66520|-4.49830"
  "Luis Moreno|luis@$HOSTNAME_LAN.local|luis|qw0f|36.67020|-4.50190"
  "Carmen Ruiz|carmen@$HOSTNAME_LAN.local|carmen|tb0f|36.66710|-4.49610"
  "Asociación de Vecinos|vecinos@$HOSTNAME_LAN.local|vecinos|sw0f|36.66880|-4.49520"
  "Panadería La Espiga|panaderia@$HOSTNAME_LAN.local|panaderia|sim_30td_hasta50kw|36.66410|-4.49990"
  "Nave Industrial Sur|nave@$HOSTNAME_LAN.local|nave|sim_61td_mas450kw|36.65950|-4.49280"
)
SIM_INTERVAL="5"                      # segundos entre lecturas del simulador de CLIENTES

echo "============================================"
echo " Stack IoT ThingsBoard - pkserver"
echo "============================================"

for cmd in docker curl python3; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: falta $cmd" >&2; exit 1; }
done
docker compose version >/dev/null 2>&1 || { echo "ERROR: falta docker compose" >&2; exit 1; }

# ./iot-thingsboard.sh --reset  -> borra contenedores y DATOS del stack y reinstala
if [ "${1:-}" = "--reset" ]; then
  echo "AVISO: se borraran TODOS los datos del stack (ThingsBoard, Postgres, Node-RED...)."
  read -r -p "Escribe 'borrar' para continuar: " OK
  [ "$OK" = "borrar" ] || { echo "Cancelado."; exit 1; }
  if [ -f "$INSTALL_DIR/docker-compose.yml" ]; then
    (cd "$INSTALL_DIR" && docker compose --profile duckdns --profile tools down -v --remove-orphans)
  fi
  # Los datos pertenecen a los usuarios de los contenedores: se borran con un contenedor.
  # backups/ se conserva a proposito.
  if [ -d "$INSTALL_DIR/data" ]; then
    docker run --rm -v "$INSTALL_DIR:/stack" alpine rm -rf /stack/data /stack/export /stack/config/mosquitto/certs
  fi
  rm -f "$INSTALL_DIR/.tb_installed"
  echo "==> Stack borrado, reinstalando..."
fi

# La IP de servicio tiene que existir en esta maquina
if ! ip -4 -o addr show 2>/dev/null | grep -q " $SERVE_IP/"; then
  echo "AVISO: $SERVE_IP no esta configurada en este equipo; el router no llegara a Caddy." >&2
  echo "       IPs actuales: $(ip -4 -o addr show | awk '$2!="lo"{print $4}' | grep -v '^172\.' | tr '\n' ' ')" >&2
fi

# --------------------------------------------
# 1. Puertos libres en el host (solo los que se publican)
# --------------------------------------------
PROJECT="iot-tb"
# Homepage pasa a este stack: el contenedor "homepage" independiente (homepage.sh,
# ~/Desktop/bb/Homepage) se retira para liberar su puerto. Su carpeta no se toca.
if [ "$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' homepage 2>/dev/null)" = "homepage" ]; then
  echo "==> Retirando el contenedor 'homepage' independiente (lo sustituye iot-homepage)"
  docker rm -f homepage >/dev/null
fi
OCUPADOS=()
for p in 80 443 "$MQTTS_PORT" "$NODERED_PORT" "$HOMEPAGE_PORT" "$PROMAN_PORT"; do
  if ss -ltnH "( sport = :$p )" 2>/dev/null | grep -q .; then
    OCUPADOS+=("$p")
  fi
done
if [ ${#OCUPADOS[@]} -gt 0 ] && ! docker ps -q --filter "label=com.docker.compose.project=$PROJECT" | grep -q .; then
  echo "ERROR: puertos ya en uso en el host: ${OCUPADOS[*]}" >&2
  echo "       Para el servicio que los usa (p.ej. otro stack) o cambia los puertos arriba." >&2
  exit 1
fi

echo "==> Creando estructura en $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"/config/{mosquitto,caddy,nodered,branding,homepage,proman} \
         "$INSTALL_DIR"/data/{postgres,thingsboard,thingsboard-logs,nodered,mosquitto,caddy,caddy-config,mqtt-explorer} \
         "$INSTALL_DIR"/export "$INSTALL_DIR"/backups/postgres
cd "$INSTALL_DIR"

# Propietarios que esperan los contenedores (ThingsBoard uid 799, Node-RED uid 1000)
docker run --rm -v "$INSTALL_DIR/data:/d" alpine sh -c \
  "chown -R 799:799 /d/thingsboard /d/thingsboard-logs && chown -R 1000:1000 /d/nodered"

# MQTT Explorer: conexion "Mosquitto" precargada (se conservan las demas conexiones)
python3 - "$MQTT_PORT" "$MQTT_USER" "$MQTT_PASSWORD" data/mqtt-explorer/settings.json <<'PY'
import json, os, sys
port, user, pw, path = sys.argv[1:]
cfg = json.load(open(path)) if os.path.exists(path) else {}
cfg.setdefault("ConnectionManager_connections", {})["mosquitto"] = {
    "configVersion": 1, "id": "mosquitto", "name": "Mosquitto", "type": "mqtt",
    "protocol": "mqtt", "host": "mosquitto", "port": int(port), "basePath": "",
    "encryption": False, "certValidation": True, "clientId": "mqtt-explorer-web",
    "username": user, "password": pw,
    "subscriptions": [{"topic": "#", "qos": 0}, {"topic": "$SYS/#", "qos": 0}]}
json.dump(cfg, open(path, "w"))
PY

# --------------------------------------------
# 2. .env (variables del compose y credenciales para export.sh)
# --------------------------------------------

PROFILES=""
[ -n "$TB_DOMAIN" ] && [ -n "$DUCKDNS_TOKEN" ] && PROFILES="duckdns"

# Homepage solo responde a los nombres/IPs de esta lista: las configuradas y todas las
# IPv4 que tenga ahora el servidor (por si el DHCP le cambia la IP)
HOMEPAGE_HOSTS=$(for h in "$IP" "$SERVE_IP" "$HOSTNAME_LAN" "$HOSTNAME_LAN.local" localhost 127.0.0.1 \
                   $(ip -4 -o addr show 2>/dev/null | awk '$2!="lo" && $2!~/^(docker|br-|veth)/ {split($4,a,"/"); print a[1]}'); do
                   echo "$h:$HOMEPAGE_PORT"; done | sort -u | paste -sd, -)

# Clave que cifra las credenciales de los flujos de Node-RED: se conserva entre
# ejecuciones (.env o, en instalaciones antiguas, el settings.js con la clave escrita)
NODERED_SECRET=$(grep -s '^NODERED_CREDENTIAL_SECRET=' .env | cut -d= -f2- || true)
[ -n "$NODERED_SECRET" ] || NODERED_SECRET=$(grep -s "credentialSecret" config/nodered/settings.js | sed -n "s/.*credentialSecret: *'\([^']*\)'.*/\1/p" || true)
[ -n "$NODERED_SECRET" ] || NODERED_SECRET=$(openssl rand -hex 16 2>/dev/null || date +%s%N)

cat > .env <<EOF
TZ=$TZ
TB_VERSION=$TB_VERSION
PG_VERSION=$PG_VERSION
MOSQUITTO_VERSION=$MOSQUITTO_VERSION
NODERED_VERSION=$NODERED_VERSION
CADDY_VERSION=$CADDY_VERSION
ADMINER_VERSION=$ADMINER_VERSION
MQTTX_VERSION=$MQTTX_VERSION
HOMEPAGE_VERSION=$HOMEPAGE_VERSION
HOMEPAGE_PORT=$HOMEPAGE_PORT
HOMEPAGE_ALLOWED_HOSTS=$HOMEPAGE_HOSTS
PROMAN_DIR=$PROMAN_DIR
PROMAN_DOCKERFILE=$INSTALL_DIR/config/proman/Dockerfile
PROMAN_PORT=$PROMAN_PORT
DUCKDNS_VERSION=$DUCKDNS_VERSION
MQTTS_PORT=$MQTTS_PORT
NODERED_PORT=$NODERED_PORT
PG_USER=$PG_USER
PG_PASSWORD=$PG_PASSWORD
TB_DOMAIN=$TB_DOMAIN
DUCKDNS_SUBDOMAIN=${TB_DOMAIN%%.duckdns.org}
DUCKDNS_TOKEN=$DUCKDNS_TOKEN
COMPOSE_PROFILES=$PROFILES
NODERED_USER=$NODERED_USER
NODERED_PASSWORD=$NODERED_PASSWORD
NODERED_CREDENTIAL_SECRET=$NODERED_SECRET
TB_SYSADMIN_PASSWORD=$TB_SYSADMIN_PASSWORD
TB_TENANT_EMAIL=$TB_TENANT_EMAIL
TB_TENANT_PASSWORD=$TB_TENANT_PASSWORD
MQTTX_PORT=$MQTTX_PORT
MQTTX_USER=$MQTT_USER
MQTTX_PASSWORD=$MQTT_PASSWORD
EOF
chmod 600 .env

# --------------------------------------------
# 3. Mosquitto (con usuario y contraseña)
# --------------------------------------------
# Usuario/contraseña comunes a los tres listeners (per_listener_settings false)
cat > config/mosquitto/mosquitto.conf <<EOF
# MQTT sin TLS: solo dentro de la red de Docker (Node-RED, MQTT Explorer)
listener $MQTT_PORT

# MQTT con TLS: el unico publicado en el host (LAN e Internet)
listener $MQTTS_PORT
certfile /mosquitto/config/certs/server.crt
keyfile /mosquitto/config/certs/server.key

# MQTT sobre WebSocket: Caddy lo expone con TLS en https://.../mqtt
listener $MQTT_WS_PORT
protocol websockets

allow_anonymous false
password_file /mosquitto/config/passwd
persistence true
persistence_location /mosquitto/data/
log_dest stdout
EOF

docker run --rm -v "$INSTALL_DIR/config/mosquitto:/mosquitto/config" "eclipse-mosquitto:$MOSQUITTO_VERSION" \
  sh -c "rm -f /mosquitto/config/passwd && mosquitto_passwd -b -c /mosquitto/config/passwd '$MQTT_USER' '$MQTT_PASSWORD' && chown mosquitto:mosquitto /mosquitto/config/passwd && chmod 0700 /mosquitto/config/passwd"

# --------------------------------------------
# 4. Node-RED (login del editor)
# --------------------------------------------
NODERED_HASH=$(docker run --rm --entrypoint node "nodered/node-red:$NODERED_VERSION" \
  -e "console.log(require('/usr/src/node-red/node_modules/bcryptjs').hashSync(process.argv[1], 8))" "$NODERED_PASSWORD")

cat > config/nodered/settings.js <<EOF
module.exports = {
    uiPort: 1880,
    flowFile: 'flows.json',
    // La clave llega por entorno desde .env (no se escribe en este fichero)
    credentialSecret: process.env.NODERED_CREDENTIAL_SECRET,
    adminAuth: {
        type: "credentials",
        users: [{ username: "$NODERED_USER", password: "$NODERED_HASH", permissions: "*" }]
    },
    functionExternalModules: true,
    // Contexto en disco: los acumulados del dia de la comunidad sobreviven a reinicios
    contextStorage: { default: { module: "localfilesystem" } },
    logging: { console: { level: "info", metrics: false, audit: false } },
    editorTheme: { projects: { enabled: false } }
};
EOF

# --------------------------------------------
# 5. Caddy (HTTPS en 443 -> ThingsBoard)
# --------------------------------------------
# Marca: logos SVG que sustituyen a los de ThingsBoard (sirve Caddy)
RAYO='<path d="M22 2 8 22h9l-3 16 15-22h-9l2-14z" fill="#ffd54f"/>'
cat > config/branding/logo_title_white.svg <<EOF
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 40" width="200" height="40">
  $RAYO
  <text x="40" y="29" font-family="Roboto, Arial, sans-serif" font-size="24" font-weight="700" fill="#ffffff">$BRAND</text>
</svg>
EOF
cat > config/branding/logo_white.svg <<EOF
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 40 40" width="40" height="40">$RAYO</svg>
EOF
cat > config/branding/favicon.svg <<EOF
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 40 40"><circle cx="20" cy="20" r="20" fill="$COLOR_NAV"/>$RAYO</svg>
EOF

# Tema de toda la interfaz (se inyecta en el index.html de ThingsBoard, ver paso 8)
cat > config/branding/VatiaCo.css <<EOF
/* Tema $BRAND para ThingsBoard: colores de la web VatiaCo */
:root { --vl-bg: $COLOR_BG; --vl-nav: $COLOR_NAV; --vl-accent: $COLOR_ACCENT; --vl-text: $COLOR_TEXT; }
/* Fondo de la aplicacion y de los paneles (sustituye al gris #eee) */
html, body, body.tb-default, mat-sidenav-container.mat-sidenav-container,
.tb-dashboard-page, .tb-dashboard-drawer-container, .tb-dashboard-layouts,
.tb-dashboard-page .mat-content { background-color: var(--vl-bg) !important; }
/* Barras superiores y menu lateral (sustituye al azul #305680) */
mat-toolbar.tb-nav-header-toolbar, mat-toolbar.tb-side-menu-toolbar,
mat-toolbar.tb-primary-toolbar, .mat-fab-toolbar-background { background-color: var(--vl-nav) !important; }
/* Opcion activa del menu lateral */
.tb-side-menu .mat-mdc-button.tb-active, .tb-side-menu a.tb-active { background-color: rgba(51, 105, 255, .25) !important; }
/* Titulos de panel sobre el fondo oscuro */
.tb-dashboard-title, .tb-dashboard-page .tb-dashboard-title { color: var(--vl-text) !important; }
/* Pie "Powered by ThingsBoard" */
section.tb-powered-by-footer { display: none !important; }
/* Rayo (enlace a la web) a la izquierda del titulo de los paneles */
section.tb-dashboard-title { display: flex !important; align-items: center; }
section.tb-dashboard-title .vl-home { order: -1; margin: 0 10px 0 12px; font-size: 30px; line-height: 1;
  text-decoration: none; transition: transform .15s; }
section.tb-dashboard-title .vl-home:hover { transform: scale(1.15); }
/* Impresion / PDF (boton de imprimir de los paneles): sin barras ni botones, sin scroll
   y los widgets uno debajo de otro, A4 apaisado. Va aqui y no en el CSS del panel porque
   ThingsBoard limita ese al interior del panel y no llega a html/body/tb-root. */
@media print {
  @page { size: A4 landscape; margin: 8mm; }
  html, body { -webkit-print-color-adjust: exact; print-color-adjust: exact; background: #fff !important; }
  mat-toolbar, tb-dashboard-toolbar, .tb-dashboard-toolbar, .tb-widget-actions,
  section.tb-powered-by-footer, tb-footer, .tb-footer { display: none !important; }
  html, body, tb-root, tb-dashboard-page, .tb-dashboard-page, .mat-content,
  mat-sidenav-container, mat-drawer-container, .mat-drawer-container, .mat-drawer-content,
  .mat-sidenav-content, .tb-dashboard-container, .tb-absolute-fill, .tb-dashboard-layouts,
  tb-dashboard-layout, tb-dashboard, .tb-dashboard-content, gridster {
    display: block !important; height: auto !important; min-height: 0 !important; max-height: none !important;
    overflow: visible !important; position: static !important;
    width: 100% !important; background: #fff !important; }
  gridster-item { position: relative !important; transform: none !important; left: 0 !important;
    top: 0 !important; width: 100% !important; margin: 0 0 6mm 0 !important;
    break-inside: avoid; page-break-inside: avoid; }
  .tb-dashboard-title, .tb-dashboard-page .tb-dashboard-title { color: #222 !important; }
  .vl-home { display: none !important; }
}
EOF

{
  echo "{"
  echo "	skip_install_trust"
  [ -n "$ACME_EMAIL" ] && echo "	email $ACME_EMAIL"
  echo "}"
  echo
  echo "# HTTPS en la LAN con certificado de la CA interna de Caddy"
  echo "# (el navegador avisara la primera vez; se puede aceptar o instalar la CA)"
  echo "(rutas) {"
  echo "	# MQTT sobre WebSocket (credenciales de Mosquitto): wss://<host>/mqtt"
  echo "	handle /mqtt* {"
  echo "		reverse_proxy mosquitto:$MQTT_WS_PORT"
  echo "	}"
  echo "	# Marca $BRAND en lugar del logo e icono de ThingsBoard (config/branding)"
  for f in logo_title_white.svg logo_white.svg; do
    echo "	handle /assets/$f {"
    echo "		root * /srv/branding"
    echo "		header Cache-Control no-cache"
    echo "		file_server"
    echo "		rewrite * /$f"
    echo "	}"
  done
  echo "	handle /branding/* {"
  echo "		root * /srv"
  echo "		header Cache-Control no-cache"
  echo "		file_server"
  echo "	}"
  echo "	# Paginas de la aplicacion: index.html de ThingsBoard con el tema $BRAND inyectado"
  echo "	@app {"
  echo "		header Accept *text/html*"
  echo "		not path /api/* /assets/* /static/* /branding/* /mqtt* /oauth2/* /login/oauth2/* *.js *.css *.ico *.svg *.png *.json *.woff* *.ttf *.otf *.map"
  echo "		file {"
  echo "			root /srv/branding"
  echo "			try_files /index.html"
  echo "		}"
  echo "	}"
  echo "	handle @app {"
  echo "		root * /srv/branding"
  echo "		rewrite * /index.html"
  echo "		header Cache-Control no-cache"
  echo "		file_server"
  echo "	}"
  echo "	handle /thingsboard.ico {"
  echo "		root * /srv/branding"
  echo "		rewrite * /favicon.svg"
  echo "		header Cache-Control no-cache"
  echo "		file_server"
  echo "	}"
  echo "	# Todo lo demas: ThingsBoard"
  echo "	handle {"
  echo "		encode gzip"
  echo "		reverse_proxy thingsboard:8080"
  echo "	}"
  echo "}"
  echo
  echo "https://$SERVE_IP, https://$IP, https://$HOSTNAME_LAN, https://$HOSTNAME_LAN.local, https://localhost {"
  echo "	tls internal"
  echo "	import rutas"
  echo "}"
  if [ -n "$TB_DOMAIN" ]; then
    echo
    echo "# HTTPS publico con Let's Encrypt (80/443 redirigidos en el router)"
    echo "$TB_DOMAIN {"
    echo "	import rutas"
    echo "}"
  fi
} > config/caddy/Caddyfile

# --------------------------------------------
# 5b. Homepage (portada de servicios): estado de los contenedores por el socket de Docker
# --------------------------------------------
cat > config/homepage/docker.yaml <<EOF
my-docker:
  socket: /var/run/docker.sock
EOF
cat > config/homepage/settings.yaml <<EOF
title: $HOSTNAME_LAN
headerStyle: clean
EOF
CEC_SOCIOS_TXT=$(for s_ in "${SOCIOS[@]}"; do IFS='|' read -r n e pw rest <<< "$s_"; [ -n "$e" ] && printf '%s / %s · ' "$e" "$pw"; done)
cat > config/homepage/services.yaml <<EOF
- IoT ThingsBoard:
    - ThingsBoard (Internet):
        href: https://$TB_DOMAIN
        description: "Acceso público HTTPS (Let's Encrypt)"
        icon: thingsboard

    - ThingsBoard:
        href: https://$IP
        description: "$TB_TENANT_EMAIL / $TB_TENANT_PASSWORD (admin ThingsBoard) · sysadmin@thingsboard.org / $TB_SYSADMIN_PASSWORD · HTTPS 443"
        icon: thingsboard
        server: my-docker
        container: iot-thingsboard

    - $CEC_NOMBRE:
        href: https://$IP
        description: "$CEC_ADMIN_EMAIL / $CEC_ADMIN_PASSWORD (admin comunidad) · socios: ${CEC_SOCIOS_TXT% · }"
        icon: mdi-lightning-bolt
        server: my-docker
        container: iot-thingsboard

    - Node-RED:
        href: http://localhost:$NODERED_PORT
        description: "$NODERED_USER / $NODERED_PASSWORD · solo 127.0.0.1 (túnel SSH)"
        icon: node-red
        server: my-docker
        container: iot-nodered

    - Mosquitto:
        description: "$MQTT_USER / $MQTT_PASSWORD · mqtts://${TB_DOMAIN:-$IP}:$MQTTS_PORT · wss://${TB_DOMAIN:-$IP}/mqtt"
        icon: mosquitto
        server: my-docker
        container: iot-mosquitto

    - PostgreSQL:
        description: "$PG_USER / $PG_PASSWORD · solo red interna (postgres:5432)"
        icon: postgres
        server: my-docker
        container: iot-postgres

    - Copias PostgreSQL:
        description: "Diarias a las 03:00 en $INSTALL_DIR/backups/postgres (7 días)"
        icon: postgres
        server: my-docker
        container: iot-pg-backup

    - Caddy:
        href: https://$IP
        description: "HTTPS 443 -> ThingsBoard · wss /mqtt -> Mosquitto"
        icon: caddy
        server: my-docker
        container: iot-caddy

    - MQTT Explorer:
        href: http://localhost:$MQTTX_PORT
        description: "GUI de Mosquitto · $MQTT_USER / $MQTT_PASSWORD · perfil tools (./tools.sh up), solo 127.0.0.1"
        icon: mdi-access-point-network
        server: my-docker
        container: iot-mqtt-explorer

    - Adminer:
        href: http://localhost:8081/?pgsql=postgres&username=$PG_USER&db=thingsboard
        description: "GUI de PostgreSQL · $PG_USER / $PG_PASSWORD · perfil tools (./tools.sh up), solo 127.0.0.1"
        icon: adminer
        server: my-docker
        container: iot-adminer

- Multimedia:
    - Jellyfin:
        href: http://$IP:8096
        description: "pk / pk / Puerto 8096"
        icon: jellyfin
        server: my-docker
        container: jellyfin

- Inteligencia Artificial:
    - Open WebUI:
        href: http://$IP:3001
        description: "admin@ia.local / pppkkkpppkkk / Puerto 3001"
        icon: open-webui
        server: my-docker
        container: ia-webui

    - IA API (FastAPI):
        href: http://$IP:8010/docs
        description: "Sin autenticacion / Puerto 8010"
        icon: fastapi
        server: my-docker
        container: ia-api

    - Ollama:
        href: http://$IP:11434
        description: "Sin autenticacion / Puerto 11434"
        icon: ollama
        server: my-docker
        container: ia-ollama

- Automatizacion:
    - n8n:
        href: http://$IP:5678
        description: "admin@pkserver.local / pppkkkpppkkkA1@ / Puerto 5678"
        icon: n8n
        server: my-docker
        container: n8n

    - Typst API:
        href: http://$IP:8020/
        description: "Editor web, sin autenticacion / Puerto 8020"
        icon: fastapi
        server: my-docker
        container: typst-api

- Web:
    - VatiaCo (proman):
        href: http://$IP:$PROMAN_PORT
        description: "Web Astro de $PROMAN_DIR · sin autenticación · puerto $PROMAN_PORT · recompilar: $INSTALL_DIR/web.sh"
        icon: astro
        server: my-docker
        container: iot-proman

- Administracion:
    - Portainer:
        href: https://$IP:9443
        description: "admin / pppkkkpppkkk / Puerto 9443 (HTTPS)"
        icon: portainer
        server: my-docker
        container: portainer
EOF

# --------------------------------------------
# 5c. Web Astro (proman): se compila desde PROMAN_DIR y se sirve con nginx
# --------------------------------------------
# La carpeta del proyecto no se modifica: solo es el contexto de build (lectura).
# El Dockerfile, su .dockerignore y la config de nginx viven en config/proman.
cat > config/proman/Dockerfile <<'EOF'
FROM node:20.19-alpine AS build
# ffprobe lo usa scripts/generate-video-manifest.mjs (prebuild)
RUN apk add --no-cache ffmpeg bash
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY . .
RUN npm run build

FROM nginx:1.27-alpine
COPY --from=build /app/dist /usr/share/nginx/html
EOF

# Ignore propio del Dockerfile (BuildKit lo busca junto a el): no se toca el proyecto
cat > config/proman/Dockerfile.dockerignore <<'EOF'
node_modules
dist
.astro
.git
.claude
.env
.env.*
zz
py
sh
sh-local
EOF

cat > config/proman/nginx.conf <<'EOF'
server {
    listen 80;
    server_name _;
    root /usr/share/nginx/html;
    index index.html;

    gzip on;
    gzip_types text/css application/javascript application/json image/svg+xml text/plain;

    location / {
        try_files $uri $uri/ $uri.html =404;
    }

    # El service worker no debe quedarse en cache
    location = /sw.js {
        add_header Cache-Control "no-cache";
    }

    location /_astro/ {
        add_header Cache-Control "public, max-age=31536000, immutable";
    }
}
EOF

# --------------------------------------------
# 6. docker-compose.yml (red bridge; datos en carpetas de $INSTALL_DIR)
# --------------------------------------------
# Solo se publican en el host 80/443 (Caddy) y 8883 (Mosquitto con TLS).
# Las herramientas de administracion escuchan en 127.0.0.1: se usan por tunel SSH.
cat > docker-compose.yml <<'EOF'
name: iot-tb

x-common: &common
  restart: unless-stopped
  logging:
    driver: json-file
    options: { max-size: "50m", max-file: "3" }

services:

  postgres:
    <<: *common
    image: postgres:${PG_VERSION}
    container_name: iot-postgres
    environment:
      POSTGRES_DB: thingsboard
      POSTGRES_USER: ${PG_USER}
      POSTGRES_PASSWORD: ${PG_PASSWORD}
      TZ: ${TZ}
    volumes:
      - ./data/postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${PG_USER} -d thingsboard"]
      interval: 5s
      timeout: 5s
      retries: 30

  # Copia diaria (pg_dump -Fc) en backups/postgres: una al arrancar y otra cada dia
  # a las 03:00; se borran las de mas de 7 dias.
  # Restaurar: docker compose exec -T postgres pg_restore -U <usuario> -d thingsboard --clean < fichero.dump
  pg-backup:
    <<: *common
    image: postgres:${PG_VERSION}
    container_name: iot-pg-backup
    environment:
      PGHOST: postgres
      PGUSER: ${PG_USER}
      PGPASSWORD: ${PG_PASSWORD}
      PGDATABASE: thingsboard
      TZ: ${TZ}
    volumes:
      - ./backups/postgres:/backups
    entrypoint: ["bash", "-c"]
    command:
      - |
        while true; do
          f=/backups/thingsboard-$$(date +%F).dump
          if pg_dump -Fc -f "$$f.tmp"; then mv "$$f.tmp" "$$f"; echo "copia: $$f"
          else rm -f "$$f.tmp"; echo "ERROR: fallo la copia de PostgreSQL" >&2; fi
          find /backups -name 'thingsboard-*.dump' -mtime +7 -delete
          t=$$(date -d 03:00 +%s); [ "$$t" -gt "$$(date +%s)" ] || t=$$((t + 86400))
          sleep $$((t - $$(date +%s)))
        done
    depends_on:
      postgres:
        condition: service_healthy

  thingsboard:
    <<: *common
    image: thingsboard/tb-node:${TB_VERSION}
    container_name: iot-thingsboard
    environment:
      TZ: ${TZ}
      TB_SERVICE_ID: tb-ce-node
      TB_QUEUE_TYPE: in-memory
      SPRING_DATASOURCE_URL: jdbc:postgresql://postgres:5432/thingsboard
      SPRING_DATASOURCE_USERNAME: ${PG_USER}
      SPRING_DATASOURCE_PASSWORD: ${PG_PASSWORD}
      # Web en thingsboard:8080 y MQTT en thingsboard:1883 (sin publicar: entra por Caddy y Node-RED)
      COAP_ENABLED: "false"
      LWM2M_ENABLED: "false"
      SNMP_ENABLED: "false"
      EDGES_ENABLED: "false"
      JAVA_OPTS: "-Xms512M -Xmx2048M"
    volumes:
      - ./data/thingsboard:/data
      - ./data/thingsboard-logs:/var/log/thingsboard
    depends_on:
      postgres:
        condition: service_healthy

  mosquitto:
    <<: *common
    image: eclipse-mosquitto:${MOSQUITTO_VERSION}
    container_name: iot-mosquitto
    ports:
      - "${MQTTS_PORT}:${MQTTS_PORT}"
    volumes:
      - ./config/mosquitto:/mosquitto/config
      - ./data/mosquitto:/mosquitto/data

  node-red:
    <<: *common
    image: nodered/node-red:${NODERED_VERSION}
    container_name: iot-nodered
    ports:
      - "127.0.0.1:${NODERED_PORT}:1880"
    environment:
      TZ: ${TZ}
      NODERED_CREDENTIAL_SECRET: ${NODERED_CREDENTIAL_SECRET}
    volumes:
      - ./data/nodered:/data
      - ./config/nodered/settings.js:/data/settings.js:ro
    depends_on:
      - mosquitto
      - thingsboard

  caddy:
    <<: *common
    image: caddy:${CADDY_VERSION}
    container_name: iot-caddy
    ports:
      - "80:80"
      - "443:443"
      - "443:443/udp"
    volumes:
      - ./config/caddy/Caddyfile:/etc/caddy/Caddyfile:ro
      - ./config/branding:/srv/branding:ro
      - ./data/caddy:/data
      - ./data/caddy-config:/config
    depends_on:
      - thingsboard

  # GUI web de PostgreSQL (perfil tools; servidor "postgres", usuario/contraseña de Postgres)
  adminer:
    <<: *common
    profiles: ["tools"]
    image: adminer:${ADMINER_VERSION}
    container_name: iot-adminer
    ports:
      - "127.0.0.1:8081:8080"
    environment:
      ADMINER_DEFAULT_SERVER: postgres
    depends_on:
      - postgres

  # GUI web de Mosquitto (perfil tools); acceso protegido con usuario/contraseña
  mqtt-explorer:
    <<: *common
    profiles: ["tools"]
    image: smeagolworms4/mqtt-explorer:${MQTTX_VERSION}
    container_name: iot-mqtt-explorer
    ports:
      - "127.0.0.1:${MQTTX_PORT}:${MQTTX_PORT}"
    environment:
      HTTP_PORT: ${MQTTX_PORT}
      HTTP_USER: ${MQTTX_USER}
      HTTP_PASSWORD: ${MQTTX_PASSWORD}
    volumes:
      - ./data/mqtt-explorer:/mqtt-explorer/config
    depends_on:
      - mosquitto

  # Portada de los servicios del servidor (config/homepage, la genera iot-thingsboard.sh).
  # Lee el socket de Docker (solo lectura) para mostrar el estado de cada contenedor.
  homepage:
    <<: *common
    image: ghcr.io/gethomepage/homepage:${HOMEPAGE_VERSION}
    container_name: iot-homepage
    ports:
      - "${HOMEPAGE_PORT}:3000"
    environment:
      HOMEPAGE_ALLOWED_HOSTS: ${HOMEPAGE_ALLOWED_HOSTS}
    volumes:
      - ./config/homepage:/app/config
      - /var/run/docker.sock:/var/run/docker.sock:ro

  # Web Astro del repositorio (PROMAN_DIR): build con Node y nginx. Se reconstruye en
  # cada ejecucion de iot-thingsboard.sh o con ./web.sh
  proman:
    <<: *common
    build:
      context: ${PROMAN_DIR}
      dockerfile: ${PROMAN_DOCKERFILE}
    image: iot-proman:local
    container_name: iot-proman
    ports:
      - "${PROMAN_PORT}:80"
    volumes:
      - ./config/proman/nginx.conf:/etc/nginx/conf.d/default.conf:ro

  # Solo se arranca si hay TB_DOMAIN y DUCKDNS_TOKEN (COMPOSE_PROFILES=duckdns)
  duckdns:
    <<: *common
    profiles: ["duckdns"]
    image: lscr.io/linuxserver/duckdns:${DUCKDNS_VERSION}
    container_name: iot-duckdns
    environment:
      SUBDOMAINS: ${DUCKDNS_SUBDOMAIN}
      TOKEN: ${DUCKDNS_TOKEN}
      TZ: ${TZ}
      LOG_FILE: "false"
EOF

# --------------------------------------------
# 7. Scripts de gestion
# --------------------------------------------
cat > start.sh <<'EOF'
#!/bin/bash
set -e
cd "$(dirname "$0")"
docker compose up -d
EOF
cat > stop.sh <<'EOF'
#!/bin/bash
cd "$(dirname "$0")"
docker compose down
EOF
cat > logs.sh <<'EOF'
#!/bin/bash
cd "$(dirname "$0")"
docker compose logs -f --tail=100 "$@"
EOF
# Herramientas (perfil tools): ./tools.sh up | ./tools.sh down
cat > tools.sh <<'EOF'
#!/bin/bash
# Adminer (127.0.0.1:8081) y MQTT Explorer (127.0.0.1:MQTTX_PORT). Desde otro equipo:
#   ssh -L 8081:127.0.0.1:8081 -L 4000:127.0.0.1:4000 -L 1880:127.0.0.1:1880 <usuario>@<servidor>
set -e
cd "$(dirname "$0")"
case "${1:-up}" in
  up)   docker compose --profile tools up -d adminer mqtt-explorer ;;
  down) docker compose --profile tools rm -sf adminer mqtt-explorer ;;
  *)    echo "uso: $0 [up|down]" >&2; exit 1 ;;
esac
EOF
# Recompila y publica solo la web Astro (tras cambiar el proyecto): ./web.sh
cat > web.sh <<'EOF'
#!/bin/bash
set -e
cd "$(dirname "$0")"
docker compose up -d --build proman
EOF
chmod +x start.sh stop.sh logs.sh tools.sh web.sh

# Certificado TLS de Mosquitto (8883): el de Let's Encrypt que obtiene Caddy para
# TB_DOMAIN o, mientras no exista, uno autofirmado. Lo ejecuta cron cada semana.
cat > mqtt-cert.sh <<'EOF'
#!/bin/bash
set -e
cd "$(dirname "$0")"
set -a; source .env; set +a
# Los certificados de Caddy son de root: se copian con un contenedor
CAMBIO=$(docker run --rm -v "$PWD:/stack" -e D="$TB_DOMAIN" alpine sh -c '
  set -e; cd /stack; C=config/mosquitto/certs; mkdir -p $C
  L="data/caddy/caddy/certificates/acme-v02.api.letsencrypt.org-directory/$D"
  if [ -n "$D" ] && [ -f "$L/$D.crt" ]; then
    if ! cmp -s "$L/$D.crt" $C/server.crt; then
      cp "$L/$D.crt" $C/server.crt; cp "$L/$D.key" $C/server.key; echo letsencrypt
    fi
  elif [ ! -f $C/server.crt ]; then
    apk add -q --no-cache openssl >/dev/null
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=${D:-localhost}" \
      -keyout $C/server.key -out $C/server.crt 2>/dev/null
    echo autofirmado
  fi
  chown -R 1883:1883 $C; chmod 600 $C/server.key')
if [ -n "$CAMBIO" ]; then
  echo "    certificado MQTT (8883): $CAMBIO"
  if [ -n "$(docker compose ps -q mosquitto)" ]; then docker compose restart mosquitto >/dev/null; fi
fi
EOF
chmod +x mqtt-cert.sh

# Exportacion a JSON de lo que hay en ThingsBoard y Node-RED (./export.sh)
cat > export.sh <<'EOF'
#!/bin/bash
# Vuelca a export/ tenants, clientes, usuarios, dispositivos, perfiles,
# paneles y cadenas de reglas de ThingsBoard, y los flujos de Node-RED.
set -e
cd "$(dirname "$0")"
set -a; source .env; set +a
python3 export.py
EOF
chmod +x export.sh

cat > export.py <<'EOF'
import json, os, re, shutil, ssl, urllib.request
from pathlib import Path

E = os.environ
# ThingsBoard solo es accesible a traves de Caddy (certificado interno en localhost)
TB = "https://localhost"
NR = f"http://127.0.0.1:{E['NODERED_PORT']}"
CTX = ssl._create_unverified_context()
OUT = Path(__file__).parent / "export"


def call(method, url, body=None, token=None, nr=False):
    h = {"Content-Type": "application/json"}
    if token:
        h["Authorization" if nr else "X-Authorization"] = "Bearer " + token
    req = urllib.request.Request(url, json.dumps(body).encode() if body else None, h, method=method)
    with urllib.request.urlopen(req, timeout=30, context=CTX) as r:
        return json.loads(r.read() or "null")


def login(user, pw):
    return call("POST", TB + "/api/auth/login", {"username": user, "password": pw})["token"]


def pages(path, tok):
    out, page = [], 0
    while True:
        sep = "&" if "?" in path else "?"
        d = call("GET", f"{TB}{path}{sep}pageSize=500&page={page}", token=tok)
        out += d["data"]
        if not d.get("hasNext"):
            return out
        page += 1


def save(rel, data):
    f = OUT / rel
    f.parent.mkdir(parents=True, exist_ok=True)
    f.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")


def slug(text):
    return re.sub(r"[^A-Za-z0-9._-]+", "_", text).strip("_") or "sin_nombre"


if OUT.exists():
    shutil.rmtree(OUT)
OUT.mkdir()

sa = login("sysadmin@thingsboard.org", E["TB_SYSADMIN_PASSWORD"])
tenants = pages("/api/tenants", sa)
save("thingsboard/tenants.json", tenants)
admins = []
for t in tenants:
    admins += pages(f"/api/tenant/{t['id']['id']}/users", sa)
save("thingsboard/tenant-admins.json", admins)

tk = login(E["TB_TENANT_EMAIL"], E["TB_TENANT_PASSWORD"])
customers = pages("/api/customers", tk)
save("thingsboard/customers.json", customers)
users = []
for c in customers:
    users += pages(f"/api/customer/{c['id']['id']}/users", tk)
save("thingsboard/customer-users.json", users)

devices = pages("/api/tenant/deviceInfos", tk)
for d in devices:
    d["credentials"] = call("GET", f"{TB}/api/device/{d['id']['id']}/credentials", token=tk)
save("thingsboard/devices.json", devices)
save("thingsboard/device-profiles.json", pages("/api/deviceProfiles", tk))

for d in pages("/api/tenant/dashboards", tk):
    full = call("GET", f"{TB}/api/dashboard/{d['id']['id']}", token=tk)
    save(f"thingsboard/dashboards/{slug(d['title'])}.json", full)

for rc in pages("/api/ruleChains", tk):
    meta = call("GET", f"{TB}/api/ruleChain/{rc['id']['id']}/metadata", token=tk)
    save(f"thingsboard/rule-chains/{slug(rc['name'])}.json", {"ruleChain": rc, "metadata": meta})

nr = call("POST", NR + "/auth/token", {"client_id": "node-red-admin", "grant_type": "password",
                                       "scope": "*", "username": E["NODERED_USER"],
                                       "password": E["NODERED_PASSWORD"]})["access_token"]
save("nodered/flows.json", call("GET", NR + "/flows", token=nr, nr=True))

n = sum(1 for _ in OUT.rglob("*.json"))
print(f"    {n} ficheros exportados en {OUT}")
EOF

# --------------------------------------------
# 8. Base de datos + instalacion inicial de ThingsBoard (solo la primera vez)
# --------------------------------------------
echo "==> Descargando imagenes..."
docker compose pull -q --ignore-buildable
echo "==> Compilando la web Astro (proman) desde $PROMAN_DIR..."
docker compose build -q proman

# Mosquitto no arranca el listener TLS sin certificado: se crea antes de levantarlo
./mqtt-cert.sh

echo "==> Arrancando PostgreSQL..."
docker compose up -d --wait postgres

# Exigir contraseña tambien en conexiones por socket local dentro del contenedor
# ("trust" es el valor por defecto de la imagen)
docker compose exec -T -u postgres postgres sh -c '
  if grep -qE "[[:space:]]trust[[:space:]]*$" "$PGDATA/pg_hba.conf"; then
    sed -i -E "s/[[:space:]]trust[[:space:]]*$/ scram-sha-256/" "$PGDATA/pg_hba.conf"
    pg_ctl reload -D "$PGDATA" >/dev/null && echo "    PostgreSQL: autenticacion local con contraseña"
  fi'

# .tb_installed guarda la version con la que se creo la base de datos
INSTALADA=$(cat .tb_installed 2>/dev/null || true)
if [ ! -f .tb_installed ]; then
  # El instalador usa la misma base de datos: no puede haber otro ThingsBoard corriendo
  docker compose rm -sf thingsboard >/dev/null 2>&1 || true
  echo "==> Instalando esquema de ThingsBoard $TB_VERSION (unos minutos, solo la primera vez)..."
  docker compose run --rm --no-deps -e INSTALL_TB=true -e LOAD_DEMO=true thingsboard
  echo "$TB_VERSION" > .tb_installed
elif [ -n "$INSTALADA" ] && [ "$INSTALADA" != "$TB_VERSION" ]; then
  echo "ERROR: la base de datos es de ThingsBoard $INSTALADA y el script usa $TB_VERSION." >&2
  echo "       No se puede cambiar de version sobre los mismos datos sin migrarlos." >&2
  echo "       Para empezar de cero:  $0 --reset" >&2
  exit 1
fi

echo "==> Arrancando el resto del stack..."
docker compose up -d
# Herramientas (perfil tools): no arrancan solas, pero si ya existen se recrean con la
# configuracion actual (si no, se quedarian con la red, puertos o version anteriores)
if docker ps -aq --filter name='^iot-(adminer|mqtt-explorer)$' | grep -q .; then
  echo "==> Actualizando herramientas (Adminer, MQTT Explorer)"
  docker compose --profile tools up -d adminer mqtt-explorer
fi
# Mosquitto y Caddy leen ficheros montados: reinicio para aplicar cambios de config
docker compose restart mosquitto caddy >/dev/null

# Espera a ThingsBoard mostrando progreso; si el contenedor se para, enseña sus logs
# (ThingsBoard ya no publica puertos: se comprueba a traves de Caddy)
echo "==> Esperando a ThingsBoard en https://localhost (1-3 minutos)..."
INICIO=$(date +%s)
until curl -skf -o /dev/null "https://localhost/login"; do
  ESTADO=$(docker inspect -f '{{.State.Status}} {{.State.Restarting}}' iot-thingsboard 2>/dev/null || echo "missing")
  T=$(( $(date +%s) - INICIO ))
  if [[ "$ESTADO" != "running false" ]] || [ "$T" -ge 600 ]; then
    echo
    echo "ERROR: ThingsBoard no arranca (estado: $ESTADO, ${T}s). Ultimas lineas del log:" >&2
    docker logs --tail 60 iot-thingsboard 2>&1 | sed 's/^/    /' >&2
    echo >&2
    echo "Estado de los contenedores:" >&2
    docker compose ps -a >&2
    exit 1
  fi
  printf '\r    %3ss  (estado: %s)  ultima linea: %.90s' "$T" "${ESTADO% *}" \
    "$(docker logs --tail 1 iot-thingsboard 2>&1 | tr -d '\r')"
  sleep 5
done
echo
echo "    ThingsBoard responde ($(( $(date +%s) - INICIO ))s)"

# index.html de ThingsBoard con el tema y el titulo de la marca (lo sirve Caddy).
# Se regenera en cada ejecucion: cambia con cada version de ThingsBoard.
# El original se pide desde el contenedor de Caddy, que ve thingsboard:8080 en la red interna.
if docker compose exec -T caddy wget -qO- http://thingsboard:8080/ > config/branding/index.orig.html 2>/dev/null \
   && [ -s config/branding/index.orig.html ]; then
  python3 - "$BRAND" "$COLOR_BG" config/branding/index.orig.html "$BRAND_WEB" "$TB_LANG" > config/branding/index.html <<'PY'
import json, sys
brand, bg, orig, web, lang = sys.argv[1:]
html = open(orig, encoding="utf-8").read()
html = html.replace("<title>ThingsBoard</title>", f"<title>{brand}</title>")
html = html.replace("background-color: #eee;", f"background-color: {bg};")
# La aplicacion pone titulos como "ThingsBoard | Inicio": se sustituye la marca al vuelo
titulo = ("<script>(function(){var B=" + repr(brand) + ";var t=document.querySelector('title');"
          "function f(){if(document.title.indexOf('ThingsBoard')>=0)"
          "document.title=document.title.replace(/ThingsBoard/g,B);}"
          "new MutationObserver(f).observe(t,{childList:true,characterData:true,subtree:true});f();})();"
          "</script>")
# Rayo a la izquierda del titulo de cada panel, enlazado a la web (nueva pestaña),
# y el logo (login y menu lateral) enlazado tambien a la web en lugar de a thingsboard.io
home = ("<script>(function(){var U=" + repr(web) + ";"
        "function f(){document.querySelectorAll('tb-logo a').forEach(function(a){"
        "if(a.getAttribute('href')!==U){a.href=U;a.target='_blank';a.rel='noopener';a.title=U;}});"
        "document.querySelectorAll('section.tb-dashboard-title').forEach(function(s){"
        "if(s.querySelector('.vl-home'))return;var a=document.createElement('a');a.className='vl-home';"
        "a.href=U;a.target='_blank';a.rel='noopener';a.title=U;"
        "a.textContent='\u26a1';s.insertBefore(a,s.firstChild);});}"
        "new MutationObserver(f).observe(document.documentElement,{childList:true,subtree:true});})();"
        "</script>")
# Idioma antes de iniciar sesion (login, recuperar contraseña): ThingsBoard lo toma del
# navegador; se le presenta TB_LANG para que salga traducido aunque el navegador este en
# otro idioma. Tras entrar manda el idioma de cada usuario (additionalInfo.lang).
bcp = lang.replace("_", "-")
idioma = ("<script>(function(){var L=" + repr([bcp, bcp.split("-")[0]]) + ";try{"
          "Object.defineProperty(navigator,'languages',{get:function(){return L;}});"
          "Object.defineProperty(navigator,'language',{get:function(){return L[0];}});"
          "}catch(e){}})();</script>")
# Mensajes de error del inicio de sesion: los manda el servidor siempre en ingles
ERRORES = {"Invalid username or password": "Usuario o contraseña incorrectos",
           "Authentication failed": "Error de autenticación",
           "User account is not active": "La cuenta de usuario no está activa",
           "User is not active": "La cuenta de usuario no está activa",
           "User account is locked due to security policy": "Cuenta bloqueada por la política de seguridad",
           "User password expired!": "La contraseña ha caducado",
           "Token has expired": "La sesión ha caducado"}
if lang.lower().startswith("es"):
    idioma += ("<script>(function(){var T=" + json.dumps(ERRORES, ensure_ascii=False) + ";"
               "function f(){document.querySelectorAll('.mat-mdc-snack-bar-container,tb-snack-bar-component,.toast-panel')"
               ".forEach(function(c){var w=document.createTreeWalker(c,NodeFilter.SHOW_TEXT),n;"
               "while((n=w.nextNode())){var k=n.nodeValue.trim();if(T[k])n.nodeValue=n.nodeValue.replace(k,T[k]);}});}"
               "new MutationObserver(f).observe(document.documentElement,{childList:true,subtree:true,characterData:true});})();"
               "</script>")
html = html.replace("<head>", "<head>\n  " + idioma, 1)
html = html.replace("</head>", '  <link rel="stylesheet" href="/branding/VatiaCo.css"/>\n  '
                    + titulo + "\n  " + home + "\n</head>", 1)
sys.stdout.write(html)
PY
  rm -f config/branding/index.orig.html
  if grep -q VatiaCo.css config/branding/index.html; then
    echo "    tema $BRAND aplicado (config/branding/index.html)"
  else
    rm -f config/branding/index.html   # sin index propio Caddy sirve el original
    echo "    AVISO: no se pudo aplicar el tema; se usa la interfaz original"
  fi
fi

# Con red bridge Docker gestiona los puertos publicados en iptables (ufw no los
# filtra): no hace falta abrir nada a mano. Lo que no se publica no es accesible.

# --------------------------------------------
# 9. Configuracion via API (idempotente):
#    - contraseñas de ThingsBoard
#    - gateway, dispositivo simulado, cliente, usuario y panel en ThingsBoard
#    - comunidad energetica: socios, datos de Datadis y panel
#    - flujos de Node-RED: puente Mosquitto -> TB y simulador
# --------------------------------------------
echo "==> Configurando ThingsBoard y Node-RED..."
TB_URL="https://localhost" NR_URL="http://127.0.0.1:$NODERED_PORT" \
TB_SYSADMIN_PASSWORD="$TB_SYSADMIN_PASSWORD" TB_TENANT_PASSWORD="$TB_TENANT_PASSWORD" \
TB_TENANT_EMAIL="$TB_TENANT_EMAIL" TB_LANG="$TB_LANG" \
TB_GATEWAY_NAME="$TB_GATEWAY_NAME" SIM_INTERVAL="$SIM_INTERVAL" \
CLIENTES="$(printf '%s\n' "${CLIENTES[@]}")" \
CEC_NOMBRE="$CEC_NOMBRE" CEC_ADMIN_EMAIL="$CEC_ADMIN_EMAIL" CEC_ADMIN_PASSWORD="$CEC_ADMIN_PASSWORD" \
SOCIOS="$(printf '%s\n' "${SOCIOS[@]}")" DATADIS_DIR="$DATADIS_DIR" TZ="$TZ" \
NODERED_USER="$NODERED_USER" NODERED_PASSWORD="$NODERED_PASSWORD" \
MQTT_PORT="$MQTT_PORT" MQTT_USER="$MQTT_USER" MQTT_PASSWORD="$MQTT_PASSWORD" \
python3 - <<'PY'
import json, os, re, ssl, time, urllib.error, urllib.parse, urllib.request, uuid
from datetime import datetime
from zoneinfo import ZoneInfo

E = os.environ
TB, NR = E["TB_URL"], E["NR_URL"]
# ThingsBoard se alcanza por Caddy en https://localhost (certificado interno)
CTX = ssl._create_unverified_context()
CLIENTES = [dict(zip(("cliente", "email", "password", "device", "panel", "perfil"), l.split("|")))
            for l in E["CLIENTES"].splitlines() if l.strip()]


def http(method, url, body=None, headers=None, raw=False):
    data = None if body is None else json.dumps(body).encode()
    h = {"Content-Type": "application/json", **(headers or {})}
    req = urllib.request.Request(url, data=data, headers=h, method=method)
    with urllib.request.urlopen(req, timeout=30, context=CTX) as r:
        txt = r.read().decode()
    if raw:
        return txt
    return json.loads(txt) if txt.strip() else None


def wait(url, seconds):
    end = time.time() + seconds
    while time.time() < end:
        try:
            urllib.request.urlopen(url, timeout=5, context=CTX)
            return True
        except Exception:
            time.sleep(3)
    return False


# ---------------- ThingsBoard ----------------
class TBClient:
    def __init__(self, token):
        self.h = {"X-Authorization": "Bearer " + token}

    def get(self, path):
        return http("GET", TB + path, headers=self.h)

    def post(self, path, body=None, raw=False):
        return http("POST", TB + path, body, self.h, raw)


def tb_login(user, pw):
    try:
        return http("POST", TB + "/api/auth/login", {"username": user, "password": pw})["token"]
    except Exception:
        return None


def tb_password(user, default, new):
    if tb_login(user, new):
        print(f"    {user}: contraseña ya configurada")
        return
    tok = tb_login(user, default)
    if not tok:
        print(f"    AVISO: no se pudo entrar como {user}")
        return
    TBClient(tok).post("/api/auth/changePassword", {"currentPassword": default, "newPassword": new})
    print(f"    {user}: contraseña cambiada")


def find(items, key, value):
    return next((i for i in items if i.get(key) == value), None)


def page(path):
    sep = "&" if "?" in path else "?"
    return path + sep + "pageSize=1000&page=0"


print("  - ThingsBoard: esperando...")
if not wait(TB + "/login", 600):
    raise SystemExit("    ERROR: ThingsBoard no responde")
# La API de login tarda algo mas que la web en estar lista
for _ in range(60):
    if tb_login("sysadmin@thingsboard.org", "sysadmin") or tb_login("sysadmin@thingsboard.org", E["TB_SYSADMIN_PASSWORD"]):
        break
    time.sleep(5)

# Politica de contraseñas: permitir contraseñas cortas (por defecto exige 6)
sys_tok = tb_login("sysadmin@thingsboard.org", "sysadmin") or \
    tb_login("sysadmin@thingsboard.org", E["TB_SYSADMIN_PASSWORD"])
sa = TBClient(sys_tok)
sec = sa.get("/api/admin/securitySettings")
pol = sec.setdefault("passwordPolicy", {})
min_len = min(6, len(E["TB_SYSADMIN_PASSWORD"]), len(E["TB_TENANT_PASSWORD"]),
              len(E["CEC_ADMIN_PASSWORD"]), *(len(c["password"]) for c in CLIENTES),
              *(len(l.split("|")[2]) for l in E["SOCIOS"].splitlines() if l.count("|") >= 2 and l.split("|")[1]))
if (pol.get("minimumLength") or 6) > min_len:
    pol.update({"minimumLength": min_len, "minimumUppercaseLetters": None,
                "minimumLowercaseLetters": None, "minimumDigits": None,
                "minimumSpecialCharacters": None, "passwordReuseFrequencyDays": None})
    sa.post("/api/admin/securitySettings", sec)
    print(f"    politica de contraseñas: minimo {min_len} caracteres")

tb_password("sysadmin@thingsboard.org", "sysadmin", E["TB_SYSADMIN_PASSWORD"])


def idioma(client, user):
    """Idioma de la interfaz del usuario (additionalInfo.lang)."""
    info = user.get("additionalInfo") or {}
    if info.get("lang") != E["TB_LANG"]:
        info["lang"] = E["TB_LANG"]
        user["additionalInfo"] = info
        client.post("/api/user?sendActivationMail=false", user)
        print(f"    {user['email']}: idioma {E['TB_LANG']}")


sa = TBClient(tb_login("sysadmin@thingsboard.org", E["TB_SYSADMIN_PASSWORD"]))
idioma(sa, sa.get("/api/auth/user"))

# Administrador del tenant: tenant@thingsboard.org pasa a TB_TENANT_EMAIL
tenant_email = E["TB_TENANT_EMAIL"]
if not tb_login(tenant_email, E["TB_TENANT_PASSWORD"]):
    tb_password("tenant@thingsboard.org", "tenant", E["TB_TENANT_PASSWORD"])
    t = TBClient(tb_login("tenant@thingsboard.org", E["TB_TENANT_PASSWORD"]))
    me = t.get("/api/auth/user")
    me.update({"email": tenant_email, "firstName": "pk"})
    t.post("/api/user?sendActivationMail=false", me)
    print(f"    tenant@thingsboard.org renombrado a {tenant_email}")
tb = TBClient(tb_login(tenant_email, E["TB_TENANT_PASSWORD"]))
idioma(tb, tb.get("/api/auth/user"))


def device(name, dtype, gateway=False):
    try:
        d = tb.get("/api/tenant/devices?deviceName=" + urllib.parse.quote(name))
    except urllib.error.HTTPError:
        body = {"name": name, "type": dtype}
        if gateway:
            body["additionalInfo"] = {"gateway": True}
        d = tb.post("/api/device", body)
        print(f"    dispositivo '{name}' creado")
    return d


gw = device(E["TB_GATEWAY_NAME"], "gateway", gateway=True)
gw_token = tb.get(f"/api/device/{gw['id']['id']}/credentials")["credentialsId"]


# Perfiles de datos: claves (etiqueta, unidad, color, icono), graficas y simulador
PERFILES = {
    "ambiente": {
        "desc": "Temperatura, humedad y potencia",
        "keys": {"temperatura": ("Temperatura", "°C", "#e53935", "thermostat"),
                 "humedad": ("Humedad", "%", "#1e88e5", "water_drop"),
                 "potencia": ("Potencia", "W", "#fb8c00", "bolt")},
        # la potencia (W) aplastaria a temperatura/humedad en un solo eje
        "charts": [("Temperatura y humedad", ["temperatura", "humedad"]),
                   ("Potencia", ["potencia"])],
        "sim": """// Paseo aleatorio suave para que las graficas tengan sentido
const s = context.get('s') || { temperatura: 21, humedad: 50, potencia: 1500 };
const step = (v, d, min, max) => Math.min(max, Math.max(min, v + (Math.random() - 0.5) * d));
s.temperatura = step(s.temperatura, 0.6, 15, 30);
s.humedad = step(s.humedad, 2, 30, 80);
s.potencia = step(s.potencia, 200, 200, 4000);
context.set('s', s);
msg.payload = {
  temperatura: +s.temperatura.toFixed(2),
  humedad: +s.humedad.toFixed(1),
  potencia: Math.round(s.potencia)
};
return msg;""",
    },
    "energia": {
        "desc": "Generacion fotovoltaica, consumo e intercambio con la red de la comunidad",
        "keys": {"generacion_kw": ("Generación FV", "kW", "#43a047", "solar_power"),
                 "consumo_kw": ("Consumo", "kW", "#e53935", "power"),
                 "red_kw": ("Red (+compra / −vertido)", "kW", "#1e88e5", "electrical_services")},
        "charts": [("Generación y consumo", ["generacion_kw", "consumo_kw"]),
                   ("Intercambio con la red", ["red_kw"])],
        "sim": """// Comunidad energetica: curva solar segun la hora (7h-20h) con nubes,
// consumo con paseo aleatorio y saldo con la red (positivo = compra)
const s = context.get('s') || { consumo: 12, nubes: 0.2 };
const step = (v, d, min, max) => Math.min(max, Math.max(min, v + (Math.random() - 0.5) * d));
const now = new Date();
const h = now.getHours() + now.getMinutes() / 60;
s.nubes = step(s.nubes, 0.1, 0, 0.8);
s.consumo = step(s.consumo, 1.5, 4, 30);
const sol = Math.max(0, Math.sin(Math.PI * (h - 7) / 13));
const gen = 40 * sol * (1 - s.nubes);
context.set('s', s);
msg.payload = {
  generacion_kw: +gen.toFixed(2),
  consumo_kw: +s.consumo.toFixed(2),
  red_kw: +(s.consumo - gen).toFixed(2)
};
return msg;""",
    },
}


# Widgets a partir de la configuracion por defecto de cada tipo
def widget(fqn, title, keys, x, y, w, h, alias_id, icon=None):
    wt = tb.get("/api/widgetType?fqn=" + urllib.parse.quote(fqn))
    desc = wt["descriptor"]
    cfg = json.loads(desc.get("defaultConfig") or "{}")
    cfg["title"] = title
    cfg["useDashboardTimewindow"] = True
    cfg["datasources"] = [{
        "type": "entity", "entityAliasId": alias_id,
        "dataKeys": [{"name": k, "type": "timeseries", "label": label, "color": color,
                      "units": units, "decimals": 1, "settings": {}}
                     for k, label, units, color in keys],
    }]
    if icon:  # tarjeta de valor: la etiqueta va dentro, sin titulo de widget
        _, _, units, color = keys[0]
        cfg["showTitle"] = False
        cfg["units"], cfg["decimals"] = units, 1
        cfg.setdefault("settings", {})["icon"] = icon
        cfg["settings"].setdefault("iconColor", {})["type"] = "constant"
        cfg["settings"]["iconColor"]["color"] = color
    else:
        cfg["showTitle"] = True
    wid = str(uuid.uuid4())
    return wid, {
        "id": wid, "typeFullFqn": fqn, "type": desc.get("type", "timeseries"),
        "sizeX": w, "sizeY": h, "row": y, "col": x, "config": cfg,
    }


def crear_panel(title, perfil, dev):
    keys = perfil["keys"]
    alias_id = str(uuid.uuid4())
    widgets, layout = {}, {}
    specs = [("system.cards.value_card", v[0], [(k, *v[:3])], i * 8, 0, 8, 3, v[3])
             for i, (k, v) in enumerate(keys.items())]
    for i, (ctitle, ks) in enumerate(perfil["charts"]):
        specs.append(("system.time_series_chart", ctitle,
                      [(k, *keys[k][:3]) for k in ks], i * 12, 3, 12, 8, None))
    for fqn, wtitle, wkeys, x, y, w, h, icon in specs:
        wid, wdef = widget(fqn, wtitle, wkeys, x, y, w, h, alias_id, icon)
        widgets[wid] = wdef
        layout[wid] = {"sizeX": w, "sizeY": h, "row": y, "col": x}
    return tb.post("/api/dashboard", {
        "title": title,
        "configuration": {
            "description": perfil["desc"],
            "widgets": widgets,
            "states": {"default": {"name": title, "root": True, "layouts": {"main": {
                "widgets": layout,
                "gridSettings": {"columns": 24, "margin": 10, "outerMargin": True,
                                 "backgroundColor": "#eeeeee"}}}}},
            "entityAliases": {alias_id: {"id": alias_id, "alias": dev["name"], "filter": {
                "type": "singleEntity", "resolveMultiple": False,
                "singleEntity": {"entityType": "DEVICE", "id": dev["id"]["id"]}}}},
            "filters": {},
            "timewindow": {"selectedTab": 0,
                           "realtime": {"realtimeType": 0, "timewindowMs": 900000, "interval": 5000},
                           "aggregation": {"type": "NONE", "limit": 5000}},
            "settings": {"stateControllerId": "entity", "showTitle": True,
                         "showDashboardsSelect": True, "showEntitiesSelect": True,
                         "showDashboardTimewindow": True, "showDashboardExport": True,
                         "toolbarAlwaysOpen": True},
        },
    })


def usuario_cliente(cid, c, dash_id, fullscreen=False):
    """Usuario de un cliente con su panel por defecto. fullscreen: el usuario solo ve ese
    panel a pantalla completa, sin menu lateral ni acceso al resto de ThingsBoard."""
    users = tb.get(page(f"/api/customer/{cid}/users"))["data"]
    user = find(users, "email", c["email"])
    if user:
        # Asegura que su panel por defecto es el suyo
        user = tb.get(f"/api/user/{user['id']['id']}")
        info = user.get("additionalInfo") or {}
        if (info.get("defaultDashboardId"), bool(info.get("defaultDashboardFullscreen"))) != (dash_id, fullscreen):
            info["defaultDashboardId"] = dash_id
            info["defaultDashboardFullscreen"] = fullscreen
            user["additionalInfo"] = info
            user = tb.post("/api/user?sendActivationMail=false", user)
        idioma(tb, user)
        return
    u = tb.post("/api/user?sendActivationMail=false", {
        "email": c["email"], "authority": "CUSTOMER_USER", "firstName": c["cliente"],
        "customerId": {"id": cid, "entityType": "CUSTOMER"},
        "additionalInfo": {"defaultDashboardId": dash_id, "defaultDashboardFullscreen": fullscreen,
                           "lang": E["TB_LANG"]},
    })
    link = http("GET", f"{TB}/api/user/{u['id']['id']}/activationLink", headers=tb.h, raw=True)
    token = urllib.parse.parse_qs(urllib.parse.urlparse(link.strip().strip('"')).query)["activateToken"][0]
    http("POST", TB + "/api/noauth/activate?sendActivationMail=false",
         {"activateToken": token, "password": c["password"]})
    print(f"    usuario '{c['email']}' creado")




# ======================= Comunidad energetica =======================
# La energia de cada socio es la de Datadis: curva de carga (horaria o cuartohoraria) y
# contrato de la descarga web, en DATADIS_DIR/<carpeta>/Consumo_*.csv y Contrato_*.csv.
# Solo las coordenadas del mapa son ficticias. Dispositivos en ThingsBoard:
#   <socio>     tipo "socio"      energia de cada periodo de medida (consumo_kwh, vertida_kwh,
#                                 generada_kwh, autoconsumo_kwh), totales diarios (d_*) y,
#                                 como atributos, los datos del suministro (CUPS, peaje...)
#   comunidad   tipo "comunidad"  suma horaria y diaria de todos los socios
# <socio> es el nombre sin acentos, en minusculas y con guiones ("Ana García" -> ana-garcia).
# La telemetria se carga al ejecutar este script y solo si cambian los ficheros de Datadis.
import csv, glob, hashlib, unicodedata

CEC = E["CEC_NOMBRE"]
DATADIS_DIR = E["DATADIS_DIR"]
TZL = ZoneInfo(E.get("TZ", "Europe/Madrid"))
CEC_DASH_VERSION = 18           # sube este numero para regenerar el panel de la comunidad
DATOS_VERSION = 3               # idem para recargar la telemetria de Datadis
OCULTAR_PIE = "section.tb-powered-by-footer { display: none !important; }"
# El CSS de impresion esta en config/branding/VatiaCo.css (global)
CSS_PANEL = OCULTAR_PIE
IMPRIMIR = {"name": "Imprimir / guardar como PDF", "icon": "print", "type": "custom",
            "customFunction": "window.print();"}


def con_imprimir(t):
    """Añade el boton de imprimir (PDF) a la cabecera de un widget."""
    wid, wdef, l = t
    wdef["config"].setdefault("actions", {})["headerButton"] = [dict(IMPRIMIR, id=str(uuid.uuid4()))]
    return t


def slug(texto):
    t = unicodedata.normalize("NFD", str(texto)).encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", "-", t).strip("-")


# Energia de Datadis: clave en ThingsBoard, columna del CSV, etiqueta y color
SERIES = [("consumo_kwh", "consumo_kWh", "Consumo de red", "#e0541f"),
          ("vertida_kwh", "energiaVertida_kWh", "Vertido a red", "#2e9d6b"),
          ("generada_kwh", "energiaGenerada_kWh", "Generación FV", "#c07a12"),
          ("autoconsumo_kwh", "energiaAutoconsumida_kWh", "Autoconsumo", "#2f7fd8")]
COLOR_APORTA, COLOR_RECIBE = "#2e9d6b", "#e0541f"

SOCIOS = []
for l in E["SOCIOS"].splitlines():
    if l.strip():
        nombre, email, pw, carpeta, lat, lon = (l.split("|") + [""] * 6)[:6]
        SOCIOS.append({"id": slug(nombre), "nombre": nombre.strip(), "email": email.strip(), "password": pw,
                       "carpeta": carpeta.strip(),
                       "lat": float(lat) if lat.strip() else None, "lon": float(lon) if lon.strip() else None})
SOCIO = {so["id"]: so for so in SOCIOS}


def _num(v):
    v = (v or "").strip()
    return float(v.replace(",", ".")) if v else None


def _csv(ruta):
    with open(ruta, encoding="utf-8", newline="") as f:
        return list(csv.DictReader(f, delimiter=";"))


def peaje(c):
    """Peaje de acceso (2.0TD, 3.0TD, 6.1TD...) a partir del contrato de Datadis."""
    t = c.get("tarifaAcceso") or ""
    m = re.search(r"\d\.\d+TD", t)
    if m:
        return m.group(0)
    if re.search(r"<=\s*15", t):
        return "2.0TD"
    return "2.0TD" if len([p for p in (c.get("potenciaContratadakW") or "").split(";") if p]) <= 2 else "3.0TD"


def datadis_leer(carpeta):
    """Curva de carga, maximetro y contrato de una carpeta de Datadis. None si no hay curva;
    si no, {"filas": [(ts_ms inicio, {clave: kWh})], "paso": minutos, "maximos": [fila de
    telemetria], "contrato": {...}, "firma": ...}."""
    d = os.path.join(DATADIS_DIR, carpeta)
    fc = sorted(glob.glob(os.path.join(d, "Consumo_*.csv")))
    fk = sorted(glob.glob(os.path.join(d, "Contrato_*.csv")))
    fp = sorted(glob.glob(os.path.join(d, "Potencias_*.csv")))
    if not fc:
        return None
    firma = hashlib.sha1()
    for ruta in fc[-1:] + fk[-1:] + fp[-1:]:
        with open(ruta, "rb") as f:
            firma.update(f.read())
    filas_csv = _csv(fc[-1])
    paso = 60 if all(r["hora"].endswith(":00") for r in filas_csv) else 15
    # Datadis numera los periodos de cada dia de forma correlativa por su hora de fin
    # (01:00..24:00; en los cambios de hora falta o se repite la 03:00): el inicio de cada
    # uno es la medianoche local mas paso x posicion en el dia
    filas, pos, t0 = [], {}, {}
    for r in filas_csv:
        fecha = r["fecha"]
        if fecha not in t0:
            y, m, dd = map(int, fecha.split("/"))
            t0[fecha] = int(datetime(y, m, dd, tzinfo=TZL).timestamp()) * 1000
        i = pos[fecha] = pos.get(fecha, -1) + 1
        v = {k: x for k, col, _, _ in SERIES if (x := _num(r.get(col))) is not None}
        if v:
            filas.append((t0[fecha] + i * paso * 60000, v))
    # Maximetro: potencia maxima de cada mes y periodo, en el inicio del mes (local), con
    # el dia y la hora en que se dio
    M = {}
    for r in _csv(fp[-1]) if fp else []:
        kw, per = _num(r.get("maximoPotenciaDemandadaKW")), (r.get("periodo") or "").strip()
        if kw is None or not per.isdigit():
            continue
        y, m, dd = map(int, r["fechaMaximo"].split("/"))
        x = M.setdefault(int(datetime(y, m, 1, tzinfo=TZL).timestamp()) * 1000, {})
        if kw >= x.get(f"pmax_p{per}_kw", -1):
            x[f"pmax_p{per}_kw"] = kw
            x[f"pmax_p{per}_cuando"] = f"{dd:02d}/{m:02d}/{y} {r.get('hora', '')}".strip()
    contrato = _csv(fk[-1]) if fk else []
    return {"filas": filas, "paso": paso, "maximos": [{"ts": ts, "values": v} for ts, v in sorted(M.items())],
            "contrato": contrato[-1] if contrato else {}, "firma": firma.hexdigest()[:16]}


def potencia_por_periodo(c, periodos):
    """Potencia contratada (kW) de cada periodo del maximetro. En 2.0TD hay dos potencias
    (P1 punta y llano, P2 valle) y el maximetro da los tres periodos de energia."""
    pot = [x for x in (_num(v) for v in (c.get("potenciaContratadakW") or "").split(";")) if x is not None]
    if not pot:
        return {}
    if len(pot) == 2:
        return {str(p): pot[0] if p < 3 else pot[1] for p in periodos}
    return {str(p): pot[min(p, len(pot)) - 1] for p in periodos}


# Periodos de los peajes (peninsula); fines de semana y festivos nacionales en valle.
# Los mismos que PERIODOS_JS en los widgets.
FESTIVOS = {(1, 1), (5, 1), (8, 15), (10, 12), (11, 1), (12, 6), (12, 8), (12, 25)}
TEMPORADA = [1, 1, 2, 4, 4, 3, 1, 3, 3, 4, 2, 1]   # 3.0TD/6.xTD: periodo de punta por mes


def periodo(lt, pj):
    """Periodo de energia (1 = punta...) a la hora local lt con el peaje pj."""
    valle = lt.weekday() >= 5 or (lt.month, lt.day) in FESTIVOS or lt.hour < 8
    punta = 10 <= lt.hour < 14 or 18 <= lt.hour < 22
    if pj == "2.0TD":
        return 3 if valle else (1 if punta else 2)
    if valle:
        return 6
    p = TEMPORADA[lt.month - 1]
    return p if 9 <= lt.hour < 14 or 18 <= lt.hour < 22 else p + 1


def por_dia(filas, pj):
    """Totales diarios (ts de la medianoche local), consumo de red de cada periodo del
    peaje pj (d_p1_kwh...) y saldo con la red (+ recibe, − aporta)."""
    D = {}
    for ts, v in filas:
        lt = datetime.fromtimestamp(ts / 1000, TZL)
        dia = lt.replace(hour=0, minute=0, second=0, microsecond=0)
        x = D.setdefault(int(dia.timestamp()) * 1000, {})
        for k, e in v.items():
            x[k] = x.get(k, 0) + e
        if "consumo_kwh" in v:
            kp = f"p{periodo(lt, pj)}_kwh"
            x[kp] = x.get(kp, 0) + v["consumo_kwh"]
    out = []
    for ts, x in sorted(D.items()):
        val = {"d_" + k: round(e, 3) + 0.0 for k, e in x.items()}
        val["d_red_neto_kwh"] = round(x.get("consumo_kwh", 0) - x.get("vertida_kwh", 0), 3) + 0.0
        out.append({"ts": ts, "values": val})
    return out


def por_hora(curvas):
    """Suma horaria de varias curvas (la de la comunidad): agrupa los cuartos de hora."""
    H = {}
    for filas in curvas:
        for ts, v in filas:
            x = H.setdefault(ts - ts % 3600000, {})
            for k, e in v.items():
                x[k] = x.get(k, 0) + e
    return sorted(H.items())


# ---- ThingsBoard: dispositivos, clientes, telemetria ----
DEV = {}   # nombre -> dispositivo de ThingsBoard


def cec_dispositivo(name, dtype, label, cid=None, attrs=None):
    d = device(name, dtype)
    if label and d.get("label") != label:
        d["label"] = label
        d = tb.post("/api/device", d)
    if cid and (d.get("customerId") or {}).get("id") != cid:
        d = tb.post(f"/api/customer/{cid}/device/{d['id']['id']}")
    if attrs:
        tb.post(f"/api/plugins/telemetry/DEVICE/{d['id']['id']}/attributes/SERVER_SCOPE", attrs)
    DEV[name] = d
    return d


def cec_borrar(path):
    http("DELETE", TB + path, headers=tb.h, raw=True)


def cec_limpiar_anterior():
    """Restos de versiones anteriores: panel y dispositivos del mapa de sitios, medidores y
    puntos de medida simulados, socios que ya no estan en SOCIOS (con su cliente y sus
    usuarios) y los widgets de potencia instantanea y energia horaria."""
    for d in tb.get(page("/api/tenant/dashboards"))["data"]:
        cfg = tb.get(f"/api/dashboard/{d['id']['id']}").get("configuration") or {}
        if "cecVersion" in cfg or d["title"].startswith(CEC + " · ") or d["title"] == PANEL_MEDIDOR:
            cec_borrar(f"/api/dashboard/{d['id']['id']}")
            print(f"    panel anterior '{d['title']}' eliminado")
    for tipo in ("comunidad-energetica", "medidor", "punto"):
        viejos = tb.get(page(f"/api/tenant/devices?type={tipo}"))["data"]
        for d in viejos:
            cec_borrar(f"/api/device/{d['id']['id']}")
        if viejos:
            print(f"    {len(viejos)} dispositivos '{tipo}' de versiones anteriores eliminados")
    old = find(tb.get(page("/api/customers"))["data"], "title", CEC)
    if old:
        cec_borrar(f"/api/customer/{old['id']['id']}")
        print(f"    cliente anterior '{CEC}' (y su usuario) eliminado")
    nombres = {so["nombre"] for so in SOCIOS}
    for d in tb.get(page("/api/tenant/devices?type=socio"))["data"]:
        if d["name"] in SOCIO:
            continue
        cec_borrar(f"/api/device/{d['id']['id']}")
        cid = (d.get("customerId") or {}).get("id")
        if cid and cid != NULL_UUID and tb.get(f"/api/customer/{cid}")["title"] not in nombres:
            cec_borrar(f"/api/customer/{cid}")
        print(f"    socio '{d.get('label') or d['name']}' (ya no está en SOCIOS) eliminado con su cliente")
    for fqn, nombre in (("VatiaCo.potencia_hora", "Potencia instantánea de la hora"),
                        ("VatiaCo.energia_dia", "Energía horaria del día")):
        try:
            w = tb.get("/api/widgetType?fqn=" + urllib.parse.quote("tenant." + fqn))
        except urllib.error.HTTPError:
            continue
        cec_borrar(f"/api/widgetType/{w['id']['id']}")
        print(f"    widget '{nombre}' eliminado")


def cec_telemetria(nombre, filas):
    d = DEV.get(nombre)
    if d and filas:
        tb.post(f"/api/plugins/telemetry/DEVICE/{d['id']['id']}/timeseries/ANY", filas)


def cec_cargar(nombre, filas, firma, pj, extra=()):
    """Sustituye la telemetria del dispositivo por la curva de Datadis, sus totales diarios
    y las filas extra (maximetro), solo si los ficheros han cambiado desde la ultima carga
    (atributo datadis_firma)."""
    did = DEV[nombre]["id"]["id"]
    firma = f"{firma}-{pj}-v{DATOS_VERSION}"
    ya = tb.get(f"/api/plugins/telemetry/DEVICE/{did}/values/attributes/SERVER_SCOPE?keys=datadis_firma")
    if ya and ya[0].get("value") == firma:
        return False
    # Fuera la telemetria anterior: la simulada de versiones previas o la de otra descarga
    claves = tb.get(f"/api/plugins/telemetry/DEVICE/{did}/keys/timeseries") or []
    if claves:
        cec_borrar(f"/api/plugins/telemetry/DEVICE/{did}/timeseries/delete?keys="
                   + urllib.parse.quote(",".join(claves)) + "&deleteAllDataForKeys=true")
    serie = [{"ts": ts, "values": {k: round(e, 3) + 0.0 for k, e in v.items()}} for ts, v in filas]
    serie += por_dia(filas, pj) + list(extra)
    for i in range(0, len(serie), 5000):
        cec_telemetria(nombre, serie[i:i + 5000])
    tb.post(f"/api/plugins/telemetry/DEVICE/{did}/attributes/SERVER_SCOPE", {"datadis_firma": firma})
    return True


# ---- Widget propio VatiaCo (ECharts) ----
ECHARTS = "https://cdnjs.cloudflare.com/ajax/libs/echarts/5.5.0/echarts.min.js"

VL_COMUN_JS = r"""
var VL = {
  pad: function (n) { return (n < 10 ? '0' : '') + n; },
  dia0: function (d) { return new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime(); },
  iso: function (d) { return d.getFullYear() + '-' + VL.pad(d.getMonth() + 1) + '-' + VL.pad(d.getDate()); },
  leer: function (s) { var p = s.split('-'); return new Date(+p[0], +p[1] - 1, +p[2]); },
  num: function (v, n) {
    return v == null || isNaN(v) ? '–' : (+v).toLocaleString('es-ES', { minimumFractionDigits: n, maximumFractionDigits: n });
  },
  ds: function (ctx) { return (ctx.datasources || [])[0]; }
};
"""

# Periodos de los peajes (peninsula), los mismos que periodo() en Python. Fines de
# semana y festivos nacionales: valle. pj: '2.0TD' (P1-P3) o cualquier otro (P1-P6).
PERIODOS_JS = r"""
var FESTIVOS = ['01-01', '05-01', '08-15', '10-12', '11-01', '12-06', '12-08', '12-25'];
var TEMPORADA = [1, 1, 2, 4, 4, 3, 1, 3, 3, 4, 2, 1];   // 3.0TD/6.xTD: periodo de punta por mes (0-11)
function PERIODO(d, h, pj) {
  var w = d.getDay(), md = VL.pad(d.getMonth() + 1) + '-' + VL.pad(d.getDate());
  var valle = w === 0 || w === 6 || FESTIVOS.indexOf(md) >= 0 || h < 8;
  if (pj === '2.0TD') return valle ? 3 : ((h >= 10 && h < 14) || (h >= 18 && h < 22) ? 1 : 2);
  if (valle) return 6;
  var p = TEMPORADA[d.getMonth()];
  return (h >= 9 && h < 14) || (h >= 18 && h < 22) ? p : p + 1;
}
"""

# VatiaCo.consumo: la vista de consumo de Datadis / e-distribucion. Pestañas Diario,
# Semanal, Mensual y Anual con navegacion; total, media, reparto por periodos del peaje
# (anillo) y periodos vecinos (barras grises, el elegido en color); grafico apilado o
# agrupado por periodos y descarga en CSV. Pestañas Autoconsumo (siempre, como Datadis),
# Potencias maximas (maximetro mensual frente a la contratada, por periodo y año) y
# Contrato (datos contractuales, localizacion, suministro y autoconsumo).
# Datos: dia = curva (consumo_kwh...) repartida por periodo en el navegador; semana, mes
# y año = totales diarios por periodo (d_p1_kwh...) que calcula este script.
CONSUMO_CSS = """
.dd { display: flex; flex-direction: column; height: 100%; font: 13px Roboto, Arial, sans-serif; color: #333;
  --ac: #7b2fa8; --ac2: #f1e6f8; }
.dd-cab { display: flex; justify-content: space-between; align-items: flex-end; flex-wrap: wrap; gap: 8px;
  padding: 0 4px 6px; border-bottom: 1px solid #eee; }
.dd-nombre { font-size: 17px; font-weight: 700; }
.dd-sub { font-size: 12px; color: #777; margin-top: 2px; }
.dd-metricas button { background: none; border: 0; border-bottom: 2px solid transparent; padding: 4px 10px;
  font: inherit; color: #555; cursor: pointer; }
.dd-metricas button.on { color: var(--ac); border-bottom-color: var(--ac); font-weight: 500; }
.dd-barra { display: flex; justify-content: space-between; align-items: center; flex-wrap: wrap; gap: 8px; padding: 10px 4px; }
.dd-tabs { display: inline-flex; background: var(--ac2); border-radius: 16px; padding: 2px; }
.dd-tabs button { border: 0; background: none; border-radius: 14px; padding: 5px 14px; font: inherit; font-size: 12px;
  font-weight: 500; color: var(--ac); cursor: pointer; }
.dd-tabs button.on { background: var(--ac); color: #fff; }
.dd-nav { display: flex; align-items: center; gap: 4px; }
.dd-nav button { border: 0; background: none; color: var(--ac); font: inherit; font-size: 12px; font-weight: 500;
  cursor: pointer; padding: 4px 6px; }
.dd-nav button:disabled { opacity: .3; cursor: default; }
.dd-sel { position: relative; background: var(--ac); color: #fff; border-radius: 3px; padding: 5px 10px;
  font-size: 12px; font-weight: 500; white-space: nowrap; cursor: pointer; }
.dd-sel input { position: absolute; inset: 0; width: 100%; opacity: 0; cursor: pointer; }
.dd-resumen { display: flex; flex-wrap: wrap; align-items: center; gap: 8px 16px; background: #f6f6f7;
  border-radius: 4px; padding: 10px 12px; }
.dd-kpi { flex: 1 1 120px; text-align: center; }
.dd-kpi b { display: block; font-size: 24px; font-weight: 700; }
.dd-kpi span { font-size: 11px; color: #555; }
.dd-dona { flex: 1 1 190px; min-width: 170px; height: 120px; }
.dd-mini { flex: 1.4 1 230px; min-width: 200px; height: 120px; }
.dd-gcab { display: flex; align-items: center; flex-wrap: wrap; gap: 10px; padding: 12px 4px 0; }
.dd-titulo { flex: 1; }
.dd-modo { display: inline-flex; border: 1px solid var(--ac); border-radius: 14px; overflow: hidden; }
.dd-modo button { border: 0; background: #fff; color: var(--ac); padding: 3px 12px; font: inherit; font-size: 12px; cursor: pointer; }
.dd-modo button.on { background: var(--ac2); font-weight: 500; }
.dd-csv { border: 1px solid var(--ac); background: #fff; color: var(--ac); border-radius: 3px; padding: 4px 10px;
  font: inherit; font-size: 12px; font-weight: 500; cursor: pointer; }
.dd-graf { position: relative; flex: 1; min-height: 120px; }
.dd-chart { position: absolute; inset: 0; }
.dd-vacio { position: absolute; inset: 40% 0 auto; text-align: center; color: #999; pointer-events: none; display: none; }
.dd-pper { border: 1px solid var(--ac); background: #fff; color: var(--ac); border-radius: 3px; padding: 4px 6px;
  font: inherit; font-size: 12px; font-weight: 500; cursor: pointer; margin-right: 6px; }
.dd-pleg { flex: 2 1 260px; display: none; font-size: 12px; }
.dd-pleg b { display: block; font-size: 14px; margin-bottom: 8px; }
.dd-pleg div { display: flex; align-items: center; gap: 12px; margin: 6px 0; }
.dd-pleg span { width: 110px; color: #555; }
.dd-pleg i { display: inline-block; width: 110px; }
.dd-pleg .dd-lc { border-top: 2px solid #f5b942; }
.dd-pleg .dd-lm { height: 14px; background: #fde3b5; }
.dd-contrato { display: none; flex: 1; overflow: auto; padding: 0 4px; }
.dd-ccab { display: flex; justify-content: flex-end; padding-top: 8px; }
.dd-ccols { display: grid; grid-template-columns: repeat(auto-fit, minmax(240px, 1fr)); gap: 0 28px; }
.dd-ccols h4 { margin: 14px 0 4px; font-size: 15px; }
.dd-ccols dl { margin: 0; }
.dd-ccols dt { font-size: 11px; color: #777; padding-top: 8px; }
.dd-ccols dd { margin: 0; padding: 2px 0 8px; border-bottom: 1px solid #e6e6e6; }
"""

CONSUMO_HTML = """<div class="dd">
  <div class="dd-cab">
    <div><div class="dd-nombre"></div><div class="dd-sub"></div></div>
    <div class="dd-metricas"><button type="button" data-m="consumo">Consumo</button><button type="button" data-m="auto">Autoconsumo</button><button type="button" data-m="pot">Potencias máximas</button><button type="button" data-m="contrato">Contrato</button></div>
  </div>
  <div class="dd-barra">
    <div class="dd-tabs"><button type="button" data-v="dia">Diario</button><button type="button" data-v="semana">Semanal</button><button type="button" data-v="mes">Mensual</button><button type="button" data-v="anio">Anual</button></div>
    <div class="dd-nav">
      <select class="dd-pper" aria-label="Periodo de potencia"></select>
      <button type="button" data-n="-1">&#8592; Anterior</button>
      <label class="dd-sel"><span></span> &#9662;<input type="date" aria-label="Fecha"></label>
      <button type="button" data-n="1">Siguiente &#8594;</button>
    </div>
  </div>
  <div class="dd-resumen">
    <div class="dd-kpi"><b class="dd-k1">–</b><span class="dd-l1"></span></div>
    <div class="dd-kpi"><b class="dd-k2">–</b><span class="dd-l2"></span></div>
    <div class="dd-dona"></div>
    <div class="dd-mini"></div>
    <div class="dd-pleg"><b class="dd-ptit"></b>
      <div><span>Contratada</span><i class="dd-lc"></i></div>
      <div><span>Máxima demanda</span><i class="dd-lm"></i></div></div>
  </div>
  <div class="dd-gcab">
    <span class="dd-titulo"></span>
    <div class="dd-modo"><button type="button" data-a="1">Apilado</button><button type="button" data-a="0">Agrupado</button></div>
    <button type="button" class="dd-csv">Descargar CSV</button>
  </div>
  <div class="dd-graf"><div class="dd-chart"></div><div class="dd-vacio">Sin datos en este periodo</div></div>
  <div class="dd-contrato"><div class="dd-ccab"><button type="button" class="dd-csv">Descargar CSV</button></div>
    <div class="dd-ccols"></div></div>
</div>"""

CONSUMO_JS = VL_COMUN_JS + PERIODOS_JS + r"""
var S = { modo: 'dia', metrica: 'consumo', apilado: true, pedido: 0, pers: [], pcon: {} };
var MESES = ['Ene', 'Feb', 'Mar', 'Abr', 'May', 'Jun', 'Jul', 'Ago', 'Sep', 'Oct', 'Nov', 'Dic'];
var MESES_L = ['enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio', 'julio', 'agosto', 'septiembre',
               'octubre', 'noviembre', 'diciembre'];
var COL3 = { 1: '#fda38a', 2: '#fddcb0', 3: '#a8ebbd' }, NOM3 = { 1: 'Punta', 2: 'Llano', 3: 'Valle' };
var COL6 = { 1: '#fda38a', 2: '#fdbf9a', 3: '#fddcb0', 4: '#eef0b4', 5: '#cdeec2', 6: '#a8ebbd' };
var AUTO = [{ k: 'auto', n: 'Autoconsumo', c: '#8fc3f0', curva: 'autoconsumo_kwh', d: 'd_autoconsumo_kwh' },
            { k: 'vert', n: 'Excedentes', c: '#a8ebbd', curva: 'vertida_kwh', d: 'd_vertida_kwh' }];
function q(s) { return S.raiz.querySelector(s); }
function qa(s) { return [].slice.call(S.raiz.querySelectorAll(s)); }
function r3(v) { return Math.round(v * 1000) / 1000; }
function pj() { return S.peaje && S.peaje !== '2.0TD' ? '6P' : '2.0TD'; }

// Series apiladas, de abajo (valle) a arriba (punta) como en Datadis
function cats() {
  if (S.metrica === 'auto') return AUTO;
  var n = pj() === '2.0TD' ? 3 : 6, out = [];
  for (var p = n; p >= 1; p--)
    out.push({ k: 'p' + p, n: n === 3 ? NOM3[p] : 'P' + p, c: (n === 3 ? COL3 : COL6)[p], curva: 'consumo_kwh', d: 'd_p' + p + '_kwh' });
  return out;
}

// Unidades de tiempo: inicio, desplazamiento y etiqueta
function inicio(d, m) {
  if (m === 'dia') return new Date(d.getFullYear(), d.getMonth(), d.getDate());
  if (m === 'semana') return new Date(d.getFullYear(), d.getMonth(), d.getDate() - (d.getDay() + 6) % 7);
  if (m === 'mes') return new Date(d.getFullYear(), d.getMonth(), 1);
  return new Date(d.getFullYear(), 0, 1);
}
function mover(d, m, n) {
  var x = inicio(d, m);
  if (m === 'dia') return new Date(x.getFullYear(), x.getMonth(), x.getDate() + n);
  if (m === 'semana') return new Date(x.getFullYear(), x.getMonth(), x.getDate() + 7 * n);
  if (m === 'mes') return new Date(x.getFullYear(), x.getMonth() + n, 1);
  return new Date(x.getFullYear() + n, 0, 1);
}
function semanaIso(d) {
  var t = new Date(d.getFullYear(), d.getMonth(), d.getDate() + 3 - (d.getDay() + 6) % 7);
  return { s: 1 + Math.floor((t - new Date(t.getFullYear(), 0, 1)) / 604800000), a: t.getFullYear() };
}
function etiqueta(d, m, corta) {
  if (m === 'dia') return VL.pad(d.getDate()) + '/' + VL.pad(d.getMonth() + 1) + (corta ? '' : '/' + d.getFullYear());
  if (m === 'semana') { var w = semanaIso(d); return corta ? 'S' + w.s : 'Semana ' + w.s + ' - ' + w.a; }
  if (m === 'mes') return corta ? MESES[d.getMonth()] + ' ' + String(d.getFullYear()).slice(2) : MESES_L[d.getMonth()] + ' ' + d.getFullYear();
  return String(d.getFullYear());
}
function casillas(t0) {
  var d0 = new Date(t0), out = [], i, d;
  if (S.modo === 'dia') for (i = 1; i <= 24; i++) out.push(VL.pad(i) + ':00');
  else if (S.modo === 'semana') for (i = 0; i < 7; i++) {
    d = new Date(d0.getFullYear(), d0.getMonth(), d0.getDate() + i); out.push(etiqueta(d, 'dia', false));
  }
  else if (S.modo === 'mes') for (i = 1; i <= new Date(d0.getFullYear(), d0.getMonth() + 1, 0).getDate(); i++) out.push(VL.pad(i));
  else for (i = 0; i < 12; i++) out.push(MESES[i] + ' ' + d0.getFullYear());
  return out;
}
function indice(ts, t0) {
  var d = new Date(ts);
  if (S.modo === 'dia') return d.getHours();
  if (S.modo === 'semana') return Math.round((VL.dia0(d) - t0) / 86400000);
  if (S.modo === 'mes') return d.getDate() - 1;
  return d.getMonth();
}

self.onInit = function () {
  S.ctx = self.ctx;
  S.raiz = self.ctx.$container[0];
  S.g = echarts.init(q('.dd-chart'));
  S.dona = echarts.init(q('.dd-dona'));
  S.mini = echarts.init(q('.dd-mini'));
  qa('.dd-tabs button').forEach(function (b) { b.onclick = function () { S.modo = b.dataset.v; cargar(); }; });
  qa('.dd-metricas button').forEach(function (b) { b.onclick = function () { S.metrica = b.dataset.m; cargar(); }; });
  qa('.dd-modo button').forEach(function (b) { b.onclick = function () { S.apilado = b.dataset.a === '1'; ui(); pintar(); }; });
  qa('.dd-nav button').forEach(function (b) { b.onclick = function () { S.ref = mover(S.ref, S.modo, +b.dataset.n); cargar(); }; });
  var inp = q('.dd-sel input');
  inp.onchange = function () { if (inp.value) { S.ref = VL.leer(inp.value); cargar(); } };
  qa('.dd-csv').forEach(function (b) { b.onclick = csv; });
  q('.dd-pper').onchange = function () { S.pper = +q('.dd-pper').value; cargar(); };
  S.mini.on('click', function (e) { S.ref = mover(S.ref, S.modo, e.dataIndex - 3); cargar(); });
  var ds = VL.ds(S.ctx);
  q('.dd-nombre').textContent = ds ? (ds.entityLabel || ds.entityName || '') : '';
  if (!ds || !ds.entityId) return;
  S.base = '/api/plugins/telemetry/' + ds.entityType + '/' + ds.entityId;
  // Datos del suministro y ultimo dia con datos (Datadis publica con retraso)
  S.ctx.http.get(S.base + '/values/attributes/SERVER_SCOPE?keys=cups,peaje,periodos,potencia,contrato,pcontratada_kw')
    .subscribe(function (a) {
    var at = {};
    (a || []).forEach(function (x) { at[x.key] = typeof x.value === 'string' && /^[{[]/.test(x.value) ? JSON.parse(x.value) : x.value; });
    S.peaje = at.peaje || at.periodos || null;
    S.contrato = at.contrato || null;
    S.pcon = at.pcontratada_kw || {};
    q('.dd-sub').textContent = [at.cups ? 'CUPS ' + at.cups : '', at.peaje ? 'Peaje ' + at.peaje : '',
                                at.potencia ? at.potencia + ' kW' : ''].filter(Boolean).join(' · ');
    ultimo();
  }, ultimo);
};

// Claves que tiene la entidad (pestañas Autoconsumo y Potencias) y ultimo dia con datos
function ultimo() {
  S.ctx.http.get(S.base + '/keys/timeseries').subscribe(function (ks) {
    ks = Array.isArray(ks) ? ks : [];
    S.hayGen = ks.indexOf('d_generada_kwh') >= 0;
    S.pers = ks.map(function (k) { var m = /^pmax_p(\d)_kw$/.exec(k); return m ? +m[1] : 0; })
               .filter(Boolean).sort();
    q('.dd-pper').innerHTML = S.pers.map(function (p) { return '<option value="' + p + '">Potencia P' + p + '</option>'; }).join('');
    S.pper = S.pers[0];
    S.ctx.http.get(S.base + '/values/timeseries?keys=d_consumo_kwh').subscribe(function (r) {
      var c = ((r || {}).d_consumo_kwh || [])[0];
      S.ref = c ? new Date(c.ts) : new Date();
      cargar();
    }, function () { S.ref = new Date(); cargar(); });
  }, function () { S.ref = new Date(); cargar(); });
}

function pedir(keys, t0, t1, ok) {
  S.ctx.http.get(S.base + '/values/timeseries?keys=' + encodeURIComponent(keys.join(',')) + '&startTs=' + t0 +
                 '&endTs=' + (t1 - 1) + '&agg=NONE&limit=50000&useStrictDataTypes=true')
    .subscribe(function (r) { ok(r || {}); }, function () { ok({}); });
}

// Consumo y Autoconsumo siempre, como en Datadis; Potencias y Contrato si hay datos
function hay(m) { return { consumo: true, auto: true, pot: S.pers.length > 0, contrato: !!S.contrato }[m]; }

function ui() {
  var pot = S.metrica === 'pot', con = S.metrica === 'contrato';
  if (pot) S.modo = 'anio';   // como en Datadis, el maximetro solo en vista anual
  qa('.dd-tabs button').forEach(function (b) {
    b.classList.toggle('on', b.dataset.v === S.modo);
    b.style.display = pot && b.dataset.v !== 'anio' ? 'none' : '';
  });
  qa('.dd-metricas button').forEach(function (b) {
    b.classList.toggle('on', b.dataset.m === S.metrica);
    b.style.display = hay(b.dataset.m) ? '' : 'none';
  });
  ['.dd-barra', '.dd-resumen', '.dd-gcab', '.dd-graf'].forEach(function (s) { q(s).style.display = con ? 'none' : ''; });
  q('.dd-contrato').style.display = con ? 'block' : 'none';
  q('.dd-dona').style.display = q('.dd-mini').style.display = pot ? 'none' : '';
  q('.dd-pleg').style.display = pot ? 'block' : 'none';
  q('.dd-pper').style.display = pot ? '' : 'none';
  q('.dd-pper').value = S.pper;
  qa('.dd-modo button').forEach(function (b) { b.classList.toggle('on', (b.dataset.a === '1') === S.apilado); });
  // En el dia de consumo cada hora es de un solo periodo: no hay nada que agrupar
  q('.dd-modo').style.display = (S.modo === 'dia' && S.metrica === 'consumo') || pot ? 'none' : '';
  q('.dd-sel span').textContent = etiqueta(S.ref, S.modo, false);
  var inp = q('.dd-sel input');
  inp.value = VL.iso(S.ref);
  inp.max = VL.iso(new Date());
  q('.dd-nav [data-n="1"]').disabled = mover(S.ref, S.modo, 1) > new Date();
}

function cargar() {
  if (!S.base || !S.ref) return;
  if (!hay(S.metrica)) S.metrica = 'consumo';
  ui();
  if (S.metrica === 'contrato') { pintarContrato(); return; }
  var n = ++S.pedido, C = cats(), dia = S.modo === 'dia';
  var t0 = inicio(S.ref, S.modo).getTime(), t1 = mover(S.ref, S.modo, 1).getTime();
  if (S.metrica === 'pot') {
    pedir(['pmax_p' + S.pper + '_kw', 'pmax_p' + S.pper + '_cuando'], t0, t1, function (r) {
      if (n === S.pedido) pintarPot(r, t0);
    });
    return;
  }
  var keys = [];
  C.forEach(function (c) { var k = dia ? c.curva : c.d; if (keys.indexOf(k) < 0) keys.push(k); });
  var mk = S.metrica === 'auto' ? 'd_generada_kwh' : 'd_consumo_kwh';
  pedir(keys, t0, t1, function (r) {
    pedir([mk], mover(S.ref, S.modo, -3).getTime(), mover(S.ref, S.modo, 4).getTime(), function (rm) {
      if (n !== S.pedido) return;
      S.datos = agrupar(r, C, t0);
      S.vecinos = vecinos(rm[mk] || []);
      pintar();
    });
  });
}

// Valores de cada casilla (hora, dia o mes) y serie
function agrupar(r, C, t0) {
  var et = casillas(t0), V = et.map(function () { return {}; }), hay = et.map(function () { return false; });
  var dia = S.modo === 'dia';
  C.forEach(function (c) {
    (r[dia ? c.curva : c.d] || []).forEach(function (p) {
      if (p.value == null) return;
      var d = new Date(p.ts), i = indice(p.ts, t0);
      if (i < 0 || i >= et.length) return;
      if (dia && S.metrica === 'consumo' && 'p' + PERIODO(d, d.getHours(), pj()) !== c.k) return;
      V[i][c.k] = (V[i][c.k] || 0) + (+p.value);
      hay[i] = true;
    });
  });
  return { et: et, V: V, hay: hay };
}

// Total de los 3 periodos anteriores y posteriores al elegido (barras grises)
function vecinos(pts) {
  var out = [];
  for (var k = -3; k <= 3; k++) {
    var a = mover(S.ref, S.modo, k), b = mover(S.ref, S.modo, k + 1).getTime(), v = null;
    pts.forEach(function (p) { if (p.value != null && p.ts >= a.getTime() && p.ts < b) v = (v || 0) + (+p.value); });
    out.push({ lab: etiqueta(a, S.modo, true), v: v });
  }
  return out;
}

function pintar() {
  var D = S.datos, C = cats(), auto = S.metrica === 'auto';
  if (!D) return;
  [S.g, S.dona, S.mini].forEach(function (c) { c.resize(); });   // por si estaban ocultos
  var tot = {}, total = 0, n = 0;
  C.forEach(function (c) { tot[c.k] = 0; });
  D.V.forEach(function (v, i) { for (var k in v) { tot[k] += v[k]; total += v[k]; } if (D.hay[i]) n++; });
  var de = { dia: 'del día', semana: 'de la semana', mes: 'del mes', anio: 'del año' }[S.modo];
  q('.dd-k1').textContent = n ? VL.num(total, 2) : '–';
  q('.dd-l1').textContent = (auto ? 'Generación total ' : 'Consumo total ') + de + ' (kWh)';
  if (auto) {
    q('.dd-k2').textContent = total ? VL.num(100 * tot.auto / total, 1) + ' %' : '–';
    q('.dd-l2').textContent = 'Autoconsumida (% de la generación)';
  } else {
    q('.dd-k2').textContent = n ? VL.num(total / n, 2) : '–';
    q('.dd-l2').textContent = { dia: 'Consumo medio horario', semana: 'Consumo medio diario', mes: 'Consumo medio diario',
                                anio: 'Consumo medio mensual' }[S.modo] + ' (kWh)';
  }
  // Anillo: reparto por periodos (o autoconsumo / excedentes)
  S.dona.setOption({
    animation: false,
    tooltip: { trigger: 'item', formatter: function (p) {
      return p.marker + p.name + ': ' + VL.num(p.value, 2) + ' kWh (' + VL.num(p.percent, 1) + ' %)'; } },
    legend: { orient: 'vertical', right: 0, top: 'middle', icon: 'circle', itemWidth: 10, itemHeight: 10,
              textStyle: { fontSize: 11, color: '#555' }, formatter: function (nm) { return nm.toUpperCase(); } },
    series: [{ type: 'pie', radius: ['62%', '84%'], center: ['34%', '50%'], label: { show: false },
               data: C.map(function (c) { return { name: c.n, value: r3(tot[c.k]), itemStyle: { color: c.c } }; }) }]
  }, true);
  // Periodos vecinos en gris y el elegido en color (pulsar una barra la abre)
  var M = S.vecinos || [];
  var mser = [{ type: 'bar', stack: 'm', barWidth: '62%',
                data: M.map(function (x, i) { return i === 3 ? null : { value: x.v, itemStyle: { color: '#e4e4e6' } }; }) }];
  C.forEach(function (c) {
    mser.push({ type: 'bar', stack: 'm', name: c.n, itemStyle: { color: c.c },
                data: M.map(function (x, i) { return i === 3 ? r3(tot[c.k]) : null; }) });
  });
  S.mini.setOption({
    animation: false, grid: { left: 4, right: 4, top: 6, bottom: 22 },
    tooltip: { trigger: 'axis', axisPointer: { type: 'shadow' }, formatter: function (ps) {
      var i = ps[0].dataIndex, v = i === 3 ? (n ? total : null) : M[i].v;
      return M[i].lab + ': ' + (v == null ? '–' : VL.num(v, 1) + ' kWh'); } },
    xAxis: { type: 'category', data: M.map(function (x) { return x.lab; }), axisTick: { show: false },
             axisLine: { lineStyle: { color: '#ccc' } }, axisLabel: { fontSize: 10, color: '#555', interval: 0 } },
    yAxis: { type: 'value', show: false },
    series: mser
  }, true);
  // Grafico principal, apilado o agrupado
  var apila = S.apilado || (S.modo === 'dia' && !auto);
  S.g.setOption({
    animation: false, grid: { left: 70, right: 12, top: 20, bottom: 46 },
    tooltip: { trigger: 'axis', axisPointer: { type: 'shadow' },
               valueFormatter: function (v) { return v == null ? '–' : VL.num(v, 2) + ' kWh'; } },
    legend: { bottom: 0, icon: 'circle', itemWidth: 10, itemHeight: 10, textStyle: { fontSize: 11 } },
    xAxis: { type: 'category', data: D.et, axisTick: { show: false }, axisLabel: { fontSize: 10, color: '#555' } },
    yAxis: { type: 'value', splitLine: { lineStyle: { color: '#eee' } },
             axisLabel: { fontSize: 10, color: '#555', formatter: function (v) { return VL.num(v, 1) + ' kWh'; } } },
    series: C.map(function (c) {
      return { type: 'bar', name: c.n, stack: apila ? 'a' : null, barMaxWidth: 48, itemStyle: { color: c.c },
               data: D.V.map(function (v) { return v[c.k] == null ? null : r3(v[c.k]); }) };
    })
  }, true);
  q('.dd-titulo').textContent = (auto ? 'Generación ' : 'Consumo ') +
    { dia: 'horario', semana: 'diario', mes: 'diario', anio: 'mensual' }[S.modo] + ' (kWh)';
  q('.dd-vacio').textContent = auto && !S.hayGen ? 'Este suministro no tiene autoconsumo (sin generación en Datadis)'
                                                  : 'Sin datos en este periodo';
  q('.dd-vacio').style.display = n ? 'none' : 'block';
}

// Potencias maximas: maximetro de cada mes del año en el periodo elegido frente a la contratada
function pintarPot(r, t0) {
  var p = S.pper, et = casillas(t0), V = et.map(function () { return null; }), W = et.map(function () { return ''; });
  (r['pmax_p' + p + '_kw'] || []).forEach(function (x) { if (x.value != null) V[new Date(x.ts).getMonth()] = +x.value; });
  (r['pmax_p' + p + '_cuando'] || []).forEach(function (x) { W[new Date(x.ts).getMonth()] = x.value || ''; });
  var c = S.pcon[p] != null ? +S.pcon[p] : null, im = -1;
  V.forEach(function (v, i) { if (v != null && (im < 0 || v > V[im])) im = i; });
  S.datos = { pot: true, et: et, V: V, W: W, c: c };
  q('.dd-ptit').textContent = 'Potencia P' + p;
  q('.dd-k1').textContent = im < 0 ? '–' : VL.num(V[im], 2);
  q('.dd-l1').textContent = 'Máxima demanda del año (kW)' + (im < 0 || !W[im] ? '' : ' · ' + W[im]);
  q('.dd-k2').textContent = c == null ? '–' : VL.num(c, 2);
  q('.dd-l2').textContent = 'Potencia contratada P' + p + ' (kW)';
  S.g.resize();
  S.g.setOption({
    animation: false, grid: { left: 70, right: 12, top: 20, bottom: 30 },
    tooltip: { trigger: 'axis', axisPointer: { type: 'shadow' }, formatter: function (ps) {
      var i = ps[0].dataIndex;
      return et[i] + '<br/>Máxima demanda: ' + (V[i] == null ? '–' : VL.num(V[i], 2) + ' kW' + (W[i] ? ' (' + W[i] + ')' : '')) +
             '<br/>Contratada: ' + (c == null ? '–' : VL.num(c, 2) + ' kW'); } },
    xAxis: { type: 'category', data: et, axisTick: { show: false }, axisLabel: { fontSize: 10, color: '#555' } },
    yAxis: { type: 'value', splitLine: { lineStyle: { color: '#eee' } },
             axisLabel: { fontSize: 10, color: '#555', formatter: function (v) { return VL.num(v, 1) + ' kW'; } } },
    series: [{ type: 'bar', name: 'Máxima demanda', barMaxWidth: 48,
               data: V.map(function (v) {
                 return v == null ? null : { value: r3(v), itemStyle: { color: c != null && v > c ? '#f59a6b' : '#fcc265' } };
               }) },
             { type: 'line', name: 'Contratada', symbol: 'none', step: 'middle', lineStyle: { color: '#f5b942', width: 2 },
               data: V.map(function (v) { return v == null ? null : c; }) }]
  }, true);
  q('.dd-titulo').textContent = 'Potencia máxima demandada en el año (kW)' +
    (V.some(function (v) { return c != null && v > c; }) ? ' — en naranja oscuro, por encima de la contratada' : '');
  q('.dd-vacio').textContent = 'Sin datos en este periodo';
  q('.dd-vacio').style.display = im < 0 ? 'block' : 'none';
}

// Contrato: los campos del contrato de Datadis agrupados como en su web
function esc(v) {
  return String(v == null || v === '' ? '–' : v).replace(/[&<>"]/g, function (x) {
    return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[x]; });
}
function camposContrato() {
  var c = S.contrato || {};
  var cols = [[['Datos contractuales', [['Fechas de inicio y fin de contrato', (c.fechaInicioVigencia || '') + ' - ' + (c.fechaFinVigencia || '')],
                                       ['Distribuidora', c.distribuidora], ['Comercializadora', c.comercializadora], ['CUPS', c.cups]]],
               ['Localización', [['Provincia', c.provincia], ['Municipio', c.municipio], ['Código postal', c.codigoPostal]]]],
              [['Suministro', [['Tarifa de acceso', c.tarifaAcceso], ['Tensión de conexión', c.tensionConexion],
                               ['Potencia contratada por periodos (kW)', (c.potenciaContratadakW || '').split(';').join(' - ')],
                               ['Modo de control de potencia', c.modoControlPotencia],
                               ['Discriminación horaria', c.discriminacionHoraria],
                               ['Potencia máxima de la instalación (kW)', c.potenciaMaximaInstalacion]]]]];
  if (c.tipoAutoconsumo)
    cols[1].push(['Autoconsumo', [['Tipo de autoconsumo', c.tipoAutoconsumo], ['Potencia de generación (kW)', c.potenciaTotalGenerada],
                                  ['CAU', c.cau], ['Sección / subsección', (c.seccion || '') + ' / ' + (c.subseccion || '')],
                                  ['Coeficiente de reparto', c.coeficienteReparto]]]);
  return cols;
}
function pintarContrato() {
  q('.dd-ccols').innerHTML = camposContrato().map(function (col) {
    return '<div>' + col.map(function (sec) {
      return '<h4>' + esc(sec[0]) + '</h4><dl>' + sec[1].map(function (x) {
        return '<dt>' + esc(x[0]) + '</dt><dd>' + esc(x[1]) + '</dd>'; }).join('') + '</dl>';
    }).join('') + '</div>';
  }).join('');
}

// CSV de la pestaña visible (separador ; y coma decimal, como Datadis)
function csv() {
  var D = S.datos, C = cats(), filas, que = S.metrica;
  var f = function (v) { return v == null ? '' : String(r3(v)).replace('.', ','); };
  if (que === 'contrato') {
    filas = ['apartado;campo;valor'];
    camposContrato().forEach(function (col) { col.forEach(function (sec) { sec[1].forEach(function (x) {
      filas.push([sec[0], x[0], x[1] == null ? '' : String(x[1]).replace(/;/g, ',')].join(';')); }); }); });
  } else if (!D || !!D.pot !== (que === 'pot')) {
    return;   // todavia cargando la pestaña
  } else if (que === 'pot') {
    filas = ['mes;máxima demanda P' + S.pper + ' (kW);fecha y hora;contratada (kW)'];
    D.et.forEach(function (e, i) { filas.push([e, f(D.V[i]), D.W[i], D.V[i] == null ? '' : f(D.c)].join(';')); });
  } else {
    filas = [['periodo'].concat(C.map(function (c) { return c.n + ' (kWh)'; }), ['total (kWh)']).join(';')];
    D.et.forEach(function (e, i) {
      var v = D.V[i], t = null;
      var cs = C.map(function (c) { if (v[c.k] != null) t = (t || 0) + v[c.k]; return f(v[c.k]); });
      filas.push([e].concat(cs, [f(t)]).join(';'));
    });
  }
  var nom = (q('.dd-nombre').textContent || 'datos') + ' ' +
            { consumo: 'consumo', auto: 'autoconsumo', pot: 'potencias P' + S.pper, contrato: 'contrato' }[que] +
            (que === 'contrato' ? '' : ' ' + etiqueta(S.ref, S.modo, false));
  var a = document.createElement('a');
  a.href = URL.createObjectURL(new Blob(['﻿' + filas.join('\r\n')], { type: 'text/csv;charset=utf-8' }));
  a.download = nom.replace(/[\\/:*?"<>|]+/g, '-') + '.csv';
  document.body.appendChild(a);
  a.click();
  setTimeout(function () { URL.revokeObjectURL(a.href); a.remove(); }, 0);
}

self.onDataUpdated = function () {};
self.onResize = function () { [S.g, S.dona, S.mini].forEach(function (c) { if (c) c.resize(); }); };
self.onDestroy = function () { [S.g, S.dona, S.mini].forEach(function (c) { if (c) c.dispose(); }); };
"""


def cec_widget(fqn, nombre, html, js, alto, css):
    """Crea o actualiza un tipo de widget del tenant (los paneles lo usan por su fqn)."""
    desc = {"type": "latest", "sizeX": 24, "sizeY": alto,
            "resources": [{"url": ECHARTS, "isModule": False}],
            "templateHtml": html, "templateCss": css, "controllerScript": js, "settingsDirective": "",
            "defaultConfig": json.dumps({"datasources": [], "showTitle": True, "title": nombre,
                                         "backgroundColor": "#fff", "color": "rgba(0,0,0,0.87)",
                                         "padding": "8px", "settings": {}})}
    try:   # se busca por "tenant.<fqn>" (sin el prefijo da 400 y se crearia un duplicado)
        w = tb.get("/api/widgetType?fqn=" + urllib.parse.quote("tenant." + fqn))
    except urllib.error.HTTPError:
        w = None
    if w and all(w["descriptor"].get(k) == desc[k] for k in ("templateHtml", "templateCss", "controllerScript", "resources")):
        return
    cuerpo = {"fqn": fqn, "name": nombre, "deprecated": False, "descriptor": desc}
    if w:
        cuerpo.update(id=w["id"], version=w.get("version"))
    tb.post("/api/widgetType", cuerpo)
    print(f"    widget '{nombre}' ({fqn}) {'actualizado' if w else 'creado'}")


def w_vl(fqn, alias, keys, titulo, x, y, w, h):
    """Widget propio en un panel: los del tenant se referencian como "tenant.<fqn>"."""
    cfg = {"datasources": [{"type": "entity", "entityAliasId": alias, "dataKeys": keys}],
           "showTitle": True, "title": titulo, "settings": {}, "backgroundColor": "#fff",
           "color": "rgba(0,0,0,0.87)", "padding": "8px", "dropShadow": True, "enableFullscreen": True}
    return _w("tenant." + fqn, cfg, "latest", x, y, w, h)


def w_consumo(alias, x, y, w, h):
    """Vista de consumo como la de Datadis (el widget pide sus datos; la clave solo
    resuelve la entidad del alias)."""
    return w_vl("VatiaCo.consumo", alias, [_dk("d_consumo_kwh", "Consumo")], "Consumo", x, y, w, h)


# ---- Paneles ----
def _dk(name, label=None, typ="timeseries", color="#2196f3", units=None, decimals=None, settings=None):
    d = {"name": name, "type": typ, "label": label or name, "color": color, "settings": settings or {}}
    if units is not None:
        d["units"] = units
    if decimals is not None:
        d["decimals"] = decimals
    return d


def _base(fqn):
    wt = tb.get("/api/widgetType?fqn=" + urllib.parse.quote(fqn))
    return json.loads(wt["descriptor"].get("defaultConfig") or "{}"), wt["descriptor"].get("type", "latest")


def _w(fqn, cfg, typ, x, y, w, h):
    wid = str(uuid.uuid4())
    return wid, {"id": wid, "typeFullFqn": fqn, "type": typ, "sizeX": w, "sizeY": h,
                 "row": y, "col": x, "config": cfg}, {"sizeX": w, "sizeY": h, "row": y, "col": x}


ABRIR_SOCIO = {"name": "Ver datos del socio", "icon": "insights", "type": "openDashboardState",
               "targetDashboardStateId": "socio", "setEntityId": True, "stateEntityParamName": None,
               "openRightLayout": False, "openInSeparateDialog": False, "openInPopover": False}
PANEL_MEDIDOR = "Lecturas del medidor"   # panel aparte de versiones anteriores (se borra)


def w_tabla_cec(alias, titulo, col, keys, x, y, w, h, orden="entityLabel", accion=None):
    cfg, typ = _base("system.cards.entities_table")
    cfg["settings"].update({"entitiesTitle": titulo, "displayEntityLabel": True, "entityLabelColumnTitle": col,
                            "displayEntityName": False, "defaultSortOrder": orden,
                            "displayPagination": False, "enableSearch": False,
                            "enableSelectColumnDisplay": False})
    cfg["datasources"] = [{"type": "entity", "entityAliasId": alias, "dataKeys": keys}]
    cfg.update({"title": titulo, "showTitle": False})
    if accion:
        cfg["actions"] = {"rowClick": [dict(accion, id=str(uuid.uuid4()))]}
    return _w("system.cards.entities_table", cfg, typ, x, y, w, h)


# Columnas de la tabla de socios: (clave, etiqueta, tipo, decimales). Los d_* son el
# total del ultimo dia con datos (el ultimo valor de la serie diaria).
CLAVES_SOCIO = [("peaje", "Peaje", "attribute", None), ("potencia", "Potencia (kW)", "attribute", None),
                ("d_consumo_kwh", "Consumo de red (kWh)", "timeseries", 1),
                ("d_vertida_kwh", "Vertido (kWh)", "timeseries", 1),
                ("d_generada_kwh", "Generación FV (kWh)", "timeseries", 1),
                ("datos_hasta", "Último día", "attribute", None)]


def w_socios(alias, x, y, w, h):
    keys = [_dk(k, lab, typ, decimals=d) for k, lab, typ, d in CLAVES_SOCIO]
    return w_tabla_cec(alias, "Socios: energía del último día con datos — pulsa uno para ver sus datos", "Socio",
                       keys, x, y, w, h, accion=ABRIR_SOCIO)


def _ventana(ms, agg, intervalo):
    """Ventana movil de ms con agrupacion (el usuario la cambia con el reloj del widget:
    periodo, agrupar por hora/dia/semana/mes y funcion)."""
    return {"selectedTab": 0, "timezone": E.get("TZ", "Europe/Madrid"),
            "realtime": {"realtimeType": 0, "timewindowMs": ms, "interval": intervalo},
            "aggregation": {"type": agg, "limit": 50000}}


def w_tabla_lecturas(alias, keys, titulo, ventana, x, y, w, h, formato="dd/MM/yyyy HH:mm"):
    """Tabla de series temporales: una fila por valor (o por grupo) con su fecha."""
    cfg, typ = _base("system.cards.timeseries_table")
    cfg["datasources"] = [{"type": "entity", "entityAliasId": alias, "dataKeys": keys}]
    cfg["settings"].update({"showTimestamp": True, "showMilliseconds": False,
                            "dateFormat": {"format": formato},
                            "displayPagination": True, "defaultPageSize": 20,
                            "enableSearch": False, "hideEmptyLines": True})
    cfg.update({"title": titulo, "showTitle": True, "useDashboardTimewindow": False,
                "displayTimewindow": True, "timewindow": ventana})
    return _w("system.cards.timeseries_table", cfg, typ, x, y, w, h)


def w_diaria(alias, x, y, w, h):
    """Energia de cada dia (ultimos 90 dias); con el reloj se agrupa por semana o mes."""
    keys = [_dk("d_" + k, lab, color=c, units="kWh", decimals=2) for k, _, lab, c in SERIES]
    keys.append(_dk("d_red_neto_kwh", "Saldo con la red (+ recibe / − aporta)", color="#8a8a8a",
                    units="kWh", decimals=2))
    return w_tabla_lecturas(alias, keys, "Energía diaria (kWh) — reloj: periodo y agrupar por semana o mes (suma)",
                            _ventana(90 * 86400000, "NONE", 86400000), x, y, w, h, formato="dd/MM/yyyy")


def w_mapa(alias, x, y, w, h):
    """Un rayo por socio en su ubicacion (ficticia): verde si el ultimo dia vertio a la red
    mas de lo que consumio de ella, rojo si consumio mas."""
    cfg, typ = _base("system.map")
    marker = json.loads(json.dumps(cfg["settings"]["markers"][0]))
    color = {"type": "function", "color": "#1e88e5",
             "colorFunction": "var r = data.d_red_neto_kwh;\nif (r === undefined || r === null) return '#9e9e9e';\n"
                              "if (r < -0.05) return '" + COLOR_APORTA + "';\n"
                              "if (r > 0.05) return '" + COLOR_RECIBE + "';\nreturn '#1e88e5';"}
    marker.update({
        "dsType": "entity", "dsLabel": "Socios", "dsEntityAliasId": alias, "dsDeviceId": None, "dsFilterId": None,
        "additionalDataKeys": [_dk(k, k, typ) for k, _, typ, _ in CLAVES_SOCIO] + [_dk("d_red_neto_kwh")],
        "xKey": _dk("latitude", "latitude", "attribute"),
        "yKey": _dk("longitude", "longitude", "attribute"),
        "label": {"show": True, "type": "pattern", "pattern": "${entityLabel}"},
        "tooltip": {"show": True, "trigger": "hover", "autoclose": True, "type": "pattern",
                    "offsetX": 0, "offsetY": -1, "pattern":
                    "<b>${entityLabel}</b> <small>(${peaje}, ${potencia} kW)</small><br/>"
                    "${datos_hasta}: consumo de red ${d_consumo_kwh:1} kWh · vertido ${d_vertida_kwh:1} kWh<br/>"
                    "<b>Saldo con la red ${d_red_neto_kwh:1} kWh</b> <small>(+ recibe / − aporta)</small><br/>"
                    "<small>Pulsa el rayo para ver sus datos</small>"},
        "click": dict(ABRIR_SOCIO, id=str(uuid.uuid4())),
    })
    if "markerIcon" in marker:   # icono de energia (Material "bolt") del color del saldo
        marker["markerType"] = "icon"
        marker["markerIcon"] = dict(marker["markerIcon"] or {}, icon="bolt", size=40, color=color)
    else:                        # mapa sin iconos: marcador de forma con el mismo color
        marker["markerType"] = "shape"
        marker["markerShape"] = {"shape": "markerShape1", "size": 38, "color": color}
    marker.pop("groups", None)
    cfg["settings"]["markers"] = [marker]
    cfg.update({"title": "Socios (ubicación ficticia) — ⚡ verde: aportó a la red el último día · rojo: recibió",
                "showTitle": True, "datasources": []})
    return _w("system.map", cfg, typ, x, y, w, h)


NULL_UUID = "13814000-1dd2-11b2-8080-808080808080"

# Un usuario de un socio entra directamente en la vista de su socio, asi la cabecera
# muestra "Comunidad › Socio" igual que cuando el administrador pulsa un socio.
# (Widget invisible de la vista principal; el administrador se queda en ella.)
REDIRIGE_SOCIO_JS = r"""
var u = ctx.currentUser || {}, sc = ctx.stateController, ds = (ctx.datasources || [])[0];
if (u.authority === 'CUSTOMER_USER' && sc && ds && ds.entityId && sc.getStateId() === 'default') {
  sc.openState('socio', { entityId: { entityType: ds.entityType || 'DEVICE', id: ds.entityId },
                          entityName: ds.entityName, entityLabel: ds.entityLabel }, false);
}
return '';
"""


def w_redirige_socio(alias, x, y, w, h):
    cfg, typ = _base("system.cards.markdown_card")
    cfg["datasources"] = [{"type": "entity", "entityAliasId": alias, "dataKeys": [_dk("d_consumo_kwh", "d_consumo_kwh")]}]
    cfg["settings"].update({"useMarkdownTextFunction": True, "markdownTextFunction": REDIRIGE_SOCIO_JS,
                            "applyDefaultMarkdownStyle": False, "markdownCss": ""})
    cfg.update({"title": "", "showTitle": False, "padding": "0", "dropShadow": False,
                "backgroundColor": "rgba(0,0,0,0)", "enableFullscreen": False})
    return _w("system.cards.markdown_card", cfg, typ, x, y, w, h)


def cec_config(title):
    """Panel estandar de la comunidad, el mismo para todos. El alias "Mi nudo" depende de
    quien mira (CURRENT_USER, relaciones creadas por cec_enlazar): el administrador ve los
    totales de la comunidad y todos los socios; un socio ve solo sus datos y su rayo.
    (Desde CURRENT_USER_OWNER no vale: ThingsBoard no deja a un usuario de cliente
    consultar relaciones que salen de su propio cliente y los alias quedan vacios.)
    Estados: default (mapa, consumo como en Datadis, socios y energia diaria) y socio
    (lo mismo del socio pulsado; sus datos de suministro, en la pestaña Contrato)."""
    al = {}

    def alias(nombre, flt):
        aid = str(uuid.uuid4())
        al[aid] = {"id": aid, "alias": nombre, "filter": flt}
        return aid

    mio = alias("Mi nudo", {"type": "relationsQuery", "resolveMultiple": False, "direction": "FROM", "maxLevel": 1,
                            "fetchLastLevelOnly": False, "filters": [{"relationType": "CecNudo", "entityTypes": ["DEVICE"]}],
                            "rootStateEntity": False, "stateEntityParamName": None, "defaultStateEntity": None,
                            "rootEntity": {"entityType": "CURRENT_USER", "id": NULL_UUID}})
    elegido = alias("Socio elegido", {"type": "stateEntity", "resolveMultiple": False,
                                      "stateEntityParamName": None, "defaultStateEntity": None})
    a_socios = alias("Socios", {"type": "deviceType", "resolveMultiple": True, "deviceType": "socio",
                                "deviceTypes": ["socio"], "deviceNameFilter": ""})

    widgets, lay = {}, {"default": {}, "socio": {}}

    def add(state, t):
        wid, wdef, l = t
        widgets[wid] = wdef
        lay[state][wid] = l

    add("default", con_imprimir(w_mapa(a_socios, 0, 0, 24, 10)))
    add("default", w_consumo(mio, 0, 10, 24, 15))
    add("default", w_socios(a_socios, 0, 25, 24, 7))
    add("default", w_diaria(mio, 0, 32, 24, 9))
    add("default", w_redirige_socio(mio, 0, 41, 24, 1))
    add("socio", con_imprimir(w_mapa(elegido, 0, 0, 24, 8)))
    add("socio", w_consumo(elegido, 0, 8, 24, 15))
    add("socio", w_diaria(elegido, 0, 23, 24, 9))

    grid = {"columns": 24, "margin": 10, "outerMargin": True, "backgroundColor": "#eeeeee"}
    estado_json = lambda nombre, root, st: {"name": nombre, "root": root,
                                            "layouts": {"main": {"widgets": lay[st], "gridSettings": grid}}}
    return {
        "description": "Comunidad energética: mapa de socios y energía horaria y diaria de Datadis",
        "widgets": widgets,
        "states": {"default": estado_json(title, True, "default"),
                   "socio": estado_json("${entityLabel}", False, "socio")},
        "entityAliases": al,
        "filters": {},
        "timewindow": {"selectedTab": 0,
                       "realtime": {"realtimeType": 0, "timewindowMs": 7200000, "interval": 5000},
                       "aggregation": {"type": "NONE", "limit": 5000}},
        "settings": {"stateControllerId": "entity", "showTitle": True,
                     "showDashboardsSelect": False, "showEntitiesSelect": False,
                     "showDashboardTimewindow": False, "showDashboardExport": False,
                     "toolbarAlwaysOpen": True, "dashboardCss": CSS_PANEL},
    }


def cec_panel(title, cfg, firma):
    """Crea o actualiza el panel (se conserva su id: los usuarios lo tienen por defecto)."""
    cfg["cecFirma"] = firma
    d = find(tb.get(page("/api/tenant/dashboards"))["data"], "title", title)
    if d:
        full = tb.get(f"/api/dashboard/{d['id']['id']}")
        if (full.get("configuration") or {}).get("cecFirma") == firma:
            return full
        full["configuration"] = cfg
        print(f"    panel '{title}' actualizado")
        return tb.post("/api/dashboard", full)
    print(f"    panel '{title}' creado")
    return tb.post("/api/dashboard", {"title": title, "configuration": cfg})


def cec_admin(dash_id):
    """Administrador de la comunidad, separado del administrador de ThingsBoard
    (TB_TENANT_EMAIL, acceso a todo). Es TENANT_ADMIN porque en la edicion Community es la
    unica forma de ver los dispositivos de todos los socios, pero queda encerrado en el
    panel de la comunidad: pantalla completa siempre, sin menu lateral ni resto de
    ThingsBoard. (Roles de solo lectura de verdad: ThingsBoard PE.)"""
    tid = tb.get("/api/auth/user")["tenantId"]["id"]
    email = E["CEC_ADMIN_EMAIL"]
    u = find(sa.get(page(f"/api/tenant/{tid}/users"))["data"], "email", email)
    if u:
        u = sa.get(f"/api/user/{u['id']['id']}")
        info = u.get("additionalInfo") or {}
        if (info.get("defaultDashboardId"), info.get("defaultDashboardFullscreen")) != (dash_id, True):
            info.update(defaultDashboardId=dash_id, defaultDashboardFullscreen=True)
            u["additionalInfo"] = info
            u = sa.post("/api/user?sendActivationMail=false", u)
            print(f"    {email}: solo el panel de la comunidad, sin menu lateral")
        idioma(sa, u)
        return
    u = sa.post("/api/user?sendActivationMail=false", {
        "email": email, "authority": "TENANT_ADMIN", "tenantId": {"id": tid, "entityType": "TENANT"},
        "firstName": "Administración", "lastName": CEC,
        "additionalInfo": {"defaultDashboardId": dash_id, "defaultDashboardFullscreen": True,
                           "lang": E["TB_LANG"]}})
    link = http("GET", f"{TB}/api/user/{u['id']['id']}/activationLink", headers=sa.h, raw=True)
    token = urllib.parse.parse_qs(urllib.parse.urlparse(link.strip().strip('"')).query)["activateToken"][0]
    http("POST", TB + "/api/noauth/activate?sendActivationMail=false",
         {"activateToken": token, "password": E["CEC_ADMIN_PASSWORD"]})
    print(f"    administrador de la comunidad '{email}' creado")


# ---- Clientes de ejemplo (perfiles ambiente/energia) ----
customers = tb.get(page("/api/customers"))["data"]
dashboards = tb.get(page("/api/tenant/dashboards"))["data"]
for c in CLIENTES:
    if c["perfil"] not in PERFILES:
        print(f"    AVISO: cliente '{c['cliente']}' con perfil desconocido '{c['perfil']}', se ignora")
        continue
    cust = find(customers, "title", c["cliente"])
    if not cust:
        cust = tb.post("/api/customer", {"title": c["cliente"]})
        print(f"    cliente '{c['cliente']}' creado")
    cid = cust["id"]["id"]
    perfil = PERFILES[c["perfil"]]
    dev = device(c["device"], "simulado-" + c["perfil"])
    tb.post(f"/api/customer/{cid}/device/{dev['id']['id']}")
    dash = find(dashboards, "title", c["panel"])
    if not dash:
        dash = crear_panel(c["panel"], perfil, dev)
        print(f"    panel '{c['panel']}' creado")
    # Solo este panel queda asignado al cliente
    tb.post(f"/api/customer/{cid}/dashboard/{dash['id']['id']}")
    usuario_cliente(cid, c, dash["id"]["id"])

# ---- Comunidad energetica ----
print(f"  - {CEC}: {len(SOCIOS)} socios con datos de Datadis ({DATADIS_DIR})")
cec_limpiar_anterior()
customers = tb.get(page("/api/customers"))["data"]
TENANT = {"entityType": "TENANT", "id": tb.get("/api/auth/user")["tenantId"]["id"]}


def cec_rel(desde, dev, tipo):
    """Relacion desde -> dispositivo (las sigue el alias "Mi nudo" del panel)."""
    try:
        tb.post("/api/relation", {"from": desde, "to": {"entityType": "DEVICE", "id": dev["id"]["id"]},
                                  "type": tipo, "typeGroup": "COMMON"})
    except urllib.error.HTTPError as e:
        print(f"    AVISO: relacion {tipo} -> {dev['name']}: HTTP {e.code}")


def cec_enlazar(n, desde):
    """Usuarios que miran el nudo n (comunidad o socio) -> nudo (relacion CecNudo)."""
    for o in desde:
        cec_rel(o, DEV[n], "CecNudo")


def cec_usuarios(lista):
    return [{"entityType": "USER", "id": u["id"]["id"]} for u in lista]


def _fecha(ts):
    return datetime.fromtimestamp(ts / 1000, TZL).strftime("%d/%m/%Y")


# Socios: cliente, dispositivo con los datos del suministro y su curva de Datadis
cec_dispositivo("comunidad", "comunidad", CEC)
curvas, firmas = [], []
for so in SOCIOS:
    cust = find(customers, "title", so["nombre"])
    if not cust:
        cust = tb.post("/api/customer", {"title": so["nombre"]})
        print(f"    socio '{so['nombre']}' creado")
    so["cid"] = cust["id"]["id"]
    dd = datadis_leer(so["carpeta"]) if so["carpeta"] else None
    attrs = {}
    if so["lat"] is not None:
        attrs.update(latitude=so["lat"], longitude=so["lon"])
    if dd and dd["filas"]:
        c, filas = dd["contrato"], dd["filas"]
        auto = (c.get("tipoAutoconsumo") or "").strip()
        attrs.update(cups=c.get("cups", ""), peaje=peaje(c),
                     potencia=" / ".join(p for p in (c.get("potenciaContratadakW") or "").split(";") if p),
                     autoconsumo=f"sí (tipo {auto})" if auto else "no",
                     resolucion="cuartohoraria" if dd["paso"] == 15 else "horaria",
                     datos_desde=_fecha(filas[0][0]), datos_hasta=_fecha(filas[-1][0]),
                     # pestaña Contrato del widget de consumo y lineas de potencia contratada
                     contrato={k: v for k, v in c.items() if k and v},
                     pcontratada_kw=potencia_por_periodo(c, sorted(
                         {int(k[6:-3]) for x in dd["maximos"] for k in x["values"] if k.endswith("_kw")})))
    cec_dispositivo(so["id"], "socio", so["nombre"], so["cid"], attrs)
    if not dd or not dd["filas"]:
        print(f"    AVISO: {so['nombre']}: sin curva de Datadis en {os.path.join(DATADIS_DIR, so['carpeta'])}")
        continue
    if cec_cargar(so["id"], dd["filas"], dd["firma"], attrs["peaje"], dd["maximos"]):
        print(f"    {so['nombre']}: {len(dd['filas'])} valores de Datadis ({attrs['resolucion']}, "
              f"{attrs['datos_desde']} - {attrs['datos_hasta']})")
    curvas.append(dd["filas"])
    firmas.append(dd["firma"])

# Comunidad: suma horaria de todos los socios
if curvas:
    com = por_hora(curvas)
    tb.post(f"/api/plugins/telemetry/DEVICE/{DEV['comunidad']['id']['id']}/attributes/SERVER_SCOPE",
            {"resolucion": "horaria", "periodos": "2.0TD",
             "datos_desde": _fecha(com[0][0]), "datos_hasta": _fecha(com[-1][0])})
    # La comunidad mezcla peajes: reparte su consumo en punta, llano y valle (2.0TD)
    if cec_cargar("comunidad", com, hashlib.sha1("".join(firmas).encode()).hexdigest()[:16], "2.0TD"):
        print(f"    comunidad: suma horaria de {len(curvas)} socios ({len(com)} horas)")
cec_widget("VatiaCo.consumo", "Consumo (como Datadis)", CONSUMO_HTML, CONSUMO_JS, 15, CONSUMO_CSS)

# Un unico panel estandar: asignado a todos los socios (cada uno ve solo lo suyo) y
# panel de inicio del administrador (ve los totales y, desde el mapa, a cada socio)
panel = cec_panel(CEC, cec_config(CEC), json.dumps([CEC_DASH_VERSION]))
for so in SOCIOS:
    tb.post(f"/api/customer/{so['cid']}/dashboard/{panel['id']['id']}")
    if so["email"]:
        # Solo el panel principal, a pantalla completa y sin menu lateral
        usuario_cliente(so["cid"], {"email": so["email"], "password": so["password"],
                                    "cliente": so["nombre"]}, panel["id"]["id"], fullscreen=True)
cec_admin(panel["id"]["id"])

# Relaciones de cada usuario con su nudo (las sigue la vista principal del panel):
# administradores del tenant -> comunidad; usuarios de un socio -> su socio
cec_enlazar("comunidad", cec_usuarios(sa.get(page(f"/api/tenant/{TENANT['id']}/users"))["data"]))
for so in SOCIOS:
    cec_enlazar(so["id"], cec_usuarios(tb.get(page(f"/api/customer/{so['cid']}/users"))["data"]))

# Ocultar el pie "Powered by ThingsBoard" en todos los paneles del tenant (CSS del panel)
OCULTAR_PIE = "section.tb-powered-by-footer { display: none !important; }"
for d in tb.get(page("/api/tenant/dashboards"))["data"]:
    full = tb.get(f"/api/dashboard/{d['id']['id']}")
    st_ = full.setdefault("configuration", {}).setdefault("settings", {})
    if OCULTAR_PIE not in (st_.get("dashboardCss") or ""):
        st_["dashboardCss"] = ((st_.get("dashboardCss") or "") + "\n" + OCULTAR_PIE).strip()
        tb.post("/api/dashboard", full)
        print(f"    panel '{d['title']}': sin pie 'Powered by ThingsBoard'")
print(f"  - ThingsBoard OK (gateway token {gw_token})")

# ---------------- Node-RED ----------------
print("  - Node-RED: esperando...")
if not wait(NR + "/", 300):
    raise SystemExit("    ERROR: Node-RED no responde")
nr_tok = http("POST", NR + "/auth/token", {
    "client_id": "node-red-admin", "grant_type": "password", "scope": "*",
    "username": E["NODERED_USER"], "password": E["NODERED_PASSWORD"]})["access_token"]
NRH = {"Authorization": "Bearer " + nr_tok}

bridge_fn = """const device = msg.topic.split('/')[1];
if (typeof msg.payload !== 'object' || msg.payload === null) return null;
msg.topic = 'v1/gateway/telemetry';
msg.payload = { [device]: [{ ts: Date.now(), values: msg.payload }] };
return msg;"""

wanted = [
    {"id": "iot-broker-mosq", "type": "mqtt-broker", "name": "Mosquitto",
     "broker": "mosquitto", "port": E["MQTT_PORT"], "clientid": "", "protocolVersion": "4",
     "keepalive": "60", "cleansession": True, "autoConnect": True,
     "credentials": {"user": E["MQTT_USER"], "password": E["MQTT_PASSWORD"]}},
    {"id": "iot-broker-tb", "type": "mqtt-broker", "name": "ThingsBoard Gateway",
     "broker": "thingsboard", "port": "1883", "clientid": "nodered-gw", "protocolVersion": "4",
     "keepalive": "60", "cleansession": True, "autoConnect": True,
     "credentials": {"user": gw_token, "password": ""}},
    # Puente: iot/<dispositivo>/telemetry (Mosquitto) -> Gateway API de ThingsBoard
    {"id": "iot-tab", "type": "tab", "label": "Mosquitto -> ThingsBoard",
     "info": "Publica en Mosquitto `iot/<dispositivo>/telemetry` un JSON y llega a ThingsBoard."},
    {"id": "iot-in", "type": "mqtt in", "z": "iot-tab", "name": "iot/+/telemetry",
     "topic": "iot/+/telemetry", "qos": "1", "datatype": "json", "broker": "iot-broker-mosq",
     "nl": False, "rap": True, "inputs": 0, "x": 160, "y": 100, "wires": [["iot-fn"]]},
    {"id": "iot-fn", "type": "function", "z": "iot-tab", "name": "a formato Gateway API",
     "func": bridge_fn, "outputs": 1, "x": 390, "y": 100, "wires": [["iot-out"]]},
    {"id": "iot-out", "type": "mqtt out", "z": "iot-tab", "name": "ThingsBoard",
     "topic": "", "qos": "1", "retain": "false", "broker": "iot-broker-tb",
     "x": 620, "y": 100, "wires": []},
]

# Simuladores: uno por cliente, publican por MQTT en Mosquitto como sensores reales.
# El primero conserva los ids "sim-*" de versiones anteriores del script.
for i, c in enumerate(CLIENTES):
    if c["perfil"] not in PERFILES:
        continue
    p = "sim" if i == 0 else "sim-" + re.sub(r"[^a-z0-9]+", "-", c["device"].lower())
    topic = f"iot/{c['device']}/telemetry"
    wanted += [
        {"id": f"{p}-tab", "type": "tab", "label": "Simulador " + c["device"],
         "info": f"{c['cliente']}: publica cada {E['SIM_INTERVAL']} s en `{topic}`."},
        {"id": f"{p}-inject", "type": "inject", "z": f"{p}-tab", "name": f"cada {E['SIM_INTERVAL']} s",
         "props": [], "repeat": E["SIM_INTERVAL"], "once": True, "onceDelay": "3",
         "x": 150, "y": 100, "wires": [[f"{p}-fn"]]},
        {"id": f"{p}-fn", "type": "function", "z": f"{p}-tab", "name": "lecturas simuladas",
         "func": PERFILES[c["perfil"]]["sim"], "outputs": 1, "x": 360, "y": 100,
         "wires": [[f"{p}-out", f"{p}-debug"]]},
        {"id": f"{p}-out", "type": "mqtt out", "z": f"{p}-tab", "name": topic,
         "topic": topic, "qos": "1", "retain": "false", "broker": "iot-broker-mosq",
         "x": 600, "y": 80, "wires": []},
        {"id": f"{p}-debug", "type": "debug", "z": f"{p}-tab", "name": "lectura", "active": False,
         "complete": "payload", "x": 570, "y": 140, "wires": []},
    ]

# Comunidad energetica: sus datos son los de Datadis, que carga este script en
# ThingsBoard. Se retiran los flujos de versiones anteriores (medidores simulados
# y suma por socio y comunidad: ids cec2-*).
current = http("GET", NR + "/flows", headers={**NRH, "Node-RED-API-Version": "v1"})
# Flujos de la comunidad de versiones anteriores (sitios churriana-0x, medidores cec2-*)
viejos = [n for n in current
          if n["id"].startswith("sim-churriana-01") or n.get("z") == "sim-churriana-01-tab"
          or n["id"] == "cec-tab" or n.get("z") == "cec-tab"
          or n["id"].startswith("cec2-") or str(n.get("z", "")).startswith("cec2-")]
# Brokers con otra direccion (p.ej. "localhost" de la version con red del host)
brokers = {n["id"]: n for n in wanted if n["type"] == "mqtt-broker"}
viejos += [n for n in current if n["id"] in brokers
           and (n.get("broker"), str(n.get("port"))) != (brokers[n["id"]]["broker"], str(brokers[n["id"]]["port"]))]
current = [n for n in current if n not in viejos]
ids = {n["id"] for n in current}
missing = [n for n in wanted if n["id"] not in ids]
if missing or viejos:
    http("POST", NR + "/flows", current + missing,
         {**NRH, "Node-RED-API-Version": "v1", "Node-RED-Deployment-Type": "full"}, raw=True)
    print(f"  - Node-RED: {len(missing)} nodos desplegados, {len(viejos)} retirados")
else:
    print("  - Node-RED: flujos ya presentes, no se modifican")
PY

echo "==> Exportando ThingsBoard y Node-RED a $INSTALL_DIR/export"
./export.sh || echo "    AVISO: la exportacion ha fallado (se puede repetir con ./export.sh)"

# Certificado del 8883: Caddy ya habra obtenido el de Let's Encrypt si hay dominio.
# Cron semanal para seguir las renovaciones de Caddy (idempotente).
./mqtt-cert.sh || echo "    AVISO: no se pudo actualizar el certificado MQTT (./mqtt-cert.sh)"
if command -v crontab >/dev/null 2>&1; then
  CRON="17 4 * * 1 $INSTALL_DIR/mqtt-cert.sh >/dev/null 2>&1"
  if ! crontab -l 2>/dev/null | grep -qF "$INSTALL_DIR/mqtt-cert.sh"; then
    (crontab -l 2>/dev/null; echo "$CRON") | crontab -
    echo "    cron: mqtt-cert.sh cada lunes a las 04:17"
  fi
fi

# --------------------------------------------
# 10. Resumen
# --------------------------------------------
cat > README.md <<EOF
# Stack IoT ThingsBoard (red bridge)

| Servicio | Acceso | Credenciales |
|---|---|---|
| ThingsBoard (HTTPS) | https://$IP | $TB_TENANT_EMAIL / $TB_TENANT_PASSWORD · sysadmin@thingsboard.org / $TB_SYSADMIN_PASSWORD |
$(for c in "${CLIENTES[@]}"; do IFS='|' read -r n e pw d pa pf <<< "$c"; echo "| Panel '$pa' ($n) | (login de cliente) | $e / $pw |"; done)
$( [ -n "$TB_DOMAIN" ] && echo "| ThingsBoard (Internet) | https://$TB_DOMAIN | (las mismas) |" )
| $CEC_NOMBRE (administrador) | (login de administrador) | $CEC_ADMIN_EMAIL / $CEC_ADMIN_PASSWORD |
$(for s_ in "${SOCIOS[@]}"; do IFS='|' read -r n e pw pf sim <<< "$s_"; [ -n "$e" ] && echo "| $CEC_NOMBRE ($n) | (login de socio) | $e / $pw |"; done)
| Mosquitto (TLS) | mqtts://${TB_DOMAIN:-$IP}:$MQTTS_PORT | $MQTT_USER / $MQTT_PASSWORD |
| Mosquitto (WebSocket TLS) | wss://${TB_DOMAIN:-$IP}/mqtt | $MQTT_USER / $MQTT_PASSWORD |
| Node-RED (tunel SSH) | http://127.0.0.1:$NODERED_PORT | $NODERED_USER / $NODERED_PASSWORD |
| PostgreSQL | postgres:5432 (solo red interna) | $PG_USER / $PG_PASSWORD |
| Adminer (tools, tunel SSH) | http://127.0.0.1:$ADMINER_PORT/?pgsql=postgres&username=$PG_USER&db=thingsboard | sistema **PostgreSQL** (no MySQL) · $PG_USER / $PG_PASSWORD |
| Homepage (portada de servicios) | http://$IP:$HOMEPAGE_PORT | — |
| Web Astro (proman) | http://$IP:$PROMAN_PORT | — (recompilar: \`./web.sh\`) |
| MQTT Explorer (tools, tunel SSH) | http://127.0.0.1:$MQTTX_PORT | $MQTT_USER / $MQTT_PASSWORD (conexion "Mosquitto" precargada) |

Solo se publican 80/443 (Caddy) y $MQTTS_PORT (MQTT con TLS). Node-RED, Adminer y
MQTT Explorer escuchan en 127.0.0.1; desde otro equipo:

\`\`\`bash
ssh -L $NODERED_PORT:127.0.0.1:$NODERED_PORT -L $ADMINER_PORT:127.0.0.1:$ADMINER_PORT -L $MQTTX_PORT:127.0.0.1:$MQTTX_PORT $USER@$IP
./tools.sh up      # arranca Adminer y MQTT Explorer (./tools.sh down para pararlos)
\`\`\`

## Comunidad energética

Los datos de energía de cada socio son los de Datadis: curva de carga (horaria o
cuartohoraria) y contrato de la descarga web, en \`$DATADIS_DIR/<carpeta>\`
(\`Consumo_*.csv\` y \`Contrato_*.csv\`). Solo la ubicación del mapa es ficticia.

- En ThingsBoard, cada socio (dispositivo tipo \`socio\`) tiene \`consumo_kwh\`, \`vertida_kwh\`,
  \`generada_kwh\` y \`autoconsumo_kwh\` por periodo de medida, los totales diarios \`d_*\` y,
  como atributos, CUPS, peaje y potencia. \`comunidad\` es la suma horaria de todos.
- Datos nuevos: descarga de nuevo en Datadis a la misma carpeta y vuelve a ejecutar
  iot-thingsboard.sh (solo recarga los socios cuyos ficheros han cambiado).
- Socio nuevo: añádelo a SOCIOS en iot-thingsboard.sh con su carpeta y sus coordenadas.

## Carpetas

| Carpeta | Contenido |
|---|---|
| \`config/\` | mosquitto.conf + passwd, Caddyfile, settings.js de Node-RED |
| \`data/postgres\` | base de datos de ThingsBoard |
| \`data/thingsboard\`, \`data/thingsboard-logs\` | datos y logs de ThingsBoard |
| \`data/nodered\` | flujos (flows.json) y nodos de Node-RED |
| \`data/mosquitto\`, \`data/caddy\` | persistencia MQTT y certificados |
| \`backups/postgres\` | copia diaria de PostgreSQL (pg_dump, 7 dias) |
| \`export/\` | JSON de tenants, clientes, usuarios, dispositivos, paneles, reglas y flujos (\`./export.sh\`) |

Copia de la base de datos: diaria en \`backups/postgres\` (servicio pg-backup). Restaurar:
\`docker compose exec -T postgres pg_restore -U $PG_USER -d thingsboard --clean < backups/postgres/<fichero>.dump\`

Copia completa: \`./stop.sh && sudo tar czf iot-tb-backup.tgz -C ~ iot-tb && ./start.sh\`

Prueba de extremo a extremo (crea el dispositivo \`sensor1\` en ThingsBoard):

\`\`\`bash
docker exec iot-mosquitto mosquitto_pub -p $MQTT_PORT -u $MQTT_USER -P '$MQTT_PASSWORD' \\
  -t iot/sensor1/telemetry -m '{"temperatura": 21.5}'
\`\`\`

Desde la LAN o Internet, por MQTT con TLS (puerto $MQTTS_PORT; con certificado autofirmado
hay que añadir \`--insecure\`):

\`\`\`bash
mosquitto_pub -h ${TB_DOMAIN:-$IP} -p $MQTTS_PORT --capath /etc/ssl/certs -u $MQTT_USER -P '$MQTT_PASSWORD' \\
  -t iot/sensor1/telemetry -m '{"temperatura": 21.5}'
\`\`\`

O por MQTT sobre WebSocket con TLS (puerto 443):

- URL: \`wss://${TB_DOMAIN:-$IP}/mqtt\` · usuario \`$MQTT_USER\` · contraseña \`$MQTT_PASSWORD\`
- Topic: \`iot/<dispositivo>/telemetry\` con un JSON; Node-RED lo pasa a ThingsBoard.

\`\`\`python
# pip install paho-mqtt
import json, ssl, paho.mqtt.client as mqtt
c = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, transport="websockets")
c.ws_set_options(path="/mqtt")
c.tls_set(cert_reqs=ssl.CERT_REQUIRED)
c.username_pw_set("$MQTT_USER", "$MQTT_PASSWORD")
c.connect("${TB_DOMAIN:-$IP}", 443)
c.publish("iot/sensor-remoto/telemetry", json.dumps({"temperatura": 19.4}), qos=1).wait_for_publish()
\`\`\`

O por HTTP directamente a ThingsBoard:

\`\`\`bash
curl -k -X POST https://$IP/api/v1/<TOKEN_DISPOSITIVO>/telemetry -d '{"temperatura": 21.5}'
\`\`\`
EOF

echo
echo "============================================"
echo " Stack IoT listo"
echo "============================================"
echo " ThingsBoard HTTPS : https://$SERVE_IP  o  https://$IP   (certificado interno: acepta el aviso)"
[ -n "$TB_DOMAIN" ] && echo " ThingsBoard WAN   : https://$TB_DOMAIN   (router: 80 y 443 TCP -> $SERVE_IP)"
[ -n "$TB_DOMAIN" ] && echo " MQTT WAN          : wss://$TB_DOMAIN/mqtt"
echo "   $TB_TENANT_EMAIL / $TB_TENANT_PASSWORD  (administrador de ThingsBoard: acceso a todo)"
echo "   sysadmin@thingsboard.org / $TB_SYSADMIN_PASSWORD"
for c in "${CLIENTES[@]}"; do
  IFS='|' read -r n e pw d pa pf <<< "$c"
  echo "   $e / $pw  (cliente '$n', solo ve '$pa')"
done
echo " $CEC_NOMBRE:"
echo "   $CEC_ADMIN_EMAIL / $CEC_ADMIN_PASSWORD  (administrador de la comunidad: solo su panel, todos los socios)"
for s_ in "${SOCIOS[@]}"; do
  IFS='|' read -r n e pw pf sim <<< "$s_"
  [ -n "$e" ] && echo "   $e / $pw  (socio '$n', solo ve su panel)"
done
echo " Node-RED          : http://127.0.0.1:$NODERED_PORT  ($NODERED_USER / $NODERED_PASSWORD, tunel SSH)"
for c in "${CLIENTES[@]}"; do
  IFS='|' read -r n e pw d pa pf <<< "$c"
  echo "   simulador '$d' ($pf) -> iot/$d/telemetry cada ${SIM_INTERVAL}s"
done
echo "   comunidad: ${#SOCIOS[@]} socios con datos de Datadis ($DATADIS_DIR)"
echo " Mosquitto TLS     : mqtts://${TB_DOMAIN:-$IP}:$MQTTS_PORT  ($MQTT_USER / $MQTT_PASSWORD)"
echo "   WebSocket       : wss://${TB_DOMAIN:-$IP}/mqtt  (mismas credenciales, TLS via Caddy)"
echo " Homepage          : http://$IP:$HOMEPAGE_PORT   (portada de los servicios del servidor)"
echo " Web Astro (proman): http://$IP:$PROMAN_PORT   (de $PROMAN_DIR; recompilar con ./web.sh)"
echo " Herramientas      : ./tools.sh up   (Adminer y MQTT Explorer, solo 127.0.0.1)"
echo "   Adminer (BD)    : http://127.0.0.1:$ADMINER_PORT/?pgsql=postgres&username=$PG_USER&db=thingsboard"
echo "   MQTT Explorer   : http://127.0.0.1:$MQTTX_PORT  ($MQTT_USER / $MQTT_PASSWORD, pulsa CONNECT en 'Mosquitto')"
echo "   desde otro equipo: ssh -L $NODERED_PORT:127.0.0.1:$NODERED_PORT -L $ADMINER_PORT:127.0.0.1:$ADMINER_PORT -L $MQTTX_PORT:127.0.0.1:$MQTTX_PORT $USER@$IP"
echo " Copias PostgreSQL : $INSTALL_DIR/backups/postgres  (diarias, 7 dias)"
echo " Carpeta           : $INSTALL_DIR  (README.md con ejemplos)"
echo "   config/  ficheros de configuracion    data/  datos de cada contenedor"
echo "   export/  JSON de ThingsBoard y Node-RED (actualizar con ./export.sh)"
echo
docker compose ps
