#!/usr/bin/env bash
set -euo pipefail

# ============================================
# Setup stack IoT con ThingsBoard - pkserver
#
#   PostgreSQL  -> bases de datos de ThingsBoard y de la comunidad ("cec") (solo red interna)
#   ThingsBoard -> plataforma IoT (web + MQTT de dispositivos: 8883 con TLS hacia fuera,
#                  cada dispositivo con su token)
#   Adminer     -> GUI web de PostgreSQL       (perfil "tools", 127.0.0.1)
#   FastAPI     -> API de la comunidad (codigo en este script, paso 4; https://<servidor>/cec-api):
#                  sincronizacion diaria con Datadis (PostgreSQL -> ThingsBoard), informes,
#                  y simuladores (Gateway API de ThingsBoard). Sustituye a Node-RED.
#   Caddy       -> HTTPS en el 443 del servidor (certificado interno o Let's Encrypt)
#   pg-backup   -> copia diaria de PostgreSQL (thingsboard y cec) en backups/postgres
#   Homepage    -> portada de los servicios del servidor (LAN, puerto HOMEPAGE_PORT)
#   proman      -> web Astro de este repositorio (compilada y servida con nginx, LAN)
#
# Cambios respecto a la version con network_mode: host:
#  - Red bridge en lugar de network_mode: host. Solo se publican 80/443 (Caddy) y 8883 (MQTT con TLS).
#    Los servicios se hablan por nombre: postgres:5432, thingsboard:8080, thingsboard:1883.
#  - Adminer solo escucha en 127.0.0.1 (acceso por túnel SSH).
#  - Adminer pasa al perfil "tools": no arranca en producción salvo que se pida.
#  - Sin Mosquitto ni MQTT Explorer: los dispositivos publican en el MQTT de ThingsBoard.
#  - Versiones fijadas por variable (nada de :latest).
#  - Copias de seguridad diarias de PostgreSQL.
#
# Variables nuevas en .env: FASTAPI_API_KEY, SYNC_HORA, DATADIS_* (y el resto de *_VERSION)
# Ya no hacen falta: PG_PORT, TB_INTERNAL_PORT, TB_MQTT_PORT, ADMINER_PORT, NODERED_*, MOSQUITTO_*, MQTT_*, MQTTX_*
#
# Carpeta del stack ($INSTALL_DIR), montada en los contenedores:
#   config/mqtt-certs/  certificado TLS del MQTT de ThingsBoard (8883, ver mqtt-cert.sh)
#   config/caddy/       Caddyfile
#   config/fastapi/     API de la comunidad: Dockerfile, requirements.txt, app/ y config.json
#   data/postgres/      bases de datos de ThingsBoard y de la comunidad (cec)
#   data/thingsboard/   datos y logs de ThingsBoard
#   data/caddy/         certificados
#   backups/postgres/   volcados diarios de PostgreSQL (se guardan 7 dias)
#   export/             JSON de ThingsBoard (tenants, clientes, usuarios,
#                       dispositivos, paneles, reglas) -> se regenera con ./export.sh
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
FASTAPI_PY_VERSION="3.12-slim"   # imagen base de la API (dependencias: requirements.txt, paso 4)
CADDY_VERSION="2.11.7"
ADMINER_VERSION="5.5.1"
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
MQTTS_PORT="8883"       # MQTT con TLS de ThingsBoard (LAN e Internet)
ADMINER_PORT="8081"     # Adminer, solo 127.0.0.1 (perfil tools)
HOMEPAGE_PORT="3000"    # Homepage (portada de servicios), LAN
PROMAN_PORT="8030"      # web Astro (proman), LAN

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
PG_USER="$IOT_USER"
PG_PASSWORD="$IOT_PASSWORD"

# Dispositivo gateway de ThingsBoard por el que FastAPI publica la telemetria de los
# simuladores. El de versiones anteriores (Node-RED) se renombra.
TB_GATEWAY_NAME="IoT Gateway"
TB_GATEWAY_ANTERIOR="Node-RED Gateway"

# Clientes de ThingsBoard. Cada uno tiene su usuario, su dispositivo simulado en
# FastAPI (que publica en ThingsBoard por MQTT, Gateway API) y un panel propio:
# el usuario solo ve ese panel y ese dispositivo.
#   "Cliente|email de login|contraseña|dispositivo|panel|perfil"
#   perfil: ambiente (temperatura/humedad/potencia) | energia (generacion FV/consumo/red)
CLIENTES=(
  "Cliente Demo|cliente@$HOSTNAME_LAN.local|$IOT_PASSWORD|simulador-01|Panel simulador|ambiente"
)

# Comunidad energetica. Los datos de energia de cada socio son los de Datadis: la API de
# FastAPI los guarda en PostgreSQL (base "cec", la fuente de verdad) y los copia a
# ThingsBoard con la suma horaria de la comunidad. Un unico panel estandar (mapa de
# socios + datos): el administrador ve los totales de la comunidad y, pulsando un rayo
# del mapa, los de cada socio; cada socio ve el mismo panel solo con sus datos. El
# administrador tiene ademas, al pie del panel, la sincronizacion con Datadis y los informes.
CEC_NOMBRE="Comunidad Energética Demo"
# Administrador de la comunidad: ve la comunidad y a todos los socios, pero solo en el
# panel de la comunidad (sin menu lateral). El administrador de ThingsBoard es TB_TENANT_EMAIL.
CEC_ADMIN_EMAIL="demo@vatiaco.es"
CEC_ADMIN_PASSWORD="demo"
# Administrador de versiones anteriores: si existe, se le cambian el email y la contraseña
CEC_ADMIN_ANTERIOR_EMAIL="admin-cec@$HOSTNAME_LAN.local"
CEC_ADMIN_ANTERIOR_PASSWORD="cec"
# Textos de los campos de la pantalla de inicio de sesion de ThingsBoard (para todos)
LOGIN_USUARIO_TXT="Nombre de usuario ($CEC_ADMIN_EMAIL)"
LOGIN_PASSWORD_TXT="Contraseña ($CEC_ADMIN_PASSWORD)"

# Carpeta con las descargas de Datadis: una subcarpeta por suministro con
# Consumo_*.csv (curva de carga) y Contrato_*.csv (formato de la descarga web).
# La primera carga de cada socio sale de aqui (da su CUPS, contrato y maximetro).
DATADIS_DIR="$PROMAN_DIR/datadis"

# API de Datadis para la sincronizacion diaria (curvas nuevas de los CUPS de los socios).
# Vacio = se toman de py/.env del repositorio (DATADIS_USER, DATADIS_PASS,
# DATADIS_NIF_AUTORIZADOS); sin credenciales la sincronizacion relee los CSV de DATADIS_DIR.
DATADIS_USER=""
DATADIS_PASS=""
DATADIS_NIF_AUTORIZADOS=""
DATADIS_PAUSA_S="5"                  # segundos entre peticiones a Datadis
SYNC_HORA="07:15"                    # sincronizacion diaria (las distribuidoras publican con retraso)
DATOS_VERSION=3                      # sube este numero para recargar en ThingsBoard toda la telemetria

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
  echo "AVISO: se borraran TODOS los datos del stack (ThingsBoard, Postgres con las lecturas de la comunidad...)."
  read -r -p "Escribe 'borrar' para continuar: " OK
  [ "$OK" = "borrar" ] || { echo "Cancelado."; exit 1; }
  if [ -f "$INSTALL_DIR/docker-compose.yml" ]; then
    (cd "$INSTALL_DIR" && docker compose --profile duckdns --profile tools down -v --remove-orphans)
  fi
  # Los datos pertenecen a los usuarios de los contenedores: se borran con un contenedor.
  # backups/ se conserva a proposito.
  if [ -d "$INSTALL_DIR/data" ]; then
    docker run --rm -v "$INSTALL_DIR:/stack" alpine rm -rf /stack/data /stack/export /stack/config/mqtt-certs /stack/config/mosquitto
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
for p in 80 443 "$MQTTS_PORT" "$HOMEPAGE_PORT" "$PROMAN_PORT"; do
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
mkdir -p "$INSTALL_DIR"/config/{mqtt-certs,caddy,fastapi,branding,homepage,proman} \
         "$INSTALL_DIR"/data/{postgres,thingsboard,thingsboard-logs,caddy,caddy-config} \
         "$INSTALL_DIR"/export "$INSTALL_DIR"/backups/postgres
cd "$INSTALL_DIR"

# Propietarios que esperan los contenedores (ThingsBoard uid 799)
docker run --rm -v "$INSTALL_DIR/data:/d" alpine sh -c \
  "chown -R 799:799 /d/thingsboard /d/thingsboard-logs"

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

