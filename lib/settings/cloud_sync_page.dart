import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../db_helper.dart';
import '../sync/cloud_sync_service.dart';
import '../text_processor.dart';
import '../theme/app_theme_extension.dart';
import '../utils/cloud_sync_data_version.dart'; // 待同步检测
import 'settings_widgets.dart';

/// 「云端同步」二级页（设置 → 云端同步）。
///
/// WebDAV 手动同步：日记（文字）/物品记录/热词/修正对 新增条目双向合并。
/// 边界：手动触发、编辑与删除不跨端；录音文件走独立开关默认不同步
/// （见页内说明与 docs/architecture/cloud-sync.md）。
class CloudSyncPage extends StatefulWidget {
  const CloudSyncPage({
    super.key,
    required this.processor,
    required this.dbHelper,
  });

  final TextProcessor processor;
  final DbHelper dbHelper;

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

  late final CloudSyncService _service = CloudSyncService(
    dbHelper: widget.dbHelper,
    processor: widget.processor,
  );

  @override
  void initState() {
    super.initState();
    _loadConfig();
    _loadLastSync();
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
      _resultMessage = result.ok ? '✅ ${result.message}' : '❌ ${result.message}';
      _resultDetails = result.details;
    });
    _loadLastSync();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result.ok ? '✅ ${result.message}' : '❌ ${result.message}'),
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
                TextField(
                  controller: _passwordController,
                  obscureText: _obscurePassword,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: ext.cardBackground,
                    labelText: '应用密码',
                    labelStyle: TextStyle(color: ext.textSecondary, fontSize: 13),
                    hintText: '坚果云在「账户信息 → 安全选项」生成',
                    hintStyle: TextStyle(color: ext.textHint, fontSize: 13),
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
                    contentPadding: const EdgeInsets.all(16),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(15),
                      borderSide: BorderSide.none,
                    ),
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
                ElevatedButton.icon(
                  onPressed: _busy ? null : _saveConfig,
                  icon: const Icon(Icons.save_rounded, size: 20),
                  label: const Text(
                    '保存配置',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: ext.primary,
                    foregroundColor: ext.textOnPrimary,
                    elevation: 0,
                    minimumSize: const Size.fromHeight(46),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
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
                  _lastSyncText == null
                      ? '尚未同步过'
                      : '上次同步：$_lastSyncText',
                  style: TextStyle(fontSize: 13, color: ext.textSecondary),
                ),
                if (_hasPending) ...[
                  const SizedBox(height: 6),
                  Text(
                    '⚠️ 本地有新增数据，尚未同步到云端',
                    style: TextStyle(fontSize: 12, color: ext.warningText),
                  ),
                ],
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _busy ? null : _testConnection,
                        icon: const Icon(Icons.wifi_tethering_rounded, size: 20),
                        label: const Text('测试连接'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: ext.primary,
                          side: BorderSide(color: ext.primary),
                          minimumSize: const Size.fromHeight(46),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: _busy || !_formConfigured ? null : _runSync,
                        icon: _busy
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.sync_rounded, size: 20),
                        label: const Text(
                          '立即同步',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: ext.primary,
                          foregroundColor: ext.textOnPrimary,
                          disabledBackgroundColor:
                              ext.primary.withValues(alpha: 0.4),
                          disabledForegroundColor: ext.textOnPrimary,
                          elevation: 0,
                          minimumSize: const Size.fromHeight(46),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
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
                        style: TextStyle(fontSize: 12, color: ext.textSecondary),
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
            child: SwitchListTile(
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
              '· 同步内容：日记文字、物品记录、热词、修正对；两台设备各自'
              '新增的内容会互相补齐\n'
              '· 录音文件默认不同步，打开「同步录音文件」开关后两台设备'
              '的录音会互相补齐（新设备恢复时逐条下载）\n'
              '· 手动触发：进入本页点「立即同步」才会同步，App 不会自动联网\n'
              '· 本机删除过的记录不会被云端拉回；编辑内容暂不同步\n'
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
  }) {
    return TextField(
      controller: controller,
      autocorrect: false,
      enableSuggestions: false,
      decoration: InputDecoration(
        filled: true,
        fillColor: ext.cardBackground,
        labelText: label,
        labelStyle: TextStyle(color: ext.textSecondary, fontSize: 13),
        hintText: hint,
        hintStyle: TextStyle(color: ext.textHint, fontSize: 13),
        contentPadding: const EdgeInsets.all(16),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(15),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}
