# 云同步架构（WebDAV）

## 概述

通过 WebDAV 协议把四类文本数据同步到用户自选网盘（坚果云、Nextcloud、
Alist 等）。**一个 WebDAV 后端通吃所有支持该协议的网盘**；将来接
Google Drive / OneDrive（都不支持 WebDAV，走各自 OAuth API）时在
`SyncBackend` 抽象口加适配器，同步引擎不动。

边界（用户拍板，日记自 v2 起放开编辑/删除）：

- **手动触发**：设置 → 云端同步 → 立即同步；随手记列表与悬浮窗展开面板
  另支持**下拉刷新**（2026-10-24 加入，见「下拉刷新入口」），App 仍不后台
  自动联网
- **同步范围**：日记（文字）、物品记录、热词、修正对；**录音文件走
  独立开关「同步录音文件」，默认关**（2026-09-23 加入，用户显式开启
  才传——WAV 约 2MB/分钟，涉及网盘流量与空间）；**截图附件双向同步**
  （2026-10-24 加入，见「截图附件同步」）
- **合并语义**：**日记走 v2 三方合并，编辑与删除双向跨端传播**
  （2026-10-24 加入，见「v2 编辑与删除同步」）；**物品记录、热词、
  修正对仍是「新增条目」双向并集**，编辑、删除不跨端传播（本机删除
  靠墓碑防复活，见下）

## 云端布局

远端目录（默认 `/shengwuji_sync`，可配置，ASCII 路径规避个别服务端
非 ASCII 路径编码差异）六个 v1 数据文件 + 录音子目录 + v2 命名空间：

```
/shengwuji_sync/
├── manifest.json          # v1 软锁 + 版本 + 最后同步者 + 各类条数（诊断用）
├── diary.json             # v1 投影：日记数组（uuid/content/created_at/audio 文件名/时长/归档/标注/排序键 sort_order）
├── items.json             # 物品数组（uuid/name/location）
├── hotwords.txt           # 原样热词文本（与本地 user_hotwords.txt 同格式）
├── correction_pairs.json  # 修正对数组（error/correct/hit_count/created_at/last_used_at）
├── audio_index.json       # 已上传录音文件名数组（上传去重索引，开关开启才读写）
├── image_index.json       # 截图索引：笔记 uuid → 图片 sha/格式/大小/来源设备
├── audio/                 # 录音本体（文件名 = 本地 diary_audio 里的 basename）
└── v2/
    ├── manifest.json      # protocol_version / min_reader_version / writers{设备→last_seen} / counts
    ├── notes.json         # 日记全量：uuid/content/created_at/updated_at/rev/mark/archived/locked/sort_order/tags/attachments/extras
    ├── tombstones.json    # 日记删除墓碑（uuid + deleted_at，非 note 类型行原样保留）
    └── assets/<xx>/       # 截图本体（内容寻址目录，xx = sha 前两位）
```

**少文件整包**是刻意设计：坚果云免费版限 600 请求/30 分钟（超限封
约 6 小时），Joplin「每条记录一个文件」在坚果云上首次同步即被限流。
请求构成：探测 + 清单/v1/v2 数据文件读取共约 10 个 GET，加软锁与解锁
2 个 PUT 打底；**七个数据文件（v1 四个 + v2 三个）一律「内容没变不
PUT」**（见「write-if-changed」），所以常态同步（云端与本地一致）约
12 个请求，有新数据时才按文件各加一次 PUT。即使高频手动同步也远低于
限额。客户端另按「本机发出的请求数」滚动记账，设置页据此估算余量（见
「本机请求计数」——本机数不等于账号剩余额度，电脑端消耗看不到）。

> **v1 与 v2 并存**：`diary.json` 是 v1 投影，仍随每次同步全量回传，
> 供只认 v1 的旧客户端读；**日记的编辑/删除以 `v2/notes.json` +
> `v2/tombstones.json` 为准**，v1 投影只承载新增与本机状态。v2 里
> tags/attachments/extras 等手机端不认识的字段经 `sync_note_meta` 表
> 原样透传，手机回写不会抹掉电脑端的数据（详见「v2 编辑与删除同步」）。

> **截图附件双向**（v17 `diary.image_path` + v18 `diary_images`，
> 2026-10-24）：截图与电脑端图片都不编入 `diary.json`、不进备份；两端
> 把图片按 sha256 写到共享的 `v2/assets/`，并在根目录
> `image_index.json` 登记「笔记 uuid → 图片」。电脑端把手机截图挂成
> `origin='mobile'` 附件；手机把电脑端图片下载到 `diary_images` 表，
> 一条笔记可多张（`position` 排序），悬浮窗/随手记显示数量并按序列
> 左右滑动。详见「截图附件同步」。

## 同步流程（`CloudSyncService.sync()`）

```
1. ping 鉴权 + readProps 探测远端目录（404 → mkdirAll 递归建）
2. 读 manifest.json（404 = 首次同步，视为空清单）+ v2/manifest.json
   版本守卫：远端 protocol_version/min_reader_version 高于本机支持（2）
   → 抛错中止整次同步（放在拿锁前，不按旧规则写新命名空间）
3. 软锁检查：他机持锁且未超时（10 分钟）→ 中止提示
   否则写 manifest 置锁 {device_id, at}
4. 下载 v1 数据文件 + v2/notes.json + v2/tombstones.json（404 按空处理；
   v2 文件 JSON 损坏视为不可用，抛 FormatException 中止，绝不当成空集合
   回写抹掉远端数据）
5. 合并入本地（见下节；ensureSyncUuids 先兜底补齐缺失 uuid）
   5a. 物品/热词/修正对：v1 并集合并（mergeDownloadedText 等）
   5b. 日记：v2 三方合并 → 落库（mergeLocalDiariesV2 +
       DbHelper.applySyncV2Notes，含透传元数据与墓碑回写）
6. 发布 v2 合并结果：先 v2/ 目录，再 notes.json → tombstones.json →
   v2/manifest.json 全量 PUT；内容有变化才写（sameV2Content 忽略
   generated_at/device_id 与本机 writers.last_seen，防止两端互相
   刷新 ETag 乒乓）
6.5 录音下载（开关开启才跑）：远端带 audio 名且本地缺文件的条目，
    逐个 GET audio/ 落盘到本地 diary_audio/ 并按 sync_uuid 回填
    audio_path（404 跳过不计错）；随后的全量回传会把回填结果随
    diary.json 上云，第三台设备即可发现同名音频
7. 回传合并后的本地 v1 状态（四个文件；内容没变不 PUT，见「write-if-changed」）
7.5 录音上传（开关开启才跑）：本地有音频文件的行与 audio_index.json
    求差，缺的逐个 PUT 到 audio/，成功的逐个记入索引并回写
7.8 截图同步（双向）：本地截图/电脑端图片本体分批 PUT 到 v2/assets/、
    合并并回写 image_index.json；电脑端多图按索引 GET 落 diary_images
    （多张全留、position 排序），本机截图丢失时按索引恢复一张
    （失败只记提示，不拖垮文本同步）
8. 写 manifest 解锁 + 更新 counts / updated_at（写回时以原始 JSON 铺底，
   保留另一端加的未知字段）
```

