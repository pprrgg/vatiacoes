#!/usr/bin/env bash
# ============================================================================
# Bootstrap del stack de supervision energetica via LoRaWAN
# ChirpStack + Mosquitto + Node-RED + ThingsBoard CE, con Docker Compose.
#
# Genera el arbol completo de directorios y archivos de configuracion (con
# una contrasena de PostgreSQL y un secreto de API generados al azar), y
# levanta el stack con "docker compose up -d".
#
# Uso:
#   chmod +x bootstrap-energy-lora-stack.sh
#   ./bootstrap-energy-lora-stack.sh [directorio-destino]
#
# Requisitos: docker y el plugin "docker compose" instalados.
# Referencia completa: seccion "Puesta en marcha" de la pagina del stack en
# el blog de Vatia&Co (Monitorizacion Energetica IoT).
# ============================================================================

set -euo pipefail

DEST="${1:-energy-lora-stack}"

if [ -e "$DEST" ]; then
  echo "El directorio \"$DEST\" ya existe. Elige otro destino o eliminalo antes de continuar." >&2
  exit 1
fi

command -v docker >/dev/null 2>&1 || {
  echo "Docker no esta instalado. Instala docker.io y el plugin docker-compose-plugin antes de continuar." >&2
  exit 1
}
docker compose version >/dev/null 2>&1 || {
  echo "El plugin 'docker compose' no esta disponible. Instala docker-compose-plugin." >&2
  exit 1
}
command -v openssl >/dev/null 2>&1 || {
  echo "openssl no esta instalado (se usa para generar contrasenas aleatorias)." >&2
  exit 1
}

echo "==> Creando arbol de directorios en \"$DEST\"..."
mkdir -p "$DEST/codecs"
mkdir -p "$DEST/node-red"
mkdir -p "$DEST/configuration/chirpstack"
mkdir -p "$DEST/configuration/chirpstack-gateway-bridge"
mkdir -p "$DEST/configuration/mosquitto"
mkdir -p "$DEST/configuration/postgresql/initdb"

cd "$DEST"

echo "==> Generando contrasena de PostgreSQL y secreto de API aleatorios..."
PG_PASSWORD="$(openssl rand -hex 16)"
API_SECRET="$(openssl rand -base64 32)"

echo "==> Escribiendo .env / .env.example..."
cat > .env <<EOF
# Generado automaticamente por bootstrap-energy-lora-stack.sh — guarda este archivo a salvo,
# no lo subas a un repositorio publico.
CHIRPSTACK_PG_PASSWORD=${PG_PASSWORD}
EOF

cat > .env.example <<'EOF'
# Copia este archivo como .env y cambia las contrasenas antes de desplegar
CHIRPSTACK_PG_PASSWORD=CambiaEstaPassword123!
EOF

echo "==> Escribiendo docker-compose.yml..."
cat > docker-compose.yml <<'EOF'
version: "3.8"

# ============================================================================
# Stack: Supervision de contadores de energia via LoRaWAN
# ChirpStack (LoRaWAN Network Server) -> Mosquitto (MQTT) -> Node-RED (traductor)
#   -> ThingsBoard CE (visualizacion / alarmas)
# ============================================================================

networks:
  iot-net:
    driver: bridge

volumes:
  chirpstack-postgres-data:
  chirpstack-redis-data:
  mosquitto-data:
  mosquitto-log:
  node-red-data:
  thingsboard-data:
  thingsboard-logs:

