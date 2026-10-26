#!/usr/bin/env bash
set -euo pipefail

# ============================================
# PostgreSQL + Adminer + Homepage - pkserver
#
# Stack minimo (docker compose) con la base de datos, su GUI web y una portada:
#
#   PostgreSQL  -> 127.0.0.1:PG_PORT (desde otro equipo, por tunel SSH)
#   Adminer     -> GUI web de PostgreSQL (127.0.0.1:ADMINER_PORT, por tunel SSH)
#   Homepage    -> portada de los servicios con sus credenciales (LAN, puerto HOMEPAGE_PORT)
#
# Sirve para abrir en Adminer las copias que hace iot-thingsboard.sh (BACKUPS_DIR, formato
# pg_dump -Fc que Adminer no sabe importar): en cada ejecucion se carga la copia mas reciente
# de cada base (thingsboard, plataforma, cec_<id>) con su mismo nombre. A mano:
#   ~/pg-adminer/cargar-copias.sh                  la mas reciente de cada base
#   ~/pg-adminer/restore.sh <fichero.dump> [base]  una copia concreta
#
# Los datos se CONSERVAN entre ejecuciones (data/postgres). Para empezar de cero:
#   RESET=1 ./postgres-adminer.sh
#
# Carpeta del stack ($INSTALL_DIR), montada en los contenedores:
#   config/homepage/ configuracion de Homepage (se regenera en cada ejecucion)
#   data/postgres/   datos de PostgreSQL
# ============================================

# Todo el stack vive en esta carpeta del host
INSTALL_DIR="$HOME/pg-adminer"
IP="localhost"
HOSTNAME_LAN="pkserver"
TZ="Europe/Madrid"

PG_VERSION="16.15"
ADMINER_VERSION="5.5.1"
HOMEPAGE_VERSION="v2.4.0"

PG_PORT="5432"          # PostgreSQL, solo 127.0.0.1
ADMINER_PORT="8082"     # Adminer, solo 127.0.0.1 (8081 lo usa iot-thingsboard.sh)
HOMEPAGE_PORT="3001"    # Homepage, LAN (3000 lo usa iot-thingsboard.sh)

PG_USER="pk"
PG_PASSWORD="pk"
PG_DB="pk"              # base que se crea al iniciar PostgreSQL por primera vez

# Copias de PostgreSQL de iot-thingsboard.sh (<base>-AAAA-MM-DD.dump y <base>-<tipo>-AAAAMMDD-HHMMSS.dump)
BACKUPS_DIR="$HOME/iot-tb/backups/postgres"
CARGAR_COPIAS="${CARGAR_COPIAS:-1}"   # 0 = no cargarlas al arrancar

RESET="${RESET:-0}"

echo "============================================"
echo " PostgreSQL + Adminer + Homepage"
echo "============================================"

command -v docker >/dev/null 2>&1 || { echo "ERROR: falta docker" >&2; exit 1; }
docker compose version >/dev/null 2>&1 || { echo "ERROR: falta docker compose" >&2; exit 1; }

# Se paran los contenedores anteriores del stack; con RESET=1 tambien se borran sus datos
# (pertenecen al usuario de postgres: se borran con un contenedor)
if [ -f "$INSTALL_DIR/docker-compose.yml" ]; then
  echo "==> Parando la instalacion anterior..."
  (cd "$INSTALL_DIR" && docker compose down --remove-orphans) || true
fi
if [ "$RESET" = "1" ] && [ -d "$INSTALL_DIR/data" ]; then
  echo "==> RESET=1: borrando los datos de PostgreSQL..."
  docker run --rm -v "$INSTALL_DIR/data:/d" alpine sh -c 'rm -rf /d/postgres'
fi

# --------------------------------------------
# 1. Puertos libres en el host
# --------------------------------------------
OCUPADOS=()
for p in "$PG_PORT" "$ADMINER_PORT" "$HOMEPAGE_PORT"; do
  if ss -ltnH "( sport = :$p )" 2>/dev/null | grep -q .; then
    OCUPADOS+=("$p")
  fi
