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
import '../theme/app_font.dart'; // 外观入口行摘要：字体档位解析
import '../theme/app_theme.dart'; // 外观入口行摘要：深色模式档位解析
import '../main.dart'; // AppRoot.themeNotifier（外观入口行摘要读当前主题名）
import '../utils/pro_gate.dart'; // Pro 门禁（永久解锁 + 7 天试用）
import '../utils/note_lock_settings.dart'; // 日记智能入口行摘要：笔记锁定开关
import '../utils/tab_visibility.dart'; // 眼不见为净入口行摘要：两个隐藏开关 key（main.dart main() 预读同一组 key，重启生效）
import '../overlay/overlay_constants.dart'; // OverlayConstants.autoHide*（自动隐藏档位唯一真值，与 overlay engine 共用；主页悬浮窗入口行摘要读）
import '../utils/backup_csv.dart'; // 全量备份 CSV 编解码（导出/导入共用：生成、解析、时间归一化、去重键）
import '../utils/diary_tag.dart'; // 4 槽位标签外观配置（随全量备份 tag_config.json 走）
import '../utils/correction_learner.dart'; // 错误-修正学习表（编解码 + 备份内容）
import '../utils/search_command_detector.dart'; // 语音搜索触发词（全量备份导出/导入 + 默认值唯一真值）
import '../web_server/diary_server_controller.dart'; // 电脑访问服务开关编排
import '../web_server/web_server_settings_card.dart'; // 电脑访问服务设置卡片
// zcode: 2026-09 设置页下沉——热词+修正学习/AI 应用/悬浮窗/音量键/关于五组
// 配置移入 lib/settings/ 二级页，主页只留入口行 + 状态摘要（返回后刷新）
import 'settings/about_page.dart';
import 'settings/accessibility_check.dart';
import 'settings/ai_app_page.dart';
import 'settings/appearance_settings_page.dart'; // 外观（主题/深色模式/图标/字号/字体/标签外观）
import 'settings/cloud_sync_page.dart';
import 'settings/diary_interaction_settings_page.dart'; // 日记智能与交互（锁定/识别/查询/点击交换）
import 'settings/feature_guide_page.dart'; // 全量功能说明（常驻入口，含升级用户）
import 'settings/overlay_settings_page.dart';
import 'settings/recognition_correction_page.dart';
import 'settings/search_settings_page.dart'; // 大爆炸搜索二级页
import 'settings/visibility_settings_page.dart'; // 眼不见为净（物品页隐藏 + 后台隐藏）
import 'utils/big_bang_search.dart'; // 搜索引擎/浏览器 prefs key 与显示名唯一真值
import 'settings/settings_widgets.dart';
import 'widgets/neu_widgets.dart';
import 'settings/volume_key_settings_page.dart';
import 'sync/cloud_sync_service.dart'; // 云端同步入口行摘要（CloudSyncConfig.lastSyncInfo）
import 'utils/cloud_sync_data_version.dart'; // 待同步检测：本地数据版本 vs 已同步快照

class SettingsTab extends StatefulWidget {
  final TextProcessor processor;
  final DbHelper dbHelper;
  const SettingsTab({
    super.key,
    required this.processor,
    required this.dbHelper,
  });

  @override
  State<SettingsTab> createState() => SettingsTabState();
}

