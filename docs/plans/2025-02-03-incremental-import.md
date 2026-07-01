# 增量更新导入功能实施计划

> **For Claude:** REQUIRED SUB-SKILL: Use @superpowers:executing-plans to implement this plan task-by-task.

**目标:** 将导入功能从全量替换改为增量更新，支持智能去重和数据合并

**架构:** 使用内存索引构建去重集合，在数据插入前过滤重复记录，保留现有数据和音频文件

**技术栈:** Flutter, Dart, SQLite (sqflite), archive (ZIP 处理)

---

## 前置说明

**修改范围:**
- 文件: `lib/settings_tab.dart`
- 方法: `_importFullBackup()` (第 417-536 行)

**不需要修改:**
- 数据库结构
- DbHelper 类
- UI 组件

**关键改动:**
1. 移除 `clearAllData()` 调用
2. 添加去重索引构建逻辑
3. 添加数据过滤逻辑
4. 修改音频文件恢复逻辑（不清空现有文件）
5. 更新确认对话框文案
6. 改进统计信息显示

---

## 任务 1: 修改确认对话框文案

**文件:**
- Modify: `lib/settings_tab.dart:432`

**步骤 1: 定位代码**

找到第 432 行的确认对话框内容文本。

**步骤 2: 修改文案**

将:
```dart
content: const Text("导入将清空并覆盖现有所有数据，是否继续？"),
```

改为:
```dart
content: const Text("导入将合并现有数据，重复的记录将被跳过。是否继续？"),
```

**步骤 3: 验证修改**

运行: `flutter analyze lib/settings_tab.dart`
预期: 无错误

**步骤 4: 提交**

```bash
git add lib/settings_tab.dart
git commit -m "claude: 修改导入确认对话框文案，说明将进行增量更新"
```

---

## 任务 2: 构建现有数据索引

**文件:**
- Modify: `lib/settings_tab.dart:494` (在 `clearAllData()` 调用之前)

**步骤 1: 注释掉清空数据调用**

将第 495 行:
```dart
await widget.dbHelper.clearAllData();
```

改为:
```dart
// await widget.dbHelper.clearAllData(); // 改为增量更新，不再清空数据
```

**步骤 2: 添加索引构建代码**

在第 494 行（`// 5. 清空现有数据` 注释之后）添加:

```dart
// 5. 构建现有数据索引（用于去重）
final existingItems = await widget.dbHelper.queryAll();
final existingDiaries = await widget.dbHelper.queryAllDiaries();

// 构建物品索引：格式 "name|location"
final itemIndex = <String>{};
for (var item in existingItems) {
  final key = '${item['name']}|${item['location']}';
  itemIndex.add(key);
}

// 构建日记索引：格式 "content|createdAt"
final diaryIndex = <String>{};
for (var diary in existingDiaries) {
  final key = '${diary['content']}|${diary['created_at']}';
  diaryIndex.add(key);
}
```

**步骤 3: 验证编译**

运行: `flutter analyze lib/settings_tab.dart`
预期: 无错误

**步骤 4: 提交**

```bash
git add lib/settings_tab.dart
git commit -m "claude: 添加现有数据索引构建逻辑，为去重做准备"
```

---

## 任务 3: 过滤重复的物品数据

**文件:**
- Modify: `lib/settings_tab.dart:498` (在 `batchInsertItems` 调用之前)

**步骤 1: 添加物品过滤逻辑**

将第 498 行:
```dart
await widget.dbHelper.batchInsertItems(items);
```

改为:

```dart
// 6. 过滤并插入物品数据
final newItems = <Map<String, String>>[];
int skippedItems = 0;

for (var item in items) {
  final key = '${item['name']}|${item['location']}';
  if (itemIndex.contains(key)) {
    skippedItems++;
  } else {
    newItems.add(item);
    itemIndex.add(key); // 添加到索引，防止导入文件内部重复
  }
}

if (newItems.isNotEmpty) {
  await widget.dbHelper.batchInsertItems(newItems);
}
```

**步骤 2: 验证编译**

运行: `flutter analyze lib/settings_tab.dart`
预期: 无错误

**步骤 3: 提交**

```bash
git add lib/settings_tab.dart
git commit -m "claude: 添加物品数据去重过滤逻辑"
```

---

## 任务 4: 过滤重复的日记数据

**文件:**
- Modify: `lib/settings_tab.dart:499` (在 `batchInsertDiaries` 调用之前)

**步骤 1: 添加日记过滤逻辑**

