# Datos Datadis

| Carpeta | CUPS | Origen | Tipo |
|---|---|---|---|
| `qw0f`, `sw0f`, `tb0f` | reales | Descarga web Datadis | 2.0TD ≤ 15 kW, horario |
| `sim_30td_hasta50kw` | ES0031999900000001LR0F | **SIMULADO** | 3.0TD BT 35/45 kW, contador tipo 4 (comercio): curva **horaria** + maxímetro + reactiva |
| `sim_61td_mas450kw` | ES0031999900000002LW0F | **SIMULADO** | 6.1TD AT 650/800 kW, contador tipo 2 (industria 2 turnos): curva **cuartohoraria** + maxímetro + reactiva |
| `sim_20td_fv_excedentes` | ES0031999900000003LA0F | **SIMULADO** | 2.0TD 4,6 kW + FV 4,5 kWp con excedentes y compensación (tipo 41), horario |
| `sim_20td_fv_ve_noche` | ES0031999900000004LG0F | **SIMULADO** | 2.0TD 6,9/9,2 kW + FV 5 kWp + VE: cargador 7,4 kW programado en valle (desde la 01:00), horario |
| `sim_20td_fv_ve_solar` | ES0031999900000005LM0F | **SIMULADO** | 2.0TD 5,75 kW + FV 6 kWp + VE: cargador inteligente con excedentes FV (1,4–7,4 kW) los días en casa; resto en valle a 3,7 kW |
| `sim_20td_fv_ve_tarde` | ES0031999900000006LY0F | **SIMULADO** | 2.0TD 5,75 kW + FV 3,5 kWp + VE: carga a 3,7 kW al llegar a casa (19:00, punta) |

Ficheros:

- `Consumo_*`: curva de carga activa (kWh). Datadis solo da cuartohoraria a contadores tipo 1 y 2.
- `Potencias_*`: maxímetro mensual por periodo (kW, máximo cuartohorario), como Datadis.
- `Contrato_*`: datos contractuales.
- `Energia_*`: reactiva inductiva mensual por periodo (kVArh), como Datadis.
- `Reactiva_*` (solo `sim_*`): curva de reactiva del contador, inductiva R1 y capacitiva R4 (kVArh),
  con la misma resolución que el consumo. **Datadis no la publica**; la da la distribuidora.
  La suma mensual de R1 por periodo coincide con `Energia_*`.

Las carpetas `sim_*` se generan con `python py/datadis_sintetico.py` (semilla fija, reproducible),
con el formato de las descargas reales: `;`, decimales con coma, horas 01:00–24:00
(00:15–24:00 en cuartohorario) y el cambio de hora como Datadis (falta o se repite la hora 03:00).

Las tres `sim_20td_fv_ve_*` son los socios de la comunidad Demo2 (SOCIOS2 en `sh-local/iot-thingsboard.sh`);
se generan solas con `python py/datadis_sintetico.py --solo sim_20td_fv_ve_noche sim_20td_fv_ve_solar sim_20td_fv_ve_tarde`.
