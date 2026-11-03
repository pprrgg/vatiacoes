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

# Todo el stack vive en esta carpeta del host (config, datos, exportaciones)
INSTALL_DIR="$HOME/iot-tb"
IP="192.168.1.134"          # IP wifi: la que usas para administrar (GUIs, Homepage)
SERVE_IP="192.168.1.135"    # IP cableada: el router redirige aqui 80/443 (HTTPS de TB y MQTT)
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
DUCKDNS_VERSION="version-d860cc34"

TB_LANG="es_ES"         # idioma de la interfaz para todos los usuarios
BRAND="VatiaCo"      # texto del logo que sustituye al de ThingsBoard
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

# Comunidad energetica. Los medidores de cada socio publican en Mosquitto
# (cec/<socio>/<sensor>), Node-RED suma por socio y por comunidad y lo manda a
# ThingsBoard. Un unico panel estandar (mapa de socios + datos): el administrador ve
# los totales de la comunidad y, pulsando un rayo del mapa, los de cada socio; cada
# socio ve el mismo panel solo con sus datos.
CEC_NOMBRE="Comunidad Energética Churriana"
CEC_ADMIN_EMAIL="admin-cec@$HOSTNAME_LAN.local"   # administrador: ve la comunidad y a todos los socios
CEC_ADMIN_PASSWORD="cec"

# Socios: "Nombre|email de login|contraseña|perfil de consumo|simulado|latitud|longitud"
#   Nombre: el que mandan los medidores en "socio" (se compara sin acentos ni mayusculas)
#   email vacio: socio sin usuario (solo lo ve el administrador)
#   perfil: Doméstico | Comercial | Industrial (forma de la curva del simulador)
#   simulado: si -> Node-RED simula sus medidores · no -> llegan de medidores reales por MQTT
#   latitud/longitud: posicion de su rayo en el mapa del panel
SOCIOS=(
  "Ana García|ana@$HOSTNAME_LAN.local|ana|Doméstico|si|36.66520|-4.49830"
  "Luis Moreno|luis@$HOSTNAME_LAN.local|luis|Doméstico|si|36.67020|-4.50190"
  "Carmen Ruiz|carmen@$HOSTNAME_LAN.local|carmen|Doméstico|si|36.66710|-4.49610"
  "Colegio Churriana|colegio@$HOSTNAME_LAN.local|colegio|Comercial|si|36.66190|-4.50300"
  "Polideportivo|polideportivo@$HOSTNAME_LAN.local|poli|Comercial|si|36.66880|-4.49520"
  "Panadería La Espiga|panaderia@$HOSTNAME_LAN.local|panaderia|Comercial|si|36.66410|-4.49990"
  "Nave Industrial Sur|nave@$HOSTNAME_LAN.local|nave|Industrial|si|36.65950|-4.49280"
)

# Medidores de cada socio: uno o varios por punto de medida.
#   "Socio|sensor|punto|modelo|kW|kWh"
#   punto: fv | eolica | bateria | consumo | ve | red
#   kW: pico (FV, eolica), potencia (bateria, cargador) o contratada (consumo); kWh: capacidad
#   Los medidores reales no hace falta listarlos: aparecen al publicar y, al volver a
#   ejecutar este script, se asignan a su socio. Listarlos les da etiqueta desde el principio.
SENSORES=(
  "Ana García|em-red|red|EM340||"
  "Ana García|em-fv|fv|EM340|5|"
  "Ana García|em-casa|consumo|EM340|4.6|"
  "Ana García|em-bateria|bateria|EM340|3|5"
  "Ana García|em-coche|ve|EM112|7.4|60"
  "Luis Moreno|em-red|red|EM340||"
  "Luis Moreno|em-fv|fv|EM340|4|"
  "Luis Moreno|em-casa|consumo|EM340|5.75|"
  "Carmen Ruiz|em-red|red|EM340||"
  "Carmen Ruiz|em-fv|fv|EM340|3|"
  "Carmen Ruiz|em-casa|consumo|EM340|3.45|"
  "Carmen Ruiz|em-coche|ve|EM112|3.7|40"
  "Colegio Churriana|em-red|red|EM24||"
  "Colegio Churriana|em-fv-norte|fv|EM24|15|"
  "Colegio Churriana|em-fv-sur|fv|EM24|15|"
  "Colegio Churriana|em-aulas|consumo|EM24|25|"
  "Colegio Churriana|em-comedor|consumo|EM24|10|"
  "Colegio Churriana|em-bateria|bateria|EM24|10|20"
  "Polideportivo|em-red|red|EM24||"
  "Polideportivo|em-fv|fv|EM24|20|"
  "Polideportivo|em-eolica|eolica|EM24|6|"
  "Polideportivo|em-pistas|consumo|EM24|20|"
  "Polideportivo|em-cargador|ve|EM24|22|80"
  "Panadería La Espiga|em-red|red|EM340||"
  "Panadería La Espiga|em-fv|fv|EM340|10|"
  "Panadería La Espiga|em-hornos|consumo|EM340|15|"
  "Nave Industrial Sur|em-red|red|EM24||"
  "Nave Industrial Sur|em-fv|fv|EM24|40|"
  "Nave Industrial Sur|em-eolica|eolica|EM24|10|"
  "Nave Industrial Sur|em-maquinaria|consumo|EM24|40|"
  "Nave Industrial Sur|em-bateria|bateria|EM24|15|30"
)
SIM_INTERVAL="5"                      # segundos entre lecturas de los simuladores

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
OCUPADOS=()
for p in 80 443 "$MQTTS_PORT" "$NODERED_PORT"; do
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
mkdir -p "$INSTALL_DIR"/config/{mosquitto,caddy,nodered,branding} \
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
chmod +x start.sh stop.sh logs.sh tools.sh

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
docker compose pull -q

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
  python3 - "$BRAND" "$COLOR_BG" config/branding/index.orig.html > config/branding/index.html <<'PY'
import sys
brand, bg, orig = sys.argv[1:]
html = open(orig, encoding="utf-8").read()
html = html.replace("<title>ThingsBoard</title>", f"<title>{brand}</title>")
html = html.replace("background-color: #eee;", f"background-color: {bg};")
# La aplicacion pone titulos como "ThingsBoard | Inicio": se sustituye la marca al vuelo
titulo = ("<script>(function(){var B=" + repr(brand) + ";var t=document.querySelector('title');"
          "function f(){if(document.title.indexOf('ThingsBoard')>=0)"
          "document.title=document.title.replace(/ThingsBoard/g,B);}"
          "new MutationObserver(f).observe(t,{childList:true,characterData:true,subtree:true});f();})();"
          "</script>")
html = html.replace("</head>", '  <link rel="stylesheet" href="/branding/VatiaCo.css"/>\n  '
                    + titulo + "\n</head>", 1)
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
#    - flujos de Node-RED: puente Mosquitto -> TB y simulador
# --------------------------------------------
echo "==> Configurando ThingsBoard y Node-RED..."
TB_URL="https://localhost" NR_URL="http://127.0.0.1:$NODERED_PORT" \
TB_SYSADMIN_PASSWORD="$TB_SYSADMIN_PASSWORD" TB_TENANT_PASSWORD="$TB_TENANT_PASSWORD" \
TB_TENANT_EMAIL="$TB_TENANT_EMAIL" TB_LANG="$TB_LANG" \
TB_GATEWAY_NAME="$TB_GATEWAY_NAME" SIM_INTERVAL="$SIM_INTERVAL" \
CLIENTES="$(printf '%s\n' "${CLIENTES[@]}")" \
CEC_NOMBRE="$CEC_NOMBRE" CEC_ADMIN_EMAIL="$CEC_ADMIN_EMAIL" CEC_ADMIN_PASSWORD="$CEC_ADMIN_PASSWORD" \
SOCIOS="$(printf '%s\n' "${SOCIOS[@]}")" SENSORES="$(printf '%s\n' "${SENSORES[@]}")" TZ="$TZ" \
NODERED_USER="$NODERED_USER" NODERED_PASSWORD="$NODERED_PASSWORD" \
MQTT_PORT="$MQTT_PORT" MQTT_USER="$MQTT_USER" MQTT_PASSWORD="$MQTT_PASSWORD" \
python3 - <<'PY'
import json, math, os, random, re, ssl, time, urllib.error, urllib.parse, urllib.request, uuid
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


def usuario_cliente(cid, c, dash_id):
    users = tb.get(page(f"/api/customer/{cid}/users"))["data"]
    user = find(users, "email", c["email"])
    if user:
        # Asegura que su panel por defecto es el suyo
        user = tb.get(f"/api/user/{user['id']['id']}")
        info = user.get("additionalInfo") or {}
        if info.get("defaultDashboardId") != dash_id:
            info["defaultDashboardId"] = dash_id
            user["additionalInfo"] = info
            user = tb.post("/api/user?sendActivationMail=false", user)
        idioma(tb, user)
        return
    u = tb.post("/api/user?sendActivationMail=false", {
        "email": c["email"], "authority": "CUSTOMER_USER", "firstName": c["cliente"],
        "customerId": {"id": cid, "entityType": "CUSTOMER"},
        "additionalInfo": {"defaultDashboardId": dash_id, "defaultDashboardFullscreen": False,
                           "lang": E["TB_LANG"]},
    })
    link = http("GET", f"{TB}/api/user/{u['id']['id']}/activationLink", headers=tb.h, raw=True)
    token = urllib.parse.parse_qs(urllib.parse.urlparse(link.strip().strip('"')).query)["activateToken"][0]
    http("POST", TB + "/api/noauth/activate?sendActivationMail=false",
         {"activateToken": token, "password": c["password"]})
    print(f"    usuario '{c['email']}' creado")