services:

  # --------------------------------------------------------------------
  # BASE DE DATOS Y CACHE PARA CHIRPSTACK
  # --------------------------------------------------------------------
  chirpstack-postgres:
    image: postgres:15-alpine
    container_name: chirpstack-postgres
    restart: unless-stopped
    environment:
      - POSTGRES_PASSWORD=${CHIRPSTACK_PG_PASSWORD}
      - CHIRPSTACK_PG_PASSWORD=${CHIRPSTACK_PG_PASSWORD}
    volumes:
      - chirpstack-postgres-data:/var/lib/postgresql/data
      - ./configuration/postgresql/initdb:/docker-entrypoint-initdb.d
    networks:
      - iot-net

  chirpstack-redis:
    image: redis:7-alpine
    container_name: chirpstack-redis
    restart: unless-stopped
    volumes:
      - chirpstack-redis-data:/data
    networks:
      - iot-net

  # --------------------------------------------------------------------
  # BROKER MQTT CENTRAL (usado por ChirpStack y por ThingsBoard/Node-RED)
  # --------------------------------------------------------------------
  mosquitto:
    image: eclipse-mosquitto:2
    container_name: mosquitto
    restart: unless-stopped
    ports:
      - "1883:1883"
    volumes:
      - ./configuration/mosquitto/mosquitto.conf:/mosquitto/config/mosquitto.conf:ro
      - mosquitto-data:/mosquitto/data
      - mosquitto-log:/mosquitto/log
    networks:
      - iot-net

  # --------------------------------------------------------------------
  # PUENTE ENTRE EL GATEWAY LORA (UDP Semtech) Y CHIRPSTACK (MQTT)
  # --------------------------------------------------------------------
  chirpstack-gateway-bridge:
    image: chirpstack/chirpstack-gateway-bridge:4
    container_name: chirpstack-gateway-bridge
    restart: unless-stopped
    ports:
      - "1700:1700/udp"   # aqui apunta el gateway fisico (Semtech UDP packet forwarder)
    volumes:
      - ./configuration/chirpstack-gateway-bridge:/etc/chirpstack-gateway-bridge
    depends_on:
      - mosquitto
    networks:
      - iot-net

  # --------------------------------------------------------------------
  # CHIRPSTACK NETWORK SERVER + APPLICATION SERVER (todo-en-uno v4)
  # --------------------------------------------------------------------
  chirpstack:
    image: chirpstack/chirpstack:4
    container_name: chirpstack
    restart: unless-stopped
    command: -c /etc/chirpstack
    ports:
      - "8080:8080"   # interfaz web de ChirpStack
    volumes:
      - ./configuration/chirpstack:/etc/chirpstack
    depends_on:
      - chirpstack-postgres
      - chirpstack-redis
      - mosquitto
      - chirpstack-gateway-bridge
    networks:
      - iot-net

  # --------------------------------------------------------------------
  # NODE-RED: traduce mensajes de ChirpStack -> formato ThingsBoard Gateway
  # --------------------------------------------------------------------
  node-red:
    image: nodered/node-red:latest
    container_name: node-red
    restart: unless-stopped
    ports:
      - "1880:1880"   # editor Node-RED
    volumes:
      - node-red-data:/data
      - ./node-red/flows-example.json:/data/flows-import.json:ro
    depends_on:
      - mosquitto
      - chirpstack
    networks:
      - iot-net

  # --------------------------------------------------------------------
  # THINGSBOARD CE (imagen todo-en-uno, con Postgres embebido)
  # --------------------------------------------------------------------
  thingsboard:
    image: thingsboard/tb-postgres:3.9.1
    container_name: thingsboard
    restart: unless-stopped
    ports:
      - "8081:9090"    # interfaz web -> http://<servidor>:8081
      - "1884:1883"    # API MQTT de ThingsBoard (distinto puerto host para no chocar con mosquitto)
      - "7070:7070"    # API Edge (opcional)
      - "5683-5688:5683-5688/udp"  # CoAP (opcional, no lo necesitas para este proyecto)
    environment:
      - TB_QUEUE_TYPE=in-memory
    volumes:
      - thingsboard-data:/data
      - thingsboard-logs:/var/log/thingsboard
    networks:
      - iot-net
EOF

echo "==> Escribiendo configuracion de ChirpStack..."
cat > configuration/chirpstack/chirpstack.toml <<EOF
[logging]
level="info"

[postgresql]
dsn="postgres://chirpstack:${PG_PASSWORD}@chirpstack-postgres/chirpstack?sslmode=disable"
# La password coincide con CHIRPSTACK_PG_PASSWORD del .env generado por este script.

