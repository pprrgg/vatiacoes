#!/usr/bin/env python3
"""
Genera datos SIMULADOS de Datadis con el mismo formato que las descargas de la web
(carpetas datadis/qw0f, sw0f, tb0f): Consumo, Potencias, Contrato y Energia (reactiva).

Perfiles (dos últimos años, del 17/10/2024 al 15/10/2026):
  sim_30td_hasta50kw      3.0TD baja tensión, 30 kW (contador tipo 4), comercio.
                          Curva horaria + maxímetro + reactiva.
  sim_61td_mas450kw       6.1TD alta tensión, 600 kW (contador tipo 2), industria a dos
                          turnos. Curva cuartohoraria + maxímetro + reactiva.

Ficheros: Consumo, Potencias (maxímetro mensual por periodo, integración 15 min),
Contrato, Energia (reactiva inductiva mensual por periodo, kVArh, como Datadis) y
Reactiva (curva inductiva R1 / capacitiva R4 del contador; Datadis no la publica).
  sim_20td_fv_excedentes  2.0TD vivienda con FV de 4,5 kWp con excedentes y compensación.
                          Horario, con energía vertida, generada y autoconsumida.

Viviendas con FV y recarga de vehículo eléctrico (comunidad Demo2), 2.0TD horario:
  sim_20td_fv_ve_noche    FV 5 kWp; cargador de 7,4 kW programado en valle (desde la 01:00).
  sim_20td_fv_ve_solar    FV 6 kWp; cargador inteligente que sigue los excedentes FV
                          (1,4–7,4 kW) los días que el coche está en casa; si no basta,
                          completa de madrugada a 3,7 kW.
  sim_20td_fv_ve_tarde    FV 3,5 kWp; carga a 3,7 kW al llegar a casa (19:00, en punta).

Los CUPS son ficticios (ES0031 9999 ...) con letras de control válidas.

Uso:
  python py/datadis_sintetico.py [--out datadis] [--semilla 42] [--solo carpeta ...]
"""

from __future__ import annotations

import argparse
import math
import random
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

TZ = ZoneInfo("Europe/Madrid")
DESDE, HASTA = date(2024, 10, 17), date(2026, 10, 15)      # días locales incluidos
SUFIJO = "17-10-2024_17-10-2026"
LAT, LON = 37.18, -3.60                                     # Granada
Q = timedelta(minutes=15)

# Festivos nacionales no sustituibles (CNMC): todo el día en P6 / valle
FESTIVOS = {(1, 1), (5, 1), (8, 15), (10, 12), (11, 1), (12, 6), (12, 8), (12, 25)}


# ------------------------------------------------------------------ utilidades

def cups(n: int) -> str:
    num = f"0031{9999_0000_0000 + n:012d}"
    r = int(num) % 529
    letras = "TRWAGMYFPDXBNJZSQVHLCKE"
    return f"ES{num}{letras[r // 23]}{letras[r % 23]}0F"


def f3(v: float) -> str:
    return f'"{v:.3f}"'.replace(".", ",")


def fpot(v: float) -> str:
    return f"{v:g}".replace(".", ",")


def es_festivo(d: date) -> bool:
    return d.weekday() == 6 or d.weekday() == 5 or (d.month, d.day) in FESTIVOS


def periodo_20td(d: date, h: int) -> int:
    """Periodo de energía 2.0TD (1 punta, 2 llano, 3 valle) para la hora local h (0..23)."""
    if es_festivo(d) or h < 8:
        return 3
    return 1 if (10 <= h < 14 or 18 <= h < 22) else 2


TEMPORADA = {1: 1, 2: 1, 7: 1, 12: 1, 3: 2, 11: 2, 6: 3, 8: 3, 9: 3, 4: 4, 5: 4, 10: 4}


