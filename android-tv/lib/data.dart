import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

Map<String, dynamic> object(dynamic v) =>
    v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
List<dynamic> array(dynamic v) => v is List ? v : <dynamic>[];
String string(dynamic v) => v == null ? '' : '$v';
String friendlyError(Object error) {
  var text = error.toString().replaceFirst('Exception: ', '');
  final marker = text.indexOf('LP_PLUGIN_ERROR:');
  if (marker >= 0) {
    try {
      text = string(object(jsonDecode(text.substring(marker + 16)))['message']);
    } catch (_) {}
  }
  text = text.replaceAll(RegExp(r'https?://[^\s\)]+'), '网络接口');
  return text.length > 240 ? '${text.substring(0, 240)}…' : text;
}

const native = MethodChannel('angel_tv/runtime');

Future<List<int>> downloadBytes(
  Uri uri, {
  int maxBytes = 32 * 1024 * 1024,
}) async {
  if (!['https', 'http'].contains(uri.scheme) || uri.host.isEmpty) {
    throw Exception('地址必须为 HTTP 或 HTTPS 链接');
  }
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    final request = await client
        .getUrl(uri)
        .timeout(const Duration(seconds: 20));
    request.headers.set('User-Agent', 'AngelLiveAndroidTV/0.1');
    final response = await request.close().timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      throw Exception('下载失败：HTTP ${response.statusCode}');
    }
    final bytes = <int>[];
    await for (final part in response.timeout(const Duration(seconds: 30))) {
      bytes.addAll(part);
      if (bytes.length > maxBytes) throw Exception('下载文件超过大小限制');
    }
    return bytes;
  } finally {
    client.close(force: true);
  }
}

String safeRelativePath(String input) {
  if (input.isEmpty ||
      input.contains('\\') ||
      input.contains(':') ||
      input.startsWith('/') ||
      input.split('/').contains('..')) {
    throw const FormatException('插件文件路径无效');
  }
  return input;
}

class PluginInfo {
  final Map<String, dynamic> raw;
  PluginInfo(this.raw);
  String get id => string(raw['pluginId']);
  String get version => string(raw['version']);
  String get name =>
      string(raw['platformName']).isNotEmpty ? string(raw['platformName']) : id;
  String get icon => string(raw['icon']);
  String get description => string(raw['platformDescription']);
  String get url => string(raw['zipURL']);
  String get digest => string(raw['sha256']).toLowerCase();
  Map<String, dynamic> capability(String name) =>
      object(object(raw['capabilities'])[name]);
}

class InstalledPlugin {
  final Directory directory;
  final Map<String, dynamic> manifest;
  InstalledPlugin(this.directory, this.manifest);
  String get id => string(manifest['pluginId']);
  String get version => string(manifest['version']);
  Future<List<String>> scripts() async {
    final names = [
      ...array(manifest['preloadScripts']).map(string),
      string(manifest['entry']),
    ];
    return Future.wait(
      names.map(
        (name) =>
            File(p.join(directory.path, safeRelativePath(name))).readAsString(),
      ),
    );
  }
}

class AppStore extends ChangeNotifier {
  late Directory root;
  Map<String, dynamic> settings = {};
  List<PluginInfo> plugins = [];
  final Map<String, InstalledPlugin> installed = {};
  final Map<String, Map<String, dynamic>> sessions = {};
  List<Map<String, dynamic>> favorites = [];
  List<Map<String, dynamic>> history = [];
  String sourceURL = '';
  String sourceName = '';
  String? error;
  String progress = '';
  bool busy = false;
  Future<void> _saveQueue = Future.value();
  final Set<String> _loadedSessions = {};

  Future<void> _readSession(String id) async {
    if (!_loadedSessions.add(id)) return;
    try {
      final encoded = await native.invokeMethod<String>('vault.read', {
        'key': 'session:$id',
      });
      if (encoded?.isNotEmpty == true) {
        sessions[id] = object(jsonDecode(encoded!));
      }
    } catch (_) {
      error = '部分账号数据无法读取，请重新登录';
    }
  }

