# 主题 / 皮肤系统

## 概述

声物记支持 5 套预设主题皮肤，所有颜色通过 `ThemeExtension` 统一收口。新增主题只需在注册表加一项，UI 自动跟随，无需逐文件改色。2026-09-28 起另有一套**全 App 唯一的深色皮肤**（`dark_standard`），不进主题选择器，由「深色模式」三档设置驱动，见「深色模式」小节。

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

- `AppThemeDefinition`：单套主题定义，含 ID、名称、种子色、是否 Pro、亮度（`brightness`，浅色恒 light，深色主题专属 dark）、完整色槽
- `AppThemes.all`：所有预设主题列表（**只含浅色皮肤**），设置页自动遍历显示
- `AppThemes.defaultTheme`：首次启动默认主题
- `AppThemes.dark`：全 App 唯一深色皮肤，**不在 all 中**，只喂 `MaterialApp.darkTheme`（见下节）
- `toThemeData({font})`：生成 `ThemeData`（ColorScheme 亮度随 `brightness`）；字体由 `AppFontChoice` 决定，默认霞鹜文楷，见「字体选项」

### AppRoot — 全局切换入口

**文件**: [lib/main.dart](../../lib/main.dart)

- `AppRoot.themeNotifier` 是全局 `ValueNotifier<AppThemeDefinition>`
- 任意位置 `AppRoot.themeNotifier.value = newTheme` 即可触发整树重建
- `main()` 启动时从 `SharedPreferences` 的 `selected_theme` 读取并初始化
- `AppRoot.themeModeNotifier` 是全局 `ValueNotifier<ThemeMode>`（深浅三档，见下节），`main()` 启动时从 `theme_mode` 读取
- `AppRoot.fontChoiceNotifier` 是全局 `ValueNotifier<AppFontChoice>`（字体档，见「字体选项」），`main()` 启动时从 `app_font_family` 读取

## 深色模式（2026-09-28 新增）

用户拍板：**只做一套标准深色皮肤**（非各浅色主题的深色变体），主 App 深浅自动/手动切换；**悬浮窗不做深色系**（视觉跨背景对比度设计，与系统深浅无关，且独立 engine 热切换成本高）。

### 三档与生效链路

```
设置页「外观 → 深色模式」三档 ChoiceChip（跟随系统 / 浅色 / 深色）
  → prefs key theme_mode（'system'/'light'/'dark'，parseThemeMode 坏串兜底 system）
  → AppRoot.themeModeNotifier.value = mode（立即整树重建）
  → MaterialApp(theme: 选中的浅色皮肤, darkTheme: AppThemes.dark, themeMode: mode)
    themeMode=system 时由 Flutter 框架跟随系统亮度自动选 theme/darkTheme
```

- 深色皮肤生效时**整体替换**当前选中的浅色皮肤（含自定义主题——自定义主题编辑器是浅色专属，深色模式下不生效）
- `brightness` 字段保证 `ColorScheme.fromSeed` 产出 dark scheme，Material 组件（SnackBar/Dialog/弹窗）自动走深色配色
- 状态栏图标亮度走既有 `isDarkOverlay` 槽（深色主题为 true）

### 深色皮肤配色（AppThemes.dark，id=`dark_standard`）

按 Material 深色规范 + 品牌青保留。按钮前景色 2026-09-28 定版**暗色调**（初版曾按「微信深色同款」用白图标白字，真机反馈与暗灰输入框视觉冲突后改近黑；白色在深底界面明度对比太跳）：

