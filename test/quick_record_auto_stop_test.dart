// 快速录音「说完自动停止」单元测试：静音状态机（SilenceTimer）+ 配置读取
// （QuickRecordAutoStopConfig.fromPrefs）。
// VAD 胶水（QuickRecordSilenceDetector）依赖 sherpa_onnx native 库，纯 Dart
// test 环境无法运行，其行为由状态机测试 + 真机联调覆盖。

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shengwuji_app/utils/quick_record_auto_stop.dart';

void main() {
  group('pcm16BytesToFloat32 PCM 转换', () {
    test('offset=0 的普通 buffer 转换正确', () {
      // PCM16 值 [0, 16384, -16384, 32767]（little-endian 字节）
      final bytes = Uint8List.fromList([
        0x00, 0x00, 0x00, 0x40, 0x00, 0xC0, 0xFF, 0x7F,
      ]);
      final f = QuickRecordSilenceDetector.pcm16BytesToFloat32(bytes);
      expect(f.length, 4);
      expect(f[0], 0.0);
      expect(f[1], closeTo(16384 / 32768.0, 1e-6));
      expect(f[2], closeTo(-16384 / 32768.0, 1e-6));
      expect(f[3], closeTo(32767 / 32768.0, 1e-6));
    });

    test('⚠️ 带 offsetInBytes 的 view（record 实测形态）波形不错位——悬浮窗自动停失灵根因回归', () {
      // record 包的 chunk 是底层共享 ByteBuffer 的 view，offsetInBytes 不固定
      // （record_tab 踩坑注释：实测 4、5 等奇偶值都会出现）。无参 asInt16List()
      // 无视 offset 从 buffer 位置 0 读 → 采样错位成乱码（rms 照样大），
      // Silero 判不出人声 → 2026-09-16 悬浮窗自动停静默失灵的真机根因
      final pad = Uint8List.fromList([0xAA, 0xBB, 0xCC, 0xDD]); // offset=4 垫底
      final payload = Uint8List.fromList([
        0x00, 0x40, // 16384
        0x00, 0xC0, // -16384
      ]);
      final buffer = Uint8List(pad.length + payload.length);
      buffer.setAll(0, pad);
      buffer.setAll(4, payload);
      final view = Uint8List.view(
        buffer.buffer,
        4,
        4,
      ); // offsetInBytes=4、长 4 字节（2 样本），与 record chunk 同形态
      expect(view.offsetInBytes, 4);

      final f = QuickRecordSilenceDetector.pcm16BytesToFloat32(view);
      expect(f.length, 2);
      expect(f[0], closeTo(16384 / 32768.0, 1e-6)); // 错位实现会读到 0xBBCC
      expect(f[1], closeTo(-16384 / 32768.0, 1e-6));
    });
  });

  group('SilenceTimer 静音状态机', () {
    late DateTime current;
    late int firedCount;

    /// 可推进的假时钟（真实使用传 DateTime.now，测试注入确定性时间）
    DateTime clock() => current;

    SilenceTimer build({int seconds = 3}) => SilenceTimer(
      silenceSeconds: seconds,
      onTimeout: () => firedCount++,
      clock: clock,
    );

    setUp(() {
      current = DateTime(2026, 9, 15, 12, 0, 0);
      firedCount = 0;
    });

    test('从未说话（一直无人声帧）永不触发——留给录音上限兜底', () {
      final timer = build();
      for (int i = 0; i < 100; i++) {
        current = current.add(const Duration(seconds: 1));
        timer.onSpeechFrame(false);
      }
      expect(firedCount, 0);
    });

    test('说话后静音满设定秒数触发一次', () {
      final timer = build(seconds: 3);
      current = current.add(const Duration(milliseconds: 100));
      timer.onSpeechFrame(true); // 开口
      current = current.add(const Duration(seconds: 3));
      timer.onSpeechFrame(false); // 静音满 3s
      expect(firedCount, 1);
    });

    test('静音不足设定秒数不触发（5 秒档在 4.9s 时）', () {
      final timer = build(seconds: 5);
      timer.onSpeechFrame(true);
      current = current.add(const Duration(milliseconds: 4900));
      timer.onSpeechFrame(false);
      expect(firedCount, 0);
    });

    test('持续说话期间不触发（语音帧持续刷新计时起点）', () {
      final timer = build(seconds: 3);
      for (int i = 0; i < 300; i++) {
        // 10 秒连续语音，远超 3 秒
        current = current.add(const Duration(milliseconds: 32));
        timer.onSpeechFrame(true);
      }
      expect(firedCount, 0);
    });

    test('静音中途再次说话计时重置（自然停顿不误停）', () {
      final timer = build(seconds: 3);
      timer.onSpeechFrame(true);
      current = current.add(const Duration(seconds: 2));
      timer.onSpeechFrame(false); // 静音 2s，未达标
      timer.onSpeechFrame(true); // 又开口：计时清零
      current = current.add(const Duration(seconds: 2));
      timer.onSpeechFrame(false); // 仅静音 2s，不应触发
      expect(firedCount, 0);
      current = current.add(const Duration(seconds: 1));
      timer.onSpeechFrame(false); // 累计 3s
      expect(firedCount, 1);
    });

    test('触发后锁定不重复触发（cancel 竞态窗口里的残余帧）', () {
      final timer = build(seconds: 3);
      timer.onSpeechFrame(true);
      current = current.add(const Duration(seconds: 3));
      timer.onSpeechFrame(false); // 触发
      current = current.add(const Duration(seconds: 10));
      timer.onSpeechFrame(false); // 残余帧不应再触发
      timer.onSpeechFrame(true);
      timer.onSpeechFrame(false);
      expect(firedCount, 1);
    });

    test('reset 后可重新触发（新录音会话）', () {
      final timer = build(seconds: 3);
      timer.onSpeechFrame(true);
      current = current.add(const Duration(seconds: 3));
      timer.onSpeechFrame(false);
      expect(firedCount, 1);

      timer.reset();
      timer.onSpeechFrame(true);
      current = current.add(const Duration(seconds: 3));
      timer.onSpeechFrame(false);
      expect(firedCount, 2);
    });

    test('3/5/8 档各自按时长触发', () {
      for (final seconds in quickRecordAutoStopSecondsChoices) {
        current = DateTime(2026, 9, 15, 12, 0, 0);
        firedCount = 0;
        final timer = build(seconds: seconds);
        timer.onSpeechFrame(true);
        current = current.add(Duration(seconds: seconds - 1));
        timer.onSpeechFrame(false);
        expect(firedCount, 0, reason: '${seconds}s 档在 ${seconds - 1}s 不应触发');
        current = current.add(const Duration(seconds: 1));
        timer.onSpeechFrame(false);
        expect(firedCount, 1, reason: '${seconds}s 档在 ${seconds}s 应触发');
      }
    });

    group('倒计时状态查询（UI 提示用）', () {
      test('从未说话 → 不在倒计时（remainingSeconds 为 null）', () {
        final timer = build(seconds: 3);
        timer.onSpeechFrame(false);
        expect(timer.countingDown, false);
        expect(timer.remainingSeconds, isNull);
      });

      test('说话进行中（最后帧是语音）→ 不在倒计时', () {
        final timer = build(seconds: 3);
        timer.onSpeechFrame(true);
        current = current.add(const Duration(seconds: 10));
        timer.onSpeechFrame(true);
        expect(timer.countingDown, false);
        expect(timer.remainingSeconds, isNull);
      });

      test('静音中 → 倒计时进行，剩余秒数向上取整', () {
        final timer = build(seconds: 3);
        timer.onSpeechFrame(true);
        current = current.add(const Duration(milliseconds: 1400));
        timer.onSpeechFrame(false); // 静音 1.4s → 剩 1.6s → 显示 2
        expect(timer.countingDown, true);
        expect(timer.remainingSeconds, 2);
      });

      test('剩余不足 1s → 显示 1（剩 0.1s 也提示还有 1 秒）', () {
        final timer = build(seconds: 3);
        timer.onSpeechFrame(true);
        current = current.add(const Duration(milliseconds: 2900));
        timer.onSpeechFrame(false);
        expect(timer.remainingSeconds, 1);
      });

      test('触发后 → 倒计时结束（null），恢复说话也回 null', () {
        final timer = build(seconds: 3);
        timer.onSpeechFrame(true);
        current = current.add(const Duration(seconds: 3));
        timer.onSpeechFrame(false); // 触发
        expect(timer.remainingSeconds, isNull);
        timer.onSpeechFrame(true); // 残余语音帧
        expect(timer.remainingSeconds, isNull);
      });

      test('静音中恢复说话 → 退出倒计时（UI 回计时文案）', () {
        final timer = build(seconds: 3);
        timer.onSpeechFrame(true);
        current = current.add(const Duration(seconds: 1));
        timer.onSpeechFrame(false); // 进入倒计时
        expect(timer.remainingSeconds, 2);
        timer.onSpeechFrame(true); // 又开口
        expect(timer.remainingSeconds, isNull);
        expect(timer.countingDown, false);
      });

      test('reset 后 → 倒计时清零', () {
        final timer = build(seconds: 3);
        timer.onSpeechFrame(true);
        current = current.add(const Duration(seconds: 1));
        timer.onSpeechFrame(false);
        expect(timer.countingDown, true);
        timer.reset();
        expect(timer.countingDown, false);
        expect(timer.remainingSeconds, isNull);
      });
    });
  });

  group('QuickRecordAutoStopConfig.fromPrefs', () {
    test('无任何存储值：默认关闭 + 默认 3 秒', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final cfg = QuickRecordAutoStopConfig.fromPrefs(prefs);
      expect(cfg.enabled, false);
      expect(cfg.silenceSeconds, quickRecordAutoStopDefaultSeconds);
    });

    test('读取已存配置（开启 + 5 秒）', () async {
      SharedPreferences.setMockInitialValues({
        quickRecordAutoStopEnabledPrefKey: true,
        quickRecordAutoStopSecondsPrefKey: 5,
      });
      final prefs = await SharedPreferences.getInstance();
      final cfg = QuickRecordAutoStopConfig.fromPrefs(prefs);
      expect(cfg.enabled, true);
      expect(cfg.silenceSeconds, 5);
    });

    test('非法秒数（残留脏值）回落默认 3 秒', () async {
      SharedPreferences.setMockInitialValues({
        quickRecordAutoStopEnabledPrefKey: true,
        quickRecordAutoStopSecondsPrefKey: 7,
      });
      final prefs = await SharedPreferences.getInstance();
      final cfg = QuickRecordAutoStopConfig.fromPrefs(prefs);
      expect(cfg.enabled, true);
      expect(cfg.silenceSeconds, quickRecordAutoStopDefaultSeconds);
    });

    test('关闭状态仅 enabled=false，秒数照常读取', () async {
      SharedPreferences.setMockInitialValues({
        quickRecordAutoStopEnabledPrefKey: false,
        quickRecordAutoStopSecondsPrefKey: 8,
      });
      final prefs = await SharedPreferences.getInstance();
      final cfg = QuickRecordAutoStopConfig.fromPrefs(prefs);
      expect(cfg.enabled, false);
      expect(cfg.silenceSeconds, 8);
    });
  });
}