# ======================= Comunidad energetica =======================
# Cada socio tiene uno o varios medidores (Carlo Gavazzi EM24 / EM340 / EM112 o
# similares) que una pasarela Modbus -> MQTT publica en Mosquitto:
#   topic cec/<socio>/<sensor>   JSON con socio (nombre), sensor, rol, p_w, kwh_imp, kwh_exp...
# Node-RED normaliza las lecturas, suma por socio y por comunidad y lo manda a
# ThingsBoard por la Gateway API. Dispositivos en ThingsBoard:
#   <socio>/<sensor>   tipo "medidor"    lecturas del medidor (V, I, P, FP, kWh+/kWh-)
#   <socio>.<rol>      tipo "punto"      potencia, entra/sale hoy, neto ayer, horario y diario
#   <socio>            tipo "socio"      resumen: potencia de cada punto y SoC
#   comunidad.<rol>, comunidad            lo mismo para el total de la comunidad
# <socio> es el nombre sin acentos, en minusculas y con guiones ("Ana García" -> ana-garcia).
# Convenio de signos: + entra al nudo del socio (FV, eolica, descarga, compra a la red),
# - sale (consumo, carga de bateria o coche, vertido a la red). La suma (balance) es 0.
import hashlib, unicodedata
from datetime import timedelta

ROLES = [("fv", "Fotovoltaica", "#2e9d6b"), ("eolica", "Eólica", "#2f7fd8"),
         ("bateria", "Batería", "#c07a12"), ("consumo", "Consumo", "#e0541f"),
         ("ve", "Cargador VE", "#8e44ad"), ("red", "Red", "#8a8a8a")]
ROL_LABEL = {r: l for r, l, _ in ROLES} | {"balance": "Balance del nudo"}
ROL_COLOR = {r: c for r, _, c in ROLES}
ORDEN = {r: i for i, (r, _, _) in enumerate(ROLES)} | {"balance": 99}
CEC = E["CEC_NOMBRE"]
DIAS_HIST = 14                  # dias de historico simulado para los nudos nuevos
CEC_DASH_VERSION = 3            # sube este numero para regenerar los paneles de la comunidad
SIM_VERSION = "cec2 v1"         # idem para redesplegar las funciones de Node-RED
OCULTAR_PIE = "section.tb-powered-by-footer { display: none !important; }"


def slug(texto):
    t = unicodedata.normalize("NFD", str(texto)).encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", "-", t).strip("-")


SOCIOS = []
for l in E["SOCIOS"].splitlines():
    if l.strip():
        nombre, email, pw, perfil, simulado, lat, lon = (l.split("|") + [""] * 7)[:7]
        SOCIOS.append({"id": slug(nombre), "nombre": nombre.strip(), "email": email.strip(), "password": pw,
                       "perfil": perfil.strip() or "Doméstico",
                       "lat": float(lat) if lat.strip() else None, "lon": float(lon) if lon.strip() else None,
                       "simulado": simulado.strip().lower() in ("si", "sí", "s", "yes", "1", "true"),
                       "sensores": []})
SOCIO = {so["id"]: so for so in SOCIOS}
for l in E["SENSORES"].splitlines():
    if not l.strip():
        continue
    socio, sensor, rol, modelo, kw, kwh = (l.split("|") + [""] * 6)[:6]
    so, rol = SOCIO.get(slug(socio)), slug(rol)
    if not so or rol not in ROL_COLOR:
        print(f"    AVISO: medidor ignorado (socio o punto desconocido): {l}")
        continue
    kw = float(kw or 0) or 1.0
    so["sensores"].append({
        "sensor": slug(sensor), "rol": rol, "modelo": modelo.strip() or "EM24", "kw": kw,
        "kwh": float(kwh or 0) or (2 * kw if rol == "bateria" else 40.0),
        "serie": "KX" + hashlib.md5(f"{so['id']}/{slug(sensor)}".encode()).hexdigest()[:8].upper()})


# ---- Modelo de simulacion (el mismo que CEC_SIM_JS en Node-RED) ----
def _gauss(h, mu, sd):
    return math.exp(-0.5 * ((h - mu) / sd) ** 2)


def _sig(x):
    return 1 / (1 + math.exp(-x))


def _forma(perfil, h):
    if perfil == "Comercial":
        return 0.12 + 0.55 * _gauss(h, 11.5, 2.8) + 0.45 * _gauss(h, 17.5, 2.2)
    if perfil == "Industrial":
        return 0.2 + 0.65 * _sig((h - 7) * 3) * _sig((19 - h) * 3)
    return 0.12 + 0.3 * _gauss(h, 8.5, 1) + 0.25 * _gauss(h, 14.5, 1.2) + 0.55 * _gauss(h, 21, 1.5)


def cec_flujos(so, s, h, dt):
    """Potencia (kW, + entra al nudo) de cada medidor del socio en este instante."""
    s["nubes"] = min(0.6, max(0, s["nubes"] + (random.random() - 0.5) * 0.08))
    s["viento"] = min(0.95, max(0.05, s["viento"] + (random.random() - 0.5) * 0.06))
    sol = max(0, math.sin(math.pi * (h - 7) / 13))
    de = lambda r: [x for x in so["sensores"] if x["rol"] == r]
    k, gen, dem, ve, bat = {}, 0, 0, 0, 0
    for x in de("fv"):
        p = x["kw"] * 0.85 * sol ** 1.2 * (1 - 0.6 * s["nubes"])
        k[x["sensor"]] = p
        gen += p
    for x in de("eolica"):
        p = x["kw"] * s["viento"] ** 3
        k[x["sensor"]] = p
        gen += p
    for x in de("consumo"):
        p = x["kw"] * 0.55 * _forma(so["perfil"], h) * (0.92 + random.random() * 0.16)
        k[x["sensor"]] = -p
        dem += p
    ves = de("ve")
    if ves:
        kwh, kw = sum(x["kwh"] for x in ves), sum(x["kw"] for x in ves)
        conectado = (h >= 19 or h < 7) if so["perfil"] == "Doméstico" else (9 <= h < 18)
        if conectado:
            ve = min(kw, max(0, (0.9 - s["soc_ve"]) * kwh / dt / 0.92))
            s["soc_ve"] += ve * 0.92 * dt / kwh
        else:
            s["soc_ve"] = max(0.2, s["soc_ve"] - 0.04 * dt)
        for x in ves:
            k[x["sensor"]] = -ve * x["kw"] / kw
    bats = de("bateria")
    if bats:
        kwh, kw = sum(x["kwh"] for x in bats), sum(x["kw"] for x in bats)
        exc = gen - dem - ve
        if exc > 0:
            c = min(exc, kw, max(0, (0.95 - s["soc_bat"]) * kwh / dt / 0.95))
            s["soc_bat"] += c * 0.95 * dt / kwh
            bat = -c
        else:
            d = min(-exc, kw, max(0, (s["soc_bat"] - 0.1) * kwh / dt))
            s["soc_bat"] -= d * dt / kwh
            bat = d
        for x in bats:
            k[x["sensor"]] = bat * x["kw"] / kw
    reds = de("red")
    for x in reds:
        k[x["sensor"]] = (dem + ve - gen - bat) / len(reds)
    return k


