import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;
import '../vad_singleton.dart';
import 'package:intl/intl.dart';
import '../db_helper.dart';
import '../text_processor.dart';
import '../list_extractor.dart';
import 'package:path_provider/path_provider.dart';
import 'package:audioplayers/audioplayers.dart';
import '../recognizer_singleton.dart';
import '../widgets/blur_loading_overlay.dart';
import '../widgets/swipe_dismiss_card.dart';
import '../widgets/checklist_widget.dart';
import 'package:url_launcher/url_launcher.dart';
import '../ai_app_model.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:external_app_launcher/external_app_launcher.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../models/time_entity.dart';
import '../widgets/time_aware_text.dart';
import '../widgets/alarm_dialog.dart';
import '../utils/dart_chrono_parser.dart';
import 'package:file_picker/file_picker.dart';
import '../app_logger.dart';
import 'package:persistent_user_dir_access_android/persistent_user_dir_access_android.dart';
import '../utils/query_detector.dart';
import '../utils/item_splitter.dart';
import '../widgets/item_transfer_widget.dart';
import '../widgets/location_answer_widget.dart';
import '../theme/app_theme_extension.dart';

/// 短句阈值：超过此长度的日记不触发转存/查询检测
/// 用户在长日记里的意图太发散，强行拆分容易误命中
/// 例："今天天气也不错，钥匙在哪里" 长度 13 → 处理
///     "今天天气也不错，哎，我突然想找一下我的钥匙..." 长度 >15 → 跳过
const int kDiaryShortTextMax = 15;

/// 日记页长录音保护阈值：录音时长 ≥ 此秒数时，走 VAD 切分 + 逐段识别 + 文本拼接
/// 避免 SenseVoice 整段识别长录音时注意力分散导致质量下降
const int kLongRecordingThresholdSec = 60;

/// 查询类日记的答案缓存数据（"游戏机在哪儿" → items 表匹配结果）
class _QueryAnswer {
  final String itemName;
  final List<Map<String, dynamic>> matches;

  _QueryAnswer({required this.itemName, required this.matches});
}

class DiaryTab extends StatefulWidget {
  final DbHelper dbHelper;
  // 如果需要文本处理器也可以传，但日记通常保存原始内容，或者简单去标点
  final TextProcessor processor;
  // [新增] 状态变化回调，用于通知外层刷新按钮 UI
  final VoidCallback? onStateChanged;
  // [新增] loading状态变化回调
  final Function(bool show, {String? message})? onLoadingChanged;
  // [新增] 日记页答案区"+N"点击 → 跳转 ListTab 并预填搜索词
  final void Function(String keyword)? onJumpToSearch;

  const DiaryTab({
    super.key,
    required this.dbHelper,
    required this.processor,
    this.onStateChanged,
    this.onLoadingChanged,
    this.onJumpToSearch,
  });

  @override
  State<DiaryTab> createState() => DiaryTabState();
}

class DiaryTabState extends State<DiaryTab> with WidgetsBindingObserver {
  static const _channel = MethodChannel('com.shengwuji.app/app');

  // 触觉反馈：通过原生 VibrationEffect API 驱动线性马达
  void _haptic(String type) {
    _channel.invokeMethod('performHaptic', {'type': type});
  }

  // --- 录音相关变量 (复用自 RecordTab) ---
  final _audioRecorder = AudioRecorder();

  // 用于保存原始 PCM bytes
  final BytesBuilder _pcmBuilder = BytesBuilder();

  // 静音提示轮询定时器（检测用户是否按了音量减）
  Timer? _muteHintTimer;

  // 用于跟踪App生命周期状态，区分真正的后台恢复和通知栏操作
  AppLifecycleState? _lastState;
  bool _wasInBackground = false; // 标记是否真正进入过后台（paused或hidden）
  DateTime? _pausedTime; // 记录进入后台的时间戳，用于判断短时间后台恢复
  static const Duration _shortBackgroundThreshold = Duration(
    minutes: 10,
  ); // 短时间后台的阈值

  // 编辑抽屉的焦点节点（用于后台恢复时重新拉起键盘）
  FocusNode? _editFocusNode;

  // 音频播放
  final AudioPlayer _audioPlayer = AudioPlayer();
  int? _playingDiaryId;
  bool _isPlaying = false;

  // 使用单例管理器
  final _recognizerManager = RecognizerSingleton.instance;
  sherpa_onnx.OfflineRecognizer? get _recognizer =>
      _recognizerManager.recognizer;

  List<double> _audioBuffer = [];
  bool isReady = false;
  bool isListening = false;
  bool isProcessing = false;
  bool _isFirstVisible = true; // 是否首次显示
  bool _isInitializing = false; // 是否正在初始化
  String statusText = "";

  // 标记是否正在预热引擎
  bool _isWarmingUp = false;

  // 标记是否需要预热（用于后台恢复）
  bool _needsWarmup = false;

  // 记录录音开始时间，用于判断是否为长语音
  DateTime? _recordingStartTime;

  // generation 计数器：防止权限弹窗等异步中断导致 startListening/stopListening 竞态
  int _operationGeneration = 0;

  // 保存录音时长（秒），用于存储到数据库
  int? _recordingDurationInSeconds;

  // 锁定录音模式（通过快捷方式触发时使用）
  bool _isLockedRecording = false;

  // 引擎就绪的 Future，用于快捷方式等待引擎加载完成
  final Completer<void> _engineReadyCompleter = Completer<void>();

  // 公共 getter：供 main.dart 访问（已废弃）
  bool get needsWarmup => _needsWarmup;

  /// 是否处于锁定录音模式
  bool get isLockedRecording => _isLockedRecording;

  // 在所有的 _updateState 中加入 widget.onStateChanged?.call()
  void _updateState(VoidCallback fn) {
    if (mounted) {
      setState(fn);
      widget.onStateChanged?.call(); // 通知外层刷新
    }
  }

  // --- 列表与搜索相关变量 ---
  List<Map<String, dynamic>> _diaryList = [];
  final TextEditingController _searchController = TextEditingController();

  // --- 编辑相关变量 ---
  final TextEditingController _editController =
      TextEditingController(); // 编辑控制器（底部抽屉复用）
  bool _isLoadingList = true;

  // --- 闹钟相关变量 ---
  // 时间实体缓存（key: diaryId, value: entities）
  final Map<int, List<TimeEntity>> _timeEntitiesCache = {};

  // 当前加载中的日记 ID
  final Set<int> _parsingDiaryIds = {};

  // --- 查询答案缓存（"XX在哪儿" → items 表匹配结果） ---
  // 与 _timeEntitiesCache 同模式：懒加载 + 防重复
  final Map<int, _QueryAnswer> _queryAnswerCache = {};
  final Set<int> _queryingDiaryIds = {};

  // --- 物品转存检测缓存（与 _queryAnswerCache 模式对称） ---
  final Map<int, ItemSplitResult?> _itemSplitCache = {};
  final Set<int> _parsingItemSplitIds = {};

  // --- dismiss 学习 + 智能识别开关 ---
  /// 用户 dismiss 的物品转存 content 集合（启动时一次性加载，避免每条日记查库）
  /// 匹配规则：完全相等（用户点 ✕ 的 content，下次相同 content 跳过转存检测）
  Set<String> _dismissedSplits = {};

  /// 智能识别开关（默认开启，用户可在设置页关闭）
  bool _itemTransferEnabled = true;   // 日记智能识别物品+位置 → 显示转存横条
  bool _queryAnswerEnabled = true;    // 日记智能查询"XX在哪儿" → 显示答案区

  // SAF 持久化目录导出
  final PersistentUserDirAccessAndroid _safDir =
      PersistentUserDirAccessAndroid();
  static const String _exportDirPrefKey =
      'diary_export_dir_uri'; // SharedPreferences 保存 key

  @override
  void initState() {
    super.initState();
    // 注册生命周期监听
    WidgetsBinding.instance.addObserver(this);
    // 只加载列表，不初始化引擎
    WidgetsBinding.instance.addPostFrameCallback((_) {
      refreshList();
    });
    // 加载 dismiss 学习数据 + 智能识别开关（与 refreshList 并行，无依赖）
    _loadDismissedSplits();
    _loadSmartSwitches();
  }

  /// 加载 dismiss 学习数据（启动时一次性加载到内存）
  /// 用户点过 ✕ 的 content 入此集合，下次相同 content 跳过转存检测
  void _loadDismissedSplits() async {
    _dismissedSplits = await widget.dbHelper.loadAllDismissedSplits();
    if (mounted) setState(() {}); // 触发重渲染，已 dismiss 的卡片刷新
  }

  /// 加载智能识别开关状态（设置页可关闭）
  void _loadSmartSwitches() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _itemTransferEnabled = prefs.getBool('diary_item_transfer_enabled') ?? true;
      _queryAnswerEnabled = prefs.getBool('diary_query_answer_enabled') ?? true;
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    // 调试日志：打印所有状态变化
    print(
      "🔍 [生命周期] 日记页状态变化: $_lastState → $state, isReady=$isReady, _wasInBackground=$_wasInBackground",
    );