将第 499 行:
```dart
await widget.dbHelper.batchInsertDiaries(diaries);
```

改为:

```dart
// 7. 过滤并插入日记数据
final newDiaries = <Map<String, dynamic>>[];
int skippedDiaries = 0;

for (var diary in diaries) {
  final key = '${diary['content']}|${diary['created_at']}';
  if (diaryIndex.contains(key)) {
    skippedDiaries++;
  } else {
    newDiaries.add(diary);
    diaryIndex.add(key); // 添加到索引，防止导入文件内部重复
  }
}

if (newDiaries.isNotEmpty) {
  await widget.dbHelper.batchInsertDiaries(newDiaries);
}
```

**步骤 2: 验证编译**

运行: `flutter analyze lib/settings_tab.dart`
预期: 无错误

**步骤 3: 提交**

```bash
git add lib/settings_tab.dart
git commit -m "claude: 添加日记数据去重过滤逻辑"
```

---

## 任务 5: 处理空数据情况

**文件:**
- Modify: `lib/settings_tab.dart:500` (在插入数据之后)

**步骤 1: 添加空数据检查**

在任务 4 添加的代码之后，音频文件恢复之前（第 501 行之前）添加:

```dart
// 8. 检查是否有新数据
if (newItems.isEmpty && newDiaries.isEmpty) {
  if (mounted) {
    Navigator.pop(context); // 关闭加载对话框
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("⚠️ 备份文件中没有新数据")),
    );
  }
  return;
}
```

**步骤 2: 验证编译**

运行: `flutter analyze lib/settings_tab.dart`
预期: 无错误

**步骤 3: 提交**

```bash
git add lib/settings_tab.dart
git commit -m "claude: 添加空数据检查，避免无意义的导入操作"
```

---

## 任务 6: 修改音频文件恢复逻辑

**文件:**
- Modify: `lib/settings_tab.dart:505-518` (音频文件恢复部分)

**步骤 1: 移除清空音频目录的代码**

将第 505-512 行:
```dart
if (!audioDir.existsSync()) {
  await audioDir.create(recursive: true);
} else {
  // 清空现有音频文件
  for (var file in audioDir.listSync()) {
    await file.delete();
  }
}
```

改为:

```dart
// 确保音频目录存在
if (!audioDir.existsSync()) {
  await audioDir.create(recursive: true);
}
// 不再清空现有音频文件，改为增量合并
```

**步骤 2: 修改音频文件恢复逻辑**

将第 514-518 行:
```dart
for (var audioFile in audioFiles) {
  final filePath = p.join(audioDir.path, p.basename(audioFile.name));
  final file = File(filePath);
  await file.writeAsBytes(audioFile.content as List<int>);
}
```

改为:

```dart
// 只恢复不存在的音频文件
int restoredAudioCount = 0;
for (var audioFile in audioFiles) {
  final fileName = p.basename(audioFile.name);
  final filePath = p.join(audioDir.path, fileName);
  final file = File(filePath);

  // 检查文件是否已存在
  if (!await file.exists()) {
    await file.writeAsBytes(audioFile.content as List<int>);
    restoredAudioCount++;
  }
}
```

**步骤 3: 验证编译**

运行: `flutter analyze lib/settings_tab.dart`
预期: 无错误

**步骤 4: 提交**

```bash
git add lib/settings_tab.dart
git commit -m "claude: 修改音频文件恢复逻辑，支持增量合并"
```

---

## 任务 7: 更新统计信息显示

**文件:**
- Modify: `lib/settings_tab.dart:526` (成功消息部分)

**步骤 1: 修改统计信息**

将第 524-528 行:
```dart
// 9. 显示成功消息
if (mounted) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text("✅ 全量备份已恢复：${items.length}个物品，${diaries.length}条日记，${audioFiles.length}个音频"))
  );
}
```

改为:

```dart
// 9. 显示成功消息
if (mounted) {
  final message = StringBuffer();
  message.writeln('✅ 导入完成');
  message.writeln('• 新增物品：${newItems.length} 条');
  if (skippedItems > 0) {
    message.writeln('• 跳过重复物品：$skippedItems 条');
  }
  message.writeln('• 新增日记：${newDiaries.length} 条');
  if (skippedDiaries > 0) {
    message.writeln('• 跳过重复日记：$skippedDiaries 条');
  }
  if (restoredAudioCount > 0) {
    message.writeln('• 恢复录音文件：$restoredAudioCount 个');
  }

  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(message.toString().trim()),
      duration: const Duration(seconds: 5),
    ),
  );
}
```

