// 快速录音「说完自动停止」：配置读取 + 静音状态机 + VAD 胶水
//
// 覆盖两个快速录音入口：悬浮窗语音速记（overlay_voice_memo）与主 App 快速
// 录音（diary_tab lockedMode）。普通点按钮录音不启用（用户手就在屏幕上，
// 无自动停需求）。
//
// 检测原理：录音流的 PCM16 chunk 实时喂 Silero VAD（复用 VadSingleton，与
// 搬家模式共用同一 per-isolate 单例；麦克风互斥保证两场景永不并发），逐窗
// 读 isDetected() 状态进静音状态机——说过话之后静音满设定秒数触发回调，由
// 调用方走各自的既有停止→转写链路。

import 'dart:math' show sqrt;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:shengwuji_app/app_logger.dart';
import 'package:shengwuji_app/vad_singleton.dart';

/// prefs key：快速录音说完自动停止开关（设置页写，两个录音入口开录时读；
/// 悬浮窗 overlay engine 读主 App 写的值须先 reload，见各读取点注释）
const String quickRecordAutoStopEnabledPrefKey = 'quick_record_auto_stop_enabled';

/// prefs key：静音等待秒数（3/5/8 档，设置页 ChoiceChip 写）
const String quickRecordAutoStopSecondsPrefKey = 'quick_record_auto_stop_seconds';

/// 静音等待秒数档位（与设置页选择器共用；默认 3 秒）
const List<int> quickRecordAutoStopSecondsChoices = [3, 5, 8];
const int quickRecordAutoStopDefaultSeconds = 3;

/// 快速录音自动停止配置（一次开录读一份，会话内不变）
class QuickRecordAutoStopConfig {
  const QuickRecordAutoStopConfig({
    required this.enabled,
    required this.silenceSeconds,
  });

  final bool enabled;
  final int silenceSeconds;

  /// 调用方须先 `prefs.reload()` 再传入（跨 engine 读主 App 写入的惯例）。
  /// 静音秒数非法（残留脏值）回落默认，保证等待时长有意义。
  factory QuickRecordAutoStopConfig.fromPrefs(SharedPreferences prefs) {
    final enabled = prefs.getBool(quickRecordAutoStopEnabledPrefKey) ?? false;
    var seconds =
        prefs.getInt(quickRecordAutoStopSecondsPrefKey) ??
        quickRecordAutoStopDefaultSeconds;
    if (!quickRecordAutoStopSecondsChoices.contains(seconds)) {
      seconds = quickRecordAutoStopDefaultSeconds;
    }
    return QuickRecordAutoStopConfig(enabled: enabled, silenceSeconds: seconds);
  }
}

/// 静音状态机（纯逻辑，不依赖 VAD，注入时钟可测）。
///
/// 语义：
/// - 一次都没说过话 → 永不触发（用户可能还在组织语言；该场景留给录音上限
///   兜底，也避免频繁产生空录音占位行）
/// - 从"最后一次检测到语音"起静音满 [silenceSeconds] → 触发一次 [onTimeout]。
///   VAD 的 isDetected 在实际静音约 minSilenceDuration（0.6s，VadSingleton
///   固定配置）后才翻 false，实际等待 ≈ 设定秒数 + 0.6s——偏保守方向，更
///   不易把说话中间的自然停顿误判为说完
/// - 静音期间再次说话 → 计时清零重来
class SilenceTimer {
  SilenceTimer({
    required this.silenceSeconds,
    required this.onTimeout,
    DateTime Function()? clock,
  }) : _now = clock ?? DateTime.now;

  final int silenceSeconds;
  final VoidCallback onTimeout;
  final DateTime Function() _now;

  DateTime? _lastSpeechAt;
  bool _hasSpoken = false;
  bool _fired = false;
  bool _lastFrameWasSpeech = false;

  /// 诊断用：本会话是否已检测到过语音（悬浮窗自动停失灵定位，看它是否
  /// 被置位可区分「VAD 没判出语音」与「状态机没走完」）
  bool get hasSpoken => _hasSpoken;

  /// 每喂一个 VAD 窗（512 样本 = 32ms）调用一次，isSpeech 为该窗的
  /// `VoiceActivityDetector.isDetected()` 值
  void onSpeechFrame(bool isSpeech) {
    _lastFrameWasSpeech = isSpeech;
    if (_fired) return;
    if (isSpeech) {
      _hasSpoken = true;
      _lastSpeechAt = _now();
      return;
    }
    if (!_hasSpoken || _lastSpeechAt == null) return;
    final silence = _now().difference(_lastSpeechAt!);
    if (silence >= Duration(seconds: silenceSeconds)) {
      // 触发一次即锁定：回调之后 stop 会掐断录音流，锁定防 cancel 竞态窗口
      // 里排队的残余 chunk 再次触发
      _fired = true;
      onTimeout();
    }
  }

  /// 重开会话时复位（新录音从头计）
  void reset() {
    _lastSpeechAt = null;
    _hasSpoken = false;
    _fired = false;
    _lastFrameWasSpeech = false;
  }

  /// 是否处于静音倒计时中（UI 提示用）：说过话、尚未触发、当前帧静音。
  /// 说话进行中（最后帧是语音）不算——一直显示"N 秒后停"会制造无谓紧张感
  bool get countingDown =>
      _hasSpoken &&
      !_fired &&
      _lastSpeechAt != null &&
      !_lastFrameWasSpeech;

  /// 倒计时剩余秒数（向上取整，UI 显示「N 秒后自动停」用）；
  /// 不在倒计时中返回 null。判定须与 [countingDown] 一致（含触发后恒 null）
  int? get remainingSeconds {
    if (!countingDown || _lastSpeechAt == null) return null;
    final remainingMs =
        Duration(seconds: silenceSeconds).inMilliseconds -
        _now().difference(_lastSpeechAt!).inMilliseconds;
    if (remainingMs <= 0) return 0;
    return (remainingMs + 999) ~/ 1000; // 向上取整：剩 0.1s 也显示 1
  }
}

