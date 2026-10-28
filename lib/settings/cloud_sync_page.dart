import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../db_helper.dart';
import '../sync/cloud_sync_service.dart';
import '../sync/webdav_request_counter.dart';
import '../text_processor.dart';
import '../theme/app_theme_extension.dart';
import '../utils/cloud_sync_data_version.dart'; // 待同步检测
import '../widgets/neu_widgets.dart';
import 'settings_widgets.dart';
import 'webdav_budget_line.dart';

/// 「云端同步」二级页（设置 → 云端同步）。
///
/// WebDAV 手动同步：日记走 v2 三方合并（编辑与删除跨端传播）；物品记录/
/// 热词/修正对仍是新增条目双向合并。
/// 边界：手动触发；录音文件走独立开关默认不同步
/// （见页内说明与 docs/architecture/cloud-sync.md）。
class CloudSyncPage extends StatefulWidget {
  const CloudSyncPage({
    super.key,
    required this.processor,
    required this.dbHelper,
    this.requestCounter,
  });

  final TextProcessor processor;
  final DbHelper dbHelper;

  /// WebDAV 请求预算；为空时用本 engine 的单例（单测可注入假计数）。
  final WebDavRequestCounter? requestCounter;

  @override
  State<CloudSyncPage> createState() => _CloudSyncPageState();
}

class _CloudSyncPageState extends State<CloudSyncPage> {
  final _serverController = TextEditingController();
  final _accountController = TextEditingController();
  final _passwordController = TextEditingController();
  final _remotePathController = TextEditingController();

  bool _obscurePassword = true;
  bool _busy = false; // 测试连接/同步共用防重入
  bool _syncAudio = false; // 是否同步录音文件（独立即时保存，默认关）
  String? _lastSyncText;
  bool _hasPending = false; // 本地有变更未同步（数据版本 > 已同步快照）
  String? _resultMessage;
  bool _resultOk = false;
  List<String> _resultDetails = const [];

  late final WebDavRequestCounter? _requestCounter =
      widget.requestCounter ?? WebDavRequestCounter.instanceOrNull;

  late final CloudSyncService _service = CloudSyncService(
    dbHelper: widget.dbHelper,
    processor: widget.processor,
    requestCounter: _requestCounter,
  );

  @override
  void initState() {
    super.initState();
    _loadConfig();
    _loadLastSync();
    // 悬浮窗 engine 的请求不在本 isolate 的内存里：进页读一次它的日志
    final counter = _requestCounter;
    if (counter != null) unawaited(counter.refreshOtherEngine());
  }

  @override
  void dispose() {
    _serverController.dispose();
    _accountController.dispose();
    _passwordController.dispose();
    _remotePathController.dispose();
    super.dispose();
  }

  Future<void> _loadConfig() async {
    final config = await CloudSyncConfig.load();
    if (!mounted) return;
    setState(() {
      _serverController.text = config.serverUrl;
      _accountController.text = config.account;
      _passwordController.text = config.password;
      _remotePathController.text = config.remotePath;
      _syncAudio = config.syncAudio;
    });
  }

  Future<void> _loadLastSync() async {
    final info = await CloudSyncConfig.lastSyncInfo();
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload(); // 悬浮窗 engine 可能刚 bump，防读到旧值
    final pending = CloudSyncDataVersion.hasPending(
      hasLastSync: info != null,
      syncedVersion: prefs.getInt(CloudSyncDataVersion.syncedVersionKey),
      currentVersion: CloudSyncDataVersion.current(prefs),
    );
    if (!mounted) return;
    setState(() {
      _hasPending = pending;
      _lastSyncText = info == null
          ? null
          : '${info.$1.month}月${info.$1.day}日 ${info.$1.hour.toString().padLeft(2, '0')}:${info.$1.minute.toString().padLeft(2, '0')} · ${info.$2}';
    });
  }

  bool get _formConfigured =>
      _serverController.text.trim().isNotEmpty &&
      _accountController.text.trim().isNotEmpty &&
      _passwordController.text.isNotEmpty;

