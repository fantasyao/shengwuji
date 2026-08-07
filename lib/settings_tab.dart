import 'dart:convert';
import 'dart:io';
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
import '../widgets/license_dialog.dart'; // 开源字体许可证查看弹窗（设置→关于）
import '../theme/app_theme_extension.dart';
import '../theme/app_theme.dart'; // AppThemes / AppThemeDefinition（Phase 3 主题选择）
import '../main.dart'; // AppRoot.themeNotifier（Phase 3 主题切换）
import '../utils/icon_pack_switcher.dart'; // Phase 4 图标包切换

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
  String _volumeKeyMode = 'down'; // 音量键监听模式：off/up/down/both
  bool _doubleClickTextNoteEnabled = true; // 双击音量键新建文本笔记开关，默认开启
  String _appVersion = ''; // 版本号，来自 package_info_plus
  bool _isProUnlocked =
      false; // Pro 功能是否已解锁，持久化在 SharedPreferences 的 is_pro_unlocked
  String _currentIconPackId = 'default'; // 当前图标包 ID（从原生层读取，不依赖 prefs），Phase 4
  bool _itemTransferEnabled = true; // 日记智能识别物品+位置开关（默认开启）
  bool _queryAnswerEnabled = true; // 日记智能查询物品位置开关（默认开启）

  /// 启动耗时诊断 UI 开关（暂时隐藏，需要时改为 true）
  static const bool _kShowStartupDiagnostics = false;

  @override
  void initState() {
    super.initState();
    _loadHotwords();
    _loadModelStatus();
    _loadAIAppPreference(); // 新增：加载 AI 应用偏好
    _loadVolumeKeyMode(); // 加载音量键监听偏好
    _loadDoubleClickTextNote(); // 加载双击文本笔记开关
    _loadAppVersion(); // 加载应用版本号
    _loadProUnlockStatus(); // 加载 Pro 解锁状态
    _loadCurrentIconPack(); // Phase 4：从原生层加载当前图标包状态
    _loadSmartSwitches(); // 加载日记智能识别开关状态
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
      });
    }
  }

  /// 显示 Pro 解锁弹窗，关闭后刷新按钮文案
  void _showProUnlockDialog() async {
    await ProUnlockDialog.show(context, isAlreadyUnlocked: _isProUnlocked);
    // 弹窗里可能点击了解锁按钮，重新读 prefs 刷新本页按钮文案
    if (mounted) {
      _loadProUnlockStatus();
    }
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

  // --- 音量键监听模式 ---
  Future<void> _loadVolumeKeyMode() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _volumeKeyMode = prefs.getString('volume_key_mode') ?? 'down';
      });
    }
  }

  Future<void> _saveVolumeKeyMode(String mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('volume_key_mode', mode);
    setState(() {
      _volumeKeyMode = mode;
    });
  }

  // --- 双击音量键文本笔记开关 ---
  Future<void> _loadDoubleClickTextNote() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _doubleClickTextNoteEnabled =
            prefs.getBool('double_click_text_note') ?? true;
      });
    }
  }

  Future<void> _saveDoubleClickTextNote(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('double_click_text_note', enabled);
    setState(() {
      _doubleClickTextNoteEnabled = enabled;
    });
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
          _appVersion = '1.0.6'; // 来自 pubspec.yaml version: 1.0.6+6
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

          // 🆕 主动请求麦克风权限，避免首次录音时权限弹窗打断长按手势
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
                        ), // 原 Colors.white
                        SizedBox(width: 10),
                        Text("✅ 模型导入成功！已自动清理缓存"),
                      ],
                    ),
                    backgroundColor: ext.primary, // 原 Colors.teal
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

  // --- 热词导入导出逻辑 ---
  Future<void> _exportHotwords() async {
    String content = _hotwordController.text;
    if (content.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("没有可导出的热词")));
      return;
    }
    String timestamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
    await FilePicker.platform.saveFile(
      fileName: 'hotwords_config_$timestamp.txt',
      bytes: utf8.encode(content),
    );
  }

  Future<void> _importHotwords() async {
    FilePickerResult? res = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['txt'],
    );
    if (res != null) {
      final file = File(res.files.single.path!);
      String content = await file.readAsString();
      setState(() => _hotwordController.text = content);
      await widget.processor.saveContent(content);
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text("热词配置已导入并生效")));
    }
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

      // 1. 获取数据
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

      // 2. 创建ZIP文件
      final archive = Archive();

      // 3. 添加 items.csv
      final itemsCsv = _generateItemsCsv(items);
      archive.addFile(
        ArchiveFile('items.csv', itemsCsv.length, utf8.encode(itemsCsv)),
      );

      // 4. 添加 diary.csv
      final diaryCsv = _generateDiaryCsv(diaries);
      archive.addFile(
        ArchiveFile('diary.csv', diaryCsv.length, utf8.encode(diaryCsv)),
      );

      // 5. 添加音频文件 - 只导出有效的录音
      final appDocDir = await getApplicationDocumentsDirectory();
      final audioDir = Directory(p.join(appDocDir.path, 'diary_audio'));

      int orphanCount = 0; // 统计孤儿文件数量

      if (audioDir.existsSync()) {
        final audioFiles = audioDir.listSync().whereType<File>().toList();

        for (var audioFile in audioFiles) {
          final fileName = p.basename(audioFile.path);

          // 只导出数据库中存在的录音
          if (validAudioPaths.contains(fileName)) {
            final bytes = await audioFile.readAsBytes();
            final archiveFileName = 'audio/$fileName';
            archive.addFile(ArchiveFile(archiveFileName, bytes.length, bytes));
          } else {
            // 标记为孤儿文件
            orphanCount++;
          }
        }
      }

      // 6. 添加 README.txt
      final readme = _generateReadme();
      archive.addFile(
        ArchiveFile('README.txt', readme.length, utf8.encode(readme)),
      );

      // 7. 压缩ZIP
      final zipBytes = ZipEncoder().encode(archive);

      // 8. 关闭加载对话框
      if (mounted) Navigator.pop(context);

      // 9. 保存文件
      if (zipBytes != null) {
        final timestamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
        final fileName = 'voice_diary_backup_$timestamp.zip';

        final result = await FilePicker.platform.saveFile(
          fileName: fileName,
          bytes: Uint8List.fromList(zipBytes),
        );

        if (result != null) {
          // ZIP 创建成功后，清理孤儿录音文件
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
      }
    } catch (e) {
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
      ['ID', '内容', '创建时间', '音频文件', '时长(秒)'],
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

      // 1. 读取ZIP文件
      final zipFile = File(result.files.single.path!);
      final zipBytes = await zipFile.readAsBytes();
      final archive = ZipDecoder().decodeBytes(zipBytes);

      // 2. 提取并验证文件
      ArchiveFile? itemsCsv;
      ArchiveFile? diaryCsv;
      List<ArchiveFile> audioFiles = [];

      for (var file in archive) {
        if (file.name == 'items.csv') {
          itemsCsv = file;
        } else if (file.name == 'diary.csv') {
          diaryCsv = file;
        } else if (file.name.startsWith('audio/')) {
          audioFiles.add(file);
        }
      }

      if (itemsCsv == null || diaryCsv == null) {
        throw Exception("备份文件格式错误：缺少必要的CSV文件");
      }

      // 3. 解析items.csv
      final itemsContent = utf8.decode(itemsCsv.content as List<int>);
      final items = _parseItemsCsv(itemsContent);

      // 4. 解析diary.csv
      final diaryContent = utf8.decode(diaryCsv.content as List<int>);
      final diaries = _parseDiaryCsv(diaryContent);

      // 5. 构建现有数据索引（用于去重）
      final existingItems = await widget.dbHelper.queryAll();
      final existingDiaries = await widget.dbHelper.queryAllDiaries();

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
        await widget.dbHelper.batchInsertItems(newItems);
      }

      // 获取应用文档目录（后续步骤共用）
      final appDocDir = await getApplicationDocumentsDirectory();

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
        await widget.dbHelper.batchInsertDiaries(newDiaries);
      }

      // 8. 检查是否有新数据
      if (newItems.isEmpty && newDiaries.isEmpty) {
        if (mounted) {
          Navigator.pop(context); // 关闭加载对话框
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text("⚠️ 备份文件中没有新数据")));
        }
        return;
      }

      // 8. 恢复音频文件
      final audioDir = Directory(p.join(appDocDir.path, 'diary_audio'));

      // 确保音频目录存在
      if (!audioDir.existsSync()) {
        await audioDir.create(recursive: true);
      }
      // 不再清空现有音频文件，改为增量合并

      // 只恢复不存在的音频文件
      int restoredAudioCount = 0;
      for (var audioFile in audioFiles) {
        final fileName = p.basename(audioFile.name);
        final filePath = p.join(audioDir.path, fileName);
        final file = File(filePath);

        // 检查文件是否已存在
        if (!await file.exists()) {
          await file.writeAsBytes(audioFile.content as List<int>);
          restoredAudioCount++;
        }
      }

      // 8. 关闭加载对话框
      if (mounted) Navigator.pop(context);

      // 9. 显示成功消息
      if (mounted) {
        String message =
            "✅ 增量导入成功：${newItems.length}个新物品，${newDiaries.length}条新日记";
        if (restoredAudioCount > 0) {
          message += "，$restoredAudioCount个新音频";
        }
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
      }
    } catch (e) {
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
      backgroundColor: ext.scaffoldBackground, // 原 Color(0xFFF8F9FB)
      appBar: AppBar(
        title: Text(
          "设置中心",
          style: TextStyle(
            color: ext.textPrimary,
            fontWeight: FontWeight.bold,
          ), // 原 Colors.black87
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
                      color: ext.warningText, // 原 Colors.deepOrange
                      size: 18,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      "数据备份",
                      style: TextStyle(
                        color: ext.textPrimary, // 原 Colors.black87
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
                  ), // 原 Colors.black54
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: _buildSecondaryBtn(
                        "导入备份",
                        Icons.restore,
                        _importFullBackup,
                        color: ext.warningText, // 原 Colors.deepOrange
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _buildSecondaryBtn(
                        "导出备份",
                        Icons.backup,
                        _exportFullBackup,
                        color: ext.warningText, // 原 Colors.deepOrange
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          const SizedBox(height: 24),

          // --- 热词管理部分 ---
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _buildSectionTitle("动态热词替换"),
              Row(
                children: [
                  _buildTextBtn(
                    "导入",
                    Icons.drive_folder_upload,
                    _importHotwords,
                  ),
                  _buildTextBtn("导出", Icons.drive_file_move, _exportHotwords),
                ],
              ),
            ],
          ),
          _buildCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                TextField(
                  controller: _hotwordController,
                  maxLines: 5,
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: ext.cardBackground, // 原 Colors.white
                    hintText: "错词 = 正词 (每行一个)",
                    hintStyle: TextStyle(
                      color: ext.textHint, // 原 Colors.grey
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
                  ), // 原 Colors.grey
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
                                          .primary // 原 Colors.blue
                                    : ext.textHint, // 原 Colors.grey.shade400
                                width: 2,
                              ),
                              color: isSelected
                                  ? ext.primary
                                  : ext.cardBackground, // 原 Colors.blue : Colors.white
                            ),
                            child: isSelected
                                ? Icon(
                                    Icons.check,
                                    size: 16,
                                    color: ext.textOnPrimary, // 原 Colors.white
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
                              color: ext.textHint, // 原 Colors.grey.shade400
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

          // --- 音量键快捷录音部分 ---
          _buildSectionTitle("音量键快捷录音"),
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
                                .positiveText // 原 Colors.green
                          : ext.textHint, // 原 Colors.grey
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _isAccessibilityEnabled ? "已开启" : "未开启",
                      style: TextStyle(
                        color: _isAccessibilityEnabled
                            ? ext
                                  .positiveText // 原 Colors.green
                            : ext.textHint, // 原 Colors.grey
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  _isAccessibilityEnabled
                      ? "在任何界面长按选择的音量键（约0.5秒）即可快速录音"
                      : "开启后，长按音量键即可在任何界面快速录音",
                  style: TextStyle(
                    color: ext.textSecondary,
                    fontSize: 13,
                  ), // 原 Colors.black54
                ),
                // 音量键选择（仅在服务开启时显示）
                if (_isAccessibilityEnabled) ...[
                  const SizedBox(height: 12),
                  const Text(
                    "长按哪个音量键触发：",
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 6),
                  _buildVolumeKeySelector(),
                  const SizedBox(height: 12),
                  SwitchListTile(
                    title: const Text(
                      '双击音量键新建文本笔记',
                      style: TextStyle(fontSize: 13),
                    ),
                    subtitle: Text(
                      '快速双击选中的音量键可新建空白笔记',
                      style: TextStyle(fontSize: 11, color: ext.textHint),
                    ), // 原 Colors.black45
                    value: _doubleClickTextNoteEnabled,
                    onChanged: (val) => _saveDoubleClickTextNote(val),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
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
                  ), // 原 Colors.blueGrey
                ),
                // 静音提示开关
                if (_isAccessibilityEnabled) ...[
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
                        onChanged: (value) async {
                          final prefs = await SharedPreferences.getInstance();
                          await prefs.setBool('mute_hint_enabled', value);
                          // 触发重建以更新UI
                          setState(() {});
                        },
                      );
                    },
                  ),
                ],
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
                      ), // 原 Colors.orange
                      const SizedBox(width: 6),
                      Text(
                        "启动耗时诊断",
                        style: TextStyle(
                          color: ext.textSecondary,
                          fontSize: 13,
                        ),
                      ), // 原 Colors.black54
                    ],
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: _buildSecondaryBtn(
                      "导出启动日志",
                      Icons.upload_file,
                      () async {
                        await StartupLogger.exportAndShare();
                      },
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
                    ), // 原 Color(0xFFD4A437)
                    SizedBox(width: 6),
                    Text(
                      "付费解锁 Pro 功能",
                      style: TextStyle(color: ext.textSecondary, fontSize: 13),
                    ), // 原 Colors.black54
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
                    color: ext.goldAccent, // 原 Color(0xFFD4A437)
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
                    ), // 原 Colors.blueAccent
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        "声物记",
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: ext.textPrimary, // 原 Colors.black87
                        ),
                      ),
                    ),
                    Text(
                      _appVersion.isNotEmpty ? "v$_appVersion" : "",
                      style: TextStyle(
                        fontSize: 14,
                        color: ext.textSecondary, // 原 Colors.black54
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
                  ), // 原 Colors.blueGrey
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
                      ), // 原 Colors.blueGrey
                      const SizedBox(width: 6),
                      Text(
                        "更新日志",
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: ext.textPrimary, // 原 Colors.black87
                        ),
                      ),
                    ],
                  ),
                  children: [
                    _buildChangelogItem(
                      version: "v1.0.15",
                      date: "2026-08-07",
                      changes:
                          "日记卡片改版（日期/时长移至顶部 + 补全年份与时分格式 + 播放按钮升级为带响度波纹的可拖动进度条，支持拖动跳转/暂停继续 + 转写中按钮区禁用态 + 修复进度条游标『先走再跳回』与暂停后续播虚高，弃用 position 流改 Stopwatch 自算）+ 搬家模式智能分割失败提示改为可左滑消除的自绘提示条（含手动保存按钮，替代手势不便的 SnackBar）",
                    ),
                    _buildChangelogItem(
                      version: "v1.0.14",
                      date: "2026-08",
                      changes:
                          "主题系统改版（4 套皮肤预设 + Android 桌面图标包切换，Pro 门禁）+ 搬家模式增强（TTS 语音播报 + 说『不对/撤销』语音撤销 + 屏幕常亮省电遮罩）+ 录音防丢失（先落盘再转写，失败可重新转写）+ 长录音 VAD 自动切分保护 + 清单触发词门禁（『代办/待办』开头才识别，避免正常说话误判）+ 锁屏隐私保护与音量键键盘修复 + 物品列表浮动语音查询按钮 + Pro 弹窗接入真实付款码 + 录入/日记页按钮钉底便于单手操作 + 修复窄屏卡片底部信息栏溢出 + 补齐霞鹜文楷字体 OFL 开源协议",
                    ),
                    _buildChangelogItem(
                      version: "v1.0.13",
                      date: "2026-06",
                      changes:
                          "日记一键转物品（浅橙横条转存按钮）+ 设置页新增 Pro 付费解锁弹窗（支持作者）+ 录音按钮样式统一 + 修复双击音量键键盘抖动",
                    ),
                    _buildChangelogItem(
                      version: "v1.0.12",
                      date: "2026-06",
                      changes:
                          "日记页语音查找物品：说\"游戏机在哪儿\"自动在卡片下方展示物品位置答案，多匹配显示+N 跳转列表",
                    ),
                    _buildChangelogItem(
                      version: "v1.0.11",
                      date: "2026-06",
                      changes: "日记页首次启动内置 7 条功能说明卡片",
                    ),
                    _buildChangelogItem(
                      version: "v1.0.10",
                      date: "2026-06",
                      changes: "应用改名「东西放哪儿了→声物记」，包名更新为 com.shengwuji.app",
                    ),
                    _buildChangelogItem(
                      version: "v1.0.9",
                      date: "2026-06",
                      changes: "清单合并到日记表(v8)、侧滑圆圈闭合动画、闹钟到点循环响铃、时间识别蓝色高亮设闹钟",
                    ),
                    _buildChangelogItem(
                      version: "v1.0.8",
                      date: "2026-06",
                      changes: "清单功能迁移到日记页，新增子弹列表展示",
                    ),
                    _buildChangelogItem(
                      version: "v1.0.7",
                      date: "2026-06",
                      changes: "设置页新增版本更新日志、启动页权限说明、录音按钮调优",
                    ),
                    _buildChangelogItem(
                      version: "v1.0.6",
                      date: "2026-06",
                      changes: "震感改为原生 VibrationEffect API 驱动线性马达",
                    ),
                    _buildChangelogItem(
                      version: "v1.0.5",
                      date: "2026-06",
                      changes: "日记页震感替换为系统 HapticFeedback",
                    ),
                    _buildChangelogItem(
                      version: "v1.0.4",
                      date: "2026-06",
                      changes: "启动页去掉模型加载，恢复延迟加载模式",
                    ),
                    _buildChangelogItem(
                      version: "v1.0.3",
                      date: "2026-06",
                      changes: "修复快捷方式进入时录音卡死不转写的问题",
                    ),
                    _buildChangelogItem(
                      version: "v1.0.2",
                      date: "2026-05",
                      changes: "归档系统、侧滑归档/删除",
                    ),
                    _buildChangelogItem(
                      version: "v1.0.1",
                      date: "2026-05",
                      changes: "日记导出为 Markdown",
                    ),
                    _buildChangelogItem(
                      version: "v1.0.0",
                      date: "2026-05",
                      changes: "初始版本，支持离线语音识别",
                      isLast: true,
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                _buildTextBtn('导出运行日志', Icons.bug_report, () => _exportLog()),
                const SizedBox(height: 8),
                _buildTextBtn(
                    '开源字体许可证', Icons.description, () => LicenseDialog.show(context)),
              ],
            ),
          ),
          const SizedBox(height: 40),
        ],
      ),
    );
  }

  // --- 音量键选择器 ---
  Widget _buildVolumeKeySelector() {
    final ext = AppThemeExtension.of(context);
    final options = [
      ('down', '音量减', Icons.volume_down),
      ('up', '音量加', Icons.volume_up),
      ('both', '两个都开', Icons.volume_up),
      ('off', '关闭', Icons.volume_off),
    ];
    return Wrap(
      spacing: 8,
      runSpacing: 6,
      children: options.map((opt) {
        final (mode, label, icon) = opt;
        final selected = _volumeKeyMode == mode;
        return ChoiceChip(
          avatar: Icon(
            icon,
            size: 16,
            color: selected
                ? ext.textOnPrimary
                : ext.primary, // 原 Colors.white : Colors.blue
          ),
          label: Text(label),
          selected: selected,
          selectedColor: ext.primary, // 原 Colors.blue
          labelStyle: TextStyle(
            color: selected
                ? ext.textOnPrimary
                : ext.textPrimary, // 原 Colors.white : Colors.black87
            fontSize: 13,
          ),
          onSelected: (_) => _saveVolumeKeyMode(mode),
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
          color: ext.textSecondary, // 原 Colors.blueGrey
        ),
      ),
    );
  }

  Widget _buildCard({required Widget child, EdgeInsetsGeometry? padding}) {
    final ext = AppThemeExtension.of(context);
    return Container(
      decoration: BoxDecoration(
        color: ext.cardBackground, // 原 Colors.white
        borderRadius: BorderRadius.circular(15),
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
          backgroundColor: ext.primary, // 原 Colors.blueAccent
          foregroundColor: ext.textOnPrimary, // 原 Colors.white
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
    VoidCallback onPressed, {
    Color? color,
  }) {
    final ext = AppThemeExtension.of(context);
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
      label: Text(
        label,
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
      style: OutlinedButton.styleFrom(
        foregroundColor: color ?? ext.primary, // 原 Colors.blueAccent
        side: BorderSide(
          color: color ?? ext.primary,
          width: 1,
        ), // 原 Colors.blueAccent
        padding: const EdgeInsets.symmetric(vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  /// 导出应用运行日志
  Future<void> _exportLog() async {
    try {
      await AppLogger.exportAndShare();
    } catch (e) {
      log('❌ 导出日志失败: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('导出日志失败: $e')));
      }
    }
  }

  Widget _buildTextBtn(String label, IconData icon, VoidCallback onPressed) {
    return TextButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 16),
      label: Text(label, style: const TextStyle(fontSize: 13)),
    );
  }

  /// 更新日志单条目组件
  Widget _buildChangelogItem({
    required String version,
    required String date,
    required String changes,
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
                    color: ext.primary, // 原 Colors.blueAccent
                    shape: BoxShape.circle,
                  ),
                ),
                if (!isLast)
                  Expanded(
                    child: Container(
                      width: 2,
                      color: ext.primary.withValues(
                        alpha: 0.2,
                      ), // 原 Colors.blueAccent.withValues(alpha: 0.2)
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
                          color: ext.primary, // 原 Colors.blueAccent
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        date,
                        style: TextStyle(
                          fontSize: 11,
                          color: ext.textHint, // 原 Colors.black38
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    changes,
                    style: TextStyle(
                      fontSize: 13,
                      color: ext.textSecondary, // 原 Colors.black54
                    ),
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