/// State 类公开：main.dart 持 GlobalKey 在切 tab 时调 refreshCloudSyncSummary
/// （IndexedStack 保活，initState 不会重跑，切回设置页需主动刷新入口行摘要）
class SettingsTabState extends State<SettingsTab> with WidgetsBindingObserver {
  // zcode: 2026-09 下沉后主页保留的 state 缩减为「入口行摘要」所需最小集；
  // 各配置项的完整状态在 lib/settings/ 对应二级页内自管（prefs key 不变）
  String _modelPathInfo = "内置模型就绪";
  // 「AI 应用分享」入口行摘要：当前选中的应用（内置或二级页 + 号添加的自定义）；
  // 异步解析（resolveAppById），加载完成前显示默认项
  AIApp _selectedAIApp = AIApp.defaultApp;
  // 「大爆炸搜索」入口行摘要：当前搜索引擎 · 浏览器（二级页写 prefs，本页只读）
  String _searchSummary = '百度 · 系统默认';
  // 无障碍服务是否已开启（null=检测失败：与「未开启」区分，UI 显式提示而非误导用户去开无障碍——服务可能明明开着）
  bool? _isAccessibilityEnabled = false;
  int _hotwordCount = 0; // 「识别与修正」入口行摘要：热词条数
  // 「识别与修正」入口行摘要：错误-修正学习表条数（从二级页返回后刷新）
  int _correctionPairCount = 0;
  // 「云端同步」入口行摘要：未配置提示或上次同步时间+结果
  String? _cloudSyncSubtitle;
  String _appVersion = ''; // 版本号，来自 package_info_plus（关于入口行）
  bool _isExportingStartupLog = false; // 启动日志导出中（同上）
  bool _isProActive = false; // Pro 是否可用（永久解锁或试用中），统一走 ProGate 判定
  // 入口行摘要（配置本体已下沉二级页，本页只读 prefs/全局 notifier 生成摘要）
  String _appearanceSummary = '默认青 · 跟随系统 · 中字号';
  String _visibilitySummary = '存物品页显示中 · 查物品页显示中 · 后台隐藏关';
  String _diaryInteractionSummary = '锁定开 · 识别开 · 查询开';
  int _overlayAutoHideSeconds = OverlayConstants
      .autoHideDefaultSeconds; // 悬浮窗入口行摘要：收起后自动隐藏秒数（二级页写，overlay engine 读同一 key）
  bool _overlaySideLeft =
      false; // 悬浮窗入口行摘要：停靠侧（OverlayConstants.overlaySideLeftPrefKey：false=右缘/true=左缘）

  /// 启动耗时诊断 UI 开关（暂时隐藏，需要时改为 true）
  static const bool _kShowStartupDiagnostics = false;

  @override
  void initState() {
    super.initState();
    _loadHotwordCount();
    _loadModelStatus();
    _loadAIAppPreference(); // 加载 AI 应用偏好（入口行摘要）
    _loadSearchSummary(); // 加载大爆炸搜索入口行摘要（引擎 · 浏览器）
    _loadAppVersion(); // 加载应用版本号（关于入口行）
    _loadProUnlockStatus(); // 加载 Pro 解锁状态
    _loadAppearanceSummary(); // 外观入口行摘要（主题/深色/字号/字体）
    _loadVisibilitySummary(); // 眼不见为净入口行摘要（两页隐藏 + 后台隐藏）
    _loadDiaryInteractionSummary(); // 日记智能与交互入口行摘要
    _loadOverlaySummary(); // 加载悬浮窗入口行摘要（停靠侧 + 自动隐藏）
    _loadCorrectionPairCount(); // 加载错误-修正学习表条数（入口行摘要）
    _loadCloudSyncSummary(); // 加载云端同步入口行摘要（是否配置 + 上次同步）
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
      // 数据可能在后台/其他入口变更（悬浮窗速记等），云端同步待同步态一并重算
      _loadCloudSyncSummary();
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

  /// 加载外观入口行摘要（主题名取全局 notifier，深色/字号/字体读 prefs；
  /// 完整配置与切换逻辑已下沉 lib/settings/appearance_settings_page.dart）
  void _loadAppearanceSummary() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    final themeName = AppRoot.themeNotifier.value.name;
    final darkLabel = switch (parseThemeMode(
      prefs.getString(kThemeModePrefKey),
    )) {
      ThemeMode.light => '浅色',
      ThemeMode.dark => '深色',
      ThemeMode.system => '跟随系统',
    };
    final scale = prefs.getDouble('font_size_scale') ?? 1.0;
    final scaleLabel = switch (scale) {
      0.85 => '小',
      1.15 => '大',
      1.3 => '特大',
      _ => '中',
    };
    final fontLabel =
        parseAppFontChoice(prefs.getString(kAppFontPrefKey)) ==
            AppFontChoice.system
        ? ' · 系统字体'
        : '';
    setState(
      () => _appearanceSummary =
          '$themeName · $darkLabel · $scaleLabel字号$fontLabel',
    );
  }