def periodo_6p(d: date, h: int) -> int:
    """Periodo 3.0TD / 6.1TD peninsular (P1..P6) para la hora local h (0..23)."""
    if es_festivo(d) or h < 8:
        return 6
    base = TEMPORADA[d.month]                   # alta→P1/P2, media-alta→P2/P3, ...
    punta = 9 <= h < 14 or 18 <= h < 22
    return base if punta else base + 1


def dias():
    d = DESDE
    while d <= HASTA:
        yield d
        d += timedelta(days=1)


def cuartos_del_dia(d: date):
    """Instantes UTC de inicio de cada cuarto de hora del día local d (92, 96 o 100)."""
    ini = datetime(d.year, d.month, d.day, tzinfo=TZ).astimezone(timezone.utc)
    sig = d + timedelta(days=1)
    fin = datetime(sig.year, sig.month, sig.day, tzinfo=TZ).astimezone(timezone.utc)
    t = ini
    while t < fin:
        yield t
        t += Q


def etiquetas(n_unidades: int, por_hora: int) -> list[str]:
    """Etiquetas de fin de periodo como las da Datadis (01:00..24:00). Cambio de hora:
    en primavera falta la hora '03:00' y en otoño se repite."""
    paso = 60 // por_hora
    base = [f"{(i * paso) // 60:02d}:{(i * paso) % 60:02d}" for i in range(1, 24 * por_hora + 1)]
    if n_unidades == 23 * por_hora:              # primavera: se salta 02:xx→03:00
        return base[: 2 * por_hora] + base[3 * por_hora:]
    if n_unidades == 25 * por_hora:              # otoño: se repite la hora 03:00
        return base[: 3 * por_hora] + base[2 * por_hora: 3 * por_hora] + base[3 * por_hora:]
    return base


# -------------------------------------------------------------------- clima y sol

class Clima:
    def __init__(self, rnd: random.Random):
        self.rnd = rnd
        self.anom: dict[date, float] = {}
        self.nube: dict[date, float] = {}
        a = 0.0
        for d in dias():
            a = 0.7 * a + rnd.gauss(0, 1.6)
            self.anom[d] = a
            verano = 0.5 + 0.5 * math.cos(2 * math.pi * (d.timetuple().tm_yday - 196) / 365)
            p_nublado = 0.30 - 0.24 * verano
            self.nube[d] = (rnd.uniform(0.15, 0.6) if rnd.random() < p_nublado
                            else rnd.uniform(0.85, 1.0))

    def temp(self, t_local: datetime) -> float:
        d = t_local.date()
        doy = d.timetuple().tm_yday
        media = 16.5 + 9.5 * math.cos(2 * math.pi * (doy - 200) / 365)
        amplitud = 5 + 3 * math.cos(2 * math.pi * (doy - 200) / 365)
        h = t_local.hour + t_local.minute / 60
        return media + self.anom.get(d, 0) + amplitud * math.cos(2 * math.pi * (h - 16) / 24)


def irradiancia_poa(t_utc: datetime, inclinacion=30.0) -> float:
    """W/m² en un plano orientado al sur (modelo de cielo despejado sencillo)."""
    n = t_utc.timetuple().tm_yday
    b = 2 * math.pi * (n - 81) / 364
    eot = 9.87 * math.sin(2 * b) - 7.53 * math.cos(b) - 1.5 * math.sin(b)
    hora_solar = t_utc.hour + t_utc.minute / 60 + LON / 15 + eot / 60
    w = math.radians(15 * (hora_solar - 12))
    dec = math.radians(23.45 * math.sin(2 * math.pi * (284 + n) / 365))
    lat, beta = math.radians(LAT), math.radians(inclinacion)
    sin_e = math.sin(lat) * math.sin(dec) + math.cos(lat) * math.cos(dec) * math.cos(w)
    if sin_e <= 0.02:
        return 0.0
    am = 1 / sin_e
    dni = 1353 * 0.7 ** (am ** 0.678)
    cos_i = (math.sin(dec) * math.sin(lat - beta)
             + math.cos(dec) * math.cos(lat - beta) * math.cos(w))
    return dni * max(cos_i, 0) + 0.12 * dni * sin_e * (1 + math.cos(beta)) / 2


