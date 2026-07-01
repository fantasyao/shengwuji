# 数据库架构

## 数据库概述

使用 SQLite 通过 `sqflite` 包实现数据持久化。

### 数据库版本
- **当前版本**: 8
- **定义位置**: [lib/db_helper.dart](../lib/db_helper.dart)

## 数据表

### items 表（物品追踪）
存储用户语音记录的物品位置信息。

| 字段 | 类型 | 说明 |
|------|------|------|
| id | INTEGER | 主键，自增 |
| name | TEXT | 物品名称 |
| location | TEXT | 存放位置 |

### diary 表（语音日记）
存储用户的语音日记条目。

| 字段 | 类型 | 说明 |
|------|------|------|
| id | INTEGER | 主键，自增 |
| content | TEXT | 日记内容（语音转文字，支持 markdown 格式清单：`- [ ]` 未完成 / `- [x]` 已完成） |
| created_at | TEXT | 创建时间戳 |
| audio_path | TEXT | 音频文件存储路径 |
| duration | INTEGER | 音频时长（秒） |
| is_archived | INTEGER | 归档标记（0=活跃, 1=已归档） |
| exported_at | TEXT | 增量导出时间戳，未导出为 NULL |

## 数据库操作

### DbHelper 类
提供所有数据库操作的封装方法：

#### 物品操作
- `getItems()` - 获取所有物品
- `addItem(name, location)` - 添加新物品
- `updateItem(id, name, location)` - 更新物品
- `deleteItem(id)` - 删除物品
- `batchInsertItems(items)` - 批量插入物品
- `searchItemsByName(keyword, {limit})` - 按物品名 LIKE 模糊查询，按 id 倒序（最近优先）。日记页"XX在哪儿"答案区使用

#### 日记操作
- `getDiaries()` - 获取所有日记
- `queryAllDiaries()` - 查询所有日记
- `addDiary(content, audioPath, duration)` - 添加新日记
- `updateDiary(id, content)` - 更新日记内容
- `deleteDiary(id)` - 删除日记
- `archiveDiary(id)` - 归档日记

#### 导出相关
- `markDiaryExported(id)` - 标记日记已导出
- `queryUnexportedDiaries()` - 查询未导出且未归档的日记
- `clearAllExportState()` - 清除所有导出标记

#### 批量与清理
- `batchInsertDiaries(diaries)` - 批量插入日记
- `clearAllData()` - 清空所有数据

## 数据迁移

数据库版本升级时，需要：
1. 增加 `database_version` 值
2. 在 `onUpgrade()` 中添加迁移逻辑
3. 确保旧数据正确迁移到新结构

### 迁移历史

| 版本变更 | 变更内容 | 说明 |
|----------|----------|------|
| v3 → v4 | 添加 `duration` 字段 | 支持日记录音时长记录 |
| v4 → v5 | 添加 `is_archived` 字段 | 归档功能，标记日记是否已归档 |
| v5 → v6 | 添加 `exported_at` 字段 | 增量导出标记，记录导出时间戳 |
| v6 → v7 | 添加 lists 表 | 存储清单标题、条目JSON、分类 |
| v7 → v8 | 清单数据合并到日记表 | items_json 转为 markdown 格式，删除 lists 表 |
