import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ai_app_model.dart';
import 'settings_widgets.dart';
import '../theme/app_theme_extension.dart';

/// 「AI 应用分享」二级页（zcode: 2026-09 设置页下沉——原主页单选列表整体搬入，
/// prefs key 'selected_ai_app' 与日记分享跳转读取方不变；
/// 2026-09 底部 + 号支持添加任意已安装应用为跳转目标，上限 AIApp.maxCustomApps=3，
/// 自定义列表存 prefs 'custom_ai_apps'，跳转侧 diary_tab._shareToAI 走 resolveAppById）
class AIAppPage extends StatefulWidget {
  const AIAppPage({super.key});

  @override
  State<AIAppPage> createState() => _AIAppPageState();
}

class _AIAppPageState extends State<AIAppPage> {
  String _selectedAIAppId = AIApp.defaultApp.id;
  List<AIApp> _customApps = [];

  @override
  void initState() {
    super.initState();
    _loadAIAppPreference();
  }

  void _loadAIAppPreference() async {
    final prefs = await SharedPreferences.getInstance();
    final appId = prefs.getString('selected_ai_app');
    final custom = await AIApp.loadCustomApps();
    if (mounted) {
      setState(() {
        _selectedAIAppId = appId ?? AIApp.defaultApp.id;
        _customApps = custom;
      });
    }
  }

  Future<void> _saveAIAppPreference(String appId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('selected_ai_app', appId);
    setState(() => _selectedAIAppId = appId);

    // 显示保存成功提示（内置 findById，自定义从已加载列表取）
    if (mounted) {
      final matches = _customApps.where((a) => a.id == appId).toList();
      final app = AIApp.findById(appId) ?? (matches.isNotEmpty ? matches.first : null);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("已设置为 ${app?.name ?? '未知应用'}"),
          duration: const Duration(seconds: 1),
        ),
      );
    }
  }

  /// 删除自定义应用；若删的正是当前选中项，选中态回落默认 ChatGPT
  Future<void> _removeCustomApp(AIApp app) async {
    await AIApp.removeCustomApp(app);
    if (_selectedAIAppId == app.id) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('selected_ai_app', AIApp.defaultApp.id);
    }
    _loadAIAppPreference();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已移除 ${app.name}'),
          duration: const Duration(seconds: 1),
        ),
      );
    }
  }

  /// 底部 + 号：满员拦截，否则弹出应用选择器，选中后写入自定义列表
  Future<void> _addCustomApp() async {
    if (_customApps.length >= AIApp.maxCustomApps) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('最多添加 ${AIApp.maxCustomApps} 个应用，请先移除后再添加'),
          duration: const Duration(seconds: 2),
        ),
      );
      return;
    }
    final picked = await showModalBottomSheet<_InstalledApp>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => const _AppPickerSheet(),
    );
    if (picked == null) return;
    final error = await AIApp.addCustomApp(picked.appName, picked.packageName);
    if (!mounted) return;
    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error), duration: const Duration(seconds: 2)),
      );
      return;
    }
    _loadAIAppPreference();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已添加 ${picked.appName}'),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ext = AppThemeExtension.of(context);
    final allSelectable = [...AIApp.allApps, ..._customApps];
    final isFull = _customApps.length >= AIApp.maxCustomApps;
    return Scaffold(
      backgroundColor: ext.scaffoldBackground,
      appBar: AppBar(
        title: Text(
          "AI 应用分享",
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
          SettingsCard(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "选择日记分享时跳转的 AI 应用",
                  style: TextStyle(fontSize: 14, color: ext.textHint),
                ),
                const SizedBox(height: 16),
                // 单选列表（内置 + 自定义）
                ...allSelectable.map((app) {
                  final isCustom = app.id.startsWith('custom_');
                  return _buildAppRow(ext, app, isCustom);
                }),
                const SizedBox(height: 8),
                // 分隔线 + 底部添加入口（最多 3 个，满员置灰）
                Divider(height: 1, color: ext.divider),
                const SizedBox(height: 8),
                InkWell(
                  onTap: isFull ? null : _addCustomApp,
                  borderRadius: BorderRadius.circular(12),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: 12,
                      horizontal: 8,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.add_circle_outline,
                          size: 22,
                          color: isFull ? ext.textHint : ext.primary,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            isFull
                                ? '自定义应用已满（${_customApps.length}/${AIApp.maxCustomApps}）'
                                : '添加应用（${_customApps.length}/${AIApp.maxCustomApps}）',
                            style: TextStyle(
                              fontSize: 15,
                              color: isFull ? ext.textHint : ext.primary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAppRow(AppThemeExtension ext, AIApp app, bool isCustom) {
    final isSelected = _selectedAIAppId == app.id;
    return InkWell(
      onTap: () => _saveAIAppPreference(app.id),
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
        child: Row(
          children: [
            // 单选圆圈
            Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: isSelected ? ext.primary : ext.textHint,
                  width: 2,
                ),
                color: isSelected ? ext.primary : ext.cardBackground,
              ),
              child: isSelected
                  ? Icon(Icons.check, size: 16, color: ext.textOnPrimary)
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
                style: TextStyle(fontSize: 16, color: ext.textPrimary),
              ),
            ),
            // 自定义应用显示包名 + 删除按钮；内置显示 URL 提示
            if (isCustom) ...[
              Flexible(
                child: Text(
                  app.packageName,
                  style: TextStyle(fontSize: 12, color: ext.textHint),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 4),
              InkWell(
                onTap: () => _removeCustomApp(app),
                borderRadius: BorderRadius.circular(12),
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Icon(Icons.close, size: 18, color: ext.textHint),
                ),
              ),
            ] else
              Text(
                app.url.replaceAll('https://', '').replaceAll('/', ''),
                style: TextStyle(fontSize: 12, color: ext.textHint),
                overflow: TextOverflow.ellipsis,
              ),
          ],
        ),
      ),
    );
  }
}