  Future<void> initialize() async {
    root = await getApplicationSupportDirectory();
    await root.create(recursive: true);
    final file = File(p.join(root.path, 'settings.json'));
    if (await file.exists()) {
      try {
        settings = object(jsonDecode(await file.readAsString()));
      } catch (_) {
        error = '设置文件读取失败，已使用默认设置';
      }
    }
    final defaults = object(
      jsonDecode(await rootBundle.loadString('assets/bootstrap.json')),
    );
    final savedSourceURL = string(settings['sourceURL']).trim();
    sourceURL = savedSourceURL.isNotEmpty
        ? savedSourceURL
        : string(defaults['sourceURL']).trim();
    favorites = array(settings['favorites']).map(object).toList();
    history = array(settings['history']).map(object).toList();
    final cached = object(settings['index']);
    plugins = array(
      cached['plugins'],
    ).map((v) => PluginInfo(object(v))).toList();
    sourceName = string(cached['sourceName']);
    for (final info in plugins) {
      await _readInstalled(info.id);
      await _readSession(info.id);
    }
    notifyListeners();
    if (plugins.isEmpty) await refreshSource(sourceURL);
  }

  Future<void> save() async {
    settings['sourceURL'] = sourceURL;
    settings['favorites'] = favorites;
    settings['history'] = history.take(100).toList();
    final snapshot = jsonEncode(settings);
    final operation = _saveQueue.then((_) async {
      final file = File(p.join(root.path, 'settings.json'));
      final temp = File('${file.path}.tmp');
      await temp.writeAsString(snapshot, flush: true);
      await temp.rename(file.path);
    });
    _saveQueue = operation.catchError((Object _) {});
    await operation;
    notifyListeners();
  }

  Future<void> refreshSource(String url) async {
    if (busy) return;
    busy = true;
    error = null;
    progress = '正在更新插件源…';
    notifyListeners();
    try {
      final index = object(
        jsonDecode(
          utf8.decode(
            await downloadBytes(
              Uri.parse(url.trim()),
              maxBytes: 4 * 1024 * 1024,
            ),
          ),
        ),
      );
      if (index['apiVersion'] != 1 || index['plugins'] is! List) {
        throw Exception('插件源协议不受支持');
      }
      final next = array(
        index['plugins'],
      ).map((v) => PluginInfo(object(v))).toList();
      final ids = <String>{};
      for (final item in next) {
        if (!RegExp(r'^[a-zA-Z0-9_.-]{1,100}$').hasMatch(item.id) ||
            !ids.add(item.id)) {
          throw Exception('插件编号无效或重复');
        }
      }
      sourceURL = url.trim();
      settings['index'] = index;
      sourceName = string(index['sourceName']);
      plugins = next;
      for (final info in plugins) {
        await _readInstalled(info.id);
        await _readSession(info.id);
      }
      await save();
    } catch (e) {
      error = friendlyError(e);
    } finally {
      busy = false;
      progress = '';
      notifyListeners();
    }
  }

  Future<void> _readInstalled(String id) async {
    final dir = Directory(p.join(root.path, 'plugins', id));
    final file = File(p.join(dir.path, 'manifest.json'));
    if (await file.exists()) {
      try {
        installed[id] = InstalledPlugin(
          dir,
          object(jsonDecode(await file.readAsString())),
        );
      } catch (_) {}
    }
  }

