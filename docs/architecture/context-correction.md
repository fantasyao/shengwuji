# 同音词上下文纠错架构

> 设置页入口：设置 → 智能修正学习 → 「同音词上下文纠错」开关（默认开，
> prefs key `context_correction_enabled`，与 `CorrectionConfig.enabledPrefKey` 一致）。

## 它解决什么问题

语音识别（sherpa-onnx）经常把专有名词转成同音的普通词：
说「智谱」识别成「质朴」，说「深度求索」识别成「深度搜索」。这类错误
**文字写法不同、读音相同**，热词表可以硬替换，但「质朴」本身是正常词汇
（"这个人很质朴"），无脑替换会改错句子——所以需要结合上下文判断，
拿不准就不改。

## 设计原则（四条）

1. **词库提供候选，不决定答案**：同音词典只负责"这里可能有歧义"，
   选哪个写法由上下文评分决定。
2. **上下文决定答案**：候选词前后窗口内的已知词（related 加分 /
   conflict 减分 / 动态共现加分）加权投票。
3. **用户历史只是弱先验**：词频项 `0.2 × log(1+freq)`，同分微调用的，
   绝不允许"用户常说智谱"单独决定替换。
4. **低置信度不修改，宁漏勿错**：必须同时过「赢家绝对分 ≥ 7」和
   「领先次高 ≥ 15」两道阈值，不过就原样保留。

## 关键文件

| 文件 | 职责 |
|------|------|
| `lib/correction/homophone_dictionary.dart` | 同音组词典（`assets/homophones.json`），扫描文本找出歧义位置，提供全组候选 |
| `lib/correction/domain_dictionary.dart` | 领域词典（`assets/domain_words.json`），每个词的 related/conflict 上下文词表 |
| `lib/correction/context_scorer.dart` | 上下文评分器（纯静态无 IO）：窗口提取上下文词 + 加权打分 |
| `lib/correction/context_learner.dart` | 编辑学习分流器：同音组对改道共现统计，普通对进修正对表 |
| `lib/correction/pair_context.dart` | 修正对语境门控（纯逻辑）：学习时记错误片段左右邻接字符，提示前比对 |
| `lib/correction/context_corrector.dart` | 编排器：总开关、词库/统计预载、`correct()` 纠错入口、`learnFromEdit()` 学习入口 |
| `lib/correction/correction_config.dart` | 全部可调阈值集中地 |
| `lib/utils/correction_learner.dart` | 字符级 diff 抽取「错误-修正」对（两个功能共用的底层） |

测试：`test/context_corrector_test.dart`、`context_scorer_test.dart`、
`context_learner_test.dart`（纠错用例集就是 `CorrectionConfig` 调参的规格）。

## 词库资产（assets/）

- `homophones.json`：`{"groups": [["质朴","智谱"], ["深度求索","深度搜索"], ["同意","通义"]]}`。
  单词组（组内不足 2 词）加载时跳过。
- `domain_words.json`：每个词条带 `related`（出现即加分）与 `conflict`
  （出现即减分，即"保护词"）。例如「智谱」related = 公司/AI/GLM/大模型…，
  conflict = 性格/为人/真诚/品质…；「质朴」正好镜像。领域词表的
  related∪conflict 还充当**上下文词的封闭词表**——窗口内只扫已知词子串，
  不需要中文分词，零依赖。

## 纠错流程 `ContextCorrector.correct(text)`

五条转写链路（录入存物品 / 日记 / 搬家模式 / 悬浮窗速记 / 语音搜索）
都在 TextProcessor **热词替换之后**调用（如 `record_tab.dart` 的
`热词 → ContextCorrector.correct → _smartSplit`）。

```
总开关关 → 原样返回
词库/统计未加载 → ensureLoaded()（加载失败 = 纠错整体静默停用）
HomophoneDictionary.findMatches(text)   → 找出所有同音组命中位置
  └ 每个命中：ContextScorer.score() 给全组候选打分
      ├ 窗口 = 命中区间前后各 12 字
      ├ 上下文词 = 领域词表 ∪ 共现统计见过的词（同音组成员排除，
      │            贪心最长匹配，距候选越近权重越高：1.0 → 0.5 线性衰减）
      ├ Score = Σ 距离权重 × (related +10 / conflict −12 / 共现 min(count,5)×2)
      │          + 0.2 × log(1+用户词频)
      └ 排序取 top1 与 top2 的差
  └ winner ≠ 原文 且 top ≥ 7 且 margin ≥ 15 → 替换；否则原样保留
自动纠错结果只写日志，绝不回流成训练数据（防错误反馈循环）
```