# ------------------------------------------------------------------ perfiles (kW)

def carga_comercio(t: datetime, temp: float, rnd: random.Random) -> float:
    d, h = t.date(), t.hour + t.minute / 60
    p = 3.2 + rnd.uniform(-0.4, 0.8)                       # frío comercial, siempre
    cerrado = d.weekday() == 6 or (d.month, d.day) in FESTIVOS
    abierto = not cerrado and (9 <= h < (14 if d.weekday() == 5 else 21))
    if abierto:
        p += 9 + rnd.gauss(0, 1.2)
        p += 1.7 * max(0, temp - 23) + 1.3 * max(0, 14 - temp)    # climatización
    elif not cerrado and (8 <= h < 9 or 21 <= h < 22):
        p += 3 + rnd.gauss(0, 0.5)
    return max(p, 1.0)


def carga_industria(t: datetime, temp: float, rnd: random.Random) -> float:
    d, h = t.date(), t.hour + t.minute / 60
    base = 42 + rnd.gauss(0, 4)                            # compresores, alumbrado, SSAA
    vacaciones = (d.month == 8 and d.day <= 23) or (d.month, d.day) >= (12, 24) or \
                 (d.month == 1 and d.day <= 6)
    if (d.month, d.day) in FESTIVOS or d.weekday() == 6 or vacaciones:
        prod = 0.0
    elif d.weekday() == 5:
        prod = 0.55 if 6 <= h < 14 else 0.0
    else:
        prod = 1.0 if 6 <= h < 22 else 0.0
        if 14 <= h < 14.5 or 22 <= h < 22.25:              # cambio de turno
            prod *= 0.6
    p = base + prod * (205 + rnd.gauss(0, 14)) + 3.5 * max(0, temp - 24)
    if prod and rnd.random() < 0.02:                       # arranques puntuales
        p += rnd.uniform(15, 45)
    return max(p, 20.0)


class Vivienda:
    def __init__(self, rnd: random.Random):
        self.rnd = rnd
        self.extra: dict[datetime, float] = {}

    def carga(self, t: datetime, temp: float) -> float:
        rnd, d = self.rnd, t.date()
        h = t.hour + t.minute / 60
        p = 0.16 + rnd.uniform(0, 0.06)
        finde = d.weekday() >= 5
        if 7 <= h < 9 and not finde:
            p += 0.45 + rnd.uniform(0, 0.4)
        if 9.5 <= h < 14 and finde:
            p += 0.35 + rnd.uniform(0, 0.3)
        if 13.5 <= h < 15.5:
            p += 0.3 + rnd.uniform(0, 0.4)
        if 19 <= h < 23:
            p += 0.35 + rnd.uniform(0, 0.45)
        if 18 <= h < 24 or 7 <= h < 9:
            p += 0.14 * max(0, 14 - temp)                  # bomba de calor
        if 14 <= h < 23:
            p += 0.22 * max(0, temp - 27)                  # aire acondicionado
        if rnd.random() < 0.012:                           # lavadora, horno, lavavajillas…
            for k in range(rnd.randint(4, 8)):
                self.extra[t + k * Q] = self.extra.get(t + k * Q, 0) + rnd.uniform(1.0, 2.0)
        return p + self.extra.pop(t, 0.0)


