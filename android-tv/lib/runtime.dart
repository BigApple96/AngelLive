import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'data.dart';
import 'http_cookies.dart';

class PluginRuntime {
  static final Map<String, PluginRuntime> _engines = {};
  static bool _listening = false;
  final AppStore store;
  final InstalledPlugin plugin;
  final String engineId = DateTime.now().microsecondsSinceEpoch.toString();
  final _ready = Completer<void>();
  final Map<String, Completer<dynamic>> _calls = {};
  final Map<String, WebSocket> _sockets = {};
  final Map<String, PluginCookieJar> _jars = {};
  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15);
  final Set<String> methods = {};
  int _sequence = 0;
  bool closed = false;
  PluginRuntime(this.store, this.plugin);

  List<String> get credentialDomains {
    final login = object(plugin.manifest['loginFlow']);
    final auth = object(plugin.manifest['auth']);
    return [
      ...array(login['cookieDomains']),
      ...array(auth['credentialDomains']),
      ...array(auth['cookieDomains']),
    ].map(string).where((d) => d.isNotEmpty).toList();
  }

  bool allowedCredentialURL(Uri uri) =>
      uri.scheme == 'https' &&
      credentialDomains.any((raw) {
        final d = raw.replaceFirst(RegExp(r'^\.'), '').toLowerCase();
        return uri.host.toLowerCase() == d ||
            uri.host.toLowerCase().endsWith('.$d');
      });

  bool allowedCredentialWebSocketURL(Uri uri) =>
      uri.scheme == 'wss' && allowedCredentialURL(uri.replace(scheme: 'https'));

  Future<void> open() async {
    if (!_listening) {
      _listening = true;
      native.setMethodCallHandler((call) async {
        if (call.method != 'message') return;
        final args = object(call.arguments);
        final runtime = _engines[string(args['engineId'])];
        if (runtime == null || runtime.closed) return;
        try {
          await runtime._message(object(jsonDecode(string(args['message']))));
        } catch (_) {}
      });
    }
    _engines[engineId] = this;
    try {
      final scripts = [
        await rootBundle.loadString('assets/worker.js'),
        await rootBundle.loadString('assets/host.js'),
        ...await plugin.scripts(),
      ];
      await native.invokeMethod('create', {
        'engineId': engineId,
        'pluginId': plugin.id,
        'cookie': store.cookie(plugin.id),
        'scripts': scripts,
      });
      await _ready.future.timeout(const Duration(seconds: 25));
      final description = object(await call('__describe', {}));
      if (description['apiVersion'] != 1) throw Exception('插件运行协议不匹配');
      methods.addAll(array(description['methods']).map(string));
    } catch (_) {
      await dispose();
      rethrow;
    }
  }

  Future<void> _eval(String code) async {
    if (!closed) {
      await native.invokeMethod('eval', {'engineId': engineId, 'script': code});
    }
  }

  Future<dynamic> call(
    String name,
    Map<String, dynamic> payload, {
    Duration timeout = const Duration(seconds: 50),
  }) async {
    if (closed) throw Exception('插件已关闭');
    final id = (++_sequence).toString();
    final completer = Completer<dynamic>();
    _calls[id] = completer;
    final session = store.sessions[plugin.id] ?? {};
    final args = {
      ...payload,
      if (string(session['uid']).isNotEmpty) 'uid': session['uid'],
      'credentialAvailable': store.cookie(plugin.id).isNotEmpty,
    };
    try {
      await _eval(
        '__tvInvoke(${jsonEncode(id)},${jsonEncode(name)},${jsonEncode(args)});',
      );
      return await completer.future.timeout(
        timeout,
        onTimeout: () => throw Exception('平台响应超时，请稍后重试'),
      );
    } finally {
      _calls.remove(id);
    }
  }

  Future<void> _message(Map<String, dynamic> message) async {
    final type = message['type'];
    if (type == 'ready') {
      if (!_ready.isCompleted) _ready.complete();
      return;
    }
    if (type == 'loadError') {
      if (!_ready.isCompleted) {
        _ready.completeError(Exception('插件加载失败：${message['error']}'));
      }
      return;
    }
    final id = string(message['id']);
    if (type == 'result') {
      final completer = _calls.remove(id);
      if (completer != null && !completer.isCompleted) {
        if (message['error'] != null) {
          completer.completeError(Exception(message['error']));
        } else {
          completer.complete(message['value']);
        }
      }
      return;
    }
    if (type != 'request') return;
    try {
      final value = await _request(
        string(message['method']),
        object(message['args']),
      );
      await _eval('__tvResolve(${jsonEncode(id)},${jsonEncode(value)},null);');
    } catch (error) {
      await _eval(
        '__tvResolve(${jsonEncode(id)},null,${jsonEncode(friendlyError(error))});',
      );
    }
  }

  Future<dynamic> _request(String method, Map<String, dynamic> args) async {
    if (method == 'http') return requestHTTP(args);
    if (method == 'seedCookies') {
      final scope = object(args['scope']);
      final domains = array(scope['cookieDomains'] ?? scope['domains']);
      final domain = string(
        scope['domain'] ??
            (domains.isEmpty
                ? (credentialDomains.isEmpty ? '' : credentialDomains.first)
                : domains.first),
      );
      if (domain.isEmpty ||
          !allowedCredentialURL(
            Uri.https(domain.replaceFirst(RegExp(r'^\.'), ''), '/'),
          )) {
        throw Exception('登录 Cookie 作用域无效');
      }
      final jar = _jars.putIfAbsent(
        'tx:${args['transactionId']}',
        PluginCookieJar.new,
      );
      object(args['cookies']).forEach((name, value) {
        jar.seed(name, string(value), domain);
      });
      return {'ok': true};
    }
    if (method == 'ws.open') {
      final uri = Uri.parse(string(args['url']));
      if (!['ws', 'wss'].contains(uri.scheme)) throw Exception('无效弹幕地址');
      final headers = object(args['headers']);
      if (string(args['authMode']).toLowerCase().replaceAll('_', '') ==
          'platformcookie') {
        if (!allowedCredentialWebSocketURL(uri)) {
          throw Exception('凭据作用域不匹配');
        }
        headers['Cookie'] = store.cookie(plugin.id);
      }
      final socket = await WebSocket.connect(
        uri.toString(),
        headers: headers,
      ).timeout(const Duration(seconds: 20));
      final id = DateTime.now().microsecondsSinceEpoch.toString();
      _sockets[id] = socket;
      socket.listen(
        (frame) {
          final event = frame is String
              ? {'type': 'text', 'text': frame}
              : {
                  'type': 'binary',
                  'bytesBase64': base64Encode(frame as List<int>),
                };
          unawaited(
            _eval('__tvSocketEvent(${jsonEncode(id)},${jsonEncode(event)});'),
          );
        },
        onError: (_) {
          unawaited(
            _eval(
              '__tvSocketEvent(${jsonEncode(id)},{type:"error",message:"Connection failed"});',
            ),
          );
        },
        onDone: () {
          unawaited(
            _eval('__tvSocketEvent(${jsonEncode(id)},{type:"close"});'),
          );
        },
      );
      return {'sessionId': id};
    }
    if (method == 'ws.send') {
      final socket = _sockets[string(args['sessionId'])];
      if (socket == null) throw Exception('弹幕连接已关闭');
      final frame = object(args['frame']);
      if (frame['bytesBase64'] != null) {
        socket.add(base64Decode(string(frame['bytesBase64'])));
      } else {
        socket.add(string(frame['text']));
      }
      return null;
    }
    if (method == 'ws.close') {
      await _sockets.remove(string(args['sessionId']))?.close();
      return null;
    }
    throw Exception('此插件要求当前客户端尚未提供的能力');
  }

  Future<Map<String, dynamic>> requestHTTP(Map<String, dynamic> options) async {
    final spec = options['request'] is Map
        ? object(options['request'])
        : options;
    var uri = Uri.parse(string(spec['url']));
    if (!['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw Exception('无效网络地址');
    }
    final mode = string(options['authMode']).toLowerCase().replaceAll('_', '');
    final transactionId = string(options['transactionId']);
    if (!['', 'none', 'platformcookie', 'logintransaction'].contains(mode)) {
      throw Exception('不支持的凭据模式');
    }
    final rules = array(options['cookieInject']).map(object).toList();
    final managed =
        mode == 'platformcookie' ||
        mode == 'logintransaction' ||
        rules.isNotEmpty;
    final requestedId = string(options['platformId']);
    if (managed && requestedId.isNotEmpty && requestedId != plugin.id) {
      throw Exception('不能读取其他插件的凭据');
    }
    if (managed &&
        (uri.scheme != 'https' ||
            (mode != 'logintransaction' && !allowedCredentialURL(uri)))) {
      throw Exception('登录接口的域名不在插件声明范围内');
    }
    if (mode == 'logintransaction' && transactionId.isEmpty) {
      throw Exception('缺少登录事务编号');
    }
    if (mode == 'logintransaction' &&
        rules.any((r) => r['target'] != 'header')) {
      throw Exception('登录事务只支持向请求头注入 Cookie');
    }
    final jarKey = mode == 'logintransaction'
        ? 'tx:$transactionId'
        : 'anonymous';
    final jar = _jars.putIfAbsent(jarKey, PluginCookieJar.new);
    final headers = object(
      spec['headers'],
    ).map((k, v) => MapEntry(k, string(v)));
    if (mode == 'platformcookie' ||
        (mode == 'logintransaction' && !allowedCredentialURL(uri))) {
      headers.removeWhere(
        (k, _) => [
          'cookie',
          'authorization',
          'proxy-authorization',
        ].contains(k.toLowerCase()),
      );
    }
    var method = string(spec['method']).toUpperCase();
    if (method.isEmpty) method = 'GET';
    List<int>? body;
    if (spec['bodyBase64'] != null) {
      body = base64Decode(string(spec['bodyBase64']));
    } else if (spec['body'] != null) {
      body = utf8.encode(
        spec['body'] is String ? spec['body'] : jsonEncode(spec['body']),
      );
    }
    final injectedHeaders = <String>{};
    var injectedURLOrBody = false;
    if (mode != 'logintransaction') {
      final values = cookieValues(store.cookie(plugin.id));
      Map<String, dynamic>? bodyJSON;
      for (final rule in rules) {
        final value = values[string(rule['cookieName'])];
        if (value == null || value.isEmpty) continue;
        final injected = '${string(rule['prefix'])}$value';
        switch (rule['target']) {
          case 'header':
            final name = string(rule['headerName']);
            if (name.isEmpty) continue;
            headers.removeWhere(
              (k, _) => k.toLowerCase() == name.toLowerCase(),
            );
            headers[name] = injected;
            injectedHeaders.add(name.toLowerCase());
          case 'query':
            final name = string(rule['queryName']);
            if (name.isEmpty) continue;
            uri = uri.replace(
              queryParameters: {...uri.queryParametersAll, name: injected},
            );
            injectedURLOrBody = true;
          case 'body':
            final path = string(rule['bodyPath']).split('.');
            if (path.any((p) => p.isEmpty)) continue;
            if (bodyJSON == null) {
              try {
                bodyJSON = object(jsonDecode(utf8.decode(body ?? [])));
              } catch (_) {
                bodyJSON = {};
              }
            }
            var target = bodyJSON;
            for (final key in path.take(path.length - 1)) {
              target[key] = object(target[key]);
              target = target[key] as Map<String, dynamic>;
            }
            target[path.last] = injected;
            injectedURLOrBody = true;
        }
      }
      if (bodyJSON != null) body = utf8.encode(jsonEncode(bodyJSON));
    }
    final timeoutMs =
        (num.tryParse(
                  string(spec['timeoutMs'] ?? options['timeoutMs']),
                )?.toInt() ??
                20000)
            .clamp(1000, 45000);
    final follow =
        options['followRedirects'] ?? spec['followRedirects'] ?? true;
    for (var redirect = 0; redirect < 6; redirect++) {
      if (closed) throw Exception('插件已关闭');
      // Rebuild scoped cookies on every hop, including Set-Cookie from a redirect.
      final hopHeaders = {...headers};
      final explicit = hopHeaders.entries
          .where((e) => e.key.toLowerCase() == 'cookie')
          .map((e) => e.value);
      final cookie = mergeCookies([
        ...explicit,
        jar.header(uri),
        if (mode == 'platformcookie') store.cookie(plugin.id),
      ]);
      hopHeaders.removeWhere((k, _) => k.toLowerCase() == 'cookie');
      if (cookie.isNotEmpty) hopHeaders['Cookie'] = cookie;
      if (mode == 'logintransaction' && allowedCredentialURL(uri)) {
        final values = cookieValues(
          jar.exportCredentials(allowedCredentialURL),
        );
        for (final rule in rules) {
          final value = values[string(rule['cookieName'])];
          final name = string(rule['headerName']);
          if (value == null || value.isEmpty || name.isEmpty) continue;
          final injected = '${string(rule['prefix'])}$value';
          final existing = hopHeaders.entries
              .where((e) => e.key.toLowerCase() == name.toLowerCase())
              .map((e) => e.value)
              .join('; ');
          hopHeaders.removeWhere(
            (k, _) => k.toLowerCase() == name.toLowerCase(),
          );
          if (name.toLowerCase() == 'cookie') {
            if (injected.contains('=')) {
              hopHeaders[name] = mergeCookies([existing, injected]);
            }
          } else {
            hopHeaders[name] = injected;
          }
        }
      }
      final request = await _http
          .openUrl(method, uri)
          .timeout(Duration(milliseconds: timeoutMs));
      request.followRedirects = false;
      hopHeaders.forEach((name, value) {
        if (![
          'content-length',
          'host',
          'connection',
          'accept-encoding',
        ].contains(name.toLowerCase())) {
          request.headers.set(name, value);
        }
      });
      request.headers.set('Accept-Encoding', 'gzip');
      if (managed) request.headers.set('Cache-Control', 'no-store');
      if (body != null) request.add(body);
      final response = await request.close().timeout(
        Duration(milliseconds: timeoutMs),
      );
      for (final cookie in response.cookies) {
        jar.receive(cookie, uri);
      }
      final location = response.headers.value('location');
      if (follow == true &&
          [301, 302, 303, 307, 308].contains(response.statusCode) &&
          location != null) {
        final next = uri.resolve(location);
        await response.drain<void>();
        if (!['https', 'http'].contains(next.scheme) ||
            next.userInfo.isNotEmpty ||
            (managed && next.scheme != 'https')) {
          throw Exception('重定向地址无效');
        }
        if (uri.origin != next.origin) {
          final becomesGET =
              response.statusCode == 303 ||
              ([301, 302].contains(response.statusCode) && method == 'POST');
          if (injectedURLOrBody ||
              mode == 'platformcookie' ||
              (managed && body != null && !becomesGET)) {
            throw Exception('包含凭据的请求发生跨域跳转，已停止');
          }
          headers.removeWhere(
            (k, _) => [
              'cookie',
              'authorization',
              'proxy-authorization',
              ...injectedHeaders,
            ].contains(k.toLowerCase()),
          );
        }
        if (response.statusCode == 303 ||
            ((response.statusCode == 301 || response.statusCode == 302) &&
                method == 'POST')) {
          method = 'GET';
          body = null;
          headers.removeWhere(
            (k, _) =>
                ['content-type', 'content-encoding'].contains(k.toLowerCase()),
          );
        }
        uri = next;
        continue;
      }
      final bytes = <int>[];
      await for (final chunk in response.timeout(
        Duration(milliseconds: timeoutMs),
      )) {
        bytes.addAll(chunk);
        if (bytes.length > 20 * 1024 * 1024) throw Exception('接口返回内容过大');
      }
      final responseHeaders = <String, String>{};
      response.headers.forEach((k, values) {
        if (managed && k.toLowerCase() == 'set-cookie') return;
        responseHeaders[k] = values.join(k == 'set-cookie' ? '\n' : ', ');
        responseHeaders[k
                .split('-')
                .map(
                  (p) =>
                      p.isEmpty ? p : '${p[0].toUpperCase()}${p.substring(1)}',
                )
                .join('-')] =
            responseHeaders[k]!;
      });
      return {
        'status': response.statusCode,
        'headers': responseHeaders,
        'url': uri.toString(),
        'bodyText': utf8.decode(bytes, allowMalformed: true),
        'bodyBase64': base64Encode(bytes),
      };
    }
    throw Exception('接口重定向次数过多');
  }

  Future<void> updateSession(Map<String, dynamic> session) async {
    await store.setSession(plugin.id, session);
    await native.invokeMethod('session', {
      'engineId': engineId,
      'cookie': store.cookie(plugin.id),
    });
  }

  Map<String, dynamic> transactionSession(String transactionId) {
    return {
      'cookie':
          _jars['tx:$transactionId']?.exportCredentials(allowedCredentialURL) ??
          '',
    };
  }

  void clearTransaction(String transactionId) =>
      _jars.remove('tx:$transactionId');

  Future<void> dispose() async {
    if (closed) return;
    closed = true;
    _engines.remove(engineId);
    _http.close(force: true);
    for (final socket in _sockets.values) {
      unawaited(socket.close());
    }
    _sockets.clear();
    for (final completer in _calls.values) {
      if (!completer.isCompleted) completer.completeError(Exception('插件已关闭'));
    }
    _calls.clear();
    try {
      await native.invokeMethod('dispose', {'engineId': engineId});
    } catch (_) {}
  }
}