CEC_SIM_JS = r"""
function gauss(h, mu, sd) { return Math.exp(-0.5 * Math.pow((h - mu) / sd, 2)); }
function sig(x) { return 1 / (1 + Math.exp(-x)); }
function forma(perfil, h) {
  if (perfil === 'Comercial') return 0.12 + 0.55 * gauss(h, 11.5, 2.8) + 0.45 * gauss(h, 17.5, 2.2);
  if (perfil === 'Industrial') return 0.2 + 0.65 * sig((h - 7) * 3) * sig((19 - h) * 3);
  return 0.12 + 0.3 * gauss(h, 8.5, 1) + 0.25 * gauss(h, 14.5, 1.2) + 0.55 * gauss(h, 21, 1.5);
}
const clamp = (v, a, b) => Math.min(b, Math.max(a, v));
const suma = (xs, k) => xs.reduce((a, x) => a + x[k], 0);
// Potencia (kW, + entra al nudo) de cada medidor del socio en este instante
function flujos(so, s, h, dt) {
  s.nubes = clamp(s.nubes + (Math.random() - 0.5) * 0.08, 0, 0.6);
  s.viento = clamp(s.viento + (Math.random() - 0.5) * 0.06, 0.05, 0.95);
  const sol = Math.max(0, Math.sin(Math.PI * (h - 7) / 13));
  const de = r => so.sensores.filter(x => x.rol === r);
  const k = {};
  let gen = 0, dem = 0, ve = 0, bat = 0;
  for (const x of de('fv')) { const p = x.kw * 0.85 * Math.pow(sol, 1.2) * (1 - 0.6 * s.nubes); k[x.sensor] = p; gen += p; }
  for (const x of de('eolica')) { const p = x.kw * Math.pow(s.viento, 3); k[x.sensor] = p; gen += p; }
  for (const x of de('consumo')) { const p = x.kw * 0.55 * forma(so.perfil, h) * (0.92 + Math.random() * 0.16); k[x.sensor] = -p; dem += p; }
  const ves = de('ve');
  if (ves.length) {
    const kwh = suma(ves, 'kwh'), kw = suma(ves, 'kw');
    const conectado = so.perfil === 'Doméstico' ? (h >= 19 || h < 7) : (h >= 9 && h < 18);
    if (conectado) { ve = Math.min(kw, Math.max(0, (0.9 - s.soc_ve) * kwh / dt / 0.92)); s.soc_ve += ve * 0.92 * dt / kwh; }
    else s.soc_ve = Math.max(0.2, s.soc_ve - 0.04 * dt);
    for (const x of ves) k[x.sensor] = -ve * x.kw / kw;
  }
  const bats = de('bateria');
  if (bats.length) {
    const kwh = suma(bats, 'kwh'), kw = suma(bats, 'kw'), exc = gen - dem - ve;
    if (exc > 0) { const c = Math.min(exc, kw, Math.max(0, (0.95 - s.soc_bat) * kwh / dt / 0.95)); s.soc_bat += c * 0.95 * dt / kwh; bat = -c; }
    else { const d = Math.min(-exc, kw, Math.max(0, (s.soc_bat - 0.1) * kwh / dt)); s.soc_bat -= d * dt / kwh; bat = d; }
    for (const x of bats) k[x.sensor] = bat * x.kw / kw;
  }
  const reds = de('red');
  for (const x of reds) k[x.sensor] = (dem + ve - gen - bat) / reds.length;
  return k;
}
// Lectura con los registros tipicos de un EM24 / EM340 (trifasico) o EM112 (monofasico)
function lectura(so, x, kw, m, s) {
  const pf = 0.93 + Math.random() * 0.06, pw = kw * 1000, i = Math.abs(pw) / (230 * pf);
  const v = () => +(230 + (Math.random() - 0.5) * 4).toFixed(1);
  const p = {
    socio: so.nombre, sensor: x.sensor, rol: x.rol, modelo: x.modelo, serie: x.serie, ts: Date.now(),
    p_w: Math.round(pw), q_var: Math.round(Math.abs(pw) * Math.tan(Math.acos(pf))), pf: +pf.toFixed(3),
    f_hz: +(50 + (Math.random() - 0.5) * 0.06).toFixed(2), kwh_imp: +m.imp.toFixed(3), kwh_exp: +m.exp.toFixed(3)
  };
  if (x.modelo === 'EM112') { p.v_l1n = v(); p.i_l1 = +i.toFixed(2); }
  else { p.v_l1n = v(); p.v_l2n = v(); p.v_l3n = v(); p.i_l1 = p.i_l2 = p.i_l3 = +(i / 3).toFixed(2); }
  if (x.rol === 'bateria') p.soc = +(s.soc_bat * 100).toFixed(1);
  if (x.rol === 've') p.soc = +(s.soc_ve * 100).toFixed(1);
  return p;
}
"""

# Lectura de un medidor -> foto en el contexto del flujo (la suma la hace CEC_AGG_JS)
CEC_NORM_JS = r"""// Lectura de un medidor (EM24 / EM340 / EM112...) publicada por la pasarela Modbus -> MQTT
const ROLES = { fv: 1, eolica: 1, bateria: 1, consumo: 1, ve: 1, red: 1 };
const slug = v => String(v == null ? '' : v).normalize('NFD').replace(/[̀-ͯ]/g, '')
  .toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '');
const p = msg.payload, partes = String(msg.topic).split('/');
if (!p || typeof p !== 'object') return null;
const num = k => (typeof p[k] === 'number' && isFinite(p[k])) ? p[k] : null;
const socio = slug(p.socio || partes[1]), sensor = slug(p.sensor || partes[2]), rol = slug(p.rol);
if (!socio || !sensor || !ROLES[rol] || num('p_w') === null || num('kwh_imp') === null || num('kwh_exp') === null) {
  node.warn('lectura descartada (faltan socio, sensor, rol, p_w, kwh_imp o kwh_exp): ' + msg.topic);
  return null;
}
const lect = {};
for (const k of ['v_l1n', 'v_l2n', 'v_l3n', 'i_l1', 'i_l2', 'i_l3', 'q_var', 'pf', 'f_hz', 'kwh_imp', 'kwh_exp'])
  if (num(k) !== null) lect[k] = p[k];
let ts = num('ts') || Date.now();
if (ts < 1e12) ts *= 1000;   // marca de tiempo en segundos
const snap = flow.get('cec_snap') || {};
snap[socio + '/' + sensor] = {
  socio, socio_nombre: String(p.socio || socio), sensor, rol, modelo: p.modelo, serie: p.serie,
  ts, recibido: Date.now(), p_kw: p.p_w / 1000, imp: p.kwh_imp, exp: p.kwh_exp, soc: num('soc'), lect
};
flow.set('cec_snap', snap);
node.status({ text: socio + '/' + sensor + ' ' + (p.p_w / 1000).toFixed(2) + ' kW' });
return null;
"""

# Cada SIM_INTERVAL s: energia de cada medidor desde la vuelta anterior (contadores
# kWh+/kWh-), sumas por socio y comunidad, cierres horarios y diarios -> Gateway API
CEC_AGG_JS = r"""
const LIMITE = 40;               // dispositivos por mensaje MQTT a ThingsBoard
const FRESCO = 5 * 60 * 1000;    // una lectura mas antigua no cuenta en la potencia actual
const snap = flow.get('cec_snap') || {};
const st = flow.get('cec_agg') || { agg: {}, sens: {}, conocidos: {} };
for (const k in INIT) if (!st.agg[k]) st.agg[k] = INIT[k];
const now = Date.now(), d = new Date(now), pad = n => String(n).padStart(2, '0');
const dia = d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate());
const hora = new Date(d.getFullYear(), d.getMonth(), d.getDate(), d.getHours()).getTime();
const r3 = v => Math.round(v * 1000) / 1000, r1 = v => Math.round(v * 10) / 10;
const tel = {}, nuevos = [];
const add = (dev, ts, values) => (tel[dev] = tel[dev] || []).push({ ts, values });
const conocer = (dev, tipo, attrs) => { if (!st.conocidos[dev]) { st.conocidos[dev] = 1; nuevos.push([dev, tipo, attrs]); } };
const nudo = n => st.agg[n] || (st.agg[n] = { day: dia, hour: hora, r: {} });
const R = (A, rol) => A.r[rol] || (A.r[rol] = { ein: 0, eout: 0, hstart: 0 });

// 1. Cierre de la hora y del dia de cada nudo (socio o comunidad)
for (const n in st.agg) {
  const A = st.agg[n];
  if (A.hour !== hora) {
    for (const rol in A.r) {
      const x = A.r[rol], net = x.ein - x.eout, h = r3(net - x.hstart);
      add(n + '.' + rol, A.hour, { h_neto_kwh: h });
      add(n + '.' + rol, A.hour + 86400000, { hy_neto_kwh: h });   // "ayer", en el eje de manana
      x.hstart = net;
    }
    const soc = {};
    if (A.soc_bat != null) soc.h_soc_bat = A.soc_bat;
    if (A.soc_ve != null) soc.h_soc_ve = A.soc_ve;
    if (Object.keys(soc).length) add(n, A.hour, soc);
    A.hour = hora;
  }
  if (A.day !== dia) {
    const t0 = new Date(A.day + 'T00:00:00').getTime();
    for (const rol in A.r) {
      const x = A.r[rol], net = r3(x.ein - x.eout);
      add(n + '.' + rol, t0, { d_entra_kwh: r3(x.ein), d_sale_kwh: r3(-x.eout), d_neto_kwh: net });
      add(n + '.' + rol, now, { neto_ayer_kwh: net });
      x.ein = x.eout = x.hstart = 0;
    }
    A.day = dia;
  }
}

// 2. Medidores: energia desde la vuelta anterior y potencia actual
const vivo = {};
for (const key in snap) {
  const s = snap[key], prev = st.sens[key];
  let din = 0, dout = 0;
  if (prev && s.imp >= prev.imp && s.exp >= prev.exp) { din = s.imp - prev.imp; dout = s.exp - prev.exp; }
  if (din > 100 || dout > 100) din = dout = 0;   // salto de contador (medidor cambiado)
  const mismoDia = prev && prev.day === dia;
  const S = st.sens[key] = { imp: s.imp, exp: s.exp, day: dia, enviado: prev ? prev.enviado : 0,
    ein: (mismoDia ? prev.ein : 0) + din, eout: (mismoDia ? prev.eout : 0) + dout };
  conocer(key, 'medidor', { socio: s.socio_nombre, sensor: s.sensor, rol: s.rol, modelo: s.modelo, serie: s.serie });
  if (s.ts !== S.enviado) {
    const v = Object.assign({}, s.lect, { p_kw: r3(s.p_kw), entra_hoy_kwh: r3(S.ein), sale_hoy_kwh: r3(-S.eout) });
    if (s.soc != null) v.soc = s.soc;
    add(key, s.ts, v);
    S.enviado = s.ts;
  }
  const fresco = now - s.recibido < FRESCO;
  for (const n of [s.socio, 'comunidad']) {
    const A = nudo(n);
    for (const rol of [s.rol, 'balance']) { const x = R(A, rol); x.ein += din; x.eout += dout; }
    const v = vivo[n] || (vivo[n] = {}), z = v[s.rol] || (v[s.rol] = { p: 0, soc: 0, n: 0 });
    if (fresco) { z.p += s.p_kw; if (s.soc != null) { z.soc += s.soc; z.n++; } }
  }
}

// 3. Puntos de medida y resumen de cada nudo
for (const n in vivo) {
  const A = st.agg[n], v = vivo[n], raiz = {};
  let pb = 0;
  for (const rol in A.r) {
    if (rol === 'balance') continue;
    const x = A.r[rol], z = v[rol] || { p: 0, n: 0 };
    const val = { p_kw: r3(z.p), entra_hoy_kwh: r3(x.ein), sale_hoy_kwh: r3(-x.eout) };
    if (z.n) val.soc = r1(z.soc / z.n);
    add(n + '.' + rol, now, val);
    conocer(n + '.' + rol, 'punto', { agregado: n, rol });
    raiz['p_' + rol + '_kw'] = r3(z.p);
    pb += z.p;
  }
  const b = R(A, 'balance');
  add(n + '.balance', now, { p_kw: r3(pb), entra_hoy_kwh: r3(b.ein), sale_hoy_kwh: r3(-b.eout) });
  conocer(n + '.balance', 'punto', { agregado: n, rol: 'balance' });
  if (v.bateria && v.bateria.n) A.soc_bat = raiz.soc_bat = r1(v.bateria.soc / v.bateria.n);
  if (v.ve && v.ve.n) A.soc_ve = raiz.soc_ve = r1(v.ve.soc / v.ve.n);
  if (A.r.red) { raiz.red_entra_hoy_kwh = r3(A.r.red.ein); raiz.red_sale_hoy_kwh = r3(-A.r.red.eout); }
  add(n, now, raiz);
  conocer(n, n === 'comunidad' ? 'comunidad' : 'socio', {});
}
flow.set('cec_agg', st);

// 4. Mensajes de la Gateway API: alta de dispositivos nuevos y telemetria por lotes
const out = [];
for (const [dev, tipo, attrs] of nuevos) {
  out.push({ topic: 'v1/gateway/connect', payload: { device: dev, type: tipo } });
  if (Object.keys(attrs).length) out.push({ topic: 'v1/gateway/attributes', payload: { [dev]: attrs } });
}
const devs = Object.keys(tel);
for (let i = 0; i < devs.length; i += LIMITE) {
  const p = {};
  for (const dv of devs.slice(i, i + LIMITE)) p[dv] = tel[dv];
  out.push({ topic: 'v1/gateway/telemetry', payload: p });
}
node.status({ text: Object.keys(snap).length + ' medidores, ' + Object.keys(vivo).length + ' nudos' });
return [out];
"""


