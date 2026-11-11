/* VatiaCo · Informes técnicos en Typst, compilados en el servidor (FastAPI: /typst/compilar).
 *
 * Todas las herramientas de /docs generan su informe con esta librería: la página escribe el
 * contenido y aquí se compone el documento Typst completo con la estructura de un informe
 * técnico según UNE 50135 / ISO 5966 (presentación de informes científicos y técnicos):
 *
 *   portada con los datos del proyecto (campos p_* de la página), hoja de control del
 *   documento, resumen y palabras clave, índices (general, figuras y tablas), cuerpo numerado
 *   (objeto y alcance, referencias normativas, términos y definiciones, metodología, datos de
 *   entrada, resultados, conclusiones y recomendaciones), bibliografía (ISO 690) y anexos.
 *
 * Las páginas que ya tenían su informe en jsPDF siguen llamando a sus mismas funciones
 * (sectionTitle, paragraph, kv, simpleTable, drawXxx...): `compat()` las redirige aquí y
 * `Lienzo` imita la parte de jsPDF que usan sus dibujos y los convierte en figuras SVG
 * vectoriales. Los apartados se reordenan según la estructura normalizada por su título.
 *
 * Uso (página con renderBody de jsPDF):
 *   VatiacoInforme.generar({ cuerpo: renderBody, glosario: GLOSARIO, titulo, tipo, archivo });
 *   ... y dentro de renderBody: const H = VatiacoInforme.compat(doc, makeHelpers(doc));
 */
