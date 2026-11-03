/*
 * Service Worker: intercepta a nivel de red las llamadas a la API de
 * FastAPI hechas desde CUALQUIER documento del sitio (incluidos los de
 * public/docs/, que no incluyen ningún script propio). Añade el token
 * guardado y, si el servidor responde 401, avisa a la página principal
 * (índice) por BroadcastChannel para que muestre el aviso de login,
 * espera el resultado y reintenta la petición original.
 *
 * A diferencia de parchear window.fetch desde fuera, esto no depende de
 * ganar ninguna carrera contra el parseo del documento: el navegador
 * siempre pasa por aquí antes de que el documento vea la respuesta.
 */

var CHANNEL_NAME = 'VatiaCo-auth-sw';
var DB_NAME = 'VatiaCo-auth';
var STORE_NAME = 'kv';
var TOKEN_KEY = 'token';
var API_HOSTS = ['127.0.0.1:8888', 'doctec.duckdns.org'];

function isApiUrl(url) {
  try {
    var u = new URL(url);
    return API_HOSTS.indexOf(u.host) !== -1 && u.pathname.indexOf('/auth/') === -1;
  } catch (e) {
    return false;
  }
}

function openDb() {
  return new Promise(function (resolve, reject) {
    var req = indexedDB.open(DB_NAME, 1);
    req.onupgradeneeded = function () {
      req.result.createObjectStore(STORE_NAME);
    };
    req.onsuccess = function () {
      resolve(req.result);
    };
    req.onerror = function () {
      reject(req.error);
    };
  });
}

function getToken() {
  return openDb()
    .then(function (db) {
      return new Promise(function (resolve) {
        var tx = db.transaction(STORE_NAME, 'readonly');
        var req = tx.objectStore(STORE_NAME).get(TOKEN_KEY);
        req.onsuccess = function () {
          resolve(req.result || null);
        };
        req.onerror = function () {
          resolve(null);
        };
      });
    })
    .catch(function () {
      return null;
    });
}

var channel = new BroadcastChannel(CHANNEL_NAME);

function requestLogin() {
  return new Promise(function (resolve) {
    function handler(event) {
      if (event.data && event.data.type === 'login-result') {
        channel.removeEventListener('message', handler);
        resolve(!!event.data.success);
      }
    }
    channel.addEventListener('message', handler);
    channel.postMessage({ type: 'need-login' });
  });
}

self.addEventListener('install', function () {
  self.skipWaiting();
});

self.addEventListener('activate', function (event) {
  event.waitUntil(self.clients.claim());
});

function buildRequest(req, token) {
  var headers = new Headers(req.headers);
  if (token) headers.set('Authorization', 'Bearer ' + token);
  var init = {
    method: req.method,
    headers: headers,
    redirect: req.redirect,
  };
  if (req.method === 'GET' || req.method === 'HEAD') {
    return fetch(req.url, init);
  }
  return req
    .clone()
    .arrayBuffer()
    .then(function (body) {
      init.body = body;
      return fetch(req.url, init);
    });
}

function handleApiRequest(req) {
  return getToken().then(function (token) {
    return buildRequest(req, token).then(function (response) {
      if (response.status !== 401) return response;
      return requestLogin().then(function (ok) {
        if (!ok) return response;
        return getToken().then(function (freshToken) {
          return buildRequest(req, freshToken);
        });
      });
    });
  });
}

self.addEventListener('fetch', function (event) {
  if (!isApiUrl(event.request.url)) return;
  event.respondWith(
    handleApiRequest(event.request).catch(function (err) {
      channel.postMessage({ type: 'debug-error', message: String(err && err.message), stack: err && err.stack });
      return new Response(JSON.stringify({ swError: String(err && err.message) }), { status: 599 });
    })
  );
});
