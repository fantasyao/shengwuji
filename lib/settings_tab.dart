import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:archive/archive.dart';
import '../text_processor.dart';
import '../db_helper.dart';
import '../ai_app_model.dart';
import 'package:permission_handler/permission_handler.dart';
import '../recognizer_singleton.dart';
import '../startup_logger.dart';
import '../app_logger.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../widgets/pro_unlock_dialog.dart';
import '../theme/app_theme_extension.dart';
import '../theme/app_theme.dart'; // AppThemes / AppThemeDefinition（Phase 3 主题选择）
import '../main.dart'; // AppRoot.themeNotifier（Phase 3 主题切换）
import '../utils/icon_pack_switcher.dart'; // Phase 4 图标包切换
import '../utils/pro_gate.dart'; // Pro 门禁（永久解锁 + 7 天试用）
import '../utils/tab_visibility.dart'; // 功能页面隐藏开关 key（main.dart main() 预读同一组 key，重启生效）
import '../overlay/overlay_constants.dart'; // OverlayConstants.autoHide*（自动隐藏档位唯一真值，与 overlay engine 共用；主页悬浮窗入口行摘要读）
import '../utils/diary_tag.dart'; // 日记标注 tag 常量（CSV 导入校验）
import '../utils/correction_learner.dart'; // 错误-修正学习表（编解码 + 备份内容）
import '../web_server/diary_server_controller.dart'; // 电脑访问服务开关编排
import '../web_server/web_server_settings_card.dart'; // 电脑访问服务设置卡片
// zcode: 2026-09 设置页下沉——热词+修正学习/AI 应用/悬浮窗/音量键/关于五组
// 配置移入 lib/settings/ 二级页，主页只留入口行 + 状态摘要（返回后刷新）
import 'settings/about_page.dart';
import 'settings/accessibility_check.dart';
import 'settings/ai_app_page.dart';
import 'settings/overlay_settings_page.dart';
import 'settings/recognition_correction_page.dart';
import 'settings/settings_widgets.dart';
import 'widgets/neu_widgets.dart';
import 'settings/volume_key_settings_page.dart';

class SettingsTab extends StatefulWidget {
  final TextProcessor processor;
  final DbHelper dbHelper;
  const SettingsTab({
    super.key,
    required this.processor,
    required this.dbHelper,
  });