失败时尽力回写「锁=null」防死锁；没来得及释放的锁靠 10 分钟超时
自动过期兜底。WebDAV 无原子 test-and-set（坚果云不保证 ETag
If-Match），软锁只防常规误并发，极端同时点击下可能双开——后果仅是
多传一次相同数据，无一致性风险。

## write-if-changed（内容没变不 PUT）

七个数据文件每次同步都参与裁决，但**绝大多数同步是「云端与本地已经
一致」**——无条件整包 PUT 只是把同样的字节再传一遍，还顺带刷新 ETag
让对端下一轮白跑。统一改成先比内容、没变就跳过（v1 走
`CloudSyncService.v1FileUnchanged`，v2 走 `sameV2Content`）：

- **比较口径**：逐字符相同即未变（`hotwords.txt` 这类纯文本只走这条）；
  否则两侧都能解析成 JSON → 用 `sameJsonContent` **递归排序对象键**后比
  序列化结果——另一端写法的键序、缩进差异不该被当成变更
- **数组顺序参与比较**（刻意不排序）：行序真的变了就照旧 PUT，宁可多写
  一次也不漏写。v1 行序来自 `queryAllDiaries`/`queryAll` 的稳定 SQL，
  跨端只在合并插入时才变动
- **v2 额外忽略易变字段**：`generated_at`/`device_id`（清单再加
  `updated_at`）与 `writers` 里**本机**条目的 `last_seen`——这些每次同步
  必然不同，不忽略就等于永远有变更；其他设备的 `writers` 条目仍参与比较
- **失败与未知情况一律「按有变更处理」**：`previousRaw` 为 null（首次
  同步云端还没这个文件）、云端文件解析失败 → 整包覆盖，本机状态是合并
  后的超集，覆盖即自愈
- **跳过不改变语义**：`diary.json` 仍是全量视图（老版本 App 只认 v1，
  该回传的一定要回传），录音下载回填 `audio_path` 后内容确实变了、照常
  PUT；跳过只在日志里记一条「v1 数据文件 N 个内容未变，跳过回传」，
  不进用户可见统计
- **manifest 不在其列**：置锁与解锁两次 PUT 是软锁语义本身，必须写

## 录音文件同步（独立开关，默认关）

- **限流分批**：坚果云免费版 600 请求/30 分钟、超限封约 6 小时，录音
  首批动辄数百个文件。单次同步上传/下载各限 `kAudioSyncBatchLimit`
  （80 个），超出的留待下次手动同步续传；上传靠云端 `audio_index.json`
  去重（已传名单），后续每次同步录音只占 0~2 个请求（索引读+写）
- **不拖垮文本**：录音阶段整体 try/catch，失败只往 stats 里记一条
  「录音部分失败，下次同步续传」，同步成功状态与待同步快照不受影响；
  上传中途断网也尽力把已成功文件名落盘索引（重传幂等，只浪费流量）
- **墓碑不拉回**：本机删过的日记 uuid 在墓碑表，其音频同样不下载
  （文本已被墓碑压掉，音频同理不拉回）；上传侧行已删自然不在候选里，
  云端已传的文件不删（没有可靠的删除通道，且索引/其他设备仍可能引用）
- **上传候选以 DB 行为准**：`audio_path` 指向且文件实际存在的才算数，
  孤儿文件不传；下载落盘名过 `isSafeAudioName` 校验（无路径分隔符/
  非 `..`），防云端 JSON 被写坏后落盘逃出 diary_audio 目录
- **回填不 bump 数据版本**：音频下载成功后 `updateDiaryAudioPathByUuid`
  恢复 audio_path，属同步的附属恢复而非用户侧变更（basename 与云端
  JSON 本就一致），不触发「有新数据待同步」
- **已知边界**：云端 audio_index 说已传但文件被网盘端清理 → 不会自动
  重传（索引与实际文件不逐个核对，核对即逐文件 PROPFIND，请求量不可
  接受）；两设备同秒各录一条 → 文件名撞车后传者覆盖先者（概率极低，
  P1 不处理）

## 截图附件同步（双向，2026-10-24）

截图（手机 `diary_images/diary_<id>_<millis>.jpg`，原生 JPEG）与电脑端
笔记图片体量比录音小、但同样不适合塞进 diary.json：单张可达数 MB，整包
重传会把每次文本同步撑大。复用电脑端已有的内容寻址资产目录，让两端各取
所需：

- **索引与本体分离**：根目录 `image_index.json` 记录
  `{note_uuid, device_id, sha256, name, mime, size, updated_at, position,
  source}`；图片本体在 `v2/assets/<sha 前两位>/<sha>.<ext>`（电脑端既有
  布局，两端口径一致）
- **归属与多图**：索引按 `(note_uuid, device_id, sha256)` 唯一，每台设备
  只替换/移除自己写的条目；同一笔记同一设备可以有多张（`position` 决定
  展示顺序，电脑端附件 `sortOrder` 映射而来）。手机自拍截图仍是每笔记
  一张（`diary.image_path`），电脑端图片全部下收到 `diary_images` 表，
  卡片显示 `image_count`、首图按 `position` 取 `primary_image_path`