# ---- ThingsBoard: dispositivos, clientes, historico ----
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
    """Panel, dispositivos y cliente de la version anterior (mapa de sitios churriana-0x)."""
    for d in tb.get(page("/api/tenant/dashboards"))["data"]:
        cfg = tb.get(f"/api/dashboard/{d['id']['id']}").get("configuration") or {}
        if "cecVersion" in cfg or d["title"].startswith(CEC + " · "):
            cec_borrar(f"/api/dashboard/{d['id']['id']}")
            print(f"    panel anterior '{d['title']}' eliminado")
    viejos = tb.get(page("/api/tenant/devices?type=comunidad-energetica"))["data"]
    for d in viejos:
        cec_borrar(f"/api/device/{d['id']['id']}")
    if viejos:
        print(f"    {len(viejos)} dispositivos del mapa anterior eliminados")
    old = find(tb.get(page("/api/customers"))["data"], "title", CEC)
    if old:
        cec_borrar(f"/api/customer/{old['id']['id']}")
        print(f"    cliente anterior '{CEC}' (y su usuario) eliminado")


def cec_telemetria(nombre, filas):
    d = DEV.get(nombre)
    if d and filas:
        tb.post(f"/api/plugins/telemetry/DEVICE/{d['id']['id']}/timeseries/ANY", filas)


def cec_rellenar(nudos):
    """DIAS_HIST dias de historico simulado de los nudos nuevos. Devuelve el estado
    final del simulador y del agregador para que Node-RED siga sin saltos."""
    tz = ZoneInfo(E.get("TZ", "Europe/Madrid"))
    sim = [so for so in SOCIOS if so["simulado"]]
    est = {so["id"]: {"soc_bat": 0.5, "soc_ve": 0.6, "nubes": 0.2, "viento": 0.4} for so in sim}
    now = int(time.time())
    ahora = datetime.fromtimestamp(now, tz)
    hoy0 = ahora.replace(hour=0, minute=0, second=0, microsecond=0)
    ayer0 = hoy0 - timedelta(days=1)
    hoy, ayer = hoy0.strftime("%Y-%m-%d"), ayer0.strftime("%Y-%m-%d")
    hoy0_ms, ayer0_ms = int(hoy0.timestamp()) * 1000, int(ayer0.timestamp()) * 1000
    hora_act = int(ahora.replace(minute=0, second=0, microsecond=0).timestamp()) * 1000
    paso = 900
    dt = paso / 3600
    B = {n: {"d": {}, "h": {}, "p": [], "soc": {}, "soc_fin": {}} for n in nudos}
    t = int((hoy0 - timedelta(days=DIAS_HIST)).timestamp())
    while t < now:
        lt = datetime.fromtimestamp(t, tz)
        dia = lt.strftime("%Y-%m-%d")
        hts = int(lt.replace(minute=0, second=0).timestamp()) * 1000
        acc, socs = {}, {}
        for so in sim:
            s = est[so["id"]]
            k = cec_flujos(so, s, lt.hour + lt.minute / 60, dt)
            for se in so["sensores"]:
                kw = k.get(se["sensor"], 0)
                for n in (so["id"], "comunidad"):
                    if n not in B:
                        continue
                    for rol in (se["rol"], "balance"):
                        x = acc.setdefault(n, {}).setdefault(rol, [0, 0, 0])
                        x[0] += kw
                        x[1] += max(kw, 0) * dt
                        x[2] += max(-kw, 0) * dt
                    if se["rol"] in ("bateria", "ve"):
                        socs.setdefault(n, {}).setdefault(se["rol"], []).append(
                            100 * s["soc_bat" if se["rol"] == "bateria" else "soc_ve"])
        for n, roles in acc.items():
            b = B[n]
            for rol, (p, ein, eout) in roles.items():
                dd = b["d"].setdefault(dia, {}).setdefault(rol, [0, 0])
                dd[0] += ein
                dd[1] += eout
                hh = b["h"].setdefault(hts, {})
                hh[rol] = hh.get(rol, 0) + ein - eout
            if t >= now - 86400:
                b["p"].append((t * 1000, {rol: v[0] for rol, v in roles.items()}))
            for rol, vs in socs.get(n, {}).items():
                b["soc"].setdefault(hts, {})[rol] = b["soc_fin"][rol] = round(sum(vs) / len(vs), 1)
        t += paso

    r3 = lambda v: round(v, 3) + 0.0   # + 0.0: sin "-0.0"
    t0 = lambda dia: int(datetime.strptime(dia, "%Y-%m-%d").replace(tzinfo=tz).timestamp()) * 1000
    init_agg = {}
    for n, b in B.items():
        A = {"day": hoy, "hour": hora_act, "r": {}}
        for rol in sorted({r for dd in b["d"].values() for r in dd}, key=lambda r: ORDEN.get(r, 50)):
            filas = [{"ts": t0(dia), "values": {"d_entra_kwh": r3(dd[rol][0]), "d_sale_kwh": r3(-dd[rol][1]),
                                                "d_neto_kwh": r3(dd[rol][0] - dd[rol][1])}}
                     for dia, dd in b["d"].items() if dia != hoy and rol in dd]
            hstart = 0
            for hts, hh in b["h"].items():
                if rol not in hh or hts >= hora_act:
                    continue
                if hts >= hoy0_ms:
                    hstart += hh[rol]
                if hts >= ayer0_ms:
                    filas += [{"ts": hts, "values": {"h_neto_kwh": r3(hh[rol])}},
                              {"ts": hts + 86400000, "values": {"hy_neto_kwh": r3(hh[rol])}}]
            filas += [{"ts": ts, "values": {"p_kw": r3(pp[rol])}} for ts, pp in b["p"] if rol in pp]
            ein, eout = b["d"].get(hoy, {}).get(rol, [0, 0])
            ult = {"entra_hoy_kwh": r3(ein), "sale_hoy_kwh": r3(-eout)}
            if rol in b["d"].get(ayer, {}):
                a_in, a_out = b["d"][ayer][rol]
                ult["neto_ayer_kwh"] = r3(a_in - a_out)
            if rol in b["soc_fin"]:
                ult["soc"] = b["soc_fin"][rol]
            filas.append({"ts": now * 1000, "values": ult})
            cec_telemetria(f"{n}.{rol}", filas)
            A["r"][rol] = {"ein": ein, "eout": eout, "hstart": hstart}
        # Resumen del nudo: potencia de cada punto y SoC
        filas = [{"ts": ts, "values": {f"p_{r}_kw": r3(v) for r, v in pp.items() if r != "balance"}}
                 for ts, pp in b["p"]]
        for hts, ss in b["soc"].items():
            if ayer0_ms <= hts < hora_act:
                v = {}
                if "bateria" in ss:
                    v["h_soc_bat"] = ss["bateria"]
                if "ve" in ss:
                    v["h_soc_ve"] = ss["ve"]
                filas.append({"ts": hts, "values": v})
        ult = {}
        if "bateria" in b["soc_fin"]:
            ult["soc_bat"] = A["soc_bat"] = b["soc_fin"]["bateria"]
        if "ve" in b["soc_fin"]:
            ult["soc_ve"] = A["soc_ve"] = b["soc_fin"]["ve"]
        if "red" in A["r"]:
            ult["red_entra_hoy_kwh"] = r3(A["r"]["red"]["ein"])
            ult["red_sale_hoy_kwh"] = r3(-A["r"]["red"]["eout"])
        if ult:
            filas.append({"ts": now * 1000, "values": ult})
        cec_telemetria(n, filas)
        init_agg[n] = A
        print(f"    {n}: {DIAS_HIST} días de histórico simulado")
    return {k: v for k, v in est.items() if k in nudos}, init_agg


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