  @override
  State<SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<SettingsTab> with WidgetsBindingObserver {
  // zcode: 2026-09 下沉后主页保留的 state 缩减为「入口行摘要」所需最小集；
  // 各配置项的完整状态在 lib/settings/ 对应二级页内自管（prefs key 不变）
  String _modelPathInfo = "内置模型就绪";
  String? _selectedAIAppId; // 「AI 应用分享」入口行摘要：当前选中的 AI 应用 ID
  // 无障碍服务是否已开启（null=检测失败：与「未开启」区分，UI 显式提示而非误导用户去开无障碍——服务可能明明开着）
  bool? _isAccessibilityEnabled = false;
  int _hotwordCount = 0; // 「识别与修正」入口行摘要：热词条数
  // 「识别与修正」入口行摘要：错误-修正学习表条数（从二级页返回后刷新）
  int _correctionPairCount = 0;
  String _appVersion = ''; // 版本号，来自 package_info_plus（关于入口行）
  bool _isExportingStartupLog = false; // 启动日志导出中（同上）
  bool _isProActive =
      false; // Pro 是否可用（永久解锁或试用中），统一走 ProGate 判定
  String _currentIconPackId = 'default'; // 当前图标包 ID（从原生层读取，不依赖 prefs），Phase 4
  bool _itemTransferEnabled = true; // 日记智能识别物品+位置开关（默认开启）
  bool _queryAnswerEnabled = true; // 日记智能查询物品位置开关（默认开启）
  bool _swapTapLongPress = false; // 日记卡片单击/长按交换开关
  bool _recordTabHidden = false; // 功能页面：隐藏存物品页开关（prefKeyRecordTabHidden，main.dart main() 预读，重启生效）
  bool _listTabHidden = false; // 功能页面：隐藏查物品页开关（prefKeyListTabHidden，同上）
  int _overlayAutoHideSeconds = OverlayConstants
      .autoHideDefaultSeconds; // 悬浮窗入口行摘要：收起后自动隐藏秒数（二级页写，overlay engine 读同一 key）
  bool _overlaySideLeft =
      false; // 悬浮窗入口行摘要：停靠侧（OverlayConstants.overlaySideLeftPrefKey：false=右缘/true=左缘）
  // 字号缩放档位（外观分区选择器；默认 1.0 中档）
  double _fontScale = 1.0;

  /// 启动耗时诊断 UI 开关（暂时隐藏，需要时改为 true）
  static const bool _kShowStartupDiagnostics = false;

  @override
  void initState() {
    super.initState();
    _loadHotwordCount();
    _loadModelStatus();
    _loadAIAppPreference(); // 加载 AI 应用偏好（入口行摘要）
    _loadAppVersion(); // 加载应用版本号（关于入口行）
    _loadProUnlockStatus(); // 加载 Pro 解锁状态
    _loadCurrentIconPack(); // Phase 4：从原生层加载当前图标包状态
    _loadSmartSwitches(); // 加载日记智能识别开关状态
    _loadTabVisibility(); // 加载功能页面隐藏开关
    _loadOverlaySummary(); // 加载悬浮窗入口行摘要（停靠侧 + 自动隐藏）
    _loadFontScale(); // 加载全局字号缩放档位
    _loadCorrectionPairCount(); // 加载错误-修正学习表条数（入口行摘要）
    WidgetsBinding.instance.addObserver(this);
    _checkAccessibilityStatus();
  }

  /// 加载「错误-修正」学习表条数（入口行副标题显示）
  Future<void> _loadCorrectionPairCount() async {
    final pairs = await widget.dbHelper.getAllCorrectionPairs();
    if (mounted) {
      setState(() => _correctionPairCount = pairs.length);
    }
  }

  /// 加载热词条数（「识别与修正」入口行副标题显示；编辑在二级页，返回后重读）
  Future<void> _loadHotwordCount() async {
    final text = await widget.processor.getLocalContent();
    if (mounted) {
      setState(() => _hotwordCount = countHotwordLines(text));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // 从系统设置返回时刷新无障碍服务状态（音量键入口行状态点；
      // 手势/静音等配置详情在二级页，该页自身也有 resume 重查）
      _checkAccessibilityStatus();
    }
  }

  void _loadModelStatus() async {
    final prefs = await SharedPreferences.getInstance();
    String? path = prefs.getString('custom_model_path');
    if (path != null && Directory(path).existsSync()) {
      // 用户手动导入过模型，显示自定义模型信息
      setState(() => _modelPathInfo = "当前模型（自定义）：${p.basename(path)}");
    } else {
      // 没有自定义模型，显示内置模型状态
      setState(() => _modelPathInfo = "当前模型：内置模型（推荐）");
    }
  }

  /// 加载 Pro 可用状态（永久解锁或试用中，统一走 ProGate 判定）
  /// 后续功能门禁也读同一判定
  void _loadProUnlockStatus() async {
    final active = await ProGate.isProActive();
    if (mounted) {
      setState(() => _isProActive = active);
    }
  }

  /// Phase 4：从原生层查询当前图标包（状态源是系统 ComponentEnabledSetting，不依赖 prefs）
  void _loadCurrentIconPack() async {
    final packId = await IconPackSwitcher.getCurrentPackId();
    if (mounted) {
      setState(() => _currentIconPackId = packId);
    }
  }

  /// 加载日记页智能识别开关状态（与 DiaryTab._loadSmartSwitches 读同一组 prefs key）
  void _loadSmartSwitches() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _itemTransferEnabled =
            prefs.getBool('diary_item_transfer_enabled') ?? true;
        _queryAnswerEnabled =
            prefs.getBool('diary_query_answer_enabled') ?? true;
        _swapTapLongPress =
            prefs.getBool('diary_card_swap_tap_longpress') ?? false;
      });
    }
  }

  /// 加载功能页面隐藏开关（读取方：main.dart main() 预读同一组 key，
  /// MainScaffold 按 visibleTabStack 装配底部导航；重启生效）
  void _loadTabVisibility() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _recordTabHidden = prefs.getBool(prefKeyRecordTabHidden) ?? false;
        _listTabHidden = prefs.getBool(prefKeyListTabHidden) ?? false;
      });
    }
  }

  /// 保存功能页面隐藏开关（读取方：main.dart main() 预读；下次冷启动装配生效）
  Future<void> _saveTabVisibility({
    required bool recordHidden,
    required bool listHidden,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(prefKeyRecordTabHidden, recordHidden);
    await prefs.setBool(prefKeyListTabHidden, listHidden);
    print(
      '🔧 [Settings] tab_visibility recordHidden=$recordHidden listHidden=$listHidden',
    );
  }

  /// 加载悬浮窗入口行摘要所需的最小配置（停靠侧 + 收起后自动隐藏秒数）。
  /// 完整配置的读写已移入 lib/settings/overlay_settings_page.dart，
  /// key 与 overlay engine 读取方不变
  void _loadOverlaySummary() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        // 收起后自动隐藏秒数（读取方：overlay engine 的 _scheduleAutoHide）
        _overlayAutoHideSeconds =
            prefs.getInt('overlay_auto_hide_seconds') ??
            OverlayConstants.autoHideDefaultSeconds;
        // 停靠侧（读取方：overlay engine 的 _refreshSide/_scheduleAutoHide +
        // 原生窗口 Gravity，默认右缘）
        _overlaySideLeft =
            prefs.getBool(OverlayConstants.overlaySideLeftPrefKey) ?? false;
      });
    }
  }

  /// 加载全局字号缩放档位（读取方：AppRoot 的 fontScaleNotifier，启动时 main() 已预读）
  void _loadFontScale() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _fontScale = prefs.getDouble('font_size_scale') ?? 1.0;
      });
    }
  }

  /// 保存全局字号缩放档位（写 prefs 持久化 + 立即触发整树重建）
  Future<void> _saveFontScale(double scale) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('font_size_scale', scale);
    AppRoot.fontScaleNotifier.value = scale; // 立即触发整树重建
    setState(() => _fontScale = scale);
  }

  /// 显示 Pro 解锁弹窗，关闭后刷新按钮文案
  void _showProUnlockDialog() async {
    await ProUnlockDialog.show(context);
    // 弹窗里可能点击了解锁按钮，重新读 prefs 刷新本页按钮文案
    if (mounted) {
      _loadProUnlockStatus();
    }
  }

  void _loadAIAppPreference() async {
    final prefs = await SharedPreferences.getInstance();
    final appId = prefs.getString('selected_ai_app');
    if (appId != null) {
      setState(() => _selectedAIAppId = appId);
    } else {
      // 默认选择 ChatGPT
      setState(() => _selectedAIAppId = 'chatgpt');
    }
  }

  // --- 无障碍服务（音量键入口行状态点）---
  // 检测/跳转逻辑抽到 lib/settings/accessibility_check.dart（主页与音量键二级页共用）；
  // 检测失败≠未开启：置 null 让 UI 显示「检测失败」而非静默当未开启（resume 会重查自动恢复）
  void _checkAccessibilityStatus() async {
    final enabled = await checkAccessibilityServiceEnabled();
    if (mounted) {
      setState(() => _isAccessibilityEnabled = enabled);
    }
  }

  // --- 二级页跳转（zcode: 2026-09 下沉改造新增；await 返回后刷新对应入口行摘要）---

  Future<void> _openRecognitionCorrection() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => RecognitionCorrectionPage(
          processor: widget.processor,
          dbHelper: widget.dbHelper,
        ),
      ),
    );
    _loadHotwordCount(); // 热词可能在二级页编辑保存
    _loadCorrectionPairCount(); // 修正对可能在管理页有增删
  }

  Future<void> _openAIAppPage() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const AIAppPage()),
    );
    _loadAIAppPreference(); // 摘要跟随二级页的选择
  }

  Future<void> _openVolumeKeyPage() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const VolumeKeySettingsPage()),
    );
    _checkAccessibilityStatus(); // 可能刚引导用户去系统设置开启了服务，刷新状态点
  }

  Future<void> _openOverlayPage() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const OverlaySettingsPage()),
    );
    _loadOverlaySummary(); // 摘要跟随二级页的配置（停靠侧/自动隐藏）
  }

  // --- 应用版本号 ---
  Future<void> _loadAppVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) {
        setState(() {
          _appVersion = info.version; // 例如 "1.0.6"
        });
      }
    } catch (e) {
      log('读取版本号失败: $e');
      // 回退：使用 pubspec.yaml 中的硬编码版本号
      if (mounted) {
        setState(() {
          _appVersion = '1.2.0'; // 来自 pubspec.yaml version: 1.2.0+23
        });
      }
    }
  }

  // --- 导入模型文件逻辑 ---
  Future<void> _importModelFiles() async {
    try {
      setState(() => _modelPathInfo = "正在准备选择文件...");

      FilePickerResult? result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
      );

      if (result != null && result.files.length >= 2) {
        PlatformFile? modelFile;
        PlatformFile? tokensFile;

        for (var file in result.files) {
          if (file.name == 'model.int8.onnx') modelFile = file;
          if (file.name == 'tokens.txt') tokensFile = file;
        }

        if (modelFile != null && tokensFile != null) {
          setState(() => _modelPathInfo = "正在拷贝模型文件 (请稍候)...");

          final appDocDir = await getApplicationDocumentsDirectory();
          final targetDir = Directory(p.join(appDocDir.path, 'external_model'));
          if (!targetDir.existsSync()) await targetDir.create(recursive: true);

          final targetModelPath = p.join(targetDir.path, 'model.int8.onnx');
          final targetTokensPath = p.join(targetDir.path, 'tokens.txt');

          await File(modelFile.path!).copy(targetModelPath);
          await File(tokensFile.path!).copy(targetTokensPath);

          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('custom_model_path', targetDir.path);

          // ⚠️ 刷新模型路径缓存，使其他 Tab 的 hasModel 判断立即生效
          // 没有这行的话，导入模型后切回录音/日记页，按钮仍为灰色
          await RecognizerSingleton.preloadModelPath();

          // 主动请求麦克风权限，避免首次录音时权限弹窗打断长按手势
          final micStatus = await Permission.microphone.status;
          if (!micStatus.isGranted) {
            log("🔍 [Settings] 模型导入成功，主动请求麦克风权限...");
            await Permission.microphone.request();
            log(
              "🔍 [Settings] 麦克风权限请求完成: ${await Permission.microphone.status}",
            );
          }

          // 【新增】检查是否首次导入模型，如果是则清理缓存
          final bool hasImportedBefore =
              prefs.getBool('model_first_imported') ?? false;
          if (!hasImportedBefore) {
            // 首次导入，标记并清理缓存
            await prefs.setBool('model_first_imported', true);
            log("🎯 首次导入模型，准备清理缓存...");

            // 异步清理缓存，不阻塞UI
            Future.delayed(const Duration(milliseconds: 500), () async {
              await _clearAppCache();

              if (mounted) {
                final ext = AppThemeExtension.of(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Row(
                      children: [
                        Icon(Icons.cleaning_services, color: ext.textOnPrimary),
                        SizedBox(width: 10),
                        Text("✅ 模型导入成功！已自动清理缓存"),
                      ],
                    ),
                    backgroundColor: ext.primary,
                    duration: Duration(seconds: 3),
                  ),
                );
              }
            });
          } else {
            // 非首次导入，立即显示简单提示
            if (mounted) {
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(const SnackBar(content: Text("✅ 导入成功！录音功能已激活")));
            }
          }

          setState(() {
            _modelPathInfo = "✅ 模型导入成功";
          });
        } else {
          _showErrorDialog("文件不全", "请同时选中 model.int8.onnx 和 tokens.txt 这两个文件。");
        }
      }
    } catch (e) {
      setState(() => _modelPathInfo = "❌ 导入失败: $e");
    }
  }

  void _showErrorDialog(String title, String content) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("确定"),
          ),
        ],
      ),
    );
  }

  // --- 全量备份导入导出逻辑 ---

  // 导出完整备份（ZIP格式）
  Future<void> _exportFullBackup() async {
    try {
      // 显示加载提示
      if (mounted) {
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => const AlertDialog(
            content: Row(
              children: [
                CircularProgressIndicator(),
                SizedBox(width: 20),
                Text("正在准备导出..."),
              ],
            ),
          ),
        );
      }

      // 1. 获取数据（主 isolate：sqflite 平台通道查询 + CSV 字符串拼装，均轻量）
      final items = await widget.dbHelper.queryAll();
      final diaries = await widget.dbHelper.queryAllDiaries();

      // 收集有效的录音文件路径
      final validAudioPaths = <String>{};
      for (var diary in diaries) {
        final audioPath = diary['audio_path'] as String?;
        if (audioPath != null && audioPath.isNotEmpty) {
          // 提取文件名（因为 audio_path 是完整路径）
          final fileName = p.basename(audioPath);
          validAudioPaths.add(fileName);
        }
      }

      // 2. CSV / README / 热词内容（字符串传给 worker，拷贝成本远低于音频字节）
      final itemsCsv = _generateItemsCsv(items);
      final diaryCsv = _generateDiaryCsv(diaries);
      final readme = _generateReadme();
      final hotwordsContent = await widget.processor.getLocalContent();
      // 错误-修正学习表：编码成「错误 = 修正」文本随备份走
      final correctionsContent = CorrectionLearner.encodeCorrections(
        await widget.dbHelper.getAllCorrectionPairs(),
      );

      final appDocDir = await getApplicationDocumentsDirectory();
      final audioDirPath = p.join(appDocDir.path, 'diary_audio');

      // 3. 建档 + 压缩 ZIP 全部下沉 worker isolate（性能审查 Top2）：
      //    读音频字节 + ZipEncoder 压缩是纯 CPU/IO，原先在主 isolate 同步执行
      //    会冻结 UI 数秒。闭包经顶层 trampoline 创建，捕获域只剩可传输值。
      log('[备份导出][诊断] 步骤3: 即将进入 Isolate.run 压缩');
      final (zipBytes, orphanCount) = await _runBuildBackupZip(
        itemsCsv: itemsCsv,
        diaryCsv: diaryCsv,
        readme: readme,
        hotwordsContent: hotwordsContent,
        correctionsContent: correctionsContent,
        audioDirPath: audioDirPath,
        validAudioNames: validAudioPaths,
      );
      log('[备份导出][诊断] 步骤3完成 压缩: 孤儿音频=$orphanCount');

      // 4. 关闭加载对话框
      if (mounted) Navigator.pop(context);

      // 5. 保存文件
      final timestamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
      final fileName = 'voice_diary_backup_$timestamp.zip';

      final result = await FilePicker.platform.saveFile(
        fileName: fileName,
        bytes: zipBytes,
      );

      if (result != null) {
        // ZIP 创建成功后，清理孤儿录音文件
        final audioDir = Directory(audioDirPath);
        int deletedCount = 0;
        if (orphanCount > 0 && audioDir.existsSync()) {
          final audioFiles = audioDir.listSync().whereType<File>().toList();

          for (var audioFile in audioFiles) {
            final fileName = p.basename(audioFile.path);
            if (!validAudioPaths.contains(fileName)) {
              try {
                await audioFile.delete();
                deletedCount++;
              } catch (e) {
                log('删除孤儿录音失败: $fileName, 错误: $e');
              }
            }
          }
        }

        // 显示清理提示
        if (mounted) {
          if (deletedCount > 0) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  "✅ 已导出 ${diaries.length} 条日记，清理了 $deletedCount 个孤儿录音文件",
                ),
              ),
            );
          } else {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  "✅ 全量备份已导出：${items.length}个物品，${diaries.length}条日记",
                ),
              ),
            );
          }
        }
      }
    } catch (e, st) {
      // [隔离诊断] 异常连同堆栈落日志，定位抛错语句
      log('[备份导出] ❌ 异常: $e\n$st');
      if (mounted) {
        Navigator.pop(context); // 关闭加载对话框
        _showErrorDialog("导出失败", "错误详情：$e");
      }
    }
  }

  // 生成物品CSV
  String _generateItemsCsv(List<Map<String, dynamic>> items) {
    final rows = [
      ['物品', '位置'],
    ];
    for (var item in items) {
      rows.add([
        _escapeCsvField(item['name']?.toString() ?? ''),
        _escapeCsvField(item['location']?.toString() ?? ''),
      ]);
    }
    return rows.map((row) => row.join(',')).join('\n');
  }

  // 生成日记CSV
  String _generateDiaryCsv(List<Map<String, dynamic>> diaries) {
    final rows = [
      // 标注列放最后（v10 新增）：旧版本 App 解析时只读前 5 列，天然兼容
      ['ID', '内容', '创建时间', '音频文件', '时长(秒)', '标注'],
    ];
    for (var diary in diaries) {
      // 格式化创建时间，精确到秒
      String formattedTime = '';
      if (diary['created_at'] != null) {
        try {
          final dateTime = DateTime.parse(diary['created_at'].toString());
          formattedTime = DateFormat('yyyy-MM-dd HH:mm:ss').format(dateTime);
        } catch (e) {
          formattedTime = diary['created_at'].toString();
        }
      }

      rows.add([
        diary['id']?.toString() ?? '',
        _escapeCsvField(diary['content']?.toString() ?? ''),
        formattedTime,
        diary['audio_path'] != null ? p.basename(diary['audio_path']) : '',
        diary['duration']?.toString() ?? '',
        // 标注（'urgent'/'star'/'idea'），无标注导出为空串
        diary['tag']?.toString() ?? '',
      ]);
    }
    return rows.map((row) => row.join(',')).join('\n');
  }

  // CSV字段转义
  String _escapeCsvField(String value) {
    if (value.contains(',') ||
        value.contains('"') ||
        value.contains('\n') ||
        value.contains('\r')) {
      return '"${value.replaceAll('"', '""')}"';
    }
    return value;
  }

  // 生成README内容
  String _generateReadme() {
    final timestamp = DateFormat('yyyy-MM-dd HH:mm:ss').format(DateTime.now());
    return '''语音日记应用数据备份
导出时间: $timestamp

文件说明:
- items.csv: 物品位置数据
- diary.csv: 日记记录数据
- audio/: 日记音频文件
- user_hotwords.txt: 动态热词替换配置
- correction_pairs.txt: 错误-修正学习表（识别纠错提示用）

导入说明:
请通过设置页的"导入全量备份"功能恢复此数据。
''';
  }

  // 导入完整备份（ZIP格式）
  Future<void> _importFullBackup() async {
    try {
      // 选择文件
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['zip'],
      );

      if (result == null) return;

      // 显示确认对话框
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text("确认导入"),
          content: const Text("导入将合并现有数据，重复的记录将被跳过。是否继续？"),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text("取消"),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text("确认导入"),
            ),
          ],
        ),
      );

      if (confirmed != true) return;

      // 显示加载对话框
      if (mounted) {
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => const AlertDialog(
            content: Row(
              children: [
                CircularProgressIndicator(),
                SizedBox(width: 20),
                Text("正在导入数据..."),
              ],
            ),
          ),
        );
      }

      // 1. 读 ZIP + 解压 + 提取 CSV/热词 + 音频落盘，全部下沉 worker isolate
      //    （性能审查 Top2：inflate 解压是纯 CPU，原先在主 isolate 同步执行）
      //    worker 内只写不存在的音频文件（增量合并语义与原版一致）；
      //    缺必要 CSV 直接抛异常 → 外层 catch 弹错误框。
      final zipPath = result.files.single.path!;
      final appDocDir = await getApplicationDocumentsDirectory();
      final audioDirPath = p.join(appDocDir.path, 'diary_audio');

      // [根因修复] 闭包经顶层 trampoline 创建（见下方 worker 注释块），
      // State 方法作用域里直接写 Isolate.run 闭包会连带捕获 this/Element
      log('[备份导入][诊断] 步骤1: 即将进入 Isolate.run 解压');
      final extracted = await _runExtractBackupZip(zipPath, audioDirPath);
      log(
        '[备份导入][诊断] 步骤1完成 解压: '
        '有热词=${extracted.hotwords != null}, '
        '音频落盘=${extracted.restoredAudioCount}个',
      );

      // 2. 解析items.csv
      final items = _parseItemsCsv(extracted.itemsCsv);

      // 3. 解析diary.csv
      final diaries = _parseDiaryCsv(extracted.diaryCsv);
      log(
        '[备份导入][诊断] 步骤2-3完成 解析CSV: items=${items.length}, diaries=${diaries.length}',
      );

      // 5. 构建现有数据索引（用于去重）
      final existingItems = await widget.dbHelper.queryAll();
      final existingDiaries = await widget.dbHelper.queryAllDiaries();
      log(
        '[备份导入][诊断] 步骤5完成 查库: 现有items=${existingItems.length}, 现有diaries=${existingDiaries.length}',
      );

      // 构建物品索引：格式 "name|location"
      final itemIndex = <String>{};
      for (var item in existingItems) {
        final key = '${item['name']}|${item['location']}';
        itemIndex.add(key);
      }

      // 构建日记索引：格式 "content|createdAt"
      final diaryIndex = <String>{};
      for (var diary in existingDiaries) {
        final key = '${diary['content']}|${diary['created_at']}';
        diaryIndex.add(key);
      }

      // 6. 过滤并插入物品数据
      final newItems = <Map<String, String>>[];
      int skippedItems = 0;

      for (var item in items) {
        final key = '${item['name']}|${item['location']}';
        if (itemIndex.contains(key)) {
          skippedItems++;
        } else {
          newItems.add(item);
          itemIndex.add(key); // 添加到索引，防止导入文件内部重复
        }
      }

      if (newItems.isNotEmpty) {
        log('[备份导入][诊断] 步骤6: 写入新物品 ${newItems.length} 条');
        await widget.dbHelper.batchInsertItems(newItems);
      }

      // 7. 过滤并插入日记数据
      final newDiaries = <Map<String, dynamic>>[];
      int skippedDiaries = 0;

      for (var diary in diaries) {
        final key = '${diary['content']}|${diary['created_at']}';
        if (diaryIndex.contains(key)) {
          skippedDiaries++;
        } else {
          // 修复 audio_path：CSV 中只存了文件名，需要还原为完整路径
          final audioPath = diary['audio_path'];
          if (audioPath != null && !audioPath.toString().startsWith('/')) {
            diary['audio_path'] = p.join(
              appDocDir.path,
              'diary_audio',
              audioPath.toString(),
            );
          }
          newDiaries.add(diary);
          diaryIndex.add(key); // 添加到索引，防止导入文件内部重复
        }
      }

      if (newDiaries.isNotEmpty) {
        log('[备份导入][诊断] 步骤7: 写入新日记 ${newDiaries.length} 条');
        await widget.dbHelper.batchInsertDiaries(newDiaries);
      }

      // 8. 恢复热词配置（如备份中包含）—— 必须在"无新数据 early return"之前，
      // 否则当 items/diary 全部命中去重时热词永远无法恢复
      bool hotwordsRestored = false;
      final hotwordsContent = extracted.hotwords;
      if (hotwordsContent != null) {
        final ruleCount = hotwordsContent
            .split('\n')
            .where((l) => l.contains('=') && !l.trim().startsWith('#'))
            .length;
        log('[备份导入] 恢复热词: ${hotwordsContent.length} 字符, $ruleCount 条规则');
        log('[备份导入][诊断] 步骤8: 写入热词文件');
        await widget.processor.saveContent(hotwordsContent);
        log('[备份导入] 热词已写入并生效');
        if (mounted) {
          // zcode: 2026-09 热词编辑框移入「识别与修正」二级页，导入备份后刷新入口行摘要条数
          setState(() => _hotwordCount = countHotwordLines(hotwordsContent));
        }
        hotwordsRestored = true;
      } else {
        log('[备份导入] 备份中无 user_hotwords.txt，跳过热词恢复');
      }

      // 8.5 恢复错误-修正学习表（如备份中包含）——同样必须在 early return 之前。
      // 语义是"合并"而非"覆盖"：与已有条目相同的自动 hit_count+1（学习计数延续），
      // 老版本备份没有此文件时静默跳过
      int correctionsRestored = 0;
      final correctionsContent = extracted.corrections;
      if (correctionsContent != null) {
        final importedPairs = CorrectionLearner.parseCorrections(
          correctionsContent,
        );
        if (importedPairs.isNotEmpty) {
          await widget.dbHelper.learnCorrectionPairs(importedPairs);
          correctionsRestored = importedPairs.length;
        }
        log('[备份导入] 恢复错误-修正对: $correctionsRestored 条');
      } else {
        log('[备份导入] 备份中无 correction_pairs.txt，跳过修正对恢复（老版本备份）');
      }

      // 9. 检查是否有新数据（热词已在上一步独立恢复，不受此 return 影响）
      if (newItems.isEmpty && newDiaries.isEmpty) {
        log('[备份导入] 无新数据 early return (hotwordsRestored=$hotwordsRestored)');
        if (mounted) {
          Navigator.pop(context); // 关闭加载对话框
          final extras = <String>[
            if (hotwordsRestored) '热词配置已恢复',
            if (correctionsRestored > 0) '修正对已合并 $correctionsRestored 条',
          ];
          final msg = extras.isNotEmpty
              ? "✅ ${extras.join('，')}（无其他新数据）"
              : "⚠️ 备份文件中没有新数据";
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(msg)));
        }
        return;
      }

      // 10. 音频文件已在 worker isolate 内增量落盘（只写不存在的文件），
      //     此处直接取落盘计数展示
      final restoredAudioCount = extracted.restoredAudioCount;

      // 11. 关闭加载对话框
      if (mounted) Navigator.pop(context);

      // 12. 显示成功消息
      if (mounted) {
        String message =
            "✅ 增量导入成功：${newItems.length}个新物品，${newDiaries.length}条新日记";
        if (restoredAudioCount > 0) {
          message += "，$restoredAudioCount个新音频";
        }
        if (hotwordsRestored) {
          message += "，热词配置已恢复";
        }
        if (correctionsRestored > 0) {
          message += "，修正对合并 $correctionsRestored 条";
        }
        log(
          '[备份导入] 完成: 新物品=${newItems.length}, 新日记=${newDiaries.length}, '
          '新音频=$restoredAudioCount, 热词恢复=$hotwordsRestored, '
          '修正对合并=$correctionsRestored',
        );
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
      }
    } catch (e, st) {
      // [隔离诊断] 异常连同堆栈落日志：log 会写控制台 + AppLogger 缓冲区（app 内可导出），
      // 堆栈能直接定位是哪条语句抛的错（此前 catch 不带 st，堆栈丢失无从定位）
      log('[备份导入] ❌ 异常: $e\n$st');
      if (mounted) {
        Navigator.pop(context);
        _showErrorDialog("导入失败", "错误详情：$e");
      }
    }
  }

  // 解析items.csv
  List<Map<String, String>> _parseItemsCsv(String csvContent) {
    final lines = csvContent.split('\n');
    final items = <Map<String, String>>[];

    for (var i = 1; i < lines.length; i++) {
      // 跳过表头
      final line = lines[i].trim();
      if (line.isEmpty) continue;

      final parts = _parseCsvLine(line);
      if (parts.length >= 2) {
        items.add({'name': parts[0], 'location': parts[1]});
      }
    }
    return items;
  }

  // 解析diary.csv
  List<Map<String, dynamic>> _parseDiaryCsv(String csvContent) {
    final lines = csvContent.split('\n');
    final diaries = <Map<String, dynamic>>[];

    for (var i = 1; i < lines.length; i++) {
      // 跳过表头
      final line = lines[i].trim();
      if (line.isEmpty) continue;

      final parts = _parseCsvLine(line);
      if (parts.length >= 5) {
        final audioPath = parts[3].isNotEmpty ? parts[3] : null;
        diaries.add({
          'id': int.tryParse(parts[0]),
          'content': parts[1],
          'created_at': parts[2],
          'audio_path': audioPath,
          'duration': parts[4].isNotEmpty ? int.tryParse(parts[4]) : null,
          // 标注列（v10 新增，放最后）：旧备份没有第 6 列 → 容忍缺列置 null；
          // 有列但值非法（非 urgent/star/idea）同样按无标注处理
          'tag': parts.length > 5 && DiaryTag.isValid(parts[5])
              ? parts[5]
              : null,
        });
      }
    }
    return diaries;
  }

  // 解析CSV行（支持引号转义）
  List<String> _parseCsvLine(String line) {
    final result = <String>[];
    String current = '';
    bool inQuotes = false;

    for (int i = 0; i < line.length; i++) {
      final char = line[i];

      if (char == '"') {
        if (inQuotes && i + 1 < line.length && line[i + 1] == '"') {
          current += '"';
          i++; // 跳过下一个引号
        } else {
          inQuotes = !inQuotes;
        }
      } else if (char == ',' && !inQuotes) {
        result.add(current);
        current = '';
      } else {
        current += char;
      }
    }
    result.add(current);
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final ext = AppThemeExtension.of(context);
    // AI 应用入口行摘要用（选择列表在二级页，这里只显示当前选中项）
    final aiApp = AIApp.findById(_selectedAIAppId ?? AIApp.defaultApp.id);
    return Scaffold(
      backgroundColor: ext.scaffoldBackground,
      appBar: AppBar(
        title: Text(
          "设置中心",
          style: TextStyle(color: ext.textPrimary, fontWeight: FontWeight.bold),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        systemOverlayStyle: ext.isDarkOverlay
            ? SystemUiOverlayStyle.light
            : SystemUiOverlayStyle.dark,
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          // --- 模型管理部分（暂时隐藏） ---
          // _buildSectionTitle("引擎模型管理"),
          // _buildCard(
          //   child: Column(
          //     crossAxisAlignment: CrossAxisAlignment.start,
          //     children: [
          //       Text(
          //         _modelPathInfo,
          //         style: const TextStyle(color: Colors.black54, fontSize: 14),
          //       ),
          //       const SizedBox(height: 12),
          //       _buildMainBtn(
          //         "选择并导入模型文件",
          //         Icons.file_present,
          //         _importModelFiles,
          //       ),
          //       const SizedBox(height: 8),
          //       const Text(
          //         "提示：应用已内置模型，无需手动导入。如需使用自定义模型，进入文件夹后长按多选 model.int8.onnx 和 tokens.txt 即可覆盖",
          //         style: TextStyle(color: Colors.blueGrey, fontSize: 11),
          //       ),
          //     ],
          //   ),
          // ),

          // const SizedBox(height: 24),

          // --- 数据库管理部分 ---

          // 数据备份（含物品、日记、音频）
          _buildCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.backup_rounded,
                      color: ext.warningText,
                      size: 18,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      "数据备份",
                      style: TextStyle(
                        color: ext.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  "包含物品、日记和所有音频文件",
                  style: TextStyle(color: ext.textSecondary, fontSize: 12),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: _buildSecondaryBtn(
                        "导入备份",
                        Icons.restore,
                        _importFullBackup,
                        color: ext.warningText,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _buildSecondaryBtn(
                        "导出备份",
                        Icons.backup,
                        _exportFullBackup,
                        color: ext.warningText,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          const SizedBox(height: 12),

          // zcode: 2026-09-17 重排（settings_reorder_preview.html 拍板）——悬浮窗挪到
          // 音量键下面、电脑访问挪到顶部入口区末尾；外标题与卡内首行完全重复的五处
          // （识别与修正/AI 应用分享/音量键/悬浮窗/电脑访问）去掉 SettingsSectionTitle，
          // 连续卡片间距 24→12，组间距仍 24
          // --- 识别与修正（原「动态热词替换」+「智能修正学习」合并下沉二级页，zcode: 2026-09）---
          SettingsCard(
            padding: EdgeInsets.zero,
            child: SettingsEntryRow(
              icon: Icons.auto_fix_high_outlined,
              title: '识别与修正',
              subtitle: '热词 $_hotwordCount 条 · 修正对 $_correctionPairCount 条',
              onTap: _openRecognitionCorrection,
            ),
          ),
          const SizedBox(height: 12),

          // --- AI 应用分享（单选列表下沉二级页，zcode: 2026-09）---
          SettingsCard(
            padding: EdgeInsets.zero,
            child: SettingsEntryRow(
              icon: Icons.smart_toy_outlined,
              title: 'AI 应用分享',
              subtitle: aiApp != null
                  ? '分享跳转：${aiApp.icon} ${aiApp.name}'
                  : '分享跳转：未设置',
              onTap: _openAIAppPage,
            ),
          ),
          const SizedBox(height: 12),

          // --- 音量键快捷操作（下沉二级页，zcode: 2026-09；入口行保留无障碍状态点，
          // resume 后本页自动重查——检测失败误报修复见 15826e9）---
          SettingsCard(
            padding: EdgeInsets.zero,
            child: SettingsEntryRow(
              icon: Icons.volume_up,
              title: '音量键快捷操作',
              titleSuffix: _buildA11yStatusDot(),
              subtitle: _isAccessibilityEnabled == true
                  ? '已开启 · 长按/双击音量键快速唤起录音、笔记或悬浮窗'
                  : _isAccessibilityEnabled == null
                  ? '检测失败 · 点击进入查看，回到本页自动重试'
                  : '未开启 · 开启后长按或双击音量键即可快速唤起对应功能',
              onTap: _openVolumeKeyPage,
            ),
          ),
          const SizedBox(height: 12),

          // --- 悬浮窗（配置全部下沉二级页，zcode: 2026-09；入口行显示停靠侧/自动隐藏摘要，
          // 与 overlay engine 共读同一组 prefs key；2026-09-17 挪到音量键下面）---
          SettingsCard(
            padding: EdgeInsets.zero,
            child: SettingsEntryRow(
              icon: Icons.picture_in_picture_alt_outlined,
              title: '悬浮窗',
              titleSuffix: _isProActive ? null : const SettingsProBadge(),
              subtitle:
                  '${_overlaySideLeft ? "左缘" : "右缘"}停靠 · '
                  '${_overlayAutoHideSeconds == OverlayConstants.autoHideNeverSeconds ? "常驻不隐藏" : "$_overlayAutoHideSeconds 秒后自动隐藏"}',
              onTap: _openOverlayPage,
            ),
          ),
          const SizedBox(height: 12),

          // zcode: 2026-09-17 挪到顶部入口区末尾 + 去重复外标题（卡内已有「电脑访问服务」）
          // --- 电脑访问区域（日记局域网 HTTP 服务）---
          // 服务本体在 web_server/diary_web_server.dart（固定端口 9527），
          // 生命周期由 DiaryServerController 编排：前台保活 + 冷启动自恢复；
          // 状态单一数据源在 controller（main.dart 自恢复与本页开关共用）
          _buildCard(
            child: WebServerSettingsCard(
              controller: DiaryServerController.instance,
            ),
          ),
          const SizedBox(height: 24),

          // --- 日记智能与交互区域 ---
          // 日记页行为设置集中一卡：物品/位置智能识别开关 + 卡片单击长按交互交换，
          // prefs key 与 DiaryTab._loadSmartSwitches 一致
          _buildSectionTitle("日记智能与交互"),
          _buildCard(
            child: Column(
              children: [
                buildSettingsSwitchTile(
                  context,
                  title: const Text('日记智能识别物品', style: TextStyle(fontSize: 13)),
                  subtitle: Text(
                    '识别"物品+位置"语句并显示转存按钮',
                    style: TextStyle(fontSize: 11, color: ext.textHint),
                  ),
                  value: _itemTransferEnabled,
                  onChanged: (v) async {
                    setState(() => _itemTransferEnabled = v);
                    final prefs = await SharedPreferences.getInstance();
                    await prefs.setBool('diary_item_transfer_enabled', v);
                  },
                ),
                buildSettingsSwitchTile(
                  context,
                  title: const Text(
                    '日记智能查询物品位置',
                    style: TextStyle(fontSize: 13),
                  ),
                  subtitle: Text(
                    '识别"XX在哪儿"语句并显示答案区',
                    style: TextStyle(fontSize: 11, color: ext.textHint),
                  ),
                  value: _queryAnswerEnabled,
                  onChanged: (v) async {
                    setState(() => _queryAnswerEnabled = v);
                    final prefs = await SharedPreferences.getInstance();
                    await prefs.setBool('diary_query_answer_enabled', v);
                  },
                ),
                const Divider(height: 1),
                buildSettingsSwitchTile(
                  context,
                  title: const Text('交换单击与长按', style: TextStyle(fontSize: 13)),
                  subtitle: Text(
                    '开启后：单击=编辑、长按=复制（默认：单击=复制、长按=编辑）。修改后需重启 App 生效',
                    style: TextStyle(fontSize: 11, color: ext.textHint),
                  ),
                  value: _swapTapLongPress,
                  onChanged: (v) async {
                    setState(() => _swapTapLongPress = v);
                    final prefs = await SharedPreferences.getInstance();
                    await prefs.setBool('diary_card_swap_tap_longpress', v);
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // 启动耗时诊断区域：暂时隐藏，恢复时把 _kShowStartupDiagnostics 改为 true
          if (_kShowStartupDiagnostics) ...[
            _buildSectionTitle("诊断"),
            _buildCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.bug_report_outlined,
                        color: ext.warningText,
                        size: 18,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        "启动耗时诊断",
                        style: TextStyle(
                          color: ext.textSecondary,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: _buildSecondaryBtn(
                      "导出启动日志",
                      Icons.upload_file,
                      _exportStartupLog,
                      busy: _isExportingStartupLog,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
          ],

          // --- 功能页面区域：主界面 Tab 显隐开关 ---
          // 读取方：main.dart main() 预读同一组 key，MainScaffold 按
          // visibleTabStack 装配 IndexedStack/底部导航；重启生效
          _buildSectionTitle("功能页面"),
          _buildCard(
            child: Column(
              children: [
                buildSettingsSwitchTile(
                  context,
                  title: const Text('隐藏存物品页', style: TextStyle(fontSize: 13)),
                  subtitle: Text(
                    '隐藏语音录入物品页，搬家模式一并隐藏。重启 App 后生效',
                    style: TextStyle(fontSize: 11, color: ext.textHint),
                  ),
                  value: _recordTabHidden,
                  onChanged: (v) async {
                    setState(() => _recordTabHidden = v);
                    await _saveTabVisibility(
                      recordHidden: v,
                      listHidden: _listTabHidden,
                    );
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('已保存，重启 App 后生效'),
                          duration: Duration(seconds: 2),
                        ),
                      );
                    }
                  },
                ),
                buildSettingsSwitchTile(
                  context,
                  title: const Text('隐藏查物品页', style: TextStyle(fontSize: 13)),
                  subtitle: Text(
                    '隐藏物品位置列表页，重启 App 后生效',
                    style: TextStyle(fontSize: 11, color: ext.textHint),
                  ),
                  value: _listTabHidden,
                  onChanged: (v) async {
                    setState(() => _listTabHidden = v);
                    await _saveTabVisibility(
                      recordHidden: _recordTabHidden,
                      listHidden: v,
                    );
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('已保存，重启 App 后生效'),
                          duration: Duration(seconds: 2),
                        ),
                      );
                    }
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // --- 外观区域（Phase 3 主题选择 + Phase 4 图标包入口）---
          _buildSectionTitle("外观"),
          _buildCard(
            child: Column(
              children: [
                _buildThemeEntry(), // Phase 3
                const Divider(height: 1),
                _buildIconPackEntry(), // Phase 4 新增
                const Divider(height: 1),
                _buildFontSizeEntry(), // 字号缩放
              ],
            ),
          ),
          const SizedBox(height: 24),

          // --- 支持作者区域 ---
          _buildSectionTitle("支持作者"),
          _buildCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.workspace_premium,
                      color: ext.goldAccent,
                      size: 18,
                    ),
                    SizedBox(width: 6),
                    Text(
                      "付费解锁 Pro 功能",
                      style: TextStyle(color: ext.textSecondary, fontSize: 13),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: _buildSecondaryBtn(
                    _isProActive ? "Pro 已解锁 ✓" : "付费解锁 Pro 功能",
                    _isProActive
                        ? Icons.lock_open_outlined
                        : Icons.lock_outline,
                    _showProUnlockDialog,
                    color: ext.goldAccent,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // --- 关于（更新日志 / 导出运行日志 / 开源许可下沉二级页，zcode: 2026-09）---
          const Divider(thickness: 1, height: 32),
          const SizedBox(height: 8),
          const SettingsSectionTitle("关于"),
          SettingsCard(
            padding: EdgeInsets.zero,
            child: SettingsEntryRow(
              icon: Icons.info_outline,
              title: '声物记',
              subtitle: _appVersion.isNotEmpty
                  ? 'v$_appVersion · 完全离线 · 无需联网'
                  : '完全离线 · 无需联网',
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const AboutPage()),
              ),
            ),
          ),
          const SizedBox(height: 40),
        ],
      ),
    );
  }


  // --- 音量键入口行无障碍状态点（绿=已开启 / 灰=未开启或检测失败；详情在二级页）---
  Widget _buildA11yStatusDot() {
    final ext = AppThemeExtension.of(context);
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        color: _isAccessibilityEnabled == true
            ? ext.positiveText
            : ext.textHint,
        shape: BoxShape.circle,
      ),
    );
  }

  // --- UI 构建辅助方法（zcode: 2026-09 起委托 lib/settings/settings_widgets.dart
  // 共享组件——主页与二级页视觉单一来源，避免下沉后两处样式漂移）---

  Widget _buildSectionTitle(String title) {
    return SettingsSectionTitle(title);
  }

  Widget _buildCard({required Widget child, EdgeInsetsGeometry? padding}) {
    return SettingsCard(child: child, padding: padding);
  }

  // ==================== Phase 3：主题选择 ====================

  /// 主题入口（仿 iOS 设置项风格，ListTile 风格）
  ///
  /// 显示当前主题名 + 调色板图标，点击调起 [_showThemePicker] BottomSheet。
  Widget _buildThemeEntry() {
    final ext = AppThemeExtension.of(context);
    final currentTheme = AppRoot.themeNotifier.value;
    return InkWell(
      onTap: _showThemePicker,
      borderRadius: BorderRadius.circular(15),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Icon(Icons.palette_outlined, color: ext.primary, size: 22),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '主题',
                    style: TextStyle(fontSize: 15, color: ext.textPrimary),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    currentTheme.name,
                    style: TextStyle(fontSize: 12, color: ext.textSecondary),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: ext.textHint, size: 22),
          ],
        ),
      ),
    );
  }

  /// 主题选择弹窗（BottomSheet，2×2 网格）
  ///
  /// 遍历 [AppThemes.all] 渲染所有预设主题，每个主题用自己的色槽预览，
  /// 让用户在切换前看到真实视觉效果。Pro 主题未解锁时点击触发 [ProUnlockDialog]。
  void _showThemePicker() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppThemeExtension.of(context).cardBackground,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 顶部拖拽指示条
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: AppThemeExtension.of(
                    sheetCtx,
                  ).textHint.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            // 标题
            Text(
              '选择主题',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: AppThemeExtension.of(sheetCtx).textPrimary,
              ),
            ),
            const SizedBox(height: 16),
            // 2×2 主题网格（顺序按 AppThemes.all 定义）
            GridView.count(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisCount: 2,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 1.1,
              children: AppThemes.all
                  .map((t) => _buildThemeCard(sheetCtx, t))
                  .toList(),
            ),
          ],
        ),
      ),
    );
  }

  /// 单个主题卡片（2×2 网格里的一格）
  ///
  /// 卡片背景/文字/边框全部使用 **该主题自己的色槽** [theme.extension]，
  /// 这样用户能直观看到切换后的视觉。当前选中主题加粗边框 + 右下角对勾。
  /// Pro 主题右上角显示金色 Pro 徽章。
  Widget _buildThemeCard(BuildContext sheetCtx, AppThemeDefinition theme) {
    final currentExt = AppThemeExtension.of(sheetCtx); // 弹窗当前主题色槽（用于非预览元素）
    final previewExt = theme.extension; // 被预览主题自己的色槽
    final isCurrent = AppRoot.themeNotifier.value.id == theme.id;

    return GestureDetector(
      onTap: () => _onThemeTap(theme),
      child: Container(
        padding: const EdgeInsets.all(12),
        // 拟物主题预览卡用自己的色槽画双向凸起阴影（不能走 neuRaisedDecoration——
        // 那取的是"当前主题"的阴影槽，在旧主题下打开选择器会拿占位色）
        decoration: previewExt.isNeumorphic
            ? BoxDecoration(
                color: previewExt.scaffoldBackground,
                borderRadius: BorderRadius.circular(14),
                boxShadow: [
                  BoxShadow(
                    color: previewExt.neuShadowDark,
                    offset: const Offset(3, 3),
                    blurRadius: 6,
                  ),
                  BoxShadow(
                    color: previewExt.neuShadowLight,
                    offset: const Offset(-3, -3),
                    blurRadius: 6,
                  ),
                ],
              )
            : BoxDecoration(
                color: previewExt.scaffoldBackground,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: isCurrent
                      ? previewExt.primary
                      : currentExt.textHint.withValues(alpha: 0.2),
                  width: isCurrent ? 2 : 1,
                ),
              ),
        child: Stack(
          children: [
            // 内容：主题名（顶）+ 4 色点（底）
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  theme.name,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: previewExt.textPrimary,
                  ),
                ),
                const Spacer(),
                Row(
                  children: [
                    _colorDot(previewExt.primary),
                    const SizedBox(width: 6),
                    _colorDot(previewExt.positiveAccent),
                    const SizedBox(width: 6),
                    _colorDot(previewExt.warningAccent),
                    const SizedBox(width: 6),
                    _colorDot(previewExt.cardBackground, withBorder: true),
                  ],
                ),
              ],
            ),
            // Pro 徽章（右上角金色，仅 Pro 主题显示）
            if (theme.isPro)
              Positioned(
                top: 0,
                right: 0,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: previewExt.goldAccent,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Text(
                    'Pro',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            // 选中对勾（右下角，仅当前主题显示）
            if (isCurrent)
              Positioned(
                bottom: 0,
                right: 0,
                child: Icon(
                  Icons.check_circle,
                  color: previewExt.primary,
                  size: 22,
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 色点辅助组件（主题卡片底部的 4 个预览圆点）
  ///
  /// [withBorder] 用于浅色色点（如 cardBackground=白色），加灰色细边避免在白底卡片上不可见。
  Widget _colorDot(Color color, {bool withBorder = false}) {
    return Container(
      width: 18,
      height: 18,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: withBorder
            ? Border.all(color: Colors.grey.shade400, width: 0.5)
            : null,
      ),
    );
  }

  /// 主题点击逻辑：Pro 门禁 + 写 prefs + 切 notifier
  ///
  /// 流程：
  /// 1. Pro 门禁：Pro 主题不可用 → 弹 ProUnlockDialog（试用/输码成功返回 true
  ///    继续应用主题；弹窗盖在主题选择 sheet 之上，不再强关 sheet，未解锁时
  ///    用户可留在选择器改选免费主题）
  /// 2. 正常切换：写 SharedPreferences('selected_theme') → 更新 [AppRoot.themeNotifier]
  ///    → 关闭弹窗 → SnackBar 提示
  Future<void> _onThemeTap(AppThemeDefinition theme) async {
    // Pro 门禁：不可用时弹解锁引导（内部含 7 天试用 / 授权码输入出口）
    if (theme.isPro) {
      final active = await ProGate.tryAccess(context);
      if (!active) return;
    }

    // 写入 prefs + 更新 notifier（触发整树重建）
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('selected_theme', theme.id);
    AppRoot.themeNotifier.value = theme;

    if (mounted) {
      Navigator.of(context).pop(); // 关闭主题弹窗
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已切换到「${theme.name}」主题'),
          backgroundColor: theme.extension.primary,
        ),
      );
    }
  }

  // ==================== Phase 4：图标包选择 ====================

  /// 图标包入口（ListTile 风格，仿 _buildThemeEntry）
  Widget _buildIconPackEntry() {
    final ext = AppThemeExtension.of(context);
    final currentPack =
        IconPacks.findById(_currentIconPackId) ?? IconPacks.defaultPack;
    return InkWell(
      onTap: _showIconPackPicker,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Icon(Icons.app_shortcut_outlined, color: ext.primary, size: 22),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '图标',
                    style: TextStyle(fontSize: 15, color: ext.textPrimary),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    currentPack.name,
                    style: TextStyle(fontSize: 12, color: ext.textSecondary),
                  ),
                ],
              ),
            ),
            // 圆形预览：背景色 + 前景色 mic 图标
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: Color(currentPack.backgroundColor),
                shape: BoxShape.circle,
                // minimal 浅色背景加细边框，避免在白底卡片上不可见
                border: currentPack.id == 'minimal'
                    ? Border.all(
                        color: ext.textHint.withValues(alpha: 0.3),
                        width: 0.5,
                      )
                    : null,
              ),
              child: Image.asset(
                'assets/icon/icon2_fg_white.png',
                width: 14,
                height: 14,
                color: Color(currentPack.foregroundColor),
                colorBlendMode: BlendMode.srcIn,
              ),
            ),
            const SizedBox(width: 8),
            Icon(Icons.chevron_right, color: ext.textHint, size: 22),
          ],
        ),
      ),
    );
  }

  /// 字号缩放入口（两行：标题行 + 档位 chips 行）
  ///
  /// 曾试过标题与 chips 挤同行的单行方案：App 内「特大」档 1.3 倍整树缩放
  /// （再叠加系统字体放大）会把行宽撑爆，「特大」chip 溢出卡片边——真机两轮
  /// 截图确诊，2026-09 用户拍板换行展示。相对最初版本仍保留瘦身：chips 无
  /// 重复 format_size 图标、无选中勾（showCheckmark）、档位名「标准→中」、
  /// labelPadding 收窄 8；选中态由 chip 实心底色表达，不再需要「当前档位」副标题。
  Widget _buildFontSizeEntry() {
    final ext = AppThemeExtension.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.format_size, color: ext.primary, size: 22),
              const SizedBox(width: 14),
              Text('字号', style: TextStyle(fontSize: 15, color: ext.textPrimary)),
            ],
          ),
          const SizedBox(height: 10),
          _buildFontSizeSelector(),
        ],
      ),
    );
  }

  /// 字号缩放档位选择器（无图标 chips 行；仿 _buildAutoHideSelector 配色。
  /// 瘦身三件套与单行失败的教训详见 _buildFontSizeEntry 注释）
  Widget _buildFontSizeSelector() {
    final ext = AppThemeExtension.of(context);
    final options = [(0.85, '小'), (1.0, '中'), (1.15, '大'), (1.3, '特大')];
    return Wrap(
      spacing: 8,
      runSpacing: 6,
      children: options.map((opt) {
        final (scale, label) = opt;
        final selected = _fontScale == scale;
        // 拟物主题：选中=凹陷+品牌青字、未选=凸起（预览拍板样式，2026-09-18
        // 真机反馈字号 chip 没有 M3 ChoiceChip 之外的拟物形态）；其余主题保持 ChoiceChip
        if (ext.isNeumorphic) {
          // 选中=NeuInset 凹陷（双轴渐变晕影，与开关/输入框同款）+品牌青字、
          // 未选=凸起；凹凸跨结构无法隐式插值，即时切换（2026-09-19 统一）
          final labelStyle = TextStyle(
            fontSize: 13,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? ext.primaryDark : ext.textPrimary,
          );
          return GestureDetector(
            onTap: () => _saveFontScale(scale),
            child: selected
                ? NeuInset(
                    radius: 999,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    child: Text(label, style: labelStyle),
                  )
                : Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: neuRaisedDecoration(context, radius: 999),
                    child: Text(label, style: labelStyle),
                  ),
          );
        }
        return ChoiceChip(
          label: Text(label),
          labelPadding: const EdgeInsets.symmetric(horizontal: 8),
          showCheckmark: false,
          selected: selected,
          selectedColor: ext.primary,
          labelStyle: TextStyle(
            color: selected ? ext.textOnPrimary : ext.textPrimary,
            fontSize: 13,
          ),
          onSelected: (_) => _saveFontScale(scale),
        );
      }).toList(),
    );
  }

  /// 图标包选择弹窗（BottomSheet，2×2 网格，仿 _showThemePicker）
  void _showIconPackPicker() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppThemeExtension.of(context).cardBackground,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 拖拽指示条
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: AppThemeExtension.of(
                    sheetCtx,
                  ).textHint.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            // 标题
            Text(
              '选择图标',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: AppThemeExtension.of(sheetCtx).textPrimary,
              ),
            ),
            const SizedBox(height: 4),
            // 切换提示（关键：告知用户应用会短暂重启）
            Text(
              '切换后应用会短暂重启',
              style: TextStyle(
                fontSize: 12,
                color: AppThemeExtension.of(sheetCtx).textSecondary,
              ),
            ),
            const SizedBox(height: 16),
            // 2×2 图标网格
            GridView.count(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisCount: 2,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 1.1,
              children: IconPacks.all
                  .map((p) => _buildIconPackCard(sheetCtx, p))
                  .toList(),
            ),
          ],
        ),
      ),
    );
  }

  /// 单个图标包卡片（2×2 网格里的一格，仿 _buildThemeCard）
  Widget _buildIconPackCard(BuildContext sheetCtx, IconPack pack) {
    final currentExt = AppThemeExtension.of(sheetCtx);
    final isCurrent = _currentIconPackId == pack.id;

    return GestureDetector(
      onTap: () => _onIconPackTap(pack),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: currentExt.scaffoldBackground,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isCurrent
                ? currentExt.primary
                : currentExt.textHint.withValues(alpha: 0.2),
            width: isCurrent ? 2 : 1,
          ),
        ),
        child: Stack(
          children: [
            // 内容：图标包名（顶）+ 圆形预览（底）
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  pack.name,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: currentExt.textPrimary,
                  ),
                ),
                const Spacer(),
                Center(
                  child: Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: Color(pack.backgroundColor),
                      shape: BoxShape.circle,
                      // minimal 浅色背景加细边框，避免在白底卡片上不可见
                      border: pack.id == 'minimal'
                          ? Border.all(
                              color: currentExt.textHint.withValues(alpha: 0.3),
                              width: 0.5,
                            )
                          : null,
                    ),
                    child: Image.asset(
                      'assets/icon/icon2_fg_white.png',
                      width: 26,
                      height: 26,
                      color: Color(pack.foregroundColor),
                      colorBlendMode: BlendMode.srcIn,
                    ),
                  ),
                ),
              ],
            ),
            // Pro 徽章（右上角金色，仅 Pro 图标包显示）
            if (pack.isPro)
              Positioned(
                top: 0,
                right: 0,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: currentExt.goldAccent,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Text(
                    'Pro',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            // 选中对勾（右下角，仅当前图标包显示）
            if (isCurrent)
              Positioned(
                bottom: 0,
                right: 0,
                child: Icon(
                  Icons.check_circle,
                  color: currentExt.primary,
                  size: 22,
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 图标包点击逻辑：Pro 门禁 + 调原生切换 + 延迟关闭弹窗
  ///
  /// 流程：
  /// 1. 当前已选中的，点一下不做事
  /// 2. Pro 门禁：Pro 图标包不可用 → 弹 ProUnlockDialog（试用/输码成功返回 true
  ///    继续切换；弹窗盖在选择弹窗之上，不强关）
  /// 3. 正常切换：写 prefs('selected_icon_pack') → 调 IconPackSwitcher.switchTo
  ///    → 显示"正在切换..." → 延迟 3 秒关闭弹窗（进程可能已被系统杀死）
  Future<void> _onIconPackTap(IconPack pack) async {
    // 当前已选中，不切换
    if (_currentIconPackId == pack.id) {
      if (mounted) Navigator.of(context).pop();
      return;
    }

    // Pro 门禁：不可用时弹解锁引导（内部含 7 天试用 / 授权码输入出口）
    if (pack.isPro) {
      final active = await ProGate.tryAccess(context);
      if (!active) return;
    }

    // 写 prefs（仅用于 UI 显示当前选中，真正的状态源是系统 ComponentEnabledSetting）
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('selected_icon_pack', pack.id);

    // 调原生层切换
    final success = await IconPackSwitcher.switchTo(pack.id);

    if (!mounted) return; // 进程可能已被系统杀死

    if (success) {
      setState(() => _currentIconPackId = pack.id);

      // 显示"正在切换" SnackBar
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              ),
              const SizedBox(width: 12),
              Text('正在切换到「${pack.name}」图标...'),
            ],
          ),
          duration: const Duration(seconds: 3),
        ),
      );

      // 延迟关闭弹窗（进程可能在此之前已被系统杀死）
      await Future.delayed(const Duration(seconds: 3));
      if (mounted) {
        Navigator.of(context).pop();
      }
    } else {
      // 切换失败
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('图标切换失败，请重试'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Widget _buildSecondaryBtn(
    String label,
    IconData icon,
    VoidCallback? onPressed, {
    Color? color,
    bool busy = false,
  }) {
    final ext = AppThemeExtension.of(context);
    // 拟物主题：同色凸起 + 彩色文字 + 按住凹陷（替代描边按钮，2026-09-18
    // 真机反馈导入/导出备份按钮没有拟物突出效果）；其余主题保持描边样式
    if (ext.isNeumorphic) {
      final fg = color ?? ext.primary;
      return NeuPressable(
        onTap: busy ? null : onPressed,
        radius: 12,
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (busy)
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              Icon(icon, size: 18, color: fg),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: fg,
              ),
            ),
          ],
        ),
      );
    }
    return OutlinedButton.icon(
      onPressed: busy ? null : onPressed,
      icon: busy
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(icon, size: 18),
      label: Text(
        label,
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
      style: OutlinedButton.styleFrom(
        foregroundColor: color ?? ext.primary,
        side: BorderSide(color: color ?? ext.primary, width: 1),
        padding: const EdgeInsets.symmetric(vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  /// 导出启动耗时诊断日志（小体量，同样加 loading 态兜底分享面板延迟）
  Future<void> _exportStartupLog() async {
    if (_isExportingStartupLog) return;
    setState(() => _isExportingStartupLog = true);
    try {
      await StartupLogger.exportAndShare();
    } catch (e) {
      log('❌ 导出启动日志失败: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('导出启动日志失败: $e')));
      }
    } finally {
      if (mounted) setState(() => _isExportingStartupLog = false);
    }
  }

  // ========== 缓存清理相关方法 ==========

  /// 计算目录大小
  int _getDirectorySize(Directory dir) {
    int size = 0;
    try {
      if (dir.existsSync()) {
        dir.listSync(recursive: true).forEach((entity) {
          if (entity is File) {
            size += entity.lengthSync();
          }
        });
      }
    } catch (e) {
      log("⚠️ 计算目录大小失败: $e");
    }
    return size;
  }

  /// 格式化字节大小
  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024)
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  /// 清理应用缓存（临时目录）
  Future<void> _clearAppCache() async {
    try {
      int cacheSize = 0;

      // 清理临时目录缓存
      final tempDir = await getTemporaryDirectory();
      if (tempDir.existsSync()) {
        // 计算缓存大小
        cacheSize += _getDirectorySize(tempDir);

        await tempDir.delete(recursive: true);
        await tempDir.create(recursive: true); // 重新创建空目录
        log("✅ 已清理临时目录缓存: ${tempDir.path}");
      }

      log("🗑️ 缓存清理完成，释放空间: ${_formatBytes(cacheSize)}");
    } catch (e) {
      log("❌ 缓存清理失败: $e");
    }
  }
}

// ============================================================
// 备份 ZIP worker（性能审查 Top2：建档/压缩/解压/音频落盘全部在 isolate 执行）
//
// ⚠️ Isolate.run 的闭包必须经下面的顶层 trampoline（_runBuildBackupZip /
//    _runExtractBackupZip）创建，不要在 State 的 async 方法作用域里直接写
//    `Isolate.run(() => worker(...))`：State 方法作用域的 enclosing context
//    会被闭包连带捕获（含 this/Element——State 的 context 挂着十几个
//    InheritedElement 依赖），SendPort 校验直接抛 "object is unsendable"
//    （2026-09-06 导入备份实测，探针日志定位：State 里创建的闭包 ❌ 不可发送 /
//    它引用的两个 String 参数、result、Directory 均 ✅ 可发送）。
//    顶层函数作用域没有 this，闭包捕获域只剩 String 参数，结构上杜绝复发。
// ============================================================

/// 主 isolate 调用的导出 trampoline：Isolate.run 闭包在顶层作用域创建，
/// 参数只收 String/Set 等可跨 isolate 传输的值。
Future<(Uint8List, int)> _runBuildBackupZip({
  required String itemsCsv,
  required String diaryCsv,
  required String readme,
  required String hotwordsContent,
  required String correctionsContent,
  required String audioDirPath,
  required Set<String> validAudioNames,
}) {
  return Isolate.run(
    () => _buildBackupZip(
      itemsCsv: itemsCsv,
      diaryCsv: diaryCsv,
      readme: readme,
      hotwordsContent: hotwordsContent,
      correctionsContent: correctionsContent,
      audioDirPath: audioDirPath,
      validAudioNames: validAudioNames,
    ),
  );
}

/// 主 isolate 调用的导入 trampoline：同上，闭包捕获域只剩两个 String。
Future<
  ({
    String itemsCsv,
    String diaryCsv,
    String? hotwords,
    String? corrections,
    int restoredAudioCount,
  })
>
_runExtractBackupZip(String zipPath, String audioDirPath) {
  return Isolate.run(
    () => _extractBackupZip(zipPath: zipPath, audioDirPath: audioDirPath),
  );
}

/// 在 worker isolate 内构建全量备份 ZIP：
/// 读音频文件字节 → 建档 → 压缩。返回 (zip 字节, 孤儿音频文件数)。
/// 孤儿文件是否删除由主 isolate 在导出成功后决定，这里只负责统计。
(Uint8List, int) _buildBackupZip({
  required String itemsCsv,
  required String diaryCsv,
  required String readme,
  required String hotwordsContent,
  required String correctionsContent,
  required String audioDirPath,
  required Set<String> validAudioNames,
}) {
  final archive = Archive();

  archive.addFile(
    ArchiveFile('items.csv', itemsCsv.length, utf8.encode(itemsCsv)),
  );
  archive.addFile(
    ArchiveFile('diary.csv', diaryCsv.length, utf8.encode(diaryCsv)),
  );
  archive.addFile(
    ArchiveFile('README.txt', readme.length, utf8.encode(readme)),
  );
  archive.addFile(
    ArchiveFile(
      'user_hotwords.txt',
      hotwordsContent.length,
      utf8.encode(hotwordsContent),
    ),
  );
  // 错误-修正学习表（v1.2.0 起随备份走；老版本备份无此文件，导入侧可空兼容）
  archive.addFile(
    ArchiveFile(
      'correction_pairs.txt',
      correctionsContent.length,
      utf8.encode(correctionsContent),
    ),
  );

  // 只导出数据库中存在的录音，其余计为孤儿文件
  int orphanCount = 0;
  final audioDir = Directory(audioDirPath);
  if (audioDir.existsSync()) {
    for (final audioFile in audioDir.listSync().whereType<File>()) {
      final fileName = p.basename(audioFile.path);
      if (validAudioNames.contains(fileName)) {
        final bytes = audioFile.readAsBytesSync();
        archive.addFile(ArchiveFile('audio/$fileName', bytes.length, bytes));
      } else {
        orphanCount++;
      }
    }
  }

  final zipBytes = ZipEncoder().encode(archive);
  if (zipBytes == null) {
    throw Exception('ZIP 编码失败');
  }
  return (
    zipBytes is Uint8List ? zipBytes : Uint8List.fromList(zipBytes),
    orphanCount,
  );
}

/// 在 worker isolate 内解压全量备份：
/// 提取 items/diary CSV 与热词/修正对内容（字符串回传主 isolate 解析入库），
/// 音频文件增量落盘（只写 audioDirPath 下不存在的文件，语义与原版一致）。
/// 缺必要 CSV 抛异常，由主 isolate catch 后弹错误框。
({
  String itemsCsv,
  String diaryCsv,
  String? hotwords,
  String? corrections,
  int restoredAudioCount,
})
_extractBackupZip({required String zipPath, required String audioDirPath}) {
  final zipBytes = File(zipPath).readAsBytesSync();
  final archive = ZipDecoder().decodeBytes(zipBytes);

  String? itemsCsv;
  String? diaryCsv;
  String? hotwords;
  String? corrections;
  int restoredAudioCount = 0;

  final audioDir = Directory(audioDirPath);

  for (final file in archive) {
    if (file.name == 'items.csv') {
      itemsCsv = utf8.decode(file.content as List<int>);
    } else if (file.name == 'diary.csv') {
      diaryCsv = utf8.decode(file.content as List<int>);
    } else if (file.name == 'user_hotwords.txt') {
      hotwords = utf8.decode(file.content as List<int>);
    } else if (file.name == 'correction_pairs.txt') {
      corrections = utf8.decode(file.content as List<int>);
    } else if (file.name.startsWith('audio/')) {
      // 不清空现有音频文件，增量合并：只恢复不存在的
      final fileName = p.basename(file.name);
      final target = File(p.join(audioDirPath, fileName));
      if (!target.existsSync()) {
        if (!audioDir.existsSync()) {
          audioDir.createSync(recursive: true);
        }
        target.writeAsBytesSync(file.content as List<int>);
        restoredAudioCount++;
      }
    }
  }

  if (itemsCsv == null || diaryCsv == null) {
    throw Exception("备份文件格式错误：缺少必要的CSV文件");
  }

  return (
    itemsCsv: itemsCsv,
    diaryCsv: diaryCsv,
    hotwords: hotwords,
    corrections: corrections,
    restoredAudioCount: restoredAudioCount,
  );
}