- **来源透传**：`source='desktop'` 标记电脑端发布的条目；手机回写索引时
  原样保留，否则电脑端会把自家图片当手机图重复挂接。缺省/空串按手机
  截图处理，兼容旧索引
- **只发布确认可拉的条目**：先传本体再写索引；上传失败/超限（单次
  `kImageSyncBatchLimit` = 80 张）的笔记保留云端旧条目，避免电脑端按
  索引拉到不存在的资产或丢掉上一张还能看的图
- **删除边界**：手机删掉截图时移除自己的索引条目，电脑端下次同步摘掉
  对应附件；电脑端删除图片同理，手机下次同步按 merged 索引裁剪
  `diary_images` 行与本地文件（笔记仍在本地但条目已消失，或笔记已删且
  命中墓碑）。索引条目本身不随笔记删除而摘除——`image_index.json` 按
  设备所有权合并，摘除别人挂的图不属于手机职权；笔记经 v2 墓碑在电脑
  端删除后，其条目自然失效，不靠删索引传播。索引 JSON 损坏按「不可用」
  处理，绝不当成空索引回写，否则会抹掉另一端已发布的条目
- **手机端删图入口只对本机截图开放**（2026-10-25 用户拍板）：图集左上角
  🗑 走 `updateDiaryImage(id, null)` + 删文件，下轮同步本机条目自然消失；
  电脑端同步来的图在手机上不给删除按钮（点了只提示去电脑端删）——即便
  临时摘掉本地行与索引条目，来源端笔记附件仍在、下轮会重发布并被本机补
  下，语义不稳定，故不做「只删手机本地副本」的假删除
- **下载副本不再转发**：手机下载别机图片时落盘为 `diary_sync_<uuid>_
  <sha>.<ext>`，构建上传条目时跳过这个前缀——否则来源手机换图后，
  接收手机的旧副本会以它自己的设备身份把旧图重新发布
- **失败隔离**：整段 try/catch，失败只在 stats 记「截图同步失败，下次
  同步重试」，文本同步照常成功；下载校验 sha 与 20 MB 上限（与电脑端
  `importBlob` 同规则）。有实际下载或裁剪才 bump `DiarySyncBridge`
  （悬浮窗展开时重查库）
- **协议保护**：远端 `v2/manifest.json` 的 `min_reader_version` 高于本机
  支持（2）时跳过截图同步，不按旧规则写新命名空间（主同步流程更严：
  整次同步直接中止，见「v2 编辑与删除同步」）

手机端实现：`image_sync.dart`（索引模型/归属合并/下载计划纯函数）+
`cloud_sync_service._syncImages`（网络与落库）+ `db_helper` 的
`diary_images` 读写；展示层见 @docs/architecture/floating-window.md
「卡片截图附件」与 @docs/guides/ui-patterns.md「图片附件图标」。

## 合并策略

| 数据 | 合并键 | 规则 | 实现位置 |
|------|--------|------|----------|
| 日记 | sync_uuid | **v2 三方合并**（基线哈希判谁改过 → 单边改改者胜、双边改 LWW → 墓碑优先），编辑与删除双向传播 | `mergeV2Notes` + `DbHelper.applySyncV2Notes` |
| 物品 | sync_uuid；自然键 name+location | 新增并集（**v2 items 未落地**，编辑/删除仍不跨端） | `planItemInserts` |
| 热词 | 行级并集；字面对（错词=正词）同错词保留本地 | 本地意图优先 | `mergeHotwordContent` |
| 修正对 | (error_text, corrected_text) | hit_count 取大、last_used_at 取新 | `DbHelper.mergeRemoteCorrectionPairs` |

> 日记的 v1 投影（`diary.json`）仍随每次同步全量回传，合并键是
> sync_uuid + 自然键 content+created_at，只做新增并集——它是给只认 v1
> 的旧客户端看的兜底视图，**不再是日记合并的裁决依据**。v1 里缺失的
> 条目在 v2 合并前作为「导入候选」进内存（同 uuid 已有 v2 记录时取更
> 完整的 v2 那份），不预先落库，避免 v1 无 `updated_at` 造成的假平局
> 把电脑端的 tags/图片/extras 覆盖掉。
>
> 排序键 sort_order（v16 悬浮窗长按拖动排序）随 v2 笔记上云，随内容
> 一起被 LWW 裁决；**新行落库**仍是：本地活跃区为空尊重远端原值（整区
> 搬过来顺序不变），非空则按 `created_at` 插进本机现有顺序——取显示
> 顺序中「最后一条比它新的行」的 sort_order 同值落位（同值由 getDiaries
> 的 `created_at DESC` 兜底），既有行的 sort_order 一个不动（整区重编号
> 会让所有笔记载荷指纹变化、下轮同步全量重传）。这样电脑端补同步的旧
> 笔记会落在对应时间位置，不会一口气堆到最前面（2026-10-25 用户反馈）。
> 归档行 sort_order 恒为 null；远端没给顺序时保留本机值（拖动排序
> 不 bump `updated_at`，两端各自重排的顺序不互相覆盖）。

- **自然键辅助去重**的原因：本地备份 ZIP 导入会给复原行造新 uuid，
  只按 uuid 合并会把同一内容同步成两条；content+created_at（微秒级
  时间戳）相同即视为同一条。
- **上传全量而非增量**：合并后本地 ⊇ 远端，全量回传即达成并集，且
  顺带自愈云端历史脏数据；各端最终收敛一致。「全量」指**视图**是全量，
  不代表每次都传真份——内容一致时按 write-if-changed 跳过 PUT
- **下载变更 bump 悬浮窗计数**：日记/物品有实际插入或更新、或日记被
  远端墓碑删掉时 `DiarySyncBridge.bump()`——悬浮窗跑在独立 engine，
  展开时只比对计数才重查库（`overlay_home._syncDiariesIfChanged`）；
  不 bump 会出现电脑端同步来的日记随手记可见、悬浮窗一直显示旧列表
  （2026-10-23 真机反馈）。代价：已展开中的面板要等下一次收起/展开才刷新