要点：
- **无歧义不处理**：文本里没有同音组词时直接原样返回，开销可忽略。
- **赢家为原文时不替换**（`winnerIsOriginal` 短路）；**纯靠对手减分抬
  差距的 0 分赢家也不替换**（`minScore=7` 挡住）。
- 静态 related 单命中（+10）不足以过 15 的 margin，必须搭配第二条证据
  或对侧 conflict 减分——误改成本高于漏改。

## 学习流程 `ContextCorrector.learnFromEdit(original, edited)`

三个编辑保存点（存物品保存、日记编辑保存、悬浮窗卡片编辑）+ 两处
「一键修正」采纳都会调用；fire-and-forget，内部自吞异常。

```
CorrectionLearner.extract(original, edited)   → 字符级 diff 抽出修正对
ContextLearner.split(...) 按"是否同音组"分流：
  ├ 同音组对（质朴→智谱）：
  │    绝不进 correction_pairs 盲替换表！
  │    改道 → correction_context_stats 共现统计（用户选的词 × 上下文词）
  │        → correction_user_words 用户词频 +1
  │    并热更新内存，下一次 correct() 立即受益
  └ 普通对（饰品→视频）：进 correction_pairs 表（见下节）
```

这就是设置页文案"你的手动修改会帮它越学越准"的实现：用户改得越多，
共现统计越准，自动纠错的把握越大。

## 与「修正对管理」（correction_pairs）的关系

两套机制共用同一次 diff 抽取（`CorrectionLearner.extract`），但存储、
触发、替换方式完全不同：

| | 修正对管理（correction_pairs） | 同音词上下文纠错 |
|---|---|---|
| 触发方式 | 识别结果命中错误片段 → SnackBar 提示，**用户点「一键修正」才替换**（提示制） | 识别后**自动替换**，但只在很有把握时 |
| 判断依据 | 字面包含错误片段，无上下文 | 上下文评分 + 双阈值 |
| 用户学习行为 | 直接进表、强化 hit_count | 改道共现统计 + 词频 |
| 互相隔离 | 同音组对被 `isHomophonePair` 挡住，不提示也不进表 | 不消费 correction_pairs 表 |

隔离的目的：修正对是盲 `replaceAll`，若收录「质朴→智谱」会把
"这个人很质朴"也改掉；上下文纠错按语境裁决，两者不能打架。

## 修正对学习的取词：分词补全到完整词（2026-09-14 起）

单字改错是高频操作（点光标改一个字就保存），学习钥匙取「错误字 ± 固定
字符」会学出半截对（「直给→脂给」误伤真实词「直给」）。现在替换类片段
**按原文分词补全到完整词**（dart_jieba，`CorrectionLearner.wordSegmenter`
由 `ContextCorrector._loadSegmenter` 注入）：

- 「体直给」改「直」→ 学「体直→体脂」（不把下个待改字带进钥匙）
- 「管管雎鸠」改「管」→ 补全到「管管」（AA 叠词钥匙区分度低，再并入
  紧邻一个内容词）→ 学「管管雎鸠→关关雎鸠」
- 单字词（补全后仍 <2 字）回退固定吸收凑区分度；删除对不走分词补全
  （维持删除类右侧优先吸收，见 2c06237）
- 对**原文**分词而非改后：ASR 错误保留词界结构；改后文本会被 HMM 带偏
  （「关关雎鸠」切成「关关雎|鸠」）
- jieba 词典（assets/jieba_dict.dgz，2MB）运行时拷到数据库目录再初始化
  （dart_jieba 用 dart:io 读文件，APK 内 asset 不是文件路径）；初始化失败
  静默回退固定吸收
- 分词器未注入时（回退路径）：替换类两侧各吸一个字符（旧行为），
  `test/correction_learner_default_path_test.dart` 守默认注入路径

### 双钥匙：整词钥匙 + 短核兜底（2026-09-14 起）

整词钥匙准但易漏——下次 ASR 错得稍不一样（「管管雎鸠」错成「管管雎究」）
就 match 不上。`CorrectionLearner.extractAll` 同时产出两把钥匙，学习时
两条都入库（`ContextLearner.split` / 词库回退分支）：

