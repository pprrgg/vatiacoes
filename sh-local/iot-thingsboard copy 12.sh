#!/usr/bin/env bash
set -euo pipefail

# ============================================
# Setup stack IoT con ThingsBoard - pkserver
#
#   PostgreSQL  -> bases de datos de ThingsBoard y de la comunidad ("cec") (solo red interna)
#   ThingsBoard -> plataforma IoT (web + MQTT de dispositivos: 8883 con TLS hacia fuera,
#                  cada dispositivo con su token)
#   Adminer     -> GUI web de PostgreSQL       (127.0.0.1)
#   FastAPI     -> API de las comunidades (codigo en este script, paso 4; https://<servidor>/cec-api;
#                  una para todas: cada comunidad con su tenant y su base cec_<id>):
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
# administrador tiene ademas la pestaña Datadis (sincronizacion e informes) y la gestion.
CEC_ID="demo"                        # identificador de la comunidad (su base es "cec")
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

# Superusuario de la plataforma: crea comunidades nuevas con su gestor desde su panel
# (tenant "Plataforma", solo ve ese panel). Los administradores del tenant de cada
# comunidad nueva son api@<id>.$HOSTNAME_LAN.local (contraseña TB_TENANT_PASSWORD).
SUPER_EMAIL="super@vatiaco.es"
SUPER_PASSWORD="super"

# Segunda comunidad energetica (Demo2), aislada de la primera: su propio tenant de
# ThingsBoard (con su administrador, que usa la API) y su base PostgreSQL (cec_$CEC2_ID).
# Mismo panel, pestañas y gestion que la primera. Socios con el formato de SOCIOS.
# Las comunidades del script son las de partida: el superusuario crea mas desde su panel y
# cada gestor da de alta a sus participantes (pestaña Participantes).
CEC2_ID="demo2"
CEC2_NOMBRE="Comunidad Energética Demo2"
CEC2_TENANT_EMAIL="api@$CEC2_ID.$HOSTNAME_LAN.local"        # administrador del tenant (contraseña TB_TENANT_PASSWORD)
CEC2_ADMIN_EMAIL="demo2@vatiaco.es"                          # gestor de la comunidad
CEC2_ADMIN_PASSWORD="demo2"
# Viviendas 2.0TD con FV y recarga de vehiculo electrico (datos simulados: py/datadis_sintetico.py)
SOCIOS2=(
  "Marta Sánchez|marta@$CEC2_ID.$HOSTNAME_LAN.local|marta|sim_20td_fv_ve_noche|37.17950|-3.59920"
  "Javier Ortega|javier@$CEC2_ID.$HOSTNAME_LAN.local|javier|sim_20td_fv_ve_solar|37.18310|-3.60480"
  "Lucía Navarro|lucia@$CEC2_ID.$HOSTNAME_LAN.local|lucia|sim_20td_fv_ve_tarde|37.17620|-3.60650"
)

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
# Copias de PostgreSQL: las escriben pg-backup (root) y la API (uid 10001, pestaña Base de datos)
docker run --rm -v "$INSTALL_DIR/backups:/b" alpine chmod 0777 /b/postgres
# CSV de Datadis que suben los gestores (pestaña Participantes): los escribe la API
mkdir -p "$INSTALL_DIR/data/subidas"
docker run --rm -v "$INSTALL_DIR/data:/d" alpine chown 10001 /d/subidas

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
PG_MAJOR=${PG_VERSION%%.*}
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
SUPER_EMAIL=$SUPER_EMAIL
TB_LANG=$TB_LANG
TENANT_DOMINIO=$HOSTNAME_LAN.local
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
#   app/gestion.py   gestion de la comunidad: registros de cada area y documentos PDF
#   app/copias.py    copias de seguridad de PostgreSQL (hacer, subir, descargar, restaurar)
rm -rf config/fastapi/app
mkdir -p config/fastapi/app
cat > config/fastapi/Dockerfile <<'__FASTAPI_EOF__'
# API de la comunidad energetica (iot-thingsboard.sh). Solo dependencias: el codigo
# (app/) se monta en /srv/app, asi que un cambio de codigo solo pide reiniciar.
ARG PY_VERSION=3.12-slim
FROM python:${PY_VERSION}
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /srv
# Fuentes de los informes PDF (Typst y graficos SVG): Roboto, la del panel; y pg_dump /
# pg_restore de la misma version mayor que el servidor (repositorio de PostgreSQL)
ARG PG_MAJOR=16
RUN apt-get update && apt-get install -y --no-install-recommends fonts-roboto-unhinted fonts-dejavu-core \
       curl ca-certificates \
    && install -d /usr/share/postgresql-common/pgdg \
    && curl -fsSo /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc https://www.postgresql.org/media/keys/ACCC4CF8.asc \
    && . /etc/os-release \
    && echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt $VERSION_CODENAME-pgdg main" \
       > /etc/apt/sources.list.d/pgdg.list \
    && apt-get update && apt-get install -y --no-install-recommends postgresql-client-$PG_MAJOR \
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
"""Configuracion comun: entorno (.env del stack), config.json (lo genera iot-thingsboard.sh)
y la comunidad de la peticion en curso.

Una sola API para todas las comunidades: cada una tiene su tenant de ThingsBoard y su base
PostgreSQL (registro en la base "plataforma", app/plataforma.py). La comunidad de cada
peticion (la del tenant del usuario que llama) va en la variable de contexto COMUNIDAD;
db.conectar(), config() y cec.tb() trabajan siempre con ella. asyncio.to_thread y las
tareas copian el contexto, asi que los hilos de una peticion ven su comunidad."""
import contextvars
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


# Comunidad en curso: fila del registro (id, nombre, base, tenant_email, tenant_id...)
COMUNIDAD = contextvars.ContextVar("comunidad", default=None)


def plataforma():
    """config.json: gateway y clientes simulados, comunidades de partida del script... Se lee
    en cada uso: el script de instalacion puede regenerarlo sin reiniciar el contenedor."""
    return json.loads(CONFIG.read_text(encoding="utf-8"))


def comunidad():
    c = COMUNIDAD.get()
    if c is None:
        raise RuntimeError("no hay ninguna comunidad en el contexto")
    return c


def config():
    """La comunidad en curso: nombre y socios (tabla socio de su base)."""
    from . import db
    c = comunidad()
    return {"id": c["id"], "cec": c["nombre"], "socios": db.socios(),
            "datos_version": int(plataforma().get("datos_version", 1))}


def datadis_configurado():
    return bool(E.get("DATADIS_USER") and E.get("DATADIS_PASS"))
__FASTAPI_EOF__

cat > config/fastapi/app/db.py <<'__FASTAPI_EOF__'
"""PostgreSQL (una base por comunidad: cec, cec_demo2...): fuente de verdad de los socios,
las lecturas y el registro de las sincronizaciones. ThingsBoard solo recibe una copia para
sus paneles. conectar() abre la base de la comunidad en curso (comun.COMUNIDAD)."""
import time
import uuid

import psycopg
from psycopg.rows import dict_row
from psycopg.types.json import Jsonb

from .comun import E, comunidad, log


def dsn(base):
    return (f"host={E.get('PGHOST', 'postgres')} port={E.get('PGPORT', '5432')} "
            f"dbname={base} user={E['PGUSER']} password={E['PGPASSWORD']} options='-c TimeZone=UTC'")


ESQUEMA = """
-- Participantes de la comunidad (los da de alta el gestor desde el panel o vienen de
-- SOCIOS del script). id = nombre sin acentos, en minusculas y con guiones (el del
-- dispositivo de ThingsBoard). Datos de Datadis: por la API (cups; nif del titular si no
-- es la cuenta de Datadis de la plataforma) o ficheros CSV de la descarga web (carpeta).
CREATE TABLE IF NOT EXISTS socio (
  id      text PRIMARY KEY,
  nombre  text NOT NULL,
  email   text,
  cups    text,
  nif     text,
  carpeta text,
  lat     double precision,
  lon     double precision,
  alta    timestamptz NOT NULL DEFAULT now(),
  por     text
);

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


def conectar(autocommit=True, base=None):
    """Base de la comunidad en curso (o la indicada)."""
    return psycopg.connect(dsn(base or comunidad()["base"]), row_factory=dict_row, autocommit=autocommit)


def socios():
    with conectar() as cx:
        return cx.execute("SELECT id, nombre, email, cups, nif, carpeta, lat, lon, alta FROM socio "
                          "ORDER BY alta, nombre").fetchall()


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
de un tenant (por defecto el de la primera comunidad, TB_TENANT_EMAIL)."""
import threading

import requests

from .comun import E

LOTE = 5000   # filas de telemetria por peticion


class TB:
    def __init__(self, email=None, password=None):
        self.email = email or E["TB_TENANT_EMAIL"]
        self.password = password or E["TB_TENANT_PASSWORD"]
        self.url = E.get("TB_URL", "http://thingsboard:8080").rstrip("/")
        self.s = requests.Session()
        self.tok = None
        self._tenant = None
        self._lk = threading.Lock()

    def _login(self):
        r = requests.post(self.url + "/api/auth/login", timeout=30,
                          json={"username": self.email, "password": self.password})
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
from .comun import COMUNIDAD, DATADIS_DIR, E, TZL, config, datadis_configurado, log
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

_TBS = {}   # email del administrador del tenant -> cliente


def tb():
    """ThingsBoard del tenant de la comunidad en curso."""
    c = COMUNIDAD.get()
    email = c["tenant_email"] if c else E["TB_TENANT_EMAIL"]
    if email not in _TBS:
        _TBS[email] = TB(email)
    return _TBS[email]


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
        nota(f"AVISO {so['nombre']}: sin ficheros CSV de Datadis" +
             (f" en {DATADIS_DIR / so['carpeta']}" if so.get("carpeta") else " (súbelos en Participantes)"))
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


def _suministro_api(cx, so, sup):
    """Primer alta de un socio dado de alta solo con su CUPS: el suministro sale de la lista
    de Datadis (sin el contrato completo, que da la descarga web en Contrato_*.csv)."""
    tipo = str(sup.get("pointType") or "")
    c = {"cups": sup["cups"], "distribuidora": sup.get("distributor") or "", "provincia": sup.get("province") or "",
         "municipio": sup.get("municipality") or "", "codigoPostal": sup.get("postalCode") or "",
         "fechaInicioVigencia": sup.get("validDateFrom") or "", "tipoPunto": tipo}
    cx.execute("""INSERT INTO suministro (cups, socio, peaje, paso_min, contrato, firma, actualizado)
                  VALUES (%s, %s, %s, %s, %s, %s, now()) ON CONFLICT (cups) DO UPDATE SET socio = EXCLUDED.socio""",
               (sup["cups"], so["id"], "2.0TD" if tipo in ("4", "5") else "3.0TD", 15 if tipo in ("1", "2") else 60,
                db.Jsonb(c), "api"))
    return suministro_de(cx, so["id"])


def ingesta_datadis(cx, api, mapa, so, desde, hasta, forzar, nota):
    """API de Datadis (meses desde..hasta, AAAA/MM) -> PostgreSQL. El CUPS de cada socio es
    el de su suministro en PostgreSQL (lo da la primera carga de sus CSV) o, si aun no lo
    tiene, el que puso el gestor al darlo de alta."""
    s = suministro_de(cx, so["id"])
    if not s and so.get("carpeta"):        # primero sus CSV (dan el contrato completo)
        ingesta_csv(cx, so, forzar, nota)
        s = suministro_de(cx, so["id"])
    cups = s["cups"] if s else (so.get("cups") or "").strip().upper()
    if not cups:
        nota(f"AVISO {so['nombre']}: sin CUPS (ponlo en Participantes o sube sus CSV de Datadis)")
        return None
    if cups not in mapa:
        nota(f"AVISO {so['nombre']}: el CUPS {cups} no está entre los suministros accesibles en Datadis "
             "(falta la autorización del titular o su NIF)")
        return None
    sup, nif = mapa[cups]
    if not s:
        s = _suministro_api(cx, so, sup)
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
        nifs += [so["nif"].strip().upper() for so in socios if (so.get("nif") or "").strip()]
        mapa = api.mapa_cups(list(dict.fromkeys(nifs)))
        nota(f"Datadis: {len(mapa)} suministros accesibles")

    hechos = errores = 0
    rangos = []
    with db.conectar() as cx:
        for so in socios:
            try:
                if origen == "csv" and not so.get("carpeta"):
                    nota(f"{so['nombre']}: sin ficheros CSV (sus datos llegan por la API de Datadis)")
                    r = None
                elif origen == "csv":
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

cat > config/fastapi/app/gestion.py <<'__FASTAPI_EOF__'
"""Gestion de la comunidad energetica: registros de cada area (PostgreSQL, tabla "registro")
y documentos PDF (Typst, A4 vertical, estructura de documento tecnico) que se archivan en
la tabla "documento". Un panel de ThingsBoard por area (widget VatiaCo.gestion).

Areas: gobernanza, tecnica, reparto, economica, tramites, participacion, rgpd. AREAS define
sus registros (campos) y DOCS sus documentos (parametros y funcion que los genera)."""
import json
import math
import re
import tempfile
import unicodedata
import uuid
from datetime import date, datetime, timedelta
from pathlib import Path

from psycopg.types.json import Jsonb

from . import cec, db
from .comun import TZL, config, log
from .graficos import es

ESQUEMA_SQL = """
CREATE TABLE IF NOT EXISTS registro (
  id          uuid PRIMARY KEY,
  area        text NOT NULL,
  tipo        text NOT NULL,
  datos       jsonb NOT NULL DEFAULT '{}',
  creado      timestamptz NOT NULL DEFAULT now(),
  actualizado timestamptz NOT NULL DEFAULT now(),
  por         text
);
CREATE INDEX IF NOT EXISTS registro_tipo ON registro (area, tipo);
-- Archivo de los documentos generados (control documental: codigo, fecha, autor)
CREATE TABLE IF NOT EXISTS documento (
  id         uuid PRIMARY KEY,
  area       text NOT NULL,
  tipo       text NOT NULL,
  titulo     text NOT NULL,
  codigo     text,
  parametros jsonb NOT NULL DEFAULT '{}',
  creado     timestamptz NOT NULL DEFAULT now(),
  por        text,
  pdf        bytea NOT NULL
);
CREATE INDEX IF NOT EXISTS documento_area ON documento (area, creado DESC);
"""


# ======================= esquema de las areas =======================
def C(id, etiqueta, tipo="texto", opciones=None, req=False, lista=True):
    """Campo de un registro. tipo: texto, largo, fecha, numero, importe, si_no, opcion, socio.
    lista: se muestra como columna en la tabla del panel."""
    return {"id": id, "etiqueta": etiqueta, "tipo": tipo, "opciones": opciones or [], "req": req, "lista": lista}


ESTADO_TRAMITE = ["pendiente", "solicitado", "en tramitación", "concedido", "denegado", "caducado"]

AREAS = {
    "gobernanza": {
        "titulo": "Gobernanza y gestión societaria", "icono": "account_balance",
        "descripcion": "Entidad jurídica, libro de socios, asambleas y juntas, reglamento interno.",
        "registros": {
            "entidad": {"titulo": "Entidad", "unico": True, "campos": [
                C("nombre", "Denominación", req=True), C("forma", "Forma jurídica", "opcion",
                  ["Asociación", "Cooperativa", "Sociedad limitada", "Otra"]), C("nif", "NIF"),
                C("domicilio", "Domicilio social"), C("registro", "Registro e inscripción", lista=False),
                C("constitucion", "Fecha de constitución", "fecha"), C("email", "Correo de contacto", lista=False),
                C("radio_km", "Radio de proximidad (km)", "numero", lista=False),
                C("presidencia", "Presidencia"), C("secretaria", "Secretaría"), C("tesoreria", "Tesorería", lista=False)]},
            "socios": {"titulo": "Libro de socios", "orden": "nombre", "campos": [
                C("nombre", "Nombre o razón social", req=True), C("socio_id", "Suministro en el panel", "socio"),
                C("nif", "NIF"), C("tipo", "Tipo", "opcion", ["Persona física", "Persona jurídica", "Pyme",
                                                              "Administración local", "Otra"]),
                C("email", "Correo", lista=False), C("telefono", "Teléfono", lista=False),
                C("direccion", "Dirección", lista=False), C("distancia_km", "Distancia a la instalación (km)", "numero"),
                C("alta", "Fecha de alta", "fecha"), C("baja", "Fecha de baja", "fecha"),
                C("cuota_entrada", "Cuota de entrada", "importe"), C("cuota_pagada", "Cuota pagada", "si_no"),
                C("votos", "Votos", "numero"), C("notas", "Notas", "largo", lista=False)]},
            "reuniones": {"titulo": "Asambleas y juntas", "orden": "-fecha", "campos": [
                C("organo", "Órgano", "opcion", ["Asamblea general ordinaria", "Asamblea general extraordinaria",
                                                 "Junta directiva", "Consejo rector"], req=True),
                C("fecha", "Fecha", "fecha", req=True), C("hora", "Hora"), C("lugar", "Lugar"),
                C("estado", "Estado", "opcion", ["Prevista", "Convocada", "Celebrada", "Anulada"]),
                C("orden_dia", "Orden del día (un punto por línea)", "largo", lista=False),
                C("asistentes", "Asistentes (uno por línea)", "largo", lista=False),
                C("acuerdos", "Acuerdos (uno por línea)", "largo", lista=False),
                C("votaciones", "Votaciones y observaciones", "largo", lista=False)]},
            "reglamento": {"titulo": "Reglamento interno", "orden": "numero", "campos": [
                C("numero", "Artículo", "numero", req=True), C("titulo", "Título", req=True),
                C("capitulo", "Capítulo", "opcion", ["Disposiciones generales", "Socios", "Reparto de la energía",
                                                     "Régimen económico", "Régimen disciplinario",
                                                     "Resolución de conflictos", "Otras"]),
                C("texto", "Texto", "largo", req=True, lista=False), C("vigente", "Vigente desde", "fecha")]},
        }},
    "tecnica": {
        "titulo": "Gestión técnica de la instalación", "icono": "solar_power",
        "descripcion": "Producción, equipos, mantenimiento, seguros, garantías y ampliaciones.",
        "registros": {
            "equipos": {"titulo": "Equipos", "orden": "tipo", "campos": [
                C("tipo", "Tipo", "opcion", ["Módulos FV", "Inversor", "Batería", "Contador", "Estructura",
                                             "Protecciones", "Monitorización", "Punto de recarga", "Otro"], req=True),
                C("marca", "Marca y modelo"), C("serie", "Nº de serie", lista=False), C("cantidad", "Cantidad", "numero"),
                C("potencia_kw", "Potencia (kW / kWh)", "numero"), C("instalacion", "Fecha de instalación", "fecha"),
                C("garantia", "Garantía hasta", "fecha"), C("ubicacion", "Ubicación", lista=False),
                C("notas", "Notas", "largo", lista=False)]},
            "mantenimiento": {"titulo": "Mantenimiento", "orden": "-fecha", "campos": [
                C("fecha", "Fecha", "fecha", req=True), C("tipo", "Tipo", "opcion",
                  ["Preventivo", "Correctivo", "Revisión obligatoria", "Limpieza", "Inspección"], req=True),
                C("equipo", "Equipo"), C("empresa", "Empresa"), C("descripcion", "Descripción", "largo"),
                C("coste", "Coste", "importe"), C("estado", "Estado", "opcion", ["Planificado", "Hecho", "Pendiente de repuesto"]),
                C("proxima", "Próxima actuación", "fecha")]},
            "seguros": {"titulo": "Seguros y garantías", "orden": "hasta", "campos": [
                C("tipo", "Tipo", "opcion", ["Seguro de daños", "Responsabilidad civil", "Garantía de equipo",
                                             "Garantía de producción", "Contrato de mantenimiento"], req=True),
                C("entidad", "Entidad"), C("poliza", "Póliza o contrato"), C("cobertura", "Cobertura", "largo", lista=False),
                C("desde", "Desde", "fecha"), C("hasta", "Hasta", "fecha"), C("importe", "Prima o coste anual", "importe")]},
            "proyectos": {"titulo": "Ampliaciones y nuevos servicios", "orden": "-prevista", "campos": [
                C("titulo", "Proyecto", req=True), C("tipo", "Tipo", "opcion",
                  ["Ampliación FV", "Almacenamiento", "Recarga de vehículos", "Eficiencia energética", "Otro"]),
                C("estado", "Estado", "opcion", ["Idea", "Estudio", "Aprobado", "En ejecución", "Terminado", "Descartado"]),
                C("presupuesto", "Presupuesto", "importe"), C("prevista", "Fecha prevista", "fecha"),
                C("descripcion", "Descripción", "largo", lista=False)]},
        }},
    "reparto": {
        "titulo": "Reparto de la energía (autoconsumo colectivo)", "icono": "share",
        "descripcion": "Coeficientes de reparto, acuerdos con la distribuidora y verificación de la compensación en factura.",
        "registros": {
            "acuerdos": {"titulo": "Acuerdos de reparto", "orden": "-fecha", "campos": [
                C("fecha", "Fecha del acuerdo", "fecha", req=True), C("modo", "Coeficientes", "opcion", ["Fijos", "Variables por horas"]),
                C("criterio", "Criterio", "opcion", ["Consumo", "Igualitario", "Potencia contratada", "Aportación"]),
                C("base_desde", "Base desde", "fecha", lista=False), C("base_hasta", "Base hasta", "fecha", lista=False),
                C("estado", "Estado", "opcion", ["Borrador", "Firmado", "Enviado a la distribuidora", "Aceptado", "Rechazado"]),
                C("comunicado", "Comunicado a la distribuidora", "fecha"), C("notas", "Notas", "largo", lista=False)]},
            "verificaciones": {"titulo": "Verificación de facturas", "orden": "-mes", "campos": [
                C("socio_id", "Socio", "socio", req=True), C("mes", "Mes facturado (día 1)", "fecha", req=True),
                C("compensada", "Energía compensada en factura (kWh)", "numero", req=True),
                C("comercializadora", "Comercializadora"), C("notas", "Notas", "largo", lista=False)]},
        }},
    "economica": {
        "titulo": "Gestión económica y fiscal", "icono": "euro",
        "descripcion": "Contabilidad, presupuestos, cuotas, financiación, IVA y excedentes.",
        "registros": {
            "movimientos": {"titulo": "Ingresos y gastos", "orden": "-fecha", "campos": [
                C("fecha", "Fecha", "fecha", req=True), C("tipo", "Tipo", "opcion", ["Ingreso", "Gasto"], req=True),
                C("categoria", "Partida", "opcion", ["Cuotas", "Venta de excedentes", "Subvenciones", "Préstamos",
                                                     "Aportaciones de socios", "Mantenimiento", "Seguros", "Energía",
                                                     "Gestoría y asesoría", "Impuestos", "Inversión", "Otros"], req=True),
                C("concepto", "Concepto", req=True), C("tercero", "Proveedor o socio"), C("factura", "Nº factura", lista=False),
                C("base", "Base imponible", "importe", req=True), C("iva", "IVA (%)", "numero"),
                C("pagado", "Cobrado o pagado", "si_no")]},
            "presupuesto": {"titulo": "Presupuesto", "orden": "-anio", "campos": [
                C("anio", "Año", "numero", req=True), C("tipo", "Tipo", "opcion", ["Ingreso", "Gasto"], req=True),
                C("categoria", "Partida", req=True), C("importe", "Importe previsto", "importe", req=True)]},
            "cuotas": {"titulo": "Cuotas", "orden": "-periodo", "campos": [
                C("socio_id", "Socio", "socio", req=True), C("periodo", "Periodo (día 1 del mes)", "fecha", req=True),
                C("concepto", "Concepto", "opcion", ["Cuota de entrada", "Cuota periódica", "Derrama"]),
                C("importe", "Importe", "importe", req=True), C("pagada", "Pagada", "si_no"), C("fecha_pago", "Fecha de pago", "fecha")]},
            "financiacion": {"titulo": "Financiación y subvenciones", "orden": "-fecha", "campos": [
                C("tipo", "Tipo", "opcion", ["Subvención", "Préstamo", "Aportación de socios", "Otra"], req=True),
                C("entidad", "Entidad o programa", req=True), C("importe", "Importe", "importe"),
                C("fecha", "Fecha de solicitud", "fecha"), C("estado", "Estado", "opcion",
                  ["Prevista", "Solicitada", "Concedida", "Cobrada", "Justificada", "Denegada"]),
                C("justificacion", "Fecha límite de justificación", "fecha"), C("notas", "Notas", "largo", lista=False)]},
        }},
    "tramites": {
        "titulo": "Trámites administrativos y regulatorios", "icono": "gavel",
        "descripcion": "Permisos, registros de autoconsumo y de comunidades energéticas, seguimiento normativo.",
        "registros": {
            "permisos": {"titulo": "Permisos y registros", "orden": "-solicitud", "campos": [
                C("tipo", "Trámite", "opcion", ["Licencia municipal de obra", "Legalización ante la comunidad autónoma",
                                                "Permiso de acceso y conexión", "Registro de autoconsumo (RADNE/CCAA)",
                                                "Registro de comunidades energéticas", "CAU / alta en la distribuidora",
                                                "Otro"], req=True),
                C("organismo", "Organismo"), C("expediente", "Nº de expediente"), C("solicitud", "Solicitud", "fecha"),
                C("resolucion", "Resolución", "fecha"), C("estado", "Estado", "opcion", ESTADO_TRAMITE),
                C("caducidad", "Caducidad o renovación", "fecha"), C("notas", "Notas", "largo", lista=False)]},
            "normativa": {"titulo": "Seguimiento normativo", "orden": "-fecha", "campos": [
                C("referencia", "Referencia", req=True), C("titulo", "Título"), C("fecha", "Fecha", "fecha"),
                C("ambito", "Ámbito", "opcion", ["Europeo", "Estatal", "Autonómico", "Local"]),
                C("impacto", "Impacto para la comunidad", "largo", lista=False), C("accion", "Acción requerida"),
                C("estado", "Estado", "opcion", ["Pendiente de análisis", "Sin impacto", "Acción pendiente", "Aplicada"])]},
        }},
    "participacion": {
        "titulo": "Participación, comunicación y dimensión social", "icono": "groups",
        "descripcion": "Información a socios, captación, objetivos sociales y relaciones institucionales.",
        "registros": {
            "comunicaciones": {"titulo": "Comunicaciones", "orden": "-fecha", "campos": [
                C("fecha", "Fecha", "fecha", req=True), C("canal", "Canal", "opcion",
                  ["Correo", "Boletín", "Reunión", "Web", "Mensajería", "Carta"]),
                C("asunto", "Asunto", req=True), C("destinatarios", "Destinatarios"), C("contenido", "Contenido", "largo", lista=False)]},
            "actividades": {"titulo": "Actividades", "orden": "-fecha", "campos": [
                C("fecha", "Fecha", "fecha", req=True), C("tipo", "Tipo", "opcion",
                  ["Formación", "Sensibilización", "Captación de socios", "Jornada abierta", "Visita a la instalación", "Otra"]),
                C("titulo", "Título", req=True), C("participantes", "Participantes", "numero"),
                C("descripcion", "Descripción", "largo", lista=False)]},
            "vulnerables": {"titulo": "Hogares vulnerables", "orden": "-desde", "campos": [
                C("socio_id", "Socio", "socio", req=True), C("criterio", "Criterio", "opcion",
                  ["Bono social", "Informe de servicios sociales", "Ingresos", "Otro"]),
                C("apoyo", "Apoyo", "largo"), C("desde", "Desde", "fecha"), C("hasta", "Hasta", "fecha")]},
            "relaciones": {"titulo": "Relaciones institucionales", "orden": "-fecha", "campos": [
                C("fecha", "Fecha", "fecha", req=True), C("entidad", "Entidad", req=True), C("tipo", "Tipo", "opcion",
                  ["Ayuntamiento", "Otra comunidad energética", "Red o federación", "Administración", "Empresa", "Otra"]),
                C("asunto", "Asunto"), C("resultado", "Resultado", "largo", lista=False)]},
        }},
    "rgpd": {
        "titulo": "Protección de datos (RGPD)", "icono": "privacy_tip",
        "descripcion": "Registro de actividades de tratamiento, consentimientos, derechos e incidencias.",
        "registros": {
            "tratamientos": {"titulo": "Actividades de tratamiento", "orden": "actividad", "campos": [
                C("actividad", "Actividad", req=True), C("finalidad", "Finalidad", "largo"),
                C("base", "Base jurídica", "opcion", ["Consentimiento (art. 6.1.a)", "Contrato o relación societaria (art. 6.1.b)",
                                                      "Obligación legal (art. 6.1.c)", "Interés legítimo (art. 6.1.f)"]),
                C("datos", "Categorías de datos", "largo", lista=False), C("interesados", "Interesados", lista=False),
                C("destinatarios", "Destinatarios", "largo", lista=False), C("conservacion", "Plazo de conservación"),
                C("medidas", "Medidas de seguridad", "largo", lista=False)]},
            "consentimientos": {"titulo": "Consentimientos y autorizaciones", "orden": "-fecha", "campos": [
                C("socio_id", "Socio", "socio", req=True), C("fecha", "Fecha", "fecha", req=True),
                C("datadis", "Autoriza el acceso a sus datos en Datadis", "si_no"),
                C("comunicaciones", "Acepta comunicaciones", "si_no"), C("imagen", "Cesión de imagen", "si_no"),
                C("revocado", "Revocado el", "fecha"), C("notas", "Notas", "largo", lista=False)]},
            "derechos": {"titulo": "Solicitudes de derechos", "orden": "-fecha", "campos": [
                C("fecha", "Recibida", "fecha", req=True), C("interesado", "Interesado", req=True),
                C("derecho", "Derecho", "opcion", ["Acceso", "Rectificación", "Supresión", "Oposición",
                                                   "Limitación", "Portabilidad"], req=True),
                C("respuesta", "Respondida", "fecha"), C("estado", "Estado", "opcion", ["Abierta", "Respondida", "Denegada"]),
                C("notas", "Notas", "largo", lista=False)]},
            "brechas": {"titulo": "Incidencias y brechas", "orden": "-fecha", "campos": [
                C("fecha", "Detectada", "fecha", req=True), C("descripcion", "Descripción", "largo", req=True),
                C("afectados", "Afectados", "numero"), C("riesgo", "Riesgo", "opcion", ["Bajo", "Medio", "Alto"]),
                C("aepd", "Notificada a la AEPD", "si_no"), C("medidas", "Medidas adoptadas", "largo", lista=False)]},
        }},
}


# ======================= registros =======================
def _campos(area, tipo):
    try:
        return AREAS[area]["registros"][tipo]["campos"]
    except KeyError:
        raise KeyError(f"{area}/{tipo}")


