import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'data.dart';
import 'runtime.dart';

class WatchPage extends StatefulWidget {
  final AppStore store;
  final PluginInfo info;
  final PluginRuntime runtime;
  final Map<String, dynamic> room;
  const WatchPage({
    super.key,
    required this.store,
    required this.info,
    required this.runtime,
    required this.room,
  });
  @override
  State<WatchPage> createState() => _WatchPageState();
}

class _WatchPageState extends State<WatchPage> with WidgetsBindingObserver {
  late final Player player;
  late final VideoController video;
  final List<StreamSubscription<dynamic>> subscriptions = [];
  List<PlaybackSource> sources = [];
  PlaybackSource? selected;
  Timer? watchdog;
  Timer? hideTimer;
  DateTime? bufferingSince;
  DateTime? playingSince;
  bool loading = true;
  bool controls = true;
  bool recovering = false;
  bool released = false;
  int attempts = 0;
  int generation = 0;
  String? error;
  Map<String, dynamic> get roomPayload => {
    'roomId': string(widget.room['roomId']),
    'userId': string(widget.room['userId']),
  };
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    player = Player(
      configuration: const PlayerConfiguration(bufferSize: 32 * 1024 * 1024),
    );
    video = VideoController(player);
    subscriptions.add(
      player.stream.buffering.listen((value) {
        if (!mounted) return;
        if (value) {
          bufferingSince ??= DateTime.now();
          playingSince = null;
        } else {
          bufferingSince = null;
          playingSince ??= DateTime.now();
        }
        setState(() {});
      }),
    );
    subscriptions.add(
      player.stream.playing.listen((_) {
        if (mounted) setState(() {});
      }),
    );
    subscriptions.add(
      player.stream.error.listen((message) {
        if (mounted && !player.state.playing && !loading && !recovering) {
          unawaited(reconnect());
        }
      }),
    );
    subscriptions.add(
      player.stream.completed.listen((done) {
        if (done && mounted && !loading) unawaited(reconnect());
      }),
    );
    watchdog = Timer.periodic(const Duration(seconds: 5), (_) {
      if (bufferingSince != null &&
          DateTime.now().difference(bufferingSince!).inSeconds >= 25 &&
          !loading) {
        unawaited(reconnect());
      }
      if (playingSince != null &&
          player.state.playing &&
          !player.state.buffering &&
          DateTime.now().difference(playingSince!).inSeconds >= 30) {
        attempts = 0;
      }
    });

