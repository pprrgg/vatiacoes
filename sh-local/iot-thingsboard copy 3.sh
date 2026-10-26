#!/usr/bin/env bash
set -euo pipefail

# ============================================
# Setup stack IoT con ThingsBoard - pkserver
#
#   PostgreSQL  -> base de datos de ThingsBoard (solo 127.0.0.1)
#   ThingsBoard -> plataforma IoT (web + MQTT de dispositivos)
#   Mosquitto   -> broker MQTT con usuario/contraseña
#   Adminer     -> GUI web de PostgreSQL
#   MQTT Explorer -> GUI web de Mosquitto (arbol de topics, publicar)
#   Node-RED    -> integra/transforma: Mosquitto -> ThingsBoard (Gateway API)
#   Caddy       -> HTTPS en el 443 del servidor (certificado interno o Let's Encrypt)
#
# Todos los contenedores usan la red del host (network_mode: host):
# se comunican por localhost y escuchan directamente en los puertos del servidor.
#
# Carpeta del stack ($INSTALL_DIR), montada en los contenedores:
#   config/mosquitto/   mosquitto.conf + passwd
#   config/caddy/       Caddyfile
#   config/nodered/     settings.js
#   data/postgres/      base de datos de ThingsBoard
#   data/thingsboard/   datos y logs de ThingsBoard
#   data/nodered/       flujos de Node-RED (flows.json), nodos instalados
#   data/mosquitto/     persistencia MQTT
#   data/caddy/         certificados
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

# Puertos en el host
TB_HTTP_PORT="8080"     # ThingsBoard web/API sin TLS (LAN), servido por Caddy con la marca VatiaCo
TB_INTERNAL_PORT="8090" # puerto real de ThingsBoard, solo 127.0.0.1 (Caddy lo publica en 8080 y 443)
TB_LANG="es_ES"         # idioma de la interfaz para todos los usuarios
BRAND="VatiaCo"      # texto del logo que sustituye al de ThingsBoard
TB_MQTT_PORT="1884"     # MQTT de dispositivos de ThingsBoard (1883 es Mosquitto)
MQTT_PORT="1883"        # Mosquitto (LAN, sin TLS)
MQTT_WS_PORT="9001"     # Mosquitto WebSocket, solo 127.0.0.1: se publica como wss://<dominio>/mqtt via Caddy
NODERED_PORT="1880"     # Node-RED
PG_PORT="5433"          # PostgreSQL (solo 127.0.0.1; 5433 para no chocar con uno del host)
ADMINER_PORT="8081"     # GUI web de PostgreSQL (LAN)
MQTTX_PORT="4000"       # GUI web de Mosquitto: MQTT Explorer (LAN)

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
#           comunidad (varios sitios de COMUNIDAD_SITIOS en un mapa; dispositivo = "-")
CLIENTES=(
  "Cliente Demo|cliente@$HOSTNAME_LAN.local|$IOT_PASSWORD|simulador-01|Panel simulador|ambiente"
  "Comunidad Energética Churriana|cec@$HOSTNAME_LAN.local|cec|-|Comunidad Energética Churriana|comunidad"
)