- **统计口径**：v2 合并只报「下载/更新/删除日记 N 条」，且**只有落库
  字段真的变了才算更新**（`_diaryRowDiffers`）——仅基线哈希变化不打扰
  用户；冲突副本是本机裁决产物，不计入「下载日记」

### v2 编辑与删除同步（2026-10-24）

电脑端 v2 契约的手机端实现，让日记的编辑与删除在电脑 ↔ 手机双向传播。
裁决规则与电脑端 `SyncMerger` 逐字对齐（同一份数据两端算出的结果必须
一致，否则会出现乒乓覆盖）：

- **`updated_at`（v19 列，毫秒）**：所有用户侧写日记的路径 bump
  （增删改、归档/还原、锁定、标注；`updateDiary` 写内容必刷）。
  **刻意不 bump** 的两个：悬浮窗拖动排序（`reorderActiveDiaries`）与
  截图替换（`updateDiaryImage`）——它们改的不是文本载荷的跨端语义，
  截图另有 `image_index.json`。存量行首启用 `created_at` 的瞬时回填
  （幂等），保证老数据有个确定时间戳参与 LWW
- **基线哈希 `base_hash`**：每次同步成功后把该笔记的 `payloadHash` 写进
  `sync_note_meta`。下次合并据此判断「相对上次同步，是本地改了还是远端
  改了」——**单边改 → 改者胜且不产生冲突副本**；双边都改 → LWW。没有
  基线（首次接 v2 / 状态丢失）时只按 LWW 且不建冲突副本，避免把存量
  差异误判成冲突
- **载荷哈希 `payloadHash`**：与电脑端同算法，覆盖 content/mark/archived/
  locked/sort_order/附件（按 payloadKey 归一后排序）/extras（有 tags 时
  并入 tags）；**`uuid`、`created_at`、`updated_at`、`rev` 不入指纹**
  （时间戳入指纹会让每次同步都被判成「本地也改过」）。平局（时间戳完全
  相同）用 payloadHash 字典序裁决，保证所有设备选同一赢家
- **5 分钟冲突窗口**：双方都改且时间差 ≤ `kV2ConflictWindow`（5 分钟）
  时，给输家留一份冲突副本（新 v4 uuid + `extras.conflict_of` 指向原
  笔记），**只在输家设备本地生成一次**，不会两台设备各建一条
- **墓碑与复活**：本机删除日记时写 `sync_deleted`（kind='diary'），合并
  时随 `v2/tombstones.json` 全量发布 → 远端和其他设备下次同步删掉对应
  行（`applyRemoteTombstones`）。**墓碑优先于内容**，但
  `updated_at > deleted_at` 允许复活（删了又重建的合法场景），复活时清
  本地残留墓碑（`removeSyncTombstones`）。非 `note` 类型的墓碑行
  （电脑端可能有 items）原样保留回写，不替别人做裁决
- **电脑端独有字段的透传**：手机端不解析 `tags` / `attachments` /
  `extras`，它们整份存在 `sync_note_meta`（`tags_json` /
  `attachments_json` / `extras_json`），写回 v2 时原样带出；本机音频
  附件按 `audio:<name>` payloadKey 与 `diary.audio_path` 双向归一，附件
  uuid 用 v5(namespace, note_uuid + name) 稳定生成，不随同步漂移
- **首次接 v2 用 seed**：本机某笔记还没有 meta 时，本地笔记以远端同
  uuid 记录为 seed 构建（保住手机不认识的标签/图片/未知字段）。否则
  「手机本地行 vs 电脑端富记录」的载荷差异会被判成本地单边改，把
  电脑端的 tags/附件写没
- **协议保护**：远端 `v2/manifest.json` 的 `protocol_version` /
  `min_reader_version` 高于本机支持（2）→ 整次同步中止并给出中文提示，
  绝不按旧规则写新命名空间；v2 文件 JSON 损坏同样中止（`FormatException`
  走 `_friendlyError` 首道映射），**不当成空集合回写**——否则等于把
  云端全部笔记/墓碑清空
- **写回保真**：v1 `manifest.json` 与 v2 三文件都先铺底远端原始 JSON 再
  覆盖本机字段（`SyncManifest.raw` / `topExtras` / `preservedRows`），
  顶层未知字段不丢；`v2/manifest.json` 的 `writers` 保留其他设备条目，
  只更新本机 `last_seen`
- **没变不 PUT**：v2 三文件与 v1 四个数据文件同一套 write-if-changed
  纪律，比较口径（忽略 `generated_at`/`device_id`、清单再忽略 `updated_at`
  与本机 `writers.last_seen`）与电脑端逐字对齐，见「write-if-changed」
- **已知边界**：① **items 未进 v2**——物品记录的编辑与删除仍不跨端；
  ② 冲突副本的 `audio_path` 为 null（音频不随副本下载）；③ v1 投影
  不含 v2 独有附件信息，只认 v1 的旧客户端仍只看文本；④ 截图本体走
  `image_index.json`，不走 notes 附件；⑤ 手机把 tags 写成 v2 顶层字段，
  读取时兼容电脑端把 tags 塞在 `extras` 里的写法（摘出为顶层并从 extras
  移除，避免同一份标签在指纹里出现两次）

### 删除与墓碑（防复活）

日记删除自 v2 起**跨端传播**（见上节）；物品删除仍是「本机防复活」：

- `diary`/`items` 所有删除入口（日记页左滑、悬浮窗、电脑访问服务、
  搬家模式撤销）都汇聚在 `DbHelper.deleteDiary`/`deleteItemById`，
  删除前把行上的 sync_uuid 写入 `sync_deleted` 墓碑表（带 kind）
- v1 下载合并时 uuid 命中本地墓碑的远端条目不插入；v2 合并时本地墓碑
  直接压掉同 uuid 的远端笔记（除非远端 `updated_at` 更新）
- `clearAllData()`（导入备份前清空）全量记墓碑：「替换本地」语义下
  被清掉的历史行不得复活；导入的新行是全新 uuid，不受影响
- 物品的已删记录因此仍留在云端与其他设备上，各端条数可能暂时不同——
  items 进 v2 后收敛

