import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:angel_live_android_tv/data.dart';
import 'package:angel_live_android_tv/main.dart';

void main() {
  testWidgets(
    'TV home fits 960x540 and D-pad reaches platforms below the fold',
    (tester) async {
      final qaFont = Platform.environment['TV_QA_FONT'];
      if (qaFont != null) {
        await tester.runAsync(() async {
          final loader = FontLoader('TV-QA')
            ..addFont(
              Future.value(
                ByteData.sublistView(await File(qaFont).readAsBytes()),
              ),
            );
          await loader.load();
          final icons = FontLoader('MaterialIcons')
            ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
          await icons.load();
        });
      }
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = AppStore()
        ..plugins = List.generate(
          19,
          (i) => PluginInfo({
            'pluginId': 'fixture_$i',
            'platformName': '平台 ${i + 1}',
            'version': '1.0.0',
          }),
        );
      final qaIndex = Platform.environment['TV_QA_INDEX'];
      if (qaIndex != null) {
        store.plugins = array(
          object(jsonDecode(File(qaIndex).readAsStringSync()))['plugins'],
        ).map((v) => PluginInfo(object(v))).toList();
      }
      final boundaryKey = GlobalKey();
      Future<void> snapshot(String name) async {
        final dir = Platform.environment['TV_QA_DIR'];
        if (dir == null) return;
        await tester.runAsync(() async {
          final boundary =
              boundaryKey.currentContext!.findRenderObject()
                  as RenderRepaintBoundary;
          final picture = await boundary.toImage(pixelRatio: 2);
          final bytes = await picture.toByteData(
            format: ui.ImageByteFormat.png,
          );
          await Directory(dir).create(recursive: true);
          await File(
            '$dir/$name.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          picture.dispose();
        });
      }

      await tester.pumpWidget(
        RepaintBoundary(
          key: boundaryKey,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData.dark(useMaterial3: true).copyWith(
              textTheme: ThemeData.dark().textTheme.apply(
                fontFamily: qaFont == null ? null : 'TV-QA',
              ),
            ),
            home: HomePage(store: store, initialize: false),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await snapshot('home');
      for (var i = 0; i < 8; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
      }
      expect(tester.takeException(), isNull);
      final scrollable = tester.state<ScrollableState>(
        find.byType(Scrollable).first,
      );
      expect(scrollable.position.pixels, greaterThan(0));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await snapshot('settings');
    },
  );
}