| 槽位 | 值 | 依据 |
|---|---|---|
| `scaffoldBackground` | `#121212` | Material dark 基准面 |
| `cardBackground` / `surface` | `#1E1E1E` | 等效 elevation 1 卡片 |
| `textPrimary/Secondary/Hint` | 白 alpha 87%/60%/38% | Material dark on-surface 规范 |
| `primary` / `fabReady` | `#009688`（不变） | 品牌青保留做按钮底色 |
| `fabContentColor`（getter） | 深色=近黑 `black87` / 浅色恒白 | 语音钮图标/确认保存文字前景色：白图标在深底太跳（2026-09-28 真机反馈），黑 87% 叠品牌青 ≈4.7:1 ≥3:1 |
| `fabClayShadow`（getter） | 深色=仅暗影 / 浅色=白高光+暗影 | 黏土阴影白高光在深底显形为光晕，深色去掉高光只留暗影托底；三处语音圆钮共用唯一真值 |
| `primaryDark` | `#80CBC4`（反转为亮青） | 语义是"强调文字色"，深底上深色文字不可读 |
| `primaryLight` | `#1E3A38`（压暗深青容器） | 选中背景 |
| `splashGradient` 等启动页槽 | 沿用默认主题深海渐变 | 本来就是深底，深浅两态视觉一致 |
| warning/danger/gold/fab 录音红·处理橙·禁用灰 | 与浅色主题同款 | 5 套预设一致的"语义色不跟随"惯例 |

主文字对比度 ≥12:1、次文字 ≥7:1、强调文字 ≥4.5:1，单测钉在 `test/dark_theme_test.dart`（parseThemeMode 解析/注册约束/配色 sanity/ThemeData 亮度/FAB 前景色与阴影的深浅分支，18 例）。

### 悬浮窗为何不做

悬浮窗卡片是深色半透明胶囊+白描边设计，跨任意背景可读；系统深色不代表悬浮窗下垫的背景是深色。overlay engine 不消费 `theme_mode` key。

## 字体选项（2026-10-22 新增）

用户反馈霞鹜文楷与部分场景观感不搭，新增全局字体档（主 App + 悬浮窗共用）：

| ID | 展示名 | fontFamily |
|---|---|---|
| `wenkai`（默认） | 霞鹜文楷 | `LXGWWenKaiMonoGBScreen` |
| `system` | 系统默认 | `null`（Flutter/Android 平台默认 Roboto 系） |

- 「系统默认」= **平台字体**，不跟随手机厂商自定义字体（后者需原生探测、各厂商支持不一致）
- prefs key `app_font_family`，`parseAppFontChoice` 对 null/空串/坏串兜底 wenkai（老用户视觉不变）
- 写：设置页「外观 → 字体」ChoiceChip；读：`main()` 启动预读 + 悬浮窗 `_loadTheme` 时 `prefs.reload()` 后解析
- 生效：`AppThemeDefinition.toThemeData(font:)` 同时设 `ThemeData.fontFamily` 与 15 个 TextTheme style；传 null 时由 Typography 填充平台默认（两层字体陷阱见 CLAUDE.md）
- 悬浮窗是独立 engine：OverlayHome 展开/刷新配置时回调 `onThemePrefsChanged → OverlayApp._loadTheme` 重读 prefs，key 未变则 no-op
- 测试：`test/app_font_test.dart`（解析兜底 / 两层字体一致性 / 明暗主题共用字体档）

## 新拟物覆盖收口（2026-10-28）

用户反馈新拟物主题仍有页面残留 M3 默认控件，视觉断层集中在**设置页二级页面**。本次收敛为单一来源，避免各页各写一份 `ext.isNeumorphic` 分支：

- `lib/widgets/neu_widgets.dart` 新增 `NeuChoiceChip`：拟物单选胶囊——选中 `NeuInset(radius:999)` + `primaryDark` 粗体，未选 `neuRaisedDecoration` 凸起；`onSelected == null` 时 45% 不透明禁用态
- `lib/settings/settings_widgets.dart` 新增 4 个分流辅助（拟物走 Neu 组件，其余主题**原样**保留 M3 控件）：
  - `buildSettingsChoiceChip`（icon / avatar / iconSize / showCheckmark / labelPadding）→ `NeuChoiceChip` | `ChoiceChip`
  - `buildSettingsPrimaryButton`（busy / minHeight / expand）→ `NeuPressable` + `primaryDark` 前景 | `ElevatedButton.icon`
  - `buildSettingsSecondaryButton` → `NeuPressable` + `primary` 字 | `OutlinedButton.icon`
  - `buildSettingsFieldShell` → `NeuInset(radius:15)` 外壳 | 原样返回