def _limpiar(area, tipo, datos):
    """Valida y normaliza un registro segun su esquema; ValueError con el motivo."""
    socios = {so["id"] for so in config()["socios"]}
    out = {}
    for c in _campos(area, tipo):
        v = datos.get(c["id"])
        if isinstance(v, str):
            v = v.strip()
        if v in (None, ""):
            if c["req"]:
                raise ValueError(f"Falta «{c['etiqueta']}»")
            continue
        t = c["tipo"]
        try:
            if t == "fecha":
                v = date.fromisoformat(str(v)[:10]).isoformat()
            elif t in ("numero", "importe"):
                v = float(str(v).replace(",", "."))
                if not math.isfinite(v):
                    raise ValueError
            elif t == "si_no":
                v = v is True or str(v).lower() in ("true", "1", "si", "sí")
            elif t == "opcion" and v not in c["opciones"]:
                raise ValueError
            elif t == "socio" and v not in socios:
                raise ValueError
            elif t in ("texto", "largo"):
                v = str(v)[:20000]
        except ValueError:
            raise ValueError(f"Valor no válido en «{c['etiqueta']}»")
        out[c["id"]] = v
    return out


def _uuid(x):
    """Id de registro o documento; KeyError (404) si no tiene formato de UUID."""
    try:
        return str(uuid.UUID(str(x)))
    except ValueError:
        raise KeyError(x)


def _fila(r):
    return {"id": str(r["id"]), **r["datos"], "_creado": r["creado"], "_actualizado": r["actualizado"], "_por": r["por"]}


def listar(cx, area, tipo):
    _campos(area, tipo)
    filas = cx.execute("SELECT * FROM registro WHERE area = %s AND tipo = %s ORDER BY creado", (area, tipo)).fetchall()
    orden = AREAS[area]["registros"][tipo].get("orden")
    out = [_fila(r) for r in filas]
    if orden:
        k, inv = orden.lstrip("-"), orden.startswith("-")
        con = sorted([x for x in out if x.get(k) not in (None, "")], key=lambda x: x[k], reverse=inv)
        out = con + [x for x in out if x.get(k) in (None, "")]
    return out


def guardar(area, tipo, datos, por, rid=None):
    limpio = _limpiar(area, tipo, datos)
    with db.conectar() as cx:
        if rid:
            rid = _uuid(rid)
            n = cx.execute("UPDATE registro SET datos = %s, actualizado = now(), por = %s WHERE id = %s AND area = %s "
                           "AND tipo = %s", (Jsonb(limpio), por, rid, area, tipo)).rowcount
            if not n:
                raise KeyError(rid)
            return rid
        if AREAS[area]["registros"][tipo].get("unico") and \
                cx.execute("SELECT 1 FROM registro WHERE area = %s AND tipo = %s", (area, tipo)).fetchone():
            raise ValueError("Este registro es único: edita el existente")
        rid = str(uuid.uuid4())
        cx.execute("INSERT INTO registro (id, area, tipo, datos, por) VALUES (%s, %s, %s, %s, %s)",
                   (rid, area, tipo, Jsonb(limpio), por))
        return rid


def borrar(area, tipo, rid):
    rid = _uuid(rid)
    with db.conectar() as cx:
        if not cx.execute("DELETE FROM registro WHERE id = %s AND area = %s AND tipo = %s", (rid, area, tipo)).rowcount:
            raise KeyError(rid)


def _uno(cx, area, tipo):
    r = cx.execute("SELECT * FROM registro WHERE area = %s AND tipo = %s ORDER BY creado LIMIT 1", (area, tipo)).fetchone()
    return _fila(r) if r else {}


# ======================= datos iniciales =======================
REGLAMENTO = [
    (1, "Objeto", "Disposiciones generales",
     "Este reglamento desarrolla los estatutos de la entidad y regula el funcionamiento de la comunidad energética, "
     "el reparto de la energía entre sus socios y los derechos y obligaciones de estos."),
    (2, "Admisión de socios", "Socios",
     "Podrán ser socios las personas físicas, pymes y entidades locales situadas en las proximidades de la "
     "instalación que lo soliciten por escrito, abonen la cuota de entrada y acepten los estatutos y este reglamento. "
     "La junta directiva resolverá las solicitudes en el plazo de un mes."),
    (3, "Baja de socios", "Socios",
     "La baja voluntaria se comunicará por escrito con un preaviso mínimo de un mes. La baja implica la salida del "
     "acuerdo de reparto en la siguiente actualización de coeficientes comunicada a la distribuidora."),
    (4, "Criterios de reparto", "Reparto de la energía",
     "La energía generada se repartirá mediante coeficientes de reparto conforme al Real Decreto 244/2019. Salvo "
     "acuerdo distinto de la asamblea, los coeficientes serán proporcionales al consumo de cada socio en los doce "
     "meses anteriores y se revisarán al menos una vez al año o cuando se produzca un alta o una baja."),
    (5, "Cuotas", "Régimen económico",
     "La asamblea fijará la cuota de entrada y las cuotas periódicas. El impago de dos cuotas consecutivas dará lugar "
     "a requerimiento por escrito."),
    (6, "Infracciones y sanciones", "Régimen disciplinario",
     "Se consideran infracciones el impago reiterado de cuotas, el uso indebido de la instalación y el incumplimiento "
     "grave de los acuerdos de la asamblea. Las sanciones irán desde el apercibimiento hasta la baja forzosa, previa "
     "audiencia de la persona interesada."),
    (7, "Resolución de conflictos", "Resolución de conflictos",
     "Los conflictos entre socios o con la entidad se intentarán resolver primero mediante mediación de la junta "
     "directiva. De no alcanzarse acuerdo, se someterán a la asamblea general y, en su caso, a arbitraje."),
]

TRATAMIENTOS = [
    {"actividad": "Gestión de socios", "finalidad": "Llevar el libro de socios, convocar asambleas y gestionar cuotas.",
     "base": "Contrato o relación societaria (art. 6.1.b)", "datos": "Identificativos, contacto, NIF, datos bancarios.",
     "interesados": "Socios", "destinatarios": "Entidad bancaria para el cobro de cuotas; Administración tributaria.",
     "conservacion": "Mientras dure la condición de socio y los plazos legales posteriores",
     "medidas": "Acceso restringido a la junta directiva; copias de seguridad cifradas."},
    {"actividad": "Datos de consumo energético", "finalidad": "Calcular los coeficientes de reparto, verificar la "
     "compensación y elaborar informes a partir de las curvas de carga de Datadis.",
     "base": "Consentimiento (art. 6.1.a)", "datos": "CUPS, curvas de carga, potencias, datos de contrato.",
     "interesados": "Socios participantes en el autoconsumo colectivo",
     "destinatarios": "Distribuidora (coeficientes de reparto); no se ceden a terceros.",
     "conservacion": "Mientras dure la participación y 4 años después",
     "medidas": "Servidor propio, acceso con usuario y contraseña, cada socio solo ve sus datos."},
    {"actividad": "Comunicaciones a socios", "finalidad": "Enviar boletines, convocatorias e información de la comunidad.",
     "base": "Consentimiento (art. 6.1.a)", "datos": "Nombre y contacto.", "interesados": "Socios y personas interesadas",
     "destinatarios": "Ninguno", "conservacion": "Hasta la retirada del consentimiento",
     "medidas": "Listas de distribución con copia oculta."},
]


def preparar():
    """Tablas y datos iniciales: socios del libro a partir de los del panel, reglamento tipo y
    registro de actividades de tratamiento (solo si estan vacios)."""
    cfg = config()
    with db.conectar() as cx:
        cx.execute(ESQUEMA_SQL)
        ya = {r["datos"].get("socio_id") for r in cx.execute(
            "SELECT datos FROM registro WHERE area = 'gobernanza' AND tipo = 'socios'").fetchall()}
        for so in cfg["socios"]:
            if so["id"] not in ya:
                cx.execute("INSERT INTO registro (id, area, tipo, datos, por) VALUES (%s, 'gobernanza', 'socios', %s, 'inicial')",
                           (str(uuid.uuid4()), Jsonb({"nombre": so["nombre"], "socio_id": so["id"], "votos": 1.0,
                                                      "tipo": "Persona física"})))
        vacio = lambda a, t: not cx.execute("SELECT 1 FROM registro WHERE area = %s AND tipo = %s", (a, t)).fetchone()
        if vacio("gobernanza", "entidad"):
            cx.execute("INSERT INTO registro (id, area, tipo, datos, por) VALUES (%s, 'gobernanza', 'entidad', %s, 'inicial')",
                       (str(uuid.uuid4()), Jsonb({"nombre": cfg["cec"], "forma": "Asociación", "radio_km": 5.0})))
        if vacio("gobernanza", "reglamento"):
            for n, t, cap, txt in REGLAMENTO:
                cx.execute("INSERT INTO registro (id, area, tipo, datos, por) VALUES (%s, 'gobernanza', 'reglamento', %s, 'inicial')",
                           (str(uuid.uuid4()), Jsonb({"numero": float(n), "titulo": t, "capitulo": cap, "texto": txt})))
        if vacio("rgpd", "tratamientos"):
            for t in TRATAMIENTOS:
                cx.execute("INSERT INTO registro (id, area, tipo, datos, por) VALUES (%s, 'rgpd', 'tratamientos', %s, 'inicial')",
                           (str(uuid.uuid4()), Jsonb(t)))


# ======================= utilidades de los documentos =======================
def fd(s):
    """Fecha ISO -> dd/mm/aaaa."""
    if not s:
        return "–"
    try:
        return date.fromisoformat(str(s)[:10]).strftime("%d/%m/%Y")
    except ValueError:
        return str(s)


def eur(x):
    return "–" if x is None else es(x) + " €"


def P(*textos):
    return [{"p": t} for t in textos if t]


def L(items, numerada=True):
    return {"lista": [str(i) for i in items], "numerada": numerada}


def T(caption, cab, filas, texto=1, total=False, nota=None):
    if not filas:   # sin filas no se pinta una tabla vacia
        return P(f"{caption}: no hay registros.")
    return {"tabla": {"cabecera": cab, "filas": [["–" if v in (None, "") else str(v) for v in f] for f in filas],
                      "texto": texto, "total": total and bool(filas)}, "caption": caption, "nota": nota}


def KV(caption, pares):
    """Tabla concepto/valor (las dos columnas alineadas a la izquierda)."""
    return T(caption, ["Concepto", "Valor"], [[k, v] for k, v in pares], texto=2)


def S(titulo, *bloques):
    out = []
    for b in bloques:
        out += b if isinstance(b, list) else [b]
    return {"titulo": titulo, "bloques": out}


def lineas(t):
    return [x.strip(" -·*\t") for x in (t or "").splitlines() if x.strip(" -·*\t")]


def _socios_nombres():
    return {so["id"]: so["nombre"] for so in config()["socios"]}


def _en(fecha, d0, d1):
    return fecha and d0 <= str(fecha)[:10] <= d1


def _hoy():
    return datetime.now(TZL).date()


def _cups_activos(cx):
    """Socios habilitados con datos: [(socio, suministro)]."""
    fuera = cec.deshabilitados(cx)
    return [(so, s) for so in config()["socios"] if so["id"] not in fuera and (s := cec.suministro_de(cx, so["id"]))]


def _energia(cx, cups, d0, d1, por_cups=False):
    """Energia por mes (y por CUPS) entre dos fechas ISO (locales, d1 incluida)."""
    t0 = datetime.fromisoformat(d0).replace(tzinfo=TZL)
    t1 = datetime.fromisoformat(d1).replace(tzinfo=TZL) + timedelta(days=1)
    g = "cups, " if por_cups else ""
    return cx.execute(
        f"SELECT {g}date_trunc('month', ts AT TIME ZONE %s)::date AS mes, coalesce(sum(consumo_kwh), 0) AS consumo, "
        "coalesce(sum(vertida_kwh), 0) AS vertida, coalesce(sum(generada_kwh), 0) AS generada, "
        "coalesce(sum(autoconsumo_kwh), 0) AS autoconsumo FROM lectura "
        f"WHERE cups = ANY(%s) AND ts >= %s AND ts < %s GROUP BY {g}mes ORDER BY {g}mes",
        (str(TZL), list(cups), t0, t1)).fetchall()


def _sumar(filas, k):
    return sum(f[k] or 0 for f in filas)


# ---------------- coeficientes de reparto ----------------
def _redondear_6(pesos):
    """Coeficientes con 6 decimales que suman exactamente 1 (mayor resto)."""
    tot = sum(pesos.values())
    if tot <= 0:
        pesos = {k: 1.0 for k in pesos}
        tot = float(len(pesos))
    base = {k: math.floor(v / tot * 1e6) for k, v in pesos.items()}
    resto = 1_000_000 - sum(base.values())
    for k in sorted(pesos, key=lambda k: pesos[k] / tot * 1e6 - base[k], reverse=True)[:resto]:
        base[k] += 1
    return {k: v / 1e6 for k, v in base.items()}


def coeficientes(cx, d0, d1, criterio):
    """[(socio, suministro, base, coeficiente)] de los socios habilitados."""
    act = _cups_activos(cx)
    if criterio == "Igualitario":
        pesos = {so["id"]: 1.0 for so, _ in act}
        base = {so["id"]: 1.0 for so, _ in act}
    elif criterio == "Potencia contratada":
        base = {}
        for so, s in act:
            pot = [cec._num(x) for x in ((s["contrato"] or {}).get("potenciaContratadakW") or "").split(";")]
            base[so["id"]] = max([x for x in pot if x is not None] or [0.0])
        pesos = dict(base)
    else:   # Consumo (consumo total = red + autoconsumo) en el periodo base
        e = {r["cups"]: r for r in _energia_total(cx, [s["cups"] for _, s in act], d0, d1)}
        base = {so["id"]: (e[s["cups"]]["consumo"] + e[s["cups"]]["autoconsumo"]) if s["cups"] in e else 0.0
                for so, s in act}
        pesos = dict(base)
    co = _redondear_6(pesos) if pesos else {}
    return [(so, s, base[so["id"]], co[so["id"]]) for so, s in act]


def _energia_total(cx, cups, d0, d1):
    t0 = datetime.fromisoformat(d0).replace(tzinfo=TZL)
    t1 = datetime.fromisoformat(d1).replace(tzinfo=TZL) + timedelta(days=1)
    return cx.execute("SELECT cups, coalesce(sum(consumo_kwh), 0) AS consumo, coalesce(sum(autoconsumo_kwh), 0) AS autoconsumo, "
                      "coalesce(sum(vertida_kwh), 0) AS vertida FROM lectura WHERE cups = ANY(%s) AND ts >= %s AND ts < %s "
                      "GROUP BY cups", (list(cups), t0, t1)).fetchall()


def fichero_coeficientes(d0, d1, criterio, modo):
    """Fichero de texto para la distribuidora: fijos "CUPS;coeficiente" o variables por horas
    "CUPS;aaaa-mm-dd hh;coeficiente" (horas locales del periodo base). Conviene confirmar con
    la distribuidora el formato exacto que pide."""
    with db.conectar() as cx:
        if modo != "Variables por horas":
            return "".join(f"{s['cups']};{c:.6f}".replace(".", ",") + "\n" for so, s, b, c in coeficientes(cx, d0, d1, criterio))
        act = _cups_activos(cx)
        t0 = datetime.fromisoformat(d0).replace(tzinfo=TZL)
        t1 = datetime.fromisoformat(d1).replace(tzinfo=TZL) + timedelta(days=1)
        filas = cx.execute("SELECT cups, (date_trunc('hour', ts AT TIME ZONE %s)) AS h, sum(coalesce(consumo_kwh, 0) + "
                           "coalesce(autoconsumo_kwh, 0)) AS e FROM lectura WHERE cups = ANY(%s) AND ts >= %s AND ts < %s "
                           "GROUP BY 1, 2", (str(TZL), [s["cups"] for _, s in act], t0, t1)).fetchall()
    H = {}
    for f in filas:
        H.setdefault(f["h"], {})[f["cups"]] = f["e"] or 0.0
    out = []
    for h in sorted(H):
        co = _redondear_6({s["cups"]: H[h].get(s["cups"], 0.0) for _, s in act})
        out += [f"{cups};{h:%Y-%m-%d %H};{c:.6f}".replace(".", ",") + "\n" for cups, c in co.items()]
    return "".join(out)


# ======================= documentos =======================
def _p(id, etiqueta, tipo, defecto=None, opciones=None, registro=None):
    """Parametro de un documento: periodo (desde/hasta), anio, trimestre, opcion, numero, registro."""
    return {"id": id, "etiqueta": etiqueta, "tipo": tipo, "defecto": defecto, "opciones": opciones or [],
            "registro": registro}


def _anterior_mes():
    fin = _hoy().replace(day=1) - timedelta(days=1)
    return fin.replace(day=1).isoformat(), fin.isoformat()


def _doce_meses():
    fin = _hoy().replace(day=1) - timedelta(days=1)
    ini = (fin.replace(day=1) - timedelta(days=330)).replace(day=1)
    return ini.isoformat(), fin.isoformat()


def _periodo(p):
    d0, d1 = p.get("desde"), p.get("hasta")
    if not d0 or not d1 or d0 > d1:
        raise ValueError("Indica un periodo válido")
    return d0, d1


def _reg(cx, area, tipo, rid):
    try:
        rid = _uuid(rid) if rid else None
    except KeyError:
        rid = None
    r = cx.execute("SELECT * FROM registro WHERE id = %s AND area = %s AND tipo = %s", (rid, area, tipo)).fetchone() if rid else None
    if not r:
        raise ValueError("Elige el registro del documento")
    return _fila(r)


# ---------------- 1. gobernanza ----------------
def doc_libro_socios(cx, p):
    ent = _uno(cx, "gobernanza", "entidad")
    socios = listar(cx, "gobernanza", "socios")
    alta = [s for s in socios if not s.get("baja")]
    bajas = [s for s in socios if s.get("baja")]
    radio = ent.get("radio_km")
    votos = sum(s.get("votos") or 0 for s in alta)
    cerca = [s for s in alta if radio is not None and s.get("distancia_km") is not None and s["distancia_km"] <= radio]
    v_cerca = sum(s.get("votos") or 0 for s in cerca)
    sin_dist = [s["nombre"] for s in alta if s.get("distancia_km") is None]
    return {"titulo": "Libro de registro de socios", "secciones": [
        S("Datos de la entidad", KV("Datos de la entidad", [
            ("Denominación", ent.get("nombre")), ("Forma jurídica", ent.get("forma")), ("NIF", ent.get("nif")),
            ("Domicilio social", ent.get("domicilio")), ("Registro", ent.get("registro")),
            ("Fecha de constitución", fd(ent.get("constitucion"))), ("Presidencia", ent.get("presidencia")),
            ("Secretaría", ent.get("secretaria"))])),
        S("Socios en alta", T("Socios en alta", ["Nº", "Nombre", "NIF", "Tipo", "Alta", "Distancia (km)", "Votos", "Cuota de entrada", "Pagada"],
                              [[i + 1, s["nombre"], s.get("nif"), s.get("tipo"), fd(s.get("alta")), es(s.get("distancia_km"), 1) if s.get("distancia_km") is not None else "–",
                                es(s.get("votos") or 0, 0), eur(s.get("cuota_entrada")), "sí" if s.get("cuota_pagada") else "no"]
                               for i, s in enumerate(alta)], texto=4)),
        S("Bajas", T("Socios dados de baja", ["Nombre", "NIF", "Alta", "Baja"],
                     [[s["nombre"], s.get("nif"), fd(s.get("alta")), fd(s.get("baja"))] for s in bajas], texto=2)
          if bajas else P("No hay bajas registradas.")),
        S("Derechos de voto y control efectivo", P(
            f"Hay {len(alta)} socios en alta con {es(votos, 0)} votos. "
            + (f"Los socios situados a {es(radio, 1)} km o menos de la instalación suman {es(v_cerca, 0)} votos "
               f"({es(100 * v_cerca / votos, 1) if votos else '0'} %), " if radio is not None else "")
            + ("lo que asegura su control efectivo de la entidad." if votos and v_cerca / votos > 0.5 else
               "por lo que conviene revisar la composición para garantizar el control efectivo por socios próximos."
               if radio is not None else ""),
            f"Sin distancia registrada: {', '.join(sin_dist)}." if sin_dist else "")),
    ]}


def doc_convocatoria(cx, p):
    r = _reg(cx, "gobernanza", "reuniones", p.get("registro"))
    ent = _uno(cx, "gobernanza", "entidad")
    od = lineas(r.get("orden_dia")) or ["(orden del día pendiente)"]
    segunda = p.get("segunda") or "media hora después"
    return {"titulo": f"Convocatoria de {r['organo'].lower()}", "subtitulo": fd(r.get("fecha")), "secciones": [
        S("Convocatoria", P(
            f"Por acuerdo de la junta directiva de {ent.get('nombre') or config()['cec']}, se convoca a "
            f"{'todos los socios' if 'Asamblea' in r['organo'] else 'sus miembros'} a la {r['organo'].lower()} que se "
            f"celebrará el {fd(r.get('fecha'))}{' a las ' + r['hora'] if r.get('hora') else ''}"
            f"{' en ' + r['lugar'] if r.get('lugar') else ''}, en primera convocatoria, y {segunda} en segunda, "
            "con el siguiente")),
        S("Orden del día", L(od)),
        S("Información a los socios", P(
            "La documentación relativa a los puntos del orden del día está a disposición de los socios en el domicilio "
            "social y puede solicitarse por correo. Los socios que no puedan asistir pueden delegar su voto por escrito en "
            "otro socio, de acuerdo con los estatutos.")),
    ], "firmas": [f"Presidencia{': ' + ent['presidencia'] if ent.get('presidencia') else ''}",
                  f"Secretaría{': ' + ent['secretaria'] if ent.get('secretaria') else ''}"]}


def doc_acta(cx, p):
    r = _reg(cx, "gobernanza", "reuniones", p.get("registro"))
    ent = _uno(cx, "gobernanza", "entidad")
    asis = lineas(r.get("asistentes"))
    socios = [s for s in listar(cx, "gobernanza", "socios") if not s.get("baja")]
    votos = sum(s.get("votos") or 0 for s in socios)
    nombres = {s["nombre"].lower(): s.get("votos") or 0 for s in socios}
    v_asis = sum(nombres.get(a.lower(), 0) for a in asis)
    acuerdos = lineas(r.get("acuerdos"))
    return {"titulo": f"Acta de {r['organo'].lower()}", "subtitulo": fd(r.get("fecha")), "secciones": [
        S("Datos de la sesión", KV("Datos de la sesión", [
            ("Órgano", r["organo"]), ("Fecha", fd(r.get("fecha"))), ("Hora", r.get("hora")), ("Lugar", r.get("lugar")),
            ("Asistentes", f"{len(asis)}" + (f" ({es(v_asis, 0)} de {es(votos, 0)} votos, {es(100 * v_asis / votos, 1)} %)"
                                             if votos and v_asis else ""))])),
        S("Asistentes", L(asis, False) if asis else P("No se han registrado los asistentes.")),
        S("Orden del día", L(lineas(r.get("orden_dia")) or ["–"])),
        S("Acuerdos adoptados", L([f"{a}" for a in acuerdos]) if acuerdos else P("No se adoptaron acuerdos.")),
        S("Votaciones y observaciones", P(r.get("votaciones") or "Sin observaciones.")),
        S("Cierre", P(f"Sin más asuntos que tratar, se levanta la sesión, de la que se extiende la presente acta, que "
                      f"firman la secretaría con el visto bueno de la presidencia de {ent.get('nombre') or config()['cec']}.")),
    ], "firmas": [f"Vº Bº Presidencia{': ' + ent['presidencia'] if ent.get('presidencia') else ''}",
                  f"Secretaría{': ' + ent['secretaria'] if ent.get('secretaria') else ''}"]}


def doc_reglamento(cx, p):
    arts = [a for a in listar(cx, "gobernanza", "reglamento")]
    caps, out = [], {}
    for a in arts:
        c = a.get("capitulo") or "Otras"
        if c not in out:
            caps.append(c)
            out[c] = []
        out[c].append(a)
    vig = max((a.get("vigente") or "" for a in arts), default="")
    return {"titulo": "Reglamento interno", "subtitulo": f"Versión vigente desde {fd(vig)}" if vig else None,
            "secciones": [S(c, *[P(f"**Artículo {int(a['numero'])}. {a['titulo']}.** {a['texto']}") for a in out[c]])
                          for c in caps]}


# ---------------- 2. tecnica ----------------
def _alertas_vencimiento(cx, dias=90):
    hoy, lim = _hoy().isoformat(), (_hoy() + timedelta(days=dias)).isoformat()
    out = []
    for e in listar(cx, "tecnica", "equipos"):
        if e.get("garantia") and e["garantia"] <= lim:
            out.append(["Garantía de equipo", f"{e['tipo']} {e.get('marca') or ''}".strip(), fd(e["garantia"]),
                        "vencida" if e["garantia"] < hoy else "vence pronto"])
    for s in listar(cx, "tecnica", "seguros"):
        if s.get("hasta") and s["hasta"] <= lim:
            out.append([s["tipo"], f"{s.get('entidad') or ''} {s.get('poliza') or ''}".strip(), fd(s["hasta"]),
                        "vencido" if s["hasta"] < hoy else "vence pronto"])
    return out


def doc_produccion(cx, p):
    d0, d1 = _periodo(p)
    act = _cups_activos(cx)
    filas = _energia(cx, [s["cups"] for _, s in act], d0, d1)
    gen_socios = [(so, s) for so, s in act]
    por = {r["cups"]: r for r in _energia_total(cx, [s["cups"] for _, s in gen_socios], d0, d1)}
    mant = [m for m in listar(cx, "tecnica", "mantenimiento") if _en(m.get("fecha"), d0, d1)]
    prox = [m for m in listar(cx, "tecnica", "mantenimiento") if m.get("proxima") and m["proxima"] >= _hoy().isoformat()]
    G, A, V = _sumar(filas, "generada"), _sumar(filas, "autoconsumo"), _sumar(filas, "vertida")
    return {"titulo": "Informe técnico de producción", "subtitulo": f"{fd(d0)} – {fd(d1)}", "secciones": [
        S("Resumen", P(f"En el periodo, las instalaciones fotovoltaicas de los socios generaron {es(G)} kWh: "
                       f"{es(A)} kWh se autoconsumieron ({es(100 * A / G, 1) if G else '0'} %) y {es(V)} kWh se vertieron "
                       "a la red."), KV("Producción del periodo", [
            ("Generación fotovoltaica", es(G) + " kWh"), ("Autoconsumo", es(A) + " kWh"), ("Excedentes", es(V) + " kWh"),
            ("Tasa de autoconsumo", (es(100 * A / G, 1) + " %") if G else "–")])),
        S("Producción mensual", T("Producción mensual", ["Mes", "Generación (kWh)", "Autoconsumo (kWh)", "Excedentes (kWh)"],
                                  [[f"{r['mes']:%m/%Y}", es(r["generada"]), es(r["autoconsumo"]), es(r["vertida"])] for r in filas]
                                  + [["Total", es(G), es(A), es(V)]], total=True)),
        S("Producción por suministro", T("Producción por suministro", ["Socio", "Excedentes (kWh)", "Autoconsumo (kWh)"],
              [[so["nombre"], es(por[s["cups"]]["vertida"]), es(por[s["cups"]]["autoconsumo"])]
               for so, s in gen_socios if s["cups"] in por and (por[s["cups"]]["vertida"] or por[s["cups"]]["autoconsumo"])],
              nota="Solo los suministros con generación en el periodo.")),
        S("Equipos instalados", T("Inventario de equipos", ["Tipo", "Marca y modelo", "Cantidad", "Potencia", "Instalación", "Garantía"],
              [[e["tipo"], e.get("marca"), es(e.get("cantidad") or 0, 0), es(e["potencia_kw"], 2) if e.get("potencia_kw") is not None else "–",
                fd(e.get("instalacion")), fd(e.get("garantia"))] for e in listar(cx, "tecnica", "equipos")], texto=2)),
        S("Mantenimiento del periodo", T("Actuaciones del periodo", ["Fecha", "Tipo", "Equipo", "Empresa", "Coste", "Estado"],
              [[fd(m["fecha"]), m["tipo"], m.get("equipo"), m.get("empresa"), eur(m.get("coste")), m.get("estado")] for m in mant], texto=4)
          if mant else P("No hay actuaciones de mantenimiento registradas en el periodo.")),
        S("Próximas actuaciones y vencimientos",
          T("Próximas actuaciones", ["Fecha", "Tipo", "Equipo", "Empresa"],
            [[fd(m["proxima"]), m["tipo"], m.get("equipo"), m.get("empresa")] for m in sorted(prox, key=lambda m: m["proxima"])], texto=4)
          if prox else P("No hay actuaciones programadas."),
          T("Garantías y seguros vencidos o que vencen en 90 días", ["Tipo", "Equipo o póliza", "Fecha", "Situación"],
            _alertas_vencimiento(cx), texto=4) if _alertas_vencimiento(cx) else P("No hay garantías ni seguros por vencer.")),
    ]}


def doc_mantenimiento(cx, p):
    anio = int(p.get("anio") or _hoy().year)
    d0, d1 = f"{anio}-01-01", f"{anio}-12-31"
    todos = listar(cx, "tecnica", "mantenimiento")
    del_anio = [m for m in todos if _en(m.get("fecha"), d0, d1) or _en(m.get("proxima"), d0, d1)]
    plan = sorted([m for m in del_anio if m.get("estado") != "Hecho" or _en(m.get("proxima"), d0, d1)],
                  key=lambda m: m.get("proxima") or m.get("fecha") or "")
    hechos = [m for m in todos if _en(m.get("fecha"), d0, d1) and m.get("estado") == "Hecho"]
    costes = {}
    for m in hechos:
        costes[m["tipo"]] = costes.get(m["tipo"], 0) + (m.get("coste") or 0)
    return {"titulo": "Plan de mantenimiento", "subtitulo": str(anio), "secciones": [
        S("Actuaciones previstas", T("Actuaciones previstas", ["Fecha", "Tipo", "Equipo", "Empresa", "Descripción"],
              [[fd(m.get("proxima") or m.get("fecha")), m["tipo"], m.get("equipo"), m.get("empresa"), m.get("descripcion")]
               for m in plan], texto=5) if plan else P("No hay actuaciones previstas.")),
        S("Actuaciones realizadas", T("Actuaciones realizadas", ["Fecha", "Tipo", "Equipo", "Empresa", "Coste"],
              [[fd(m["fecha"]), m["tipo"], m.get("equipo"), m.get("empresa"), eur(m.get("coste"))] for m in hechos]
              + [["Total", "", "", "", eur(sum(costes.values()))]], texto=4, total=True) if hechos else P("Ninguna en el año.")),
        S("Coste por tipo", T("Coste de mantenimiento por tipo", ["Tipo", "Coste"], [[k, eur(v)] for k, v in sorted(costes.items())])
          if costes else P("Sin costes registrados.")),
    ]}


