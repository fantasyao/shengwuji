# 音素热词架构

> 设置页入口：设置 → 识别与修正 → 「动态热词替换」分区（「音素匹配热词」
> 开关 + 替换阈值滑条；prefs key `phoneme_hotword_enabled` /
> `phoneme_hotword_threshold`，与 `PhonemeHotwordConfig` 一致）。

## 它解决什么问题

字面热词（`错词 = 正词` 逐字 replaceAll）只能纠正「一字不差」的错误：
识别出「买当劳」时，热词表里写的是「次握 = 次卧」这类确定错法就无能为力。
语音识别的错误绝大多数是**同音/近音字**，所以在字面替换之外增加一层
**按发音匹配**：把识别文本和热词都转成音素序列，发音相似度超过阈值才替换。

方案移植自 CapsWriter-Offline 的客户端热词（`core/client/hotword/`，
纯后处理、不碰识别模型）。sherpa-onnx 的 `hotwords` 参数只对 transducer
模型生效，本项目 SenseVoice（CTC）用不了模型侧热词，后处理是唯一路径。

## 设计原则（四条）

1. **字面打底，音素增强**：`TextProcessor.process` 内顺序固定为
   去空格 → 正则规则 → 字面热词替换 → **音素热词**。老条目零迁移自动获得
   发音匹配能力，关闭音素开关后退回纯字面行为。
2. **阈值分流，宁提示勿误换**：相似度 ≥ 强制阈值（默认 0.85）才静默替换；
   ≥ 相似阈值（0.60）只进 `lastPhonemeSimilars` 供 UI 弹一键替换提示。
3. **短热词保险丝**：别名气素数 <4（约单字 3 音素）即使过强制阈值也只提示
   不替换——单字误伤面最大（热词「猫」会想吃掉「毛」），CapsWriter 文档
   自认短词易误换，本侧做成硬约束。
4. **用户配置优先**：音素热词在 `ContextCorrector.correct`（同音词语境
   纠错）之前执行；用户显式配置的替换先落地，语境纠错只对其余位置兜底。

## 关键文件

| 文件 | 职责 |
|------|------|
| `lib/hotword/phoneme.dart` | `Phoneme` 七元组（值/语言/词首/词尾/是调/字始/字终）、`PinyinDict` 进程级缓存、`getPhonemeInfo` 文本→音素序列（中文声母韵母声调、英文逐字母、标点跳过但保留字符区间映射） |
| `lib/hotword/phoneme_corrector.dart` | 17 组模糊音表、词边界约束模糊子串 DP（`searchConstrained`）、阈值分流、冲突解决（分数>长度、区间不重叠、从后往前替换）、`PhonemeHotwordConfig` 调参集中地 |
| `lib/text_processor.dart` | 三格式解析（`parseHotwordEntries`）+ `process` 挂载音素阶段 + `appendHotwordPair`（修正对升级通道写入口） |
| `lib/widgets/hotword_promotion.dart` | 「一键修正」采纳后满 3 次追问「加入热词」的共享 UI |
| `assets/pinyin_dict.txt` | 汉字→tone3 拼音字典 20924 字（生成于 tools/pinyin/，数据源 pypinyin，MIT，全文在 assets/licenses/LICENSE-pinyin-data.txt） |
| `tools/pinyin/gen_pinyin_dict.py` | 字典生成脚本（UV 运行），内含 13 字权威自检，输出须 LF（`\r\n` 会毁掉声调尾字符校验） |

测试：`test/phoneme_hotword_test.dart`（25 例：转换对拍 pypinyin 权威值、
匹配用例手算分数、保险丝、冲突解决、三格式解析）。

## 音素化约定（与 CapsWriter 严格同参）

- 中文每字 → `[声母?, 韵母, 声调0-5]`，轻声记 5；zh/ch/sh 最长匹配，
  y/w 按惯用分界算声母，零声母（安 an1）韵母顶词首。
- 多音字取 pypinyin 默认读音（「长」= zhang3）。⚠️ 「长江 chang2」这类
  非默认读音的词要用别名兜底：写「长江 | 长江」无意义，应写成
  `长江 | 常江`（把会读错的写法列为别名），或依赖提示而非静默替换。
- 英文按驼峰/字母数字边界断 token 后**逐字母**拆分；数字整段一个音素
  （lang='num'）；标点/空格跳过，音素仍记录原文字符区间，替换按区间写回。
- 音素代价：同值 0 / 模糊音 0.5（前后鼻音 an-ang、平翘舌 z-zh、n-l、f-h、
  o-uo 等 17 组）/ 中文声调不同 0.5 / 英文 token 间 LCS 字符相似 / 跨语言 1。

## 匹配流程 `PhonemeCorrector.correct(text)`

