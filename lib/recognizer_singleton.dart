import 'app_logger.dart';
import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;
import 'recognition_service.dart';
import 'startup_logger.dart';

/// 内置模型在本地文件系统中的目录名
const String _bundledModelDirName = 'bundled_model';

/// 语音识别器单例
/// 全局共享一个识别器实例，避免重复加载模型
///
/// 【worker isolate 门面】识别链路（模型加载 + decode）整体下沉到常驻
/// worker isolate（RecognitionService，9edb24f），本类为门面代理：
/// 公开语义（isReady / isInitializing / hasEverInitialized / hasModel /
/// preloadModelPath / initialize / dispose）保持不变，消费点零改动；
/// 直接摸 recognizer 做 decode 的调用点统一改为 transcribe() / warmup()。
/// 主 isolate 不再创建 OfflineRecognizer（FFI 对象只在 worker 内，内存单份）。
class RecognizerSingleton {
  static RecognizerSingleton? _instance;
  static bool _isInitializing = false;
  static bool _hasEverInitialized = false;
  static String? _currentModelPath;

  /// 常驻识别 worker 服务（模型加载 + decode 都在 worker isolate 内）。
  /// ⚠️ 非 final：RecognitionService.dispose 是终态操作（_shuttingDown 置位后
  /// initialize 永远拒绝、监听端口已 close），实例不可复用——dispose() 里会
  /// 重建本字段，下一次 initialize() 重新 spawn worker（overlay 语音速记的
  /// idle 释放 → 再录音依赖此行为）
  RecognitionService _service = RecognitionService();

  RecognizerSingleton._();

  static RecognizerSingleton get instance {
    _instance ??= RecognizerSingleton._();
    return _instance!;
  }

  /// 获取识别器实例
  /// worker 模式下主 isolate 不再创建 FFI 识别器，此 getter 恒返回 null，
  /// 仅为兼容保留签名。请改用 transcribe() / warmup()。
  @Deprecated('worker 模式下恒为 null，请改用 transcribe()')
  sherpa_onnx.OfflineRecognizer? get recognizer => null;

  /// 是否正在初始化
  bool get isInitializing => _isInitializing;

  /// 是否已就绪
  bool get isReady => _service.isReady;