  Future<void> install(PluginInfo plugin) async {
    if (busy) throw Exception('请等待当前下载完成');
    busy = true;
    error = null;
    progress = '正在安装 ${plugin.name}…';
    notifyListeners();
    Directory? staging;
    try {
      final bytes = await downloadBytes(Uri.parse(plugin.url));
      if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(plugin.digest) ||
          sha256.convert(bytes).toString() != plugin.digest) {
        throw Exception('插件校验失败，未安装');
      }
      final archive = ZipDecoder().decodeBytes(bytes, verify: true);
      var total = 0;
      for (final entry in archive) {
        safeRelativePath(entry.name);
        total += entry.size;
        if (total > 80 * 1024 * 1024 || entry.isSymbolicLink) {
          throw Exception('插件包内容不受支持');
        }
      }
      final manifests = archive
          .where(
            (f) =>
                f.isFile &&
                (f.name == 'manifest.json' ||
                    f.name.endsWith('/manifest.json')),
          )
          .toList();
      if (manifests.length != 1) throw Exception('插件包的清单不唯一');
      final manifestFile = manifests.single;
      final manifest = object(jsonDecode(utf8.decode(manifestFile.content)));
      if (manifest['pluginId'] != plugin.id ||
          manifest['version'] != plugin.version ||
          manifest['apiVersion'] != 1) {
        throw Exception('插件包版本或协议不匹配');
      }
      final prefix = manifestFile.name == 'manifest.json'
          ? ''
          : manifestFile.name.substring(0, manifestFile.name.length - 13);
      staging = Directory(
        p.join(
          root.path,
          'staging',
          '${plugin.id}-${DateTime.now().microsecondsSinceEpoch}',
        ),
      );
      await staging.create(recursive: true);
      for (final entry in archive) {
        if (!entry.isFile || !entry.name.startsWith(prefix)) continue;
        final name = safeRelativePath(entry.name.substring(prefix.length));
        final out = File(p.join(staging.path, name));
        await out.parent.create(recursive: true);
        await out.writeAsBytes(entry.content);
      }
      for (final name in [
        ...array(manifest['preloadScripts']).map(string),
        string(manifest['entry']),
      ]) {
        if (!await File(
          p.join(staging.path, safeRelativePath(name)),
        ).exists()) {
          throw Exception('插件脚本缺失');
        }
      }
      final target = Directory(p.join(root.path, 'plugins', plugin.id));
      await target.parent.create(recursive: true);
      final backup = Directory('${target.path}.previous');
      if (await backup.exists()) await backup.delete(recursive: true);
      if (await target.exists()) await target.rename(backup.path);
      try {
        await staging.rename(target.path);
      } catch (_) {
        if (await backup.exists()) await backup.rename(target.path);
        rethrow;
      }
      installed[plugin.id] = InstalledPlugin(target, manifest);
      await save();
    } catch (e) {
      error = friendlyError(e);
      rethrow;
    } finally {
      if (staging != null && await staging.exists()) {
        await staging.delete(recursive: true);
      }
      busy = false;
      progress = '';
      notifyListeners();
    }
  }

  Future<void> setSession(String pluginId, Map<String, dynamic> session) async {
    await native.invokeMethod('vault.write', {
      'key': 'session:$pluginId',
      'value': jsonEncode(session),
    });
    sessions[pluginId] = session;
    notifyListeners();
  }

  String cookie(String pluginId) => string(sessions[pluginId]?['cookie']);
  bool isFavorite(String pluginId, Map<String, dynamic> room) => favorites.any(
    (r) =>
        r['pluginId'] == pluginId &&
        string(r['roomId']) == string(room['roomId']),
  );
  Future<void> toggleFavorite(
    String pluginId,
    Map<String, dynamic> room,
  ) async {
    if (isFavorite(pluginId, room)) {
      favorites.removeWhere(
        (r) =>
            r['pluginId'] == pluginId &&
            string(r['roomId']) == string(room['roomId']),
      );
    } else {
      favorites.insert(0, {...room, 'pluginId': pluginId});
    }
    await save();
  }

  Future<void> addHistory(String pluginId, Map<String, dynamic> room) async {
    history.removeWhere(
      (r) =>
          r['pluginId'] == pluginId &&
          string(r['roomId']) == string(room['roomId']),
    );
    history.insert(0, {...room, 'pluginId': pluginId});
    await save();
  }
}

