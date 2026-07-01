import 'dart:async';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;
import 'package:audioplayers/audioplayers.dart';

/// 内置 TTS 模型在本地文件系统中的目录名
//  ⚠️ 不与 ASR 的 bundled_model/ 共享目录：
//     两个 tokens.txt 同名但内容不同（ASR 的 SenseVoice tokens vs TTS 的 Piper tokens），
//     混目录会互相覆盖。
//
//  ⚠️ 目录名带版本号（v2）：v1 的 ONNX 缺 voice/has_espeak metadata 字段，
//     导致 sherpa-onnx 传空字符串给 espeak_SetVoiceByName 回退到非中文声音。
//     bump 到 v2 强制已安装用户重新从 assets 拷贝修复后的 ONNX。
//     后续如再需强制重拷贝（如修 espeak-ng-data），继续 bump 到 v3/v4...
const String _kBundledTtsDirName = 'bundled_tts_v2';

/// TTS 单例
///
/// 搬家模式语音播报使用（"已保存电脑到客厅"），懒加载：
/// - 搬家模式首次开启时由 record_tab.dart `_enterMoveMode` 调用 [initialize]
/// - APP 生命周期内不释放（参考 RecognizerSingleton 模式），下次进搬家模式直接复用
///
/// 内置模型拷贝逻辑参考 [RecognizerSingleton._ensureBundledModel]，
/// 文件存在则跳过，避免每次开启搬家模式都走 IO。
///
/// ⚠️ [speak] 内部串行化（_speakLock）：搬家场景连说多个物品时，
///    新调用直接 return 丢弃（宁可丢一句 TTS 也不堆队列）。
class TtsSingleton {
  static final TtsSingleton instance = TtsSingleton._();
  TtsSingleton._();

  sherpa_onnx.OfflineTts? _tts;
  bool _isInitializing = false;
  bool _hasEverInitialized = false;
  String? _bundledTtsDir; // 缓存内置模型目录路径

  /// 串行化 speak：上一句没播完时新调用直接 return
  //  用 Completer 而非 bool：speak 内部多段 await（generate/writeWave/play/complete），
  //  bool 需要每段都 try-finally 复位，容易漏；Completer 在 finally 里 complete 一次即可。
  Completer<void>? _speakLock;

  /// 是否已就绪
  bool get isReady => _tts != null;

  /// 是否正在初始化
  bool get isInitializing => _isInitializing;

  /// 是否曾经初始化过（用于判断冷热启动）
  bool get hasEverInitialized => _hasEverInitialized;

  /// 获取内置 TTS 模型在本地的目录路径
  Future<String> _getBundledTtsDir() async {
    final appDocDir = await getApplicationDocumentsDirectory();
    return p.join(appDocDir.path, _kBundledTtsDirName);
  }

  /// 校验 bundled_tts/ 目录完整性并缓存路径（零成本，可在 main() 调用）
  ///
  /// 与 [RecognizerSingleton.preloadModelPath] 对称：只做路径缓存，不加载模型。
  /// 当前未在 main() 中调用（TTS 懒加载，首次进搬家模式才用），
  /// 保留方法以便后续如需提前预热（如 splash 阶段）可直接调用。
  static Future<void> preloadModelPath() async {
    if (instance._bundledTtsDir != null) return;
    try {
      final dir = await instance._getBundledTtsDir();
      // 校验关键文件存在性（onnx + tokens + espeak-ng-data 目录）
      final modelOk = File(p.join(dir, 'zh_CN-huayan-x_low.onnx')).existsSync();
      final tokensOk = File(p.join(dir, 'tokens.txt')).existsSync();
      final dataDirOk =
          Directory(p.join(dir, 'espeak-ng-data')).existsSync();
      if (modelOk && tokensOk && dataDirOk) {
        instance._bundledTtsDir = dir;
        print("📍 [TTS] preloadModelPath: 内置模型已就绪, dir=$dir");
      } else {
        print(
          "📍 [TTS] preloadModelPath: 内置模型不完整("
          "model=$modelOk, tokens=$tokensOk, dataDir=$dataDirOk)，"
          "等待 initialize 时拷贝",
        );
      }
    } catch (e) {
      debugPrint("⚠️ [TTS] preloadModelPath 失败: $e");
    }
  }