  /// worker 是否正在服务"最新期望模型路径"（_currentModelPath）
  /// 热切换守卫用（bb769ce）：导入新模型后 preloadModelPath 已把 _currentModelPath
  /// 刷成新路径，但 worker 里旧模型还活着（isReady=true），此时本字段为 false——
  /// 外层各"已就绪直接返回"守卫（diary/record 的 refreshEngine/initEngine）改判本
  /// 字段即可放行，让 initialize() 把新路径送进 _service 触发 worker 先建新再释旧
  bool get isServingLatestModel =>
      _service.isReady && _service.loadedModelDir == _currentModelPath;

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
      log("📍 [Singleton] 内置模型已存在于本地: $bundledDir (${(modelSize / 1024 / 1024).toStringAsFixed(1)}MB)");
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
      log('❌ [Singleton] assets/model.int8.onnx 不存在：$e');
      log('❌ [Singleton] 开源仓库不含 229MB 模型，请从 GitHub Release 下载 model.int8.onnx 放到 assets/ 目录');
      rethrow;
    }
    copySw.stop();
    log("⏱️ [Singleton] rootBundle.load(model) 耗时: ${copySw.elapsedMilliseconds}ms");
    StartupLogger.log("rootBundle.load(model)", copySw.elapsedMilliseconds);

    copySw.reset();
    copySw.start();
    await modelFile.writeAsBytes(
      modelData.buffer.asUint8List(modelData.offsetInBytes, modelData.lengthInBytes),
    );
    copySw.stop();
    log("⏱️ [Singleton] writeAsBytes(model) 耗时: ${copySw.elapsedMilliseconds}ms, 大小: ${(modelData.lengthInBytes / 1024 / 1024).toStringAsFixed(1)}MB");
    StartupLogger.log("writeAsBytes(model)", copySw.elapsedMilliseconds, extra: "${(modelData.lengthInBytes / 1024 / 1024).toStringAsFixed(1)}MB");
    log("📦 [Singleton] model.int8.onnx 拷贝完成");

    // 拷贝 tokens.txt
    final tokensData = await rootBundle.load('assets/tokens.txt');
    await tokensFile.writeAsBytes(
      tokensData.buffer.asUint8List(tokensData.offsetInBytes, tokensData.lengthInBytes),
    );
    log("📦 [Singleton] tokens.txt 拷贝完成");

    debugPrint("✅ [Singleton] 内置模型拷贝完成: $bundledDir");
    return bundledDir;
  }

  /// 从 SharedPreferences 刷新模型路径缓存（不加载模型）
  /// 可在应用启动、模型导入后调用，使 hasModel 正确判断
  /// ⚠️ 调用时机：main() 启动时、settings_tab 导入模型后、tab 切换时 refreshEngine
  /// 会自动确保内置模型已拷贝到本地
  static Future<void> preloadModelPath() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final customPath = prefs.getString('custom_model_path');

      if (customPath != null && Directory(customPath).existsSync()) {
        // 用户手动导入过模型，优先使用
        _currentModelPath = customPath;
        log("📍 [Singleton] preloadModelPath: 使用用户导入的模型, path=$_currentModelPath, hasModel=$hasModel");
      } else {
        // 没有用户导入的模型，使用内置模型
        final bundledDir = await _ensureBundledModel();
        _currentModelPath = bundledDir;
        log("📍 [Singleton] preloadModelPath: 使用内置模型, path=$_currentModelPath, hasModel=$hasModel");
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
  /// 优先使用用户导入的模型，如果没有则自动使用内置模型
  Future<bool> initialize() async {
    // 如果已经初始化完成，直接返回
    // 热切换守卫（bb769ce）：必须"已就绪且模型路径未变"（worker 实际加载目录 ==
    // 当前期望路径）才短路——导入新模型后旧模型还活着 isReady=true，只判 isReady
    // 会让新模型永远加载不上；路径变了继续往下走 _service.initialize(新路径)，
    // 由 worker 先建新再释旧
    if (_service.isReady && _service.loadedModelDir == _currentModelPath) {
      return true;
    }

    // 如果正在初始化中，等待完成
    if (_isInitializing) {
      // 最多等待 30 秒
      int attempts = 0;
      while (_isInitializing && attempts < 300) {
        await Future.delayed(const Duration(milliseconds: 100));
        attempts++;
      }
      return _service.isReady;
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
      // 热切换守卫同上（bb769ce）：必须与 worker 实际已加载目录比较——
      // `_currentModelPath == modelDir` 恒为 true（modelDir 就是刚从
      // _currentModelPath 取的），那样等于只判 isReady，同样挡热切换
      if (_service.isReady && _service.loadedModelDir == modelDir) {
        _isInitializing = false;
        return true;
      }

      debugPrint("🔄 开始加载模型: $modelPath");

      // 模型加载 + 内联预热在常驻 worker isolate（RecognitionService，9edb24f）内
      // 完成，主 isolate 只收发消息。⚠️ 勿改回"主 isolate Future 里直接 new
      // OfflineRecognizer"：Future 只让出事件循环，同步 FFI 构造仍冻结 UI。
      // _currentModelPath 本身就是模型目录（bundled_model/ 或用户导入目录），
      // 与 RecognitionService.initialize(modelDir) 入参语义直接对齐，原样传入。
      final loadSw = Stopwatch()..start();
      final ok = await _service.initialize(modelDir);
      loadSw.stop();
      log("⏱️ [Singleton] 模型加载到内存 耗时: ${loadSw.elapsedMilliseconds}ms");
      StartupLogger.log("模型加载到内存", loadSw.elapsedMilliseconds);

      if (!ok) {
        debugPrint("❌ 模型加载失败(worker isolate)");
        _isInitializing = false;
        return false;
      }

      _hasEverInitialized = true;

      debugPrint("✅ 模型加载完成");
      _isInitializing = false;
      return true;
    } catch (e) {
      debugPrint("❌ 模型加载失败: $e");
      _isInitializing = false;
      return false;
    }
  }

  /// 单段 PCM 识别为文本（worker isolate 内 decode，不冻结主 isolate UI）
  /// samples：16kHz 单声道归一化采样（与原 diary_tab._recognizeSamplesToText
  /// 入参一致）
  /// ⚠️ 未就绪抛 StateError、超时抛 TimeoutException（与 RecognitionService
  /// 一致，调用方自行 try-catch 或前置 isReady 守卫）
  Future<String> transcribe(Float32List samples) =>
      _service.transcribe(samples);

  /// 预热引擎（worker 内 0.1s 静音 decode，幂等不抛；未就绪时静默返回）
  Future<void> warmup() => _service.warmup();

  /// 释放资源
  /// 通知 worker isolate 退出（Isolate.exit + 端口清理）。_service.dispose() 是
  /// Future，这里用 unawaited 保持原同步签名（签名兼容优先）。
  void dispose() {
    unawaited(_service.dispose());
    // 旧 service 已终态不可复用（RecognitionService.dispose 后 initialize 永远
    // 拒绝），换新实例——下一次 initialize() 会重新 spawn worker 加载模型。
    // 调用方（overlay 语音速记 idle 释放）正是靠"dispose 后可再 initialize"。
    // _hasEverInitialized 不回退（splash 冷/热启动判断语义保持）
    _service = RecognitionService();
    _currentModelPath = null;
    _isInitializing = false;
  }
}