def cec_tipo(aid, nombre, dtype, prefijo):
    return {"id": aid, "alias": nombre, "filter": {
        "type": "deviceType", "resolveMultiple": True, "deviceType": dtype, "deviceTypes": [dtype],
        "deviceNameFilter": prefijo}}


def _eje_soc(st):
    ax = json.loads(json.dumps(st["yAxes"]["default"]))
    ax.update({"id": "soc", "units": "%", "decimals": 0, "label": "", "position": "right",
               "min": 0, "max": 100, "order": 1})
    st["yAxes"]["soc"] = ax


def _serie(key, label, color, units, tipo="bar", eje="default", **linea):
    s = {"type": tipo, "yAxisId": eje, "showInLegend": True}
    if tipo == "line":
        s["lineSettings"] = {"showPoints": False, "lineWidth": 2, "smooth": False, **linea}
    return _dk(key, label, color=color, units=units, decimals=1 if units != "%" else 0, settings=s)


def w_ultimas(a_raiz, roles, x, y, w, h):
    cfg, typ = _base("system.time_series_chart")
    keys = [_serie(f"p_{r}_kw", ROL_LABEL[r], ROL_COLOR[r], "kW", "line",
                   **({"lineType": "dashed"} if r == "red" else {})) for r in roles]
    cfg["datasources"] = [{"type": "entity", "entityAliasId": a_raiz, "dataKeys": keys}]
    st = cfg["settings"]
    st["yAxes"]["default"].update({"units": "kW", "decimals": 1, "label": ""})
    st["legendConfig"].update({"direction": "row", "position": "bottom", "showAvg": False, "showTotal": False})
    cfg.update({"title": "Últimas medidas — potencia en kW, últimas 2 h (+ entra al nudo, − sale)",
                "showTitle": True, "useDashboardTimewindow": False, "displayTimewindow": False,
                "timewindow": {"selectedTab": 0,
                               "realtime": {"realtimeType": 0, "timewindowMs": 7200000, "interval": 300000},
                               "aggregation": {"type": "AVG", "limit": 25000}}})
    return _w("system.time_series_chart", cfg, typ, x, y, w, h)


def w_hoy_ayer(a_sel, a_raiz, x, y, w, h, titulo):
    cfg, typ = _base("system.time_series_chart")
    ds = [{"type": "entity", "entityAliasId": a_sel, "dataKeys": [
        _serie("h_neto_kwh", "${entityLabel} · hoy", "#5b4fc4", "kWh"),
        _serie("hy_neto_kwh", "${entityLabel} · ayer", "#b5b2a8", "kWh")]}]
    if a_raiz:
        ds.append({"type": "entity", "entityAliasId": a_raiz, "dataKeys": [
            _serie("h_soc_bat", "SoC batería", ROL_COLOR["bateria"], "%", "line", "soc", smooth=True),
            _serie("h_soc_ve", "SoC coche", "#d6336c", "%", "line", "soc", lineType="dashed")]})
    cfg["datasources"] = ds
    st = cfg["settings"]
    st["stack"] = False
    st["yAxes"]["default"].update({"units": "kWh", "decimals": 1, "label": ""})
    _eje_soc(st)
    st["legendConfig"].update({"direction": "row", "position": "bottom", "showAvg": False, "showTotal": False})
    cfg.update({"title": titulo, "showTitle": True, "useDashboardTimewindow": False, "displayTimewindow": False,
                "timewindow": {"selectedTab": 0,
                               "realtime": {"realtimeType": 1, "quickInterval": "CURRENT_DAY",
                                            "timewindowMs": 86400000, "interval": 3600000},
                               "aggregation": {"type": "NONE", "limit": 5000}}})
    return _w("system.time_series_chart", cfg, typ, x, y, w, h)


def w_diario(a_sel, x, y, w, h, titulo):
    cfg, typ = _base("system.time_series_chart")
    cfg["datasources"] = [{"type": "entity", "entityAliasId": a_sel, "dataKeys": [
        _serie("d_entra_kwh", "${entityLabel} · entra", ROL_COLOR["fv"], "kWh"),
        _serie("d_sale_kwh", "${entityLabel} · sale", ROL_COLOR["consumo"], "kWh"),
        _serie("d_neto_kwh", "${entityLabel} · neto", "#5b4fc4", "kWh", "line", showPoints=True)]}]
    st = cfg["settings"]
    st["stack"] = False
    st["yAxes"]["default"].update({"units": "kWh", "decimals": 1, "label": ""})
    st["legendConfig"].update({"direction": "row", "position": "bottom", "showAvg": False, "showTotal": True})
    cfg.update({"title": titulo, "showTitle": True, "useDashboardTimewindow": False, "displayTimewindow": True,
                "timewindow": {"selectedTab": 1,
                               "history": {"historyType": 0, "timewindowMs": 30 * 86400000,
                                           "interval": 86400000},
                               "aggregation": {"type": "NONE", "limit": 5000}}})
    return _w("system.time_series_chart", cfg, typ, x, y, w, h)


# Acciones: abrir la vista estandar de un socio (mapa o tabla de socios) y el detalle
# de un punto de medida (dialogo con su hoy/ayer y sus valores diarios)
ABRIR_SOCIO = {"name": "Ver datos del socio", "icon": "insights", "type": "openDashboardState",
               "targetDashboardStateId": "socio", "setEntityId": True, "stateEntityParamName": None,
               "openRightLayout": False, "openInSeparateDialog": False, "openInPopover": False}
ABRIR_PUNTO = {"name": "Ver el punto", "icon": "bar_chart", "type": "openDashboardState",
               "targetDashboardStateId": "punto", "setEntityId": True, "stateEntityParamName": None,
               "openRightLayout": False, "openInSeparateDialog": True, "openInPopover": False,
               "dialogTitle": "", "dialogHideDashboardToolbar": True}


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


def w_puntos(alias, x, y, w, h):
    oculto = {"columnSelectionToDisplay": "disabled", "defaultColumnVisibility": "hidden"}
    keys = [_dk("orden", "orden", "attribute", settings=oculto),
            _dk("p_kw", "Potencia (kW)", decimals=1), _dk("entra_hoy_kwh", "Entra hoy (kWh)", decimals=1),
            _dk("sale_hoy_kwh", "Sale hoy (kWh)", decimals=1), _dk("neto_ayer_kwh", "Neto ayer (kWh)", decimals=1),
            _dk("soc", "SoC (%)", decimals=0)]
    return w_tabla_cec(alias, "Valores instantáneos y diarios — pulsa un punto para ver su detalle",
                       "Punto de medida", keys, x, y, w, h, orden="orden", accion=ABRIR_PUNTO)


CLAVES_SOCIO = [("p_fv_kw", "FV (kW)", 1), ("p_eolica_kw", "Eólica (kW)", 1), ("p_consumo_kw", "Consumo (kW)", 1),
                ("p_bateria_kw", "Batería (kW)", 1), ("p_ve_kw", "VE (kW)", 1), ("p_red_kw", "Red (kW)", 1),
                ("red_entra_hoy_kwh", "Recibe hoy (kWh)", 1), ("red_sale_hoy_kwh", "Aporta hoy (kWh)", 1),
                ("soc_bat", "SoC bat. (%)", 0), ("soc_ve", "SoC VE (%)", 0)]


