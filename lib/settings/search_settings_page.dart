import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/app_theme_extension.dart';
import '../utils/big_bang_search.dart';
import 'settings_widgets.dart';

/// 「大爆炸搜索」二级页：搜索引擎三选一 + 用什么浏览器打开（系统默认/已安装
/// 浏览器单选）。浏览器列表与图标走 com.shengwuji.app/app 通道的
/// getInstalledBrowsers / getAppIcon（契约见并行开发约定）
class SearchSettingsPage extends StatefulWidget {
  const SearchSettingsPage({super.key});

  @override
  State<SearchSettingsPage> createState() => _SearchSettingsPageState();
}

class _SearchSettingsPageState extends State<SearchSettingsPage>
    with WidgetsBindingObserver {
  static const _channel = MethodChannel('com.shengwuji.app/app');

  SearchEngine _engine = SearchEngine.baidu;
  // 浏览器选择：空串 = 系统默认（包名是选择真值；名称只进 prefs 供主页摘要显示）
  String _browserPackage = '';

  final Map<String, Uint8List?> _iconCache = {}; // null = 加载失败，不再重试
  List<_BrowserApp>? _browsers; // null = 加载中
  bool _loadFailed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadPrefs();
    _loadBrowsers();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // 照 ai_app_page _AppPickerSheet 的 MIUI 兜底：ROM 层「读取应用列表」权限
  // 弹窗首查返回空，授权回来不会重新 initState，列表为空时趁 resumed 自动重查
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        _browsers != null &&
        _browsers!.isEmpty) {
      _loadBrowsers();
    }
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _engine = parseSearchEngine(prefs.getString(kSearchEngineKey));
      _browserPackage = prefs.getString(kSearchBrowserPackageKey) ?? '';
    });
  }

  Future<void> _saveEngine(SearchEngine engine) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kSearchEngineKey, engine.name);
    setState(() => _engine = engine);
    print('🔧 [Settings] search_engine=${engine.name}');
  }

  Future<void> _saveBrowser(String packageName, String appName) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kSearchBrowserPackageKey, packageName);
    await prefs.setString(kSearchBrowserNameKey, appName);
    setState(() => _browserPackage = packageName);
    print('🔧 [Settings] search_browser=$packageName($appName)');
  }

  Future<void> _loadBrowsers() async {
    try {
      final raw = await _channel.invokeListMethod<dynamic>(
        'getInstalledBrowsers',
      );
      final browsers = (raw ?? [])
          .whereType<Map>()
          .map(
            (e) => _BrowserApp(
              e['appName'] as String? ?? '',
              e['packageName'] as String? ?? '',
            ),
          )
          .where((b) => b.packageName.isNotEmpty)
          .toList();
      if (mounted) {
        setState(() {
          _browsers = browsers;
          _loadFailed = false;
        });
      }
    } catch (e) {
      print("⚠️ [SearchSettings] 获取浏览器列表失败: $e");
      if (mounted) {
        setState(() {
          _browsers = [];
          _loadFailed = true;
        });
      }
    }
  }

  Future<Uint8List?> _loadIcon(String packageName) async {
    if (_iconCache.containsKey(packageName)) return _iconCache[packageName];
    try {
      final bytes = await _channel.invokeMethod<Uint8List>('getAppIcon', {
        'packageName': packageName,
      });
      _iconCache[packageName] = bytes;
    } catch (e) {
      _iconCache[packageName] = null;
    }
    return _iconCache[packageName];
  }

  @override
  Widget build(BuildContext context) {
    final ext = AppThemeExtension.of(context);
    return Scaffold(
      backgroundColor: ext.scaffoldBackground,
      appBar: AppBar(
        title: Text(
          "大爆炸搜索",
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
          const SettingsSectionTitle("搜索引擎"),
          SettingsCard(child: _buildEngineSelector()),
          const SizedBox(height: 24),
          const SettingsSectionTitle("用什么浏览器打开"),
          SettingsCard(child: _buildBrowserSection(ext)),
        ],
      ),
    );
  }

  Widget _buildEngineSelector() {
    // 显示名取 searchEngines 注册表唯一真值（lib/utils/big_bang_search.dart）
    final options = SearchEngine.values;
    return Wrap(
      spacing: 8,
      runSpacing: 6,
      children: options.map((engine) {
        final label = searchEngines[engine]!.label;
        const icon = Icons.search;
        final selected = _engine == engine;
        return buildSettingsChoiceChip(
          context,
          icon: icon,
          label: Text(label),
          selected: selected,
          onTap: () => _saveEngine(engine),
        );
      }).toList(),
    );
  }

  Widget _buildBrowserSection(AppThemeExtension ext) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 系统默认恒为首行（浏览器列表加载中/失败也可选）
        _buildBrowserRow(ext, packageName: '', appName: '系统默认'),
        if (_browsers == null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_browsers!.isEmpty)
          _buildBrowserEmptyState(ext)
        else
          ..._browsers!.map(
            (b) => _buildBrowserRow(
              ext,
              packageName: b.packageName,
              appName: b.appName,
            ),
          ),
      ],
    );
  }

  /// 空态：查询失败可重试 / 查到 0 个（ROM 权限拦截兜底，resumed 自动重查
  /// 万一仍为空时给手动出口）——照 ai_app_page _AppPickerSheet 三分支
  Widget _buildBrowserEmptyState(AppThemeExtension ext) {
    final message = _loadFailed ? "获取浏览器列表失败，请重试" : "未获取到已安装的浏览器";
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message, style: TextStyle(fontSize: 14, color: ext.textHint)),
            const SizedBox(height: 12),
            TextButton(onPressed: _loadBrowsers, child: const Text('重新加载')),
          ],
        ),
      ),
    );
  }

  Widget _buildBrowserRow(
    AppThemeExtension ext, {
    required String packageName,
    required String appName,
  }) {
    final isSelected = _browserPackage == packageName;
    return InkWell(
      onTap: () => _saveBrowser(packageName, appName),
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
        child: Row(
          children: [
            packageName.isEmpty
                ? Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: Theme.of(
                        context,
                      ).dividerColor.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      Icons.public,
                      size: 22,
                      color: ext.textSecondary,
                    ),
                  )
                : _BrowserIcon(packageName: packageName, loader: _loadIcon),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                appName,
                style: TextStyle(fontSize: 15, color: ext.textPrimary),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (isSelected)
              Icon(Icons.check_circle, size: 20, color: ext.primary),
          ],
        ),
      ),
    );
  }
}

/// 浏览器条目数据（Kotlin getInstalledBrowsers 返回的 Map 转出）
class _BrowserApp {
  final String appName;
  final String packageName;
  const _BrowserApp(this.appName, this.packageName);
}

/// 浏览器图标：异步加载 PNG 字节，失败/未加载显示通用占位
/// （照 ai_app_page _AppIcon 模式）
class _BrowserIcon extends StatelessWidget {
  final String packageName;
  final Future<Uint8List?> Function(String) loader;

  const _BrowserIcon({required this.packageName, required this.loader});

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
          child: const Icon(Icons.public, size: 22),
        );
      },
    );
  }
}