def doc_inventario(cx, p):
    return {"titulo": "Inventario, garantías y seguros", "secciones": [
        S("Equipos", T("Inventario de equipos", ["Tipo", "Marca y modelo", "Nº serie", "Cantidad", "Potencia", "Ubicación", "Garantía"],
              [[e["tipo"], e.get("marca"), e.get("serie"), es(e.get("cantidad") or 0, 0),
                es(e["potencia_kw"], 2) if e.get("potencia_kw") is not None else "–", e.get("ubicacion"), fd(e.get("garantia"))]
               for e in listar(cx, "tecnica", "equipos")], texto=3)),
        S("Seguros, garantías y contratos", T("Seguros, garantías y contratos", ["Tipo", "Entidad", "Póliza", "Desde", "Hasta", "Importe"],
              [[s["tipo"], s.get("entidad"), s.get("poliza"), fd(s.get("desde")), fd(s.get("hasta")), eur(s.get("importe"))]
               for s in listar(cx, "tecnica", "seguros")], texto=3)),
        S("Vencimientos", T("Vencidos o que vencen en 90 días", ["Tipo", "Equipo o póliza", "Fecha", "Situación"],
                            _alertas_vencimiento(cx), texto=4) if _alertas_vencimiento(cx) else P("Nada vencido ni por vencer en 90 días.")),
    ]}


def doc_ampliaciones(cx, p):
    pr = listar(cx, "tecnica", "proyectos")
    vivos = [x for x in pr if x.get("estado") not in ("Terminado", "Descartado")]
    return {"titulo": "Plan de ampliaciones y nuevos servicios", "secciones": [
        S("Cartera de proyectos", T("Proyectos", ["Proyecto", "Tipo", "Estado", "Fecha prevista", "Presupuesto"],
              [[x["titulo"], x.get("tipo"), x.get("estado"), fd(x.get("prevista")), eur(x.get("presupuesto"))] for x in pr]
              + [["Total en curso o previsto", "", "", "", eur(sum(x.get("presupuesto") or 0 for x in vivos))]], texto=4, total=True)),
        S("Descripción", *[P(f"**{x['titulo']}** ({x.get('estado') or 'sin estado'}). {x.get('descripcion') or ''}") for x in pr]
          or P("No hay proyectos registrados.")),
    ]}


# ---------------- 3. reparto ----------------
def _coef_tabla(co, criterio):
    unidad = {"Consumo": "kWh", "Potencia contratada": "kW"}.get(criterio, "")
    return T("Coeficientes de reparto", ["Socio", "CUPS", f"Base{' (' + unidad + ')' if unidad else ''}", "Coeficiente β", "%"],
             [[so["nombre"], s["cups"], es(b, 2) if unidad else "1", f"{c:.6f}".replace(".", ","), es(100 * c, 4)] for so, s, b, c in co]
             + [["Total", "", "", f"{sum(c for *_, c in co):.6f}".replace(".", ","), es(100 * sum(c for *_, c in co), 4)]],
             texto=2, total=True)


METODO_COEF = {
    "Consumo": "Cada coeficiente es la proporción del consumo total (consumo de red más autoconsumo) del socio en el "
               "periodo base respecto a la suma de todos los participantes.",
    "Igualitario": "Todos los participantes reciben el mismo coeficiente.",
    "Potencia contratada": "Cada coeficiente es proporcional a la mayor potencia contratada del suministro.",
}


def doc_propuesta_coef(cx, p):
    d0, d1 = _periodo(p)
    crit = p.get("criterio") or "Consumo"
    co = coeficientes(cx, d0, d1, crit)
    fuera = [n for i, n in _socios_nombres().items() if i in cec.deshabilitados(cx)]
    return {"titulo": "Propuesta de coeficientes de reparto", "subtitulo": f"Criterio: {crit.lower()}", "secciones": [
        S("Método", P(METODO_COEF.get(crit, ""),
                      f"Periodo base: {fd(d0)} – {fd(d1)}. Participan {len(co)} suministros"
                      + (f"; no participan los socios deshabilitados ({', '.join(fuera)})" if fuera else "") + ".",
                      "Los coeficientes se expresan con seis decimales y su suma es exactamente 1, como exige el Real "
                      "Decreto 244/2019. Si se acuerdan coeficientes variables por horas, el fichero horario se descarga "
                      "desde el panel de reparto.")),
        S("Coeficientes propuestos", _coef_tabla(co, crit)),
    ]}


def doc_acuerdo(cx, p):
    d0, d1 = _periodo(p)
    crit = p.get("criterio") or "Consumo"
    co = coeficientes(cx, d0, d1, crit)
    ent = _uno(cx, "gobernanza", "entidad")
    modo = p.get("modo") or "Fijos"
    return {"titulo": "Acuerdo de reparto de la energía", "subtitulo": "Autoconsumo colectivo", "secciones": [
        S("Partes", P(f"Los titulares de los suministros que figuran en la tabla de coeficientes, participantes en la "
                      f"instalación de autoconsumo colectivo gestionada por {ent.get('nombre') or config()['cec']}, "
                      "acuerdan el reparto de la energía generada conforme al artículo 4 y al anexo I del Real Decreto 244/2019.")),
        S("Criterio y coeficientes", P(f"Coeficientes {modo.lower()}. {METODO_COEF.get(crit, '')} Periodo base: {fd(d0)} – {fd(d1)}."),
          _coef_tabla(co, crit)),
        S("Vigencia y modificaciones", P(
            "El acuerdo surtirá efectos desde su comunicación a la empresa distribuidora y se mantendrá mientras no se "
            "comunique uno nuevo. Las altas y bajas de participantes y los cambios de criterio requerirán un nuevo acuerdo "
            "firmado por todos los participantes.")),
    ], "firmas": [so["nombre"] for so, *_ in co]}


def doc_verificacion(cx, p):
    d0, d1 = _periodo(p)
    crit = p.get("criterio") or "Consumo"
    co = {so["id"]: (s, c) for so, s, b, c in coeficientes(cx, *_doce_meses(), crit)}
    nombres = _socios_nombres()
    ver = [v for v in listar(cx, "reparto", "verificaciones") if _en(v.get("mes"), d0, d1)]
    act = _cups_activos(cx)
    exc = {r["mes"].isoformat()[:7]: r["vertida"] for r in _energia(cx, [s["cups"] for _, s in act], d0, d1)}
    filas, revisar = [], 0
    for v in sorted(ver, key=lambda v: (v["mes"], nombres.get(v["socio_id"], ""))):
        _, c = co.get(v["socio_id"], (None, 0.0))
        esperada = c * exc.get(v["mes"][:7], 0.0)
        dif = v["compensada"] - esperada
        ok = abs(dif) <= max(0.05 * esperada, 1.0)
        revisar += not ok
        filas.append([nombres.get(v["socio_id"], v["socio_id"]), v["mes"][:7], es(v["compensada"]), es(esperada),
                      es(dif), "correcta" if ok else "REVISAR"])
    return {"titulo": "Verificación de la energía compensada en factura", "subtitulo": f"{fd(d0)} – {fd(d1)}", "secciones": [
        S("Método", P("La energía esperada de cada socio es su coeficiente de reparto (criterio "
                      f"{crit.lower()}, últimos doce meses) multiplicado por los excedentes de la comunidad en el mes. "
                      "Se marca para revisar cualquier diferencia mayor del 5 % (o de 1 kWh).")),
        S("Resultado", T("Comparación factura frente a reparto", ["Socio", "Mes", "En factura (kWh)", "Esperada (kWh)",
                                                                   "Diferencia (kWh)", "Resultado"], filas, texto=2)
          if filas else P("No hay verificaciones registradas en el periodo."),
          P(f"{revisar} de {len(filas)} facturas deben revisarse con la comercializadora." if filas else "")),
    ]}


# ---------------- 4. economica ----------------
def _cuota_iva(m):
    return (m.get("base") or 0) * (m.get("iva") or 0) / 100


def doc_cuentas(cx, p):
    d0, d1 = _periodo(p)
    mov = [m for m in listar(cx, "economica", "movimientos") if _en(m.get("fecha"), d0, d1)]
    tot = lambda t: sum(m["base"] for m in mov if m["tipo"] == t)
    cat = {}
    for m in mov:
        cat.setdefault((m["tipo"], m["categoria"]), 0)
        cat[(m["tipo"], m["categoria"])] += m["base"]
    pend = [m for m in mov if not m.get("pagado")]
    return {"titulo": "Estado de cuentas", "subtitulo": f"{fd(d0)} – {fd(d1)}", "secciones": [
        S("Resumen", KV("Resumen del periodo (bases imponibles)", [
            ("Ingresos", eur(tot("Ingreso"))), ("Gastos", eur(tot("Gasto"))), ("Resultado", eur(tot("Ingreso") - tot("Gasto"))),
            ("Pendiente de cobro", eur(sum(m["base"] for m in pend if m["tipo"] == "Ingreso"))),
            ("Pendiente de pago", eur(sum(m["base"] for m in pend if m["tipo"] == "Gasto")))])),
        S("Por partidas", T("Ingresos y gastos por partida", ["Tipo", "Partida", "Importe"],
                            [[t, c, eur(v)] for (t, c), v in sorted(cat.items())], texto=2)),
        S("Movimientos", T("Movimientos del periodo", ["Fecha", "Tipo", "Partida", "Concepto", "Tercero", "Base", "IVA", "Estado"],
              [[fd(m["fecha"]), m["tipo"], m["categoria"], m["concepto"], m.get("tercero"), eur(m["base"]), eur(_cuota_iva(m)),
                "cobrado/pagado" if m.get("pagado") else "pendiente"] for m in sorted(mov, key=lambda m: m["fecha"])], texto=5)),
    ]}


def doc_presupuesto(cx, p):
    anio = int(p.get("anio") or _hoy().year)
    pre = [x for x in listar(cx, "economica", "presupuesto") if int(x["anio"]) == anio]
    mov = [m for m in listar(cx, "economica", "movimientos") if _en(m.get("fecha"), f"{anio}-01-01", f"{anio}-12-31")]
    claves = sorted({(x["tipo"], x["categoria"]) for x in pre} | {(m["tipo"], m["categoria"]) for m in mov})
    filas = []
    for t, c in claves:
        prev = sum(x["importe"] for x in pre if (x["tipo"], x["categoria"]) == (t, c))
        real = sum(m["base"] for m in mov if (m["tipo"], m["categoria"]) == (t, c))
        filas.append([t, c, eur(prev), eur(real), eur(real - prev), (es(100 * real / prev, 1) + " %") if prev else "–"])
    return {"titulo": "Ejecución presupuestaria", "subtitulo": str(anio), "secciones": [
        S("Ejecución por partida", T("Presupuesto frente a realizado", ["Tipo", "Partida", "Previsto", "Realizado",
                                                                         "Desviación", "Ejecución"], filas, texto=2)
          if filas else P("No hay presupuesto ni movimientos para el año.")),
    ]}


def doc_cuotas(cx, p):
    nombres = _socios_nombres()
    cu = [c for c in listar(cx, "economica", "cuotas") if not c.get("pagada")]
    por = {}
    for c in cu:
        por[c["socio_id"]] = por.get(c["socio_id"], 0) + c["importe"]
    return {"titulo": "Relación de cuotas pendientes", "subtitulo": f"A {_hoy():%d/%m/%Y}", "secciones": [
        S("Cuotas pendientes", T("Cuotas pendientes de pago", ["Socio", "Periodo", "Concepto", "Importe"],
              [[nombres.get(c["socio_id"], c["socio_id"]), c["periodo"][:7], c.get("concepto"), eur(c["importe"])]
               for c in sorted(cu, key=lambda c: (nombres.get(c["socio_id"], ""), c["periodo"]))]
              + [["Total", "", "", eur(sum(por.values()))]], texto=3, total=True) if cu else P("No hay cuotas pendientes.")),
        S("Por socio", T("Pendiente por socio", ["Socio", "Importe"], [[nombres.get(k, k), eur(v)] for k, v in sorted(por.items())])
          if por else P("–")),
    ]}


def doc_iva(cx, p):
    anio, tri = int(p.get("anio") or _hoy().year), int(p.get("trimestre") or 1)
    d0 = date(anio, 3 * tri - 2, 1)
    d1 = (date(anio + (tri == 4), (3 * tri) % 12 + 1, 1) - timedelta(days=1))
    mov = [m for m in listar(cx, "economica", "movimientos") if _en(m.get("fecha"), d0.isoformat(), d1.isoformat())]
    ing = [m for m in mov if m["tipo"] == "Ingreso"]
    gas = [m for m in mov if m["tipo"] == "Gasto"]
    rep, sop = sum(_cuota_iva(m) for m in ing), sum(_cuota_iva(m) for m in gas)
    return {"titulo": "Resumen de IVA", "subtitulo": f"{tri}.º trimestre de {anio}", "secciones": [
        S("Liquidación", P("Resumen informativo para preparar la autoliquidación (modelo 303); no la sustituye."),
          KV("IVA del trimestre", [("Base de ingresos", eur(sum(m["base"] for m in ing))), ("IVA repercutido", eur(rep)),
                                   ("Base de gastos", eur(sum(m["base"] for m in gas))), ("IVA soportado", eur(sop)),
                                   ("Resultado (a ingresar si es positivo)", eur(rep - sop))])),
        S("Facturas", T("Facturas del trimestre", ["Fecha", "Tipo", "Factura", "Tercero", "Base", "IVA %", "Cuota"],
              [[fd(m["fecha"]), m["tipo"], m.get("factura"), m.get("tercero"), eur(m["base"]), es(m.get("iva") or 0, 0), eur(_cuota_iva(m))]
               for m in sorted(mov, key=lambda m: m["fecha"])], texto=4)),
    ]}


def doc_financiacion(cx, p):
    fi = listar(cx, "economica", "financiacion")
    hoy, lim = _hoy().isoformat(), (_hoy() + timedelta(days=60)).isoformat()
    alerta = [f for f in fi if f.get("justificacion") and f.get("estado") in ("Concedida", "Cobrada") and f["justificacion"] <= lim]
    return {"titulo": "Financiación y subvenciones", "subtitulo": f"A {_hoy():%d/%m/%Y}", "secciones": [
        S("Situación", T("Financiación", ["Tipo", "Entidad o programa", "Importe", "Solicitud", "Estado", "Justificación"],
              [[f["tipo"], f["entidad"], eur(f.get("importe")), fd(f.get("fecha")), f.get("estado"), fd(f.get("justificacion"))]
               for f in fi], texto=2)),
        S("Justificaciones próximas", T("Pendientes de justificar en 60 días o vencidas", ["Entidad", "Importe", "Fecha límite", "Situación"],
              [[f["entidad"], eur(f.get("importe")), fd(f["justificacion"]), "vencida" if f["justificacion"] < hoy else "próxima"]
               for f in alerta], texto=1) if alerta else P("No hay justificaciones próximas.")),
    ]}


def doc_excedentes(cx, p):
    d0, d1 = _periodo(p)
    precio = float(p.get("precio") or 0.05)
    act = _cups_activos(cx)
    e = {r["cups"]: r for r in _energia_total(cx, [s["cups"] for _, s in act], d0, d1)}
    filas = [(so["nombre"], e[s["cups"]]["vertida"]) for so, s in act if s["cups"] in e and e[s["cups"]]["vertida"]]
    tot = sum(v for _, v in filas)
    return {"titulo": "Valoración de los excedentes", "subtitulo": f"{fd(d0)} – {fd(d1)}", "secciones": [
        S("Método", P(f"Excedentes vertidos a la red por cada suministro, valorados a {es(precio, 4)} €/kWh (precio "
                      "indicado al generar el documento; puede ser el de compensación simplificada o el de venta).")),
        S("Valoración", T("Excedentes y valoración", ["Socio", "Excedentes (kWh)", "Valor"],
              [[n, es(v), eur(v * precio)] for n, v in filas] + [["Total", es(tot), eur(tot * precio)]], total=True)
          if filas else P("No hubo excedentes en el periodo.")),
    ]}


# ---------------- 5. tramites ----------------
def doc_tramites(cx, p):
    pe = listar(cx, "tramites", "permisos")
    hoy, lim = _hoy().isoformat(), (_hoy() + timedelta(days=90)).isoformat()
    abiertos = [x for x in pe if x.get("estado") in ("pendiente", "solicitado", "en tramitación")]
    cad = [x for x in pe if x.get("caducidad") and x["caducidad"] <= lim]
    return {"titulo": "Registro de trámites y permisos", "subtitulo": f"A {_hoy():%d/%m/%Y}", "secciones": [
        S("Situación", T("Permisos y registros", ["Trámite", "Organismo", "Expediente", "Solicitud", "Resolución", "Estado", "Caducidad"],
              [[x["tipo"], x.get("organismo"), x.get("expediente"), fd(x.get("solicitud")), fd(x.get("resolucion")),
                x.get("estado"), fd(x.get("caducidad"))] for x in pe], texto=3)),
        S("Trámites abiertos", T("Trámites abiertos", ["Trámite", "Organismo", "Solicitud", "Estado", "Días"],
              [[x["tipo"], x.get("organismo"), fd(x.get("solicitud")), x.get("estado"),
                (date.today() - date.fromisoformat(x["solicitud"])).days if x.get("solicitud") else "–"] for x in abiertos], texto=2)
          if abiertos else P("No hay trámites abiertos.")),
        S("Caducidades", T("Caducados o que caducan en 90 días", ["Trámite", "Expediente", "Caducidad", "Situación"],
              [[x["tipo"], x.get("expediente"), fd(x["caducidad"]), "caducado" if x["caducidad"] < hoy else "caduca pronto"] for x in cad], texto=2)
          if cad else P("Nada caducado ni por caducar en 90 días.")),
    ]}


def doc_normativa(cx, p):
    no = listar(cx, "tramites", "normativa")
    pend = [n for n in no if n.get("estado") in ("Pendiente de análisis", "Acción pendiente")]
    return {"titulo": "Seguimiento normativo", "subtitulo": f"A {_hoy():%d/%m/%Y}", "secciones": [
        S("Normas registradas", T("Normas", ["Referencia", "Título", "Fecha", "Ámbito", "Estado"],
              [[n["referencia"], n.get("titulo"), fd(n.get("fecha")), n.get("ambito"), n.get("estado")] for n in no], texto=2)),
        S("Acciones pendientes", *[P(f"**{n['referencia']}** — {n.get('accion') or 'analizar su impacto'}. {n.get('impacto') or ''}")
                                   for n in pend] or P("No hay acciones pendientes.")),
    ]}


# ---------------- 6. participacion ----------------
def doc_boletin(cx, p):
    d0, d1 = _periodo(p)
    precio, pexc = float(p.get("precio") or 0.15), float(p.get("precio_excedente") or 0.05)
    act = _cups_activos(cx)
    e = _energia(cx, [s["cups"] for _, s in act], d0, d1)
    Cr, A, V, Gn = (_sumar(e, k) for k in ("consumo", "autoconsumo", "vertida", "generada"))
    mov = [m for m in listar(cx, "economica", "movimientos") if _en(m.get("fecha"), d0, d1)]
    ing = sum(m["base"] for m in mov if m["tipo"] == "Ingreso")
    gas = sum(m["base"] for m in mov if m["tipo"] == "Gasto")
    hoy = _hoy().isoformat()
    prox = [r for r in listar(cx, "gobernanza", "reuniones") if r.get("fecha", "") >= hoy and r.get("estado") != "Anulada"]
    acts = [a for a in listar(cx, "participacion", "actividades") if _en(a.get("fecha"), d0, d1)]
    return {"titulo": "Boletín informativo para los socios", "subtitulo": f"{fd(d0)} – {fd(d1)}", "secciones": [
        S("La energía de la comunidad", P(
            f"Los {len(act)} suministros de la comunidad consumieron {es(Cr + A)} kWh, de los que {es(A)} kWh salieron de "
            f"las placas ({es(100 * A / (Cr + A), 1) if Cr + A else '0'} %). Las instalaciones generaron {es(Gn)} kWh y "
            f"vertieron a la red {es(V)} kWh."),
          KV("Energía del periodo", [("Consumo total", es(Cr + A) + " kWh"), ("Autoconsumo", es(A) + " kWh"),
                                     ("Excedentes", es(V) + " kWh"), ("Generación", es(Gn) + " kWh")])),
        S("Ahorro estimado", P(f"Con un precio medio de {es(precio, 3)} €/kWh para la energía de la red y "
                               f"{es(pexc, 3)} €/kWh para los excedentes, el ahorro estimado es de "
                               f"{eur(A * precio + V * pexc)}: {eur(A * precio)} por autoconsumo y {eur(V * pexc)} por "
                               "excedentes. Es una estimación: el ahorro real depende de la tarifa de cada socio.")),
        S("Cuentas", KV("Cuentas del periodo", [("Ingresos", eur(ing)), ("Gastos", eur(gas)), ("Resultado", eur(ing - gas))])
          if mov else P("Sin movimientos en el periodo.")),
        S("Actividades y próximas citas",
          L([f"{fd(a['fecha'])} · {a['titulo']} ({a.get('tipo') or 'actividad'})" for a in acts], False) if acts else P("Sin actividades en el periodo."),
          L([f"{fd(r['fecha'])}{' ' + r['hora'] if r.get('hora') else ''} · {r['organo']}{' en ' + r['lugar'] if r.get('lugar') else ''}"
             for r in sorted(prox, key=lambda r: r["fecha"])], False) if prox else P("No hay reuniones convocadas.")),
    ]}


def doc_memoria(cx, p):
    anio = int(p.get("anio") or _hoy().year)
    d0, d1 = f"{anio}-01-01", f"{anio}-12-31"
    nombres = _socios_nombres()
    acts = [a for a in listar(cx, "participacion", "actividades") if _en(a.get("fecha"), d0, d1)]
    vul = [v for v in listar(cx, "participacion", "vulnerables") if (v.get("desde") or "") <= d1 and (v.get("hasta") or "9999") >= d0]
    rel = [r for r in listar(cx, "participacion", "relaciones") if _en(r.get("fecha"), d0, d1)]
    com = [c for c in listar(cx, "participacion", "comunicaciones") if _en(c.get("fecha"), d0, d1)]
    socios = listar(cx, "gobernanza", "socios")
    altas = [s for s in socios if _en(s.get("alta"), d0, d1)]
    return {"titulo": "Memoria social", "subtitulo": str(anio), "secciones": [
        S("Resumen", KV("Cifras del año", [("Actividades", len(acts)), ("Participantes", es(sum(a.get("participantes") or 0 for a in acts), 0)),
                                           ("Comunicaciones a socios", len(com)), ("Nuevos socios", len(altas)),
                                           ("Hogares vulnerables apoyados", len(vul)), ("Relaciones institucionales", len(rel))])),
        S("Actividades", T("Actividades del año", ["Fecha", "Tipo", "Título", "Participantes"],
              [[fd(a["fecha"]), a.get("tipo"), a["titulo"], es(a.get("participantes") or 0, 0)] for a in acts], texto=3)
          if acts else P("Sin actividades registradas.")),
        S("Inclusión de hogares vulnerables", T("Hogares apoyados", ["Socio", "Criterio", "Apoyo", "Desde", "Hasta"],
              [[nombres.get(v["socio_id"], v["socio_id"]), v.get("criterio"), v.get("apoyo"), fd(v.get("desde")), fd(v.get("hasta"))]
               for v in vul], texto=3) if vul else P("Sin hogares registrados.")),
        S("Relaciones institucionales", T("Relaciones del año", ["Fecha", "Entidad", "Tipo", "Asunto"],
              [[fd(r["fecha"]), r["entidad"], r.get("tipo"), r.get("asunto")] for r in rel], texto=4) if rel else P("Sin registros.")),
    ]}


# ---------------- 7. rgpd ----------------
def doc_rat(cx, p):
    ent = _uno(cx, "gobernanza", "entidad")
    tr = listar(cx, "rgpd", "tratamientos")
    return {"titulo": "Registro de actividades de tratamiento", "subtitulo": "Artículo 30 del RGPD", "secciones": [
        S("Responsable del tratamiento", KV("Responsable", [("Denominación", ent.get("nombre")), ("NIF", ent.get("nif")),
                                                            ("Domicilio", ent.get("domicilio")), ("Contacto", ent.get("email"))]))]
        + [S(t["actividad"], KV(f"Actividad de tratamiento: {t['actividad']}", [
            ("Finalidad", t.get("finalidad")), ("Base jurídica", t.get("base")), ("Categorías de datos", t.get("datos")),
            ("Interesados", t.get("interesados")), ("Destinatarios", t.get("destinatarios")),
            ("Plazo de conservación", t.get("conservacion")), ("Medidas de seguridad", t.get("medidas"))])) for t in tr]}


def doc_consentimientos(cx, p):
    nombres = _socios_nombres()
    ult = {}
    for c in listar(cx, "rgpd", "consentimientos"):
        if c["socio_id"] not in ult or c["fecha"] > ult[c["socio_id"]]["fecha"]:
            ult[c["socio_id"]] = c
    socios = [s for s in listar(cx, "gobernanza", "socios") if not s.get("baja") and s.get("socio_id")]
    si = lambda c, k: "–" if not c else ("revocado" if c.get("revocado") else "sí" if c.get(k) else "no")
    sin = [s["nombre"] for s in socios if not (c := ult.get(s["socio_id"])) or c.get("revocado") or not c.get("datadis")]
    return {"titulo": "Estado de los consentimientos", "subtitulo": f"A {_hoy():%d/%m/%Y}", "secciones": [
        S("Consentimientos por socio", T("Último consentimiento de cada socio", ["Socio", "Fecha", "Datadis", "Comunicaciones", "Imagen"],
              [[s["nombre"], fd((ult.get(s["socio_id"]) or {}).get("fecha")), si(ult.get(s["socio_id"]), "datadis"),
                si(ult.get(s["socio_id"]), "comunicaciones"), si(ult.get(s["socio_id"]), "imagen")] for s in socios])),
        S("Pendientes", P(("Socios sin autorización vigente para acceder a sus datos de Datadis: " + ", ".join(sin)
                           + ". No deben tratarse sus curvas de carga hasta obtenerla.") if sin else
                          "Todos los socios en alta tienen autorización vigente para Datadis.")),
    ]}


def doc_derechos(cx, p):
    de = listar(cx, "rgpd", "derechos")
    br = listar(cx, "rgpd", "brechas")
    plazo = lambda d: (date.fromisoformat(d["respuesta"]) - date.fromisoformat(d["fecha"])).days if d.get("respuesta") else \
        (date.today() - date.fromisoformat(d["fecha"])).days
    return {"titulo": "Registro de derechos e incidencias", "subtitulo": f"A {_hoy():%d/%m/%Y}", "secciones": [
        S("Solicitudes de derechos", P("El plazo general de respuesta es de un mes desde la recepción (art. 12.3 RGPD)."),
          T("Solicitudes", ["Recibida", "Interesado", "Derecho", "Estado", "Días", "En plazo"],
            [[fd(d["fecha"]), d["interesado"], d["derecho"], d.get("estado"), plazo(d), "sí" if plazo(d) <= 30 else "NO"] for d in de], texto=4)
          if de else P("No hay solicitudes registradas.")),
        S("Incidencias y brechas", P("Las brechas con riesgo para los derechos de las personas deben notificarse a la AEPD "
                                     "en 72 horas (art. 33 RGPD)."),
          T("Incidencias", ["Detectada", "Descripción", "Afectados", "Riesgo", "AEPD"],
            [[fd(b["fecha"]), b["descripcion"], es(b.get("afectados") or 0, 0), b.get("riesgo"), "sí" if b.get("aepd") else "no"] for b in br], texto=2)
          if br else P("No hay incidencias registradas.")),
    ]}


def doc_clausula(cx, p):
    ent = _uno(cx, "gobernanza", "entidad")
    n = ent.get("nombre") or config()["cec"]
    return {"titulo": "Cláusula informativa de protección de datos", "subtitulo": "Para socios y participantes", "secciones": [
        S("Responsable", P(f"{n}{', NIF ' + ent['nif'] if ent.get('nif') else ''}{', ' + ent['domicilio'] if ent.get('domicilio') else ''}"
                           f"{'. Contacto: ' + ent['email'] if ent.get('email') else ''}.")),
        S("Finalidades y base jurídica", L([f"{t['actividad']}: {t.get('finalidad') or ''} Base jurídica: {t.get('base') or '–'}."
                                            for t in listar(cx, "rgpd", "tratamientos")])),
        S("Destinatarios", P("Los datos de consumo se comunican a la empresa distribuidora solo para aplicar el reparto de la "
                             "energía. No se ceden a terceros salvo obligación legal.")),
        S("Derechos", P("Puede ejercer los derechos de acceso, rectificación, supresión, oposición, limitación y portabilidad "
                        "dirigiéndose al responsable, y presentar una reclamación ante la Agencia Española de Protección de "
                        "Datos (www.aepd.es). Puede retirar su consentimiento en cualquier momento.")),
        S("Autorización de acceso a Datadis", P(
            "Para calcular los coeficientes de reparto y elaborar los informes, la comunidad necesita acceder a las curvas de "
            "carga de su suministro en Datadis. Con su firma autoriza ese acceso mientras participe en la comunidad.")),
    ], "firmas": ["Nombre y firma del socio", "Fecha"]}


PERIODO = [_p("desde", "Desde", "fecha"), _p("hasta", "Hasta", "fecha")]
ANIO = [_p("anio", "Año", "anio")]
CRITERIO = _p("criterio", "Criterio", "opcion", "Consumo", ["Consumo", "Igualitario", "Potencia contratada"])