def w_socios(alias, x, y, w, h):
    keys = [_dk(k, lab, decimals=d) for k, lab, d in CLAVES_SOCIO]
    return w_tabla_cec(alias, "Socios — pulsa uno para ver sus datos", "Socio", keys, x, y, w, h,
                       accion=ABRIR_SOCIO)


def w_medidores(alias, x, y, w, h):
    keys = [_dk("socio", "Socio", "attribute"), _dk("modelo", "Modelo", "attribute")]
    keys += [_dk(k, lab, decimals=d) for k, lab, d in (
        ("p_kw", "P (kW)", 2), ("v_l1n", "V L1 (V)", 1), ("i_l1", "I L1 (A)", 2), ("pf", "FP", 2),
        ("f_hz", "f (Hz)", 2), ("kwh_imp", "kWh+", 1), ("kwh_exp", "kWh−", 1),
        ("entra_hoy_kwh", "Entra hoy (kWh)", 1), ("sale_hoy_kwh", "Sale hoy (kWh)", 1))]
    return w_tabla_cec(alias, "Medidores", "Medidor", keys, x, y, w, h)


def w_mapa(alias, x, y, w, h):
    """Un rayo por socio: verde si aporta energia a la comunidad, rojo si la recibe."""
    cfg, typ = _base("system.map")
    marker = json.loads(json.dumps(cfg["settings"]["markers"][0]))
    color = {"type": "function", "color": "#1e88e5",
             "colorFunction": "var r = data.p_red_kw;\nif (r === undefined || r === null) return '#9e9e9e';\n"
                              "if (r < -0.05) return '" + ROL_COLOR["fv"] + "';\n"
                              "if (r > 0.05) return '" + ROL_COLOR["consumo"] + "';\nreturn '#1e88e5';"}
    marker.update({
        "dsType": "entity", "dsLabel": "Socios", "dsEntityAliasId": alias, "dsDeviceId": None, "dsFilterId": None,
        "additionalDataKeys": [_dk(k, k) for k, _, _ in CLAVES_SOCIO],
        "xKey": _dk("latitude", "latitude", "attribute"),
        "yKey": _dk("longitude", "longitude", "attribute"),
        "label": {"show": True, "type": "pattern", "pattern": "${entityLabel}"},
        "tooltip": {"show": True, "trigger": "hover", "autoclose": True, "type": "pattern",
                    "offsetX": 0, "offsetY": -1, "pattern":
                    "<b>${entityLabel}</b><br/>"
                    "FV ${p_fv_kw:1} kW · Consumo ${p_consumo_kw:1} kW<br/>"
                    "<b>Red ${p_red_kw:2} kW</b> <small>(+ recibe / − aporta)</small><br/>"
                    "Hoy: recibe ${red_entra_hoy_kwh:1} kWh · aporta ${red_sale_hoy_kwh:1} kWh<br/>"
                    "<small>Pulsa el rayo para ver sus datos</small>"},
        "click": dict(ABRIR_SOCIO, id=str(uuid.uuid4())),
    })
    if "markerIcon" in marker:   # icono de energia (Material "bolt") del color del intercambio
        marker["markerType"] = "icon"
        marker["markerIcon"] = dict(marker["markerIcon"] or {}, icon="bolt", size=40, color=color)
    else:                        # mapa sin iconos: marcador de forma con el mismo color
        marker["markerType"] = "shape"
        marker["markerShape"] = {"shape": "markerShape1", "size": 38, "color": color}
    marker.pop("groups", None)
    cfg["settings"]["markers"] = [marker]
    cfg.update({"title": "Socios — ⚡ verde: aporta a la comunidad · rojo: recibe · azul: en equilibrio",
                "showTitle": True, "datasources": []})
    return _w("system.map", cfg, typ, x, y, w, h)


NULL_UUID = "13814000-1dd2-11b2-8080-808080808080"


