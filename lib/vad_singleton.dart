import 'app_logger.dart';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;

/// 内置 VAD 模型在本地文件系统中的目录名（与 SenseVoice 同目录）
const String _bundledVadDirName = 'bundled_model';

/// VAD 单例
///
/// 搬家模式（VoiceActivityDetector 驱动）使用，懒加载：
/// - 搬家模式首次开启时调用 [initialize]
/// - 退出搬家模式时调用 [dispose] 防 native 内存泄漏
///
/// 内置模型拷贝逻辑参考 [RecognizerSingleton._ensureBundledModel]，
/// 文件存在则跳过，避免每次开启搬家模式都走 IO。
class VadSingleton {
  static final VadSingleton instance = VadSingleton._();
  VadSingleton._();

  sherpa_onnx.VoiceActivityDetector? _vad;
  String? _modelPath; // 缓存路径，避免每次开启搬家模式都检查

  /// 是否已就绪
  bool get isReady => _vad != null;

  /// 获取 native VAD 实例（未初始化时为 null）
  sherpa_onnx.VoiceActivityDetector? get vad => _vad;

  /// 获取内置 VAD 模型在本地的目录路径
  Future<String> _getBundledVadDir() async {
    final appDocDir = await getApplicationDocumentsDirectory();
    return p.join(appDocDir.path, _bundledVadDirName);
  }

  /// 确保 silero_vad.onnx 已从 assets 拷贝到本地目录
  ///
  /// 复用 [RecognizerSingleton._ensureBundledModel] 的同构逻辑：
  /// - 文件已存在 → 直接返回路径（跳过拷贝）
  /// - 不存在 → rootBundle.load → writeAsBytes
  ///
  /// 返回 silero_vad.onnx 的完整文件路径。
  Future<String> _ensureModel() async {
    final bundledDir = await _getBundledVadDir();
    final dir = Directory(bundledDir);

    final modelFile = File(p.join(bundledDir, 'silero_vad.onnx'));

    // 如果文件已存在，直接返回路径（跳过拷贝）
    if (modelFile.existsSync()) {
      final modelSize = await modelFile.length();
      log("📍 [VAD] 模型已存在于本地: ${modelFile.path} (${(modelSize / 1024).toStringAsFixed(1)}KB)");
      return modelFile.path;
    }

    // 需要拷贝，先确保目录存在
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }

    log("📦 [VAD] 首次启动，从 assets 拷贝 silero_vad.onnx 到本地...");
    final copySw = Stopwatch()..start();

    // 从 assets 加载模型字节
    final modelData = await rootBundle.load('assets/silero_vad.onnx');
    copySw.stop();
    log("⏱️ [VAD] rootBundle.load(silero_vad) 耗时: ${copySw.elapsedMilliseconds}ms");

    copySw.reset();
    copySw.start();
    await modelFile.writeAsBytes(
      modelData.buffer.asUint8List(modelData.offsetInBytes, modelData.lengthInBytes),
    );
    copySw.stop();
    log("⏱️ [VAD] writeAsBytes(silero_vad) 耗时: ${copySw.elapsedMilliseconds}ms, 大小: ${(modelData.lengthInBytes / 1024).toStringAsFixed(1)}KB");
    log("📦 [VAD] silero_vad.onnx 拷贝完成: ${modelFile.path}");
    return modelFile.path;
  }

  /// 懒加载初始化。搬家模式首次开启时调用。
  ///
  /// 返回 true 表示初始化成功，false 表示失败。
  Future<bool> initialize() async {
    if (_vad != null) return true;

    try {
      final path = _modelPath ??= await _ensureModel();

      if (!File(path).existsSync()) {
        debugPrint("⚠️ [VAD] 模型文件不存在: $path");
        return false;
      }

      log("🚀 [VAD] 初始化 VoiceActivityDetector, model=$path");
      final initSw = Stopwatch()..start();

      // 在 Future 中加载，避免阻塞调用线程（参考 RecognizerSingleton.initialize）
      await Future(() {
        _vad = sherpa_onnx.VoiceActivityDetector(
          config: sherpa_onnx.VadModelConfig(
            sileroVad: sherpa_onnx.SileroVadModelConfig(
              model: path,
              threshold: 0.5, // 语音/非语音判定阈值，越高越严格
              minSilenceDuration: 0.6, // 静音超过 0.6s 视为语音段结束
              minSpeechDuration: 0.3, // 短于 0.3s 的语音段丢弃（过滤噪声）
              windowSize: 512, // Silero v4 16kHz 强制值（不可改）
              maxSpeechDuration: 15.0, // 搬家模式需求：单段最长 15 秒
            ),
            sampleRate: 16000,
            numThreads: 1,
            provider: 'cpu',
            debug: false, // ⚠️ 必须 false，默认 true 会每 32ms 打一行日志刷屏
          ),
          bufferSizeInSeconds: 30, // 内部环形缓冲 30 秒
        );
      });
      initSw.stop();
      log("⏱️ [VAD] VoiceActivityDetector 创建耗时: ${initSw.elapsedMilliseconds}ms");
      log("✅ [VAD] 初始化成功");
      return true;
    } catch (e) {
      debugPrint("❌ [VAD] 初始化失败: $e");
      _vad = null;
      _modelPath = null;
      return false;
    }
  }

  /// 退出搬家模式时调用，防 native 内存泄漏
  ///
  /// flush 把残留的尾部语音段 push 到输出队列（理论上搬家模式结束时
  /// 已经处理过，但保险起见调用一次），free 释放 native 资源。
  void dispose() {
    if (_vad != null) {
      _vad!.flush();
      _vad!.free();
      _vad = null;
      log("🧹 [VAD] 已释放");
    }
  }
}