    unawaited(load());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      unawaited(player.pause());
    }
    if (state == AppLifecycleState.resumed && !released) {
      unawaited(reconnect(manual: true));
    }
  }

  @override
  void dispose() {
    released = true;
    generation++;
    WidgetsBinding.instance.removeObserver(this);
    watchdog?.cancel();
    hideTimer?.cancel();
    for (final subscription in subscriptions) {
      unawaited(subscription.cancel());
    }
    unawaited(player.dispose());
    super.dispose();
  }

  void showControls() {
    if (!mounted) return;
    setState(() => controls = true);
    hideTimer?.cancel();
    hideTimer = Timer(const Duration(seconds: 7), () {
      if (mounted && error == null && !loading) {
        setState(() => controls = false);
      }
    });
  }

  Future<void> load({bool recovery = false}) async {
    final token = ++generation;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final context = <String, dynamic>{...roomPayload};
      if (recovery && selected != null) {
        context.addAll(
          Map.fromEntries(
            selected!.selection.entries.where((e) => !e.key.startsWith('_')),
          ),
        );
      }
      final result = await widget.runtime.call('getPlayback', context);
      final next = playbackSources(result);
      if (next.isEmpty) {
        throw Exception('没有取得可播放地址。此内容可能需要登录，或使用了当前版本尚不支持的播放格式。');
      }
      if (!mounted || token != generation) return;
      sources = next;
      final same = selected == null
          ? <PlaybackSource>[]
          : next.where((s) => s.name == selected!.name).toList();
      final moderate = next
          .where((s) => RegExp(r'720|高清|超清').hasMatch(s.name))
          .toList();
      await play(
        same.isNotEmpty
            ? same.first
            : moderate.isNotEmpty
            ? moderate.first
            : next.first,
        token: token,
      );
    } catch (e) {
      if (mounted && token == generation) {
        setState(() {
          error = friendlyError(e);
          loading = false;
          controls = true;
        });
      }
    }
  }

  Future<void> play(
    PlaybackSource source, {
    int? token,
    bool switching = false,
  }) async {
    final current = token ?? ++generation;
    if (switching) {
      setState(() {
        loading = true;
        error = null;
      });
    }
    try {
      var target = source;
      if (source.refresh &&
          widget.runtime.methods.contains('refreshPlayback')) {
        final fresh = await widget.runtime.call('refreshPlayback', {
          ...roomPayload,
          'cdn': source.selection['_cdn'] ?? {},
          'quality': source.selection['_quality'] ?? {},
        });
        final candidates = playbackSources(fresh);
        if (candidates.isEmpty) {
          throw Exception('刷新该清晰度时没有取得播放地址，请换一条线路');
        }
        target = candidates.first;
      }
      if (!mounted || current != generation) return;
      selected = PlaybackSource(
        target.url,
        source.name,
        {...source.headers, ...target.headers},
        source.selection,
        source.refresh,
      );
      bufferingSince = DateTime.now();
      playingSince = null;
      await player.open(Media(target.url, httpHeaders: selected!.headers));
      if (!mounted || current != generation) return;
      setState(() {
        loading = false;
        error = null;
      });
      showControls();
    } catch (e) {
      if (mounted && current == generation) {
        setState(() {
          error = friendlyError(e);
          loading = false;
          controls = true;
        });
      }
    }
  }

  Future<void> reconnect({bool manual = false}) async {
    if (recovering || released || !mounted) return;
    if (manual) attempts = 0;
    if (attempts >= 3) {
      setState(() {
        error = '连接多次中断。可换一条线路，或稍后选择“重试”。';
        controls = true;
      });
      return;
    }
    recovering = true;
    attempts++;
    try {
      await load(recovery: true);
    } finally {
      recovering = false;
    }
  }

  Future<void> pickSource() async {
    hideTimer?.cancel();
    final source = await showDialog<PlaybackSource>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('清晰度与线路'),
        children: sources
            .map(
              (s) => SimpleDialogOption(
                onPressed: () => Navigator.pop(context, s),
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(
                    '${selected?.name == s.name ? '✓  ' : ''}${s.name}',
                  ),
                ),
              ),
            )
            .toList(),
      ),
    );
    if (source != null && mounted) await play(source, switching: true);
    showControls();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    body: Focus(
      onKeyEvent: (_, event) {
        if (event is KeyDownEvent &&
            [
              LogicalKeyboardKey.mediaPlayPause,
              LogicalKeyboardKey.mediaPlay,
              LogicalKeyboardKey.mediaPause,
            ].contains(event.logicalKey)) {
          unawaited(
            event.logicalKey == LogicalKeyboardKey.mediaPlay
                ? player.play()
                : event.logicalKey == LogicalKeyboardKey.mediaPause
                ? player.pause()
                : player.playOrPause(),
          );
          showControls();
          return KeyEventResult.handled;
        }
        if (event is KeyDownEvent &&
            !controls &&
            [
              LogicalKeyboardKey.arrowUp,
              LogicalKeyboardKey.arrowDown,
              LogicalKeyboardKey.arrowLeft,
              LogicalKeyboardKey.arrowRight,
              LogicalKeyboardKey.select,
              LogicalKeyboardKey.enter,
            ].contains(event.logicalKey)) {
          showControls();
          return KeyEventResult.handled;
        }
        if (event is KeyDownEvent && controls) showControls();
        return KeyEventResult.ignored;
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          Video(controller: video, controls: NoVideoControls),
          if (loading || player.state.buffering)
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 16),
                  Text(
                    recovering
                        ? '正在重新获取直播地址…'
                        : loading
                        ? '正在打开直播…'
                        : '正在缓冲…',
                    style: const TextStyle(color: Colors.white70),
                  ),
                ],
              ),
            ),
          if (error != null)
            Center(
              child: Container(
                constraints: const BoxConstraints(maxWidth: 620),
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: const Color(0xee191c2a),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Text(
                  error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 18),
                ),
              ),
            ),
          if (controls)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Container(
                padding: const EdgeInsets.all(28),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.black87, Colors.transparent],
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      string(widget.room['roomTitle']),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${widget.info.name} · ${string(widget.room['userName'])}',
                      style: const TextStyle(color: Colors.white70),
                    ),
                  ],
                ),
              ),
            ),
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: AnimatedOpacity(
              opacity: controls ? 1 : 0,
              duration: const Duration(milliseconds: 160),
              child: Container(
                padding: const EdgeInsets.fromLTRB(28, 30, 28, 24),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [Colors.black, Colors.transparent],
                  ),
                ),
                child: Row(
                  children: [
                    FilledButton(
                      autofocus: true,
                      onPressed: () {
                        unawaited(player.playOrPause());
                        showControls();
                      },
                      child: Text(player.state.playing ? '暂停' : '播放'),
                    ),
                    const SizedBox(width: 12),
                    OutlinedButton(
                      onPressed: sources.isEmpty ? null : pickSource,
                      child: const Text('清晰度／线路'),
                    ),
                    const SizedBox(width: 12),
                    OutlinedButton(
                      onPressed: loading ? null : () => reconnect(manual: true),
                      child: const Text('重试'),
                    ),
                    const SizedBox(width: 12),
                    OutlinedButton(
                      onPressed: () async {
                        await widget.store.toggleFavorite(
                          widget.info.id,
                          widget.room,
                        );
                        if (mounted) setState(() {});
                        showControls();
                      },
                      child: Text(
                        widget.store.isFavorite(widget.info.id, widget.room)
                            ? '已收藏'
                            : '收藏',
                      ),
                    ),
                    const Spacer(),
                    Flexible(
                      child: Text(
                        selected?.name ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
