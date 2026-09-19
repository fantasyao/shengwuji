import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_logger.dart';
import 'diary_web_server.dart';

/// 电脑访问服务开关的生命周期编排器（设置页开关 / 冷启动自动恢复的唯一入口）。
///
/// 职责：
/// 1. 开启 = 先拉起原生前台服务（DiaryServerService，拉住进程优先级防止
///    App 退后台后进程被冻结、HTTP 服务断掉）→ 再启动 Dart 侧 HTTP 服务；
///    HTTP 起失败时回滚前台服务
/// 2. 关闭 = 停 HTTP → 停前台服务 → 清持久化开关
/// 3. 开启状态持久化到 prefs（[enabledPrefKey]），冷启动由
///    [autoStartIfEnabled] 自动恢复——重启 App 后服务自己回来，
///    电脑端书签里的地址始终有效
class DiaryServerController {
  DiaryServerController({DiaryWebServer? server})
    : _server = server ?? DiaryWebServer.instance;

  /// 应用全局单例（设置页卡片 / main.dart 使用）
  static final DiaryServerController instance = DiaryServerController();

  /// prefs 键：服务是否应处于开启状态（写库成功才置 true，与 HTTP 实际
  /// 存活解耦——冷启动按此恢复，起不来会在设置页显示具体错误）
  static const String enabledPrefKey = 'diary_web_server_enabled';

  static const MethodChannel _platform = MethodChannel('com.shengwuji.app/app');

  final DiaryWebServer _server;

  /// 状态（设置页卡片 ValueListenableBuilder 订阅）
  final ValueNotifier<DiaryServerStatus> status = ValueNotifier(
    const DiaryServerStatus(),
  );

  bool _starting = false;

  bool get isRunning => _server.isRunning;

  /// 开启服务（幂等：starting 中直接忽略；已在跑也走一遍 start——
  /// DiaryWebServer.start 自带"先停旧实例再启"的幂等语义）
  Future<void> start() async {
    if (_starting) return;
    _starting = true;
    status.value = const DiaryServerStatus(phase: DiaryServerPhase.starting);
    log('💻 [WebServer] 开启电脑访问服务');

    // 1. 先拉前台服务保活（进程优先级先上去，HTTP 再绑定）
    try {
      await _platform.invokeMethod<bool>('startDiaryServerService');
    } catch (e) {
      // 原生侧失败不阻塞：服务仍可在前台使用（仅退后台可能被冻结）
      log('💻 [WebServer] ⚠️ 前台服务拉起失败（服务仍将启动）: $e');
    }

    // 1. 先拉前台服务保活（进程优先级先上去，HTTP 再绑定）
    try {
      final fgsAck = await _platform.invokeMethod<bool>(
        'startDiaryServerService',
      );
      log('💻 [WebServer] 前台保活服务指令已发（ack=$fgsAck）');
    } catch (e) {
      // 原生侧失败不阻塞：服务仍可在前台使用（仅退后台可能被冻结）
      log('💻 [WebServer] ⚠️ 前台服务拉起失败（服务仍将启动）: $e');
    }

    // 2. 启动 HTTP 服务（含端口被占时的自家实例接管）
    final result = await _server.start();
    log(
      '💻 [WebServer] HTTP 启动结果: ${result.status} — ${result.userMessage}',
    );
    if (!result.isSuccess) {
      // HTTP 起失败 → 回滚前台服务，不留孤儿通知
      await _stopForegroundService();
      status.value = DiaryServerStatus(
        phase: DiaryServerPhase.error,
        message: result.userMessage,
      );
      _starting = false;
      return;
    }

    // 3. 持久化开关（冷启动自动恢复依据）
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(enabledPrefKey, true);
    } catch (e) {
      log('💻 [WebServer] ⚠️ 开关持久化失败（不影响本次运行）: $e');
    }

    status.value = const DiaryServerStatus(phase: DiaryServerPhase.running);
    _starting = false;
  }

  /// 关闭服务（幂等）
  Future<void> stop() async {
    log('💻 [WebServer] 关闭电脑访问服务');
    await _server.stop();
    await _stopForegroundService();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(enabledPrefKey, false);
    } catch (_) {}
    status.value = const DiaryServerStatus(phase: DiaryServerPhase.idle);
  }

  Future<void> _stopForegroundService() async {
    try {
      await _platform.invokeMethod<bool>('stopDiaryServerService');
    } catch (e) {
      log('💻 [WebServer] ⚠️ 前台服务停止失败: $e');
    }
  }

  /// 冷启动自动恢复：上次开启过则静默拉起。默认延迟 1.5s——启动热路径
  /// （模型预载 / 日记页首帧）优先，服务晚一两秒可接受
  Future<void> autoStartIfEnabled({
    Duration delay = const Duration(milliseconds: 1500),
  }) async {
    bool enabled = false;
    try {
      final prefs = await SharedPreferences.getInstance();
      enabled = prefs.getBool(enabledPrefKey) ?? false;
    } catch (e) {
      log('💻 [WebServer] 读取服务开关失败，跳过自动恢复: $e');
      return;
    }
    if (!enabled) return;
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    if (isRunning || _starting) return;
    log('💻 [WebServer] 上次开启过电脑访问服务，自动恢复');
    await start();
  }

  /// 本机局域网 IPv4 列表（设置页拼 http://手机IP:9527 展示用）。
  /// 私有网段优先排序（192.168 > 10. > 172. > 其他），多网卡时常用的在前
  static Future<List<String>> lanAddresses() async {
    final result = <String>[];
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
        includeLinkLocal: false,
      );
      for (final itf in interfaces) {
        for (final addr in itf.addresses) {
          result.add(addr.address);
        }
      }
    } catch (e) {
      log('💻 [WebServer] 获取局域网地址失败: $e');
    }
    int rank(String ip) {
      if (ip.startsWith('192.168.')) return 0;
      if (ip.startsWith('10.')) return 1;
      if (ip.startsWith('172.')) return 2;
      return 3;
    }

    result.sort((a, b) => rank(a).compareTo(rank(b)));
    return result;
  }
}

enum DiaryServerPhase { idle, starting, running, error }

/// 服务运行状态（设置页卡片展示）
class DiaryServerStatus {
  const DiaryServerStatus({
    this.phase = DiaryServerPhase.idle,
    this.message,
  });

  final DiaryServerPhase phase;

  /// error 时的用户可读文案
  final String? message;
}
