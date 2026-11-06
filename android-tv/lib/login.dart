import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'data.dart';
import 'runtime.dart';
import 'widgets.dart';

class AccountPage extends StatefulWidget {
  final PluginRuntime runtime;
  final PluginInfo info;
  const AccountPage({super.key, required this.runtime, required this.info});
  @override
  State<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends State<AccountPage> {
  PluginRuntime get runtime => widget.runtime;
  bool busy = false;
  String message = '';
  Map<String, dynamic> challenge = {};
  Map<String, dynamic> verification = {};
  String transactionId = '';
  Timer? timer;
  DateTime? expires;
  int generation = 0;
  Map<String, dynamic> get protocol =>
      object(runtime.plugin.manifest['loginChallenge']);
  Map<String, dynamic> get functions => object(protocol['functions']);
  bool get canCookie => array(
    object(runtime.plugin.manifest['auth'])['credentialKinds'],
  ).contains('cookie');
  bool get canQR =>
      protocol['kind'] == 'qrcode' &&
      runtime.methods.contains(string(functions['create']));
  @override
  void dispose() {
    generation++;
    timer?.cancel();
    unawaited(cancel());
    super.dispose();
  }

  Future<void> cancel() async {
    final id = transactionId;
    final code = challenge['challengeId'];
    if (id.isNotEmpty && code != null && !runtime.closed) {
      try {
        await runtime.call(string(functions['cancel']), {
          'transactionId': id,
          'challengeId': code,
        }, timeout: const Duration(seconds: 8));
      } catch (_) {}
    }
    if (id.isNotEmpty) runtime.clearTransaction(id);
  }

  Future<void> saveSession(Map<String, dynamic> candidate) async {
    if (string(candidate['cookie']).isEmpty) {
      throw Exception('登录接口未返回有效会话，请重试或导入 Cookie');
    }
    final previous = {...?runtime.store.sessions[widget.info.id]};
    try {
      await runtime.updateSession(candidate);
      if (runtime.methods.contains('validateCredential')) {
        final result = object(
          await runtime.call('validateCredential', {
            'credentialAvailable': true,
          }),
        );
        if (result['valid'] == false ||
            result['isValid'] == false ||
            result['authenticated'] == false ||
            result['success'] == false) {
          throw Exception('账号校验未通过');
        }
        final uid = result['uid'] ?? result['userId'] ?? candidate['uid'];
        await runtime.updateSession({
          ...candidate,
          if (uid != null) 'uid': uid,
        });
      }
    } catch (_) {
      await runtime.updateSession(previous);
      rethrow;
    }
  }

  Future<void> importCookie() async {
    final cookie = await inputText(
      context,
      '导入本平台 Cookie',
      hint: '仅保存在电视本机，输入内容会隐藏',
      secret: true,
    );
    if (cookie == null || cookie.isEmpty || !mounted) return;
    setState(() {
      busy = true;
      message = '正在校验账号…';
    });
    try {
      await saveSession({'cookie': cookie});
      if (mounted) setState(() => message = '账号已保存');
    } catch (e) {
      if (mounted) setState(() => message = friendlyError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> beginQR() async {
    timer?.cancel();
    final token = ++generation;
    await cancel();
    if (!mounted) return;
    transactionId = DateTime.now().microsecondsSinceEpoch.toString();
    challenge = {};
    verification = {};
    setState(() {
      busy = true;
      message = '正在创建二维码…';
    });
    try {
      final result = object(
        await runtime.call(string(functions['create']), {
          'transactionId': transactionId,
        }),
      );
      if (!mounted || token != generation) return;
      if ((string(result['qrContent']).isEmpty &&
              string(result['qrImage']).isEmpty) ||
          string(result['challengeId']).isEmpty) {
        throw Exception('插件没有返回有效的二维码');
      }
      challenge = result;
      final timeout =
          num.tryParse(string(protocol['timeoutSeconds']))?.toInt() ?? 180;
      expires = DateTime.now().add(Duration(seconds: timeout.clamp(30, 600)));
      setState(() {
        busy = false;
        message = string(result['hint']).isEmpty
            ? string(protocol['hint'])
            : string(result['hint']);
      });
      schedulePoll(token);
    } catch (e) {
      if (mounted && token == generation) {
        setState(() {
          busy = false;
          message = friendlyError(e);
        });
      }
    }
  }

  void schedulePoll(int token) {
    final interval =
        (num.tryParse(
                  string(
                    challenge['pollIntervalMs'] ?? protocol['pollIntervalMs'],
                  ),
                )?.toInt() ??
                3000)
            .clamp(1000, 60000);
    timer = Timer(Duration(milliseconds: interval), () => poll(token));
  }

  Future<void> poll(int token) async {
    if (!mounted || token != generation || runtime.closed) return;
    if (expires != null && DateTime.now().isAfter(expires!)) {
      await cancel();
      if (!mounted || token != generation) return;
      setState(() {
        challenge = {};
        message = '二维码已过期，请重新生成';
      });
      return;
    }
    try {
      final result = object(
        await runtime.call(string(functions['poll']), {
          'transactionId': transactionId,
          'challengeId': challenge['challengeId'],
        }),
      );
      if (!mounted || token != generation) return;
      final state = string(result['state']);
      if (state == 'confirmed') {
        setState(() {
          busy = true;
          message = '正在校验账号…';
        });
        final candidate = runtime.transactionSession(transactionId);
        if (result['uid'] != null) candidate['uid'] = result['uid'];
        await saveSession(candidate);
        await cancel();
        if (mounted && token == generation) {
          setState(() {
            busy = false;
            challenge = {};
            message = '登录成功，可以返回平台观看';
          });
        }
        return;
      }
      if (state == 'expired' || state == 'cancelled' || state == 'failed') {
        await cancel();
        if (!mounted || token != generation) return;
        setState(() {
          challenge = {};
          message = string(result['message']).isEmpty
              ? '二维码已失效，请重新生成'
              : string(result['message']);
        });
        return;
      }
      if (state == 'verification_required') {
        setState(() {
          verification = object(result['verification']);
          message = string(verification['prompt']);
        });
        return;
      }
      setState(
        () => message = state == 'scanned'
            ? '已扫码，请在手机上确认'
            : string(protocol['hint']).isEmpty
            ? '请使用对应平台的 App 扫码'
            : string(protocol['hint']),
      );
      schedulePoll(token);
    } catch (e) {
      if (mounted && token == generation) {
        setState(() {
          busy = false;
          message = friendlyError(e);
        });
      }
    }
  }

  Future<void> submitVerification() async {
    final code = await inputText(
      context,
      string(verification['prompt']).isEmpty
          ? '输入验证码'
          : string(verification['prompt']),
      secret: true,
    );
    if (code == null || code.isEmpty || !mounted) return;
    setState(() => busy = true);
    try {
      final result = object(
        await runtime.call(string(functions['submitVerification']), {
          'transactionId': transactionId,
          'challengeId': challenge['challengeId'],
          'verificationId': verification['verificationId'],
          'code': code,
        }),
      );
      if (!mounted) return;
      if (result['accepted'] != true) {
        throw Exception(
          string(result['message']).isEmpty
              ? '验证码未通过，请重试'
              : string(result['message']),
        );
      }
      verification = {};
      schedulePoll(generation);
    } catch (e) {
      if (mounted) setState(() => message = friendlyError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(28),
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
                  '${widget.info.name} · 账号',
                  style: const TextStyle(
                    fontSize: 25,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 260,
                    child: ListView(
                      children: [
                        if (canQR) ...[
                          FilledButton(
                            onPressed: busy ? null : beginQR,
                            child: const Text('生成登录二维码'),
                          ),
                          const SizedBox(height: 14),
                        ],
                        if (canCookie)
                          OutlinedButton(
                            onPressed: busy ? null : importCookie,
                            child: const Text('导入 Cookie'),
                          ),
                        const SizedBox(height: 14),
                        OutlinedButton(
                          onPressed: busy
                              ? null
                              : () async {
                                  timer?.cancel();
                                  generation++;
                                  await cancel();
                                  await runtime.updateSession({});
                                  if (mounted) {
                                    setState(() {
                                      challenge = {};
                                      verification = {};
                                      message = '账号已退出';
                                    });
                                  }
                                },
                          child: const Text('退出登录'),
                        ),
                        const SizedBox(height: 20),
                        Text(
                          runtime.store.cookie(widget.info.id).isNotEmpty
                              ? '本机已保存账号'
                              : '当前未登录',
                          style: const TextStyle(color: Colors.white60),
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          '账号数据由电视本机加密保存。',
                          style: TextStyle(color: Colors.white38, fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 40),
                  Expanded(
                    child: Center(
                      child: SingleChildScrollView(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (busy) ...[
                              const CircularProgressIndicator(),
                              const SizedBox(height: 20),
                            ],
                            if (string(challenge['qrContent']).isNotEmpty ||
                                string(challenge['qrImage']).isNotEmpty) ...[
                              Container(
                                color: Colors.white,
                                padding: const EdgeInsets.all(14),
                                child:
                                    string(challenge['qrImage']).startsWith(
                                          'data:image/png;base64,',
                                        ) &&
                                        string(challenge['qrImage']).length <
                                            3 * 1024 * 1024
                                    ? Image.memory(
                                        base64Decode(
                                          string(
                                            challenge['qrImage'],
                                          ).split(',').last,
                                        ),
                                        width: 220,
                                        height: 220,
                                        errorBuilder: (_, _, _) => const Text(
                                          '二维码图片无效',
                                          style: TextStyle(color: Colors.black),
                                        ),
                                      )
                                    : QrImageView(
                                        data: string(challenge['qrContent']),
                                        size: 220,
                                        backgroundColor: Colors.white,
                                      ),
                              ),
                              const SizedBox(height: 18),
                            ],
                            Text(
                              message.isEmpty
                                  ? canQR
                                        ? '选择“生成登录二维码”，然后用手机扫码。'
                                        : canCookie
                                        ? '该插件未提供扫码登录，可导入本平台 Cookie。'
                                        : array(
                                            object(
                                              runtime.plugin.manifest['auth'],
                                            )['credentialKinds'],
                                          ).isEmpty
                                        ? '该插件没有声明账号登录能力。'
                                        : '该平台使用设备授权或 Token，首版尚未接入此类登录。'
                                  : message,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontSize: 18,
                                color: Colors.white70,
                              ),
                            ),
                            if (verification.isNotEmpty) ...[
                              const SizedBox(height: 18),
                              FilledButton(
                                onPressed: busy ? null : submitVerification,
                                child: const Text('输入验证码'),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