def cec_config(title, roles):
    """Panel estandar de la comunidad, el mismo para todos. Los alias dependen de quien
    mira (CURRENT_USER, relaciones creadas por cec_enlazar_usuarios): el administrador ve
    los totales de la comunidad y todos los socios; un socio ve solo sus datos y su rayo.
    (Desde CURRENT_USER_OWNER no vale: ThingsBoard no deja a un usuario de cliente
    consultar relaciones que salen de su propio cliente y los alias quedan vacios.)
    Estados: default (mapa + vista estandar), socio (vista estandar del socio pulsado),
    punto (dialogo con el detalle de un punto de medida)."""
    al = {}

    def alias(nombre, flt):
        aid = str(uuid.uuid4())
        al[aid] = {"id": aid, "alias": nombre, "filter": flt}
        return aid

    def rel(tipo, multiple, del_estado=False):
        f = {"type": "relationsQuery", "resolveMultiple": multiple, "direction": "FROM", "maxLevel": 1,
             "fetchLastLevelOnly": False, "filters": [{"relationType": tipo, "entityTypes": ["DEVICE"]}],
             "rootStateEntity": del_estado, "stateEntityParamName": None, "defaultStateEntity": None,
             "rootEntity": None if del_estado else {"entityType": "CURRENT_USER", "id": NULL_UUID}}
        return f

    tipo = lambda t: {"type": "deviceType", "resolveMultiple": True, "deviceType": t, "deviceTypes": [t],
                      "deviceNameFilter": ""}
    estado = {"type": "stateEntity", "resolveMultiple": False, "stateEntityParamName": None,
              "defaultStateEntity": None}
    mio = {"nudo": alias("Mi nudo", rel("CecNudo", False)), "puntos": alias("Mis puntos", rel("CecPunto", True)),
           "red": alias("Mi red", rel("CecRed", False)), "medidores": alias("Mis medidores", tipo("medidor"))}
    socio = {"nudo": alias("Socio elegido", estado),
             "puntos": alias("Puntos del socio", rel("CecPunto", True, True)),
             "red": alias("Red del socio", rel("CecRed", False, True)),
             "medidores": alias("Medidores del socio", rel("CecMedidor", True, True))}
    a_socios = alias("Socios", tipo("socio"))
    a_punto = alias("Punto elegido", estado)

    widgets, lay = {}, {"default": {}, "socio": {}, "punto": {}}

    def add(state, t):
        wid, wdef, l = t
        widgets[wid] = wdef
        lay[state][wid] = l

    def estandar(state, A, y):
        add(state, w_ultimas(A["nudo"], roles, 0, y, 24, 7))
        add(state, w_hoy_ayer(A["red"], A["nudo"], 0, y + 7, 24, 9,
                              "Hoy frente a ayer — energía horaria de la red (kWh), SoC a la derecha"))
        add(state, w_puntos(A["puntos"], 0, y + 16, 24, 7))
        add(state, w_diario(A["red"], 0, y + 23, 24, 8,
                            "Valores diarios de la red entre fechas (kWh) — cambia el intervalo con el reloj"))
        return y + 31

    add("default", w_mapa(a_socios, 0, 0, 24, 10))
    y = estandar("default", mio, 10)
    add("default", w_socios(a_socios, 0, y, 24, 7))
    add("default", w_medidores(mio["medidores"], 0, y + 7, 24, 8))
    y = estandar("socio", socio, 0)
    add("socio", w_medidores(socio["medidores"], 0, y, 24, 8))
    add("punto", w_hoy_ayer(a_punto, None, 0, 0, 24, 9, "Hoy frente a ayer — energía horaria (kWh)"))
    add("punto", w_diario(a_punto, 0, 9, 24, 8, "Valores diarios entre fechas (kWh)"))

    grid = {"columns": 24, "margin": 10, "outerMargin": True, "backgroundColor": "#eeeeee"}
    estado_json = lambda nombre, root, st: {"name": nombre, "root": root,
                                            "layouts": {"main": {"widgets": lay[st], "gridSettings": grid}}}
    return {
        "description": "Comunidad energética: mapa de socios, potencia, hoy frente a ayer, valores diarios y medidores",
        "widgets": widgets,
        "states": {"default": estado_json(title, True, "default"),
                   "socio": estado_json("${entityLabel}", False, "socio"),
                   "punto": estado_json("${entityLabel}", False, "punto")},
        "entityAliases": al,
        "filters": {},
        "timewindow": {"selectedTab": 0,
                       "realtime": {"realtimeType": 0, "timewindowMs": 7200000, "interval": 5000},
                       "aggregation": {"type": "NONE", "limit": 5000}},
        "settings": {"stateControllerId": "entity", "showTitle": True,
                     "showDashboardsSelect": False, "showEntitiesSelect": False,
                     "showDashboardTimewindow": False, "showDashboardExport": False,
                     "toolbarAlwaysOpen": True, "dashboardCss": OCULTAR_PIE},
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
    """Administrador de la comunidad: TENANT_ADMIN (en la edicion Community es la unica
    forma de ver los dispositivos de todos los clientes/socios)."""
    tid = tb.get("/api/auth/user")["tenantId"]["id"]
    email = E["CEC_ADMIN_EMAIL"]
    u = find(sa.get(page(f"/api/tenant/{tid}/users"))["data"], "email", email)
    if u:
        u = sa.get(f"/api/user/{u['id']['id']}")
        info = u.get("additionalInfo") or {}
        if info.get("defaultDashboardId") != dash_id:
            info["defaultDashboardId"] = dash_id
            u["additionalInfo"] = info
            u = sa.post("/api/user?sendActivationMail=false", u)
        idioma(sa, u)
        return
    u = sa.post("/api/user?sendActivationMail=false", {
        "email": email, "authority": "TENANT_ADMIN", "tenantId": {"id": tid, "entityType": "TENANT"},
        "firstName": "Administración", "lastName": CEC,
        "additionalInfo": {"defaultDashboardId": dash_id, "defaultDashboardFullscreen": False,
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
print(f"  - {CEC}: {len(SOCIOS)} socios, {sum(len(so['sensores']) for so in SOCIOS)} medidores")
cec_limpiar_anterior()
customers = tb.get(page("/api/customers"))["data"]
ROLES_DE = lambda sens: sorted({s["rol"] for s in sens}, key=ORDEN.get)
TENANT = {"entityType": "TENANT", "id": tb.get("/api/auth/user")["tenantId"]["id"]}


def cec_rel(desde, dev, tipo):
    """Relacion desde -> dispositivo (las siguen los alias del panel estandar)."""
    try:
        tb.post("/api/relation", {"from": desde, "to": {"entityType": "DEVICE", "id": dev["id"]["id"]},
                                  "type": tipo, "typeGroup": "COMMON"})
    except urllib.error.HTTPError as e:
        print(f"    AVISO: relacion {tipo} -> {dev['name']}: HTTP {e.code}")


def cec_enlazar(n, desde):
    """Nudo n (comunidad o socio) -> sus puntos (CecPunto), su punto de red (CecRed; balance
    si no tiene red) y sus medidores (CecMedidor). Cada entidad de 'desde' (usuarios que
    miran ese nudo) -> nudo (CecNudo), puntos y red."""
    raiz = {"entityType": "DEVICE", "id": DEV[n]["id"]["id"]}
    origenes = [raiz] + desde
    for o in desde:
        cec_rel(o, DEV[n], "CecNudo")
    for nombre, d in DEV.items():
        if nombre.startswith(n + "."):
            for o in origenes:
                cec_rel(o, d, "CecPunto")
        elif nombre.startswith(n + "/"):
            cec_rel(raiz, d, "CecMedidor")
    red = DEV.get(f"{n}.red") or DEV.get(f"{n}.balance")
    if red:
        for o in origenes:
            cec_rel(o, red, "CecRed")


def cec_usuarios(lista):
    return [{"entityType": "USER", "id": u["id"]["id"]} for u in lista]


def cec_puntos(n, roles, cid):
    for r in roles + ["balance"]:
        cec_dispositivo(f"{n}.{r}", "punto", ROL_LABEL[r], cid, {"agregado": n, "rol": r, "orden": ORDEN[r]})


cec_dispositivo("comunidad", "comunidad", CEC)
cec_puntos("comunidad", ROLES_DE([s for so in SOCIOS for s in so["sensores"]]), None)
for so in SOCIOS:
    cust = find(customers, "title", so["nombre"])
    if not cust:
        cust = tb.post("/api/customer", {"title": so["nombre"]})
        print(f"    socio '{so['nombre']}' creado")
    so["cid"] = cust["id"]["id"]
    attrs = {"perfil": so["perfil"]}
    if so["lat"] is not None:
        attrs.update(latitude=so["lat"], longitude=so["lon"])
    cec_dispositivo(so["id"], "socio", so["nombre"], so["cid"], attrs)
    cec_puntos(so["id"], ROLES_DE(so["sensores"]), so["cid"])
    for s in so["sensores"]:
        cec_dispositivo(f"{so['id']}/{s['sensor']}", "medidor", f"{s['sensor']} · {ROL_LABEL[s['rol']]}",
                        so["cid"], {"socio": so["nombre"], "sensor": s["sensor"], "rol": s["rol"],
                                    "modelo": s["modelo"], "serie": s["serie"]})

# Medidores reales (y sus puntos) que Node-RED ha dado de alta al recibirlos por MQTT:
# se asignan al socio de su nombre; uno de un socio sin configurar queda en el tenant.
PUNTOS = {}   # nudo -> roles con dispositivo
for dtype, sep in (("medidor", "/"), ("punto", ".")):
    for d in tb.get(page(f"/api/tenant/devices?type={dtype}"))["data"]:
        n, _, resto = d["name"].partition(sep)
        if dtype == "punto":
            PUNTOS.setdefault(n, set()).add(resto)
        if d["name"] in DEV:
            continue
        DEV[d["name"]] = d
        if dtype == "punto" and resto in ORDEN:
            tb.post(f"/api/plugins/telemetry/DEVICE/{d['id']['id']}/attributes/SERVER_SCOPE",
                    {"orden": ORDEN[resto], "rol": resto, "agregado": n})
        so = SOCIO.get(n)
        if not so:
            continue
        if not d.get("label"):
            d["label"] = ROL_LABEL.get(resto, resto) if dtype == "punto" else d["name"]
            d = tb.post("/api/device", d)
        if (d.get("customerId") or {}).get("id") != so["cid"]:
            DEV[d["name"]] = tb.post(f"/api/customer/{so['cid']}/device/{d['id']['id']}")
            print(f"    '{d['name']}' (llegado por MQTT) asignado a {so['nombre']}")

# Relaciones del nudo a sus puntos y medidores (vista de un socio elegido en el mapa)
cec_enlazar("comunidad", [])
for so in SOCIOS:
    cec_enlazar(so["id"], [])

# Historico simulado de los nudos nuevos (sin telemetria todavia)
nuevos = {n for n in ["comunidad"] + [so["id"] for so in SOCIOS if so["simulado"]]
          if not tb.get(f"/api/plugins/telemetry/DEVICE/{DEV[n]['id']['id']}/keys/timeseries")}
CEC_INIT_SIM, CEC_INIT_AGG = cec_rellenar(nuevos) if nuevos else ({}, {})

# Un unico panel estandar: asignado a todos los socios (cada uno ve solo lo suyo) y
# panel de inicio del administrador (ve los totales y, desde el mapa, a cada socio)
roles = sorted({r for rs in PUNTOS.values() for r in rs if r in ROL_COLOR}, key=ORDEN.get)
panel = cec_panel(CEC, cec_config(CEC, roles), json.dumps([CEC_DASH_VERSION, roles]))
for so in SOCIOS:
    tb.post(f"/api/customer/{so['cid']}/dashboard/{panel['id']['id']}")
    if so["email"]:
        usuario_cliente(so["cid"], {"email": so["email"], "password": so["password"],
                                    "cliente": so["nombre"]}, panel["id"]["id"])
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

# Comunidad energetica: medidores (MQTT cec/<socio>/<sensor>) -> sumas -> ThingsBoard,
# y simulador de los socios marcados como simulados. Las funciones llevan una firma:
# si cambia (version o configuracion de socios/medidores) se redespliegan.
CEC_SIM = [{"id": so["id"], "nombre": so["nombre"], "perfil": so["perfil"], "sensores": so["sensores"]}
           for so in SOCIOS if so["simulado"]]
firma_sim = hashlib.sha1(json.dumps([SIM_VERSION, CEC_SIM], sort_keys=True).encode()).hexdigest()[:12]
CEC_FIRMAS = {"cec2-norm": f"// {SIM_VERSION}", "cec2-agg": f"// {SIM_VERSION}",
              "cec2-sim-fn": f"// {SIM_VERSION} {firma_sim}"}
sim_fn = (CEC_FIRMAS["cec2-sim-fn"] + "\n// Medidores simulados: publican en Mosquitto como los reales\n"
          f"const SOCIOS = {json.dumps(CEC_SIM, ensure_ascii=False)};\n"
          f"const INIT = {json.dumps(CEC_INIT_SIM)};\n"
          f"const DT = {int(E['SIM_INTERVAL'])} / 3600;\n" + CEC_SIM_JS + """
const st = context.get('st') || {};
for (const k in INIT) if (!st[k]) st[k] = INIT[k];
const now = new Date(), h = now.getHours() + now.getMinutes() / 60 + now.getSeconds() / 3600;
const out = [];
for (const so of SOCIOS) {
  const s = st[so.id] || (st[so.id] = { soc_bat: 0.5, soc_ve: 0.6, nubes: 0.2, viento: 0.4 });
  s.m = s.m || {};
  const k = flujos(so, s, h, DT);
  for (const x of so.sensores) {
    const kw = k[x.sensor] || 0;
    const m = s.m[x.sensor] || (s.m[x.sensor] = { imp: 1000 + Math.random() * 20000, exp: Math.random() * 3000 });
    m.imp += Math.max(kw, 0) * DT;
    m.exp += Math.max(-kw, 0) * DT;
    out.push({ topic: 'cec/' + so.id + '/' + x.sensor, payload: lectura(so, x, kw, m, s) });
  }
}
context.set('st', st);
return [out];""")
agg_fn = (CEC_FIRMAS["cec2-agg"] + f"\nconst INIT = {json.dumps(CEC_INIT_AGG)};" + CEC_AGG_JS)
norm_fn = CEC_FIRMAS["cec2-norm"] + "\n" + CEC_NORM_JS
CEC_DOC = """Lecturas de los medidores de los socios (Carlo Gavazzi EM24 / EM340 / EM112 o similares),
publicadas en Mosquitto por la pasarela Modbus -> MQTT.

**Topic:** `cec/<socio>/<sensor>` · **JSON:**

```json
{"socio": "Ana García", "sensor": "em-red", "rol": "red", "modelo": "EM340",
 "ts": 1760000000000, "p_w": -1300, "kwh_imp": 15234.12, "kwh_exp": 2311.8,
 "v_l1n": 231.2, "i_l1": 5.6, "pf": 0.98, "f_hz": 50.01, "soc": 64}
```

- Obligatorios: `socio` (nombre del socio), `sensor`, `rol`, `p_w`, `kwh_imp`, `kwh_exp`.
- `rol`: fv · eolica · bateria · consumo · ve · red. `soc` solo en bateria y ve.
- Signo: **+ entra al nudo del socio** (FV, eólica, descarga, compra a red), **− sale**.
  `kwh_imp` cuenta lo que entra y `kwh_exp` lo que sale.
- Un medidor nuevo aparece solo en ThingsBoard; para que lo vea el socio en su panel,
  vuelve a ejecutar iot-thingsboard.sh (lo asigna a su socio)."""
wanted += [
    {"id": "cec2-tab", "type": "tab", "label": "Comunidad: medidores -> ThingsBoard",
     "info": "Normaliza las lecturas de `cec/<socio>/<sensor>`, suma por socio y comunidad "
             "y lo publica en ThingsBoard (Gateway API)."},
    {"id": "cec2-doc", "type": "comment", "z": "cec2-tab", "name": "Formato de las lecturas (léeme)",
     "info": CEC_DOC, "x": 190, "y": 40, "wires": []},
    {"id": "cec2-in", "type": "mqtt in", "z": "cec2-tab", "name": "cec/+/+", "topic": "cec/+/+",
     "qos": "1", "datatype": "json", "broker": "iot-broker-mosq", "nl": False, "rap": True,
     "inputs": 0, "x": 130, "y": 100, "wires": [["cec2-norm"]]},
    {"id": "cec2-norm", "type": "function", "z": "cec2-tab", "name": "normalizar medidor",
     "func": norm_fn, "outputs": 1, "x": 340, "y": 100, "wires": [[]]},
    {"id": "cec2-tick", "type": "inject", "z": "cec2-tab", "name": f"cada {E['SIM_INTERVAL']} s",
     "props": [], "repeat": E["SIM_INTERVAL"], "once": True, "onceDelay": "5",
     "x": 150, "y": 180, "wires": [["cec2-agg"]]},
    {"id": "cec2-agg", "type": "function", "z": "cec2-tab", "name": "sumar socios y comunidad",
     "func": agg_fn, "outputs": 1, "x": 370, "y": 180, "wires": [["cec2-out"]]},
    {"id": "cec2-out", "type": "mqtt out", "z": "cec2-tab", "name": "ThingsBoard (Gateway API)",
     "topic": "", "qos": "1", "retain": "false", "broker": "iot-broker-tb",
     "x": 620, "y": 180, "wires": []},
]
if CEC_SIM:
    wanted += [
        {"id": "cec2-sim-tab", "type": "tab", "label": "Simulador comunidad (EM24/EM340)",
         "info": f"{len(CEC_SIM)} socios simulados: publica cada {E['SIM_INTERVAL']} s en "
                 "`cec/<socio>/<sensor>` (Mosquitto) lo mismo que mandaría un medidor real."},
        {"id": "cec2-sim-inject", "type": "inject", "z": "cec2-sim-tab", "name": f"cada {E['SIM_INTERVAL']} s",
         "props": [], "repeat": E["SIM_INTERVAL"], "once": True, "onceDelay": "3",
         "x": 150, "y": 100, "wires": [["cec2-sim-fn"]]},
        {"id": "cec2-sim-fn", "type": "function", "z": "cec2-sim-tab", "name": "medidores simulados",
         "func": sim_fn, "outputs": 1, "x": 370, "y": 100, "wires": [["cec2-sim-out", "cec2-sim-debug"]]},
        {"id": "cec2-sim-out", "type": "mqtt out", "z": "cec2-sim-tab", "name": "cec/<socio>/<sensor>",
         "topic": "", "qos": "1", "retain": "false", "broker": "iot-broker-mosq",
         "x": 620, "y": 80, "wires": []},
        {"id": "cec2-sim-debug", "type": "debug", "z": "cec2-sim-tab", "name": "lectura", "active": False,
         "complete": "true", "x": 590, "y": 140, "wires": []},
    ]

current = http("GET", NR + "/flows", headers={**NRH, "Node-RED-API-Version": "v1"})
# Simuladores de versiones anteriores del script (sitios churriana-0x): los sustituye cec2-*
viejos = [n for n in current
          if n["id"].startswith("sim-churriana-01") or n.get("z") == "sim-churriana-01-tab"
          or n["id"] == "cec-tab" or n.get("z") == "cec-tab"]
# Funciones de la comunidad con otra firma (version o socios/medidores cambiados)
viejos += [n for n in current if n["id"] in CEC_FIRMAS
           and not n.get("func", "").startswith(CEC_FIRMAS[n["id"]] + "\n")]
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
| MQTT Explorer (tools, tunel SSH) | http://127.0.0.1:$MQTTX_PORT | $MQTT_USER / $MQTT_PASSWORD (conexion "Mosquitto" precargada) |

Solo se publican 80/443 (Caddy) y $MQTTS_PORT (MQTT con TLS). Node-RED, Adminer y
MQTT Explorer escuchan en 127.0.0.1; desde otro equipo:

\`\`\`bash
ssh -L $NODERED_PORT:127.0.0.1:$NODERED_PORT -L $ADMINER_PORT:127.0.0.1:$ADMINER_PORT -L $MQTTX_PORT:127.0.0.1:$MQTTX_PORT $USER@$IP
./tools.sh up      # arranca Adminer y MQTT Explorer (./tools.sh down para pararlos)
\`\`\`

## Comunidad energética

Cada medidor de un socio (Carlo Gavazzi EM24 / EM340 / EM112 o similar, leído por una
pasarela Modbus -> MQTT) publica en Mosquitto, topic \`cec/<socio>/<sensor>\`:

\`\`\`json
{"socio": "Ana García", "sensor": "em-red", "rol": "red", "modelo": "EM340",
 "p_w": -1300, "kwh_imp": 15234.12, "kwh_exp": 2311.8, "v_l1n": 231.2, "i_l1": 5.6, "pf": 0.98}
\`\`\`

- \`rol\`: fv · eolica · bateria · consumo · ve · red (\`soc\` en bateria y ve).
- Signo: + entra al nudo del socio (FV, eólica, descarga, compra a red), − sale.
- Node-RED (pestaña "Comunidad: medidores -> ThingsBoard") suma por socio y por comunidad.
- Socio o medidor nuevo: añádelo a SOCIOS / SENSORES en iot-thingsboard.sh y vuelve a
  ejecutarlo. Un medidor real que publica sin estar listado aparece solo; al volver a
  ejecutar el script se asigna a su socio y entra en su panel.

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
echo "   $TB_TENANT_EMAIL / $TB_TENANT_PASSWORD  (administrador)"
echo "   sysadmin@thingsboard.org / $TB_SYSADMIN_PASSWORD"
for c in "${CLIENTES[@]}"; do
  IFS='|' read -r n e pw d pa pf <<< "$c"
  echo "   $e / $pw  (cliente '$n', solo ve '$pa')"
done
echo " $CEC_NOMBRE:"
echo "   $CEC_ADMIN_EMAIL / $CEC_ADMIN_PASSWORD  (administrador: totales de la comunidad y cada socio desde el mapa)"
for s_ in "${SOCIOS[@]}"; do
  IFS='|' read -r n e pw pf sim <<< "$s_"
  [ -n "$e" ] && echo "   $e / $pw  (socio '$n', solo ve su panel)"
done
echo " Node-RED          : http://127.0.0.1:$NODERED_PORT  ($NODERED_USER / $NODERED_PASSWORD, tunel SSH)"
for c in "${CLIENTES[@]}"; do
  IFS='|' read -r n e pw d pa pf <<< "$c"
  echo "   simulador '$d' ($pf) -> iot/$d/telemetry cada ${SIM_INTERVAL}s"
done
echo "   comunidad: ${#SENSORES[@]} medidores de ${#SOCIOS[@]} socios -> cec/<socio>/<sensor> cada ${SIM_INTERVAL}s"
echo " Mosquitto TLS     : mqtts://${TB_DOMAIN:-$IP}:$MQTTS_PORT  ($MQTT_USER / $MQTT_PASSWORD)"
echo "   WebSocket       : wss://${TB_DOMAIN:-$IP}/mqtt  (mismas credenciales, TLS via Caddy)"
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
