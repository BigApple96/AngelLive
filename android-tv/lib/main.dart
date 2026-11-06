import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'data.dart';
import 'runtime.dart';
import 'widgets.dart';
import 'player.dart';
import 'login.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  runApp(AngelTV(store: AppStore()));
}

class AngelTV extends StatelessWidget {
  final AppStore store;
  const AngelTV({super.key, required this.store});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Angel Live TV 兼容版',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorSchemeSeed: const Color(0xffb5abff),
      scaffoldBackgroundColor: const Color(0xff0c101c),
      textTheme: const TextTheme(
        bodyMedium: TextStyle(fontSize: 16),
        titleMedium: TextStyle(fontSize: 19),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(80, 46),
          padding: const EdgeInsets.symmetric(horizontal: 20),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(minimumSize: const Size(80, 46)),
      ),
    ),
    home: HomePage(store: store),
  );
}

class HomePage extends StatefulWidget {
  final AppStore store;
  final bool initialize;
  const HomePage({super.key, required this.store, this.initialize = true});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  AppStore get store => widget.store;
  bool ready = false;
  String? initializationError;
  int tab = 0;
  @override
  void initState() {
    super.initState();
    if (widget.initialize) {
      unawaited(load());
    } else {
      ready = true;
    }
  }

  Future<void> load() async {
    try {
      await store.initialize();
      if (mounted) {
        setState(() {
          ready = true;
          initializationError = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => initializationError = friendlyError(e));
    }
  }

  Future<void> open(PluginInfo info, [Map<String, dynamic>? room]) async {
    try {
      if (store.installed[info.id]?.version != info.version) {
        await store.install(info);
      }
      if (mounted) {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) =>
                BrowsePage(store: store, info: info, initialRoom: room),
          ),
        );
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> installAll() async {
    var failed = 0;
    for (final info in store.plugins.toList()) {
      if (store.installed[info.id]?.version == info.version) continue;
      try {
        await store.install(info);
      } catch (_) {
        failed++;
      }
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(failed == 0 ? '插件安装完成' : '其中 $failed 个插件失败，可单独重试'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: store,
    builder: (context, _) => Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 20, 28, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.live_tv_rounded,
                    color: Color(0xffc3bcff),
                    size: 32,
                  ),
                  const SizedBox(width: 12),
                  const Text(
                    'Angel Live TV',
                    style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(width: 10),
                  const Text(
                    'Android 兼容版',
                    style: TextStyle(color: Colors.white54, fontSize: 13),
                  ),
                  const Spacer(),
                  for (var i = 0; i < 4; i++)
                    Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: TextButton(
                        autofocus: i == 0,
                        onPressed: () => setState(() => tab = i),
                        style: TextButton.styleFrom(
                          backgroundColor: tab == i ? Colors.white12 : null,
                          minimumSize: const Size(64, 44),
                        ),
                        child: Text(
                          ['平台', '收藏', '历史', '设置'][i],
                          style: const TextStyle(fontSize: 16),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 20),
              if (store.busy) ...[
                Text(
                  store.progress,
                  style: const TextStyle(color: Color(0xffc3bcff)),
                ),
                const SizedBox(height: 8),
                const LinearProgressIndicator(),
                const SizedBox(height: 12),
              ],
              if (store.error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    store.error!,
                    style: const TextStyle(color: Color(0xffffbcbd)),
                  ),
                ),
              Expanded(
                child: initializationError != null
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(initializationError!),
                            const SizedBox(height: 16),
                            FilledButton(
                              onPressed: load,
                              child: const Text('重试'),
                            ),
                          ],
                        ),
                      )
                    : !ready
                    ? const Center(child: CircularProgressIndicator())
                    : tab == 3
                    ? settingsView()
                    : tab == 0
                    ? platforms()
                    : savedRooms(tab == 1 ? store.favorites : store.history),
              ),
              const SizedBox(height: 12),
              const Text(
                '方向键选择 · 确认键打开 · 返回键退出当前页面',
                style: TextStyle(fontSize: 12, color: Colors.white38),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  Widget platforms() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Text(
            '直播平台  ${store.plugins.length}',
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
          ),
          const Spacer(),
          OutlinedButton(
            onPressed: store.busy
                ? null
                : () => store.refreshSource(store.sourceURL),
            child: const Text('更新插件源'),
          ),
          const SizedBox(width: 10),
          FilledButton(
            onPressed: store.busy ? null : installAll,
            child: const Text('安装／更新全部'),
          ),
        ],
      ),
      const SizedBox(height: 16),
      Expanded(
        child: store.plugins.isEmpty
            ? const Center(child: Text('暂未载入平台，请到设置添加插件源'))
            : LayoutBuilder(
                builder: (context, constraints) => GridView.builder(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: constraints.maxWidth >= 850 ? 4 : 3,
                    mainAxisSpacing: 14,
                    crossAxisSpacing: 14,
                    mainAxisExtent: 128,
                  ),
                  itemCount: store.plugins.length,
                  itemBuilder: (_, index) {
                    final info = store.plugins[index];
                    final installed = store.installed[info.id];
                    return TvTile(
                      onPressed: store.busy ? null : () => open(info),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(
                                Icons.sensors,
                                color: Color(0xffc3bcff),
                              ),
                              const Spacer(),
                              Text(
                                installed == null
                                    ? '点击安装'
                                    : installed.version == info.version
                                    ? '已安装'
                                    : '可更新',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: installed == null
                                      ? Colors.white54
                                      : const Color(0xffa9dec5),
                                ),
                              ),
                            ],
                          ),
                          const Spacer(),
                          Text(
                            info.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'v${info.version}',
                            style: const TextStyle(
                              fontSize: 12,
                              color: Colors.white54,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
      ),
    ],
  );
  Widget savedRooms(List<Map<String, dynamic>> rooms) => rooms.isEmpty
      ? Center(
          child: Text(tab == 1 ? '还没有收藏。在播放页面选择“收藏”即可添加。' : '观看过的直播间会显示在这里。'),
        )
      : LayoutBuilder(
          builder: (_, size) => GridView.builder(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: size.maxWidth >= 850 ? 4 : 3,
              mainAxisSpacing: 14,
              crossAxisSpacing: 14,
              mainAxisExtent: 190,
            ),
            itemCount: rooms.length,
            itemBuilder: (_, i) => RoomTile(
              room: rooms[i],
              onPressed: () {
                final matches = store.plugins.where(
                  (p) => p.id == rooms[i]['pluginId'],
                );
                if (matches.isNotEmpty) {
                  unawaited(open(matches.first, rooms[i]));
                } else {
                  showError(context, Exception('当前插件源未提供这个平台'));
                }
              },
            ),
          ),
        );
  Widget settingsView() => ListView(
    children: [
      const Text(
        '插件源与设置',
        style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 16),
      TvTile(
        onPressed: () async {
          final url = await inputText(
            context,
            '插件源链接',
            initial: store.sourceURL,
            hint: 'https://…/plugins.json',
          );
          if (url != null && url.isNotEmpty) await store.refreshSource(url);
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('修改插件源'),
            const SizedBox(height: 8),
            Text(
              store.sourceURL,
              style: const TextStyle(color: Colors.white54, fontSize: 13),
            ),
          ],
        ),
      ),
      const SizedBox(height: 16),
      const Text('独立安卓 TV 兼容客户端 · 0.1.0', style: TextStyle(fontSize: 18)),
      const SizedBox(height: 8),
      const Text(
        '兼容 Angel Live 插件 API v1，非 Angel Live 官方安卓发行版。',
        style: TextStyle(color: Colors.white60),
      ),
      const SizedBox(height: 12),
      const Text(
        '平台需要登录时，在平台页面选择“账号”。账号数据由 Android Keystore 加密保存。',
        style: TextStyle(color: Colors.white60),
      ),
    ],
  );
}

