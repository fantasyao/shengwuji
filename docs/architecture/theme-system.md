# 主题 / 皮肤系统

## 概述

声物记支持 5 套预设主题皮肤，所有颜色通过 `ThemeExtension` 统一收口。新增主题只需在注册表加一项，UI 自动跟随，无需逐文件改色。

| ID | 名称 | 种子色 | Pro | 说明 |
|---|---|---|---|---|
| `default_teal` | 默认青 | `#009688` | 否 | 精确还原旧版视觉的基准主题 |
| `warm_orange` | 暖橙 | `#E65100` | 否 | 暖色调主题 |
| `forest_green` | 墨绿 | `#2E7D32` | 否 | 森林绿主题 |
| `sky_blue` | 晴空蓝 | `#7CCAF4` | 是 | 浅色主题，主色背景上使用深蓝黑文字保证对比度 |
| `neumorphism` | 新拟物 | `#009688` | 是 | 经典拟物灰底（2026-09-17 新增；2026-09-19 Pro 化），组件用双向凸/凹阴影 |

> 历史 handoff 中曾为"黑金"主题，后根据用户反馈替换为"晴空蓝"，但 Pro 门禁逻辑不变。
> 新拟物主题的不变量（scaffoldBackground == cardBackground == surface）与组件库见 `lib/widgets/neu_widgets.dart` 头注释；悬浮窗不适用本主题（透明窗口裁剪外扩散阴影，overlay_app.dart 有降级逻辑）。

## 核心组件

### AppThemeExtension — 语义化色槽

**文件**: [lib/theme/app_theme_extension.dart](../../lib/theme/app_theme_extension.dart)

定义 25 个语义化色槽，按用途命名而非按颜色命名：

- **基础语义**: `primary`, `primaryLight`, `primaryDark`, `surface`, `cardBackground`, `scaffoldBackground`
- **文字**: `textPrimary`, `textSecondary`, `textHint`, `textOnPrimary`
- **功能色**: `positiveAccent`, `positiveText`, `warningAccent`, `warningText`, `dangerAccent`, `timeHighlight`, `timeHighlightBg`
- **特殊色**: `splashBackground`, `splashGradient`, `splashGlow`, `goldAccent`, `goldLight`, `goldBorder`
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
    → theme.isPro 时 await ProGate.tryAccess(context)：不可用弹 ProUnlockDialog
      （试用激活/输码成功返回 true 继续应用；失败留在选择器）
    → prefs.setString('selected_theme', theme.id)
    → AppRoot.themeNotifier.value = theme
    → 全树重建，所有取 ext 的组件颜色更新