[redis]
servers=["redis://chirpstack-redis/"]

[network]
net_id="000000"
enabled_regions=["eu868"]

[network.enabled_regions_configuration]

[gateway]
[gateway.backend]
type="mqtt"
[gateway.backend.mqtt]
server="tcp://mosquitto:1883"

[integration]
enabled=["mqtt"]
[integration.mqtt]
server="tcp://mosquitto:1883"
# Aqui es donde ChirpStack publicara los datos ya descodificados de cada
# contador, en el topic: application/{applicationID}/device/{devEUI}/event/up
# Node-RED se suscribe a ese topic para reenviarlo a ThingsBoard.

[api]
bind="0.0.0.0:8080"
secret="${API_SECRET}"
EOF

cat > configuration/chirpstack/region_eu868.toml <<'EOF'
# Configuracion de region para Espana / Europa.
# Este archivo se referencia automaticamente al habilitar "eu868" en chirpstack.toml.
# ChirpStack trae los parametros EU868 por defecto (frecuencias 863-870 MHz),
# normalmente no necesitas tocar nada aqui salvo que tengas un gateway con
# canales personalizados.
EOF

echo "==> Escribiendo configuracion de chirpstack-gateway-bridge..."
cat > configuration/chirpstack-gateway-bridge/chirpstack-gateway-bridge.toml <<'EOF'
[general]
log_level=4

[integration]
marshaler="protobuf"

[integration.mqtt]
event_topic_template="eu868/gateway/{{ .GatewayID }}/event/{{ .EventType }}"
command_topic_template="eu868/gateway/{{ .GatewayID }}/command/#"

[integration.mqtt.auth]
type="generic"
[integration.mqtt.auth.generic]
servers=["tcp://mosquitto:1883"]

[backend]
type="semtech_udp"

[backend.semtech_udp]
# Puerto en el que escucha este servicio a la espera de las tramas UDP
# que le envia el packet forwarder del gateway fisico.
udp_bind="0.0.0.0:1700"
EOF

echo "==> Escribiendo configuracion de Mosquitto..."
cat > configuration/mosquitto/mosquitto.conf <<'EOF'
listener 1883
allow_anonymous true

persistence true
persistence_location /mosquitto/data/
log_dest file /mosquitto/log/mosquitto.log

# NOTA DE SEGURIDAD:
# allow_anonymous true es comodo para arrancar rapido, pero en produccion
# deberias crear usuarios con mosquitto_passwd y poner allow_anonymous false,
# ya que este broker va a estar recibiendo datos energeticos de tus clientes.
EOF

echo "==> Escribiendo script de inicializacion de PostgreSQL..."
cat > configuration/postgresql/initdb/001-init-chirpstack.sh <<'EOF'
#!/bin/bash
set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    create role chirpstack with login password '${CHIRPSTACK_PG_PASSWORD}';
    create database chirpstack with owner chirpstack;
    \c chirpstack
    create extension if not exists pg_trgm;
    create extension if not exists hstore;
EOSQL
EOF
chmod +x configuration/postgresql/initdb/001-init-chirpstack.sh

