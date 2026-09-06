// PCM → WAV 落盘公共工具
//
// 与 lib/diary_tab.dart 的 `_writeWavFile` / `_wavHeader` 同构（diary_tab 本地
// 实现保留未迁移，控制改动半径），两边 WAV 头字段逐字节一致：
// RIFF/fmt/data 块、采样率 16000、位深 16、单声道、44 字节标准头。
// 用途：悬浮窗语音速记（overlay_voice_memo）的防丢落盘——PCM 先落 WAV 再
// 占位入库 diary 表，转写失败/崩溃时录音不丢，用户可在主 App 里"再次转写"。

import 'dart:io';
import 'dart:typed_data';

/// 把 PCM16 LE 的字节流编成标准 WAV 文件（16kHz / 16bit / 单声道）并返回文件路径
///
/// 与 diary_tab._writeWavFile 同构，差异仅一点：目标文件路径由调用方生成
/// （目录创建 + 文件名命名归调用方管），本函数只负责"拼 WAV 头 + 写文件"。
Future<String> writeWavFile(
  Uint8List pcmBytes,
  String filePath, {
  int sampleRate = 16000,
}) async {
  final header = _wavHeader(pcmBytes.length, sampleRate, 1, 16);
  final out = BytesBuilder();
  out.add(header);
  out.add(pcmBytes);

  final file = File(filePath);
  await file.writeAsBytes(out.toBytes(), flush: true);
  return filePath;
}

/// 生成 44 字节的 WAV header（PCM16 little-endian）
Uint8List _wavHeader(
  int pcmDataLength,
  int sampleRate,
  int channels,
  int bitsPerSample,
) {
  final bytesPerSample = (bitsPerSample / 8).round();
  final byteRate = sampleRate * channels * bytesPerSample;
  final blockAlign = channels * bytesPerSample;
  final subchunk2Size = pcmDataLength;
  final chunkSize = 36 + subchunk2Size;

  final header = ByteData(44);
  header.setUint8(0, 'R'.codeUnitAt(0));
  header.setUint8(1, 'I'.codeUnitAt(0));
  header.setUint8(2, 'F'.codeUnitAt(0));
  header.setUint8(3, 'F'.codeUnitAt(0));
  header.setUint32(4, chunkSize, Endian.little);
  header.setUint8(8, 'W'.codeUnitAt(0));
  header.setUint8(9, 'A'.codeUnitAt(0));
  header.setUint8(10, 'V'.codeUnitAt(0));
  header.setUint8(11, 'E'.codeUnitAt(0));
  header.setUint8(12, 'f'.codeUnitAt(0));
  header.setUint8(13, 'm'.codeUnitAt(0));
  header.setUint8(14, 't'.codeUnitAt(0));
  header.setUint8(15, ' '.codeUnitAt(0));
  header.setUint32(16, 16, Endian.little); // Subchunk1Size for PCM
  header.setUint16(20, 1, Endian.little); // AudioFormat 1 = PCM
  header.setUint16(22, channels, Endian.little);
  header.setUint32(24, sampleRate, Endian.little);
  header.setUint32(28, byteRate, Endian.little);
  header.setUint16(32, blockAlign, Endian.little);
  header.setUint16(34, bitsPerSample, Endian.little);
  header.setUint8(36, 'd'.codeUnitAt(0));
  header.setUint8(37, 'a'.codeUnitAt(0));
  header.setUint8(38, 't'.codeUnitAt(0));
  header.setUint8(39, 'a'.codeUnitAt(0));
  header.setUint32(40, subchunk2Size, Endian.little);
  return header.buffer.asUint8List();
}
