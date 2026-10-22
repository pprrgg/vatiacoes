#!/usr/bin/env python3
"""
Cliente sencillo para la API privada de Datadis (https://datadis.es).

Qué hace:
  1. Inicia sesión y obtiene el token.
  2. Lista los CUPS de la cuenta y, opcionalmente, los de NIF que te han autorizado
     (socios de la comunidad energética).
  3. Descarga las curvas de consumo/excedentes (cuartohorarias si existen; si no, horarias).
  4. Guarda la respuesta original (JSON) y un CSV limpio con marcas de tiempo en UTC,
     listas para enviar a ThingsBoard u otra base de datos.

Uso:
  pip install requests
  cp py/.env.example py/.env   # y rellena usuario, contraseña y NIF autorizados

  # Tus suministros + los de los NIF de DATADIS_NIF_AUTORIZADOS, mes actual:
  python py/datadis.py

  # Solo suministros de terceros, de julio a octubre de 2026, forzando horario:
  python py/datadis.py --solo-terceros --nif 11111111H --desde 2026/07 --hasta 2026/10 --horario

  # Un único CUPS:
  python py/datadis.py --cups ES0021000012345678AB

Notas importantes:
  - Datadis bloquea durante 24 h una consulta idéntica (y cuenta también las rechazadas).
    Por eso el script guarda una caché local de consultas hechas en las últimas 24 h
    y no las repite salvo que uses --forzar.
  - Las fechas de consulta son mensuales (AAAA/MM).
  - Endpoints y nombres de campos tomados de librerías cliente mantenidas (e-data, datadis).
    Haz una primera prueba con un CUPS y revisa el JSON guardado en ./datadis_out/raw/.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
import sys
import time
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

import requests

# ============================ CONFIGURACIÓN ============================
# Las credenciales se leen de variables de entorno o de un fichero .env junto
# a este script (py/.env, ignorado por git). Plantilla en py/.env.example:
#   DATADIS_USER=12345678Z                 # NIF/NIE con el que entras en datadis.es
#   DATADIS_PASS=...
#   DATADIS_NIF_AUTORIZADOS=11111111H,22222222J   # NIF que te han autorizado (terceros)
SCRIPT_DIR = Path(__file__).resolve().parent


def _load_dotenv(path: Path) -> None:
    """Carga KEY=VALUE de un .env sin pisar variables ya definidas en el entorno."""
    if not path.is_file():
        return
    for linea in path.read_text(encoding="utf-8").splitlines():
        linea = linea.strip()
        if not linea or linea.startswith("#") or "=" not in linea:
            continue
        k, v = linea.split("=", 1)
        v = v.split(" #", 1)[0].strip().strip('"').strip("'")
        os.environ.setdefault(k.strip(), v)


_load_dotenv(SCRIPT_DIR / ".env")

DATADIS_USER = os.getenv("DATADIS_USER", "")
DATADIS_PASS = os.getenv("DATADIS_PASS", "")
NIF_AUTORIZADOS: list[str] = [
    n.strip().upper() for n in os.getenv("DATADIS_NIF_AUTORIZADOS", "").split(",") if n.strip()
]
# =======================================================================

HOST = "https://datadis.es"
URL_LOGIN = f"{HOST}/nikola-auth/tokens/login"
URL_SUPPLIES = f"{HOST}/api-private/api/get-supplies-v2"
URL_CONSUMPTION = f"{HOST}/api-private/api/get-consumption-data-v2"

TZ_ES = ZoneInfo("Europe/Madrid")
HOURLY, QUARTER = 0, 1          # measurementType
TIMEOUT = 180                   # Datadis puede tardar bastante en responder
OUT = SCRIPT_DIR / "datadis_out"
CACHE_FILE = OUT / "consultas_24h.json"


# --------------------------------------------------------------------------- API

class Datadis:
    def __init__(self, user: str, password: str):
        self.user, self.password = user, password
        self.s = requests.Session()
        self.s.headers["Accept-Encoding"] = "identity"
        self.token: str | None = None

    def login(self) -> None:
        r = self.s.post(URL_LOGIN, data={"username": self.user, "password": self.password},
                        timeout=TIMEOUT)
        if r.status_code != 200:
            raise RuntimeError(f"Login rechazado ({r.status_code}): {r.text[:200]}")
        self.token = r.text.strip()
        self.s.headers["Authorization"] = f"Bearer {self.token}"

    def _get(self, url: str, params: dict) -> dict:
        if not self.token:
            self.login()
        for intento in range(2):
            r = self.s.get(url, params=params, timeout=TIMEOUT)
            if r.status_code == 401 and intento == 0:      # token caducado → renovar
                self.login()
                continue
            if r.status_code == 429:
                raise RuntimeError("Datadis: límite de consultas (429). Espera 24 h para repetirla.")
            if r.status_code != 200:
                raise RuntimeError(f"Error {r.status_code} en {url}: {r.text[:300]}")
            return r.json() if r.text.strip() else {}
        return {}

    def supplies(self, authorized_nif: str | None = None) -> list[dict]:
        params = {"authorizedNif": authorized_nif} if authorized_nif else {}
        data = self._get(URL_SUPPLIES, params)
        _report_distributor_errors(data)
        return data.get("supplies", []) if isinstance(data, dict) else data

    def consumption(self, supply: dict, desde: str, hasta: str,
                    measurement_type: int, authorized_nif: str | None = None) -> dict:
        params = {
            "cups": supply["cups"],
            "distributorCode": supply["distributorCode"],
            "startDate": desde,             # AAAA/MM
            "endDate": hasta,               # AAAA/MM
            "measurementType": measurement_type,
            "pointType": supply["pointType"],
        }
        if authorized_nif:
            params["authorizedNif"] = authorized_nif
        data = self._get(URL_CONSUMPTION, params)
        _report_distributor_errors(data)
        return data


def _report_distributor_errors(data) -> None:
    if isinstance(data, dict):
        for e in data.get("distributorError") or []:
            print(f"   ⚠ Distribuidora {e.get('distributorName', e.get('distributorCode'))}: "
                  f"{e.get('errorDescription', e)}")


# --------------------------------------------------------- caché de consultas 24 h

def _load_cache() -> dict:
    try:
        cache = json.loads(CACHE_FILE.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return {}
    limite = time.time() - 24 * 3600
    return {k: v for k, v in cache.items() if v > limite}


def _save_cache(cache: dict) -> None:
    CACHE_FILE.parent.mkdir(parents=True, exist_ok=True)
    CACHE_FILE.write_text(json.dumps(cache, indent=1))


def _key(*parts) -> str:
    return hashlib.sha1("|".join(map(str, parts)).encode()).hexdigest()[:16]


# ---------------------------------------------------- conversión a tiempos en UTC

def to_utc_rows(time_curve: list[dict], measurement_type: int) -> list[dict]:
    """
    Datadis da fecha local + hora de FIN del periodo ("01:00".."24:00" o "00:15".."24:00").
    Se calcula el instante desde la medianoche local de ese día, pasada a UTC, sumando
    los minutos de la etiqueta; así los días de 23 y 25 horas (cambio de hora) quedan bien
    siempre que la distribuidora numere los periodos de forma correlativa.
    Devuelve el INICIO del periodo en UTC (convención habitual en ThingsBoard).
    """
    paso = timedelta(minutes=15 if measurement_type == QUARTER else 60)
    filas = []
    for r in time_curve:
        try:
            d = datetime.strptime(r["date"], "%Y/%m/%d").date()
            hh, mm = map(int, r["time"].split(":"))
        except (KeyError, ValueError):
            continue
        minutos_fin = hh * 60 + mm
        if minutos_fin == 0:            # fila espuria "00:00" que emiten algunas distribuidoras
            continue
        medianoche_utc = datetime(d.year, d.month, d.day, tzinfo=TZ_ES).astimezone(timezone.utc)
        inicio = medianoche_utc + timedelta(minutes=minutos_fin) - paso
        filas.append({
            "cups": r.get("cups"),
            "inicio_utc": inicio.isoformat().replace("+00:00", "Z"),
            "ts_ms": int(inicio.timestamp() * 1000),
            "fecha_local": r["date"],
            "hora_fin_local": r["time"],
            "consumo_kwh": _num(r.get("consumptionKWh")),
            "excedente_kwh": _num(r.get("surplusEnergyKWh")),
            "generacion_kwh": _num(r.get("generationEnergyKWh")),
            "autoconsumo_kwh": _num(r.get("selfConsumptionEnergyKWh")),
            "metodo": r.get("obtainMethod", ""),
            "resolucion": "15min" if measurement_type == QUARTER else "1h",
        })
    filas.sort(key=lambda x: x["ts_ms"])
    return filas


def _num(v) -> float | None:
    try:
        return None if v is None else float(v)
    except (TypeError, ValueError):
        return None


# ------------------------------------------------------------------------ guardado

def save(cups: str, desde: str, hasta: str, raw: dict, filas: list[dict]) -> Path:
    tag = f"{cups}_{desde.replace('/', '-')}_{hasta.replace('/', '-')}"
    (OUT / "raw").mkdir(parents=True, exist_ok=True)
    (OUT / "raw" / f"{tag}.json").write_text(json.dumps(raw, indent=2, ensure_ascii=False))
    path = OUT / f"{tag}.csv"
    if filas:
        with path.open("w", newline="", encoding="utf-8") as f:
            w = csv.DictWriter(f, fieldnames=list(filas[0].keys()))
            w.writeheader()
            w.writerows(filas)
    return path


# --------------------------------------------------------------------------- main

def main() -> int:
    hoy = date.today()
    ap = argparse.ArgumentParser(description="Descarga curvas de Datadis")
    ap.add_argument("--nif", nargs="*", default=[], help="NIF autorizados (socios)")
    ap.add_argument("--cups", nargs="*", default=[], help="Limitar a estos CUPS")
    ap.add_argument("--desde", default=f"{hoy.year}/{hoy.month:02d}", help="AAAA/MM")
    ap.add_argument("--hasta", default=f"{hoy.year}/{hoy.month:02d}", help="AAAA/MM")
    ap.add_argument("--horario", action="store_true", help="No intentar cuartohorario")
    ap.add_argument("--forzar", action="store_true", help="Ignorar la caché de 24 h")

    ap.add_argument("--solo-terceros", action="store_true",
                    help="No descargar los suministros propios de la cuenta")
    args = ap.parse_args()

    user, pwd = DATADIS_USER, DATADIS_PASS
    if not user or not pwd:
        print(f"Faltan DATADIS_USER / DATADIS_PASS. Defínelas en el entorno o en "
              f"{SCRIPT_DIR / '.env'} (ver .env.example).", file=sys.stderr)
        return 2
    if not args.nif:
        args.nif = list(NIF_AUTORIZADOS)

    api = Datadis(user, pwd)
    api.login()
    print("✓ Sesión iniciada")

    cache = _load_cache()
    titulares = ([] if args.solo_terceros else [None]) + args.nif   # None = cuenta propia

    for nif in titulares:
        etiqueta = f"NIF autorizado {nif}" if nif else "cuenta propia"
        try:
            sups = api.supplies(nif)
        except RuntimeError as e:
            print(f"✗ {etiqueta}: {e}")
            continue
        if args.cups:
            sups = [s for s in sups if s.get("cups") in args.cups]
        print(f"\n{etiqueta}: {len(sups)} suministro(s)")

        for s in sups:
            cups = s["cups"]
            print(f" • {cups}  (tipo {s.get('pointType')}, {s.get('distributor', '')})")
            tipos = [HOURLY] if args.horario else [QUARTER, HOURLY]
            for mt in tipos:
                k = _key(cups, nif, args.desde, args.hasta, mt)
                if k in cache and not args.forzar:
                    print("   – ya consultado en las últimas 24 h, se omite (usa --forzar)")
                    break
                try:
                    raw = api.consumption(s, args.desde, args.hasta, mt, nif)
                except RuntimeError as e:
                    print(f"   ✗ {e}")
                    break
                cache[k] = time.time()
                _save_cache(cache)
                curva = raw.get("timeCurve", []) if isinstance(raw, dict) else raw
                if not curva and mt == QUARTER:
                    print("   – sin datos cuartohorarios, pruebo horario")
                    continue
                filas = to_utc_rows(curva, mt)
                path = save(cups, args.desde, args.hasta, raw, filas)
                tot_c = sum(f["consumo_kwh"] or 0 for f in filas)
                tot_e = sum(f["excedente_kwh"] or 0 for f in filas)
                est = sum(1 for f in filas if f["metodo"].lower().startswith("estim"))
                ultimo = filas[-1]["fecha_local"] + " " + filas[-1]["hora_fin_local"] if filas else "—"
                print(f"   ✓ {len(filas)} registros ({'15 min' if mt == QUARTER else '1 h'}), "
                      f"consumo {tot_c:.2f} kWh, excedente {tot_e:.2f} kWh, "
                      f"{est} estimados, último dato {ultimo} → {path}")
                break
    return 0


if __name__ == "__main__":
    sys.exit(main())