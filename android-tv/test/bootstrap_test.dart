import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:angel_live_android_tv/data.dart';

class _Network extends HttpOverrides {}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late HttpServer server;
  late String defaultURL;
  late List<String> requests;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('tv-bootstrap-test-');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    defaultURL = 'http://127.0.0.1:${server.port}/default-index';
    requests = [];
    server.listen((request) async {
      requests.add(request.uri.path);
      final custom = request.uri.path == '/custom-index';
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'apiVersion': 1,
          'sourceName': 'Fixture source',
          'plugins': List.generate(
            custom ? 2 : 19,
            (i) => {
              'pluginId': '${custom ? 'custom' : 'source'}_$i',
              'version': '1.0.0',
            },
          ),
        }),
      );
      await request.response.close();
    });
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => directory.path,
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      native,
      (_) async => null,
    );
    binding.defaultBinaryMessenger.setMockMessageHandler('flutter/assets', (
      message,
    ) async {
      final name = utf8.decode(
        message!.buffer.asUint8List(
          message.offsetInBytes,
          message.lengthInBytes,
        ),
      );
      if (name != 'assets/bootstrap.json') return null;
      return ByteData.sublistView(
        Uint8List.fromList(utf8.encode(jsonEncode({'sourceURL': defaultURL}))),
      );
    });
    rootBundle.evict('assets/bootstrap.json');
  });

  tearDown(() async {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(native, null);
    binding.defaultBinaryMessenger.setMockMessageHandler(
      'flutter/assets',
      null,
    );
    rootBundle.evict('assets/bootstrap.json');
    await server.close(force: true);
    await directory.delete(recursive: true);
  });

  test(
    'first start imports the full default catalog and reuses its cache',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final store = AppStore();
        await store.initialize();
        expect(store.error, isNull);
        expect(store.sourceURL, defaultURL);
        expect(store.plugins, hasLength(19));
        expect(store.plugins.last.id, 'source_18');
        final restarted = AppStore();
        await restarted.initialize();
        expect(restarted.plugins, hasLength(19));
        expect(requests, ['/default-index']);
        store.dispose();
        restarted.dispose();
      }, _Network());
    },
  );

  test(
    'an empty saved subscription adopts the default without clearing user data',
    () async {
      await File('${directory.path}/settings.json').writeAsString(
        jsonEncode({
          'sourceURL': '  ',
          'favorites': [
            {'roomId': 'fixture-room'},
          ],
          'history': [
            {'roomId': 'fixture-history'},
          ],
        }),
      );
      await HttpOverrides.runWithHttpOverrides(() async {
        final store = AppStore();
        await store.initialize();
        expect(store.error, isNull);
        expect(store.sourceURL, defaultURL);
        expect(store.plugins, hasLength(19));
        final saved = jsonDecode(
          await File('${directory.path}/settings.json').readAsString(),
        );
        expect(saved['favorites'].single['roomId'], 'fixture-room');
        expect(saved['history'].single['roomId'], 'fixture-history');
        store.dispose();
      }, _Network());
    },
  );

  test(
    'a saved custom subscription is preserved instead of the build default',
    () async {
      final customURL = 'http://127.0.0.1:${server.port}/custom-index';
      await File(
        '${directory.path}/settings.json',
      ).writeAsString(jsonEncode({'sourceURL': customURL}));
      await HttpOverrides.runWithHttpOverrides(() async {
        final store = AppStore();
        await store.initialize();
        expect(store.error, isNull);
        expect(store.sourceURL, customURL);
        expect(store.plugins, hasLength(2));
        expect(requests, ['/custom-index']);
        store.dispose();
      }, _Network());
    },
  );
}
