import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
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
import '../utils/volume_gesture_config.dart'; // 音量键手势槽位配置（4 槽位动作选择器）
import '../overlay/overlay_constants.dart'; // OverlayConstants.autoHide*（自动隐藏档位唯一真值，与 overlay engine 共用）
import '../utils/diary_tag.dart'; // 日记标注 tag 常量（CSV 导入校验）

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
  final TextEditingController _hotwordController = TextEditingController();
  String _modelPathInfo = "内置模型就绪";
  String? _selectedAIAppId; // 新增：选中的 AI 应用 ID
  bool _isAccessibilityEnabled = false; // 无障碍服务是否已开启
  bool _keepMutedOnVolumeDownEnabled = true; // 按音量减保持静音开关，默认开启
  String _appVersion = ''; // 版本号，来自 package_info_plus
  bool _isExportingLog = false; // 运行日志导出中（拉起系统分享面板前禁用按钮+转圈）
  bool _isExportingStartupLog = false; // 启动日志导出中（同上）
  bool _isProUnlocked =
      false; // Pro 功能是否已解锁，持久化在 SharedPreferences 的 is_pro_unlocked
  String _currentIconPackId = 'default'; // 当前图标包 ID（从原生层读取，不依赖 prefs），Phase 4
  bool _itemTransferEnabled = true; // 日记智能识别物品+位置开关（默认开启）
  bool _queryAnswerEnabled = true; // 日记智能查询物品位置开关（默认开启）
  bool _swapTapLongPress = false; // 日记卡片单击/长按交换开关
  int _autoHideSeconds =
      OverlayConstants.autoHideDefaultSeconds; // 悬浮窗收起后自动隐藏秒数（5/10/30 或 autoHideNeverSeconds=永久，overlay engine 侧读同一 key）
  // 字号缩放档位（外观分区选择器；默认 1.0 标准）
  double _fontScale = 1.0;
  // 音量键手势槽位 → 动作映射（key 为 VolumeGestureSlot.* 常量；
  // 写入方 _loadVolumeGestureActions/_saveGestureAction，读取方本页 4 行槽位选择器）
  Map<String, String> _gestureActions = {};

  /// 启动耗时诊断 UI 开关（暂时隐藏，需要时改为 true）
  static const bool _kShowStartupDiagnostics = false;

  @override
  void initState() {
    super.initState();
    _loadHotwords();
    _loadModelStatus();
    _loadAIAppPreference(); // 新增：加载 AI 应用偏好
    _loadVolumeGestureActions(); // 加载音量键手势槽位动作配置
    _loadKeepMutedOnVolumeDown(); // 加载按音量减保持静音开关
    _loadAppVersion(); // 加载应用版本号
    _loadProUnlockStatus(); // 加载 Pro 解锁状态
    _loadCurrentIconPack(); // Phase 4：从原生层加载当前图标包状态
    _loadSmartSwitches(); // 加载日记智能识别开关状态
    _loadOverlaySettings(); // 加载悬浮窗开关状态
    _loadFontScale(); // 加载全局字号缩放档位
    WidgetsBinding.instance.addObserver(this);
    _checkAccessibilityStatus();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // 从系统设置返回时刷新无障碍服务状态
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

  /// 加载 Pro 解锁状态（从 SharedPreferences 的 is_pro_unlocked 字段）
  /// 后续功能门禁也读这同一个字段
  void _loadProUnlockStatus() async {
    final prefs = await SharedPreferences.getInstance();
    final unlocked = prefs.getBool('is_pro_unlocked') ?? false;
    if (mounted) {
      setState(() => _isProUnlocked = unlocked);
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

  /// 加载悬浮窗相关配置（收起后自动隐藏秒数）
  void _loadOverlaySettings() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        // 收起后自动隐藏秒数（读取方：overlay engine 的 _scheduleAutoHide，跨 engine 靠 reload 读新值）
        _autoHideSeconds =
            prefs.getInt('overlay_auto_hide_seconds') ?? OverlayConstants.autoHideDefaultSeconds;
      });
    }
  }

  /// 保存“收起后自动隐藏”秒数（读取方：overlay engine 的 _scheduleAutoHide）
  Future<void> _saveOverlayAutoHide(int seconds) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('overlay_auto_hide_seconds', seconds);
    setState(() => _autoHideSeconds = seconds);
    print('🔧 [Settings] overlay_auto_hide_seconds=$seconds');
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
    await ProUnlockDialog.show(context, isAlreadyUnlocked: _isProUnlocked);
    // 弹窗里可能点击了解锁按钮，重新读 prefs 刷新本页按钮文案
    if (mounted) {
      _loadProUnlockStatus();
    }
  }

  /// 悬浮窗系动作的 Pro 门禁：已解锁返回 true 放行；未解锁弹付费弹窗并返回 false（调用方不写 prefs）。
  /// 覆盖 3 个悬浮窗动作（show_overlay/overlay_record/overlay_new_note）+ 自动隐藏时长选择器。
  bool _ensureOverlayPro() {
    if (_isProUnlocked) return true;
    _showProUnlockDialog();
    return false;
  }

  /// Pro 徽章（金色胶囊，复用主题卡片 _buildThemeCard 同款视觉）
  Widget _buildProBadge() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppThemeExtension.of(context).goldAccent,
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
    );
  }

  void _loadHotwords() async {
    String text = await widget.processor.getLocalContent();
    setState(() => _hotwordController.text = text);
  }

  // 新增：加载 AI 应用偏好
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

  // 新增：保存 AI 应用选择
  Future<void> _saveAIAppPreference(String appId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('selected_ai_app', appId);
    setState(() => _selectedAIAppId = appId);

    // 显示保存成功提示
    if (mounted) {
      final app = AIApp.findById(appId);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("已设置为 ${app?.name ?? '未知应用'}"),
          duration: const Duration(seconds: 1),
        ),
      );
    }
  }

  // --- 无障碍服务（音量键录音）---
  static const _platform = MethodChannel('com.shengwuji.app/app');

  void _checkAccessibilityStatus() async {
    try {
      final enabled =
          await _platform.invokeMethod<bool>('isAccessibilityServiceEnabled') ??
          false;
      if (mounted) {
        setState(() => _isAccessibilityEnabled = enabled);
      }
    } catch (e) {
      log('检查无障碍服务状态失败: $e');
    }
  }

  void _openAccessibilitySettings() async {
    try {
      await _platform.invokeMethod<bool>('openAccessibilitySettings');
    } catch (e) {
      log('打开无障碍设置失败: $e');
    }
  }

  // --- 音量键手势槽位配置（4 槽位 × 5 动作）---
  /// 加载：新 key 优先，否则按旧配置推导（读取方：本页 4 行选择器；Kotlin 无障碍服务侧另有同规则 fallback）
  Future<void> _loadVolumeGestureActions() async {
    final prefs = await SharedPreferences.getInstance();
    final actions = await loadVolumeGestureActions(prefs);
    if (mounted) setState(() => _gestureActions = actions);
  }

  /// 保存：新 key 的唯一写入方（原生侧每次按键直接读落盘 prefs，无需 MethodChannel 通知）
  Future<void> _saveGestureAction(String slot, String action) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(slot, action);
    setState(() => _gestureActions[slot] = action);
    print('🔧 [Settings] 手势动作 $slot=$action');
  }

  // --- 按音量减保持静音开关 ---
  Future<void> _loadKeepMutedOnVolumeDown() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _keepMutedOnVolumeDownEnabled =
            prefs.getBool('keep_muted_on_volume_down') ?? true;
      });
    }
  }

  Future<void> _saveKeepMutedOnVolumeDown(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('keep_muted_on_volume_down', enabled);
    if (!enabled) {
      await prefs.setBool('mute_hint_enabled', false);
    }
    if (mounted) {
      setState(() {
        _keepMutedOnVolumeDownEnabled = enabled;
      });
    }
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
          _appVersion = '1.1.0'; // 来自 pubspec.yaml version: 1.1.0+21
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
                        Icon(
                          Icons.cleaning_services,
                          color: ext.textOnPrimary,
                        ),
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
      log('[备份导入][诊断] 步骤2-3完成 解析CSV: items=${items.length}, diaries=${diaries.length}');

      // 5. 构建现有数据索引（用于去重）
      final existingItems = await widget.dbHelper.queryAll();
      final existingDiaries = await widget.dbHelper.queryAllDiaries();
      log('[备份导入][诊断] 步骤5完成 查库: 现有items=${existingItems.length}, 现有diaries=${existingDiaries.length}');

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
          setState(() => _hotwordController.text = hotwordsContent);
        }
        hotwordsRestored = true;
      } else {
        log('[备份导入] 备份中无 user_hotwords.txt，跳过热词恢复');
      }

      // 9. 检查是否有新数据（热词已在上一步独立恢复，不受此 return 影响）
      if (newItems.isEmpty && newDiaries.isEmpty) {
        log('[备份导入] 无新数据 early return (hotwordsRestored=$hotwordsRestored)');
        if (mounted) {
          Navigator.pop(context); // 关闭加载对话框
          final msg = hotwordsRestored ? "✅ 热词配置已恢复（无其他新数据）" : "⚠️ 备份文件中没有新数据";
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
        log(
          '[备份导入] 完成: 新物品=${newItems.length}, 新日记=${newDiaries.length}, '
          '新音频=$restoredAudioCount, 热词恢复=$hotwordsRestored',
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
    return Scaffold(
      backgroundColor: ext.scaffoldBackground,
      appBar: AppBar(
        title: Text(
          "设置中心",
          style: TextStyle(
            color: ext.textPrimary,
            fontWeight: FontWeight.bold,
          ),
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
          _buildSectionTitle("数据备份与还原"),

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
                  style: TextStyle(
                    color: ext.textSecondary,
                    fontSize: 12,
                  ),
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

          const SizedBox(height: 24),

          // --- 热词管理部分 ---
          _buildSectionTitle("动态热词替换"),
          _buildCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                TextField(
                  controller: _hotwordController,
                  maxLines: 5,
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: ext.cardBackground,
                    hintText: "错词 = 正词 (每行一个)",
                    hintStyle: TextStyle(
                      color: ext.textHint,
                      fontSize: 13,
                    ),
                    contentPadding: const EdgeInsets.all(16),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(15),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
                const Divider(height: 1),
                _buildMainBtn("保存并更新热词", Icons.save_rounded, () async {
                  await widget.processor.saveContent(_hotwordController.text);
                  if (mounted)
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(const SnackBar(content: Text("✅ 热词已保存生效")));
                }, roundedBottom: true),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // --- AI 应用选择部分 ---
          _buildSectionTitle("AI 应用分享"),
          _buildCard(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "选择日记分享时跳转的 AI 应用",
                  style: TextStyle(
                    fontSize: 14,
                    color: ext.textHint,
                  ),
                ),
                const SizedBox(height: 16),
                // 单选列表
                ...AIApp.allApps.map((app) {
                  final isSelected = _selectedAIAppId == app.id;
                  return InkWell(
                    onTap: () => _saveAIAppPreference(app.id),
                    borderRadius: BorderRadius.circular(12),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: 10,
                        horizontal: 8,
                      ),
                      child: Row(
                        children: [
                          // 单选圆圈
                          Container(
                            width: 22,
                            height: 22,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: isSelected
                                    ? ext
                                          .primary
                                    : ext.textHint,
                                width: 2,
                              ),
                              color: isSelected
                                  ? ext.primary
                                  : ext.cardBackground,
                            ),
                            child: isSelected
                                ? Icon(
                                    Icons.check,
                                    size: 16,
                                    color: ext.textOnPrimary,
                                  )
                                : null,
                          ),
                          const SizedBox(width: 12),
                          // 图标
                          Text(app.icon, style: const TextStyle(fontSize: 24)),
                          const SizedBox(width: 12),
                          // 名称
                          Expanded(
                            child: Text(
                              app.name,
                              style: TextStyle(
                                fontSize: 16,
                                color: ext.textPrimary,
                              ),
                            ),
                          ),
                          // URL 提示
                          Text(
                            app.url
                                .replaceAll('https://', '')
                                .replaceAll('/', ''),
                            style: TextStyle(
                              fontSize: 12,
                              color: ext.textHint,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  );
                }).toList(),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // --- 音量键快捷操作部分 ---
          _buildSectionTitle("音量键快捷操作"),
          _buildCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      _isAccessibilityEnabled
                          ? Icons.check_circle
                          : Icons.cancel_outlined,
                      color: _isAccessibilityEnabled
                          ? ext
                                .positiveText
                          : ext.textHint,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _isAccessibilityEnabled ? "已开启" : "未开启",
                      style: TextStyle(
                        color: _isAccessibilityEnabled
                            ? ext
                                  .positiveText
                            : ext.textHint,
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  _isAccessibilityEnabled
                      ? "在任意界面通过音量键手势快速唤起录音、笔记或悬浮窗"
                      : "开启后，长按或双击音量键即可快速唤起对应功能",
                  style: TextStyle(
                    color: ext.textSecondary,
                    fontSize: 13,
                  ),
                ),
                // 4 手势槽位动作选择（仅在服务开启时显示）
                if (_isAccessibilityEnabled) ...[
                  const SizedBox(height: 12),
                  _buildGestureSelectorRow(
                    '长按音量加（约0.5秒）',
                    VolumeGestureSlot.longPressUp,
                  ),
                  const SizedBox(height: 14),
                  _buildGestureSelectorRow(
                    '长按音量减（约0.5秒）',
                    VolumeGestureSlot.longPressDown,
                  ),
                  const SizedBox(height: 14),
                  _buildGestureSelectorRow(
                    '双击音量加（0.3秒内）',
                    VolumeGestureSlot.doubleClickUp,
                  ),
                  const SizedBox(height: 14),
                  _buildGestureSelectorRow(
                    '双击音量减（0.3秒内）',
                    VolumeGestureSlot.doubleClickDown,
                  ),
                  SwitchListTile(
                    title: const Text(
                      '按音量减保持静音',
                      style: TextStyle(fontSize: 13),
                    ),
                    subtitle: Text(
                      '快捷录音/悬浮窗录音期间按音量减键，录音结束后继续保持静音',
                      style: TextStyle(fontSize: 11, color: ext.textHint),
                    ),
                    value: _keepMutedOnVolumeDownEnabled,
                    onChanged: (val) => _saveKeepMutedOnVolumeDown(val),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                  ),
                  const SizedBox(height: 8),
                  FutureBuilder<bool>(
                    future: SharedPreferences.getInstance().then(
                      (prefs) => prefs.getBool('mute_hint_enabled') ?? true,
                    ),
                    builder: (context, snapshot) {
                      return SwitchListTile(
                        title: const Text('静音提示'),
                        subtitle: const Text('快速录音静音时显示提示文案'),
                        value: snapshot.data ?? true,
                        onChanged: _keepMutedOnVolumeDownEnabled
                            ? (value) async {
                                final prefs =
                                    await SharedPreferences.getInstance();
                                await prefs.setBool('mute_hint_enabled', value);
                                // 触发重建以更新UI
                                setState(() {});
                              }
                            : null,
                      );
                    },
                  ),
                ],
                const SizedBox(height: 12),
                _buildMainBtn(
                  _isAccessibilityEnabled ? "已开启，前往系统设置" : "前往系统设置开启",
                  _isAccessibilityEnabled ? Icons.settings : Icons.launch,
                  _openAccessibilitySettings,
                ),
                const SizedBox(height: 6),
                Text(
                  "提示：在无障碍设置中找到「声物记」并开启服务",
                  style: TextStyle(
                    color: ext.textSecondary,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // --- 日记智能识别区域 ---
          // 控制日记页两个智能识别功能的开关，prefs key 与 DiaryTab._loadSmartSwitches 一致
          _buildSectionTitle("日记智能识别"),
          _buildCard(
            child: Column(
              children: [
                SwitchListTile(
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
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                ),
                SwitchListTile(
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
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // --- 日记交互区域 ---
          // 日记卡片单击/长按交互交换开关，prefs key 与 DiaryTab._loadSmartSwitches 一致
          _buildSectionTitle("日记卡片交互习惯"),
          _buildCard(
            child: Column(
              children: [
                SwitchListTile(
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
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                ),
              ],
            ),
          ),

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

          // --- 悬浮窗区域（闪念胶囊）---
          _buildSectionTitle("悬浮窗"),
          _buildCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.picture_in_picture_alt_outlined,
                      color: ext.primary,
                      size: 18,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      "屏幕边缘随手记面板",
                      style: TextStyle(color: ext.textSecondary, fontSize: 13),
                    ),
                    if (!_isProUnlocked) ...[
                      const SizedBox(width: 6),
                      _buildProBadge(),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '通过音量键手势召唤悬浮窗（见上方音量键快捷操作）',
                  style: TextStyle(fontSize: 12, color: ext.textHint),
                ),
                const SizedBox(height: 10),
                const Divider(height: 1),
                // 收起后自动隐藏时长选择（读取方：overlay engine 的 _scheduleAutoHide）
                Padding(
                  padding: const EdgeInsets.only(left: 4, top: 10, bottom: 6),
                  child: Text(
                    '收起后自动隐藏',
                    style: TextStyle(fontSize: 13, color: ext.textSecondary),
                  ),
                ),
                _buildAutoHideSelector(),
                const SizedBox(height: 10),
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
                    _isProUnlocked ? "Pro 已解锁 ✓" : "付费解锁 Pro 功能",
                    _isProUnlocked
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

          // --- 关于区域 ---
          const Divider(thickness: 1, height: 32),
          const SizedBox(height: 8),
          _buildSectionTitle("关于"),
          _buildCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 应用名称和版本号
                Row(
                  children: [
                    Icon(
                      Icons.info_outline,
                      color: ext.primary,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        "声物记",
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: ext.textPrimary,
                        ),
                      ),
                    ),
                    Text(
                      _appVersion.isNotEmpty ? "v$_appVersion" : "",
                      style: TextStyle(
                        fontSize: 14,
                        color: ext.textSecondary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  "完全离线 · 无需联网",
                  style: TextStyle(
                    fontSize: 12,
                    color: ext.textSecondary,
                  ),
                ),
                const SizedBox(height: 16),

                // 更新日志（可展开）
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: const EdgeInsets.only(top: 8),
                  dense: true,
                  title: Row(
                    children: [
                      Icon(
                        Icons.history,
                        color: ext.textSecondary,
                        size: 18,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        "更新日志",
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: ext.textPrimary,
                        ),
                      ),
                    ],
                  ),
                  children: [
                    _buildChangelogItem(
                      version: "v1.1.0",
                      date: "2026-09-06",
                      changes: [
                        "全新悬浮窗（闪念胶囊）：把闪念胶囊 1:1 搬进系统级悬浮窗，任意界面长按音量键即呼出——不用跳转 app、不打断当前操作，说完即走，收起后自动隐藏（Pro 功能）",
                        "悬浮窗语音定闹钟：点卡片闹钟按钮说「周六晚上八点提醒我去看电影」，自动识别时间，转轮确认后写入系统日历，到点响铃；「晚上八点」「两点半」等中文说法随口说也能识别",
                        "音量键唤醒悬浮窗：长按音量键唤出并自动展开最近笔记，显示中再按立即隐藏；音量键手势升级为长按 / 双击四槽位自定义",
                        "悬浮窗快速新建：面板顶部「+」一键新建笔记，自动弹起键盘进入编辑；点卡片展开全文直接编辑",
                        "悬浮窗卡片标注：紧急 / 收藏 / 灵感三种标注整卡换色，主 App 日记页同步显示色点",
                        "悬浮窗录音回放：语音速记卡片自带播放按钮，支持重放 / 暂停 / 继续",
                        "悬浮窗录音也支持临时静音：与快捷录音共用「按音量减保持静音」开关，录音期间按音量减，结束后继续保持静音",
                        "日历提醒确认更省心：时间可上下滑动微调、标题所见即所得，响铃开关可只建日历事件；缺权限时自动引导回主 App 授权，无通知权限自动改为仅日历提醒",
                        "悬浮窗语音速记录音上限 60 秒 → 5 分钟；悬浮窗记录与主 App 日记实时同步",
                        "语音转文字不再卡顿：转写挪到后台进行，转写期间刷列表、打字依旧流畅",
                        "备份导出 / 导入更稳更快：打包在后台完成不卡顿，等待期间 app 可正常使用，也修复了备份导入导出会报错的问题",
                        "Pro 解锁更贴心：扫码付款回来后点「已扫码，点击解锁」即可，不用再走付费入口",
                        "搬家模式语音播报更顺滑：播报在后台生成，边收边说不卡顿",
                        "闹钟到点即时提醒：响铃提示立即弹出，不再有可感知的等待",
                        "一批顺滑度优化：日记搜索更跟手、悬浮窗收展更流畅、拖动录音按钮更跟手，整体更省电",
                      ],
                    ),
                    _buildChangelogItem(
                      version: "v1.0.17",
                      date: "2026-08-18",
                      changes: [
                        "日记页录音按钮支持上滑-快速新建文本笔记",
                        "设置页将『静音提示』开关与『按音量减保持静音』开关整合在一起",
                        "临时静音保持功能-新增开关",
                        "隐藏日记卡片底部未实现的爱心图标，等待后续功能完善",
                      ],
                    ),
                    _buildChangelogItem(
                      version: "v1.0.16",
                      date: "2026-08-12",
                      changes: [
                        "随手记 / 日记归档后可一键恢复（新增恢复入口）",
                        "日记卡片「单击 / 长按」交互支持自定义交换",
                        "接收系统分享：从其他 App 选文字分享到声物记，存为笔记",
                        "热词配置纳入全量备份 / 恢复",
                      ],
                    ),
                    _buildChangelogItem(
                      version: "v1.0.15",
                      date: "2026-08-07",
                      changes: [
                        "日记卡片改版：日期/时长移至顶部，补全年份与时分格式",
                        "播放按钮升级为带响度波纹的可拖动进度条（拖动跳转/暂停继续）",
                        "转写中按钮区禁用态；修复进度条游标『先走再跳回』与暂停后续播虚高",
                        "搬家模式智能分割失败提示改为可左滑消除的自绘提示条（含手动保存按钮）",
                      ],
                    ),
                    _buildChangelogItem(
                      version: "v1.0.14",
                      date: "2026-08",
                      changes: [
                        "主题系统改版（4 套皮肤预设 + Android 桌面图标包切换，Pro 功能）",
                        "搬家模式增强（语音播报 + 说『不对/撤销』语音撤销 + 屏幕常亮省电遮罩）",
                        "录音防丢失（先落盘再转写，失败可重新转写）",
                        "长录音自动分段，说太久也不丢内容",
                        "待办清单需以『代办/待办』开头才识别，正常说话不会误判",
                        "锁屏隐私保护与音量键键盘修复",
                        "物品列表浮动语音查询按钮",
                        "Pro 弹窗接入真实付款码",
                        "录入/日记页按钮钉底便于单手操作",
                        "修复窄屏卡片底部信息栏溢出",
                        "补齐霞鹜文楷字体 OFL 开源协议",
                      ],
                    ),
                    _buildChangelogItem(
                      version: "v1.0.13",
                      date: "2026-06",
                      changes: [
                        "日记一键转物品（浅橙横条转存按钮）",
                        "设置页新增 Pro 付费解锁弹窗（支持作者）",
                        "录音按钮样式统一",
                        "修复双击音量键键盘抖动",
                      ],
                    ),
                    _buildChangelogItem(
                      version: "v1.0.12",
                      date: "2026-06",
                      changes: [
                        "日记页语音查找物品：说\"游戏机在哪儿\"自动在卡片下方展示物品位置答案，多匹配显示+N 跳转列表",
                      ],
                    ),
                    _buildChangelogItem(
                      version: "v1.0.11",
                      date: "2026-06",
                      changes: ["日记页首次启动内置 7 条功能说明卡片"],
                    ),
                    _buildChangelogItem(
                      version: "v1.0.10",
                      date: "2026-06",
                      changes: ["应用改名「东西放哪儿了→声物记」，包名更新为 com.shengwuji.app"],
                    ),
                    _buildChangelogItem(
                      version: "v1.0.9",
                      date: "2026-06",
                      changes: ["清单合并到日记表(v8)、侧滑圆圈闭合动画、闹钟到点循环响铃、时间识别蓝色高亮设闹钟"],
                    ),
                    _buildChangelogItem(
                      version: "v1.0.8",
                      date: "2026-06",
                      changes: ["清单功能迁移到日记页，新增子弹列表展示"],
                    ),
                    _buildChangelogItem(
                      version: "v1.0.7",
                      date: "2026-06",
                      changes: ["设置页新增版本更新日志、启动页权限说明、录音按钮调优"],
                    ),
                    _buildChangelogItem(
                      version: "v1.0.6",
                      date: "2026-06",
                      changes: ["震感改为原生 VibrationEffect API 驱动线性马达"],
                    ),
                    _buildChangelogItem(
                      version: "v1.0.5",
                      date: "2026-06",
                      changes: ["日记页震感替换为系统 HapticFeedback"],
                    ),
                    _buildChangelogItem(
                      version: "v1.0.4",
                      date: "2026-06",
                      changes: ["启动页去掉模型加载，恢复延迟加载模式"],
                    ),
                    _buildChangelogItem(
                      version: "v1.0.3",
                      date: "2026-06",
                      changes: ["修复快捷方式进入时录音卡死不转写的问题"],
                    ),
                    _buildChangelogItem(
                      version: "v1.0.2",
                      date: "2026-05",
                      changes: ["归档系统、侧滑归档/删除"],
                    ),
                    _buildChangelogItem(
                      version: "v1.0.1",
                      date: "2026-05",
                      changes: ["日记导出为 Markdown"],
                    ),
                    _buildChangelogItem(
                      version: "v1.0.0",
                      date: "2026-05",
                      changes: ["初始版本，支持离线语音识别"],
                      isLast: true,
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                _buildTextBtn(
                  '导出运行日志',
                  Icons.bug_report,
                  _exportLog,
                  busy: _isExportingLog,
                ),
                const SizedBox(height: 8),
                _buildTextBtn(
                  '开放源代码许可',
                  Icons.description,
                  () => showLicensePage(
                    context: context,
                    applicationName: '声物记',
                    applicationVersion: _appVersion.isNotEmpty
                        ? 'v$_appVersion'
                        : null,
                    applicationLegalese: '© 2026 声物记',
                    applicationIcon: Padding(
                      padding: const EdgeInsets.all(10),
                      child: Image.asset(
                        'assets/icon/app_icon.png',
                        width: 48,
                        height: 48,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 40),
        ],
      ),
    );
  }

  // --- 音量键手势槽位动作选择器行（标题 Text + 6 间距 + Wrap ChoiceChip）---
  Widget _buildGestureSelectorRow(String title, String slot) {
    final ext = AppThemeExtension.of(context);
    final options = [
      (VolumeGestureAction.none, '无动作', Icons.block),
      (VolumeGestureAction.showOverlay, '显示悬浮窗', Icons.picture_in_picture_alt),
      (VolumeGestureAction.overlayRecord, '悬浮窗录音', Icons.mic),
      (VolumeGestureAction.quickRecord, 'APP内录音', Icons.fiber_manual_record),
      (VolumeGestureAction.quickTextNote, 'APP内笔记', Icons.edit_note),
      (VolumeGestureAction.overlayNewNote, '悬浮窗笔记', Icons.note_add_outlined),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: options.map((opt) {
            final (action, label, icon) = opt;
            final selected =
                (_gestureActions[slot] ?? VolumeGestureAction.none) == action;
            // 悬浮窗系动作未解锁时展示 Pro 徽章（门禁在 onSelected 拦截，不写 prefs）
            final isOverlayAction =
                action == VolumeGestureAction.showOverlay ||
                action == VolumeGestureAction.overlayRecord ||
                action == VolumeGestureAction.overlayNewNote;
            return ChoiceChip(
              // ⚠️ ChoiceChip 的 avatar 槽位固定 24×24（M3 Container 定宽高居中），
              // 塞 Row 会溢出压到 label（防再犯：徽章必须放 label 侧）
              avatar: Icon(
                icon,
                size: 16,
                color: selected ? ext.textOnPrimary : ext.primary,
              ),
              label: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(label),
                  if (isOverlayAction && !_isProUnlocked) ...[
                    const SizedBox(width: 4),
                    _buildProBadge(),
                  ],
                ],
              ),
              selected: selected,
              selectedColor: ext.primary,
              labelStyle: TextStyle(
                color: selected
                    ? ext.textOnPrimary
                    : ext.textPrimary,
                fontSize: 13,
              ),
              onSelected: (_) {
                if (isOverlayAction && !_ensureOverlayPro()) return;
                _saveGestureAction(slot, action);
              },
            );
          }).toList(),
        ),
      ],
    );
  }

  // --- 悬浮窗收起后自动隐藏时长选择器（仿 _buildVolumeKeySelector 配色）---
  Widget _buildAutoHideSelector() {
    final ext = AppThemeExtension.of(context);
    // 「永久」写哨兵值 autoHideNeverSeconds（-1）进同一 prefs key，overlay
    // engine 读到即不起隐藏计时（收起态把手常驻）
    final options = [
      (5, '5 秒', Icons.timer_outlined),
      (10, '10 秒', Icons.timer_outlined),
      (30, '30 秒', Icons.timer_outlined),
      (OverlayConstants.autoHideNeverSeconds, '永久', Icons.all_inclusive),
    ];
    return Wrap(
      spacing: 8,
      runSpacing: 6,
      children: options.map((opt) {
        final (seconds, label, icon) = opt;
        final selected = _autoHideSeconds == seconds;
        return ChoiceChip(
          avatar: Icon(
            icon,
            size: 16,
            color: selected ? ext.textOnPrimary : ext.primary,
          ),
          label: Text(label),
          selected: selected,
          selectedColor: ext.primary,
          labelStyle: TextStyle(
            color: selected ? ext.textOnPrimary : ext.textPrimary,
            fontSize: 13,
          ),
          onSelected: (_) {
            // 自动隐藏时长属于悬浮窗配置，未解锁 Pro 时门禁（不写 prefs）
            if (!_ensureOverlayPro()) return;
            _saveOverlayAutoHide(seconds);
          },
        );
      }).toList(),
    );
  }

  // --- UI 构建辅助方法 ---

  Widget _buildSectionTitle(String title) {
    final ext = AppThemeExtension.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 10),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.bold,
          color: ext.textSecondary,
        ),
      ),
    );
  }

  Widget _buildCard({required Widget child, EdgeInsetsGeometry? padding}) {
    final ext = AppThemeExtension.of(context);
    return Container(
      decoration: BoxDecoration(
        color: ext.cardBackground,
        borderRadius: BorderRadius.circular(15),
        boxShadow: [
          BoxShadow(
            color: ext.textPrimary.withValues(
              alpha: 0.03,
            ),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      padding: padding ?? const EdgeInsets.all(16),
      child: child,
    );
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
        decoration: BoxDecoration(
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
  /// 1. Pro 门禁：未解锁点击 Pro 主题 → 关闭主题弹窗 → 调 [_showProUnlockDialog]
  /// 2. 正常切换：写 SharedPreferences('selected_theme') → 更新 [AppRoot.themeNotifier]
  ///    → 关闭弹窗 → SnackBar 提示
  Future<void> _onThemeTap(AppThemeDefinition theme) async {
    // Pro 门禁：未解锁点击 Pro 主题 → 关闭主题弹窗 + 调 ProUnlockDialog
    if (theme.isPro && !_isProUnlocked) {
      if (mounted) Navigator.of(context).pop();
      _showProUnlockDialog(); // 原方法签名为 void async，不 await（内部自管 mounted）
      return;
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

  /// 字号缩放入口（标题行仿 _buildThemeEntry 视觉 + 下方内嵌 ChoiceChip 选择器）
  ///
  /// 只有 4 个档位，不值得开弹窗，直接内嵌在卡片里（参照悬浮窗卡片的自动隐藏选择器）。
  Widget _buildFontSizeEntry() {
    final ext = AppThemeExtension.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Icon(Icons.format_size, color: ext.primary, size: 22),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '字号',
                      style: TextStyle(fontSize: 15, color: ext.textPrimary),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _fontScaleLabel(_fontScale),
                      style: TextStyle(fontSize: 12, color: ext.textSecondary),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        // 档位选择器（与标题行左图标文字对齐：16 边距 + 22 图标 + 14 间距）
        Padding(
          padding: const EdgeInsets.only(left: 52, right: 16, bottom: 14),
          child: _buildFontSizeSelector(),
        ),
      ],
    );
  }

  /// 字号缩放档位选择器（仿 _buildAutoHideSelector 配色）
  Widget _buildFontSizeSelector() {
    final ext = AppThemeExtension.of(context);
    final options = [(0.85, '小'), (1.0, '标准'), (1.15, '大'), (1.3, '特大')];
    return Wrap(
      spacing: 8,
      runSpacing: 6,
      children: options.map((opt) {
        final (scale, label) = opt;
        final selected = _fontScale == scale;
        return ChoiceChip(
          avatar: Icon(
            Icons.format_size,
            size: 16,
            color: selected ? ext.textOnPrimary : ext.primary,
          ),
          label: Text(label),
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

  /// 档位数值 → 展示名（标题行副标题用）
  String _fontScaleLabel(double scale) {
    switch (scale) {
      case 0.85:
        return '小';
      case 1.15:
        return '大';
      case 1.3:
        return '特大';
      default:
        return '标准';
    }
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
  /// 2. Pro 门禁：未解锁点击 Pro 图标包 → 关闭弹窗 → 调 _showProUnlockDialog
  /// 3. 正常切换：写 prefs('selected_icon_pack') → 调 IconPackSwitcher.switchTo
  ///    → 显示"正在切换..." → 延迟 3 秒关闭弹窗（进程可能已被系统杀死）
  Future<void> _onIconPackTap(IconPack pack) async {
    // 当前已选中，不切换
    if (_currentIconPackId == pack.id) {
      if (mounted) Navigator.of(context).pop();
      return;
    }

    // Pro 门禁：未解锁点击 Pro 图标包 → 关闭弹窗 + 调 ProUnlockDialog
    // 注：_showProUnlockDialog 原方法签名为 void async，不 await（内部自管 mounted）
    if (pack.isPro && !_isProUnlocked) {
      if (mounted) Navigator.of(context).pop();
      _showProUnlockDialog();
      return;
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

  Widget _buildMainBtn(
    String label,
    IconData icon,
    VoidCallback onPressed, {
    bool roundedBottom = false,
  }) {
    final ext = AppThemeExtension.of(context);
    return SizedBox(
      width: double.infinity,
      height: 50,
      child: ElevatedButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 20),
        label: Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
        style: ElevatedButton.styleFrom(
          backgroundColor: ext.primary,
          foregroundColor: ext.textOnPrimary,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: roundedBottom
                ? const BorderRadius.vertical(bottom: Radius.circular(15))
                : BorderRadius.circular(10),
          ),
        ),
      ),
    );
  }

  Widget _buildSecondaryBtn(
    String label,
    IconData icon,
    VoidCallback? onPressed, {
    Color? color,
    bool busy = false,
  }) {
    final ext = AppThemeExtension.of(context);
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
        side: BorderSide(
          color: color ?? ext.primary,
          width: 1,
        ),
        padding: const EdgeInsets.symmetric(vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  /// 导出应用运行日志（日志已由 AppLogger 实时落盘，这里主要耗时在
  /// 拉起系统分享面板——用 loading 态兜底这段延迟）
  Future<void> _exportLog() async {
    if (_isExportingLog) return;
    setState(() => _isExportingLog = true);
    try {
      await AppLogger.exportAndShare();
    } catch (e) {
      log('❌ 导出日志失败: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('导出日志失败: $e')));
      }
    } finally {
      if (mounted) setState(() => _isExportingLog = false);
    }
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

  Widget _buildTextBtn(
    String label,
    IconData icon,
    VoidCallback? onPressed, {
    bool busy = false,
  }) {
    return TextButton.icon(
      onPressed: busy ? null : onPressed,
      icon: busy
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(icon, size: 16),
      label: Text(label, style: const TextStyle(fontSize: 13)),
    );
  }

  /// 更新日志单条目组件
  Widget _buildChangelogItem({
    required String version,
    required String date,
    required List<String> changes,
    bool isLast = false,
  }) {
    final ext = AppThemeExtension.of(context);
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 时间线竖线 + 圆点
          SizedBox(
            width: 24,
            child: Column(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: ext.primary,
                    shape: BoxShape.circle,
                  ),
                ),
                if (!isLast)
                  Expanded(
                    child: Container(
                      width: 2,
                      color: ext.primary.withValues(
                        alpha: 0.2,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          // 内容区域
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: isLast ? 0 : 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        version,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: ext.primary,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        date,
                        style: TextStyle(
                          fontSize: 11,
                          color: ext.textHint,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (int i = 0; i < changes.length; i++) ...[
                        if (i > 0) const SizedBox(height: 4),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(top: 7),
                              child: Container(
                                width: 4,
                                height: 4,
                                decoration: BoxDecoration(
                                  color: ext.textSecondary,
                                  shape: BoxShape.circle,
                                ),
                              ),
                            ),
                            const SizedBox(width: 7),
                            Expanded(
                              child: Text(
                                changes[i],
                                style: TextStyle(
                                  fontSize: 13,
                                  color: ext.textSecondary,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
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
  required String audioDirPath,
  required Set<String> validAudioNames,
}) {
  return Isolate.run(
    () => _buildBackupZip(
      itemsCsv: itemsCsv,
      diaryCsv: diaryCsv,
      readme: readme,
      hotwordsContent: hotwordsContent,
      audioDirPath: audioDirPath,
      validAudioNames: validAudioNames,
    ),
  );
}

/// 主 isolate 调用的导入 trampoline：同上，闭包捕获域只剩两个 String。
Future<({String itemsCsv, String diaryCsv, String? hotwords, int restoredAudioCount})>
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
/// 提取 items/diary CSV 与热词内容（字符串回传主 isolate 解析入库），
/// 音频文件增量落盘（只写 audioDirPath 下不存在的文件，语义与原版一致）。
/// 缺必要 CSV 抛异常，由主 isolate catch 后弹错误框。
({String itemsCsv, String diaryCsv, String? hotwords, int restoredAudioCount})
_extractBackupZip({
  required String zipPath,
  required String audioDirPath,
}) {
  final zipBytes = File(zipPath).readAsBytesSync();
  final archive = ZipDecoder().decodeBytes(zipBytes);

  String? itemsCsv;
  String? diaryCsv;
  String? hotwords;
  int restoredAudioCount = 0;

  final audioDir = Directory(audioDirPath);

  for (final file in archive) {
    if (file.name == 'items.csv') {
      itemsCsv = utf8.decode(file.content as List<int>);
    } else if (file.name == 'diary.csv') {
      diaryCsv = utf8.decode(file.content as List<int>);
    } else if (file.name == 'user_hotwords.txt') {
      hotwords = utf8.decode(file.content as List<int>);
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
    restoredAudioCount: restoredAudioCount,
  );
}