DOCS = {
    "gobernanza": [
        ("libro_socios", "Libro de registro de socios", "Socios en alta y bajas, votos y control por socios próximos.", [], doc_libro_socios),
        ("convocatoria", "Convocatoria", "Convocatoria de una asamblea o reunión de la junta.",
         [_p("registro", "Reunión", "registro", registro="reuniones"), _p("segunda", "Segunda convocatoria", "texto", "media hora después")],
         doc_convocatoria),
        ("acta", "Acta", "Acta de una asamblea o reunión con asistentes, orden del día y acuerdos.",
         [_p("registro", "Reunión", "registro", registro="reuniones")], doc_acta),
        ("reglamento", "Reglamento interno", "Texto del reglamento por capítulos.", [], doc_reglamento),
    ],
    "tecnica": [
        ("produccion", "Informe técnico de producción", "Generación, autoconsumo, excedentes, equipos y mantenimiento.", PERIODO, doc_produccion),
        ("mantenimiento", "Plan de mantenimiento", "Actuaciones previstas y realizadas, y costes.", ANIO, doc_mantenimiento),
        ("inventario", "Inventario, garantías y seguros", "Equipos, pólizas y vencimientos.", [], doc_inventario),
        ("ampliaciones", "Plan de ampliaciones", "Cartera de proyectos y presupuesto.", [], doc_ampliaciones),
    ],
    "reparto": [
        ("propuesta", "Propuesta de coeficientes", "Coeficientes de reparto con seis decimales que suman 1.", PERIODO + [CRITERIO], doc_propuesta_coef),
        ("acuerdo", "Acuerdo de reparto", "Acuerdo para firmar por los participantes y comunicar a la distribuidora.",
         PERIODO + [CRITERIO, _p("modo", "Coeficientes", "opcion", "Fijos", ["Fijos", "Variables por horas"])], doc_acuerdo),
        ("verificacion", "Verificación de facturas", "Energía compensada en factura frente a la que corresponde por reparto.",
         PERIODO + [CRITERIO], doc_verificacion),
    ],
    "economica": [
        ("cuentas", "Estado de cuentas", "Ingresos, gastos y resultado del periodo.", PERIODO, doc_cuentas),
        ("presupuesto", "Ejecución presupuestaria", "Previsto frente a realizado por partida.", ANIO, doc_presupuesto),
        ("cuotas", "Cuotas pendientes", "Relación de cuotas sin pagar.", [], doc_cuotas),
        ("iva", "Resumen de IVA", "IVA repercutido y soportado del trimestre.",
         ANIO + [_p("trimestre", "Trimestre", "opcion", None, ["1", "2", "3", "4"])], doc_iva),
        ("financiacion", "Financiación y subvenciones", "Situación y justificaciones próximas.", [], doc_financiacion),
        ("excedentes", "Valoración de excedentes", "Excedentes vertidos y su valor económico.",
         PERIODO + [_p("precio", "Precio (€/kWh)", "numero", 0.05)], doc_excedentes),
    ],
    "tramites": [
        ("tramites", "Registro de trámites y permisos", "Situación, trámites abiertos y caducidades.", [], doc_tramites),
        ("normativa", "Seguimiento normativo", "Normas registradas y acciones pendientes.", [], doc_normativa),
    ],
    "participacion": [
        ("boletin", "Boletín para los socios", "Producción, ahorro estimado, cuentas y próximas citas.",
         PERIODO + [_p("precio", "Precio de la energía (€/kWh)", "numero", 0.15),
                    _p("precio_excedente", "Precio de los excedentes (€/kWh)", "numero", 0.05)], doc_boletin),
        ("memoria", "Memoria social", "Actividades, inclusión y relaciones del año.", ANIO, doc_memoria),
    ],
    "rgpd": [
        ("rat", "Registro de actividades de tratamiento", "Artículo 30 del RGPD.", [], doc_rat),
        ("consentimientos", "Estado de los consentimientos", "Autorizaciones de cada socio y pendientes.", [], doc_consentimientos),
        ("derechos", "Registro de derechos e incidencias", "Solicitudes, plazos y brechas.", [], doc_derechos),
        ("clausula", "Cláusula informativa", "Texto informativo y autorización de Datadis para firmar.", [], doc_clausula),
    ],
}


