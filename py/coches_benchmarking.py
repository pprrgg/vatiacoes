import pandas as pd
import matplotlib.pyplot as plt
import numpy as np

# 1. Datos incrustados directamente en un diccionario (variable 'var')
var = {
    'Modelo (Versión Base EV)': [
        'Leapmotor T03', 'BYD Dolphin Surf Active', 'Citroën ë-C3', 
        'Geely E2 Pro', 'BYD Dolphin (Estándar Base)', 'Geely Galaxy E5 (Base)', 
        'BYD Atto 3 (Evo / Base)', 'Geely E5 PRO', 'BYD Seal (Comfort RWD)', 
        'BYD Sealion 7 (Base RWD)'
    ],
    'Potencia (kW)': [70, 65, 83, 85, 150, 150, 150, 160, 230, 230],
    'Potencia (CV)': [95, 88, 113, 116, 204, 204, 204, 218, 313, 313],
    'Batería Neta (kWh)': [37.3, 30.0, 44.0, 35.0, 60.4, 60.2, 60.4, 68.2, 82.5, 82.5],
    'Autonomía WLTP (km)': [265, 220, 320, '252 - 325', 427, 440, 420, 475, 570, '480 - 570'],
    'Precio Aprox. al Contado (€)': [17900, 18780, 19900, 20280, 27302, 32500, 32200, 37490, 41130, 42500]
}

# 2. Convertir el diccionario a un DataFrame de Pandas
df = pd.DataFrame(var)

# 3. Función para limpiar y promediar los rangos de autonomía
def clean_autonomy(val):
    if isinstance(val, str) and '-' in val:
        parts = val.split('-')
        return np.mean([float(p.strip()) for p in parts])
    try:
        return float(val)
    except:
        return np.nan

df['Autonomia_num'] = df['Autonomía WLTP (km)'].apply(clean_autonomy)

# 4. Definir colores manuales específicos y únicos para cada modelo
models = df['Modelo (Versión Base EV)'].unique()
colors_hex = [
    '#e41a1c', '#377eb8', '#4daf4a', '#984ea3', '#ff7f00',
    '#a65628', '#f781bf', '#999999', '#66c2a5', '#fc8d62'
]
model_color_map = dict(zip(models, colors_hex))

# 5. Configurar la figura en formato vertical (Gráfico arriba, Tabla abajo de 3 columnas)
fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(13, 12), gridspec_kw={'height_ratios': [2, 1.8]})

# 6. Generar el gráfico de dispersión (sin leyenda)
for model, color in model_color_map.items():
    subset = df[df['Modelo (Versión Base EV)'] == model]
    ax1.scatter(
        subset['Autonomia_num'], 
        subset['Precio Aprox. al Contado (€)'], 
        color=color, 
        s=150,               
        edgecolor='black',   
        linewidth=1.5,
        alpha=0.8
    )

# Estilos del gráfico superior
ax1.set_title('Precio vs Autonomía WLTP (Por Modelo)', fontsize=16, fontweight='bold')
ax1.set_xlabel('Autonomía WLTP (km)', fontsize=13)
ax1.set_ylabel('Precio Aprox. al Contado (€)', fontsize=13)
ax1.grid(True, linestyle='--', alpha=0.6)

# 7. Configurar la tabla inferior con 3 columnas (color aplicado al fondo del modelo)
ax2.axis('off')
ax2.axis('tight')

table_data = []
cell_colors = []
header_color = '#2C3E50'
header_text_color = 'white'

col_labels = ["Modelo (Versión Base EV)", "Autonomía WLTP (km)", "Precio Aprox. al Contado (€)"]

for _, row in df.iterrows():
    model_name = row['Modelo (Versión Base EV)']
    model_color = model_color_map[model_name]
    
    row_data = [
        model_name, 
        str(row['Autonomía WLTP (km)']), 
        f"{row['Precio Aprox. al Contado (€)']:,} €"
    ]
    table_data.append(row_data)
    
    # Fondo de la celda de modelo con su color asignado; el resto blanco
    row_colors = [model_color, 'white', 'white']
    cell_colors.append(row_colors)

table = ax2.table(
    cellText=table_data,
    colLabels=col_labels,
    loc='center',
    cellLoc='center',
    cellColours=cell_colors
)

table.auto_set_font_size(False)
table.set_fontsize(11)
table.scale(1, 1.6)

# Definir qué colores de fondo son oscuros para usar texto blanco
dark_bg = ['#e41a1c', '#377eb8', '#984ea3', '#a65628', '#999999']

for key, cell in table.get_celld().items():
    row_idx, col_idx = key
    if row_idx == 0:
        cell.set_facecolor(header_color)
        cell.set_text_props(color=header_text_color, weight='bold')
        cell.set_edgecolor('black')
    else:
        cell.set_edgecolor('black')
        if col_idx == 0:
            model_val = cell.get_text().get_text()
            bg_color = model_color_map.get(model_val, '#FFFFFF').lower()
            if bg_color in dark_bg:
                cell.set_text_props(color='white', weight='bold')
            else:
                cell.set_text_props(color='black', weight='bold')

plt.tight_layout()
plt.show()