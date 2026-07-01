import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;
import 'package:vibration/vibration.dart';
import '../db_helper.dart';
import '../recognizer_singleton.dart';
import '../text_processor.dart';
import '../theme/app_theme_extension.dart';
import '../utils/query_detector.dart';

class ListTab extends StatefulWidget {
  final DbHelper dbHelper;
  // 仿 DiaryTab 的 onStateChanged：录音/处理状态变化时通知父组件重建浮动按钮 UI
  // 上下游：main.dart 的 _buildFloatingListButton 订阅此回调刷新视觉态
  final VoidCallback? onStateChanged;
  // 注意：这里必须是 ListTabState，不能是私有的 _ListTabState
  const ListTab({super.key, required this.dbHelper, this.onStateChanged});

  @override
  State<ListTab> createState() => ListTabState();
}

// 注意：这里去掉了下划线，让它可以被 main.dart 的 GlobalKey 访问到
class ListTabState extends State<ListTab> {
  final TextEditingController _searchController = TextEditingController();
  List<Map<String, dynamic>> _allEntries = [];
  List<Map<String, dynamic>> _displayItems = [];

  // --- 语音查询相关 State ---
  // 上下游：RecognizerSingleton 是全局单例，DiaryTab 已初始化过，
  //         ListTab 直接读 _recognizerManager.recognizer 即可，无需自己 initialize
  final _recognizerManager = RecognizerSingleton.instance;
  // 本地 TextProcessor 实例（ListTab 不接收 processor 参数，避免改 main.dart）
  // 上下游：main.dart 只传 dbHelper 给 ListTab，TextProcessor 在此内部创建+loadConfigs
  final TextProcessor _processor = TextProcessor();

  bool _isVoiceRecording = false;
  bool _isVoiceProcessing = false;
  AudioRecorder? _audioRecorder;
  List<double> _audioBuffer = []; // PCM Float32 累积（sherpa_onnx 要求 Float32List）
  DateTime? _recordingStartTime;

  // --- 暴露给 main.dart 浮动按钮使用的 public API ---
  // 仿 DiaryTabState 的 isReady/isListening/isProcessing 模式
  // 上下游：main.dart._buildFloatingListButton 读取这三个 getter 决定按钮颜色/图标
  bool get isReady => _recognizerManager.isReady;
  bool get isListening => _isVoiceRecording;
  bool get isProcessing => _isVoiceProcessing;

  @override
  void initState() {
    super.initState();
    _audioRecorder = AudioRecorder();
    _processor.loadConfigs(); // 异步加载纠错规则，不阻塞 UI
    refreshItems();
    _initEngineIfNeeded(); // 🆕 异步触发模型加载，不阻塞 build
  }

  @override
  void dispose() {
    // 切 Tab 时如果还在录音，必须停止录音并释放资源
    // 上下游：AudioRecorder().dispose() 会停止任何进行中的录音
    if (_isVoiceRecording) {
      _audioRecorder?.stop();
    }
    _audioRecorder?.dispose();
    _searchController.dispose();
    super.dispose();
  }

  // 这个方法现在是公开的，main.dart 可以直接调用它
  void refreshItems() async {
    final data = await widget.dbHelper.queryAll();
    if (!mounted) return;
    setState(() {
      _allEntries = data;
      _filterItems(_searchController.text);
    });
  }

  void _filterItems(String query) {
    String q = query.toLowerCase();
    setState(() {
      _displayItems = q.isEmpty
          ? _allEntries
          : _allEntries
                .where(
                  (i) =>
                      i['name'].toString().toLowerCase().contains(q) ||
                      i['location'].toString().toLowerCase().contains(q),
                )
                .toList();
    });
  }

  // 公开方法：设置搜索框内容并触发过滤（日记页"+N"跳转使用）
  void setSearchQuery(String query) {
    _searchController.text = query;
    _filterItems(query);
  }

