import 'dart:typed_data';
import 'dart:developer' as dev;
import 'dart:async'; // StreamSubscription（搬家模式 PCM 流订阅）
import 'dart:math' show sqrt;
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:vibration/vibration.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;
import 'package:audioplayers/audioplayers.dart';
import '../db_helper.dart';
import '../text_processor.dart';
import '../recognizer_singleton.dart';
import '../widgets/blur_loading_overlay.dart';
import '../app_logger.dart';
import '../utils/item_splitter.dart';
import '../vad_singleton.dart';
import '../tts_singleton.dart';
import '../theme/app_theme_extension.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

class RecordTab extends StatefulWidget {
  final TextProcessor processor;
  final DbHelper dbHelper;
  final Function(bool show, {String? message})? onLoadingChanged;
  final VoidCallback? onStateChanged; // 状态变化通知 main.dart 重建外层按钮栏（仿 ListTab）

  const RecordTab({
    super.key,
    required this.processor,
    required this.dbHelper,
    this.onLoadingChanged,
    this.onStateChanged,
  });

  @override
  State<RecordTab> createState() => RecordTabState(); // 改为公开 State 类名
}

class RecordTabState extends State<RecordTab> with WidgetsBindingObserver {
  final _audioRecorder = AudioRecorder();
  final TextEditingController _itemController = TextEditingController();
  final TextEditingController _locationController = TextEditingController();

  // 用于跟踪App生命周期状态，区分真正的后台恢复和通知栏操作
  AppLifecycleState? _lastState;
  bool _wasInBackground = false; // 标记是否真正进入过后台（paused或hidden）
  DateTime? _pausedTime; // 记录进入后台的时间戳，用于判断短时间后台恢复
  static const Duration _shortBackgroundThreshold = Duration(
    minutes: 10,
  ); // 短时间后台的阈值

  // 使用单例管理器
  final _recognizerManager = RecognizerSingleton.instance;
  sherpa_onnx.OfflineRecognizer? get _recognizer =>
      _recognizerManager.recognizer;

  List<double> _audioBuffer = [];
  bool _isReady = false;
  bool _isListening = false;
  bool _isProcessing = false;
  bool _isFirstVisible = true; // 是否首次显示
  bool _isInitializing = false; // 是否正在初始化
  String _statusText = "按住录音";

  // 暴露给 main.dart 外层 Stack 的钉底按钮栏使用（仿 ListTab getter 模式）
  // 按钮已搬到 main.dart _buildRecordBottomBar，这里只提供只读状态 + 方法入口
  bool get isReady => _isReady;
  bool get isListening => _isListening;
  bool get isProcessing => _isProcessing;
  bool get isMoveMode =>
      _isMoveMode; // 搬家模式时 main.dart 外层录音/保存按钮栏不显示（避免与搬家撤销按钮重叠）
  String get statusText => _statusText;
  void startListening() => _startListening();
  void stopListening() => _stopListening();
  void saveData() => _saveData();

  // ── 搬家模式字段 ──
  bool _isMoveMode = false; // 搬家模式总开关
  bool _isTtsPlaying = false; // TTS 播报中（回采屏蔽三层防御的标志位）
  bool _ttsEnabled =
      true; // 搬家模式 TTS 保存播报开关（仅控制 _playTtsFeedback，不影响撤销 _speakRaw；持久化 key: move_mode_tts_enabled）
  int _moveSavedCount = 0; // 本场已保存条数（UI 显示，退出不清零，作为"本场共 N 条"统计）
  int _moveSegmentSeq = 0; // VAD 切段流水号（仅日志诊断用，_enterMoveMode 时清零，便于看本场切段数与识别关联）
  // 最近保存记录列表（最多保留 5 条，最新在尾部）
  // 每条记录保存 rowid + 预览文字，用于列表内撤销（替代旧的 SnackBar 撤销）
  final List<_MoveSaveRecord> _recentSaves = [];
  StreamSubscription? _moveStreamSub; // PCM 流订阅（手动管理，dispose 时 cancel）
  String? _moveSplitError; // 搬家模式智能分割失败提示文本（非 null 时底部显示可左滑消除的提示条）
  Timer? _splitErrorTimer; // 提示条 8s 自动消失计时器
  int _splitErrorSeq = 0; // 提示条 Dismissible key 序号（每次新错误自增，保证 key 唯一）

  // ── 搬家模式：屏幕常亮 + 闲置降亮 ──
  // 设计意图：搬家过程持续录音不能黑屏（wakelock 保活），但全亮刺眼+耗电，
  // 10s 内无操作盖上半透明遮罩（OLED 真省电），触摸立即恢复全亮并重新计时。
  // 上下游：_enterMoveMode 启用 → _exitMoveMode 关闭；_onUserInteract 重置。
  bool _isDimmed = false; // 当前是否处于降亮遮罩状态
  Timer? _idleDimTimer; // 闲置降亮计时器
  static const Duration _kDimDelay = Duration(seconds: 10); // 闲置多久后变暗
  static const double _kDimOpacity = 0.55; // 遮罩不透明度
  // 注：plan 原列 _kDimAnimDuration 字段，但第一版明确不用动画（直接 if 渲染），
  // 该字段无引用，已删除避免 unused_field 警告。后续若加 AnimatedOpacity 再补回。

  // ── 搬家模式：语音撤销命令配置 ──
  // 用户听到 TTS 念错后（如"电扇"识别成"电脑"），不方便看手机点撤销按钮，
  // 可在 10 秒窗口内说"不对"/"撤销"等关键词自动撤销上一条 + TTS 回显"已撤销"。
  // 设计要点：
  // 1) 白名单严格匹配（≤5 字纯中文），避免长句里的"不对"误命中
  // 2) 10 秒窗口不阻塞正常录入——超时或非命中关键词的文本走 ItemSplitter 正常保存
  // 3) 与 _undoSave (UI 撤销按钮) 复用同一删除路径
  static const Set<String> _kUndoKeywords = {
    '不对',
    '撤销',
    '错了',
    '取消',
    '删掉',
    '不是这个',
  };
  static const int _kUndoMaxTextLen = 5; // 撤销命令文本最大长度（避免长句误命中）
  static const int _kUndoWindowSeconds = 10; // 撤销时间窗口（秒）

  // 搬家模式声音提示：成功=高音叮(880+1320Hz)、失败=低音嗡(220+224Hz)
  // 复用一个 AudioPlayer 实例，play() 自带 stop 当前播放，连说连报不会重叠堆积
  //
  // ⚠️ audioContext 必须设 mixWithOthers（即 AndroidAudioFocus.none）：
  //    默认 gain 会请求音频焦点，Android 系统按"后来者居上"把焦点给 MediaPlayer，
  //    record 包的录音器收到 AUDIOFOCUS_LOSS(-1) 后会停止 PCM 流，搬家模式第一次
  //    播放提示音后录音就断了。mixWithOthers 不抢焦点，与录音并存。
  //    AudioPlayer 6.6 构造函数不接受 audioContext，必须用 setAudioContext 异步配，
  //    在 initState 里 fire-and-forget 即可（player 内部 await creatingCompleter）。
  final AudioPlayer _sfxPlayer = AudioPlayer();

  // TTS 播报播放器（搬家模式语音确认）
  // 独立实例，不与 _sfxPlayer 共用：_sfxPlayer.play() 自带 stop 当前播放，
  // 长音频 TTS 会被 SFX 的 stop 截断。AudioContext 同样配 mixWithOthers（initState 里设置）。
  final AudioPlayer _ttsPlayer = AudioPlayer();

