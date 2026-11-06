import 'package:flutter_test/flutter_test.dart';
import 'package:angel_live_android_tv/data.dart';
import 'package:angel_live_android_tv/runtime.dart';
import 'dart:io';

void main() {
  test('package paths cannot escape installation directory', () {
    for (final path in [
      '../outside',
      'plugin/../../outside',
      '/absolute',
      r'C:\escape',
      r'..\escape',
    ]) {
      expect(() => safeRelativePath(path), throwsFormatException);
    }
    expect(safeRelativePath('scripts/runtime.js'), 'scripts/runtime.js');
  });
  test(
    'same provisional URL retains distinct lazy quality selections and headers',
    () {
      final sources = playbackSources([
        {
          'cdn': 'Line A',
          'requestContext': {'cdn': 'actual-cdn'},
          'headers': {'Referer': 'https://example.com/'},
          'qualitys': [
            {
              'title': '720p',
              'qn': 720,
              'url': 'https://example.com/live.flv',
              'userAgent': 'FixturePlayer',
              'requestContext': {'rate': '2'},
              'playbackHints': {'selectionBehavior': 'refreshOnSelect'},
            },
            {
              'title': '1080p',
              'qn': 1080,
              'url': 'https://example.com/live.flv',
              'playbackHints': {'selectionBehavior': 'refreshOnSelect'},
            },
          ],
        },
      ]);
      expect(sources, hasLength(2));
      expect(sources.first.name, 'Line A · 720p');
      expect(sources.first.headers['Referer'], 'https://example.com/');
      expect(sources.first.headers['User-Agent'], 'FixturePlayer');
      expect(sources.first.selection['rate'], '2');
      expect(sources.first.selection['cdn'], 'actual-cdn');
      expect(sources.first.refresh, isTrue);
    },
  );
  test('room wrappers keep stable numeric and string room identifiers', () {
    final rooms = roomList({
      'data': {
        'list': [
          {'roomId': 123, 'userName': 'A'},
          {'roomId': '456'},
          {'title': 'invalid'},
        ],
      },
    });
    expect(rooms, hasLength(2));
    expect(string(rooms.first['roomId']), '123');
  });
  test(
    'credentials require HTTPS and an exact domain or its subdomain',
    () async {
      final runtime = PluginRuntime(
        AppStore(),
        InstalledPlugin(Directory.systemTemp, {
          'pluginId': 'fixture',
          'loginFlow': {
            'cookieDomains': ['example.com'],
          },
        }),
      );
      expect(
        runtime.allowedCredentialURL(Uri.parse('https://api.example.com/')),
        isTrue,
      );
      expect(
        runtime.allowedCredentialURL(
          Uri.parse('https://example.com.evil.invalid/'),
        ),
        isFalse,
      );
      expect(
        runtime.allowedCredentialURL(Uri.parse('http://example.com/')),
        isFalse,
      );
      expect(
        runtime.allowedCredentialWebSocketURL(Uri.parse('ws://example.com/')),
        isFalse,
      );
      expect(
        runtime.allowedCredentialWebSocketURL(
          Uri.parse('wss://api.example.com/'),
        ),
        isTrue,
      );
      await runtime.dispose();
    },
  );
}