  /// 引擎初始化（仿 DiaryTab.initEngine）
  /// 让 ListTab 不依赖 DiaryTab 先初始化，冷启动直接进 ListTab 也能加载模型
  /// 上下游：initState 末尾异步触发；startVoiceSearch 在 isReady=false 时也主动调用
  Future<void> initEngine() async {
    // 已就绪 → 跳过
    if (isReady) return;

    // 模型文件不存在 → 不加载（startVoiceSearch 会提示导入）
    if (!RecognizerSingleton.hasModel) {
      await RecognizerSingleton.preloadModelPath();
      if (!RecognizerSingleton.hasModel) return;
    }

    // 调用单例加载（RecognizerSingleton 内部用 _isInitializing 串行化，
    // 即使 DiaryTab 同时也在 initEngine，二次调用会安全等待）
    final success = await _recognizerManager.initialize();
    print("🔍 [ListTab] initEngine: 初始化结果, success=$success");

    if (mounted) {
      setState(() {}); // 刷新按钮状态（isReady 会变 true）
      widget.onStateChanged?.call(); // 通知 main.dart 重建浮动按钮
    }
  }

  /// initState 用的私有 wrapper：让 build 先完成再异步加载模型
  Future<void> _initEngineIfNeeded() async {
    // Future.delayed(Duration.zero) 让当前帧先完成 build，
    // 避免在 initState 同步上下文调用 setState 引发警告
    await Future.delayed(Duration.zero);
    if (!mounted) return;
    await initEngine();
  }

  // --- 语音查询：震动反馈辅助方法 ---
  // 用户明确要求：开始录音震动 50ms/amplitude 50，停止震动 30ms/amplitude 40
  // 参考 record_tab.dart 的 _vibrate 实现风格
  Future<void> _haptic({int duration = 50, int amplitude = 50}) async {
    try {
      // vibration 3.1.8 的 hasVibrator 返回非空 Future<bool>，无需 ?? false
      if (await Vibration.hasVibrator() == true) {
        Vibration.vibrate(duration: duration, amplitude: amplitude);
      }
    } catch (e) {
      print("ListTab 震动失败: $e");
    }
  }

