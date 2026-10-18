/*
 * Gestiona el login/registro del sitio y responde a los avisos del
 * Service Worker (sw.js), que es quien realmente intercepta a nivel de
 * red las llamadas a la API hechas desde CUALQUIER documento del sitio
 * (incluidos los de public/docs/, que no incluyen ningún script propio).
 * Cuando el SW ve un 401, avisa aquí por BroadcastChannel; este script
 * muestra el aviso/login y responde con el resultado para que el SW
 * reintente la petición original.
 */
(function () {
  var TOKEN_KEY = 'proman_auth_token';

  // URL base para /auth/login y /auth/register. La alterna
  // scripts/set-docs-url.sh (predeploy/postdeploy en package.json), igual
  // que hace con las URLs incrustadas en public/docs/**/*.html.
  var API_BASE_URL = 'https://doctec.duckdns.org/fast/';

  function apiBase() {
    return API_BASE_URL.replace(/\/$/, '');
  }

  function getUsername() {
    var token = localStorage.getItem(TOKEN_KEY);
    if (!token) return null;
    try {
      var base64 = token.split('.')[1].replace(/-/g, '+').replace(/_/g, '/');
      var payload = JSON.parse(atob(base64));
      if (!payload.exp || payload.exp * 1000 <= Date.now()) return null;
      return payload.sub || null;
    } catch (e) {
      return null;
    }
  }

  function notifyAuthChanged() {
    window.dispatchEvent(new CustomEvent('VatiaCo-auth-changed'));
  }

  // ---------- Espejo del token en IndexedDB para el Service Worker ----------
  // Un Service Worker no puede leer localStorage, así que cada vez que el
  // token cambia aquí también se guarda en IndexedDB (misma base de datos
  // que lee sw.js) para que pueda añadir el header Authorization.
  var IDB_NAME = 'VatiaCo-auth';
  var IDB_STORE = 'kv';
  var IDB_TOKEN_KEY = 'token';

  function openIdb() {
    return new Promise(function (resolve, reject) {
      var req = indexedDB.open(IDB_NAME, 1);
      req.onupgradeneeded = function () {
        req.result.createObjectStore(IDB_STORE);
      };
      req.onsuccess = function () {
        resolve(req.result);
      };
      req.onerror = function () {
        reject(req.error);
      };
    });
  }

  function syncTokenToIdb(token) {
    return openIdb().then(function (db) {
      return new Promise(function (resolve) {
        var tx = db.transaction(IDB_STORE, 'readwrite');
        if (token) tx.objectStore(IDB_STORE).put(token, IDB_TOKEN_KEY);
        else tx.objectStore(IDB_STORE).delete(IDB_TOKEN_KEY);
        // Esperamos a que la transacción termine de verdad (no solo a que
        // se encole): el Service Worker puede releer el token justo
        // después de que avisemos de que el login ya está listo.
        tx.oncomplete = function () {
          resolve();
        };
        tx.onerror = function () {
          resolve();
        };
      });
    });
  }

  function setToken(token) {
    localStorage.setItem(TOKEN_KEY, token);
    return syncTokenToIdb(token)
      .catch(function () {})
      .then(function () {
        notifyAuthChanged();
      });
  }

  function logout() {
    localStorage.removeItem(TOKEN_KEY);
    return syncTokenToIdb(null)
      .catch(function () {})
      .then(function () {
        notifyAuthChanged();
      });
  }

  if ('serviceWorker' in navigator) {
    navigator.serviceWorker.register('/sw.js').catch(function () {});
  }

  // ---------- Aviso informativo (lo dispara el Service Worker) ----------
  var modalEl = null;
  var pending = [];

  var DEMO_USERNAME = 'invitado';
  var DEMO_PASSWORD = 'invitado';

  function ensureModal() {
    if (modalEl) return modalEl;
    modalEl = document.createElement('div');
    modalEl.innerHTML =
      '<style>' +
      '#ag-backdrop{position:fixed;inset:0;background:rgba(0,0,0,.55);display:flex;align-items:center;justify-content:center;z-index:9999;font-family:Inter,system-ui,sans-serif;}' +
      '#ag-card{width:min(320px,90vw);background:#23262f;color:#edeef3;border-radius:.75rem;padding:1.75rem;box-shadow:0 18px 60px rgba(0,0,0,.45);}' +
      '#ag-card h2{margin:0 0 .25rem;font-size:1.1rem;color:#fff;}' +
      '#ag-card p.ag-subtitle{margin:0 0 1.25rem;font-size:.8125rem;line-height:1.5;color:#888c96;}' +
      '#ag-card p.ag-subtitle strong{color:#edeef3;}' +
      '#ag-card .ag-actions{display:flex;gap:.5rem;}' +
      '#ag-card button{flex:1;padding:.6rem .7rem;border:0;border-radius:.5rem;font:inherit;font-weight:600;font-size:.875rem;cursor:pointer;}' +
      '#ag-card button.ag-submit{background:#3369ff;color:#fff;}' +
      '#ag-card button.ag-login{background:#3369ff;color:#fff;}' +
      '#ag-card button.ag-cancel{background:#353841;color:#c1c3c8;}' +
      '#ag-card .ag-error{display:none;margin-top:.75rem;font-size:.8125rem;color:#ff6b6b;}' +
      '#ag-card .ag-error.visible{display:block;}' +
      '</style>' +
      '<div id="ag-backdrop">' +
      '<div id="ag-card">' +
      '<h2>Inicia sesión</h2>' +
      '<p class="ag-subtitle">Necesitas iniciar sesión para usar esta herramienta. </p>' +
      '<div class="ag-actions"><button type="button" class="ag-cancel">Cancelar</button><button type="button" class="ag-login">Inicia sesión</button></div>' +
      '</div>' +
      '</div>';
    document.body.appendChild(modalEl);

    modalEl.querySelector('.ag-login').addEventListener('click', function () {
      hideModal();
      showFormModal('login');
    });

    modalEl.querySelector('.ag-cancel').addEventListener('click', function () {
      hideModal();
      rejectPending();
    });

    return modalEl;
  }

  // Este aviso nunca inicia sesión por sí solo: solo informa. La única
  // forma de completarlo es el botón superior (loginWithForm).
  function showModal() {
    ensureModal().style.display = 'block';
  }

  function hideModal() {
    if (modalEl) modalEl.style.display = 'none';
  }

  function resolvePending() {
    var toResolve = pending;
    pending = [];
    toResolve.forEach(function (p) {
      p.resolve();
    });
  }

  function rejectPending() {
    var toReject = pending;
    pending = [];
    toReject.forEach(function (p) {
      p.reject(new Error('Login cancelado'));
    });
  }

  function waitForLogin() {
    return new Promise(function (resolve, reject) {
      pending.push({ resolve: resolve, reject: reject });
      showModal();
    });
  }

  // El aviso nunca inicia sesión por sí mismo: se resuelve en cuanto el
  // usuario complete el login desde el otro modal (botón superior).
  window.addEventListener('VatiaCo-auth-changed', function () {
    if (getUsername() && pending.length) {
      hideModal();
      resolvePending();
    }
  });

  // El Service Worker intercepta las llamadas a la API de CUALQUIER
  // documento (incluidos los iframes) y, ante un 401, avisa aquí por
  // BroadcastChannel; se muestra el aviso y se le responde con el
  // resultado para que reintente (o no) la petición original.
  if ('BroadcastChannel' in window) {
    var swChannel = new BroadcastChannel('VatiaCo-auth-sw');
    swChannel.addEventListener('message', function (event) {
      if (event.data && event.data.type === 'need-login') {
        waitForLogin()
          .then(function () {
            swChannel.postMessage({ type: 'login-result', success: true });
          })
          .catch(function () {
            swChannel.postMessage({ type: 'login-result', success: false });
          });
      }
    });
  }

  // ---------- Modal de login/registro con formulario (botón del topnav) ----------
  var formModalEl = null;
  var formPending = [];

  function performLogin(username, password) {
    return fetch(apiBase() + '/auth/login', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ username: username, password: password }),
    }).then(function (res) {
      return res.json().then(function (data) {
        return { ok: res.ok, data: data };
      });
    });
  }

  function ensureFormModal() {
    if (formModalEl) return formModalEl;
    formModalEl = document.createElement('div');
    formModalEl.innerHTML =
      '<style>' +
      '#agf-backdrop{position:fixed;inset:0;background:rgba(0,0,0,.55);display:flex;align-items:center;justify-content:center;z-index:9999;font-family:Inter,system-ui,sans-serif;}' +
      '#agf-card{width:min(340px,90vw);background:#23262f;color:#edeef3;border-radius:.75rem;padding:1.75rem;box-shadow:0 18px 60px rgba(0,0,0,.45);}' +
      '#agf-card h2{margin:0 0 .25rem;font-size:1.1rem;color:#fff;}' +
      '#agf-card p.agf-subtitle{margin:0 0 1.25rem;font-size:.8125rem;color:#888c96;}' +
      '#agf-card label{display:block;font-size:.8125rem;font-weight:600;margin-bottom:.3rem;}' +
      '#agf-card .agf-field{margin-bottom:.85rem;}' +
      '#agf-card input{width:100%;box-sizing:border-box;padding:.55rem .7rem;border-radius:.5rem;border:1px solid #353841;background:#17181c;color:#fff;font:inherit;font-size:.9rem;}' +
      '#agf-card input:focus{outline:none;border-color:#3369ff;}' +
      '#agf-card .agf-actions{display:flex;gap:.5rem;margin-top:.5rem;}' +
      '#agf-card button{flex:1;padding:.6rem .7rem;border:0;border-radius:.5rem;font:inherit;font-weight:600;font-size:.875rem;cursor:pointer;}' +
      '#agf-card button[type=submit]{background:#3369ff;color:#fff;}' +
      '#agf-card button.agf-cancel{background:#353841;color:#c1c3c8;}' +
      '#agf-card .agf-error{display:none;margin-top:.75rem;font-size:.8125rem;color:#ff6b6b;}' +
      '#agf-card .agf-error.visible{display:block;}' +
      '#agf-card .agf-success{display:none;margin-top:.75rem;font-size:.8125rem;color:#4caf50;}' +
      '#agf-card .agf-success.visible{display:block;}' +
      '#agf-card .agf-switch{margin:1rem 0 0;text-align:center;font-size:.8125rem;color:#888c96;}' +
      '#agf-card .agf-switch a{color:#6d94ff;text-decoration:none;font-weight:600;}' +
      '#agf-card .agf-switch a:hover{text-decoration:underline;}' +
      '#agf-card .agf-view[hidden]{display:none;}' +
      '</style>' +
      '<div id="agf-backdrop">' +
      '<div id="agf-card">' +
      '<div class="agf-view" data-view="login">' +
      '<h2>Inicia sesión</h2>' +
      '<p class="agf-subtitle">Introduce tus credenciales de acceso.</p>' +
      '<form class="agf-login-form">' +
      '<div class="agf-field"><label>Usuario</label><input name="username" autocomplete="username" required value="' + DEMO_USERNAME + '" /></div>' +
      '<div class="agf-field"><label>Contraseña</label><input name="password" type="password" autocomplete="current-password" required value="' + DEMO_PASSWORD + '" /></div>' +
      '<div class="agf-actions"><button type="button" class="agf-cancel">Cancelar</button><button type="submit">Entrar</button></div>' +
      '<p class="agf-error"></p>' +
      '</form>' +
      '<p class="agf-switch">¿No tienes cuenta? <a href="#" class="agf-goto-register">Regístrate</a></p>' +
      '</div>' +
      '<div class="agf-view" data-view="register" hidden>' +
      '<h2>Crear cuenta</h2>' +
      '<p class="agf-subtitle">Rellena tus datos para registrarte.</p>' +
      '<form class="agf-register-form">' +
      '<div class="agf-field"><label>Nombre</label><input name="nombre" autocomplete="name" /></div>' +
      '<div class="agf-field"><label>Email</label><input name="email" type="email" autocomplete="email" /></div>' +
      '<div class="agf-field"><label>Empresa</label><input name="empresa" autocomplete="organization" /></div>' +
      '<div class="agf-field"><label>Teléfono</label><input name="telefono" type="tel" autocomplete="tel" /></div>' +
      '<div class="agf-field"><label>Usuario</label><input name="username" autocomplete="username" required /></div>' +
      '<div class="agf-field"><label>Contraseña</label><input name="password" type="password" autocomplete="new-password" required /></div>' +
      '<div class="agf-field"><label>Confirmar contraseña</label><input name="password2" type="password" autocomplete="new-password" required /></div>' +
      '<div class="agf-actions"><button type="button" class="agf-cancel">Cancelar</button><button type="submit">Registrarme</button></div>' +
      '<p class="agf-error"></p>' +
      '<p class="agf-success"></p>' +
      '</form>' +
      '<p class="agf-switch">¿Ya tienes cuenta? <a href="#" class="agf-goto-login">Inicia sesión</a></p>' +
      '</div>' +
      '</div>' +
      '</div>';
    document.body.appendChild(formModalEl);

    var loginView = formModalEl.querySelector('[data-view=login]');
    var registerView = formModalEl.querySelector('[data-view=register]');
    var loginForm = formModalEl.querySelector('.agf-login-form');
    var registerForm = formModalEl.querySelector('.agf-register-form');

    function showView(view) {
      loginView.hidden = view !== 'login';
      registerView.hidden = view !== 'register';
      formModalEl.querySelectorAll('.agf-error, .agf-success').forEach(function (el) {
        el.classList.remove('visible');
      });
      loginForm.reset();
      registerForm.reset();
    }

    formModalEl.querySelector('.agf-goto-register').addEventListener('click', function (ev) {
      ev.preventDefault();
      showView('register');
    });
    formModalEl.querySelector('.agf-goto-login').addEventListener('click', function (ev) {
      ev.preventDefault();
      showView('login');
    });

    formModalEl.querySelectorAll('.agf-cancel').forEach(function (btn) {
      btn.addEventListener('click', function () {
        hideFormModal();
        rejectFormPending();
      });
    });

    loginForm.addEventListener('submit', function (ev) {
      ev.preventDefault();
      var errorEl = loginForm.querySelector('.agf-error');
      var submitBtn = loginForm.querySelector('button[type=submit]');
      errorEl.classList.remove('visible');
      submitBtn.disabled = true;
      submitBtn.textContent = 'Entrando…';

      var username = loginForm.querySelector('input[name=username]').value.trim();
      var password = loginForm.querySelector('input[name=password]').value;

      performLogin(username, password)
        .then(function (result) {
          if (!result.ok) {
            errorEl.textContent = result.data && result.data.detail ? result.data.detail : 'Usuario o contraseña incorrectos.';
            errorEl.classList.add('visible');
            return;
          }
          return setToken(result.data.access_token).then(function () {
            hideFormModal();
            resolveFormPending();
          });
        })
        .catch(function () {
          errorEl.textContent = 'No se ha podido contactar con el servidor. Inténtalo de nuevo.';
          errorEl.classList.add('visible');
        })
        .finally(function () {
          submitBtn.disabled = false;
          submitBtn.textContent = 'Entrar';
        });
    });

    registerForm.addEventListener('submit', function (ev) {
      ev.preventDefault();
      var errorEl = registerForm.querySelector('.agf-error');
      var successEl = registerForm.querySelector('.agf-success');
      var submitBtn = registerForm.querySelector('button[type=submit]');
      errorEl.classList.remove('visible');
      successEl.classList.remove('visible');

      var nombre = registerForm.querySelector('input[name=nombre]').value.trim();
      var email = registerForm.querySelector('input[name=email]').value.trim();
      var empresa = registerForm.querySelector('input[name=empresa]').value.trim();
      var telefono = registerForm.querySelector('input[name=telefono]').value.trim();
      var username = registerForm.querySelector('input[name=username]').value.trim();
      var password = registerForm.querySelector('input[name=password]').value;
      var password2 = registerForm.querySelector('input[name=password2]').value;

      if (password !== password2) {
        errorEl.textContent = 'Las contraseñas no coinciden.';
        errorEl.classList.add('visible');
        return;
      }

      submitBtn.disabled = true;
      submitBtn.textContent = 'Registrando…';

      var body = new FormData();
      body.append('nombre', nombre);
      body.append('email', email);
      body.append('empresa', empresa);
      body.append('telefono', telefono);
      body.append('username', username);
      body.append('password', password);

      fetch(apiBase() + '/auth/register', { method: 'POST', body: body })
        .then(function (res) {
          return res.json();
        })
        .then(function (data) {
          if (data.status !== 'ok') {
            errorEl.textContent = data.message || 'No se ha podido completar el registro.';
            errorEl.classList.add('visible');
            return;
          }
          // El registro ya no crea la cuenta al momento (se revisa a mano),
          // así que no iniciamos sesión: solo confirmamos la solicitud.
          registerForm.reset();
          successEl.textContent = data.message || 'Solicitud recibida. En breve recibirás un correo de confirmación.';
          successEl.classList.add('visible');
        })
        .catch(function () {
          errorEl.textContent = 'No se ha podido contactar con el servidor. Inténtalo de nuevo.';
          errorEl.classList.add('visible');
        })
        .finally(function () {
          submitBtn.disabled = false;
          submitBtn.textContent = 'Registrarme';
        });
    });

    formModalEl._showView = showView;
    return formModalEl;
  }

  function showFormModal(view) {
    var modal = ensureFormModal();
    // Por defecto se abre en login (p.ej. desde el botón superior), aunque
    // la última vez se hubiera quedado en la vista de registro.
    modal._showView(view || 'login');
    modal.style.display = 'block';
  }

  function hideFormModal() {
    if (formModalEl) formModalEl.style.display = 'none';
  }

  function resolveFormPending() {
    var toResolve = formPending;
    formPending = [];
    toResolve.forEach(function (p) {
      p.resolve();
    });
  }

  function rejectFormPending() {
    var toReject = formPending;
    formPending = [];
    toReject.forEach(function (p) {
      p.reject(new Error('Login cancelado'));
    });
  }

  function loginWithForm() {
    return new Promise(function (resolve, reject) {
      formPending.push({ resolve: resolve, reject: reject });
      showFormModal();
    });
  }

  // ---------- Modal de confirmación (p.ej. cerrar sesión) ----------
  var confirmModalEl = null;

  function ensureConfirmModal() {
    if (confirmModalEl) return confirmModalEl;
    confirmModalEl = document.createElement('div');
    confirmModalEl.innerHTML =
      '<style>' +
      '#agc-backdrop{position:fixed;inset:0;background:rgba(0,0,0,.55);display:flex;align-items:center;justify-content:center;z-index:9999;font-family:Inter,system-ui,sans-serif;}' +
      '#agc-card{width:min(320px,90vw);background:#23262f;color:#edeef3;border-radius:.75rem;padding:1.75rem;box-shadow:0 18px 60px rgba(0,0,0,.45);}' +
      '#agc-card h2{margin:0 0 .5rem;font-size:1.1rem;color:#fff;}' +
      '#agc-card p{margin:0;font-size:.8125rem;color:#888c96;}' +
      '#agc-card .agc-actions{display:flex;gap:.5rem;margin-top:1.25rem;}' +
      '#agc-card button{flex:1;padding:.6rem .7rem;border:0;border-radius:.5rem;font:inherit;font-weight:600;font-size:.875rem;cursor:pointer;}' +
      '#agc-card button.agc-confirm{background:#e5484d;color:#fff;}' +
      '#agc-card button.agc-cancel{background:#353841;color:#c1c3c8;}' +
      '</style>' +
      '<div id="agc-backdrop">' +
      '<div id="agc-card">' +
      '<h2 class="agc-title"></h2>' +
      '<p class="agc-message"></p>' +
      '<div class="agc-actions"><button type="button" class="agc-cancel">Cancelar</button><button type="button" class="agc-confirm">Confirmar</button></div>' +
      '</div>' +
      '</div>';
    document.body.appendChild(confirmModalEl);
    return confirmModalEl;
  }

  function confirmDialog(options) {
    var modal = ensureConfirmModal();
    modal.querySelector('.agc-title').textContent = (options && options.title) || 'Confirmar';
    modal.querySelector('.agc-message').textContent = (options && options.message) || '';
    var confirmBtn = modal.querySelector('.agc-confirm');
    confirmBtn.textContent = (options && options.confirmLabel) || 'Confirmar';
    modal.style.display = 'block';

    return new Promise(function (resolve) {
      function cleanup(result) {
        modal.style.display = 'none';
        confirmBtn.removeEventListener('click', onConfirm);
        cancelBtn.removeEventListener('click', onCancel);
        resolve(result);
      }
      function onConfirm() {
        cleanup(true);
      }
      function onCancel() {
        cleanup(false);
      }
      var cancelBtn = modal.querySelector('.agc-cancel');
      confirmBtn.addEventListener('click', onConfirm);
      cancelBtn.addEventListener('click', onCancel);
    });
  }

  // API pública para la UI (p.ej. el botón de sesión en el topnav).
  window.PromanAuth = {
    getUsername: getUsername,
    isLoggedIn: function () {
      return !!getUsername();
    },
    login: waitForLogin,
    loginWithForm: loginWithForm,
    confirm: confirmDialog,
    logout: logout,
  };
})();