(function(){
'use strict';

const API = 'https://vatiaco.duckdns.org/cec-api/typst/compilar';
const MESES = ['enero','febrero','marzo','abril','mayo','junio','julio','agosto','septiembre','octubre','noviembre','diciembre'];

// ===================== Texto Typst, números y fechas =====================
// Texto como cadena de Typst: se imprime tal cual (#, $, *, _, @... sin marcado)
function tq(v){
  return '"'+String(v==null ? '' : v).replace(/[\x00-\x08\x0b-\x1f\x7f]/g,'')
    .replace(/\\/g,'\\\\').replace(/"/g,'\\"').replace(/\r?\n/g,'\\n').replace(/\t/g,' ')+'"';
}
function tm(v){ return '#('+tq(v)+')'; }
// Valor de JavaScript -> literal de Typst
function ty(v){
  if(v===null || v===undefined) return 'none';
  if(typeof v==='boolean') return v ? 'true' : 'false';
  if(typeof v==='number') return isFinite(v) ? String(v) : 'none';
  if(typeof v==='string') return tq(v);
  if(Array.isArray(v)) return v.length ? '('+v.map(ty).join(', ')+(v.length===1 ? ',' : '')+')' : '()';
  const k = Object.keys(v);
  return k.length ? '('+k.map(x=>x+': '+ty(v[x])).join(', ')+')' : '(:)';
}
function nES(v, d=2){
  if(v===null || v===undefined || !isFinite(v)) return '–';
  const s = Math.abs(v).toFixed(d), p = s.split('.');
  return ((v<0 && Number(s)!==0) ? '−' : '')+p[0].replace(/\B(?=(\d{3})+(?!\d))/g,'.')+(p[1] ? ','+p[1] : '');
}
function fechaLarga(iso){
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(iso||'');
  return m ? (+m[3])+' de '+MESES[+m[2]-1]+' de '+m[1] : '—';
}
const sinTildes = s => String(s||'').normalize('NFD').replace(/[̀-ͯ]/g,'').toLowerCase();
const vacio = v => (v!==undefined && v!==null && String(v).trim() && String(v).trim()!=='-') ? String(v).trim() : '—';

// ===================== Tildes =====================
// Los informes de jsPDF se escribían sin tildes (sus fuentes no las tenían). Typst sí las
// tiene: las palabras de este diccionario (formas sin tilde que aparecen en los informes de
// la web, sin ambigüedad) se corrigen en títulos, párrafos, tablas y leyendas, nunca en las
// fórmulas. El diccionario lo amplía VatiacoInforme.TILDES.
const TILDES = {"aceptacion":"aceptación","acido":"ácido","acrilico":"acrílico","actua":"actúa","actuacion":"actuación","actualizacion":"actualización","ademas":"además","adquisicion":"adquisición","aeronautica":"aeronáutica","agricolas":"agrícolas","agrupacion":"agrupación","algun":"algún","alimentacion":"alimentación","alla":"allá","ambito":"ámbito","amortizacion":"amortización","analisis":"análisis","angulo":"ángulo","anio":"año","anios":"años","ano":"año","anos":"años","aplicacion":"aplicación","aportacion":"aportación","aproximacion":"aproximación","aqui":"aquí","area":"área","arquitectonica":"arquitectónica","articulo":"artículo","articulos":"artículos","asi":"así","asociacion":"asociación","atencion":"atención","auditoria":"auditoría","autarquia":"autarquía","automatica":"automática","automaticamente":"automáticamente","autonoma":"autónoma","autonomia":"autonomía","autorizacion":"autorización","basico":"básico","bateria":"batería","baterias":"baterías","boletin":"boletín","busqueda":"búsqueda","caida":"caída","calculo":"cálculo","calefaccion":"calefacción","calorifico":"calorífico","capitulo":"capítulo","caracter":"carácter","caracteristicas":"características","catalogo":"catálogo","categorias":"categorías","circulacion":"circulación","clasificacion":"clasificación","climatica":"climática","climaticas":"climáticas","climaticos":"climáticos","climatizacion":"climatización","codigo":"código","combinacion":"combinación","combustion":"combustión","comision":"comisión","compensacion":"compensación","comprobacion":"comprobación","comunicacion":"comunicación","conclusion":"conclusión","condicion":"condición","conduccion":"conducción","conexion":"conexión","configuracion":"configuración","constitucion":"constitución","construccion":"construcción","correccion":"corrección","criticos":"críticos","decision":"decisión","declaracion":"declaración","deficit":"déficit","definicion":"definición","degradacion":"degradación","demas":"demás","democratica":"democrática","democratico":"democrático","deposito":"depósito","derivacion":"derivación","descripcion":"descripción","despues":"después","dia":"día","diagnostico":"diagnóstico","dias":"días","diesel":"diésel","difusion":"difusión","dinamicamente":"dinámicamente","dinamico":"dinámico","dinamizacion":"dinamización","direccion":"dirección","diseno":"diseño","distribucion":"distribución","diversificacion":"diversificación","documentacion":"documentación","domesticas":"domésticas","dotacion":"dotación","duracion":"duración","ecologico":"ecológico","economica":"económica","economicamente":"económicamente","economicas":"económicas","economico":"económico","economicos":"económicos","edicion":"edición","edificacion":"edificación","ejecucion":"ejecución","eleccion":"elección","electrica":"eléctrica","electricas":"eléctricas","electrico":"eléctrico","electricos":"eléctricos","electrotecnico":"electrotécnico","emision":"emisión","energetica":"energética","energeticas":"energéticas","energetico":"energético","energia":"energía","energias":"energías","energizacion":"energización","eolico":"eólico","epoca":"época","espana":"españa","espanol":"español","espanola":"española","especificacion":"especificación","especifico":"específico","especificos":"específicos","estacion":"estación","estan":"están","estandar":"estándar","estatico":"estático","esten":"estén","estimacion":"estimación","evalua":"evalúa","evaluacion":"evaluación","evolucion":"evolución","exito":"éxito","explicitamente":"explícitamente","explotacion":"explotación","exportacion":"exportación","facturacion":"facturación","financiacion":"financiación","fisica":"física","formacion":"formación","formula":"fórmula","formulas":"fórmulas","fotografico":"fotográfico","fraccion":"fracción","friccion":"fricción","frigorificas":"frigoríficas","frigorifico":"frigorífico","funcion":"función","fundacion":"fundación","fusion":"fusión","garantia":"garantía","garantias":"garantías","gasoleo":"gasóleo","generacion":"generación","generico":"genérico","geograficas":"geográficas","gestion":"gestión","guia":"guía","guias":"guías","hibridacion":"hibridación","hibrido":"híbrido","hibridos":"híbridos","hidraulica":"hidráulica","hidraulico":"hidráulico","hipotesis":"hipótesis","historico":"histórico","homologacion":"homologación","hosteleria":"hostelería","implantacion":"implantación","importacion":"importación","inclinacion":"inclinación","incorporacion":"incorporación","indice":"índice","inflacion":"inflación","informacion":"información","inscripcion":"inscripción","inspeccion":"inspección","instalacion":"instalación","instantaneo":"instantáneo","interes":"interés","introduccion":"introducción","inversion":"inversión","inyeccion":"inyección","irradiacion":"irradiación","isotonica":"isotónica","iteracion":"iteración","juridica":"jurídica","juridicas":"jurídicas","juridico":"jurídico","kilometros":"kilómetros","legalizacion":"legalización","limite":"límite","limites":"límites","linea":"línea","lineas":"líneas","logistica":"logística","mas":"más","masico":"másico","matricula":"matrícula","matriculacion":"matriculación","maxima":"máxima","maximetro":"maxímetro","maximo":"máximo","mayoria":"mayoría","mecanico":"mecánico","medicion":"medición","menu":"menú","metalica":"metálica","meteorologia":"meteorología","metodo":"método","metodologia":"metodología","metodologias":"metodologías","metodos":"métodos","minima":"mínima","minimas":"mínimas","minimo":"mínimo","minimos":"mínimos","modificacion":"modificación","modulos":"módulos","monitorizacion":"monitorización","monotono":"monótono","motorizacion":"motorización","numero":"número","obligacion":"obligación","obtencion":"obtención","opcion":"opción","operacion":"operación","optima":"óptima","optimas":"óptimas","optimizacion":"optimización","optimo":"óptimo","organizacion":"organización","orientacion":"orientación","parametro":"parámetro","parametros":"parámetros","participacion":"participación","pequeno":"pequeño","perdidas":"pérdidas","periodica":"periódica","poliester":"poliéster","ponderacion":"ponderación","presentacion":"presentación","presion":"presión","prestamo":"préstamo","prevision":"previsión","produccion":"producción","proteccion":"protección","publicas":"públicas","raiz":"raíz","rapida":"rápida","rapido":"rápido","recomendacion":"recomendación","recuperacion":"recuperación","reduccion":"reducción","refrigeracion":"refrigeración","regimen":"régimen","reglamentacion":"reglamentación","regresion":"regresión","regulacion":"regulación","rehabilitacion":"rehabilitación","resolucion":"resolución","revision":"revisión","seccion":"sección","segun":"según","simbolos":"símbolos","simulacion":"simulación","situacion":"situación","sobretension":"sobretensión","sustitucion":"sustitución","tambien":"también","tecnica":"técnica","tecnicamente":"técnicamente","tecnicas":"técnicas","tecnico":"técnico","tecnicos":"técnicos","tecnologia":"tecnología","tension":"tensión","teorico":"teórico","teoricos":"teóricos","termica":"térmica","termicamente":"térmicamente","termicas":"térmicas","termico":"térmico","termicos":"térmicos","termino":"término","terminos":"términos","tipicamente":"típicamente","tipico":"típico","tipicos":"típicos","tramitacion":"tramitación","tramite":"trámite","tramites":"trámites","transformacion":"transformación","transicion":"transición","transposicion":"transposición","triangulo":"triángulo","trifasico":"trifásico","ubicacion":"ubicación","ultima":"última","ultimas":"últimas","ultimo":"último","unico":"único","urbanistica":"urbanística","util":"útil","vacio":"vacío","valido":"válido","variacion":"variación","vehiculo":"vehículo","vehiculos":"vehículos","verificacion":"verificación","version":"versión","via":"vía","volumetria":"volumetría"};
function acentuar(s){
  if(typeof s!=='string' || !s) return s;
  return s.replace(/[A-Za-z]+/g, w=>{
    const t = TILDES[w.toLowerCase()];
    if(!t) return w;
    if(w===w.toUpperCase() && w.length>1) return t.toUpperCase();
    if(w[0]===w[0].toUpperCase()) return t[0].toUpperCase()+t.slice(1);
    return t;
  });
}

// ===================== Lienzo: jsPDF -> SVG =====================
// Imita la parte de jsPDF que usan los dibujos de las páginas (mm, A4) y guarda cada
// elemento en SVG con su página; las figuras se cortan entre llamadas a los helpers.
const PT_MM = 25.4/72;
const FUENTES = {
  helvetica: { svg:'Roboto, DejaVu Sans, sans-serif', canvas:'Helvetica, Arial, sans-serif' },
  times:     { svg:'Libertinus Serif, DejaVu Serif, serif', canvas:'"Times New Roman", Times, serif' },
  courier:   { svg:'DejaVu Sans Mono, monospace', canvas:'"Courier New", Courier, monospace' },
};
let ctxMedida = null;
function medir(texto, fuente, estilo, sizePt){
  if(!ctxMedida){ try{ ctxMedida = document.createElement('canvas').getContext('2d'); }catch(e){} }
  const f = FUENTES[fuente] || FUENTES.helvetica;
  if(!ctxMedida) return String(texto).length*sizePt*0.5*PT_MM;
  ctxMedida.font = (/italic/.test(estilo) ? 'italic ' : '')+(/bold/.test(estilo) ? 'bold ' : '')+'100px '+f.canvas;
  return ctxMedida.measureText(String(texto)).width/100*sizePt*PT_MM;
}
function xml(s){ return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;'); }
function color(a){
  const args = Array.prototype.slice.call(a);
  if(typeof args[0]==='string'){
    const s = args[0].trim();
    if(/^#[0-9a-f]{3,8}$/i.test(s) || /^[a-z]+$/i.test(s)) return s;
    return '#000';
  }
  if(args.length>=3) return 'rgb('+args.slice(0,3).map(v=>Math.round(Math.max(0,Math.min(255,+v||0)))).join(',')+')';
  const g = Math.round(Math.max(0,Math.min(255,+args[0]||0)));
  return 'rgb('+g+','+g+','+g+')';
}
const f2 = v => (Math.round((+v||0)*100)/100).toString();

class Lienzo {
  constructor(){
    this.pagina = 0; this.paginas = 1; this.elementos = []; this.marca = 0;
    this.fuente = 'helvetica'; this.estilo = 'normal'; this.size = 16;
    this.cTexto = 'rgb(0,0,0)'; this.cTrazo = 'rgb(0,0,0)'; this.cRelleno = 'rgb(0,0,0)';
    this.grosor = 0.2; this.trazos = null; this.interlineado = 1.15;
    const self = this;
    this.internal = {
      getNumberOfPages: ()=>self.paginas,
      pageSize: { width:210, height:297, getWidth:()=>210, getHeight:()=>297 },
      scaleFactor: 72/25.4,
      getCurrentPageInfo: ()=>({ pageNumber: self.pagina+1 }),
    };
  }
  _poner(svg, x0, y0, x1, y1){
    this.elementos.push({ p:this.pagina, svg, x0:Math.min(x0,x1), y0:Math.min(y0,y1), x1:Math.max(x0,x1), y1:Math.max(y0,y1) });
  }
  _estiloTrazo(){
    return ' stroke="'+this.cTrazo+'" stroke-width="'+f2(this.grosor)+'"'+(this.trazos ? ' stroke-dasharray="'+this.trazos.map(f2).join(' ')+'"' : '');
  }
  _pintura(estilo){
    const e = String(estilo||'S').toUpperCase();
    const relleno = /F/.test(e) ? ' fill="'+this.cRelleno+'"' : ' fill="none"';
    const trazo = (/D|S/.test(e) || e==='') ? this._estiloTrazo() : ' stroke="none"';
    return relleno+trazo;
  }
  // --- estado ---
  setFont(n, s){ this.fuente = String(n||'helvetica').toLowerCase(); if(!FUENTES[this.fuente]) this.fuente = 'helvetica'; this.estilo = String(s||'normal').toLowerCase(); return this; }
  getFont(){ return { fontName:this.fuente, fontStyle:this.estilo }; }
  setFontStyle(s){ this.estilo = String(s||'normal').toLowerCase(); return this; }
  setFontSize(n){ this.size = +n||10; return this; }
  getFontSize(){ return this.size; }
  setTextColor(){ this.cTexto = color(arguments); return this; }
  setDrawColor(){ this.cTrazo = color(arguments); return this; }
  setFillColor(){ this.cRelleno = color(arguments); return this; }
  setLineWidth(w){ this.grosor = +w||0.2; return this; }
  setLineDashPattern(a){ this.trazos = (Array.isArray(a) && a.length) ? a : null; return this; }
  setLineHeightFactor(f){ this.interlineado = +f||1.15; return this; }
  getLineHeightFactor(){ return this.interlineado; }
  setLineCap(){ return this; } setLineJoin(){ return this; } setGState(){ return this; }
  addFont(){ return this; } setProperties(){ return this; } setDocumentProperties(){ return this; }
  addPage(){ this.paginas++; this.pagina = this.paginas-1; return this; }
  setPage(n){ this.pagina = Math.max(0, Math.min(this.paginas-1, (+n||1)-1)); return this; }
  getNumberOfPages(){ return this.paginas; }
  save(){ return this; } output(){ return ''; } autoPrint(){ return this; }
  // --- medida de texto ---
  getTextWidth(t){ return medir(t, this.fuente, this.estilo, this.size); }
  getStringUnitWidth(t){ return medir(t, this.fuente, this.estilo, 1)/PT_MM; }
  getTextDimensions(t){ return { w: this.getTextWidth(t), h: this.size*PT_MM }; }
  splitTextToSize(texto, ancho){
    const out = [];
    String(texto==null ? '' : texto).split(/\r?\n/).forEach(par=>{
      const palabras = par.split(/ +/);
      let linea = '';
      palabras.forEach(w=>{
        const prueba = linea ? linea+' '+w : w;
        if(linea && this.getTextWidth(prueba) > ancho){ out.push(linea); linea = w; }
        else linea = prueba;
      });
      out.push(linea);
    });
    return out;
  }
  // --- dibujo ---
  text(texto, x, y, opts, extra){
    if(typeof opts!=='object' || opts===null) opts = (typeof extra==='object' && extra) ? extra : {};
    let lineas = Array.isArray(texto) ? texto.map(String) : String(texto==null ? '' : texto).split(/\r?\n/);
    if(opts.maxWidth) lineas = [].concat(...lineas.map(l=>this.splitTextToSize(l, opts.maxWidth)));
    const h = this.size*PT_MM, paso = h*this.interlineado;
    const anclaje = opts.align==='center' ? 'middle' : (opts.align==='right' ? 'end' : 'start');
    let dy = 0;
    if(opts.baseline==='middle') dy = h*0.35; else if(opts.baseline==='top' || opts.baseline==='hanging') dy = h*0.75; else if(opts.baseline==='bottom') dy = -h*0.2;
    const f = FUENTES[this.fuente] || FUENTES.helvetica;
    const peso = /bold/.test(this.estilo) ? ' font-weight="bold"' : '';
    const cursiva = /italic|oblique/.test(this.estilo) ? ' font-style="italic"' : '';
    const giro = opts.angle ? ' transform="rotate('+f2(-opts.angle)+' '+f2(x)+' '+f2(y)+')"' : '';
    lineas.forEach((l, i)=>{
      if(l==='') return;
      l = acentuar(l);
      const yy = y+dy+i*paso, w = this.getTextWidth(l);
      const x0 = anclaje==='middle' ? x-w/2 : (anclaje==='end' ? x-w : x);
      this._poner('<text x="'+f2(x)+'" y="'+f2(yy)+'" font-family="'+f.svg+'" font-size="'+f2(h)+'" fill="'+this.cTexto+'" text-anchor="'+anclaje+'"'+peso+cursiva+giro+'>'+xml(l)+'</text>',
        opts.angle ? x-w : x0-w*0.06, yy-h*0.8, opts.angle ? x+w : x0+w*1.12, yy+h*0.25);
    });
    return this;
  }
  line(x1, y1, x2, y2){
    this._poner('<line x1="'+f2(x1)+'" y1="'+f2(y1)+'" x2="'+f2(x2)+'" y2="'+f2(y2)+'"'+this._estiloTrazo()+'/>', x1-this.grosor/2, y1-this.grosor/2, x2+this.grosor/2, y2+this.grosor/2);
    return this;
  }
  lines(segs, x, y, escala, estilo, cerrado){
    let cx = x, cy = y, d = 'M'+f2(x)+','+f2(y), xs = [x], ys = [y];
    (segs||[]).forEach(s=>{
      if(s.length===2){ cx += s[0]; cy += s[1]; d += ' L'+f2(cx)+','+f2(cy); }
      else if(s.length===6){ d += ' C'+f2(cx+s[0])+','+f2(cy+s[1])+' '+f2(cx+s[2])+','+f2(cy+s[3])+' '+f2(cx+s[4])+','+f2(cy+s[5]); cx += s[4]; cy += s[5]; }
      xs.push(cx); ys.push(cy);
    });
    if(cerrado) d += ' Z';
    this._poner('<path d="'+d+'"'+this._pintura(estilo)+'/>', Math.min(...xs), Math.min(...ys), Math.max(...xs), Math.max(...ys));
    return this;
  }
  rect(x, y, w, h, estilo){
    this._poner('<rect x="'+f2(Math.min(x,x+w))+'" y="'+f2(Math.min(y,y+h))+'" width="'+f2(Math.abs(w))+'" height="'+f2(Math.abs(h))+'"'+this._pintura(estilo)+'/>', x, y, x+w, y+h);
    return this;
  }
  roundedRect(x, y, w, h, rx, ry, estilo){
    this._poner('<rect x="'+f2(Math.min(x,x+w))+'" y="'+f2(Math.min(y,y+h))+'" width="'+f2(Math.abs(w))+'" height="'+f2(Math.abs(h))+'" rx="'+f2(rx)+'" ry="'+f2(ry)+'"'+this._pintura(estilo)+'/>', x, y, x+w, y+h);
    return this;
  }
  circle(x, y, r, estilo){
    this._poner('<circle cx="'+f2(x)+'" cy="'+f2(y)+'" r="'+f2(r)+'"'+this._pintura(estilo)+'/>', x-r, y-r, x+r, y+r);
    return this;
  }
  ellipse(x, y, rx, ry, estilo){
    this._poner('<ellipse cx="'+f2(x)+'" cy="'+f2(y)+'" rx="'+f2(rx)+'" ry="'+f2(ry)+'"'+this._pintura(estilo)+'/>', x-rx, y-ry, x+rx, y+ry);
    return this;
  }
  triangle(x1, y1, x2, y2, x3, y3, estilo){
    this._poner('<polygon points="'+[x1,y1,x2,y2,x3,y3].map(f2).join(' ').replace(/(\S+) (\S+)( |$)/g,'$1,$2$3')+'"'+this._pintura(estilo)+'/>',
      Math.min(x1,x2,x3), Math.min(y1,y2,y3), Math.max(x1,x2,x3), Math.max(y1,y2,y3));
    return this;
  }
  addImage(img, formato, x, y, w, h){
    let src = img;
    if(img && typeof img==='object'){
      if(img.toDataURL) src = img.toDataURL('image/png');
      else if(img.src) src = img.src;
    }
    if(typeof src==='string' && src.startsWith('data:image/'))
      this._poner('<image x="'+f2(x)+'" y="'+f2(y)+'" width="'+f2(w)+'" height="'+f2(h)+'" preserveAspectRatio="none" href="'+src+'"/>', x, y, x+w, y+h);
    return this;
  }
  // Elementos dibujados desde la última marca -> SVG (o null), uniendo las páginas sin huecos
  cortar(){
    const els = this.elementos.slice(this.marca);
    this.marca = this.elementos.length;
    if(!els.length) return null;
    const paginas = [...new Set(els.map(e=>e.p))].sort((a,b)=>a-b);
    const x0 = Math.min(...els.map(e=>e.x0))-1, x1 = Math.max(...els.map(e=>e.x1))+1;
    let alto = 0;
    const grupos = paginas.map(p=>{
      const de = els.filter(e=>e.p===p);
      const y0 = Math.min(...de.map(e=>e.y0)), y1 = Math.max(...de.map(e=>e.y1));
      const dy = alto-y0+1;
      alto += (y1-y0)+2;
      return '<g transform="translate('+f2(-x0)+' '+f2(dy)+')">'+de.map(e=>e.svg).join('')+'</g>';
    });
    const ancho = x1-x0;
    if(ancho<=0.5 || alto<=0.5) return null;
    return { ancho, alto,
      svg: '<svg xmlns="http://www.w3.org/2000/svg" width="'+f2(ancho)+'mm" height="'+f2(alto)+'mm" viewBox="0 0 '+f2(ancho)+' '+f2(alto)+'">'+grupos.join('')+'</svg>' };
  }
}

// ===================== Gráficos sencillos en SVG =====================
// g: { tipo:'linea'|'barras', valores:[...], max, color:[r,g,b], ticks:[{v,t}], ejeX:[{i,t}], etiquetas:[...] }
// -> { svg, ancho, alto } en mm, para Contenido.dibujo()
function grafico(g, alto){
  alto = alto || 50;
  const ancho = 165, izq = 17, der = 4, sup = 4, inf = 8;
  const valores = (g.valores||[]).map(v=>isFinite(v) ? +v : 0), n = valores.length;
  const max = g.max || Math.max(1, ...valores);
  const linea = g.tipo==='linea', util = alto-sup-inf, base = alto-inf;
  const paso = (ancho-izq-der)/(linea ? Math.max(n-1,1) : Math.max(n,1)), centro = linea ? 0 : paso/2;
  const y = v => base-util*(v/max);
  const col = Array.isArray(g.color) ? 'rgb('+g.color.join(',')+')' : (g.color || '#2a78d6');
  const txt = (x, yy, s, size, anchor, color) => '<text x="'+f2(x)+'" y="'+f2(yy)+'" font-family="Roboto, DejaVu Sans, sans-serif" font-size="'+f2(size)+'" fill="'+(color||'#8a8f99')+'" text-anchor="'+(anchor||'middle')+'">'+xml(acentuar(String(s)))+'</text>';
  const out = ['<rect x="0.1" y="0.1" width="'+f2(ancho-0.2)+'" height="'+f2(alto-0.2)+'" fill="none" stroke="rgb(215,215,220)" stroke-width="0.2"/>'];
  (g.ticks||[]).forEach(tk=>{
    out.push('<line x1="'+izq+'" x2="'+f2(ancho-der)+'" y1="'+f2(y(tk.v))+'" y2="'+f2(y(tk.v))+'" stroke="rgb(225,225,230)" stroke-width="0.12"/>');
    out.push(txt(izq-2, y(tk.v)+0.8, tk.t, 2.1, 'end'));
  });
  if(linea){
    out.push('<path d="'+valores.map((v,i)=>(i ? 'L' : 'M')+f2(izq+paso*i)+','+f2(y(v))).join(' ')+'" fill="none" stroke="'+col+'" stroke-width="0.3"/>');
  } else {
    const ab = paso*0.6;
    valores.forEach((v,i)=>{
      const x = izq+paso*i+(paso-ab)/2;
      out.push('<rect x="'+f2(x)+'" y="'+f2(y(v))+'" width="'+f2(ab)+'" height="'+f2(Math.max(base-y(v),0))+'" fill="'+col+'"/>');
      if(g.etiquetas && g.etiquetas[i]!==undefined) out.push(txt(x+ab/2, y(v)-1, g.etiquetas[i], 2.1, 'middle', 'rgb(90,96,106)'));
    });
  }
  (g.ejeX||[]).forEach(m=>out.push(txt(izq+paso*m.i+centro, alto-3, m.t, 2.3)));
  return { ancho, alto, svg:'<svg xmlns="http://www.w3.org/2000/svg" width="'+ancho+'mm" height="'+alto+'mm" viewBox="0 0 '+ancho+' '+alto+'">'+out.join('')+'</svg>' };
}

// ===================== Contenido del informe =====================
// Bloques: {t:'seccion'|'sub'|'p'|'kv'|'formula'|'tabla'|'dibujo'|'leyendaTabla'|'leyendaFigura'|'lista'|'typst'}
class Contenido {
  constructor(){ this.bloques = []; }
  seccion(titulo){ this.bloques.push({ t:'seccion', titulo:String(titulo||'') }); return this; }
  sub(titulo){ this.bloques.push({ t:'sub', titulo:String(titulo||'') }); return this; }
  p(texto, negrita){ if(String(texto||'').trim()) this.bloques.push({ t:'p', texto:String(texto), negrita:!!negrita }); return this; }
  kv(k, v){ this.bloques.push({ t:'kv', k:String(k==null?'':k), v:String(v==null?'':v) }); return this; }
  formula(lineas, pie){ this.bloques.push({ t:'formula', lineas:[].concat(lineas||[]).map(String), pie: pie ? String(pie) : '' }); return this; }
  tabla(cabecera, filas, titulo){
    if(titulo) this.leyendaTabla(titulo);
    this.bloques.push({ t:'tabla', cabecera:(cabecera||[]).map(String), filas:(filas||[]).map(f=>[].concat(f).map(c=>c==null?'':String(c))) });
    return this;
  }
  dibujo(svg, ancho, alto){ this.bloques.push({ t:'dibujo', svg, ancho, alto }); return this; }
  imagen(dataUrl, anchoMm){ this.bloques.push({ t:'imagen', src:dataUrl, ancho:anchoMm||160 }); return this; }
  leyendaTabla(texto){ this.bloques.push({ t:'leyendaTabla', texto:String(texto||'') }); return this; }
  leyendaFigura(texto){ this.bloques.push({ t:'leyendaFigura', texto:String(texto||'') }); return this; }
  lista(items, numerada){ this.bloques.push({ t:'lista', items:[].concat(items||[]).map(String), numerada:!!numerada }); return this; }
  typst(codigo){ this.bloques.push({ t:'typst', codigo:String(codigo||'') }); return this; }
}

// Helpers estándar de los informes jsPDF de la web -> Contenido. El resto (drawXxx,
// monthTable...) se envuelven: lo que dibujan en el lienzo se convierte en una figura.
const ESTANDAR = ['checkPage','sectionTitle','subTitle','kv','paragraph','formulaBlock','tableCaption','figureCaption','simpleTable'];
function compat(doc, H0){
  const C = doc.__contenido || (doc.__contenido = new Contenido());
  const suelto = ()=>{ const g = doc.cortar ? doc.cortar() : null; if(g) C.dibujo(g.svg, g.ancho, g.alto); };
  const H = {};
  Object.keys(H0||{}).forEach(k=>{
    if(typeof H0[k]!=='function' || ESTANDAR.includes(k)){ H[k] = H0[k]; return; }
    H[k] = function(){ suelto(); const r = H0[k].apply(this, arguments); suelto(); return r; };
  });
  H.checkPage = H0 && H0.checkPage ? H0.checkPage : (yy=>yy);
  H.sectionTitle = (yy, num, texto)=>{ suelto(); C.seccion(texto); return yy; };
  H.subTitle = (yy, num, texto)=>{ suelto(); C.sub(texto); return yy; };
  H.kv = (yy, k, v)=>{ suelto(); C.kv(k, v); return yy; };
  H.paragraph = (yy, texto, opts)=>{ suelto(); C.p(texto, opts && opts.bold); return yy; };
  H.formulaBlock = (yy, lineas, pie)=>{ suelto(); C.formula(lineas, pie); return yy; };
  H.tableCaption = (yy, num, texto)=>{ suelto(); C.leyendaTabla(texto); return yy; };
  H.figureCaption = (yy, num, texto)=>{ suelto(); C.leyendaFigura(texto); return yy; };
  H.simpleTable = (yy, cab, filas)=>{ suelto(); C.tabla(cab, filas); return yy; };
  H.__contenido = C;
  return H;
}

// ===================== Estructura normalizada (ISO 5966) =====================
// Apartados de la página -> sus partes del informe, por el título.
function clasificar(titulo){
  const t = sinTildes(titulo);
  if(/^resumen( ejecutivo)?$|resumen ejecutivo/.test(t)) return 'resumen';
  if(/introduccion|^objeto|antecedentes/.test(t)) return 'objeto';
  if(/fundamento|metodolog|^metodo|marco teorico|base teorica|bases de calculo|teoria|formulacion/.test(t)) return 'metodologia';
  if(/datos de partida|datos del proyecto|datos generales/.test(t)) return 'partida';
  if(/conclusion/.test(t)) return 'conclusiones';
  if(/^referencias|bibliograf/.test(t)) return 'referencias';
  if(/glosario/.test(t)) return 'glosario';
  if(/^anexo/.test(t)) return 'anexo';
  return 'resultado';
}
const NORMATIVA = /\b(UNE|EN|IEC|ISO|CEI|Real Decreto|RD|Reglamento|ITC|Orden|Ley|Directiva|Circular|CTE|RITE|REBT|Gu[ií]a t[eé]cnica|BOE)\b/;
const DATOS_PROYECTO = /^(proyecto|autor|organizaci|direcci|contacto|destinatario|fecha( del informe)?$|cif|tel[eé]fono|correo|n.? ?de registro)/;

function partes(bloques){
  const P = { previos:[], secciones:[] };
  let actual = null;
  bloques.forEach(b=>{
    if(b.t==='seccion'){ actual = { titulo:b.titulo, tipo:clasificar(b.titulo), bloques:[] }; P.secciones.push(actual); }
    else if(actual) actual.bloques.push(b);
    else P.previos.push(b);
  });
  return P;
}

// ===================== Plantilla Typst =====================
function estilos(ac){
  const rgb = c => 'rgb('+c.map(v=>Math.round(v)).join(', ')+')';
  const oscuro = ac.map(v=>v*0.55);
  return `
#let ac = ${rgb(ac)}
#let ac2 = ${rgb(oscuro)}
#let gris = rgb("#666")
#set text(font: ("Roboto", "DejaVu Sans"), lang: "es", region: "es", size: 9.5pt, fill: rgb("#222"))
#set par(justify: true, leading: 0.62em, spacing: 0.9em)
#set page(paper: "a4", margin: (top: 2.4cm, bottom: 2.2cm, left: 2.5cm, right: 2cm))
#set list(indent: 0.6em)
#set enum(indent: 0.6em)
#set heading(numbering: "1.1")
#show heading: set block(sticky: true)
#show heading.where(level: 1): it => block(above: 1.8em, below: 1em, width: 100%)[
  #text(13.5pt, weight: "bold", fill: ac2,
    if it.numbering == none [#it.body]
    else if it.numbering == "A.1" [Anexo #counter(heading).display("A") #h(0.5em) #it.body #h(0.3em) #text(9pt, weight: "regular", fill: gris)[(informativo)]]
    else [#counter(heading).display(it.numbering) #h(0.5em) #it.body])
  #v(-7pt)
  #line(length: 100%, stroke: 0.8pt + ac)]
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
    align: (x, y) => if t.alin.at(x, default: "l") == "r" { right } else { left },
    stroke: (x, y) => if y == 0 { (top: 0.8pt, bottom: 0.6pt) } else { (bottom: 0.3pt + luma(215)) },
    inset: (x: 3.5pt, y: 2.6pt),
    table.header(..t.cabecera.map(c => strong(c))),
    ..t.filas.flatten().map(c => [#c]),
  )
}
#let ftabla(t, cap, size: 7.5pt) = {
  show figure: set block(breakable: t.filas.len() > 25)
  figure(tabla(t, size: size), caption: cap)
}
#let kv(filas, ancho: 6.2cm) = {
  set par(justify: false)
  table(columns: (ancho, 1fr), stroke: (x, y) => (bottom: 0.3pt + luma(225)), inset: (x: 0pt, y: 4pt),
    ..filas.map(f => (text(fill: gris)[#f.at(0)], strong[#f.at(1)])).flatten())
}
#let formula(lineas, pie: none) = block(width: 100%, fill: rgb("#fafafb"), stroke: 0.5pt + luma(210),
  radius: 2pt, inset: (x: 10pt, y: 8pt), breakable: false)[
  #set align(center)
  #stack(spacing: 7pt, ..lineas.map(l => text(font: "DejaVu Sans Mono", size: 9pt, weight: "bold", fill: ac2, l)))
  #if pie != none [#v(2pt) #text(7.5pt, fill: gris, pie)]]
#let cifra(valor, unidad, etiqueta) = block(width: 100%, fill: ac.lighten(88%), stroke: (left: 2pt + ac),
  inset: (x: 8pt, y: 7pt))[
  #text(14pt, weight: "bold", fill: rgb("#14181f"), valor) #text(8pt, fill: gris, unidad)
  #linebreak()
  #text(7pt, fill: gris, tracking: 0.5pt, upper(etiqueta))]
#let rotulo(t) = [#text(7.5pt, weight: "bold", fill: ac2, tracking: 1pt)[#upper(t)] #v(-5pt) #line(length: 100%, stroke: 0.6pt + ac) #v(-2pt)]
#let ficha(filas, ancho: 4.4cm) = {
  set text(8.5pt)
  set par(justify: false)
  table(columns: (ancho, 1fr), stroke: (x, y) => (bottom: 0.3pt + luma(215)), inset: (x: 0pt, y: 4pt),
    ..filas.map(f => (text(fill: gris)[#f.at(0)], [#f.at(1)])).flatten())
}
#let paginas = context { let q = query(<fin-informe>); if q.len() > 0 { str(q.first().location().page()) } }
`;
}

// Columnas numéricas a la derecha
const NUMERICO = /^[\s+\-−–]*[\d.,]+\s*(%|€|EUR|kW|kWh|h|a|años?|anios?|ud|uds|m|mm²?|A|V|W|kVA|kvar)?[\s/a-zA-Z²·]*$/;
function alineacion(cab, filas){
  return cab.map((_, i)=>{
    const vals = filas.map(f=>f[i]).filter(v=>v!==undefined && String(v).trim() && String(v).trim()!=='-' && String(v).trim()!=='—');
    return vals.length && vals.every(v=>NUMERICO.test(String(v)) && /\d/.test(String(v))) ? 'r' : 'l';
  }).join('');
}

// Bloques -> Typst (con leyendas de tabla encima y de figura debajo)
function bloquesTypst(bloques, archivos, estado){
  let t = '', kvs = [], leyendaTabla = null;
  const cerrarKv = ()=>{
    if(!kvs.length) return;
    const c = 'kv('+ty(kvs.map(([k,v])=>[acentuar(k), acentuar(v)]))+')';
    if(leyendaTabla!==null){ t += '#figure('+c+', kind: table, caption: ['+tm(acentuar(leyendaTabla))+'])\n'; leyendaTabla = null; }
    else t += '#'+c+'\n';
    kvs = [];
  };
  const pendienteTabla = ()=>{ if(leyendaTabla!==null){ t += '#text(8.5pt, style: "italic", '+tq(acentuar(leyendaTabla))+')\n\n'; leyendaTabla = null; } };
  bloques.forEach((b, i)=>{
    if(b.t!=='kv') cerrarKv();
    const sig = bloques[i+1];
    switch(b.t){
      case 'sub': pendienteTabla(); t += '\n== '+tm(acentuar(b.titulo))+'\n'; break;
      case 'p': pendienteTabla(); t += (b.negrita ? '#strong('+tq(acentuar(b.texto))+')' : tm(acentuar(b.texto)))+'\n\n'; break;
      case 'kv': kvs.push([b.k, b.v]); break;
      case 'formula': pendienteTabla(); t += '#formula('+ty(b.lineas)+(b.pie ? ', pie: '+tq(acentuar(b.pie)) : '')+')\n'; break;
      case 'lista': pendienteTabla(); b.items.forEach(x=>{ t += (b.numerada ? '+ ' : '- ')+tm(acentuar(x))+'\n'; }); t += '\n'; break;
      case 'typst': pendienteTabla(); t += b.codigo+'\n'; break;
      case 'leyendaTabla': pendienteTabla(); leyendaTabla = b.texto; break;
      case 'tabla': {
        const tab = { cabecera: b.cabecera.map(acentuar), filas: b.filas.map(f=>f.map(acentuar)), alin: alineacion(b.cabecera, b.filas) };
        if(leyendaTabla!==null){ t += '#ftabla('+ty(tab)+', ['+tm(acentuar(leyendaTabla))+'])\n'; leyendaTabla = null; }
        else t += '#tabla('+ty(tab)+')\n';
        break;
      }
      case 'dibujo': case 'imagen': {
        let nombre, ancho;
        if(b.t==='dibujo'){ nombre = 'fig-'+(++estado.n)+'.svg'; archivos[nombre] = b.svg; ancho = Math.min(b.ancho, 165); }
        else { const m = /^data:image\/(png|jpe?g|gif|webp)/.exec(b.src||''), ext = m ? m[1].replace('jpeg','jpg') : 'png'; nombre = 'img-'+(++estado.n)+'.'+ext; archivos[nombre] = b.src; ancho = Math.min(b.ancho, 165); }
        const img = 'image('+tq(nombre)+', width: '+f2(ancho)+'mm)';
        if(leyendaTabla!==null){ t += '#figure('+img+', kind: table, caption: ['+tm(acentuar(leyendaTabla))+'])\n'; leyendaTabla = null; }
        else if(sig && sig.t==='leyendaFigura'){ t += '#figure('+img+', caption: ['+tm(acentuar(sig.texto))+'])\n'; sig.usada = true; }
        else t += '#align(center, '+img+')\n';
        break;
      }
      case 'leyendaFigura':
        if(!b.usada) t += '#align(center, text(8.5pt, style: "italic", '+tq(acentuar(b.texto))+'))\n\n';
        break;
    }
  });
  cerrarKv(); pendienteTabla();
  return t;
}

// Datos del proyecto: campos p_* de la página (compartidos entre documentos en VatiaCo.proyecto)
function datosProyecto(defecto){
  const campo = id => { const el = document.getElementById('p_'+id); return el ? String(el.value||'').trim() : ''; };
  const pr = {};
  ['proyecto','fecha','codigo','revision','emplazamiento','autor','registro','org_nombre','org_cif','org_dir',
   'org_tel','org_correo','dest_nombre','dest_cif','dest_dir'].forEach(k=>{ pr[k] = campo(k); });
  pr.proyecto = pr.proyecto || defecto || 'Informe técnico';
  pr.fechaIso = /^\d{4}-\d{2}-\d{2}$/.test(pr.fecha) ? pr.fecha : new Date().toISOString().slice(0,10);
  pr.fechaTxt = fechaLarga(pr.fechaIso);
  return pr;
}

// Documento completo -> { principal, nombre, archivos }
function documento(o){
  const pr = datosProyecto(o.titulo);
  pr.codigo = pr.codigo || ((o.codigo || 'IT')+'-'+pr.fechaIso.replace(/-/g,''));
  pr.revision = pr.revision || '0';
  const P = partes(o.contenido.bloques);
  const archivos = {}, estado = { n:0 };
  const de = tipo => P.secciones.filter(s=>s.tipo===tipo);
  const autorTxt = vacio(pr.autor)+(pr.registro && pr.registro!=='-' ? ' (n.º de registro '+pr.registro+')' : '');
  const contacto = [pr.org_tel, pr.org_correo].filter(x=>x && x!=='-').join(' · ');
  const tipoDoc = acentuar(o.tipo || 'Informe técnico');
  const ac = o.acento || [245,166,35];

  // Resumen: párrafos de "Resumen ejecutivo" (lo demás de ese apartado pasa al cuerpo)
  const resumenP = [], restoResumen = [];
  de('resumen').forEach(s=>s.bloques.forEach(b=>(b.t==='p' ? resumenP : restoResumen).push(b)));
  if(!resumenP.length) resumenP.push({ t:'p', texto:'Este documento recoge '+tipoDoc.toLowerCase()+' del proyecto «'+pr.proyecto+'»: datos de entrada, metodología de cálculo, resultados y conclusiones.' });
  // Referencias: párrafos "1. ..." -> lista; las normativas también en "Referencias normativas"
  const refs = [];
  de('referencias').forEach(s=>s.bloques.forEach(b=>{
    if(b.t==='p') refs.push(b.texto.replace(/^\s*\[?\d+[.)\]]\s*/,''));
    else if(b.t==='lista') refs.push(...b.items);
  }));
  (o.referencias||[]).forEach(r=>refs.push(r));
  const normativas = refs.filter(r=>NORMATIVA.test(r)).concat(o.normativa||[]);
  // Datos de partida: sin los datos del proyecto (van en la portada)
  const partida = [];
  de('partida').forEach(s=>s.bloques.forEach(b=>{ if(!(b.t==='kv' && DATOS_PROYECTO.test(sinTildes(b.k)))) partida.push(b); }));

  const filasProyecto = [
    ['Proyecto', pr.proyecto], ['Emplazamiento', vacio(pr.emplazamiento || pr.dest_dir)], ['Autor', autorTxt],
    ['Fecha de emisión', pr.fechaTxt], ['Código del informe', pr.codigo+' · revisión '+pr.revision],
  ].concat((o.datosPortada||[]).map(([k,v])=>[acentuar(k), String(v)]));
  const destinatario = [['Nombre', vacio(pr.dest_nombre)], ['CIF / NIF', vacio(pr.dest_cif)], ['Dirección', vacio(pr.dest_dir)]];
  const organizacion = [['Nombre', vacio(pr.org_nombre)], ['CIF', vacio(pr.org_cif)], ['Dirección', vacio(pr.org_dir)], ['Contacto', vacio(contacto)]];
  const control = [
    ['Título', pr.proyecto], ['Tipo de documento', tipoDoc], ['Código', pr.codigo], ['Revisión', pr.revision],
    ['Fecha', pr.fechaTxt], ['Estado', 'Emitido'], ['Elaborado por', autorTxt], ['Organización', vacio(pr.org_nombre)],
    ['Destinatario', vacio(pr.dest_nombre)], ['Distribución', 'Destinatario y organización redactora'],
  ];
  const cifras = (o.cifras||[]).slice(0,4);

  let t = `// ${tipoDoc}: ${pr.proyecto}. Generado por la web de VatiaCo y compilado con Typst.
#set document(title: ${tq(pr.proyecto)}, author: ${tq(pr.autor||pr.org_nombre||'VatiaCo')})
${estilos(ac)}
// ================= Portada (con los datos del proyecto) =================
#page(margin: (x: 2.2cm, top: 2cm, bottom: 1.8cm), header: none, footer: none)[
  #block(fill: ac, width: 100%, inset: (x: 12pt, y: 10pt))[
    #text(fill: white, 9.5pt, weight: "bold", tracking: 1.5pt, upper(${tq(tipoDoc)})) #h(1fr)
    #text(fill: white, 8.5pt)[${tm(pr.codigo)} · Rev. ${tm(pr.revision)}]]
  #v(1.3cm)
  #text(21pt, weight: "bold", fill: rgb("#14181f"), upper(${tq(pr.proyecto)}))
  #v(2pt)
  #line(length: 35%, stroke: 2pt + ac)
  #v(2pt)
  #text(12pt, fill: gris, ${tq(acentuar(o.subtitulo || tipoDoc))})
${cifras.length ? `  #v(0.9cm)
  #grid(columns: (1fr,) * ${cifras.length}, gutter: 8pt, ${cifras.map(c=>'cifra('+tq(c[0])+', '+tq(c[1]||'')+', '+tq(acentuar(c[2]||''))+')').join(', ')})
` : ''}  #v(1.6cm)
  #rotulo[Datos del proyecto]
  #ficha(${ty(filasProyecto)})
  #v(10pt)
  #grid(columns: (1fr, 1fr), gutter: 18pt,
    [#rotulo[Destinatario] #ficha(${ty(destinatario)}, ancho: 2.2cm)],
    [#rotulo[Organización redactora] #ficha(${ty(organizacion)}, ancho: 2.2cm)])
  #v(1fr)
  #text(7pt, fill: gris, ${tq(acentuar(o.pie || 'Documento generado con las herramientas interactivas de VatiaCo.')+' Estructura del documento según UNE 50135 (ISO 5966).')})
]

// ================= Preliminares (numeración romana) =================
#set page(
  numbering: "i",
  header: context [#set text(7.5pt, fill: gris); ${tm(pr.codigo)} · Rev. ${tm(pr.revision)} #h(1fr) ${tm(pr.proyecto)} #v(-4pt) #line(length: 100%, stroke: 0.4pt + luma(200))],
  footer: context [#set text(7.5pt, fill: gris); #h(1fr) Página #counter(page).display() #h(1fr)],
)
#counter(page).update(1)

#heading(numbering: none, outlined: false)[Hoja de control del documento]
#kv(${ty(control)} + (("Número de páginas", paginas),), ancho: 4.5cm)
#v(10pt)
#strong[Historial de revisiones]
#tabla(${ty({ cabecera:['Rev.','Fecha','Descripción','Autor'], filas:[[pr.revision, pr.fechaTxt, pr.revision==='0' ? 'Emisión inicial del documento' : 'Revisión del documento', vacio(pr.autor)]], alin:'llll' })}, size: 8pt)
#v(10pt)
#strong[Elaboración, revisión y aprobación]
#v(2pt)
#table(columns: (1fr, 1fr, 1fr), stroke: 0.4pt + luma(190), inset: 6pt,
  ..([Elaborado], [Revisado], [Aprobado]).map(c => text(8pt, weight: "bold", c)),
  text(8pt, ${tq(vacio(pr.autor))}), text(8pt)[ ], text(8pt)[ ],
  ..range(3).map(_ => block(height: 1.6cm, text(7pt, fill: gris)[Firma y fecha:])))

#pagebreak()
#heading(numbering: none, outlined: false)[Resumen]
${resumenP.map(b=>tm(acentuar(b.texto))).join('\n\n')}

#strong[Palabras clave:] ${tm(acentuar((o.palabrasClave || []).join('; ') || tipoDoc.toLowerCase()))}.

#pagebreak()
#outline(title: [Índice], depth: 2)
#pagebreak()
#outline(title: [Índice de figuras], target: figure.where(kind: image))
#v(1.5em)
#outline(title: [Índice de tablas], target: figure.where(kind: table))
#pagebreak()

// ================= Cuerpo =================
#set page(numbering: "1")
#counter(page).update(1)

= Objeto y alcance
`;
  const objeto = de('objeto');
  if(o.objeto) t += tm(acentuar(o.objeto))+'\n\n';
  objeto.forEach(s=>{ t += bloquesTypst(s.bloques, archivos, estado); });
  if(!o.objeto && !objeto.length) t += tm('El objeto de este documento es recoger '+tipoDoc.toLowerCase()+' del proyecto «'+pr.proyecto+'».')+'\n\n';
  t += tm(o.alcance || 'El alcance se limita a los cálculos, comprobaciones y estimaciones recogidos en los apartados siguientes, realizados con la herramienta interactiva de VatiaCo a partir de los datos de entrada indicados. No sustituye al proyecto o memoria técnica de ejecución ni a la documentación oficial exigible, cuya verificación corresponde al técnico responsable.')+'\n\n';

  t += '\n= Referencias normativas\n';
  t += tm('Documentos citados en el texto o de aplicación a la materia del informe:')+'\n';
  const listaNorm = normativas.concat([
    'UNE 50135 (ISO 5966). Documentación. Presentación de informes científicos y técnicos (estructura de este documento).',
    'ISO 690. Información y documentación. Directrices para la redacción de referencias bibliográficas.',
  ]);
  listaNorm.forEach(r=>{ t += '- '+tm(acentuar(r))+'\n'; });

  t += '\n= Términos, definiciones y abreviaturas\n';
  const glos = (o.glosario||[]).filter(g=>Array.isArray(g) && g.length>=2);
  de('glosario').forEach(s=>{ t += bloquesTypst(s.bloques, archivos, estado); });
  if(glos.length) t += '#ftabla('+ty({ cabecera:['Término o sigla','Definición','Unidad'], filas: glos.map(g=>[String(g[0]), acentuar(String(g[1])), acentuar(String(g[2]==null?'—':g[2]).replace(/^-$/,'—'))]), alin:'lll' })+', [Términos, definiciones y abreviaturas], size: 8pt)\n';
  else if(!de('glosario').length) t += tm('Se emplean los términos y unidades habituales de la materia; las magnitudes se definen junto a cada fórmula.')+'\n';

  const metodo = de('metodologia');
  if(metodo.length){
    t += '\n= Metodología\n';
    metodo.forEach(s=>{ if(metodo.length>1) t += '\n== '+tm(acentuar(s.titulo))+'\n'; t += bloquesTypst(s.bloques, archivos, estado); });
  }
  if(partida.length || P.previos.length){
    t += '\n= Datos de entrada\n';
    t += bloquesTypst(P.previos.concat(partida), archivos, estado);
  }
  if(restoResumen.length){ t += '\n= Síntesis de resultados\n'+bloquesTypst(restoResumen, archivos, estado); }
  de('resultado').forEach(s=>{ t += '\n= '+tm(acentuar(s.titulo))+'\n'+bloquesTypst(s.bloques, archivos, estado); });

  t += '\n= Conclusiones y recomendaciones\n';
  de('conclusiones').forEach(s=>{ t += bloquesTypst(s.bloques, archivos, estado); });
  if(o.recomendaciones && o.recomendaciones.length){
    t += '\n#strong[Recomendaciones]\n';
    o.recomendaciones.forEach(r=>{ t += '+ '+tm(acentuar(r))+'\n'; });
  }
  t += '\n'+tm('Los resultados de este informe dependen de los datos de entrada y de las hipótesis indicadas. El técnico responsable debe verificarlos antes de utilizarlos en documentación oficial o decisiones de inversión.')+'\n';

  if(refs.length){
    t += '\n#heading(numbering: none)[Bibliografía]\n#set enum(numbering: "[1]")\n';
    refs.forEach(r=>{ t += '+ '+tm(acentuar(r))+'\n'; });
    t += '#set enum(numbering: "1.")\n';
  }
  const anexos = de('anexo').concat((o.anexos||[]).map(a=>({ titulo:a.titulo, bloques:a.contenido.bloques })));
  if(anexos.length){
    t += '\n#pagebreak()\n#counter(heading).update(0)\n#set heading(numbering: "A.1")\n';
    anexos.forEach((a, i)=>{
      if(i) t += '#pagebreak()\n';
      t += '= '+tm(acentuar(String(a.titulo).replace(/^anexo\s*[A-Z0-9]*[.:\-–—]?\s*/i,'')))+'\n'+bloquesTypst(a.bloques, archivos, estado);
    });
  }
  t += '\n#metadata(none) <fin-informe>\n';
  archivos['informe.typ'] = t;
  const base = sinTildes(pr.org_nombre && pr.org_nombre!=='-' ? pr.org_nombre : 'proyecto').replace(/[^a-z0-9]+/g,'-').replace(/^-|-$/g,'') || 'proyecto';
  const nombre = (o.archivo || 'informe-').replace(/\.pdf$/i,'');
  return { principal:'informe.typ', nombre: (/-$/.test(nombre) ? nombre+base : nombre)+'.pdf', archivos };
}

// ===================== Compilación en el servidor y descarga =====================
let avisoPagina = null;   // funcion de avisos de la pagina (showToast, showToastPump...)
function aviso(m){
  const f = avisoPagina || window.showToast;
  if(typeof f==='function'){ f(m); return; }
  console.log(m);
  // La pagina no tiene avisos propios: uno flotante sencillo
  let el = document.getElementById('vatiacoInformeAviso');
  if(!el){
    el = document.createElement('div');
    el.id = 'vatiacoInformeAviso';
    el.setAttribute('role', 'status');
    el.style.cssText = 'position:fixed;left:50%;bottom:24px;transform:translateX(-50%);z-index:99999;max-width:min(560px,calc(100vw - 32px));padding:10px 16px;border-radius:8px;background:#14181f;color:#fff;font:14px/1.4 system-ui,sans-serif;box-shadow:0 4px 16px rgba(0,0,0,.3)';
    document.body.appendChild(el);
  }
  el.textContent = m; el.style.display = 'block';
  clearTimeout(aviso.t); aviso.t = setTimeout(()=>{ el.style.display = 'none'; }, 5000);
}
function errorServidor(e){
  if(e && e.name==='AbortError') return 'el servidor de VatiaCo tarda demasiado en responder';
  if(e instanceof TypeError) return 'no se puede contactar con el servidor de VatiaCo';
  return (e && e.message) || String(e);
}
async function compilar(doc, opciones){
  opciones = opciones || {};
  const ctl = new AbortController(), reloj = setTimeout(()=>ctl.abort(), opciones.tiempo || 180000);
  try{
    const r = await fetch(opciones.api || API, { method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify(doc), signal:ctl.signal });
    if(!r.ok){
      let m = '';
      try{ m = (await r.json()).message || ''; }catch(e){}
      throw new Error(m || ('HTTP '+r.status));
    }
    const blob = await r.blob();
    const nombre = ((r.headers.get('Content-Disposition')||'').match(/filename="([^"]+)"/)||[])[1] || doc.nombre;
    const a = document.createElement('a');
    a.href = URL.createObjectURL(blob); a.download = nombre;
    document.body.appendChild(a); a.click(); a.remove();
    setTimeout(()=>URL.revokeObjectURL(a.href), 10000);
    return nombre;
  }finally{ clearTimeout(reloj); }
}

// Genera, compila y descarga el informe. o: { cuerpo(doc, collect) | contenido, titulo, tipo,
// subtitulo, pie, glosario, archivo, codigo, acento:[r,g,b], cifras:[[valor, unidad, etiqueta]],
// palabrasClave:[], referencias:[], normativa:[], recomendaciones:[], objeto, alcance, anexos:[{titulo, contenido}],
// boton: id o elemento }
let ocupado = false;
async function generar(o){
  if(ocupado) return;
  ocupado = true;
  avisoPagina = typeof o.aviso==='function' ? o.aviso : null;
  const boton = typeof o.boton==='string' ? document.getElementById(o.boton) : (o.boton || document.getElementById('btnPdf'));
  const texto = boton ? boton.textContent : '';
  if(boton){ boton.disabled = true; boton.textContent = 'Generando el PDF en el servidor…'; }
  try{
    if(typeof o.antes==='function') await o.antes();
    let contenido = o.contenido;
    if(!contenido){
      const lienzo = new Lienzo();
      contenido = lienzo.__contenido = new Contenido();
      const r = o.cuerpo(lienzo, { toc:[], tables:[], figures:[] });
      if(r && typeof r.then==='function') await r;
      const g = lienzo.cortar();
      if(g) contenido.dibujo(g.svg, g.ancho, g.alto);
    }
    const doc = documento(Object.assign({}, o, { contenido }));
    await compilar(doc, o);
    aviso('PDF generado y descargado.');
  }catch(e){
    console.error(e);
    aviso('Error generando el PDF: '+errorServidor(e));
  }finally{
    ocupado = false;
    if(boton){ boton.disabled = false; boton.textContent = texto; }
  }
}

window.VatiacoInforme = { API, TILDES, grafico, tq, tm, ty, nES, fechaLarga, acentuar, Lienzo, Contenido, compat, documento, compilar, generar, errorServidor };
})();