done
if [ ${#OCUPADOS[@]} -gt 0 ]; then
  echo "ERROR: puertos ya en uso en el host: ${OCUPADOS[*]}" >&2
  echo "       Para el servicio que los usa (p.ej. otro stack) o cambia los puertos arriba." >&2
  exit 1
fi

echo "==> Creando estructura en $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"/config/homepage "$INSTALL_DIR"/data/postgres
cd "$INSTALL_DIR"

# --------------------------------------------
# 2. .env (variables del compose)
# --------------------------------------------

# Homepage solo responde a los nombres/IPs de esta lista: las configuradas y todas las
# IPv4 que tenga ahora el servidor (por si el DHCP le cambia la IP)
HOMEPAGE_HOSTS=$(for h in "$IP" "$HOSTNAME_LAN" "$HOSTNAME_LAN.local" localhost 127.0.0.1 \
                   $(ip -4 -o addr show 2>/dev/null | awk '$2!="lo" && $2!~/^(docker|br-|veth)/ {split($4,a,"/"); print a[1]}'); do
                   echo "$h:$HOMEPAGE_PORT"; done | sort -u | paste -sd, -)

cat > .env <<EOF
TZ=$TZ
PG_VERSION=$PG_VERSION
ADMINER_VERSION=$ADMINER_VERSION
HOMEPAGE_VERSION=$HOMEPAGE_VERSION
HOMEPAGE_PORT=$HOMEPAGE_PORT
HOMEPAGE_ALLOWED_HOSTS=$HOMEPAGE_HOSTS
PG_PORT=$PG_PORT
ADMINER_PORT=$ADMINER_PORT
PG_USER=$PG_USER
PG_PASSWORD=$PG_PASSWORD
PG_DB=$PG_DB
BACKUPS_DIR=$BACKUPS_DIR
EOF
chmod 600 .env

# --------------------------------------------
# 2b. Homepage: portada de los servicios con las credenciales de acceso y el estado de
#     cada contenedor (socket de Docker)
# --------------------------------------------
cat > config/homepage/docker.yaml <<EOF
my-docker:
  socket: /var/run/docker.sock
EOF
cat > config/homepage/settings.yaml <<EOF
title: PostgreSQL · $HOSTNAME_LAN
headerStyle: clean
EOF
cat > config/homepage/services.yaml <<EOF
- Base de datos:
    - PostgreSQL:
        description: "$PG_USER / $PG_PASSWORD · base $PG_DB · localhost:$PG_PORT (postgresql://$PG_USER:$PG_PASSWORD@localhost:$PG_PORT/$PG_DB)"
        icon: postgres
        server: my-docker
        container: pg-postgres
    - Adminer:
        href: http://localhost:$ADMINER_PORT/?pgsql=postgres&username=$PG_USER
        description: "Sistema PostgreSQL · $PG_USER / $PG_PASSWORD · solo 127.0.0.1 (desde otro equipo: ssh -L $ADMINER_PORT:127.0.0.1:$ADMINER_PORT $USER@$IP)"
        icon: adminer
        server: my-docker
        container: pg-adminer
    - Copias de iot-thingsboard:
        description: "$BACKUPS_DIR · la más reciente de cada base se carga con su nombre (thingsboard, plataforma, cec_<id>) · $INSTALL_DIR/cargar-copias.sh"
        icon: postgres
EOF

# --------------------------------------------
# 3. docker-compose.yml (red bridge; datos en carpetas de $INSTALL_DIR)
# --------------------------------------------
# PostgreSQL y Adminer escuchan solo en 127.0.0.1 (se usan por tunel SSH); Homepage, en la LAN.
cat > docker-compose.yml <<'EOF'
name: pg-adminer

x-common: &common
  restart: unless-stopped
  logging:
    driver: json-file
    options: { max-size: "50m", max-file: "3" }

services:

  postgres:
    <<: *common
    image: postgres:${PG_VERSION}
    container_name: pg-postgres
    ports:
      - "127.0.0.1:${PG_PORT}:5432"
    environment:
      POSTGRES_DB: ${PG_DB}
      POSTGRES_USER: ${PG_USER}
      POSTGRES_PASSWORD: ${PG_PASSWORD}
      TZ: ${TZ}
    volumes:
      - ./data/postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${PG_USER} -d ${PG_DB}"]
      interval: 5s
      timeout: 5s
      retries: 30

  # GUI web de PostgreSQL (servidor "postgres", usuario/contraseña de Postgres)
  adminer:
    <<: *common
    image: adminer:${ADMINER_VERSION}
    container_name: pg-adminer
    ports:
      - "127.0.0.1:${ADMINER_PORT}:8080"
    environment:
      ADMINER_DEFAULT_SERVER: postgres
    depends_on:
      postgres:
        condition: service_healthy

  # Portada de los servicios con sus credenciales (config/homepage, la genera postgres-adminer.sh).
  # Lee el socket de Docker (solo lectura) para mostrar el estado de cada contenedor.
  homepage:
    <<: *common
    image: ghcr.io/gethomepage/homepage:${HOMEPAGE_VERSION}
    container_name: pg-homepage
    ports:
      - "${HOMEPAGE_PORT}:3000"
    environment:
      HOMEPAGE_ALLOWED_HOSTS: ${HOMEPAGE_ALLOWED_HOSTS}
    volumes:
      - ./config/homepage:/app/config
      - /var/run/docker.sock:/var/run/docker.sock:ro
EOF

# --------------------------------------------
# 4. Scripts de gestion
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
# Consola psql: ./psql.sh [base]
cat > psql.sh <<'EOF'
#!/bin/bash
cd "$(dirname "$0")"
set -a; source .env; set +a
docker compose exec postgres psql -U "$PG_USER" -d "${1:-$PG_DB}"
EOF
# Restaurar una copia: ./restore.sh <fichero> [base]
#   .dump (pg_dump -Fc, empieza por "PGDMP"; Adminer no lo lee) -> pg_restore
#   .sql / .sql.gz (texto plano)                                  -> psql
# La base (por defecto, el nombre del fichero hasta el primer "-": thingsboard-2026-10-21.dump
# -> thingsboard) se borra y se vuelve a crear vacia antes de cargar la copia.
cat > restore.sh <<'EOF'
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
set -a; source .env; set +a
f="${1:?uso: $0 <fichero.dump|.sql|.sql.gz> [base]}"
[ -f "$f" ] || { echo "ERROR: no existe $f" >&2; exit 1; }
n=$(basename "$f"); db="${2:-${n%%-*}}"; db="${db%%.*}"
q() { docker compose exec -T -e PGOPTIONS=--client-min-messages=warning postgres psql -U "$PG_USER" -d "$PG_DB" -v ON_ERROR_STOP=1 -Atc "$1"; }
[ "$db" != "$PG_DB" ] || { echo "ERROR: no se puede restaurar sobre $PG_DB (base de conexion)" >&2; exit 1; }
echo "==> Restaurando $f en $db"
q "DROP DATABASE IF EXISTS \"$db\" WITH (FORCE)" >/dev/null
q "CREATE DATABASE \"$db\"" >/dev/null
if [ "$(head -c 5 "$f")" = PGDMP ]; then
  docker compose exec -T postgres pg_restore -U "$PG_USER" -d "$db" --no-owner --no-acl < "$f"
elif [[ "$f" == *.gz ]]; then
  gunzip -c "$f" | docker compose exec -T postgres psql -U "$PG_USER" -d "$db" -v ON_ERROR_STOP=1 -q
else
  docker compose exec -T postgres psql -U "$PG_USER" -d "$db" -v ON_ERROR_STOP=1 -q < "$f"
fi
echo "==> Listo: base $db"
EOF
# Cargar las copias de iot-thingsboard.sh: ./cargar-copias.sh [base...]
#   la mas reciente (por fecha del fichero) de cada base de BACKUPS_DIR, o solo de las indicadas
cat > cargar-copias.sh <<'EOF'
#!/bin/bash
set -uo pipefail
cd "$(dirname "$0")"
set -a; source .env; set +a
[ -d "$BACKUPS_DIR" ] || { echo "No existe $BACKUPS_DIR (copias de iot-thingsboard.sh)" >&2; exit 1; }
declare -A ULTIMA=()
while IFS= read -r f; do
  n=$(basename "$f"); b="${n%%-*}"
  [ -n "${ULTIMA[$b]:-}" ] || ULTIMA[$b]="$f"
done < <(ls -1t "$BACKUPS_DIR"/*.dump 2>/dev/null)
[ ${#ULTIMA[@]} -gt 0 ] || { echo "No hay copias (.dump) en $BACKUPS_DIR"; exit 0; }
bases=("$@"); [ ${#bases[@]} -gt 0 ] || mapfile -t bases < <(printf '%s\n' "${!ULTIMA[@]}" | sort)
err=0
for b in "${bases[@]}"; do
  if [ -z "${ULTIMA[$b]:-}" ]; then echo "AVISO: no hay copia de $b en $BACKUPS_DIR" >&2; err=1; continue; fi
  ./restore.sh "${ULTIMA[$b]}" "$b" || { echo "AVISO: la copia de $b se cargo con errores" >&2; err=1; }
done
exit $err
EOF
chmod +x start.sh stop.sh logs.sh psql.sh restore.sh cargar-copias.sh

# --------------------------------------------
# 5. Arranque
# --------------------------------------------
echo "==> Arrancando PostgreSQL, Adminer y Homepage..."
docker compose up -d --wait

if [ "$CARGAR_COPIAS" = "1" ]; then
  echo "==> Cargando las copias de $BACKUPS_DIR..."
  ./cargar-copias.sh || true
fi
BASES=$(docker compose exec -T postgres psql -U "$PG_USER" -d "$PG_DB" -Atc \
  "SELECT string_agg(datname, ', ' ORDER BY datname) FROM pg_database WHERE NOT datistemplate AND datname NOT IN ('postgres', '$PG_DB')")

echo
echo "============================================"
echo " PostgreSQL + Adminer + Homepage listos"
echo "============================================"
echo " PostgreSQL : localhost:$PG_PORT  (o 127.0.0.1:$PG_PORT; $PG_USER / $PG_PASSWORD, base $PG_DB)"
echo "   URL      : postgresql://$PG_USER:$PG_PASSWORD@localhost:$PG_PORT/$PG_DB"
echo "   psql     : $INSTALL_DIR/psql.sh"
echo "   bases    : ${BASES:-(ninguna cargada)}"
echo "   copias   : $INSTALL_DIR/cargar-copias.sh [base...]   (la mas reciente de $BACKUPS_DIR)"
echo "   restaurar: $INSTALL_DIR/restore.sh <fichero.dump|.sql> [base]   (los .dump no se cargan en Adminer)"
echo " Adminer    : http://localhost:$ADMINER_PORT/?pgsql=postgres&username=$PG_USER   ($PG_USER / $PG_PASSWORD)"
echo "              http://127.0.0.1:$ADMINER_PORT/?pgsql=postgres&username=$PG_USER"
echo "   desde otro equipo: ssh -L $ADMINER_PORT:127.0.0.1:$ADMINER_PORT -L $PG_PORT:127.0.0.1:$PG_PORT $USER@$IP"
echo " Homepage   : http://localhost:$HOMEPAGE_PORT   (servicios y credenciales)"
echo " Carpeta    : $INSTALL_DIR  (start.sh, stop.sh, logs.sh, psql.sh, restore.sh, cargar-copias.sh)"
echo
docker compose ps
