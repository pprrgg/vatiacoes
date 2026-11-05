#!/usr/bin/env python3
"""Pasa los documentos del blog (public/docs/**/*.html) al tema claro de la web
(src/styles/sitio.css): fondo blanco, texto azul marino, un azul de accion (#2457e6) y el
amarillo del sol solo para resaltar.

Los documentos estan hechos sobre unas pocas plantillas oscuras (la de «ingenieria»: fondo
#0A121C, cian #37CFFF, ambar #FFB020...; la de la portada personal y la del inventario). Cada
color de esas plantillas tiene aqui su equivalente claro y se sustituye en todo el documento:
las variables de :root, el CSS y el JavaScript de las graficas (que dibujan con colores fijos).
No se tocan las imagenes embebidas (data:...) ni los neutros (#000, #fff) de las librerias.

Se puede ejecutar otra vez sin riesgo: los colores ya claros no estan en la tabla. Los
documentos nuevos hechos con las plantillas oscuras se convierten igual.

    python3 scripts/docs-tema-claro.py            # aplica los cambios
    python3 scripts/docs-tema-claro.py --prueba   # solo cuenta lo que cambiaria
"""
import re
import sys
from pathlib import Path

DOCS = Path(__file__).resolve().parent.parent / "public" / "docs"

# Plantilla oscura de «ingenieria» (casi todos los documentos)
HEX = {
    # fondos y paneles
    "#0a121c": "#ffffff", "#070d15": "#f4f6f9", "#111e2e": "#ffffff", "#0e1826": "#f6f8fb",
    # lineas
    "#213348": "#dfe4eb", "#182739": "#eceff4",
    # texto: principal, secundario y terciario (en claro, el secundario es mas oscuro)
    "#e7ecf2": "#1c2735", "#8fa3b8": "#4f5b6d", "#5b7086": "#7b8696",
    # acento cian -> azul de la web
    "#37cfff": "#2457e6", "#7fe1ff": "#1b47c4", "#1b6e86": "#a9bdf3", "#22d3ee": "#2457e6",
    # ambar (el sol), verde, rojo y violeta, legibles sobre blanco
    "#ffb020": "#c27c00", "#ffc352": "#a86a00", "#8a6220": "#ecd08f",
    "#57d9a3": "#16894f", "#1e6e52": "#b5dcc6", "#ff6b6b": "#c62828",
    "#b98cff": "#7c4dcc", "#a78bfa": "#7c4dcc",
    # portada personal (index/index.html)
    "#0a0f1a": "#ffffff", "#e8ecf1": "#1c2735", "#8fa1b3": "#4f5b6d", "#5c6c7d": "#7b8696",
    "#cf8f4f": "#2457e6", "#e6ad70": "#1b47c4", "#5fd68a": "#16894f", "#e2574c": "#c62828",
    # inventario (ERP/A03_Inventario.html), verde oscuro
    "#0d2419": "#ffffff", "#123320": "#ffffff", "#17402a": "#f4f6f9", "#2a5c3f": "#dfe4eb",
    "#eef2e6": "#1c2735", "#8fac9c": "#5a6576", "#e8b04b": "#c27c00", "#c97c4b": "#2457e6",
    "#8a5535": "#a9bdf3", "#d16456": "#c62828",
    # generador de documentos de la comunidad (ya era claro; verde -> azul de la web)
    "#0d6a5b": "#2457e6", "#dcefe9": "#edf2fe", "#e9eeec": "#f4f6f9", "#cfd9d6": "#dfe4eb",
    "#17232a": "#0b1f3a", "#586870": "#5a6576",
}
# rgb(a) con transparencia: mismo alfa, color equivalente
RGB = {
    (55, 207, 255): (36, 87, 230),     # cian
    (34, 211, 238): (36, 87, 230),
    (127, 225, 255): (27, 71, 196),
    (255, 176, 32): (194, 124, 0),     # ambar
    (87, 217, 163): (22, 137, 79),     # verde
    (255, 107, 107): (198, 40, 40),    # rojo
    (10, 18, 28): (255, 255, 255),     # fondo (cabeceras translucidas, degradados)
    (7, 13, 21): (244, 246, 249),
    (17, 30, 46): (255, 255, 255),
    (231, 236, 242): (11, 31, 58),     # texto claro usado como linea o velo
    (232, 236, 241): (11, 31, 58),
    (10, 15, 26): (255, 255, 255),     # portada personal
    (17, 26, 41): (255, 255, 255),
    (22, 32, 47): (244, 246, 249),
    (207, 143, 79): (36, 87, 230),
    (13, 36, 25): (255, 255, 255),     # inventario
}
# sombras negras fuertes del tema oscuro -> sombras suaves azuladas
SOMBRAS = [(re.compile(r"rgba\(\s*0\s*,\s*0\s*,\s*0\s*,\s*(0?\.\d+)\s*\)"), lambda a: f"rgba(11,31,58,{min(float(a), 0.12):.2f})")]
# tipografia y esquinas, como en la web
TEXTO = [
    ("'Space Grotesk'", "'Inter'"),
    ("\"Space Grotesk\"", "\"Inter\""),
    ("--radius:2px", "--radius:8px"),
    ("--radius: 2px", "--radius: 8px"),
]