  // 2. 增加一个公开的刷新方法
  /// 公开方法：供 MainScaffold 调用，按需初始化引擎
  Future<void> initializeIfNeeded() async {
    // 刷新模型路径缓存，使 hasModel 判断正确
    await RecognizerSingleton.preloadModelPath();
    log(
      "📍 [Record] initializeIfNeeded: _isReady=$_isReady, hasModel=${RecognizerSingleton.hasModel}",
    );

    // 如果已经加载成功，不重复加载
    if (_isReady && _recognizerManager.isReady) return;

    // 🆕 启动页已完成模型加载，直接同步状态（跳过重复加载）
    if (_recognizerManager.isReady) {
      setState(() {
        _isReady = true;
        _statusText = "长按录音";
      });
      log("📍 [Record] 启动页已加载模型，同步状态");
      return;
    }

    // 🆕 如果单例已经初始化过，直接同步状态
    if (_recognizerManager.hasEverInitialized) {
      setState(() => _statusText = "正在检查引擎...");
      await _initEngine();
      return;
    }

    // 🆕 首次进入时不自动加载模型，但刷新 UI（按钮颜色可能因 hasModel 变化而更新）
    if (_isFirstVisible) {
      setState(() {
        _isFirstVisible = false;
      });
    } else {
      setState(() {}); // 强制重建 UI
    }
  }

