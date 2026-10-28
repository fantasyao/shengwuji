/// 全 App 字体选择（主 App 与悬浮窗共用）
///
/// 霞鹜文楷与整体观感不搭时（用户反馈），可切到系统默认字体。/// 「系统默认」= Flutter/Android 平台默认字体（Roboto 系），不是跟随手机
/// 系统设置里的自定义字体——后者需原生探测，各厂商支持不一致。
enum AppFontChoice {
  wenkai('wenkai', '霞鹜文楷', 'LXGWWenKaiMonoGBScreen'),
  system('system', '系统默认', null);

  const AppFontChoice(this.id, this.label, this.fontFamily);

  /// 持久化用的唯一 ID（prefs `app_font_family`）
  final String id;

  /// 设置页展示名
  final String label;

  /// ThemeData / TextTheme 使用的字体名；null = 平台默认字体
  final String? fontFamily;
}

/// prefs key：字体选择（主 App 写，悬浮窗独立 engine 读）
const kAppFontPrefKey = 'app_font_family';

/// 默认字体保持霞鹜文楷（新选项不改变老用户视觉）
const kDefaultAppFontChoice = AppFontChoice.wenkai;

/// 解析字体偏好：null/旧版本/坏串一律回退霞鹜文楷
AppFontChoice parseAppFontChoice(String? raw) => switch (raw) {
  'system' => AppFontChoice.system,
  _ => kDefaultAppFontChoice,
};