def esquema():
    """Lo que necesita el panel: areas, registros, campos, documentos y parametros."""
    a0, a1 = _anterior_mes()
    defectos = {"desde": a0, "hasta": a1, "anio": _hoy().year, "trimestre": str((_hoy().month - 1) // 3 + 1)}
    out = {}
    for k, a in AREAS.items():
        out[k] = {"titulo": a["titulo"], "descripcion": a["descripcion"], "icono": a["icono"],
                  "registros": {t: {"titulo": r["titulo"], "unico": r.get("unico", False), "campos": r["campos"]}
                                for t, r in a["registros"].items()},
                  "documentos": [{"id": d, "titulo": ti, "descripcion": de,
                                  "parametros": [dict(x, defecto=x["defecto"] if x["defecto"] is not None else defectos.get(x["id"]))
                                                 for x in ps]} for d, ti, de, ps, _ in DOCS[k]]}
    return {"comunidad": config()["cec"], "areas": out,
            "socios": [{"id": so["id"], "nombre": so["nombre"]} for so in config()["socios"]]}


# ======================= PDF =======================
PLANTILLA = r"""
// Documento de gestion: A4 vertical, apartados numerados (ISO 2145), titulos de tabla
// encima (ISO 7144), ficha de control documental y firmas.
#let d = json("datos.json")
#let ac = rgb("#7b2fa8")
#let gris = rgb("#666")
#set document(title: d.titulo, author: d.autor)
#set text(font: ("Roboto", "DejaVu Sans"), lang: "es", region: "es", size: 9.5pt, fill: rgb("#222"))
#set par(justify: true, leading: 0.62em, spacing: 0.9em)
#set page(paper: "a4", margin: (top: 2.3cm, bottom: 2.2cm, left: 2.5cm, right: 2cm),
  header: context [#set text(7.5pt, fill: gris); #d.entidad #h(1fr) #d.codigo #v(-4pt) #line(length: 100%, stroke: 0.4pt + luma(200))],
  footer: context [#set text(7.5pt, fill: gris); #d.area #h(1fr) Página #counter(page).display() de #counter(page).final().first()])
#set heading(numbering: "1.1")
#show heading: set block(sticky: true)
#show heading.where(level: 1): it => block(above: 1.4em, below: 0.7em, text(11.5pt, weight: "bold", fill: ac,
  [#counter(heading).display(it.numbering) #h(0.4em) #it.body]))
#set figure(gap: 0.5em)
#set figure.caption(separator: [ — ])
#show figure.caption: set text(8.5pt)
#show figure.caption: it => [#strong[#it.supplement #context it.counter.display(it.numbering)]#it.separator#it.body]
#show figure.where(kind: table): set figure.caption(position: top)
#let tabla(t) = {
  set text(7.8pt)
  set par(justify: false)
  table(columns: t.cabecera.len(),
    align: (x, y) => if x < t.texto { left } else { right },
    stroke: (x, y) => if y == 0 { (top: 0.8pt, bottom: 0.6pt) } else { (bottom: 0.3pt + luma(215)) },
    fill: (x, y) => if t.total and y == t.filas.len() { luma(236) },
    inset: (x: 3.5pt, y: 3pt),
    table.header(..t.cabecera.map(c => strong(c))),
    ..t.filas.flatten().map(c => [#c]))
}

#block(fill: ac, width: 100%, inset: (x: 10pt, y: 7pt))[
  #text(fill: white, 8.5pt, weight: "bold", tracking: 1.2pt)[#upper(d.area)] #h(1fr) #text(fill: white, 8pt)[#d.codigo]]
#v(6pt)
#text(18pt, weight: "bold", fill: ac)[#d.titulo]
#if d.subtitulo != none [ \ #text(11pt, fill: gris)[#d.subtitulo]]
#v(6pt)
#{
  set text(8pt)
  set par(justify: false)
  table(columns: (3.6cm, 1fr, 3.2cm, 1fr), stroke: (x, y) => (bottom: 0.3pt + luma(210)), inset: (x: 2pt, y: 4pt),
    text(fill: gris)[Entidad], [#d.entidad], text(fill: gris)[Código], [#d.codigo],
    text(fill: gris)[Fecha de emisión], [#d.fecha], text(fill: gris)[Versión], [#d.version],
    text(fill: gris)[Elaborado por], [#d.por], text(fill: gris)[Parámetros], [#d.parametros])
}
#v(4pt)

#for s in d.secciones [
  = #s.titulo
  #for b in s.bloques {
    if "p" in b { par(b.p.map(x => if x.b { strong(x.t) } else { x.t }).join()) }
    else if "lista" in b { if b.numerada { enum(..b.lista.map(x => [#x])) } else { list(..b.lista.map(x => [#x])) } }
    else if "tabla" in b {
      figure(tabla(b.tabla), caption: [#b.caption])
      if b.nota != none { text(7.5pt, fill: gris, b.nota) }
    }
  }
]

#if d.firmas.len() > 0 [
  #v(1.5cm)
  #block(breakable: false, grid(columns: (1fr,) * calc.min(3, d.firmas.len()), column-gutter: 18pt, row-gutter: 1.4cm,
    ..d.firmas.map(f => [#v(1.2cm) #line(length: 100%, stroke: 0.5pt) #text(8pt)[#f]])))
]
"""


def _segmentos(t):
    """Parrafo -> [{t, b}]: texto literal (Typst no interpreta nada) y **negrita**."""
    partes = re.split(r"\*\*(.+?)\*\*", str(t))
    return [{"t": x, "b": i % 2 == 1} for i, x in enumerate(partes) if x]


def _codigo(area, doc):
    return f"CEC-{area[:3].upper()}-{re.sub(r'[^A-Za-z0-9]', '', doc)[:6].upper()}-{datetime.now(TZL):%Y%m%d-%H%M}"


def generar(area, doc, params, por):
    """Genera el PDF, lo archiva en la tabla documento y devuelve su fila (sin el PDF)."""
    import typst

    fns = {d: (ti, fn) for d, ti, de, ps, fn in DOCS.get(area, [])}
    if doc not in fns:
        raise KeyError(doc)
    with db.conectar() as cx:
        contenido = fns[doc][1](cx, params or {})
        ent = _uno(cx, "gobernanza", "entidad")
    for s in contenido["secciones"]:
        for b in s["bloques"]:
            if "p" in b:
                b["p"] = _segmentos(b["p"])
    codigo = _codigo(area, doc)
    legibles = {"desde": "desde", "hasta": "hasta"}
    datos = {"titulo": contenido["titulo"], "subtitulo": contenido.get("subtitulo"),
             "secciones": contenido["secciones"], "firmas": contenido.get("firmas", []),
             "area": AREAS[area]["titulo"], "entidad": ent.get("nombre") or config()["cec"], "codigo": codigo,
             "fecha": f"{datetime.now(TZL):%d/%m/%Y %H:%M}", "version": "1.0", "por": por, "autor": por,
             "parametros": ", ".join(f"{legibles.get(k, k)}: {fd(v) if re.fullmatch(r'\d{4}-\d{2}-\d{2}', str(v)) else v}"
                                     for k, v in (params or {}).items() if v not in (None, "") and k != "registro") or "–"}
    with tempfile.TemporaryDirectory() as raiz:
        Path(raiz, "doc.typ").write_text(PLANTILLA, encoding="utf-8")
        Path(raiz, "datos.json").write_text(json.dumps(datos, ensure_ascii=False, default=str), encoding="utf-8")
        pdf = typst.compile(str(Path(raiz, "doc.typ")), root=raiz, font_paths=["/usr/share/fonts"])
    did = str(uuid.uuid4())
    titulo = contenido["titulo"] + (f" · {contenido['subtitulo']}" if contenido.get("subtitulo") else "")
    with db.conectar() as cx:
        cx.execute("INSERT INTO documento (id, area, tipo, titulo, codigo, parametros, por, pdf) VALUES (%s, %s, %s, %s, %s, %s, %s, %s)",
                   (did, area, doc, titulo, codigo, Jsonb(params or {}), por, pdf))
    return {"id": did, "titulo": titulo, "codigo": codigo}


def documentos(area):
    with db.conectar() as cx:
        return cx.execute("SELECT id, tipo, titulo, codigo, creado, por, length(pdf) AS bytes FROM documento "
                          "WHERE area = %s ORDER BY creado DESC LIMIT 100", (area,)).fetchall()


def pdf(did):
    did = _uuid(did)
    with db.conectar() as cx:
        r = cx.execute("SELECT titulo, codigo, pdf FROM documento WHERE id = %s", (did,)).fetchone()
    if not r:
        raise KeyError(did)
    base = re.sub(r"[^A-Za-z0-9]+", "_", unicodedata.normalize("NFD", r["titulo"]).encode("ascii", "ignore").decode()).strip("_")
    return bytes(r["pdf"]), f"{r['codigo']}_{base[:60]}.pdf"


def borrar_documento(did):
    did = _uuid(did)
    with db.conectar() as cx:
        if not cx.execute("DELETE FROM documento WHERE id = %s", (did,)).rowcount:
            raise KeyError(did)
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

from .comun import E, TZL, log, plataforma
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
                self.gateway = plataforma()["gateway"]
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
        cfg = plataforma()
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

cat > config/fastapi/app/plataforma.py <<'__FASTAPI_EOF__'
"""Plataforma: registro de las comunidades (base "plataforma"), alta de comunidades (la hace
el superusuario desde su panel) y de participantes (la hace el gestor de cada comunidad).

Cada comunidad tiene su tenant de ThingsBoard (con un administrador que usa esta API), su
base PostgreSQL (cec_<id>; la primera comunidad, "cec") y su gestor (TENANT_ADMIN encerrado
en el panel de la comunidad). Lo que hay en ThingsBoard (tenant, usuarios, dispositivos,
widgets y paneles) lo crea tb-config.py, el mismo programa que usa iot-thingsboard.sh: aqui
se ejecuta con los datos de la comunidad y la lista completa de sus socios (los que ya no
estan se borran de ThingsBoard con su cliente y su usuario).

Comunidades de partida: las de iot-thingsboard.sh (config.json, "comunidades"); sus socios
se marcan por = 'script' y siguen la lista del script. Las demas, y los socios que dan de
alta los gestores, solo cambian desde los paneles."""
import os
import random
import re
import shutil
import subprocess
import sys
import threading
import time
import unicodedata
from pathlib import Path

import psycopg
from psycopg import sql
from psycopg.rows import dict_row

from . import db, gestion
from .comun import COMUNIDAD, E, comunidad, log, plataforma
from .tb import TB

BASE = "plataforma"
TB_CONFIG = os.environ.get("TB_CONFIG", "/srv/tb-config.py")
SUBIDAS = Path(E.get("SUBIDAS_DIR", "/subidas"))
_LK = threading.Lock()            # un aprovisionamiento a la vez
CSV = re.compile(r"^(Consumo|Contrato|Potencias)_[\w.-]*\.csv$", re.I)
CUPS = re.compile(r"^ES[0-9]{16}[A-Z]{2}([0-9][A-Z])?$")
EMAIL = re.compile(r"^[^@\s|]+@[^@\s|]+\.[^@\s|]+$")

ESQUEMA = """
CREATE TABLE IF NOT EXISTS comunidad (
  id           text PRIMARY KEY,
  nombre       text NOT NULL UNIQUE,
  base         text NOT NULL UNIQUE,
  tenant_email text NOT NULL,      -- administrador del tenant (lo usa la API)
  tenant_id    text,               -- se averigua al entrar con tenant_email
  gestor_email text,
  lat          double precision,   -- centro del mapa (socios sin ubicacion)
  lon          double precision,
  creada       timestamptz NOT NULL DEFAULT now(),
  por          text
);
-- Gestor: activo | bloqueado (credenciales desactivadas) | quitado (usuario borrado).
-- gestor_origen: script (sigue a iot-thingsboard.sh) | panel (lo cambio el superusuario)
ALTER TABLE comunidad ADD COLUMN IF NOT EXISTS gestor_estado text NOT NULL DEFAULT 'activo';
ALTER TABLE comunidad ADD COLUMN IF NOT EXISTS gestor_origen text NOT NULL DEFAULT 'script';
"""


def slug(texto):   # el mismo que tb-config.py (id del dispositivo de cada socio)
    t = unicodedata.normalize("NFD", str(texto)).encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", "-", t).strip("-")


def _cx(base=BASE):
    return psycopg.connect(db.dsn(base), row_factory=dict_row, autocommit=True)


def crear_base(nombre):
    with _cx("postgres") as cx:
        if not cx.execute("SELECT 1 FROM pg_database WHERE datname = %s", (nombre,)).fetchone():
            cx.execute(sql.SQL("CREATE DATABASE {}").format(sql.Identifier(nombre)))
            log.info("base de datos '%s' creada", nombre)


def con(c, f, *a, **k):
    """Ejecuta f con c como comunidad en curso."""
    tok = COMUNIDAD.set(c)
    try:
        return f(*a, **k)
    finally:
        COMUNIDAD.reset(tok)


def semilla(cid):
    return next((x for x in plataforma().get("comunidades", []) if x["id"] == cid), None)


def lista():
    with _cx() as cx:
        return cx.execute("SELECT * FROM comunidad ORDER BY creada, id").fetchall()


def por_id(cid):
    with _cx() as cx:
        return cx.execute("SELECT * FROM comunidad WHERE id = %s", (cid,)).fetchone()


def por_tenant(tid):
    """Comunidad de un tenant de ThingsBoard (None si no es de ninguna, p. ej. Plataforma)."""
    filas = lista()
    for c in filas:
        if c["tenant_id"] == tid:
            return c
    for c in filas:
        if c["tenant_id"]:
            continue
        try:
            t = TB(c["tenant_email"]).tenant_id()
        except Exception:
            continue          # aun sin aprovisionar
        with _cx() as cx:
            cx.execute("UPDATE comunidad SET tenant_id = %s WHERE id = %s", (t, c["id"]))
        if t == tid:
            return dict(c, tenant_id=t)
    return None


def preparar(espera_s=300):
    """Base y registro de la plataforma, comunidades de partida del script y esquema de la
    base de cada comunidad (espera a PostgreSQL)."""
    fin = time.time() + espera_s
    while True:
        try:
            crear_base(BASE)
            break
        except psycopg.OperationalError as e:
            if time.time() > fin:
                raise
            log.info("PostgreSQL no disponible todavia (%s)", e)
            time.sleep(3)
    with _cx() as cx:
        cx.execute(ESQUEMA)
        for x in plataforma().get("comunidades", []):
            cx.execute("""INSERT INTO comunidad (id, nombre, base, tenant_email, gestor_email, lat, lon, por)
                          VALUES (%s, %s, %s, %s, %s, %s, %s, 'script')
                          ON CONFLICT (id) DO UPDATE SET nombre = EXCLUDED.nombre, tenant_email = EXCLUDED.tenant_email,
                            gestor_email = CASE WHEN comunidad.gestor_origen = 'script' THEN EXCLUDED.gestor_email
                                                ELSE comunidad.gestor_email END,
                            lat = EXCLUDED.lat, lon = EXCLUDED.lon""",
                       (x["id"], x["nombre"], x["base"], x["tenant_email"], x["gestor_email"], x.get("lat"), x.get("lon")))
    for c in lista():
        crear_base(c["base"])
        con(c, _preparar_comunidad, semilla(c["id"]))


def _preparar_comunidad(sem):
    db.preparar()
    if sem:   # socios del script: altas, cambios y bajas segun su lista
        with db.conectar() as cx:
            for so in sem["socios"]:
                cx.execute("""INSERT INTO socio (id, nombre, email, carpeta, lat, lon, por)
                              VALUES (%s, %s, %s, %s, %s, %s, 'script')
                              ON CONFLICT (id) DO UPDATE SET nombre = EXCLUDED.nombre, email = EXCLUDED.email,
                                carpeta = EXCLUDED.carpeta, lat = EXCLUDED.lat, lon = EXCLUDED.lon
                              WHERE socio.por = 'script'""",
                           (so["id"], so["nombre"], so.get("email") or None, so.get("carpeta") or None,
                            so.get("lat"), so.get("lon")))
            cx.execute("DELETE FROM socio WHERE por = 'script' AND NOT (id = ANY(%s))", ([so["id"] for so in sem["socios"]],))
    gestion.preparar()


def aprovisionar(c, gestor_password="", passwords=None):
    """ThingsBoard de una comunidad (tb-config.py): tenant, gestor, socios, widgets y paneles.
    Solo se pasan las contraseñas de los usuarios que hay que crear (los demas ya existen)."""
    sem = semilla(c["id"]) or {}
    pw = {so["id"]: so.get("password") or "" for so in sem.get("socios", [])}
    pw.update(passwords or {})
    socios = con(c, db.socios)
    lineas = "\n".join("|".join([so["nombre"], so["email"] or "", pw.get(so["id"], ""), so["carpeta"] or "",
                                 "" if so["lat"] is None else str(so["lat"]), "" if so["lon"] is None else str(so["lon"])])
                       for so in socios)
    env = dict(os.environ, TB_URL=E.get("TB_URL", "http://thingsboard:8080"),
               TB_TENANT_EMAIL=c["tenant_email"], CEC_TENANT=c["nombre"], TB_LANG=E.get("TB_LANG", "es_ES"),
               TB_GATEWAY_NAME="", TB_GATEWAY_ANTERIOR="", CLIENTES="", SUPER_EMAIL="",
               CEC_NOMBRE=c["nombre"], CEC_ADMIN_EMAIL=c["gestor_email"] or "",
               CEC_ADMIN_PASSWORD=gestor_password or (sem.get("gestor_password") if c["gestor_origen"] == "script" else "") or "",
               CEC_ADMIN_ANTERIOR_EMAIL=sem.get("anterior_email") or "",
               CEC_ADMIN_ANTERIOR_PASSWORD=sem.get("anterior_password") or "",
               CEC_API="/cec-api", SOCIOS=lineas)
    with _LK:
        r = subprocess.run([sys.executable, TB_CONFIG], env=env, capture_output=True, text=True, timeout=1800)
    salida = (r.stdout + ("\n" + r.stderr if r.stderr else "")).strip()
    log.info("aprovisionamiento de %s:\n%s", c["id"], salida)
    if r.returncode:
        raise RuntimeError(f"ThingsBoard ({c['nombre']}): " + salida[-1500:])
    return salida


def aprovisionar_todas():
    return {c["id"]: aprovisionar(c) for c in lista()}


# ---------------- comunidades (superusuario) ----------------
def resumen():
    out = []
    for c in lista():
        try:
            n = len(con(c, db.socios))
        except Exception:
            n = None
        out.append({"id": c["id"], "nombre": c["nombre"], "gestor_email": c["gestor_email"], "base": c["base"],
                    "gestor_estado": c["gestor_estado"] if c["gestor_email"] else "sin gestor",
                    "socios": n, "aprovisionada": bool(c["tenant_id"]), "creada": c["creada"].isoformat(),
                    "origen": "script" if c["por"] == "script" else "panel"})
    return out


def crear_comunidad(d, por):
    nombre = (d.get("nombre") or "").strip()
    cid = slug(d.get("id") or nombre)[:30].strip("-")
    email = (d.get("gestor_email") or "").strip().lower()
    pw = d.get("gestor_password") or ""
    if not 3 <= len(nombre) <= 80 or "|" in nombre:
        raise ValueError("El nombre de la comunidad debe tener entre 3 y 80 caracteres")
    if not re.match(r"^[a-z0-9][a-z0-9-]{1,29}$", cid):
        raise ValueError("Identificador no válido (letras minúsculas, números y guiones)")
    if not EMAIL.match(email):
        raise ValueError("Email del gestor no válido")
    if len(pw) < 4:
        raise ValueError("La contraseña del gestor debe tener al menos 4 caracteres")
    for c in lista():
        if c["id"] == cid or c["nombre"].lower() == nombre.lower():
            raise ValueError("Ya existe una comunidad con ese nombre o identificador")
    lat, lon = _num(d.get("lat"), 37.18), _num(d.get("lon"), -3.60)
    base = "cec_" + cid.replace("-", "_")
    crear_base(base)
    with _cx() as cx:
        cx.execute("INSERT INTO comunidad (id, nombre, base, tenant_email, gestor_email, lat, lon, por, gestor_origen) "
                   "VALUES (%s, %s, %s, %s, %s, %s, %s, %s, 'panel')",
                   (cid, nombre, base, f"api@{cid}.{E.get('TENANT_DOMINIO') or 'local'}", email, lat, lon, por))
    c = por_id(cid)
    con(c, _preparar_comunidad, None)
    aprovisionar(c, gestor_password=pw)
    return next(x for x in resumen() if x["id"] == cid)


def _sa():
    """Sysadmin de ThingsBoard (gestiona usuarios de cualquier tenant)."""
    return TB("sysadmin@thingsboard.org", E["TB_SYSADMIN_PASSWORD"])


def _comunidad(cid):
    c = por_id(cid)
    if not c:
        raise KeyError(cid)
    return c


def _usuario_tb(sa, c, email):
    """Usuario del tenant de la comunidad con ese email (None si no existe)."""
    if not email:
        return None
    tid = c["tenant_id"] or TB(c["tenant_email"]).tenant_id()
    r = sa.req("GET", f"/api/tenant/{tid}/users", params={"pageSize": 1000, "page": 0}) or {}
    return next((u for u in r.get("data", []) if (u.get("email") or "").lower() == email.lower()), None)


def _estado_gestor(cid, estado, email=None, origen="panel"):
    with _cx() as cx:
        if email is None:
            cx.execute("UPDATE comunidad SET gestor_estado = %s, gestor_origen = %s WHERE id = %s", (estado, origen, cid))
        else:
            cx.execute("UPDATE comunidad SET gestor_estado = %s, gestor_origen = %s, gestor_email = %s WHERE id = %s",
                       (estado, origen, email or None, cid))


def bloquear_gestor(cid, bloquear):
    """Desactiva (o vuelve a activar) las credenciales del gestor: no puede entrar, y la API
    rechaza ya sus peticiones aunque su sesion de ThingsBoard siga abierta."""
    c = _comunidad(cid)
    if not c["gestor_email"]:
        raise ValueError("La comunidad no tiene gestor")
    sa = _sa()
    u = _usuario_tb(sa, c, c["gestor_email"])
    if not u:
        raise ValueError(f"El gestor {c['gestor_email']} no existe en ThingsBoard (actualiza ThingsBoard o asigna otro)")
    sa.req("POST", f"/api/user/{u['id']['id']}/userCredentialsEnabled",
           params={"userCredentialsEnabled": "false" if bloquear else "true"})
    _estado_gestor(cid, "bloqueado" if bloquear else "activo", origen=c["gestor_origen"])
    log.info("gestor %s de %s %s", c["gestor_email"], cid, "bloqueado" if bloquear else "desbloqueado")


def quitar_gestor(cid):
    """Borra el usuario del gestor: la comunidad se queda sin gestor hasta asignar otro."""
    c = _comunidad(cid)
    if not c["gestor_email"]:
        raise ValueError("La comunidad no tiene gestor")
    sa = _sa()
    u = _usuario_tb(sa, c, c["gestor_email"])
    if u:
        sa.req("DELETE", f"/api/user/{u['id']['id']}")
    _estado_gestor(cid, "quitado", "")
    log.info("gestor %s de %s quitado", c["gestor_email"], cid)


def asignar_gestor(cid, email, password):
    """Nuevo gestor (sustituye al que hubiera): crea su usuario con el panel de la comunidad."""
    c = _comunidad(cid)
    email = (email or "").strip().lower()
    if not EMAIL.match(email):
        raise ValueError("Email del gestor no válido")
    if len(password or "") < 4:
        raise ValueError("La contraseña del gestor debe tener al menos 4 caracteres")
    sa = _sa()
    if c["gestor_email"] and c["gestor_email"].lower() != email:
        viejo = _usuario_tb(sa, c, c["gestor_email"])
        if viejo:
            sa.req("DELETE", f"/api/user/{viejo['id']['id']}")
    if _usuario_tb(sa, c, email):
        raise ValueError(f"{email} ya es usuario de esta comunidad")
    _estado_gestor(cid, "activo", email)
    aprovisionar(por_id(cid), gestor_password=password)
    if not _usuario_tb(sa, c, email):
        raise RuntimeError(f"No se pudo crear el usuario {email} (¿ya existe en otra comunidad?)")
    log.info("gestor de %s: %s", cid, email)


def entrar(cid):
    """Token del administrador del tenant de la comunidad (lo pide el sysadmin): el
    superusuario entra en la comunidad con acceso completo a su tenant."""
    c = _comunidad(cid)
    sa = _sa()
    u = _usuario_tb(sa, c, c["tenant_email"])
    if not u:
        raise ValueError("La comunidad aún no está en ThingsBoard (pulsa Actualizar ThingsBoard)")
    t = sa.req("GET", f"/api/user/{u['id']['id']}/token")
    if not t or not t.get("token"):
        raise RuntimeError("ThingsBoard no permite entrar como otro usuario (SECURITY_USER_TOKEN_ACCESS_ENABLED)")
    log.info("el superusuario entra en %s como %s", cid, c["tenant_email"])
    return {"token": t["token"], "refreshToken": t.get("refreshToken"), "comunidad": c["nombre"]}


def _num(v, defecto=None):
    try:
        return float(str(v).replace(",", ".")) if v not in (None, "") else defecto
    except ValueError:
        raise ValueError(f"Número no válido: {v}")


# ---------------- participantes (gestor de la comunidad en curso) ----------------
def socios_detalle():
    from . import cec
    out = []
    with db.conectar() as cx:
        fuera = cec.deshabilitados(cx)
        for so in db.socios():
            s = cec.suministro_de(cx, so["id"])
            ext = cec.extension(cx, [s["cups"]]) if s else None
            out.append({**{k: so[k] for k in ("id", "nombre", "email", "nif", "lat", "lon")},
                        "cups": (s and s["cups"]) or so["cups"], "csv": bool(so["carpeta"]),
                        "alta": so["alta"].isoformat(), "deshabilitado": so["id"] in fuera,
                        "datos_desde": ext and ext["desde"] and ext["desde"].isoformat(),
                        "datos_hasta": ext and ext["hasta"] and ext["hasta"].isoformat(),
                        "lecturas": ext["n"] if ext else 0})
    return out


def _datos_socio(d, nuevo):
    cups = (d.get("cups") or "").replace(" ", "").upper() or None
    if cups and not CUPS.match(cups):
        raise ValueError("CUPS no válido (ES + 16 cifras + 2 letras, p. ej. ES0031999900000004LG0F)")
    nif = (d.get("nif") or "").replace(" ", "").upper() or None
    if nif and not re.match(r"^[0-9A-Z]{8,10}$", nif):
        raise ValueError("NIF no válido")
    return {"cups": cups, "nif": nif, "lat": _num(d.get("lat")), "lon": _num(d.get("lon"))}


def alta_socio(d, por):
    c = comunidad()
    nombre = " ".join((d.get("nombre") or "").split())
    sid = slug(nombre)
    email = (d.get("email") or "").strip().lower() or None
    pw = d.get("password") or ""
    if not 2 <= len(nombre) <= 80 or "|" in nombre or not sid or sid == "comunidad":
        raise ValueError("Nombre del participante no válido")
    if email and not EMAIL.match(email):
        raise ValueError("Email no válido")
    if email and len(pw) < 4:
        raise ValueError("Con email (usuario para ver su panel), la contraseña debe tener al menos 4 caracteres")
    x = _datos_socio(d, True)
    if x["lat"] is None or x["lon"] is None:   # cerca del centro de la comunidad
        x["lat"] = (c["lat"] or 37.18) + random.uniform(-0.004, 0.004)
        x["lon"] = (c["lon"] or -3.60) + random.uniform(-0.005, 0.005)
    with db.conectar() as cx:
        if cx.execute("SELECT 1 FROM socio WHERE id = %s", (sid,)).fetchone():
            raise ValueError(f"Ya hay un participante con ese nombre ({sid})")
        cx.execute("INSERT INTO socio (id, nombre, email, cups, nif, lat, lon, por) VALUES (%s, %s, %s, %s, %s, %s, %s, %s)",
                   (sid, nombre, email, x["cups"], x["nif"], x["lat"], x["lon"], por))
    try:
        aprovisionar(c, passwords={sid: pw} if email else None)
    except Exception:
        with db.conectar() as cx:   # sin ThingsBoard no queda a medias
            cx.execute("DELETE FROM socio WHERE id = %s", (sid,))
        raise
    gestion.preparar()           # libro de socios
    return next(s for s in socios_detalle() if s["id"] == sid)


def editar_socio(sid, d):
    x = _datos_socio(d, False)
    with db.conectar() as cx:
        r = cx.execute("UPDATE socio SET cups = %s, nif = %s, lat = COALESCE(%s, lat), lon = COALESCE(%s, lon) "
                       "WHERE id = %s RETURNING id", (x["cups"], x["nif"], x["lat"], x["lon"], sid)).fetchone()
    if not r:
        raise KeyError(sid)
    if x["lat"] is not None or x["lon"] is not None:
        aprovisionar(comunidad())    # ubicacion del rayo en el mapa
    return next(s for s in socios_detalle() if s["id"] == sid)


def baja_socio(sid):
    """Quita al participante de la comunidad y de ThingsBoard (dispositivo, cliente y
    usuario). Sus lecturas se quedan en PostgreSQL (informes de periodos pasados)."""
    c = comunidad()
    with db.conectar() as cx:
        if not cx.execute("DELETE FROM socio WHERE id = %s RETURNING id", (sid,)).fetchone():
            raise KeyError(sid)
        cx.execute("DELETE FROM socio_estado WHERE socio = %s", (sid,))
    aprovisionar(c)
    shutil.rmtree(SUBIDAS / c["id"] / sid, ignore_errors=True)


def carpeta_socio(sid):
    with db.conectar() as cx:
        if not cx.execute("SELECT 1 FROM socio WHERE id = %s", (sid,)).fetchone():
            raise KeyError(sid)
    d = SUBIDAS / comunidad()["id"] / sid
    d.mkdir(parents=True, exist_ok=True)
    return d


def guardar_csv(sid, nombre, tmp):
    """Fichero de la descarga web de Datadis (Consumo_*, Contrato_* o Potencias_*): sustituye
    al anterior del mismo tipo y la carpeta pasa a ser la de los CSV del socio."""
    m = CSV.match(nombre or "")
    if not m:
        raise ValueError("Solo ficheros de Datadis: Consumo_*.csv, Contrato_*.csv o Potencias_*.csv")
    d = Path(tmp).parent
    cab = Path(tmp).read_bytes()[:400].decode("utf-8", "replace").lower()
    if "cups" not in cab or ";" not in cab:
        raise ValueError(f"{nombre}: no parece un CSV de Datadis (separado por ';' con columna cups)")
    tipo = m.group(1).capitalize()
    for viejo in d.glob(f"{tipo}_*.csv"):
        viejo.unlink()
    Path(tmp).rename(d / f"{tipo}_{nombre[len(tipo) + 1:]}")
    with db.conectar() as cx:
        cx.execute("UPDATE socio SET carpeta = %s WHERE id = %s", (str(d), sid))
    return sorted(f.name for f in d.glob("*.csv"))
__FASTAPI_EOF__

cat > config/fastapi/app/copias.py <<'__FASTAPI_EOF__'
"""Copias de seguridad de la base de la comunidad en curso (pestaña "Base de datos" del
panel) en /backups (backups/postgres del stack, la misma carpeta que la copia diaria del
servicio pg-backup).

Nombres: <base>-AAAA-MM-DD.dump (diaria, pg-backup) y <base>-<tipo>-AAAAMMDD-HHMMSS.dump
(tipo: manual, subida o previa = estado anterior a una restauracion). Formato pg_dump -Fc.
Cada gestor ve solo las copias de la base de su comunidad (cec, cec_demo2...). La base de
ThingsBoard es comun a todos los tenants: su copia es la diaria y se restaura a mano
(ver el README del stack)."""
import os
import re
import subprocess
from datetime import datetime
from pathlib import Path

from .comun import TZL, comunidad

DIR = Path(os.environ.get("BACKUP_DIR", "/backups"))


def _base():
    return comunidad()["base"]


def _re(base):
    b = re.escape(base)
    return re.compile(rf"^({b})-(\d{{4}}-\d{{2}}-\d{{2}})\.dump$"), \
        re.compile(rf"^({b})-(manual|subida|previa)-(\d{{8}}-\d{{6}})\.dump$")


def bases():
    return [{"id": _base(), "nombre": "Datos de la comunidad", "restaurable": True}]


def _pg(*args, timeout=3600):
    """Ejecuta pg_dump / pg_restore (PGHOST, PGUSER y PGPASSWORD vienen del entorno)."""
    env = dict(os.environ, PGOPTIONS="-c lock_timeout=30s")
    r = subprocess.run(args, env=env, capture_output=True, text=True, timeout=timeout)
    if r.returncode:
        raise RuntimeError((r.stderr or r.stdout or "error desconocido").strip()[-1500:])
    return r.stdout


def _info(f):
    diaria, otra = _re(_base())
    m, o = diaria.match(f.name), otra.match(f.name)
    if not (m or o):
        return None
    st = f.stat()
    return {"nombre": f.name, "base": (m or o).group(1), "restaurable": True, "tipo": "diaria" if m else o.group(2),
            "bytes": st.st_size, "fecha": datetime.fromtimestamp(st.st_mtime, TZL).isoformat(timespec="seconds")}


def listar():
    if not DIR.is_dir():
        return []
    return sorted(filter(None, (_info(f) for f in DIR.glob("*.dump"))), key=lambda x: x["fecha"], reverse=True)


def ruta(nombre):
    """Fichero de una copia de la comunidad (solo nombres de copia validos: nada de rutas)."""
    if not (DIR / nombre).is_file() or "/" in nombre or not _info(DIR / nombre):
        raise KeyError(nombre)
    return DIR / nombre


def _nuevo(tipo):
    return DIR / f"{_base()}-{tipo}-{datetime.now(TZL):%Y%m%d-%H%M%S}.dump"


def crear(bases=None, tipo="manual"):
    """Copia ahora (pg_dump -Fc) de la base de la comunidad; devuelve sus datos."""
    if bases and set(bases) != {_base()}:
        raise ValueError("Solo se puede copiar la base de la comunidad")
    f = _nuevo(tipo)
    tmp = f.with_suffix(".tmp")
    try:
        _pg("pg_dump", "-Fc", "-d", _base(), "-f", str(tmp))
        tmp.rename(f)
    finally:
        tmp.unlink(missing_ok=True)
    return [_info(f)]


def subir(tmp):
    """Guarda como copia de la comunidad un fichero subido, si es un volcado pg_dump -Fc valido."""
    try:
        lista = _pg("pg_restore", "-l", str(tmp), timeout=300)
    except RuntimeError:
        raise ValueError("El fichero no es una copia de PostgreSQL (pg_dump -Fc)")
    if "TABLE public lectura " not in lista and "TABLE public suministro " not in lista:
        raise ValueError("La copia no es de una base de datos de comunidad")
    f = _nuevo("subida")
    Path(tmp).rename(f)
    return _info(f)


def borrar(nombre):
    ruta(nombre).unlink()


def restaurar(nombre):
    """Sustituye la base de la comunidad por la copia, en una sola transaccion (si algo falla
    no cambia nada). Antes guarda el estado actual como copia "previa"."""
    f = ruta(nombre)
    previa = crear(None, "previa")[0]
    _pg("pg_restore", "--clean", "--if-exists", "--no-owner", "--single-transaction", "-d", _base(), str(f))
    return {"restaurada": nombre, "previa": previa}
__FASTAPI_EOF__

cat > config/fastapi/app/main.py <<'__FASTAPI_EOF__'
"""API de la comunidad energetica (sustituye a Node-RED en el stack iot-tb).

Se publica a traves de Caddy en https://<servidor>/cec-api (mismo origen que ThingsBoard:
sin CORS). Autenticacion:
  - JWT de ThingsBoard (cabecera X-Authorization: Bearer ..., la que ya usa el panel):
    administradores (TENANT_ADMIN) del tenant de una comunidad, que solo ven la suya; y el
    superusuario (SUPER_EMAIL, tenant Plataforma) para las rutas /plataforma.
  - X-Api-Key: API_KEY del .env, para el script de instalacion y tareas del servidor; la
    comunidad va en la cabecera X-Comunidad (por defecto, la primera).
"""
import asyncio
import secrets
import time
from contextlib import asynccontextmanager
from datetime import date, timedelta
from typing import Literal

from apscheduler.schedulers.asyncio import AsyncIOScheduler
from apscheduler.triggers.cron import CronTrigger
from fastapi import Depends, FastAPI, Header, HTTPException, Query, Request, Response
from fastapi.responses import FileResponse, JSONResponse
from pydantic import BaseModel, Field

from . import cec, copias, db, gestion, informes, plataforma, tb
from .comun import COMUNIDAD, E, TZL, comunidad, config, datadis_configurado, log
from .puente import Puente

SYNC_HORA = E.get("SYNC_HORA") or "07:15"
PLAN = AsyncIOScheduler(timezone=TZL)
PUENTE = Puente()
TAREAS = set()
_LANZAR = asyncio.Lock()


@asynccontextmanager
async def vida(app):
    await asyncio.to_thread(plataforma.preparar)
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


def _api_key(x_api_key):
    if E.get("API_KEY") and secrets.compare_digest(x_api_key, E["API_KEY"]):
        return True
    raise HTTPException(401, "API key no válida")


async def _usuario_tb(x_authorization, authorization):
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
    return u


async def admin(x_api_key: str | None = Header(None),
                x_authorization: str | None = Header(None),
                authorization: str | None = Header(None),
                x_comunidad: str | None = Header(None)) -> str:
    """Gestor (o administrador del tenant) de una comunidad: la deja como comunidad en curso
    de la peticion (comun.COMUNIDAD)."""
    if x_api_key and _api_key(x_api_key):
        c = await asyncio.to_thread(plataforma.por_id, x_comunidad) if x_comunidad else \
            next(iter(await asyncio.to_thread(plataforma.lista)), None)
        if not c:
            raise HTTPException(404, "No existe esa comunidad")
        COMUNIDAD.set(c)
        return "api-key"
    u = await _usuario_tb(x_authorization, authorization)
    c = await asyncio.to_thread(plataforma.por_tenant, (u.get("tenantId") or {}).get("id")) \
        if u.get("authority") == "TENANT_ADMIN" else None
    if not c:
        raise HTTPException(403, "Solo para administradores de la comunidad")
    if c["gestor_estado"] != "activo" and (u.get("email") or "").lower() == (c["gestor_email"] or "").lower():
        raise HTTPException(403, "Acceso bloqueado por la plataforma")
    COMUNIDAD.set(c)
    return u.get("email") or "admin"


async def superusuario(x_api_key: str | None = Header(None),
                       x_authorization: str | None = Header(None),
                       authorization: str | None = Header(None)) -> str:
    """Superusuario de la plataforma (SUPER_EMAIL): crea comunidades y sus gestores."""
    if x_api_key and _api_key(x_api_key):
        return "api-key"
    u = await _usuario_tb(x_authorization, authorization)
    if u.get("authority") != "TENANT_ADMIN" or not E.get("SUPER_EMAIL") or \
            (u.get("email") or "").lower() != E["SUPER_EMAIL"].lower():
        raise HTTPException(403, "Solo para el superusuario de la plataforma")
    return u["email"]


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
    """Una sincronizacion por comunidad (cada una en su base y su tenant)."""
    for c in await asyncio.to_thread(plataforma.lista):
        tok = COMUNIDAD.set(c)   # la tarea de lanzar() copia este contexto
        try:
            jid = await lanzar("auto", None, None, False, None, "programada")
            log.info("sincronización programada de %s: %s", c["id"], jid)
        except Ocupado as o:
            log.info("sincronización programada de %s omitida: ya hay una en curso (%s)", c["id"], o.jid)
        except Exception:
            log.exception("sincronización programada de %s", c["id"])
        finally:
            COMUNIDAD.reset(tok)


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
    socios = (await asyncio.to_thread(config))["socios"]
    if socio_id not in {so["id"] for so in socios}:
        raise HTTPException(404, "No existe ese socio")
    await asyncio.to_thread(cec.fijar_deshabilitado, socio_id, p.deshabilitado, quien)
    return {"socio": socio_id, "deshabilitado": p.deshabilitado,
            **await asyncio.to_thread(cec.comunidad_pendiente, socios)}


@app.get("/comunidad/pendiente", summary="¿Hay socios habilitados o deshabilitados sin recalcular la comunidad?")
async def comunidad_pendiente(_: str = Depends(admin)):
    return await asyncio.to_thread(lambda: cec.comunidad_pendiente(config()["socios"]))


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


# ---------------- gestion de la comunidad (paneles "Gestión · ...") ----------------
def _gestion(f, *a):
    """Errores de gestion -> HTTP: registro o documento inexistente 404, datos no validos 422."""
    try:
        return f(*a)
    except KeyError as e:
        raise HTTPException(404, f"No existe: {e.args[0] if e.args else ''}")
    except ValueError as e:
        raise HTTPException(422, str(e))


@app.get("/gestion/esquema", summary="Areas de gestion, registros, campos y documentos")
async def gestion_esquema(_: str = Depends(admin)):
    return await asyncio.to_thread(gestion.esquema)


@app.get("/gestion/archivo/{did}", summary="Descarga un documento generado (PDF)")
async def gestion_pdf(did: str, _: str = Depends(admin)):
    contenido, nombre = await asyncio.to_thread(_gestion, gestion.pdf, did)
    return Response(contenido, media_type="application/pdf", headers={"Content-Disposition": f'attachment; filename="{nombre}"'})


@app.delete("/gestion/archivo/{did}", summary="Borra un documento del archivo")
async def gestion_pdf_borrar(did: str, _: str = Depends(admin)):
    await asyncio.to_thread(_gestion, gestion.borrar_documento, did)
    return {"ok": True}


@app.get("/gestion/reparto/coeficientes.txt", summary="Fichero de coeficientes de reparto para la distribuidora")
async def gestion_coeficientes(desde: date, hasta: date, criterio: str = "Consumo", modo: str = "Fijos",
                               _: str = Depends(admin)):
    if hasta < desde:
        raise HTTPException(422, "desde es posterior a hasta")
    txt = await asyncio.to_thread(gestion.fichero_coeficientes, desde.isoformat(), hasta.isoformat(), criterio, modo)
    nombre = f"coeficientes_{'horarios' if modo.startswith('Variables') else 'fijos'}_{desde:%Y%m%d}-{hasta:%Y%m%d}.txt"
    return Response(txt.encode("utf-8"), media_type="text/plain; charset=utf-8",
                    headers={"Content-Disposition": f'attachment; filename="{nombre}"'})


@app.get("/gestion/{area}/documentos", summary="Documentos generados de un area")
async def gestion_documentos(area: str, _: str = Depends(admin)):
    filas = await asyncio.to_thread(gestion.documentos, area)
    return [dict(f, id=str(f["id"])) for f in filas]


@app.post("/gestion/{area}/documentos/{doc}", status_code=201, summary="Genera un documento PDF y lo archiva")
async def gestion_generar(area: str, doc: str, parametros: dict, quien: str = Depends(admin)):
    return await asyncio.to_thread(_gestion, gestion.generar, area, doc, parametros, quien)


@app.get("/gestion/{area}/{tipo}", summary="Registros de un tipo")
async def gestion_listar(area: str, tipo: str, _: str = Depends(admin)):
    def f():
        with db.conectar() as cx:
            return gestion.listar(cx, area, tipo)
    return await asyncio.to_thread(_gestion, f)


@app.post("/gestion/{area}/{tipo}", status_code=201, summary="Crea un registro")
async def gestion_crear(area: str, tipo: str, datos: dict, quien: str = Depends(admin)):
    return {"id": await asyncio.to_thread(_gestion, gestion.guardar, area, tipo, datos, quien)}


@app.put("/gestion/{area}/{tipo}/{rid}", summary="Modifica un registro")
async def gestion_modificar(area: str, tipo: str, rid: str, datos: dict, quien: str = Depends(admin)):
    return {"id": await asyncio.to_thread(_gestion, gestion.guardar, area, tipo, datos, quien, rid)}


@app.delete("/gestion/{area}/{tipo}/{rid}", summary="Borra un registro")
async def gestion_borrar(area: str, tipo: str, rid: str, _: str = Depends(admin)):
    await asyncio.to_thread(_gestion, gestion.borrar, area, tipo, rid)
    return {"ok": True}


# ---------------- copias de seguridad (pestaña "Base de datos") ----------------
def _copias(f, *a):
    try:
        return f(*a)
    except KeyError:
        raise HTTPException(404, "No existe esa copia")
    except ValueError as e:
        raise HTTPException(422, str(e))
    except RuntimeError as e:
        raise HTTPException(500, f"PostgreSQL: {e}")


class PeticionCopia(BaseModel):
    bases: list[str] | None = Field(None, description="Bases a copiar (ver GET /copias/bases); por defecto, la de la comunidad")


@app.get("/copias/bases", summary="Bases de datos que se pueden copiar desde esta API")
async def copias_bases(_: str = Depends(admin)):
    return copias.bases()


@app.get("/copias", summary="Copias de seguridad de PostgreSQL (diarias, manuales, subidas y previas)")
async def copias_lista(_: str = Depends(admin)):
    return await asyncio.to_thread(copias.listar)


@app.post("/copias", status_code=201, summary="Hace ahora una copia de las bases pedidas")
async def copias_crear(p: PeticionCopia, _: str = Depends(admin)):
    return await asyncio.to_thread(_copias, copias.crear, p.bases)


@app.post("/copias/subir", status_code=201, summary="Sube una copia de la base de la comunidad (fichero .dump, cuerpo binario)")
async def copias_subir(request: Request, _: str = Depends(admin)):
    tmp = copias.DIR / f".subida-{secrets.token_hex(8)}.tmp"
    try:
        with open(tmp, "wb") as f:
            async for trozo in request.stream():
                f.write(trozo)
        return await asyncio.to_thread(_copias, copias.subir, tmp)
    finally:
        tmp.unlink(missing_ok=True)


@app.get("/copias/{nombre}", summary="Descarga una copia")
async def copias_descargar(nombre: str, _: str = Depends(admin)):
    f = _copias(copias.ruta, nombre)
    return FileResponse(f, media_type="application/octet-stream", filename=nombre)


@app.delete("/copias/{nombre}", summary="Borra una copia")
async def copias_borrar(nombre: str, _: str = Depends(admin)):
    await asyncio.to_thread(_copias, copias.borrar, nombre)
    return {"ok": True}


@app.post("/copias/{nombre}/restaurar", summary="Restaura la base de la comunidad desde una copia (antes guarda la actual)")
async def copias_restaurar(nombre: str, quien: str = Depends(admin)):
    async with _LANZAR:   # ninguna sincronizacion puede empezar mientras se restaura
        activo = await asyncio.to_thread(db.job_activo)
        if activo:
            raise Ocupado(activo)
        r = await asyncio.to_thread(_copias, copias.restaurar, nombre)
        # La copia puede ser anterior a tablas nuevas: se crean las que falten
        await asyncio.to_thread(db.preparar)
        await asyncio.to_thread(gestion.preparar)
    log.info("base %s restaurada desde %s por %s (copia previa %s)", comunidad()["base"], nombre, quien, r["previa"]["nombre"])
    return r


# ---------------- participantes (pestaña "Participantes" del gestor) ----------------
def _plat(f, *a):
    try:
        return f(*a)
    except KeyError:
        raise HTTPException(404, "No existe ese participante o esa comunidad")
    except ValueError as e:
        raise HTTPException(422, str(e))
    except RuntimeError as e:
        raise HTTPException(502, str(e))


@app.get("/socios", summary="Participantes de la comunidad con el estado de sus datos")
async def socios_lista(_: str = Depends(admin)):
    return await asyncio.to_thread(plataforma.socios_detalle)


@app.post("/socios", status_code=201, summary="Da de alta un participante (crea su dispositivo, cliente y usuario)")
async def socios_alta(datos: dict, quien: str = Depends(admin)):
    return await asyncio.to_thread(_plat, plataforma.alta_socio, datos, quien)


@app.put("/socios/{socio_id}", summary="Cambia el CUPS, el NIF del titular o la ubicación de un participante")
async def socios_editar(socio_id: str, datos: dict, _: str = Depends(admin)):
    return await asyncio.to_thread(_plat, plataforma.editar_socio, socio_id, datos)


@app.delete("/socios/{socio_id}", summary="Da de baja un participante (sus lecturas se conservan)")
async def socios_baja(socio_id: str, _: str = Depends(admin)):
    async with _LANZAR:
        if await asyncio.to_thread(db.job_activo):
            raise HTTPException(409, "Hay una sincronización en curso; prueba cuando termine")
        await asyncio.to_thread(_plat, plataforma.baja_socio, socio_id)
    return {"ok": True}


@app.post("/socios/{socio_id}/csv", status_code=201,
          summary="Sube un fichero de la descarga web de Datadis (cuerpo binario; ?fichero=Consumo_....csv)")
async def socios_csv(socio_id: str, request: Request, fichero: str = Query(...), _: str = Depends(admin)):
    d = await asyncio.to_thread(_plat, plataforma.carpeta_socio, socio_id)
    tmp, n = d / f".subida-{secrets.token_hex(8)}.tmp", 0
    try:
        with open(tmp, "wb") as f:
            async for trozo in request.stream():
                n += len(trozo)
                if n > 200 * 1024 * 1024:
                    raise HTTPException(413, "Fichero demasiado grande (máximo 200 MB)")
                f.write(trozo)
        return {"ficheros": await asyncio.to_thread(_plat, plataforma.guardar_csv, socio_id, fichero, tmp)}
    finally:
        tmp.unlink(missing_ok=True)


# ---------------- plataforma (superusuario) ----------------
@app.get("/plataforma/comunidades", summary="Comunidades de la plataforma")
async def plataforma_lista(_: str = Depends(superusuario)):
    return await asyncio.to_thread(plataforma.resumen)


@app.post("/plataforma/comunidades", status_code=201,
          summary="Crea una comunidad: tenant de ThingsBoard, base de datos, paneles y su gestor")
async def plataforma_crear(datos: dict, quien: str = Depends(superusuario)):
    try:
        return await asyncio.to_thread(plataforma.crear_comunidad, datos, quien)
    except ValueError as e:
        raise HTTPException(422, str(e))
    except RuntimeError as e:
        raise HTTPException(502, str(e))


@app.post("/plataforma/comunidades/{cid}/aprovisionar",
          summary="Vuelve a crear o actualizar en ThingsBoard lo de una comunidad (paneles, usuarios...)")
async def plataforma_aprovisionar(cid: str, _: str = Depends(superusuario)):
    c = await asyncio.to_thread(plataforma.por_id, cid)
    if not c:
        raise HTTPException(404, "No existe esa comunidad")
    try:
        return {"salida": await asyncio.to_thread(plataforma.aprovisionar, c)}
    except RuntimeError as e:
        raise HTTPException(502, str(e))


class PeticionBloqueo(BaseModel):
    bloqueado: bool


class PeticionGestor(BaseModel):
    email: str
    password: str


@app.put("/plataforma/comunidades/{cid}/gestor/bloqueo", summary="Bloquea o desbloquea el acceso del gestor")
async def plataforma_bloqueo(cid: str, p: PeticionBloqueo, _: str = Depends(superusuario)):
    await asyncio.to_thread(_plat, plataforma.bloquear_gestor, cid, p.bloqueado)
    return {"ok": True}


@app.delete("/plataforma/comunidades/{cid}/gestor", summary="Quita al gestor (borra su usuario)")
async def plataforma_quitar_gestor(cid: str, _: str = Depends(superusuario)):
    await asyncio.to_thread(_plat, plataforma.quitar_gestor, cid)
    return {"ok": True}


@app.put("/plataforma/comunidades/{cid}/gestor", summary="Asigna un gestor nuevo (sustituye al anterior)")
async def plataforma_asignar_gestor(cid: str, p: PeticionGestor, _: str = Depends(superusuario)):
    await asyncio.to_thread(_plat, plataforma.asignar_gestor, cid, p.email, p.password)
    return {"ok": True}


@app.post("/plataforma/comunidades/{cid}/entrar",
          summary="Token para entrar en la comunidad como administrador de su tenant")
async def plataforma_entrar(cid: str, quien: str = Depends(superusuario)):
    r = await asyncio.to_thread(_plat, plataforma.entrar, cid)
    log.info("%s entra en la comunidad %s", quien, cid)
    return r


@app.post("/plataforma/aprovisionar", summary="Aprovisiona todas las comunidades (lo usa iot-thingsboard.sh)")
async def plataforma_aprovisionar_todas(_: str = Depends(superusuario)):
    try:
        return await asyncio.to_thread(plataforma.aprovisionar_todas)
    except RuntimeError as e:
        raise HTTPException(502, str(e))


@app.exception_handler(Ocupado)
async def _ocupado(_, o):
    return JSONResponse({"detail": {"mensaje": "Ya hay una sincronización en curso", "job_id": o.jid}}, 409)
__FASTAPI_EOF__

# config.json de la API: clientes simulados y comunidades de partida (las del script, con
# sus socios; la API las guarda en la base "plataforma" y en la de cada comunidad). Las
# contraseñas solo se usan para crear los usuarios que aun no existen.
SOCIOS="$(printf '%s\n' "${SOCIOS[@]}")" SOCIOS2="$(printf '%s\n' "${SOCIOS2[@]}")" \
CLIENTES="$(printf '%s\n' "${CLIENTES[@]}")" TB_GATEWAY_NAME="$TB_GATEWAY_NAME" SIM_INTERVAL="$SIM_INTERVAL" \
DATOS_VERSION="$DATOS_VERSION" \
C1="$CEC_ID|$CEC_NOMBRE|cec|$TB_TENANT_EMAIL|$CEC_ADMIN_EMAIL|$CEC_ADMIN_PASSWORD|$CEC_ADMIN_ANTERIOR_EMAIL|$CEC_ADMIN_ANTERIOR_PASSWORD|36.6660|-4.4990" \
C2="$CEC2_ID|$CEC2_NOMBRE|cec_$CEC2_ID|$CEC2_TENANT_EMAIL|$CEC2_ADMIN_EMAIL|$CEC2_ADMIN_PASSWORD|||37.1796|-3.6027" \
python3 - config/fastapi/config.json <<'PY'
import json, os, re, sys, unicodedata
E = os.environ


def slug(texto):   # el mismo que en la configuracion de ThingsBoard (paso 9)
    t = unicodedata.normalize("NFD", str(texto)).encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", "-", t).strip("-")


def socios(texto):
    out = []
    for l in texto.splitlines():
        if l.strip():
            nombre, email, pw, carpeta, lat, lon = (l.split("|") + [""] * 6)[:6]
            out.append({"id": slug(nombre), "nombre": nombre.strip(), "email": email.strip(), "password": pw,
                        "carpeta": carpeta.strip(), "lat": float(lat) if lat.strip() else None,
                        "lon": float(lon) if lon.strip() else None})
    return out


def comunidad(linea, texto):
    cid, nombre, base, tenant, gestor, pw, ant, ant_pw, lat, lon = linea.split("|")
    return {"id": cid, "nombre": nombre, "base": base, "tenant_email": tenant, "gestor_email": gestor,
            "gestor_password": pw, "anterior_email": ant, "anterior_password": ant_pw,
            "lat": float(lat), "lon": float(lon), "socios": socios(texto)}


clientes = [{"device": p[3], "perfil": p[5]} for p in (l.split("|") for l in E["CLIENTES"].splitlines() if l.strip())
            if len(p) >= 6]
json.dump({"gateway": E["TB_GATEWAY_NAME"], "sim_interval": float(E["SIM_INTERVAL"]),
           "datos_version": int(E["DATOS_VERSION"]), "clientes": clientes,
           "comunidades": [comunidad(E["C1"], E["SOCIOS"]), comunidad(E["C2"], E["SOCIOS2"])]},
          open(sys.argv[1], "w", encoding="utf-8"), ensure_ascii=False, indent=2)
os.chmod(sys.argv[1], 0o644)
PY
rm -f config/fastapi/config-*.json

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
/* Pestañas de gestion de la comunidad (widget VatiaCo.nav, arriba del panel): siempre
   visibles al desplazar el panel */
gridster-item:has(.vl-nav-w) { position: sticky !important; top: 0; z-index: 20; }
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
  gridster-item:has(.vl-nav-w) { display: none !important; }
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
  echo "	# API de las comunidades (FastAPI): mismo origen que ThingsBoard, sin CORS. Valida el"
  echo "	# JWT de ThingsBoard que manda el panel (gestores y superusuario)."
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
        href: http://localhost:$ADMINER_PORT/?pgsql=postgres&username=$PG_USER&db=thingsboard
        description: "GUI de PostgreSQL · $PG_USER / $PG_PASSWORD · solo 127.0.0.1 (desde otro equipo: ssh -L $ADMINER_PORT:127.0.0.1:$ADMINER_PORT)"
        icon: adminer
        server: my-docker
        container: iot-adminer



- Web:
    - VatiaCo (proman):
        href: http://$IP:$PROMAN_PORT
        description: "Web Astro de $PROMAN_DIR · sin autenticación · puerto $PROMAN_PORT · recompilar: $INSTALL_DIR/web.sh"
        icon: astro
        server: my-docker
        container: iot-proman


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

  # Copia diaria (pg_dump -Fc) de thingsboard, plataforma y las comunidades (cec, cec_*) en backups/postgres: una al arrancar
  # y otra cada dia a las 03:00; se borran las diarias de mas de 7 dias (las que se hacen o
  # suben desde la pestaña Base de datos del panel se conservan hasta borrarlas alli).
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
          for db in $$(psql -d thingsboard -Atc "SELECT datname FROM pg_database WHERE datname IN ('thingsboard', 'plataforma') OR datname = 'cec' OR datname LIKE 'cec\\_%' ORDER BY 1"); do
            f=/backups/$$db-$$(date +%F).dump
            if pg_dump -Fc -d "$$db" -f "$$f.tmp"; then mv "$$f.tmp" "$$f"; echo "copia: $$f"
            else rm -f "$$f.tmp"; echo "ERROR: fallo la copia de PostgreSQL ($$db)" >&2; fi
          done
          find /backups -name '*-[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].dump' -mtime +7 -delete
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

  # API de las comunidades (config/fastapi, paso 4): una para todas (cada una con su tenant y
  # su base: registro en la base "plataforma"). Sincronizacion diaria con Datadis
  # (PostgreSQL -> ThingsBoard), informes, gestion, participantes, alta de comunidades
  # (ejecuta config/tb-config.py) y simuladores
  # (publican en ThingsBoard por MQTT, Gateway API). Sin puertos publicados: Caddy la sirve en https://<servidor>/cec-api.
  # Un unico worker de uvicorn (Dockerfile): la sincronizacion programada no se duplica.
  fastapi:
    <<: *common
    build:
      context: ./config/fastapi
      args:
        PY_VERSION: ${FASTAPI_PY_VERSION}
        PG_MAJOR: ${PG_MAJOR}
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
      TB_SYSADMIN_PASSWORD: ${TB_SYSADMIN_PASSWORD}
      TB_LANG: ${TB_LANG}
      SUPER_EMAIL: ${SUPER_EMAIL}
      TENANT_DOMINIO: ${TENANT_DOMINIO}
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
      - ./config/tb-config.py:/srv/tb-config.py:ro
      - ${DATADIS_DIR}:/datadis:ro
      - ./backups/postgres:/backups
      - ./data/subidas:/subidas
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

  # GUI web de PostgreSQL (servidor "postgres", usuario/contraseña de Postgres)
  adminer:
    <<: *common
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
# Parar/arrancar Adminer a mano: ./tools.sh down | ./tools.sh up
cat > tools.sh <<'EOF'
#!/bin/bash
# Adminer (127.0.0.1:8081). Desde otro equipo:
#   ssh -L 8081:127.0.0.1:8081 <usuario>@<servidor>
set -e
cd "$(dirname "$0")"
case "${1:-up}" in
  up)   docker compose up -d adminer ;;
  down) docker compose rm -sf adminer ;;
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
#   CEC_COMUNIDAD=demo2 ./sync.sh ...      otra comunidad (por defecto, la primera)
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
if os.environ.get("CEC_COMUNIDAD"):
    H["X-Comunidad"] = os.environ["CEC_COMUNIDAD"]


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