  @override
  void initState() {
    super.initState();
    // 注册生命周期监听，支持从桌面恢复时预热引擎
    WidgetsBinding.instance.addObserver(this);

    // 🆕 不再在首次进入时自动初始化引擎
    // 模型将在用户停止录音后加载，确保录音流程不被打断

    // 配置音效播放器：mixWithOthers = AndroidAudioFocus.none
    // 不抢音频焦点，避免与 record 包的录音器冲突（详见 _sfxPlayer 字段注释）
    // fire-and-forget：setAudioContext 内部 await creatingCompleter，不影响调用线程
    _sfxPlayer.setAudioContext(
      AudioContextConfig(focus: AudioContextConfigFocus.mixWithOthers).build(),
    );
    // TTS 播报播放器同款 mixWithOthers 配置（详见 _ttsPlayer 字段注释）
    _ttsPlayer.setAudioContext(
      AudioContextConfig(focus: AudioContextConfigFocus.mixWithOthers).build(),
    );

    // 读取搬家模式 TTS 开关持久化值（fire-and-forget，默认 true 保持现有行为）
    SharedPreferences.getInstance().then((prefs) {
      _ttsEnabled = prefs.getBool('move_mode_tts_enabled') ?? true;
      if (mounted) setState(() {});
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    // 搬家模式中 app 进后台（被切走、按 Home 键、来电等）→ 自动退出
    // 防止后台持续录音导致 native 资源泄漏 + 隐私问题
    // 用 paused + inactive 两个状态都触发，比单 paused 更稳
    // （Android 多窗口切走时可能只触发 inactive）
    if (_isMoveMode &&
        (state == AppLifecycleState.paused ||
            state == AppLifecycleState.inactive)) {
      log('🔄 [搬家模式] 检测到 app 进后台，自动退出');
      _exitMoveMode();
    }

    // 调试日志：打印所有状态变化
    log(
      "🔍 [生命周期] 录入页状态变化: $_lastState → $state, _isReady=$_isReady, _wasInBackground=$_wasInBackground",
    );

    // 标记是否进入过后台，并记录时间戳
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _wasInBackground = true;
      _pausedTime = DateTime.now(); // 记录进入后台的时间
      log("录入页：进入后台，记录时间戳: $_pausedTime");
    }

    // 只在从后台恢复到前台时才预热（真正的后台恢复，而非通知栏操作）
    // 条件：经历过后台 + 现在恢复到resumed + 引擎已就绪
    if (_wasInBackground && state == AppLifecycleState.resumed && _isReady) {
      // 计算后台时长
      final backgroundDuration = _pausedTime != null
          ? DateTime.now().difference(_pausedTime!)
          : Duration.zero;

      final isShortBackground = backgroundDuration < _shortBackgroundThreshold;

      log(
        "录入页：从后台恢复，后台时长: ${backgroundDuration.inSeconds}秒，是否短时间后台: $isShortBackground",
      );

      if (isShortBackground) {
        // 短时间后台：静默预热，不显示loading
        log("录入页：短时间后台恢复，静默预热");

        Future.delayed(const Duration(milliseconds: 50), () async {
          await _warmupEngine();
          if (mounted) {
            log("录入页：静默预热完成");
          }
        });
      } else {
        // 长时间后台：显示全局loading并预热
        log("录入页：长时间后台恢复，显示loading并预热");

        // 回调显示全局loading
        final stopwatch = Stopwatch()..start();
        widget.onLoadingChanged?.call(
          true,
          message: BlurLoadingOverlay.getRandomMessage(),
        );

        // 异步执行预热
        Future.delayed(const Duration(milliseconds: 50), () async {
          await _warmupEngine();
          if (mounted) {
            // 回调隐藏全局loading
            stopwatch.stop();
            log(
              "🔍 [性能检测] 录入页后台恢复预热高斯模糊loading耗时: ${stopwatch.elapsedMilliseconds}ms",
            );
            widget.onLoadingChanged?.call(false);
            log("录入页：后台恢复预热完成");
          }
        });
      }

      // 重置后台标记和时间戳
      _wasInBackground = false;
      _pausedTime = null;
    }

    _lastState = state;
  }

  @override
  void dispose() {
    // 移除生命周期监听
    WidgetsBinding.instance.removeObserver(this);
    // 搬家模式资源清理：cancel 返回 Future 但 dispose 同步，按 Dart 惯例不 await
    _moveStreamSub?.cancel();
    // 闲置降亮计时器同步清理（wakelock 由 _exitMoveMode / didChangeAppLifecycleState 负责）
    _idleDimTimer?.cancel();
    VadSingleton.instance.dispose();
    _sfxPlayer.dispose(); // 释放 audioplayers native 资源
    _ttsPlayer.dispose();
    _audioRecorder.dispose();
    _itemController.dispose();
    _locationController.dispose();
    // 不再在这里释放识别器，因为它是单例共享的
    super.dispose();
  }

  // ⚠️ 【延迟加载关键】不能检查 _isProcessing
  // 调用链：_stopListening → _isProcessing=true → _initEngine() → 加载模型 → _isReady=true
  // 上下游：_isReady → 控制 build 中按钮颜色、main.dart 浮动按钮（仅日记页）
  Future<void> _initEngine() async {
    if (_isReady) return;

    // 检查权限
    if (await Permission.microphone.request().isGranted) {
      // 分步打印，观察进度
      setState(() => _statusText = "正在唤醒引擎...");

      // 使用单例初始化
      final success = await _recognizerManager.initialize();

      if (mounted) {
        setState(() {
          _isReady = success;
          _statusText = success ? "长按录音" : "⚠️ 请先在设置中导入模型";
        });
      }
    } else {
      if (mounted) {
        setState(() {
          _isReady = false;
          _statusText = "⚠️ 需要麦克风权限";
        });
      }
    }
  }

  // 预热引擎：执行一次空识别，避免第一次使用时卡顿
  Future<void> _warmupEngine() async {
    if (_recognizer == null) return;

    try {
      // 创建一个空的音频流（0.1秒的静音）
      final sampleRate = 16000;
      final silentSamples = List.filled(sampleRate ~/ 10, 0.0); // 0.1秒静音

      final stream = _recognizer!.createStream();
      stream.acceptWaveform(
        samples: Float32List.fromList(silentSamples),
        sampleRate: sampleRate,
      );
      _recognizer!.decode(stream);
      _recognizer!.getResult(stream);
      stream.free();

      log("录入引擎预热完成");
    } catch (e) {
      log("录入引擎预热失败: $e");
    }
  }

  // 【优化 3】在用户长按时增加二次保险，如果引擎还没好，临时触发一次初始化
  void _startListening() async {
    if (_isProcessing) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("正在处理中...")));
      return;
    }

    // 🆕 只检查模型文件是否存在
    if (!RecognizerSingleton.hasModel) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("⚠️ 请先在设置中导入语音识别模型")));
      return;
    }

    // 🆕 先请求录音权限
    if (!await Permission.microphone.request().isGranted) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text("⚠️ 需要麦克风权限才能录音")));
      }
      return;
    }

    // 🆕 直接开始录音，不等待模型加载
    _vibrate(duration: 50, amplitude: 40);
    _audioBuffer.clear();
    final stream = await _audioRecorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
      ),
    );
    setState(() {
      _isListening = true;
      _statusText = "正在录音›...";
    });
    stream.listen(
      (data) =>
          _audioBuffer.addAll(_convertBytesToFloat32(Uint8List.fromList(data))),
    );
  }

  void _stopListening() async {
    if (_isProcessing) return; // 🆕 移除 _recognizer == null 检查

    final stopwatch = Stopwatch()..start();
    await _audioRecorder.stop();
    await Future.delayed(const Duration(milliseconds: 100));

    setState(() {
      _isListening = false;
      _isProcessing = true;
      _statusText = "正在识别...";
    });

    sherpa_onnx.OfflineStream? stream;
    try {
      // 🆕 关键改动：在识别前先加载模型（如果未加载）
      if (!_isReady || !_recognizerManager.isReady) {
        if (!_recognizerManager.hasEverInitialized) {
          // 显示 loading 提示
          widget.onLoadingChanged?.call(true, message: "正在加载语音识别模型...");

          try {
            await _initEngine();

            if (mounted) {
              widget.onLoadingChanged?.call(false);
            }

            // 检查加载是否成功
            if (!_isReady) {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text("⚠️ 模型加载失败，请检查设置")),
                );
                setState(() {
                  _isProcessing = false;
                  _statusText = "录音已停止";
                });
              }
              return;
            }
          } catch (e) {
            if (mounted) {
              widget.onLoadingChanged?.call(false);
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(SnackBar(content: Text("⚠️ 模型加载出错: $e")));
              setState(() {
                _isProcessing = false;
                _statusText = "录音已停止";
              });
            }
            return;
          }
        }
      }

      // 🆕 模型加载完成后，继续原有的识别逻辑
      if (_audioBuffer.isNotEmpty) {
        stream = _recognizer!.createStream();
        stream.acceptWaveform(
          samples: Float32List.fromList(_audioBuffer),
          sampleRate: 16000,
        );
        _recognizer!.decode(stream);
        final result = _recognizer!.getResult(stream);
        final rawText = result.text; // 拿到的原始语音文本

        if (rawText.isNotEmpty) {
          // ================= 【核心新增逻辑：智能日记识别】 =================
          if (rawText.startsWith("记录一下") || rawText.startsWith("记一下")) {
            // 1. 剥离关键字，拿到正文
            // 例如："记录一下今天心情很好" -> 变成 "今天心情很好"
            String diaryContent = rawText
                .replaceFirst("记录一下，", "")
                .replaceFirst("记一下，", "")
                .trim();

            if (diaryContent.isNotEmpty) {
              // 2. 直接调用 dbHelper 保存到日记表
              await widget.dbHelper.insertDiary(diaryContent);

              // 3. 弹出智能提示
              if (mounted) {
                // 【新增：重置 UI 状态】
                // 在 return 之前，必须把处理状态关掉，文字改回来
                setState(() {
                  _isProcessing = false;
                  _statusText = "按住录音";
                });
                final snackBarExt = AppThemeExtension.of(
                  context,
                ); // build 外使用主题色
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Row(
                      children: [
                        Icon(
                          Icons.auto_awesome,
                          color: snackBarExt.goldAccent, // 原 Colors.amber
                          size: 20,
                        ),
                        SizedBox(width: 10),
                        Text(
                          "智能识别：已为您存入随手记",
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                    backgroundColor:
                        snackBarExt.primaryDark, // 原 Colors.teal.shade700
                    behavior: SnackBarBehavior.floating,
                    duration: const Duration(seconds: 2),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                );
              }

              // 4. 重要：既然存了日记，就直接返回，不走下面"存物品"的输入框逻辑了
              return;
            }
          }
          // =============================================================

          // 如果不是以"记录一下"开头，则继续走原来的"存物品"逻辑
          final processedText = widget.processor.process(rawText);
          log("原始识别: $rawText");
          log("修正后文本: $processedText");
          AppLogger.appLog('🎤 [Record] 原始识别: $rawText');
          AppLogger.appLog('📝 [Record] 修正后文本: $processedText');

          setState(() {
            final res = _smartSplit(processedText);
            _itemController.text = res['item']!;
            if (res['location']!.isNotEmpty) {
              _locationController.text = res['location']!;
            }
          });
        }
      }
    } catch (e) {
      dev.log("❌ [识别出错]: $e");
      AppLogger.appLog('❌ [Record] 识别出错: $e');
      setState(() => _statusText = "识别出错");
    } finally {
      // 【最关键】无论成功还是报错，必须释放 C++ 层的流资源，防止闪退
      stream?.free();
      _audioBuffer.clear();
    }

    stopwatch.stop();
    // 改用 print，这样在任何过滤器下都更容易被看到
    log("----------------------------------------");
    log("🚀 [性能检测] 识别总耗时: ${stopwatch.elapsedMilliseconds} 毫秒");
    log("📝 识别结果: ${_itemController.text} | ${_locationController.text}");
    log("----------------------------------------");

    _vibrate(duration: 30, amplitude: 40);
    setState(() {
      _isProcessing = false;
      _statusText = "识别完成 (${stopwatch.elapsedMilliseconds}ms)";
    });

    Future.delayed(const Duration(seconds: 3), () {
      if (mounted && !_isListening && !_isProcessing) {
        setState(() => _statusText = "长按录音");
      }
    });
  }

  String _cleanPunctuation(String text) {
    // [，。！？,.!?] 匹配标点，\s 匹配任何空白字符（空格、制表符、换页符等）
    // 实际逻辑抽取到 ItemSplitter.cleanPunctuation，此处保留为 thin wrapper
    // 因为 record_tab 内多处直接调用 _cleanPunctuation，保留方法签名避免大改
    return ItemSplitter.cleanPunctuation(text);
  }

  Map<String, String> _smartSplit(String text) {
    // 核心拆分逻辑抽取到 ItemSplitter.detect
    // 此处保留原 fallback：未命中时返回 {"item": cleanText, "location": ""}
    final result = ItemSplitter.detect(text);
    if (result == null) {
      return {"item": _cleanPunctuation(text), "location": ""};
    }
    return {"item": result.item, "location": result.location};
  }

  void _saveData() async {
    String currentItem = _cleanPunctuation(_itemController.text);
    String currentLoc = _cleanPunctuation(_locationController.text);

    if (currentLoc.isEmpty && currentItem.isNotEmpty) {
      final splitRes = _smartSplit(currentItem);
      if (splitRes['location']!.isNotEmpty) {
        currentItem = splitRes['item']!;
        currentLoc = splitRes['location']!;
      }
    }

    if (currentItem.isNotEmpty && currentLoc.isNotEmpty) {
      // 【修改点】duration 缩短，amplitude 调低（40 左右很轻微）
      _vibrate(duration: 30, amplitude: 40);
      await widget.dbHelper.insertItem(currentItem, currentLoc);
      AppLogger.appLog('💾 [Record] 保存物品: $currentItem -> $currentLoc');
      _itemController.clear();
      _locationController.clear();
      setState(() => _statusText = "✅ 已保存");
      FocusScope.of(context).unfocus();
    } else {
      setState(() => _statusText = "⚠️ 请完善物品和位置");
    }
  }

  Float32List _convertBytesToFloat32(Uint8List bytes) {
    // ⚠️ record 包的 PCM chunk 是底层共享 ByteBuffer 的 view，
    //    offsetInBytes 不固定（实测 4、5 等奇偶值都会出现），
    //    asInt16List 要求 offset 必须 2 字节对齐，会抛 RangeError。
    //    解法：用 ByteData.sublistView 自动处理 offset，手动按 little-endian 读 PCM16。
    //    代价：每 sample 多一次 getInt16 调用，80ms chunk=1280 sample 性能损失可忽略。
    final int sampleCount = bytes.lengthInBytes ~/ 2;
    final float32Data = Float32List(sampleCount);
    final byteData = ByteData.sublistView(bytes);
    for (int i = 0; i < sampleCount; i++) {
      // PCM16 little-endian（Android ARM 默认字节序）
      final int sample = byteData.getInt16(i * 2, Endian.little);
      float32Data[i] = sample / 32768.0;
    }
    return float32Data;
  }

  // 调整后的振动函数，增加 amplitude 参数
  void _vibrate({int duration = 50, int amplitude = -1}) async {
    if (await Vibration.hasVibrator() ?? false) {
      // amplitude 为 -1 时使用系统默认强度，1-255 之间数字越大越强
      Vibration.vibrate(duration: duration, amplitude: amplitude);
    }
  }

  // ==================== 搬家模式 ====================

  /// 进入搬家模式：初始化 VAD + 启动持续录音
  Future<void> _enterMoveMode() async {
    if (_isMoveMode) return;
    setState(() {
      _isProcessing = true;
      _statusText = '正在初始化...';
    });
    try {
      await VadSingleton.instance.initialize();
      // 保险懒加载识别器
      if (!_recognizerManager.isReady) {
        await RecognizerSingleton.instance.initialize();
      }
      // 懒加载 TTS（首次进搬家模式时拷贝模型+创建实例）
      // 失败不阻塞搬家模式主流程，speak 时再判断 isReady 降级为音效
      try {
        await TtsSingleton.instance.initialize();
      } catch (e) {
        log('⚠️ [搬家模式] TTS 初始化失败，降级为音效: $e');
      }
      _audioBuffer.clear();
      final stream = await _audioRecorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
        ),
      );
      _moveStreamSub = stream.listen(_onMoveModePcm);
      setState(() {
        _isMoveMode = true;
        _isListening = true;
        _isProcessing = false;
        _moveSavedCount = 0;
        _moveSegmentSeq = 0; // 新一场切段流水号归零，方便日志看本场切段数
        _statusText = '搬家模式：请说出「物品+位置」';
      });
      // 搬家模式屏幕常亮（防止系统锁屏中断 PCM 流）+ 启动闲置降亮计时
      // 放在 setState 之后：确保 _isMoveMode 已 true，避免 enable 异常时污染已成功的状态
      try {
        await WakelockPlus.enable();
      } catch (e) {
        log("搬家模式启用 Wakelock 失败: $e");
      }
      _startIdleDimTimer();
    } catch (e) {
      log('❌ [搬家模式] 进入失败: $e');
      setState(() {
        _isProcessing = false;
        _statusText = '搬家模式启动失败：$e';
      });
    }
  }

  /// PCM 流回调：喂 VAD + 拉取分段
  //
  // ⚠️ 不要在这里 setState：原节流 setState 是给录音按钮染色的（按 vad.isDetected 变色），
  //    UI 改造后按钮已删除，节流 setState 完全多余，反而跟 _recognizeAndSave 里的
  //    setState 竞态，触发 !semantics.parentDataDirty assertion。
  //    现在 setState 只发生在 _recognizeAndSave 内（列表新增时），渲染时序稳定。
  void _onMoveModePcm(Uint8List data) {
    // 回采屏蔽第 1 层（最外层）：TTS 播放中麦克风采到的全是回采，
    // 持续 clear 防 VAD 把已 accept 的样本在 TTS 后切段输出。
    if (_isTtsPlaying) {
      VadSingleton.instance.vad?.clear();
      return;
    }
    final samples = _convertBytesToFloat32(data);
    VadSingleton.instance.vad?.acceptWaveform(samples);
    _drainVadSegments();

    // 诊断日志：每 30 帧（约 0.5s）打印一次 PCM RMS + VAD 状态
    _pcmChunkCounter++;
    if (_pcmChunkCounter % 30 == 0) {
      double sumSq = 0;
      for (final s in samples) {
        sumSq += s * s;
      }
      final rms = samples.isNotEmpty ? sqrt(sumSq / samples.length) : 0;
      final vad = VadSingleton.instance.vad;
      final isDetected = vad?.isDetected();
      final isEmpty = vad?.isEmpty();
      log(
        '📊 [搬家诊断] chunk#$_pcmChunkCounter '
        'bytes=${data.length} samples=${samples.length} '
        'rms=${rms.toStringAsFixed(4)} '
        'isDetected=$isDetected isEmpty=$isEmpty',
      );
    }
  }

  // PCM 帧计数（仅用于诊断日志节流）
  int _pcmChunkCounter = 0;

  /// 循环取出 VAD 已切分的段落，逐段识别保存
  void _drainVadSegments() {
    if (_isTtsPlaying) return; // 回采屏蔽第 2 层（双保险）
    final vad = VadSingleton.instance.vad;
    if (vad == null) return;
    while (!vad.isEmpty()) {
      final seg = vad.front();
      vad.pop();
      final samples = seg.samples;
      final seq = ++_moveSegmentSeq;
      // ── VAD 切段诊断日志（用于判定识别率低的根因） ──
      // 段长：判定首尾字被切（"袋子里"应 0.6-0.9s，过短=被切）
      // RMS：判定段内能量（弱音节"子" RMS 会低）
      // 头/尾静音：判定 VAD 边界是否在音节中间切断（正常应 < 50ms）
      final durationSec = samples.length / 16000.0;
      double sumSq = 0;
      for (final s in samples) {
        sumSq += s * s;
      }
      final rms = samples.isNotEmpty ? sqrt(sumSq / samples.length) : 0.0;
      const silenceThreshold = 0.01; // 约 -40dBFS，接近静音
      int headSilent = 0;
      for (final s in samples) {
        if (s.abs() < silenceThreshold) {
          headSilent++;
        } else {
          break;
        }
      }
      int tailSilent = 0;
      for (int i = samples.length - 1; i >= 0; i--) {
        if (samples[i].abs() < silenceThreshold) {
          tailSilent++;
        } else {
          break;
        }
      }
      log(
        '📦 [VAD#$seq] 段长 ${durationSec.toStringAsFixed(2)}s (${samples.length}样本), '
        'RMS ${rms.toStringAsFixed(4)}, '
        '头静音 ${(headSilent / 16).toStringAsFixed(0)}ms, '
        '尾静音 ${(tailSilent / 16).toStringAsFixed(0)}ms',
      );
      _recognizeAndSave(samples); // 不 await，循环继续
    }
  }

  /// 播放成功音（用户提供的 nextEditSuggestion.mp3 改名）
  /// 调用点：识别保存成功 / 手动保存成功
  void _playSuccess() {
    _sfxPlayer.play(AssetSource('sounds/success.mp3'));
  }

  /// 播放失败音（220+224Hz 拍频"嗡"，280ms）
  /// 调用点：识别为空 / 智能分割失败 / 异常
  void _playFailure() {
    _sfxPlayer.play(AssetSource('sounds/failure.wav'));
  }

  /// TTS 语音播报反馈（搬家模式专属）
  ///
  /// 调用点：`_recognizeAndSave` 成功保存后（替代单纯的 `_playSuccess` 音效）。
  /// 职责：
  /// 1. 设置 `_isTtsPlaying=true`（触发回采屏蔽三层防御）
  /// 2. 清空 VAD 已 accept 但未输出的样本（防 TTS 触发前用户刚说出口的尾巴被混入识别）
  /// 3. 调用 TtsSingleton.speak（内部串行化 + 独立 AudioPlayer）
  /// 4. 播完后多留 200ms 缓冲（喇叭余震 + 麦克风回声衰减）
  /// 5. 失败降级为音效
  Future<void> _playTtsFeedback(String item, String location) async {
    // TTS 开关关闭时直接 return（保存音效 _playSuccess 已在调用前播过，无需降级）
    if (!_ttsEnabled) return;
    setState(() => _isTtsPlaying = true);
    // 关键：TTS 开始前清空 VAD 已 accept 但未输出的样本
    // （防 TTS 触发前用户刚说出口的尾巴被混入识别）
    VadSingleton.instance.vad?.clear();
    try {
      final text = _buildTtsText(item, location);
      await TtsSingleton.instance.speak(text);
      // 播完后多留 200ms 缓冲（喇叭余震 + 麦克风回声衰减）
      await Future.delayed(const Duration(milliseconds: 200));
    } catch (e) {
      log('❌ [TTS] 播报失败，降级音效: $e');
      _playSuccess();
    } finally {
      if (mounted) setState(() => _isTtsPlaying = false);
    }
  }

  /// 构造 TTS 播报文本
  ///
  /// 清掉 emoji / 标点等 TTS 可能读成乱码的字符，固定模板"已保存{物品}到{位置}"。
  //  与 plan 第 3.7 节一致：insertItemReturningId 是纯 INSERT，恒用"已保存"文案。
  String _buildTtsText(String item, String location) {
    // 清掉 emoji / 标点等 TTS 可能读成乱码的字符
    final cleanItem = item.replaceAll(RegExp(r'[^\u4e00-\u9fa5a-zA-Z0-9]'), '');
    final cleanLoc = location.replaceAll(
      RegExp(r'[^\u4e00-\u9fa5a-zA-Z0-9]'),
      '',
    );
    return '已保存$cleanItem到$cleanLoc';
  }

  /// 识别单段语音 + 智能分割 + 写库
  Future<void> _recognizeAndSave(Float32List samples) async {
    if (_isTtsPlaying) {
      log('🔇 [搬家模式] TTS 播放中，丢弃残余段'); // 回采屏蔽第 3 层（最深层防御）
      return;
    }
    setState(() {
      _isProcessing = true;
      _statusText = '正在识别...';
    });
    try {
      final recognizer = _recognizer;
      if (recognizer == null) {
        log('⚠️ [搬家模式] 识别器未就绪，跳过本段');
        setState(() {
          _isProcessing = false;
          _statusText = '识别器未就绪';
        });
        return;
      }
      final stream = recognizer.createStream();
      stream.acceptWaveform(samples: samples, sampleRate: 16000);
      recognizer.decode(stream);
      final rawText = recognizer.getResult(stream).text;
      stream.free();
      log('🎤 [搬家模式] 识别结果: "$rawText"');
      if (rawText.isEmpty) {
        setState(() {
          _isProcessing = false;
          _statusText = '(未听到，继续说...)';
        });
        _playFailure();
        return;
      }
      final processed = widget.processor.process(rawText);
      // 🆕 撤销命令前置分流：检测到"不对"/"撤销"等关键词且窗口内 → 走撤销路径
      // 不阻塞正常录入：未命中关键词的文本继续走 ItemSplitter 正常保存
      if (_isUndoCommand(processed)) {
        await _handleUndoCommand();
        return;
      }
      // lenient: true → 宽松模式（搬家场景常见容器名如"3号盒子"无方位词，需放宽校验）
      final splitRes = ItemSplitter.detect(processed, lenient: true);
      if (splitRes == null) {
        // 智能分割失败：弹出带"手动保存"按钮的 SnackBar（步骤 5）
        log('⚠️ [搬家模式] 智能分割失败: "$processed"');
        setState(() {
          _isProcessing = false;
          _statusText = '没分出物品+位置: $processed';
        });
        _playFailure();
        _showSplitErrorBar(processed);
        return;
      }
      final id = await widget.dbHelper.insertItemReturningId(
        splitRes.item,
        splitRes.location,
      );
      setState(() {
        _recentSaves.add(
          _MoveSaveRecord(
            id: id,
            item: splitRes.item,
            location: splitRes.location,
            timeLabel: '刚刚',
            savedAt: DateTime.now(),
          ),
        );
        // 最多保留 5 条，超出最旧的丢掉（已写库不可撤销，仍可去 List Tab 删）
        if (_recentSaves.length > 5) {
          _recentSaves.removeAt(0);
        }
        _moveSavedCount++;
        _isProcessing = false;
        _statusText = '已保存 $_moveSavedCount 条';
      });
      _playSuccess();
      // TTS 播报（仅搬家模式 + 引擎就绪时；否则降级为音效）
      if (TtsSingleton.instance.isReady) {
        await _playTtsFeedback(splitRes.item, splitRes.location);
      } else {
        _playSuccess();
      }
      log('📝 [搬家模式] 已保存: ${splitRes.item} → ${splitRes.location} (id=$id)');
    } catch (e) {
      log('❌ [搬家模式] 识别保存失败: $e');
      setState(() {
        _isProcessing = false;
        _statusText = '识别失败：$e';
      });
      _playFailure();
    }
  }

  /// 列表内撤销单条记录（替代旧的 SnackBar 撤销）
  //  使用场景：搬家模式下，列表内每条记录卡片右侧的"撤销"按钮
  //  行为：删除 items 表对应行 + 从 _recentSaves 列表移除 + 计数 -1
  Future<void> _undoSave(int id) async {
    await widget.dbHelper.deleteItemById(id);
    setState(() {
      _recentSaves.removeWhere((r) => r.id == id);
      _moveSavedCount--;
      _statusText = '已撤销，本场共 $_moveSavedCount 条';
    });
    log('↩️ [搬家模式] 已撤销 id=$id');
  }

  /// 钉底「撤销最近」按钮回调：撤销最近一条 + 震动反馈
  //  与卡片撤销按钮(下面 _buildRecentSaveCard 内)同语义：直接调 _undoSave，不走语音撤销的
  //  10s 窗口判断(_handleUndoCommand)和 TTS 播报——手动按钮 = 明确意图，UI 已刷新可见。
  //  空态由 onPressed: null 自动 disable，这里仍防御性判空。
  Future<void> _undoLastManually() async {
    if (_recentSaves.isEmpty) return; // 防御性判空（onPressed 已守卫）
    _vibrate(duration: 40, amplitude: 80); // 中等强度，撤销确认（比保存轻震稍强）
    await _undoSave(_recentSaves.last.id); // 复用现成删除：DB 删行 + 列表移除 + 计数-1 + 状态文案
  }

  /// 撤销场景的纯文本播报（不走"已保存X到Y"模板）
  //  与 _playTtsFeedback 共享三层回采屏蔽机制（_isTtsPlaying + vad.clear）
  //  用途：语音撤销成功 / 超时 / 空记录 等场景的简短反馈
  Future<void> _speakRaw(String text) async {
    if (!TtsSingleton.instance.isReady) {
      // TTS 未就绪：降级为失败音效，至少给个反馈
      _playFailure();
      return;
    }
    setState(() => _isTtsPlaying = true);
    // 关键：TTS 开始前清空 VAD 已 accept 但未输出的样本（防回采污染撤销命令识别）
    VadSingleton.instance.vad?.clear();
    try {
      await TtsSingleton.instance.speak(text);
      // 播完后多留 200ms 缓冲（喇叭余震 + 麦克风回声衰减）
      await Future.delayed(const Duration(milliseconds: 200));
    } catch (e) {
      log('❌ [TTS] 撤销播报失败，降级音效: $e');
      _playFailure();
    } finally {
      if (mounted) setState(() => _isTtsPlaying = false);
    }
  }

  /// 判断识别文本是否为撤销命令
  //  规则：去除非中文字符后，纯中文长度 ≤5 且（完全匹配 或 包含）白名单关键词
  //  - 完全匹配：clean ∈ _kUndoKeywords（如"不对"、"撤销"）
  //  - 短包含：clean.contains(kw)（应对 SenseVoice 输出"嗯不对"等前缀噪声）
  //  长度限制 ≤5 避免"今天天气不对劲"（7字）这类长句误命中
  bool _isUndoCommand(String text) {
    final clean = text.replaceAll(RegExp(r'[^\u4e00-\u9fa5]'), '').trim();
    if (clean.isEmpty || clean.length > _kUndoMaxTextLen) return false;
    if (_kUndoKeywords.contains(clean)) return true;
    for (final kw in _kUndoKeywords) {
      if (clean.contains(kw)) return true;
    }
    return false;
  }

  /// 处理语音撤销命令（_recognizeAndSave 命中撤销关键词后调用）
  //  分三种场景：
  //  1) _recentSaves 空 → TTS "没有可撤销的记录"
  //  2) 上一条超 10s 窗口 → TTS "上一条已超时，无法撤销"
  //  3) 窗口内 → 复用 _undoSave 删除 + TTS "已撤销"
  //  注意：撤销 TTS 用 _speakRaw（纯文本播报），不走 _playTtsFeedback 的"已保存X到Y"模板
  Future<void> _handleUndoCommand() async {
    if (_recentSaves.isEmpty) {
      log('🚫 [搬家模式] 撤销命令但无记录可撤');
      setState(() {
        _isProcessing = false;
        _statusText = '没有可撤销的记录';
      });
      await _speakRaw('没有可撤销的记录');
      return;
    }
    final last = _recentSaves.last;
    final age = DateTime.now().difference(last.savedAt);
    if (age.inSeconds > _kUndoWindowSeconds) {
      log('⏰ [搬家模式] 撤销命令但上一条已超时（${age.inSeconds}s）');
      setState(() {
        _isProcessing = false;
        _statusText = '上一条已超时，无法撤销';
      });
      await _speakRaw('上一条已超时，无法撤销');
      return;
    }
    // 窗口内 → 复用 UI 撤销的同款删除逻辑
    log(
      '↩️ [搬家模式] 语音撤销：${last.item} → ${last.location} (id=${last.id}, ${age.inSeconds}s 前)',
    );
    await _undoSave(last.id);
    setState(() {
      _isProcessing = false;
      _statusText = '已撤销，本场共 $_moveSavedCount 条';
    });
    await _speakRaw('已撤销');
  }

  /// 智能分割失败：显示底部可左滑消除的提示条（替代原 SnackBar）
  //  原方案用 SnackBar，但 SnackBar 默认只能下滑消除，搬家模式下手势不便。
  //  改为 Stack 内自定义 Dismissible 提示条，支持左滑消除 + 手动保存按钮。
  void _showSplitErrorBar(String rawText) {
    if (!mounted) return;
    _splitErrorTimer?.cancel();
    _splitErrorSeq++;
    setState(() {
      _moveSplitError = rawText;
    });
    _splitErrorTimer = Timer(const Duration(seconds: 8), () {
      if (mounted) _hideSplitErrorBar();
    });
  }

  /// 隐藏分割失败提示条
  void _hideSplitErrorBar() {
    _splitErrorTimer?.cancel();
    _splitErrorTimer = null;
    if (mounted) {
      setState(() {
        _moveSplitError = null;
      });
    }
  }

  /// 分割失败提示条的「手动保存」按钮回调：无位置保存 + 清提示条
  Future<void> _handleManualSaveSplitError() async {
    final rawText = _moveSplitError;
    if (rawText == null) return;
    _hideSplitErrorBar();
    final id = await widget.dbHelper.insertItemReturningId(rawText, '');
    setState(() {
      _recentSaves.add(
        _MoveSaveRecord(
          id: id,
          item: rawText,
          location: '（未指定位置）',
          timeLabel: '刚刚',
          savedAt: DateTime.now(),
        ),
      );
      if (_recentSaves.length > 5) {
        _recentSaves.removeAt(0);
      }
      _moveSavedCount++;
      _statusText = '已保存 $_moveSavedCount 条';
    });
    _playSuccess();
    log('📝 [搬家模式] 手动保存（无位置）: $rawText');
  }

  /// 退出搬家模式：清理录音 + 处理 VAD 尾部 + 释放资源
  Future<void> _exitMoveMode() async {
    if (!_isMoveMode) return;
    log('🚪 [搬家模式] 退出中...');
    try {
      await _moveStreamSub?.cancel();
      _moveStreamSub = null;
      await _audioRecorder.stop();
      // flush 把 VAD 内部残余样本强制输出
      VadSingleton.instance.vad?.flush();
      _drainVadSegments(); // 处理最后一段（可能正在说话中，不完整）
      VadSingleton.instance.dispose();
      ScaffoldMessenger.of(context).clearSnackBars();
      // 搬家模式退出：取消闲置计时器 + 隐藏遮罩 + 关闭 wakelock
      // 必须在 setState(_isMoveMode=false) 之前完成，确保 UI 重绘时遮罩已清
      _idleDimTimer?.cancel();
      _idleDimTimer = null;
      if (_isDimmed) _isDimmed = false;
      _splitErrorTimer?.cancel();
      _splitErrorTimer = null;
      _moveSplitError = null;
      try {
        await WakelockPlus.disable();
      } catch (e) {
        log("搬家模式禁用 Wakelock 失败: $e");
      }
      setState(() {
        _isMoveMode = false;
        _isListening = false;
        _isProcessing = false;
        // 计数 _moveSavedCount 保留作为"本场共 N 条"统计
        // 清空列表：本次会话的撤销按钮不再可见，已写库的记录可在 List Tab 删除
        _recentSaves.clear();
        _statusText = _moveSavedCount > 0
            ? '搬家模式结束，本场共保存 $_moveSavedCount 条'
            : '搬家模式结束';
      });
      log('✅ [搬家模式] 已退出');
    } catch (e) {
      log('❌ [搬家模式] 退出失败: $e');
      setState(() => _statusText = '退出失败：$e');
    }
  }

  // ── 闲置降亮：启动 / 重置 10s 闲置计时器 ──
  // 上下游：_enterMoveMode 启动 / _onUserInteract 重置 / _exitMoveMode 取消
  // 到期后盖上半透明遮罩（_isDimmed=true）。mounted+(_isMoveMode) 双重守卫
  // 防止退出后 Timer 仍触发 setState（Timer.cancel 不是同步屏障，回调可能已在队列中）。
  void _startIdleDimTimer() {
    _idleDimTimer?.cancel();
    _idleDimTimer = Timer(_kDimDelay, () {
      if (mounted && _isMoveMode) {
        setState(() => _isDimmed = true);
      }
    });
  }

  // ── 闲置降亮：用户触摸屏幕时的回调 ──
  // 上下游：build() 外层 Listener(onPointerDown:) → 此处
  // 行为：立即恢复全亮（_isDimmed=false）+ 重置 10s 计时（再闲置再变暗）
  // 用 PointerDownEvent 而非 onTap：Listener 不参与手势竞技场，按钮/列表的
  // tap 事件照常触发，外层同时感知到 pointerDown（项目记忆里日记页侧滑同样套路）。
  void _onUserInteract(PointerDownEvent _) {
    if (!_isMoveMode) return;
    if (_isDimmed) {
      setState(() => _isDimmed = false);
    }
    _startIdleDimTimer();
  }

  // ── 搬家模式按钮染色 helper（颜色随 VAD 状态联动） ──
  // 优先级：识别中 > 初始化中 > 正在说话 > 等待说话
  Color _moveButtonColor(AppThemeExtension ext) {
    if (_isProcessing) return ext.fabProcessing; // 识别中：橙色
    final isSpeaking = VadSingleton.instance.vad?.isDetected() ?? false;
    return isSpeaking ? ext.fabRecording : ext.fabReady; // 说话中：红 / 等待：青
  }

  // ── 搬家模式按钮图标 helper ──
  Widget _moveButtonChild(AppThemeExtension ext) {
    if (_isProcessing) {
      return SizedBox(
        width: 45,
        height: 45,
        child: CircularProgressIndicator(
          color: ext.textOnPrimary,
          strokeWidth: 4,
        ),
      );
    }
    final isSpeaking = VadSingleton.instance.vad?.isDetected() ?? false;
    return Icon(
      isSpeaking ? Icons.fiber_manual_record : Icons.mic_none,
      color: ext.textOnPrimary,
      size: 55,
    );
  }

  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    // 录音/保存按钮栏在 main.dart 外层 Stack（_buildRecordBottomBar），RecordTab 内部
    // setState 不会触发 main.dart 重建。这里统一通知，让外层按钮颜色/状态/搬家显隐同步刷新。
    // 仿 ListTab.onStateChanged；RecordTab 状态变化点太多（~20 处散落录音/识别/搬家分支），逐点加易漏，故在 setState 重写里统一通知。
    widget.onStateChanged?.call();
  }

  @override
  Widget build(BuildContext context) {
    final ext = AppThemeExtension.of(context);

    // 如果正在初始化，返回空白容器，避免显示未初始化的UI
    if (_isInitializing) {
      return const SizedBox.shrink();
    }

    return Listener(
      // behavior=translucent：自身接 pointerDown 用于闲置降亮复位，事件继续传给子树
      // （Switch / 撤销按钮 / 列表滚动 全部正常工作）
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onUserInteract,
      child: Stack(
        children: [
          Scaffold(
            backgroundColor: ext.scaffoldBackground, // 原 Color(0xFFF8F9FB)
            body: LayoutBuilder(
              builder: (context, constraints) {
                return SingleChildScrollView(
                  physics: const ClampingScrollPhysics(),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: constraints.maxHeight,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24.0),
                      child: Column(
                        children: [
                          const SizedBox(height: 40),
                          // ── 搬家模式入口（紧凑版：避免占用过多纵向空间导致按钮被键盘遮挡）──
                          // 原 SwitchListTile 占 ~80px（含 subtitle），改紧凑 Row + Switch 省 ~40px
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 4,
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.local_shipping,
                                  size: 20,
                                  color: ext.primary,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  '搬家模式',
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    color: ext.textPrimary,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  '· 持续录音',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: ext.textSecondary,
                                  ),
                                ),
                                const Spacer(),
                                Switch(
                                  value: _isMoveMode,
                                  activeThumbColor: ext.primary,
                                  onChanged: (v) =>
                                      v ? _enterMoveMode() : _exitMoveMode(),
                                ),
                              ],
                            ),
                          ),
                          // ── 搬家模式 TTS 子开关（仅在搬家模式打开时显示） ──
                          // 只控制 _playTtsFeedback（保存播报），不影响撤销 _speakRaw
                          if (_isMoveMode)
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 4,
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.volume_up,
                                    size: 20,
                                    color: ext.primary,
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    '语音播报',
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                      color: ext.textPrimary,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    '· 保存后朗读',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: ext.textSecondary,
                                    ),
                                  ),
                                  const Spacer(),
                                  Switch(
                                    value: _ttsEnabled,
                                    activeThumbColor: ext.primary,
                                    onChanged: (v) async {
                                      setState(() => _ttsEnabled = v);
                                      final prefs =
                                          await SharedPreferences.getInstance();
                                      await prefs.setBool(
                                        'move_mode_tts_enabled',
                                        v,
                                      );
                                    },
                                  ),
                                ],
                              ),
                            ),
                          if (_isMoveMode) ...[
                            // 麦克风"正在听"指示器：自管 Timer + setState，不污染外层 layout
                            const _MicPulseIndicator(),
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 4,
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.inventory,
                                    size: 18,
                                    color: ext.primary,
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    '已保存 $_moveSavedCount 条',
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                      color: ext.textPrimary,
                                    ),
                                  ),
                                  const Spacer(),
                                  if (_isProcessing)
                                    const SizedBox(
                                      width: 14,
                                      height: 14,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ],
                          // ── 非搬家模式：保留原录入页交互 ──
                          if (!_isMoveMode) ...[
                            // 物品名称上方间距加大（40→120），让物品名/存放位置整体下移约 80dp，
                            // 便于单手拇指够到物品名输入框。搬家模式不渲染此分支，不受影响。
                            const SizedBox(height: 120),
                            _buildModernField(
                              controller: _itemController,
                              hint: "物品名称",
                              icon: Icons.inventory_2_rounded,
                              accentColor: ext.primary, // 原 Colors.blueAccent
                            ),
                            // 物品名与存放位置的间距翻倍（20→40）
                            const SizedBox(height: 40),
                            _buildModernField(
                              controller: _locationController,
                              hint: "存放位置",
                              icon: Icons.place_rounded,
                              accentColor:
                                  ext.warningText, // 原 Colors.orangeAccent
                            ),
                          ],
                          // ── 搬家模式：移除原录音按钮（Switch 已是开关），改用列表内撤销 ──
                          if (_isMoveMode)
                            Text(
                              _statusText,
                              style: TextStyle(
                                // 搬家模式下放大字号，让用户在房间走动时一眼可见状态
                                fontSize: 18,
                                fontWeight: FontWeight.w500,
                                color: ext.textSecondary,
                              ),
                            ),
                          // 搬家模式：5 条记录列表（最新在底部，像聊天记录）
                          // ⚠️ 历史踩坑：
                          //    1) ListView.builder+reverse → setState 频繁触发 !semantics.parentDataDirty
                          //    2) Expanded+Spacer（贴底布局）→ 外层 SingleChildScrollView 高度无界，
                          //       Expanded 拿不到 bounded height，触发
                          //       "RenderFlex children have non-zero flex but incoming height constraints are unbounded"
                          //       该布局错误连锁触发 !semantics.parentDataDirty。
                          //    终方案：搬家模式下不用 Expanded/Spacer，直接 Column(mainAxisSize.min)
                          //    按时间倒序堆卡片，最新一条在最上方。页面由 SingleChildScrollView 自然撑开。
                          if (_isMoveMode) ...[
                            if (_recentSaves.isEmpty)
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 32,
                                  horizontal: 16,
                                ),
                                child: Text(
                                  '说一句话试试，比如"钥匙放在抽屉"',
                                  style: TextStyle(
                                    fontSize: 14,
                                    color: ext.textSecondary,
                                  ),
                                ),
                              )
                            else
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                ),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    for (final record in _recentSaves.reversed)
                                      _buildRecentSaveCard(record, ext),
                                  ],
                                ),
                              ),
                            // 搬家模式底部留白加大：防最后一张卡片被钉底「撤销最近」按钮遮挡
                            // （下方 Stack 最顶层会钉一个 56 高按钮 + bottom:12 + SafeArea）
                            const SizedBox(height: 120),
                          ] else
                            // 非搬家模式：底部预留 ~按钮栏高度，防止滚动内容被钉底按钮遮挡
                            const SizedBox(height: 140),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          // ── 搬家模式闲置降亮遮罩 ──
          // 触发条件：_isMoveMode && _isDimmed（10s 闲置后 _startIdleDimTimer 设 true）
          // IgnorePointer：让事件穿透到下方 UI（用户点"撤销"按钮时按钮正常工作，
          //   同时父级 Listener 已感知 pointerDown 恢复全亮）
          // ColoredBox+black opacity 0.55：OLED 屏真实省电，视觉明显变暗但不黑
          // 直接 if 渲染无动画——plan 第一版决策，后续若用户觉得突兀再加 AnimatedOpacity
          if (_isMoveMode && _isDimmed)
            Positioned.fill(
              child: IgnorePointer(
                child: ColoredBox(
                  color: Colors.black.withValues(alpha: _kDimOpacity),
                ),
              ),
            ),
          // ── 搬家模式：分割失败提示条（可左滑消除，替代原 SnackBar）──
          // 渲染在降亮遮罩之上（全亮可见）、撤销最近按钮之上（z-index 最高）
          if (_isMoveMode && _moveSplitError != null)
            Positioned(
              left: 0,
              right: 0,
              bottom: 100, // 在「撤销最近」按钮上方（按钮 bottom:12 + SafeArea + height:56 ≈ 80-92）
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24.0),
                  child: Dismissible(
                    key: ValueKey('split_error_$_splitErrorSeq'),
                    direction: DismissDirection.endToStart,
                    onDismissed: (_) => _hideSplitErrorBar(),
                    background: Container(
                      alignment: Alignment.centerRight,
                      padding: const EdgeInsets.only(right: 20),
                      child: const Icon(Icons.delete_sweep, color: Colors.white54),
                    ),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                      decoration: BoxDecoration(
                        color: ext.primaryDark,
                        borderRadius: BorderRadius.circular(10),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.3),
                            blurRadius: 8,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '没分出物品+位置: "$_moveSplitError"',
                              style: const TextStyle(color: Colors.white, fontSize: 13),
                            ),
                          ),
                          const SizedBox(width: 8),
                          TextButton(
                            onPressed: _handleManualSaveSplitError,
                            style: TextButton.styleFrom(
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(horizontal: 8),
                            ),
                            child: const Text(
                              '手动保存',
                              style: TextStyle(fontWeight: FontWeight.bold),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          // ── 搬家模式：钉底「撤销最近」按钮（最高层级，永远全亮不被卡片/遮罩遮挡）──
          // 放在降亮遮罩之后：遮罩 IgnorePointer 穿透事件，按钮自身可点；
          //   且按钮渲染在遮罩之上，降亮期间保持全亮可见（用户随时可撤销）。
          //   用户点按钮时，外层 Listener.onPointerDown(record_tab.dart:1204 附近) 先恢复全亮。
          if (_isMoveMode)
            Positioned(
              left: 0,
              right: 0,
              bottom: 12,
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24.0),
                  child: SizedBox(
                    width: double.infinity,
                    height: 56, // 稍大便于按，≥48 满足无障碍触控目标
                    child: ElevatedButton.icon(
                      onPressed: _recentSaves.isEmpty
                          ? null
                          : _undoLastManually,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: ext
                            .warningText, // 暖橙，撤销/可逆操作语义（与 ItemTransferWidget 同款）
                        foregroundColor: ext.textOnPrimary,
                        disabledBackgroundColor: ext.warningText.withValues(
                          alpha: 0.35,
                        ),
                        disabledForegroundColor: ext.textOnPrimary.withValues(
                          alpha: 0.6,
                        ),
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(18),
                        ),
                      ),
                      icon: const Icon(Icons.undo),
                      label: const Text(
                        '撤销最近',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildModernField({
    required TextEditingController controller,
    required String hint,
    required IconData icon,
    required Color accentColor,
  }) {
    final ext = AppThemeExtension.of(context);
    return Container(
      decoration: BoxDecoration(
        color: ext.cardBackground, // 原 Colors.white
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: ext.textPrimary.withValues(
              alpha: 0.03,
            ), // 原 Colors.black.withValues(alpha: 0.03)
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: TextField(
        controller: controller,
        style: TextStyle(color: ext.textPrimary), // 输入文字色（黑金主题下白色，深色卡片上清晰）
        textInputAction: TextInputAction.done, // 设置键盘动作按钮为"完成"
        onSubmitted: (_) => _saveData(), // 当用户点击键盘的完成/Enter按钮时触发保存
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: TextStyle(color: ext.textHint), // hint 占位文字色
          prefixIcon: Icon(icon, color: accentColor),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(
            vertical: 18,
            horizontal: 20,
          ),
        ),
      ),
    );
  }

  // ── 搬家模式：单条最近保存记录卡片 ──
  // 布局：浅青背景 + 圆角，左侧 📍 + 加粗物品 + " → " + 位置，右上角时间标签，右下角撤销按钮
  // 设计意图：用户能看到最近 5 条结果，说话太快时上一条没看清下一条就保存的问题解决
  Widget _buildRecentSaveCard(_MoveSaveRecord record, AppThemeExtension ext) {
    return Container(
      // ValueKey 防 ListView.builder widget 复用时 parentData 残留
      // （!semantics.parentDataDirty assertion 的常见规避手段）
      key: ValueKey('move_save_${record.id}'),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        // 浅青背景，与查询答案区 LocationAnswerWidget 保持一致
        color: ext.cardBackground,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 左侧：📍 + 物品 → 位置（允许换行，避免长物品名被截）
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '📍 ',
                  style: TextStyle(fontSize: 14, color: ext.textPrimary),
                ),
                Expanded(
                  child: RichText(
                    text: TextSpan(
                      style: DefaultTextStyle.of(
                        context,
                      ).style.copyWith(fontSize: 14, color: ext.textPrimary),
                      children: [
                        TextSpan(
                          text: record.item,
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: ext.textPrimary,
                          ),
                        ),
                        TextSpan(
                          text: ' → ',
                          style: TextStyle(color: ext.textSecondary),
                        ),
                        TextSpan(
                          text: record.location,
                          style: TextStyle(color: ext.textSecondary),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          // 右侧：时间标签（上）+ 撤销按钮（下），垂直排列
          // 紧凑布局，避免在小屏上占用过多横向空间
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                record.timeLabel,
                style: TextStyle(fontSize: 11, color: ext.textSecondary),
              ),
              const SizedBox(height: 4),
              GestureDetector(
                onTap: () => _undoSave(record.id),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 2,
                  ),
                  child: Text(
                    '撤销',
                    style: TextStyle(
                      fontSize: 13,
                      color: ext.textSecondary,
                      decoration: TextDecoration.underline,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 搬家模式最近保存记录（列表内撤销用）
//  字段含义：id=rowid（删除用）, item/location=预览文字, timeLabel=显示用时间
//  本次实现所有记录都标 "刚刚"，不引入 DateFormat，避免 dart:ui 依赖复杂度
class _MoveSaveRecord {
  final int id;
  final String item;
  final String location;
  final String timeLabel; // 例如 "刚刚" / "10:23"
  final DateTime savedAt; // 保存时间戳，用于语音撤销 10s 窗口判断

  _MoveSaveRecord({
    required this.id,
    required this.item,
    required this.location,
    required this.timeLabel,
    required this.savedAt,
  });
}

/// 搬家模式麦克风"正在听"指示器
///
/// 一个 12px 圆点 + 状态文字，给用户"声音是否被检测到"的实时视觉反馈：
/// - 静默（isDetected=false）：灰色圆点 + "请说出 物品+位置"
/// - 说话中（isDetected=true）：红色圆点 + 呼吸放大动画 + "正在听..."
///
/// 实现要点（关键设计决策）：
/// 1. 独立 StatefulWidget + 自管 Timer（150ms 周期）：
///    setState 只刷新本 widget，绝不冒泡到外层 RecordTab。
///    历史教训：在 _onMoveModePcm 里 setState 会让外层 Column 重建，
///    触发 !semantics.parentDataDirty / RenderFlex unbounded。
///
/// 2. 只在 _isMoveMode=true 时 mount（外层条件 build）：
///    退出搬家模式时 widget 自动从树上摘下，dispose 触发 _t.cancel()，
///    不需要外层手动管理 Timer 生命周期。
///
/// 3. 颜色复用主题 token：fabRecording（红）/ textSecondary（灰），
///    不硬编码 Color，跟随主题切换。
class _MicPulseIndicator extends StatefulWidget {
  const _MicPulseIndicator();

  @override
  State<_MicPulseIndicator> createState() => _MicPulseIndicatorState();
}

class _MicPulseIndicatorState extends State<_MicPulseIndicator>
    with SingleTickerProviderStateMixin {
  Timer? _t;
  bool _speaking = false;

  @override
  void initState() {
    super.initState();
    // 150ms 周期平衡：比 VAD 内部 32ms 慢（省 CPU），比人耳感知快（肉眼流畅）
    _t = Timer.periodic(const Duration(milliseconds: 150), (_) {
      final det = VadSingleton.instance.vad?.isDetected() ?? false;
      if (det != _speaking && mounted) {
        setState(() => _speaking = det);
      }
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    _t = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ext = AppThemeExtension.of(context);
    final color = _speaking ? ext.fabRecording : ext.textSecondary;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          AnimatedScale(
            scale: _speaking ? 1.35 : 1.0,
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeInOut,
            child: Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                // 说话时加发光阴影，强化"活着的"感觉
                boxShadow: _speaking
                    ? [
                        BoxShadow(
                          // withValues 是 Flutter 3.27+ 替代 withOpacity 的 API
                          color: color.withValues(alpha: 0.45),
                          blurRadius: 8,
                          spreadRadius: 1,
                        ),
                      ]
                    : null,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            _speaking ? '正在听...' : '请说出 物品+位置',
            style: TextStyle(
              fontSize: 13,
              color: ext.textSecondary,
              // 说话时加粗，状态切换更醒目
              fontWeight: _speaking ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
        ],
      ),
    );
  }
}