HEX_RE = re.compile(r"#[0-9a-fA-F]{6}\b")
RGB_RE = re.compile(r"rgba?\(\s*(\d{1,3})\s*,\s*(\d{1,3})\s*,\s*(\d{1,3})\s*(,\s*[\d.]+\s*)?\)")
DATA_RE = re.compile(r"data:[\w/+.-]+;base64,[A-Za-z0-9+/=]+")   # imagenes y fuentes embebidas


def convertir(t):
    n = 0

    def hx(m):
        nonlocal n
        nuevo = HEX.get(m.group(0).lower())
        if nuevo:
            n += 1
            return nuevo
        return m.group(0)

    def rg(m):
        nonlocal n
        nuevo = RGB.get(tuple(int(x) for x in m.group(1, 2, 3)))
        if not nuevo:
            return m.group(0)
        n += 1
        alfa = m.group(4)
        return f"rgba({nuevo[0]},{nuevo[1]},{nuevo[2]}{alfa.replace(' ', '')})" if alfa else f"rgb({nuevo[0]},{nuevo[1]},{nuevo[2]})"

    def sombra(m):
        nonlocal n
        n += 1
        return SOMBRAS[0][1](m.group(1))

    t = HEX_RE.sub(hx, t)
    t = RGB_RE.sub(rg, t)
    t = SOMBRAS[0][0].sub(sombra, t)
    for a, b in TEXTO:
        n += t.count(a)
        t = t.replace(a, b)
    return t, n


def procesar(f, prueba):
    t = f.read_text(encoding="utf-8")
    # se convierte todo menos los trozos data:...;base64 (se dejan tal cual)
    partes, total, ultimo = [], 0, 0
    for m in DATA_RE.finditer(t):
        trozo, n = convertir(t[ultimo:m.start()])
        partes += [trozo, m.group(0)]
        total += n
        ultimo = m.end()
    trozo, n = convertir(t[ultimo:])
    partes.append(trozo)
    total += n
    # color-scheme: dark -> light (sin tocar las consultas «prefers-color-scheme: dark»)
    nuevo = re.sub(r"(?<!prefers-)color-scheme:(\s*)dark", r"color-scheme:\1light", "".join(partes))
    if nuevo != t and not prueba:
        f.write_text(nuevo, encoding="utf-8")
    return total


def main():
    prueba = "--prueba" in sys.argv
    suma = 0
    for f in sorted(DOCS.rglob("*.html")):
        n = procesar(f, prueba)
        suma += n
        print(f"{n:5}  {f.relative_to(DOCS)}")
    print(f"{suma} cambios{' (prueba: no se ha escrito nada)' if prueba else ''}")


if __name__ == "__main__":
    main()