  /// 确保内置 TTS 模型已从 assets/tts-model/ 拷贝到本地目录
  ///
  /// 复用 [RecognizerSingleton._ensureBundledModel] 的同构逻辑：
  /// - 关键文件已存在 → 直接返回目录路径（跳过拷贝）
  /// - 不存在 → 从 assets 拷贝 onnx + tokens + 解压 espeak-ng-data.zip
  ///
  /// ⚠️ espeak-ng-data 目录原 357 个文件分布在 39 个子目录，
  ///    Flutter 的 assets 声明不递归子目录（`- assets/tts-model/espeak-ng-data/`
  ///    只打包直接文件，子目录文件丢失）。改为 zip 单文件打包 + 运行时解压：
  ///    1. onnx + tokens.txt → rootBundle.load 直接拷贝
  ///    2. espeak-ng-data.zip → ZipDecoder 解压到 bundledDir/
  ///
  /// ⚠️ 不再用 AssetManifest.json：Flutter 3.41 默认改用 AssetManifest.bin
  ///    二进制格式，loadString('AssetManifest.json') 会抛异常。
  Future<String> _ensureBundledTts() async {
    final bundledDir = await _getBundledTtsDir();

    // 关键文件存在性检查（与 preloadModelPath 一致）
    final modelFile = File(p.join(bundledDir, 'zh_CN-huayan-x_low.onnx'));
    final tokensFile = File(p.join(bundledDir, 'tokens.txt'));
    final dataDir = Directory(p.join(bundledDir, 'espeak-ng-data'));

    if (modelFile.existsSync() &&
        tokensFile.existsSync() &&
        dataDir.existsSync()) {
      final modelSize = await modelFile.length();
      print(
        "📍 [TTS] 模型已存在于本地: $bundledDir "
        "(${(modelSize / 1024 / 1024).toStringAsFixed(1)}MB)",
      );
      // 已存在也要跑铺平（升级场景：旧版安装未铺平，新版首次跑要补上）
      // 幂等：已存在的 voice 文件跳过
      await _flattenLangToVoices(bundledDir);
      _logEspeakDataDiagnosis(bundledDir);
      return bundledDir;
    }

    // 需要拷贝，先确保目录存在
    final dir = Directory(bundledDir);
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }

    print("📦 [TTS] 首次启动，从 assets/tts-model/ 拷贝到本地...");
    final copySw = Stopwatch()..start();

    // 1. 拷贝 onnx（20MB，直接 rootBundle.load）
    final onnxData =
        await rootBundle.load('assets/tts-model/zh_CN-huayan-x_low.onnx');
    await modelFile.writeAsBytes(
      onnxData.buffer.asUint8List(onnxData.offsetInBytes, onnxData.lengthInBytes),
    );

    // 2. 拷贝 tokens.txt
    final tokensData = await rootBundle.load('assets/tts-model/tokens.txt');
    await tokensFile.writeAsBytes(
      tokensData.buffer
          .asUint8List(tokensData.offsetInBytes, tokensData.lengthInBytes),
    );

    // 3. 解压 espeak-ng-data.zip 到 bundledDir/
    //    zip 内路径形如 "espeak-ng-data/cmn_dict", "espeak-ng-data/lang/aav/..."
    //    解压到 bundledDir/ 下保持同样的相对结构
    final zipData =
        await rootBundle.load('assets/tts-model/espeak-ng-data.zip');
    final bytes =
        zipData.buffer.asUint8List(zipData.offsetInBytes, zipData.lengthInBytes);
    final archive = ZipDecoder().decodeBytes(bytes);
    int fileCount = 0;
    for (final file in archive) {
      // file.name 已含 "espeak-ng-data/..." 前缀
      final outPath = p.join(bundledDir, file.name);
      if (file.isFile) {
        final outFile = File(outPath);
        await outFile.parent.create(recursive: true);
        await outFile.writeAsBytes(file.content as List<int>);
        fileCount++;
      } else {
        await Directory(outPath).create(recursive: true);
      }
    }

    copySw.stop();
    final modelSize = await modelFile.length();
    print(
      "⏱️ [TTS] 拷贝完成 耗时: ${copySw.elapsedMilliseconds}ms, "
      "模型大小: ${(modelSize / 1024 / 1024).toStringAsFixed(1)}MB, "
      "文件数: $fileCount",
    );
    print("📦 [TTS] 拷贝完成: $bundledDir");