  /// 加载眼不见为净入口行摘要（两个 Tab 隐藏开关 + 后台隐藏，均以 prefs 为准）
  void _loadVisibilitySummary() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    final recordHidden = prefs.getBool(prefKeyRecordTabHidden) ?? false;
    final listHidden = prefs.getBool(prefKeyListTabHidden) ?? false;
    final recentsHidden = prefs.getBool('exclude_from_recents') ?? false;
    setState(
      () => _visibilitySummary =
          '存物品页${recordHidden ? '已隐藏' : '显示中'} · '
          '查物品页${listHidden ? '已隐藏' : '显示中'} · '
          '后台隐藏${recentsHidden ? '开' : '关'}',
    );
  }

  /// 加载日记智能与交互入口行摘要（锁定/识别/查询/点击交换）
  void _loadDiaryInteractionSummary() async {
    final prefs = await SharedPreferences.getInstance();
    final noteLock = await NoteLockSettings.isEnabled();
    if (!mounted) return;
    final itemTransfer = prefs.getBool('diary_item_transfer_enabled') ?? true;
    final queryAnswer = prefs.getBool('diary_query_answer_enabled') ?? true;
    final swapTap = prefs.getBool('diary_card_swap_tap_longpress') ?? false;
    setState(
      () => _diaryInteractionSummary =
          '锁定${noteLock ? '开' : '关'} · 识别${itemTransfer ? '开' : '关'} · '
          '查询${queryAnswer ? '开' : '关'}${swapTap ? ' · 点击已交换' : ''}',
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
    // 自定义应用（+ 号添加）也要能解析出来——findById 只查内置列表
    final appId = prefs.getString('selected_ai_app') ?? 'chatgpt';
    final app = await AIApp.resolveAppById(appId);
    if (mounted) {
      setState(() => _selectedAIApp = app ?? AIApp.defaultApp);
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

  // --- 云端同步（WebDAV 手动同步：日记/物品/热词/修正对，见 sync/ 模块）---
  Future<void> _openCloudSyncPage() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CloudSyncPage(
          processor: widget.processor,
          dbHelper: widget.dbHelper,
        ),
      ),
    );
    _loadCloudSyncSummary(); // 可能在二级页刚同步过或改了配置
  }

  /// main 切到本 tab 时调用：数据可能在其他 tab 变更（记日记/存物品/
  /// 悬浮窗速记），云端同步入口行的待同步态需要重算
  void refreshCloudSyncSummary() => _loadCloudSyncSummary();

  /// 加载「云端同步」入口行副标题：本地数据版本 > 已同步快照时优先显示
  /// 「有新数据待同步」（P1 无自动同步，只显示上次结果会让用户误以为一致）
  Future<void> _loadCloudSyncSummary() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload(); // 悬浮窗 engine 可能刚 bump，防读到旧值
    final configured =
        (prefs.getString(CloudSyncConfig.kServerUrl) ?? '').isNotEmpty;
    final info = await CloudSyncConfig.lastSyncInfo();
    final hasPending = CloudSyncDataVersion.hasPending(
      hasLastSync: info != null,
      syncedVersion: prefs.getInt(CloudSyncDataVersion.syncedVersionKey),
      currentVersion: CloudSyncDataVersion.current(prefs),
    );
    if (!mounted) return;
    setState(() {
      _cloudSyncSubtitle = CloudSyncConfig.buildEntrySubtitle(
        configured: configured,
        hasPending: hasPending,
        lastSync: info,
      );
    });
  }

  Future<void> _openAIAppPage() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const AIAppPage()),
    );
    _loadAIAppPreference(); // 摘要跟随二级页的选择
  }

  /// 加载「大爆炸搜索」入口行副标题：搜索引擎显示名 · 浏览器名（空=系统默认）
  Future<void> _loadSearchSummary() async {
    final prefs = await SharedPreferences.getInstance();
    final engineName =
        searchEngines[parseSearchEngine(prefs.getString(kSearchEngineKey))]!
            .label;
    final browserPackage = prefs.getString(kSearchBrowserPackageKey) ?? '';
    final browserName = prefs.getString(kSearchBrowserNameKey) ?? '';
    final browserLabel = (browserPackage.isEmpty || browserName.isEmpty)
        ? '系统默认'
        : browserName;
    if (!mounted) return;
    setState(() => _searchSummary = '$engineName · $browserLabel');
  }

  Future<void> _openSearchSettingsPage() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const SearchSettingsPage()),
    );
    _loadSearchSummary(); // 摘要跟随二级页的选择
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

  Future<void> _openVisibilityPage() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const VisibilitySettingsPage()),
    );
    _loadVisibilitySummary(); // 摘要跟随二级页的开关
  }

  Future<void> _openDiaryInteractionPage() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const DiaryInteractionSettingsPage()),
    );
    _loadDiaryInteractionSummary(); // 摘要跟随二级页的开关
  }

  Future<void> _openAppearancePage() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const AppearanceSettingsPage()),
    );
    _loadAppearanceSummary(); // 主题可能刚切换，摘要重读 notifier/prefs
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
          _appVersion = '1.6.0'; // 来自 pubspec.yaml version: 1.6.0+27
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
      final itemsCsv = generateItemsCsv(items);
      final diaryCsv = generateDiaryCsv(diaries);
      final readme = _generateReadme();
      final hotwordsContent = await widget.processor.getLocalContent();
      // 错误-修正学习表：编码成「错误 = 修正」文本随备份走
      final correctionsContent = CorrectionLearner.encodeCorrections(
        await widget.dbHelper.getAllCorrectionPairs(),
      );
      // 语音搜索触发词配置（规范化后换行分隔，与 prefs 同格式；
      // 导出的是"当前实际生效"的列表，未配置时即默认白名单）
      final prefs = await SharedPreferences.getInstance();
      final voiceSearchTriggersContent = SearchCommandDetector.parseTriggers(
        prefs.getString(kVoiceSearchTriggersKey),
      ).join('\n');
      // 4 槽位标签外观（图标/颜色）：主 App 内存里的 notifier 即当前真值
      final tagConfigContent = DiaryTagStyles.config.encode();

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
        voiceSearchTriggersContent: voiceSearchTriggersContent,
        tagConfigContent: tagConfigContent,
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
- voice_search_triggers.txt: 悬浮窗语音搜索触发词（每行一个）
- tag_config.json: 4 个标注槽位的图标与颜色配置

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
      final items = parseItemsCsv(extracted.itemsCsv);

      // 3. 解析diary.csv
      final diaries = parseDiaryCsv(extracted.diaryCsv);
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

      // 构建日记索引：自然键 content+创建时间（秒级对齐，见 backup_csv.diaryDedupeKey）。
      // 曾逐字比对 created_at，导出侧被格式化改写 → 原封导入整包判新（2026-09 修复）
      final diaryIndex = <String>{};
      for (var diary in existingDiaries) {
        diaryIndex.add(
          diaryDedupeKey(
            diary['content']?.toString() ?? '',
            diary['created_at']?.toString() ?? '',
          ),
        );
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
        final key = diaryDedupeKey(
          diary['content']?.toString() ?? '',
          diary['created_at']?.toString() ?? '',
        );
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

      // 8.6 恢复语音搜索触发词（如备份中包含）——同样必须在 early return 之前。
      // 语义是"覆盖"：按备份里的配置恢复（备份里的内容已规范化）；老版本备份
      // 没有此文件、或文件内容为空时保留本机现有配置不动——不回落默认，避免
      // 误清用户已配置的触发词
      bool voiceSearchTriggersRestored = false;
      final triggersContent = extracted.voiceSearchTriggers;
      if (triggersContent != null) {
        final triggers = SearchCommandDetector.normalize(triggersContent);
        if (triggers.isNotEmpty) {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(kVoiceSearchTriggersKey, triggers.join('\n'));
          voiceSearchTriggersRestored = true;
          log('[备份导入] 恢复语音搜索触发词: ${triggers.join('/')}');
        } else {
          log('[备份导入] voice_search_triggers.txt 内容为空，跳过（保留本机配置）');
        }
      } else {
        log('[备份导入] 备份中无 voice_search_triggers.txt，跳过（老版本备份）');
      }

      // 8.7 恢复 4 槽位标签外观（如备份中包含）——同样必须在 early return 之前。
      // 语义是"覆盖"：备份里有合法配置就整份替换；老版本备份没有此文件、
      // 或内容非法时保留本机现值（不回落默认，避免误清用户换过的图标/颜色）
      bool tagStylesRestored = false;
      final tagConfigRaw = extracted.tagConfig;
      if (tagConfigRaw != null) {
        final config = DiaryTagStyleConfig.tryParse(tagConfigRaw);
        if (config != null) {
          await DiaryTagStyles.save(config);
          tagStylesRestored = true;
          log('[备份导入] 恢复标签外观配置: ${config.encode()}');
        } else {
          log('[备份导入] tag_config.json 内容非法，跳过（保留本机配置）');
        }
      } else {
        log('[备份导入] 备份中无 tag_config.json，跳过（老版本备份）');
      }

      // 9. 检查是否有新数据（热词/修正对/触发词均已在前面独立恢复，
      //    不受此 return 影响）
      if (newItems.isEmpty && newDiaries.isEmpty) {
        log('[备份导入] 无新数据 early return (hotwordsRestored=$hotwordsRestored)');
        if (mounted) {
          Navigator.pop(context); // 关闭加载对话框
          final extras = <String>[
            if (hotwordsRestored) '热词配置已恢复',
            if (correctionsRestored > 0) '修正对已合并 $correctionsRestored 条',
            if (voiceSearchTriggersRestored) '语音搜索触发词已恢复',
            if (tagStylesRestored) '标签外观已恢复',
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
        if (voiceSearchTriggersRestored) {
          message += "，语音搜索触发词已恢复";
        }
        if (tagStylesRestored) {
          message += "，标签外观已恢复";
        }
        log(
          '[备份导入] 完成: 新物品=${newItems.length}, 新日记=${newDiaries.length}, '
          '新音频=$restoredAudioCount, 热词恢复=$hotwordsRestored, '
          '修正对合并=$correctionsRestored, '
          '触发词恢复=$voiceSearchTriggersRestored, '
          '标签外观恢复=$tagStylesRestored',
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

  @override
  Widget build(BuildContext context) {
    final ext = AppThemeExtension.of(context);
    // AI 应用入口行摘要用（选择列表在二级页，这里只显示当前选中项；
    // _selectedAIApp 在 _loadAIAppPreference 异步解析，含自定义应用）
    final aiApp = _selectedAIApp;
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

          // --- 云端同步（WebDAV 手动同步，与上面的本地 ZIP 备份互补）---
          SettingsCard(
            padding: EdgeInsets.zero,
            child: SettingsEntryRow(
              icon: Icons.cloud_sync_outlined,
              title: '云端同步',
              subtitle: _cloudSyncSubtitle ?? '未配置 · 支持 WebDAV 网盘（坚果云等）',
              onTap: _openCloudSyncPage,
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
              subtitle: '分享跳转：${aiApp.icon} ${aiApp.name}',
              onTap: _openAIAppPage,
            ),
          ),
          const SizedBox(height: 12),

          // --- 大爆炸搜索（引擎/浏览器选择下沉二级页）---
          SettingsCard(
            padding: EdgeInsets.zero,
            child: SettingsEntryRow(
              icon: Icons.travel_explore,
              title: '大爆炸搜索',
              subtitle: _searchSummary,
              onTap: _openSearchSettingsPage,
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
          const SizedBox(height: 12),

          // --- 眼不见为净（功能页面显隐 + 后台隐藏聚合二级页，2026-10-22）---
          // 两个 Tab 隐藏开关重启生效（main.dart main() 预读同一组 key）；
          // 后台隐藏写 prefs 即真值源并经 RecentsVisibility 通道实时生效
          _buildCard(
            padding: EdgeInsets.zero,
            child: SettingsEntryRow(
              icon: Icons.visibility_off_outlined,
              title: '眼不见为净',
              subtitle: _visibilitySummary,
              onTap: _openVisibilityPage,
            ),
          ),
          const SizedBox(height: 12),

          // --- 日记智能与交互（下沉二级页，2026-10-22）---
          _buildCard(
            padding: EdgeInsets.zero,
            child: SettingsEntryRow(
              icon: Icons.auto_awesome_outlined,
              title: '日记智能与交互',
              subtitle: _diaryInteractionSummary,
              onTap: _openDiaryInteractionPage,
            ),
          ),
          const SizedBox(height: 12),

          // --- 外观（主题/深色模式/图标/字号/字体/标签外观下沉二级页，2026-10-22）---
          _buildCard(
            padding: EdgeInsets.zero,
            child: SettingsEntryRow(
              icon: Icons.palette_outlined,
              title: '外观',
              subtitle: _appearanceSummary,
              onTap: _openAppearancePage,
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

          // --- 使用帮助：全量功能说明常驻入口（说明卡只是日记行，会被删除且
          // 旧文案不随版本更新；本页保证升级用户也能随时查到最新说法）---
          _buildSectionTitle("使用帮助"),
          _buildCard(
            padding: EdgeInsets.zero,
            child: SettingsEntryRow(
              icon: Icons.menu_book_outlined,
              title: '功能说明',
              subtitle: '全功能操作指南：语音说法、手势、悬浮窗与快捷方式',
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const FeatureGuidePage()),
              ),
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
  required String voiceSearchTriggersContent,
  required String tagConfigContent,
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
      voiceSearchTriggersContent: voiceSearchTriggersContent,
      tagConfigContent: tagConfigContent,
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
    String? voiceSearchTriggers,
    String? tagConfig,
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
  required String voiceSearchTriggersContent,
  required String tagConfigContent,
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
  // 悬浮窗语音搜索触发词（每行一个；导出的是当前实际生效列表）
  archive.addFile(
    ArchiveFile(
      'voice_search_triggers.txt',
      voiceSearchTriggersContent.length,
      utf8.encode(voiceSearchTriggersContent),
    ),
  );
  // 4 槽位标签外观（图标/颜色 JSON；老版本备份无此文件，导入侧可空兼容）
  archive.addFile(
    ArchiveFile(
      'tag_config.json',
      tagConfigContent.length,
      utf8.encode(tagConfigContent),
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
  String? voiceSearchTriggers,
  String? tagConfig,
  int restoredAudioCount,
})
_extractBackupZip({required String zipPath, required String audioDirPath}) {
  final zipBytes = File(zipPath).readAsBytesSync();
  final archive = ZipDecoder().decodeBytes(zipBytes);

  String? itemsCsv;
  String? diaryCsv;
  String? hotwords;
  String? corrections;
  String? voiceSearchTriggers;
  String? tagConfig;
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
    } else if (file.name == 'voice_search_triggers.txt') {
      voiceSearchTriggers = utf8.decode(file.content as List<int>);
    } else if (file.name == 'tag_config.json') {
      tagConfig = utf8.decode(file.content as List<int>);
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
    voiceSearchTriggers: voiceSearchTriggers,
    tagConfig: tagConfig,
    restoredAudioCount: restoredAudioCount,
  );
}