- **primary**：分词补全的整词钥匙（管管雎鸠→关关雎鸠），误伤少、提示文案可读；
- **shortCore**：固定吸收的短钥匙（管管→关关），错误串变形时兜底命中。

提示场景用 `dedupeSubsumed` 折叠短核（判定：错误侧与修正侧**互为子串**
才是双钥匙——「脂给」不是「体脂率」的子串，故「直给→脂给」与
「体直给→体脂率」是两条独立规则不折叠），"共 N 处"计数不虚高；替换
仍用全集：`applyCorrections` 长钥匙先应用，短钥匙只兜底残余位置。
管理页会看到同一错误的两条（长/短钥匙），各自独立 hit_count。

## 修正对提示的语境门控（2026-09-13 起）

修正对原本是**纯字面匹配**：识别文本包含错误片段就弹一键修正提示。
个人口音/专名对（影视→隐私、co林兰→coding plan）由此学到后，在
**错误语境**里也会误提示——「今晚看的影视不错」被「互联网影视可控」
学到的对打扰。语境门控给提示装上眼睛：

- **学习时**（`ContextCorrector.learnFromEdit` 学普通对的分支）：
  `PairContextGate.extract` 从识别原文中错误片段的每个出现位置，记录
  边界两侧各 ≤4 个"词字符"（中文/字母/数字，标点空格剥离、ASCII 折叠
  小写），存入 `correction_pair_contexts` 表（同一对可积累多条档案）。
- **提示时**（record_tab / diary_tab 两处 `_offerCorrectionFix`）：
  取当前文本中错误片段出现位置的同样邻接字符，与档案比对——左侧比
  公共后缀、右侧比公共前缀（两边都以错误片段为锚点），任一侧连续
  共享 ≥2 字符即同语境，弹提示；全不沾边则安静。

为什么用**锚定边界的字符指纹**而不是领域词表的词：学到的对多来自
个人口音/专名，其语境词（互联网/可控）不在任何封闭词表里，字符指纹
不依赖分词和词库，中英混排通用；2 字符门槛挡掉"的/了"类函数词撞车。

精度优先的取舍：

- **无档案的对照旧字面提示**（老数据/导入/学自裸片段）——门控只为砍
  误提示，不为吞掉本该出现的提示。说整句"co林兰"这类无邻接场景因此
  不受影响（学不到档案 = 永远放行）。
- **裸片段撞上有档案的对不提示**——上下文全无时提示纯属猜测。
- **同义词语境会漏提示**（档案"可控"、这次说"权限管理"）：静默漏掉，
  用户再手改一次即补上该语境档案，越用越准——与同音纠错的学习闭环
  同构。
- 仍是提示制，不碰自动替换；误匹配的代价只是多/少一次提示。

## DB 表（V12/V13 新增，db_helper.dart）

- `correction_context_stats(source_word, context_word, count)`：
  同音词 × 上下文词共现计数，主键去重；容量 3000 行，超出按 count
  从低到高淘汰。
- `correction_user_words(word, frequency, last_used_at)`：用户选用词频
  （弱先验）。
- `correction_pair_contexts(error_text, corrected_text, left_context,
  right_context, hit_count)`：修正对语境档案（V13）。四列业务键去重、
  容量 2000 行按 hit_count 淘汰；修正对单条删除/清空时级联删除。
- （V11 的 `correction_pairs` 属修正对管理，见修正对管理小节/页面。）

## 调参速查（CorrectionConfig）

| 参数 | 值 | 含义 |
|---|---|---|
| `contextWindowChars` | 12 | 候选前后上下文窗口字数 |
| `relatedHitScore` | +10 | related 命中加分（× 距离权重） |
| `conflictPenaltyScore` | −12 | conflict 命中减分（保护词） |
| `cooccurrenceScorePerCount` | ×2 | 动态共现每单位计数分值 |
| `cooccurrenceCountCap` | 5 | 单条共现计数封顶（防统计爆炸） |
| `userFrequencyWeight` | 0.2 | 用户词频弱先验系数 |
| `minScore` | 7 | 赢家绝对分下限（低于不动原文） |
| `minMargin` | 15 | 赢家领先次高的最小差距 |
| `contextStatsCap` | 3000 | 共现统计表容量上限 |

调参以 `test/context_corrector_test.dart` 的验收用例为规格：
「应改」用例须过双阈值，「防误改」用例必须全部不触发。