class RecargaVE:
    """Recarga de un vehículo eléctrico en casa (kW por cuarto de hora).

    Cada día que se conduce, a las 08:00 se suma la energía gastada (km × kWh/km) a la
    pendiente de cargar; el coche está fuera de 08:00 a 18:00 salvo los días en casa
    (fines de semana y teletrabajo). modo:
      noche  a "kw" desde la 01:00 hasta reponer lo pendiente (si pasa de 4 kWh)
      solar  los días en casa, de 10:00 a 17:00, con los excedentes FV (1,4 kW mínimo,
             "kw" máximo); de madrugada, a 3,7 kW, si quedan más de 12 kWh pendientes
      tarde  a "kw" desde las 19:00 los días laborables hasta reponer lo pendiente
    """

    def __init__(self, rnd: random.Random, modo: str, kw: float, km_dia: float,
                 kwh_km: float = 0.16, teletrabajo=()):
        self.rnd, self.modo, self.kw, self.km, self.kwh_km = rnd, modo, kw, km_dia, kwh_km
        self.teletrabajo = set(teletrabajo)
        self.pend = 0.0
        self.cargando = False

    def en_casa(self, d: date, h: float) -> bool:
        return d.weekday() >= 5 or d.weekday() in self.teletrabajo or not (8 <= h < 18)

    def potencia(self, t: datetime, excedente_kw: float) -> float:
        d, h = t.date(), t.hour + t.minute / 60
        if t.hour == 8 and t.minute == 0:                  # viajes del día
            casa = d.weekday() >= 5 or d.weekday() in self.teletrabajo
            km = self.km * (self.rnd.uniform(0, 1.6) if casa else self.rnd.uniform(0.6, 1.4))
            if self.rnd.random() < 0.04:                   # viaje largo
                km += self.rnd.uniform(150, 300)
            self.pend += km * self.kwh_km
        if not self.en_casa(d, h) or self.pend <= 0.05:
            self.cargando = False
            return 0.0
        kw = 0.0
        if self.modo == "noche":
            if t.hour == 1 and t.minute == 0 and self.pend > 4:
                self.cargando = True
            kw = self.kw if self.cargando else 0.0
        elif self.modo == "solar":
            casa = d.weekday() >= 5 or d.weekday() in self.teletrabajo
            if casa and 10 <= h < 17 and excedente_kw >= 1.4:
                kw = min(excedente_kw, self.kw)
            elif 2 <= h < 7 and self.pend > 12:
                kw = 3.7
        elif self.modo == "tarde":
            if t.hour == 19 and t.minute == 0 and d.weekday() < 5:
                self.cargando = True
            kw = self.kw if self.cargando else 0.0
        kw = min(kw, self.pend * 4 / 0.92)                 # no carga más de lo pendiente
        self.pend -= kw / 4 * 0.92                         # pérdidas del cargador y la batería
        if self.pend <= 0.05:
            self.cargando = False
        return kw


# ----------------------------------------------------------------------- escritura