## 模块结构

| 文件 | 职责 |
|------|------|
| [lib/sync/sync_models.dart](../../lib/sync/sync_models.dart) | 三类数据载荷 + 四文件编解码 + manifest/软锁模型 + 音频索引解码（纯函数，解码宽容：坏行跳过不抛） |
| [lib/sync/sync_merge.dart](../../lib/sync/sync_merge.dart) | 热词合并 + 日记/物品插入计划 + 录音上传/下载计划（纯函数，单测覆盖） |
| [lib/sync/image_sync.dart](../../lib/sync/image_sync.dart) | 截图索引模型/编解码、按设备归属合并、下载计划、图片格式识别（纯函数，单测覆盖） |
| [lib/sync/sync_v2.dart](../../lib/sync/sync_v2.dart) | v2 契约：笔记/附件/墓碑/清单模型与编解码、payloadHash、UTC 时间口径、本地行 ↔ v2 笔记与 meta 行互转、write-if-changed 比较（`sameV2Content` 忽略 generated_at/device_id 与本机 writers.last_seen；`sameJsonContent` 递归排序键，v1 也复用）、版本守卫高于支持版本抛 FormatException（纯函数，单测覆盖） |
| [lib/sync/sync_v2_merge.dart](../../lib/sync/sync_v2_merge.dart) | v2 三方合并裁决（基线哈希 → 单边改/LWW/冲突副本/墓碑与复活，纯函数，单测覆盖） |
| [lib/sync/cloud_sync_service.dart](../../lib/sync/cloud_sync_service.dart) | 同步引擎 + 配置存取（CloudSyncConfig）+ v2 合并落库与发布编排 + 录音/截图编排（分批/容错/索引回写）+ 友好错误映射 + 唯一 WebDAV 客户端出口（`createClient` 挂请求计数拦截器） |
| [lib/sync/webdav_request_counter.dart](../../lib/sync/webdav_request_counter.dart) | 本机 WebDAV 请求预算：滚动 30 分钟分钟桶、600/1500 估算、双 engine 追加日志与合并、启动/运行期压缩、到期刷新（ChangeNotifier） |
| [lib/db_helper.dart](../../lib/db_helper.dart) | v14 迁移（sync_uuid 列 + sync_deleted 表 + 存量回填）、v19 迁移（diary.updated_at + sync_note_meta 透传表）、增删改钩子、远端行插入、修正对行级合并、截图/录音路径回填、`applySyncV2Notes` 单事务落库 |
| [lib/settings/cloud_sync_page.dart](../../lib/settings/cloud_sync_page.dart) | 二级页：服务配置/测试连接/立即同步/请求预算行/说明 |
| [lib/settings/webdav_budget_line.dart](../../lib/settings/webdav_budget_line.dart) | 「最近 30 分钟」请求预算行（本机合计、80% 变红、只统计本机说明） |
| [test/sync_merge_test.dart](../../test/sync_merge_test.dart) | 合并裁决与编解码单测 |
| [test/sync_image_test.dart](../../test/sync_image_test.dart) | 截图索引编解码/归属合并/下载计划/路径回填单测 |
| [test/sync_v2_test.dart](../../test/sync_v2_test.dart) | v2 编解码与载荷哈希等价性、版本守卫、write-if-changed、三方合并全场景、本地行 ↔ v2 互转与 seed |
| [test/db_upgrade_v19_test.dart](../../test/db_upgrade_v19_test.dart) | v18→v19 迁移（updated_at 回填 + meta 表）、`applySyncV2Notes` 增改删语义 |
| [test/cloud_sync_v2_merge_test.dart](../../test/cloud_sync_v2_merge_test.dart) | `mergeLocalDiariesV2` 端到端落库：首次导入保富字段、双向编辑、冲突副本、远端墓碑删除 |
| [test/cloud_sync_v1_write_if_changed_test.dart](../../test/cloud_sync_v1_write_if_changed_test.dart) | v1 数据文件「内容没变不 PUT」判断（键序宽容/行序严格/文本逐字符/坏文件覆盖） |
| [test/webdav_request_counter_test.dart](../../test/webdav_request_counter_test.dart) | 请求计数：滚动窗口/剩余钳 0/追加日志恢复/坏行/启动与运行期压缩/双 engine 合并与快照/到期时长 |
| [test/cloud_sync_request_counting_test.dart](../../test/cloud_sync_request_counting_test.dart) | 拦截器口径：ping 与 404 探测都 +1、先计数后发送、无计数器时请求照常 |
| [test/webdav_budget_line_test.dart](../../test/webdav_budget_line_test.dart) | 设置页预算行文案、剩余数、80% 变红与滑出窗口提示 |

依赖：`webdav_client`（dio 底层，Basic/Digest 认证）、`flutter_secure_storage`
（密码存 Android Keystore；地址/账号存 SharedPreferences 供入口行摘要同步读）、
`uuid`、`crypto`（截图按 sha256 内容寻址）。设备标识 `cloud_sync_device_id`
（prefs，首次生成）。

### DB 侧不变量

- **任何新增 diary/items 的路径都必须带 sync_uuid**：`insertDiary`/
  `insertItem`/`batchInsert*` 已内置生成；`_seedTutorialDiaries` 等直接
  batch.insert 的路径靠 `ensureSyncUuids()`（同步前调用）兜底
- **任何删除路径都必须记墓碑**：新代码删行要么走 DbHelper 既有删除
  方法，要么自行补 `_recordSyncTombstone`（日记的墓碑会经
  `v2/tombstones.json` 传播到其他端）
- **任何改日记内容/状态的用户侧写库都必须 bump `updated_at`**：这是 v2
  LWW 的唯一裁决依据，漏 bump 就等于「本机编辑永远输」；同步落库
  （`applySyncV2Notes`）例外——它写的是裁决结果，`updated_at` 随笔记
  带过来，不再自增
- **任何新增/更新日记的路径都要考虑 `sync_note_meta`**：meta 缺行只
  影响透传字段（合并时退化成「无基线 + 首次 seed」），不会丢文本；
  但**新写的电脑端独有字段若不经 meta 透传，就会在下次手机回写时被抹掉**