# Base de datos de la primera comunidad (lecturas de Datadis, sincronizaciones, gestion). La
# API crea las demas (plataforma y cec_<id>) y las tablas de todas
for db_ in cec; do
  if ! docker compose exec -T -e PGPASSWORD="$PG_PASSWORD" postgres \
       psql -U "$PG_USER" -d thingsboard -tAc "SELECT 1 FROM pg_database WHERE datname = '$db_'" | grep -q 1; then
    docker compose exec -T -e PGPASSWORD="$PG_PASSWORD" postgres createdb -U "$PG_USER" "$db_"
    echo "    PostgreSQL: base de datos '$db_' creada"
  fi
done

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
#    config/tb-config.py: aqui, la ejecucion base (sysadmin, gateway, CLIENTES, superusuario);
#    la API lo ejecuta para cada comunidad (su tenant, que crea si no existe, gestor, socios
#    y paneles) al aprovisionar, al crear una comunidad y al dar de alta o baja un socio.
# --------------------------------------------
cat > config/tb-config.py <<'PY'
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
min_len = min(6, *(len(x) for x in [E["TB_SYSADMIN_PASSWORD"], E["TB_TENANT_PASSWORD"], E.get("CEC_ADMIN_PASSWORD", ""),
                                     E.get("SUPER_PASSWORD", ""), *(c["password"] for c in CLIENTES),
                                     *(l.split("|")[2] for l in E.get("SOCIOS", "").splitlines()
                                       if l.count("|") >= 2 and l.split("|")[1])] if x))
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

def activar(client, u, password):
    """Activa un usuario recien creado con su contraseña (sin correo de activacion)."""
    link = http("GET", f"{TB}/api/user/{u['id']['id']}/activationLink", headers=client.h, raw=True)
    token = urllib.parse.parse_qs(urllib.parse.urlparse(link.strip().strip('"')).query)["activateToken"][0]
    http("POST", TB + "/api/noauth/activate?sendActivationMail=false", {"activateToken": token, "password": password})


# Administrador del tenant: tenant@thingsboard.org pasa a TB_TENANT_EMAIL. Otra comunidad
# (CEC_TENANT): su tenant y su administrador se crean si no existen.
tenant_email = E["TB_TENANT_EMAIL"]
if E.get("CEC_TENANT"):
    if not tb_login(tenant_email, E["TB_TENANT_PASSWORD"]):
        ten = find(sa.get(page("/api/tenants"))["data"], "title", E["CEC_TENANT"])
        if not ten:
            ten = sa.post("/api/tenant", {"title": E["CEC_TENANT"]})
            print(f"    tenant '{E['CEC_TENANT']}' creado")
        u = sa.post("/api/user?sendActivationMail=false", {
            "email": tenant_email, "authority": "TENANT_ADMIN", "firstName": "pk",
            "tenantId": {"id": ten["id"]["id"], "entityType": "TENANT"},
            "additionalInfo": {"lang": E["TB_LANG"]}})
        activar(sa, u, E["TB_TENANT_PASSWORD"])
        print(f"    administrador del tenant '{tenant_email}' creado")
elif not tb_login(tenant_email, E["TB_TENANT_PASSWORD"]):
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


gw_token = None
if E["TB_GATEWAY_NAME"]:   # solo en el tenant de la primera comunidad (simuladores de CLIENTES)
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
    if not c.get("password"):
        print(f"    AVISO: usuario '{c['email']}' sin contraseña: no se crea")
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

CEC = E.get("CEC_NOMBRE", "")
DATADIS_DIR = E.get("DATADIS_DIR", "")
CEC_DASH_VERSION = 27           # sube este numero para regenerar el panel de la comunidad
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
for l in E.get("SOCIOS", "").splitlines():
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


# Pestañas de gestion de la comunidad (solo administradores): el panel de la comunidad
# (mapa) primero y luego un panel por area de gestion. Las usan el widget VatiaCo.nav,
# arriba del panel de la comunidad, y VatiaCo.gestion. nav: [[area, nombre, titulo del
# panel]]; la pestaña activa es la del area "activo" ("" = comunidad).
NAV_CSS = """
.vl-tabs { display: flex; align-items: flex-end; gap: 2px; overflow-x: auto; scrollbar-width: thin;
  border-bottom: 1px solid #e6e6e6; font: 13px Roboto, Arial, sans-serif; }
.vl-tabs button { flex: none; border: 0; background: none; padding: 9px 14px 7px; font: inherit; font-size: 13.5px;
  color: #555; cursor: pointer; border-bottom: 3px solid transparent; white-space: nowrap; }
.vl-tabs button:hover:not(:disabled) { color: #7b2fa8; background: #faf5fd; }
.vl-tabs button.on { color: #7b2fa8; border-bottom-color: #7b2fa8; font-weight: 500; cursor: default; }
.vl-tabs button:disabled { opacity: .4; cursor: default; }
"""

NAV_JS = r"""
function vlNav(ctx, el, nav, activo) {
  el.innerHTML = nav.map(function (n, i) {
    return '<button type="button" data-i="' + i + '"' + (n[0] === activo ? ' class="on" aria-current="page"' : '') + '>' +
      String(n[1]).replace(/[&<>"]/g, function (x) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[x]; }) +
      '</button>';
  }).join('');
  var on = el.querySelector('.on'); if (on && on.scrollIntoView) on.scrollIntoView({ block: 'nearest', inline: 'nearest' });
  ctx.http.get('/api/tenant/dashboards?pageSize=200&page=0').subscribe(function (r) {
    var ids = {}; (r.data || []).forEach(function (d) { ids[d.title] = d.id.id; });
    [].forEach.call(el.querySelectorAll('button'), function (b) {
      var n = nav[+b.dataset.i], id = ids[n[2]];
      if (!id) { b.disabled = true; return; }
      if (n[0] === activo) return;
      b.onclick = function () {
        if (ctx.router) ctx.router.navigateByUrl('/dashboard/' + id); else location.href = '/dashboard/' + id;
      };
    });
  });
}
"""

# VatiaCo.nav: las pestañas arriba del panel de la comunidad (fijas al desplazar, ver
# VatiaCo.css); a los socios no se les muestran.
NAV_W_CSS = NAV_CSS + """
.vl-nav-w { height: 100%; display: flex; align-items: flex-end; }
.vl-nav-w .vl-tabs { flex: 1; min-width: 0; border-bottom: 0; }
.vl-nav-w.vl-oculto { display: none; }
"""
NAV_W_HTML = """<div class="vl-nav-w"><div class="vl-tabs"></div></div>"""
NAV_W_JS = NAV_JS + r"""
self.onInit = function () {
  var c = self.ctx.$container[0], s = self.ctx.settings || {};
  if ((self.ctx.currentUser || {}).authority !== 'TENANT_ADMIN') { c.querySelector('.vl-nav-w').classList.add('vl-oculto'); return; }
  vlNav(self.ctx, c.querySelector('.vl-tabs'), s.nav || [], s.activo || '');
};
self.onDestroy = function () {};
"""


# VatiaCo.basedatos: copias de seguridad de PostgreSQL (pestaña "Base de datos", solo
# administradores) con la API de la comunidad (/cec-api/copias): hacer una copia ahora,
# subir una, descargar, borrar y restaurar la base de la comunidad (cec, cec_demo2...).
BD_CSS = """
.bd { height: 100%; overflow: auto; font: 13px Roboto, Arial, sans-serif; color: #333; }
.bd-fila { display: flex; flex-wrap: wrap; gap: 12px; }
.bd-caja { flex: 1 1 340px; min-width: 0; border: 1px solid #eee; border-radius: 6px; padding: 8px 10px; margin-bottom: 12px; }
.bd h3 { margin: 0 0 8px; font-size: 14px; font-weight: 700; color: #7b2fa8; }
.bd p { margin: 4px 0; color: #666; font-size: 12px; }
.bd code { background: #f5f5f5; padding: 1px 4px; border-radius: 3px; font-size: 11.5px; word-break: break-all; }
.bd-ctrl { display: flex; flex-wrap: wrap; gap: 6px 12px; align-items: center; margin: 8px 0; }
.bd-ctrl label { display: inline-flex; gap: 4px; align-items: center; color: #555; }
.bd-b { font: inherit; padding: 5px 12px; border: 0; border-radius: 4px; background: #7b2fa8; color: #fff; cursor: pointer; }
.bd-b.sec { background: #f1e6f8; color: #7b2fa8; }
.bd-b.peq { padding: 2px 8px; font-size: 12px; }
.bd-b.peligro { background: #fdecea; color: #c62828; }
.bd-b:disabled { opacity: .5; cursor: default; }
.bd-msg { min-height: 18px; color: #555; } .bd-msg.err { color: #c62828; } .bd-msg.ok { color: #2e7d32; }
.bd table { border-collapse: collapse; width: 100%; }
.bd th, .bd td { text-align: left; padding: 5px 7px; border-bottom: 1px solid #f0f0f0; white-space: nowrap; }
.bd th { font-weight: 700; color: #555; } .bd td.n { text-align: right; } .bd td.acc { text-align: right; }
.bd-chip { display: inline-block; padding: 1px 8px; border-radius: 10px; font-size: 11.5px; background: #eee; color: #555; }
.bd-chip.cec { background: #f1e6f8; color: #7b2fa8; } .bd-chip.previa { background: #fff3e0; color: #b26a00; }
.bd-oculto { display: none; }
"""

BD_HTML = """<div class="bd">
 <div class="bd-fila">
  <section class="bd-caja">
   <h3>Hacer una copia ahora</h3>
   <div class="bd-ctrl bd-bases"></div>
   <div class="bd-ctrl"><button class="bd-b bd-hacer">Hacer copia</button></div>
   <p>Además, cada día a las 03:00 se hace una copia automática (se guardan 7 días).</p>
  </section>
  <section class="bd-caja">
   <h3>Subir una copia</h3>
   <div class="bd-ctrl"><input type="file" class="bd-fich" accept=".dump"><button class="bd-b sec bd-subir">Subir</button></div>
   <p>Fichero <code>.dump</code> de la base de la comunidad (el que se descarga aquí). Después se puede restaurar desde la lista.</p>
  </section>
 </div>
 <div class="bd-msg"></div>
 <section class="bd-caja">
  <h3>Copias guardadas</h3>
  <div class="bd-tabla">Cargando…</div>
  <p><b>Restaurar</b> sustituye todos los datos de la comunidad (lecturas, socios, gestión y documentos) por los de la copia,
   en una sola operación: si algo falla no se cambia nada. Antes se guarda el estado actual como copia <i>previa</i>.
   ThingsBoard se pone al día en la siguiente sincronización (pestaña Datadis).</p>
  <p class="bd-tbnota bd-oculto">La base de ThingsBoard no se restaura desde aquí (hay que pararlo): en el servidor,
   <code>docker compose stop thingsboard &amp;&amp; docker compose exec -T postgres pg_restore -U &lt;usuario&gt; -d thingsboard --clean --if-exists &lt; backups/postgres/&lt;fichero&gt; &amp;&amp; docker compose start thingsboard</code></p>
 </section>
</div>"""

BD_JS = r"""
var API = '/cec-api';
function cab() { return { 'X-Authorization': 'Bearer ' + (localStorage.getItem('jwt_token') || '') }; }
function api(metodo, ruta, cuerpo, crudo, tipo) {
  var h = cab();
  if (cuerpo) h['Content-Type'] = tipo || 'application/json';
  return fetch(API + ruta, { method: metodo, headers: h,
    body: cuerpo ? (tipo ? cuerpo : JSON.stringify(cuerpo)) : undefined }).then(function (r) {
    if (r.ok) return crudo ? r : r.json();
    return r.json().catch(function () { return {}; }).then(function (j) {
      var d = j.detail; throw new Error(typeof d === 'string' ? d : (d && d.mensaje) || 'HTTP ' + r.status); });
  });
}
function esc(t) { return String(t == null ? '' : t).replace(/[&<>"]/g, function (x) {
  return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[x]; }); }
function tam(b) { var u = ['B', 'KB', 'MB', 'GB'], i = 0; while (b >= 1024 && i < 3) { b /= 1024; i++; }
  return b.toLocaleString('es-ES', { maximumFractionDigits: i ? 1 : 0 }) + ' ' + u[i]; }
function fecha(s) { var d = new Date(s); return isNaN(d) ? s : d.toLocaleString('es-ES', { dateStyle: 'short', timeStyle: 'short' }); }
var TIPOS = { diaria: 'diaria', manual: 'manual', subida: 'subida', previa: 'previa a restaurar' };

self.onInit = function () {
  var c = self.ctx.$container[0];
  var q = function (s) { return c.querySelector('.' + s); };
  if ((self.ctx.currentUser || {}).authority !== 'TENANT_ADMIN') { q('bd').classList.add('bd-oculto'); return; }
  function msg(t, tipo) { var m = q('bd-msg'); m.textContent = t || ''; m.className = 'bd-msg' + (tipo ? ' ' + tipo : ''); }
  function ocupado(si) { [].forEach.call(c.querySelectorAll('button'), function (b) { b.disabled = si; }); }
  function tarea(texto, p, ok) {
    ocupado(true); msg(texto);
    return p.then(function (r) { msg(ok(r), 'ok'); }).catch(function (e) { msg(e.message, 'err'); })
      .then(function () { ocupado(false); lista(); });
  }

  function lista() {
    api('GET', '/copias').then(function (filas) {
      if (!filas.length) { q('bd-tabla').innerHTML = '<p>No hay copias.</p>'; return; }
      q('bd-tabla').innerHTML = '<table><tr><th>Fecha</th><th>Base</th><th>Tipo</th><th>Tamaño</th><th>Fichero</th><th></th></tr>' +
        filas.map(function (f) {
          var n = esc(f.nombre);
          return '<tr><td>' + fecha(f.fecha) + '</td><td><span class="bd-chip' + (f.restaurable ? ' cec' : '') + '">' +
            (f.restaurable ? 'Comunidad' : 'ThingsBoard') + '</span></td>' +
            '<td>' + (f.tipo === 'previa' ? '<span class="bd-chip previa">' + TIPOS[f.tipo] + '</span>' : TIPOS[f.tipo] || f.tipo) + '</td>' +
            '<td class="n">' + tam(f.bytes) + '</td><td>' + n + '</td><td class="acc">' +
            '<button class="bd-b sec peq" data-d="' + n + '">Descargar</button> ' +
            (f.restaurable ? '<button class="bd-b peq" data-r="' + n + '">Restaurar</button> ' : '') +
            '<button class="bd-b peligro peq" data-x="' + n + '">Borrar</button></td></tr>';
        }).join('') + '</table>';
      [].forEach.call(c.querySelectorAll('[data-d]'), function (b) { b.onclick = function () { descargar(b.dataset.d); }; });
      [].forEach.call(c.querySelectorAll('[data-r]'), function (b) { b.onclick = function () { restaurar(b.dataset.r); }; });
      [].forEach.call(c.querySelectorAll('[data-x]'), function (b) { b.onclick = function () {
        if (!confirm('¿Borrar la copia ' + b.dataset.x + '?')) return;
        tarea('Borrando…', api('DELETE', '/copias/' + encodeURIComponent(b.dataset.x)), function () { return 'Copia borrada.'; });
      }; });
    }).catch(function (e) { q('bd-tabla').innerHTML = ''; msg('No se pudieron leer las copias: ' + e.message, 'err'); });
  }

  function descargar(n) {
    tarea('Descargando ' + n + '…', api('GET', '/copias/' + encodeURIComponent(n), null, true).then(function (r) { return r.blob(); })
      .then(function (b) {
        var a = document.createElement('a'); a.href = URL.createObjectURL(b); a.download = n;
        document.body.appendChild(a); a.click();
        setTimeout(function () { URL.revokeObjectURL(a.href); a.remove(); }, 2000);
      }), function () { return 'Descargada ' + n + '.'; });
  }

  function restaurar(n) {
    if (!confirm('Se sustituirán TODOS los datos de la comunidad por los de la copia\n' + n +
                 '\n\nAntes se guarda el estado actual como copia previa. ¿Continuar?')) return;
    tarea('Restaurando ' + n + '… (no cierres la página)', api('POST', '/copias/' + encodeURIComponent(n) + '/restaurar'),
      function (r) { return 'Base de la comunidad restaurada desde ' + r.restaurada + '. Estado anterior guardado en ' + r.previa.nombre + '.'; });
  }

  api('GET', '/copias/bases').then(function (bs) {
    q('bd-bases').innerHTML = bs.map(function (b) {
      return '<label><input type="checkbox" value="' + esc(b.id) + '"' + (b.restaurable ? ' checked' : '') + '> ' +
        esc(b.nombre) + ' <code>' + esc(b.id) + '</code></label>';
    }).join('');
    if (bs.some(function (b) { return !b.restaurable; })) q('bd-tbnota').classList.remove('bd-oculto');
  }).catch(function (e) { msg('No se pudieron leer las bases: ' + e.message, 'err'); });
  q('bd-hacer').onclick = function () {
    var bases = [].map.call(c.querySelectorAll('.bd-bases input:checked'), function (i) { return i.value; });
    if (!bases.length) { msg('Elige al menos una base de datos.', 'err'); return; }
    tarea('Haciendo la copia… (la de ThingsBoard puede tardar un poco)', api('POST', '/copias', { bases: bases }),
      function (r) { return 'Copia hecha: ' + r.map(function (f) { return f.nombre + ' (' + tam(f.bytes) + ')'; }).join(', ') + '.'; });
  };
  q('bd-subir').onclick = function () {
    var f = q('bd-fich').files[0];
    if (!f) { msg('Elige un fichero .dump.', 'err'); return; }
    tarea('Subiendo ' + f.name + '…', api('POST', '/copias/subir', f, false, 'application/octet-stream'),
      function (r) { q('bd-fich').value = ''; return 'Copia subida como ' + r.nombre + '. Ya se puede restaurar desde la lista.'; });
  };
  lista();
};
self.onDestroy = function () {};
"""


def w_basedatos(x, y, w, h):
    """Copias de seguridad de PostgreSQL (VatiaCo.basedatos): widget estatico, sin datasource."""
    cfg = {"datasources": [], "showTitle": True, "title": "Copias de seguridad de la base de datos",
           "settings": {}, "backgroundColor": "#fff", "color": "rgba(0,0,0,0.87)", "padding": "8px",
           "dropShadow": True, "enableFullscreen": True, "mobileHeight": 20}
    return _w("tenant.VatiaCo.basedatos", cfg, "static", x, y, w, h)


# Estilo comun de los widgets de alta (participantes y plataforma)
ALTA_CSS = """
.al { height: 100%; overflow: auto; font: 13px Roboto, Arial, sans-serif; color: #333; position: relative; }
.al-caja { border: 1px solid #eee; border-radius: 6px; padding: 8px 10px; margin-bottom: 12px; }
.al h3 { margin: 0 0 8px; font-size: 14px; font-weight: 700; color: #7b2fa8; }
.al p { margin: 4px 0; color: #666; font-size: 12px; }
.al-campos { display: grid; grid-template-columns: repeat(auto-fill, minmax(190px, 1fr)); gap: 8px 12px; }
.al-campos label { display: flex; flex-direction: column; gap: 3px; font-size: 12px; color: #555; }
.al-campos label.ancho { grid-column: 1 / -1; }
.al-campos .req::after { content: ' *'; color: #c62828; }
.al input, .al select { font: inherit; padding: 4px 6px; border: 1px solid #ccc; border-radius: 4px; background: #fff; }
.al-ctrl { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; margin-top: 10px; }
.al-b { font: inherit; padding: 5px 12px; border: 0; border-radius: 4px; background: #7b2fa8; color: #fff; cursor: pointer; }
.al-b.sec { background: #f1e6f8; color: #7b2fa8; } .al-b.peq { padding: 2px 8px; font-size: 12px; }
.al-b.peligro { background: #fdecea; color: #c62828; } .al-b:disabled { opacity: .5; cursor: default; }
.al-msg { min-height: 18px; margin: 4px 0 8px; color: #555; white-space: pre-wrap; }
.al-msg.err { color: #c62828; } .al-msg.ok { color: #2e7d32; }
.al-log { max-height: 160px; overflow: auto; background: #fafafa; border: 1px solid #eee; border-radius: 4px;
  padding: 6px; margin: 6px 0; font: 11.5px/1.45 monospace; white-space: pre-wrap; display: none; }
.al table { border-collapse: collapse; width: 100%; }
.al th, .al td { text-align: left; padding: 5px 7px; border-bottom: 1px solid #f0f0f0; white-space: nowrap; vertical-align: top; }
.al th { font-weight: 700; color: #555; } .al td.acc { text-align: right; } .al td.n { text-align: right; }
.al small { color: #888; }
.al-chip { display: inline-block; padding: 1px 8px; border-radius: 10px; font-size: 11.5px; background: #eee; color: #555; }
.al-chip.ok { background: #e3f4ea; color: #2e7d32; } .al-chip.no { background: #fdecea; color: #c62828; }
.al-oculto { display: none !important; }
"""

# Funciones comunes: llamada a la API de la comunidad con la sesion de ThingsBoard
ALTA_JS = r"""
var API = '/cec-api';
function api(metodo, ruta, cuerpo, tipo) {
  var h = { 'X-Authorization': 'Bearer ' + (localStorage.getItem('jwt_token') || '') };
  if (cuerpo) h['Content-Type'] = tipo || 'application/json';
  return fetch(API + ruta, { method: metodo, headers: h, body: cuerpo ? (tipo ? cuerpo : JSON.stringify(cuerpo)) : undefined })
    .then(function (r) {
      if (r.ok) return r.json();
      return r.json().catch(function () { return {}; }).then(function (j) {
        var d = j.detail; throw new Error(typeof d === 'string' ? d : (d && d.mensaje) || (Array.isArray(d) ? d.map(function (x) { return x.msg; }).join('; ') : 'HTTP ' + r.status));
      });
    });
}
function esc(t) { return String(t == null ? '' : t).replace(/[&<>"]/g, function (x) {
  return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[x]; }); }
function fecha(s) { if (!s) return '–'; var d = new Date(s); return isNaN(d) ? s : d.toLocaleDateString('es-ES'); }
"""

# VatiaCo.participantes: pestaña "Participantes" del gestor. Alta (crea su dispositivo, su
# cliente y, con email, su usuario), datos por la API de Datadis (CUPS y NIF del titular) o
# subiendo los CSV de la descarga web, edicion, baja y carga de sus datos.
PART_HTML = """<div class="al">
 <section class="al-caja">
  <h3>Participantes</h3>
  <div class="al-tabla">Cargando…</div>
 </section>
 <div class="al-msg"></div><div class="al-log"></div>
 <section class="al-caja al-form">
  <h3 class="al-titulo">Nuevo participante</h3>
  <div class="al-campos">
   <label><span class="req">Nombre</span><input class="f-nombre" maxlength="80" placeholder="Nombre y apellidos o entidad"></label>
   <label>Email (usuario para ver su panel)<input class="f-email" type="email"></label>
   <label>Contraseña<input class="f-password" type="text" autocomplete="new-password"></label>
   <label>CUPS<input class="f-cups" placeholder="ES0031…" maxlength="24"></label>
   <label>NIF del titular<input class="f-nif" maxlength="10" placeholder="si no es la cuenta de Datadis"></label>
   <label>Cargar desde (Datadis)<input class="f-desde" type="month"></label>
   <label>Latitud<input class="f-lat" placeholder="automática"></label>
   <label>Longitud<input class="f-lon" placeholder="automática"></label>
   <label class="ancho">Ficheros CSV de Datadis (opcional: Consumo_*, Contrato_*, Potencias_*)<input class="f-csv" type="file" accept=".csv" multiple></label>
  </div>
  <p>Los datos llegan por la <b>API de Datadis</b> con el CUPS (el titular tiene que haber autorizado a la cuenta de la
   plataforma; pon su NIF si no es el de la cuenta) o subiendo los <b>CSV de la descarga web</b> de Datadis, que también dan
   el contrato completo. Sin ubicación, su rayo se coloca cerca del centro de la comunidad.</p>
  <div class="al-ctrl"><button class="al-b al-guardar">Dar de alta</button><button class="al-b sec al-cancelar al-oculto">Cancelar</button></div>
 </section>
</div>"""

PART_JS = ALTA_JS + r"""
var P = { edita: null, filas: [] };
self.onInit = function () {
  var c = self.ctx.$container[0];
  var q = function (s) { return c.querySelector('.' + s); };
  if ((self.ctx.currentUser || {}).authority !== 'TENANT_ADMIN') { q('al').classList.add('al-oculto'); return; }
  var d = new Date(); d.setMonth(d.getMonth() - 12);
  q('f-desde').value = d.getFullYear() + '-' + ('0' + (d.getMonth() + 1)).slice(-2);
  function msg(t, tipo) { var m = q('al-msg'); m.textContent = t || ''; m.className = 'al-msg' + (tipo ? ' ' + tipo : ''); }
  function ocupado(si) { [].forEach.call(c.querySelectorAll('button'), function (b) { b.disabled = si; }); }
  function log(lineas) { var l = q('al-log'); l.style.display = lineas ? 'block' : 'none'; l.textContent = lineas || ''; l.scrollTop = l.scrollHeight; }

  function lista() {
    return api('GET', '/socios').then(function (filas) {
      P.filas = filas;
      if (!filas.length) { q('al-tabla').innerHTML = '<p>Todavía no hay participantes.</p>'; return; }
      q('al-tabla').innerHTML = '<table><tr><th>Participante</th><th>Usuario</th><th>CUPS</th><th>Datos</th><th>Origen</th><th></th></tr>' +
        filas.map(function (f) {
          var datos = f.lecturas ? fecha(f.datos_desde) + ' – ' + fecha(f.datos_hasta) + '<br><small>' + f.lecturas.toLocaleString('es-ES') + ' lecturas</small>'
                                 : '<span class="al-chip no">sin datos</span>';
          return '<tr><td><b>' + esc(f.nombre) + '</b>' + (f.deshabilitado ? ' <span class="al-chip">deshabilitado</span>' : '') +
            '<br><small>' + esc(f.id) + '</small></td><td>' + (f.email ? esc(f.email) : '<small>sin usuario</small>') + '</td>' +
            '<td>' + (f.cups ? esc(f.cups) : '–') + (f.nif ? '<br><small>NIF ' + esc(f.nif) + '</small>' : '') + '</td>' +
            '<td>' + datos + '</td><td>' + (f.csv ? '<span class="al-chip ok">CSV</span> ' : '') + (f.cups ? '<span class="al-chip">API</span>' : '') + '</td>' +
            '<td class="acc"><button class="al-b sec peq" data-c="' + esc(f.id) + '">Cargar datos</button> ' +
            '<label class="al-b sec peq">Subir CSV<input type="file" accept=".csv" multiple data-s="' + esc(f.id) + '" style="display:none"></label> ' +
            '<button class="al-b sec peq" data-e="' + esc(f.id) + '">Editar</button> ' +
            '<button class="al-b peligro peq" data-x="' + esc(f.id) + '">Baja</button></td></tr>';
        }).join('') + '</table>';
      [].forEach.call(c.querySelectorAll('[data-c]'), function (b) { b.onclick = function () { cargar(socio(b.dataset.c)); }; });
      [].forEach.call(c.querySelectorAll('[data-s]'), function (i) { i.onchange = function () {
        var so = socio(i.dataset.s), fs = [].slice.call(i.files); i.value = '';
        tarea(subir(so, fs).then(function () { return cargar(so, true); }));
      }; });
      [].forEach.call(c.querySelectorAll('[data-e]'), function (b) { b.onclick = function () { editar(socio(b.dataset.e)); }; });
      [].forEach.call(c.querySelectorAll('[data-x]'), function (b) { b.onclick = function () {
        var so = socio(b.dataset.x);
        if (!confirm('¿Dar de baja a ' + so.nombre + '?\nSe borran su dispositivo, su cliente y su usuario de ThingsBoard; ' +
                     'sus lecturas se conservan en la base de datos.')) return;
        msg('Dando de baja a ' + so.nombre + '… (actualizando ThingsBoard)');
        tarea(api('DELETE', '/socios/' + encodeURIComponent(so.id)).then(function () { msg(so.nombre + ' dado de baja.', 'ok'); }));
      }; });
    }).catch(function (e) { msg('No se pudieron leer los participantes: ' + e.message, 'err'); });
  }
  function socio(id) { return P.filas.filter(function (f) { return f.id === id; })[0] || { id: id, nombre: id }; }
  function tarea(p) {
    ocupado(true);
    return p.catch(function (e) { msg(e.message, 'err'); }).then(function () { ocupado(false); return lista(); });
  }

  // Ficheros CSV de un socio, uno a uno
  function subir(so, ficheros) {
    return ficheros.reduce(function (p, f) {
      return p.then(function () {
        msg('Subiendo ' + f.name + ' (' + so.nombre + ')…');
        return api('POST', '/socios/' + encodeURIComponent(so.id) + '/csv?fichero=' + encodeURIComponent(f.name), f, 'text/csv');
      });
    }, Promise.resolve());
  }

  // Sincronizacion de un socio y su progreso
  function cargar(so, csv) {
    var desde = (q('f-desde').value || '').replace('-', '/'), hoy = new Date();
    var cuerpo = { origen: csv ? 'csv' : 'auto', socios: [so.id] };
    if (!csv && desde) { cuerpo.desde = desde; cuerpo.hasta = hoy.getFullYear() + '/' + ('0' + (hoy.getMonth() + 1)).slice(-2); }
    msg('Cargando los datos de ' + so.nombre + '…');
    return api('POST', '/sync', cuerpo).catch(function (e) {
      if (/datadis/i.test(e.message) && cuerpo.desde) { delete cuerpo.desde; delete cuerpo.hasta; return api('POST', '/sync', cuerpo); }
      throw e;
    }).then(function (j) { return seguir(j.job_id, so); });
  }
  function seguir(id, so) {
    return new Promise(function (ok, mal) {
      (function paso() {
        api('GET', '/sync/' + id).then(function (j) {
          log((j.log || []).map(function (l) { return l.m; }).join('\n'));
          if (j.estado === 'pendiente' || j.estado === 'en_curso') return setTimeout(paso, 2000);
          msg('Carga de ' + so.nombre + ': ' + ({ ok: 'correcta', con_errores: 'con errores (mira el registro)', error: 'error' }[j.estado] || j.estado) +
              '. Pulsa Recalcular en la tabla de socios del panel de la comunidad si cambia el total.', j.estado === 'ok' ? 'ok' : 'err');
          ok();
        }).catch(mal);
      })();
    });
  }

  function form(f) {
    P.edita = f || null;
    q('al-titulo').textContent = f ? 'Editar ' + f.nombre : 'Nuevo participante';
    q('al-guardar').textContent = f ? 'Guardar cambios' : 'Dar de alta';
    q('al-cancelar').classList.toggle('al-oculto', !f);
    ['nombre', 'email', 'password'].forEach(function (k) { q('f-' + k).disabled = !!f; q('f-' + k).value = f ? (f[k] || '') : ''; });
    ['cups', 'nif', 'lat', 'lon'].forEach(function (k) { q('f-' + k).value = f && f[k] != null ? f[k] : ''; });
    q('f-csv').value = '';
  }
  function editar(f) { form(f); q('al-form').scrollIntoView({ behavior: 'smooth' }); }
  q('al-cancelar').onclick = function () { form(null); };
  q('al-guardar').onclick = function () {
    var v = {}; ['nombre', 'email', 'password', 'cups', 'nif', 'lat', 'lon'].forEach(function (k) { v[k] = q('f-' + k).value.trim(); });
    var ficheros = [].slice.call(q('f-csv').files);
    if (P.edita) {
      var so = P.edita;
      msg('Guardando ' + so.nombre + '…');
      return tarea(api('PUT', '/socios/' + encodeURIComponent(so.id), v).then(function () {
        return ficheros.length ? subir(so, ficheros).then(function () { return cargar(so, true); }) : null;
      }).then(function () { form(null); msg(so.nombre + ': cambios guardados.', 'ok'); }));
    }
    if (!v.nombre) { msg('Pon el nombre del participante.', 'err'); return; }
    if (!v.cups && !ficheros.length && !confirm('Sin CUPS ni ficheros CSV no tendrá datos hasta que los añadas. ¿Darlo de alta igualmente?')) return;
    msg('Dando de alta a ' + v.nombre + '… (creando su dispositivo y su usuario en ThingsBoard)');
    tarea(api('POST', '/socios', v).then(function (so) {
      form(null);
      if (ficheros.length) return subir(so, ficheros).then(function () { return cargar(so, true); });
      if (so.cups) return cargar(so, false);
      msg(so.nombre + ' dado de alta. Añade su CUPS o sus CSV para cargar sus datos.', 'ok');
    }));
  };
  form(null);
  lista();
};
self.onDestroy = function () {};
"""


