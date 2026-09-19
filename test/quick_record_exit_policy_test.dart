import 'package:flutter_test/flutter_test.dart';
import 'package:shengwuji_app/utils/quick_record_exit_policy.dart';

/// 快捷录音「退出即停」判定纯函数的单测（背景见库注释）。
void main() {
  group('shouldAutoStopQuickRecording', () {
    test('快捷会话 + 后台 + 亮屏 → 停（用户反馈的目标场景）', () {
      expect(
        shouldAutoStopQuickRecording(
          isLockedRecording: true,
          isListening: true,
          isProcessing: false,
          appStillBackgrounded: true,
          screenOn: true,
        ),
        isTrue,
      );
    });

    test('息屏（锁屏快捷录音按电源键）→ 续录', () {
      expect(
        shouldAutoStopQuickRecording(
          isLockedRecording: true,
          isListening: true,
          isProcessing: false,
          appStillBackgrounded: true,
          screenOn: false,
        ),
        isFalse,
      );
    });

    test('屏幕状态查询失败（null）→ 保守续录，不截断录音', () {
      expect(
        shouldAutoStopQuickRecording(
          isLockedRecording: true,
          isListening: true,
          isProcessing: false,
          appStillBackgrounded: true,
          screenOn: null,
        ),
        isFalse,
      );
    });

    test('App 内手动录音（非 lockedMode）→ 续录（既有后台续录行为不变）', () {
      expect(
        shouldAutoStopQuickRecording(
          isLockedRecording: false,
          isListening: true,
          isProcessing: false,
          appStillBackgrounded: true,
          screenOn: true,
        ),
        isFalse,
      );
    });

    test('延迟复核时已回前台（误触 Home 后立刻返回）→ 续录', () {
      expect(
        shouldAutoStopQuickRecording(
          isLockedRecording: true,
          isListening: true,
          isProcessing: false,
          appStillBackgrounded: false,
          screenOn: true,
        ),
        isFalse,
      );
    });

    test('已停止录音 / 已在转写 → 不动', () {
      expect(
        shouldAutoStopQuickRecording(
          isLockedRecording: true,
          isListening: false,
          isProcessing: false,
          appStillBackgrounded: true,
          screenOn: true,
        ),
        isFalse,
      );
      expect(
        shouldAutoStopQuickRecording(
          isLockedRecording: true,
          isListening: false,
          isProcessing: true,
          appStillBackgrounded: true,
          screenOn: true,
        ),
        isFalse,
      );
    });
  });
}
