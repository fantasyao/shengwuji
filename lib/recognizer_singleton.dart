import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;
import 'startup_logger.dart';

/// 内置模型在本地文件系统中的目录名
const String _bundledModelDirName = 'bundled_model';

/// 语音识别器单例
/// 全局共享一个识别器实例，避免重复加载模型
class RecognizerSingleton {
  static RecognizerSingleton? _instance;
  static sherpa_onnx.OfflineRecognizer? _recognizer;
  static bool _isInitializing = false;
  static bool _hasEverInitialized = false;
  static String? _currentModelPath;

  RecognizerSingleton._();

  static RecognizerSingleton get instance {
    _instance ??= RecognizerSingleton._();
    return _instance!;
  }

  /// 获取识别器实例
  sherpa_onnx.OfflineRecognizer? get recognizer => _recognizer;

  /// 是否正在初始化
  bool get isInitializing => _isInitializing;

  /// 是否已就绪
  bool get isReady => _recognizer != null;

  /// 是否曾经初始化过（用于判断是否需要显示首次加载loading）
  bool get hasEverInitialized => _hasEverInitialized;

  /// 获取内置模型在本地的目录路径
  static Future<String> _getBundledModelDir() async {
    final appDocDir = await getApplicationDocumentsDirectory();
    return p.join(appDocDir.path, _bundledModelDirName);
  }

  /// 确保内置模型已从 assets 拷贝到本地目录
  /// 首次启动时拷贝，后续启动如果文件已存在则跳过
  static Future<String> _ensureBundledModel() async {
    final bundledDir = await _getBundledModelDir();
    final dir = Directory(bundledDir);

    final modelFile = File(p.join(bundledDir, 'model.int8.onnx'));
    final tokensFile = File(p.join(bundledDir, 'tokens.txt'));

    // 如果两个文件都已存在，直接返回路径
    if (modelFile.existsSync() && tokensFile.existsSync()) {
      final modelSize = await modelFile.length();
      print("📍 [Singleton] 内置模型已存在于本地: $bundledDir (${(modelSize / 1024 / 1024).toStringAsFixed(1)}MB)");
      StartupLogger.log("内置模型已存在(跳过拷贝)", 0, extra: "${(modelSize / 1024 / 1024).toStringAsFixed(1)}MB");
      return bundledDir;
    }

    // 需要拷贝，先确保目录存在
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }

    debugPrint("📦 [Singleton] 首次启动，从 assets 拷贝内置模型到本地...");
    final copySw = Stopwatch()..start();

    // 拷贝 model.int8.onnx
    // 🔑 模型文件可能不在 assets（开源仓库排除了 229MB 模型，需用户从 GitHub Release 下载）
    // 捕获 rootBundle.load 失败，给出明确错误信息，避免上层只看到 "Unable to load asset" 不知如何处理
    final dynamic modelData;
    try {
      modelData = await rootBundle.load('assets/model.int8.onnx');
    } catch (e) {
      print('❌ [Singleton] assets/model.int8.onnx 不存在：$e');
      print('❌ [Singleton] 开源仓库不含 229MB 模型，请从 GitHub Release 下载 model.int8.onnx 放到 assets/ 目录');
      rethrow;
    }
    copySw.stop();
    print("⏱️ [Singleton] rootBundle.load(model) 耗时: ${copySw.elapsedMilliseconds}ms");
    StartupLogger.log("rootBundle.load(model)", copySw.elapsedMilliseconds);

    copySw.reset();
    copySw.start();
    await modelFile.writeAsBytes(
      modelData.buffer.asUint8List(modelData.offsetInBytes, modelData.lengthInBytes),
    );
    copySw.stop();
    print("⏱️ [Singleton] writeAsBytes(model) 耗时: ${copySw.elapsedMilliseconds}ms, 大小: ${(modelData.lengthInBytes / 1024 / 1024).toStringAsFixed(1)}MB");
    StartupLogger.log("writeAsBytes(model)", copySw.elapsedMilliseconds, extra: "${(modelData.lengthInBytes / 1024 / 1024).toStringAsFixed(1)}MB");
    print("📦 [Singleton] model.int8.onnx 拷贝完成");

    // 拷贝 tokens.txt
    final tokensData = await rootBundle.load('assets/tokens.txt');
    await tokensFile.writeAsBytes(
      tokensData.buffer.asUint8List(tokensData.offsetInBytes, tokensData.lengthInBytes),
    );
    print("📦 [Singleton] tokens.txt 拷贝完成");