```

启动恢复（main.dart）：Pro 主题且不可用（试用过期/未解锁）→ 回退 `default_teal` 并写回 prefs，首帧 SnackBar 提示一次（"下次启动回退"策略，当次会话不中断）。

## 自定义主题（2026-09-22 新增，Pro 专属）

**文件**: [lib/theme/custom_theme.dart](../../lib/theme/custom_theme.dart)（配置 + 色系派生）、[lib/settings/custom_theme_page.dart](../../lib/settings/custom_theme_page.dart)（编辑页）

用户从选色盘挑一个**主色**（选中背景色的来源），app 自动派生一套推荐色系；背景色 / 按钮色 / 选中背景色三项可各自用选色盘**覆盖**推荐值（允许反差搭配，观感由用户负责）。存储与加载：

- 配置只存 `seed` + 三个可选覆盖的 int 色值（prefs key `custom_theme_data`，JSON），**不存派生结果**——派生规则调整后旧配置按新规则自动重建，无需迁移
- `selected_theme == 'custom'` 时主 App 启动链与悬浮窗 `_loadTheme` 都经 `loadThemeById()` 现建主题（`AppThemeDefinition(id: 'custom', isPro: true)`），坏配置/缺失返回 null 由调用方兜底默认青
- Pro 门禁完全复用既有链：未解锁/试用过期时启动自动回退默认青，入口卡点击走 `ProGate.tryAccess`

派生策略（`generateCustomTheme`，纯函数，对齐既有预设惯例）：

| 槽位 | 规则 |
|---|---|
| `scaffoldBackground` | 主色极浅低饱和同色调（L 0.965 / S ≤0.12） |
| `primaryLight`（选中背景） | 主色浅化（L 0.82 / S 减半封顶 0.55） |
| `primaryDark` / `timeHighlight` | 主色加深（L ×0.72 封顶 0.45）；暖橙/墨绿预设先例：高亮跟随主色 |
| `textOnPrimary` | WCAG 对比度 ≥3.0 用白字，否则主色深版（L 0.13，晴空蓝深蓝黑先例） |
| `fabReady`（推荐按钮色） | 主色 L >0.55（过浅，白图标不可读）时自动落到 `primaryDark` |
| `positiveAccent/Text`、`timeHighlightBg`、`splashBackground` | 同色系浅化/深化（splash L 0.14~0.30 避免黑底破坏调性） |
| warning/danger/gold/fab 录音红·处理橙·禁用灰 | **固定不跟随**（5 套预设一致的惯例） |
| 拟物 | 恒 `isNeumorphic=false`，悬浮窗无需拟物降级 |

交互约定：主题选择 sheet 网格末尾追加"自定义"卡（有配置=派生色槽预览+Pro 徽章，复用 `_buildThemeCard`；无配置=虚线创建入口）；点击**不直接切主题**，先过 Pro 门禁再进编辑页，应用动作统一在编辑页"使用此主题"完成（避免点击语义二义），pop(true)=已应用才关 sheet。编辑页内换主色会清空三项微调（推荐色系随新主色重新生成）；删除自定义主题时若正在使用则回退默认青。

测试：`test/custom_theme_test.dart`（派生关系/对比度切换/覆盖生效/恢复推荐/JSON 往返/加载链兜底，19 例）。已知物理舍入：极浅背景（L≈0.97）RGB 8bit 量化可折算十几度色相抖动，测试色相断言容差 25°。

## 启动页配色（2026-09-24 重设计）

方案 B「深海极光」（用户从配色预览选定）：默认主题新增 `splashGradient`（深海三段渐变 `#0D1B2E→#13253C→#16304A`）与 `splashGlow`（图标区冷蓝辉光 `#5A5E9EDC` 径向淡出），其余主题维持各自纯色 `splashBackground` 回落；`splashBackground` 在默认主题降级为兜底纯色（渐变层之下/系统导航栏区域）+ 授权按钮文字色。装饰槽 lerp 按 t<0.5 取自身（与 bool 槽同策略，不做逐色插值）。配套：启动页图标 `assets/icon/icon2.png` 由薄荷绿渐变底重制为藏青 `#2C3E50` 底（与桌面图标同源，脚本 `test/design_preview/recolor_icon_navy.py` 可复现）；Android 12+ 系统启动画面背景 `#0D1B2E`（`values-v31/styles.xml`，与 Flutter 渐变起始色衔接）。详见 `lib/splash_screen.dart` 的 `SplashShell` 与 `test/splash_theme_test.dart`（8 例）。

## Pro 门禁

**文件**: [lib/utils/pro_gate.dart](../../lib/utils/pro_gate.dart)、[pro-license.md](pro-license.md)（授权体系权威文档）

- `ProGate.tryAccess(context)`：Pro 不可用（未解锁且试用过期）时弹 `ProUnlockDialog`，返回弹窗关闭时 Pro 是否已可用（试用激活或输码成功为 true）
- `ProGate.isProActive()`：永久解锁（`is_pro_unlocked`）或试用中（`pro_trial_deadline_ms` 未到）任一满足
- 主题选择 UI 中，Pro 主题卡片右上角显示金色 "Pro" 徽章
- Pro 主题：晴空蓝、新拟物（2026-09-19 起）

## 设计原则

1. **命名按用途**：如 `positiveAccent` 表示"积极反馈背景"，而非 `lightTeal`
2. **一对一映射**：迁移期每个语义槽与旧硬编码颜色一对一映射，保证默认主题视觉无差异
3. **透明度动态计算**：透明度变体用 `ext.xxx.withValues(alpha:)` 动态生成，不新增色槽
4. **品牌/警示色保留**：Pro 金色、闹钟横幅红色等语义不随主题变化，保留原硬编码

## 关键文件

- [lib/theme/app_theme_extension.dart](../../lib/theme/app_theme_extension.dart) - 语义化色槽
- [lib/theme/app_theme.dart](../../lib/theme/app_theme.dart) - 主题定义注册表
- [lib/theme/custom_theme.dart](../../lib/theme/custom_theme.dart) - 自定义主题（配置存取 + 色系派生）
- [lib/settings/custom_theme_page.dart](../../lib/settings/custom_theme_page.dart) - 自定义主题编辑页（选色盘）
- [lib/main.dart](../../lib/main.dart) - `AppRoot.themeNotifier` 全局切换
- [lib/utils/pro_gate.dart](../../lib/utils/pro_gate.dart) - Pro 门禁
- [lib/settings_tab.dart](../../lib/settings_tab.dart) - 主题选择 UI

## 相关文档

- [ui-patterns.md](../guides/ui-patterns.md#外观设置) - 外观设置 UI 说明
- [icon-pack-switching.md](icon-pack-switching.md) - Android 图标包切换
- [pro-license.md](pro-license.md) - Pro 授权码体系 + 7 天试用