/// 流式 PCM → VAD → 静音状态机 的胶水（快速录音会话各持一个实例）。
///
/// 生命周期：开流成功后创建（此前任一失败路径 return 时实例尚不存在，无需
/// 回滚），录音流回调里 feedPcm16，停止/失败时 dispose——dispose 释放
/// VadSingleton（清掉本会话喂进去的残留样本/段 + native 内存），给后续用途
/// （搬家模式 / diary 长录音停止后的分段兜底）留干净状态，它们 initialize
/// 时重建（VadSingleton.initialize/dispose 均幂等，交叉时序安全）。
class QuickRecordSilenceDetector {
  QuickRecordSilenceDetector({
    required this.config,
    required this.onSilence,
    DateTime Function()? clock,
  }) : _timer = SilenceTimer(
         silenceSeconds: config.silenceSeconds,
         onTimeout: onSilence,
         clock: clock,
       );

  /// 本会话的配置（开录时快照；调用方打日志可直接读 silenceSeconds）
  final QuickRecordAutoStopConfig config;

  final SilenceTimer _timer;

  /// 诊断日志节流计数（每 30 chunk ≈ 1.5s 一条，见 feedPcm16）
  int _diagChunkCounter = 0;

  /// 静音达标回调（每会话至多一次），调用方走自己的停止→转写链路
  final VoidCallback onSilence;

  /// 静音倒计时剩余秒数（UI 提示用；null = 不在倒计时中），转发状态机
  int? get remainingSeconds => _timer.remainingSeconds;

  /// 确保 VAD 模型就绪（首次数百 ms，之后幂等秒回）。
  /// 调用方不 await：初始化与录音并行，未就绪期间 feedPcm16 直接跳过——
  /// 只会延迟自动停的触发起点，不会漏停（没说话本就不触发）。
  Future<bool> ensureInitialized() => VadSingleton.instance.initialize();

  /// 喂一段录音流的 PCM16 chunk（16kHz 单声道，同 record startStream 配置）
  void feedPcm16(Uint8List chunk) {
    final vad = VadSingleton.instance.vad;
    if (vad == null) return; // 初始化未完成：本块跳过（见 ensureInitialized 注释）
    final samples = pcm16BytesToFloat32(chunk);
    vad.acceptWaveform(samples);
    // 本链路只要"当前是否有人声"的状态信号，不要切段数据——段队列随到随弃，
    // 防持续录音时 VAD 内部队列堆积占内存
    while (!vad.isEmpty()) {
      vad.pop();
    }
    _timer.onSpeechFrame(vad.isDetected());

    // 🔍 诊断日志（节流 ~1.5s 一条，log 双写 logcat + 应用内日志文件）：
    // 悬浮窗自动停失灵定位（2026-09-16，VAD 初始化已修好后仍不触发）——
    // 看 isDetected 值分布即可定案：恒 false=VAD 没判出语音（数据/阈值），
    // 恒 true=状态机卡语音态（计时起点一直被刷新），有 true/false 却不触发
    // =状态机问题（有单测覆盖，可能性低）。主 App 链路已工作，此日志两链路
    // 共用，稳定后可按搬家模式诊断日志惯例保留或精简
    _diagChunkCounter++;
    if (_diagChunkCounter % 30 == 1) {
      double sumSq = 0;
      for (final s in samples) {
        sumSq += s * s;
      }
      final rms = samples.isNotEmpty ? sqrt(sumSq / samples.length) : 0.0;
      log(
        '🔍 [SilenceDetector] chunk#$_diagChunkCounter bytes=${chunk.length} '
        'offset=${chunk.offsetInBytes} '
        'rms=${rms.toStringAsFixed(4)} isDetected=${vad.isDetected()} '
        'hasSpoken=${_timer.hasSpoken} countingDown=${_timer.countingDown} '
        'remaining=${_timer.remainingSeconds}',
      );
    }
  }

  /// 会话结束（停止/失败）时调用：复位状态机 + 释放 VAD 单例
  void dispose() {
    _timer.reset();
    VadSingleton.instance.dispose();
  }

  /// PCM16 字节 → Float32 归一化采样（Int16 little-endian / 32768）。
  ///
  /// ⚠️ record 包的 PCM chunk 是底层共享 ByteBuffer 的 view，offsetInBytes
  /// 不固定（实测 4、5 等奇偶值都会出现，见 record_tab._convertBytesToFloat32
  /// 同款踩坑注释）——asInt16List() 无参形式无视 offset 从 buffer 位置 0 开始
  /// 读，采样值两两错位成高能量乱码（rms 照样大），Silero 判不出人声 → 自动停
  /// 静默失灵。2026-09-16 真机日志确诊：说话中 rms=0.59 而 isDetected 恒 false，
  /// 转写正常（转写走 BytesBuilder 产物 offset=0）。解法同 record_tab：
  /// ByteData.sublistView 自动处理 offset，手动按 little-endian 读 PCM16。
  /// public 供回归测试锁死（带 offset 的 view 输入必须输出正确波形）
  static Float32List pcm16BytesToFloat32(Uint8List bytes) {
    final int sampleCount = bytes.lengthInBytes ~/ 2;
    final float32Data = Float32List(sampleCount);
    final byteData = ByteData.sublistView(bytes);
    for (int i = 0; i < sampleCount; i++) {
      // PCM16 little-endian（Android ARM 默认字节序）
      float32Data[i] = byteData.getInt16(i * 2, Endian.little) / 32768.0;
    }
    return float32Data;
  }
}