    debugPrint("✅ [Singleton] 内置模型拷贝完成: $bundledDir");
    return bundledDir;
  }

  /// 从 SharedPreferences 刷新模型路径缓存（不加载模型）
  /// 可在应用启动、模型导入后调用，使 hasModel 正确判断
  /// ⚠️ 调用时机：main() 启动时、settings_tab 导入模型后、tab 切换时 refreshEngine
  /// 🆕 现在会自动确保内置模型已拷贝到本地
  static Future<void> preloadModelPath() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final customPath = prefs.getString('custom_model_path');

      if (customPath != null && Directory(customPath).existsSync()) {
        // 用户手动导入过模型，优先使用
        _currentModelPath = customPath;
        print("📍 [Singleton] preloadModelPath: 使用用户导入的模型, path=$_currentModelPath, hasModel=$hasModel");
      } else {
        // 没有用户导入的模型，使用内置模型
        final bundledDir = await _ensureBundledModel();
        _currentModelPath = bundledDir;
        print("📍 [Singleton] preloadModelPath: 使用内置模型, path=$_currentModelPath, hasModel=$hasModel");
      }
    } catch (e) {
      debugPrint("⚠️ 预读模型路径失败: $e");
    }
  }

  /// 检查模型文件是否存在（不加载模型）
  /// 用于在录音开始前检查用户是否已导入模型
  /// 注意：需先调用 preloadModelPath() 缓存路径，否则首次启动时返回 false
  /// ⚠️ 上下游：main.dart 浮动按钮颜色、diary_tab/record_tab 按钮颜色、startListening 权限判断
  static bool get hasModel {
    try {
      // 如果没有缓存过路径，无法判断
      if (_currentModelPath == null) {
        return false;
      }

      // 检查模型文件和 tokens.txt 是否存在
      final modelFile = File(p.join(_currentModelPath!, 'model.int8.onnx'));
      final tokensFile = File(p.join(_currentModelPath!, 'tokens.txt'));
      return modelFile.existsSync() && tokensFile.existsSync();
    } catch (e) {
      debugPrint("⚠️ 检查模型文件时出错: $e");
      return false;
    }
  }

  /// 初始化识别器（异步，不阻塞 UI）
  /// 🆕 优先使用用户导入的模型，如果没有则自动使用内置模型
  Future<bool> initialize() async {
    // 如果已经初始化完成，直接返回
    if (_recognizer != null) return true;

    // 如果正在初始化中，等待完成
    if (_isInitializing) {
      // 最多等待 30 秒
      int attempts = 0;
      while (_isInitializing && attempts < 300) {
        await Future.delayed(const Duration(milliseconds: 100));
        attempts++;
      }
      return _recognizer != null;
    }

    // 开始初始化
    _isInitializing = true;

    try {
      // 确保 _currentModelPath 已设置
      if (_currentModelPath == null) {
        await preloadModelPath();
      }

      final modelDir = _currentModelPath!;

      if (!Directory(modelDir).existsSync()) {
        debugPrint("⚠️ 模型路径不存在: $modelDir");
        _isInitializing = false;
        return false;
      }

      final modelPath = p.join(modelDir, 'model.int8.onnx');
      final tokensPath = p.join(modelDir, 'tokens.txt');

      if (!File(modelPath).existsSync() || !File(tokensPath).existsSync()) {
        debugPrint("⚠️ 模型文件不存在: $modelPath 或 $tokensPath");
        _isInitializing = false;
        return false;
      }

      // 检查是否是同一个模型（避免重复加载）
      if (_currentModelPath == modelDir && _recognizer != null) {
        _isInitializing = false;
        return true;
      }

      debugPrint("🔄 开始加载模型: $modelPath");

      // 【关键优化】在 Future 中加载，不阻塞调用线程
      final loadSw = Stopwatch()..start();
      await Future(() async {
        final config = sherpa_onnx.OfflineRecognizerConfig(
          model: sherpa_onnx.OfflineModelConfig(
            senseVoice: sherpa_onnx.OfflineSenseVoiceModelConfig(
              model: modelPath,
              language: 'zh',
              useInverseTextNormalization: true,
            ),
            tokens: tokensPath,
            numThreads: 1,
          ),
        );
        print("线程数: ${config.model.numThreads}");
        // 这一步会阻塞，但在 Future 中执行
        _recognizer = sherpa_onnx.OfflineRecognizer(config);
      });
      loadSw.stop();
      print("⏱️ [Singleton] 模型加载到内存 耗时: ${loadSw.elapsedMilliseconds}ms");
      StartupLogger.log("模型加载到内存", loadSw.elapsedMilliseconds);

      _hasEverInitialized = true;

      debugPrint("✅ 模型加载完成");
      _isInitializing = false;
      return true;
    } catch (e) {
      debugPrint("❌ 模型加载失败: $e");
      _isInitializing = false;
      _recognizer = null;
      return false;
    }
  }

  /// 释放资源
  void dispose() {
    _recognizer?.free();
    _recognizer = null;
    _currentModelPath = null;
    _isInitializing = false;
  }
}