  Future<void> _saveConfig() async {
    if (!_formConfigured) {
      _showSnack('服务器地址、账号和应用密码都不能为空');
      return;
    }
    await CloudSyncConfig.save(
      serverUrl: _serverController.text,
      account: _accountController.text,
      password: _passwordController.text,
      remotePath: _remotePathController.text,
    );
    if (mounted) _showSnack('✅ 配置已保存');
  }

  Future<void> _testConnection() async {
    await CloudSyncConfig.save(
      serverUrl: _serverController.text,
      account: _accountController.text,
      password: _passwordController.text,
      remotePath: _remotePathController.text,
    );
    setState(() {
      _busy = true;
      _resultMessage = '正在连接…';
      _resultDetails = const [];
    });
    final error = await _service.testConnection();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _resultOk = error == null;
      _resultMessage = error == null ? '✅ 连接成功，远端目录可用' : '❌ $error';
    });
  }

  Future<void> _runSync() async {
    await CloudSyncConfig.save(
      serverUrl: _serverController.text,
      account: _accountController.text,
      password: _passwordController.text,
      remotePath: _remotePathController.text,
    );
    setState(() {
      _busy = true;
      _resultOk = false;
      _resultMessage = '正在同步…';
      _resultDetails = const [];
    });
    final result = await _service.sync();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _resultOk = result.ok;
      _resultMessage = result.ok
          ? '✅ ${result.message}'
          : '❌ ${result.message}';
      _resultDetails = result.details;
    });
    _loadLastSync();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.ok ? '✅ ${result.message}' : '❌ ${result.message}',
          ),
        ),
      );
    }
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final ext = AppThemeExtension.of(context);
    return Scaffold(
      backgroundColor: ext.scaffoldBackground,
      appBar: AppBar(
        title: Text(
          "云端同步",
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
          const SettingsSectionTitle("WebDAV 服务配置"),
          SettingsCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildField(
                  ext,
                  controller: _serverController,
                  label: '服务器地址',
                  hint: 'https://dav.jianguoyun.com/dav/',
                ),
                const SizedBox(height: 12),
                _buildField(
                  ext,
                  controller: _accountController,
                  label: '账号',
                  hint: '登录账号（如邮箱）',
                ),
                const SizedBox(height: 12),
                _buildField(
                  ext,
                  controller: _passwordController,
                  label: '应用密码',
                  hint: '坚果云在「账户信息 → 安全选项」生成',
                  obscureText: _obscurePassword,
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscurePassword
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                      size: 20,
                    ),
                    onPressed: () =>
                        setState(() => _obscurePassword = !_obscurePassword),
                  ),
                ),
                const SizedBox(height: 12),
                _buildField(
                  ext,
                  controller: _remotePathController,
                  label: '远端目录（网盘上的存放位置）',
                  hint: CloudSyncConfig.defaultRemotePath,
                ),
                const SizedBox(height: 14),
                buildSettingsPrimaryButton(
                  context,
                  icon: Icons.save_rounded,
                  label: '保存配置',
                  onPressed: _busy ? null : _saveConfig,
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          const SettingsSectionTitle("同步"),
          SettingsCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _lastSyncText == null ? '尚未同步过' : '上次同步：$_lastSyncText',
                  style: TextStyle(fontSize: 13, color: ext.textSecondary),
                ),
                if (_hasPending) ...[
                  const SizedBox(height: 6),
                  Text(
                    '⚠️ 本地有新增数据，尚未同步到云端',
                    style: TextStyle(fontSize: 12, color: ext.warningText),
                  ),
                ],
                if (_requestCounter != null) ...[
                  const SizedBox(height: 10),
                  WebDavBudgetLine(counter: _requestCounter),
                ],
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: buildSettingsSecondaryButton(
                        context,
                        icon: Icons.wifi_tethering_rounded,
                        label: '测试连接',
                        onPressed: _busy ? null : _testConnection,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: buildSettingsPrimaryButton(
                        context,
                        icon: Icons.sync_rounded,
                        label: '立即同步',
                        busy: _busy,
                        onPressed: _busy || !_formConfigured ? null : _runSync,
                      ),
                    ),
                  ],
                ),
                if (_resultMessage != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _resultMessage!,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.5,
                      color: _resultOk ? ext.primary : ext.warningText,
                    ),
                  ),
                  for (final d in _resultDetails)
                    Padding(
                      padding: const EdgeInsets.only(left: 12, top: 4),
                      child: Text(
                        '· $d',
                        style: TextStyle(
                          fontSize: 12,
                          color: ext.textSecondary,
                        ),
                      ),
                    ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),
          // 录音同步开关：独立于「保存配置」按钮即时生效。默认关——WAV
          // 约 2MB/分钟，开启意味着用户显式接受网盘流量与空间的占用
          SettingsCard(
            child: ext.isNeumorphic
                // 拟物主题：凹槽开关（与设置页其他开关同款）；其余主题保持
                // 历史 SwitchListTile（开关在右）布局，渲染路径零变化
                ? NeuSwitchTile(
                    title: Text(
                      '同步录音文件',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: ext.textPrimary,
                      ),
                    ),
                    subtitle: Text(
                      '关闭时只同步文字。开启后录音分批上传/下载'
                      '（每次最多 80 条，其余下次同步续传）；'
                      'WAV 约 2MB/分钟，注意网盘流量与空间',
                      style: TextStyle(fontSize: 12, color: ext.textSecondary),
                    ),
                    value: _syncAudio,
                    onChanged: (v) {
                      setState(() => _syncAudio = v);
                      CloudSyncConfig.saveSyncAudio(v);
                    },
                  )
                : SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _syncAudio,
                    onChanged: (v) {
                      setState(() => _syncAudio = v);
                      CloudSyncConfig.saveSyncAudio(v);
                    },
                    activeColor: ext.primary,
                    title: Text(
                      '同步录音文件',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: ext.textPrimary,
                      ),
                    ),
                    subtitle: Text(
                      '关闭时只同步文字。开启后录音分批上传/下载'
                      '（每次最多 80 条，其余下次同步续传）；'
                      'WAV 约 2MB/分钟，注意网盘流量与空间',
                      style: TextStyle(fontSize: 12, color: ext.textSecondary),
                    ),
                  ),
          ),
          const SizedBox(height: 24),
          const SettingsSectionTitle("说明"),
          SettingsCard(
            child: Text(
              '· 支持任何 WebDAV 网盘：坚果云（网页端「账户信息 → 安全选项」'
              '生成应用密码）、Nextcloud、Alist 等\n'
              '· 同步内容：日记文字与截图附件、物品记录、热词、修正对；两台设备各自'
              '新增的内容会互相补齐\n'
              '· 录音文件默认不同步，打开「同步录音文件」开关后两台设备'
              '的录音会互相补齐（新设备恢复时逐条下载）\n'
              '· 手动触发：本页点「立即同步」，或在随手记列表、悬浮窗面板下拉刷新；'
              'App 不会自动联网同步\n'
              '· 日记的修改与删除会同步到其他设备；同一条两端同时改过会保留'
              '两份（多出的那份带「冲突」标记）\n'
              '· 物品记录只补齐新增，本机删除过的不会被云端拉回\n'
              '· 密码保存在系统安全存储中，不上传到任何服务器',
              style: TextStyle(fontSize: 12, color: ext.textHint, height: 1.6),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildField(
    AppThemeExtension ext, {
    required TextEditingController controller,
    required String label,
    required String hint,
    bool obscureText = false,
    Widget? suffixIcon,
  }) {
    final neu = ext.isNeumorphic;
    return buildSettingsFieldShell(
      context,
      // 拟物：标签画在凹陷外（浮动标签会压在上沿、被内阴影切半截）
      label: neu ? label : null,
      field: TextField(
        controller: controller,
        obscureText: obscureText,
        autocorrect: false,
        enableSuggestions: false,
        decoration: InputDecoration(
          // 拟物主题由外层 NeuInset 提供同色凹陷底，填充会盖住内阴影
          filled: !neu,
          fillColor: ext.cardBackground,
          labelText: neu ? null : label,
          labelStyle: TextStyle(color: ext.textSecondary, fontSize: 13),
          hintText: hint,
          hintStyle: TextStyle(color: ext.textHint, fontSize: 13),
          suffixIcon: suffixIcon,
          contentPadding: const EdgeInsets.all(16),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(15),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }
}