# Clave de la API de la comunidad para el script y tareas del servidor (cabecera
# X-Api-Key); los usuarios del panel usan su sesion de ThingsBoard. Se conserva entre ejecuciones.
FASTAPI_API_KEY=$(grep -s '^FASTAPI_API_KEY=' .env | cut -d= -f2- || true)
[ -n "$FASTAPI_API_KEY" ] || FASTAPI_API_KEY=$(openssl rand -hex 24 2>/dev/null || head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')

# Credenciales de Datadis: las de arriba o, si estan vacias, las de py/.env del repositorio
for v in DATADIS_USER DATADIS_PASS DATADIS_NIF_AUTORIZADOS; do
  if [ -z "${!v}" ] && [ -f "$PROMAN_DIR/py/.env" ]; then
    val=$(grep -s "^$v=" "$PROMAN_DIR/py/.env" | tail -1 | cut -d= -f2- | sed 's/ #.*//; s/^["'\'']//; s/["'\'']$//')
    printf -v "$v" '%s' "$val"
  fi
done

cat > .env <<EOF
TZ=$TZ
TB_VERSION=$TB_VERSION
PG_VERSION=$PG_VERSION
FASTAPI_PY_VERSION=$FASTAPI_PY_VERSION
CADDY_VERSION=$CADDY_VERSION
ADMINER_VERSION=$ADMINER_VERSION
HOMEPAGE_VERSION=$HOMEPAGE_VERSION
HOMEPAGE_PORT=$HOMEPAGE_PORT
HOMEPAGE_ALLOWED_HOSTS=$HOMEPAGE_HOSTS
PROMAN_DIR=$PROMAN_DIR
PROMAN_DOCKERFILE=$INSTALL_DIR/config/proman/Dockerfile
PROMAN_PORT=$PROMAN_PORT
DUCKDNS_VERSION=$DUCKDNS_VERSION
MQTTS_PORT=$MQTTS_PORT
PG_USER=$PG_USER
PG_PASSWORD=$PG_PASSWORD
TB_DOMAIN=$TB_DOMAIN
DUCKDNS_SUBDOMAIN=${TB_DOMAIN%%.duckdns.org}
DUCKDNS_TOKEN=$DUCKDNS_TOKEN
COMPOSE_PROFILES=$PROFILES
FASTAPI_API_KEY=$FASTAPI_API_KEY
SYNC_HORA=$SYNC_HORA
DATADIS_DIR=$DATADIS_DIR
DATADIS_USER=$DATADIS_USER
DATADIS_PASS='$DATADIS_PASS'
DATADIS_NIF_AUTORIZADOS=$DATADIS_NIF_AUTORIZADOS
DATADIS_PAUSA_S=$DATADIS_PAUSA_S
TB_SYSADMIN_PASSWORD=$TB_SYSADMIN_PASSWORD
TB_TENANT_EMAIL=$TB_TENANT_EMAIL
TB_TENANT_PASSWORD=$TB_TENANT_PASSWORD
EOF
chmod 600 .env

# --------------------------------------------
# 4. FastAPI (API de la comunidad): Dockerfile, dependencias, codigo (app/) y config.json
# --------------------------------------------
# Todo se escribe desde aqui en config/fastapi (se regenera en cada ejecucion: los cambios
# se hacen en este script). El codigo (app/) se monta en el contenedor: un cambio solo pide
# reiniciarlo, que hace este script. La imagen solo lleva las dependencias.
#   app/comun.py     entorno y config.json          app/db.py       PostgreSQL (base cec)
#   app/tb.py        cliente REST de ThingsBoard     app/datadis.py  API de Datadis
#   app/cec.py       sincronizacion CSV/Datadis -> PostgreSQL -> ThingsBoard
#   app/graficos.py  graficos SVG del panel          app/informes.py informes PDF/Excel/CSV
#   app/puente.py    simuladores (Gateway API)       app/main.py     API, planificador, auth
rm -rf config/fastapi/app
mkdir -p config/fastapi/app
cat > config/fastapi/Dockerfile <<'__FASTAPI_EOF__'
# API de la comunidad energetica (iot-thingsboard.sh). Solo dependencias: el codigo
# (app/) se monta en /srv/app, asi que un cambio de codigo solo pide reiniciar.
ARG PY_VERSION=3.12-slim
FROM python:${PY_VERSION}
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /srv
# Fuentes de los informes PDF (Typst y graficos SVG): Roboto, la del panel
RUN apt-get update && apt-get install -y --no-install-recommends fonts-roboto-unhinted fonts-dejavu-core \
    && rm -rf /var/lib/apt/lists/*
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
RUN useradd -r -u 10001 api
USER api
# Un unico worker: el planificador (sincronizacion diaria) y el puente MQTT no se duplican
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "1", \
     "--root-path", "/cec-api", "--proxy-headers", "--forwarded-allow-ips", "*"]
__FASTAPI_EOF__

cat > config/fastapi/requirements.txt <<'__FASTAPI_EOF__'
fastapi==0.115.*
uvicorn[standard]==0.32.*
psycopg[binary]==3.2.*
requests==2.32.*
paho-mqtt==2.1.*
APScheduler==3.10.*
openpyxl==3.1.*
typst>=0.13,<0.15
__FASTAPI_EOF__

: > config/fastapi/app/__init__.py

cat > config/fastapi/app/comun.py <<'__FASTAPI_EOF__'
"""Configuracion comun: entorno (.env del stack) y config.json (lo genera iot-thingsboard.sh)."""
import json
import logging
import os
from pathlib import Path
from zoneinfo import ZoneInfo

E = os.environ
TZL = ZoneInfo(E.get("TZ") or "Europe/Madrid")
CONFIG = Path(E.get("CEC_CONFIG", "/srv/config.json"))
DATADIS_DIR = Path(E.get("DATADIS_DIR", "/datadis"))

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
log = logging.getLogger("cec")


def config():
    """Socios, clientes simulados, nombre del gateway... Se lee en cada uso: el script de
    instalacion puede regenerarlo sin reiniciar el contenedor."""
    return json.loads(CONFIG.read_text(encoding="utf-8"))


def datadis_configurado():
    return bool(E.get("DATADIS_USER") and E.get("DATADIS_PASS"))
__FASTAPI_EOF__

cat > config/fastapi/app/db.py <<'__FASTAPI_EOF__'
"""PostgreSQL (base de datos "cec"): fuente de verdad de las lecturas y registro de las
sincronizaciones. ThingsBoard solo recibe una copia para sus paneles."""
import time
import uuid

import psycopg
from psycopg.rows import dict_row
from psycopg.types.json import Jsonb

from .comun import E, log

DSN = (f"host={E.get('PGHOST', 'postgres')} port={E.get('PGPORT', '5432')} "
       f"dbname={E.get('PGDATABASE', 'cec')} user={E['PGUSER']} password={E['PGPASSWORD']} "
       "options='-c TimeZone=UTC'")

ESQUEMA = """
CREATE TABLE IF NOT EXISTS suministro (
  cups        text PRIMARY KEY,
  socio       text NOT NULL,
  peaje       text,
  paso_min    smallint,
  contrato    jsonb NOT NULL DEFAULT '{}',
  firma_csv   text,              -- ficheros de Datadis cargados por ultima vez
  firma       text,              -- cambia con cada carga que modifica lecturas
  actualizado timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS suministro_socio ON suministro (socio, actualizado DESC);

-- Curva de carga: una fila por periodo de medida, ts = inicio del periodo
CREATE TABLE IF NOT EXISTS lectura (
  cups            text NOT NULL,
  ts              timestamptz NOT NULL,
  paso_min        smallint NOT NULL,
  consumo_kwh     double precision,
  vertida_kwh     double precision,
  generada_kwh    double precision,
  autoconsumo_kwh double precision,
  metodo          text,
  origen          text NOT NULL,   -- csv | datadis
  cargado         timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (cups, ts)
);

-- Maximetro: potencia maxima de cada mes y periodo
CREATE TABLE IF NOT EXISTS maximetro (
  cups    text NOT NULL,
  mes     date NOT NULL,
  periodo smallint NOT NULL,
  kw      double precision NOT NULL,
  cuando  text,
  PRIMARY KEY (cups, mes, periodo)
);

-- Datadis bloquea 24 h una consulta identica (cuenta tambien las rechazadas)
CREATE TABLE IF NOT EXISTS datadis_consulta (
  clave text PRIMARY KEY,
  hecha timestamptz NOT NULL
);

-- Socios deshabilitados por el administrador (casilla de la tabla de socios del panel):
-- no cuentan en los totales de la comunidad ni en su informe
CREATE TABLE IF NOT EXISTS socio_estado (
  socio         text PRIMARY KEY,
  deshabilitado boolean NOT NULL DEFAULT false,
  actualizado   timestamptz NOT NULL DEFAULT now(),
  por           text
);

CREATE TABLE IF NOT EXISTS sync_job (
  id         uuid PRIMARY KEY,
  origen     text NOT NULL,          -- auto | csv | datadis | comunidad (solo recalcula la comunidad)
  desde      text,
  hasta      text,
  forzar     boolean NOT NULL DEFAULT false,
  socios     text[],
  solicitado text,
  estado     text NOT NULL,          -- pendiente | en_curso | ok | con_errores | error
  creado     timestamptz NOT NULL DEFAULT now(),
  inicio     timestamptz,
  fin        timestamptz,
  total      int NOT NULL DEFAULT 0,
  hechos     int NOT NULL DEFAULT 0,
  errores    int NOT NULL DEFAULT 0,
  log        jsonb NOT NULL DEFAULT '[]'
);
CREATE INDEX IF NOT EXISTS sync_job_creado ON sync_job (creado DESC);
"""

ACTIVOS = ("pendiente", "en_curso")
FINALES = ("ok", "con_errores", "error")


def conectar(autocommit=True):
    return psycopg.connect(DSN, row_factory=dict_row, autocommit=autocommit)


def preparar(espera_s=300):
    """Crea el esquema (espera a PostgreSQL) y cierra los trabajos que un reinicio dejo a medias."""
    fin = time.time() + espera_s
    while True:
        try:
            with conectar() as cx:
                cx.execute(ESQUEMA)
                n = cx.execute(
                    "UPDATE sync_job SET estado = 'error', fin = now(), "
                    "log = log || %s WHERE estado = ANY(%s)",
                    (Jsonb([_linea("Interrumpida: el servicio se reinició")]), list(ACTIVOS))).rowcount
                if n:
                    log.warning("%s sincronizaciones interrumpidas marcadas como error", n)
            return
        except psycopg.OperationalError as e:
            if time.time() > fin:
                raise
            log.info("PostgreSQL no disponible todavia (%s)", e)
            time.sleep(3)


def _linea(texto):
    return {"t": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "m": texto}


# ---------------- trabajos de sincronizacion ----------------
def job_activo():
    with conectar() as cx:
        r = cx.execute("SELECT id FROM sync_job WHERE estado = ANY(%s) ORDER BY creado LIMIT 1",
                       (list(ACTIVOS),)).fetchone()
    return str(r["id"]) if r else None


def crear_job(origen, desde, hasta, forzar, socios, solicitado):
    jid = uuid.uuid4()
    with conectar() as cx:
        cx.execute("INSERT INTO sync_job (id, origen, desde, hasta, forzar, socios, solicitado, estado) "
                   "VALUES (%s, %s, %s, %s, %s, %s, %s, 'pendiente')",
                   (jid, origen, desde, hasta, forzar, socios, solicitado))
    return str(jid)


def job(jid):
    try:
        uuid.UUID(str(jid))
    except ValueError:
        return None
    with conectar() as cx:
        return cx.execute("SELECT * FROM sync_job WHERE id = %s", (jid,)).fetchone()


def jobs(limite=20):
    with conectar() as cx:
        return cx.execute("SELECT id, origen, desde, hasta, forzar, solicitado, estado, creado, inicio, fin, "
                          "total, hechos, errores FROM sync_job ORDER BY creado DESC LIMIT %s",
                          (limite,)).fetchall()


def empezar(jid, origen, total):
    with conectar() as cx:
        cx.execute("UPDATE sync_job SET estado = 'en_curso', origen = %s, total = %s, inicio = now() "
                   "WHERE id = %s", (origen, total, jid))


def nota(jid, texto):
    log.info("[sync %s] %s", str(jid)[:8], texto)
    with conectar() as cx:
        cx.execute("UPDATE sync_job SET log = log || %s WHERE id = %s", (Jsonb([_linea(texto)]), jid))


def avance(jid, hechos, errores):
    with conectar() as cx:
        cx.execute("UPDATE sync_job SET hechos = %s, errores = %s WHERE id = %s", (hechos, errores, jid))


def terminar(jid, estado):
    with conectar() as cx:
        cx.execute("UPDATE sync_job SET estado = %s, fin = now() WHERE id = %s", (estado, jid))


# ---------------- consultas a Datadis (bloqueo de 24 h) ----------------
def consultada(cx, clave):
    return cx.execute("SELECT 1 FROM datadis_consulta WHERE clave = %s AND hecha > now() - interval '24 hours'",
                      (clave,)).fetchone() is not None


def marcar_consulta(cx, clave):
    cx.execute("INSERT INTO datadis_consulta (clave, hecha) VALUES (%s, now()) "
               "ON CONFLICT (clave) DO UPDATE SET hecha = now()", (clave,))
    cx.execute("DELETE FROM datadis_consulta WHERE hecha < now() - interval '2 days'")
__FASTAPI_EOF__

cat > config/fastapi/app/tb.py <<'__FASTAPI_EOF__'
"""Cliente REST de ThingsBoard (red interna: http://thingsboard:8080) con el administrador
del tenant."""
import threading

import requests

from .comun import E

LOTE = 5000   # filas de telemetria por peticion


class TB:
    def __init__(self):
        self.url = E.get("TB_URL", "http://thingsboard:8080").rstrip("/")
        self.s = requests.Session()
        self.tok = None
        self._tenant = None
        self._lk = threading.Lock()

    def _login(self):
        r = requests.post(self.url + "/api/auth/login", timeout=30,
                          json={"username": E["TB_TENANT_EMAIL"], "password": E["TB_TENANT_PASSWORD"]})
        r.raise_for_status()
        self.tok = r.json()["token"]

    def req(self, metodo, ruta, **kw):
        """Peticion autenticada; renueva el token si caduca. 404 -> None."""
        for intento in range(2):
            with self._lk:
                if not self.tok:
                    self._login()
                tok = self.tok
            r = self.s.request(metodo, self.url + ruta, timeout=120,
                               headers={"X-Authorization": "Bearer " + tok}, **kw)
            if r.status_code == 401 and intento == 0:
                with self._lk:
                    self.tok = None
                continue
            if r.status_code == 404:
                return None
            r.raise_for_status()
            if r.content and "json" in r.headers.get("content-type", ""):
                return r.json()
            return None

    def tenant_id(self):
        if not self._tenant:
            self._tenant = self.req("GET", "/api/auth/user")["tenantId"]["id"]
        return self._tenant

    def dispositivo(self, nombre):
        return self.req("GET", "/api/tenant/devices", params={"deviceName": nombre})

    def credenciales(self, did):
        return self.req("GET", f"/api/device/{did}/credentials")["credentialsId"]

    def leer_atributos(self, did, claves):
        v = self.req("GET", f"/api/plugins/telemetry/DEVICE/{did}/values/attributes/SERVER_SCOPE",
                     params={"keys": ",".join(claves)}) or []
        return {a["key"]: a["value"] for a in v}

    def atributos(self, did, attrs):
        self.req("POST", f"/api/plugins/telemetry/DEVICE/{did}/attributes/SERVER_SCOPE", json=attrs)

    def telemetria(self, did, serie):
        """serie: [{"ts": ms, "values": {...}}]; ThingsBoard sobrescribe la misma clave y ts."""
        for i in range(0, len(serie), LOTE):
            self.req("POST", f"/api/plugins/telemetry/DEVICE/{did}/timeseries/ANY", json=serie[i:i + LOTE])

    def borrar_series(self, did):
        claves = self.req("GET", f"/api/plugins/telemetry/DEVICE/{did}/keys/timeseries") or []
        if claves:
            self.req("DELETE", f"/api/plugins/telemetry/DEVICE/{did}/timeseries/delete",
                     params={"keys": ",".join(claves), "deleteAllDataForKeys": "true"})


def usuario(token):
    """Usuario de ThingsBoard dueño de un JWT (None si no es valido)."""
    try:
        r = requests.get(E.get("TB_URL", "http://thingsboard:8080").rstrip("/") + "/api/auth/user",
                         headers={"X-Authorization": "Bearer " + token}, timeout=15)
    except requests.RequestException:
        return None
    return r.json() if r.status_code == 200 else None
__FASTAPI_EOF__

cat > config/fastapi/app/datadis.py <<'__FASTAPI_EOF__'
"""API privada de Datadis (https://datadis.es), la misma que py/datadis.py del repositorio."""
import time

import requests

from .comun import E

HOST = "https://datadis.es"
URL_LOGIN = f"{HOST}/nikola-auth/tokens/login"
URL_SUPPLIES = f"{HOST}/api-private/api/get-supplies-v2"
URL_CONSUMPTION = f"{HOST}/api-private/api/get-consumption-data-v2"
HOURLY, QUARTER = 0, 1          # measurementType
TIMEOUT = 180                   # Datadis puede tardar bastante en responder


class Datadis:
    def __init__(self, user=None, password=None, pausa_s=None):
        self.user = user or E["DATADIS_USER"]
        self.password = password or E["DATADIS_PASS"]
        self.pausa = float(pausa_s if pausa_s is not None else E.get("DATADIS_PAUSA_S") or 5)
        self.s = requests.Session()
        self.s.headers["Accept-Encoding"] = "identity"
        self.token = None
        self.avisos = []        # errores de distribuidora (no cortan la sincronizacion)
        self._ultima = 0.0

    def login(self):
        r = self.s.post(URL_LOGIN, data={"username": self.user, "password": self.password}, timeout=TIMEOUT)
        if r.status_code != 200:
            raise RuntimeError(f"Datadis: login rechazado ({r.status_code}): {r.text[:200]}")
        self.token = r.text.strip()
        self.s.headers["Authorization"] = f"Bearer {self.token}"

    def _get(self, url, params):
        if not self.token:
            self.login()
        for intento in range(2):
            espera = self._ultima + self.pausa - time.time()   # pausa entre peticiones
            if espera > 0:
                time.sleep(espera)
            r = self.s.get(url, params=params, timeout=TIMEOUT)
            self._ultima = time.time()
            if r.status_code == 401 and intento == 0:      # token caducado -> renovar
                self.login()
                continue
            if r.status_code == 429:
                raise RuntimeError("Datadis: límite de consultas (429); se podrá repetir en 24 h")
            if r.status_code != 200:
                raise RuntimeError(f"Datadis: error {r.status_code}: {r.text[:300]}")
            data = r.json() if r.text.strip() else {}
            if isinstance(data, dict):
                for e in data.get("distributorError") or []:
                    self.avisos.append(f"distribuidora {e.get('distributorName', e.get('distributorCode'))}: "
                                       f"{e.get('errorDescription', e)}")
            return data
        return {}

    def supplies(self, authorized_nif=None):
        data = self._get(URL_SUPPLIES, {"authorizedNif": authorized_nif} if authorized_nif else {})
        return data.get("supplies", []) if isinstance(data, dict) else data

    def consumption(self, supply, desde, hasta, measurement_type, authorized_nif=None):
        """desde/hasta: AAAA/MM. Devuelve la lista timeCurve."""
        params = {"cups": supply["cups"], "distributorCode": supply["distributorCode"],
                  "startDate": desde, "endDate": hasta, "measurementType": measurement_type,
                  "pointType": supply["pointType"]}
        if authorized_nif:
            params["authorizedNif"] = authorized_nif
        data = self._get(URL_CONSUMPTION, params)
        return data.get("timeCurve", []) if isinstance(data, dict) else (data or [])

    def mapa_cups(self, nifs):
        """CUPS -> (suministro, NIF autorizado o None) de la cuenta y de los NIF autorizados."""
        m = {}
        for nif in [None] + list(nifs):
            try:
                for s in self.supplies(nif):
                    m.setdefault(s["cups"], (s, nif))
            except RuntimeError as e:
                self.avisos.append(f"{'NIF ' + nif if nif else 'cuenta propia'}: {e}")
        return m
__FASTAPI_EOF__

cat > config/fastapi/app/cec.py <<'__FASTAPI_EOF__'
"""Comunidad energetica: lecturas de Datadis (ficheros CSV de la descarga web o API) ->
PostgreSQL -> ThingsBoard.

Dispositivos en ThingsBoard (los crea iot-thingsboard.sh; aqui solo se rellenan):
  <socio>     tipo "socio"      energia de cada periodo de medida (consumo_kwh, vertida_kwh,
                                generada_kwh, autoconsumo_kwh), totales diarios (d_*),
                                maximetro mensual (pmax_p*) y, como atributos, los datos del
                                suministro (CUPS, peaje, contrato...)
  comunidad   tipo "comunidad"  suma horaria y diaria de todos los socios
La telemetria lleva el ts original de cada lectura (inicio del periodo de medida).
"""
import csv
import glob
import hashlib
import os
import re
from datetime import date, datetime, timedelta, timezone

from . import db
from .comun import DATADIS_DIR, E, TZL, config, datadis_configurado, log
from .datadis import HOURLY, QUARTER, Datadis
from .tb import TB

LOCK = 727001          # pg_advisory_lock: una sola sincronizacion a la vez

# Energia de Datadis: clave en ThingsBoard/PostgreSQL, columna del CSV y campo de la API
SERIES = [("consumo_kwh", "consumo_kWh", "consumptionKWh"),
          ("vertida_kwh", "energiaVertida_kWh", "surplusEnergyKWh"),
          ("generada_kwh", "energiaGenerada_kWh", "generationEnergyKWh"),
          ("autoconsumo_kwh", "energiaAutoconsumida_kWh", "selfConsumptionEnergyKWh")]
CLAVES = [k for k, _, _ in SERIES]
COLS_CSV = {k: c for k, c, _ in SERIES}
COLS_API = {k: a for k, _, a in SERIES}

_TB = None


def tb():
    global _TB
    if _TB is None:
        _TB = TB()
    return _TB


# ======================= lectura de los datos de Datadis =======================
def _num(v):
    if v is None:
        return None
    if isinstance(v, (int, float)):
        return float(v)
    v = str(v).strip()
    try:
        return float(v.replace(",", ".")) if v else None
    except ValueError:
        return None


def _csv(ruta):
    with open(ruta, encoding="utf-8", newline="") as f:
        return list(csv.DictReader(f, delimiter=";"))


def a_filas(registros, f_fecha, f_hora, cols, f_metodo):
    """Curva de Datadis -> ([(ts_ms inicio, paso, {clave: kWh}, metodo)], paso en minutos).
    Datadis numera los periodos de cada dia de forma correlativa por su hora de fin
    (01:00..24:00; en los cambios de hora falta o se repite la 03:00): el inicio de cada
    uno es la medianoche local mas paso x posicion en el dia."""
    regs = [r for r in registros if (r.get(f_hora) or "").strip() not in ("", "00:00")]
    if not regs:
        return [], 60
    paso = 60 if all(r[f_hora].strip().endswith(":00") for r in regs) else 15
    filas, pos, t0 = [], {}, {}
    for r in regs:
        fecha = r[f_fecha].strip()
        if fecha not in t0:
            y, m, dd = map(int, fecha.split("/"))
            t0[fecha] = int(datetime(y, m, dd, tzinfo=TZL).timestamp()) * 1000
        i = pos[fecha] = pos.get(fecha, -1) + 1
        v = {k: x for k, col in cols.items() if (x := _num(r.get(col))) is not None}
        if v:
            filas.append((t0[fecha] + i * paso * 60000, paso, v, (r.get(f_metodo) or "").strip() or None))
    return filas, paso


def leer_csv(carpeta):
    """Curva de carga, maximetro y contrato de una carpeta de Datadis (descarga web). None si
    no hay curva. La firma es la de iot-thingsboard.sh (no se recarga lo que ya esta)."""
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
    filas, paso = a_filas(filas_csv, "fecha", "hora", COLS_CSV, "metodoObtencion")
    # Maximetro: potencia maxima de cada mes y periodo, con el dia y la hora en que se dio
    M = {}
    for r in _csv(fp[-1]) if fp else []:
        kw, per = _num(r.get("maximoPotenciaDemandadaKW")), (r.get("periodo") or "").strip()
        if kw is None or not per.isdigit():
            continue
        y, m, dd = map(int, r["fechaMaximo"].split("/"))
        clave = (date(y, m, 1), int(per))
        if kw >= M.get(clave, (-1,))[0]:
            M[clave] = (kw, f"{dd:02d}/{m:02d}/{y} {r.get('hora', '')}".strip())
    contrato = _csv(fk[-1]) if fk else []
    contrato = contrato[-1] if contrato else {}
    cups = (contrato.get("cups") or (filas_csv[0].get("cups") if filas_csv else "") or "").strip()
    return {"cups": cups, "filas": filas, "paso": paso, "contrato": contrato,
            "maximos": [(mes, per, kw, cuando) for (mes, per), (kw, cuando) in sorted(M.items())],
            "firma": firma.hexdigest()[:16]}


def peaje(c):
    """Peaje de acceso (2.0TD, 3.0TD, 6.1TD...) a partir del contrato de Datadis."""
    t = c.get("tarifaAcceso") or ""
    m = re.search(r"\d\.\d+TD", t)
    if m:
        return m.group(0)
    if re.search(r"<=\s*15", t):
        return "2.0TD"
    return "2.0TD" if len([p for p in (c.get("potenciaContratadakW") or "").split(";") if p]) <= 2 else "3.0TD"


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
# Los mismos que PERIODOS_JS en los widgets de iot-thingsboard.sh.
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


def _fecha(dt):
    return dt.astimezone(TZL).strftime("%d/%m/%Y") if dt else None


def _dia_local(dt, mas=0):
    """Medianoche local del dia de dt (+ mas dias), como datetime con zona."""
    d = dt.astimezone(TZL).date() + timedelta(days=mas)
    return datetime(d.year, d.month, d.day, tzinfo=TZL)


# ======================= PostgreSQL =======================
def guardar_lecturas(cx, cups, filas, origen):
    """Inserta o actualiza lecturas; devuelve los ts (UTC) que han cambiado. Un valor que
    falta en la carga nueva no borra el que habia."""
    cx.execute("CREATE TEMP TABLE IF NOT EXISTS _l (LIKE lectura INCLUDING DEFAULTS) ON COMMIT DELETE ROWS")
    with cx.cursor() as cur:
        with cur.copy("COPY _l (cups, ts, paso_min, consumo_kwh, vertida_kwh, generada_kwh, "
                      "autoconsumo_kwh, metodo, origen) FROM STDIN") as cp:
            for ts, paso, v, metodo in filas:
                cp.write_row((cups, datetime.fromtimestamp(ts / 1000, timezone.utc), paso,
                              *(v.get(k) for k in CLAVES), metodo, origen))
        cur.execute("""
            INSERT INTO lectura AS l (cups, ts, paso_min, consumo_kwh, vertida_kwh, generada_kwh,
                                      autoconsumo_kwh, metodo, origen)
            SELECT DISTINCT ON (ts) cups, ts, paso_min, consumo_kwh, vertida_kwh, generada_kwh,
                   autoconsumo_kwh, metodo, origen FROM _l ORDER BY ts
            ON CONFLICT (cups, ts) DO UPDATE SET
              paso_min = EXCLUDED.paso_min,
              consumo_kwh = COALESCE(EXCLUDED.consumo_kwh, l.consumo_kwh),
              vertida_kwh = COALESCE(EXCLUDED.vertida_kwh, l.vertida_kwh),
              generada_kwh = COALESCE(EXCLUDED.generada_kwh, l.generada_kwh),
              autoconsumo_kwh = COALESCE(EXCLUDED.autoconsumo_kwh, l.autoconsumo_kwh),
              metodo = COALESCE(EXCLUDED.metodo, l.metodo),
              origen = EXCLUDED.origen, cargado = now()
            WHERE (COALESCE(EXCLUDED.consumo_kwh, l.consumo_kwh), COALESCE(EXCLUDED.vertida_kwh, l.vertida_kwh),
                   COALESCE(EXCLUDED.generada_kwh, l.generada_kwh),
                   COALESCE(EXCLUDED.autoconsumo_kwh, l.autoconsumo_kwh), COALESCE(EXCLUDED.metodo, l.metodo))
                  IS DISTINCT FROM (l.consumo_kwh, l.vertida_kwh, l.generada_kwh, l.autoconsumo_kwh, l.metodo)
            RETURNING ts""")
        return [r["ts"] for r in cur.fetchall()]


def guardar_maximos(cx, cups, maximos):
    with cx.cursor() as cur:
        cur.executemany("INSERT INTO maximetro (cups, mes, periodo, kw, cuando) VALUES (%s, %s, %s, %s, %s) "
                        "ON CONFLICT (cups, mes, periodo) DO UPDATE SET kw = EXCLUDED.kw, cuando = EXCLUDED.cuando",
                        [(cups, *m) for m in maximos])


def suministro_de(cx, socio_id):
    """Suministro actual de un socio (el ultimo cargado)."""
    return cx.execute("SELECT * FROM suministro WHERE socio = %s ORDER BY actualizado DESC LIMIT 1",
                      (socio_id,)).fetchone()


def lecturas(cx, cups, d0=None, d1=None):
    """[(ts_ms, {clave: kWh})] de uno o varios CUPS (sumados por periodo si son varios)."""
    rango = " AND ts >= %s AND ts < %s" if d0 else ""
    sel = ", ".join(f"sum({k}) AS {k}" for k in CLAVES)
    filas = cx.execute(f"SELECT (extract(epoch FROM ts) * 1000)::bigint AS t, {sel} FROM lectura "
                       f"WHERE cups = ANY(%s){rango} GROUP BY ts ORDER BY ts",
                       (list(cups), d0, d1) if d0 else (list(cups),)).fetchall()
    return [(r["t"], {k: r[k] for k in CLAVES if r[k] is not None}) for r in filas]


def lecturas_hora(cx, cups, d0=None, d1=None):
    """Suma horaria de varios CUPS (la de la comunidad): agrupa los cuartos de hora."""
    rango = " AND ts >= %s AND ts < %s" if d0 else ""
    sel = ", ".join(f"sum({k}) AS {k}" for k in CLAVES)
    filas = cx.execute(f"SELECT (extract(epoch FROM date_trunc('hour', ts)) * 1000)::bigint AS t, {sel} "
                       f"FROM lectura WHERE cups = ANY(%s){rango} GROUP BY 1 ORDER BY 1",
                       (list(cups), d0, d1) if d0 else (list(cups),)).fetchall()
    return [(r["t"], {k: r[k] for k in CLAVES if r[k] is not None}) for r in filas]


def extension(cx, cups):
    return cx.execute("SELECT min(ts) AS desde, max(ts) AS hasta, count(*) AS n FROM lectura WHERE cups = ANY(%s)",
                      (list(cups),)).fetchone()


# ======================= ingesta =======================
def ingesta_csv(cx, so, forzar, nota):
    """Ficheros de la descarga web de Datadis (DATADIS_DIR/<carpeta>) -> PostgreSQL.
    Solo se leen si han cambiado desde la ultima carga (o con forzar)."""
    dd = leer_csv(so["carpeta"]) if so.get("carpeta") else None
    if not dd or not dd["filas"] or not dd["cups"]:
        nota(f"AVISO {so['nombre']}: sin curva de Datadis en {DATADIS_DIR / (so.get('carpeta') or '?')}")
        return None
    cups, c = dd["cups"], dd["contrato"]
    prev = cx.execute("SELECT firma_csv FROM suministro WHERE cups = %s", (cups,)).fetchone()
    if prev and prev["firma_csv"] == dd["firma"] and not forzar:
        return {"cups": cups, "rango": None}
    with cx.transaction():
        cx.execute("""INSERT INTO suministro (cups, socio, peaje, paso_min, contrato, firma_csv, firma, actualizado)
                      VALUES (%s, %s, %s, %s, %s, %s, %s, now())
                      ON CONFLICT (cups) DO UPDATE SET socio = EXCLUDED.socio, peaje = EXCLUDED.peaje,
                        paso_min = EXCLUDED.paso_min, contrato = EXCLUDED.contrato,
                        firma_csv = EXCLUDED.firma_csv, firma = EXCLUDED.firma, actualizado = now()""",
                   (cups, so["id"], peaje(c), dd["paso"], db.Jsonb({k: v for k, v in c.items() if k and v}),
                    dd["firma"], dd["firma"]))
        cambiadas = guardar_lecturas(cx, cups, dd["filas"], "csv")
        guardar_maximos(cx, cups, dd["maximos"])
    nota(f"{so['nombre']}: {len(dd['filas'])} lecturas en los CSV ({'cuartohorarias' if dd['paso'] == 15 else 'horarias'}), "
         f"{len(cambiadas)} nuevas o cambiadas en PostgreSQL")
    return {"cups": cups, "rango": (min(cambiadas), max(cambiadas)) if cambiadas else None}


def ingesta_datadis(cx, api, mapa, so, desde, hasta, forzar, nota):
    """API de Datadis (meses desde..hasta, AAAA/MM) -> PostgreSQL. El CUPS de cada socio es
    el de su suministro en PostgreSQL (lo da la primera carga de sus CSV)."""
    s = suministro_de(cx, so["id"])
    if not s:
        nota(f"AVISO {so['nombre']}: sin CUPS conocido (carga antes sus CSV de Datadis)")
        return None
    cups = s["cups"]
    if cups not in mapa:
        nota(f"AVISO {so['nombre']}: el CUPS {cups} no está entre los suministros accesibles en Datadis")
        return None
    sup, nif = mapa[cups]
    tipos = [QUARTER, HOURLY] if str(sup.get("pointType")) in ("1", "2") else [HOURLY]
    curva = []
    for mt in tipos:
        clave = hashlib.sha1(f"{cups}|{nif}|{desde}|{hasta}|{mt}".encode()).hexdigest()[:16]
        if not forzar and db.consultada(cx, clave):
            nota(f"{so['nombre']}: {desde}-{hasta} ya consultado en las últimas 24 h (usa forzar)")
            return {"cups": cups, "rango": None}
        db.marcar_consulta(cx, clave)          # Datadis cuenta tambien las rechazadas
        curva = api.consumption(sup, desde, hasta, mt, nif)
        if curva:
            break
    curva = sorted(curva, key=lambda r: (r.get("date", ""), _minutos(r.get("time"))))
    filas, paso = a_filas(curva, "date", "time", COLS_API, "obtainMethod")
    if not filas:
        nota(f"{so['nombre']}: Datadis no tiene lecturas de {desde} a {hasta}")
        return {"cups": cups, "rango": None}
    with cx.transaction():
        cambiadas = guardar_lecturas(cx, cups, filas, "datadis")
        if cambiadas:
            firma = hashlib.sha1(f"{s['firma']}|{min(cambiadas)}|{max(cambiadas)}|{len(cambiadas)}".encode())
            cx.execute("UPDATE suministro SET firma = %s, paso_min = COALESCE(paso_min, %s), actualizado = now() "
                       "WHERE cups = %s", (firma.hexdigest()[:16], paso, cups))
    ultimo = datetime.fromtimestamp(filas[-1][0] / 1000, TZL).strftime("%d/%m/%Y %H:%M")
    nota(f"{so['nombre']}: {len(filas)} lecturas de Datadis ({desde}-{hasta}, última {ultimo}), "
         f"{len(cambiadas)} nuevas o cambiadas")
    return {"cups": cups, "rango": (min(cambiadas), max(cambiadas)) if cambiadas else None}


def _minutos(h):
    try:
        hh, mm = map(int, str(h).split(":"))
        return hh * 60 + mm
    except ValueError:
        return 0


# ======================= ThingsBoard =======================
def _dispositivo(nombre):
    d = tb().dispositivo(nombre)
    if not d:
        raise RuntimeError(f"no existe el dispositivo '{nombre}' en ThingsBoard (ejecuta iot-thingsboard.sh)")
    return d["id"]["id"]


def _serie(filas):
    return [{"ts": ts, "values": {k: round(e, 3) + 0.0 for k, e in v.items()}} for ts, v in filas]


def publicar_socio(cx, so, rango, forzar, version):
    """PostgreSQL -> ThingsBoard de un socio, solo si ThingsBoard no tiene ya esa version de
    los datos (atributo datadis_firma). Con un rango conocido solo se envian los dias que
    lo tocan; si no (primera carga, otra version, forzar), se sustituye todo."""
    s = suministro_de(cx, so["id"])
    if not s:
        return None
    did, pj = _dispositivo(so["id"]), s["peaje"] or "2.0TD"
    firma = f"{s['firma']}-{pj}-v{version}"
    ya = tb().leer_atributos(did, ["datadis_firma"]).get("datadis_firma")
    if ya == firma and not forzar:
        return None
    completo = forzar or rango is None or not ya or not str(ya).endswith(f"-{pj}-v{version}")
    if completo:
        tb().borrar_series(did)
        d0 = d1 = None
    else:
        d0, d1 = _dia_local(rango[0]), _dia_local(rango[1], 1)
    filas = lecturas(cx, [s["cups"]], d0, d1)
    maximos = cx.execute("SELECT mes, periodo, kw, cuando FROM maximetro WHERE cups = %s ORDER BY mes",
                         (s["cups"],)).fetchall()
    M = {}
    for m in maximos:
        x = M.setdefault(int(datetime(m["mes"].year, m["mes"].month, 1, tzinfo=TZL).timestamp()) * 1000, {})
        x[f"pmax_p{m['periodo']}_kw"] = m["kw"]
        x[f"pmax_p{m['periodo']}_cuando"] = m["cuando"]
    tb().telemetria(did, _serie(filas) + por_dia(filas, pj) + [{"ts": t, "values": v} for t, v in sorted(M.items())])
    c, ext = s["contrato"] or {}, extension(cx, [s["cups"]])
    auto = (c.get("tipoAutoconsumo") or "").strip()
    tb().atributos(did, {
        "cups": s["cups"], "peaje": pj,
        "potencia": " / ".join(p for p in (c.get("potenciaContratadakW") or "").split(";") if p),
        "autoconsumo": f"sí (tipo {auto})" if auto else "no",
        "resolucion": "cuartohoraria" if s["paso_min"] == 15 else "horaria",
        "datos_desde": _fecha(ext["desde"]), "datos_hasta": _fecha(ext["hasta"]),
        # pestaña Contrato del widget de consumo y lineas de potencia contratada
        "contrato": c, "pcontratada_kw": potencia_por_periodo(c, sorted({m["periodo"] for m in maximos})),
        "datadis_firma": firma})
    return {"completo": completo, "n": len(filas), "d0": d0, "d1": d1}


def deshabilitados(cx):
    """Ids de los socios deshabilitados (no cuentan en la comunidad)."""
    return {r["socio"] for r in cx.execute("SELECT socio FROM socio_estado WHERE deshabilitado").fetchall()}


def fijar_deshabilitado(socio_id, valor, por):
    """Guarda el estado en PostgreSQL y el atributo "deshabilitado" del socio en ThingsBoard
    (lo usan la tabla de socios y el color del mapa)."""
    with db.conectar() as cx:
        cx.execute("INSERT INTO socio_estado (socio, deshabilitado, actualizado, por) VALUES (%s, %s, now(), %s) "
                   "ON CONFLICT (socio) DO UPDATE SET deshabilitado = EXCLUDED.deshabilitado, "
                   "actualizado = now(), por = EXCLUDED.por", (socio_id, valor, por))
    tb().atributos(_dispositivo(socio_id), {"deshabilitado": bool(valor)})


def comunidad_pendiente(socios):
    """Socios habilitados con datos frente a los que suma ahora la comunidad en ThingsBoard
    (atributo cec_socios): pendiente = hay que pulsar Recalcular."""
    with db.conectar() as cx:
        fuera = deshabilitados(cx)
        ids = [s["socio"] for so in socios if so["id"] not in fuera and (s := suministro_de(cx, so["id"]))
               and cx.execute("SELECT 1 FROM lectura WHERE cups = %s LIMIT 1", (s["cups"],)).fetchone()]
    d = tb().dispositivo("comunidad")
    actual = tb().leer_atributos(d["id"]["id"], ["cec_socios"]).get("cec_socios") if d else None
    return {"pendiente": (actual or "") != ",".join(ids), "incluidos": ids,
            "deshabilitados": [so["id"] for so in socios if so["id"] in fuera]}


def _sincronizar_estados(cx, socios):
    """PostgreSQL manda; ThingsBoard lleva una copia en el atributo "deshabilitado". Un socio
    sin estado en PostgreSQL lo toma de ThingsBoard (versiones anteriores del panel)."""
    pg = {r["socio"]: r["deshabilitado"] for r in cx.execute("SELECT socio, deshabilitado FROM socio_estado").fetchall()}
    for so in socios:
        d = tb().dispositivo(so["id"])
        if not d:
            continue
        v = tb().leer_atributos(d["id"]["id"], ["deshabilitado"]).get("deshabilitado")
        v = v is True or str(v).lower() == "true" if v is not None else None
        if so["id"] not in pg:
            if v:
                cx.execute("INSERT INTO socio_estado (socio, deshabilitado, por) VALUES (%s, true, 'panel') "
                           "ON CONFLICT DO NOTHING", (so["id"],))
        elif v != pg[so["id"]]:
            tb().atributos(d["id"]["id"], {"deshabilitado": pg[so["id"]]})


def publicar_comunidad(cx, socios, rangos, forzar, version):
    """Suma horaria de todos los socios habilitados con datos. rangos: rangos de dias
    cambiados en esta sincronizacion (None en la lista = algun socio se sustituyo entero).
    Habilitar o deshabilitar un socio cambia el conjunto (cec_socios): se recalcula entera."""
    _sincronizar_estados(cx, socios)
    fuera = deshabilitados(cx)
    sums = [s for so in socios if so["id"] not in fuera and (s := suministro_de(cx, so["id"]))
            and cx.execute("SELECT 1 FROM lectura WHERE cups = %s LIMIT 1", (s["cups"],)).fetchone()]
    did = _dispositivo("comunidad")
    excluidos = [so["nombre"] for so in socios if so["id"] in fuera]
    if not sums:   # todos deshabilitados (o sin datos): la comunidad se queda sin telemetria
        if tb().leer_atributos(did, ["cec_socios"]).get("cec_socios"):
            tb().borrar_series(did)
            tb().atributos(did, {"cec_socios": "", "datadis_firma": "", "socios_deshabilitados": ", ".join(excluidos)})
        return {"completo": True, "horas": 0, "socios": 0, "excluidos": excluidos}
    # La comunidad mezcla peajes: reparte su consumo en punta, llano y valle (2.0TD)
    firma = hashlib.sha1("".join(s["firma"] for s in sums).encode()).hexdigest()[:16] + f"-2.0TD-v{version}"
    ids = ",".join(s["socio"] for s in sums)
    ya = tb().leer_atributos(did, ["datadis_firma", "cec_socios"])
    if ya.get("datadis_firma") == firma and not forzar:
        return None
    completo = (forzar or not rangos or None in rangos or ya.get("cec_socios") != ids
                or not str(ya.get("datadis_firma") or "").endswith(f"-2.0TD-v{version}"))
    cups = [s["cups"] for s in sums]
    if completo:
        tb().borrar_series(did)
        d0 = d1 = None
    else:
        d0, d1 = min(r[0] for r in rangos), max(r[1] for r in rangos)
    com = lecturas_hora(cx, cups, d0, d1)
    tb().telemetria(did, _serie(com) + por_dia(com, "2.0TD"))
    ext = extension(cx, cups)
    tb().atributos(did, {"resolucion": "horaria", "periodos": "2.0TD", "datos_desde": _fecha(ext["desde"]),
                         "datos_hasta": _fecha(ext["hasta"]), "cec_socios": ids, "datadis_firma": firma,
                         "socios_deshabilitados": ", ".join(excluidos)})
    return {"completo": completo, "horas": len(com), "socios": len(sums), "excluidos": excluidos}


# ======================= sincronizacion =======================
def meses_por_defecto():
    """Datadis publica con dias de retraso: mes anterior y actual."""
    hoy = date.today()
    ant = (hoy.replace(day=1) - timedelta(days=1))
    return f"{ant.year}/{ant.month:02d}", f"{hoy.year}/{hoy.month:02d}"


def ejecutar(jid):
    """Ejecuta un trabajo de sincronizacion (en un hilo). pg_try_advisory_lock evita que
    corran dos a la vez (la diaria programada y el boton del panel, por ejemplo)."""
    with db.conectar() as lk:
        if not lk.execute("SELECT pg_try_advisory_lock(%s) AS ok", (LOCK,)).fetchone()["ok"]:
            db.nota(jid, "ERROR: ya hay otra sincronización en curso")
            db.terminar(jid, "error")
            return
        try:
            _ejecutar(db.job(jid))
        except Exception as e:                # el trabajo queda en error con el motivo
            log.exception("sincronizacion %s", jid)
            db.nota(jid, f"ERROR: {e}")
            db.terminar(jid, "error")
        finally:
            lk.execute("SELECT pg_advisory_unlock(%s)", (LOCK,))


def _ejecutar(j):
    jid, cfg = j["id"], config()
    version = int(cfg.get("datos_version", 1))
    origen = j["origen"]
    # "comunidad": solo recalcula sus totales (al habilitar o deshabilitar un socio)
    socios = [] if origen == "comunidad" else [so for so in cfg["socios"] if not j["socios"] or so["id"] in j["socios"]]
    if origen == "auto":
        origen = "datadis" if datadis_configurado() else "csv"
    if origen == "datadis" and not datadis_configurado():
        raise RuntimeError("faltan DATADIS_USER / DATADIS_PASS en el .env del stack")
    desde, hasta = j["desde"], j["hasta"]
    if origen == "datadis" and not (desde and hasta):
        desde, hasta = meses_por_defecto()
    db.empezar(jid, origen, len(socios))
    nota = lambda m: db.nota(jid, m)
    if origen == "comunidad":
        nota("Recalculo de los totales de la comunidad (socios habilitados)")
    else:
        nota(f"Origen {'API de Datadis (' + desde + '-' + hasta + ')' if origen == 'datadis' else 'ficheros CSV'}"
             f", {len(socios)} socios{', forzada' if j['forzar'] else ''}")

    api = mapa = None
    if origen == "datadis":
        api = Datadis()
        api.login()
        nifs = [n.strip().upper() for n in (E.get("DATADIS_NIF_AUTORIZADOS") or "").split(",") if n.strip()]
        mapa = api.mapa_cups(nifs)
        nota(f"Datadis: {len(mapa)} suministros accesibles")

    hechos = errores = 0
    rangos = []
    with db.conectar() as cx:
        for so in socios:
            try:
                if origen == "csv":
                    r = ingesta_csv(cx, so, j["forzar"], nota)
                else:
                    r = ingesta_datadis(cx, api, mapa, so, desde, hasta, j["forzar"], nota)
                p = publicar_socio(cx, so, r and r["rango"], j["forzar"], version)
                if p:
                    rangos.append(None if p["completo"] else (p["d0"], p["d1"]))
                    nota(f"{so['nombre']}: ThingsBoard {'recargado entero' if p['completo'] else 'actualizado'} "
                         f"({p['n']} lecturas)")
            except Exception as e:
                errores += 1
                log.exception("socio %s", so["id"])
                nota(f"ERROR {so['nombre']}: {e}")
            hechos += 1
            db.avance(jid, hechos, errores)
        for a in (api.avisos if api else []):
            nota(f"AVISO Datadis: {a}")
        try:
            c = publicar_comunidad(cx, cfg["socios"], rangos, j["forzar"], version)
            nota(f"Comunidad: suma horaria de {c['socios']} socios {'recargada' if c['completo'] else 'actualizada'} "
                 f"({c['horas']} horas)" + (f"; sin los deshabilitados: {', '.join(c['excluidos'])}" if c["excluidos"] else "")
                 if c else "Comunidad: sin cambios")
        except Exception as e:
            errores += 1
            log.exception("comunidad")
            nota(f"ERROR comunidad: {e}")
    db.avance(jid, hechos, errores)
    nota("Terminada" + (f" con {errores} errores" if errores else ""))
    db.terminar(jid, "con_errores" if errores else "ok")
__FASTAPI_EOF__

cat > config/fastapi/app/graficos.py <<'__FASTAPI_EOF__'
"""Graficos SVG de los informes: los mismos del widget de consumo del panel (VatiaCo.consumo,
iot-thingsboard.sh) con sus colores. Typst los incrusta como imagenes vectoriales.

  barras()   grafico principal: consumo apilado por periodos del peaje (valle abajo, punta
             arriba), autoconsumo encima y excedentes por debajo de cero; o el maximetro
             frente a la potencia contratada (linea escalonada)
  dona()     reparto del consumo por periodos y autoconsumo
  vecinos()  periodos anteriores en gris y el del informe en color
"""
import math
from html import escape

FUENTE = "Roboto, DejaVu Sans, sans-serif"
GRIS_TEXTO, GRIS_LINEA, GRIS_EJE, GRIS_VECINO = "#555", "#eee", "#ccc", "#e4e4e6"

# Colores y nombres de los periodos (COL3/NOM3/COL6/GEN del widget)
COL3 = {1: "#fda38a", 2: "#fddcb0", 3: "#a8ebbd"}
NOM3 = {1: "Punta", 2: "Llano", 3: "Valle"}
COL6 = {1: "#fda38a", 2: "#fdbf9a", 3: "#fddcb0", 4: "#eef0b4", 5: "#cdeec2", 6: "#a8ebbd"}
AUTO = ("auto", "Autoconsumo", "#8fc3f0")
VERT = ("vert", "Excedentes", "#4caf7d")
POT_BAJO, POT_ALTO, POT_LINEA = "#fcc265", "#f59a6b", "#f5b942"


def es(v, n=2):
    """Numero con formato español (1.234,56)."""
    if v is None:
        return "–"
    return f"{v:,.{n}f}".replace(",", "X").replace(".", ",").replace("X", ".")


def categorias(pj, hay_gen):
    """Series apiladas del grafico, de abajo arriba: (clave, nombre, color, signo)."""
    n = 3 if pj == "2.0TD" else 6
    out = [(f"p{p}", NOM3[p] if n == 3 else f"P{p}", (COL3 if n == 3 else COL6)[p], 1) for p in range(n, 0, -1)]
    if hay_gen:
        out += [AUTO + (1,), VERT + (-1,)]
    return out


def _svg(ancho, alto, cuerpo):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{ancho}" height="{alto}" '
            f'viewBox="0 0 {ancho} {alto}" font-family="{FUENTE}">' + "".join(cuerpo) + "</svg>")


def _texto(x, y, t, size=10, color=GRIS_TEXTO, anchor="start", peso="normal"):
    return (f'<text x="{x:.1f}" y="{y:.1f}" font-size="{size}" fill="{color}" text-anchor="{anchor}" '
            f'font-weight="{peso}">{escape(str(t))}</text>')


def _escala(vmin, vmax, n=5):
    """Limites y marcas "redondas" del eje Y."""
    if vmax - vmin < 1e-9:
        vmax = vmin + 1
    bruto = (vmax - vmin) / n
    mag = 10 ** math.floor(math.log10(bruto))
    paso = next(m * mag for m in (1, 2, 2.5, 5, 10) if m * mag >= bruto - 1e-12)
    lo, hi = math.floor(vmin / paso + 1e-9) * paso, math.ceil(vmax / paso - 1e-9) * paso
    return lo, hi, [lo + i * paso for i in range(round((hi - lo) / paso) + 1)], paso


def _leyenda(items, ancho, y):
    """Leyenda centrada con circulos, como la de ECharts del panel."""
    anchos = [24 + len(n) * 5.6 for n, _ in items]
    x = (ancho - sum(anchos)) / 2
    out = []
    for (n, c), w in zip(items, anchos):
        out.append(f'<circle cx="{x + 5:.1f}" cy="{y - 3.5:.1f}" r="4.5" fill="{c}"/>')
        out.append(_texto(x + 14, y, n, 10))
        x += w
    return out


def barras(etiquetas, series, ancho=760, alto=270, unidad="kWh", linea=None):
    """series: [{"n", "c", "v": [valor o None], "cs": [color por barra, opcional]}] apiladas;
    linea: {"n", "c", "v": [...]} escalonada (potencia contratada)."""
    n = max(len(etiquetas), 1)
    val = lambda s, i: s["v"][i] or 0
    tops = [sum(max(val(s, i), 0) for s in series) for i in range(len(etiquetas))]
    bots = [sum(min(val(s, i), 0) for s in series) for i in range(len(etiquetas))]
    extra = [v for v in (linea or {}).get("v", []) if v is not None]
    lo, hi, marcas, paso = _escala(min(bots + [0]), max(tops + extra + [0]) * 1.05 or 1)
    dec = 0 if paso >= 1 else 1 if paso >= 0.1 else 2
    ml, mr, mt, mb = 70, 12, 12, 52
    pw, ph = ancho - ml - mr, alto - mt - mb
    y = lambda v: mt + ph * (hi - v) / (hi - lo)
    out = []
    for t in marcas:
        out.append(f'<line x1="{ml}" x2="{ancho - mr}" y1="{y(t):.1f}" y2="{y(t):.1f}" stroke="{GRIS_LINEA}"/>')
        out.append(_texto(ml - 6, y(t) + 3.5, f"{es(t, dec)} {unidad}", 9.5, anchor="end"))
    banda = pw / n
    bw = min(banda * 0.62, 48)
    for i in range(len(etiquetas)):
        x0, arriba, abajo = ml + banda * i + (banda - bw) / 2, 0.0, 0.0
        for s in series:
            v = s["v"][i]
            if not v:
                continue
            c = (s.get("cs") or [None] * n)[i] or s["c"]
            if v > 0:
                y0, y1, arriba = y(arriba + v), y(arriba), arriba + v
            else:
                y0, y1, abajo = y(abajo), y(abajo + v), abajo + v
            out.append(f'<rect x="{x0:.1f}" y="{y0:.1f}" width="{bw:.1f}" height="{max(y1 - y0, 0.3):.1f}" fill="{c}"/>')
    out.append(f'<line x1="{ml}" x2="{ancho - mr}" y1="{y(0):.1f}" y2="{y(0):.1f}" stroke="{GRIS_EJE}"/>')
    if linea:   # escalonada: un tramo horizontal por barra con dato (step: 'middle' del panel)
        d, previo = [], None
        for i, v in enumerate(linea["v"]):
            if v is None:
                previo = None
                continue
            xa, xb = ml + banda * i, ml + banda * (i + 1)
            d.append(f"{'L' if previo is not None else 'M'}{xa:.1f},{y(v):.1f} L{xb:.1f},{y(v):.1f}")
            previo = v
        if d:
            out.append(f'<path d="{" ".join(d)}" fill="none" stroke="{linea["c"]}" stroke-width="2"/>')
    # Etiquetas del eje X: se saltan las que no caben
    salto = max(1, math.ceil(n / max(1, pw / (6.2 * max(len(str(e)) for e in etiquetas) + 8)))) if etiquetas else 1
    for i, e in enumerate(etiquetas):
        if i % salto == 0:
            out.append(_texto(ml + banda * (i + 0.5), mt + ph + 15, e, 9.5, anchor="middle"))
    ley = [(s["n"], s["c"]) for s in series if any(s["v"])]
    if linea and extra:
        ley.append((linea["n"], linea["c"]))
    return _svg(ancho, alto, out + _leyenda(ley, ancho, alto - 10))


def dona(items, ancho=300, alto=130):
    """Anillo del reparto: items [(nombre, valor, color)] y leyenda vertical a la derecha."""
    total = sum(max(v or 0, 0) for _, v, _ in items)
    cx, cy, R = ancho * 0.25, alto / 2, alto * 0.42
    r = R * 0.74
    rm, grosor = (R + r) / 2, R - r
    circ = 2 * math.pi * rm
    out = [f'<circle cx="{cx:.1f}" cy="{cy:.1f}" r="{rm:.1f}" fill="none" stroke="{GRIS_VECINO}" stroke-width="{grosor:.1f}"/>']
    hecho = 0.0
    for _, v, c in items:   # cada tramo, un trazo del circulo (empieza arriba, sentido horario)
        if not total or not v or v <= 0:
            continue
        lon = circ * v / total
        out.append(f'<circle cx="{cx:.1f}" cy="{cy:.1f}" r="{rm:.1f}" fill="none" stroke="{c}" '
                   f'stroke-width="{grosor:.1f}" stroke-dasharray="{lon:.2f} {circ:.2f}" '
                   f'stroke-dashoffset="{-hecho:.2f}" transform="rotate(-90 {cx:.1f} {cy:.1f})"/>')
        hecho += lon
    vis = [(n, v, c) for n, v, c in items if v and v > 0] or items
    paso = min(18, (alto - 10) / max(len(vis), 1))
    y0 = cy - paso * (len(vis) - 1) / 2
    for i, (nombre, v, c) in enumerate(vis):
        yy = y0 + paso * i
        out.append(f'<circle cx="{ancho * 0.52:.1f}" cy="{yy - 3.5:.1f}" r="4.5" fill="{c}"/>')
        pct = f"{es(100 * v / total, 1)} %" if total and v else "–"
        out.append(_texto(ancho * 0.52 + 10, yy, nombre.upper(), 10))
        out.append(_texto(ancho - 2, yy, pct, 10, anchor="end", peso="bold"))
    return _svg(ancho, alto, out)


def vecinos(items, sel, apilado, ancho=380, alto=130):
    """Periodos vecinos: items [(etiqueta, total o None)]; el de indice sel se pinta apilado
    con los colores de apilado [(color, valor)] y el resto en gris."""
    vals = [v or 0 for _, v in items] + [sum(max(v, 0) for _, v in apilado)]
    vmax = max(vals) or 1
    mt, mb = 16, 20
    ph, banda = alto - mt - mb, ancho / max(len(items), 1)
    bw = banda * 0.62
    y = lambda v: mt + ph * (1 - v / vmax)
    out = []
    for i, (lab, v) in enumerate(items):
        x0 = banda * i + (banda - bw) / 2
        if i == sel:
            acc = 0.0
            for c, x in apilado:
                if x and x > 0:
                    out.append(f'<rect x="{x0:.1f}" y="{y(acc + x):.1f}" width="{bw:.1f}" height="{y(acc) - y(acc + x):.1f}" fill="{c}"/>')
                    acc += x
            v = acc
        elif v:
            out.append(f'<rect x="{x0:.1f}" y="{y(v):.1f}" width="{bw:.1f}" height="{y(0) - y(v):.1f}" fill="{GRIS_VECINO}"/>')
        if v:
            out.append(_texto(x0 + bw / 2, y(v) - 3, es(v, 0), 8.5, anchor="middle",
                              peso="bold" if i == sel else "normal"))
        out.append(_texto(x0 + bw / 2, alto - 6, lab, 9.5, anchor="middle", peso="bold" if i == sel else "normal"))
    out.append(f'<line x1="0" x2="{ancho}" y1="{y(0):.1f}" y2="{y(0):.1f}" stroke="{GRIS_EJE}"/>')
    return _svg(ancho, alto, out)
__FASTAPI_EOF__

cat > config/fastapi/app/informes.py <<'__FASTAPI_EOF__'
"""Informes de energia de la comunidad o de un socio, desde PostgreSQL: PDF (Typst), Excel y CSV.

El PDF lleva los mismos graficos que el widget de consumo del panel (graficos.py): cifras
del periodo, reparto por periodos del peaje (anillo), periodos anteriores, consumo apilado
por periodos con autoconsumo y excedentes, potencias maximas frente a la contratada y los
datos del contrato. Una seccion para la comunidad y otra por socio."""
import csv
import io
import json
import re
import tempfile
import unicodedata
from datetime import date, datetime, timedelta
from pathlib import Path

from . import cec, db, graficos as G
from .comun import TZL, config

ENERGIA = [("consumo_kwh", "Consumo de red"), ("vertida_kwh", "Vertido a red"),
           ("generada_kwh", "Generación FV"), ("autoconsumo_kwh", "Autoconsumo")]

PLANTILLA = r"""
// Informe tecnico: A4 vertical. Estructura de ISO 7144 (portada, preliminares, cuerpo),
// apartados numerados segun ISO 2145 (1, 1.1), titulos de tabla encima y de figura debajo.
#let d = json("datos.json")
#let ac = rgb("#7b2fa8")
#let gris = rgb("#666")
#set document(title: d.titulo, author: d.autor)
#set text(font: ("Roboto", "DejaVu Sans"), lang: "es", region: "es", size: 9.5pt, fill: rgb("#222"))
#set par(justify: true, leading: 0.62em, spacing: 0.9em)
#set page(paper: "a4", margin: (top: 2.4cm, bottom: 2.2cm, left: 2.5cm, right: 2cm))

#set heading(numbering: "1.1")
#show heading: set block(sticky: true)   // un titulo nunca queda solo al pie de pagina
#show heading.where(level: 1): it => {
  pagebreak(weak: true)
  block(above: 0pt, below: 1.1em, text(15pt, weight: "bold", fill: ac,
    if it.numbering != none [#counter(heading).display(it.numbering) #h(0.5em) #it.body] else [#it.body]))
}
#show heading.where(level: 2): it => block(above: 1.4em, below: 0.7em, text(11pt, weight: "bold",
  [#counter(heading).display(it.numbering) #h(0.4em) #it.body]))

#set figure(gap: 0.6em)
#set figure.caption(separator: [ — ])
#show figure.caption: set text(8.5pt)
#show figure.caption: it => [#strong[#it.supplement #context it.counter.display(it.numbering)]#it.separator#it.body]
#show figure.where(kind: table): set figure.caption(position: top)

#let tabla(t, size: 7.5pt) = {
  set text(size)
  set par(justify: false)
  table(
    columns: t.cabecera.len(),
    align: (x, y) => if x < t.texto { left } else { right },
    stroke: (x, y) => if y == 0 { (top: 0.8pt, bottom: 0.6pt) } else { (bottom: 0.3pt + luma(215)) },
    fill: (x, y) => if t.total and y == t.filas.len() { luma(236) },
    inset: (x: 3.5pt, y: 2.6pt),
    table.header(..t.cabecera.map(c => strong(c))),
    ..t.filas.flatten().map(c => if type(c) == dictionary [#c.t \ #text(6.5pt, fill: gris)[#c.sub]] else [#c]),
  )
}
// Solo las tablas largas se parten entre paginas (repiten su cabecera); el resto va entera
#let ftabla(t, cap, size: 7.5pt) = {
  show figure: set block(breakable: t.filas.len() > 30)
  figure(tabla(t, size: size), caption: cap)
}
#let contrato(cols) = {
  set par(justify: false)
  grid(columns: (1fr, 1fr), column-gutter: 24pt, align: left,
    ..cols.map(col => col.map(sec => [
      #text(9.5pt, weight: "bold")[#sec.at(0)]
      #for kv in sec.at(1) [
        #block(above: 5pt, below: 3pt)[#text(7pt, fill: gris)[#kv.at(0)] \ #kv.at(1)]
        #line(length: 100%, stroke: 0.3pt + luma(220))
      ]
    ]).join()))
}

// ---------------- Portada ----------------
#page(margin: (x: 2.5cm, y: 2.5cm), header: none, footer: none)[
  #block(fill: ac, width: 100%, inset: (x: 12pt, y: 10pt))[
    #text(fill: white, 10pt, weight: "bold", tracking: 1.5pt)[INFORME TÉCNICO] #h(1fr)
    #text(fill: white, 9pt)[#d.codigo]]
  #v(3.2cm)
  #text(26pt, weight: "bold", fill: ac)[#d.titulo]
  #v(6pt)
  #text(15pt, fill: gris)[#d.subtitulo]
  #v(10pt)
  #line(length: 35%, stroke: 2pt + ac)
  #v(10pt)
  #text(12pt)[Periodo analizado: *#d.periodo*]
  #v(1fr)
  #set text(9pt)
  #table(columns: (5cm, 1fr), stroke: (x, y) => (bottom: 0.3pt + luma(200)), inset: (x: 0pt, y: 5pt),
    ..d.ficha.map(f => (text(fill: gris)[#f.at(0)], [#f.at(1)])).flatten())
  #v(14pt)
  #text(7.5pt, fill: gris)[#d.nota]
]

// ---------------- Preliminares (numeracion romana) ----------------
#set page(
  numbering: "i",
  header: context [#set text(7.5pt, fill: gris); #d.titulo #h(1fr) #d.codigo #v(-4pt) #line(length: 100%, stroke: 0.4pt + luma(200))],
  footer: context [#set text(7.5pt, fill: gris); #d.periodo #h(1fr) #counter(page).display()],
)
#counter(page).update(1)

#heading(numbering: none)[Resumen]
#for p in d.resumen [#p #parbreak()]
#v(8pt)
#block(fill: rgb("#f6f6f7"), inset: 10pt, radius: 3pt, width: 100%)[
  #text(weight: "bold")[Cifras principales] #v(2pt)
  #tabla(d.cifras_resumen, size: 8.5pt)]

#heading(numbering: none, outlined: false)[Índice]
#outline(title: none, depth: 2, indent: auto)

#heading(numbering: none)[Índice de figuras]
#outline(title: none, target: figure.where(kind: image))

#heading(numbering: none)[Índice de tablas]
#outline(title: none, target: figure.where(kind: table))

#heading(numbering: none)[Glosario y abreviaturas]
#{
  set par(justify: false)
  table(columns: (3.6cm, 1fr), stroke: (x, y) => (bottom: 0.3pt + luma(215)), inset: (x: 3pt, y: 4pt),
    ..d.glosario.map(g => (strong(g.at(0)), [#g.at(1)])).flatten())
}

// ---------------- Cuerpo (numeracion arabiga) ----------------
#set page(numbering: "1", footer: context [#set text(7.5pt, fill: gris); #d.periodo #h(1fr)
  Página #counter(page).display() de #counter(page).final().first()])
#counter(page).update(1)

= Objeto, alcance y método
#for a in d.metodo [
  == #a.titulo
  #for p in a.parrafos [#p #parbreak()]
]

#for s in d.secciones [
  #heading(level: 1)[#s.nombre]
  #text(fill: gris)[#s.sub]

  #if s.contrato != none [
    == Datos del contrato
    #block(breakable: false, figure(kind: table, contrato(s.contrato), caption: [Datos del contrato de suministro — #s.nombre]))
  ]

  == Cifras del periodo
  #ftabla(s.cifras, [Cifras del periodo — #s.nombre], size: 8.5pt)

  == Reparto del consumo y comparación con periodos anteriores
  #grid(columns: (1fr, 1fr), column-gutter: 14pt, align: bottom,
    figure(image(s.dona, width: 100%), caption: [Reparto del consumo por periodos — #s.nombre]),
    figure(image(s.vecinos, width: 100%), caption: [Consumo total frente a los tres periodos anteriores — #s.nombre]))

  == #s.titulo_barras
  #figure(image(s.barras, width: 100%), caption: [#s.titulo_barras — #s.nombre])
  #text(8pt, fill: gris)[#s.nota_barras]

  #if s.pot.len() > 0 [
    == Potencias máximas frente a la contratada
    #block(breakable: false)[
    #text(8pt, fill: gris)[Maxímetro de los doce meses que terminan en el del informe; en naranja oscuro, los meses por encima de la potencia contratada (línea).]
    #grid(columns: (1fr, 1fr), column-gutter: 14pt, row-gutter: 12pt,
      ..s.pot.map(p => figure(
        [#image(p.svg, width: 100%) #v(-2pt) #text(7.5pt, fill: gris)[#p.sub]],
        caption: [Potencia máxima demandada en #p.titulo — #s.nombre])))]
  ]
  #if s.resumen != none [
    == Energía por socio
    #ftabla(s.resumen, [Energía del periodo por socio])
    #ftabla(s.resumen_p, [Consumo de red por periodos del peaje de cada socio])
  ]
  == #s.titulo_tabla
  #ftabla(s.tabla, [#s.titulo_tabla — #s.nombre])
]
"""


_es = G.es
MESES = ["Ene", "Feb", "Mar", "Abr", "May", "Jun", "Jul", "Ago", "Sep", "Oct", "Nov", "Dic"]
MESES_L = ["enero", "febrero", "marzo", "abril", "mayo", "junio", "julio", "agosto", "septiembre",
           "octubre", "noviembre", "diciembre"]


def datos(socio_id, desde, hasta):
    """Totales por socio y por dia del periodo [desde, hasta] (fechas locales)."""
    cfg = config()
    socios = [so for so in cfg["socios"] if socio_id is None or so["id"] == socio_id]
    if socio_id and not socios:
        raise KeyError(socio_id)
    with db.conectar() as cx:
        fuera = cec.deshabilitados(cx)
    # Informe de la comunidad: solo los socios habilitados (los totales cuadran con el panel)
    excluidos = [so["nombre"] for so in socios if socio_id is None and so["id"] in fuera]
    if socio_id is None:
        socios = [so for so in socios if so["id"] not in fuera]
    d0 = datetime(desde.year, desde.month, desde.day, tzinfo=TZL)
    d1 = datetime(hasta.year, hasta.month, hasta.day, tzinfo=TZL) + timedelta(days=1)
    resumen, diario, periodos = [], [], set()
    with db.conectar() as cx:
        for so in socios:
            s = cec.suministro_de(cx, so["id"])
            if not s:
                continue
            pj = s["peaje"] or "2.0TD"
            dias = cec.por_dia(cec.lecturas(cx, [s["cups"]], d0, d1), pj)
            tot = {}
            for x in dias:
                for k, v in x["values"].items():
                    tot[k] = tot.get(k, 0) + v
                diario.append({"fecha": datetime.fromtimestamp(x["ts"] / 1000, TZL).date(),
                               "socio": so["nombre"], "cups": s["cups"], **x["values"]})
            periodos |= {int(k[3:-4]) for k in tot if k.startswith("d_p") and k.endswith("_kwh")}
            c = s["contrato"] or {}
            resumen.append({"socio": so["nombre"], "cups": s["cups"], "peaje": pj,
                            "coef": c.get("coeficienteReparto") or "", "dias": len(dias), **tot})
    return {"titulo": cfg["cec"] if socio_id is None else socios[0]["nombre"],
            "subtitulo": "Informe de energía de la comunidad" if socio_id is None else f"Informe de energía · {cfg['cec']}",
            "comunidad": socio_id is None, "socio_id": socio_id, "excluidos": excluidos, "resumen": resumen, "diario": diario,
            "periodos": sorted(periodos), "desde": desde, "hasta": hasta}


def _neto(x):
    return x.get("d_red_neto_kwh", 0.0)


def _tablas(D):
    """Cabeceras y filas (valores numericos) de las tablas Resumen y Diario."""
    P = D["periodos"]
    cab_r = (["Socio", "CUPS", "Peaje", "Coef. reparto", "Días"] + [n for _, n in ENERGIA]
             + [f"P{p}" for p in P] + ["Saldo red"])
    filas_r = [[r["socio"], r["cups"], r["peaje"], r["coef"], r["dias"]] + [r.get("d_" + k, 0.0) for k, _ in ENERGIA]
               + [r.get(f"d_p{p}_kwh", 0.0) for p in P] + [_neto(r)] for r in D["resumen"]]
    if D["comunidad"] and filas_r:
        filas_r.append(["Total comunidad", "", "", "", ""] + [sum(f[i] for f in filas_r) for i in range(5, len(cab_r))])
    # Diario: por socio (CSV/Excel) y, en el PDF de la comunidad, la suma de todos
    cab_d = ["Fecha", "Socio", "CUPS"] + [n for _, n in ENERGIA] + [f"P{p}" for p in P] + ["Saldo red"]
    filas_d = [[x["fecha"], x["socio"], x["cups"]] + [x.get("d_" + k, 0.0) for k, _ in ENERGIA]
               + [x.get(f"d_p{p}_kwh", 0.0) for p in P] + [_neto(x)]
               for x in sorted(D["diario"], key=lambda x: (x["fecha"], x["socio"]))]
    return cab_r, filas_r, cab_d, filas_d


def _periodo(D):
    return f"{D['desde']:%d/%m/%Y} – {D['hasta']:%d/%m/%Y}"


def _nombre(D, ext):
    """Nombre de fichero ASCII (va en la cabecera Content-Disposition)."""
    t = unicodedata.normalize("NFD", D["titulo"]).encode("ascii", "ignore").decode()
    base = re.sub(r"[^A-Za-z0-9]+", "_", t).strip("_")
    return f"informe_{base}_{D['desde']:%Y%m%d}-{D['hasta']:%Y%m%d}.{ext}"


def a_csv(D):
    _, _, cab_d, filas_d = _tablas(D)
    out = io.StringIO()
    w = csv.writer(out, delimiter=";")
    w.writerow(cab_d)
    for f in filas_d:
        w.writerow([f"{v:%Y/%m/%d}" if isinstance(v, date) else _es(v, 3).replace(".", "") if isinstance(v, float) else v
                    for v in f])
    return ("﻿" + out.getvalue()).encode("utf-8")   # BOM: Excel lo abre en UTF-8


def a_xlsx(D):
    from openpyxl import Workbook
    from openpyxl.styles import Font

    cab_r, filas_r, cab_d, filas_d = _tablas(D)
    wb = Workbook()
    for i, (titulo, cab, filas) in enumerate((("Resumen", cab_r, filas_r), ("Diario", cab_d, filas_d))):
        ws = wb.active if i == 0 else wb.create_sheet()
        ws.title = titulo
        ws.append([f"{D['titulo']} · {_periodo(D)} (kWh)"])
        ws.append(cab)
        ws["A1"].font = Font(bold=True, size=12)
        for c in ws[2]:
            c.font = Font(bold=True)
        for f in filas:
            ws.append(f)
        for col in ws.iter_cols(min_row=3):
            for c in col:
                if isinstance(c.value, float):
                    c.number_format = "#,##0.000"
                elif isinstance(c.value, date):
                    c.number_format = "dd/mm/yyyy"
        for j, c in enumerate(cab, 1):
            ws.column_dimensions[ws.cell(row=2, column=j).column_letter].width = max(11, len(c) + 2)
        ws.column_dimensions["A"].width = 24 if titulo == "Resumen" else 12
        ws.column_dimensions["B"].width = 26
        ws.freeze_panes = "A3"
    out = io.BytesIO()
    wb.save(out)
    return out.getvalue()


# ======================= PDF con graficos =======================
def _local(d, mas=0):
    d = d + timedelta(days=mas)
    return datetime(d.year, d.month, d.day, tzinfo=TZL)


def _mas_meses(d, n):
    m = d.year * 12 + d.month - 1 + n
    return date(m // 12, m % 12 + 1, 1)


def _granularidad(desde, hasta):
    """Como las pestañas del panel: un dia -> horas; hasta dos meses -> dias; mas -> meses."""
    dias = (hasta - desde).days + 1
    return "hora" if dias == 1 else "dia" if dias <= 62 else "mes"


def _cubos(g, desde, hasta):
    """Casillas del grafico: [(clave, etiqueta del eje, etiqueta de la tabla)]."""
    if g == "hora":   # hora de fin, como Datadis (01:00..24:00)
        return [(h, f"{h + 1:02d}:00", f"{h + 1:02d}:00") for h in range(24)]
    if g == "dia":
        n = (hasta - desde).days + 1
        return [(d, f"{d:%d/%m}", f"{d:%d/%m/%Y}") for d in (desde + timedelta(days=i) for i in range(n))]
    out, m = [], date(desde.year, desde.month, 1)
    while m <= hasta:
        out.append(((m.year, m.month), f"{MESES[m.month - 1]} {m.year % 100:02d}", f"{MESES_L[m.month - 1]} {m.year}"))
        m = _mas_meses(m, 1)
    return out


def _clave(lt, g):
    return lt.hour if g == "hora" else lt.date() if g == "dia" else (lt.year, lt.month)


def _agregar(filas, pj, g, cubos):
    """Energia de cada casilla y consumo de red por periodo del peaje (p1...)."""
    idx = {c[0]: i for i, c in enumerate(cubos)}
    V = [{} for _ in cubos]
    for ts, v in filas:
        lt = datetime.fromtimestamp(ts / 1000, TZL)
        i = idx.get(_clave(lt, g))
        if i is None:
            continue
        x = V[i]
        x["_hay"] = True
        for k, e in v.items():
            x[k] = x.get(k, 0) + e
        if "consumo_kwh" in v:
            kp = f"p{cec.periodo(lt, pj)}"
            x[kp] = x.get(kp, 0) + v["consumo_kwh"]
    return V


def _valor(x, k):
    """Valor de una serie del grafico: autoconsumo positivo, excedentes en negativo."""
    if k == "auto":
        return x.get("autoconsumo_kwh")
    if k == "vert":
        return -x["vertida_kwh"] if x.get("vertida_kwh") is not None else None
    return x.get(k)


def _ventanas(desde, hasta):
    """El periodo del informe y los 3 anteriores de la misma duracion (meses enteros si el
    informe lo es), como las barras de periodos vecinos del panel."""
    enteros = desde.day == 1 and (hasta + timedelta(days=1)).day == 1
    n = (hasta.year - desde.year) * 12 + hasta.month - desde.month + 1
    L = (hasta - desde).days + 1
    out = []
    for k in range(-3, 1):
        if enteros:
            a, b = _mas_meses(desde, k * n), _mas_meses(desde, (k + 1) * n) - timedelta(days=1)
            lab = (f"{MESES[a.month - 1]} {a.year % 100:02d}" if n == 1 else
                   str(a.year) if n == 12 and a.month == 1 else f"{a:%m/%y}–{b:%m/%y}")
        else:
            a = desde + timedelta(days=k * L)
            b = a + timedelta(days=L - 1)
            lab = f"{a:%d/%m}" if L == 1 else f"{a:%d/%m}–{b:%d/%m}"
        out.append((a, b, lab))
    return out


def _contrato(c):
    """Campos del contrato agrupados como en la pestaña Contrato del panel."""
    v = lambda k: c.get(k) or "–"
    cols = [[["Datos contractuales", [["Fechas de inicio y fin de contrato",
                                       f"{c.get('fechaInicioVigencia') or ''} - {c.get('fechaFinVigencia') or ''}"],
                                      ["Distribuidora", v("distribuidora")], ["Comercializadora", v("comercializadora")],
                                      ["CUPS", v("cups")]]],
             ["Localización", [["Provincia", v("provincia")], ["Municipio", v("municipio")],
                               ["Código postal", v("codigoPostal")]]]],
            [["Suministro", [["Tarifa de acceso", v("tarifaAcceso")], ["Tensión de conexión", v("tensionConexion")],
                             ["Potencia contratada por periodos (kW)",
                              " - ".join((c.get("potenciaContratadakW") or "–").split(";"))],
                             ["Modo de control de potencia", v("modoControlPotencia")],
                             ["Discriminación horaria", v("discriminacionHoraria")],
                             ["Potencia máxima de la instalación (kW)", v("potenciaMaximaInstalacion")]]]]]
    if c.get("tipoAutoconsumo"):
        cols[1].append(["Autoconsumo", [["Tipo de autoconsumo", v("tipoAutoconsumo")],
                                        ["Potencia de generación (kW)", v("potenciaTotalGenerada")],
                                        ["CAU", v("cau")],
                                        ["Sección / subsección", f"{c.get('seccion') or ''} / {c.get('subseccion') or ''}"],
                                        ["Coeficiente de reparto", v("coeficienteReparto")]]])
    return cols


def _potencias(cx, cups, contrato, hasta, raiz, pref):
    """Maximetro de los 12 meses que acaban en el del informe, un grafico por periodo."""
    m1 = date(hasta.year, hasta.month, 1)
    m0 = _mas_meses(m1, -11)
    filas = cx.execute("SELECT mes, periodo, kw, cuando FROM maximetro WHERE cups = %s AND mes >= %s AND mes <= %s",
                       (cups, m0, m1)).fetchall()
    periodos = sorted({f["periodo"] for f in filas})
    pcon = cec.potencia_por_periodo(contrato or {}, periodos)
    meses = [_mas_meses(m0, i) for i in range(12)]
    out = []
    for p in periodos:
        M = {f["mes"]: f for f in filas if f["periodo"] == p}
        V = [M[m]["kw"] if m in M else None for m in meses]
        c = pcon.get(str(p))
        im = max((i for i, x in enumerate(V) if x is not None), key=lambda i: V[i], default=None)
        nombre = f"{pref}_pot{p}.svg"
        Path(raiz, nombre).write_text(G.barras(
            [f"{MESES[m.month - 1]} {m.year % 100:02d}" for m in meses],
            [{"n": "Máxima demanda", "c": G.POT_BAJO, "v": V,
              "cs": [G.POT_ALTO if x is not None and c is not None and x > c else None for x in V]}],
            ancho=340, alto=200, unidad="kW",
            linea={"n": "Contratada", "c": G.POT_LINEA, "v": [c if x is not None else None for x in V]}),
            encoding="utf-8")
        exceso = c is not None and any(x is not None and x > c for x in V)
        sub = ("Sin datos" if im is None else f"Máxima {_es(V[im])} kW ({M[meses[im]]['cuando'] or ''})") + \
              (f" · contratada {_es(c)} kW" if c is not None else "") + (" · superada" if exceso else "")
        out.append({"titulo": f"P{p}", "sub": sub, "svg": nombre, "exceso": exceso})
    return out


def _cifras(t, n, g, hay_gen, previo):
    """Tabla de cifras del periodo (concepto, valor) y los numeros para el resumen."""
    total = t["total"]
    media = total / n if n else None
    var = (100 * (total - previo) / previo) if previo else None
    filas = [["Consumo total (red + autoconsumo)", _es(total) + " kWh" if n else "–"],
             ["Consumo de red", _es(t["red"]) + " kWh" if n else "–"]]
    if hay_gen:
        filas += [["Generación fotovoltaica", _es(t["gen"]) + " kWh"], ["Autoconsumo", _es(t["auto"]) + " kWh"],
                  ["Excedentes vertidos a la red", _es(t["vert"]) + " kWh"],
                  ["Consumo cubierto con autoconsumo", _es(100 * t["auto"] / total, 1) + " %" if total else "–"]]
    filas += [["Saldo con la red (+ recibe, − aporta)", _es(t["red"] - t["vert"]) + " kWh" if n else "–"],
              [{"hora": "Consumo medio horario", "dia": "Consumo medio diario", "mes": "Consumo medio mensual"}[g],
               _es(media) + " kWh" if media is not None else "–"],
              ["Variación respecto al periodo anterior", (("+" if var > 0 else "") + _es(var, 1) + " %")
               if var is not None else "sin datos del periodo anterior"]]
    return ({"cabecera": ["Concepto", "Valor"], "texto": 1, "total": False, "filas": filas},
            dict(t, media=media, var=var, n=n))


def _seccion(cx, raiz, pref, nombre, sub, cups, pj, desde, hasta, horaria=False):
    """Un capitulo (comunidad o socio), siempre con la misma estructura: cifras, anillo,
    periodos anteriores, consumo apilado y tabla de energia (potencias y contrato los
    añade a_pdf a los socios)."""
    g = _granularidad(desde, hasta)
    cubos = _cubos(g, desde, hasta)
    lect = cec.lecturas_hora if horaria else cec.lecturas
    filas = lect(cx, cups, _local(desde), _local(hasta, 1))
    hay_gen = any("generada_kwh" in v or "autoconsumo_kwh" in v for _, v in filas)
    C = G.categorias(pj, hay_gen)
    V = _agregar(filas, pj, g, cubos)
    tot = {k: sum(_valor(x, k) or 0 for x in V) for k, *_ in C}
    pos = [c for c in C if c[3] > 0]
    n = sum(1 for x in V if x.get("_hay"))
    suma = lambda k: sum(x.get(k, 0) for x in V)
    t = {"total": sum(tot[c[0]] for c in pos), "red": suma("consumo_kwh"), "gen": suma("generada_kwh"),
         "auto": suma("autoconsumo_kwh"), "vert": suma("vertida_kwh")}

    # Anillo: de donde sale el consumo (periodos de red y autoconsumo)
    Path(raiz, f"{pref}_dona.svg").write_text(G.dona([(c[1], tot[c[0]], c[2]) for c in pos], ancho=300, alto=140),
                                              encoding="utf-8")
    # Periodos anteriores en gris y el del informe en color
    ven = _ventanas(desde, hasta)
    prev = lect(cx, cups, _local(ven[0][0]), _local(desde))
    vtot = []
    for a, b, lab in ven[:-1]:
        t0, t1 = _local(a).timestamp() * 1000, _local(b, 1).timestamp() * 1000
        x = [e.get("consumo_kwh", 0) + e.get("autoconsumo_kwh", 0) for ts, e in prev if t0 <= ts < t1]
        vtot.append((lab, sum(x) if x else None))
    vtot.append((ven[-1][2], t["total"]))
    Path(raiz, f"{pref}_vecinos.svg").write_text(
        G.vecinos(vtot, 3, [(c[2], tot[c[0]]) for c in pos], ancho=300, alto=140), encoding="utf-8")
    # Grafico principal: apilado, positivos hacia arriba y excedentes hacia abajo
    Path(raiz, f"{pref}_barras.svg").write_text(G.barras(
        [c[1] for c in cubos], [{"n": c[1], "c": c[2], "v": [_valor(x, c[0]) for x in V]} for c in C],
        ancho=620, alto=300), encoding="utf-8")
    titulo = "Consumo " + {"hora": "horario", "dia": "diario", "mes": "mensual"}[g] + " por periodos"
    nota = ("Consumo de red apilado por periodos del peaje (" + ("punta, llano y valle" if pj == "2.0TD" else "P1 a P6")
            + ")" + ("; el autoconsumo se suma encima y los excedentes se representan en negativo." if hay_gen else "."))

    # Tabla de energia con las mismas filas que el grafico
    P = sorted(int(k[1:]) for k in (c[0] for c in C) if k.startswith("p"))
    nomp = (lambda p: G.NOM3[p]) if pj == "2.0TD" else (lambda p: f"P{p}")
    cols = [("consumo_kwh", "Consumo de red"), ("vertida_kwh", "Vertido"), ("generada_kwh", "Generación FV"),
            ("autoconsumo_kwh", "Autoconsumo")][:4 if hay_gen else 1]
    cab = [{"hora": "Hora", "dia": "Fecha", "mes": "Mes"}[g]] + [n_ for _, n_ in cols] + [nomp(p) for p in P] + ["Saldo red"]
    filas_t, sumas = [], [0.0] * (len(cab) - 1)
    for (_, _, et), x in zip(cubos, V):
        if not x.get("_hay"):
            continue
        nums = [x.get(k, 0) for k, _ in cols] + [x.get(f"p{p}", 0) for p in P] + \
               [x.get("consumo_kwh", 0) - x.get("vertida_kwh", 0)]
        sumas = [a + b for a, b in zip(sumas, nums)]
        filas_t.append([et] + [_es(v) for v in nums])
    if filas_t:
        filas_t.append(["Total"] + [_es(v) for v in sumas])
    cifras, num = _cifras(t, n, g, hay_gen, vtot[-2][1])
    return {"nombre": nombre, "corto": nombre.split(": ", 1)[-1], "sub": sub, "cifras": cifras, "num": dict(num, gen_hay=hay_gen),
            "dona": f"{pref}_dona.svg", "vecinos": f"{pref}_vecinos.svg", "barras": f"{pref}_barras.svg",
            "titulo_barras": titulo, "nota_barras": nota, "pot": [], "contrato": None, "resumen": None,
            "titulo_tabla": "Energía " + {"hora": "horaria", "dia": "diaria", "mes": "mensual"}[g] + " (kWh)",
            "tabla": {"cabecera": cab, "texto": 1, "total": bool(filas_t), "filas": filas_t}}


def _resumen_pdf(D):
    """Energia por socio en dos tablas que caben en A4 vertical: energia y saldo, y consumo
    de red por periodos. El CUPS va bajo el nombre."""
    cab_r, filas_r, _, _ = _tablas(D)
    P = D["periodos"]
    txt = lambda v: v if isinstance(v, str) else _es(v, 0) if isinstance(v, int) else _es(v)
    con_coef = any(f[3] for f in filas_r)
    socio = lambda f: {"t": f[0], "sub": f[1]} if f[1] else f[0]
    ie = [2] + ([3] if con_coef else []) + [4, 5, 6, 7, 8, len(cab_r) - 1]
    ip = list(range(9, 9 + len(P)))
    t1 = {"cabecera": ["Socio"] + [cab_r[i] for i in ie], "texto": 2 + con_coef, "total": bool(filas_r),
          "filas": [[socio(f)] + [txt(f[i]) for i in ie] for f in filas_r]}
    t2 = {"cabecera": ["Socio"] + [cab_r[i] for i in ip], "texto": 1, "total": bool(filas_r),
          "filas": [[socio(f)] + [txt(f[i]) for i in ip] for f in filas_r]}
    return t1, t2


GLOSARIO = [
    ("Autoconsumo", "Energía generada por la instalación fotovoltaica y consumida en el propio suministro, sin pasar por la red."),
    ("CAU", "Código de Autoconsumo: identifica la instalación de autoconsumo."),
    ("Coeficiente de reparto", "Fracción de la generación de una instalación de autoconsumo colectivo que corresponde a cada participante."),
    ("Comunidad energética", "Entidad que agrupa a los socios para producir, compartir y gestionar energía; aquí, la suma de sus suministros."),
    ("Consumo de red", "Energía activa tomada de la red de distribución y registrada por el contador."),
    ("Consumo total", "Consumo de red más autoconsumo: toda la energía que utiliza el suministro."),
    ("CUPS", "Código Universal del Punto de Suministro: identifica cada suministro eléctrico."),
    ("Curva de carga", "Serie de lecturas horarias o cuartohorarias de energía de un contador."),
    ("Datadis", "Plataforma de las distribuidoras españolas que publica las lecturas de los contadores (con uno o varios días de retraso)."),
    ("Excedentes (vertido)", "Energía generada que no se consume y se entrega a la red."),
    ("Generación FV", "Energía producida por la instalación fotovoltaica."),
    ("kW / kWh", "Kilovatio (potencia) y kilovatio hora (energía)."),
    ("Maxímetro", "Potencia máxima demandada en un mes y periodo, medida como máximo cuartohorario."),
    ("Peaje de acceso", "Tarifa de acceso a la red (2.0TD, 3.0TD, 6.1TD...): fija los periodos horarios y de potencia."),
    ("Periodos P1–P6", "Periodos horarios del peaje: P1 es el de mayor precio (punta) y el último, valle. En 2.0TD: punta (P1), llano (P2) y valle (P3)."),
    ("Potencia contratada", "Potencia máxima que el suministro puede demandar en cada periodo según su contrato."),
    ("Saldo con la red", "Consumo de red menos excedentes vertidos: positivo si el suministro recibe energía neta, negativo si aporta."),
]


def _metodo(cfg, D, socios, g):
    nombres = ", ".join(so["nombre"] for so, _ in socios)
    res = {"hora": "horaria", "dia": "diaria", "mes": "mensual"}[g]
    return [
        {"titulo": "Objeto", "parrafos": [
            f"Este informe presenta la energía eléctrica consumida, generada, autoconsumida y vertida a la red "
            f"{'por los socios de ' + cfg['cec'] if D['comunidad'] else 'por el suministro de ' + D['titulo'] + ', socio de ' + cfg['cec']}"
            f" durante el periodo {_periodo(D)}, como apoyo a la gestión de la comunidad y al reparto de la energía."]},
        {"titulo": "Alcance", "parrafos": [
            (f"Comprende {len(socios)} suministros: {nombres}. " if D["comunidad"] else "")
            + (f"No se incluyen los socios deshabilitados por la administración: {', '.join(D['excluidos'])}. "
               if D["comunidad"] and D["excluidos"] else "")
            + f"Los resultados se presentan con resolución {res}; la tabla de cada capítulo tiene las mismas filas que su gráfico "
            "de consumo. Las potencias máximas cubren los doce meses que terminan en el del informe."]},
        {"titulo": "Fuente de los datos y tratamiento", "parrafos": [
            "Las lecturas proceden de Datadis (curvas de carga y maxímetro publicados por las distribuidoras) y de los datos de "
            "contrato de cada suministro. Se almacenan en la base de datos de la comunidad, que es la fuente de este informe; "
            "cada lectura se asigna al instante de inicio de su periodo de medida, en hora local peninsular (Europe/Madrid).",
            "La comunidad es la suma horaria de todos los socios y, al mezclar peajes, su consumo se reparte con los periodos "
            "del peaje 2.0TD. Los datos de los últimos días pueden estar incompletos por el retraso con que publican las "
            "distribuidoras."]},
        {"titulo": "Periodos horarios", "parrafos": [
            "2.0TD: punta (P1) de 10 a 14 h y de 18 a 22 h; llano (P2) de 8 a 10 h, de 14 a 18 h y de 22 a 24 h; valle (P3) "
            "de 0 a 8 h y todo el día en fines de semana y festivos nacionales de fecha fija.",
            "3.0TD y 6.1TD: seis periodos. Fines de semana, festivos y de 0 a 8 h, P6; el resto del día se reparte entre dos "
            "periodos según la temporada eléctrica del mes (alta, media-alta, media y baja)."]},
        {"titulo": "Convenciones", "parrafos": [
            "Energía en kWh y potencia en kW, con coma decimal. Consumo total = consumo de red + autoconsumo. Saldo con la "
            "red = consumo de red − excedentes (+ recibe, − aporta). En los gráficos de consumo, los periodos se apilan de "
            "valle (abajo) a punta (arriba), el autoconsumo encima y los excedentes por debajo de cero; son los mismos "
            "gráficos que el panel de la comunidad."]},
    ]


def _resumen(cfg, D, secciones):
    """Resumen del informe (texto) a partir de las cifras de cada capitulo."""
    s0 = secciones[0]
    x = s0["num"]
    que = f"de los {len(secciones) - 1} socios de {cfg['cec']}" if D["comunidad"] else f"del suministro de {D['titulo']}"
    out = [f"Este informe técnico recoge la energía eléctrica {que} entre el {D['desde']:%d/%m/%Y} y el "
           f"{D['hasta']:%d/%m/%Y}, a partir de las curvas de carga publicadas por las distribuidoras en Datadis."]
    if not x["n"]:
        return out + ["No hay lecturas en el periodo analizado."]
    p = (f"El consumo total fue de {_es(x['total'])} kWh ({_es(x['media'])} kWh de "
         f"{ {'hora': 'media horaria', 'dia': 'media diaria', 'mes': 'media mensual'}[_granularidad(D['desde'], D['hasta'])] }), "
         f"de los que {_es(x['red'])} kWh se tomaron de la red")
    if x["gen_hay"]:
        p += (f" y {_es(x['auto'])} kWh ({_es(100 * x['auto'] / x['total'], 1) if x['total'] else '0'} %) se cubrieron con "
              f"autoconsumo. La generación fotovoltaica sumó {_es(x['gen'])} kWh y los excedentes vertidos, {_es(x['vert'])} kWh")
    p += f". El saldo con la red fue de {_es(x['red'] - x['vert'])} kWh."
    if x["var"] is not None:
        p += f" Respecto al periodo anterior de la misma duración, el consumo {'aumentó' if x['var'] > 0 else 'disminuyó'} un {_es(abs(x['var']), 1)} %."
    out.append(p)
    socios = secciones[1:] if D["comunidad"] else []
    if socios:
        mx = max(socios, key=lambda s: s["num"]["total"])
        frase = f"El socio con mayor consumo fue {mx['corto']} ({_es(mx['num']['total'])} kWh, " \
                f"{_es(100 * mx['num']['total'] / x['total'], 1) if x['total'] else '0'} % del total)"
        gen = [s for s in socios if s["num"]["gen"] > 0]
        if gen:
            mg = max(gen, key=lambda s: s["num"]["gen"])
            frase += f"; el de mayor generación fotovoltaica, {mg['corto']} ({_es(mg['num']['gen'])} kWh)"
        out.append(frase + ".")
    ex = [(s["corto"], [p["titulo"] for p in s["pot"] if p["exceso"]]) for s in (socios or secciones)]
    ex = [(n, ps) for n, ps in ex if ps]
    if any(s["pot"] for s in (socios or secciones)):
        out.append("En los doce meses que terminan en el del informe, " + (
            "ninguna potencia máxima demandada superó la contratada." if not ex else
            "la potencia máxima demandada superó la contratada en: "
            + "; ".join(f"{n} ({', '.join(ps)})" for n, ps in ex) + ". Conviene revisar esas potencias contratadas."))
    return out


def _codigo(D):
    t = unicodedata.normalize("NFD", "CEC" if D["comunidad"] else D["titulo"]).encode("ascii", "ignore").decode()
    base = re.sub(r"[^A-Za-z0-9]+", "-", t).strip("-").upper()[:24]
    return f"INF-{base}-{D['desde']:%Y%m%d}-{D['hasta']:%Y%m%d}"


def a_pdf(D):
    import typst

    cfg = config()
    socios = ([so for so in cfg["socios"] if so["id"] == D["socio_id"]] if D["socio_id"]
              else [so for so in cfg["socios"] if so["nombre"] not in D["excluidos"]])
    g = _granularidad(D["desde"], D["hasta"])
    # Directorio temporal como raiz: la plantilla no puede leer nada mas del servidor
    with tempfile.TemporaryDirectory() as raiz, db.conectar() as cx:
        sums = [(so, s) for so in socios if (s := cec.suministro_de(cx, so["id"]))]
        secciones = []
        if D["comunidad"] and sums:
            # Comunidad: suma horaria de todos los socios, repartida como 2.0TD (igual que en el panel)
            sec = _seccion(cx, raiz, "com", "Comunidad: " + cfg["cec"], f"{len(sums)} socios · periodos del peaje 2.0TD",
                           [s["cups"] for _, s in sums], "2.0TD", D["desde"], D["hasta"], horaria=True)
            sec["resumen"], sec["resumen_p"] = _resumen_pdf(D)
            sec["titulo_tabla"] += " de la comunidad"
            secciones.append(sec)
        for i, (so, s) in enumerate(sums):
            c = s["contrato"] or {}
            pot = " / ".join(p for p in (c.get("potenciaContratadakW") or "").split(";") if p)
            sub = " · ".join(x for x in (f"CUPS {s['cups']}", f"Peaje {s['peaje'] or '2.0TD'}",
                                         f"Potencia contratada {pot} kW" if pot else "") if x)
            sec = _seccion(cx, raiz, f"s{i}", ("Socio: " if D["comunidad"] else "") + so["nombre"], sub, [s["cups"]],
                           s["peaje"] or "2.0TD", D["desde"], D["hasta"])
            sec["pot"] = _potencias(cx, s["cups"], c, D["hasta"], raiz, f"s{i}")
            sec["contrato"] = _contrato(c) if c else None
            secciones.append(sec)
        if not secciones:
            raise KeyError("sin datos")
        ambito = (f"Comunidad completa ({len(sums)} socios)" if D["comunidad"]
                  else f"{D['titulo']} (CUPS {sums[0][1]['cups']})")
        ahora = datetime.now(TZL)
        doc = {"titulo": D["titulo"], "subtitulo": "Informe de energía de la comunidad" if D["comunidad"]
               else f"Informe de energía del socio · {cfg['cec']}",
               "periodo": _periodo(D), "codigo": _codigo(D), "autor": f"Administración de {cfg['cec']}",
               "ficha": [["Código del informe", _codigo(D)], ["Versión", "1.0"],
                         ["Fecha de emisión", f"{ahora:%d/%m/%Y}"], ["Periodo analizado", _periodo(D)],
                         ["Ámbito", ambito], ["Resolución de los datos", {"hora": "horaria", "dia": "diaria", "mes": "mensual"}[g]],
                         ["Fuente de los datos", "Datadis (distribuidoras) · base de datos de la comunidad"],
                         ["Elaborado por", f"Administración de {cfg['cec']}"]],
               "nota": f"Documento generado automáticamente el {ahora:%d/%m/%Y} a las {ahora:%H:%M} a partir de los datos "
                       "disponibles en ese momento. Los últimos días pueden cambiar cuando las distribuidoras completen sus lecturas.",
               "resumen": _resumen(cfg, D, secciones), "cifras_resumen": secciones[0]["cifras"],
               "glosario": GLOSARIO, "metodo": _metodo(cfg, D, sums, g), "secciones": secciones}
        Path(raiz, "informe.typ").write_text(PLANTILLA, encoding="utf-8")
        Path(raiz, "datos.json").write_text(json.dumps(doc, ensure_ascii=False, default=str), encoding="utf-8")
        return typst.compile(str(Path(raiz, "informe.typ")), root=raiz, font_paths=["/usr/share/fonts"])


FORMATOS = {"csv": (a_csv, "text/csv; charset=utf-8"),
            "xlsx": (a_xlsx, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"),
            "pdf": (a_pdf, "application/pdf")}


def generar(socio_id, desde, hasta, formato):
    """-> (bytes, tipo MIME, nombre de fichero)."""
    D = datos(socio_id, desde, hasta)
    f, mime = FORMATOS[formato]
    return f(D), mime, _nombre(D, formato)
__FASTAPI_EOF__

cat > config/fastapi/app/puente.py <<'__FASTAPI_EOF__'
"""Simuladores (sustituyen a los flujos de Node-RED): uno por cliente de CLIENTES.
Publican en el MQTT de ThingsBoard (thingsboard:1883, red interna) por la Gateway API
(v1/gateway/telemetry con el token del dispositivo gateway), como sensores reales.
Los dispositivos de verdad publican directamente en ThingsBoard con su token
(mqtts://<servidor>:8883, v1/devices/me/telemetry)."""
import json
import math
import random
import threading
import time
from datetime import datetime

import paho.mqtt.client as mqtt

from .comun import E, TZL, config, log
from .tb import TB


def _paso(v, d, lo, hi):
    return min(hi, max(lo, v + (random.random() - 0.5) * d))


def sim_ambiente(s):
    """Paseo aleatorio suave para que las graficas tengan sentido."""
    s.setdefault("temperatura", 21.0), s.setdefault("humedad", 50.0), s.setdefault("potencia", 1500.0)
    s["temperatura"] = _paso(s["temperatura"], 0.6, 15, 30)
    s["humedad"] = _paso(s["humedad"], 2, 30, 80)
    s["potencia"] = _paso(s["potencia"], 200, 200, 4000)
    return {"temperatura": round(s["temperatura"], 2), "humedad": round(s["humedad"], 1),
            "potencia": round(s["potencia"])}


def sim_energia(s):
    """Curva solar segun la hora (7h-20h) con nubes, consumo con paseo aleatorio y saldo
    con la red (positivo = compra)."""
    s.setdefault("consumo", 12.0), s.setdefault("nubes", 0.2)
    now = datetime.now(TZL)
    h = now.hour + now.minute / 60
    s["nubes"] = _paso(s["nubes"], 0.1, 0, 0.8)
    s["consumo"] = _paso(s["consumo"], 1.5, 4, 30)
    gen = 40 * max(0.0, math.sin(math.pi * (h - 7) / 13)) * (1 - s["nubes"])
    return {"generacion_kw": round(gen, 2), "consumo_kw": round(s["consumo"], 2),
            "red_kw": round(s["consumo"] - gen, 2)}


SIM = {"ambiente": sim_ambiente, "energia": sim_energia}


class Puente:
    def __init__(self):
        self.alto = threading.Event()
        self.gw = None
        self.enviados = 0
        self.gateway = None

    def arrancar(self):
        threading.Thread(target=self._run, name="simuladores", daemon=True).start()

    def parar(self):
        self.alto.set()
        if self.gw:
            self.gw.loop_stop()
            self.gw.disconnect()

    def estado(self):
        return {"gateway": self.gateway, "thingsboard": bool(self.gw and self.gw.is_connected()),
                "mensajes_enviados": self.enviados}

    def _token_gateway(self):
        """Espera a que exista el dispositivo gateway (lo crea iot-thingsboard.sh)."""
        while not self.alto.is_set():
            try:
                self.gateway = config()["gateway"]
                t = TB()
                d = t.dispositivo(self.gateway)
                if d:
                    return t.credenciales(d["id"]["id"])
                log.info("simuladores: aún no existe el gateway '%s' en ThingsBoard", self.gateway)
            except Exception as e:
                log.info("simuladores: ThingsBoard no disponible todavía (%s)", e)
            self.alto.wait(15)
        return None

    def _run(self):
        cfg = config()
        sims = [c for c in cfg.get("clientes", []) if c.get("perfil") in SIM]
        if not sims:
            return
        token = self._token_gateway()
        if not token:
            return
        self.gw = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id="iot-fastapi-gw")
        self.gw.username_pw_set(token)
        self.gw.reconnect_delay_set(1, 30)
        self.gw.max_queued_messages_set(1000)     # sin conexion no se acumulan sin limite
        self.gw.connect_async(E.get("TB_MQTT_HOST", "thingsboard"), int(E.get("TB_MQTT_PORT", 1883)), 60)
        self.gw.loop_start()
        intervalo = float(cfg.get("sim_interval") or 5)
        estados = {c["device"]: {} for c in sims}
        log.info("simuladores: %s cada %ss (gateway '%s')", ", ".join(c["device"] for c in sims),
                 intervalo, self.gateway)
        while not self.alto.wait(intervalo):
            ts = int(time.time() * 1000)
            datos = {c["device"]: [{"ts": ts, "values": SIM[c["perfil"]](estados[c["device"]])}] for c in sims}
            self.gw.publish("v1/gateway/telemetry", json.dumps(datos), qos=1)
            self.enviados += 1
__FASTAPI_EOF__

cat > config/fastapi/app/main.py <<'__FASTAPI_EOF__'
"""API de la comunidad energetica (sustituye a Node-RED en el stack iot-tb).

Se publica a traves de Caddy en https://<servidor>/cec-api (mismo origen que ThingsBoard:
sin CORS). Autenticacion:
  - JWT de ThingsBoard (cabecera X-Authorization: Bearer ..., la que ya usa el panel): solo
    administradores del tenant (TENANT_ADMIN).
  - X-Api-Key: API_KEY del .env, para el script de instalacion y tareas del servidor.
"""
import asyncio
import secrets
import time
from contextlib import asynccontextmanager
from datetime import date, timedelta
from typing import Literal

from apscheduler.schedulers.asyncio import AsyncIOScheduler
from apscheduler.triggers.cron import CronTrigger
from fastapi import Depends, FastAPI, Header, HTTPException, Query, Response
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

from . import cec, db, informes, tb
from .comun import E, TZL, config, datadis_configurado, log
from .puente import Puente

SYNC_HORA = E.get("SYNC_HORA") or "07:15"
PLAN = AsyncIOScheduler(timezone=TZL)
PUENTE = Puente()
TAREAS = set()
_LANZAR = asyncio.Lock()


@asynccontextmanager
async def vida(app):
    await asyncio.to_thread(db.preparar)
    hh, mm = map(int, SYNC_HORA.split(":"))
    PLAN.add_job(sync_programada, CronTrigger(hour=hh, minute=mm, timezone=TZL), id="diaria",
                 coalesce=True, max_instances=1, misfire_grace_time=3 * 3600)
    PLAN.start()
    PUENTE.arrancar()
    log.info("sincronización diaria a las %s (%s)", SYNC_HORA, "API de Datadis" if datadis_configurado() else "CSV")
    yield
    PLAN.shutdown(wait=False)
    PUENTE.parar()


app = FastAPI(title="API de la comunidad energética", version="1.0", lifespan=vida,
              description="Sincronización de Datadis (PostgreSQL → ThingsBoard), informes y simuladores.")


# ---------------- autenticacion ----------------
_TOKENS = {}   # JWT -> (caduca, usuario) para no preguntar a ThingsBoard en cada peticion


async def admin(x_api_key: str | None = Header(None),
                x_authorization: str | None = Header(None),
                authorization: str | None = Header(None)) -> str:
    if x_api_key:
        if E.get("API_KEY") and secrets.compare_digest(x_api_key, E["API_KEY"]):
            return "api-key"
        raise HTTPException(401, "API key no válida")
    cab = x_authorization or authorization or ""
    if not cab.lower().startswith("bearer "):
        raise HTTPException(401, "Falta el token de ThingsBoard (X-Authorization: Bearer ...)")
    token = cab[7:].strip()
    hit = _TOKENS.get(token)
    if hit and hit[0] > time.time():
        u = hit[1]
    else:
        u = await asyncio.to_thread(tb.usuario, token)
        if len(_TOKENS) > 500:
            _TOKENS.clear()
        _TOKENS[token] = (time.time() + 60, u)
    if not u:
        raise HTTPException(401, "Token de ThingsBoard no válido o caducado")
    if u.get("authority") != "TENANT_ADMIN" or \
            (u.get("tenantId") or {}).get("id") != await asyncio.to_thread(cec.tb().tenant_id):
        raise HTTPException(403, "Solo para administradores de la comunidad")
    return u.get("email") or "admin"


# ---------------- sincronizacion ----------------
class Ocupado(Exception):
    def __init__(self, jid):
        self.jid = jid


async def lanzar(origen, desde, hasta, forzar, socios, quien):
    async with _LANZAR:
        activo = await asyncio.to_thread(db.job_activo)
        if activo:
            raise Ocupado(activo)
        jid = await asyncio.to_thread(db.crear_job, origen, desde, hasta, forzar, socios, quien)
    t = asyncio.create_task(asyncio.to_thread(cec.ejecutar, jid))
    TAREAS.add(t)
    t.add_done_callback(TAREAS.discard)
    return jid


async def sync_programada():
    try:
        jid = await lanzar("auto", None, None, False, None, "programada")
        log.info("sincronización programada %s", jid)
    except Ocupado as o:
        log.info("sincronización programada omitida: ya hay una en curso (%s)", o.jid)


MES = r"^\d{4}[/-](0[1-9]|1[0-2])$"


class PeticionSync(BaseModel):
    origen: Literal["auto", "csv", "datadis", "comunidad"] = Field(
        "auto", description="auto: API de Datadis si hay credenciales; si no, los CSV de DATADIS_DIR. "
                            "comunidad: solo recalcula los totales de la comunidad (socios habilitados)")
    desde: str | None = Field(None, pattern=MES, description="Primer mes (AAAA/MM), solo API de Datadis")
    hasta: str | None = Field(None, pattern=MES, description="Último mes (AAAA/MM), solo API de Datadis")
    forzar: bool = Field(False, description="Repetir consultas de las últimas 24 h y recargar ThingsBoard entero")
    socios: list[str] | None = Field(None, description="Solo estos socios (ids); vacío = todos")


def _job_json(j):
    if not j:
        return None
    j = dict(j)
    j["id"] = str(j["id"])
    return j


@app.get("/salud", include_in_schema=False)
async def salud():
    return {"ok": True}


@app.post("/sync", status_code=202, summary="Lanza una sincronización en segundo plano")
async def sync(p: PeticionSync, quien: str = Depends(admin)):
    desde, hasta = (p.desde or "").replace("-", "/") or None, (p.hasta or "").replace("-", "/") or None
    if desde and hasta and desde > hasta:
        raise HTTPException(422, "desde es posterior a hasta")
    try:
        jid = await lanzar(p.origen, desde, hasta, p.forzar, p.socios or None, quien)
    except Ocupado as o:
        raise HTTPException(409, {"mensaje": "Ya hay una sincronización en curso", "job_id": o.jid})
    return {"job_id": jid, "estado": f"sync/{jid}"}


class PeticionEstado(BaseModel):
    deshabilitado: bool = Field(..., description="true: el socio no cuenta en los totales de la comunidad")


@app.put("/socios/{socio_id}/deshabilitado",
         summary="Habilita o deshabilita un socio (los totales cambian al recalcular la comunidad)")
async def socio_deshabilitado(socio_id: str, p: PeticionEstado, quien: str = Depends(admin)):
    socios = config()["socios"]
    if socio_id not in {so["id"] for so in socios}:
        raise HTTPException(404, "No existe ese socio")
    await asyncio.to_thread(cec.fijar_deshabilitado, socio_id, p.deshabilitado, quien)
    return {"socio": socio_id, "deshabilitado": p.deshabilitado,
            **await asyncio.to_thread(cec.comunidad_pendiente, socios)}


@app.get("/comunidad/pendiente", summary="¿Hay socios habilitados o deshabilitados sin recalcular la comunidad?")
async def comunidad_pendiente(_: str = Depends(admin)):
    return await asyncio.to_thread(cec.comunidad_pendiente, config()["socios"])


@app.get("/sync", summary="Últimas sincronizaciones")
async def sync_lista(_: str = Depends(admin)):
    return [_job_json(j) for j in await asyncio.to_thread(db.jobs)]


@app.get("/sync/{job_id}", summary="Estado de una sincronización")
async def sync_estado(job_id: str, _: str = Depends(admin)):
    j = await asyncio.to_thread(db.job, job_id)
    if not j:
        raise HTTPException(404, "No existe esa sincronización")
    return _job_json(j)


def _estado():
    cfg = config()
    with db.conectar() as cx:
        fuera = cec.deshabilitados(cx)
        socios = []
        for so in cfg["socios"]:
            s = cec.suministro_de(cx, so["id"])
            ext = cec.extension(cx, [s["cups"]]) if s else None
            socios.append({"id": so["id"], "nombre": so["nombre"], "cups": s and s["cups"],
                           "peaje": s and s["peaje"], "paso_min": s and s["paso_min"],
                           "desde": ext and ext["desde"], "hasta": ext and ext["hasta"],
                           "lecturas": ext["n"] if ext else 0, "actualizado": s and s["actualizado"],
                           "deshabilitado": so["id"] in fuera})
    ultimo = db.jobs(1)
    return {"comunidad": cfg["cec"], "datadis_api": datadis_configurado(), "sync_hora": SYNC_HORA,
            "proxima_sync": PLAN.get_job("diaria").next_run_time if PLAN.running else None,
            "ultima_sync": _job_json(ultimo[0]) if ultimo else None,
            "meses_por_defecto": cec.meses_por_defecto(), "puente": PUENTE.estado(), "socios": socios}


@app.get("/estado", summary="Datos cargados en PostgreSQL, próxima sincronización y simuladores")
async def estado(_: str = Depends(admin)):
    return await asyncio.to_thread(_estado)


# ---------------- informes ----------------
def _mes_anterior():
    fin = date.today().replace(day=1) - timedelta(days=1)
    return fin.replace(day=1), fin


async def _informe(socio_id, desde, hasta, formato):
    d0, d1 = _mes_anterior()
    desde, hasta = desde or d0, hasta or d1
    if hasta < desde:
        raise HTTPException(422, "desde es posterior a hasta")
    if (hasta - desde).days > 3 * 366:
        raise HTTPException(422, "Periodo demasiado largo (máximo 3 años)")
    try:
        contenido, mime, nombre = await asyncio.to_thread(informes.generar, socio_id, desde, hasta, formato)
    except KeyError:
        raise HTTPException(404, "No existe ese socio")
    return Response(contenido, media_type=mime, headers={"Content-Disposition": f'attachment; filename="{nombre}"'})


Formato = Literal["pdf", "xlsx", "csv"]


@app.get("/informes/comunidad", summary="Informe de la comunidad (por defecto, el mes anterior)")
async def informe_comunidad(desde: date | None = Query(None), hasta: date | None = Query(None),
                            formato: Formato = "pdf", _: str = Depends(admin)):
    return await _informe(None, desde, hasta, formato)


@app.get("/informes/socio/{socio_id}", summary="Informe de un socio (por defecto, el mes anterior)")
async def informe_socio(socio_id: str, desde: date | None = Query(None), hasta: date | None = Query(None),
                        formato: Formato = "pdf", _: str = Depends(admin)):
    return await _informe(socio_id, desde, hasta, formato)


@app.exception_handler(Ocupado)
async def _ocupado(_, o):
    return JSONResponse({"detail": {"mensaje": "Ya hay una sincronización en curso", "job_id": o.jid}}, 409)
__FASTAPI_EOF__

# Socios y clientes simulados para la API (mismo id de socio que en ThingsBoard)
SOCIOS="$(printf '%s\n' "${SOCIOS[@]}")" CLIENTES="$(printf '%s\n' "${CLIENTES[@]}")" \
CEC_NOMBRE="$CEC_NOMBRE" TB_GATEWAY_NAME="$TB_GATEWAY_NAME" SIM_INTERVAL="$SIM_INTERVAL" \
DATOS_VERSION="$DATOS_VERSION" python3 - config/fastapi/config.json <<'PY'
import json, os, re, sys, unicodedata
E = os.environ


def slug(texto):   # el mismo que en la configuracion de ThingsBoard (paso 9)
    t = unicodedata.normalize("NFD", str(texto)).encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", "-", t).strip("-")


socios = []
for l in E["SOCIOS"].splitlines():
    if l.strip():
        nombre, _, _, carpeta = (l.split("|") + [""] * 4)[:4]
        socios.append({"id": slug(nombre), "nombre": nombre.strip(), "carpeta": carpeta.strip()})
clientes = [{"device": p[3], "perfil": p[5]} for p in (l.split("|") for l in E["CLIENTES"].splitlines() if l.strip())
            if len(p) >= 6]
json.dump({"cec": E["CEC_NOMBRE"], "gateway": E["TB_GATEWAY_NAME"], "sim_interval": float(E["SIM_INTERVAL"]),
           "datos_version": int(E["DATOS_VERSION"]), "socios": socios, "clientes": clientes},
          open(sys.argv[1], "w", encoding="utf-8"), ensure_ascii=False, indent=2)
PY

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
  echo "	# API de la comunidad (FastAPI): mismo origen que ThingsBoard, sin CORS. Valida el"
  echo "	# JWT de ThingsBoard que manda el panel (solo administradores)."
  echo "	handle_path /cec-api/* {"
  echo "		reverse_proxy fastapi:8000"
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
  echo "		not path /api/* /cec-api/* /assets/* /static/* /branding/* /oauth2/* /login/oauth2/* *.js *.css *.ico *.svg *.png *.json *.woff* *.ttf *.otf *.map"
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
        description: "$TB_TENANT_EMAIL / $TB_TENANT_PASSWORD (admin ThingsBoard) · sysadmin@thingsboard.org / $TB_SYSADMIN_PASSWORD · HTTPS 443 · MQTT TLS $MQTTS_PORT (token del dispositivo)"
        icon: thingsboard
        server: my-docker
        container: iot-thingsboard

    - $CEC_NOMBRE:
        href: https://$IP
        description: "$CEC_ADMIN_EMAIL / $CEC_ADMIN_PASSWORD (admin comunidad) · socios: ${CEC_SOCIOS_TXT% · }"
        icon: mdi-lightning-bolt
        server: my-docker
        container: iot-thingsboard

    - API comunidad (FastAPI):
        href: https://$IP/cec-api/docs
        description: "Sincronización Datadis (diaria $SYNC_HORA), informes y simuladores · token de admin de ThingsBoard o X-Api-Key"
        icon: fastapi
        server: my-docker
        container: iot-fastapi

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
        description: "HTTPS 443 -> ThingsBoard · /cec-api -> FastAPI"
        icon: caddy
        server: my-docker
        container: iot-caddy

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
# Solo se publican en el host 80/443 (Caddy) y 8883 (MQTT con TLS de ThingsBoard).
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

  # Copia diaria (pg_dump -Fc) de thingsboard y cec en backups/postgres: una al arrancar
  # y otra cada dia a las 03:00; se borran las de mas de 7 dias.
  # Restaurar: docker compose exec -T postgres pg_restore -U <usuario> -d <thingsboard|cec> --clean < fichero.dump
  pg-backup:
    <<: *common
    image: postgres:${PG_VERSION}
    container_name: iot-pg-backup
    environment:
      PGHOST: postgres
      PGUSER: ${PG_USER}
      PGPASSWORD: ${PG_PASSWORD}
      TZ: ${TZ}
    volumes:
      - ./backups/postgres:/backups
    entrypoint: ["bash", "-c"]
    command:
      - |
        while true; do
          for db in thingsboard cec; do
            f=/backups/$$db-$$(date +%F).dump
            if pg_dump -Fc -d "$$db" -f "$$f.tmp"; then mv "$$f.tmp" "$$f"; echo "copia: $$f"
            else rm -f "$$f.tmp"; echo "ERROR: fallo la copia de PostgreSQL ($$db)" >&2; fi
          done
          find /backups -name '*-*.dump' -mtime +7 -delete
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
      # Web en thingsboard:8080 y MQTT en thingsboard:1883 (sin publicar: entra por Caddy y FastAPI).
      # Hacia fuera, solo MQTT con TLS (8883) con el certificado de config/mqtt-certs
      # (mqtt-cert.sh); ThingsBoard lo lee al arrancar.
      MQTT_SSL_ENABLED: "true"
      MQTT_SSL_BIND_PORT: "${MQTTS_PORT}"
      MQTT_SSL_CREDENTIALS_TYPE: PEM
      MQTT_SSL_PEM_CERT: /mqtt-certs/server.crt
      MQTT_SSL_PEM_KEY: /mqtt-certs/server.key
      MQTT_SSL_PEM_KEY_PASSWORD: ""
      COAP_ENABLED: "false"
      LWM2M_ENABLED: "false"
      SNMP_ENABLED: "false"
      EDGES_ENABLED: "false"
      JAVA_OPTS: "-Xms512M -Xmx2048M"
    volumes:
      - ./data/thingsboard:/data
      - ./data/thingsboard-logs:/var/log/thingsboard
      - ./config/mqtt-certs:/mqtt-certs:ro
    ports:
      - "${MQTTS_PORT}:${MQTTS_PORT}"
    depends_on:
      postgres:
        condition: service_healthy

  # API de la comunidad (config/fastapi, paso 4): sincronizacion diaria con Datadis
  # (PostgreSQL "cec" -> ThingsBoard), informes y simuladores
  # (publican en ThingsBoard por MQTT, Gateway API). Sin puertos publicados: Caddy la sirve en https://<servidor>/cec-api.
  # Un unico worker de uvicorn (Dockerfile): la sincronizacion programada no se duplica.
  fastapi:
    <<: *common
    build:
      context: ./config/fastapi
      args:
        PY_VERSION: ${FASTAPI_PY_VERSION}
    image: iot-fastapi:local
    container_name: iot-fastapi
    environment:
      TZ: ${TZ}
      PGHOST: postgres
      PGDATABASE: cec
      PGUSER: ${PG_USER}
      PGPASSWORD: ${PG_PASSWORD}
      TB_URL: http://thingsboard:8080
      TB_TENANT_EMAIL: ${TB_TENANT_EMAIL}
      TB_TENANT_PASSWORD: ${TB_TENANT_PASSWORD}
      API_KEY: ${FASTAPI_API_KEY}
      SYNC_HORA: ${SYNC_HORA}
      DATADIS_DIR: /datadis
      DATADIS_USER: ${DATADIS_USER}
      DATADIS_PASS: ${DATADIS_PASS}
      DATADIS_NIF_AUTORIZADOS: ${DATADIS_NIF_AUTORIZADOS}
      DATADIS_PAUSA_S: ${DATADIS_PAUSA_S}
    volumes:
      - ./config/fastapi/app:/srv/app:ro
      - ./config/fastapi/config.json:/srv/config.json:ro
      - ${DATADIS_DIR}:/datadis:ro
    healthcheck:
      test: ["CMD", "python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/salud', timeout=3)"]
      interval: 15s
      timeout: 5s
      retries: 20
    depends_on:
      postgres:
        condition: service_healthy
      thingsboard:
        condition: service_started

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
# Adminer (127.0.0.1:8081). Desde otro equipo:
#   ssh -L 8081:127.0.0.1:8081 <usuario>@<servidor>
set -e
cd "$(dirname "$0")"
case "${1:-up}" in
  up)   docker compose --profile tools up -d adminer ;;
  down) docker compose --profile tools rm -sf adminer ;;
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
# Sincronizacion con Datadis a mano (la diaria la programa la propia API a las SYNC_HORA):
#   ./sync.sh                      origen automatico, mes anterior y actual
#   ./sync.sh csv                  relee los CSV de DATADIS_DIR
#   ./sync.sh datadis 2026/01 2026/03 [forzar]
cat > sync.sh <<'EOF'
#!/bin/bash
set -e
cd "$(dirname "$0")"
set -a; source .env; set +a
python3 - "$@" <<'PY'
import json, os, ssl, sys, time, urllib.error, urllib.request
a = sys.argv[1:]
cuerpo = {"origen": a[0] if a else "auto", "forzar": "forzar" in a}
if len(a) >= 3:
    cuerpo.update(desde=a[1], hasta=a[2])
API, CTX = "https://localhost/cec-api", ssl._create_unverified_context()
H = {"X-Api-Key": os.environ["FASTAPI_API_KEY"], "Content-Type": "application/json"}


def pedir(metodo, ruta, body=None):
    req = urllib.request.Request(API + ruta, json.dumps(body).encode() if body else None, H, method=metodo)
    with urllib.request.urlopen(req, timeout=60, context=CTX) as r:
        return json.loads(r.read())


try:
    jid = pedir("POST", "/sync", cuerpo)["job_id"]
except urllib.error.HTTPError as e:
    d = json.loads(e.read() or "{}").get("detail")
    if e.code != 409:
        sys.exit(f"ERROR {e.code}: {d}")
    jid = d["job_id"]
    print("ya hay una sincronizacion en curso, se sigue esa")
visto = 0
while True:
    j = pedir("GET", f"/sync/{jid}")
    for l in j["log"][visto:]:
        print("   ", l["m"])
    visto = len(j["log"])
    if j["estado"] not in ("pendiente", "en_curso"):
        sys.exit(0 if j["estado"] == "ok" else 1)
    time.sleep(3)
PY
EOF
chmod +x start.sh stop.sh logs.sh tools.sh web.sh sync.sh

# Certificado TLS del MQTT de ThingsBoard (8883): el de Let's Encrypt que obtiene Caddy
# para TB_DOMAIN o, mientras no exista, uno autofirmado. Lo ejecuta cron cada semana;
# si cambia, reinicia ThingsBoard (solo lee el certificado al arrancar: 1-3 minutos).
cat > mqtt-cert.sh <<'EOF'
#!/bin/bash
set -e
cd "$(dirname "$0")"
set -a; source .env; set +a
# Los certificados de Caddy son de root: se copian con un contenedor
CAMBIO=$(docker run --rm -v "$PWD:/stack" -e D="$TB_DOMAIN" alpine sh -c '
  set -e; cd /stack; C=config/mqtt-certs; mkdir -p $C
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
  chown -R 799:799 $C; chmod 600 $C/server.key')
if [ -n "$CAMBIO" ]; then
  echo "    certificado MQTT (8883): $CAMBIO"
  if [ -n "$(docker compose ps -q thingsboard)" ]; then docker compose restart thingsboard >/dev/null; fi
fi
EOF
chmod +x mqtt-cert.sh

# Exportacion a JSON de lo que hay en ThingsBoard (./export.sh)
cat > export.sh <<'EOF'
#!/bin/bash
# Vuelca a export/ tenants, clientes, usuarios, dispositivos, perfiles,
# paneles y cadenas de reglas de ThingsBoard. (Las lecturas de la comunidad estan en
# PostgreSQL, base cec: copia diaria en backups/postgres.)
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
CTX = ssl._create_unverified_context()
OUT = Path(__file__).parent / "export"


def call(method, url, body=None, token=None):
    h = {"Content-Type": "application/json"}
    if token:
        h["X-Authorization"] = "Bearer " + token
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
echo "==> Construyendo la imagen de la API de la comunidad (FastAPI)..."
docker compose build -q fastapi

# ThingsBoard no abre el MQTT con TLS sin certificado: se crea antes de levantarlo
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

# Base de datos de la comunidad (lecturas de Datadis, sincronizaciones): la API crea sus tablas
if ! docker compose exec -T -e PGPASSWORD="$PG_PASSWORD" postgres \
     psql -U "$PG_USER" -d thingsboard -tAc "SELECT 1 FROM pg_database WHERE datname = 'cec'" | grep -q 1; then
  docker compose exec -T -e PGPASSWORD="$PG_PASSWORD" postgres createdb -U "$PG_USER" cec
  echo "    PostgreSQL: base de datos 'cec' creada"
fi

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
# --remove-orphans: retira los contenedores de versiones anteriores (Node-RED, Mosquitto,
# MQTT Explorer); sus carpetas data/nodered, data/mosquitto... se conservan
docker compose up -d --remove-orphans
# Herramientas (perfil tools): no arrancan solas, pero si ya existen se recrean con la
# configuracion actual (si no, se quedarian con la red, puertos o version anteriores)
if docker ps -aq --filter name='^iot-adminer$' | grep -q .; then
  echo "==> Actualizando herramientas (Adminer)"
  docker compose --profile tools up -d adminer
fi
# Caddy y FastAPI leen ficheros montados: reinicio para aplicar cambios de config (y del
# codigo de la API)
docker compose restart caddy fastapi >/dev/null

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
  python3 - "$BRAND" "$COLOR_BG" config/branding/index.orig.html "$BRAND_WEB" "$TB_LANG" \
    "$LOGIN_USUARIO_TXT" "$LOGIN_PASSWORD_TXT" > config/branding/index.html <<'PY'
import json, sys
brand, bg, orig, web, lang, txt_usuario, txt_password = sys.argv[1:]
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
# Pantalla de inicio de sesion (tb-login): textos propios en las etiquetas de usuario y
# contraseña. Se reaplican si Angular las vuelve a pintar (cambio de idioma, recarga).
login = ("<script>(function(){var T={'username-input':" + json.dumps(txt_usuario, ensure_ascii=False) +
         ",'password-input':" + json.dumps(txt_password, ensure_ascii=False) + "};"
         "function f(){var l=document.querySelector('tb-login');if(!l)return;"
         "Object.keys(T).forEach(function(id){var i=l.querySelector('#'+id),c=i&&i.closest('mat-form-field'),"
         "m=c&&c.querySelector('mat-label');if(m&&m.textContent!==T[id])m.textContent=T[id];});}"
         "new MutationObserver(f).observe(document.documentElement,{childList:true,subtree:true,characterData:true});})();"
         "</script>")
idioma += login
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
#    - comunidad energetica: socios, dispositivos, usuarios y panel (los datos de
#      Datadis los carga despues la API: ./sync.sh csv)
# --------------------------------------------
echo "==> Configurando ThingsBoard..."
TB_URL="https://localhost" \
TB_SYSADMIN_PASSWORD="$TB_SYSADMIN_PASSWORD" TB_TENANT_PASSWORD="$TB_TENANT_PASSWORD" \
TB_TENANT_EMAIL="$TB_TENANT_EMAIL" TB_LANG="$TB_LANG" \
TB_GATEWAY_NAME="$TB_GATEWAY_NAME" TB_GATEWAY_ANTERIOR="$TB_GATEWAY_ANTERIOR" \
CLIENTES="$(printf '%s\n' "${CLIENTES[@]}")" \
CEC_NOMBRE="$CEC_NOMBRE" CEC_ADMIN_EMAIL="$CEC_ADMIN_EMAIL" CEC_ADMIN_PASSWORD="$CEC_ADMIN_PASSWORD" \
CEC_ADMIN_ANTERIOR_EMAIL="$CEC_ADMIN_ANTERIOR_EMAIL" CEC_ADMIN_ANTERIOR_PASSWORD="$CEC_ADMIN_ANTERIOR_PASSWORD" \
SOCIOS="$(printf '%s\n' "${SOCIOS[@]}")" DATADIS_DIR="$DATADIS_DIR" TZ="$TZ" \
python3 - <<'PY'
import json, os, re, ssl, time, urllib.error, urllib.parse, urllib.request, uuid

E = os.environ
TB = E["TB_URL"]
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


# El gateway de versiones anteriores (Node-RED) se renombra: conserva su token y la
# relacion con los dispositivos que creo
def device_existente(name):
    try:
        return tb.get("/api/tenant/devices?deviceName=" + urllib.parse.quote(name))
    except urllib.error.HTTPError:
        return None


viejo = device_existente(E["TB_GATEWAY_ANTERIOR"])
if viejo and not device_existente(E["TB_GATEWAY_NAME"]):
    viejo["name"] = E["TB_GATEWAY_NAME"]
    tb.post("/api/device", viejo)
    print(f"    gateway '{E['TB_GATEWAY_ANTERIOR']}' renombrado a '{E['TB_GATEWAY_NAME']}'")
gw = device(E["TB_GATEWAY_NAME"], "gateway", gateway=True)
gw_token = tb.get(f"/api/device/{gw['id']['id']}/credentials")["credentialsId"]


# Perfiles de datos: claves (etiqueta, unidad, color, icono) y graficas. Los simuladores
# estan en la API (config/fastapi/app/puente.py).
PERFILES = {
    "ambiente": {
        "desc": "Temperatura, humedad y potencia",
        "keys": {"temperatura": ("Temperatura", "°C", "#e53935", "thermostat"),
                 "humedad": ("Humedad", "%", "#1e88e5", "water_drop"),
                 "potencia": ("Potencia", "W", "#fb8c00", "bolt")},
        # la potencia (W) aplastaria a temperatura/humedad en un solo eje
        "charts": [("Temperatura y humedad", ["temperatura", "humedad"]),
                   ("Potencia", ["potencia"])],
    },
    "energia": {
        "desc": "Generacion fotovoltaica, consumo e intercambio con la red de la comunidad",
        "keys": {"generacion_kw": ("Generación FV", "kW", "#43a047", "solar_power"),
                 "consumo_kw": ("Consumo", "kW", "#e53935", "power"),
                 "red_kw": ("Red (+compra / −vertido)", "kW", "#1e88e5", "electrical_services")},
        "charts": [("Generación y consumo", ["generacion_kw", "consumo_kw"]),
                   ("Intercambio con la red", ["red_kw"])],
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
# La energia de cada socio es la de Datadis. La carga la API de la comunidad (FastAPI,
# config/fastapi): ficheros de DATADIS_DIR/<carpeta> o API de Datadis -> PostgreSQL
# (base cec) -> ThingsBoard, con el ts original de cada lectura. Aqui solo se crean los
# dispositivos, clientes, usuarios y el panel. Solo las coordenadas del mapa son ficticias.
#   <socio>     tipo "socio"      energia de cada periodo de medida (consumo_kwh, vertida_kwh,
#                                 generada_kwh, autoconsumo_kwh), totales diarios (d_*) y,
#                                 como atributos, los datos del suministro (CUPS, peaje...)
#   comunidad   tipo "comunidad"  suma horaria y diaria de todos los socios
# <socio> es el nombre sin acentos, en minusculas y con guiones ("Ana García" -> ana-garcia).
import unicodedata

CEC = E["CEC_NOMBRE"]
DATADIS_DIR = E["DATADIS_DIR"]
CEC_DASH_VERSION = 24           # sube este numero para regenerar el panel de la comunidad
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


def slug(texto):   # el mismo que genera config/fastapi/config.json (paso 4)
    t = unicodedata.normalize("NFD", str(texto)).encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", "-", t).strip("-")


# Energia de Datadis: clave en ThingsBoard, columna del CSV, etiqueta y color (los widgets)
SERIES = [("consumo_kwh", "consumo_kWh", "Consumo de red", "#e0541f"),
          ("vertida_kwh", "energiaVertida_kWh", "Vertido a red", "#2e9d6b"),
          ("generada_kwh", "energiaGenerada_kWh", "Generación FV", "#c07a12"),
          ("autoconsumo_kwh", "energiaAutoconsumida_kWh", "Autoconsumo", "#2f7fd8")]
COLOR_APORTA, COLOR_RECIBE = "#2e9d6b", "#e0541f"
COLOR_DESHABILITADO = "#bdbdbd"   # socio deshabilitado en la tabla de socios

SOCIOS = []
for l in E["SOCIOS"].splitlines():
    if l.strip():
        nombre, email, pw, carpeta, lat, lon = (l.split("|") + [""] * 6)[:6]
        SOCIOS.append({"id": slug(nombre), "nombre": nombre.strip(), "email": email.strip(), "password": pw,
                       "carpeta": carpeta.strip(),
                       "lat": float(lat) if lat.strip() else None, "lon": float(lon) if lon.strip() else None})
SOCIO = {so["id"]: so for so in SOCIOS}


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
# agrupado por periodos y descarga en CSV. Si hay generacion, el autoconsumo se suma al
# consumo (positivo) y los excedentes van en negativo. Pestañas
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
    <div class="dd-metricas"><button type="button" data-m="consumo">Consumos y excedentes</button><button type="button" data-m="pot">Potencias máximas</button><button type="button" data-m="contrato">Contrato</button></div>
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
    <div class="dd-kpi dd-kx"><b class="dd-k3">–</b><span class="dd-l3">Excedentes vertidos a la red (kWh)</span></div>
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
// Con generacion: autoconsumo (consumo cubierto por la FV, positivo) y excedentes (negativo)
var GEN = [{ k: 'auto', n: 'Autoconsumo', c: '#8fc3f0', curva: 'autoconsumo_kwh', d: 'd_autoconsumo_kwh', signo: 1 },
           { k: 'vert', n: 'Excedentes', c: '#4caf7d', curva: 'vertida_kwh', d: 'd_vertida_kwh', signo: -1 }];
function q(s) { return S.raiz.querySelector(s); }
function qa(s) { return [].slice.call(S.raiz.querySelectorAll(s)); }
function r3(v) { return Math.round(v * 1000) / 1000; }
function pj() { return S.peaje && S.peaje !== '2.0TD' ? '6P' : '2.0TD'; }

// Series apiladas: consumo de red por periodos, de abajo (valle) a arriba (punta) como en
// Datadis, el autoconsumo encima y los excedentes por debajo de cero
function cats() {
  var n = pj() === '2.0TD' ? 3 : 6, out = [];
  for (var p = n; p >= 1; p--)
    out.push({ k: 'p' + p, n: n === 3 ? NOM3[p] : 'P' + p, c: (n === 3 ? COL3 : COL6)[p], curva: 'consumo_kwh',
               d: 'd_p' + p + '_kwh', signo: 1, periodo: true });
  return S.hayGen ? out.concat(GEN) : out;
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
  // Datos recalculados (sincronizacion o recalculo de la comunidad): se vuelven a pedir
  S.recarga = function () { cargar(); };
  window.addEventListener('vatiaco-datos', S.recarga);
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

// Claves que tiene la entidad (generacion y pestaña Potencias) y ultimo dia con datos
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

// Consumo siempre; Potencias y Contrato si hay datos
function hay(m) { return { consumo: true, pot: S.pers.length > 0, contrato: !!S.contrato }[m]; }

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
  q('.dd-kx').style.display = !pot && S.hayGen ? '' : 'none';
  q('.dd-pper').style.display = pot ? '' : 'none';
  q('.dd-pper').value = S.pper;
  qa('.dd-modo button').forEach(function (b) { b.classList.toggle('on', (b.dataset.a === '1') === S.apilado); });
  // En el dia cada hora es de un solo periodo: no hay nada que agrupar
  q('.dd-modo').style.display = S.modo === 'dia' || pot ? 'none' : '';
  q('.dd-sel span').textContent = etiqueta(S.ref, S.modo, false);
  var inp = q('.dd-sel input');
  inp.value = VL.iso(S.ref);
  inp.max = VL.iso(new Date());
  q('.dd-nav [data-n="1"]').disabled = mover(S.ref, S.modo, 1) > new Date();
}

// Ventana de tiempo del panel = periodo del grafico: la siguen los widgets que usan la
// del panel (la tabla de energia diaria)
function sincronizar(t0, t1) {
  var db = S.ctx.dashboard;
  if (!db || typeof db.onUpdateTimewindow !== 'function' || (S.tw0 === t0 && S.tw1 === t1)) return;
  S.tw0 = t0; S.tw1 = t1;
  db.onUpdateTimewindow(t0, t1 - 1);
}

function cargar() {
  if (!S.base || !S.ref) return;
  if (!hay(S.metrica)) S.metrica = 'consumo';
  ui();
  if (S.metrica === 'contrato') { pintarContrato(); return; }
  var n = ++S.pedido, C = cats(), dia = S.modo === 'dia';
  var t0 = inicio(S.ref, S.modo).getTime(), t1 = mover(S.ref, S.modo, 1).getTime();
  sincronizar(t0, t1);
  if (S.metrica === 'pot') {
    pedir(['pmax_p' + S.pper + '_kw', 'pmax_p' + S.pper + '_cuando'], t0, t1, function (r) {
      if (n === S.pedido) pintarPot(r, t0);
    });
    return;
  }
  var keys = [];
  C.forEach(function (c) { var k = dia ? c.curva : c.d; if (keys.indexOf(k) < 0) keys.push(k); });
  // Periodos vecinos: consumo total (de red + autoconsumo)
  var mk = S.hayGen ? ['d_consumo_kwh', 'd_autoconsumo_kwh'] : ['d_consumo_kwh'];
  pedir(keys, t0, t1, function (r) {
    pedir(mk, mover(S.ref, S.modo, -3).getTime(), mover(S.ref, S.modo, 4).getTime(), function (rm) {
      if (n !== S.pedido) return;
      S.datos = agrupar(r, C, t0);
      S.vecinos = vecinos([].concat.apply([], mk.map(function (k) { return rm[k] || []; })));
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
      if (dia && c.periodo && 'p' + PERIODO(d, d.getHours(), pj()) !== c.k) return;
      V[i][c.k] = (V[i][c.k] || 0) + c.signo * p.value;
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
  var D = S.datos, C = cats();
  if (!D) return;
  [S.g, S.dona, S.mini].forEach(function (c) { c.resize(); });   // por si estaban ocultos
  var pos = C.filter(function (c) { return c.signo > 0; });
  var tot = {}, total = 0, n = 0;
  C.forEach(function (c) { tot[c.k] = 0; });
  D.V.forEach(function (v, i) { for (var k in v) tot[k] += v[k]; if (D.hay[i]) n++; });
  pos.forEach(function (c) { total += tot[c.k]; });   // consumo total = de red + autoconsumo
  var de = { dia: 'del día', semana: 'de la semana', mes: 'del mes', anio: 'del año' }[S.modo];
  q('.dd-k1').textContent = n ? VL.num(total, 2) : '–';
  q('.dd-l1').textContent = 'Consumo total ' + de + ' (kWh)' +
    (S.hayGen && total ? ' · ' + VL.num(100 * tot.auto / total, 0) + ' % con autoconsumo' : '');
  q('.dd-k2').textContent = n ? VL.num(total / n, 2) : '–';
  q('.dd-l2').textContent = { dia: 'Consumo medio horario', semana: 'Consumo medio diario', mes: 'Consumo medio diario',
                              anio: 'Consumo medio mensual' }[S.modo] + ' (kWh)';
  q('.dd-k3').textContent = n && S.hayGen ? VL.num(tot.vert, 2) : '–';
  // Anillo: de donde sale el consumo (periodos de red y autoconsumo)
  S.dona.setOption({
    animation: false,
    tooltip: { trigger: 'item', formatter: function (p) {
      return p.marker + p.name + ': ' + VL.num(p.value, 2) + ' kWh (' + VL.num(p.percent, 1) + ' %)'; } },
    legend: { orient: 'vertical', right: 0, top: 'middle', icon: 'circle', itemWidth: 10, itemHeight: 10,
              textStyle: { fontSize: 11, color: '#555' }, formatter: function (nm) { return nm.toUpperCase(); } },
    series: [{ type: 'pie', radius: ['62%', '84%'], center: ['34%', '50%'], label: { show: false },
               data: pos.map(function (c) { return { name: c.n, value: r3(tot[c.k]), itemStyle: { color: c.c } }; }) }]
  }, true);
  // Periodos vecinos en gris y el elegido en color (pulsar una barra la abre)
  var M = S.vecinos || [];
  var mser = [{ type: 'bar', stack: 'm', barWidth: '62%',
                data: M.map(function (x, i) { return i === 3 ? null : { value: x.v, itemStyle: { color: '#e4e4e6' } }; }) }];
  pos.forEach(function (c) {
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
  // Grafico principal: apilado (positivos hacia arriba, excedentes hacia abajo) o agrupado
  var apila = S.apilado || S.modo === 'dia';
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
  q('.dd-titulo').textContent = 'Consumo ' + { dia: 'horario', semana: 'diario', mes: 'diario', anio: 'mensual' }[S.modo] +
    ' (kWh)' + (S.hayGen ? ' — autoconsumo sumado al consumo, excedentes en negativo' : '');
  q('.dd-vacio').textContent = 'Sin datos en este periodo';
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
    filas = [['periodo'].concat(C.map(function (c) { return c.n + ' (kWh)'; }), ['consumo total (kWh)']).join(';')];
    D.et.forEach(function (e, i) {
      var v = D.V[i], t = null;
      var cs = C.map(function (c) { if (v[c.k] != null && c.signo > 0) t = (t || 0) + v[c.k]; return f(v[c.k]); });
      filas.push([e].concat(cs, [f(t)]).join(';'));
    });
  }
  var nom = (q('.dd-nombre').textContent || 'datos') + ' ' +
            { consumo: 'consumo', pot: 'potencias P' + S.pper, contrato: 'contrato' }[que] +
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
self.onDestroy = function () {
  window.removeEventListener('vatiaco-datos', S.recarga);
  [S.g, S.dona, S.mini].forEach(function (c) { if (c) c.dispose(); });
};
"""


# VatiaCo.tabla_periodo: tabla de energia del periodo que muestra el widget de consumo
# (la ventana de tiempo del panel, que ese widget fija) con las mismas filas que su
# grafico: horas (01:00..24:00) si es un dia, dias si es una semana o un mes y meses si es
# un año. Columnas (siempre todas): las series de Datadis, saldo con la red y totales.
TABLA_CSS = """
.tp { display: flex; flex-direction: column; height: 100%; font: 13px Roboto, Arial, sans-serif; color: #333; }
.tp-sub { font-size: 12px; color: #777; padding: 0 4px 6px; }
.tp-cuerpo { flex: 1; overflow: auto; }
.tp table { width: 100%; border-collapse: collapse; }
.tp th, .tp td { padding: 5px 8px; text-align: right; border-bottom: 1px solid #eee; white-space: nowrap; }
.tp th:first-child, .tp td:first-child { text-align: left; }
.tp thead th { position: sticky; top: 0; background: #fafafa; font-size: 12px; font-weight: 500; color: #555; }
.tp tfoot td { position: sticky; bottom: 0; background: #fafafa; font-weight: 700; }
.tp th i { display: inline-block; width: 8px; height: 8px; border-radius: 50%; margin-right: 5px; }
.tp-vacio { color: #999; text-align: center; padding: 24px; }
"""

TABLA_HTML = """<div class="tp"><div class="tp-sub"></div><div class="tp-cuerpo"></div></div>"""

TABLA_JS = VL_COMUN_JS + r"""
var T = {};
var MESES = ['Ene', 'Feb', 'Mar', 'Abr', 'May', 'Jun', 'Jul', 'Ago', 'Sep', 'Oct', 'Nov', 'Dic'];
var COLS = """ + json.dumps([{"curva": k, "d": "d_" + k, "n": lab, "c": c} for k, _, lab, c in SERIES],
                            ensure_ascii=False) + r""";

self.onInit = function () {
  T.ctx = self.ctx;
  T.raiz = self.ctx.$container[0];
  var ds = VL.ds(T.ctx);
  if (ds && ds.entityId) T.base = '/api/plugins/telemetry/' + ds.entityType + '/' + ds.entityId;
  revisar();
  T.timer = setInterval(revisar, 2000);   // por si la ventana cambia sin datos nuevos
  // Datos recalculados (sincronizacion o recalculo de la comunidad): se vuelven a pedir
  T.recarga = function () { T.clave = null; revisar(); };
  window.addEventListener('vatiaco-datos', T.recarga);
};
self.onDataUpdated = function () { revisar(); };
self.onDestroy = function () { clearInterval(T.timer); window.removeEventListener('vatiaco-datos', T.recarga); };

// Ventana de tiempo del panel (fija si la ha puesto el widget de consumo)
function ventana() {
  var s = T.ctx.defaultSubscription, tw = s && s.subscriptionTimewindow;
  if (tw && tw.fixedWindow) return [tw.fixedWindow.startTimeMs, tw.fixedWindow.endTimeMs];
  if (tw && tw.realtimeWindowMs) return [Date.now() - tw.realtimeWindowMs, Date.now()];
  var w = T.ctx.timeWindow;
  return w && w.minTime ? [w.minTime, w.maxTime] : null;
}

function revisar() {
  var w = ventana();
  if (!w || !T.base) return;
  var clave = Math.round(w[0] / 3600000) + '-' + Math.round(w[1] / 3600000);
  if (clave === T.clave) return;
  T.clave = clave;
  cargar(w[0], w[1]);
}

// Filas como en el grafico de consumo: horas en un dia, meses en un año, dias si no
function cargar(t0, t1) {
  var dur = t1 - t0, g = dur <= 26 * 3600000 ? 'hora' : dur > 62 * 86400000 ? 'mes' : 'dia', n = (T.pedido = (T.pedido || 0) + 1);
  var keys = COLS.map(function (c) { return g === 'hora' ? c.curva : c.d; });
  T.ctx.http.get(T.base + '/values/timeseries?keys=' + encodeURIComponent(keys.join(',')) + '&startTs=' + t0 +
                 '&endTs=' + t1 + '&agg=NONE&limit=50000&useStrictDataTypes=true')
    .subscribe(function (r) { if (n === T.pedido) pintar(r || {}, g, t0, t1); }, function () {});
}

function grupo(ts, g) {
  var d = new Date(ts);
  if (g === 'hora') return new Date(d.getFullYear(), d.getMonth(), d.getDate(), d.getHours()).getTime();
  if (g === 'mes') return new Date(d.getFullYear(), d.getMonth(), 1).getTime();
  return VL.dia0(d);
}
function fecha(d) { return VL.pad(d.getDate()) + '/' + VL.pad(d.getMonth() + 1) + '/' + d.getFullYear(); }
function etiqueta(t, g) {
  var d = new Date(t);
  if (g === 'hora') return fecha(d) + ' ' + VL.pad(d.getHours() + 1) + ':00';   // hora de fin, como Datadis
  if (g === 'mes') return MESES[d.getMonth()] + ' ' + d.getFullYear();
  return fecha(d);
}

function pintar(r, g, t0, t1) {
  var F = {};
  COLS.forEach(function (c, j) {
    (r[g === 'hora' ? c.curva : c.d] || []).forEach(function (p) {
      if (p.value == null) return;
      var k = grupo(p.ts, g), f = F[k] || (F[k] = {});
      f[j] = (f[j] || 0) + (+p.value);
    });
  });
  // Todas las columnas, aunque el suministro no tenga datos de alguna (sin FV: –)
  var cols = COLS.map(function (c, j) { return j; });
  var filas = Object.keys(F).map(Number).sort(function (a, b) { return a - b; }), tot = {};
  var sub = { hora: 'Horario', dia: 'Diario', mes: 'Mensual' }[g] + ' · ' + fecha(new Date(t0)) +
            (g === 'hora' ? '' : ' – ' + fecha(new Date(t1)));
  T.raiz.querySelector('.tp-sub').textContent = sub + ' · ' + filas.length + (g === 'hora' ? ' horas' : g === 'mes' ? ' meses' : ' días');
  if (!filas.length) {
    T.raiz.querySelector('.tp-cuerpo').innerHTML = '<div class="tp-vacio">Sin datos en este periodo</div>';
    return;
  }
  var celda = function (v) { return '<td>' + (v == null ? '–' : VL.num(v, 2)) + '</td>'; };
  var h = '<table><thead><tr><th>' + { hora: 'Hora', dia: 'Día', mes: 'Mes' }[g] + '</th>' +
    cols.map(function (j) { return '<th><i style="background:' + COLS[j].c + '"></i>' + COLS[j].n + ' (kWh)</th>'; }).join('') +
    '<th>Saldo con la red (kWh)<br><small>+ recibe / − aporta</small></th></tr></thead><tbody>';
  filas.forEach(function (k) {
    var f = F[k];
    h += '<tr><td>' + etiqueta(k, g) + '</td>' + cols.map(function (j) {
      if (f[j] != null) tot[j] = (tot[j] || 0) + f[j];
      return celda(f[j]);
    }).join('') + celda(f[0] == null && f[1] == null ? null : (f[0] || 0) - (f[1] || 0)) + '</tr>';
  });
  h += '</tbody><tfoot><tr><td>Total</td>' + cols.map(function (j) { return celda(tot[j]); }).join('') +
       celda(tot[0] == null && tot[1] == null ? null : (tot[0] || 0) - (tot[1] || 0)) + '</tr></tfoot></table>';
  T.raiz.querySelector('.tp-cuerpo').innerHTML = h;
}
"""


# VatiaCo.admin_datos: administracion de los datos de la comunidad (solo administradores;
# a los socios no se les muestra). Habla con la API de la comunidad en /cec-api (mismo
# origen, a traves de Caddy) con la sesion de ThingsBoard del usuario: la API valida el
# JWT y que sea administrador del tenant. Sincronizacion con Datadis (ahora o un rango de
# meses) con su progreso y registro, datos cargados en PostgreSQL por socio e informes.
ADMIN_CSS = """
.ad { height: 100%; overflow: auto; font: 13px Roboto, Arial, sans-serif; color: #333; }
.ad-oculto { display: none; }
.ad-fila { display: flex; flex-wrap: wrap; gap: 12px; }
.ad-caja { flex: 1 1 340px; min-width: 0; border: 1px solid #eee; border-radius: 6px; padding: 8px 10px; margin-bottom: 12px; }
.ad h3 { margin: 0 0 8px; font-size: 14px; font-weight: 700; color: #7b2fa8; }
.ad-ctrl { display: flex; flex-wrap: wrap; gap: 6px 10px; align-items: center; margin: 8px 0; }
.ad-ctrl label { display: inline-flex; gap: 4px; align-items: center; color: #555; }
.ad input, .ad select { font: inherit; padding: 3px 4px; border: 1px solid #ccc; border-radius: 4px; background: #fff; }
.ad-b { font: inherit; padding: 5px 12px; border: 0; border-radius: 4px; background: #7b2fa8; color: #fff; cursor: pointer; }
.ad-b.sec { background: #f1e6f8; color: #7b2fa8; }
.ad-b:disabled { opacity: .5; cursor: default; }
.ad-estado b { font-weight: 700; }
.ad-chip { display: inline-block; padding: 1px 8px; border-radius: 10px; font-size: 12px; font-weight: 700; color: #fff; background: #9e9e9e; }
.ad-chip.ok { background: #2e9d6b; } .ad-chip.en_curso, .ad-chip.pendiente { background: #2f7fd8; }
.ad-chip.con_errores { background: #c07a12; } .ad-chip.error { background: #e0541f; }
.ad-barra { height: 6px; background: #eee; border-radius: 3px; margin: 6px 0; overflow: hidden; }
.ad-barra div { height: 100%; background: #2f7fd8; width: 0; transition: width .3s; }
.ad-log { max-height: 150px; overflow: auto; background: #fafafa; border: 1px solid #eee; border-radius: 4px;
  padding: 6px; margin: 6px 0 0; font: 11.5px/1.45 monospace; white-space: pre-wrap; }
.ad-msg { margin-top: 6px; color: #555; } .ad-msg.err { color: #e0541f; }
.ad table { border-collapse: collapse; width: 100%; }
.ad th, .ad td { text-align: left; padding: 4px 6px; border-bottom: 1px solid #f0f0f0; white-space: nowrap; }
.ad th { font-weight: 700; color: #555; } .ad td.n { text-align: right; }
"""

ADMIN_HTML = """<div class="ad">
 <div class="ad-fila">
  <section class="ad-caja">
   <h3>Sincronización con Datadis</h3>
   <div class="ad-estado">Cargando…</div>
   <div class="ad-barra"><div></div></div>
   <div class="ad-ctrl"><button class="ad-b ad-ya">Actualizar ahora</button><span class="ad-prog"></span></div>
   <div class="ad-ctrl">
    <label>Origen <select class="ad-origen"><option value="auto">Automático</option>
     <option value="datadis">API de Datadis</option><option value="csv">Ficheros CSV</option></select></label>
    <label>Desde <input type="month" class="ad-desde"></label>
    <label>Hasta <input type="month" class="ad-hasta"></label>
    <label title="Repite consultas de las últimas 24 h y recarga ThingsBoard entero"><input type="checkbox" class="ad-forzar"> Forzar</label>
    <button class="ad-b sec ad-rango">Recargar rango</button>
   </div>
   <pre class="ad-log"></pre>
   <div class="ad-msg ad-smsg"></div>
  </section>
  <section class="ad-caja">
   <h3>Informes</h3>
   <div class="ad-ctrl"><label>De <select class="ad-ambito"><option value="">Toda la comunidad</option></select></label></div>
   <div class="ad-ctrl">
    <label>Desde <input type="date" class="ad-idesde"></label>
    <label>Hasta <input type="date" class="ad-ihasta"></label>
    <label>Formato <select class="ad-fmt"><option value="pdf">PDF</option><option value="xlsx">Excel</option>
     <option value="csv">CSV</option></select></label>
    <button class="ad-b ad-desc">Descargar</button>
   </div>
   <div class="ad-msg ad-imsg">PDF con los mismos gráficos que el panel (reparto por periodos, periodos anteriores, consumo apilado, potencias máximas) y contrato; Excel y CSV con los datos diarios.</div>
  </section>
 </div>
 <section class="ad-caja"><h3>Datos cargados en la base de datos (PostgreSQL)</h3><div class="ad-tabla"></div></section>
</div>"""

ADMIN_JS = VL_COMUN_JS + r"""
self.onInit = function () {
  var c = self.ctx.$container[0], u = self.ctx.currentUser || {};
  var q = function (s) { return c.querySelector('.' + s); };
  self.vivo = true;
  if (u.authority !== 'TENANT_ADMIN') { q('ad').classList.add('ad-oculto'); return; }
  var API = '/cec-api', jobVisto = null, siguiendo = false;
  var ESTADOS = { pendiente: 'pendiente', en_curso: 'en curso', ok: 'correcta', con_errores: 'con errores', error: 'error' };

  function api(metodo, ruta, cuerpo, crudo) {
    var h = { 'X-Authorization': 'Bearer ' + (localStorage.getItem('jwt_token') || '') };
    if (cuerpo) h['Content-Type'] = 'application/json';
    return fetch(API + ruta, { method: metodo, headers: h, body: cuerpo ? JSON.stringify(cuerpo) : undefined })
      .then(function (r) {
        if (r.ok) return crudo ? r : r.json();
        return r.json().catch(function () { return {}; }).then(function (j) {
          var d = j.detail, e = new Error(typeof d === 'string' ? d : (d && d.mensaje) || ('HTTP ' + r.status));
          e.job = d && d.job_id; throw e;
        });
      });
  }
  function fecha(s) {
    if (!s) return '–';
    var d = new Date(s);
    return VL.pad(d.getDate()) + '/' + VL.pad(d.getMonth() + 1) + '/' + d.getFullYear() + ' ' + VL.pad(d.getHours()) + ':' + VL.pad(d.getMinutes());
  }
  function dia(s) { return s ? fecha(s).slice(0, 10) : '–'; }
  function esc(t) { return String(t == null ? '' : t).replace(/[&<>"]/g, function (x) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[x]; }); }
  function msg(cl, t, err) { var m = q(cl); m.textContent = t || ''; m.classList.toggle('err', !!err); }
  function botones(activo) { q('ad-ya').disabled = q('ad-rango').disabled = activo; }

  function pintarJob(j) {
    if (!j) { q('ad-prog').textContent = 'Aún no hay sincronizaciones'; return; }
    var activo = j.estado === 'pendiente' || j.estado === 'en_curso';
    q('ad-prog').innerHTML = '<span class="ad-chip ' + j.estado + '">' + (ESTADOS[j.estado] || j.estado) + '</span> ' +
      esc(j.origen) + (j.desde ? ' ' + esc(j.desde) + '–' + esc(j.hasta) : '') + ' · ' + fecha(j.inicio || j.creado) +
      (j.total ? ' · ' + j.hechos + '/' + j.total + ' socios' : '') + (j.errores ? ' · ' + j.errores + ' errores' : '');
    q('ad-barra').firstChild.style.width = (j.total ? Math.round(100 * j.hechos / j.total) : (activo ? 5 : 100)) + '%';
    if (j.log) {
      var log = q('ad-log');
      log.textContent = j.log.slice(-60).map(function (l) { return l.t.slice(11, 19) + '  ' + l.m; }).join('\n');
      log.scrollTop = log.scrollHeight;
    }
    botones(activo);
    if (activo) { seguir(j.id); }
    else if (siguiendo && jobVisto === j.id) {
      siguiendo = false;
      window.dispatchEvent(new CustomEvent('vatiaco-datos'));   // el resto del panel recarga sus datos
      q('ad-smsg').textContent = 'Sincronización terminada: los gráficos y tablas del panel se han actualizado.';
      cargarEstado(true);
    }
  }
  function seguir(id) {
    jobVisto = id; siguiendo = true;
    clearTimeout(self.T);
    self.T = setTimeout(function () {
      if (!self.vivo) return;
      api('GET', '/sync/' + id).then(pintarJob).catch(function (e) { msg('ad-smsg', e.message, true); });
    }, 2500);
  }
  function pintarSocios(s) {
    var h = '<table><tr><th>Socio</th><th>CUPS</th><th>Peaje</th><th>Resolución</th><th>Desde</th><th>Hasta</th><th class="n">Lecturas</th><th>Última carga</th></tr>';
    s.socios.forEach(function (x) {
      h += '<tr><td>' + esc(x.nombre) + '</td><td>' + esc(x.cups || '–') + '</td><td>' + esc(x.peaje || '–') + '</td><td>' +
        (x.paso_min ? (x.paso_min === 15 ? 'cuartohoraria' : 'horaria') : '–') + '</td><td>' + dia(x.desde) + '</td><td>' + dia(x.hasta) +
        '</td><td class="n">' + VL.num(x.lecturas, 0) + '</td><td>' + fecha(x.actualizado) + '</td></tr>';
    });
    q('ad-tabla').innerHTML = h + '</table>';
  }
  function cargarEstado(soloTabla) {
    return api('GET', '/estado').then(function (s) {
      pintarSocios(s);
      if (soloTabla) return;
      q('ad-estado').innerHTML = 'Automática cada día a las <b>' + esc(s.sync_hora) + '</b> desde ' +
        (s.datadis_api ? 'la <b>API de Datadis</b>' : 'los <b>ficheros CSV</b> (sin credenciales de Datadis)') +
        ' · próxima: ' + fecha(s.proxima_sync);
      var m = s.meses_por_defecto || [];
      if (m[0]) { q('ad-desde').value = m[0].replace('/', '-'); q('ad-hasta').value = m[1].replace('/', '-'); }
      var amb = q('ad-ambito');
      s.socios.forEach(function (x) { var o = document.createElement('option'); o.value = x.id; o.textContent = x.nombre; amb.appendChild(o); });
      pintarJob(s.ultima_sync && s.ultima_sync.id ? s.ultima_sync : null);
      if (s.ultima_sync) api('GET', '/sync/' + s.ultima_sync.id).then(pintarJob);
    }).catch(function (e) { q('ad-estado').textContent = 'No se pudo consultar la API de la comunidad: ' + e.message; });
  }
  function lanzar(cuerpo) {
    msg('ad-smsg', ''); botones(true);
    api('POST', '/sync', cuerpo).then(function (r) {
      jobVisto = r.job_id; siguiendo = true;
      return api('GET', '/sync/' + r.job_id).then(pintarJob);
    }).catch(function (e) {
      msg('ad-smsg', e.message, true);
      if (e.job) { seguir(e.job); } else { botones(false); }
    });
  }
  q('ad-ya').onclick = function () { lanzar({ origen: 'auto' }); };
  q('ad-rango').onclick = function () {
    var d = q('ad-desde').value, h = q('ad-hasta').value, o = q('ad-origen').value;
    if (o !== 'csv' && (!d || !h || d > h)) { msg('ad-smsg', 'Elige un rango de meses válido', true); return; }
    lanzar({ origen: o, desde: d ? d.replace('-', '/') : null, hasta: h ? h.replace('-', '/') : null, forzar: q('ad-forzar').checked });
  };

  // Informes: por defecto, el mes anterior
  var hoy = new Date(), fin = new Date(hoy.getFullYear(), hoy.getMonth(), 0);
  q('ad-idesde').value = VL.iso(new Date(fin.getFullYear(), fin.getMonth(), 1));
  q('ad-ihasta').value = VL.iso(fin);
  q('ad-desc').onclick = function () {
    var amb = q('ad-ambito').value, fmt = q('ad-fmt').value, b = q('ad-desc');
    var ruta = (amb ? '/informes/socio/' + encodeURIComponent(amb) : '/informes/comunidad') +
      '?desde=' + q('ad-idesde').value + '&hasta=' + q('ad-ihasta').value + '&formato=' + fmt;
    b.disabled = true; msg('ad-imsg', 'Generando el informe…');
    api('GET', ruta, null, true).then(function (r) {
      var n = (r.headers.get('Content-Disposition') || '').match(/filename="([^"]+)"/);
      return r.blob().then(function (blob) {
        var a = document.createElement('a');
        a.href = URL.createObjectURL(blob); a.download = n ? n[1] : 'informe.' + fmt;
        document.body.appendChild(a); a.click();
        setTimeout(function () { URL.revokeObjectURL(a.href); a.remove(); }, 2000);
        msg('ad-imsg', 'Descargado ' + a.download);
      });
    }).catch(function (e) { msg('ad-imsg', e.message, true); })
      .then(function () { b.disabled = false; });
  };
  cargarEstado();
};
self.onDestroy = function () { self.vivo = false; clearTimeout(self.T); };
"""


def cec_widget(fqn, nombre, html, js, alto, css, tipo="latest", recursos=None):
    """Crea o actualiza un tipo de widget del tenant (los paneles lo usan por su fqn).
    tipo "timeseries": recibe la ventana de tiempo del panel; "static": sin datos."""
    desc = {"type": tipo, "sizeX": 24, "sizeY": alto,
            "resources": [{"url": ECHARTS, "isModule": False}] if recursos is None else recursos,
            "templateHtml": html, "templateCss": css, "controllerScript": js, "settingsDirective": "",
            "defaultConfig": json.dumps({"datasources": [], "showTitle": True, "title": nombre,
                                         "backgroundColor": "#fff", "color": "rgba(0,0,0,0.87)",
                                         "padding": "8px", "settings": {}})}
    try:   # se busca por "tenant.<fqn>" (sin el prefijo da 400 y se crearia un duplicado)
        w = tb.get("/api/widgetType?fqn=" + urllib.parse.quote("tenant." + fqn))
    except urllib.error.HTTPError:
        w = None
    if w and all(w["descriptor"].get(k) == desc[k] for k in ("type", "templateHtml", "templateCss", "controllerScript", "resources")):
        return
    cuerpo = {"fqn": fqn, "name": nombre, "deprecated": False, "descriptor": desc}
    if w:
        cuerpo.update(id=w["id"], version=w.get("version"))
    tb.post("/api/widgetType", cuerpo)
    print(f"    widget '{nombre}' ({fqn}) {'actualizado' if w else 'creado'}")


def w_vl(fqn, alias, keys, titulo, x, y, w, h, alto_movil=None):
    """Widget propio en un panel: los del tenant se referencian como "tenant.<fqn>".
    alto_movil: filas (de 70 px) en pantallas pequeñas; si no, las mismas que en escritorio."""
    cfg = {"datasources": [{"type": "entity", "entityAliasId": alias, "dataKeys": keys}],
           "showTitle": True, "title": titulo, "settings": {}, "backgroundColor": "#fff",
           "color": "rgba(0,0,0,0.87)", "padding": "8px", "dropShadow": True, "enableFullscreen": True}
    if alto_movil:
        cfg["mobileHeight"] = alto_movil
    return _w("tenant." + fqn, cfg, "latest", x, y, w, h)


def w_consumo(alias, x, y, w, h):
    """Vista de consumo como la de Datadis (el widget pide sus datos; la clave solo
    resuelve la entidad del alias). En pantallas pequeñas (vista movil de ThingsBoard,
    filas de 70 px) 12 filas en vez de 15: el grafico de barras, que ocupa lo que dejan
    la cabecera y el resumen, se queda en la mitad de alto."""
    return w_vl("VatiaCo.consumo", alias, [_dk("d_consumo_kwh", "Consumo")], "Consumo", x, y, w, h, alto_movil=12)


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


# Columnas de la tabla de socios: (clave, etiqueta, tipo, decimales). Los d_* son el
# total del ultimo dia con datos (el ultimo valor de la serie diaria).
CLAVES_SOCIO = [("peaje", "Peaje", "attribute", None), ("potencia", "Potencia (kW)", "attribute", None),
                ("d_consumo_kwh", "Consumo de red (kWh)", "timeseries", 1),
                ("d_vertida_kwh", "Vertido (kWh)", "timeseries", 1),
                ("d_generada_kwh", "Generación FV (kWh)", "timeseries", 1),
                ("datos_hasta", "Último día", "attribute", None)]


# VatiaCo.socios: tabla de socios con la energia del ultimo dia con datos. Se ordena por
# cualquier columna (pulsando su cabecera, otra vez para invertir) y el administrador puede
# marcar un socio como deshabilitado: la API de la comunidad lo guarda, recalcula los totales
# de la comunidad sin el (panel e informes) y pone su atributo "deshabilitado", que pinta de
# gris su fila y su rayo del mapa. Pulsar una fila abre los datos del socio.
SOCIOS_CSS = """
.ts { display: flex; flex-direction: column; height: 100%; font: 13px Roboto, Arial, sans-serif; color: #333; }
.ts-ayuda { font-size: 12px; color: #777; padding: 0 4px 6px; }
.ts-cuerpo { flex: 1; overflow: auto; }
.ts table { width: 100%; border-collapse: collapse; }
.ts th, .ts td { padding: 6px 8px; text-align: right; border-bottom: 1px solid #eee; white-space: nowrap; }
.ts th:first-child, .ts td:first-child, .ts th.tx, .ts td.tx { text-align: left; }
.ts th { position: sticky; top: 0; background: #fff; font-weight: 500; color: #555; cursor: pointer; user-select: none; }
.ts th:hover { color: #7b2fa8; }
.ts th.on { color: #7b2fa8; }
.ts th .fl { display: inline-block; width: 12px; font-size: 10px; }
.ts tbody tr { cursor: pointer; }
.ts tbody tr:hover { background: #f6f1fa; }
.ts tr.off td { color: #aaa; }
.ts tr.off td:first-child::after { content: ' (deshabilitado)'; font-size: 11px; }
.ts td.ck, .ts th.ck { text-align: center; }
.ts input { cursor: pointer; width: 16px; height: 16px; accent-color: #7b2fa8; }
.ts-msg { font-size: 12px; color: #e0541f; padding: 4px; }
.ts-rc { display: block; margin: 4px auto 0; font: inherit; font-size: 11px; font-weight: 500; padding: 2px 8px;
  border: 1px solid #7b2fa8; border-radius: 3px; background: #fff; color: #7b2fa8; cursor: pointer; }
.ts-rc.pend { background: #7b2fa8; color: #fff; }
.ts-rc:disabled { opacity: .5; cursor: default; }
"""

SOCIOS_HTML = """<div class="ts"><div class="ts-ayuda">Pulsa una cabecera para ordenar (otra vez para invertir) y una fila
para ver los datos del socio. <span class="ts-ad">Marca <b>Deshabilitado</b> para sacarlo de los totales de la comunidad
(se muestra en gris en el mapa) y pulsa <b>Recalcular</b> para aplicar los cambios.</span></div>
<div class="ts-cuerpo"></div><div class="ts-msg"></div></div>"""

SOCIOS_JS = VL_COMUN_JS + r"""
// t: n numero (la potencia "4,6 / 4,6" ordena por la primera), d fecha dd/mm/aaaa, s texto, b casilla
var COLS = [{ k: '_nombre', n: 'Socio', t: 's' }, { k: 'peaje', n: 'Peaje', t: 's' },
            { k: 'potencia', n: 'Potencia (kW)', t: 'n', txt: true },
            { k: 'd_consumo_kwh', n: 'Consumo de red (kWh)', t: 'n', dec: 1 },
            { k: 'd_vertida_kwh', n: 'Vertido (kWh)', t: 'n', dec: 1 },
            { k: 'd_generada_kwh', n: 'Generación FV (kWh)', t: 'n', dec: 1 },
            { k: 'datos_hasta', n: 'Último día', t: 'd' }, { k: 'deshabilitado', n: 'Deshabilitado', t: 'b' }];
var S = { orden: 0, asc: true, filas: [], local: {}, pendiente: false, recalculando: false };
var API = '/cec-api';
function api(metodo, ruta, cuerpo) {
  return fetch(API + ruta, { method: metodo, body: cuerpo ? JSON.stringify(cuerpo) : undefined,
    headers: { 'Content-Type': 'application/json', 'X-Authorization': 'Bearer ' + (localStorage.getItem('jwt_token') || '') }
  }).then(function (r) {
    return r.json().catch(function () { return {}; }).then(function (j) {
      if (r.ok) return j;
      var d = j.detail, e = new Error(typeof d === 'string' ? d : (d && d.mensaje) || 'HTTP ' + r.status);
      e.job = d && d.job_id; throw e;
    });
  });
}

function q(s) { return S.raiz.querySelector(s); }
function esc(t) { return String(t == null ? '' : t).replace(/[&<>"]/g, function (x) {
  return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[x]; }); }
function desh(f) {
  var v = f.id in S.local ? S.local[f.id] : f.deshabilitado;
  return v === true || v === 'true';
}
function clave(f, c) {
  if (c.t === 'b') return desh(f) ? 1 : 0;
  var v = f[c.k];
  if (v == null || v === '') return null;
  if (c.t === 'n') { var x = parseFloat(String(v).replace(',', '.')); return isNaN(x) ? null : x; }
  if (c.t === 'd') { var p = String(v).split('/'); return p.length === 3 ? +p[2] * 10000 + +p[1] * 100 + +p[0] : null; }
  return String(v).toLocaleLowerCase('es');
}

self.onInit = function () {
  S.raiz = self.ctx.$container[0];
  S.admin = (self.ctx.currentUser || {}).authority === 'TENANT_ADMIN';
  if (!S.admin) q('.ts-ad').style.display = 'none';
  self.onDataUpdated();
  if (S.admin) api('GET', '/comunidad/pendiente').then(function (j) { S.pendiente = j.pendiente; pintar(); }, function () {});
};

// Una fila por entidad del alias con el ultimo valor de cada clave
self.onDataUpdated = function () {
  var F = {}, orden = [];
  (self.ctx.data || []).forEach(function (d) {
    var ds = d.datasource;
    if (!ds || !ds.entityId) return;
    var f = F[ds.entityId];
    if (!f) {
      f = F[ds.entityId] = { id: ds.entityId, tipo: ds.entityType || 'DEVICE', name: ds.entityName,
                             _nombre: ds.entityLabel || ds.entityName };
      orden.push(f);
    }
    f[d.dataKey.name] = d.data && d.data.length ? d.data[d.data.length - 1][1] : null;
  });
  // Los cambios propios dejan de ser locales cuando llega el valor guardado
  orden.forEach(function (f) {
    if (f.id in S.local && (f.deshabilitado === true || f.deshabilitado === 'true') === S.local[f.id]) delete S.local[f.id];
  });
  S.filas = orden;
  pintar();
};

function pintar() {
  if (!S.raiz) return;
  var c = COLS[S.orden], dir = S.asc ? 1 : -1;
  var filas = S.filas.slice().sort(function (a, b) {
    var x = clave(a, c), y = clave(b, c);
    if (x === y) return String(a._nombre).localeCompare(String(b._nombre), 'es');
    if (x === null) return 1;            // sin dato, siempre al final
    if (y === null) return -1;
    return (x < y ? -1 : 1) * dir;
  });
  var h = '<table><thead><tr>' + COLS.map(function (k, i) {
    var cl = (k.t === 'b' ? 'ck' : k.t === 'n' ? '' : 'tx') + (i === S.orden ? ' on' : '');
    var boton = k.t === 'b' && S.admin ? '<button type="button" class="ts-rc' + (S.pendiente ? ' pend' : '') + '"' +
      (S.recalculando ? ' disabled' : '') + ' title="Recalcula los totales de la comunidad con los socios habilitados">' +
      (S.recalculando ? 'Recalculando…' : 'Recalcular') + '</button>' : '';
    return '<th class="' + cl + '" data-i="' + i + '">' + esc(k.n) +
           '<span class="fl">' + (i === S.orden ? (S.asc ? '▲' : '▼') : '') + '</span>' + boton + '</th>';
  }).join('') + '</tr></thead><tbody>';
  filas.forEach(function (f) {
    var off = desh(f);
    h += '<tr data-id="' + esc(f.id) + '"' + (off ? ' class="off"' : '') + '>' + COLS.map(function (k) {
      var v = f[k.k];
      if (k.t === 'b')
        return '<td class="ck"><input type="checkbox" data-id="' + esc(f.id) + '"' + (off ? ' checked' : '') +
               (S.admin ? '' : ' disabled') + ' title="Deshabilitar: se muestra en gris en el mapa"></td>';
      if (k.t === 'n' && !k.txt) return '<td>' + (v == null || v === '' ? '–' : VL.num(+v, k.dec)) + '</td>';
      return '<td class="' + (k.t === 'n' ? '' : 'tx') + '">' + (v == null || v === '' ? '–' : esc(v)) + '</td>';
    }).join('') + '</tr>';
  });
  q('.ts-cuerpo').innerHTML = h + '</tbody></table>';

  var rc = q('.ts-rc');
  if (rc) rc.onclick = function (e) { e.stopPropagation(); recalcular(); };
  [].forEach.call(S.raiz.querySelectorAll('th'), function (th) {
    th.onclick = function () {
      var i = +th.dataset.i;
      S.asc = i === S.orden ? !S.asc : true;
      S.orden = i;
      pintar();
    };
  });
  [].forEach.call(S.raiz.querySelectorAll('tbody tr'), function (tr) {
    tr.onclick = function (e) {
      if (e.target.tagName === 'INPUT') return;
      var f = S.filas.filter(function (x) { return x.id === tr.dataset.id; })[0], sc = self.ctx.stateController;
      if (f && sc) sc.openState('socio', { entityId: { entityType: f.tipo, id: f.id },
                                           entityName: f.name, entityLabel: f._nombre }, false);
    };
  });
  [].forEach.call(S.raiz.querySelectorAll('tbody input'), function (cb) {
    cb.onchange = function () {
      var f = S.filas.filter(function (x) { return x.id === cb.dataset.id; })[0];
      if (!f) return;
      S.local[f.id] = cb.checked;
      q('.ts-msg').textContent = '';
      pintar();
      // La API guarda el estado y pone el atributo (color del mapa); los totales de la
      // comunidad cambian al pulsar Recalcular
      api('PUT', '/socios/' + encodeURIComponent(f.name) + '/deshabilitado', { deshabilitado: cb.checked })
      .then(function (j) {
        S.pendiente = j.pendiente;
        aviso(f._nombre + (cb.checked ? ' deshabilitado' : ' habilitado') +
              (j.pendiente ? '. Pulsa Recalcular para aplicarlo a los totales de la comunidad.' : '.'), false);
        pintar();
      }).catch(function (e) {
        delete S.local[f.id];
        aviso('No se pudo guardar el cambio de ' + f._nombre + ' (' + e.message + ')', true);
        pintar();
      });
    };
  });
}

function aviso(t, err) { var m = q('.ts-msg'); m.textContent = t; m.style.color = err ? '#e0541f' : '#2e7d32'; }

function recalcular() {
  S.recalculando = true;
  aviso('Recalculando los totales de la comunidad…', false);
  pintar();
  api('POST', '/sync', { origen: 'comunidad' }).then(function (j) { seguir(j.job_id); }, function (e) {
    if (e.job) { aviso('Hay una sincronización en curso; sus totales incluirán los cambios. Esperando…', false); seguir(e.job); }
    else { S.recalculando = false; aviso('No se pudo recalcular: ' + e.message, true); pintar(); }
  });
}

// Sigue el trabajo y, al terminar, avisa al resto de widgets del panel para que recarguen
// sus datos (grafico de consumo y tabla de energia: evento "vatiaco-datos")
function seguir(id) {
  clearTimeout(S.T);
  S.T = setTimeout(function () {
    api('GET', '/sync/' + id).then(function (j) {
      if (j.estado === 'pendiente' || j.estado === 'en_curso') return seguir(id);
      S.recalculando = false;
      if (j.estado === 'ok' || j.estado === 'con_errores') window.dispatchEvent(new CustomEvent('vatiaco-datos'));
      return api('GET', '/comunidad/pendiente').then(function (p) {
        S.pendiente = p.pendiente;
        aviso(j.estado === 'ok' ? 'Totales de la comunidad recalculados.' : 'El recálculo ha terminado con estado ' + j.estado + '.',
              j.estado !== 'ok');
        pintar();
      });
    }).catch(function (e) { S.recalculando = false; aviso('No se pudo seguir el recálculo: ' + e.message, true); pintar(); });
  }, 2000);
}

self.onDestroy = function () { clearTimeout(S.T); };
"""


def w_socios(alias, x, y, w, h):
    keys = [_dk(k, lab, typ, decimals=d) for k, lab, typ, d in CLAVES_SOCIO] + \
           [_dk("deshabilitado", "Deshabilitado", "attribute")]
    return w_vl("VatiaCo.socios", alias, keys, "Socios: energía del último día con datos", x, y, w, h)


def w_diaria(alias, x, y, w, h):
    """Tabla de energia del periodo del grafico de consumo (VatiaCo.tabla_periodo): sigue la
    ventana de tiempo del panel, que fija el widget de consumo."""
    cfg = {"datasources": [{"type": "entity", "entityAliasId": alias, "dataKeys": [_dk("d_consumo_kwh", "Consumo")]}],
           "showTitle": True, "title": "Energía del periodo del gráfico (kWh)", "settings": {},
           "backgroundColor": "#fff", "color": "rgba(0,0,0,0.87)", "padding": "8px", "dropShadow": True,
           "enableFullscreen": True, "useDashboardTimewindow": True, "displayTimewindow": False}
    return _w("tenant.VatiaCo.tabla_periodo", cfg, "timeseries", x, y, w, h)


def w_mapa(alias, x, y, w, h):
    """Un rayo por socio en su ubicacion (ficticia): verde si el ultimo dia vertio a la red
    mas de lo que consumio de ella, rojo si consumio mas; gris claro si esta deshabilitado
    (casilla de la tabla de socios)."""
    cfg, typ = _base("system.map")
    marker = json.loads(json.dumps(cfg["settings"]["markers"][0]))
    color = {"type": "function", "color": "#1e88e5",
             "colorFunction": "if (data.deshabilitado === true || data.deshabilitado === 'true') return '" + COLOR_DESHABILITADO + "';\n"
                              "var r = data.d_red_neto_kwh;\nif (r === undefined || r === null) return '#9e9e9e';\n"
                              "if (r < -0.05) return '" + COLOR_APORTA + "';\n"
                              "if (r > 0.05) return '" + COLOR_RECIBE + "';\nreturn '#1e88e5';"}
    marker.update({
        "dsType": "entity", "dsLabel": "Socios", "dsEntityAliasId": alias, "dsDeviceId": None, "dsFilterId": None,
        "additionalDataKeys": [_dk(k, k, typ) for k, _, typ, _ in CLAVES_SOCIO] + [_dk("d_red_neto_kwh"),
                               _dk("deshabilitado", "deshabilitado", "attribute")],
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


def w_admin(x, y, w, h):
    """Administracion de los datos (VatiaCo.admin_datos): widget estatico, sin datasource."""
    cfg = {"datasources": [], "showTitle": True, "title": "Administración de datos de la comunidad",
           "settings": {}, "backgroundColor": "#fff", "color": "rgba(0,0,0,0.87)", "padding": "8px",
           "dropShadow": True, "enableFullscreen": True, "mobileHeight": 16}
    return _w("tenant.VatiaCo.admin_datos", cfg, "static", x, y, w, h)


def cec_config(title):
    """Panel estandar de la comunidad, el mismo para todos. El alias "Mi nudo" depende de
    quien mira (CURRENT_USER, relaciones creadas por cec_enlazar): el administrador ve los
    totales de la comunidad y todos los socios; un socio ve solo sus datos y su rayo.
    (Desde CURRENT_USER_OWNER no vale: ThingsBoard no deja a un usuario de cliente
    consultar relaciones que salen de su propio cliente y los alias quedan vacios.)
    Estados: default (mapa, consumo como en Datadis, socios, energia diaria y, para el
    administrador, sincronizacion con Datadis e informes) y socio
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
    # Solo lo ve el administrador: los socios no se quedan en esta vista (w_redirige_socio)
    # y el widget se oculta si el usuario no es administrador
    add("default", w_admin(0, 42, 24, 11))
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
        # La fija el widget de consumo (periodo elegido); hasta entonces, los ultimos 30 dias
        "timewindow": {"selectedTab": 0, "timezone": E.get("TZ", "Europe/Madrid"),
                       "realtime": {"realtimeType": 0, "timewindowMs": 30 * 86400000, "interval": 86400000},
                       "aggregation": {"type": "NONE", "limit": 50000}},
        "settings": {"stateControllerId": "entity", "showTitle": True,
                     "showDashboardsSelect": False, "showEntitiesSelect": False,
                     "showDashboardTimewindow": False, "showDashboardExport": False,
                     "toolbarAlwaysOpen": True, "dashboardCss": CSS_PANEL},
    }


def cec_panel(title, cfg, firma):
    """Crea o actualiza el panel (se conserva su id: los usuarios lo tienen por defecto)."""
    cfg["cecFirma"] = firma
    paneles = tb.get(page("/api/tenant/dashboards"))["data"]
    d = find(paneles, "title", title)
    if not d:   # la comunidad ha cambiado de nombre (CEC_NOMBRE): se renombra su panel
        d = next((x for x in paneles if "cecFirma" in (tb.get(f"/api/dashboard/{x['id']['id']}")
                                                        .get("configuration") or {})), None)
    if d:
        full = tb.get(f"/api/dashboard/{d['id']['id']}")
        if full["title"] == title and (full.get("configuration") or {}).get("cecFirma") == firma:
            return full
        if full["title"] != title:
            print(f"    panel '{full['title']}' renombrado a '{title}'")
        full["title"], full["configuration"] = title, cfg
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
    usuarios = sa.get(page(f"/api/tenant/{tid}/users"))["data"]
    u = find(usuarios, "email", email)
    viejo = find(usuarios, "email", E["CEC_ADMIN_ANTERIOR_EMAIL"])
    if not u and viejo and E["CEC_ADMIN_ANTERIOR_EMAIL"] != email:
        # El de versiones anteriores pasa a las credenciales nuevas (conserva su id y relaciones)
        u = sa.get(f"/api/user/{viejo['id']['id']}")
        u["email"] = email
        u = sa.post("/api/user?sendActivationMail=false", u)
        print(f"    administrador de la comunidad '{E['CEC_ADMIN_ANTERIOR_EMAIL']}' renombrado a '{email}'")
    if u:
        # Contraseña: se cambia si aun es la anterior (ThingsBoard CE solo deja cambiarla con la actual)
        if not tb_login(email, E["CEC_ADMIN_PASSWORD"]):
            tb_password(email, E["CEC_ADMIN_ANTERIOR_PASSWORD"], E["CEC_ADMIN_PASSWORD"])
        u = sa.get(f"/api/user/{u['id']['id']}")
        if u.get("lastName") != CEC:   # la comunidad ha cambiado de nombre
            u["lastName"] = CEC
            u = sa.post("/api/user?sendActivationMail=false", u)
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


# Socios: cliente y dispositivo (su energia, CUPS, contrato... los pone la API al sincronizar)
cec_dispositivo("comunidad", "comunidad", CEC)
for so in SOCIOS:
    cust = find(customers, "title", so["nombre"])
    if not cust:
        cust = tb.post("/api/customer", {"title": so["nombre"]})
        print(f"    socio '{so['nombre']}' creado")
    so["cid"] = cust["id"]["id"]
    attrs = {}
    if so["lat"] is not None:
        attrs.update(latitude=so["lat"], longitude=so["lon"])
    cec_dispositivo(so["id"], "socio", so["nombre"], so["cid"], attrs)
cec_widget("VatiaCo.consumo", "Consumo (como Datadis)", CONSUMO_HTML, CONSUMO_JS, 15, CONSUMO_CSS)
cec_widget("VatiaCo.tabla_periodo", "Energía del periodo", TABLA_HTML, TABLA_JS, 9, TABLA_CSS, tipo="timeseries")
cec_widget("VatiaCo.socios", "Socios", SOCIOS_HTML, SOCIOS_JS, 7, SOCIOS_CSS, recursos=[])
cec_widget("VatiaCo.admin_datos", "Administración de datos", ADMIN_HTML, ADMIN_JS, 11, ADMIN_CSS,
           tipo="static", recursos=[])

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
PY

# Datos de la comunidad: la API relee los CSV de DATADIS_DIR (solo carga lo que ha
# cambiado) y los pasa a PostgreSQL y ThingsBoard. Las curvas nuevas llegan despues con la
# sincronizacion diaria (SYNC_HORA) o con el boton del panel del administrador.
echo "==> Cargando los datos de Datadis con la API de la comunidad..."
INICIO=$(date +%s)
until curl -skf -o /dev/null https://localhost/cec-api/salud; do
  if [ $(( $(date +%s) - INICIO )) -ge 300 ]; then
    echo "ERROR: la API de la comunidad no responde. Ultimas lineas del log:" >&2
    docker logs --tail 40 iot-fastapi 2>&1 | sed 's/^/    /' >&2
    exit 1
  fi
  sleep 3
done
./sync.sh csv || echo "    AVISO: la carga ha terminado con errores (se puede repetir con ./sync.sh csv)"

echo "==> Exportando ThingsBoard a $INSTALL_DIR/export"
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
| MQTT de ThingsBoard (TLS) | mqtts://${TB_DOMAIN:-$IP}:$MQTTS_PORT | usuario = token del dispositivo, sin contraseña |
| API de la comunidad (FastAPI) | https://$IP/cec-api/docs | token de administrador de ThingsBoard o cabecera \`X-Api-Key\` (FASTAPI_API_KEY de .env) |
| PostgreSQL | postgres:5432 (solo red interna) | $PG_USER / $PG_PASSWORD |
| Adminer (tools, tunel SSH) | http://127.0.0.1:$ADMINER_PORT/?pgsql=postgres&username=$PG_USER&db=thingsboard | sistema **PostgreSQL** (no MySQL) · $PG_USER / $PG_PASSWORD |
| Homepage (portada de servicios) | http://$IP:$HOMEPAGE_PORT | — |
| Web Astro (proman) | http://$IP:$PROMAN_PORT | — (recompilar: \`./web.sh\`) |

Solo se publican 80/443 (Caddy) y $MQTTS_PORT (MQTT con TLS de ThingsBoard). Adminer escucha
en 127.0.0.1; desde otro equipo:

\`\`\`bash
ssh -L $ADMINER_PORT:127.0.0.1:$ADMINER_PORT $USER@$IP
./tools.sh up      # arranca Adminer (./tools.sh down para pararlo)
\`\`\`

## Comunidad energética

Los datos de energía de cada socio son los de Datadis. La API de la comunidad (FastAPI,
contenedor \`iot-fastapi\`, código en \`config/fastapi\`) los guarda en PostgreSQL
(base \`cec\`: la fuente de verdad) y los copia a ThingsBoard con el instante original de
cada lectura. Solo la ubicación del mapa es ficticia.

- Primera carga de cada socio: descarga web de Datadis en \`$DATADIS_DIR/<carpeta>\`
  (\`Consumo_*.csv\`, \`Contrato_*.csv\`, \`Potencias_*.csv\`): da su CUPS, contrato y maxímetro.
- Sincronización diaria a las $SYNC_HORA (dentro de la API): con credenciales de Datadis
  (\`DATADIS_USER\`...) pide a su API las curvas del mes anterior y el actual de los CUPS de
  los socios; sin ellas relee los CSV. Solo envía a ThingsBoard los días que cambian.
- A mano: \`./sync.sh\` (automático), \`./sync.sh csv\` o \`./sync.sh datadis 2026/01 2026/03 [forzar]\`.
- Panel del administrador de la comunidad, al pie: botón *Actualizar ahora*, recarga de un
  rango de meses, progreso y registro de cada sincronización, datos cargados por socio e
  informes de la comunidad o de un socio: PDF (Typst) con los mismos gráficos que el panel,
  Excel o CSV con los datos diarios.
- En ThingsBoard, cada socio (dispositivo tipo \`socio\`) tiene \`consumo_kwh\`, \`vertida_kwh\`,
  \`generada_kwh\` y \`autoconsumo_kwh\` por periodo de medida, los totales diarios \`d_*\` y,
  como atributos, CUPS, peaje y potencia. \`comunidad\` es la suma horaria de todos.
- Socio nuevo: añádelo a SOCIOS en iot-thingsboard.sh con su carpeta y sus coordenadas.

API (https://$IP/cec-api/docs, mismo origen que ThingsBoard):

| Método | Ruta | |
|---|---|---|
| POST | \`/cec-api/sync\` | lanza una sincronización: 202 y \`job_id\` (409 si ya hay una en curso) |
| GET | \`/cec-api/sync/{job_id}\` | estado: pendiente, en_curso, ok, con_errores, error; avance y registro |
| GET | \`/cec-api/estado\` | datos cargados por socio, próxima sincronización, simuladores |
| GET | \`/cec-api/informes/comunidad?desde=&hasta=&formato=pdf\|xlsx\|csv\` | informe de la comunidad |
| GET | \`/cec-api/informes/socio/{id}?desde=&hasta=&formato=\` | informe de un socio |

## Carpetas

| Carpeta | Contenido |
|---|---|
| \`config/\` | certificado MQTT (\`mqtt-certs\`), Caddyfile, código y config.json de la API (\`config/fastapi\`) |
| \`data/postgres\` | bases de datos de ThingsBoard y de la comunidad (\`cec\`) |
| \`data/thingsboard\`, \`data/thingsboard-logs\` | datos y logs de ThingsBoard |
| \`data/caddy\` | certificados HTTPS |
| \`backups/postgres\` | copia diaria de PostgreSQL (pg_dump, 7 dias) |
| \`export/\` | JSON de tenants, clientes, usuarios, dispositivos, paneles, y reglas de ThingsBoard (\`./export.sh\`) |

Copia de las bases de datos (thingsboard y cec): diaria en \`backups/postgres\` (servicio pg-backup). Restaurar:
\`docker compose exec -T postgres pg_restore -U $PG_USER -d <thingsboard|cec> --clean < backups/postgres/<fichero>.dump\`

Copia completa: \`./stop.sh && sudo tar czf iot-tb-backup.tgz -C ~ iot-tb && ./start.sh\`

Enviar datos de un dispositivo: créalo en ThingsBoard (Entidades > Dispositivos) y copia su
token de acceso. Por MQTT con TLS (puerto $MQTTS_PORT; con certificado autofirmado hay que
añadir \`--insecure\`):

\`\`\`bash
mosquitto_pub -h ${TB_DOMAIN:-$IP} -p $MQTTS_PORT --capath /etc/ssl/certs -u <TOKEN_DISPOSITIVO> \\
  -t v1/devices/me/telemetry -m '{"temperatura": 21.5}'
\`\`\`

\`\`\`python
# pip install paho-mqtt
import json, ssl, paho.mqtt.client as mqtt
c = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2)
c.tls_set(cert_reqs=ssl.CERT_REQUIRED)
c.username_pw_set("<TOKEN_DISPOSITIVO>")
c.connect("${TB_DOMAIN:-$IP}", $MQTTS_PORT)
c.loop_start()
c.publish("v1/devices/me/telemetry", json.dumps({"temperatura": 19.4}), qos=1).wait_for_publish()
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
[ -n "$TB_DOMAIN" ] && echo " MQTT WAN          : mqtts://$TB_DOMAIN:$MQTTS_PORT  (router: $MQTTS_PORT TCP -> $SERVE_IP)"
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
echo " API comunidad     : https://$IP/cec-api/docs  (sincronizacion diaria $SYNC_HORA, ./sync.sh a mano)"
if [ -n "$DATADIS_USER" ]; then echo "   origen diario: API de Datadis ($DATADIS_USER)"; else echo "   origen diario: CSV de $DATADIS_DIR (sin credenciales de Datadis)"; fi
for c in "${CLIENTES[@]}"; do
  IFS='|' read -r n e pw d pa pf <<< "$c"
  echo "   simulador '$d' ($pf) -> iot/$d/telemetry cada ${SIM_INTERVAL}s"
done
echo "   comunidad: ${#SOCIOS[@]} socios con datos de Datadis ($DATADIS_DIR)"
echo " MQTT TLS          : mqtts://${TB_DOMAIN:-$IP}:$MQTTS_PORT  (ThingsBoard; usuario = token del dispositivo)"
echo " Homepage          : http://$IP:$HOMEPAGE_PORT   (portada de los servicios del servidor)"
echo " Web Astro (proman): http://$IP:$PROMAN_PORT   (de $PROMAN_DIR; recompilar con ./web.sh)"
echo " Herramientas      : ./tools.sh up   (Adminer, solo 127.0.0.1)"
echo "   Adminer (BD)    : http://127.0.0.1:$ADMINER_PORT/?pgsql=postgres&username=$PG_USER&db=thingsboard"
echo "   desde otro equipo: ssh -L $ADMINER_PORT:127.0.0.1:$ADMINER_PORT $USER@$IP"
echo " Copias PostgreSQL : $INSTALL_DIR/backups/postgres  (thingsboard y cec, diarias, 7 dias)"
echo " Carpeta           : $INSTALL_DIR  (README.md con ejemplos)"
echo "   config/  ficheros de configuracion    data/  datos de cada contenedor"
echo "   export/  JSON de ThingsBoard (actualizar con ./export.sh)"
echo
docker compose ps
