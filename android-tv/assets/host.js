(function () {
  'use strict';
  const pending = new Map();
  const sockets = new Map();
  let sequence = 0;
  const emit = value => NativeHost.postMessage(JSON.stringify(value));
  const request = (method, args) => new Promise((resolve, reject) => {
    const id = String(++sequence);
    pending.set(id, { resolve, reject });
    emit({ type: 'request', id, method, args });
  });
  globalThis.__tvResolve = (id, result, error) => {
    const p = pending.get(id);
    if (!p) return;
    pending.delete(id);
    if (error) p.reject(new Error(String(error))); else p.resolve(result);
  };
  globalThis.__tvSocketEvent = (id, event) => {
    const socket = sockets.get(id);
    if (!socket) return;
    if (socket.handler) socket.handler(event); else socket.pending.push(event);
  };
  globalThis.Host = {
    capabilities: {
      mediaTransform: 0, loginTransaction: true, loginChallengeProtocol: 2,
      loginChallengePush: false, loginChallengeBootstrap: false,
      credentialExposure: true, webSocketPlatformCookie: true
    },
    makeError(code, message, context) {
      return new Error('LP_PLUGIN_ERROR:' + JSON.stringify({ code: String(code || 'UNKNOWN'), message: String(message || ''), context: context || {} }));
    },
    raise(code, message, context) { throw Host.makeError(code, message, context); },
    http: { request: options => request('http', options || {}) },
    crypto: {
      md5: value => NativeHost.md5(String(value)),
      base64Decode: value => NativeHost.base64Decode(String(value))
    },
    session: {
      getCookieHeader: id => NativeHost.cookie(String(id || '')),
      getTransactionCookieHeader: () => Promise.reject(Host.makeError('UNSUPPORTED', 'Transaction cookies are host managed')),
      seedTransactionCookies: (transactionId, cookies, scope) => request('seedCookies', { transactionId, cookies, scope })
    },
    time: { nowMillis: () => Date.now() },
    runtime: {
      loadBuiltinScript: () => false
    },
    storage: {
      get: key => { const value = NativeHost.storageGet(String(key)); try { return JSON.parse(value); } catch (_) { return value || null; } },
      set: (key, value) => NativeHost.storageSet(String(key), JSON.stringify(value)),
      remove: key => NativeHost.storageSet(String(key), '')
    },
    nativeStream: { resolve: () => Promise.reject(Host.makeError('UNSUPPORTED', 'Native stream provider is not available')) },
    ws: {
      open: async options => {
        const result = await request('ws.open', options || {});
        const state = { handler: null, pending: [] };
        sockets.set(result.sessionId, state);
        return {
          sessionId: result.sessionId,
          onMessage: callback => { state.handler = callback; while (state.pending.length && state.handler) state.handler(state.pending.shift()); },
          send: frame => request('ws.send', { sessionId: result.sessionId, frame }),
          close: async options => { await request('ws.close', { sessionId: result.sessionId, options }); sockets.delete(result.sessionId); }
        };
      }
    }
  };
  Host.stream = { resolve: Host.nativeStream.resolve, getInfo: Host.nativeStream.resolve };
  globalThis.__tvInvoke = async (id, name, payload) => {
    try {
      const plugin = globalThis.LiveParsePlugin;
      if (!plugin) throw new Error('Plugin entry did not register LiveParsePlugin');
      if (name === '__describe') {
        emit({ type: 'result', id, value: { apiVersion: plugin.apiVersion, methods: Object.keys(plugin).filter(k => typeof plugin[k] === 'function') } });
        return;
      }
      if (typeof plugin[name] !== 'function') throw Host.makeError('UNSUPPORTED', 'Plugin does not implement ' + name);
      const value = await plugin[name](payload || {});
      emit({ type: 'result', id, value: value === undefined ? null : value });
    } catch (error) {
      emit({ type: 'result', id, error: String(error && error.message ? error.message : error).slice(0, 1500) });
    }
  };
  globalThis.console = { log() {}, error() {}, warn() {}, debug() {}, info() {} };
})();
