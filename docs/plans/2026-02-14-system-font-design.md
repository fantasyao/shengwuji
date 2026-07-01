# 系统字体支持设计文档

**日期**: 2026-02-14
**作者**: Claude & 用户
**状态**: 已批准

## 1. 问题概述

### 1.1 问题描述
用户的三星 S24 手机系统字体设置为**霞鹜文楷**，系统其他应用能正常显示该字体，但 Flutter 应用使用的是内置的 Roboto 字体，无法响应系统字体设置。

### 1.2 根本原因
Flutter 在 Android 平台默认使用内置的 Roboto 字体文件，不会自动读取系统自定义的字体设置。这是 Flutter 的默认行为。

### 1.3 需求目标
让 Flutter 应用能够响应系统字体设置，显示用户设置的霞鹜文楷字体。

## 2. 解决方案：修改 Android 原生主题

### 2.1 方案选择理由
- ✅ **实现简单**：只需修改一个 XML 配置文件
- ✅ **效果最好**：完全响应系统字体，包括自定义字体（霞鹜文楷）
- ✅ **稳定性高**：Android 官方推荐的做法
- ✅ **自动跟随**：系统字体变化时自动跟随

### 2.2 影响范围
- ✅ Android 平台：所有文本（标题、正文、按钮、列表、对话框等）
- ❌ iOS 平台：不受影响（iOS 已经默认使用系统字体 San Francisco）

## 3. 架构设计

### 3.1 核心原理
Android 应用默认使用 Material 主题，该主题硬编码了 Roboto 字体。解决方案是在 `styles.xml` 中创建一个继承自系统主题的样式，并将字体族设置为系统默认（`@null` 或 `sans-serif`）。

### 3.2 修改文件
1. **主配置文件**：`android/app/src/main/res/values/styles.xml`
2. **AndroidManifest**：`android/app/src/main/AndroidManifest.xml`（可能需要调整）
3. **其他语言版本**：`android/app/src/main/res/values-XX/styles.xml`（如存在）

## 4. 具体实现

### 4.1 创建 styles.xml

**文件路径**：`android/app/src/main/res/values/styles.xml`

**实现方式 A：使用 @null（推荐）**
```xml
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <style name="NormalTheme" parent="Theme.AppCompat.Light.NoActionBar">
        <item name="android:fontFamily">@null</item>
        <item name="android:textColor">@android:color/black</item>
    </style>
</resources>
```

**实现方式 B：使用 sans-serif**
```xml
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <style name="NormalTheme" parent="Theme.AppCompat.Light.NoActionBar">
        <item name="android:fontFamily">sans-serif</item>
    </style>
</resources>
```

**推荐方式 A**，因为 `@null` 完全移除字体限制，让系统使用默认字体。

### 4.2 配置说明

**关键属性解释**：
- `parent="Theme.AppCompat.Light.NoActionBar"` → 继承 AppCompat 主题，兼容性更好
- `android:fontFamily="@null"` → 使用系统默认字体（霞鹜文楷）
- `android:fontFamily="sans-serif"` → 使用系统默认字体族（次优选择）

### 4.3 AndroidManifest.xml 配置

**文件路径**：`android/app/src/main/AndroidManifest.xml`

检查 `<application>` 和 `<activity>` 标签的 `android:theme` 属性：

```xml
<application
    android:label="my_first_app"
    android:name="${applicationName}"
    android:icon="@mipmap/ic_launcher"
    android:theme="@style/NormalTheme">  <!-- 确保使用我们的主题 -->

    <activity
        android:name=".MainActivity"
        android:exported="true"
        android:launchMode="singleTop"
        android:theme="@style/NormalTheme">  <!-- Activity 级承主题 -->
        ...
    </activity>
</application>
```

**注意**：
- 如果已有 `android:theme` 属性，需要改为 `@style/NormalTheme`
- Activity 的 theme 会覆盖 Application 的 theme
- Flutter 默认生成的项目可能已有主题配置，需要替换

## 5. 测试与验证

### 5.1 构建步骤

```bash
# 清理旧构建
flutter clean

# 构建 Release APK
flutter build apk --release

# 安装到设备
flutter install
```

### 5.2 检查点

**全局检查**：
- ✅ 应用启动后，所有文本应显示为霞鹜文楷
- ✅ 字体渲染清晰，无错位或变形

**分页面检查**：
- ✅ **Record Tab**：按钮文本、提示信息、识别结果
- ✅ **List Tab**：物品名称、位置、搜索框文本
- ✅ **Diary Tab**：日记内容、时间戳、播放按钮
- ✅ **Settings Tab**：菜单项、开关标签、说明文本
- ✅ **底部导航栏**：标签文字（"存物品"、"查物品"、"随手记"、"设置"）

### 5.3 iOS 平台验证
- iOS 不需要修改，默认使用系统字体
- 确认 iOS 构建和运行不受影响

### 5.4 潜在问题与回退

**常见问题**：
1. **部分文本仍显示 Roboto**
   - 原因：某些 Widget 硬编码了 `fontFamily` 属性
   - 排查：全局搜索 `fontFamily` 关键字
   - 解决：移除硬编码的字体设置

2. **字体加载失败**
   - 原因：系统字体文件损坏或不存在
   - 排查：Logcat 日志中的字体加载错误
   - 回退：删除 `styles.xml` 修改，使用默认主题

3. **应用崩溃**
   - 原因：XML 配置错误
   - 排查：`flutter run -v` 查看详细日志
   - 回退：恢复 `AndroidManifest.xml` 原始配置

**回退方法**：
```bash
# 删除或重命名 styles.xml
cd android/app/src/main/res/values/
mv styles.xml styles.xml.bak

# 恢复 AndroidManifest.xml 的主题配置
git checkout android/app/src/main/AndroidManifest.xml

# 重新构建
flutter clean && flutter build apk --release
```

## 6. 相关文件清单

### 6.1 需要修改的文件
- `android/app/src/main/res/values/styles.xml`（创建或修改）
- `android/app/src/main/AndroidManifest.xml`（可能需要调整）

### 6.2 可能需要检查的文件
- `android/app/src/main/res/values-XX/styles.xml`（其他语言版本）
- `lib/main.dart`（检查是否有硬编码 fontFamily）

### 6.3 不受影响的文件
- Flutter 代码（`lib/` 目录下的所有文件）
- iOS 配置（`ios/` 目录）
- 资源文件（`assets/` 目录）

## 7. 未来考虑

### 7.1 可能的增强
- 动态字体切换（添加字体选择器到设置页面）
- 多语言字体支持（不同语言使用不同字体）
- 自定义字体包（打包特定字体到应用中）

### 7.2 相关文档
- Flutter 官方文档：[样式和主题](https://flutter.dev/docs/development/ui/widgets/text)
- Android 开发者文档：[样式和主题](https://developer.android.com/guide/topics/ui/look-and-feel/themes)

## 8. 总结

本设计通过修改 Android 原生主题配置，实现 Flutter 应用对系统字体的完整支持。方案简单高效，无需修改 Flutter 代码，完全符合用户需求。

**关键优势**：
- 实现简单，只需修改一个 XML 文件
- 完全响应系统字体设置
- 稳定性高，遵循 Android 官方最佳实践
- 自动跟随系统字体变化

**预计工作量**：15-30 分钟（包括测试）
