import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ai_app_model.dart';
import 'settings_widgets.dart';
import '../theme/app_theme_extension.dart';

/// 「AI 应用分享」二级页（zcode: 2026-09 设置页下沉——原主页单选列表整体搬入，
/// prefs key 'selected_ai_app' 与日记分享跳转读取方不变）
class AIAppPage extends StatefulWidget {
  const AIAppPage({super.key});

  @override
  State<AIAppPage> createState() => _AIAppPageState();
}

class _AIAppPageState extends State<AIAppPage> {
  String _selectedAIAppId = AIApp.defaultApp.id;

  @override
  void initState() {
    super.initState();
    _loadAIAppPreference();
  }

  void _loadAIAppPreference() async {
    final prefs = await SharedPreferences.getInstance();
    final appId = prefs.getString('selected_ai_app');
    if (mounted) {
      setState(() => _selectedAIAppId = appId ?? AIApp.defaultApp.id);
    }
  }

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

  @override
  Widget build(BuildContext context) {
    final ext = AppThemeExtension.of(context);
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
                                color: isSelected ? ext.primary : ext.textHint,
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
                            style: TextStyle(fontSize: 12, color: ext.textHint),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  );
                }),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