/// 选择器条目数据（Kotlin getInstalledApps 返回的 Map 转出）
class _InstalledApp {
  final String appName;
  final String packageName;
  const _InstalledApp(this.appName, this.packageName);
}

/// 应用选择器底部弹窗：搜索过滤 + 真实图标懒加载；
/// 内置列表与已添加的自定义应用不重复出现
class _AppPickerSheet extends StatefulWidget {
  const _AppPickerSheet();

  @override
  State<_AppPickerSheet> createState() => _AppPickerSheetState();
}

class _AppPickerSheetState extends State<_AppPickerSheet> {
  static const _channel = MethodChannel('com.shengwuji.app/app');

  final TextEditingController _searchCtrl = TextEditingController();
  final Map<String, Uint8List?> _iconCache = {}; // null = 加载失败，不再重试
  List<_InstalledApp>? _apps; // null = 加载中
  bool _loadFailed = false;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _loadInstalledApps();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadInstalledApps() async {
    try {
      final raw = await _channel.invokeListMethod<dynamic>('getInstalledApps');
      final apps = (raw ?? [])
          .whereType<Map>()
          .map(
            (e) => _InstalledApp(
              e['appName'] as String? ?? '',
              e['packageName'] as String? ?? '',
            ),
          )
          .where((a) => a.packageName.isNotEmpty)
          .toList();
      if (mounted) setState(() => _apps = apps);
    } catch (e) {
      print("⚠️ [_AppPickerSheet] 获取应用列表失败: $e");
      if (mounted) {
        setState(() {
          _apps = [];
          _loadFailed = true;
        });
      }
    }
  }

  Future<Uint8List?> _loadIcon(String packageName) async {
    if (_iconCache.containsKey(packageName)) return _iconCache[packageName];
    try {
      final bytes = await _channel.invokeMethod<Uint8List>(
        'getAppIcon',
        {'packageName': packageName},
      );
      _iconCache[packageName] = bytes;
    } catch (e) {
      _iconCache[packageName] = null;
    }
    return _iconCache[packageName];
  }

  /// 过滤：搜索词（名称/包名不区分大小写）+ 排除内置与已添加的自定义应用
  List<_InstalledApp> _filtered(List<_InstalledApp> apps) {
    final excludePackages = {
      ...AIApp.allApps.map((a) => a.packageName),
    };
    final q = _query.trim().toLowerCase();
    return apps.where((a) {
      if (excludePackages.contains(a.packageName)) return false;
      if (q.isEmpty) return true;
      return a.appName.toLowerCase().contains(q) ||
          a.packageName.toLowerCase().contains(q);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final ext = AppThemeExtension.of(context);
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.75,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 8, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      "选择要添加的应用",
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.bold,
                        color: ext.textPrimary,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.close, color: ext.textHint),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
              child: TextField(
                controller: _searchCtrl,
                onChanged: (v) => setState(() => _query = v),
                decoration: InputDecoration(
                  hintText: "搜索应用名称或包名",
                  prefixIcon: Icon(Icons.search, color: ext.textHint),
                  isDense: true,
                  filled: true,
                  fillColor: ext.cardBackground,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            Expanded(
              child: _apps == null
                  ? const Center(child: CircularProgressIndicator())
                  : _filtered(_apps!).isEmpty
                  ? Center(
                      child: Text(
                        _loadFailed ? "获取应用列表失败，请重试" : "没有匹配的应用",
                        style: TextStyle(fontSize: 14, color: ext.textHint),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.only(bottom: 20),
                      itemCount: _filtered(_apps!).length,
                      itemBuilder: (context, index) {
                        final app = _filtered(_apps!)[index];
                        return InkWell(
                          onTap: () => Navigator.pop(context, app),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 20,
                              vertical: 10,
                            ),
                            child: Row(
                              children: [
                                _AppIcon(
                                  packageName: app.packageName,
                                  loader: _loadIcon,
                                ),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: Text(
                                    app.appName,
                                    style: TextStyle(
                                      fontSize: 15,
                                      color: ext.textPrimary,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 应用图标：异步加载 PNG 字节，失败/未加载显示通用占位
class _AppIcon extends StatelessWidget {
  final String packageName;
  final Future<Uint8List?> Function(String) loader;

  const _AppIcon({required this.packageName, required this.loader});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: loader(packageName),
      builder: (context, snapshot) {
        final data = snapshot.data;
        if (data != null && data.isNotEmpty) {
          return ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.memory(data, width: 40, height: 40),
          );
        }
        return Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: Theme.of(context).dividerColor.withValues(alpha: 0.3),
            borderRadius: BorderRadius.circular(10),
          ),
          child: const Icon(Icons.apps, size: 22),
        );
      },
    );
  }
}
