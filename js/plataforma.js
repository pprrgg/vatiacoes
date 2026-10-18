/*
 * Acceso de participantes a la plataforma de la comunidad, en un visor a pantalla
 * completa (iframe sin barra). Lo usan la pagina principal y el mapa de comunidades:
 * mismo visor y misma direccion, asi que el inicio de sesion es el mismo desde los dos
 * sitios (el navegador guarda la sesion del iframe ligada a este sitio web).
 *
 *   <script src="/js/plataforma.js"></script>
 *   <a href="https://VatiaCo.duckdns.org/" data-plataforma="Acceso participantes">…</a>
 *   VatiaCoPlataforma.abrir('Nombre de la comunidad')
 *
 * Dentro del visor del blog (iframe del mismo origen) se monta en la ventana de arriba
 * para ocupar toda la pantalla. Se cierra con "atras" del navegador (o Esc mientras el
 * foco no este en la plataforma).
 */
(function () {
  var DESTINO = 'https://VatiaCo.duckdns.org/';
  var HASH = '#plataforma';

  var W = window;
  try { if (window.top !== window && window.top.document) W = window.top; } catch (e) { W = window; }
  var D = W.document;
  var foco = null;

  function visor() {
    var v = D.getElementById('ceVisor');
    if (v) return v;
    v = D.createElement('div');
    v.id = 'ceVisor';
    v.setAttribute('role', 'dialog');
    v.setAttribute('aria-modal', 'true');
    v.setAttribute('aria-label', 'Plataforma de la comunidad energética');
    v.style.cssText = 'position:fixed;inset:0;z-index:2147483000;display:none;background:#17181c;';
    var fr = D.createElement('iframe');
    fr.title = 'Plataforma de la comunidad energética';
    fr.allow = 'fullscreen; clipboard-write';
    fr.style.cssText = 'width:100%;height:100%;border:0;background:#fff;display:block;';
    v.appendChild(fr);
    D.body.appendChild(v);
    return v;
  }
  function abierto() { var v = D.getElementById('ceVisor'); return !!v && v.style.display !== 'none'; }

  function abrir(titulo) {
    var v = visor(), fr = v.querySelector('iframe');
    fr.title = titulo || 'Plataforma de la comunidad energética';
    if (fr.getAttribute('src') !== DESTINO) fr.src = DESTINO;
    foco = document.activeElement;
    v.style.display = 'block';
    D.body.style.overflow = 'hidden';
    fr.focus();
    if (W.location.hash !== HASH) W.history.pushState({ ceVisor: true }, '', W.location.pathname + W.location.search + HASH);
  }
  function cerrar() {
    if (!abierto()) return;
    D.getElementById('ceVisor').style.display = 'none';
    D.body.style.overflow = '';
    if (foco && foco.focus) foco.focus();
  }
  function salir() { if (W.location.hash === HASH) W.history.back(); else cerrar(); }

  W.addEventListener('popstate', cerrar);
  [D, document].forEach(function (t, i, a) {
    if (i && t === a[0]) return;
    t.addEventListener('keydown', function (e) { if (e.key === 'Escape' && abierto()) salir(); });
  });
  // Al cargar con #plataforma (p.ej. tras recargar) no se deja el hash colgado
  if (W.location.hash === HASH) W.history.replaceState(null, '', W.location.pathname + W.location.search);
  // Montado en la ventana de arriba: si esta pagina se descarga, el visor no se queda encima
  if (W !== window) window.addEventListener('pagehide', function () { cerrar(); var v = D.getElementById('ceVisor'); if (v) v.remove(); });

  // Enlaces y botones con data-plataforma: abren el visor (sin JS, el enlace va a la plataforma)
  document.addEventListener('click', function (e) {
    var a = e.target.closest && e.target.closest('[data-plataforma]');
    if (!a) return;
    e.preventDefault();
    abrir(a.getAttribute('data-plataforma') || 'Acceso participantes');
  });

  window.VatiaCoPlataforma = { abrir: abrir, cerrar: cerrar, url: DESTINO };
})();
