# 清单提取器

## 概述

从语音识别文本中提取结构化的购物/待办清单。纯 Dart 实现，无第三方依赖。

**显式触发词**（2026-06-29 加入）：文本必须以 **"代办"或"待办"** 开头才会进入清单提取流程，否则直接跳过。设计上用白名单替代脆弱的评分制黑名单——补漏洞永远修不完，开小口最稳。

**示例**：
```
输入: "代办我要买牛奶、面包、2斤苹果、3个鸡蛋"
→ 剥离触发词后: "我要买牛奶、面包、2斤苹果、3个鸡蛋"
→ 提取为 4 条清单项:
  - 牛奶（购物）
  - 面包（购物）
  - 2斤苹果（购物）
  - 3个鸡蛋（购物）

输入: "刚刚地震了，还有点吓人"
→ 未命中触发词 → isList=false（走普通日记路径，不会被误判为清单）
```

## 处理管道

5 个阶段依次执行：

```
预处理 → 触发词门禁 → 条目拆分 → 结构提取 → 自动分类
```

### Stage 1: 预处理
- 半角逗号统一为全角
- 去除填充词（"嗯"、"啊"、"那个"等）
- 去首尾空格

### Stage 2: 触发词门禁（主决策点）

判定 `isList` 的**唯一权威来源**。命中条件：

1. 预处理后的文本严格以 `"代办"` 或 `"待办"` 开头（不接受任何前置引导词，连"我要代办"都不行）
2. 剥离触发词后内容非空
3. Stage 3 拆分后至少 2 条

任一条件不满足 → `isList=false`，直接返回。

**触发词剥离**：命中后去掉触发词前缀（2 个字符），顺手清掉首尾残余标点（如 `"代办，买苹果"` → `"买苹果"`），剩余内容 `payload` 送入后续管道。

**为什么用白名单**：旧的评分制 `_detectIntent` 加分规则存在子串重叠问题（如 `"还"` 和 `"还有"` 同时在枚举连接词列表中，"还有点吓人"会被双重计分 +3），导致大量正常叙述被误判为清单（典型 case：`"刚刚地震了，还有点吓人"` 被拆成 2 条 TodoItem）。每修一个 case 就冒出新的，干脆改成"必须先报上暗号"的特权通道。

> 旧 `_detectIntent` 函数保留在代码里，但 `isList` 判定已不再由它决定——它现在仅用于打分类标签（购物/任务/家务/工作/生活），传给 Stage 5 作为 fallback 类别。

### Stage 3: 条目拆分
按以下分隔符拆分为独立条目（优先级从高到低）：
- 顿号（、）— 优先级最高
- 逗号（,，）
- 枚举连接词（"还有"、"再买"、"以及"等）

### Stage 4: 结构提取
从每个条目中提取：
- **数量**: "2斤"、"3个"、"5瓶"
- **单位**: 斤、个、瓶、盒、袋等
- **时间**: "明天"、"下午3点"等
- 去除动词前缀（"买"、"拿"、"带"等）

### Stage 5: 自动分类
基于关键词匹配分配类别：

| 类别 | 关键词示例 |
|------|-----------|
| 购物 | 买、购、缺、没、要、超市 |
| 家务 | 打扫、洗、整理、擦、拖 |
| 工作 | 开会、报告、提交、审核 |
| 生活 | 取、送、缴费、预约 |
| 未分类 | 无匹配关键词（fallback 到 `_detectIntent` 的 intentType） |

## 数据模型

### TodoItem
```dart
class TodoItem {
  final String content;     // 核心内容
  final int? quantity;      // 数量（如 2、3）
  final String? unit;       // 单位（如 斤、个）
  final String category;    // 分类（购物/家务/工作/生活/未分类）
  final String? time;       // 时间信息
  final String rawSegment;  // 原始文本片段
}
```

### ExtractionResult
```dart
class ExtractionResult {
  final bool isList;           // 是否为清单（由触发词门禁决定）
  final List<TodoItem> items;  // 提取的条目列表
  final String normalizedText; // 预处理后的文本（包含触发词）
  final String? detectedIntent; // 检测到的意图类型（购物/任务/清单）
}
```

## 集成方式

**唯一调用点**：`lib/diary_tab.dart:1562`，日记页处理识别文本时调用。

```dart
// diary_tab.dart 中的处理逻辑
final extractor = ListExtractor();
final listResult = extractor.extract(text);

if (listResult.isList) {
  // 命中触发词且拆出 2+ 条 → 转 markdown 任务列表存入 diary 表
  final markdownContent = listResult.toMarkdown();
  // ... 写入 diary 表
} else {
  // 未命中触发词 → 走普通日记路径（含物品转存横条、查询答案区等检测）
}
```

**用户使用方式**：
- 想批量记录清单 → 开口说"代办..."或"待办..."即可
- 普通日记、记录物品位置、查询物品 → 正常说话，永远不会误触发清单

## 触发词边界行为详表

| 输入 | 行为 | 原因 |
|------|------|------|
| `代办买苹果、香蕉` | isList=true | 命中 + 拆出 2 条 |
| `待办买苹果、香蕉` | isList=true | 同音字变体同样接受 |
| `代办，买苹果、香蕉` | isList=true | 首尾标点被自动清理 |
| `代办苹果香蕉` | isList=false | 拆分后只 1 条（无顿号/逗号） |
| `代办买苹果` | isList=false | 拆分后只 1 条 |
| `代办` | isList=false | 剥离后内容为空 |
| `嗯代办买苹果、香蕉` | isList=true | 预处理先去"嗯" |
| `我说代办买苹果、香蕉` | isList=false | 触发词不在开头 |
| `刚刚地震了，还有点吓人` | isList=false | 未命中触发词 |
| `钥匙放在客厅` | isList=false | 未命中触发词 |

## 关键文件

| 文件 | 说明 |
|------|------|
| [lib/list_extractor.dart](../../lib/list_extractor.dart) | 清单提取器核心实现 |
| [test/list_extractor_test.dart](../../test/list_extractor_test.dart) | 单元测试（含触发词门禁边界测试） |
| [lib/diary_tab.dart](../../lib/diary_tab.dart) | 唯一调用点（line 1562） |

## 相关文档
- @speech-recognition.md - 语音识别整体流程（清单提取是第 4 步）
- @database.md - 物品存储表结构（清单条目实际写入 diary 表，不是 items 表）