    // 标记是否进入过后台，并记录时间戳
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _wasInBackground = true;
      _pausedTime = DateTime.now(); // 记录进入后台的时间
      print("日记页：进入后台，记录时间戳: $_pausedTime");
    }

    // 后台恢复时，如果编辑抽屉开着但键盘没拉起来，重新请求焦点
    // Android 12+ 从后台恢复时 showSoftInput 被忽略（已知 Flutter 问题）
    // 注意：不依赖 isReady，键盘重试跟引擎无关
    // 🔥 区分两种场景的核心依据：直接从引擎层读 viewInsets.bottom（绕过 widget tree 重建延迟）
    //    - 场景 A（锁屏双击音量键）：_showEditSheet 内 300ms requestFocus 因 windowFocus=false
    //      导致 IME 完全未启动（onFailed at PHASE_CLIENT_VIEW_SERVED），
    //      引擎层 viewInsets.bottom=0 → 需要重试 unfocus+requestFocus（focusNode.hasFocus=true
    //      但 IME 未起，单纯 requestFocus 会 early return 无效，必须 unfocus 强制 _handleFocusChanged）
    //    - 场景 B（桌面双击音量键）：_showEditSheet 内 300ms requestFocus 成功，IME 已显示，
    //      引擎层 viewInsets.bottom>0 → 跳过重试，避免 unfocus+requestFocus 造成 hide→show 抖动
    // ⚠️ 不能用 focusNode.hasFocus 判断：Flutter focus 状态独立于 Android windowFocus，
    //    场景 A 中 hasFocus=true 但 IME 拒绝显示
    // ⚠️ 不能用 MediaQuery.of(context).viewInsets：依赖 widget rebuild，500ms 内可能未传播
    if (_wasInBackground &&
        state == AppLifecycleState.resumed &&
        _editFocusNode != null) {
      Future.delayed(const Duration(milliseconds: 500), () {
        if (!mounted || _editFocusNode == null) return;
        // 直接从引擎层取最新 viewInsets（绕过 widget tree 的 InheritedWidget 传播延迟）
        final view = WidgetsBinding.instance.platformDispatcher.views.first;
        final keyboardAlreadyVisible = view.viewInsets.bottom > 0;
        if (keyboardAlreadyVisible) {
          print("⌨️ [DiaryTab] 键盘已可见（引擎层 viewInsets>0），跳过重试");
          return;
        }
        print("⌨️ [DiaryTab] 键盘未可见（引擎层 viewInsets=0），unfocus+requestFocus 重试");
        _editFocusNode!.unfocus();
        Future.delayed(const Duration(milliseconds: 100), () {
          _editFocusNode?.requestFocus();
        });
      });
    }

    // 只在从后台恢复到前台时才预热（真正的后台恢复，而非通知栏操作）
    // 条件：经历过后台 + 现在恢复到resumed + 引擎已就绪
    if (_wasInBackground && state == AppLifecycleState.resumed && isReady) {
      // 计算后台时长
      final backgroundDuration = _pausedTime != null
          ? DateTime.now().difference(_pausedTime!)
          : Duration.zero;

      final isShortBackground = backgroundDuration < _shortBackgroundThreshold;

      print(
        "日记页：从后台恢复，后台时长: ${backgroundDuration.inSeconds}秒，是否短时间后台: $isShortBackground",
      );

      if (isShortBackground) {
        // 短时间后台：静默预热，不显示loading
        print("日记页：短时间后台恢复，静默预热");

        Future.delayed(const Duration(milliseconds: 50), () async {
          await _warmupEngine();
          if (mounted) {
            print("日记页：静默预热完成");
          }
        });
      } else {
        // 长时间后台：显示全局loading并预热
        print("日记页：长时间后台恢复，显示loading并预热");

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
            print(
              "🔍 [性能检测] 日记页后台恢复预热高斯模糊loading耗时: ${stopwatch.elapsedMilliseconds}ms",
            );
            widget.onLoadingChanged?.call(false);
            _updateState(() => _needsWarmup = false);
            print("日记页：后台恢复预热完成");
          }
        });
      }

      // 重置后台标记和时间戳
      _wasInBackground = false;
      _pausedTime = null;
    }

    _lastState = state;
  }

  /// 把 PCM16 LE 的 bytes 编成标准 WAV（16-bit, mono）并返回文件路径
  Future<String> _writeWavFile(
    Uint8List pcm16Bytes, {
    int sampleRate = 16000,
  }) async {
    final dir = await getApplicationDocumentsDirectory();
    final folder = Directory(p.join(dir.path, 'diary_audio'));
    if (!folder.existsSync()) folder.createSync(recursive: true);

    final fileName =
        'diary_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}.wav';
    final filePath = p.join(folder.path, fileName);

    final header = _wavHeader(pcm16Bytes.length, sampleRate, 1, 16);
    final out = BytesBuilder();
    out.add(header);
    out.add(pcm16Bytes);

    final file = File(filePath);
    await file.writeAsBytes(out.toBytes(), flush: true);
    return filePath;
  }

  /// 生成 44 字节的 WAV header (PCM16 little-endian)
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

  void _togglePlay(int id, String? path) async {
    if (path == null) return;
    try {
      if (_playingDiaryId == id && _isPlaying) {
        await _audioPlayer.pause();
        _updateState(() {
          _isPlaying = false;
        });
      } else {
        // 先停止之前的
        await _audioPlayer.stop();
        final result = await _audioPlayer.play(DeviceFileSource(path));
        // play 方法在 audioplayers v3 返回一个 PlayerState 或 void，兼容性请以你本地版本为准
        _updateState(() {
          _playingDiaryId = id;
          _isPlaying = true;
        });
        _audioPlayer.onPlayerComplete.listen((_) {
          _updateState(() {
            _isPlaying = false;
            _playingDiaryId = null;
          });
        });
      }
    } catch (e) {
      print("播放失败: $e");
    }
  }

  @override
  void dispose() {
    _muteHintTimer?.cancel();
    // 移除生命周期监听
    WidgetsBinding.instance.removeObserver(this);
    _audioRecorder.dispose();
    // 不再在这里释放识别器，因为它是单例共享的
    _searchController.dispose();
    _audioPlayer.dispose();
    _editController.dispose(); // 清理编辑控制器
    super.dispose();
  }

  // 公开方法：供 MainScaffold 调用
  /// 新建空白文本笔记并进入编辑模式
  /// 供 MainScaffold 通过 GlobalKey 调用（双击音量键触发）
  Future<void> startNewTextNote() async {
    _haptic('tick');
    final newId = await widget.dbHelper.insertDiary(
      '',
      audioPath: null,
      duration: null,
    );
    print("📝 [Diary] 新建空白文本笔记, id=$newId");
    await refreshList();
    if (mounted) {
      _showEditSheet(newId, '', isNewEmptyNote: true);
    }
  }

  /// 设置录音状态标志（供原生层读取）
  Future<void> _setRecordingFlag(bool recording) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('is_recording', recording);
      print("📝 [Diary] 录音标志: is_recording=$recording");
    } catch (e) {
      print("设置录音标志失败: $e");
    }
  }

  // 公开方法：供 MainScaffold 调用，按需初始化引擎
  Future<void> refreshEngine() async {
    // 🆕 不再自动加载模型
    if (isReady && _recognizerManager.isReady) return;

    // 🆕 启动页已完成模型加载，直接同步状态（跳过重复加载）
    if (_recognizerManager.isReady) {
      _updateState(() {
        isReady = true;
      });
      // 标记引擎就绪 Completer，防止 stopListening 中 await 卡死
      if (!_engineReadyCompleter.isCompleted) {
        _engineReadyCompleter.complete();
      }
      print("📍 [Diary] 启动页已加载模型，同步状态");
      return;
    }

    // 只同步状态（如果单例已初始化）
    if (_recognizerManager.hasEverInitialized) {
      await initEngine();
      return;
    }

    // 首次进入时不加载
    if (_isFirstVisible) {
      _updateState(() => _isFirstVisible = false);
    }
  }

  Future<void> refreshList() async {
    final data = await widget.dbHelper.getDiaries(
      keyword: _searchController.text,
    );

    if (mounted) {
      _updateState(() {
        _diaryList = List.from(data); // 创建可变副本
        _isLoadingList = false;
      });
    }

    // 清除时间实体缓存
    _timeEntitiesCache.clear();
    // 清除查询答案缓存（与时间实体缓存同步）
    _queryAnswerCache.clear();
    _queryingDiaryIds.clear();
    // 清除物品转存检测缓存（与查询答案缓存同步）
    _itemSplitCache.clear();
    _parsingItemSplitIds.clear();
  }

  /// 导出日记为 Markdown 文件
  Future<void> _exportDiariesToMarkdown() async {
    try {
      // 1. 查询未导出且未归档的日记（增量导出）
      final unexportedDiaries = await widget.dbHelper.queryUnexportedDiaries();

      if (unexportedDiaries.isEmpty) {
        if (mounted) _showNoNewDiariesDialog();
        return;
      }

      // 2. 获取持久化导出目录 URI
      final prefs = await SharedPreferences.getInstance();
      String? dirUri = prefs.getString(_exportDirPrefKey);

      // 如果没有保存的 URI，让用户选择目录
      if (dirUri == null) {
        dirUri = await _safDir.requestDirectoryUri();

        if (dirUri == null) {
          // 用户取消选择
          return;
        }

        // 保存 URI 到 SharedPreferences
        await prefs.setString(_exportDirPrefKey, dirUri);
        print("🔍 [Diary] 导出目录已保存: $dirUri");
      }

      // 3. 生成 Markdown 文件
      int successCount = 0;
      int failCount = 0;

      for (var diary in unexportedDiaries) {
        try {
          final fileName = _generateFileName(diary);
          final content = _generateMarkdownContent(diary);
          final success = await _safDir.writeFile(
            dirUri,
            fileName,
            'text/markdown',
            utf8.encode(content),
          );
          if (success) {
            successCount++;
            // 标记该日记已导出，下次不再重复导出
            await widget.dbHelper.markDiaryExported(diary['id']);
          } else {
            print('导出日记 ID ${diary['id']} 失败: writeFile 返回 false');
            failCount++;
          }
        } catch (e) {
          print('导出日记 ID ${diary['id']} 失败: $e');
          failCount++;
        }
      }

      // 4. 显示结果
      if (mounted) {
        _showExportResultDialog(successCount, failCount);
      }
    } catch (e) {
      if (mounted) {
        _showErrorDialog("导出失败", "错误详情：$e");
      }
    }
  }

  String _generateFileName(Map<String, dynamic> diary) {
    String timestamp = '';
    if (diary['created_at'] != null) {
      try {
        final dateTime = DateTime.parse(diary['created_at'].toString());
        timestamp = DateFormat('yyyy-MM-dd_HH-mm-ss').format(dateTime);
      } catch (e) {
        timestamp = 'unknown';
      }
    }
    return '日记_$timestamp.md';
  }

  String _generateMarkdownContent(Map<String, dynamic> diary) {
    String date = '', time = '', createdAt = '';
    if (diary['created_at'] != null) {
      try {
        final dateTime = DateTime.parse(diary['created_at'].toString());
        date = DateFormat('yyyy-MM-dd').format(dateTime);
        time = DateFormat('HH:mm:ss').format(dateTime);
        createdAt = diary['created_at'].toString();
      } catch (e) {
        createdAt = diary['created_at'].toString();
      }
    }

    final content = diary['content']?.toString() ?? '';

    return '''---
title: 日记条目
date: $date
time: $time
created_at: $createdAt
id: ${diary['id']}
---

# 日记内容

$content

---
*由语音日记应用生成*
''';
  }

  void _showExportResultDialog(int successCount, int failCount) {
    if (mounted) {
      final msg = failCount == 0
          ? "✅ 成功导出 $successCount 篇日记"
          : "⚠️ 导出 $successCount 篇成功，$failCount 篇失败";
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(msg),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  void _showNoNewDiariesDialog() {
    if (mounted) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text("没有新日记"),
          content: const Text("所有日记都已导出，没有新日记需要导出。"),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text("确定"),
            ),
          ],
        ),
      );
    }
  }

  void _showEmptyDiaryDialog() {
    if (mounted) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text("没有日记"),
          content: const Text("当前没有可导出的日记。"),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text("确定"),
            ),
          ],
        ),
      );
    }
  }

  void _showErrorDialog(String title, String message) {
    if (mounted) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text("确定"),
            ),
          ],
        ),
      );
    }
  }

  /// 解析日记内容中的时间实体（添加文本预处理，修复标点符号问题）
  Future<void> _parseTimeEntities(int diaryId, String content) async {
    if (_parsingDiaryIds.contains(diaryId)) return;

    setState(() {
      _parsingDiaryIds.add(diaryId);
    });

    try {
      // 文本预处理：将中文标点符号（：）替换为英文点符号（.）
      // 这样"8点"变成"8."，chrono.js 就能正确解析为下午
      final processedText = content.replaceAll('：', '.');

      // 使用 DartChronoParser（纯 Dart 实现，无 JS 依赖）
      final chrono = DartChronoParser();
      final entities = await chrono.parseDateTimeEntities(processedText);

      if (mounted) {
        setState(() {
          _timeEntitiesCache[diaryId] = entities;
        });
      }
    } catch (e) {
      print('解析时间实体失败: $e');
    } finally {
      if (mounted) {
        setState(() {
          _parsingDiaryIds.remove(diaryId);
        });
      }
    }
  }

  /// 解析日记内容中的查询语句，后台查询 items 表并缓存结果。
  /// 与 _parseTimeEntities 同模式：懒加载 + 防重复 + setState 刷新。
  Future<void> _parseQueryAnswer(int diaryId, String content) async {
    // 开关关闭 → 整个功能禁用（设置页可关）
    if (!_queryAnswerEnabled) return;

    if (_queryAnswerCache.containsKey(diaryId) ||
        _queryingDiaryIds.contains(diaryId)) return;

    // 长句跳过：用户说长句时意图模糊，不进行查询处理（与 _parseItemSplit 同步）
    if (ItemSplitter.cleanPunctuation(content).length > kDiaryShortTextMax) {
      return;
    }

    // 检测是否为查询语句（如"游戏机在哪儿"）
    final query = QueryDetector.detect(content);
    // ⚠️ QueryDetector 扩展后支持反向查询（"客厅里有什么"→type=locationQuery, itemName=''）。
    // DiaryTab 的 LocationAnswerWidget 是为正向查询设计的（📍物品→位置），
    // 反向查询的展示逻辑在 ListTab 处理，这里跳过避免拿空 itemName 查询全表。
    if (!query.isQuery || query.itemName.isEmpty) return;

    setState(() {
      _queryingDiaryIds.add(diaryId);
    });

    try {
      // 后台查询 items 表，按 id 倒序（最近优先）
      final matches = await widget.dbHelper.searchItemsByName(
        query.itemName,
        limit: 10,
      );
      if (mounted) {
        setState(() {
          _queryAnswerCache[diaryId] = _QueryAnswer(
            itemName: query.itemName,
            matches: matches,
          );
        });
      }
    } catch (e) {
      print('解析查询答案失败: $e');
    } finally {
      if (mounted) {
        setState(() {
          _queryingDiaryIds.remove(diaryId);
        });
      }
    }
  }

  /// 检测日记内容是否为"物品+位置"模式，缓存结果用于渲染转存横条
  /// 与 _parseQueryAnswer 模式对称：懒加载 + 防重复 + setState 触发重渲染
  void _parseItemSplit(int diaryId, String content) {
    if (_itemSplitCache.containsKey(diaryId) ||
        _parsingItemSplitIds.contains(diaryId)) {
      return;
    }

    // 开关关闭 → 整个功能禁用（设置页可关）
    if (!_itemTransferEnabled) return;

    // 用户已 dismiss 此 content → 不再触发转存检测（dismiss 学习）
    // 显式置 null 防止重试，与"检测后无结果"一致
    if (_dismissedSplits.contains(content)) {
      _itemSplitCache[diaryId] = null;
      return;
    }

    // 长句跳过：用户说长句时意图模糊，不进行转存处理（与 _parseQueryAnswer 同步）
    if (ItemSplitter.cleanPunctuation(content).length > kDiaryShortTextMax) {
      return;
    }

    // 互斥规则：查询语句优先（"游戏机在哪里"不应被拆成"游戏机 / 哪里"）
    if (QueryDetector.detect(content).isQuery) {
      return;
    }

    _parsingItemSplitIds.add(diaryId);

    // 同步检测（纯 Dart 计算，无 IO）
    final result = ItemSplitter.detect(content);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {
        _itemSplitCache[diaryId] = result;
        _parsingItemSplitIds.remove(diaryId);
      });
    });
  }

  /// 将日记转存为物品后删除原日记（含录音文件）
  /// 参考现有 _deleteItem 的录音文件清理模式
  Future<void> _transferToItem(
      int diaryId, String itemName, String location) async {
    // 1. 写入 items 表
    await widget.dbHelper.insertItem(itemName, location);
    AppLogger.appLog(
        '📦 [Diary] 转存物品: $itemName -> $location (来源日记#$diaryId)');

    // 2. 先获取日记的录音文件路径（deleteDiary 只删数据库行，不删文件）
    final diaries = await widget.dbHelper.queryAllDiaries();
    final diary = diaries.firstWhere(
      (d) => d['id'] == diaryId,
      orElse: () => <String, dynamic>{},
    );
    final audioPath = diary['audio_path'] as String?;

    // 3. 删除数据库记录
    await widget.dbHelper.deleteDiary(diaryId);

    // 4. 删除对应的录音文件（复用 _deleteItem 的清理模式）
    if (audioPath != null && audioPath.isNotEmpty) {
      try {
        final file = File(audioPath);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (e) {
        // 文件删除失败不影响主流程，仅记录日志
        print('转存时删除录音文件失败: $e');
      }
    }

    // 5. 清缓存（避免悬空引用）
    _itemSplitCache.remove(diaryId);
    _queryAnswerCache.remove(diaryId);
    _timeEntitiesCache.remove(diaryId);

    // 6. 震动反馈（参考日记保存的 _haptic('tick')）
    _haptic('tick');

    // 7. 刷新列表
    refreshList();

    // 8. SnackBar 提示
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已转存：$itemName → $location'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  /// 用户点了物品转存横条的 ✕：表示"这条不是物品记录"。
  /// 入库 dismissed_splits + 加内存 Set + 隐藏横条 + 震动 + SnackBar
  /// 与 _transferToItem 结构对称：写库 → 改缓存 → 震动 → SnackBar
  Future<void> _onItemSplitDismiss(int diaryId, String content) async {
    // 1. 入库 dismissed_splits（持久化，重启后仍生效）
    await widget.dbHelper.insertDismissedSplit(content);
    // 2. 加内存 Set（本次会话立即生效，避免重复查库）
    _dismissedSplits.add(content);
    // 3. 隐藏横条（显式置 null，与 _parseItemSplit 中的 dismiss 守卫呼应）
    setState(() {
      _itemSplitCache[diaryId] = null;
    });
    // 4. 震动反馈（与转存成功 _transferToItem 同款 _haptic('tick')）
    _haptic('tick');
    // 5. SnackBar 提示
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('已记下，类似内容不再提示'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  /// 从日记内容中剥离用户点击的时间子串，得到动作内容
  /// 用于日历事件标题——时间信息已通过 timestamp 传递，标题无需重复
  /// 例：「今天晚上十二点提醒我去睡觉」→「提醒我去睡觉」
  /// 例：「下午3点」→ 剥离后为空 → 回退用原文「下午3点」
  String _extractActionContent(String content, TimeEntity entity) {
    if (content.isEmpty) return content;
    // 防御：start/end 必须在合法区间（解析器理论上保证，双保险）
    if (entity.start < 0 ||
        entity.end > content.length ||
        entity.start >= entity.end) {
      return content;
    }
    final before = content.substring(0, entity.start);
    final after = content.substring(entity.end);
    String remaining = before + after;
    // 去掉首尾中英文标点和空白（剥离后可能留下孤立逗号/顿号）
    remaining = remaining.replaceAll(
        RegExp(r'^[\s，,。.、；;：:！!？?]+'), '');
    remaining = remaining.replaceAll(
        RegExp(r'[\s，,。.、；;：:！!？?]+$'), '');
    // 合并中间连续空格（如「提醒我 明天8点 起床」→「提醒我 起床」中间留有空格）
    remaining = remaining.replaceAll(RegExp(r'\s+'), ' ').trim();
    // 剥离后为空（原文只有时间表达式）→ 回退用原文，避免空标题
    return remaining.isEmpty ? content : remaining;
  }

  /// 处理时间实体点击 - 设置闹钟
  Future<void> _handleTimeEntityTap(int diaryId, TimeEntity entity) async {
    if (entity.dateTime == null) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('无法解析时间')));
      }
      return;
    }

    final diary = _diaryList.firstWhere(
      (d) => d['id'] == diaryId,
      orElse: () => <String, dynamic>{'id': diaryId, 'content': ''},
    );

    // 剥离时间子串，得到干净的日历事件标题（所见即所得：
    // AlarmDialog 显示的内容 = 写入日历的 title = 通知栏响铃显示的内容）
    final actionContent = _extractActionContent(
        diary['content'] ?? '', entity);

    final result = await AlarmDialog.show(
      context,
      entity,
      actionContent,
    );

    if (result?.confirmed == true) {
      final enableAlarm = result!.enableAlarm;

      // 先请求通知权限（Android 13+ 通知栏响铃停止按钮必需）
      // 仅在用户开启响铃闹钟时请求
      if (enableAlarm) {
        final notifStatus = await Permission.notification.request();
        if (!notifStatus.isGranted) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(notifStatus.isPermanentlyDenied
                    ? '通知权限被拒绝，请在系统设置中手动开启，否则无法在通知栏停止响铃'
                    : '需要通知权限才能显示响铃通知'),
                backgroundColor: Colors.orange,
                duration: Duration(seconds: 3),
              ),
            );
          }
          return;
        }
      }

      // 再请求日历权限
      final status = await Permission.calendarFullAccess.request();
      if (!status.isGranted) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(status.isPermanentlyDenied
                  ? '日历权限被拒绝，请在系统设置中手动开启'
                  : '需要日历权限才能添加日程提醒'),
              backgroundColor: Colors.orange,
              duration: Duration(seconds: 3),
            ),
          );
        }
        return;
      }

      final channel = const MethodChannel('com.shengwuji.app/app');
      try {
        final success = await channel.invokeMethod('addCalendarEvent', {
          'timestamp': entity.dateTime!.millisecondsSinceEpoch,
          'title': actionContent,
          'enableAlarm': enableAlarm,
        });

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(success == true
                  ? (enableAlarm
                      ? '日程已成功添加到系统日历'
                      : '日程已添加到系统日历（无响铃）')
                  : '添加日历事件失败，请检查日历权限'),
              backgroundColor: success == true ? Colors.green : Colors.red,
              duration: Duration(seconds: 3),
            ),
          );
        }
      } catch (e) {
        print('添加日历事件失败: $e');
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('添加日历事件失败')));
        }
      }
    }
  }

  // --- 引擎初始化 (复用逻辑) ---
  // ⚠️ 【延迟加载守卫规则】修改此区域前必读：
  // 1. initEngine() 只能检查 isReady，不能检查 isProcessing
  //    原因：stopListening 调用链是 isProcessing=true → initEngine() → 加载模型
  //    如果 initEngine 检查 isProcessing 则模型永远加载不了
  // 2. stopListening() 只能检查 isProcessing，不能检查 _recognizer==null
  //    原因：首次录音时 _recognizer 为 null 是正常的（延迟加载），模型在 stopListening 内部加载
  // 3. startListening() 的 isProcessing 检查是为了防止重复调用
  //    权限授予后的 generation 检查是为了防止权限弹窗打断长按手势的竞态条件
  Future<void> initEngine() async {
    print(
      "🔍 [Diary] initEngine: 入口, isReady=$isReady, isProcessing=$isProcessing",
    );
    if (isReady)
      return; // ⚠️ 延迟加载模式下不检查 isProcessing（stopListening 会先设 isProcessing=true 再调此方法）

    // 检查权限
    if (await Permission.microphone.request().isGranted) {
      // 使用单例初始化
      final success = await _recognizerManager.initialize();
      print("🔍 [Diary] initEngine: 初始化结果, success=$success");

      if (mounted) {
        _updateState(() {
          isReady = success;
          statusText = success ? "" : "⚠️ 请先在设置导入模型";
        });
      }

      // 引擎加载完成，标记为就绪
      if (success && !_engineReadyCompleter.isCompleted) {
        _engineReadyCompleter.complete();
      }
    } else {
      if (mounted) {
        _updateState(() => statusText = "⚠️ 需要麦克风权限");
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

      print("日记引擎预热完成");
    } catch (e) {
      print("日记引擎预热失败: $e");
    }
  }

  // --- 录音控制 ---
  /// 开始录音（支持锁定录音模式）
  /// [lockedMode] 是否为锁定录音模式（通过快捷方式触发）
  Future<void> startListening({bool lockedMode = false}) async {
    final myGeneration = ++_operationGeneration;
    print(
      "🔍 [Diary] startListening: 入口, generation=$myGeneration, isProcessing=$isProcessing, isReady=$isReady, isListening=$isListening",
    );

    // 防止正在处理时重复调用
    if (isProcessing) {
      print("🔍 [Diary] startListening: 正在处理中，忽略");
      return;
    }

    // 如果是锁定模式，设置标志并启用 Wakelock
    if (lockedMode) {
      _isLockedRecording = true;
      // 启用 Wakelock 保持屏幕唤醒
      try {
        await WakelockPlus.enable();
      } catch (e) {
        print("启用 Wakelock 失败: $e");
      }
      // 震动反馈
      _haptic('heavy');
      // 快速录音时静音其他媒体
      try {
        await _channel.invokeMethod('muteMedia');
        // 显示静音提示（前5次）
        await _showMuteHintIfNeeded();
      } catch (e) {
        print("静音媒体失败: $e");
      }
    }

    // 设置录音状态标志（供原生层双击检测使用）
    await _setRecordingFlag(true);

    if (!isReady && !RecognizerSingleton.hasModel) {
      // 如果连模型文件都没有，提示用户
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text("⚠️ 请先在设置中导入语音识别模型")));
      }
      if (lockedMode) {
        _isLockedRecording = false;
        try {
          await WakelockPlus.disable();
        } catch (e) {
          print("禁用 Wakelock 失败: $e");
        }
      }
      return;
    }

    // ... 原有的录音逻辑 ...
    // 权限授予后，检查是否已被 stopListening 中断（权限弹窗可能打断了长按手势）
    if (myGeneration != _operationGeneration || isProcessing) {
      print(
        "🔍 [Diary] startListening: 权限授予后发现状态已变（generation=$myGeneration→$_operationGeneration, isProcessing=$isProcessing），放弃录音",
      );
      if (lockedMode) {
        _isLockedRecording = false;
        try {
          await WakelockPlus.disable();
        } catch (e) {
          print("禁用 Wakelock 失败: $e");
        }
      }
      return;
    }

    // 如果不是锁定模式，使用原来的短震动
    if (!lockedMode) {
      _haptic('click');
    }
    _audioBuffer.clear();
    _pcmBuilder.clear(); // 清空之前的 bytes

    // 记录录音开始时间
    _recordingStartTime = DateTime.now();

    final stream = await _audioRecorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
      ),
    );
    _updateState(() {
      isListening = true;
      statusText = "正在聆听...";
    });
    stream.listen((data) {
      // data 可能是 List<int> 或 Uint8List，确保为 Uint8List
      final chunk = Uint8List.fromList(data);
      _pcmBuilder.add(chunk);
      _audioBuffer.addAll(_convertBytesToFloat32(chunk));
    });
  }

  void stopListening() async {
    _operationGeneration++; // 使正在等待权限的 startListening 失效
    print(
      "🔍 [Diary] stopListening: 入口, generation=$_operationGeneration, isProcessing=$isProcessing, _recordingStartTime=$_recordingStartTime",
    );

    // 清除录音状态标志（供原生层双击检测使用）
    await _setRecordingFlag(false);

    // 如果是锁定录音模式，释放 Wakelock 并重置标志
    if (_isLockedRecording) {
      // 取消静音提示轮询定时器
      _muteHintTimer?.cancel();
      _muteHintTimer = null;
      try {
        await WakelockPlus.disable();
      } catch (e) {
        print("禁用 Wakelock 失败: $e");
      }
      // 恢复媒体音量（如果用户没按音量减保持静音）
      try {
        await _channel.invokeMethod('restoreMedia');
      } catch (e) {
        print("恢复媒体音量失败: $e");
      }
      _isLockedRecording = false;

      // 🔒 锁屏隐私保护：录音停止时**不**清除 sticky 锁屏 flag。
      // 否则 APP 立即失去"锁屏之上"显示能力，用户在锁屏之上录完后看不到转写结果。
      // flag 的清理由 MainActivity 的 ACTION_SCREEN_OFF 接收器统一负责
      // （用户主动锁屏时清 flag + moveTaskToBack）。

      // 停止时震动反馈
      _haptic('heavy');
    }

    // ⚠️ 延迟加载模式下只检查 isProcessing，不能检查 _recognizer==null
    // 因为首次录音时 _recognizer 为 null 是正常的，模型会在后面加载
    if (isProcessing) return;

    // 录音从未开始（权限弹窗阻断了 startListening 流程，录音从未启动）
    if (_recordingStartTime == null) {
      print(
        "🔍 [Diary] stopListening: 录音从未开始（_recordingStartTime=null），跳过模型加载，重置状态",
      );
      _updateState(() {
        isProcessing = false;
        isListening = false;
        statusText = "";
      });
      return;
    }

    // 计算录音时长
    final recordingDuration = _recordingStartTime != null
        ? DateTime.now().difference(_recordingStartTime!)
        : Duration.zero;
    final bool isLongRecording = recordingDuration.inSeconds >= 30;

    // 保存录音时长（秒）到成员变量，供后续保存到数据库使用
    _recordingDurationInSeconds = recordingDuration.inSeconds;

    print("录音时长: ${recordingDuration.inSeconds}秒, 是否长语音: $isLongRecording");

    // === 阶段1：先更新UI为识别中状态 ===
    _updateState(() {
      isListening = false;
      isProcessing = true;
      statusText = "生成日记中...";
    });

    // === 阶段2：停止录音 ===
    try {
      await _audioRecorder.stop();
      await Future.delayed(const Duration(milliseconds: 50));
    } catch (e) {
      print("停止录音失败: $e");
    }

    // === 阶段3：先播放转圈动画（避免模型加载阻塞动画） ===
    // 上下游：原设计把模型加载放在 delay 之前，native 同步加载会卡住橙色转圈
    // 重排后先 delay 让用户看到完整动画，再做模型加载（UI 可能卡顿但关键视觉已演完）
    if (isLongRecording) {
      // 长语音：1.5秒动画
      await Future.delayed(const Duration(milliseconds: 1500));
    } else {
      // 短语音：800ms 动画
      await Future.delayed(const Duration(milliseconds: 800));
    }

    // === 阶段3.5：切换到中间态（按钮变绿+"识别中..."文字） ===
    // 关键过渡：isProcessing 从 true→false 触发 main.dart 中 AnimatedContainer 200ms
    // 颜色渐变，用户看到"橙→淡黄→绿"过渡色。后续模型加载/识别都在绿色普通态下进行，
    // native 卡顿不可见。statusText="识别中..." 保留文字提示，告知用户引擎仍在工作
    if (mounted) {
      _updateState(() {
        isProcessing = false;
        statusText = "识别中...";
      });
    }
    await Future.delayed(const Duration(milliseconds: 100)); // 等 UI 渲染稳定

    // === 阶段4：加载模型（无遮罩；UI 可能短暂卡顿但动画已演完） ===
    try {
      if (!isReady || !_recognizerManager.isReady) {
        if (!_recognizerManager.hasEverInitialized) {
          try {
            await initEngine();
            if (!isReady) {
              // 加载失败处理
              if (_isLockedRecording) {
                _isLockedRecording = false;
                try {
                  await WakelockPlus.disable();
                } catch (e) {
                  print("禁用 Wakelock 失败: $e");
                }
              }
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text("⚠️ 模型加载失败，请检查设置")),
                );
              }
              _updateState(() {
                isProcessing = false;
                statusText = "录音已停止";
              });
              return;
            }
          } catch (e) {
            if (mounted) {
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(SnackBar(content: Text("⚠️ 模型加载出错: $e")));
            }
            if (_isLockedRecording) {
              _isLockedRecording = false;
              try {
                await WakelockPlus.disable();
              } catch (e) {
                print("禁用 Wakelock 失败: $e");
              }
            }
            _updateState(() {
              isProcessing = false;
              statusText = "录音已停止";
            });
            return;
          }
        } else {
          // hasEverInitialized 为 true 但 isReady 为 false
          // 说明引擎已初始化但 DiaryTab 状态未同步（如快捷方式冷启动进入）
          await initEngine();
        }
      }

      // 模型加载完成后，继续原有的识别逻辑
      await _engineReadyCompleter.future;
    } catch (e) {
      print("模型加载阶段出错: $e");
      if (_isLockedRecording) {
        _isLockedRecording = false;
        try {
          await WakelockPlus.disable();
        } catch (e) {
          print("禁用 Wakelock 失败: $e");
        }
      }
      _updateState(() {
        isProcessing = false;
        statusText = "录音已停止";
      });
      return;
    }

    // === 阶段5：识别（按钮已是绿色普通态，native 卡顿对用户不可见） ===
    await _processRecognition();

    // === 阶段6：清理 statusText，刷新列表（isProcessing 已在阶段3.5 切换为 false） ===
    if (mounted) {
      _updateState(() {
        statusText = "";
      });
    }
    await refreshList();

    // 短语音震动反馈（与原短语音分支一致）
    if (!isLongRecording && mounted) {
      await Future.delayed(const Duration(milliseconds: 50));
      _haptic('click');
    }
  }

  // 执行语音识别的核心逻辑（提取为独立方法）
  Future<void> _processRecognition() async {
    try {
      final rawText = await _recognizeLong();
      if (rawText.isNotEmpty) {
        await _processRecognizedText(rawText);
      }
    } catch (e) {
      print("日记识别出错: $e");
      AppLogger.appLog('❌ [Diary] 识别出错: $e');
    } finally {
      // 清理缓冲区：识别路径（_recognizeLong）会自己管 stream.free，
      // 但 _audioBuffer 和 _pcmBuilder 是录音期间累积的，必须在这里清理
      _audioBuffer.clear();
      _pcmBuilder.clear();
    }
  }

  /// 根据录音时长路由识别方式：< 60s 整段识别，≥ 60s 走 VAD 切分保护
  /// 返回识别后的文本（已拼接），调用方负责后续处理（_processRecognizedText）
  Future<String> _recognizeLong() async {
    // _recordingDurationInSeconds 是 nullable（int?），null 视为 0 走短录音原逻辑
    final int durationSec = _recordingDurationInSeconds ?? 0;
    final bool isLongRecording = durationSec >= kLongRecordingThresholdSec;

    if (!isLongRecording) {
      // 短录音：原整段识别逻辑（保留原行为）
      if (_audioBuffer.isEmpty) return '';
      final stream = _recognizer!.createStream();
      try {
        stream.acceptWaveform(
          samples: Float32List.fromList(_audioBuffer),
          sampleRate: 16000,
        );
        _recognizer!.decode(stream);
        final rawText = _recognizer!.getResult(stream).text;
        print("原始识别: $rawText");
        AppLogger.appLog('🎤 [Diary] 原始识别: $rawText');
        return rawText;
      } finally {
        stream.free();
      }
    }

    // 长录音：VAD 切分 + 逐段识别 + 文本拼接
    print("📦 [长录音保护] 录音 ${_recordingDurationInSeconds}s ≥ ${kLongRecordingThresholdSec}s, 启用 VAD 切分");
    AppLogger.appLog('📦 [Diary] 启用长录音保护: ${_recordingDurationInSeconds}s');
    return _recognizeWithVad();
  }

  /// 长录音 VAD 切分核心：分块喂 VAD（避免 30s 环形缓冲溢出），逐段识别后拼接
  /// 失败时兜底退回整段识别（与原行为一致）
  Future<String> _recognizeWithVad() async {
    // 1. 确保 VAD 就绪（懒加载，与 record_tab.dart搬家模式 _enterMoveMode 同构）
    await VadSingleton.instance.initialize();

    final texts = <String>[];
    var segmentCount = 0;
    final sw = Stopwatch()..start();

    try {
      // 2. 分块喂 VAD（每块 5 秒 = 80000 samples，远小于 30s 环形缓冲）
      const int sampleRate = 16000;
      const int chunkSize = sampleRate * 5;
      for (int i = 0; i < _audioBuffer.length; i += chunkSize) {
        final end = min(i + chunkSize, _audioBuffer.length);
        final chunk = Float32List.fromList(_audioBuffer.sublist(i, end));
        VadSingleton.instance.vad!.acceptWaveform(chunk);
        segmentCount += await _drainAndCollect(
          vad: VadSingleton.instance.vad!,
          texts: texts,
        );
      }
      // 3. flush 强制输出尾部最后一段
      VadSingleton.instance.vad!.flush();
      segmentCount += await _drainAndCollect(
        vad: VadSingleton.instance.vad!,
        texts: texts,
      );

      final combined = texts.where((t) => t.trim().isNotEmpty).join('');
      print("📦 [长录音保护] 切出 $segmentCount 段, 拼接结果: $combined");
      AppLogger.appLog('📦 [Diary] 长录音切分: $segmentCount段 - $combined');

      // 4. SnackBar 提示（多段时）
      if (mounted && segmentCount > 1) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('长录音已切分为 $segmentCount 段识别后拼接'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
      return combined;
    } catch (e) {
      print('❌ [长录音保护] 失败: $e, 退回整段识别');
      AppLogger.appLog('❌ [Diary] 长录音切分失败: $e');
      // 兜底：失败时退回整段识别（与原行为一致）
      if (_audioBuffer.isEmpty) return '';
      final stream = _recognizer!.createStream();
      try {
        stream.acceptWaveform(
          samples: Float32List.fromList(_audioBuffer),
          sampleRate: 16000,
        );
        _recognizer!.decode(stream);
        return _recognizer!.getResult(stream).text;
      } finally {
        stream.free();
      }
    } finally {
      // 5. 释放 VAD（与搬家模式 _exitMoveMode 同构，防 native 内存泄漏）
      VadSingleton.instance.dispose();
      sw.stop();
      print("🚀 [长录音保护] VAD 切分总耗时: ${sw.elapsedMilliseconds}ms");
    }
  }

  /// 取出 VAD 已切分的所有段，逐段识别后追加到 texts，返回处理的段数
  Future<int> _drainAndCollect({
    required sherpa_onnx.VoiceActivityDetector vad,
    required List<String> texts,
  }) async {
    var count = 0;
    while (!vad.isEmpty()) {
      final seg = vad.front();
      vad.pop();
      count++;
      final text = await _recognizeSamplesToText(seg.samples);
      if (text.isNotEmpty) texts.add(text);
    }
    return count;
  }

  /// 单段 PCM 识别为纯文本（只识别不保存，与录入页搬家模式 _recognizeAndSave 不同）
  /// _recognizer 为 null 时返回空字符串（保守处理，调用方负责 fallback）
  Future<String> _recognizeSamplesToText(Float32List samples) async {
    final recognizer = _recognizer;
    if (recognizer == null) return '';
    final stream = recognizer.createStream();
    try {
      stream.acceptWaveform(samples: samples, sampleRate: 16000);
      recognizer.decode(stream);
      return recognizer.getResult(stream).text;
    } finally {
      stream.free();
    }
  }

  /// 处理已识别文本：热词纠错 → 清单检测 → WAV 生成 → insertDiary
  /// 共用入口：整段识别 + 长录音 VAD 切分拼接 后都走这里
  Future<void> _processRecognizedText(String rawText) async {
    // 应用热词替换（日记模式保留空格，不去除英文单词之间的空格）
    final processedText = widget.processor.process(
      rawText,
      removeSpaces: false,
    );
    print("修正后文本: $processedText");
    AppLogger.appLog('📝 [Diary] 修正后文本: $processedText');

    String text = processedText; // 使用处理后的文本

    // 清单检测：如果识别为清单，转为 markdown 存入 diary 表
    if (text.isNotEmpty) {
      final extractor = ListExtractor();
      final listResult = extractor.extract(text);
      if (listResult.isList) {
        final markdownContent = listResult.toMarkdown();
        await widget.dbHelper.insertDiary(markdownContent, audioPath: null, duration: 0);
        AppLogger.appLog('📋 [Diary] 清单识别: ${listResult.items.length}条 - $text');
        _haptic('click');
        await refreshList();
        return; // 清单已保存，不走日记存储
      }
    }

    // 简单处理：去掉末尾多余标点
    if (text.isNotEmpty) {
      // 1) 生成 wav 文件（使用 _pcmBuilder 中的原始 PCM16 bytes）
      try {
        final pcmBytes = _pcmBuilder.toBytes();
        if (pcmBytes.isNotEmpty) {
          final wavPath = await _writeWavFile(
            Uint8List.fromList(pcmBytes),
            sampleRate: 16000,
          );
          await widget.dbHelper.insertDiary(
            text,
            audioPath: wavPath,
            duration: _recordingDurationInSeconds,
          );
          AppLogger.appLog('💾 [Diary] 保存日记: $text');
        } else {
          // 没有采集到原始 bytes（异常情况），仍然保存文字
          await widget.dbHelper.insertDiary(
            text,
            audioPath: null,
            duration: _recordingDurationInSeconds,
          );
        }
      } catch (e) {
        // 出错也不要阻塞：保存文字并记录日志
        print('保存 wav 失败: $e');
        await widget.dbHelper.insertDiary(
          text,
          audioPath: null,
          duration: _recordingDurationInSeconds,
        );
      }
      // 震动移到外部处理，避免阻塞动画
    }
  }

  // --- 辅助工具 ---
  Float32List _convertBytesToFloat32(Uint8List bytes) {
    final int16Data = bytes.buffer.asInt16List();
    final float32Data = Float32List(int16Data.length);
    for (int i = 0; i < int16Data.length; i++) {
      float32Data[i] = int16Data[i] / 32768.0;
    }
    return float32Data;
  }

  /// 显示静音提示（可在设置中关闭）
  Future<void> _showMuteHintIfNeeded() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // 检查开关
      final hintEnabled = prefs.getBool('mute_hint_enabled') ?? true;
      if (!hintEnabled) return;
      // 显示提示
      if (mounted) {
        final ext = AppThemeExtension.of(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              "已进入临时静音，如需保持静音，请按音量减键",
              style: TextStyle(color: ext.textPrimary),
            ),
            duration: const Duration(milliseconds: 1800),
            backgroundColor: ext.surface, // 原 Color(0xE6323232) SnackBar 背景
            behavior: SnackBarBehavior.floating,
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.all(Radius.circular(20)),
            ),
            margin: const EdgeInsets.only(bottom: 200, left: 60, right: 60),
          ),
        );
      }
      // 启动轮询：检测用户是否按了音量减
      _muteHintTimer?.cancel();
      _muteHintTimer = Timer.periodic(const Duration(milliseconds: 500), (
        timer,
      ) async {
        try {
          final p = await SharedPreferences.getInstance();
          // 强制从磁盘重新读取（原生层写入后 Dart 缓存不会自动更新）
          await p.reload();
          final keepMuted = p.getBool('keep_muted') ?? false;
          print("🔇 [Diary] 轮询 keep_muted=$keepMuted");
          if (keepMuted && mounted) {
            timer.cancel();
            _muteHintTimer = null;
            final ext2 = AppThemeExtension.of(context);
            ScaffoldMessenger.of(context).clearSnackBars();
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  "录音结束将保持静音",
                  style: TextStyle(color: ext2.textPrimary),
                ),
                duration: const Duration(milliseconds: 1500),
                backgroundColor: ext2.surface, // 原 Color(0xE6323232) SnackBar 背景
                behavior: SnackBarBehavior.floating,
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.all(Radius.circular(20)),
                ),
                margin: const EdgeInsets.only(bottom: 200, left: 60, right: 60),
              ),
            );
          }
        } catch (_) {
          // 轮询失败不影响录音
        }
      });
    } catch (e) {
      print("显示静音提示失败: $e");
    }
  }

  void _deleteItem(int id) async {
    // 1. 先获取日记的录音文件路径
    final diaries = await widget.dbHelper.queryAllDiaries();
    final diary = diaries.firstWhere(
      (d) => d['id'] == id,
      orElse: () => <String, dynamic>{},
    );
    final audioPath = diary['audio_path'] as String?;

    // 2. 删除数据库记录
    await widget.dbHelper.deleteDiary(id);

    // 3. 删除对应的录音文件
    if (audioPath != null && audioPath.isNotEmpty) {
      try {
        final file = File(audioPath);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (e) {
        // 文件删除失败不影响主流程，仅记录日志
        print('删除录音文件失败: $e');
      }
    }

    refreshList();
    if (mounted) {
      final ext = AppThemeExtension.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            "日记已删除",
            style: TextStyle(color: ext.textPrimary),
          ),
          duration: const Duration(milliseconds: 1500),
          backgroundColor: ext.surface, // 原 Color(0xCC323232) SnackBar 背景
          behavior: SnackBarBehavior.floating,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(20)),
          ),
          margin: const EdgeInsets.symmetric(horizontal: 60),
        ),
      );
    }
  }

  void _archiveItem(int id) async {
    // 1. 先获取日记的录音文件路径
    final diaries = await widget.dbHelper.queryAllDiaries();
    final diary = diaries.firstWhere(
      (d) => d['id'] == id,
      orElse: () => <String, dynamic>{},
    );
    final audioPath = diary['audio_path'] as String?;

    // 2. 归档数据库记录
    await widget.dbHelper.archiveDiary(id);

    // 3. 删除对应的录音文件
    if (audioPath != null && audioPath.isNotEmpty) {
      try {
        final file = File(audioPath);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (e) {
        // 文件删除失败不影响主流程，仅记录日志
        print('删除录音文件失败: $e');
      }
    }

    refreshList();
    if (mounted) {
      final ext = AppThemeExtension.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            "日记已归档",
            style: TextStyle(color: ext.textPrimary),
          ),
          duration: const Duration(milliseconds: 1500),
          backgroundColor: ext.surface, // 原 Color(0xCC323232) SnackBar 背景
          behavior: SnackBarBehavior.floating,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(20)),
          ),
          margin: const EdgeInsets.symmetric(horizontal: 60),
        ),
      );
    }
  }

  // --- 复制和编辑功能 ---

  // 复制到剪贴板
  void _copyToClipboard(String content) async {
    _haptic('tick');
    await Clipboard.setData(ClipboardData(text: content));
    // 静默复制，不显示提示
  }

  /// 分享日记内容到 AI 应用
  /// 1. 复制文本到剪贴板
  /// 2. 使用包名启动应用（Android）或 URL（iOS/其他）
  Future<void> _shareToAI(String content) async {
    // 1. 复制到剪贴板（静默复制）
    await Clipboard.setData(ClipboardData(text: content));

    // 2. 震动反馈（中等强度）
    _haptic('tick');

    // 3. 读取用户选择的 AI 应用
    final prefs = await SharedPreferences.getInstance();
    final appId = prefs.getString('selected_ai_app') ?? 'chatgpt';
    final selectedApp = AIApp.findById(appId) ?? AIApp.defaultApp;

    // 4. 根据平台和应用类型使用不同的启动方式
    if (Platform.isAndroid) {
      // Android: 大部分应用使用包名，但微信等系统应用使用 URL
      if (selectedApp.id == 'wechat') {
        // 微信特殊处理：使用 URL scheme
        try {
          final wechatUri = Uri.parse('weixin://');
          final success = await launchUrl(
            wechatUri,
            mode: LaunchMode.externalApplication,
          );
          if (success) {
            print("✅ 成功启动 ${selectedApp.name} (scheme): weixin://");
          } else {
            // scheme 失败，尝试 web URL
            final webUri = Uri.parse(selectedApp.url);
            await launchUrl(webUri, mode: LaunchMode.externalApplication);
            print("✅ 成功启动 ${selectedApp.name} (web): ${selectedApp.url}");
          }
        } catch (e) {
          print("⚠️ 微信启动失败: $e");
          if (mounted) {
            _showLaunchErrorHint(selectedApp.name);
          }
        }
      } else {
        // 其他应用：使用包名直接启动
        try {
          await LaunchApp.openApp(
            androidPackageName: selectedApp.packageName,
            openStore: false,
          );
          print(
            "✅ 成功启动 ${selectedApp.name} (package): ${selectedApp.packageName}",
          );
        } catch (e) {
          print("⚠️ 启动失败: $e");
          if (mounted) {
            _showLaunchErrorHint(selectedApp.name);
          }
        }
      }
    } else {
      // iOS 或其他平台: 使用 URL scheme 或 web URL
      bool launched = false;

      // 先尝试 scheme
      try {
        final schemeUri = Uri.parse(selectedApp.scheme);
        if (await canLaunchUrl(schemeUri)) {
          final success = await launchUrl(
            schemeUri,
            mode: LaunchMode.externalApplication,
          );
          if (success) {
            launched = true;
            print("✅ 成功启动 ${selectedApp.name} (scheme): ${selectedApp.scheme}");
          }
        }
      } catch (e) {
        print("⚠️ Scheme 启动失败: $e");
      }

      // 失败则尝试 web URL
      if (!launched) {
        try {
          final webUri = Uri.parse(selectedApp.url);
          final success = await launchUrl(
            webUri,
            mode: LaunchMode.externalApplication,
          );
          if (success) {
            print("✅ 成功启动 ${selectedApp.name} (web): ${selectedApp.url}");
          } else {
            if (mounted) {
              _showLaunchErrorHint(selectedApp.name);
            }
          }
        } catch (e) {
          print("⚠️ Web URL 启动失败: $e");
          if (mounted) {
            _showLaunchErrorHint(selectedApp.name);
          }
        }
      }
    }
  }

  /// 显示启动失败的提示
  void _showLaunchErrorHint(String appName) {
    final ext = AppThemeExtension.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(Icons.info_outline, color: ext.textOnPrimary), // 原 Colors.white
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                "内容已复制，请手动打开 $appName",
                style: TextStyle(fontSize: 14, color: ext.textOnPrimary),
              ),
            ),
          ],
        ),
        backgroundColor: ext.fabProcessing, // 原 Colors.orangeAccent 启动失败提示
        duration: const Duration(seconds: 3),
      ),
    );
  }

  // 开始编辑 - 弹出底部抽屉
  void _startEditing(int id, String content) {
    _haptic('click');
    _showEditSheet(id, content);
  }

  // 底部抽屉编辑
  void _showEditSheet(int id, String content, {bool isNewEmptyNote = false}) async {
    _editController.text = content;
    // FocusNode 在 builder 外创建，避免每次重建都新建
    final focusNode = FocusNode();
    _editFocusNode = focusNode; // 保存引用，供后台恢复时重新拉起键盘
    // 用外层 context 获取状态栏高度（sheetContext 可能被消耗 padding）
    final statusBarHeight = MediaQuery.of(context).padding.top;
    // 延迟聚焦：等抽屉滑入动画完成再拉键盘
    // 注意：不能用 addPostFrameCallback，冷启动场景下 postFrame 触发时抽屉
    // 动画仍在进行，TextField 尚未 attach 到 render tree，requestFocus 会
    // 被丢弃（参见提交 10a146c 引入的回归）
    Future.delayed(const Duration(milliseconds: 300), () {
      if (mounted) {
        focusNode.requestFocus();
      }
    });

    final ext = AppThemeExtension.of(context);
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent, // 透明遮罩，保持不变
      builder: (sheetContext) {
        final screenHeight = MediaQuery.of(sheetContext).size.height;
        final keyboardHeight = MediaQuery.of(sheetContext).viewInsets.bottom;
        // 无键盘：85% 屏幕高度；有键盘：不超过状态栏
        final availableHeight = screenHeight - statusBarHeight - keyboardHeight;
        final targetHeight = min(
          (screenHeight - statusBarHeight) * 0.85,
          availableHeight,
        );
        return Padding(
          padding: EdgeInsets.only(bottom: keyboardHeight),
          child: Container(
            height: targetHeight,
            decoration: BoxDecoration(
              color: ext.cardBackground, // 原 Colors.white 编辑抽屉背景
              borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.max,
              children: [
                // 拖拽指示条
                Container(
                  margin: const EdgeInsets.only(top: 8, bottom: 4),
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: ext.textHint.withValues(alpha: 0.3), // 原 Colors.grey[300] 拖拽指示条
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                // 编辑内容区域
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: TextField(
                      controller: _editController,
                      focusNode: focusNode,
                      maxLines: null,
                      autofocus: false,
                      decoration: const InputDecoration(
                        border: InputBorder.none,
                        hintText: "编辑日记内容...",
                      ),
                      style: const TextStyle(fontSize: 16, height: 1.6),
                    ),
                  ),
                ),
                // 底部按钮栏
                SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () {
                            // 取消：如果是空白新笔记则删除
                            if (isNewEmptyNote &&
                                _editController.text.trim().isEmpty) {
                              widget.dbHelper.deleteDiary(id);
                              refreshList();
                            }
                            // 🔒 锁屏隐私保护：编辑面板关闭时**不**清 flag（与 stopListening 一致），
                            // 由 ACTION_SCREEN_OFF 接收器统一负责
                            Navigator.pop(sheetContext);
                          },
                          child: const Text("取消"),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton(
                          onPressed: () async {
                            _haptic('tick');
                            final newContent =
                                _editController.text.trim();
                            if (newContent.isEmpty) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                    content: Text("内容不能为空")),
                              );
                              return;
                            }
                            await widget.dbHelper.updateDiary(
                                id, newContent);
                            refreshList();
                            // 🔒 锁屏隐私保护：编辑面板关闭时**不**清 flag（与 stopListening 一致），
                            // 由 ACTION_SCREEN_OFF 接收器统一负责
                            Navigator.pop(sheetContext);

                            // 显示保存成功提示
                            if (mounted) {
                              final overlay = Overlay.of(context);
                              final overlayEntry = OverlayEntry(
                                builder: (context) => Positioned(
                                  top: 40,
                                  left: 20,
                                  right: 20,
                                  child: Material(
                                    color: Colors.transparent, // 透明 Material 层，保持不变
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 20, vertical: 12),
                                      decoration: BoxDecoration(
                                        color: ext.primary, // 原 Colors.teal 保存成功提示背景
                                        borderRadius:
                                            BorderRadius.circular(24),
                                        boxShadow: [
                                          BoxShadow(
                                            color: Colors.black.withValues(
                                                alpha: 0.1),
                                            blurRadius: 8,
                                            offset: const Offset(0, 2),
                                          ),
                                        ],
                                      ),
                                      child: Center(
                                        child: Text(
                                          "保存成功",
                                          style: TextStyle(
                                            color: ext.textOnPrimary, // 原 Colors.white
                                            fontSize: 14,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              );
                              overlay.insert(overlayEntry);
                              Future.delayed(const Duration(seconds: 1), () {
                                overlayEntry.remove();
                              });
                            }
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: ext.primary, // 原 Colors.teal
                            foregroundColor: ext.textOnPrimary, // 原 Colors.white
                          ),
                          child: const Text("保存"),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    _editFocusNode = null;
    focusNode.dispose();
  }

  // --- 构建卡片 UI ---

  /// 清单项勾选/取消（基于 diary 表中的 markdown 内容）
  void _toggleChecklistItem(int diaryId, String content, int lineIndex) {
    final lines = content.split('\n');
    int count = 0;
    for (int i = 0; i < lines.length; i++) {
      if (lines[i].contains('- [ ]') || lines[i].contains('- [x]')) {
        if (count == lineIndex) {
          lines[i] = lines[i].contains('- [ ]')
              ? lines[i].replaceFirst('- [ ]', '- [x]')
              : lines[i].replaceFirst('- [x]', '- [ ]');
          break;
        }
        count++;
      }
    }
    final newContent = lines.join('\n');
    widget.dbHelper.updateDiary(diaryId, newContent);
    _haptic('click'); // 勾选触感反馈
    setState(() {
      final idx = _diaryList.indexWhere((d) => d['id'] == diaryId);
      if (idx != -1) {
        _diaryList[idx] = Map<String, dynamic>.from(_diaryList[idx])
          ..['content'] = newContent;
      }
    });
  }

  // 构建普通模式的卡片内容
  Widget _buildNormalCard(Map<String, dynamic> item) {
    final ext = AppThemeExtension.of(context);
    final isArchived = item['is_archived'] == 1;
    final date = DateTime.tryParse(item['created_at']) ?? DateTime.now();
    final dateStr =
        "${date.month}月${date.day}日 ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}";

    // 格式化音频时长：例如 0:05、3:13
    String durationStr = '';
    if (item['duration'] != null) {
      final int durationInSeconds = item['duration'];
      final int minutes = durationInSeconds ~/ 60;
      final int seconds = durationInSeconds % 60;
      durationStr = '$minutes:${seconds.toString().padLeft(2, '0')}';
    }

    // 获取日记ID和内容
    final diaryId = item['id'] as int;
    final content = item['content'] as String;

    // 首次显示时触发时间实体解析
    if (!_timeEntitiesCache.containsKey(diaryId) &&
        !_parsingDiaryIds.contains(diaryId)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _parseTimeEntities(diaryId, content);
      });
    }

    // 首次显示时触发查询答案解析（与时间实体同模式：懒加载 + 防重复）
    // 开关关闭时跳过调度（_parseQueryAnswer 入口也有守卫，这里省一次 addPostFrameCallback）
    if (_queryAnswerEnabled &&
        !_queryAnswerCache.containsKey(diaryId) &&
        !_queryingDiaryIds.contains(diaryId)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _parseQueryAnswer(diaryId, content);
      });
    }
    // 物品转存检测（与查询答案检测并列触发）
    // 开关关闭时跳过调度（_parseItemSplit 入口也有守卫，这里省一次 addPostFrameCallback）
    if (_itemTransferEnabled &&
        !_itemSplitCache.containsKey(diaryId) &&
        !_parsingItemSplitIds.contains(diaryId)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _parseItemSplit(diaryId, content);
      });
    }
    final answer = _queryAnswerCache[diaryId];
    // 物品转存检测结果（命中"物品+位置"模式时非 null）
    final itemSplit = _itemSplitCache[diaryId];

    final timeEntities = _timeEntitiesCache[diaryId] ?? [];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 清单渲染分支：检测到 markdown 任务列表格式时使用 ChecklistWidget
        if (ChecklistWidget.isChecklist(content))
          ChecklistWidget(
            content: content,
            onToggle: (lineIndex) => _toggleChecklistItem(diaryId, content, lineIndex),
          )
        // 时间高亮文本或普通文本
        else if (timeEntities.isEmpty)
            Text(
              content,
              style: TextStyle(
                fontSize: 16,
                height: 1.6,
                color: isArchived ? ext.textHint : ext.textPrimary, // 原 Colors.grey / Color(0xFF1E293B)
                decoration: isArchived ? TextDecoration.lineThrough : null,
              ),
            )
          else
            TimeAwareText(
              text: content,
              timeEntities: timeEntities,
              baseStyle: TextStyle(
                fontSize: 16,
                height: 1.6,
                color: isArchived ? ext.textHint : ext.textPrimary, // 原 Colors.grey / Color(0xFF1E293B)
                decoration: isArchived ? TextDecoration.lineThrough : null,
              ),
              onTimeTap: (entity) => _handleTimeEntityTap(diaryId, entity),
            ),
        // 答案区域（仅查询类笔记显示，不修改笔记 content）
        if (answer != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: LocationAnswerWidget(
              itemName: answer.itemName,
              matches: answer.matches,
              onViewMore: () => widget.onJumpToSearch?.call(answer.itemName),
            ),
          ),
        // 物品转存横条（命中"物品+位置"模式时显示，与查询答案区并列）
        if (itemSplit != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: ItemTransferWidget(
              itemName: itemSplit.item,
              location: itemSplit.location,
              onTransfer: () =>
                  _transferToItem(diaryId, itemSplit.item, itemSplit.location),
              onDismiss: () => _onItemSplitDismiss(diaryId, content),
            ),
          ),
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            // 左侧：日期 + 时长
            Row(
              children: [
                Text(
                  dateStr,
                  style: TextStyle(fontSize: 12, color: ext.textHint), // 原 Colors.grey
                ),
                if (durationStr.isNotEmpty) ...[
                  const SizedBox(width: 20),
                  Text(
                    durationStr,
                    style: TextStyle(fontSize: 12, color: ext.textHint), // 原 Colors.grey
                  ),
                ],
              ],
            ),
            // 右侧：播放按钮 + 分享按钮 + 爱心
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (item['audio_path'] != null && !isArchived)
                  SizedBox(
                    width: 40,
                    height: 40,
                    child: IconButton(
                      iconSize: 18,
                      padding: EdgeInsets.zero,
                      icon: Icon(
                        _playingDiaryId == item['id'] && _isPlaying
                            ? Icons.pause_circle_filled
                            : Icons.play_circle_fill,
                        color: ext.primary, // 原 Colors.teal 播放按钮
                      ),
                      onPressed: () =>
                          _togglePlay(item['id'], item['audio_path']),
                    ),
                  ),
                const SizedBox(width: 8),
                // AI 应用分享按钮
                SizedBox(
                  width: 40,
                  height: 40,
                  child: IconButton(
                    iconSize: 18,
                    padding: EdgeInsets.zero,
                    icon: const Icon(
                      Icons.chat_bubble_outline,
                      color: Colors.green, // AI 分享按钮品牌色，保留
                    ),
                    onPressed: () => _shareToAI(item['content']),
                    tooltip: "分享到 AI 应用",
                  ),
                ),
                const SizedBox(width: 8),
                // 喜欢图标（包在同样大小的容器中）
                SizedBox(
                  width: 40,
                  height: 40,
                  child: Icon(
                    Icons.favorite_border,
                    size: 18,
                    color: ext.textHint.withValues(alpha: 0.2), // 原 Colors.black12 装饰图标
                  ),
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }

  // --- UI 构建 ---
  @override
  Widget build(BuildContext context) {
    final ext = AppThemeExtension.of(context);

    // 如果正在初始化，返回空白容器，避免显示未初始化的UI
    if (_isInitializing) {
      return const SizedBox.shrink();
    }

    // 按钮颜色逻辑
    Color btnColor = ext.fabReady; // 原 Colors.teal 日记页录音按钮
    Widget btnChild = Icon(Icons.mic, color: ext.textOnPrimary, size: 40); // 原 Colors.white
    VoidCallback? onBtnPressed = startListening;

    // 获取当前屏幕的媒体查询数据
    // final MediaQueryData mediaQuery = MediaQuery.of(context);

    if (!isReady) {
      btnColor = ext.fabDisabled; // 原 Colors.grey
      onBtnPressed = null; // 禁用按钮
    } else if (isListening) {
      // 正在录音状态：红色背景，停止方块图标
      btnColor = ext.fabRecording; // 原 Colors.redAccent
      btnChild = Icon(Icons.stop, color: ext.textOnPrimary, size: 40); // 原 Colors.white
    } else if (isProcessing) {
      // 识别中状态：橙色背景，显示转圈圈的 Loading
      btnColor = ext.fabProcessing; // 原 Colors.orangeAccent
      btnChild = SizedBox(
        width: 30,
        height: 30,
        child: CircularProgressIndicator(color: ext.textOnPrimary, strokeWidth: 3), // 原 Colors.white
      );
      onBtnPressed = null; // 处理中禁用按钮
    }

    // 重点：获取键盘高度
    final double keyboardHeight = MediaQuery.of(context).viewInsets.bottom;

    return Scaffold(
      resizeToAvoidBottomInset: false, // <--- 添加这一行，禁止页面随键盘弹起而压缩
      backgroundColor: ext.scaffoldBackground, // 原 Color(0xFFF8F9FB)
      body: Stack(
        children: [
          // 1. 渐变背景层
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [ext.scaffoldBackground, ext.scaffoldBackground.withValues(alpha: 0.8)], // 原 Color(0xFFF8FAFC), Color(0xFFE2E8F0)
                ),
              ),
            ),
          ),

          // 2. 彩色光晕层（增强玻璃拟态层次感）
          Positioned(
            left: -50,
            top: -50,
            child: Container(
              width: 200,
              height: 200,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: ext.primary.withValues(alpha: 0.3), // 原 Colors.teal.withValues(alpha: 0.3) 光晕
                    blurRadius: 80,
                    spreadRadius: 40,
                  ),
                ],
              ),
            ),
          ),
          Positioned(
            right: 200,
            top: -30,
            child: Container(
              width: 180,
              height: 180,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: ext.timeHighlight.withValues(alpha: 0.25), // 原 Colors.blue.withValues(alpha: 0.25) 光晕
                    blurRadius: 70,
                    spreadRadius: 35,
                  ),
                ],
              ),
            ),
          ),
          Positioned(
            left: -80,
            top: 300,
            child: Container(
              width: 150,
              height: 150,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: ext.primary.withValues(alpha: 0.15), // 原 Colors.purple.withValues(alpha: 0.15) 光晕，映射到 primary
                    blurRadius: 60,
                    spreadRadius: 30,
                  ),
                ],
              ),
            ),
          ),

          // 3. 列表内容层
          Column(
            children: [
              const SizedBox(height: 60), // 顶部留白
              // 搜索框和导出按钮（玻璃拟态）
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  children: [
                    // 搜索框
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(24),
                        child: BackdropFilter(
                          filter: ui.ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                          child: Container(
                            decoration: BoxDecoration(
                              color: ext.cardBackground.withValues(alpha: 0.4), // 原 Color(0x66FFFFFF) 玻璃拟态搜索框
                              borderRadius: BorderRadius.circular(24),
                              border: Border.all(
                                color: Colors.black.withValues(alpha: 0.08), // 原 Color(0x14000000) 极淡黑色边框
                                width: 1,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.05),
                                  blurRadius: 8,
                                  offset: const Offset(0, 2),
                                ),
                              ],
                            ),
                            child: TextField(
                              controller: _searchController,
                              onChanged: (val) => refreshList(),
                              decoration: InputDecoration(
                                hintText: "搜索回忆...",
                                prefixIcon: Icon(
                                  Icons.search,
                                  color: ext.primary, // 原 Colors.teal 搜索图标
                                ),
                                border: InputBorder.none,
                                contentPadding: const EdgeInsets.symmetric(
                                  vertical: 15,
                                  horizontal: 20,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    // 导出按钮（长按可重新选择目录）
                    IconButton(
                      onPressed: _exportDiariesToMarkdown,
                      onLongPress: () async {
                        // 清除导出目录和导出标记，重新导出全部
                        final prefs = await SharedPreferences.getInstance();
                        await prefs.remove(_exportDirPrefKey);
                        await widget.dbHelper.clearAllExportState();
                        print("🔍 [Diary] 已清除导出目录和导出标记，将重新选择");
                        _exportDiariesToMarkdown();
                      },
                      icon: const Icon(Icons.download_rounded),
                      tooltip: '导出为 Markdown（长按重新选择目录）',
                      style: IconButton.styleFrom(
                        backgroundColor: ext.primary.withValues(alpha: 0.1), // 原 Colors.teal.withValues(alpha: 0.1)
                        foregroundColor: ext.primary, // 原 Colors.teal
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              // 日记列表
              Expanded(
                child: _diaryList.isEmpty
                    ? Center(
                        child: Text(
                          _isLoadingList ? "加载中..." : "还没有日记，试着说句话吧",
                          style: TextStyle(color: ext.textHint), // 原 Colors.grey
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(20, 10, 20, 160),
                        itemCount: _diaryList.length,
                        itemBuilder: (context, index) {
                          final item = _diaryList[index];
                          final isArchived = item['is_archived'] == 1;

                          // 检测是否需要显示归档分隔线
                          Widget? separator;
                          if (isArchived && index > 0) {
                            final prevItem = _diaryList[index - 1];
                            if (prevItem['is_archived'] != 1) {
                              separator = Container(
                                margin: const EdgeInsets.symmetric(
                                  vertical: 16,
                                ),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Divider(
                                        color: ext.textHint, // 原 Colors.grey
                                        thickness: 1,
                                      ),
                                    ),
                                    Container(
                                      margin: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                      ),
                                      child: Text(
                                        '已归档',
                                        style: TextStyle(
                                          color: ext.textHint, // 原 Colors.grey
                                          fontSize: 12,
                                        ),
                                      ),
                                    ),
                                    Expanded(
                                      child: Divider(
                                        color: ext.textHint, // 原 Colors.grey
                                        thickness: 1,
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            }
                          }

                          return Column(
                            key: ValueKey(item['id']),
                            children: [
                              if (separator != null) separator,
                              SwipeDismissCard(
                                icon: isArchived ? Icons.delete : Icons.archive,
                                iconColor: ext.textSecondary, // 原 Colors.grey.shade600
                                circleColor: ext.textHint, // 原 Colors.grey.shade500
                                onDismissed: () {
                                  _haptic('click');
                                  print('[DiaryTab] onDismissed: id=${item['id']}, isArchived=$isArchived, 移除前列表长度=${_diaryList.length}');
                                  setState(() {
                                    _diaryList.removeWhere(
                                      (d) => d['id'] == item['id'],
                                    );
                                  });
                                  print('[DiaryTab] onDismissed: 移除后列表长度=${_diaryList.length}');
                                  if (isArchived) {
                                    _deleteItem(item['id']);
                                  } else {
                                    _archiveItem(item['id']);
                                  }
                                },
                                child: GestureDetector(
                                  onTap: () =>
                                      _copyToClipboard(item['content']),
                                  onDoubleTap: () =>
                                      _shareToAI(item['content']), // 新增：双击分享
                                  onLongPress: () => _startEditing(
                                    item['id'],
                                    item['content'],
                                  ),
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(16),
                                    child: BackdropFilter(
                                      filter: ui.ImageFilter.blur(
                                        sigmaX: 10,
                                        sigmaY: 10,
                                      ),
                                      child: Container(
                                        margin: const EdgeInsets.only(
                                          bottom: 12,
                                        ),
                                        padding: const EdgeInsets.all(16),
                                        decoration: BoxDecoration(
                                          color: ext.cardBackground.withValues(alpha: 0.7), // 原 Color(0xB3FFFFFF) 玻璃拟态卡片
                                          borderRadius:
                                              BorderRadius.circular(16),
                                          border: Border.all(
                                            color: Colors.black.withValues(alpha: 0.08), // 原 Color(0x14000000) 极淡黑色边框
                                            width: 1,
                                          ),
                                          boxShadow: [
                                            BoxShadow(
                                              color: Colors.black.withValues(
                                                alpha: 0.05,
                                              ),
                                              blurRadius: 10,
                                              offset: const Offset(0, 4),
                                            ),
                                          ],
                                        ),
                                        child: _buildNormalCard(item),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          );
                        },
                      ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
