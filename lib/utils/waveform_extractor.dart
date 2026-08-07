import 'dart:io';
import 'dart:math' show sqrt;
import 'dart:typed_data';

/// 从 WAV 文件提取响度波纹（用于日记卡片播放进度条叠加显示）。
///
/// 设计要点：
/// - **纯 Dart 实现**，无第三方依赖；复用 record_tab.dart 已验证的 PCM16→Float32 解码方式。
/// - **buckets=64**：底部左半约 100–140dp 可用，每柱 ~1.6–2.2dp，视觉清晰；
///   10s 录音每 bucket≈156ms，能分辨音节。
/// - **归一化**：除以全局 max（自适应每段录音动态，保留"哪段更响"的相对信息）
///   + floor 0.08（静音段保留极细一线，避免视觉空白）。
/// - **空数组/读失败返回 const []**：调用方按"无波纹"渲染纯色进度条，不阻塞 UI。
///
/// ⚠️ 关键陷阱：旧 diary_tab.dart 里的 `_convertBytesToFloat32` 用了 `bytes.buffer.asInt16List()`，
///    sublist(44) 后 offset 非 2 字节对齐会抛 RangeError。
///    本文件**只抄 record_tab.dart:625-640 的安全版**（`ByteData.sublistView` + `Endian.little`）。
Future<List<double>> extractPeaks(String wavPath, {int buckets = 64}) async {
  try {
    final bytes = await File(wavPath).readAsBytes();
    if (bytes.length <= 44) return const [];
    // 简单 WAV 头校验：'RI' 魔数
    if (bytes[0] != 'R'.codeUnitAt(0) || bytes[1] != 'I'.codeUnitAt(0)) {
      return const [];
    }
    // 跳过 44 字节 WAV 头，取 PCM16 body
    final samples = _pcm16ToFloat32(bytes.sublist(44));
    if (samples.isEmpty) return const [];

    final blockSize = (samples.length / buckets).ceil();
    final peaks = List<double>.filled(buckets, 0.0);
    double globalMax = 1e-9; // 防 0 除
    for (int b = 0; b < buckets; b++) {
      final start = b * blockSize;
      final end = (start + blockSize).clamp(0, samples.length);
      double sumSq = 0.0;
      for (int i = start; i < end; i++) {
        sumSq += samples[i] * samples[i];
      }
      final rms = end > start ? sqrt(sumSq / (end - start)) : 0.0;
      peaks[b] = rms;
      if (rms > globalMax) globalMax = rms;
    }
    // 归一化 + 静音 floor（极细一线，避免视觉空白）
    const floor = 0.08;
    for (int i = 0; i < peaks.length; i++) {
      final normalized = peaks[i] / globalMax;
      peaks[i] = (normalized < floor ? floor : normalized).clamp(0.0, 1.0);
    }
    return peaks;
  } catch (_) {
    return const [];
  }
}

/// PCM16 little-endian 字节 → Float32 [-1.0, 1.0] 样本。
///
/// ⚠️ 必须用 `ByteData.sublistView`：record 包/WAV 文件读取出来的字节切片
///    在 sublist 后 offset 可能不是 2 字节对齐，`asInt16List` 会 RangeError。
///    `ByteData.sublistView` 自动处理 offset，手动按 little-endian 读 PCM16。
///    代价：每 sample 一次 getInt16 调用，性能损失可忽略（峰值提取是离线一次性）。
Float32List _pcm16ToFloat32(Uint8List bytes) {
  final out = Float32List(bytes.lengthInBytes ~/ 2);
  final bd = ByteData.sublistView(bytes);
  for (int i = 0; i < out.length; i++) {
    // PCM16 little-endian（Android ARM 默认字节序）
    out[i] = bd.getInt16(i * 2, Endian.little) / 32768.0;
  }
  return out;
}
