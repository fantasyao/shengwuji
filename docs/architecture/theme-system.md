# 主题 / 皮肤系统

## 概述

声物记支持 4 套预设主题皮肤，所有颜色通过 `ThemeExtension` 统一收口。新增主题只需在注册表加一项，UI 自动跟随，无需逐文件改色。

| ID | 名称 | 种子色 | Pro | 说明 |
|---|---|---|---|---|
| `default_teal` | 默认青 | `#009688` | 否 | 精确还原旧版视觉的基准主题 |
| `warm_orange` | 暖橙 | `#E65100` | 否 | 暖色调主题 |
| `forest_green` | 墨绿 | `#2E7D32` | 否 | 森林绿主题 |
| `sky_blue` | 晴空蓝 | `#7CCAF4` | 是 | 浅色主题，主色背景上使用深蓝黑文字保证对比度 |

> 历史 handoff 中曾为"黑金"主题，后根据用户反馈替换为"晴空蓝"，但 Pro 门禁逻辑不变。

## 核心组件

### AppThemeExtension — 语义化色槽

**文件**: [lib/theme/app_theme_extension.dart](../../lib/theme/app_theme_extension.dart)

定义 25 个语义化色槽，按用途命名而非按颜色命名：

- **基础语义**: `primary`, `primaryLight`, `primaryDark`, `surface`, `cardBackground`, `scaffoldBackground`
- **文字**: `textPrimary`, `textSecondary`, `textHint`, `textOnPrimary`
- **功能色**: `positiveAccent`, `positiveText`, `warningAccent`, `warningText`, `dangerAccent`, `timeHighlight`, `timeHighlightBg`
- **特殊色**: `splashBackground`, `goldAccent`, `goldLight`, `goldBorder`
- **浮动按钮**: `fabReady`, `fabRecording`, `fabProcessing`, `fabDisabled`
- **系统层**: `divider`, `isDarkOverlay`

使用方式：

```dart
final ext = AppThemeExtension.of(context);
return Container(color: ext.positiveAccent);
```

### AppThemeDefinition / AppThemes — 主题注册表

**文件**: [lib/theme/app_theme.dart](../../lib/theme/app_theme.dart)

- `AppThemeDefinition`：单套主题定义，含 ID、名称、种子色、是否 Pro、完整色槽
- `AppThemes.all`：所有预设主题列表，设置页自动遍历显示
- `AppThemes.defaultTheme`：首次启动默认主题
- `toThemeData()`：生成带霞鹜文楷字体的 `ThemeData`

### AppRoot — 全局切换入口

**文件**: [lib/main.dart](../../lib/main.dart)

- `AppRoot.themeNotifier` 是全局 `ValueNotifier<AppThemeDefinition>`
- 任意位置 `AppRoot.themeNotifier.value = newTheme` 即可触发整树重建
- `main()` 启动时从 `SharedPreferences` 的 `selected_theme` 读取并初始化

## 切换流程

```
设置页点击主题卡片
  → _onThemeTap(theme)
    → ProGate.tryAccess(theme.isPro) 拦截未解锁的 Pro 主题
    → prefs.setString('selected_theme', theme.id)
    → AppRoot.themeNotifier.value = theme
    → 全树重建，所有取 ext 的组件颜色更新
```

## Pro 门禁

**文件**: [lib/utils/pro_gate.dart](../../lib/utils/pro_gate.dart)

- `ProGate.tryAccess(context, isPro)`：若 `isPro=true` 且未解锁，调起 `ProUnlockDialog`
- 主题选择 UI 中，Pro 主题卡片右上角显示金色 "Pro" 徽章
- 晴空蓝主题为当前唯一的 Pro 主题

## 设计原则

1. **命名按用途**：如 `positiveAccent` 表示"积极反馈背景"，而非 `lightTeal`
2. **一对一映射**：迁移期每个语义槽与旧硬编码颜色一对一映射，保证默认主题视觉无差异
3. **透明度动态计算**：透明度变体用 `ext.xxx.withValues(alpha:)` 动态生成，不新增色槽
4. **品牌/警示色保留**：Pro 金色、闹钟横幅红色等语义不随主题变化，保留原硬编码

## 关键文件

- [lib/theme/app_theme_extension.dart](../../lib/theme/app_theme_extension.dart) - 语义化色槽
- [lib/theme/app_theme.dart](../../lib/theme/app_theme.dart) - 主题定义注册表
- [lib/main.dart](../../lib/main.dart) - `AppRoot.themeNotifier` 全局切换
- [lib/utils/pro_gate.dart](../../lib/utils/pro_gate.dart) - Pro 门禁
- [lib/settings_tab.dart](../../lib/settings_tab.dart) - 主题选择 UI

## 相关文档

- [ui-patterns.md](../guides/ui-patterns.md#外观设置) - 外观设置 UI 说明
- [icon-pack-switching.md](icon-pack-switching.md) - Android 图标包切换