## 待同步检测（入口行提示）

P1 无自动同步，卡片若只显示上次同步结果快照，用户同步后再新增数据会误
以为云端一致（真机反馈 2026-09-22）。机制（`lib/utils/cloud_sync_data_version.dart`，
与 DiarySyncBridge 同款跨 engine 计数纪律）：

- **写方 bump**：DbHelper/TextProcessor 所有用户侧写库路径（日记/物品的
  增删改归档标注、截图替换、备份导入、修正对学习/删除、热词保存）
  fire-and-forget 自增 prefs 计数 `cloud_sync_data_version`（bump 前 reload
  防悬浮窗 engine 覆盖）
- **同步成功快照**：`CloudSyncService.sync()` 在全部合并/上传完成后把当前
  计数写入 `cloud_sync_synced_data_version`；同步失败不快照，待同步态保留
- **读方判定**：`hasPending = 有上次同步记录 &&（无快照 || 当前 > 快照）`。
  入口行副标题（`CloudSyncConfig.buildEntrySubtitle` 纯函数，单测覆盖）
  与二级页状态区共享文案逻辑
- **刷新时机**（IndexedStack 保活，initState 不重跑）：切到设置 tab
  （main.dart 持 `SettingsTabKey` 调 `refreshCloudSyncSummary`）、App 回
  前台（didChangeAppLifecycleState.resumed）、从二级页返回、进入二级页

## 下拉刷新入口（2026-10-24）

主 App 与悬浮窗各有一个「下拉即同步」入口，省去「切到设置页 → 立即同步」
的路径（悬浮窗场景尤其明显）：

- **随手记（主 engine）**：`RefreshIndicator` 包住日记列表与空态（空态用
  `AlwaysScrollableScrollPhysics` 撑满视口，空库也能下拉）；同步完成后
  `refreshList()` 重查，结果走 SnackBar。未配置时只刷新本地并提示
  「设置 → 云端同步」，不发起必失败请求
- **悬浮窗（overlay engine）**：展开面板的列表、空态、错误态都包
  `RefreshIndicator`（内容不足一屏也靠 `AlwaysScrollableScrollPhysics` 可
  下拉；空库首次同步主要靠它）；同步在 overlay engine 内直接执行（同一个
  `items.db` + 独立 `TextProcessor` 读写 `user_hotwords.txt`），落库后直接
  `_loadDiaries`，不等 DiarySyncBridge 展开脏检查；结果走原生 Toast（收起
  后面板不可见，Flutter 侧无可见载体）
- **文案一致**：两处共用 `CloudSyncResult.pullRefreshMessage`——成功无新增
  显示「云端与本地一致」，有新增带分项统计，失败沿用友好错误文案
- **并发**：`CloudSyncService._syncing` 静态标志只在各自 engine 内防重入；
  两处同时下拉时同 device_id 不触发远端软锁互斥，最坏多传一次相同数据
  （沿用「极端同时点击双开无害」的既有边界）

## 本机请求计数（限流预算，2026-10-25）

坚果云没有查询剩余额度的接口，响应也不返回限流余量，所以客户端自己按
**滚动 30 分钟窗口**记账（[lib/sync/webdav_request_counter.dart](../../lib/sync/webdav_request_counter.dart)，
分钟桶 + 注入时钟，`remaining` 钳到 0，`untilNextExpiry` 给最早一批滑出
窗口的时间）。这是**本机请求数**，不是账号剩余额度：电脑端和其它客户端
消耗的额度看不到，429 后即使本机显示还有剩也可能已被封锁数小时。

**双 engine 各记一份**（手机端的核心约束）：

- 主 App 与悬浮窗是两个 FlutterEngine，静态单例/prefs 内存缓存都不跨
  isolate。每个 engine 只**追加写自己那份**
  `<应用支持目录>/webdav_requests_main.log` / `webdav_requests_overlay.log`，
  一行一个 epoch 毫秒（只用时间戳，不写账号/URL/远端路径）。
- 追加写不需要防抖，进程被杀也不丢已发出的记录；`flush()` 只等已入队的
  行落盘（`main.dart` 在 paused/hidden 调用）。**不在 dispose 里异步写**。
- 展示口径 = 本 engine 内存计数 + 另一份日志的窗口内条数。另一份在
  **进设置页时和同步结束时各读一次**（`refreshOtherEngine`），是快照：
  悬浮窗在页面打开后新发的请求要等下次刷新才计入。
- 日志超过 2000 行时压缩（启动读入后，或运行期累计到阈值就排一次），
  只留窗口内时间戳，临时文件 + rename。每个 engine 只写自己的文件，
  另一 engine 只读，不存在并发写；进程长期不重启也不会无限增长。

**唯一计数出口**：`CloudSyncService.createClient` 给 `WdDio`（`Client.c`，
implements Dio）挂 `onRequest` 拦截器，**先计数再发送**，失败/超时/429
也计入。ping、readProps、mkdirAll、read、write、404 目录探测、「测试
连接」以及录音/截图同步全部经过这里，不在业务方法里散落计数。
`webdav_client` 已设 `followRedirects = false`，计数与服务端实际请求
基本一致（401 Digest 重试与 302 重定向在包内会再发一次，也各计一次）。

**展示与提示**：

- 设置 → 云端同步「同步」卡片显示「最近 30 分钟：这台手机共发出 N 次
  请求（含悬浮窗），按免费版估算还剩 M 次」；达到 80% 用
  `ext.warningText` 变红，提示降频/暂停并给出最早一批滑出窗口的分钟数；
  底部注明「仅统计这台手机，电脑端和其它客户端不计入」。
- 429 的用户文案追加「（本机最近 30 分钟已发出 N 次请求）」，同时保留
  「超限后可能被封锁数小时」，不暗示马上可用。

**已知边界**：分钟粒度最多差 59 秒；手动改系统时间会让窗口失真；另一
engine 的计数是快照；没有准确的剩余额度（600/1500 只是免费/付费版估算，
无法自动识别版本）；极端同时同步时两 engine 都可能发请求，本机合计会
都计入。

**验收项**：