- 输入框配套不变量：拟物主题 `TextField.filled` 必须为 false，否则填充色盖住 `NeuInset` 内阴影（cloud_sync / recognition 两页已按 `!ext.isNeumorphic` 传入）
- 输入框标签不变量（2026-10-28 用户真机反馈修正）：拟物主题**禁用 `InputDecoration.labelText`**。浮动标签是 `OutlineInputBorder` 的配套排版（压在上边框线上、为切口预留上内边距），而拟物壳没有可见边框，标签会悬在凹陷上沿被内阴影切掉半截、输入框还凭空变高。拟物分支改传 `buildSettingsFieldShell(label: ...)`，由外壳在凹陷外画 12px `textSecondary` 小标题；非拟物主题仍走 M3 浮动标签，视觉零变化（cloud_sync_page 的 4 个字段已统一走 `_buildField`）

覆盖范围（均为用户点名项）：WebDAV 同步页（保存配置 / 测试连接 / 立即同步 / 同步录音开关 / 各输入框）、识别与修正页（热词输入框 + 保存并更新热词）、大爆炸搜索页（3 个搜索引擎）、音量键快捷操作页（4 槽位动作 + 长按时长预设/自定义 + 说完自动停止秒数 + 底部系统设置按钮）、悬浮窗设置页（把手大小 / 把手主题 / 字体大小 / 面板高度 / 按钮位置 / 自动隐藏 / 停靠侧 / 边缘间距 + 立即启动悬浮窗）、外观页（字体两档 / 字号 / 深色模式三档）。

测试：`test/settings_neu_controls_test.dart`（12 例：共享分流 7 例 + 搜索/外观/悬浮窗/音量键/云端同步页面级各 1~2 例，断言拟物命中 `NeuChoiceChip`/`NeuPressable`/`NeuInset` 且点击确实写 prefs；输入框 3 例含「标签整体落在凹陷上沿之外」几何断言与「拟物 4 个字段不用 labelText」页面级断言）。

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
- [lib/theme/app_font.dart](../../lib/theme/app_font.dart) - 字体档枚举 + prefs 解析
- [lib/widgets/neu_widgets.dart](../../lib/widgets/neu_widgets.dart) - 新拟物组件库（凸/凹阴影、NeuPressable、NeuSwitch、NeuChoiceChip）
- [lib/settings/settings_widgets.dart](../../lib/settings/settings_widgets.dart) - 设置页控件分流层（拟物 / 其他主题）
- [lib/overlay/overlay_app.dart](../../lib/overlay/overlay_app.dart) - 悬浮窗主题/字体重载（独立 engine）
- [lib/theme/custom_theme.dart](../../lib/theme/custom_theme.dart) - 自定义主题（配置存取 + 色系派生）
- [lib/settings/custom_theme_page.dart](../../lib/settings/custom_theme_page.dart) - 自定义主题编辑页（选色盘）
- [lib/main.dart](../../lib/main.dart) - `AppRoot.themeNotifier` 全局切换
- [lib/utils/pro_gate.dart](../../lib/utils/pro_gate.dart) - Pro 门禁
- [lib/settings_tab.dart](../../lib/settings_tab.dart) - 主题选择 UI

## 相关文档

- [ui-patterns.md](../guides/ui-patterns.md#外观设置) - 外观设置 UI 说明
- [icon-pack-switching.md](icon-pack-switching.md) - Android 图标包切换
- [pro-license.md](pro-license.md) - Pro 授权码体系 + 7 天试用
