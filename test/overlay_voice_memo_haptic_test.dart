// 转写成功震动的让位判定（纯函数）：手动停短录音跳过，避免与停止操作震贴脸。
// 背景：2026-09-16 用户拍板——手动停(按钮/音量键)自带停止操作震，录音 <30s 时
// 转写快、成功震会与它贴脸干扰，跳过；自动停(VAD)/上限停无停止操作震恒震。
import 'package:flutter_test/flutter_test.dart';
import 'package:shengwuji_app/overlay/overlay_voice_memo.dart';

void main() {
  group('OverlayVoiceMemoController.shouldHapticOnTranscribeSuccess', () {
    test('手动停 + 录音不足 30s → 跳过（成功震让位停止操作震）', () {
      expect(
        OverlayVoiceMemoController.shouldHapticOnTranscribeSuccess(
          manualStop: true,
          durationSeconds: 5.0,
        ),
        isFalse,
      );
    });

    test('手动停 + 恰好 30s（边界）→ 震', () {
      expect(
        OverlayVoiceMemoController.shouldHapticOnTranscribeSuccess(
          manualStop: true,
          durationSeconds: 30.0,
        ),
        isTrue,
      );
    });

    test('手动停 + 长录音 → 震（转写耗时已与停止震拉开间隔）', () {
      expect(
        OverlayVoiceMemoController.shouldHapticOnTranscribeSuccess(
          manualStop: true,
          durationSeconds: 120.0,
        ),
        isTrue,
      );
    });

    test('自动停（VAD/上限）+ 短录音 → 恒震（无停止操作震可让位）', () {
      expect(
        OverlayVoiceMemoController.shouldHapticOnTranscribeSuccess(
          manualStop: false,
          durationSeconds: 2.0,
        ),
        isTrue,
      );
    });
  });
}