- 「测试连接」后计数 +1 或 +2（远端目录不存在时多一次 MKCOL）
- 完整文本同步后计数增加 12～16 次，录音/截图再各加
- 429 提示里出现本机次数
- 杀进程重启后计数仍在，30 分钟后自然归零
- 悬浮窗下拉刷新同步的请求计入（进设置页可见）
- 达到 80% 变红并提示，文案明确「只统计这台手机」

## 错误处理

`_friendlyError` 把 DioException 映射为用户文案：401/403 → 账号或
「应用密码」错误（坚果云要求在网页端「账户信息 → 安全选项」生成应用
密码，登录密码不行）；429 → 限流提示（附本机最近 30 分钟请求数，见
「本机请求计数」）；507 → 空间不足；超时/连接错误
→ 检查地址网络。404 单列（缺文件/目录是首次同步的正常路径，不算错）。
`FormatException` 排在这道映射最前——v2 协议版本不兼容、v2 文件损坏的
中文原因要直接透出，不能被泛化成「同步失败」。

## 未来演进

- **P2 已落地（日记）**：diary 加 `updated_at` + 墓碑跨端传播 → 编辑
  LWW 同步、删除同步收敛（见「v2 编辑与删除同步」）
- **P2 待办**：items 进 v2（物品记录的编辑/删除同样走三方合并）；冲突
  副本在 UI 上给出可辨识提示（当前只在同步统计里报条数）；截图本体
  从 `image_index.json` 迁到 v2 附件口径
- **P3**：`SyncBackend` 抽象口 + Google Drive/OneDrive OAuth 适配器
  （录音文件同步已随独立开关落地，见「录音文件同步」节）

## Changelog

- 2026-09-21：首版（P1）。WebDAV 手动同步：manifest 软锁 + 四文件整包
  合并；日记/物品 sync_uuid 并集 + 自然键去重 + 本地墓碑防复活；热词行级
  并集；修正对 hit_count/last_used_at 行级合并；录音不同步、编辑删除
  不跨端（P1 拍板边界）。v14 迁移与本地 wsgidav 实测冒烟（PROPFIND/
  MKCOL/PUT/GET/404 错误面）全过。
- 2026-09-22：新增待同步检测——本地数据版本计数（用户侧写库 bump / 同步
  成功快照），入口行与二级页显示「有新数据待同步」，刷新时机：切设置 tab /
  App 回前台 / 二级页进出（真机反馈：同步后新增数据卡片仍显示一致）。
- 2026-09-23：录音文件同步（独立开关默认关）。云端新增 audio/ 子目录 +
  audio_index.json 上传索引；上传/下载各限 80 个/次防坚果云限流，超出
  下次续传；录音阶段失败不拖垮文本同步；下载按 sync_uuid 回填
  audio_path（不 bump 数据版本）、墓碑行不拉回；文件名过 isSafeAudioName
  安全校验。合并计划纯函数 planAudioUploads/planAudioDownloads 单测覆盖。
- 2026-09-29：diary.json 携带 sort_order（v16 悬浮窗长按拖动排序键，
  编解码宽容——旧云端文件无此字段按 null 处理）。下载插入排序决策：
  本地活跃区空尊重远端值、非空堆顶部；两端各自重排的顺序不互相覆盖
  （P1「编辑不跨端」边界的延伸）。
- 2026-10-21：明确截图附件（v17 diary.image_path）不同步——不编入
  diary.json、不进备份，图片仅本机存储（见「云端布局」注记）。
- 2026-10-24：截图附件手机 → 电脑同步。手机把截图按 sha256 写入电脑端
  既有的 `v2/assets/`，根目录 `image_index.json` 登记笔记 uuid → 图片；
  电脑端读取索引挂成 origin='mobile' 附件并下载。手机侧：单次 80 张分批、
  失败/超限保留旧条目、索引损坏按不可用处理、下载副本 diary_sync_* 不再
  转发、sha/20MB 校验、失败隔离；截图替换计入待同步检测。新增
  image_sync.dart 与 sync_image_test.dart；电脑端同步改动见其仓库文档。
- 2026-10-23：修复电脑端同步数据悬浮窗不可见——下载合并有实际插入时
  `DiarySyncBridge.bump()`（悬浮窗展开脏检查的唯一信号）；合并段抽为
  可单测的 `mergeDownloadedText`；新增 cloud_sync_overlay_refresh_test
  （远端日记/物品落库可见 + 计数 +1 + 重复同步不 bump）。
- 2026-10-24：新增随手记与悬浮窗面板**下拉刷新云同步**——两处
  `RefreshIndicator` 均覆盖空态（空库首次同步可下拉），未配置时只刷新
  本地并提示入口；悬浮窗同步在 overlay engine 内直接执行、落库后立即重查、
  结果走原生 Toast；两处共用 `CloudSyncResult.pullRefreshMessage`
  （新增 cloud_sync_pull_refresh_message_test）。
- 2026-10-24：截图附件扩展为**双向多图**。电脑端发布自有图片条目
  （`source='desktop'`、`position` 映射附件 sortOrder），手机回写索引
  原样透传 source；手机按 `(note, device, sha)` 全量补下电脑端图片到新增
  v18 `diary_images` 表（多张全留、position 排序），本机截图丢失时按索引
  恢复一张。合并裁剪远端已摘掉的条目与墓碑笔记并删文件（有裁剪才 bump）。
  悬浮窗缩略图带数量角标、点击打开 PageView 图集左右切换；随手记卡片
  仅有图的笔记显示图片图标（数量 > 1 带角标），点击打开同一图集。新增
  db_helper 多图读写与 `image_count`/`primary_image_path` 计算列、
  多图合并/下载/裁剪单测、图集手势单测；电脑端改动见其仓库文档。