def escribir(carpeta: Path, req: int, perfil: dict, filas_consumo, potencias, reactiva,
             filas_reactiva):
    carpeta.mkdir(parents=True, exist_ok=True)
    for viejo in carpeta.glob("*.csv"):
        viejo.unlink()
    c = perfil["cups"]

    with (carpeta / f"Consumo_{req}{SUFIJO}.csv").open("w", encoding="utf-8", newline="") as f:
        f.write("cups;fecha;hora;consumo_kWh;metodoObtencion;energiaVertida_kWh;"
                "energiaGenerada_kWh;energiaAutoconsumida_kWh\n")
        for fecha, hora, cons, met, vert, gen, auto in filas_consumo:
            extra = ";".join(f3(x) if x is not None else "" for x in (vert, gen, auto))
            f.write(f'"{c}";"{fecha}";"{hora}";{f3(cons)};{met};{extra}\n')

    with (carpeta / f"Potencias_{req + 1}{SUFIJO}.csv").open("w", encoding="utf-8", newline="") as f:
        f.write("cups;fechaMaximo;hora;maximoPotenciaDemandadaKW;periodo\n")
        for fecha, hora, kw, per in potencias:
            f.write(f'"{c}";"{fecha}";"{hora}";{f3(kw)};"{per}"\n')

    with (carpeta / f"Contrato_{req + 2}{SUFIJO}.csv").open("w", encoding="utf-8", newline="") as f:
        f.write("cups;distribuidora;comercializadora;tarifaAcceso;tensionConexion;"
                "potenciaContratadakW;modoControlPotencia;discriminacionHoraria;"
                "fechaInicioVigencia;fechaFinVigencia;provincia;municipio;codigoPostal;"
                "potenciaTotalGenerada;tipoAutoconsumo;seccion;subseccion;coeficienteReparto;"
                "cau;potenciaMaximaInstalacion\n")
        a = perfil.get("autoconsumo")
        auto = (f'"{a["potencia"]}";"{a["tipo"]}";"{a["seccion"]}";"{a["subseccion"]}";'
                f'"{a["coef"]}";"{a["cau"]}"') if a else ";;;;;"
        pot = ";".join(fpot(x) for x in perfil["potencias"])
        f.write(f'"{c}";EDISTRIBUCIÓN;"-";"{perfil["tarifa"]}";"{perfil["tension"]}";"{pot}";'
                f'{perfil["control"]};"{perfil["discriminacion"]}";"{perfil["inicio"]}";;'
                f'{perfil["provincia"]};{perfil["municipio"]};"{perfil["cp"]}";{auto};'
                f'"{perfil["pmax_instalacion"]}"\r\n')

    with (carpeta / f"Energia_{req + 3}{SUFIJO}.csv").open("w", encoding="utf-8", newline="") as f:
        f.write("cups;fecha;energiaP1;energiaP2;energiaP3;energiaP4;energiaP5;energiaP6\n")
        for mes, valores in reactiva:
            f.write(f'"{c}";"{mes}";' + ";".join(f3(v) for v in valores) + "\n")

    # Curva de reactiva del contador (no la publica Datadis: la da la distribuidora)
    if filas_reactiva:
        with (carpeta / f"Reactiva_{req + 4}{SUFIJO}.csv").open("w", encoding="utf-8",
                                                               newline="") as f:
            f.write("cups;fecha;hora;reactivaInductiva_kVArh;reactivaCapacitiva_kVArh;"
                    "metodoObtencion\n")
            for fecha, hora, r1, r4, met in filas_reactiva:
                f.write(f'"{c}";"{fecha}";"{hora}";{f3(r1)};{f3(r4)};{met}\n')