def w_participantes(x, y, w, h):
    cfg = {"datasources": [], "showTitle": True, "title": "Participantes de la comunidad", "settings": {},
           "backgroundColor": "#fff", "color": "rgba(0,0,0,0.87)", "padding": "8px", "dropShadow": True,
           "enableFullscreen": True, "mobileHeight": 24}
    return _w("tenant.VatiaCo.participantes", cfg, "static", x, y, w, h)


# VatiaCo.plataforma: panel del superusuario (tenant Plataforma). Comunidades de la
# plataforma y alta de una nueva con su gestor (la API crea el tenant, la base de datos,
# los paneles y el usuario del gestor).
PLAT_HTML = """<div class="al">
 <section class="al-caja">
  <h3>Comunidades energéticas</h3>
  <div class="al-tabla">Cargando…</div>
 </section>
 <div class="al-msg"></div><div class="al-log"></div>
 <section class="al-caja">
  <h3>Nueva comunidad y su gestor</h3>
  <div class="al-campos">
   <label><span class="req">Nombre de la comunidad</span><input class="f-nombre" maxlength="80"></label>
   <label>Identificador<input class="f-id" maxlength="30" placeholder="automático"></label>
   <label><span class="req">Email del gestor</span><input class="f-email" type="email"></label>
   <label><span class="req">Contraseña del gestor</span><input class="f-password" type="text" autocomplete="new-password"></label>
   <label>Latitud del centro<input class="f-lat" placeholder="37.18"></label>
   <label>Longitud del centro<input class="f-lon" placeholder="-3.60"></label>
  </div>
  <p>Se crea su tenant de ThingsBoard, su base de datos, su panel con las pestañas de gestión y el usuario del gestor,
   que entra directamente en su comunidad y da de alta a los participantes en la pestaña <b>Participantes</b>. Tarda un minuto.</p>
  <div class="al-ctrl"><button class="al-b al-crear">Crear comunidad</button></div>
 </section>
 <section class="al-caja">
  <h3>Asignar gestor</h3>
  <div class="al-campos">
   <label><span class="req">Comunidad</span><select class="g-com"></select></label>
   <label><span class="req">Email del nuevo gestor</span><input class="g-email" type="email"></label>
   <label><span class="req">Contraseña</span><input class="g-password" type="text" autocomplete="new-password"></label>
  </div>
  <p>Sustituye al gestor actual (se borra su usuario) o da gestor a una comunidad que no lo tiene.</p>
  <div class="al-ctrl"><button class="al-b al-asignar">Asignar gestor</button></div>
 </section>
</div>"""

PLAT_JS = ALTA_JS + r"""
var P = { filas: [] };
self.onInit = function () {
  var c = self.ctx.$container[0];
  var q = function (s) { return c.querySelector('.' + s); };
  function msg(t, tipo) { var m = q('al-msg'); m.textContent = t || ''; m.className = 'al-msg' + (tipo ? ' ' + tipo : ''); }
  function ocupado(si) { [].forEach.call(c.querySelectorAll('button'), function (b) { b.disabled = si; }); }
  function tarea(p) { ocupado(true); return p.catch(function (e) { msg(e.message, 'err'); }).then(function () { ocupado(false); lista(); }); }
  function lista() {
    api('GET', '/plataforma/comunidades').then(function (filas) {
      q('al-tabla').innerHTML = !filas.length ? '<p>No hay comunidades.</p>' :
        '<table><tr><th>Comunidad</th><th>Gestor</th><th class="n">Participantes</th><th>ThingsBoard</th><th>Alta</th><th></th></tr>' +
        filas.map(function (f) {
          var est = { activo: '<span class="al-chip ok">activo</span>', bloqueado: '<span class="al-chip no">bloqueado</span>' }[f.gestor_estado] ||
                    '<span class="al-chip">sin gestor</span>';
          var g = f.gestor_email ? (f.gestor_estado === 'bloqueado'
                    ? '<button class="al-b sec peq" data-d="' + esc(f.id) + '">Desbloquear</button> '
                    : '<button class="al-b sec peq" data-b="' + esc(f.id) + '">Bloquear</button> ') +
                  '<button class="al-b peligro peq" data-q="' + esc(f.id) + '">Quitar gestor</button> ' : '';
          return '<tr><td><b>' + esc(f.nombre) + '</b><br><small>' + esc(f.id) + ' · base ' + esc(f.base) + '</small></td>' +
            '<td>' + esc(f.gestor_email || '–') + '<br>' + est + '</td><td class="n">' + (f.socios == null ? '–' : f.socios) + '</td>' +
            '<td>' + (f.aprovisionada ? '<span class="al-chip ok">lista</span>' : '<span class="al-chip no">pendiente</span>') + '</td>' +
            '<td>' + fecha(f.creada) + '<br><small>' + (f.origen === 'script' ? 'del script' : 'desde el panel') + '</small></td>' +
            '<td class="acc">' + (f.aprovisionada ? '<button class="al-b peq" data-e="' + esc(f.id) + '">Entrar</button> ' : '') + g +
            '<button class="al-b sec peq" data-a="' + esc(f.id) + '">Actualizar ThingsBoard</button></td></tr>';
        }).join('') + '</table>';
      P.filas = filas;
      q('g-com').innerHTML = filas.map(function (f) {
        return '<option value="' + esc(f.id) + '">' + esc(f.nombre) + (f.gestor_email ? ' (' + esc(f.gestor_email) + ')' : ' (sin gestor)') + '</option>';
      }).join('');
      function nombre(id) { return (filas.filter(function (f) { return f.id === id; })[0] || {}).nombre || id; }
      var ruta = function (id) { return '/plataforma/comunidades/' + encodeURIComponent(id); };
      [].forEach.call(c.querySelectorAll('[data-e]'), function (b) { b.onclick = function () {
        var n = nombre(b.dataset.e);
        if (!confirm('Vas a entrar en ' + n + ' como administrador de su tenant (acceso completo).\n' +
                     'Tu sesión de superusuario se cierra: para volver, sal y entra otra vez con tu usuario.')) return;
        msg('Entrando en ' + n + '…'); ocupado(true);
        api('POST', ruta(b.dataset.e) + '/entrar').then(function (t) {
          location.href = '/?accessToken=' + encodeURIComponent(t.token) + (t.refreshToken ? '&refreshToken=' + encodeURIComponent(t.refreshToken) : '');
        }).catch(function (e) { ocupado(false); msg(e.message, 'err'); });
      }; });
      [].forEach.call(c.querySelectorAll('[data-b],[data-d]'), function (b) { b.onclick = function () {
        var id = b.dataset.b || b.dataset.d, bloq = !!b.dataset.b;
        if (bloq && !confirm('¿Bloquear el acceso del gestor de ' + nombre(id) + '? No podrá entrar hasta que lo desbloquees.')) return;
        msg((bloq ? 'Bloqueando' : 'Desbloqueando') + ' al gestor de ' + nombre(id) + '…');
        tarea(api('PUT', ruta(id) + '/gestor/bloqueo', { bloqueado: bloq }).then(function () {
          msg('Gestor de ' + nombre(id) + (bloq ? ' bloqueado.' : ' desbloqueado.'), 'ok'); }));
      }; });
      [].forEach.call(c.querySelectorAll('[data-q]'), function (b) { b.onclick = function () {
        var id = b.dataset.q;
        if (!confirm('¿Quitar al gestor de ' + nombre(id) + '? Se borra su usuario; la comunidad y sus datos se conservan ' +
                     'y puedes asignarle otro gestor.')) return;
        msg('Quitando al gestor de ' + nombre(id) + '…');
        tarea(api('DELETE', ruta(id) + '/gestor').then(function () { msg(nombre(id) + ' se ha quedado sin gestor.', 'ok'); }));
      }; });
      [].forEach.call(c.querySelectorAll('[data-a]'), function (b) { b.onclick = function () {
        msg('Actualizando ThingsBoard de ' + nombre(b.dataset.a) + '…');
        tarea(api('POST', '/plataforma/comunidades/' + encodeURIComponent(b.dataset.a) + '/aprovisionar').then(function (r) {
          var l = q('al-log'); l.style.display = 'block'; l.textContent = r.salida; msg('Comunidad ' + b.dataset.a + ' actualizada.', 'ok');
        }));
      }; });
    }).catch(function (e) { msg('No se pudieron leer las comunidades: ' + e.message, 'err'); });
  }
  q('al-crear').onclick = function () {
    var v = { nombre: q('f-nombre').value.trim(), id: q('f-id').value.trim(), gestor_email: q('f-email').value.trim(),
              gestor_password: q('f-password').value, lat: q('f-lat').value.trim(), lon: q('f-lon').value.trim() };
    if (!v.nombre || !v.gestor_email || !v.gestor_password) { msg('Rellena el nombre, el email y la contraseña del gestor.', 'err'); return; }
    msg('Creando ' + v.nombre + '… (tenant, base de datos, paneles y gestor; un minuto)');
    tarea(api('POST', '/plataforma/comunidades', v).then(function (r) {
      ['nombre', 'id', 'email', 'password', 'lat', 'lon'].forEach(function (k) { q('f-' + k).value = ''; });
      msg('Comunidad ' + r.nombre + ' creada. Su gestor entra con ' + r.gestor_email + ' y da de alta a los participantes en la pestaña Participantes.', 'ok');
    }));
  };
  q('al-asignar').onclick = function () {
    var id = q('g-com').value, email = q('g-email').value.trim(), pw = q('g-password').value;
    if (!id || !email || !pw) { msg('Elige la comunidad y pon el email y la contraseña del gestor.', 'err'); return; }
    var f = P.filas.filter(function (x) { return x.id === id; })[0] || {};
    if (f.gestor_email && f.gestor_email !== email.toLowerCase() &&
        !confirm('Se borra el usuario del gestor actual (' + f.gestor_email + '). ¿Continuar?')) return;
    msg('Asignando gestor a ' + (f.nombre || id) + '…');
    tarea(api('PUT', '/plataforma/comunidades/' + encodeURIComponent(id) + '/gestor', { email: email, password: pw }).then(function () {
      q('g-email').value = ''; q('g-password').value = '';
      msg(email + ' es ahora el gestor de ' + (f.nombre || id) + '.', 'ok');
    }));
  };
  lista();
};
self.onDestroy = function () {};
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
    tipo "timeseries": recibe la ventana de tiempo del panel; "static": sin datos.
    Los widgets hablan con la API de la comunidad de este tenant (CEC_API)."""
    js = js.replace("'/cec-api'", "'" + (E.get("CEC_API") or "/cec-api") + "'")
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
           "dropShadow": True, "enableFullscreen": True, "mobileHeight": 20}
    return _w("tenant.VatiaCo.admin_datos", cfg, "static", x, y, w, h)


def w_nav(activo, x, y, w, h):
    """Pestañas de gestion de la comunidad (VatiaCo.nav), activa la del area "activo"."""
    cfg = {"datasources": [], "showTitle": False, "title": "Gestión de la comunidad",
           "settings": {"nav": nav_gestion(), "activo": activo}, "backgroundColor": "#fff",
           "color": "rgba(0,0,0,0.87)", "padding": "0 8px", "dropShadow": True, "enableFullscreen": False,
           "mobileHeight": 1}
    return _w("tenant.VatiaCo.nav", cfg, "static", x, y, w, h)


# VatiaCo.gestion: un panel por area de gestion de la comunidad (gobernanza, tecnica,
# reparto, economica, tramites, participacion, rgpd). El area va en los ajustes del widget
# (settings.area) y la barra de navegacion en settings.nav. Todo lo demas sale del esquema
# de la API (/cec-api/gestion/esquema): una pestaña por registro (tabla, alta, edicion y
# borrado con un formulario segun el tipo de cada campo) y otra de documentos PDF (con sus
# parametros) y el archivo de los ya generados. Solo administradores.
GESTION_CSS = NAV_CSS + """
.ge { height: 100%; overflow: auto; font: 13px Roboto, Arial, sans-serif; color: #333; position: relative; }
.ge > .vl-tabs { position: sticky; top: 0; z-index: 4; background: #fff; }
.ge-cab { padding: 10px 2px 4px; }
.ge-cab h2 { margin: 0; font-size: 18px; color: #7b2fa8; }
.ge-cab p { margin: 2px 0 0; color: #777; font-size: 12px; }
.ge-tabs { display: flex; flex-wrap: wrap; gap: 2px; border-bottom: 1px solid #e6e6e6; margin: 8px 0; }
.ge-tabs button { border: 0; background: none; padding: 7px 12px; font: inherit; color: #555; cursor: pointer;
  border-bottom: 2px solid transparent; }
.ge-tabs button.on { color: #7b2fa8; border-bottom-color: #7b2fa8; font-weight: 500; }
.ge-barra { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; margin: 6px 0; }
.ge-b { font: inherit; padding: 5px 12px; border: 0; border-radius: 4px; background: #7b2fa8; color: #fff; cursor: pointer; }
.ge-b.sec { background: #f1e6f8; color: #7b2fa8; }
.ge-b.peq { padding: 2px 8px; font-size: 12px; }
.ge-b.peligro { background: #fdecea; color: #c62828; }
.ge-b:disabled { opacity: .5; cursor: default; }
.ge input, .ge select, .ge textarea { font: inherit; padding: 4px 6px; border: 1px solid #ccc; border-radius: 4px; background: #fff; }
.ge-busca { min-width: 200px; }
.ge-n { color: #777; font-size: 12px; }
.ge table { border-collapse: collapse; width: 100%; }
.ge th, .ge td { text-align: left; padding: 5px 7px; border-bottom: 1px solid #f0f0f0; vertical-align: top; }
.ge th { position: sticky; top: 0; background: #fff; color: #555; font-weight: 500; cursor: pointer; white-space: nowrap; }
.ge th:hover { color: #7b2fa8; }
.ge td.num { text-align: right; white-space: nowrap; }
.ge td.acc { white-space: nowrap; text-align: right; }
.ge-docs { display: grid; grid-template-columns: repeat(auto-fill, minmax(300px, 1fr)); gap: 10px; }
.ge-doc { border: 1px solid #eee; border-radius: 6px; padding: 10px; display: flex; flex-direction: column; gap: 6px; }
.ge-doc h4 { margin: 0; font-size: 14px; }
.ge-doc p { margin: 0; color: #777; font-size: 12px; }
.ge-doc label { display: flex; flex-direction: column; gap: 2px; font-size: 12px; color: #555; }
.ge-params { display: grid; grid-template-columns: 1fr 1fr; gap: 6px; }
.ge h3 { font-size: 14px; color: #7b2fa8; margin: 16px 0 6px; }
.ge-msg { position: sticky; bottom: 0; padding: 6px 8px; font-size: 12px; background: #fff; }
.ge-msg.err { color: #c62828; } .ge-msg.ok { color: #2e7d32; }
.ge-modal { position: absolute; inset: 0; background: rgba(0,0,0,.35); display: none; align-items: flex-start;
  justify-content: center; padding: 20px; z-index: 5; overflow: auto; }
.ge-modal.on { display: flex; }
.ge-form { background: #fff; border-radius: 6px; padding: 14px 16px; width: min(720px, 100%); box-shadow: 0 4px 20px rgba(0,0,0,.25); }
.ge-form h4 { margin: 0 0 10px; color: #7b2fa8; font-size: 15px; }
.ge-campos { display: grid; grid-template-columns: repeat(auto-fill, minmax(210px, 1fr)); gap: 8px 12px; }
.ge-campos label { display: flex; flex-direction: column; gap: 3px; font-size: 12px; color: #555; }
.ge-campos label.ancho { grid-column: 1 / -1; }
.ge-campos label.si { flex-direction: row; align-items: center; gap: 6px; }
.ge-campos textarea { min-height: 70px; resize: vertical; }
.ge-campos .req::after { content: ' *'; color: #c62828; }
.ge-pie { display: flex; justify-content: flex-end; gap: 8px; margin-top: 12px; }
.ge-unico { max-width: 760px; }
"""

GESTION_HTML = """<div class="ge">
  <div class="vl-tabs"></div>
  <div class="ge-cab"><h2></h2><p></p></div>
  <div class="ge-tabs"></div>
  <div class="ge-cuerpo"></div>
  <div class="ge-msg"></div>
  <div class="ge-modal"><div class="ge-form"><h4></h4><div class="ge-campos"></div>
    <div class="ge-pie"><button type="button" class="ge-b sec ge-cancelar">Cancelar</button>
    <button type="button" class="ge-b ge-guardar">Guardar</button></div></div></div>
</div>"""

GESTION_JS = VL_COMUN_JS + NAV_JS + r"""
var G = { tab: null, orden: null, asc: true, busca: '', datos: {} };
var API = '/cec-api';
function q(s) { return G.raiz.querySelector(s); }
function esc(t) { return String(t == null ? '' : t).replace(/[&<>"]/g, function (x) {
  return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[x]; }); }
function api(metodo, ruta, cuerpo, crudo) {
  return fetch(API + ruta, { method: metodo, body: cuerpo ? JSON.stringify(cuerpo) : undefined,
    headers: { 'Content-Type': 'application/json', 'X-Authorization': 'Bearer ' + (localStorage.getItem('jwt_token') || '') }
  }).then(function (r) {
    if (r.ok) return crudo ? r : r.json();
    return r.json().catch(function () { return {}; }).then(function (j) {
      throw new Error(typeof j.detail === 'string' ? j.detail : 'HTTP ' + r.status); });
  });
}
function msg(t, tipo) { var m = q('.ge-msg'); m.textContent = t || ''; m.className = 'ge-msg' + (tipo ? ' ' + tipo : ''); }
function fecha(s) { if (!s) return ''; var p = String(s).slice(0, 10).split('-'); return p.length === 3 ? p[2] + '/' + p[1] + '/' + p[0] : s; }
function descargar(r, nombre) {
  var n = (r.headers.get('Content-Disposition') || '').match(/filename="([^"]+)"/);
  return r.blob().then(function (b) {
    var a = document.createElement('a');
    a.href = URL.createObjectURL(b); a.download = n ? n[1] : nombre;
    document.body.appendChild(a); a.click();
    setTimeout(function () { URL.revokeObjectURL(a.href); a.remove(); }, 2000);
    return a.download;
  });
}

self.onInit = function () {
  G.raiz = self.ctx.$container[0];
  G.cfg = self.ctx.settings || {};
  if ((self.ctx.currentUser || {}).authority !== 'TENANT_ADMIN') {
    G.raiz.innerHTML = '<p style="padding:12px;color:#777">Solo para la administración de la comunidad.</p>'; return;
  }
  vlNav(self.ctx, q('.vl-tabs'), G.cfg.nav || [], G.cfg.area);
  api('GET', '/gestion/esquema').then(function (e) {
    G.esq = e; G.area = e.areas[G.cfg.area];
    if (!G.area) { msg('Área desconocida: ' + G.cfg.area, 'err'); return; }
    G.socios = {}; e.socios.forEach(function (s) { G.socios[s.id] = s.nombre; });
    q('.ge-cab h2').textContent = G.area.titulo;
    q('.ge-cab p').textContent = G.area.descripcion;
    G.tab = Object.keys(G.area.registros)[0];
    pestanas(); abrir();
  }).catch(function (e) { msg('No se pudo cargar la gestión: ' + e.message, 'err'); });
  q('.ge-cancelar').onclick = cerrarForm;
};
self.onDestroy = function () {};

function pestanas() {
  var t = Object.keys(G.area.registros).map(function (k) { return [k, G.area.registros[k].titulo]; });
  t.push(['_docs', 'Documentos PDF']);
  q('.ge-tabs').innerHTML = t.map(function (x) {
    return '<button type="button" data-t="' + x[0] + '"' + (x[0] === G.tab ? ' class="on"' : '') + '>' + esc(x[1]) + '</button>';
  }).join('');
  [].forEach.call(q('.ge-tabs').querySelectorAll('button'), function (b) {
    b.onclick = function () { G.tab = b.dataset.t; G.orden = null; G.busca = ''; msg(''); pestanas(); abrir(); };
  });
}

function abrir() {
  if (G.tab === '_docs') return documentos();
  q('.ge-cuerpo').innerHTML = '<p class="ge-n">Cargando…</p>';
  api('GET', '/gestion/' + G.cfg.area + '/' + G.tab).then(function (filas) {
    G.datos[G.tab] = filas;
    if (G.area.registros[G.tab].unico) unico(filas[0]); else tabla();
  }).catch(function (e) { msg(e.message, 'err'); });
}

// ---------------- registros ----------------
function valor(c, v, html) {
  if (v == null || v === '') return '';
  if (c.tipo === 'fecha') return fecha(v);
  if (c.tipo === 'importe') return VL.num(+v, 2) + ' €';
  if (c.tipo === 'numero') return VL.num(+v, +v % 1 ? 2 : 0);
  if (c.tipo === 'si_no') return v ? 'sí' : 'no';
  if (c.tipo === 'socio') return G.socios[v] || v;
  var s = String(v);
  return html && s.length > 80 ? s.slice(0, 80) + '…' : s;
}
function tabla() {
  var r = G.area.registros[G.tab], cols = r.campos.filter(function (c) { return c.lista; });
  var filas = (G.datos[G.tab] || []).slice(), b = G.busca.toLowerCase();
  if (b) filas = filas.filter(function (f) { return r.campos.some(function (c) { return String(valor(c, f[c.id]) || '').toLowerCase().indexOf(b) >= 0; }); });
  if (G.orden) {
    var c = r.campos.filter(function (x) { return x.id === G.orden; })[0], d = G.asc ? 1 : -1;
    filas.sort(function (x, y) {
      var a = x[c.id], z = y[c.id];
      if (a == null || a === '') return 1; if (z == null || z === '') return -1;
      if (c.tipo === 'socio') { a = G.socios[a] || a; z = G.socios[z] || z; }
      return (typeof a === 'number' && typeof z === 'number' ? a - z : String(a).localeCompare(String(z), 'es')) * d;
    });
  }
  var h = '<div class="ge-barra"><button type="button" class="ge-b ge-nuevo">Nuevo</button>' +
    '<input class="ge-busca" placeholder="Buscar…" value="' + esc(G.busca) + '"><span class="ge-n">' + filas.length + ' de ' +
    (G.datos[G.tab] || []).length + '</span></div><table><thead><tr>' + cols.map(function (c) {
      return '<th data-c="' + c.id + '">' + esc(c.etiqueta) + (G.orden === c.id ? (G.asc ? ' ▲' : ' ▼') : '') + '</th>';
    }).join('') + '<th></th></tr></thead><tbody>' + filas.map(function (f) {
      return '<tr>' + cols.map(function (c) {
        return '<td class="' + (c.tipo === 'numero' || c.tipo === 'importe' ? 'num' : '') + '">' + esc(valor(c, f[c.id], true)) + '</td>';
      }).join('') + '<td class="acc"><button type="button" class="ge-b sec peq" data-e="' + f.id + '">Editar</button> ' +
        '<button type="button" class="ge-b peligro peq" data-b="' + f.id + '">Borrar</button></td></tr>';
    }).join('') + '</tbody></table>' + (filas.length ? '' : '<p class="ge-n">Sin registros.</p>');
  q('.ge-cuerpo').innerHTML = h;
  q('.ge-nuevo').onclick = function () { formulario(null); };
  var bu = q('.ge-busca');
  bu.oninput = function () { G.busca = bu.value; var pos = bu.selectionStart; tabla(); var n = q('.ge-busca'); n.focus(); n.setSelectionRange(pos, pos); };
  [].forEach.call(G.raiz.querySelectorAll('.ge-cuerpo th[data-c]'), function (th) {
    th.onclick = function () { G.asc = G.orden === th.dataset.c ? !G.asc : true; G.orden = th.dataset.c; tabla(); };
  });
  [].forEach.call(G.raiz.querySelectorAll('[data-e]'), function (b) {
    b.onclick = function () { formulario((G.datos[G.tab] || []).filter(function (f) { return f.id === b.dataset.e; })[0]); };
  });
  [].forEach.call(G.raiz.querySelectorAll('[data-b]'), function (b) {
    b.onclick = function () {
      if (!confirm('¿Borrar este registro? No se puede deshacer.')) return;
      api('DELETE', '/gestion/' + G.cfg.area + '/' + G.tab + '/' + b.dataset.b).then(function () { msg('Registro borrado.', 'ok'); abrir(); })
        .catch(function (e) { msg(e.message, 'err'); });
    };
  });
}

function campoHtml(c, v) {
  var id = 'f-' + c.id, req = c.req ? ' class="req"' : '', et = '<span' + req + '>' + esc(c.etiqueta) + '</span>';
  if (c.tipo === 'si_no') return '<label class="si"><input type="checkbox" id="' + id + '"' + (v ? ' checked' : '') + '>' + et + '</label>';
  if (c.tipo === 'largo') return '<label class="ancho">' + et + '<textarea id="' + id + '">' + esc(v) + '</textarea></label>';
  if (c.tipo === 'opcion' || c.tipo === 'socio') {
    var ops = c.tipo === 'socio' ? G.esq.socios.map(function (s) { return [s.id, s.nombre]; }) : c.opciones.map(function (o) { return [o, o]; });
    return '<label>' + et + '<select id="' + id + '"><option value=""></option>' + ops.map(function (o) {
      return '<option value="' + esc(o[0]) + '"' + (o[0] === v ? ' selected' : '') + '>' + esc(o[1]) + '</option>'; }).join('') + '</select></label>';
  }
  var tipo = c.tipo === 'fecha' ? 'date' : c.tipo === 'numero' || c.tipo === 'importe' ? 'number" step="any' : 'text';
  return '<label>' + et + '<input type="' + tipo + '" id="' + id + '" value="' + esc(v == null ? '' : v) + '"></label>';
}
function leerForm(campos, raiz) {
  var d = {};
  campos.forEach(function (c) {
    var el = raiz.querySelector('#f-' + c.id);
    if (!el) return;
    d[c.id] = c.tipo === 'si_no' ? el.checked : el.value === '' ? null : el.value;
  });
  return d;
}
function formulario(f) {
  var r = G.area.registros[G.tab];
  q('.ge-form h4').textContent = (f ? 'Editar · ' : 'Nuevo · ') + r.titulo;
  q('.ge-campos').innerHTML = r.campos.map(function (c) { return campoHtml(c, f ? f[c.id] : null); }).join('');
  q('.ge-modal').classList.add('on');
  q('.ge-guardar').onclick = function () {
    var d = leerForm(r.campos, q('.ge-campos'));
    api(f ? 'PUT' : 'POST', '/gestion/' + G.cfg.area + '/' + G.tab + (f ? '/' + f.id : ''), d).then(function () {
      cerrarForm(); msg('Guardado.', 'ok'); abrir();
    }).catch(function (e) { msg(e.message, 'err'); });
  };
}
function cerrarForm() { q('.ge-modal').classList.remove('on'); }

// Registro unico (datos de la entidad): formulario directo
function unico(f) {
  var r = G.area.registros[G.tab];
  q('.ge-cuerpo').innerHTML = '<div class="ge-unico"><div class="ge-campos">' +
    r.campos.map(function (c) { return campoHtml(c, f ? f[c.id] : null); }).join('') +
    '</div><div class="ge-pie"><button type="button" class="ge-b ge-gu">Guardar</button></div></div>';
  q('.ge-gu').onclick = function () {
    var d = leerForm(r.campos, q('.ge-cuerpo'));
    api(f ? 'PUT' : 'POST', '/gestion/' + G.cfg.area + '/' + G.tab + (f ? '/' + f.id : ''), d)
      .then(function () { msg('Guardado.', 'ok'); abrir(); }).catch(function (e) { msg(e.message, 'err'); });
  };
}

// ---------------- documentos ----------------
function paramHtml(dId, p, opsReg) {
  var id = 'p-' + dId + '-' + p.id, v = p.defecto == null ? '' : p.defecto;
  if (p.tipo === 'opcion') return '<label>' + esc(p.etiqueta) + '<select id="' + id + '">' + p.opciones.map(function (o) {
    return '<option' + (String(o) === String(v) ? ' selected' : '') + '>' + esc(o) + '</option>'; }).join('') + '</select></label>';
  if (p.tipo === 'registro') return '<label>' + esc(p.etiqueta) + '<select id="' + id + '">' + (opsReg[p.registro] || []).map(function (o) {
    return '<option value="' + esc(o[0]) + '">' + esc(o[1]) + '</option>'; }).join('') + '</select></label>';
  var t = p.tipo === 'fecha' ? 'date' : p.tipo === 'anio' || p.tipo === 'numero' ? 'number" step="any' : 'text';
  return '<label>' + esc(p.etiqueta) + '<input type="' + t + '" id="' + id + '" value="' + esc(v) + '"></label>';
}
function documentos() {
  var regs = {}, pend = [];
  G.area.documentos.forEach(function (d) { d.parametros.forEach(function (p) { if (p.tipo === 'registro') regs[p.registro] = 1; }); });
  Object.keys(regs).forEach(function (t) {
    pend.push(api('GET', '/gestion/' + G.cfg.area + '/' + t).then(function (filas) {
      var r = G.area.registros[t], c = r.campos;
      regs[t] = filas.map(function (f) { return [f.id, c.slice(0, 2).map(function (x) { return valor(x, f[x.id]); }).filter(Boolean).join(' · ')]; });
    }));
  });
  Promise.all(pend).then(function () {
    var docs = G.area.documentos.slice();
    if (G.cfg.area === 'reparto') docs.push({ id: '_coef', titulo: 'Fichero de coeficientes (.txt)',
      descripcion: 'Para comunicar a la distribuidora: fijos (CUPS;coeficiente) o variables por horas. Confirma con ella el formato exacto.',
      parametros: [{ id: 'desde', etiqueta: 'Desde', tipo: 'fecha', defecto: (docs[0].parametros[0] || {}).defecto },
                   { id: 'hasta', etiqueta: 'Hasta', tipo: 'fecha', defecto: (docs[0].parametros[1] || {}).defecto },
                   { id: 'criterio', etiqueta: 'Criterio', tipo: 'opcion', defecto: 'Consumo', opciones: ['Consumo', 'Igualitario', 'Potencia contratada'] },
                   { id: 'modo', etiqueta: 'Coeficientes', tipo: 'opcion', defecto: 'Fijos', opciones: ['Fijos', 'Variables por horas'] }] });
    q('.ge-cuerpo').innerHTML = '<div class="ge-docs">' + docs.map(function (d) {
      var falta = d.parametros.some(function (p) { return p.tipo === 'registro' && !(regs[p.registro] || []).length; });
      return '<div class="ge-doc"><h4>' + esc(d.titulo) + '</h4><p>' + esc(d.descripcion) + '</p>' +
        (d.parametros.length ? '<div class="ge-params">' + d.parametros.map(function (p) { return paramHtml(d.id, p, regs); }).join('') + '</div>' : '') +
        '<div><button type="button" class="ge-b" data-d="' + d.id + '"' + (falta ? ' disabled title="Crea antes el registro"' : '') + '>' +
        (d.id === '_coef' ? 'Descargar fichero' : 'Generar PDF') + '</button></div></div>';
    }).join('') + '</div><h3>Documentos generados</h3><div class="ge-arch"><p class="ge-n">Cargando…</p></div>';
    [].forEach.call(G.raiz.querySelectorAll('[data-d]'), function (b) {
      b.onclick = function () {
        var d = docs.filter(function (x) { return x.id === b.dataset.d; })[0], par = {};
        d.parametros.forEach(function (p) { var el = q('#p-' + d.id + '-' + p.id); if (el && el.value !== '') par[p.id] = el.value; });
        b.disabled = true; msg('Generando «' + d.titulo + '»…');
        var hecho = function () { b.disabled = false; };
        if (d.id === '_coef') {
          api('GET', '/gestion/reparto/coeficientes.txt?' + Object.keys(par).map(function (k) {
            return k + '=' + encodeURIComponent(par[k]); }).join('&'), null, true)
            .then(function (r) { return descargar(r, 'coeficientes.txt'); })
            .then(function (n) { msg('Descargado ' + n, 'ok'); }).catch(function (e) { msg(e.message, 'err'); }).then(hecho);
          return;
        }
        api('POST', '/gestion/' + G.cfg.area + '/documentos/' + d.id, par).then(function (j) {
          return api('GET', '/gestion/archivo/' + j.id, null, true).then(function (r) { return descargar(r, j.codigo + '.pdf'); });
        }).then(function (n) { msg('Generado y descargado: ' + n, 'ok'); archivo(); })
          .catch(function (e) { msg('No se pudo generar: ' + e.message, 'err'); }).then(hecho);
      };
    });
    archivo();
  }).catch(function (e) { msg(e.message, 'err'); });
}
function archivo() {
  api('GET', '/gestion/' + G.cfg.area + '/documentos').then(function (filas) {
    var el = q('.ge-arch');
    if (!el) return;
    el.innerHTML = filas.length ? '<table><thead><tr><th>Fecha</th><th>Documento</th><th>Código</th><th>Por</th><th></th></tr></thead><tbody>' +
      filas.map(function (f) {
        return '<tr><td>' + esc(fecha(f.creado)) + ' ' + esc(String(f.creado).slice(11, 16)) + '</td><td>' + esc(f.titulo) + '</td><td>' +
          esc(f.codigo) + '</td><td>' + esc(f.por) + '</td><td class="acc"><button type="button" class="ge-b sec peq" data-pdf="' + f.id +
          '">Descargar</button> <button type="button" class="ge-b peligro peq" data-del="' + f.id + '">Borrar</button></td></tr>';
      }).join('') + '</tbody></table>' : '<p class="ge-n">Aún no se ha generado ningún documento.</p>';
    [].forEach.call(el.querySelectorAll('[data-pdf]'), function (b) {
      b.onclick = function () { api('GET', '/gestion/archivo/' + b.dataset.pdf, null, true).then(function (r) { return descargar(r, 'documento.pdf'); })
        .catch(function (e) { msg(e.message, 'err'); }); };
    });
    [].forEach.call(el.querySelectorAll('[data-del]'), function (b) {
      b.onclick = function () {
        if (!confirm('¿Borrar este documento del archivo?')) return;
        api('DELETE', '/gestion/archivo/' + b.dataset.del).then(archivo).catch(function (e) { msg(e.message, 'err'); });
      };
    });
  }).catch(function (e) { msg(e.message, 'err'); });
}
"""