```
getPhonemeInfo(text)                        → 输入音素序列（带字符区间）
  └ 对每条热词（target 自身 + 全部别名各一组音素）：
      searchConstrained(hw, input, 0.5)     → 词边界约束模糊子串 DP
        ├ 起点必须 isWordStart、终点必须 isWordEnd（只匹配整字整词）
        ├ score = 1 − 编辑距离/热词语素数
        ├ 行最小值早停剪枝（CapsWriter 同款，+2 放宽）
        └ 同终点只留最优
  └ 分类：score ≥ threshold 且音素数 ≥4 → 强制替换候选
          score ≥ similarThreshold        → similars（UI 提示）
  └ 冲突解决：分数优先 > 覆盖长度优先，区间不重叠，原文==目标只占位，
    从后往前写回
```

与 CapsWriter 的两处有意差异：① 不移植 FastRAG 倒排粗筛（个人热词几十~几百
条 × 短文本，全文 DP 毫秒级够用）；② 新增短热词保险丝（见设计原则 3）。

## 三格式热词（user_hotwords.txt，设置页同一文本框编辑）

| 格式 | 字面替换 | 音素匹配 | 例 |
|---|---|---|---|
| `错词 = 正词` | ✔（原行为） | ✔（正词为目标、错词为别名） | `次握 = 次卧` |
| `目标 \| 别名 \| 别名` | ✘ | ✔（别名全部参与匹配） | `Claude \| cloud \| 克劳德` |
| `目标`（整行一词） | ✘ | ✔（无别名） | `麦当劳` |

` | ` 别名格式可用作语音快捷短语（说别名上屏目标，如
`18200006666 | 我的手机号`）。注释行（#）与空行跳过。

## 修正对 → 热词升级通道

修正对（提示制，见 context-correction.md）只在字面完全一致时提示。
命中次数累计到 3 次（`PhonemeHotwordConfig.promotionHitThreshold`）后
提供升级入口，转成音素热词后发音近似的写法也自动替换：

- 日记/录入两链路「一键修正」采纳后，`maybePromptHotwordPromotion`
  追问「已出现 N 次，要加入热词吗」（`hit_count+1 ≥ 3` 才弹）。
- 修正对管理页每条 trailing「加入热词」按钮（≥3 次高亮，删除型对不给）。

写入口统一走 `TextProcessor.appendHotwordPair(target, alias)`：追加
`target | alias` 行 → 写盘 → 重解析 → 重建纠错器立即生效；已存在同
target+alias（跨格式解析判定）时不重复添加。必须用主实例调用
（管理页构造传入 `widget.processor`），写盘后主实例内存词表才同步。

## 提示链路（diary/record，其余链路只静默替换）

修正对没弹提示时，音素 similars 兜底弹「『X』听起来像热词『Y』」+
一键替换（`_offerPhonemeSimilarFix`）；两条提示互不叠加。悬浮窗速记
维持「只学不提示」原则（走同一 `process`，吃到替换不吃提示）。

## 调参速查（PhonemeHotwordConfig）

| 参数 | 值 | 含义 |
|---|---|---|
| `defaultThreshold` | 0.85 | 强制替换阈值（CapsWriter hot_thresh 同款） |
| `similarGap` | 0.10 | 相似提示阈值 = 强制阈值 − gap（默认 0.75，用户要求收窄提示带） |
| `minThreshold` / `maxThreshold` | 0.70 / 0.95 | 设置页滑条范围，越界回落默认 |
| `minPhonemesForReplace` | 4 | 短热词保险丝：低于此音素数只提示 |
| `promotionHitThreshold` | 3 | 修正对升级「加入热词」的命中次数门槛 |

0.85 的语义：9 音素的三字词最多容忍 1 个音素完全不同（或 2 个模糊音差异）。
调低到 0.75 左右「撒贝你→撒贝宁」（1 韵母 + 1 声调差，0.833）即可自动替换。

## Changelog

- 2026-09-21：首版。移植 CapsWriter-Offline 客户端音素热词（模糊子串 DP +
  17 组模糊音 + 词边界约束 + 阈值分流），pypinyin 同源字典 20924 字内置
  asset（lpinyin 因 SDK 上限 <3.0.0 弃用）；三格式热词解析，老条目零迁移
  自动音素化；短热词保险丝（音素 <4 只提示）；设置页开关/阈值；
  diary/record 音素相似兜底提示；修正对满 3 次「加入热词」升级通道
  （SnackBar 追问 + 管理页按钮）。
- 2026-09-23：提示线 0.60→0.75（similarGap 0.25→0.10，用户要求：0.67 一类
  低分不该弹提示）。修复带 action 的 SnackBar 永不自动消失：Flutter
  `SnackBar.persist` 默认 = `action != null`（超时计时器到点后对 persist
  直接 return），5 处提示（diary/record 相似替换、diary/record 修正对、
  热词升级提议）显式 `persist: false` 才按 duration 隐藏（相似提示 3s、
  修正对/升级提议 6s）。
