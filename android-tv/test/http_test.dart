import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:angel_live_android_tv/data.dart';
import 'package:angel_live_android_tv/http_cookies.dart';
import 'package:angel_live_android_tv/runtime.dart';

class _RealNetwork extends HttpOverrides {}

void main() {
  test('cookie jar keeps host, path, secure and expiry boundaries', () {
    final jar = PluginCookieJar();
    final url = Uri.parse('https://api.example.com/login/start');
    jar.receive(Cookie('host', 'one'), url);
    jar.receive(
      Cookie('domain', 'two')
        ..domain = '.example.com'
        ..path = '/'
        ..secure = true,
      url,
    );
    jar.receive(Cookie('forged', 'bad')..domain = 'other.com', url);
    expect(
      jar.header(Uri.parse('https://api.example.com/login/poll')),
      contains('host=one'),
    );
    expect(
      jar.header(Uri.parse('https://child.api.example.com/login/poll')),
      'domain=two',
    );
    expect(
      jar.header(Uri.parse('https://api.example.com/loginfoo')),
      'domain=two',
    );
    expect(jar.header(Uri.parse('http://api.example.com/')), isEmpty);
    jar.receive(
      Cookie('domain', '')
        ..domain = '.example.com'
        ..path = '/'
        ..maxAge = 0,
      url,
    );
    expect(jar.header(Uri.parse('https://other.example.com/')), isEmpty);
    expect(jar.exportCredentials((uri) => uri.host == 'other.com'), isEmpty);
  });

  test(
    'redirect consumes new cookies and strips credentials across origins',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final destination = await HttpServer.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        final source = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() async {
          await source.close(force: true);
          await destination.close(force: true);
        });
        source.listen((request) async {
          if (request.uri.path == '/first') {
            request.response.cookies.add(Cookie('fresh', 'set-on-redirect'));
            request.response.statusCode = 302;
            request.response.headers.set('location', '/second');
          } else if (request.uri.path == '/second') {
            expect(
              request.headers.value('cookie'),
              contains('fresh=set-on-redirect'),
            );
            expect(request.headers.value('accept-encoding'), 'gzip');
            request.response.statusCode = 302;
            request.response.headers.set(
              'location',
              'http://localhost:${destination.port}/done',
            );
          }
          await request.response.close();
        });
        destination.listen((request) async {
          expect(request.headers.value('cookie'), isNull);
          expect(request.headers.value('authorization'), isNull);
          request.response.write('redirect-ok');
          await request.response.close();
        });
        final runtime = PluginRuntime(
          AppStore(),
          InstalledPlugin(Directory.systemTemp, {'pluginId': 'fixture'}),
        );
        try {
          final result = await runtime.requestHTTP({
            'url': 'http://127.0.0.1:${source.port}/first',
            'headers': {'Authorization': 'test-only', 'Accept-Encoding': 'br'},
          });
          expect(result['bodyText'], 'redirect-ok');
        } finally {
          await runtime.dispose();
        }
      }, _RealNetwork());
    },
  );

  test(
    'managed credentials reject insecure and undeclared destinations before I/O',
    () async {
      final store = AppStore()
        ..sessions['fixture'] = {'cookie': 'session=test-only'};
      final runtime = PluginRuntime(
        store,
        InstalledPlugin(Directory.systemTemp, {
          'pluginId': 'fixture',
          'auth': {
            'credentialDomains': ['example.com'],
          },
        }),
      );
      for (final url in [
        'http://example.com/',
        'https://example.com.evil.invalid/',
      ]) {
        await expectLater(
          runtime.requestHTTP({'url': url, 'authMode': 'platform_cookie'}),
          throwsException,
        );
        await expectLater(
          runtime.requestHTTP({
            'url': url,
            'cookieInject': [
              {
                'cookieName': 'session',
                'target': 'query',
                'queryName': 'token',
              },
            ],
          }),
          throwsException,
        );
      }
      await expectLater(
        runtime.requestHTTP({
          'url': 'https://example.com/',
          'authMode': 'login_transaction',
        }),
        throwsException,
      );
      await runtime.dispose();
    },
  );
}