echo "==> Escribiendo codec del SDM630..."
cat > codecs/sdm630_codec.js <<'EOF'
// ============================================================================
// CODEC de ejemplo para ChirpStack v4
// Dispositivo: Dragino RS485-LN leyendo un contador Eastron SDM630 (Modbus RTU)
// ============================================================================
//
// COMO USARLO:
// 1. En ChirpStack, ve a tu Device Profile -> pestana "Codec"
// 2. Selecciona "JavaScript functions (custom)"
// 3. Pega la funcion decodeUplink de abajo
//
// IMPORTANTE - AJUSTA ESTO A TU CONFIGURACION REAL:
// El Dragino RS485-LN te permite definir hasta varios "AT+COMMAND"
// (uno por cada rango de registros Modbus que quieres leer). El payload que
// llega por LoRaWAN concatena el resultado de cada comando, en el mismo
// orden en que los configuraste con AT+COMMANDx.
//
// Antes de dar esto por bueno:
//   - Configura el RS485-LN con los registros exactos de tu datasheet del
//     SDM630 (la direccion de registro puede variar segun el firmware/ano
//     del contador: SDM630 vs SDM630-MCT vs SDM630M no siempre coinciden).
//   - Verifica en la consola serie del Dragino (o en su app de configuracion)
//     el orden exacto de bytes que finalmente envia, y ajusta el "offset"
//     de este ejemplo si hace falta.
//   - La documentacion oficial de decoders de Dragino (repositorio
//     dragino-end-node-decoder en GitHub) trae ejemplos actualizados: es
//     buena idea contrastar con la version mas reciente antes de produccion.
//
// Este ejemplo asume que configuraste el RS485-LN para leer, en este orden,
// 8 registros float de 32 bits (function code 0x04, 2 registros = 4 bytes
// cada uno, IEEE754 big-endian "ABCD"):
//   V_L1, V_L2, V_L3, I_L1, I_L2, I_L3, P_total, Energia_total_kWh

function bytesToFloat32(bytes) {
  // bytes: array de 4 elementos, orden ABCD (big-endian), tipico en SDM630
  var buffer = new ArrayBuffer(4);
  var view = new DataView(buffer);
  for (var i = 0; i < 4; i++) {
    view.setUint8(i, bytes[i]);
  }
  return view.getFloat32(0, false); // false = big-endian
}

function decodeUplink(input) {
  var bytes = input.bytes;
  var data = {};
  var errors = [];

  // El Dragino RS485-LN suele anteponer 2 bytes de cabecera
  // (battery/status) antes de los datos Modbus. Ajusta "offset" si tu
  // payload no encaja - compara con el bytes.length esperado.
  var offset = 2;

  var campos = [
    "voltaje_l1", "voltaje_l2", "voltaje_l3",
    "corriente_l1", "corriente_l2", "corriente_l3",
    "potencia_total_w", "energia_total_kwh"
  ];

  try {
    for (var i = 0; i < campos.length; i++) {
      var chunk = bytes.slice(offset, offset + 4);
      if (chunk.length < 4) {
        errors.push("Payload mas corto de lo esperado en el campo " + campos[i]);
        break;
      }
      data[campos[i]] = Math.round(bytesToFloat32(chunk) * 100) / 100;
      offset += 4;
    }
  } catch (e) {
    errors.push("Error decodificando: " + e.message);
  }

  return {
    data: data,
    errors: errors
  };
}
EOF