def generar(perfil: dict, carpeta: Path, req: int, semilla: int) -> dict:
    rnd = random.Random(semilla)
    clima = Clima(rnd)
    por_hora = 4 if perfil["cuartohorario"] else 1
    n_per = perfil["n_periodos"]
    fper = periodo_6p if n_per == 6 else periodo_20td
    viv = Vivienda(rnd) if perfil["tipo"] == "fv" else None
    ve = RecargaVE(rnd, **perfil["ve"]) if perfil.get("ve") else None
    kwp, inversor = perfil.get("kwp", 0.0), perfil.get("inversor", 4.0)
    estimados = {date(2025, 5, 13), date(2026, 2, 3)}       # días con lectura estimada

    filas, filas_r, maximos, react = [], [], {}, {}
    tot = {"consumo": 0.0, "vertida": 0.0, "generada": 0.0}
    for d in dias():
        cuartos = list(cuartos_del_dia(d))
        datos = []                                         # (cons, vert, gen, auto) por cuarto
        curva_r = []                                       # (R1, R4) kVArh por cuarto
        for t in cuartos:
            tl = t.astimezone(TZ)
            temp = clima.temp(tl)
            if perfil["tipo"] == "comercio":
                kw = carga_comercio(tl, temp, rnd)
            elif perfil["tipo"] == "industria":
                kw = carga_industria(tl, temp, rnd) * perfil.get("escala", 1)
            else:
                kw = viv.carga(tl, temp)
            if viv:
                poa = irradiancia_poa(t + Q / 2)
                derrateo = 1 - 0.004 * max(0, temp + poa / 40 - 25)
                pv = min(kwp * poa / 1000 * 0.86 * clima.nube[d] * derrateo, inversor) / 4
                if ve:
                    kw += ve.potencia(tl, max(0.0, pv * 4 - kw))
            carga = kw / 4
            if viv:
                auto_ = min(carga, pv)
                datos.append((carga - auto_, pv - auto_, pv, auto_))
            else:
                datos.append((carga, None, None, None))
            if perfil.get("reactiva"):
                r1, r4 = perfil["reactiva"](kw / perfil.get("escala", 1), carga, rnd)
                curva_r.append((r1, r4))
                rk = (d.year, d.month)
                react.setdefault(rk, [0.0] * 6)[fper(d, tl.hour) - 1] += r1
            # maxímetro (cuartohorario) y reactiva por periodo
            per = fper(d, tl.hour)
            mk = (d.year, d.month, per)
            if mk not in maximos or datos[-1][0] * 4 > maximos[mk][2]:
                fin = tl + Q
                maximos[mk] = (d, f"{fin.hour:02d}:{fin.minute:02d}", datos[-1][0] * 4)

        if por_hora == 1:                                  # agrega a horas
            datos = [_agrega_hora(datos[i:i + 4]) for i in range(0, len(datos), 4)]
            curva_r = [tuple(map(sum, zip(*curva_r[i:i + 4]))) for i in range(0, len(curva_r), 4)]
        etq = etiquetas(len(datos), por_hora)
        met = "Estimada" if d in estimados else "Real"
        for hora, (cons, vert, gen, auto_) in zip(etq, datos):
            filas.append((d.strftime("%Y/%m/%d"), hora, round(cons, 3), met, vert, gen, auto_))
            tot["consumo"] += cons
            tot["vertida"] += vert or 0
            tot["generada"] += gen or 0
        filas_r.extend((d.strftime("%Y/%m/%d"), hora, r1, r4, met)
                       for hora, (r1, r4) in zip(etq, curva_r))

    potencias = [(d.strftime("%Y/%m/%d"), hora, kw, per)
                 for (_, _, per), (d, hora, kw) in sorted(maximos.items())]
    reactiva = [(f"{y}/{m:02d}", vals) for (y, m), vals in sorted(react.items())]

    escribir(carpeta, req, perfil, filas, potencias, reactiva, filas_r)
    return tot


def _agrega_hora(cuartos: list[tuple]) -> tuple:
    return tuple(None if cuartos[0][k] is None else sum(c[k] for c in cuartos) for k in range(4))


# ------------------------------------------------------------------------ perfiles

def reactiva_comercio(kw, kwh, rnd):
    """(R1, R4) en kVArh. Frío y climatización sin compensar: cos φ 0,90-0,98."""
    cphi = min(0.99, 0.90 + 0.003 * kw + rnd.uniform(-0.02, 0.02))
    return kwh * math.tan(math.acos(cphi)), 0.0


def reactiva_industria(kw, kwh, rnd):
    """(R1, R4) en kVArh. Batería automática: buen cos φ en producción; en vacío
    queda algún escalón conectado y el suministro pasa a capacitivo."""
    if kw < 60:
        return kwh * rnd.uniform(0.02, 0.08), kwh * rnd.uniform(0.15, 0.35)
    cphi = min(0.995, 0.88 + 0.0004 * kw + rnd.uniform(-0.015, 0.015))
    return kwh * math.tan(math.acos(cphi)), 0.0