- 2026-10-24：日记升级 **v2 双向编辑/删除同步**（用户反馈：新增双向
  正常，但电脑端改文本同步不到手机、手机端改也同步不到电脑——原 P1
  边界）。手机侧落地电脑端同一份 v2 契约：`v2/notes.json` +
  `v2/tombstones.json` + `v2/manifest.json`，三方合并（基线哈希判谁改过
  → 单边改改者胜、双边改 LWW → 平局比 payloadHash、≤5 分钟给输家冲突
  副本）+ 墓碑优先与 `updated_at > deleted_at` 复活；v2 版本守卫与文件
  损坏一律中止整次同步（`FormatException` 优先透出中文原因），绝不把
  坏文件当空集合回写。DB 升 v19：`diary.updated_at`（存量按 created_at
  回填、用户侧写库路径全部 bump，拖动排序与截图替换刻意不 bump）+
  `sync_note_meta` 透传表（tags/attachments/extras/base_hash/rev），手机
  不认识的电脑端字段原样回写；首次接 v2 用远端同 uuid 记录做 seed，
  防止载荷差异被误判成本地编辑而抹掉电脑端标签与图片。v1 `diary.json`
  降级为旧客户端投影（其中缺失条目只作内存导入候选，不预落库）；
  v2/manifest/v1 manifest 写回均铺底远端原始 JSON 保未知字段，
  `sameV2Content` 忽略 generated_at/device_id 与本机 writers.last_seen
  做到「没变不 PUT」。边界：items 仍未进 v2（物品编辑/删除不跨端）、
  冲突副本不带音频、v1 投影不含附件信息。**未做真网盘端到端联网验证**
  （仅单测覆盖合并与落库）。新增 `sync_v2.dart` / `sync_v2_merge.dart`
  与 sync_v2_test（23 例）、db_upgrade_v19_test、cloud_sync_v2_merge_test；
  flutter analyze 0 error、flutter test 全过；电脑端改动见其仓库文档。
- 2026-10-24：v1 四个数据文件接入 **write-if-changed**（用户提出「电脑端
  还没正式上线、双份是浪费」；结论：v1 兼容层必须留着——旧版 App 只认 v1，
  且 items/热词/修正对根本没有 v2 通道——但重复 PUT 可以省）。
  `CloudSyncService.v1FileUnchanged`：逐字符相同即未变（`hotwords.txt`
  只走这条）；否则两侧解析成 JSON 后用新抽出的 `sameJsonContent` 递归排序
  对象键再比（键序/缩进差异不算变更，**数组顺序仍参与比较**，宁多写不漏写）；
  首次同步（previousRaw=null）与云端文件解析失败一律按有变更整包覆盖。
  `diary.json`/`items.json`/`correction_pairs.json` 复用下载段已读到的原始
  文本、`hotwords.txt` 复用合并段的 `remoteHotwords`，不额外发 GET。跳过数
  只进日志「v1 数据文件 N 个内容未变，跳过回传」，不进用户可见统计；
  manifest 的置锁/解锁两次 PUT 属软锁语义本身，不受影响。常态同步请求量
  由「10 GET + 6 PUT」降到约 12。新增 cloud_sync_v1_write_if_changed_test
  （9 例）与 sync_v2_test 的 sameJsonContent 组（4 例）；
  flutter analyze 0 error + flutter test 928 全过。
- 2026-10-25：新增**本机 WebDAV 请求预算**（对齐电脑端同一设计的 3 个
  提交；手机端差异是 `webdav_client` 底层与双 engine）。`WebDavRequestCounter`
  按分钟桶滚动统计最近 30 分钟，600/1500 只作估算；主 App 与悬浮窗各
  追加写自己的 `webdav_requests_<engine>.log`（一行一个 epoch 毫秒，
  不防抖、进程被杀不丢；超过 2000 行（启动读入后或运行期累计触发）
  只留窗口内行并原子重写），
  展示时合并另一份日志（进设置页/同步结束各读一次，是快照）。计数挂在
  `CloudSyncService.createClient` 给 `WdDio` 加的 `onRequest` 拦截器上
  ——ping/readProps/mkdirAll/read/write、404 探测与「测试连接」全覆盖，
  先计数后发送、失败也计入；429 文案追加本机次数并保留「可能封锁数小时」
  口径。设置页「同步」卡片新增预算行：本机合计（含悬浮窗）、剩余估算、
  80% 变红、最早一批滑出窗口分钟数，底部注明只统计这台手机。新增
  webdav_request_counter_test（10 例）、cloud_sync_request_counting_test
  （2 例，假 adapter 驱动 ping/404）、webdav_budget_line_test（2 例）。
- 2026-10-25：修复**电脑端补同步的旧笔记在手机端整批置顶**（用户反馈：
  手机 14:27 写完、电脑 14:15 与前一天各写一条，同步后电脑两条都跑到
  手机列表最前面；时间显示正确但顺序不按时间）。`DbHelper` 新增
  `_placeIncomingRowsByTime`：本地活跃区非空时，远端新行按 `created_at`
  插进本机当前显示顺序——取显示顺序中「最后一条比它新的行」的
  `sort_order` 同值落位（同值由 getDiaries 的 `created_at DESC` 兜底），
  **既有行 sort_order 一个不动**（不整区重编号：否则所有笔记载荷指纹
  变化，下轮同步会整批重传）。`insertRemoteDiaries`（v1 路径）与
  `applySyncV2Notes`（v2 主路径）共用；活跃区为空（换机恢复）仍尊重
  远端原值，归档行恒 null。新增 db_remote_note_order_test（1 例）；
  db_sort_order_test 远端合并段扩为顶部/中间/底部三组；flutter analyze
  0 error（167 issue 与基线持平）+ flutter test 945 全过。
 - 2026-10-25：手机侧补上**图集内删图入口**（用户要求：悬浮窗截完图也能单独丢图，
  位置与删除范围用户拍板）——`OverlayImagePreview` 顶栏左上角加 🗑，只删本机自拍
  那张（`updateDiaryImage(id, null)` + 删文件 + bump 数据版本），下轮同步本机索引
  条目自然消失、电脑端摘掉对应附件；电脑端同步来的图不给删除按钮（点了只 Toast
  提示去电脑端删），刻意不做「只删手机本地副本」的假删除——来源端笔记附件仍在，
  下轮会重发布并被本机补下。详见「截图附件同步」的删除边界两条与
  floating-window.md「卡片截图附件」；overlay_image_preview_test 增至 12 例。