    // 首次拷贝完成也要跑铺平 + 诊断（与"已存在"分支对称）
    await _flattenLangToVoices(bundledDir);
    _logEspeakDataDiagnosis(bundledDir);
    return bundledDir;
  }

  /// 把 espeak-ng-data/lang/<family>/<voice> 复制（铺平）到 voices/<voice>
  ///
  /// 兼容老版本 espeak-ng voice 查找逻辑：
  /// sherpa-onnx 内置 espeak 调用 SetVoiceByName("cmn") 时只扫 voices/<name>，
  /// 不扫 lang/<family>/<name>。而 Piper 中文模型的 cmn voice 文件实际在 lang/sit/cmn，
  /// voices/ 下只有 !v/ 子目录（variant voices）。
  ///
  /// 幂等：目标已存在则跳过，重复调用安全（升级场景：旧版安装未铺平，新版首次跑补上）。
  Future<void> _flattenLangToVoices(String bundledDir) async {
    final langDir = Directory(p.join(bundledDir, 'espeak-ng-data/lang'));
    final voicesDir = Directory(p.join(bundledDir, 'espeak-ng-data/voices'));
    if (langDir.existsSync() && voicesDir.existsSync()) {
      int copied = 0;
      for (final familyDir in langDir.listSync().whereType<Directory>()) {
        for (final entity in familyDir.listSync()) {
          if (entity is! File) continue;
          final voiceName = p.basename(entity.path);
          final targetPath = p.join(voicesDir.path, voiceName);
          if (!File(targetPath).existsSync()) {
            await entity.copy(targetPath);
            copied++;
          }
        }
      }
      print("📋 [TTS] 已铺平 lang/*/voices → voices/ ($copied 个文件)");
    } else {
      print("⚠️ [TTS] lang 或 voices 目录缺失，无法铺平");
    }
  }

  /// 诊断日志：列出 espeak-ng-data/ 顶层文件 + 关键 voice 文件存在性
  ///
  /// 用于真机 logcat 直接判断 zip 解压是否完整 + 铺平是否生效。
  void _logEspeakDataDiagnosis(String bundledDir) {
    final espeakDir = Directory(p.join(bundledDir, 'espeak-ng-data'));
    if (espeakDir.existsSync()) {
      final topFiles = espeakDir.listSync()
          .where((e) => e is File)
          .map((f) {
            final size = (f as File).lengthSync();
            return '${p.basename(f.path)}(${(size / 1024).toStringAsFixed(1)}KB)';
          })
          .join(', ');
      print("📋 [TTS] espeak-ng-data 顶层文件: $topFiles");
      // 关键文件单独标记
      final cmnVoice = File(p.join(bundledDir, 'espeak-ng-data/lang/sit/cmn'));
      print(
        "📋 [TTS] lang/sit/cmn 存在=${cmnVoice.existsSync()} "
        "大小=${cmnVoice.existsSync() ? cmnVoice.lengthSync() : 0}B",
      );
      // 验证 voice 文件铺平后是否可见
      final cmnInVoices = File(p.join(bundledDir, 'espeak-ng-data/voices/cmn'));
      print(
        "📋 [TTS] voices/cmn 存在=${cmnInVoices.existsSync()} "
        "大小=${cmnInVoices.existsSync() ? cmnInVoices.lengthSync() : 0}B",
      );
    } else {
      print("⚠️ [TTS] espeak-ng-data/ 目录不存在！");
    }
  }

  /// 初始化 TTS 引擎（异步，不阻塞 UI）
  ///
  /// 调用时机：搬家模式首次开启时（record_tab.dart `_enterMoveMode`）。
  /// 失败不抛出（调用方已 try-catch），返回 false。
  Future<bool> initialize() async {
    if (_tts != null) return true;
    if (_isInitializing) {
      // 最多等待 30 秒
      int attempts = 0;
      while (_isInitializing && attempts < 300) {
        await Future.delayed(const Duration(milliseconds: 100));
        attempts++;
      }
      return _tts != null;
    }

    _isInitializing = true;
    try {
      final base = _bundledTtsDir ??= await _ensureBundledTts();

      final modelPath = p.join(base, 'zh_CN-huayan-x_low.onnx');
      final tokensPath = p.join(base, 'tokens.txt');
      // sherpa-onnx 期望 dataDir 指向 espeak-ng-data 目录本身（直接在 dataDir 下找 phontab/phondata/phonindex）
      // 实测验证：传父目录会报 ".../bundled_tts/phontab does not exist"
      final dataDirPath = p.join(base, 'espeak-ng-data');

      if (!File(modelPath).existsSync() || !File(tokensPath).existsSync()) {
        debugPrint("⚠️ [TTS] 模型文件不存在: $modelPath 或 $tokensPath");
        _isInitializing = false;
        return false;
      }
      if (!Directory(dataDirPath).existsSync()) {
        debugPrint("⚠️ [TTS] espeak-ng-data 目录不存在: $dataDirPath");
        _isInitializing = false;
        return false;
      }

      print("🚀 [TTS] 初始化 OfflineTts, model=$modelPath");
      final initSw = Stopwatch()..start();

      // 【关键】OfflineTts 构造是同步阻塞的（FFI calloc + native init），
      //   必须包在 Future 里让 event loop 调度，否则卡 UI 几百毫秒。
      //   禁用 compute()——OfflineTts.ptr 是 FFI 指针，跨 isolate 不可用。
      await Future(() {
        // Piper 中文模型走 espeak-ng 路径：
        //   - lexicon 必须留空（否则与 espeak-ng 音素化冲突）
        //   - dataDir 指向 espeak-ng-data/（含 cmn_dict + phonemes/）
        final vitsConfig = sherpa_onnx.OfflineTtsVitsModelConfig(
          model: modelPath,
          lexicon: '', // ⚠️ Piper 走 espeak-ng 路径，必须留空
          tokens: tokensPath,
          dataDir: dataDirPath,
        );
        final modelConfig = sherpa_onnx.OfflineTtsModelConfig(
          vits: vitsConfig,
          numThreads: 2,
          debug: false,
          provider: 'cpu',
        );
        final config = sherpa_onnx.OfflineTtsConfig(
          model: modelConfig,
          ruleFsts: '',
          maxNumSenetences: 2,
        );
        _tts = sherpa_onnx.OfflineTts(config);
      });

      initSw.stop();
      print("⏱️ [TTS] OfflineTts 创建耗时: ${initSw.elapsedMilliseconds}ms");
      print("✅ [TTS] 初始化成功");
      _hasEverInitialized = true;
      _isInitializing = false;
      return true;
    } catch (e) {
      debugPrint("❌ [TTS] 初始化失败: $e");
      _isInitializing = false;
      _tts = null;
      return false;
    }
  }

  /// 播报文本（核心契约）
  ///
  /// 流程：
  /// 1. 未就绪/已在播报 → 直接 return（丢弃，不堆队列）
  /// 2. generate 同步阻塞 → 包 Future 让 event loop 调度
  /// 3. writeWave 写临时 WAV 到 getTemporaryDirectory()
  /// 4. 独立 AudioPlayer 播放（mixWithOthers，不抢音频焦点）
  /// 5. await onPlayerComplete → 释放 player + 删 WAV
  ///
  /// ⚠️ 调用方负责设置 `_isTtsPlaying` 标志位 + clear VAD（防回采），
  ///    本方法只管"生成+播放+清理"，不感知录音状态（职责分离）。
  Future<void> speak(String text) async {
    if (_tts == null) return;
    // 串行化：上一句没播完直接丢弃（搬家场景宁可丢也不堆队列）
    if (_speakLock != null) return;

    _speakLock = Completer<void>();
    try {
      // 1. 生成音频（同步阻塞，必须包 Future）
      //    ⚠️ FFI 抛 Error 不是 Exception，必须 catch Object 拦截；
      //       但若 native SIGABRT（C++ exception → abort），Dart 端拦不住，
      //       真正修复靠 dataDir 改对（见 initialize 中 dataDirPath 注释）。
      sherpa_onnx.GeneratedAudio audio;
      try {
        audio = await Future(
          () => _tts!.generate(text: text, sid: 0, speed: 1.0),
        );
      } catch (e, st) {
        print('❌ [TTS] generate 崩溃（dataDir 可能不对）: $e\n$st');
        // 不再 throw，让调用方继续（避免 APP 整个崩）
        return;
      }
      if (audio.samples.isEmpty) {
        print("⚠️ [TTS] generate 返回空音频，跳过播放");
        return;
      }

      // 2. 写临时 WAV
      final tmpDir = await getTemporaryDirectory();
      final wavPath = p.join(
        tmpDir.path,
        'tts_${DateTime.now().microsecondsSinceEpoch}.wav',
      );
      sherpa_onnx.writeWave(
        filename: wavPath,
        samples: audio.samples,
        sampleRate: audio.sampleRate,
      );

      // 3. 用独立 AudioPlayer 播放（mixWithOthers，不抢音频焦点）
      //    ⚠️ 不能用 record_tab 的 _sfxPlayer：play() 自带 stop 当前播放，
      //       长音频 TTS 会被 SFX 的 stop 截断。
      //    AudioContext 必须设 mixWithOthers（即 AndroidAudioFocus.none）：
      //       默认 gain 会让 record 包失去 audio focus 停止 PCM 流。
      //       （与 record_tab.dart _sfxPlayer 同款配置，详见字段注释）
      final player = AudioPlayer();
      await player.setAudioContext(
        AudioContextConfig(focus: AudioContextConfigFocus.mixWithOthers).build(),
      );
      await player.play(DeviceFileSource(wavPath));

      // 4. 等播放完成
      await player.onPlayerComplete.first;

      // 5. 清理
      await player.release();
      try {
        await File(wavPath).delete();
      } catch (e) {
        // 删临时文件失败不影响主流程
        debugPrint("⚠️ [TTS] 删除临时 WAV 失败: $e");
      }
    } finally {
      _speakLock!.complete();
      _speakLock = null;
    }
  }

  /// 释放 native 资源
  ///
  /// 当前 APP 生命周期内不调用（参考 RecognizerSingleton 模式），
  /// 保留方法以便后续如需在退出搬家模式时释放（Phase 2 决策）。
  void dispose() {
    if (_tts != null) {
      _tts!.free();
      _tts = null;
      _bundledTtsDir = null;
      _isInitializing = false;
      print("🧹 [TTS] 已释放");
    }
  }
}
