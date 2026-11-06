(function () {
  const send = globalThis.postMessage.bind(globalThis);
  const config = globalThis.__tvConfig || {};
  const storage = config.storage || {};
  let cookieHeader = config.cookie || '';
  for (const name of ['atob','btoa','setTimeout','clearTimeout','setInterval','clearInterval','requestAnimationFrame','cancelAnimationFrame','queueMicrotask','fetch','addEventListener','removeEventListener','dispatchEvent']) {
    if (typeof globalThis[name] === 'function') globalThis[name] = globalThis[name].bind(globalThis);
  }
  const nativePerformance = globalThis.performance;
  Object.defineProperty(globalThis, 'performance', { configurable: true, writable: true, value: { now: () => nativePerformance.now(), timeOrigin: nativePerformance.timeOrigin, timing: {} } });
  function md5(input) {
    const bytes = new TextEncoder().encode(input), n = Math.ceil((bytes.length + 9) / 64) * 64;
    const data = new Uint8Array(n); data.set(bytes); data[bytes.length] = 128;
    const view = new DataView(data.buffer); view.setUint32(n - 8, bytes.length * 8, true);
    let h = [0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476];
    const shifts = [[7,12,17,22],[5,9,14,20],[4,11,16,23],[6,10,15,21]];
    for (let off = 0; off < n; off += 64) {
      let [a,b,c,d] = h;
      for (let i = 0; i < 64; i++) {
        let f,g;
        if(i<16){f=(b&c)|(~b&d);g=i;}else if(i<32){f=(d&b)|(~d&c);g=(5*i+1)%16;}else if(i<48){f=b^c^d;g=(3*i+5)%16;}else{f=c^(b|~d);g=(7*i)%16;}
        const sum=(a+f+Math.floor(Math.abs(Math.sin(i+1))*4294967296)+view.getUint32(off+g*4,true))|0;
        const s=shifts[i>>4][i%4], old=d;d=c;c=b;b=(b+((sum<<s)|(sum>>>(32-s))))|0;a=old;
      }
      h=[(h[0]+a)|0,(h[1]+b)|0,(h[2]+c)|0,(h[3]+d)|0];
    }
    return h.map(v=>[0,8,16,24].map(s=>((v>>>s)&255).toString(16).padStart(2,'0')).join('')).join('');
  }
  Object.defineProperty(globalThis, 'navigator', { configurable: true, writable: true, value: { userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36', platform: 'MacIntel', language: 'zh-CN', languages: ['zh-CN','en'], hardwareConcurrency: 4 } });
  Object.defineProperty(globalThis, 'location', { configurable: true, writable: true, value: { href: '', protocol: 'https:', hostname: '', host: '', pathname: '/', search: '', hash: '' } });
  globalThis.window = {};
  Object.defineProperty(globalThis, 'self', { configurable: true, writable: true, value: globalThis.window });
  globalThis.document = {};
  globalThis.NativeHost = {
    postMessage: message => send(message), md5,
    base64Decode: value => new TextDecoder().decode(Uint8Array.from(atob(value), c => c.charCodeAt(0))),
    cookie: id => !id || id === config.pluginId ? cookieHeader : '',
    setCookie: value => { cookieHeader = String(value || ''); },
    storageGet: key => storage[key] || '',
    storageSet: (key, value) => { storage[key] = value; send(JSON.stringify({type:'storage', value: storage})); }
  };
  globalThis.addEventListener('message', event => { try { (0,eval)(event.data.script); } catch(error) { send(JSON.stringify({type:'workerError',error:String(error && error.message || error)})); } });
})();
