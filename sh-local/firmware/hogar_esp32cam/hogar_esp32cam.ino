// Camara e interruptor del tenant "Hogar" con UNA placa ESP32-CAM (AI-Thinker) y un rele.
// WiFi + MQTT con TLS hacia ThingsBoard (conexion saliente: no hay que abrir puertos en casa).
//   Foto: atributo de cliente "foto" (JPEG en base64): solo se guarda la ultima, sin historico
//   Rele: atributo compartido "rele" (lo cambia el panel); la placa responde con "rele_estado"
// Librerias: placa "esp32" (Espressif) y PubSubClient. Rele en GPIO13 (activo en alto).
#include <WiFi.h>
#include <WiFiClientSecure.h>
#include <PubSubClient.h>
#include "esp_camera.h"
#include "mbedtls/base64.h"

// ---- Rellena estos datos ----
const char* WIFI_SSID = "TU_WIFI";
const char* WIFI_PASS = "TU_CLAVE_WIFI";
const char* TB_HOST   = "TU_SERVIDOR";       // el nombre o IP que figura en el certificado
const char* TB_TOKEN  = "HOGAR_TOKEN";       // HOGAR_TOKEN de sh-local/.env.secretos
// Certificado que valida al servidor. Con dominio: la raiz de Let's Encrypt (ISRG Root X1).
// Sin dominio: el contenido de config/mqtt-certs/server.crt de la instalacion.
const char* CA_PEM = R"PEM(
-----BEGIN CERTIFICATE-----
PEGA_AQUI_EL_CERTIFICADO
-----END CERTIFICATE-----
)PEM";
// -----------------------------
const int  TB_PORT = 8883, PIN_RELE = 13;
const unsigned long FOTO_MS = 5000;

WiFiClientSecure red;
PubSubClient mqtt(red);
unsigned long ultimaFoto = 0;

void ponerRele(bool on) {
  digitalWrite(PIN_RELE, on ? HIGH : LOW);
  mqtt.publish("v1/devices/me/attributes", on ? "{\"rele_estado\":true}" : "{\"rele_estado\":false}");
}

// Llega {"rele":true} (cambio) o {"shared":{"rele":true}} (respuesta al arrancar)
void alRecibir(char*, byte* p, unsigned int n) {
  String s; s.reserve(n);
  for (unsigned int i = 0; i < n; i++) s += (char)p[i];
  int k = s.indexOf("\"rele\":");
  if (k >= 0) ponerRele(s.substring(k + 7).startsWith("true"));
}

void conectar() {
  while (WiFi.status() != WL_CONNECTED) delay(500);
  while (!mqtt.connected()) {
    if (mqtt.connect("hogar-esp32cam", TB_TOKEN, NULL)) {
      mqtt.subscribe("v1/devices/me/attributes");
      mqtt.subscribe("v1/devices/me/attributes/response/+");
      mqtt.publish("v1/devices/me/attributes/request/1", "{\"sharedKeys\":\"rele\"}");
    } else delay(5000);
  }
}

void enviarFoto() {
  camera_fb_t* f = esp_camera_fb_get();
  if (!f) return;
  size_t n = 0, cap = f->len * 4 / 3 + 8;
  unsigned char* b = (unsigned char*)ps_malloc(cap);
  if (b && mbedtls_base64_encode(b, cap, &n, f->buf, f->len) == 0) {
    const char* a = "{\"foto\":\"", *z = "\"}";
    if (mqtt.beginPublish("v1/devices/me/attributes", n + strlen(a) + strlen(z), false)) {
      mqtt.print(a);
      for (size_t i = 0; i < n; i += 1024) mqtt.write(b + i, min((size_t)1024, n - i));
      mqtt.print(z);
      mqtt.endPublish();
    }
  }
  free(b);
  esp_camera_fb_return(f);
}

void setup() {
  pinMode(PIN_RELE, OUTPUT);
  camera_config_t c = {};
  c.ledc_channel = LEDC_CHANNEL_0; c.ledc_timer = LEDC_TIMER_0;
  c.pin_d0 = 5; c.pin_d1 = 18; c.pin_d2 = 19; c.pin_d3 = 21; c.pin_d4 = 36; c.pin_d5 = 39; c.pin_d6 = 34; c.pin_d7 = 35;
  c.pin_xclk = 0; c.pin_pclk = 22; c.pin_vsync = 25; c.pin_href = 23; c.pin_sccb_sda = 26; c.pin_sccb_scl = 27;
  c.pin_pwdn = 32; c.pin_reset = -1; c.xclk_freq_hz = 20000000; c.pixel_format = PIXFORMAT_JPEG;
  c.frame_size = FRAMESIZE_QVGA; c.jpeg_quality = 20; c.fb_count = 1; c.fb_location = CAMERA_FB_IN_PSRAM;
  if (esp_camera_init(&c) != ESP_OK) ESP.restart();
  WiFi.begin(WIFI_SSID, WIFI_PASS);
  red.setCACert(CA_PEM);          // valida el certificado del servidor
  mqtt.setServer(TB_HOST, TB_PORT);
  mqtt.setCallback(alRecibir);
  mqtt.setBufferSize(1024);
}

void loop() {
  if (!mqtt.connected()) conectar();
  mqtt.loop();
  if (millis() - ultimaFoto >= FOTO_MS) { ultimaFoto = millis(); enviarFoto(); }
}
