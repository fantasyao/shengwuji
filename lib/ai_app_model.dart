// AI 应用数据模型
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class AIApp {
  final String id;
  final String name;
  final String packageName; // Android 包名
  final String scheme; // URL scheme（备用）
  final String url; // Web URL（兜底）
  final String icon;

  const AIApp({
    required this.id,
    required this.name,
    required this.packageName,
    this.scheme = '',
    this.url = '',
    this.icon = '📱',
  });

  /// 所有可用的 AI 应用列表
  static const List<AIApp> allApps = [
    AIApp(
      id: 'chatgpt',
      name: 'ChatGPT',
      packageName: 'com.openai.chatgpt',
      scheme: 'chatgpt://new-chat',
      url: 'https://chat.openai.com/',
      icon: '🤖',
    ),
    AIApp(
      id: 'deepseek',
      name: 'DeepSeek',
      packageName: 'com.deepseek.chat',
      scheme: 'deepseek://chat',
      url: 'https://chat.deepseek.com/',
      icon: '🧠',
    ),
    AIApp(
      id: 'kimi',
      name: 'Kimi',
      packageName: 'com.moonshot.kimichat',
      scheme: 'kimi://chat',
      url: 'https://kimi.moonshot.cn/',
      icon: '🌙',
    ),
    AIApp(
      id: 'wechat',
      name: '微信',
      packageName: 'com.tencent.mm',
      scheme: 'weixin://',
      url: 'https://weixin.qq.com/',
      icon: '💬',
    ),
  ];

  /// 根据 ID 查找应用（仅内置列表，自定义应用走 [resolveAppById]）
  static AIApp? findById(String id) {
    try {
      return allApps.firstWhere((app) => app.id == id);
    } catch (e) {
      return null;
    }
  }

  /// 获取默认应用（ChatGPT）
  static AIApp get defaultApp => allApps[0];

  // --- 自定义应用（zcode: 2026-09 二级页 + 号添加任意已安装应用，上限 3 个）---
  // prefs 存 JSON 数组字符串；id 用 'custom_' 前缀 + 包名，天然不与内置 id 冲突

  static const int maxCustomApps = 3;
  static const String customAppsPrefsKey = 'custom_ai_apps';

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'packageName': packageName,
  };

  factory AIApp.fromJson(Map<String, dynamic> json) => AIApp(
    id: json['id'] as String,
    name: json['name'] as String,
    packageName: json['packageName'] as String,
  );

  /// 从 prefs 读取自定义应用列表；脏数据（非 JSON/字段缺失）逐条跳过不抛错
  static Future<List<AIApp>> loadCustomApps() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(customAppsPrefsKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List;
      final apps = <AIApp>[];
      for (final e in list) {
        if (e is! Map) continue;
        try {
          apps.add(AIApp.fromJson(e.cast<String, dynamic>()));
        } catch (_) {
          // 单条脏数据跳过，不影响其余条目
        }
      }
      return apps;
    } catch (_) {
      return [];
    }
  }

  static Future<void> saveCustomApps(List<AIApp> apps) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      customAppsPrefsKey,
      jsonEncode(apps.map((a) => a.toJson()).toList()),
    );
  }

  /// 添加自定义应用。返回 null 表示成功，否则返回给用户看的失败原因。
  /// 查重三道：内置列表已含该包名 / 自定义已添加 / 超出 3 个上限。
  static Future<String?> addCustomApp(String name, String packageName) async {
    if (allApps.any((a) => a.packageName == packageName)) {
      return '「$name」已在应用列表中';
    }
    final custom = await loadCustomApps();
    if (custom.any((a) => a.packageName == packageName)) {
      return '「$name」已添加过';
    }
    if (custom.length >= maxCustomApps) {
      return '最多添加 $maxCustomApps 个应用';
    }
    custom.add(AIApp(id: 'custom_$packageName', name: name, packageName: packageName));
    await saveCustomApps(custom);
    return null;
  }

  static Future<void> removeCustomApp(AIApp app) async {
    final custom = await loadCustomApps();
    custom.removeWhere((a) => a.packageName == app.packageName);
    await saveCustomApps(custom);
  }

  /// 按 ID 解析应用：内置优先，未命中再查自定义；都无（如已删除）返回 null。
  /// 分享跳转的读取方用本方法，调用方自行兜底 defaultApp。
  static Future<AIApp?> resolveAppById(String id) async {
    final builtin = findById(id);
    if (builtin != null) return builtin;
    if (!id.startsWith('custom_')) return null;
    final custom = await loadCustomApps();
    try {
      return custom.firstWhere((app) => app.id == id);
    } catch (e) {
      return null;
    }
  }
}