class BrowsePage extends StatefulWidget {
  final AppStore store;
  final PluginInfo info;
  final Map<String, dynamic>? initialRoom;
  const BrowsePage({
    super.key,
    required this.store,
    required this.info,
    this.initialRoom,
  });
  @override
  State<BrowsePage> createState() => _BrowsePageState();
}

class _BrowsePageState extends State<BrowsePage> {
  PluginRuntime? runtime;
  List<Map<String, dynamic>> rooms = [];
  List<Map<String, dynamic>> categories = [];
  Map<String, dynamic> category = {};
  int page = 1;
  int generation = 0;
  String query = '';
  String? error;
  bool busy = true;
  @override
  void initState() {
    super.initState();
    unawaited(start());
  }

  @override
  void dispose() {
    generation++;
    if (runtime != null) unawaited(runtime!.dispose());
    super.dispose();
  }

  Future<void> start() async {
    try {
      final engine = PluginRuntime(
        widget.store,
        widget.store.installed[widget.info.id]!,
      );
      runtime = engine;
      await engine.open();
      if (!mounted) {
        await engine.dispose();
        return;
      }
      if (widget.initialRoom != null) {
        await watch(widget.initialRoom!);
        if (!mounted) return;
      }
      await loadCategories();
    } catch (e) {
      if (mounted) {
        setState(() {
          busy = false;
          error = friendlyError(e);
        });
      }
    }
  }

  Future<void> loadCategories() async {
    try {
      if (runtime!.methods.contains('getCategories')) {
        categories = categoryList(await runtime!.call('getCategories', {}));
      }
      category = categories.isNotEmpty ? categories.first : {};
      await loadRooms();
    } catch (e) {
      if (mounted) {
        setState(() {
          busy = false;
          error = friendlyError(e);
        });
      }
    }
  }