# Areas de gestion: id, nombre corto (navegacion) y titulo de su panel
AREAS_GESTION = [("gobernanza", "Gobernanza"), ("tecnica", "Técnica"), ("reparto", "Reparto"),
                 ("economica", "Economía"), ("tramites", "Trámites"), ("participacion", "Participación"),
                 ("rgpd", "Protección de datos")]
GESTION_DASH_VERSION = 5         # sube este numero para regenerar los paneles de gestion


def nav_gestion():
    """Pestañas de gestion: [area, nombre, titulo del panel] (la comunidad, con el mapa,
    primero; luego Datadis, los participantes, las areas de gestion y las copias de la base
    de datos)."""
    return [["", "⚡ Comunidad", CEC], ["datadis", "Datadis", "Gestión · Datadis"],
            ["participantes", "Participantes", "Gestión · Participantes"]] + \
           [[a, n, f"Gestión · {n}"] for a, n in AREAS_GESTION] + \
           [["bd", "Base de datos", "Gestión · Base de datos"]]


def panel_admin(title, descripcion, ws, autofill, area):
    """Crea o actualiza un panel solo para administradores (no se asigna a ningun cliente)
    con los widgets ws [(wid, wdef, layout)]; autofill: ajustados al alto de la pantalla."""
    conf = {"description": descripcion, "widgets": {wid: wdef for wid, wdef, _ in ws},
            "states": {"default": {"name": title, "root": True, "layouts": {"main": {
                "widgets": {wid: l for wid, _, l in ws},
                "gridSettings": {"columns": 24, "margin": 10, "outerMargin": True, "autoFillHeight": autofill,
                                 "backgroundColor": "#eeeeee"}}}}},
            "entityAliases": {}, "filters": {},
            "timewindow": {"selectedTab": 0, "realtime": {"realtimeType": 0, "timewindowMs": 86400000, "interval": 60000}},
            "settings": {"stateControllerId": "entity", "showTitle": True, "showDashboardsSelect": False,
                         "showEntitiesSelect": False, "showDashboardTimewindow": False, "showDashboardExport": False,
                         "toolbarAlwaysOpen": True, "dashboardCss": CSS_PANEL},
            "gestionFirma": json.dumps([GESTION_DASH_VERSION, area, nav_gestion()], ensure_ascii=False)}
    d = find(tb.get(page("/api/tenant/dashboards"))["data"], "title", title)
    if d:
        full = tb.get(f"/api/dashboard/{d['id']['id']}")
        if (full.get("configuration") or {}).get("gestionFirma") == conf["gestionFirma"]:
            return
        full["configuration"] = conf
        tb.post("/api/dashboard", full)
        print(f"    panel '{title}' actualizado")
    else:
        tb.post("/api/dashboard", {"title": title, "configuration": conf})
        print(f"    panel '{title}' creado")


def gestion_paneles():
    """Pestañas Datadis (sincronizacion, datos cargados e informes) y Base de datos (copias)
    y un panel por area de gestion."""
    panel_admin("Gestión · Datadis", "Datadis: sincronización, datos cargados e informes",
                [w_nav("datadis", 0, 0, 24, 1), w_admin(0, 1, 24, 14)], False, "datadis")
    panel_admin("Gestión · Participantes", "Alta, datos y baja de los participantes de la comunidad",
                [w_nav("participantes", 0, 0, 24, 1), w_participantes(0, 1, 24, 16)], False, "participantes")
    panel_admin("Gestión · Base de datos", "Copias de seguridad de PostgreSQL: hacer, subir, descargar y restaurar",
                [w_nav("bd", 0, 0, 24, 1), w_basedatos(0, 1, 24, 14)], False, "bd")
    for area, nombre in AREAS_GESTION:
        title = f"Gestión · {nombre}"
        cfg = {"datasources": [], "showTitle": False, "title": title, "backgroundColor": "#fff",
               "color": "rgba(0,0,0,0.87)", "padding": "12px", "dropShadow": True, "enableFullscreen": False,
               "settings": {"area": area, "nav": nav_gestion()}}
        panel_admin(title, f"Gestión de la comunidad: {nombre}",
                    [_w("tenant.VatiaCo.gestion", cfg, "static", 0, 0, 24, 20)], True, area)


def cec_config(title):
    """Panel estandar de la comunidad, el mismo para todos. El alias "Mi nudo" depende de
    quien mira (CURRENT_USER, relaciones creadas por cec_enlazar): el administrador ve los
    totales de la comunidad y todos los socios; un socio ve solo sus datos y su rayo.
    (Desde CURRENT_USER_OWNER no vale: ThingsBoard no deja a un usuario de cliente
    consultar relaciones que salen de su propio cliente y los alias quedan vacios.)
    Estados: default (pestañas de gestion para el administrador, mapa, consumo como en
    Datadis, socios y energia diaria) y socio
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

    # Pestañas de gestion: solo las ve el administrador (los socios no se quedan en esta
    # vista, w_redirige_socio, y el widget se oculta si no es administrador)
    add("default", w_nav("", 0, 0, 24, 1))
    add("default", con_imprimir(w_mapa(a_socios, 0, 1, 24, 10)))
    add("default", w_consumo(mio, 0, 11, 24, 15))
    add("default", w_socios(a_socios, 0, 26, 24, 7))
    add("default", w_diaria(mio, 0, 33, 24, 9))
    add("default", w_redirige_socio(mio, 0, 42, 24, 1))
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
    if not email:
        return
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
        if E["CEC_ADMIN_PASSWORD"] and E["CEC_ADMIN_ANTERIOR_PASSWORD"] and not tb_login(email, E["CEC_ADMIN_PASSWORD"]):
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
    if not E["CEC_ADMIN_PASSWORD"]:
        print(f"    AVISO: gestor '{email}' sin contraseña: no se crea")
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

# ---- Plataforma: superusuario que crea comunidades (solo en la ejecucion base) ----
def plataforma_super():
    """Tenant "Plataforma" con el superusuario (SUPER_EMAIL), encerrado en su panel de
    comunidades: TENANT_ADMIN de un tenant sin dispositivos; la API reconoce su email."""
    global tb
    email, pw = E["SUPER_EMAIL"], E["SUPER_PASSWORD"]
    if not tb_login(email, pw):
        ten = find(sa.get(page("/api/tenants"))["data"], "title", "Plataforma") or \
            sa.post("/api/tenant", {"title": "Plataforma"})
        u = sa.post("/api/user?sendActivationMail=false", {
            "email": email, "authority": "TENANT_ADMIN", "firstName": "Superusuario", "lastName": "Plataforma",
            "tenantId": {"id": ten["id"]["id"], "entityType": "TENANT"}, "additionalInfo": {"lang": E["TB_LANG"]}})
        activar(sa, u, pw)
        print(f"    superusuario '{email}' creado (tenant Plataforma)")
    tb = TBClient(tb_login(email, pw))
    cec_widget("VatiaCo.plataforma", "Comunidades de la plataforma", PLAT_HTML, PLAT_JS, 16, ALTA_CSS,
               tipo="static", recursos=[])
    cfg = {"datasources": [], "showTitle": True, "title": "Comunidades energéticas de la plataforma", "settings": {},
           "backgroundColor": "#fff", "color": "rgba(0,0,0,0.87)", "padding": "8px", "dropShadow": True,
           "enableFullscreen": False, "mobileHeight": 24}
    wid, wdef, l = _w("tenant.VatiaCo.plataforma", cfg, "static", 0, 0, 24, 16)
    conf = {"description": "Comunidades energéticas y sus gestores", "widgets": {wid: wdef},
            "states": {"default": {"name": "Plataforma", "root": True, "layouts": {"main": {"widgets": {wid: l},
                       "gridSettings": {"columns": 24, "margin": 10, "outerMargin": True, "backgroundColor": "#eeeeee"}}}}},
            "entityAliases": {}, "filters": {}, "timewindow": {"selectedTab": 0, "realtime": {"realtimeType": 0, "timewindowMs": 86400000}},
            "settings": {"stateControllerId": "entity", "showTitle": True, "showDashboardsSelect": False,
                         "showEntitiesSelect": False, "showDashboardTimewindow": False, "showDashboardExport": False,
                         "toolbarAlwaysOpen": True, "dashboardCss": CSS_PANEL},
            "plataformaFirma": "1"}
    d = find(tb.get(page("/api/tenant/dashboards"))["data"], "title", "Plataforma")
    if not d:
        d = tb.post("/api/dashboard", {"title": "Plataforma", "configuration": conf})
        print("    panel 'Plataforma' creado")
    elif (tb.get(f"/api/dashboard/{d['id']['id']}").get("configuration") or {}).get("plataformaFirma") != "1":
        full = tb.get(f"/api/dashboard/{d['id']['id']}")
        full["configuration"] = conf
        d = tb.post("/api/dashboard", full)
    me = tb.get("/api/auth/user")
    info = me.get("additionalInfo") or {}
    if (info.get("defaultDashboardId"), info.get("defaultDashboardFullscreen")) != (d["id"]["id"], True):
        info.update(defaultDashboardId=d["id"]["id"], defaultDashboardFullscreen=True, lang=E["TB_LANG"])
        me["additionalInfo"] = info
        sa.post("/api/user?sendActivationMail=false", me)
        print(f"    {email}: solo el panel Plataforma, sin menu lateral")


if E.get("SUPER_EMAIL"):
    plataforma_super()
if not CEC:   # ejecucion base (iot-thingsboard.sh): las comunidades las aprovisiona la API
    print("  - ThingsBoard OK" + (f" (gateway token {gw_token})" if gw_token else ""))
    raise SystemExit(0)

# ---- Comunidad energetica ----
print(f"  - {CEC}: {len(SOCIOS)} socios")
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
cec_widget("VatiaCo.gestion", "Gestión de la comunidad", GESTION_HTML, GESTION_JS, 20, GESTION_CSS, tipo="static", recursos=[])
cec_widget("VatiaCo.nav", "Pestañas de gestión", NAV_W_HTML, NAV_W_JS, 1, NAV_W_CSS, tipo="static", recursos=[])
cec_widget("VatiaCo.participantes", "Participantes", PART_HTML, PART_JS, 16, ALTA_CSS, tipo="static", recursos=[])
cec_widget("VatiaCo.basedatos", "Copias de la base de datos", BD_HTML, BD_JS, 14, BD_CSS, tipo="static", recursos=[])
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
# Administrador del tenant (el superusuario entra en la comunidad con el): sin panel de
# inicio, el de la comunidad (con menu lateral, acceso completo)
me = tb.get("/api/auth/user")
info_ = me.get("additionalInfo") or {}
if not info_.get("defaultDashboardId"):
    info_.update(defaultDashboardId=panel["id"]["id"], defaultDashboardFullscreen=False)
    me["additionalInfo"] = info_
    sa.post("/api/user?sendActivationMail=false", me)
    print(f"    {me['email']}: panel de inicio '{CEC}'")
# Paneles de Datadis, de gestion (gobernanza, tecnica, reparto...) y de copias, solo para administradores
gestion_paneles()

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
print(f"  - ThingsBoard OK ({CEC})")
PY

# Ejecucion base: sysadmin, tenant de la primera comunidad (gateway y CLIENTES) y tenant
# Plataforma con el superusuario. Las comunidades las aprovisiona despues la API con este
# mismo programa (POST /plataforma/aprovisionar), con los socios de su base de datos.
echo "==> Configurando ThingsBoard..."
TB_URL="https://localhost" \
TB_SYSADMIN_PASSWORD="$TB_SYSADMIN_PASSWORD" TB_TENANT_PASSWORD="$TB_TENANT_PASSWORD" \
TB_TENANT_EMAIL="$TB_TENANT_EMAIL" TB_LANG="$TB_LANG" \
TB_GATEWAY_NAME="$TB_GATEWAY_NAME" TB_GATEWAY_ANTERIOR="$TB_GATEWAY_ANTERIOR" \
CLIENTES="$(printf '%s\n' "${CLIENTES[@]}")" SUPER_EMAIL="$SUPER_EMAIL" SUPER_PASSWORD="$SUPER_PASSWORD" \
CEC_NOMBRE="" CEC_ADMIN_PASSWORD="$CEC_ADMIN_PASSWORD" \
SOCIOS="$(printf '%s\n' "${SOCIOS[@]}" "${SOCIOS2[@]}")" TZ="$TZ" \
python3 config/tb-config.py

echo "==> Esperando a la API de las comunidades..."
INICIO=$(date +%s)
until curl -skf -o /dev/null https://localhost/cec-api/salud; do
  if [ $(( $(date +%s) - INICIO )) -ge 300 ]; then
    echo "ERROR: la API de las comunidades no responde. Ultimas lineas del log:" >&2
    docker logs --tail 40 iot-fastapi 2>&1 | sed 's/^/    /' >&2
    exit 1
  fi
  sleep 3
done
echo "==> Aprovisionando las comunidades en ThingsBoard (tenants, gestores, socios y paneles)..."
python3 - <<'PY'
import json, os, ssl, sys, urllib.error, urllib.request
key = [l.split("=", 1)[1].strip() for l in open(".env") if l.startswith("FASTAPI_API_KEY=")][0]
req = urllib.request.Request("https://localhost/cec-api/plataforma/aprovisionar", b"{}", method="POST",
                             headers={"X-Api-Key": key, "Content-Type": "application/json"})
try:
    with urllib.request.urlopen(req, timeout=3600, context=ssl._create_unverified_context()) as r:
        for cid, salida in json.loads(r.read()).items():
            print("\n".join("    " + l for l in salida.splitlines() if l.strip()))
except urllib.error.HTTPError as e:
    sys.exit(f"ERROR {e.code}: {e.read().decode()[-2000:]}")
PY

# Datos de cada comunidad: la API relee los CSV de DATADIS_DIR (solo carga lo que ha
# cambiado) y los pasa a PostgreSQL y ThingsBoard. Las curvas nuevas llegan despues con la
# sincronizacion diaria (SYNC_HORA) o con el boton del panel del gestor.
for c_ in "$CEC_ID|$CEC_NOMBRE" "$CEC2_ID|$CEC2_NOMBRE"; do
  IFS='|' read -r id_ nombre_ <<< "$c_"
  echo "==> Cargando los datos de Datadis ($nombre_)..."
  CEC_COMUNIDAD="$id_" ./sync.sh csv || echo "    AVISO: la carga ha terminado con errores (se puede repetir con CEC_COMUNIDAD=$id_ ./sync.sh csv)"
done

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
| Superusuario (crea comunidades y gestores) | (login, panel Plataforma) | $SUPER_EMAIL / $SUPER_PASSWORD |
| $CEC_NOMBRE (gestor) | (login de administrador) | $CEC_ADMIN_EMAIL / $CEC_ADMIN_PASSWORD |
$(for s_ in "${SOCIOS[@]}"; do IFS='|' read -r n e pw pf sim <<< "$s_"; [ -n "$e" ] && echo "| $CEC_NOMBRE ($n) | (login de socio) | $e / $pw |"; done)
| $CEC2_NOMBRE (gestor, tenant propio) | (login de administrador) | $CEC2_ADMIN_EMAIL / $CEC2_ADMIN_PASSWORD |
| $CEC2_NOMBRE (administrador del tenant) | (login de administrador) | $CEC2_TENANT_EMAIL / $TB_TENANT_PASSWORD |
$(for s_ in "${SOCIOS2[@]}"; do IFS='|' read -r n e pw pf sim <<< "$s_"; [ -n "$e" ] && echo "| $CEC2_NOMBRE ($n) | (login de socio) | $e / $pw |"; done)
| MQTT de ThingsBoard (TLS) | mqtts://${TB_DOMAIN:-$IP}:$MQTTS_PORT | usuario = token del dispositivo, sin contraseña |
| API de las comunidades (FastAPI) | https://$IP/cec-api/docs | token del gestor (su comunidad) o del superusuario (/plataforma), o cabecera \`X-Api-Key\` (FASTAPI_API_KEY de .env) con \`X-Comunidad: <id>\` |
| PostgreSQL | postgres:5432 (solo red interna) | $PG_USER / $PG_PASSWORD |
| Adminer (127.0.0.1, tunel SSH) | http://127.0.0.1:$ADMINER_PORT/?pgsql=postgres&username=$PG_USER&db=thingsboard | sistema **PostgreSQL** (no MySQL) · $PG_USER / $PG_PASSWORD |
| Homepage (portada de servicios) | http://$IP:$HOMEPAGE_PORT | — |
| Web Astro (proman) | http://$IP:$PROMAN_PORT | — (recompilar: \`./web.sh\`) |

Solo se publican 80/443 (Caddy) y $MQTTS_PORT (MQTT con TLS de ThingsBoard). Adminer escucha
en 127.0.0.1; desde otro equipo:

\`\`\`bash
ssh -L $ADMINER_PORT:127.0.0.1:$ADMINER_PORT $USER@$IP
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
- Pestaña *Datadis* del administrador de la comunidad: botón *Actualizar ahora*, recarga de un
  rango de meses, progreso y registro de cada sincronización, datos cargados por socio e
  informes de la comunidad o de un socio: PDF (Typst) con los mismos gráficos que el panel,
  Excel o CSV con los datos diarios.
- En ThingsBoard, cada socio (dispositivo tipo \`socio\`) tiene \`consumo_kwh\`, \`vertida_kwh\`,
  \`generada_kwh\` y \`autoconsumo_kwh\` por periodo de medida, los totales diarios \`d_*\` y,
  como atributos, CUPS, peaje y potencia. \`comunidad\` es la suma horaria de todos.
- Socio nuevo: añádelo a SOCIOS en iot-thingsboard.sh con su carpeta y sus coordenadas.

### Plataforma: comunidades, gestores y participantes

Una sola API para todas las comunidades (\`iot-fastapi\`): cada comunidad tiene su tenant de
ThingsBoard, su base PostgreSQL (\`cec\` la primera, \`cec_<id>\` las demás) y su gestor; el
registro está en la base \`plataforma\`. La API sabe de qué comunidad es cada petición por el
tenant del usuario que llama.

- **Superusuario** ($SUPER_EMAIL, tenant *Plataforma*): en su panel ve las comunidades y crea una
  nueva con su gestor (tenant, base de datos, paneles y usuario del gestor; tarda un minuto).
  Por cada comunidad: **Entrar** (como administrador de su tenant, con acceso completo; su sesión
  de superusuario se cierra), **Bloquear / Desbloquear** al gestor (credenciales desactivadas; la
  API rechaza ya sus peticiones), **Quitar gestor** (borra su usuario) y **Asignar gestor**.
- **Gestor**: pestaña *Participantes* de su comunidad: alta (crea su dispositivo, su cliente y,
  con email, su usuario), datos por la **API de Datadis** (CUPS y NIF del titular, que tiene que
  haber autorizado a la cuenta \`DATADIS_USER\`) o subiendo los **CSV de la descarga web** de
  Datadis (\`data/subidas\`), edición, carga de datos y baja (sus lecturas se conservan).
- Comunidades de partida: las del script (\`$CEC_NOMBRE\` y \`$CEC2_NOMBRE\`); sus socios siguen
  las listas SOCIOS y SOCIOS2. Lo creado desde los paneles solo cambia desde los paneles.
- Lo de ThingsBoard lo crea \`config/tb-config.py\` (el script en su ejecución base; la API, para
  cada comunidad). Para rehacerlo: botón *Actualizar ThingsBoard* del superusuario.
- Sincronización a mano de otra comunidad: \`CEC_COMUNIDAD=<id> ./sync.sh ...\`.

### Gestión de la comunidad

El administrador tiene, además del panel de la comunidad y de *Gestión · Datadis*, un panel
por área (pestañas de navegación arriba en todos ellos, la comunidad primero): *Gestión · Gobernanza*, *Técnica*, *Reparto*, *Economía*,
*Trámites*, *Participación* y *Protección de datos*. Cada uno tiene sus registros (tablas
con alta, edición y borrado) y una pestaña de documentos PDF que se archivan con su código:

| Área | Registros | Documentos PDF |
|---|---|---|
| Gobernanza | entidad, libro de socios, asambleas y juntas, reglamento | libro de socios, convocatoria, acta, reglamento interno |
| Técnica | equipos, mantenimiento, seguros y garantías, ampliaciones | informe de producción, plan de mantenimiento, inventario y garantías, plan de ampliaciones |
| Reparto | acuerdos de reparto, verificación de facturas | propuesta de coeficientes, acuerdo de reparto, verificación de facturas, fichero de coeficientes (.txt) |
| Economía | ingresos y gastos, presupuesto, cuotas, financiación | estado de cuentas, ejecución presupuestaria, cuotas pendientes, IVA trimestral, financiación, valoración de excedentes |
| Trámites | permisos y registros, normativa | registro de trámites, seguimiento normativo |
| Participación | comunicaciones, actividades, hogares vulnerables, relaciones | boletín para socios, memoria social |
| Protección de datos | actividades de tratamiento, consentimientos, derechos, brechas | registro de actividades (art. 30), consentimientos, derechos e incidencias, cláusula informativa |

Los datos de energía (coeficientes, producción, boletín, excedentes, verificación) salen de
PostgreSQL; el resto, de los registros (tablas \`registro\` y \`documento\` de la base \`cec\`).

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

Copia de las bases de datos (thingsboard y cec): diaria en \`backups/postgres\` (servicio pg-backup, 7 días).
En el panel, pestaña *Base de datos* (administrador): hacer una copia ahora, subir, descargar, borrar y
restaurar la base de la comunidad (cec; antes se guarda la actual como copia *previa*). Restaurar a mano:
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
echo " $CEC2_NOMBRE (tenant propio):"
echo "   $CEC2_ADMIN_EMAIL / $CEC2_ADMIN_PASSWORD  (gestor de la comunidad)"
echo "   $CEC2_TENANT_EMAIL / $TB_TENANT_PASSWORD  (administrador de su tenant de ThingsBoard)"
for s_ in "${SOCIOS2[@]}"; do
  IFS='|' read -r n e pw pf sim <<< "$s_"
  [ -n "$e" ] && echo "   $e / $pw  (socio '$n', solo ve su panel)"
done
echo "   a mano: CEC_COMUNIDAD=$CEC2_ID ./sync.sh"
echo " Superusuario      : $SUPER_EMAIL / $SUPER_PASSWORD  (panel Plataforma: crea comunidades y sus gestores)"
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
echo "   Adminer (BD)    : http://127.0.0.1:$ADMINER_PORT/?pgsql=postgres&username=$PG_USER&db=thingsboard"
echo "   desde otro equipo: ssh -L $ADMINER_PORT:127.0.0.1:$ADMINER_PORT $USER@$IP"
echo " Copias PostgreSQL : $INSTALL_DIR/backups/postgres  (thingsboard y cec, diarias, 7 dias)"
echo " Carpeta           : $INSTALL_DIR  (README.md con ejemplos)"
echo "   config/  ficheros de configuracion    data/  datos de cada contenedor"
echo "   export/  JSON de ThingsBoard (actualizar con ./export.sh)"
echo
docker compose ps