  // --- 语音查询：开始录音 ---
  // 公开方法：main.dart 的浮动按钮直接调用（仿 DiaryTabState.startListening）
  Future<void> startVoiceSearch() async {
    // 处理中或已录音中，忽略重复点击
    if (_isVoiceProcessing || _isVoiceRecording) return;

    // 检查模型文件是否存在（hasModel 缓存由 preloadModelPath 维护）
    if (!RecognizerSingleton.hasModel) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text("⚠️ 请先在设置中导入语音识别模型")));
      }
      return;
    }
    // 模型存在但识别器未就绪 → 主动加载（initState 的异步加载可能还没完成）
    if (!_recognizerManager.isReady) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text("识别器加载中，请稍后...")));
      }
      await initEngine();
      if (!isReady) return; // 加载失败，放弃本次录音
    }

    // 检查麦克风权限
    final micStatus = await Permission.microphone.status;
    if (!micStatus.isGranted) {
      final result = await Permission.microphone.request();
      if (!result.isGranted) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text("需要麦克风权限才能语音查询")));
        }
        return;
      }
    }

    // 权限通过后再次校验状态（权限弹窗可能打断点击流程）
    if (_isVoiceProcessing || _isVoiceRecording) return;

    // 清空缓冲区
    _audioBuffer.clear();
    _recordingStartTime = DateTime.now();

    try {
      final stream = await _audioRecorder!.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
        ),
      );
      stream.listen((data) {
        // data 可能是 List<int> 或 Uint8List，统一转 Uint8List 再转 Float32
        final chunk = Uint8List.fromList(data);
        _audioBuffer.addAll(_convertBytesToFloat32(chunk));
      });

      // 开始录音震动反馈（用户明确要求 50ms/amplitude 50）
      await _haptic(duration: 50, amplitude: 50);

      if (mounted) {
        // 先通知父组件，让 main.dart 的浮动按钮同步切到"录音中"视觉态
        widget.onStateChanged?.call();
        setState(() {
          _isVoiceRecording = true;
        });
      }
      print("🔍 [ListTab] 语音查询录音开始");
    } catch (e) {
      print("🔍 [ListTab] 启动录音失败: $e");
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text("录音启动失败: $e")));
      }
    }
  }

  // --- 语音查询：停止录音 + 识别 + 查询分发 ---
  // 公开方法：main.dart 的浮动按钮直接调用（仿 DiaryTabState.stopListening）
  Future<void> stopVoiceSearch() async {
    if (!_isVoiceRecording) return;

    // 停止录音震动反馈（用户明确要求 30ms/amplitude 40）
    await _haptic(duration: 30, amplitude: 40);

    // 记录录音时长用于后续校验
    final recordingDuration = _recordingStartTime != null
        ? DateTime.now().difference(_recordingStartTime!)
        : Duration.zero;

    // 切换 UI 到处理中状态
    if (mounted) {
      // 先通知父组件，让浮动按钮切到"处理中"视觉态
      widget.onStateChanged?.call();
      setState(() {
        _isVoiceRecording = false;
        _isVoiceProcessing = true;
      });
    }

    // 停止录音流
    try {
      await _audioRecorder!.stop();
      await Future.delayed(const Duration(milliseconds: 50));
    } catch (e) {
      print("🔍 [ListTab] 停止录音失败: $e");
    }

    print("🔍 [ListTab] 语音查询录音时长: ${recordingDuration.inMilliseconds}ms");

    // 录音过短校验（<500ms 视为误触）
    if (recordingDuration.inMilliseconds < 500) {
      if (mounted) {
        // 通知父组件：处理结束，按钮恢复就绪态
        widget.onStateChanged?.call();
        setState(() {
          _isVoiceProcessing = false;
        });
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text("录音过短，请重试")));
      }
      _audioBuffer.clear();
      return;
    }

    // 执行识别 + 查询分发
    await _processVoiceSearch();

    if (mounted) {
      // 通知父组件：处理结束，按钮恢复就绪态
      widget.onStateChanged?.call();
      setState(() {
        _isVoiceProcessing = false;
      });
    }
  }

  // --- 语音查询：识别 + 纠错 + 查询分发 ---
  Future<void> _processVoiceSearch() async {
    sherpa_onnx.OfflineStream? stream;
    try {
      final recognizer = _recognizerManager.recognizer;
      if (recognizer == null) {
        print("🔍 [ListTab] 识别器为 null，无法识别");
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text("识别器加载中，请稍后")));
        }
        return;
      }

      if (_audioBuffer.isEmpty) {
        print("🔍 [ListTab] 录音缓冲为空");
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text("没听清，请重试")));
        }
        return;
      }

      // 识别
      stream = recognizer.createStream();
      stream.acceptWaveform(
        samples: Float32List.fromList(_audioBuffer),
        sampleRate: 16000,
      );
      recognizer.decode(stream);
      final result = recognizer.getResult(stream);
      final rawText = result.text;
      print("🔍 [ListTab] 原始识别: $rawText");

      if (rawText.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text("没听清，请重试")));
        }
        return;
      }

      // 纠错（参考 DiaryTab 第 1407 行 widget.processor.process 调用）
      // ListTab 查询场景默认 removeSpaces=true（查询词不需要空格）
      final corrected = _processor.process(rawText, removeSpaces: true);
      print("🔍 [ListTab] 纠错后: $corrected");

      // 查询检测
      final queryResult = QueryDetector.detect(corrected);

      if (!queryResult.isQuery) {
        // 不命中查询模式 → 提示用户正确说法
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('没听懂，请说"XX在哪里"或"XX里有什么"')),
          );
        }
        return;
      }

      // 根据查询方向预填搜索框（复用 setSearchQuery 触发本地 _filterItems）
      // _filterItems 已支持 name + location 双字段 LIKE 过滤，无论传物品名还是位置名都正确
      switch (queryResult.type) {
        case QueryType.itemQuery:
          print("🔍 [ListTab] 正向查询: ${queryResult.itemName}");
          setSearchQuery(queryResult.itemName);
          break;
        case QueryType.locationQuery:
          print("🔍 [ListTab] 反向查询: ${queryResult.locationName}");
          setSearchQuery(queryResult.locationName);
          break;
      }
    } catch (e) {
      print("🔍 [ListTab] 识别/查询出错: $e");
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text("识别出错: $e")));
      }
    } finally {
      stream?.free();
      _audioBuffer.clear();
    }
  }

  // --- PCM bytes → Float32 转换（参考 diary_tab.dart 第 1477 行同款实现）---
  Float32List _convertBytesToFloat32(Uint8List bytes) {
    final int16Data = bytes.buffer.asInt16List();
    final float32Data = Float32List(int16Data.length);
    for (int i = 0; i < int16Data.length; i++) {
      float32Data[i] = int16Data[i] / 32768.0;
    }
    return float32Data;
  }

  // 注：浮动语音查询按钮的渲染已搬到 main.dart._buildFloatingListButton
  // 与日记页 _buildFloatingDiaryButton 对称——按钮钉在外层 Stack 不受键盘挤压
  // 本文件只保留录音/识别/纠错/查询分发逻辑和暴露 public getter + 方法

  @override
  Widget build(BuildContext context) {
    final ext = AppThemeExtension.of(context);
    // 注：浮动按钮渲染已搬到 main.dart._buildFloatingListButton（外层 Stack），
    // 这里恢复为单 Scaffold 结构，避免被 IndexedStack 的 resizeToAvoidBottomInset 挤压
    return Scaffold(
      // 1. 统一背景色
      backgroundColor: ext.scaffoldBackground, // 原 Color(0xFFF8F9FB)
      appBar: AppBar(
        title: Text(
          "物品列表",
          style: TextStyle(color: ext.textPrimary, fontWeight: FontWeight.bold),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        systemOverlayStyle: SystemUiOverlayStyle.dark,
      ),
      // 搜索框 + 物品列表（原 body 内 Stack 的第一层 Column）
      body: Column(
        children: [
          // 3. 仿照录音页 ModernField 样式的搜索框
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 20),
            child: Container(
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
                controller: _searchController,
                onChanged: (value) {
                  _filterItems(value);
                  setState(() {}); // 触发 suffixIcon 重新计算显隐
                },
                decoration: InputDecoration(
                  hintText: "搜索物品或位置...",
                  hintStyle: TextStyle(color: ext.textHint, fontSize: 14),
                  prefixIcon: Icon(Icons.search, color: ext.primary),
                  suffixIcon: _searchController.text.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.close, size: 20),
                          color: ext.textHint,
                          onPressed: () {
                            _searchController.clear();
                            _filterItems('');
                            setState(() {}); // 触发重建以隐藏 suffixIcon
                          },
                          tooltip: '清空',
                        )
                      : null,
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(vertical: 15),
                ),
              ),
            ),
          ),
          Expanded(
            child: _displayItems.isEmpty
                ? Center(
                    child: Text("暂无记录", style: TextStyle(color: ext.textHint)),
                  )
                : ListView.builder(
                    itemCount: _displayItems.length,
                    itemBuilder: (context, index) {
                      final item = _displayItems[index];
                      return Card(
                        color: ext.cardBackground,
                        margin: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 6,
                        ),
                        child: ListTile(
                          title: Text(
                            item['name'],
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          subtitle: Text("📍 ${item['location']}"),
                          trailing: IconButton(
                            icon: Icon(
                              Icons.delete_outline,
                              color: ext.dangerAccent,
                            ),
                            onPressed: () async {
                              final dbClient = await widget.dbHelper.db;
                              await dbClient.delete(
                                'items',
                                where: 'id = ?',
                                whereArgs: [item['id']],
                              );
                              refreshItems();
                            },
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