List<Map<String, dynamic>> roomList(dynamic value) {
  if (value is List) {
    return value
        .map(object)
        .where((r) => string(r['roomId']).isNotEmpty)
        .toList();
  }
  final map = object(value);
  for (final key in ['rooms', 'list', 'items', 'data', 'results']) {
    if (map[key] is List || map[key] is Map) {
      final found = roomList(map[key]);
      if (found.isNotEmpty) return found;
    }
  }
  return [];
}

List<Map<String, dynamic>> categoryList(dynamic value) {
  if (value is! List) {
    final m = object(value);
    return categoryList(m['categories'] ?? m['list'] ?? m['data'] ?? []);
  }
  final result = <Map<String, dynamic>>[];
  for (final item in value) {
    final map = object(item);
    final children = array(
      map['subList'] ?? map['children'] ?? map['subCategories'],
    );
    if (children.isEmpty) {
      result.add(map);
    } else {
      for (final child in children) {
        result.add({...object(child), 'parentId': map['id']});
      }
    }
  }
  return result;
}

class PlaybackSource {
  final String url;
  final String name;
  final Map<String, String> headers;
  final Map<String, dynamic> selection;
  final bool refresh;
  PlaybackSource(
    this.url,
    this.name,
    this.headers,
    this.selection,
    this.refresh,
  );
}

List<PlaybackSource> playbackSources(dynamic input) {
  final sources = <PlaybackSource>[];
  void visit(
    dynamic value,
    String label,
    Map<String, String> headers,
    Map<String, dynamic> selection,
  ) {
    if (value is List) {
      for (final child in value) {
        visit(child, label, headers, selection);
      }
      return;
    }
    if (value is! Map) return;
    final map = object(value);
    final inherited = {...headers};
    for (final key in ['headers', 'httpHeaders', 'requestHeaders']) {
      object(map[key]).forEach((k, v) {
        inherited[k] = string(v);
      });
    }
    final title = string(
      map['title'] ??
          map['name'] ??
          map['qualityName'] ??
          map['cdnName'] ??
          map['displayName'] ??
          (map['cdn'] is String ? map['cdn'] : null),
    );
    final nextLabel = title.isEmpty
        ? label
        : (label.isEmpty ? title : '$label · $title');
    final nextSelection = {...selection};
    if (map['qualitys'] is List) nextSelection['_cdn'] = map;
    for (final key in [
      'rate',
      'cdn',
      'lineSeq',
      'gear',
      'quality',
      'qn',
      'bitRate',
      'codec',
      'qualityCode',
      'selection',
      'userId',
    ]) {
      if (map.containsKey(key)) nextSelection[key] = map[key];
    }
    nextSelection.addAll(object(map['requestContext']));
    if (string(map['userAgent']).isNotEmpty) {
      inherited['User-Agent'] = string(map['userAgent']);
    }
    final url = string(map['url'] ?? map['playUrl'] ?? map['playURL']);
    if (url.startsWith('https://') || url.startsWith('http://')) {
      if (map['decryption'] != null) return;
      if (!sources.any((s) => s.url == url && s.name == nextLabel)) {
        sources.add(
          PlaybackSource(
            url,
            nextLabel.isEmpty ? '默认线路' : nextLabel,
            inherited,
            {...nextSelection, '_quality': map},
            map['refreshOnSelect'] == true ||
                object(map['playbackHints'])['selectionBehavior'] ==
                    'refreshOnSelect',
          ),
        );
      }
    }
    for (final entry in map.entries) {
      if ([
        'headers',
        'httpHeaders',
        'requestHeaders',
        'decryption',
      ].contains(entry.key)) {
        continue;
      }
      if (entry.value is List || entry.value is Map) {
        visit(entry.value, nextLabel, inherited, nextSelection);
      }
    }
  }

  visit(input, '', {}, {});
  return sources;
}