**步骤 2: 验证编译**

运行: `flutter analyze lib/settings_tab.dart`
预期: 无错误

**步骤 3: 提交**

```bash
git add lib/settings_tab.dart
git commit -m "claude: 改进导入统计信息，显示详细的新增和跳过数据"
```

---

## 任务 8: 手动测试验证

**测试场景 1: 首次导入（空数据库）**

**步骤:**
1. 卸载应用或清空数据
2. 运行应用: `flutter run`
3. 导入一个包含数据的备份文件

**预期结果:**
- 显示 "新增物品：X 条，新增日记：Y 条"
- 跳过重复：0 条
- 所有数据正常显示在列表中

**测试场景 2: 导入重复数据**

**步骤:**
1. 确保数据库中已有数据
2. 再次导入同一份备份文件

**预期结果:**
- 显示 "新增物品：0 条，跳过重复物品：X 条"
- 显示 "新增日记：0 条，跳过重复日记：Y 条"
- 数据库记录数不变

**测试场景 3: 导入部分重复数据**

**步骤:**
1. 准备两份不同的备份文件 A 和 B
2. 先导入备份 A
3. 再导入备份 B（包含部分 A 的数据）

**预期结果:**
- 显示新增了 B 中的新数据
- 显示跳过了 A 中已有的数据
- 数据库包含 A 和 B 的所有不重复数据

**测试场景 4: 音频文件合并**

**步骤:**
1. 导入包含录音的备份 A
2. 再导入包含不同录音的备份 B

**预期结果:**
- audio/ 目录保留所有录音文件
- 新录音被正确恢复
- 已存在的录音不会被覆盖

**测试场景 5: 空数据处理**

**步骤:**
1. 导入只包含表头的 CSV 文件

**预期结果:**
- 显示 "备份文件中没有新数据"
- 数据库不变
- 不报错

---

## 任务 9: 代码审查和清理

**步骤 1: 运行代码分析**

```bash
flutter analyze
```

预期: 无严重错误，只有已有的警告

**步骤 2: 检查代码格式**

```bash
flutter format lib/settings_tab.dart
```

**步骤 3: 最终验证**

运行应用，执行所有测试场景，确保功能正常。

**步骤 4: 提交最终版本**

```bash
git add lib/settings_tab.dart
git commit -m "claude: 完成增量更新导入功能，支持智能去重和数据合并"
```

---

## 附录: 关键代码片段参考

### 去重索引构建

```dart
// 物品索引格式: "name|location"
final itemIndex = <String>{};
for (var item in existingItems) {
  itemIndex.add('${item['name']}|${item['location']}');
}

// 日记索引格式: "content|createdAt"
final diaryIndex = <String>{};
for (var diary in existingDiaries) {
  diaryIndex.add('${diary['content']}|${diary['created_at']}');
}
```

### 数据过滤

```dart
// 过滤物品
for (var item in items) {
  final key = '${item['name']}|${item['location']}';
  if (!itemIndex.contains(key)) {
    newItems.add(item);
    itemIndex.add(key);
  }
}

// 过滤日记
for (var diary in diaries) {
  final key = '${diary['content']}|${diary['created_at']}';
  if (!diaryIndex.contains(key)) {
    newDiaries.add(diary);
    diaryIndex.add(key);
  }
}
```

### 音频文件智能合并

```dart
// 只恢复不存在的文件
for (var audioFile in audioFiles) {
  final fileName = p.basename(audioFile.name);
  final file = File(p.join(audioDir.path, fileName));

  if (!await file.exists()) {
    await file.writeAsBytes(audioFile.content as List<int>);
    restoredAudioCount++;
  }
}
```

---

## 回滚方案

如果出现问题需要回滚：

1. **恢复旧版本文案**
   - 将确认对话框改回 "导入将清空并覆盖现有所有数据"

2. **恢复清空数据逻辑**
   - 取消注释 `await widget.dbHelper.clearAllData();`
   - 删除索引构建和过滤逻辑

3. **恢复音频文件清空逻辑**
   - 恢复清空音频目录的代码
   - 移除文件存在性检查

---

## 性能指标

- 1000 条物品导入时间 < 2 秒
- 1000 条日记导入时间 < 3 秒
- 去重检查时间 < 500ms

如果性能不达标，考虑：
- 使用数据库事务
- 分批处理大量数据
- 使用数据库级别的去重查询
