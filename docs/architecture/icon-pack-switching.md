# Android 图标包切换

## 概述

声物记支持 4 套 Android 桌面图标包，用户可在设置页"外观"分区一键切换。实现基于 `activity-alias`，无需创建真实 Activity 类，由系统 `ComponentEnabledSetting` 持久化状态。

| ID | 名称 | 背景色 | Pro |
|---|---|---|---|
| `default` | 默认 | `#2C3E50` | 否 |
| `warm` | 暖橙 | `#E65100` | 否 |
| `festive` | 节日红 | `#C62828` | 是 |
| `minimal` | 极简白 | `#FAFAFA` | 是 |

## 核心设计

### activity-alias 声明

**文件**: [android/app/src/main/AndroidManifest.xml](../../android/app/src/main/AndroidManifest.xml)

每个非默认图标包对应一个 `activity-alias`，`targetActivity` 指向 `.MainActivity`：

```xml
<activity-alias
    android:name=".IconWarm"
    android:enabled="false"
    android:icon="@mipmap/launcher_icon_warm"
    android:roundIcon="@mipmap/launcher_icon_warm"
    android:targetActivity=".MainActivity"
    android:exported="true">
    <intent-filter>
        <action android:name="android.intent.action.MAIN" />
        <category android:name="android.intent.category.LAUNCHER" />
    </intent-filter>
    <!-- 复制完整的 shortcuts meta-data，否则切换后桌面长按快捷方式失效 -->
    <meta-data android:name="android.app.shortcuts" android:resource="@xml/shortcuts" />
</activity-alias>
```

关键要点：

- `android:name=".IconWarm"` 只是组件名占位，**不需要创建对应类**
- 每个 alias 必须复制主 Activity 的完整 `intent-filter` 和 `shortcuts` meta-data
- 默认 Activity 与 alias 同时声明 `LAUNCHER`，通过 enabled 状态控制实际生效图标

### Flutter-Native 通信

**文件**: [lib/utils/icon_pack_switcher.dart](../../lib/utils/icon_pack_switcher.dart)

```dart
// 切换到指定图标包
await IconPackSwitcher.switchTo('festive');

// 查询当前图标包（从原生层读取，不依赖 prefs）
final packId = await IconPackSwitcher.getCurrentPackId();
```

对应原生方法在 [MainActivity.kt](../../android/app/src/main/java/com/shengwuji/app/MainActivity.kt)：

- `setIconPack(packId)`：用 `PackageManager.setComponentEnabledSetting` 启用目标 alias、禁用其余
- `getCurrentIconPack()`：反向遍历 alias enabled 状态，返回当前图标包 ID

### 状态持久化

- **真正状态源**：Android 系统的 `ComponentEnabledSetting`
- **prefs 作用**：`selected_icon_pack` 仅用于 UI 显示当前选中（因读取原生状态有异步成本）
- 杀进程重进后，设置页通过 `getCurrentPackId()` 反查系统状态，保证与桌面图标一致

## 切换流程

```
设置页点击图标包卡片
  → ProGate.tryAccess(pack.isPro) 拦截未解锁的 Pro 图标包
  → IconPackSwitcher.switchTo(pack.id)
    → MainActivity.setIconPack(packId)
      → 启用目标 activity-alias
      → 禁用其他 alias
  → UI 提示"应用会短暂重启"
  → Android 1-3 秒内杀死 APP 进程
  → 用户回到桌面，图标已更新
```

## 重要限制

### 切换后 APP 进程会被杀死

`setComponentEnabledSetting` 改变组件启用状态后，Android 会在 1-3 秒内重启/杀死应用进程。即使加 `DONT_KILL_APP` flag 也只是延迟，不能避免。

**UI 必须明确告知用户**："切换后应用会短暂重启，属正常现象"。

### 无障碍服务 / 闹钟不受影响

- `VolumeKeyAccessibilityService` 是 service，不参与 alias 切换
- `AlarmReceiver` / `AlarmStopReceiver` 是 receiver，不参与 alias 切换
- 切换后音量键快捷、闹钟功能正常工作

### 快捷方式兼容

每个 alias 必须复制：

- `LAUNCHER` intent-filter
- `android.app.shortcuts` meta-data

否则切换后桌面长按图标的快捷方式会失效。

## Pro 门禁

与主题系统共用 [lib/utils/pro_gate.dart](../../lib/utils/pro_gate.dart)：

- 节日红、极简白为 Pro 图标包
- 未解锁时点击调起 `ProUnlockDialog`
- 解锁后才能切换

## 资源生成

每套图标包需要：

- `res/mipmap-anydpi-v26/launcher_icon_${id}.xml` — adaptive-icon XML
- `res/drawable/ic_launcher_foreground_${id}.xml` — 前景 vector
- `res/values/colors.xml` — `ic_launcher_background_${id}`
- `res/mipmap-{hdpi,mdpi,xhdpi,xxhdpi,xxxhdpi}/launcher_icon_${id}.png` — 5 套分辨率 PNG

## 关键文件

- [android/app/src/main/AndroidManifest.xml](../../android/app/src/main/AndroidManifest.xml) - activity-alias 声明
- [android/app/src/main/java/com/shengwuji/app/MainActivity.kt](../../android/app/src/main/java/com/shengwuji/app/MainActivity.kt) - `setIconPack` / `getCurrentIconPack`
- [lib/utils/icon_pack_switcher.dart](../../lib/utils/icon_pack_switcher.dart) - Flutter 端桥接
- [lib/utils/pro_gate.dart](../../lib/utils/pro_gate.dart) - Pro 门禁
- [lib/settings_tab.dart](../../lib/settings_tab.dart) - 图标包选择 UI

## 相关文档

- [theme-system.md](theme-system.md) - 主题/皮肤系统
- [ui-patterns.md](../guides/ui-patterns.md#外观设置) - 外观设置 UI 说明
- [volume-key-shortcuts.md](volume-key-shortcuts.md) - 无障碍服务不受图标切换影响