PERFILES = [
    ("sim_30td_hasta50kw", 990001, {
        "cups": cups(1), "tipo": "comercio", "cuartohorario": False, "n_periodos": 6,
        "tarifa": "BAJA TENSION y 15 kW < POTENCIA <= 50 kW (3.0TD)", "tension": "Baja tensión",
        "potencias": [35, 35, 35, 35, 35, 45], "control": "MAXIMETRO",
        "discriminacion": "TARIFA DE SEIS PERIODOS", "inicio": "2021/06/01",
        "provincia": "Granada", "municipio": "GUADIX", "cp": "18500",
        "pmax_instalacion": "43.65", "reactiva": reactiva_comercio,
    }),
    ("sim_61td_mas450kw", 990011, {
        "cups": cups(2), "tipo": "industria", "cuartohorario": True, "n_periodos": 6,
        "escala": 2.1,
        "tarifa": "ALTA TENSION 1 kV <= TENSION < 30 kV (6.1TD)", "tension": "Alta tensión",
        "potencias": [650, 650, 650, 650, 650, 800], "control": "MAXIMETRO",
        "discriminacion": "TARIFA DE SEIS PERIODOS", "inicio": "2021/06/01",
        "provincia": "Granada", "municipio": "GUADIX", "cp": "18500",
        "pmax_instalacion": "1000.0", "reactiva": reactiva_industria,
    }),
    ("sim_20td_fv_excedentes", 990021, {
        "cups": cups(3), "tipo": "fv", "cuartohorario": False, "n_periodos": 3, "kwp": 4.5,
        "tarifa": "BAJA TENSION y POTENCIA <= 15 kW", "tension": "Baja tensión",
        "potencias": [4.6, 4.6], "control": "ICP",
        "discriminacion": "TARIFA DE TRES PERIODOS", "inicio": "2023/04/12",
        "provincia": "Granada", "municipio": "GRANADA", "cp": "18008",
        "pmax_instalacion": "5.75",
        "autoconsumo": {"potencia": "4", "tipo": "41", "seccion": "b", "subseccion": "b1",
                        "coef": "1", "cau": f"{cups(3)[:20]}A000"},
    }),
]


def vivienda_fv_ve(n, kwp, inversor, potencias, cp, ve):
    """Vivienda 2.0TD con FV con excedentes y compensación y recarga de VE."""
    return {
        "cups": cups(n), "tipo": "fv", "cuartohorario": False, "n_periodos": 3,
        "kwp": kwp, "inversor": inversor, "ve": ve,
        "tarifa": "BAJA TENSION y POTENCIA <= 15 kW", "tension": "Baja tensión",
        "potencias": potencias, "control": "ICP",
        "discriminacion": "TARIFA DE TRES PERIODOS", "inicio": "2024/03/01",
        "provincia": "Granada", "municipio": "GRANADA", "cp": cp,
        "pmax_instalacion": f"{max(potencias) * 1.25:.2f}",
        "autoconsumo": {"potencia": f"{inversor:g}", "tipo": "41", "seccion": "b", "subseccion": "b1",
                        "coef": "1", "cau": f"{cups(n)[:20]}A000"},
    }


PERFILES += [
    ("sim_20td_fv_ve_noche", 990031, vivienda_fv_ve(4, 5.0, 5.0, [6.9, 9.2], "18012",
                                                    {"modo": "noche", "kw": 7.4, "km_dia": 55})),
    ("sim_20td_fv_ve_solar", 990041, vivienda_fv_ve(5, 6.0, 5.5, [5.75, 5.75], "18014",
                                                    {"modo": "solar", "kw": 7.4, "km_dia": 35,
                                                     "teletrabajo": (0, 2, 4)})),
    ("sim_20td_fv_ve_tarde", 990051, vivienda_fv_ve(6, 3.5, 3.3, [5.75, 5.75], "18015",
                                                    {"modo": "tarde", "kw": 3.7, "km_dia": 45})),
]


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[1])
    ap.add_argument("--out", default=str(Path(__file__).resolve().parent.parent / "datadis"))
    ap.add_argument("--semilla", type=int, default=42)
    ap.add_argument("--solo", nargs="*", help="solo estas carpetas (por defecto, todas)")
    args = ap.parse_args()
    for i, (nombre, req, perfil) in enumerate(PERFILES):
        if args.solo and nombre not in args.solo:
            continue
        tot = generar(perfil, Path(args.out) / nombre, req, args.semilla + i)
        extra = (f", generada {tot['generada']:.0f} kWh, vertida {tot['vertida']:.0f} kWh"
                 if perfil["tipo"] == "fv" else "")
        print(f"✓ {nombre} {perfil['cups']}: consumo red {tot['consumo']:.0f} kWh{extra}")


if __name__ == "__main__":
    main()