# Sitios de la comunidad energetica (perfil "comunidad"): uno por dispositivo
#   "dispositivo|nombre|latitud|longitud|FV kWp|bateria kWh|bateria kW|contratada kW|tipo"
#   tipo: Doméstico | Comercial | Industrial (forma de la curva de consumo)
COMUNIDAD_SITIOS=(
  "churriana-01|Plaza de la Inmaculada|36.66520|-4.49830|10|10|5|5.75|Doméstico"
  "churriana-02|Colegio|36.66190|-4.50300|30|20|10|30|Comercial"
  "churriana-03|Polideportivo|36.66880|-4.49520|20|15|7.5|20|Comercial"
  "churriana-04|Vivienda Norte|36.67020|-4.50190|5|5|3|4.6|Doméstico"
  "churriana-05|Nave Industrial|36.65950|-4.49280|40|30|15|40|Industrial"
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
    (cd "$INSTALL_DIR" && docker compose --profile duckdns down -v --remove-orphans)
  fi
  # Los datos pertenecen a los usuarios de los contenedores: se borran con un contenedor
  if [ -d "$INSTALL_DIR/data" ]; then
    docker run --rm -v "$INSTALL_DIR:/stack" alpine rm -rf /stack/data /stack/export
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
# 1. Puertos libres (con red del host no puede haber dos servicios en el mismo)
# --------------------------------------------
PROJECT="iot-tb"
OCUPADOS=()
for p in 80 443 "$TB_HTTP_PORT" "$TB_MQTT_PORT" "$MQTT_PORT" "$MQTT_WS_PORT" "$NODERED_PORT" "$PG_PORT" "$ADMINER_PORT" "$MQTTX_PORT" "$TB_INTERNAL_PORT"; do
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
         "$INSTALL_DIR"/export
cd "$INSTALL_DIR"

# Propietarios que esperan los contenedores (ThingsBoard uid 799, Node-RED uid 1000)
docker run --rm -v "$INSTALL_DIR/data:/d" alpine sh -c \
  "chown -R 799:799 /d/thingsboard /d/thingsboard-logs && chown -R 1000:1000 /d/nodered"

# MQTT Explorer: conexion a Mosquitto precargada (solo la primera vez)
if [ ! -f data/mqtt-explorer/settings.json ]; then
  python3 - "$MQTT_PORT" "$MQTT_USER" "$MQTT_PASSWORD" > data/mqtt-explorer/settings.json <<'PY'
import json, sys
port, user, pw = sys.argv[1:]
print(json.dumps({"ConnectionManager_connections": {"mosquitto": {
    "configVersion": 1, "id": "mosquitto", "name": "Mosquitto", "type": "mqtt",
    "protocol": "mqtt", "host": "localhost", "port": int(port), "basePath": "",
    "encryption": False, "certValidation": True, "clientId": "mqtt-explorer-web",
    "username": user, "password": pw,
    "subscriptions": [{"topic": "#", "qos": 0}, {"topic": "$SYS/#", "qos": 0}]}}}))
PY
fi

# --------------------------------------------
# 2. .env (variables del compose y credenciales para export.sh)
# --------------------------------------------

PROFILES=""
[ -n "$TB_DOMAIN" ] && [ -n "$DUCKDNS_TOKEN" ] && PROFILES="duckdns"

cat > .env <<EOF
TZ=$TZ
TB_VERSION=$TB_VERSION
TB_HTTP_PORT=$TB_HTTP_PORT
TB_INTERNAL_PORT=$TB_INTERNAL_PORT
TB_MQTT_PORT=$TB_MQTT_PORT
NODERED_PORT=$NODERED_PORT
PG_PORT=$PG_PORT
PG_USER=$PG_USER
PG_PASSWORD=$PG_PASSWORD
TB_DOMAIN=$TB_DOMAIN
DUCKDNS_SUBDOMAIN=${TB_DOMAIN%%.duckdns.org}
DUCKDNS_TOKEN=$DUCKDNS_TOKEN
COMPOSE_PROFILES=$PROFILES
NODERED_PORT=$NODERED_PORT
NODERED_USER=$NODERED_USER
NODERED_PASSWORD=$NODERED_PASSWORD
TB_SYSADMIN_PASSWORD=$TB_SYSADMIN_PASSWORD
TB_TENANT_EMAIL=$TB_TENANT_EMAIL
TB_TENANT_PASSWORD=$TB_TENANT_PASSWORD
ADMINER_PORT=$ADMINER_PORT
MQTTX_PORT=$MQTTX_PORT
MQTTX_USER=$MQTT_USER
MQTTX_PASSWORD=$MQTT_PASSWORD
EOF
chmod 600 .env

# --------------------------------------------
# 3. Mosquitto (con usuario y contraseña)
# --------------------------------------------
# Usuario/contraseña comunes a los dos listeners (per_listener_settings false)
cat > config/mosquitto/mosquitto.conf <<EOF
# MQTT en la LAN
listener $MQTT_PORT

# MQTT sobre WebSocket solo en local: Caddy lo expone con TLS en https://.../mqtt
listener $MQTT_WS_PORT 127.0.0.1
protocol websockets

allow_anonymous false
password_file /mosquitto/config/passwd
persistence true
persistence_location /mosquitto/data/
log_dest stdout
EOF

docker run --rm -v "$INSTALL_DIR/config/mosquitto:/mosquitto/config" eclipse-mosquitto:2 \
  sh -c "rm -f /mosquitto/config/passwd && mosquitto_passwd -b -c /mosquitto/config/passwd '$MQTT_USER' '$MQTT_PASSWORD' && chown mosquitto:mosquitto /mosquitto/config/passwd && chmod 0700 /mosquitto/config/passwd"

# --------------------------------------------
# 4. Node-RED (login del editor)
# --------------------------------------------
NODERED_HASH=$(docker run --rm --entrypoint node nodered/node-red:latest \
  -e "console.log(require('/usr/src/node-red/node_modules/bcryptjs').hashSync(process.argv[1], 8))" "$NODERED_PASSWORD")
NODERED_SECRET=$(grep -s "credentialSecret" config/nodered/settings.js | sed -n "s/.*credentialSecret: *'\([^']*\)'.*/\1/p" || true)
[ -n "$NODERED_SECRET" ] || NODERED_SECRET=$(openssl rand -hex 16 2>/dev/null || date +%s%N)

cat > config/nodered/settings.js <<EOF
module.exports = {
    uiPort: $NODERED_PORT,
    flowFile: 'flows.json',
    credentialSecret: '$NODERED_SECRET',
    adminAuth: {
        type: "credentials",
        users: [{ username: "$NODERED_USER", password: "$NODERED_HASH", permissions: "*" }]
    },
    functionExternalModules: true,
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
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 40 40"><circle cx="20" cy="20" r="20" fill="#305680"/>$RAYO</svg>
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
  echo "		reverse_proxy localhost:$MQTT_WS_PORT"
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
  echo "	handle /thingsboard.ico {"
  echo "		root * /srv/branding"
  echo "		rewrite * /favicon.svg"
  echo "		header Cache-Control no-cache"
  echo "		file_server"
  echo "	}"
  echo "	# Todo lo demas: ThingsBoard"
  echo "	handle {"
  echo "		encode gzip"
  echo "		reverse_proxy localhost:$TB_INTERNAL_PORT"
  echo "	}"
  echo "}"
  echo
  echo "# HTTP en la LAN (puerto $TB_HTTP_PORT), tambien con la marca $BRAND"
  echo "http://:$TB_HTTP_PORT {"
  echo "	import rutas"
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
# 6. docker-compose.yml (red del host; datos en carpetas de $INSTALL_DIR)
# --------------------------------------------
cat > docker-compose.yml <<'EOF'
name: iot-tb

x-common: &common
  restart: unless-stopped
  network_mode: host
  logging:
    driver: json-file
    options: { max-size: "50m", max-file: "3" }

services:

  postgres:
    <<: *common
    image: postgres:16
    container_name: iot-postgres
    command: ["postgres", "-c", "listen_addresses=127.0.0.1", "-c", "port=${PG_PORT}"]
    environment:
      POSTGRES_DB: thingsboard
      POSTGRES_USER: ${PG_USER}
      POSTGRES_PASSWORD: ${PG_PASSWORD}
      TZ: ${TZ}
    volumes:
      - ./data/postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -h 127.0.0.1 -p ${PG_PORT} -U ${PG_USER} -d thingsboard"]
      interval: 5s
      timeout: 5s
      retries: 30

  thingsboard:
    <<: *common
    image: thingsboard/tb-node:${TB_VERSION}
    container_name: iot-thingsboard
    environment:
      TZ: ${TZ}
      TB_SERVICE_ID: tb-ce-node
      TB_QUEUE_TYPE: in-memory
      SPRING_DATASOURCE_URL: jdbc:postgresql://127.0.0.1:${PG_PORT}/thingsboard
      SPRING_DATASOURCE_USERNAME: ${PG_USER}
      SPRING_DATASOURCE_PASSWORD: ${PG_PASSWORD}
      # Solo local: Caddy lo publica en 8080 (HTTP) y 443 (HTTPS) con la marca propia
      HTTP_BIND_ADDRESS: 127.0.0.1
      HTTP_BIND_PORT: ${TB_INTERNAL_PORT}
      MQTT_BIND_PORT: ${TB_MQTT_PORT}
      # Transportes y servicios que no se usan (evita ocupar puertos del host)
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
    image: eclipse-mosquitto:2
    container_name: iot-mosquitto
    volumes:
      - ./config/mosquitto:/mosquitto/config
      - ./data/mosquitto:/mosquitto/data

  node-red:
    <<: *common
    image: nodered/node-red:latest
    container_name: iot-nodered
    environment:
      TZ: ${TZ}
    volumes:
      - ./data/nodered:/data
      - ./config/nodered/settings.js:/data/settings.js:ro
    depends_on:
      - mosquitto
      - thingsboard

  caddy:
    <<: *common
    image: caddy:2
    container_name: iot-caddy
    volumes:
      - ./config/caddy/Caddyfile:/etc/caddy/Caddyfile:ro
      - ./config/branding:/srv/branding:ro
      - ./data/caddy:/data
      - ./data/caddy-config:/config
    depends_on:
      - thingsboard

  # GUI web de PostgreSQL (login: servidor 127.0.0.1:PG_PORT, usuario/contraseña de Postgres)
  adminer:
    <<: *common
    image: adminer:latest
    container_name: iot-adminer
    command: ["php", "-S", "0.0.0.0:${ADMINER_PORT}", "-t", "/var/www/html"]
    environment:
      ADMINER_DEFAULT_SERVER: 127.0.0.1:${PG_PORT}
    depends_on:
      - postgres

  # GUI web de Mosquitto (MQTT Explorer); acceso protegido con usuario/contraseña
  mqtt-explorer:
    <<: *common
    image: smeagolworms4/mqtt-explorer:latest
    container_name: iot-mqtt-explorer
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
    image: lscr.io/linuxserver/duckdns:latest
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
chmod +x start.sh stop.sh logs.sh

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
import json, os, re, shutil, urllib.request
from pathlib import Path

E = os.environ
TB = f"http://localhost:{E['TB_HTTP_PORT']}"
NR = f"http://localhost:{E['NODERED_PORT']}"
OUT = Path(__file__).parent / "export"


def call(method, url, body=None, token=None, nr=False):
    h = {"Content-Type": "application/json"}
    if token:
        h["Authorization" if nr else "X-Authorization"] = "Bearer " + token
    req = urllib.request.Request(url, json.dumps(body).encode() if body else None, h, method=method)
    with urllib.request.urlopen(req, timeout=30) as r:
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

echo "==> Arrancando PostgreSQL..."
docker compose up -d --wait postgres

# Exigir contraseña tambien en conexiones locales: con la red del host, "trust"
# (valor por defecto de la imagen) dejaria entrar a cualquier proceso del servidor
docker compose exec -T -u postgres postgres sh -c '
  if grep -qE "[[:space:]]trust[[:space:]]*$" "$PGDATA/pg_hba.conf"; then
    sed -i -E "s/[[:space:]]trust[[:space:]]*$/ scram-sha-256/" "$PGDATA/pg_hba.conf"
    pg_ctl reload -D "$PGDATA" >/dev/null && echo "    PostgreSQL: autenticacion local con contraseña"
  fi'

# .tb_installed guarda la version con la que se creo la base de datos
INSTALADA=$(cat .tb_installed 2>/dev/null || true)
if [ ! -f .tb_installed ]; then
  # El instalador abre el puerto web: no puede haber otro ThingsBoard corriendo
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
echo "==> Esperando a ThingsBoard en localhost:$TB_HTTP_PORT (1-3 minutos)..."
INICIO=$(date +%s)
until curl -sf -o /dev/null "http://localhost:$TB_HTTP_PORT/login"; do
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

# Con network_mode: host los puertos NO pasan por las reglas de Docker:
# si ufw esta activo hay que abrirlos para acceder desde la LAN
if command -v ufw >/dev/null 2>&1 && sudo -n ufw status 2>/dev/null | grep -q "Status: active"; then
  echo "==> ufw activo: abriendo puertos del stack"
  for p in 80 443 "$TB_HTTP_PORT" "$TB_MQTT_PORT" "$MQTT_PORT" "$NODERED_PORT" "$ADMINER_PORT" "$MQTTX_PORT"; do
    sudo -n ufw allow "$p/tcp" >/dev/null && echo "    $p/tcp abierto"
  done
fi

# --------------------------------------------
# 9. Configuracion via API (idempotente):
#    - contraseñas de ThingsBoard
#    - gateway, dispositivo simulado, cliente, usuario y panel en ThingsBoard
#    - flujos de Node-RED: puente Mosquitto -> TB y simulador
# --------------------------------------------
echo "==> Configurando ThingsBoard y Node-RED..."
TB_URL="http://localhost:$TB_HTTP_PORT" NR_URL="http://localhost:$NODERED_PORT" \
TB_SYSADMIN_PASSWORD="$TB_SYSADMIN_PASSWORD" TB_TENANT_PASSWORD="$TB_TENANT_PASSWORD" \
TB_TENANT_EMAIL="$TB_TENANT_EMAIL" TB_LANG="$TB_LANG" \
TB_GATEWAY_NAME="$TB_GATEWAY_NAME" SIM_INTERVAL="$SIM_INTERVAL" \
CLIENTES="$(printf '%s\n' "${CLIENTES[@]}")" \
COMUNIDAD_SITIOS="$(printf '%s\n' "${COMUNIDAD_SITIOS[@]}")" TZ="$TZ" \
NODERED_USER="$NODERED_USER" NODERED_PASSWORD="$NODERED_PASSWORD" \
MQTT_PORT="$MQTT_PORT" MQTT_USER="$MQTT_USER" MQTT_PASSWORD="$MQTT_PASSWORD" \
TB_MQTT_PORT="$TB_MQTT_PORT" \
python3 - <<'PY'
import json, math, os, random, re, time, urllib.error, urllib.parse, urllib.request, uuid
from datetime import datetime
from zoneinfo import ZoneInfo

E = os.environ
TB, NR = E["TB_URL"], E["NR_URL"]
CLIENTES = [dict(zip(("cliente", "email", "password", "device", "panel", "perfil"), l.split("|")))
            for l in E["CLIENTES"].splitlines() if l.strip()]


def http(method, url, body=None, headers=None, raw=False):
    data = None if body is None else json.dumps(body).encode()
    h = {"Content-Type": "application/json", **(headers or {})}
    req = urllib.request.Request(url, data=data, headers=h, method=method)
    with urllib.request.urlopen(req, timeout=30) as r:
        txt = r.read().decode()
    if raw:
        return txt
    return json.loads(txt) if txt.strip() else None


def wait(url, seconds):
    end = time.time() + seconds
    while time.time() < end:
        try:
            urllib.request.urlopen(url, timeout=5)
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
              *(len(c["password"]) for c in CLIENTES))
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




# ======================= Comunidad energetica (perfil "comunidad") =======================
# Cada sitio: dispositivo con atributos (ubicacion y potencias) y telemetria simulada
# por Node-RED con balance FV + bateria + red. Panel: mapa + tabla y, al pulsar un
# sitio, diagrama de flujo de energia del dia y reparto horario (barras apiladas + SOC).
SITIOS = [dict(zip(("device", "nombre", "lat", "lon", "kwp", "bat_kwh", "bat_kw", "contratada_kw", "tipo"),
                   l.split("|"))) for l in E.get("COMUNIDAD_SITIOS", "").splitlines() if l.strip()]
for st_ in SITIOS:
    for k in ("lat", "lon", "kwp", "bat_kwh", "bat_kw", "contratada_kw"):
        st_[k] = float(st_[k])
STEP_S = 300            # relleno historico: una lectura cada 5 minutos
DASH_VERSION = 7        # sube este numero para regenerar el panel de la comunidad
MODELO_VERSION = "cec-modelo v2"   # idem para rehacer historico y simulador de Node-RED

# Modelo compartido con el simulador de Node-RED (misma logica en JavaScript)
MODELO_JS = r"""
function gauss(h, mu, sd) { return Math.exp(-0.5 * Math.pow((h - mu) / sd, 2)); }
function sig(x) { return 1 / (1 + Math.exp(-x)); }
function demandaForma(tipo, h) {
  if (tipo === 'Comercial') return 0.12 + 0.55 * gauss(h, 11.5, 2.8) + 0.45 * gauss(h, 17.5, 2.2);
  if (tipo === 'Industrial') return 0.2 + 0.65 * sig((h - 7) * 3) * sig((19 - h) * 3);
  return 0.12 + 0.3 * gauss(h, 8.5, 1) + 0.25 * gauss(h, 14.5, 1.2) + 0.55 * gauss(h, 21, 1.5);
}
function paso(s, site, h, dt, dia) {
  if (s.day !== dia) { s.day = dia; s.e = { gen: 0, dem: 0, imp: 0, exp: 0, carga: 0, desc: 0 }; }
  s.nubes = Math.min(0.6, Math.max(0, s.nubes + (Math.random() - 0.5) * 0.08));
  const sol = Math.max(0, Math.sin(Math.PI * (h - 7) / 13));
  const pv = site.kwp * 0.85 * Math.pow(sol, 1.2) * (1 - 0.6 * s.nubes);
  const dem = site.contratada_kw * 0.55 * demandaForma(site.tipo, h) * (0.92 + Math.random() * 0.16);
  const cap = site.bat_kwh;
  let carga = 0, desc = 0;
  if (pv > dem) carga = Math.min(pv - dem, site.bat_kw, Math.max(0, (0.95 - s.soc) * cap / dt));
  else desc = Math.min(dem - pv, site.bat_kw, Math.max(0, (s.soc - 0.10) * cap / dt));
  s.soc += (carga * 0.95 - desc) * dt / cap;
  const red = dem - pv + carga - desc;
  const imp = Math.max(red, 0), exp = Math.max(-red, 0);
  s.e.gen += pv * dt; s.e.dem += dem * dt; s.e.imp += imp * dt;
  s.e.exp += exp * dt; s.e.carga += carga * dt; s.e.desc += desc * dt;
  const r = (v, n) => +v.toFixed(n === undefined ? 2 : n);
  return {
    generacion_kw: r(pv), consumo_kw: r(dem), red_kw: r(red), bateria_kw: r(carga - desc),
    soc: r(s.soc * 100, 1), desc_kw: r(desc), imp_kw: r(imp),
    dem_neg_kw: r(-dem), carga_neg_kw: r(-carga), exp_neg_kw: r(-exp), total_kw: r(dem + carga + exp),
    e_gen_kwh: r(s.e.gen), e_dem_kwh: r(s.e.dem), e_imp_kwh: r(s.e.imp),
    e_exp_kwh: r(s.e.exp), e_carga_kwh: r(s.e.carga), e_desc_kwh: r(s.e.desc)
  };
}
"""


def _gauss(h, mu, sd):
    return math.exp(-0.5 * ((h - mu) / sd) ** 2)


def _sig(x):
    return 1 / (1 + math.exp(-x))


def _forma(tipo, h):
    if tipo == "Comercial":
        return 0.12 + 0.55 * _gauss(h, 11.5, 2.8) + 0.45 * _gauss(h, 17.5, 2.2)
    if tipo == "Industrial":
        return 0.2 + 0.65 * _sig((h - 7) * 3) * _sig((19 - h) * 3)
    return 0.12 + 0.3 * _gauss(h, 8.5, 1) + 0.25 * _gauss(h, 14.5, 1.2) + 0.55 * _gauss(h, 21, 1.5)


def _paso(s, site, h, dt, dia):
    """Version Python de paso() (MODELO_JS) para rellenar el historico."""
    if s["day"] != dia:
        s["day"], s["e"] = dia, dict(gen=0, dem=0, imp=0, exp=0, carga=0, desc=0)
    s["nubes"] = min(0.6, max(0, s["nubes"] + (random.random() - 0.5) * 0.08))
    sol = max(0, math.sin(math.pi * (h - 7) / 13))
    pv = site["kwp"] * 0.85 * sol ** 1.2 * (1 - 0.6 * s["nubes"])
    dem = site["contratada_kw"] * 0.55 * _forma(site["tipo"], h) * (0.92 + random.random() * 0.16)
    cap = site["bat_kwh"]
    carga = desc = 0
    if pv > dem:
        carga = min(pv - dem, site["bat_kw"], max(0, (0.95 - s["soc"]) * cap / dt))
    else:
        desc = min(dem - pv, site["bat_kw"], max(0, (s["soc"] - 0.10) * cap / dt))
    s["soc"] += (carga * 0.95 - desc) * dt / cap
    red = dem - pv + carga - desc
    imp, exp = max(red, 0), max(-red, 0)
    e = s["e"]
    e["gen"] += pv * dt; e["dem"] += dem * dt; e["imp"] += imp * dt
    e["exp"] += exp * dt; e["carga"] += carga * dt; e["desc"] += desc * dt
    r = lambda v, n=2: round(v, n)
    return {
        "generacion_kw": r(pv), "consumo_kw": r(dem), "red_kw": r(red), "bateria_kw": r(carga - desc),
        "soc": r(s["soc"] * 100, 1), "desc_kw": r(desc), "imp_kw": r(imp),
        "dem_neg_kw": r(-dem), "carga_neg_kw": r(-carga), "exp_neg_kw": r(-exp),
        "total_kw": r(dem + carga + exp),
        "e_gen_kwh": r(e["gen"]), "e_dem_kwh": r(e["dem"]), "e_imp_kwh": r(e["imp"]),
        "e_exp_kwh": r(e["exp"]), "e_carga_kwh": r(e["carga"]), "e_desc_kwh": r(e["desc"]),
    }


def rellenar_historico(dev, site):
    """24 h de datos simulados para que las graficas no salgan vacias. Devuelve el estado final."""
    did = dev["id"]["id"]
    keys = tb.get(f"/api/plugins/telemetry/DEVICE/{did}/keys/timeseries")
    if "total_kw" in keys:
        return None
    if keys:  # historico de una version anterior del modelo: se borra y se rehace
        http("DELETE", f"{TB}/api/plugins/telemetry/DEVICE/{did}/timeseries/delete?keys="
             + urllib.parse.quote(",".join(keys)) + "&deleteAllDataForKeys=true", headers=tb.h, raw=True)
    tz = ZoneInfo(E.get("TZ", "Europe/Madrid"))
    s = {"soc": 0.5, "nubes": 0.2, "day": "", "e": {}}
    now = int(time.time())
    filas = []
    for t in range(now - 86400, now, STEP_S):
        lt = datetime.fromtimestamp(t, tz)
        vals = _paso(s, site, lt.hour + lt.minute / 60, STEP_S / 3600, lt.strftime("%Y-%m-%d"))
        filas.append({"ts": t * 1000, "values": vals})
    tb.post(f"/api/plugins/telemetry/DEVICE/{dev['id']['id']}/timeseries/ANY", filas)
    return s


def sitio_dispositivo(cid, site):
    dev = device(site["device"], "comunidad-energetica")
    if dev.get("label") != site["nombre"]:
        dev["label"] = site["nombre"]
        dev = tb.post("/api/device", dev)
    tb.post(f"/api/customer/{cid}/device/{dev['id']['id']}")
    # "bateria_kw" como atributo (version anterior) chocaba con la telemetria del mismo nombre
    http("DELETE", f"{TB}/api/plugins/telemetry/DEVICE/{dev['id']['id']}/SERVER_SCOPE?keys=bateria_kw",
         headers=tb.h, raw=True)
    tb.post(f"/api/plugins/telemetry/DEVICE/{dev['id']['id']}/attributes/SERVER_SCOPE", {
        "latitude": site["lat"], "longitude": site["lon"], "tipo": site["tipo"],
        "pv_kwp": site["kwp"], "bateria_kwh": site["bat_kwh"], "bateria_potencia_kw": site["bat_kw"],
        "potencia_contratada_kw": site["contratada_kw"]})
    return dev


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


def _accion_detalle(nombre="Ver detalle"):
    return {"id": str(uuid.uuid4()), "name": nombre, "icon": "insights", "type": "openDashboardState",
            "targetDashboardStateId": "sitio", "setEntityId": True, "stateEntityParamName": None,
            "openRightLayout": False, "openInSeparateDialog": False, "openInPopover": False}


ATTRS = [("pv_kwp", "FV instalada", "kWp"), ("bateria_kwh", "Batería", "kWh"),
         ("bateria_potencia_kw", "Potencia batería", "kW"), ("potencia_contratada_kw", "Contratada", "kW")]
LIVE = [("generacion_kw", "Generación", "kW", "#f5a623"), ("consumo_kw", "Consumo", "kW", "#29b6f6"),
        ("red_kw", "Red (+compra/−vertido)", "kW", "#e53935"), ("bateria_kw", "Batería (+carga/−desc.)", "kW", "#7e57c2"),
        ("soc", "SOC", "%", "#ec407a")]


def w_mapa(alias, x, y, w, h):
    cfg, typ = _base("system.map")
    marker = json.loads(json.dumps(cfg["settings"]["markers"][0]))
    marker.update({
        "dsType": "entity", "dsLabel": "Sitios", "dsEntityAliasId": alias, "dsDeviceId": None,
        "dsFilterId": None,
        "additionalDataKeys": [_dk(k, k, "timeseries") for k, *_ in LIVE] +
                              [_dk(k, k, "attribute") for k, *_ in ATTRS] + [_dk("tipo", "tipo", "attribute")],
        "xKey": _dk("latitude", "latitude", "attribute"),
        "yKey": _dk("longitude", "longitude", "attribute"),
        "label": {"show": True, "type": "pattern", "pattern": "${entityLabel}"},
        "tooltip": {"show": True, "trigger": "click", "autoclose": True, "type": "pattern",
                    "offsetX": 0, "offsetY": -1, "pattern":
                    "<b>${entityLabel}</b> <small>(${tipo})</small><br/>"
                    "FV ${pv_kwp:1} kWp · Batería ${bateria_kwh:0} kWh / ${bateria_potencia_kw:1} kW<br/>"
                    "Potencia contratada ${potencia_contratada_kw:2} kW<br/><br/>"
                    "<b>Generación:</b> ${generacion_kw:2} kW<br/>"
                    "<b>Consumo:</b> ${consumo_kw:2} kW<br/>"
                    "<b>Red:</b> ${red_kw:2} kW <small>(+compra / −vertido)</small><br/>"
                    "<b>Batería:</b> ${bateria_kw:2} kW · SOC ${soc:0} %<br/>"
                    "<small>Pulsa el marcador para ver el detalle</small>"},
        "markerType": "shape",
        "markerShape": {"shape": "markerShape1", "size": 38, "color": {
            "type": "function", "color": "#307FE5",
            "colorFunction": "var r = data.red_kw;\nif (r === undefined || r === null) return '#9e9e9e';\n"
                             "if (r < -0.05) return '#2e7d32';\nif (r > 0.05) return '#e53935';\n"
                             "return '#1e88e5';"}},
        "click": _accion_detalle(),
    })
    marker.pop("groups", None)
    cfg["settings"]["markers"] = [marker]
    cfg.update({"title": "Sitios — verde: vierte a la red · rojo: compra · azul: en equilibrio",
                "showTitle": True, "datasources": []})
    return _w("system.map", cfg, typ, x, y, w, h)


def w_tabla(alias, x, y, w, h):
    cfg, typ = _base("system.cards.entities_table")
    cfg["settings"].update({"entitiesTitle": "Sitios", "displayEntityLabel": True,
                            "entityLabelColumnTitle": "Sitio",
                            "displayEntityName": False, "defaultSortOrder": "entityLabel",
                            "displayPagination": False, "enableSearch": False})
    cortas = {"pv_kwp": "FV kWp", "bateria_kwh": "Bat. kWh", "bateria_potencia_kw": "Bat. kW",
              "bateria_kw": "Bat. ±kW",
              "potencia_contratada_kw": "Contr. kW", "generacion_kw": "Gen. kW", "consumo_kw": "Cons. kW",
              "red_kw": "Red kW", "soc": "SOC %"}
    keys = [_dk(k, cortas[k], "attribute", decimals=1) for k, *_ in ATTRS]
    keys += [_dk(k, cortas[k], "timeseries", color=c, decimals=1) for k, lab, u, c in LIVE if k in cortas]
    cfg["datasources"] = [{"type": "entity", "entityAliasId": alias, "dataKeys": keys}]
    cfg.update({"title": "Sitios", "showTitle": False,
                "actions": {"rowClick": [_accion_detalle()]}})
    return _w("system.cards.entities_table", cfg, typ, x, y, w, h)


def w_card(alias, key, label, units, color, icon, x, y, w, h):
    cfg, typ = _base("system.cards.value_card")
    cfg["datasources"] = [{"type": "entity", "entityAliasId": alias,
                           "dataKeys": [_dk(key, label, color=color, units=units, decimals=1)]}]
    cfg.update({"title": label, "showTitle": False, "units": units, "decimals": 1})
    cfg.setdefault("settings", {})["icon"] = icon
    cfg["settings"]["iconColor"] = {"type": "constant", "color": color}
    return _w("system.cards.value_card", cfg, typ, x, y, w, h)


CABECERA_JS = r"""
var d = data[0] || {};
function v(k, n) { var x = parseFloat(d[k]); return isNaN(x) ? '–' : x.toFixed(n); }
return '<div style="display:flex;flex-wrap:wrap;gap:24px;align-items:baseline;font-size:15px;padding:6px 4px">' +
  '<span style="font-size:20px;font-weight:600">' + (d.entityLabel || d.entityName || '') + '</span>' +
  '<span>' + (d.tipo || '') + '</span>' +
  '<span>FV instalada <b>' + v('pv_kwp', 1) + ' kWp</b></span>' +
  '<span>Batería <b>' + v('bateria_kwh', 0) + ' kWh</b> / <b>' + v('bateria_potencia_kw', 1) + ' kW</b></span>' +
  '<span>Potencia contratada <b>' + v('potencia_contratada_kw', 2) + ' kW</b></span></div>';
"""

FLUJO_JS = r"""
var d = data[0] || {};
function v(k, n) { var x = parseFloat(d[k]); return isNaN(x) ? '–' : x.toFixed(n === undefined ? 1 : n).replace('.', ','); }
var C = {fv:'#f5a623', dem:'#29b6f6', carga:'#5c6bc0', desc:'#9ccc65', exp:'#26c281', imp:'#e53935', txt:'#37474f'};
function marker(id, c) { return '<marker id="'+id+'" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0,0L10,5L0,10z" fill="'+c+'"/></marker>'; }
function line(x1,y1,x2,y2,c,id) { return '<line x1="'+x1+'" y1="'+y1+'" x2="'+x2+'" y2="'+y2+'" stroke="'+c+'" stroke-width="2.5" marker-end="url(#'+id+')"/>'; }
function lab(x,y,t,c) { return '<text x="'+x+'" y="'+y+'" fill="'+c+'" font-size="13" font-weight="700" text-anchor="middle">'+t+'</text>'; }
function node(x,y,t) { return '<ellipse cx="'+x+'" cy="'+y+'" rx="58" ry="22" fill="#fff" stroke="#00838f" stroke-width="2"/>' +
  '<text x="'+x+'" y="'+(y+5)+'" font-size="13" font-weight="700" text-anchor="middle" fill="'+C.txt+'">'+t+'</text>'; }
function box(x,y,val,u,c) { return '<rect x="'+x+'" y="'+y+'" width="62" height="24" rx="3" fill="#fff" stroke="#00838f"/>' +
  '<text x="'+(x+31)+'" y="'+(y+17)+'" font-size="13" text-anchor="middle" fill="'+C.txt+'">'+val+'</text>' +
  '<text x="'+(x+68)+'" y="'+(y+17)+'" font-size="12" font-weight="700" fill="'+(c||'#00838f')+'">'+u+'</text>'; }
var s = '<svg viewBox="0 0 560 370" style="width:100%;height:100%;font-family:Roboto,sans-serif">' +
  '<defs>' + marker('aFv',C.fv) + marker('aDem',C.dem) + marker('aCar',C.carga) + marker('aDes',C.desc) + marker('aExp',C.exp) + marker('aImp',C.imp) + '</defs>' +
  // leyenda
  '<g font-size="11" fill="'+C.txt+'">' +
  '<rect x="10" y="8" width="10" height="3" fill="'+C.fv+'"/><text x="24" y="13">generación FV</text>' +
  '<rect x="110" y="8" width="10" height="3" fill="'+C.dem+'"/><text x="124" y="13">demanda</text>' +
  '<rect x="185" y="8" width="10" height="3" fill="'+C.carga+'"/><text x="199" y="13">carga batería</text>' +
  '<rect x="285" y="8" width="10" height="3" fill="'+C.desc+'"/><text x="299" y="13">descarga batería</text>' +
  '<rect x="10" y="24" width="10" height="3" fill="'+C.exp+'"/><text x="24" y="29">exportación a red</text>' +
  '<rect x="125" y="24" width="10" height="3" fill="'+C.imp+'"/><text x="139" y="29">importación de red</text></g>' +
  // nodos
  node(280,70,'FV') + node(280,190,'Electricidad') + node(90,190,'Batería') + node(470,190,'Red') + node(280,320,'Demanda') +
  // flechas y kWh del dia
  line(280,92,280,166,C.fv,'aFv') + lab(300,135,v('e_gen_kwh'),C.fv) +
  line(222,182,150,182,C.carga,'aCar') + lab(186,174,v('e_carga_kwh'),C.carga) +
  line(150,200,222,200,C.desc,'aDes') + lab(186,218,v('e_desc_kwh'),C.desc) +
  line(412,182,338,182,C.imp,'aImp') + lab(375,174,v('e_imp_kwh'),C.imp) +
  line(338,200,412,200,C.exp,'aExp') + lab(375,218,v('e_exp_kwh'),C.exp) +
  line(280,212,280,296,C.dem,'aDem') + lab(304,258,v('e_dem_kwh'),C.dem) +
  // capacidades
  box(360,58,v('pv_kwp'),'kWp',C.fv) +
  box(20,240,v('bateria_kwh',0),'kWh') + box(20,270,v('bateria_potencia_kw'),'kW') + box(20,300,v('soc',0),'% SOC') +
  box(420,240,v('potencia_contratada_kw',2),'kW contr.') +
  box(360,308,v('e_dem_kwh'),'kWh/día',C.dem) +
  '</svg>';
return '<div style="height:100%;display:flex;align-items:center">' + s + '</div>';
"""


def w_markdown(alias, fn, keys, title, x, y, w, h, show_title=True):
    cfg, typ = _base("system.cards.markdown_card")
    cfg["datasources"] = [{"type": "entity", "entityAliasId": alias, "dataKeys": keys}]
    cfg["settings"].update({"useMarkdownTextFunction": True, "markdownTextFunction": fn,
                            "applyDefaultMarkdownStyle": False, "markdownCss": ""})
    cfg.update({"title": title, "showTitle": show_title, "padding": "4px"})
    return _w("system.cards.markdown_card", cfg, typ, x, y, w, h)


def w_reparto(alias, x, y, w, h):
    cfg, typ = _base("system.time_series_chart")
    serie = lambda k, lab, c: _dk(k, lab, color=c, units="kWh", decimals=2,
                                  settings={"type": "bar", "yAxisId": "default", "showInLegend": True})
    # ThingsBoard apila todas las series de un mismo eje sumandolas en orden
    # (stackStrategy "all"): primero las salidas (bajan desde 0), luego una serie
    # transparente con el total (+T) que devuelve la base a 0, y despues las
    # entradas (suben desde 0). Entradas y salidas suman lo mismo (balance).
    total = serie("total_kw", "Total (entra = sale)", "rgba(0,0,0,0)")
    total["settings"]["showInLegend"] = False
    keys = [serie("dem_neg_kw", "Demanda", "#29b6f6"),
            serie("carga_neg_kw", "Carga batería", "#5c6bc0"),
            serie("exp_neg_kw", "Exportación", "#26c281"),
            total,
            serie("generacion_kw", "Generación", "#f5a623"),
            serie("desc_kw", "Descarga batería", "#9ccc65"),
            serie("imp_kw", "Importación", "#e53935"),
            _dk("soc", "SOC (%)", color="#ec407a", units="%", decimals=0,
                settings={"type": "line", "yAxisId": "soc", "showInLegend": True,
                          "lineSettings": {"step": True, "stepType": "end", "lineType": "dashed",
                                           "lineWidth": 2, "showPoints": False}})]
    cfg["datasources"] = [{"type": "entity", "entityAliasId": alias, "dataKeys": keys}]
    st = cfg["settings"]
    st["stack"] = True
    st["yAxes"]["default"].update({"units": "kWh", "decimals": 1, "label": "kWh"})
    soc_axis = json.loads(json.dumps(st["yAxes"]["default"]))
    soc_axis.update({"id": "soc", "units": "%", "decimals": 0, "label": "SOC %", "position": "right",
                     "min": 0, "max": 100, "order": 1})
    st["yAxes"]["soc"] = soc_axis
    st["legendConfig"].update({"direction": "row", "position": "bottom", "showAvg": False,
                               "showTotal": False})
    cfg.update({
        "title": "Reparto horario — entra (arriba) / sale (abajo), últimas 24 h",
        "showTitle": True, "useDashboardTimewindow": False, "displayTimewindow": True,
        # medias horarias de potencia (kW) = energia por hora (kWh)
        "timewindow": {"selectedTab": 0, "realtime": {"realtimeType": 0, "timewindowMs": 86400000,
                                                      "interval": 3600000},
                       "aggregation": {"type": "AVG", "limit": 25000}},
    })
    return _w("system.time_series_chart", cfg, typ, x, y, w, h)


def config_comunidad(title, devs):
    a_sitios, a_sitio = str(uuid.uuid4()), str(uuid.uuid4())
    est = {"comunidad": {}, "sitio": {}}
    widgets = {}

    def add(state, t):
        wid, wdef, lay = t
        widgets[wid] = wdef
        est[state][wid] = lay

    # Estado principal: mapa + tabla
    add("comunidad", w_mapa(a_sitios, 0, 0, 24, 11))
    add("comunidad", w_tabla(a_sitios, 0, 11, 24, 8))
    # Estado de detalle de un sitio
    attr_keys = [_dk(k, k, "attribute") for k, *_ in ATTRS] + [_dk("tipo", "tipo", "attribute")]
    add("sitio", w_markdown(a_sitio, CABECERA_JS, attr_keys, "Sitio", 0, 0, 24, 2, show_title=False))
    iconos = ["solar_power", "power", "electrical_services", "battery_charging_full", "battery_5_bar"]
    anchos = [5, 5, 5, 5, 4]
    xx = 0
    for (k, lab, u, c), ic, an in zip(LIVE, iconos, anchos):
        add("sitio", w_card(a_sitio, k, lab, u, c, ic, xx, 2, an, 3))
        xx += an
    flujo_keys = [_dk(k, k) for k in ("e_gen_kwh", "e_dem_kwh", "e_imp_kwh", "e_exp_kwh",
                                       "e_carga_kwh", "e_desc_kwh", "soc")] + attr_keys
    add("sitio", w_markdown(a_sitio, FLUJO_JS, flujo_keys, "Flujo de energía (kWh) — total del día",
                            0, 5, 10, 10))
    add("sitio", w_reparto(a_sitio, 10, 5, 14, 10))

    grid = {"columns": 24, "margin": 10, "outerMargin": True, "backgroundColor": "#eeeeee"}
    return {
        "cecVersion": DASH_VERSION,
        "description": "Comunidad energética: mapa de sitios, flujo de energía y reparto horario",
        "widgets": widgets,
        "states": {
            "comunidad": {"name": title, "root": True,
                          "layouts": {"main": {"widgets": est["comunidad"], "gridSettings": grid}}},
            "sitio": {"name": "${entityLabel}", "root": False,
                      "layouts": {"main": {"widgets": est["sitio"], "gridSettings": grid}}},
        },
        "entityAliases": {
            a_sitios: {"id": a_sitios, "alias": "Sitios", "filter": {
                "type": "entityList", "resolveMultiple": True, "entityType": "DEVICE",
                "entityList": [d["id"]["id"] for d in devs]}},
            a_sitio: {"id": a_sitio, "alias": "Sitio seleccionado", "filter": {
                "type": "stateEntity", "resolveMultiple": False, "stateEntityParamName": None,
                "defaultStateEntity": {"entityType": "DEVICE", "id": devs[0]["id"]["id"]}}},
        },
        "filters": {},
        "timewindow": {"selectedTab": 0,
                       "realtime": {"realtimeType": 0, "timewindowMs": 3600000, "interval": 5000},
                       "aggregation": {"type": "NONE", "limit": 5000}},
        "settings": {"stateControllerId": "entity", "showTitle": False,
                     "showDashboardsSelect": False, "showEntitiesSelect": False,
                     "showDashboardTimewindow": False, "showDashboardExport": False,
                     "toolbarAlwaysOpen": True},
    }


def panel_comunidad(title, devs, existente):
    cfg = config_comunidad(title, devs)
    if existente:
        d = tb.get(f"/api/dashboard/{existente['id']['id']}")
        if (d.get("configuration") or {}).get("cecVersion") == DASH_VERSION:
            return d
        d["configuration"] = cfg
        d = tb.post("/api/dashboard", d)
        print(f"    panel '{title}' actualizado (mapa + flujo + reparto horario)")
        return d
    d = tb.post("/api/dashboard", {"title": title, "configuration": cfg})
    print(f"    panel '{title}' creado (mapa + flujo + reparto horario)")
    return d


COMUNIDAD_INIT = {}   # estado final del relleno -> estado inicial del simulador en Node-RED


customers = tb.get(page("/api/customers"))["data"]
dashboards = tb.get(page("/api/tenant/dashboards"))["data"]
for c in CLIENTES:
    cust = find(customers, "title", c["cliente"])
    if not cust:
        cust = tb.post("/api/customer", {"title": c["cliente"]})
        print(f"    cliente '{c['cliente']}' creado")
    cid = cust["id"]["id"]
    if c["perfil"] == "comunidad":
        devs = [sitio_dispositivo(cid, st_) for st_ in SITIOS]
        for dev, st_ in zip(devs, SITIOS):
            fin = rellenar_historico(dev, st_)
            if fin:
                COMUNIDAD_INIT[st_["device"]] = fin
                print(f"    {st_['device']} ({st_['nombre']}): 24 h de historico simulado")
        dash = panel_comunidad(c["panel"], devs, find(dashboards, "title", c["panel"]))
        tb.post(f"/api/customer/{cid}/dashboard/{dash['id']['id']}")
        usuario_cliente(cid, c, dash["id"]["id"])
        continue
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
     "broker": "localhost", "port": E["MQTT_PORT"], "clientid": "", "protocolVersion": "4",
     "keepalive": "60", "cleansession": True, "autoConnect": True,
     "credentials": {"user": E["MQTT_USER"], "password": E["MQTT_PASSWORD"]}},
    {"id": "iot-broker-tb", "type": "mqtt-broker", "name": "ThingsBoard Gateway",
     "broker": "localhost", "port": E["TB_MQTT_PORT"], "clientid": "nodered-gw", "protocolVersion": "4",
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
    if c["perfil"] == "comunidad":
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

# Simulador de la comunidad: todos los sitios en una funcion (modelo FV + bateria + red),
# arranca desde el estado final del historico rellenado en ThingsBoard
if SITIOS:
    sites_js = json.dumps([{k: st_[k] for k in ("device", "kwp", "bat_kwh", "bat_kw", "contratada_kw", "tipo")}
                           for st_ in SITIOS], ensure_ascii=False)
    cec_fn = (f"// {MODELO_VERSION}\nconst SITES = {sites_js};\nconst INIT = {json.dumps(COMUNIDAD_INIT)};\n"
              f"const DT = {int(E['SIM_INTERVAL'])} / 3600;\n" + MODELO_JS + """
const st = context.get('st') || INIT;
const now = new Date();
const pad = n => String(n).padStart(2, '0');
const dia = now.getFullYear() + '-' + pad(now.getMonth() + 1) + '-' + pad(now.getDate());
const h = now.getHours() + now.getMinutes() / 60 + now.getSeconds() / 3600;
const out = [];
for (const site of SITES) {
  const s = st[site.device] || (st[site.device] = { soc: 0.5, nubes: 0.2, day: '', e: {} });
  out.push({ topic: 'iot/' + site.device + '/telemetry', payload: paso(s, site, h, DT, dia) });
}
context.set('st', st);
return [out];""")
    wanted += [
        {"id": "cec-tab", "type": "tab", "label": "Simulador comunidad energética",
         "info": "Sitios de la comunidad: FV + batería + red. Publica cada "
                 f"{E['SIM_INTERVAL']} s en `iot/<sitio>/telemetry` (Mosquitto)."},
        {"id": "cec-inject", "type": "inject", "z": "cec-tab", "name": f"cada {E['SIM_INTERVAL']} s",
         "props": [], "repeat": E["SIM_INTERVAL"], "once": True, "onceDelay": "3",
         "x": 150, "y": 100, "wires": [["cec-fn"]]},
        {"id": "cec-fn", "type": "function", "z": "cec-tab", "name": "sitios: FV + batería + red",
         "func": cec_fn, "outputs": 1, "x": 380, "y": 100, "wires": [["cec-out", "cec-debug"]]},
        {"id": "cec-out", "type": "mqtt out", "z": "cec-tab", "name": "iot/<sitio>/telemetry",
         "topic": "", "qos": "1", "retain": "false", "broker": "iot-broker-mosq",
         "x": 640, "y": 80, "wires": []},
        {"id": "cec-debug", "type": "debug", "z": "cec-tab", "name": "lectura", "active": False,
         "complete": "true", "x": 610, "y": 140, "wires": []},
    ]

current = http("GET", NR + "/flows", headers={**NRH, "Node-RED-API-Version": "v1"})
# Simulador de una version anterior del script (churriana-01 suelto): lo sustituye el de la comunidad
viejos = [n for n in current
          if n["id"].startswith("sim-churriana-01") or n.get("z") == "sim-churriana-01-tab"]
# Funcion del simulador de un modelo anterior: se sustituye por la actual
viejos += [n for n in current if n["id"] == "cec-fn" and MODELO_VERSION not in n.get("func", "")]
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

# --------------------------------------------
# 10. Resumen
# --------------------------------------------
cat > README.md <<EOF
# Stack IoT ThingsBoard (red del host)

| Servicio | Acceso | Credenciales |
|---|---|---|
| ThingsBoard (HTTPS) | https://$IP | $TB_TENANT_EMAIL / $TB_TENANT_PASSWORD · sysadmin@thingsboard.org / $TB_SYSADMIN_PASSWORD |
| ThingsBoard (HTTP LAN) | http://$IP:$TB_HTTP_PORT | (las mismas) |
$(for c in "${CLIENTES[@]}"; do IFS='|' read -r n e pw d pa pf <<< "$c"; echo "| Panel '$pa' ($n) | (login de cliente) | $e / $pw |"; done)
$( [ -n "$TB_DOMAIN" ] && echo "| ThingsBoard (Internet) | https://$TB_DOMAIN | (las mismas) |" )
| MQTT dispositivos TB | $IP:$TB_MQTT_PORT | token del dispositivo como usuario |
| Mosquitto (LAN) | mqtt://$IP:$MQTT_PORT | $MQTT_USER / $MQTT_PASSWORD |
| Mosquitto (WebSocket TLS) | wss://${TB_DOMAIN:-$IP}/mqtt | $MQTT_USER / $MQTT_PASSWORD |
| Node-RED | http://$IP:$NODERED_PORT | $NODERED_USER / $NODERED_PASSWORD |
| PostgreSQL | 127.0.0.1:$PG_PORT (solo local) | $PG_USER / $PG_PASSWORD |
| Adminer (GUI PostgreSQL) | http://$IP:$ADMINER_PORT/?pgsql=127.0.0.1%3A$PG_PORT&username=$PG_USER&db=thingsboard | sistema **PostgreSQL** (no MySQL) · $PG_USER / $PG_PASSWORD |
| MQTT Explorer (GUI Mosquitto) | http://$IP:$MQTTX_PORT | $MQTT_USER / $MQTT_PASSWORD (conexion "Mosquitto" precargada) |

## Carpetas

| Carpeta | Contenido |
|---|---|
| \`config/\` | mosquitto.conf + passwd, Caddyfile, settings.js de Node-RED |
| \`data/postgres\` | base de datos de ThingsBoard |
| \`data/thingsboard\`, \`data/thingsboard-logs\` | datos y logs de ThingsBoard |
| \`data/nodered\` | flujos (flows.json) y nodos de Node-RED |
| \`data/mosquitto\`, \`data/caddy\` | persistencia MQTT y certificados |
| \`export/\` | JSON de tenants, clientes, usuarios, dispositivos, paneles, reglas y flujos (\`./export.sh\`) |

Copia de seguridad: \`./stop.sh && sudo tar czf iot-tb-backup.tgz -C ~ iot-tb && ./start.sh\`

Prueba de extremo a extremo (crea el dispositivo \`sensor1\` en ThingsBoard):

\`\`\`bash
docker exec iot-mosquitto mosquitto_pub -p $MQTT_PORT -u $MQTT_USER -P '$MQTT_PASSWORD' \\
  -t iot/sensor1/telemetry -m '{"temperatura": 21.5}'
\`\`\`

Desde fuera de la LAN, por MQTT sobre WebSocket con TLS (puerto 443):

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
echo " ThingsBoard HTTP  : http://$IP:$TB_HTTP_PORT"
echo "   $TB_TENANT_EMAIL / $TB_TENANT_PASSWORD  (administrador)"
echo "   sysadmin@thingsboard.org / $TB_SYSADMIN_PASSWORD"
for c in "${CLIENTES[@]}"; do
  IFS='|' read -r n e pw d pa pf <<< "$c"
  echo "   $e / $pw  (cliente '$n', solo ve '$pa')"
done
echo " Node-RED          : http://$IP:$NODERED_PORT  ($NODERED_USER / $NODERED_PASSWORD)"
for c in "${CLIENTES[@]}"; do
  IFS='|' read -r n e pw d pa pf <<< "$c"
  [ "$pf" = "comunidad" ] && continue
  echo "   simulador '$d' ($pf) -> iot/$d/telemetry cada ${SIM_INTERVAL}s"
done
echo "   simulador comunidad: ${#COMUNIDAD_SITIOS[@]} sitios -> iot/<sitio>/telemetry cada ${SIM_INTERVAL}s"
echo " Mosquitto         : mqtt://$IP:$MQTT_PORT  ($MQTT_USER / $MQTT_PASSWORD)"
echo "   desde fuera     : wss://${TB_DOMAIN:-$IP}/mqtt  (mismas credenciales, TLS via Caddy)"
echo " MQTT ThingsBoard  : $IP:$TB_MQTT_PORT"
echo " Adminer (BD)      : http://$IP:$ADMINER_PORT/?pgsql=127.0.0.1%3A$PG_PORT&username=$PG_USER&db=thingsboard"
echo "                     (sistema PostgreSQL, contraseña $PG_PASSWORD)"
echo " MQTT Explorer     : http://$IP:$MQTTX_PORT  ($MQTT_USER / $MQTT_PASSWORD, pulsa CONNECT en 'Mosquitto')"
echo " Carpeta           : $INSTALL_DIR  (README.md con ejemplos)"
echo "   config/  ficheros de configuracion    data/  datos de cada contenedor"
echo "   export/  JSON de ThingsBoard y Node-RED (actualizar con ./export.sh)"
echo
docker compose ps
