# 系统字体支持实施计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**目标:** 修改 Android 原生主题配置，使 Flutter 应用能够使用系统自定义字体（霞鹜文楷）

**架构:** 在 Android 原生层创建 `styles.xml`，定义一个继承自 `Theme.AppCompat.Light.NoActionBar` 的主题，设置 `android:fontFamily="@null"` 以使用系统默认字体。确保 `AndroidManifest.xml` 正确引用此主题。

**技术栈:** Android XML, AndroidManifest, Flutter

---

## Task 1: 检查当前 Android 主题配置

**文件:**
- Read: `android/app/src/main/AndroidManifest.xml`

**Step 1: 读取 AndroidManifest.xml**

检查当前 `<application>` 和 `<activity>` 标签的 `android:theme` 配置。

**Step 2: 检查 styles.xml 是否存在**

```bash
ls android/app/src/main/res/values/styles.xml 2>&1
```

Expected output:
- 如果文件存在：显示文件路径
- 如果不存在：`No such file or directory`

**Step 3: 记录当前状态**

记录以下信息到临时文件 `/tmp/font_config_check.txt`：
- AndroidManifest 中的当前主题引用（如果有）
- styles.xml 是否存在
- values 目录下是否有其他语言文件夹（如 values-zh, values-en）

```bash
cat > /tmp/font_config_check.txt << EOF
AndroidManifest theme: [记录找到的主题配置]
styles.xml exists: [true/false]
Language variants: [列出 values-* 文件夹]
EOF
```

---

## Task 2: 创建 styles.xml（推荐方式 A：使用 @null）

**文件:**
- Create: `android/app/src/main/res/values/styles.xml`

**Step 1: 创建 values 目录（如果不存在）**

```bash
mkdir -p android/app/src/main/res/values
```

**Step 2: 创建 styles.xml 文件**

```xml
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <style name="NormalTheme" parent="Theme.AppCompat.Light.NoActionBar">
        <item name="android:fontFamily">@null</item>
        <item name="android:textColor">@android:color/black</item>
    </style>
</resources>
```

**关键点说明：**
- `parent="Theme.AppCompat.Light.NoActionBar"` → 使用 AppCompat 兼容库主题，兼容性最好
- `android:fontFamily="@null"` → 完全移除字体限制，使用系统默认字体（霞鹜文楷）
- `android:textColor="@android:color/black"` → 设置文本颜色（可选，但推荐）

**Step 3: 验证 XML 语法**

```bash
xmllint --noout android/app/src/main/res/values/styles.xml 2>&1
```

Expected: 无错误输出

**Step 4: 提交 styles.xml**

```bash
git add android/app/src/main/res/values/styles.xml
git commit -m "claude: 创建 Android 原生主题配置，使用系统默认字体"
```

---

## Task 3: 更新 AndroidManifest.xml 引用主题

**文件:**
- Modify: `android/app/src/main/AndroidManifest.xml`

**Step 1: 读取当前 AndroidManifest.xml**

**Step 2: 定位 <application> 标签**

查找 `<application>` 标签，检查是否已有 `android:theme` 属性：

**情况 A：已有 android:theme 属性**
```xml
<application
    android:theme="@style/SomeTheme"
    ...>
```

**情况 B：没有 android:theme 属性**
```xml
<application
    ...>
```

**Step 3: 修改或添加主题引用**

**对于情况 A（已有主题）：**
将 `android:theme` 的值改为 `@style/NormalTheme`：

```xml
<application
    android:label="my_first_app"
    android:name="${applicationName}"
    android:icon="@mipmap/ic_launcher"
    android:theme="@style/NormalTheme">
```

**对于情况 B（无主题）：**
在 `<application>` 标签中添加 `android:theme="@style/NormalTheme"`：

```xml
<application
    android:label="my_first_app"
    android:name="${applicationName}}"
    android:icon="@mipmap/ic_launcher"
    android:theme="@style/NormalTheme">
```

**Step 4: 检查 <activity> 标签的主题设置**

查找 `<activity>` 标签（通常是 `.MainActivity`），确认是否需要设置主题。

**推荐做法：**
```xml
<activity
    android:name=".MainActivity"
    android:exported="true"
    android:launchMode="singleTop"
    android:theme="@style/NormalTheme"
    ...>
```

**注意：** 如果 Activity 已有 theme 属性且与 Application 不同，根据需要决定是否修改。

**Step 5: 验证 XML 语法**

```bash
xmllint --noout android/app/src/main/AndroidManifest.xml 2>&1
```

Expected: 无错误输出

**Step 6: 提交 AndroidManifest.xml**

```bash
git add android/app/src/main/AndroidManifest.xml
git commit -m "claude: 更新 AndroidManifest.xml 引用系统字体主题"
```

---

## Task 4: 检查其他语言版本的 values 目录（可选）

**文件:**
- Check: `android/app/src/main/res/values-*/`

**Step 1: 列出所有 values-* 目录**

```bash
ls -d android/app/src/main/res/values-* 2>/dev/null || echo "No language variants found"
```

**Step 2: 如果存在其他语言版本**