echo "==> Escribiendo flujo de ejemplo de Node-RED..."
cat > node-red/flows-example.json <<'EOF'
[
  {
    "id": "broker-mosquitto",
    "type": "mqtt-broker",
    "name": "Mosquitto (ChirpStack)",
    "broker": "mosquitto",
    "port": "1883",
    "clientid": "",
    "usetls": false,
    "keepalive": "60",
    "cleansession": true
  },
  {
    "id": "broker-thingsboard",
    "type": "mqtt-broker",
    "name": "ThingsBoard (Gateway API)",
    "broker": "thingsboard",
    "port": "1883",
    "clientid": "",
    "usetls": false,
    "keepalive": "60",
    "cleansession": true,
    "credentials": {
      "user": "PON_AQUI_EL_ACCESS_TOKEN_DEL_DISPOSITIVO_GATEWAY",
      "password": ""
    }
  },
  {
    "id": "tab-energia",
    "type": "tab",
    "label": "Contadores de energia - ChirpStack a ThingsBoard",
    "disabled": false,
    "info": "Flujo que se suscribe a los eventos 'uplink' de ChirpStack (MQTT) y los reenvia a ThingsBoard usando su Gateway API, para no tener que crear un token MQTT por cada uno de los 20-50 contadores."
  },
  {
    "id": "in-chirpstack",
    "type": "mqtt in",
    "z": "tab-energia",
    "name": "Uplinks ChirpStack",
    "topic": "application/+/device/+/event/up",
    "qos": "1",
    "datatype": "json",
    "broker": "broker-mosquitto",
    "x": 180,
    "y": 120,
    "wires": [["fn-transform"]]
  },
  {
    "id": "fn-transform",
    "type": "function",
    "z": "tab-energia",
    "name": "Transformar a formato ThingsBoard Gateway",
    "func": "// msg.payload es el evento 'up' de ChirpStack ya decodificado por el codec\n// Estructura relevante:\n//   payload.deviceInfo.deviceName\n//   payload.deviceInfo.devEui\n//   payload.object  <- lo que devolvio tu codec (sdm630_codec.js)\n//   payload.time    <- timestamp ISO de la trama\n\nvar p = msg.payload;\n\nif (!p || !p.deviceInfo || !p.object) {\n    node.warn('Trama sin objeto decodificado, se descarta (revisa el codec en ChirpStack)');\n    return null;\n}\n\n// Nombre con el que aparecera el dispositivo en ThingsBoard.\n// Puedes usar el deviceName que le pongas en ChirpStack (recomendado:\n// usa un nombre legible tipo \"CT-Nave3-ContadorGeneral\" al dar de alta\n// cada device en ChirpStack, asi no tienes que mapear nada aqui).\nvar deviceName = p.deviceInfo.deviceName || p.deviceInfo.devEui;\n\nvar ts = p.time ? new Date(p.time).getTime() : Date.now();\n\nvar gatewayPayload = {};\ngatewayPayload[deviceName] = [\n    {\n        ts: ts,\n        values: p.object\n    }\n];\n\nmsg.payload = gatewayPayload;\nmsg.topic = 'v1/gateway/telemetry';\nreturn msg;",
    "outputs": 1,
    "x": 480,
    "y": 120,
    "wires": [["out-thingsboard", "debug-out"]]
  },
  {
    "id": "out-thingsboard",
    "type": "mqtt out",
    "z": "tab-energia",
    "name": "ThingsBoard v1/gateway/telemetry",
    "topic": "v1/gateway/telemetry",
    "qos": "1",
    "retain": "false",
    "broker": "broker-thingsboard",
    "x": 800,
    "y": 100,
    "wires": []
  },
  {
    "id": "debug-out",
    "type": "debug",
    "z": "tab-energia",
    "name": "Debug (ver en pestana Debug)",
    "active": true,
    "tosidebar": true,
    "console": false,
    "complete": "payload",
    "x": 800,
    "y": 160,
    "wires": []
  }
]
EOF

echo "==> Levantando el stack con docker compose (puede tardar unos minutos la primera vez)..."
docker compose up -d

echo
echo "======================================================================"
echo " Stack levantado en \"$DEST\"."
echo "======================================================================"
echo " ChirpStack   : http://localhost:8080  (admin / admin)"
echo " ThingsBoard  : http://localhost:8081  (sysadmin@thingsboard.org / sysadmin)"
echo " Node-RED     : http://localhost:1880"
echo " Mosquitto    : localhost:1883 (MQTT)"
echo " Gateway UDP  : localhost:1700/udp  <- aqui apunta tu gateway fisico"
echo
echo " Contrasena de PostgreSQL y secreto de API generados al azar y guardados en:"
echo "   $DEST/.env"
echo "   $DEST/configuration/chirpstack/chirpstack.toml"
echo
echo " Cambia las contrasenas por defecto de ChirpStack y ThingsBoard en cuanto"
echo " entres por primera vez. Siguientes pasos manuales: da de alta el gateway y"
echo " los contadores en ChirpStack (con el codec de codecs/sdm630_codec.js), e"
echo " importa node-red/flows-example.json en Node-RED con el Access Token del"
echo " dispositivo Gateway de ThingsBoard (ver seccion 'Puesta en marcha' de la"
echo " pagina del stack en el blog)."
echo "======================================================================"
