/// AI 应用数据模型
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
    required this.scheme,
    required this.url,
    required this.icon,
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

  /// 根据 ID 查找应用
  static AIApp? findById(String id) {
    try {
      return allApps.firstWhere((app) => app.id == id);
    } catch (e) {
      return null;
    }
  }

  /// 获取默认应用（ChatGPT）
  static AIApp get defaultApp => allApps[0];
}