为每个语言版本创建对应的 styles.xml（避免在不同语言环境下主题丢失）：

**示例：创建 values-zh（中文）版本**
```bash
mkdir -p android/app/src/main/res/values-zh
```

```xml
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <style name="NormalTheme" parent="Theme.AppCompat.Light.NoActionBar">
        <item name="android:fontFamily">@null</item>
        <item name="android:textColor">@android:color/black</item>
    </style>
</resources>
```

**注意：** 此步骤可选，如果只有一个 `values` 目录可以跳过。

**Step 3: 如果创建了多语言版本，提交**

```bash
git add android/app/src/main/res/values-*/styles.xml
git commit -m "claude: 添加多语言版本的系统字体主题配置"
```

---

## Task 5: 清理旧构建并重新构建 APK

**Step 1: 清理 Flutter 构建缓存**

```bash
flutter clean
```

Expected output:
```
Deleting build...
Deleting .dart_tool...
```

**Step 2: 获取依赖（确保包完整）**

```bash
flutter pub get
```

Expected output:
```
Got dependencies!
```

**Step 3: 构建 Debug APK（快速测试）**

```bash
flutter build apk --debug
```

Expected output:
```
Built build/app/outputs/flutter-apk/app-debug.apk
```

**Step 4: 验证 APK 生成**

```bash
ls -lh build/app/outputs/flutter-apk/app-debug.apk
```

Expected: 显示 APK 文件大小和时间戳

**Step 5: 安装到设备（需连接设备或模拟器）**

```bash
flutter install
```

Expected output:
```
Installing build/app/outputs/flutter-apk/app-debug.apk...
Success
```

---

## Task 6: 验证字体效果（手动测试）

**Step 1: 启动应用**

在设备上找到并启动应用图标。

**Step 2: 视觉验证**

**全局检查：**
- ✅ 应用启动后，所有文本应显示为霞鹜文楷
- ✅ 字体渲染清晰，无错位或变形

**分页面检查清单：**

**Record Tab（录音页）：**
- [ ] 页面标题文本
- [ ] 录音按钮下方提示文本（如 "长按录音"）
- [ ] 识别结果显示区域
- [ ] "存物品" 导航标签

**List Tab（列表页）：**
- [ ] 物品名称列表
- [ ] 存放位置信息
- [ ] 搜索框占位文本
- [ ] "查物品" 导航标签

**Diary Tab（日记页）：**
- [ ] 日记内容列表
- [ ] 时间戳文本
- [ ] 播放/停止按钮文本
- [ ] "随手记" 导航标签

**Settings Tab（设置页）：**
- [ ] 菜单项文本
- [ ] 开关标签文本
- [ ] 说明文本
- [ ] "设置" 导航标签

**Step 3: 记录测试结果**

创建测试报告文件 `/tmp/font_test_results.txt`：

```
测试日期: 2026-02-14
设备型号: 三星 S24
系统字体: 霞鹜文楷

测试结果:
[✅/❌] 全局文本显示正确
[✅/❌] Record Tab 字体正确
[✅/❌] List Tab 字体正确
[✅/❌] Diary Tab 字体正确
[✅/❌] Settings Tab 字体正确
[✅/❌] 导航栏字体正确

问题记录:
[记录任何显示异常或不符合预期的文本]
```

**Step 4: 如果测试通过，标记任务完成**

如果所有文本都正确显示霞鹜文楷字体，任务成功完成！

---

## Task 7: 构建 Release APK（可选，用于发布）

**Step 1: 构建 Release APK**

```bash
flutter build apk --release
```

Expected output:
```
Built build/app/outputs/flutter-apk/app-release.apk
```

**Step 2: 验证 Release APK 字体效果**

卸载旧版本，安装 Release APK 再次验证字体：

```bash
flutter uninstall
flutter install build/app/outputs/flutter-apk/app-release.apk
```

**Step 3: 保存 Release APK 到安全位置**

```bash
cp build/app/outputs/flutter-apk/app-release.apk ~/Desktop/my_first_app-release.apk
```

---

## 回退计划

如果遇到问题需要回退：

**回退 Step 1: 恢复 AndroidManifest.xml**

```bash
git checkout HEAD~1 android/app/src/main/AndroidManifest.xml
```

**回退 Step 2: 删除 styles.xml**

```bash
rm android/app/src/main/res/values/styles.xml
```

**回退 Step 3: 清理并重新构建**

```bash
flutter clean
flutter build apk --debug
```

**回退 Step 4: 安装旧版本验证**

```bash
flutter install
```

---

## 相关文档

- **设计文档**: @docs/plans/2026-02-14-system-font-design.md
- **Android 主题文档**: https://developer.android.com/guide/topics/ui/look-and-feel/themes
- **Flutter Android 嵌入**: https://flutter.dev/docs/development/platform-integration/android

---

## 预计工作量

- **总时间**: 30-45 分钟
- **关键任务**: Task 2, 3, 5, 6
- **可选任务**: Task 4, 7

## 成功标准

✅ 应用所有文本显示霞鹜文楷字体
✅ 与系统其他应用字体一致
✅ 无显示异常或布局错位
✅ Debug 和 Release APK 均正常工作
