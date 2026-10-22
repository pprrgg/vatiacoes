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
TB_HTTP_PORT="8080"     # ThingsBoard web/API sin TLS (LAN)
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
CLIENTES=(
  "Cliente Demo|cliente@$HOSTNAME_LAN.local|$IOT_PASSWORD|simulador-01|Panel simulador|ambiente"
  "Comunidad Energética Churriana|cec@$HOSTNAME_LAN.local|cec|churriana-01|Comunidad Energética Churriana|energia"
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
for p in 80 443 "$TB_HTTP_PORT" "$TB_MQTT_PORT" "$MQTT_PORT" "$MQTT_WS_PORT" "$NODERED_PORT" "$PG_PORT" "$ADMINER_PORT" "$MQTTX_PORT"; do
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
mkdir -p "$INSTALL_DIR"/config/{mosquitto,caddy,nodered} \
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
  echo "	# Todo lo demas: ThingsBoard"
  echo "	handle {"
  echo "		encode gzip"
  echo "		reverse_proxy localhost:$TB_HTTP_PORT"
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
      HTTP_BIND_PORT: ${TB_HTTP_PORT}
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
TB_TENANT_EMAIL="$TB_TENANT_EMAIL" \
TB_GATEWAY_NAME="$TB_GATEWAY_NAME" SIM_INTERVAL="$SIM_INTERVAL" \
CLIENTES="$(printf '%s\n' "${CLIENTES[@]}")" \
NODERED_USER="$NODERED_USER" NODERED_PASSWORD="$NODERED_PASSWORD" \
MQTT_PORT="$MQTT_PORT" MQTT_USER="$MQTT_USER" MQTT_PASSWORD="$MQTT_PASSWORD" \
TB_MQTT_PORT="$TB_MQTT_PORT" \
python3 - <<'PY'
import json, os, re, time, urllib.error, urllib.parse, urllib.request, uuid

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
            tb.post("/api/user?sendActivationMail=false", user)
        return
    u = tb.post("/api/user?sendActivationMail=false", {
        "email": c["email"], "authority": "CUSTOMER_USER", "firstName": c["cliente"],
        "customerId": {"id": cid, "entityType": "CUSTOMER"},
        "additionalInfo": {"defaultDashboardId": dash_id, "defaultDashboardFullscreen": False},
    })
    link = http("GET", f"{TB}/api/user/{u['id']['id']}/activationLink", headers=tb.h, raw=True)
    token = urllib.parse.parse_qs(urllib.parse.urlparse(link.strip().strip('"')).query)["activateToken"][0]
    http("POST", TB + "/api/noauth/activate?sendActivationMail=false",
         {"activateToken": token, "password": c["password"]})
    print(f"    usuario '{c['email']}' creado")


customers = tb.get(page("/api/customers"))["data"]
dashboards = tb.get(page("/api/tenant/dashboards"))["data"]
for c in CLIENTES:
    perfil = PERFILES[c["perfil"]]
    dev = device(c["device"], "simulado-" + c["perfil"])
    cust = find(customers, "title", c["cliente"])
    if not cust:
        cust = tb.post("/api/customer", {"title": c["cliente"]})
        print(f"    cliente '{c['cliente']}' creado")
    cid = cust["id"]["id"]
    tb.post(f"/api/customer/{cid}/device/{dev['id']['id']}")
    dash = find(dashboards, "title", c["panel"])
    if not dash:
        dash = crear_panel(c["panel"], perfil, dev)
        print(f"    panel '{c['panel']}' creado")
    # Solo este panel queda asignado al cliente
    tb.post(f"/api/customer/{cid}/dashboard/{dash['id']['id']}")
    usuario_cliente(cid, c, dash["id"]["id"])
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

current = http("GET", NR + "/flows", headers={**NRH, "Node-RED-API-Version": "v1"})
ids = {n["id"] for n in current}
missing = [n for n in wanted if n["id"] not in ids]
if missing:
    http("POST", NR + "/flows", current + missing,
         {**NRH, "Node-RED-API-Version": "v1", "Node-RED-Deployment-Type": "full"}, raw=True)
    print(f"  - Node-RED: {len(missing)} nodos desplegados (puente + simulador)")
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
  echo "   simulador '$d' ($pf) -> iot/$d/telemetry cada ${SIM_INTERVAL}s"
done
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