  Future<void> loadRooms({bool append = false}) async {
    final token = ++generation;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final result = query.isNotEmpty
          ? await runtime!.call('search', {
              'keyword': query,
              'page': page,
              'pageSize': 32,
            })
          : await runtime!.call('getRooms', {
              'id': category['id'] ?? '',
              'parentId': category['parentId'] ?? '',
              'page': page,
              'pageSize': 32,
            });
      if (!mounted || token != generation) return;
      final next = roomList(result);
      setState(() {
        rooms = append
            ? [
                ...rooms,
                ...next.where(
                  (r) => !rooms.any((old) => old['roomId'] == r['roomId']),
                ),
              ]
            : next;
        busy = false;
      });
    } catch (e) {
      if (mounted && token == generation) {
        setState(() {
          busy = false;
          error = friendlyError(e);
        });
      }
    }
  }

  Future<void> watch(Map<String, dynamic> room) async {
    if (!mounted || runtime == null || runtime!.closed) return;
    await widget.store.addHistory(widget.info.id, room);
    if (mounted) {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => WatchPage(
            store: widget.store,
            info: widget.info,
            runtime: runtime!,
            room: room,
          ),
        ),
      );
    }
  }

  Future<void> pickCategory() async {
    final chosen = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('选择分类'),
        children: categories
            .map(
              (c) => SimpleDialogOption(
                onPressed: () => Navigator.pop(context, c),
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(string(c['name'] ?? c['title'] ?? c['id'])),
                ),
              ),
            )
            .toList(),
      ),
    );
    if (chosen != null && mounted) {
      category = chosen;
      page = 1;
      query = '';
      await loadRooms();
    }
  }

  Future<void> directRoom() async {
    final input = await inputText(context, '输入房间号或直播分享链接');
    if (input == null || input.isEmpty || !mounted) return;
    try {
      dynamic result;
      if (input.contains('http') && runtime!.methods.contains('resolveShare')) {
        result = await runtime!.call('resolveShare', {'shareCode': input});
      } else if (runtime!.methods.contains('getRoomDetail')) {
        result = await runtime!.call('getRoomDetail', {'roomId': input});
      } else {
        result = {'roomId': input, 'roomTitle': input};
      }
      final room = object(result);
      if (string(room['roomId']).isEmpty) throw Exception('未能识别直播间');
      await watch(room);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                IconButton(
                  autofocus: true,
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.arrow_back),
                ),
                const SizedBox(width: 8),
                Text(
                  widget.info.name,
                  style: const TextStyle(
                    fontSize: 25,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                OutlinedButton(
                  onPressed: runtime == null || runtime!.methods.isEmpty
                      ? null
                      : () async {
                          await Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => AccountPage(
                                runtime: runtime!,
                                info: widget.info,
                              ),
                            ),
                          );
                          if (mounted) {
                            page = 1;
                            await loadCategories();
                          }
                        },
                  child: const Text('账号'),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: runtime == null || runtime!.methods.isEmpty
                      ? null
                      : directRoom,
                  child: const Text('房间号／链接'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed:
                      runtime == null || !runtime!.methods.contains('search')
                      ? null
                      : () async {
                          final value = await inputText(
                            context,
                            '搜索主播或直播间',
                            initial: query,
                          );
                          if (value != null && mounted) {
                            query = value;
                            page = 1;
                            await loadRooms();
                          }
                        },
                  child: const Text('搜索'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                OutlinedButton(
                  onPressed: categories.isEmpty || busy ? null : pickCategory,
                  child: Text(
                    query.isNotEmpty
                        ? '搜索：$query'
                        : string(category['name'] ?? category['title']).isEmpty
                        ? '全部分类'
                        : string(category['name'] ?? category['title']),
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  '${rooms.length} 个直播间',
                  style: const TextStyle(color: Colors.white54),
                ),
                const Spacer(),
                TextButton(
                  onPressed: busy || runtime == null || runtime!.methods.isEmpty
                      ? null
                      : () {
                          page = 1;
                          unawaited(loadRooms());
                        },
                  child: const Text('刷新'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (busy) const LinearProgressIndicator(),
            if (error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  error!,
                  style: const TextStyle(color: Color(0xffffb6ba)),
                ),
              ),
            Expanded(
              child: rooms.isEmpty
                  ? Center(
                      child: Text(
                        busy
                            ? '正在加载直播间…'
                            : error == null
                            ? '暂无直播间，可以更换分类、搜索或输入房间号。'
                            : '可重试刷新；需要登录的平台请先选择“账号”。',
                        style: const TextStyle(color: Colors.white60),
                      ),
                    )
                  : LayoutBuilder(
                      builder: (_, size) => GridView.builder(
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: size.maxWidth >= 850 ? 4 : 3,
                          mainAxisSpacing: 14,
                          crossAxisSpacing: 14,
                          mainAxisExtent: 190,
                        ),
                        itemCount: rooms.length + 1,
                        itemBuilder: (_, i) => i == rooms.length
                            ? TvTile(
                                onPressed: busy
                                    ? null
                                    : () {
                                        page++;
                                        unawaited(loadRooms(append: true));
                                      },
                                child: const Center(child: Text('加载更多')),
                              )
                            : RoomTile(
                                room: rooms[i],
                                onPressed: () => watch(rooms[i]),
                              ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    ),
  );
}
