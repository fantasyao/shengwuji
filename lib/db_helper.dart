import 'app_logger.dart';
import 'dart:async';
import 'dart:convert';
import 'package:package_info_plus/package_info_plus.dart'; // 读取 build number 判断版本化说明卡片
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
import 'package:path/path.dart';
import 'correction/context_learner.dart';
import 'correction/pair_context.dart';
import 'utils/cloud_sync_data_version.dart'; // 云同步待同步检测：用户侧写库 bump 数据版本
import 'utils/correction_learner.dart';
import 'utils/diary_tag.dart'; // 标注筛选哨兵 filterNormal（"普通"=无标注档）

class DbHelper {
  static Database? _db;

  /// v18 多图附件表：一行 = 某条笔记来自某设备的一张云端图片。
  /// note_uuid 用同步身份而不是本地自增 id——悬浮窗滑动删除的撤销窗口
  /// 会重插新 id，图片行必须跟 sync_uuid 走才能活过撤销。
  /// image_path 为本机下载后的绝对路径（NULL=尚未落盘）。
  static const String _diaryImagesTableSql = '''
CREATE TABLE IF NOT EXISTS diary_images(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  note_uuid TEXT NOT NULL,
  device_id TEXT NOT NULL,
  sha256 TEXT NOT NULL,
  image_path TEXT,
  remote_name TEXT,
  mime_type TEXT,
  byte_size INTEGER,
  position INTEGER NOT NULL DEFAULT 0,
  updated_at TEXT,
  UNIQUE(note_uuid, device_id, sha256)
)''';

  /// v19 云同步 v2 旁路元数据（一条笔记一行，按 sync_uuid 关联）：
  /// - base_hash：上次成功同步时的 v2 载荷哈希（与电脑端 SyncState.bases
  ///   同一算法，用于三方合并判断「本地/远端谁改过」）
  /// - rev：协议里的本机修订号（仅诊断，不做新旧比较）
  /// - tags/attachments/extras：手机端不解析的电脑端字段，原样透传，
  ///   避免手机写回 v2/notes.json 时把电脑端图片附件、用户标签抹掉
  static const String _syncNoteMetaTableSql = '''
CREATE TABLE IF NOT EXISTS sync_note_meta(
  note_uuid TEXT PRIMARY KEY,
  base_hash TEXT,
  rev INTEGER NOT NULL DEFAULT 1,
  tags_json TEXT,
  attachments_json TEXT,
  extras_json TEXT
)''';

  /// 全部内置表 DDL 的唯一真值：onCreate（新建库）与 _ensureCoreTables
  /// （缺表自愈）共用同一份，避免两处各写一套、日后只改一边。
  /// 一律 CREATE TABLE IF NOT EXISTS：自愈时对已存在的表重复执行是空操作。
  static const List<({String name, String sql})> _coreTables = [
    // 创建物品表：id, name (物品), location (位置)
    // sync_uuid：云同步全局唯一身份（本地自增 id 两台设备会撞，合并键必须用它）
    (
      name: 'items',
      sql:
          'CREATE TABLE IF NOT EXISTS items(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, location TEXT, sync_uuid TEXT)',
    ),
    // 创建日记表，包含音频时长字段；tag = 标注（悬浮窗标注功能，
    // 'urgent'/'star'/'idea'/'task'，NULL=无标注）；is_locked = 用户手动锁定的
    // 笔记（防锁屏悬浮窗偷看：全链路打码 + 设备凭据认证后可看）；
    // sort_order = 活跃区自定义排序键（越小越靠前，仅活跃区有意义，
    // 归档区行恒 NULL；悬浮窗长按拖动排序写入，主 App/电脑访问顺序跟随）；
    // image_path = 截图附件绝对路径（悬浮窗展开卡长按复制按钮生成，
    // 每卡最多一张，重新截图覆盖旧文件；不进备份 ZIP/CSV，随云同步双向）
    // updated_at = 内容/标注/锁定/归档等用户侧编辑的毫秒时间戳（v19，
    // 云同步 v2 的 LWW 裁决依据；新建行等于 created_at）
    (
      name: 'diary',
      sql:
          'CREATE TABLE IF NOT EXISTS diary(id INTEGER PRIMARY KEY AUTOINCREMENT, content TEXT, created_at TEXT, audio_path TEXT, duration INTEGER, is_archived INTEGER DEFAULT 0, exported_at TEXT, tag TEXT, sync_uuid TEXT, is_locked INTEGER DEFAULT 0, sort_order INTEGER, image_path TEXT, updated_at INTEGER)',
    ),
    // dismissed_splits 表：用户在日记页 ✕ 掉的物品转存内容（V9 新增）
    // 同一 content UNIQUE，避免重复入库
    (
      name: 'dismissed_splits',
      sql:
          'CREATE TABLE IF NOT EXISTS dismissed_splits(id INTEGER PRIMARY KEY AUTOINCREMENT, content TEXT NOT NULL UNIQUE, created_at TEXT)',
    ),
    // correction_pairs 表：错误-修正学习表（V11 新增）。
    // 用户手动修改识别文本时，对比「识别原文 → 保存文字」学到的片段级
    // 替换对（见 CorrectionLearner）；下次识别再出现相同错误片段时
    // 提示用户一键修正。(error_text, corrected_text) 联合 UNIQUE 去重
    (
      name: 'correction_pairs',
      sql:
          'CREATE TABLE IF NOT EXISTS correction_pairs(id INTEGER PRIMARY KEY AUTOINCREMENT, error_text TEXT NOT NULL, corrected_text TEXT NOT NULL, hit_count INTEGER NOT NULL DEFAULT 1, created_at TEXT, last_used_at TEXT, UNIQUE(error_text, corrected_text))',
    ),
    // correction_context_stats 表：同音词×上下文词共现统计（V12 新增）。
    // 用户编辑/一键修正确认了同音组纠错（如 质朴→智谱）时累加
    // 「用户选的词 × 上下文词」计数，供 ContextScorer 做上下文加权评分；
    // 与 correction_pairs 互补：同音组对绝不进盲替换表，只进这里
    (
      name: 'correction_context_stats',
      sql:
          'CREATE TABLE IF NOT EXISTS correction_context_stats(source_word TEXT NOT NULL, context_word TEXT NOT NULL, count INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(source_word, context_word))',
    ),
    // correction_user_words 表：用户选用词频（V12 新增）。
    // log(1+frequency)×小系数 作为评分弱先验（只做 tiebreaker，
    // 不允许词频单独决定替换）
    (
      name: 'correction_user_words',
      sql:
          'CREATE TABLE IF NOT EXISTS correction_user_words(word TEXT PRIMARY KEY, frequency INTEGER NOT NULL DEFAULT 0, last_used_at TEXT)',
    ),
    // correction_pair_contexts 表：修正对语境档案（V13 新增）。
    // 普通修正对（非同音组）被学到时，顺带记录错误片段在识别原文中
    // 出现位置的左右邻接字符（PairContextGate 归一化）；提示一键修正前
    // 比对当前文本的邻接字符，语境吻合才弹提示（语境门控），
    // 「互联网影视可控」学到的「影视→隐私」不会打扰「今晚看的影视不错」
    (
      name: 'correction_pair_contexts',
      sql:
          'CREATE TABLE IF NOT EXISTS correction_pair_contexts(error_text TEXT NOT NULL, corrected_text TEXT NOT NULL, left_context TEXT NOT NULL DEFAULT \'\', right_context TEXT NOT NULL DEFAULT \'\', hit_count INTEGER NOT NULL DEFAULT 1, PRIMARY KEY(error_text, corrected_text, left_context, right_context))',
    ),
    // sync_deleted 表：云同步删除墓碑（V14 新增）。
    // 本地删除日记/物品时记下其 sync_uuid，云同步下载合并时 uuid 命中
    // 墓碑的远端条目不再插回本地（防复活）。自 v2（V19）起 kind='diary'
    // 的墓碑随 v2/tombstones.json 跨端传播，kind='items' 仍只在本机生效
    (
      name: 'sync_deleted',
      sql:
          'CREATE TABLE IF NOT EXISTS sync_deleted(uuid TEXT PRIMARY KEY, kind TEXT NOT NULL, deleted_at TEXT NOT NULL)',
    ),
    // diary_images 表：云同步下收的电脑端图片（V18 新增）。
    // 手机自拍截图仍走 diary.image_path，本表只放其他设备发布的多图
    (name: 'diary_images', sql: _diaryImagesTableSql),
    (name: 'sync_note_meta', sql: _syncNoteMetaTableSql),
  ];

  /// 库文件名。仅供测试改用独立文件名（多 isolate 并行跑 flutter test 时，
  /// 各测试文件共用 items.db 会互相 deleteDatabase 打架——三个 db_*_test
  /// 同跑时的偶发失败即此因）；生产代码不得读写此字段
  static String dbFileName = 'items.db';

  // 单飞打开：并发首开时共享同一个 Future，保证每个 isolate 只 openDatabase
  // 一次。旧写法 `if (_db != null) return _db!` 拦不住并发（await initDb()
  // 期间第二个调用方也会看到 _db == null 而再次 open，两条连接在升级窗口
  // 打架）——真机 2026-09-21 覆盖安装后首启 database_closed 复现的根因之一
  static Future<Database>? _opening;

  // 获取数据库实例
  Future<Database> get db {
    final cached = _db;
    if (cached != null) return Future.value(cached);
    return _opening ??= _openDbOnce();
  }

  /// 首开（带瞬态重试）+ 打开成功后的数据修补。
  /// 失败时清空 _opening，允许后续调用重新走一遍打开流程
  Future<Database> _openDbOnce() async {
    try {
      final dbClient = await _openWithRetry();
      _db = dbClient;
      // 缺表自愈必须排在所有列级自愈之前：后面的 ALTER TABLE 依赖表存在
      // （2026-10-27 模拟器首启事故的补救点，见 _ensureCoreTables 头注释）
      var rebuiltCoreTables = false;
      try {
        rebuiltCoreTables = await _ensureCoreTables(dbClient);
      } catch (e) {
        log("[DbHelper] ⚠️ 缺表自愈失败（读写将不可用，重启重试）：$e");
      }
      if (rebuiltCoreTables) {
        // diary 表都被重建 = 等价新装库（原库没有任何行），补回内置说明卡
        try {
          await _seedTutorialDiaries(dbClient);
          log("[DbHelper] 缺表自愈后补回内置说明卡片");
        } catch (e) {
          log("[DbHelper] ⚠️ 缺表自愈后补说明卡片失败：$e");
        }
      }
      // v14 自愈：先核 schema 再回填。版本号不可信的原因见 _ensureSyncSchema
      try {
        await _ensureSyncSchema(dbClient);
      } catch (e) {
        log("[DbHelper] ⚠️ sync 表结构自愈失败（写入将不可用，重启重试）：$e");
      }
      // v16 自愈：同 _ensureSyncSchema 同款理由（版本号被中断的升级污染时
      // 以实际表结构为准），diary 缺 sort_order 列就地补齐
      try {
        await _ensureSortOrderSchema(dbClient);
      } catch (e) {
        log("[DbHelper] ⚠️ sort_order 表结构自愈失败（排序将退回纯时间序，重启重试）：$e");
      }
      // v18 自愈：同上，多图附件表缺失就地补齐（图片同步将不可用，重启重试）
      try {
        await _ensureDiaryImagesSchema(dbClient);
      } catch (e) {
        log("[DbHelper] ⚠️ diary_images 表结构自愈失败（多图同步不可用，重启重试）：$e");
      }
      // v19 自愈：diary.updated_at + sync_note_meta（v2 编辑同步的身份与
      // 透传字段；缺列时 LWW 会永远判本地最旧，必须补齐）
      try {
        await _ensureV19Schema(dbClient);
      } catch (e) {
        log("[DbHelper] ⚠️ v2 同步表结构自愈失败（编辑同步不可用，重启重试）：$e");
      }
      // sync_uuid 回填在连接建立后做（幂等）：onCreate/onUpgrade 事务里只做
      // DDL，把逐行生成 UUID 的 Dart 循环挪出升级事务——升级窗口缩到毫秒级，
      // 回填失败也不阻塞使用（同步前 ensureSyncUuids / 下次启动会重试）
      try {
        final backfilled = await _backfillSyncUuids(dbClient);
        if (backfilled > 0) {
          log("[DbHelper] 首开后补生成 $backfilled 条 sync_uuid");
        }
      } catch (e) {
        log("[DbHelper] sync_uuid 回填失败（下次启动/同步前重试）：$e");
      }
      // sort_order 回填同 sync_uuid 模式（幂等，挪出升级事务）
      try {
        final backfilled = await _backfillSortOrder(dbClient);
        if (backfilled > 0) {
          log("[DbHelper] 首开后回填 $backfilled 条活跃日记 sort_order");
        }
      } catch (e) {
        log("[DbHelper] sort_order 回填失败（下次启动重试）：$e");
      }
      // v19 updated_at 回填：用 created_at 的瞬时（不是 now）——否则存量行
      // 会在首次 v2 同步时无端赢过电脑端更晚的真实编辑
      try {
        final backfilled = await _backfillDiaryUpdatedAt(dbClient);
        if (backfilled > 0) {
          log("[DbHelper] 首开后回填 $backfilled 条日记 updated_at");
        }
      } catch (e) {
        log("[DbHelper] updated_at 回填失败（下次启动重试）：$e");
      }
      return dbClient;
    } catch (e) {
      _opening = null;
      rethrow;
    }
  }

  /// 缺表自愈（2026-10-27 模拟器首启事故）：新建库时 onCreate 的 DDL 与
  /// 说明卡插入全部执行完，但 sqflite 侧 COMMIT 报「no current transaction」
  /// 失败并关闭连接；user_version 是独立写出去的（同 v14 事故的「版本号
  /// 在事务之外」），于是留下「版本=19 但一张表都没有」的空库。重试打开时
  /// onCreate 被跳过，列级自愈只会 ALTER 到 no such table，唯一直写 DDL 的
  /// diary_images 自愈反而建成了——最终库里有 diary_images、没有 diary，
  /// 每条查询都失败、随手记永远停在「加载中」。
  ///
  /// 修法沿用「版本号不可信，以实际表结构为准」：缺表就按 _coreTables
  /// 补齐（与 onCreate 同源、全部 IF NOT EXISTS，重复执行是空操作）。
  /// 返回是否重建了 diary（= 库里原本没有任何日记行，等价新装库）。
  Future<bool> _ensureCoreTables(Database dbClient) async {
    final rows = await dbClient.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table'",
    );
    final existing = rows.map((r) => r['name']).whereType<String>().toSet();
    final missing = <String>[];
    for (final table in _coreTables) {
      if (existing.contains(table.name)) continue;
      await dbClient.execute(table.sql);
      missing.add(table.name);
    }
    if (missing.isEmpty) return false;
    // 版本号 + 缺表清单一起记：下次再出这类事故，日志里能直接看出是
    // 「建库事务被中断」而不是升级路径问题
    var version = -1;
    try {
      version = await dbClient.getVersion();
    } catch (_) {
      // 读不到版本不影响补齐，日志里如实写 -1
    }
    log(
      "[DbHelper] 🔧 自愈：库缺表 ${missing.join('/')}"
      "（user_version=$version），已按当前 schema 补齐",
    );
    return missing.contains('diary');
  }

  /// v14 表结构自愈（幂等，正常库两次 PRAGMA 零开销）：
  /// sqflite 原生侧的 user_version 写入发生在升级事务【之外】——升级中途
  /// 被瞬态错误（覆盖安装撞旧进程文件锁）打断时，DDL 随事务回滚，但版本号
  /// 已经写成 14，产出「user_version=14 但 sync_uuid 列缺失」的坏库。此后
  /// onUpgrade 永远不再触发，所有带 sync_uuid 的写入全部失败（真机
  /// 2026-09-21 复现：回填报 no such column、录音落库全丢）。版本号不可信，
  /// 以实际表结构为准：缺列就地补齐
  Future<void> _ensureSyncSchema(Database dbClient) async {
    for (final table in const ['items', 'diary']) {
      final cols = await dbClient.rawQuery('PRAGMA table_info($table)');
      final hasUuid = cols.any((c) => c['name'] == 'sync_uuid');
      if (!hasUuid) {
        await dbClient.execute(
          "ALTER TABLE $table ADD COLUMN sync_uuid TEXT",
        );
        log("[DbHelper] 🔧 自愈：$table 缺 sync_uuid 列（版本号被中断的升级污染），已补列");
      }
    }
    await dbClient.execute(
      "CREATE TABLE IF NOT EXISTS sync_deleted(uuid TEXT PRIMARY KEY, kind TEXT NOT NULL, deleted_at TEXT NOT NULL)",
    );
  }

  /// v16 表结构自愈（幂等，正常库一次 PRAGMA 零开销）：
  /// 与 _ensureSyncSchema 同款理由——版本号不可信（被中断的升级可能留下
  /// user_version=16 但 sort_order 列缺失的坏库），以实际表结构为准
  Future<void> _ensureSortOrderSchema(Database dbClient) async {
    final cols = await dbClient.rawQuery('PRAGMA table_info(diary)');
    final hasSortOrder = cols.any((c) => c['name'] == 'sort_order');
    if (!hasSortOrder) {
      await dbClient.execute(
        "ALTER TABLE diary ADD COLUMN sort_order INTEGER",
      );
      log("[DbHelper] 🔧 自愈：diary 缺 sort_order 列（版本号被中断的升级污染），已补列");
    }
  }

  /// v18 多图附件表（同款自愈：版本号被中断的升级可能停在 18 却没建表）
  Future<void> _ensureDiaryImagesSchema(Database dbClient) async {
    await dbClient.execute(_diaryImagesTableSql);
    await dbClient.execute(
      'CREATE INDEX IF NOT EXISTS idx_diary_images_note '
      'ON diary_images(note_uuid)',
    );
  }

  /// v19 表结构自愈（同款理由）：diary 缺 updated_at 列 / sync_note_meta
  /// 缺表都就地补齐，不依赖 user_version
  Future<void> _ensureV19Schema(Database dbClient) async {
    final cols = await dbClient.rawQuery('PRAGMA table_info(diary)');
    if (!cols.any((c) => c['name'] == 'updated_at')) {
      await dbClient.execute(
        'ALTER TABLE diary ADD COLUMN updated_at INTEGER',
      );
      log("[DbHelper] 🔧 自愈：diary 缺 updated_at 列，已补列");
    }
    await dbClient.execute(_syncNoteMetaTableSql);
  }

  /// 存量行 updated_at 回填（幂等）：取 created_at 的毫秒瞬时。
  /// created_at 是本地时间字符串（无 Z），DateTime.tryParse 按本机时区解释，
  /// 与展示语义一致。解析失败按 0（最旧），不会压过任何真实编辑
  Future<int> _backfillDiaryUpdatedAt(Database dbClient) async {
    final rows = await dbClient.query(
      'diary',
      columns: ['id', 'created_at'],
      where: 'updated_at IS NULL',
    );
    if (rows.isEmpty) return 0;
    final batch = dbClient.batch();
    for (final r in rows) {
      final createdAt = r['created_at'] as String?;
      batch.update(
        'diary',
        {'updated_at': _millisOfLocalTime(createdAt)},
        where: 'id = ?',
        whereArgs: [r['id']],
      );
    }
    await batch.commit(noResult: true);
    return rows.length;
  }

  /// 本地无 Z 时间字符串 → 毫秒瞬时；空/坏值返回 0
  static int _millisOfLocalTime(String? value) {
    if (value == null || value.trim().isEmpty) return 0;
    return DateTime.tryParse(value.trim())?.millisecondsSinceEpoch ?? 0;
  }

  /// 活跃区 sort_order 回填（幂等，首开成功后执行——DDL 在迁移事务，
  /// 逐行回填挪出升级事务，同 sync_uuid 回填模式）：
  /// 活跃区 NULL 行赋 min-1 递减系列。⚠️ 迭代方向必须 created_at ASC：
  /// 显示排序是 sort_order ASC（小=置顶），最旧行拿 min-1、最新行拿系列
  /// 最小值，ASC 排出来才是「新在前」；按 DESC 迭代会把顺序整个颠倒。
  /// 存量升级 = 全体 NULL → 赋负值系列，显示顺序与升级前完全一致
  Future<int> _backfillSortOrder(Database dbClient) async {
    final nullRows = await dbClient.query('diary',
        columns: ['id'],
        where: 'is_archived = 0 AND sort_order IS NULL',
        orderBy: 'created_at ASC');
    if (nullRows.isEmpty) return 0;
    final minRow = await dbClient.rawQuery(
        'SELECT MIN(sort_order) AS m FROM diary WHERE is_archived = 0');
    var next = (minRow.first['m'] as int?) ?? 0;
    final batch = dbClient.batch();
    for (final r in nullRows) {
      next -= 1;
      batch.update('diary', {'sort_order': next},
          where: 'id = ?', whereArgs: [r['id']]);
    }
    await batch.commit(noResult: true);
    return nullRows.length;
  }

  /// 活跃区「置顶插入」的 sort_order 取值：当前最小值-1（空活跃区从 0 起）
  Future<int> _nextTopSortOrder(DatabaseExecutor dbClient) async {
    final r = await dbClient.rawQuery(
        'SELECT MIN(sort_order) AS m FROM diary WHERE is_archived = 0');
    return ((r.first['m'] as int?) ?? 1) - 1;
  }

  /// 打开重试：覆盖安装后第一次启动，旧进程被杀到 SQLite 文件锁彻底释放
  /// 有个短暂窗口，新进程立即 open 可能撞瞬态锁失败——首次打开失败的
  /// 连接对象后续使用全是 database_closed（真机 2026-09-21 复现，杀后台
  /// 重启即愈）。瞬态错误重试即愈：最多 3 次、间隔递增
  Future<Database> _openWithRetry() async {
    for (var attempt = 1;; attempt++) {
      try {
        return await initDb();
      } catch (e) {
        if (attempt >= 3) rethrow;
        log("[DbHelper] 数据库打开失败（第 $attempt 次）：$e，${300 * attempt}ms 后重试");
        await Future<void>.delayed(Duration(milliseconds: 300 * attempt));
      }
    }
  }

  // 初始化数据库
  initDb() async {
    String path = join(await getDatabasesPath(), dbFileName);
    // 版本升级：3->4 时长, 4->5 归档, 5->6 导出标记, 6->7 lists 表, 7->8 清单合并到日记, 8->9 dismissed_splits 表, 9->10 diary.tag 标注列, 10->11 correction_pairs 错误-修正表, 11->12 上下文纠错统计表, 12->13 修正对语境档案表, 13->14 云同步列（sync_uuid + 墓碑表）, 14->15 diary.is_locked 笔记锁定列, 15->16 diary.sort_order 自定义排序列, 16->17 diary.image_path 截图附件列, 17->18 diary_images 多图附件表, 18->19 diary.updated_at 编辑时间 + sync_note_meta 透传表（云同步 v2）
    return await openDatabase(
      path,
      version: 19,
      onCreate: (db, version) async {
        // 建表 DDL 与缺表自愈同源（_coreTables），此处不再逐表展开
        for (final table in _coreTables) {
          await db.execute(table.sql);
        }
        await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_diary_images_note '
          'ON diary_images(note_uuid)',
        );
        // 首次创建数据库时内置说明卡片（点击复制、长按编辑等 8 条功能引导）
        await _seedTutorialDiaries(db);
        // 说明卡的 sync_uuid 不在这里补：升级事务里只做 DDL，
        // 逐行回填统一在首开成功后执行（见 _openDbOnce）
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 4) {
          await db.execute("ALTER TABLE diary ADD COLUMN duration INTEGER");
        }
        if (oldVersion < 5) {
          await db.execute(
            "ALTER TABLE diary ADD COLUMN is_archived INTEGER DEFAULT 0",
          );
        }
        if (oldVersion < 6) {
          await db.execute("ALTER TABLE diary ADD COLUMN exported_at TEXT");
        }
        if (oldVersion < 7) {
          await db.execute('''
              CREATE TABLE lists(
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                title TEXT,
                items_json TEXT,
                category TEXT,
                created_at TEXT
              )
            ''');
        }
        // 数据库升级：从版本7升级到版本8，清单数据合并到日记表并删除 lists 表
        if (oldVersion < 8) {
          try {
            final lists = await db.rawQuery(
              'SELECT * FROM lists ORDER BY created_at',
            );
            int migratedCount = 0;
            for (final row in lists) {
              final title = row['title'] as String? ?? '';
              final itemsJson = row['items_json'] as String? ?? '[]';
              final createdAt =
                  row['created_at'] as String? ??
                  DateTime.now().toIso8601String();

              final List<dynamic> items = jsonDecode(itemsJson);
              final markdownLines = <String>[];
              for (final item in items) {
                final text = item['text'] as String? ?? '';
                final done = item['done'] as bool? ?? false;
                if (done) {
                  markdownLines.add('- [x] $text');
                } else {
                  markdownLines.add('- [ ] $text');
                }
              }

              final content = markdownLines.isNotEmpty
                  ? '$title\n${markdownLines.join('\n')}'
                  : title;

              // 插入到 diary 表
              await db.rawInsert(
                'INSERT INTO diary (content, created_at, audio_path, duration, is_archived, exported_at) VALUES (?, ?, NULL, 0, 0, NULL)',
                [content, createdAt],
              );
              migratedCount++;
            }

            await db.execute('DROP TABLE lists');
            log("数据库迁移 v7→v8：已将 $migratedCount 条清单迁移到日记表，lists 表已删除");
          } catch (e) {
            log("数据库迁移 v7→v8 失败（不阻止升级）：$e");
          }
        }
        // 数据库升级：从版本8升级到版本9，新增 dismissed_splits 表（日记页 ✕ 学习功能）
        if (oldVersion < 9) {
          try {
            await db.execute(
              "CREATE TABLE dismissed_splits(id INTEGER PRIMARY KEY AUTOINCREMENT, content TEXT NOT NULL UNIQUE, created_at TEXT)",
            );
            log("数据库迁移 v8→v9：已创建 dismissed_splits 表");
          } catch (e) {
            log("数据库迁移 v8→v9 失败（不阻止升级）：$e");
          }
        }
        // 数据库升级：从版本9升级到版本10，diary 表新增 tag 标注列
        //（悬浮窗日记卡片标注功能：'urgent'/'star'/'idea'，NULL=无标注；
        // 2026-10-22 新增第 4 槽位 'task'，仅显示层换肤，列结构不变）
        if (oldVersion < 10) {
          try {
            await db.execute("ALTER TABLE diary ADD COLUMN tag TEXT");
            log("数据库迁移 v9→v10：diary 表已添加 tag 标注列");
          } catch (e) {
            log("数据库迁移 v9→v10 失败（不阻止升级）：$e");
          }
        }
        // 数据库升级：从版本10升级到版本11，新增 correction_pairs 错误-修正学习表
        //（用户手动修改识别文本 → 学习「识别原文片段 → 修正片段」替换对）
        if (oldVersion < 11) {
          try {
            await db.execute(
              "CREATE TABLE correction_pairs(id INTEGER PRIMARY KEY AUTOINCREMENT, error_text TEXT NOT NULL, corrected_text TEXT NOT NULL, hit_count INTEGER NOT NULL DEFAULT 1, created_at TEXT, last_used_at TEXT, UNIQUE(error_text, corrected_text))",
            );
            log("数据库迁移 v10→v11：已创建 correction_pairs 错误-修正表");
          } catch (e) {
            log("数据库迁移 v10→v11 失败（不阻止升级）：$e");
          }
        }
        // 数据库升级：从版本11升级到版本12，新增上下文纠错两张统计表
        //（correction_context_stats 同音词×上下文词共现 + correction_user_words 用户词频弱先验）
        if (oldVersion < 12) {
          try {
            await db.execute(
              "CREATE TABLE correction_context_stats(source_word TEXT NOT NULL, context_word TEXT NOT NULL, count INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(source_word, context_word))",
            );
            await db.execute(
              "CREATE TABLE correction_user_words(word TEXT PRIMARY KEY, frequency INTEGER NOT NULL DEFAULT 0, last_used_at TEXT)",
            );
            log("数据库迁移 v11→v12：已创建上下文纠错统计表");
          } catch (e) {
            log("数据库迁移 v11→v12 失败（不阻止升级）：$e");
          }
        }
        // 数据库升级：从版本12升级到版本13，新增修正对语境档案表
        //（普通修正对学到时记录错误片段左右邻接字符，提示前做语境门控）
        if (oldVersion < 13) {
          try {
            await db.execute(
              "CREATE TABLE correction_pair_contexts(error_text TEXT NOT NULL, corrected_text TEXT NOT NULL, left_context TEXT NOT NULL DEFAULT '', right_context TEXT NOT NULL DEFAULT '', hit_count INTEGER NOT NULL DEFAULT 1, PRIMARY KEY(error_text, corrected_text, left_context, right_context))",
            );
            log("数据库迁移 v12→v13：已创建修正对语境档案表");
          } catch (e) {
            log("数据库迁移 v12→v13 失败（不阻止升级）：$e");
          }
        }
        // 数据库升级：从版本13升级到版本14，云同步基础列——
        // diary/items 加 sync_uuid（全局唯一身份，跨端合并键）+
        // sync_deleted 墓碑表。⚠️ 事务里只做 DDL 不做逐行回填：回填的
        // Dart 循环会拉长升级事务窗口（覆盖安装后首启撞锁 database_closed
        // 的事故，见 _openWithRetry 注释），回填统一在首开成功后执行
        if (oldVersion < 14) {
          try {
            await db.execute("ALTER TABLE items ADD COLUMN sync_uuid TEXT");
            await db.execute("ALTER TABLE diary ADD COLUMN sync_uuid TEXT");
            await db.execute(
              "CREATE TABLE IF NOT EXISTS sync_deleted(uuid TEXT PRIMARY KEY, kind TEXT NOT NULL, deleted_at TEXT NOT NULL)",
            );
            log("数据库迁移 v13→v14：sync_uuid 列 + 墓碑表就绪（回填在首开后执行）");
          } catch (e) {
            log("数据库迁移 v13→v14 失败（不阻止升级）：$e");
          }
        }
        // 数据库升级：从版本14升级到版本15，diary 表新增 is_locked 锁定列
        //（笔记锁定功能：1=用户手动锁定，主 App/悬浮窗/局域网服务全链路
        // 打码展示，设备凭据认证后才显示内容；存量行默认 0 无需回填）
        if (oldVersion < 15) {
          try {
            await db.execute(
              "ALTER TABLE diary ADD COLUMN is_locked INTEGER DEFAULT 0",
            );
            log("数据库迁移 v14→v15：diary 表已添加 is_locked 锁定列");
          } catch (e) {
            log("数据库迁移 v14→v15 失败（不阻止升级）：$e");
          }
        }
        // 数据库升级：从版本15升级到版本16，diary 表新增 sort_order 排序列
        //（活跃区自定义排序键，越小越靠前，仅活跃区有意义、归档区行恒 NULL；
        // 存量活跃行为 NULL，由首开回填赋负值系列——显示顺序与升级前完全
        // 一致，见 _backfillSortOrder）
        if (oldVersion < 16) {
          try {
            await db.execute("ALTER TABLE diary ADD COLUMN sort_order INTEGER");
            log("数据库迁移 v15→v16：diary 表已添加 sort_order 排序列（回填在首开后执行）");
          } catch (e) {
            log("数据库迁移 v15→v16 失败（不阻止升级）：$e");
          }
        }
        // 数据库升级：从版本16升级到版本17，diary 表新增 image_path 截图附件列
        //（悬浮窗展开卡长按复制按钮 → 收起截屏 → 存 diary_images/，存绝对
        // 路径；存量行默认 NULL = 无附件。图片是本机附件，不进备份/云同步）
        if (oldVersion < 17) {
          try {
            await db.execute("ALTER TABLE diary ADD COLUMN image_path TEXT");
            log("数据库迁移 v16→v17：diary 表已添加 image_path 截图附件列");
          } catch (e) {
            log("数据库迁移 v16→v17 失败（不阻止升级）：$e");
          }
        }
        // 数据库升级：从版本17升级到版本18，新增 diary_images 多图附件表
        //（电脑端图片经 image_index.json 下发后落本表；手机自拍截图仍存
        // diary.image_path，两处合起来才是某条笔记的完整图片列表）
        if (oldVersion < 18) {
          try {
            await db.execute(_diaryImagesTableSql);
            await db.execute(
              'CREATE INDEX IF NOT EXISTS idx_diary_images_note '
              'ON diary_images(note_uuid)',
            );
            log("数据库迁移 v17→v18：已创建 diary_images 多图附件表");
          } catch (e) {
            log("数据库迁移 v17→v18 失败（不阻止升级）：$e");
          }
        }
        // 数据库升级：从版本18升级到版本19，云同步 v2——
        // diary 加 updated_at（用户侧编辑的毫秒时间戳，LWW 裁决依据）+
        // sync_note_meta 旁路表（基线哈希 + 电脑端标签/附件/未知字段透传）。
        // 存量 updated_at 由首开成功后回填（事务里只做 DDL）
        if (oldVersion < 19) {
          try {
            await db.execute('ALTER TABLE diary ADD COLUMN updated_at INTEGER');
            await db.execute(_syncNoteMetaTableSql);
            log("数据库迁移 v18→v19：diary.updated_at + sync_note_meta 就绪（回填在首开后执行）");
          } catch (e) {
            log("数据库迁移 v18→v19 失败（不阻止升级）：$e");
          }
        }
      },
    );
  }

  /// 为 sync_uuid 为 NULL 的行批量生成 UUID v4。
  /// 迁移（v14）与云同步前（ensureSyncUuids）共用：说明卡等 batch.insert
  /// 直插的行不带 uuid，靠这里兜底
  Future<int> _backfillSyncUuids(Database db) async {
    const uuidGen = Uuid();
    int count = 0;
    final batch = db.batch();
    for (final table in const ['items', 'diary']) {
      final rows = await db.query(
        table,
        columns: ['id'],
        where: 'sync_uuid IS NULL',
      );
      for (final r in rows) {
        batch.update(
          table,
          {'sync_uuid': uuidGen.v4()},
          where: 'id = ?',
          whereArgs: [r['id']],
        );
        count++;
      }
    }
    await batch.commit(noResult: true);
    return count;
  }

  /// 云同步开始前调用：补齐所有缺失的 sync_uuid，保证全量导出时每行都有
  /// 合并身份
  Future<void> ensureSyncUuids() async {
    final dbClient = await db;
    final n = await _backfillSyncUuids(dbClient);
    if (n > 0) log("[DbHelper] 云同步前补生成 $n 条 sync_uuid");
  }

  /// 记录删除墓碑（uuid 已存在则刷新 deleted_at）
  Future<void> _recordSyncTombstone(
    DatabaseExecutor dbClient,
    String uuid,
    String kind,
  ) async {
    await dbClient.insert(
      'sync_deleted',
      {
        'uuid': uuid,
        'kind': kind,
        'deleted_at': DateTime.now().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 全量墓碑 uuid 集合（云同步下载合并时过滤「本地删过的远端条目」）
  Future<Set<String>> loadSyncTombstones() async {
    final dbClient = await db;
    final rows = await dbClient.query('sync_deleted', columns: ['uuid']);
    return rows.map((r) => r['uuid'] as String).toSet();
  }

  /// 撤销删除：把刚删除的日记行原样插回（本地自增 id 重新分配，其余字段
  /// 全保留，含 sync_uuid——跨端身份不变，含 sort_order——撤销删除回到
  /// 删除前的原位置而非顶部）并清除其同步墓碑（行已复活，
  /// 墓碑残留会让云端同 uuid 条目永远无法再拉回本地）。
  /// 调用方：悬浮窗「滑动直接删除」的撤销窗口（OverlayHome._undoSwipeDelete）。
  /// 录音文件不在此处处理——撤销窗口内音频从未删除，无需还原
  Future<int> restoreDeletedDiary(Map<String, dynamic> row) async {
    final dbClient = await db;
    final uuid = row['sync_uuid'] as String?;
    final newId = await dbClient.insert('diary', {
      'content': row['content'],
      'created_at': row['created_at'],
      'audio_path': row['audio_path'],
      'duration': row['duration'],
      'is_archived': row['is_archived'] ?? 0,
      'exported_at': row['exported_at'],
      'tag': row['tag'],
      'sync_uuid': uuid,
      'is_locked': row['is_locked'] ?? 0,
      'sort_order': row['sort_order'],
      // 截图附件随行还原：撤销窗口内图片文件从未删除（同录音），直接指回原路径
      'image_path': row['image_path'],
      // v2 删除同步后撤销 = 一次晚于墓碑的显式编辑（对端按
      // updated_at > deleted_at 允许复活）；沿用旧时间会被墓碑立刻再删掉
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    });
    if (uuid != null) {
      await dbClient.delete(
        'sync_deleted',
        where: 'uuid = ?',
        whereArgs: [uuid],
      );
    }
    unawaited(CloudSyncDataVersion.bump()); // 库行删而又插，按变更计
    return newId;
  }

  // 内置说明卡片：首次创建数据库时调用，写入 9 条功能引导作为普通日记
  // 用户可左滑删除任意一条，删除后不会重生（除非清除数据/重装）
  // 时间戳策略：offsetSec 越大 → created_at 越新 → 排序越靠前
  Future<void> _seedTutorialDiaries(Database db) async {
    final baseTime = DateTime.now();
    final tutorials = <Map<String, dynamic>>[
      {
        'content': '📋 点击复制\n轻点任意日记卡片，内容即刻复制到剪贴板，无提示音，可直接粘贴到任意位置。',
        'offsetSec': 9,
      },
      {
        'content': '✏️ 双击编辑\n双击日记卡片，从底部弹出抽屉，可修改文字后保存。（设置页可交换单击与双击）',
        'offsetSec': 8,
      },
      {
        'content':
            '💥 长按大爆炸\n长按日记卡片，文字会炸成一个个词块：点选或滑动连选想要的词，可一键复制，也可用选中的词直接搜索。',
        'offsetSec': 7,
      },
      {
        'content': '💬 AI 对话\n点击日记卡片底部的 AI 按钮，内容自动复制并跳转 ChatGPT、DeepSeek、Kimi 等应用继续对话。',
        'offsetSec': 6,
      },
      {'content': '⬅️ 左滑归档/删除\n将日记卡片向左滑动：活跃日记会归档，已归档日记会被彻底删除。', 'offsetSec': 5},
      {
        'content':
            '📦 搬家模式\n录制页开启搬家模式后，手机放一旁就行：app 会一直听，自动听出每句话的开头结尾，说一句记一条，存好一件还会开口播报“已保存X到Y”，连说多件物品也逐条入库，全程不用看屏幕、不用按按钮。',
        'offsetSec': 4,
      },
      {
        'content':
            '✅ 语音代办清单\n开口必须以“代办”或“待办”起头，再用顿号、“还有”、“再买”连接多个事项，系统才会自动拆分为待办清单（说正常话不会误判）。',
        'offsetSec': 3,
      },
      {
        'content':
            '↩️ 搬家模式撤销\n搬家模式听错时（如把“电扇”听成“电脑”），10 秒内说“不对”“撤销”“错了”“取消”“删掉”“删除”“报销”等任一关键词（或“这条不对”“删除上一条”），会自动删除上一条物品记录并播报“已撤销”。',
        'offsetSec': 2,
      },
      {
        'content': '⏰ 时间自动识别\n日记中写到时间（如“明天下午3点”），对应文字会变蓝色，点击即可一键设置系统闹钟。',
        'offsetSec': 1,
      },
    ];

    final batch = db.batch();
    for (final t in tutorials) {
      batch.insert('diary', {
        'content': t['content'],
        'created_at': baseTime
            .add(Duration(seconds: t['offsetSec'] as int))
            .toIso8601String(),
        'audio_path': null,
        'duration': 0,
        'is_archived': 0,
        'exported_at': null,
        // sort_order 取 -offsetSec：越小越靠前，对齐 offsetSec 越大越靠前
        // 的既有心智（与 created_at 排序等价，首次重排前的初始顺序）
        'sort_order': -(t['offsetSec'] as int),
      });
    }
    await batch.commit(noResult: true);
    log("[DbHelper] 已内置 ${tutorials.length} 条说明卡片");
  }

  // ====================================================================
  // 版本化说明卡片（增量插入机制）
  // ====================================================================
  // 背景：_seedTutorialDiaries 只在首次建库时跑一次，老用户升级后看不到
  //       新版本附带的新功能说明。此机制由 SplashScreen 启动时调用，
  //       按 build number 对比 prefs 记录，为老用户补充插入新增卡片。
  //
  // 发布新版本附带新说明卡片时：只需在 _versionedTutorials 追加条目
  // （key 用 pubspec.yaml 的 version: x.y.z+N 中的 build number N）。
  //
  // 设计：onCreate 的 9 条基础卡保持不变，v18+ 的新卡统一只走本增量通道——
  //       新装用户 = onCreate 9 条 + 首次 seedVersionedTutorials 增量 1 条，
  //       单一事实来源，文案不需两处维护。

  /// v1.0.18(+18) 新增：上滑麦克风按钮新建文本笔记
  static const String _kTutorialSwipeFabText =
      '⌨️ 上滑建文本笔记\n在日记页按住底部麦克风圆钮向上滑动，拉出「Aa」标记后松手，即刻新建一条空白文本笔记，直接打字，无需语音。';

  /// v1.1.0(+19) 新增：悬浮窗语音定闹钟
  static const String _kTutorialOverlayAlarmText =
      '⏰ 悬浮窗语音定闹钟\n悬浮窗卡片上点闹钟按钮，说一句「周六晚上八点提醒我去看电影」，app 自动认出时间，拨动转轮确认后写入系统日历，到点响铃。「晚上八点」「两点半」这样随口说也能听懂。';

  /// v1.6.0(+27) 新增：卡片手势速览（单击复制 / 双击编辑 / 长按大爆炸）
  /// 老用户库里的旧内置卡（长按编辑/双击跳 AI）不会自动更新，用本卡告知新手势；
  /// 文案保持中性（不写"更新"），新装用户经全量插入收到时同样成立
  static const String _kTutorialGestureUpdateText =
      '💥 卡片手势一览\n单击卡片复制内容，双击弹出编辑抽屉，长按把文字炸成词块（点选/滑选后可一键复制或搜索）。单击与双击可在设置页交换。';

  /// 版本化说明卡片注册表：build number → 该版本新增的说明卡片文案
  /// ⚠️ key 必须用 int 的 build number（不能用版本字符串比较：
  ///    '1.0.9' > '1.0.17' 按字符串序为 true，会误判）
  static const Map<int, List<String>> _versionedTutorials = {
    18: [_kTutorialSwipeFabText], // v1.0.18：上滑麦克风新建文本笔记
    19: [_kTutorialOverlayAlarmText], // v1.1.0：悬浮窗语音定闹钟
    27: [_kTutorialGestureUpdateText], // v1.6.0：卡片手势更新（双击编辑/长按大爆炸）
  };

  /// prefs 键：已 seed 到的 build number
  static const String _kSeedBuildKey = 'tutorial_seed_build';

  /// 启动时调用（SplashScreen._doInit）：版本更新后补充插入新增的说明卡片
  ///
  /// 规则：
  /// - prefs 无记录（老用户首次升到引入此机制的版本）→ 插入注册表全部条目
  /// - prefs 有记录 → 只插入 build > 记录值 的条目（支持跨版本跳级升级）
  /// - 已是当前版本 → 跳过（用户手动删掉卡片后同版本不会重生，
  ///   下个大版本更新才会再出现，这是预期行为）
  Future<void> seedVersionedTutorials() async {
    final prefs = await SharedPreferences.getInstance();
    final info = await PackageInfo.fromPlatform();
    final currentBuild = int.tryParse(info.buildNumber) ?? 0;
    final seededBuild = prefs.getInt(_kSeedBuildKey);
    if (seededBuild != null && seededBuild >= currentBuild) return; // 已同步

    final newTutorials = <String>[];
    for (final entry in _versionedTutorials.entries) {
      if (seededBuild == null || entry.key > seededBuild) {
        newTutorials.addAll(entry.value);
      }
    }

    if (newTutorials.isNotEmpty) {
      final dbClient = await db;
      // created_at 取 now+10s：保证排在 onCreate 那 9 条基础卡
      // （baseTime+1~9s）之上，出现在列表最顶部；相对时间显示上无感
      final createdAt = DateTime.now()
          .add(const Duration(seconds: 10))
          .toIso8601String();
      // sort_order 从活跃区当前最小值-1 起递减：几条新卡按注册表顺序
      // 依次置顶（对齐 created_at+10s 置顶的既有心智）
      var nextOrder = await _nextTopSortOrder(dbClient);
      final batch = dbClient.batch();
      for (final content in newTutorials) {
        batch.insert('diary', {
          'content': content,
          'created_at': createdAt,
          'audio_path': null,
          'duration': 0,
          'is_archived': 0,
          'exported_at': null,
          'sort_order': nextOrder--,
        });
      }
      await batch.commit(noResult: true);
      log(
        "[DbHelper] 版本更新（seed=$seededBuild → $currentBuild），"
        "补充插入 ${newTutorials.length} 条说明卡片",
      );
    }

    // 无论是否插入都更新标记（无新增卡片的版本也要推进记录值）
    await prefs.setInt(_kSeedBuildKey, currentBuild);
  }

  // 插入数据
  Future<void> insertItem(String name, String location) async {
    final dbClient = await db;
    await dbClient.insert('items', {
      'name': name,
      'location': location,
      'sync_uuid': const Uuid().v4(),
    });
    unawaited(CloudSyncDataVersion.bump()); // 本地有变更未上云，入口行提示用
    log("已保存: $name 在 $location");
  }

  /// 搬家模式专用：插入物品并返回 rowid（用于撤销）
  /// 与 insertItem 的区别：返回 rowid 而非 void，调用方拿到 id 后可在撤销时按 id 删除
  /// 不修改老 insertItem，避免影响 RecordTab 现有保存流程
  Future<int> insertItemReturningId(String name, String location) async {
    final dbClient = await db;
    final id = await dbClient.insert('items', {
      'name': name,
      'location': location,
      'sync_uuid': const Uuid().v4(),
    });
    unawaited(CloudSyncDataVersion.bump());
    log("📦 [DB] 已保存(id=$id): $name 在 $location");
    return id;
  }

  /// 按 id 删除物品（搬家模式撤销用）。
  /// 删除前记墓碑：云同步时该 uuid 的远端条目不再拉回本地（防复活）
  Future<void> deleteItemById(int id) async {
    final dbClient = await db;
    final rows = await dbClient.query(
      'items',
      columns: ['sync_uuid'],
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    final uuid = rows.isEmpty ? null : rows.first['sync_uuid'] as String?;
    await dbClient.delete('items', where: 'id = ?', whereArgs: [id]);
    if (uuid != null) {
      await _recordSyncTombstone(dbClient, uuid, 'items');
    }
    unawaited(CloudSyncDataVersion.bump());
    log("🗑️ [DB] 已撤销(id=$id)");
  }

  // 查询所有数据（用于后续展示）
  Future<List<Map<String, dynamic>>> queryAll() async {
    final dbClient = await db;
    return await dbClient.query('items', orderBy: "id DESC");
  }

  // 按物品名模糊查询（日记页"XX在哪儿"答案区使用），按 id 倒序=最近优先
  Future<List<Map<String, dynamic>>> searchItemsByName(
    String keyword, {
    int limit = 10,
  }) async {
    final dbClient = await db;
    return await dbClient.query(
      'items',
      where: 'name LIKE ?',
      whereArgs: ['%$keyword%'],
      orderBy: "id DESC",
      limit: limit,
    );
  }

  // 按位置模糊查询（ListTab 反向语音查询"XX里有什么"使用），按 id 倒序=最近优先
  // 与 searchItemsByName API 对称，便于未来扩展（当前 ListTab 用 setSearchQuery 触发本地过滤）
  Future<List<Map<String, dynamic>>> searchItemsByLocation(
    String keyword, {
    int limit = 10,
  }) async {
    final dbClient = await db;
    return await dbClient.query(
      'items',
      where: 'location LIKE ?',
      whereArgs: ['%$keyword%'],
      orderBy: "id DESC",
      limit: limit,
    );
  }

  // --- 以下是新增的日记操作方法 ---

  // 1. 插入日记数据
  // 修改 insertDiary，支持同时写入 audioPath（可空）和 duration（时长，秒）
  Future<int> insertDiary(
    String content, {
    String? audioPath,
    int? duration,
  }) async {
    final dbClient = await db;
    final nowInstant = DateTime.now();
    String now = nowInstant.toIso8601String();
    final map = {
      'content': content,
      'created_at': now,
      'audio_path': audioPath,
      'duration': duration,
      'sync_uuid': const Uuid().v4(),
      // v19：新建行 updated_at = created_at（同一瞬时），v2 同步不会
      // 无端压过其它设备的后续编辑
      'updated_at': nowInstant.millisecondsSinceEpoch,
      // 新卡置顶：取活跃区当前最小 sort_order - 1（统一入口，
      // diary_tab/record_tab/overlay_data_client/overlay_voice_memo
      // 全部调用方共享同一语义）
      'sort_order': await _nextTopSortOrder(dbClient),
    };
    final id = await dbClient.insert('diary', map);
    unawaited(CloudSyncDataVersion.bump()); // 本地有变更未上云，入口行提示用
    log("日记已保存: $content, audio: $audioPath, duration: ${duration}秒");
    return id;
  }

  // 2. 查询所有日记（支持搜索关键词）
  Future<List<Map<String, dynamic>>> getDiaries({
    String? keyword,
    String? tag,
  }) async {
    final dbClient = await db;
    // 搜索关键词与标注筛选可叠加（AND）；tag 为 null 时不过滤（=全部）
    final conditions = <String>[];
    final args = <dynamic>[];
    if (keyword != null && keyword.isNotEmpty) {
      conditions.add('content LIKE ?');
      args.add('%$keyword%');
    }
    if (tag != null) {
      // 哨兵 filterNormal = 筛「普通」（无标注）档：库里无标注即 tag IS NULL
      if (tag == DiaryTag.filterNormal) {
        conditions.add('tag IS NULL');
      } else {
        conditions.add('tag = ?');
        args.add(tag);
      }
    }
    final whereSql = conditions.isEmpty
        ? ''
        : "WHERE ${conditions.join(' AND ')}";
    // 排序语义：活跃区（is_archived=0）在前，区内按 sort_order 升序
    //（越小越靠前，悬浮窗长按拖动排序的结果）；漏网的 NULL 行（回填前
    // 存量/异常写入）排活跃区尾部按时间倒序，显示不错乱、首次重排即
    // 规范化。归档区行 sort_order 恒 NULL → 全按 created_at DESC（现状不变）
    //
    // image_count / primary_image_path 是派生的展示字段（V18）：
    // 手机自拍截图（diary.image_path，最多一张）+ 云同步下收的电脑端图片
    //（diary_images）合起来计数；缩略图优先用自拍截图，否则取下载图的第一张
    return await dbClient.rawQuery('''
      SELECT d.*,
        (CASE WHEN d.image_path IS NOT NULL AND d.image_path <> ''
              THEN 1 ELSE 0 END)
        + (SELECT COUNT(*) FROM diary_images i
           WHERE i.note_uuid = d.sync_uuid
             AND i.image_path IS NOT NULL AND i.image_path <> '')
        AS image_count,
        CASE
          WHEN d.image_path IS NOT NULL AND d.image_path <> ''
            THEN d.image_path
          ELSE (
            SELECT i.image_path FROM diary_images i
            WHERE i.note_uuid = d.sync_uuid
              AND i.image_path IS NOT NULL AND i.image_path <> ''
            ORDER BY i.position ASC, i.sha256 ASC
            LIMIT 1
          )
        END AS primary_image_path
      FROM diary d
      $whereSql
      ORDER BY
        d.is_archived ASC,
        (d.sort_order IS NULL) ASC,
        d.sort_order ASC,
        d.created_at DESC
    ''', args);
  }

  // 按 id 查单条日记（电脑访问服务 PUT/DELETE 前定位 audio_path 用，见
  // web_server/diary_web_server.dart）
  Future<Map<String, dynamic>?> getDiaryById(int id) async {
    final dbClient = await db;
    final rows = await dbClient.query(
      'diary',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  // 3. 删除某条日记。
  // 删除前记墓碑：云同步时该 uuid 的远端条目不再拉回本地（防复活）。
  // 所有删除入口（日记页左滑 / 悬浮窗 / 电脑访问服务 DELETE）都汇聚到这里
  Future<int> deleteDiary(int id) async {
    final dbClient = await db;
    final rows = await dbClient.query(
      'diary',
      columns: ['sync_uuid'],
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    final uuid = rows.isEmpty ? null : rows.first['sync_uuid'] as String?;
    final count = await dbClient.delete('diary', where: 'id = ?', whereArgs: [id]);
    if (uuid != null) {
      await _recordSyncTombstone(dbClient, uuid, 'diary');
    }
    unawaited(CloudSyncDataVersion.bump()); // 本地有变更未上云，入口行提示用
    return count;
  }

  // 归档日记（删除音频文件，标记归档状态）
  // 归档即清出排序域：sort_order 置 NULL（sort_order 仅活跃区有意义，
  // 归档区恒 NULL → 归档区全按 created_at DESC）
  Future<int> archiveDiary(int id) async {
    final dbClient = await db;
    final count = await dbClient.update(
      'diary',
      {
        'is_archived': 1,
        'sort_order': null,
        // 归档属于笔记状态，随 updated_at 参与 v2 LWW
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
    unawaited(CloudSyncDataVersion.bump()); // 归档位随同步载荷上云，算变更
    return count;
  }

  // 恢复日记（将 is_archived 标记为 0）：回活跃区顶部
  //（sort_order 取当前最小值-1，与新插入卡同款语义）
  Future<int> restoreDiary(int id) async {
    final dbClient = await db;
    final count = await dbClient.update(
      'diary',
      {
        'is_archived': 0,
        'sort_order': await _nextTopSortOrder(dbClient),
        // 恢复归档同样算笔记状态变更（否则对端会一直把它当归档）
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
    unawaited(CloudSyncDataVersion.bump());
    return count;
  }

  /// 重排活跃区（悬浮窗长按拖动排序的写库口）：
  /// orderedActiveIds = 重排后活跃区 diary id 顺序（顶→底）。事务内把整个
  /// 活跃区 sort_order 规范重写——orderedActiveIds 按序得 0..n-1；不在
  /// 列表里的活跃行（并发新增等漏网）按 created_at DESC 续排其后。
  /// 归档行不参与（归档区 sort_order 恒 NULL）。
  /// 调用方：OverlayHome 长按拖动排序 onReorder；主 App 日记页经
  /// DiarySyncBridge 计数比对自动跟随（由调用方 bump DiarySyncBridge）。
  /// ⚠️ 故意不 bump updated_at：排序是设备视图偏好，不该让笔记在 v2 LWW
  /// 里「变新」；顺序变化由载荷哈希差异传播（电脑端同规则）。
  Future<void> reorderActiveDiaries(List<int> orderedActiveIds) async {
    final dbClient = await db;
    await dbClient.transaction((txn) async {
      final stray = await txn.query('diary',
          columns: ['id'], where: 'is_archived = 0', orderBy: 'created_at DESC');
      final ordered = <int>[...orderedActiveIds];
      final seen = ordered.toSet();
      for (final r in stray) {
        final id = r['id'] as int;
        if (!seen.contains(id)) ordered.add(id);
      }
      final batch = txn.batch();
      for (var i = 0; i < ordered.length; i++) {
        batch.update('diary', {'sort_order': i},
            where: 'id = ? AND is_archived = 0', whereArgs: [ordered[i]]);
      }
      await batch.commit(noResult: true);
    });
    unawaited(CloudSyncDataVersion.bump()); // 顺序随同步载荷上云，算变更
  }

  // 4. 更新日记内容
  Future<int> updateDiary(int id, String content) async {
    final dbClient = await db;
    final count = await dbClient.update(
      'diary',
      {
        'content': content,
        // v2 编辑同步：用户改正文 = 一次显式编辑，刷新 LWW 时间
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
    unawaited(CloudSyncDataVersion.bump());
    return count;
  }

  // 5. 更新日记标注（悬浮窗标注功能）：tag 取值见 DiaryTag 常量
  //（'urgent'/'star'/'idea'/'task'），传 null = 取消标注。
  // 调用方：OverlayHome._setDiaryTag（悬浮窗展开卡标注行）
  Future<int> updateDiaryTag(int id, String? tag) async {
    final dbClient = await db;
    final count = await dbClient.update(
      'diary',
      {
        'tag': tag,
        // 标注属于笔记状态，随 updated_at 参与 v2 LWW
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
    unawaited(CloudSyncDataVersion.bump());
    return count;
  }

  /// 更新截图附件路径（悬浮窗长按复制按钮截屏落盘后调用）。传 null = 清除
  /// 附件引用（文件删除由调用方负责，本方法只改库）
  Future<int> updateDiaryImage(int id, String? imagePath) async {
    final dbClient = await db;
    final count = await dbClient.update(
      'diary',
      {'image_path': imagePath},
      where: 'id = ?',
      whereArgs: [id],
    );
    // 截图随 image_index.json 上云 → 算本地待同步变更
    unawaited(CloudSyncDataVersion.bump());
    return count;
  }

  // 6. 设置/解除笔记锁定（is_locked 列）：主 App 与悬浮窗共用（两个 engine
  // 直连同一库）。锁定后全链路打码 + 设备凭据认证可看（解锁「会话」与锁定
  // 标志是两回事：会话过期卡片重新打码，但 is_locked 标志不动）。
  // 调用方：DiaryTab._toggleDiaryLock / OverlayHome._toggleDiaryLock
  Future<int> setDiaryLocked(int id, bool locked) async {
    final dbClient = await db;
    final count = await dbClient.update(
      'diary',
      {
        'is_locked': locked ? 1 : 0,
        // 锁定状态属于笔记状态，随 updated_at 参与 v2 LWW
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
    unawaited(CloudSyncDataVersion.bump()); // 锁定位随同步载荷上云，算变更
    return count;
  }

  // --- 批量操作方法（用于导入导出） ---

  // 清除所有日记的导出标记（换目录重新导出时调用）
  Future<void> clearAllExportState() async {
    final dbClient = await db;
    await dbClient.update('diary', {'exported_at': null});
    log("已清除所有日记的导出标记");
  }

  // 标记日记已导出（设置 exported_at 为当前时间）
  Future<void> markDiaryExported(int id) async {
    final dbClient = await db;
    await dbClient.update(
      'diary',
      {'exported_at': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  // 查询未导出且未归档的日记（增量导出用）
  Future<List<Map<String, dynamic>>> queryUnexportedDiaries() async {
    final dbClient = await db;
    return await dbClient.query(
      'diary',
      where: 'is_archived != 1 AND exported_at IS NULL',
      orderBy: "created_at DESC",
    );
  }

  // 查询所有日记（用于导出）
  Future<List<Map<String, dynamic>>> queryAllDiaries() async {
    final dbClient = await db;
    return await dbClient.query('diary', orderBy: "created_at DESC");
  }

  // 批量插入物品
  Future<void> batchInsertItems(List<Map<String, String>> items) async {
    final dbClient = await db;
    final batch = dbClient.batch();
    for (var item in items) {
      batch.insert('items', {
        'name': item['name'],
        'location': item['location'],
        // 备份 CSV 不带 uuid，导入行生成新身份（内容级去重在导入方做）
        'sync_uuid': const Uuid().v4(),
      });
    }
    await batch.commit(noResult: true);
    unawaited(CloudSyncDataVersion.bump()); // 导入=本地数据变更，入口行提示用
    log("批量插入 ${items.length} 条物品数据");
  }

  // 批量插入日记
  Future<void> batchInsertDiaries(List<Map<String, dynamic>> diaries) async {
    final dbClient = await db;
    final batch = dbClient.batch();
    for (var diary in diaries) {
      batch.insert('diary', {
        'content': diary['content'],
        'created_at': diary['created_at'],
        'audio_path': diary['audio_path'],
        'duration': diary['duration'],
        // 标注列（v10 新增）：旧备份导入时解析结果为 null，落库即无标注
        'tag': diary['tag'],
        // 归档位随备份走（2026-09 修复：此前 CSV 不含归档列，导入行走 DDL
        // 默认 0，归档笔记恢复后全部复活成活跃）
        'is_archived': diary['is_archived'] ?? 0,
        // 排序键随备份走（v16 起 CSV 第 8 列；旧备份缺列解析为 null，
        // 活跃区 NULL 行由首开回填按时间兜底，归档行本来就恒 NULL）
        'sort_order': diary['sort_order'],
        // 备份 CSV 不带 uuid，导入行生成新身份（内容级去重在导入方做）
        'sync_uuid': const Uuid().v4(),
        // updated_at 取导入行的创建瞬时（不是 now）：备份还原的旧笔记
        // 不应在首次云同步时压过电脑端更晚的真实编辑
        'updated_at': _millisOfLocalTime(diary['created_at'] as String?),
      });
    }
    await batch.commit(noResult: true);
    unawaited(CloudSyncDataVersion.bump());
    log("批量插入 ${diaries.length} 条日记数据");
  }

  // 清空所有数据（用于导入前）。
  // 清空前全量记墓碑：导入是"替换本地"语义，被清掉的行若曾云同步过，
  // 下次同步不能从远端复活（备份导入的新行有自己的新 uuid，不受影响）
  Future<void> clearAllData() async {
    final dbClient = await db;
    await dbClient.transaction((txn) async {
      for (final kind in const ['items', 'diary']) {
        final rows = await txn.query(
          kind,
          columns: ['sync_uuid'],
          where: 'sync_uuid IS NOT NULL',
        );
        final now = DateTime.now().toIso8601String();
        final batch = txn.batch();
        for (final r in rows) {
          batch.insert(
            'sync_deleted',
            {'uuid': r['sync_uuid'], 'kind': kind, 'deleted_at': now},
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
        await batch.commit(noResult: true);
        await txn.delete(kind);
      }
    });
    unawaited(CloudSyncDataVersion.bump());
    log("已清空所有数据（含同步墓碑记录）");
  }

  // ==================== dismissed_splits（日记页 ✕ 学习）====================

  /// 记录用户 dismiss 的物品转存 content
  /// 用户在日记卡片橙色横条上点了 ✕ = "这条不是物品记录"
  /// UNIQUE 约束 + ConflictAlgorithm.ignore 保证同一 content 只入库一次
  Future<void> insertDismissedSplit(String content) async {
    final dbClient = await db;
    await dbClient.insert('dismissed_splits', {
      'content': content,
      'created_at': DateTime.now().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    log("[DbHelper] 已记录 dismiss 内容: $content");
  }

  /// 启动时一次性加载所有 dismissed content 到内存 Set
  /// DiaryTab.initState 调用，避免每次 _parseItemSplit 都查库
  Future<Set<String>> loadAllDismissedSplits() async {
    final dbClient = await db;
    final rows = await dbClient.query('dismissed_splits', columns: ['content']);
    final result = rows.map((r) => r['content'] as String).toSet();
    log("[DbHelper] 已加载 ${result.length} 条 dismissed 记录到内存");
    return result;
  }

  /// 查询单条 content 是否已 dismiss（主要靠内存 Set，此方法作为备份）
  Future<bool> isDismissedSplit(String content) async {
    final dbClient = await db;
    final rows = await dbClient.query(
      'dismissed_splits',
      where: 'content = ?',
      whereArgs: [content],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  /// 清空所有 dismiss 记录（设置页"重置智能学习"按钮用）
  Future<void> clearAllDismissedSplits() async {
    final dbClient = await db;
    await dbClient.delete('dismissed_splits');
    log("[DbHelper] 已清空所有 dismiss 记录");
  }

  // ==================== correction_pairs（错误-修正学习表）====================

  /// 表容量上限：超过时按 last_used_at 淘汰最久未命中的记录，
  /// 防止学习表无限膨胀（每条都是极小文本，500 条上限绰绰有余）
  static const int _kCorrectionPairsCap = 500;

  /// 学习「错误-修正」对：同一 (error, corrected) 已存在 → hit_count+1 并刷新
  /// last_used_at；否则插入新行。SQLite 版本兼容考虑（Android 老机 UPSERT
  /// 语法不可靠），用"先查后更/插"的事务实现。
  /// 调用方：日记编辑保存 / 录入页保存 / 悬浮窗编辑保存（用户主动修改识别
  /// 文本时）+ 一键修正被采纳时（强化计数）
  Future<void> learnCorrectionPairs(List<CorrectionPair> pairs) async {
    if (pairs.isEmpty) return;
    final dbClient = await db;
    final now = DateTime.now().toIso8601String();
    // 同一批次内先按 (error, correct) 去重，避免 batch 里 SELECT 看不到
    // 同事务未提交的插入导致重复建行
    final deduped = <CorrectionPair>{...pairs}.toList();
    await dbClient.transaction((txn) async {
      for (final p in deduped) {
        if (p.error.isEmpty || p.error == p.correct) continue;
        final rows = await txn.query(
          'correction_pairs',
          columns: ['id'],
          where: 'error_text = ? AND corrected_text = ?',
          whereArgs: [p.error, p.correct],
          limit: 1,
        );
        if (rows.isNotEmpty) {
          await txn.rawUpdate(
            'UPDATE correction_pairs SET hit_count = hit_count + 1, last_used_at = ? WHERE id = ?',
            [now, rows.first['id']],
          );
          log("[DbHelper] 修正对命中+1: ${p.error} → ${p.correct}");
        } else {
          await txn.insert('correction_pairs', {
            'error_text': p.error,
            'corrected_text': p.correct,
            'hit_count': 1,
            'created_at': now,
            'last_used_at': now,
          });
          log("[DbHelper] 新学修正对: ${p.error} → ${p.correct}");
        }
      }
      // 容量控制：超出上限时淘汰最久未命中的行
      await txn.rawDelete(
        'DELETE FROM correction_pairs WHERE id IN ('
        'SELECT id FROM correction_pairs ORDER BY last_used_at DESC LIMIT -1 OFFSET ?)',
        [_kCorrectionPairsCap],
      );
    });
    unawaited(CloudSyncDataVersion.bump()); // 修正对随同步上云，算变更
    log("[DbHelper] 已学习 ${deduped.length} 条修正对");
  }

  /// 查出 text 中命中的修正对（按错误片段长度降序=先长后短替换更精确）。
  /// 每次识别回填/识别填框时调用一次，表容量有上限（≤500 行），全表扫描无压力
  Future<List<CorrectionPair>> matchCorrectionPairs(String text) async {
    if (text.isEmpty) return const [];
    final all = await getAllCorrectionPairs();
    return all.where((p) => text.contains(p.error)).toList();
  }

  /// 全量修正对（按错误片段长度降序、命中次数降序）。
  /// 录入页物品/位置两个字段分别匹配时复用一次查询；
  /// 顺带映射 created_at/last_used_at（query 本就取全列，管理页排序零额外 IO）
  Future<List<CorrectionPair>> getAllCorrectionPairs() async {
    final dbClient = await db;
    final rows = await dbClient.query(
      'correction_pairs',
      orderBy: 'LENGTH(error_text) DESC, hit_count DESC',
    );
    return rows
        .map(
          (r) => CorrectionPair(
            error: (r['error_text'] as String?) ?? '',
            correct: (r['corrected_text'] as String?) ?? '',
            hitCount: (r['hit_count'] as int?) ?? 1,
            createdAt: r['created_at'] as String?,
            lastUsedAt: r['last_used_at'] as String?,
          ),
        )
        .where((p) => p.error.isNotEmpty && p.error != p.correct)
        .toList();
  }

  /// 清空所有修正对（设置页修正管理页"清空全部"按钮用）。
  /// 语境档案一并清空（无主修正对的档案留着只会占容量）
  Future<void> clearAllCorrectionPairs() async {
    final dbClient = await db;
    await dbClient.delete('correction_pairs');
    await dbClient.delete('correction_pair_contexts');
    unawaited(CloudSyncDataVersion.bump());
    log("[DbHelper] 已清空所有错误-修正对");
  }

  /// 删除单条修正对（设置页修正管理页每行的删除按钮用）。
  /// 表没有暴露自增 id 到 UI 层，按 (error, corrected) 业务键删除；
  /// 该对的语境档案级联删除
  Future<int> deleteCorrectionPair(String error, String correct) async {
    final dbClient = await db;
    final count = await dbClient.delete(
      'correction_pairs',
      where: 'error_text = ? AND corrected_text = ?',
      whereArgs: [error, correct],
    );
    await dbClient.delete(
      'correction_pair_contexts',
      where: 'error_text = ? AND corrected_text = ?',
      whereArgs: [error, correct],
    );
    unawaited(CloudSyncDataVersion.bump());
    log("[DbHelper] 已删除修正对: $error → $correct");
    return count;
  }

  // ==================== correction_pair_contexts（修正对语境档案）====================

  /// 语境档案表容量上限（PairContextGate.tableCap 的 DB 侧同步）
  static const int _kPairContextsCap = PairContextGate.tableCap;

  /// 记录修正对语境档案（学习普通修正对时顺带，PairContextGate.extract 产出）：
  /// 同一 (error, correct, left, right) 已存在 → hit_count+1；否则插入。
  /// 事务内"先查后更/插"（同 learnCorrectionPairs 的老机 UPSERT 兼容写法）；
  /// 末尾按 hit_count 淘汰超限行，防止档案表无限膨胀
  Future<void> learnPairContexts(List<PairContextRecord> records) async {
    if (records.isEmpty) return;
    final dbClient = await db;
    final deduped = <PairContextRecord>{...records}.toList();
    await dbClient.transaction((txn) async {
      for (final r in deduped) {
        if (r.error.isEmpty) continue;
        final rows = await txn.query(
          'correction_pair_contexts',
          columns: ['rowid'],
          where:
              'error_text = ? AND corrected_text = ? AND left_context = ? AND right_context = ?',
          whereArgs: [r.error, r.correct, r.leftContext, r.rightContext],
          limit: 1,
        );
        if (rows.isNotEmpty) {
          await txn.rawUpdate(
            'UPDATE correction_pair_contexts SET hit_count = hit_count + 1 WHERE rowid = ?',
            [rows.first['rowid']],
          );
        } else {
          await txn.insert('correction_pair_contexts', {
            'error_text': r.error,
            'corrected_text': r.correct,
            'left_context': r.leftContext,
            'right_context': r.rightContext,
            'hit_count': 1,
          });
        }
      }
      // 容量控制：保 hit_count 最高的行（同分保留较新的）
      await txn.rawDelete(
        'DELETE FROM correction_pair_contexts WHERE rowid IN ('
        'SELECT rowid FROM correction_pair_contexts '
        'ORDER BY hit_count ASC, rowid DESC LIMIT -1 OFFSET ?)',
        [_kPairContextsCap],
      );
    });
    log("[DbHelper] 已记录 ${deduped.length} 条修正对语境档案");
  }

  /// 全量语境档案（提示点一次读全表建分组索引；容量有上限 ≤2000 行无压力）
  Future<List<PairContextRecord>> getAllPairContexts() async {
    final dbClient = await db;
    final rows = await dbClient.query('correction_pair_contexts');
    return rows
        .map(
          (r) => PairContextRecord(
            error: (r['error_text'] as String?) ?? '',
            correct: (r['corrected_text'] as String?) ?? '',
            leftContext: (r['left_context'] as String?) ?? '',
            rightContext: (r['right_context'] as String?) ?? '',
            hitCount: (r['hit_count'] as int?) ?? 1,
          ),
        )
        .where((r) => r.error.isNotEmpty)
        .toList();
  }

  // ============ correction_context_stats / correction_user_words（上下文纠错）============

  /// 共现统计表容量上限（CorrectionConfig.contextStatsCap 的 DB 侧副本，
  /// 不 import correction 模块避免反向依赖：DB 层只认 context_learner 的模型类）
  static const int _kContextStatsCap = 3000;

  /// 批量累加「同音词×上下文词」共现统计 + 用户选用词频
  /// （ContextLearner 产出的增量，用户明确纠错行为触发）。
  /// 事务内"先查后更/插"（同 learnCorrectionPairs 的老机 UPSERT 兼容写法）；
  /// 末尾按 count 淘汰超限行，防止统计表无限膨胀
  Future<void> applyContextLearning(
    List<ContextStatBump> statBumps,
    List<String> userWordBumps,
  ) async {
    if (statBumps.isEmpty && userWordBumps.isEmpty) return;
    final dbClient = await db;
    final now = DateTime.now().toIso8601String();
    // 同批次先聚合（事务内 SELECT 看不到未提交插入，不聚合会重复建行）
    final agg = <String, Map<String, int>>{};
    for (final b in statBumps) {
      if (b.source.isEmpty || b.context.isEmpty) continue;
      final inner = agg.putIfAbsent(b.source, () => {});
      inner[b.context] = (inner[b.context] ?? 0) + b.delta;
    }
    final freqAgg = <String, int>{};
    for (final w in userWordBumps) {
      if (w.isEmpty) continue;
      freqAgg[w] = (freqAgg[w] ?? 0) + 1;
    }
    if (agg.isEmpty && freqAgg.isEmpty) return;
    await dbClient.transaction((txn) async {
      for (final entry in agg.entries) {
        for (final e in entry.value.entries) {
          final rows = await txn.query(
            'correction_context_stats',
            columns: ['rowid'],
            where: 'source_word = ? AND context_word = ?',
            whereArgs: [entry.key, e.key],
            limit: 1,
          );
          if (rows.isNotEmpty) {
            await txn.rawUpdate(
              'UPDATE correction_context_stats SET count = count + ? WHERE source_word = ? AND context_word = ?',
              [e.value, entry.key, e.key],
            );
          } else {
            await txn.insert('correction_context_stats', {
              'source_word': entry.key,
              'context_word': e.key,
              'count': e.value,
            });
          }
        }
      }
      for (final w in freqAgg.entries) {
        final rows = await txn.query(
          'correction_user_words',
          columns: ['rowid'],
          where: 'word = ?',
          whereArgs: [w.key],
          limit: 1,
        );
        if (rows.isNotEmpty) {
          await txn.rawUpdate(
            'UPDATE correction_user_words SET frequency = frequency + ?, last_used_at = ? WHERE word = ?',
            [w.value, now, w.key],
          );
        } else {
          await txn.insert('correction_user_words', {
            'word': w.key,
            'frequency': w.value,
            'last_used_at': now,
          });
        }
      }
      // 容量控制：保 count 最高的行（同分保留较新的）
      await txn.rawDelete(
        'DELETE FROM correction_context_stats WHERE rowid IN ('
        'SELECT rowid FROM correction_context_stats '
        'ORDER BY count ASC, rowid DESC LIMIT -1 OFFSET ?)',
        [_kContextStatsCap],
      );
    });
    log(
      "[DbHelper] 上下文纠错统计已累加: 共现 ${agg.length} 词组、词频 ${freqAgg.length} 词",
    );
  }

  /// 全量共现统计（上下文纠错单例启动时一次预载进内存；
  /// 表容量有上限 ≤3000 行，全表读无压力）
  Future<Map<String, Map<String, int>>> getAllCorrectionContextStats() async {
    final dbClient = await db;
    final rows = await dbClient.query('correction_context_stats');
    final result = <String, Map<String, int>>{};
    for (final r in rows) {
      final source = (r['source_word'] as String?) ?? '';
      final context = (r['context_word'] as String?) ?? '';
      if (source.isEmpty || context.isEmpty) continue;
      (result[source] ??= {})[context] = (r['count'] as int?) ?? 0;
    }
    return result;
  }

  /// 全量用户选用词频（同上，预载进内存做评分弱先验）
  Future<Map<String, int>> getAllUserWords() async {
    final dbClient = await db;
    final rows = await dbClient.query('correction_user_words');
    return {
      for (final r in rows)
        if (((r['word'] as String?) ?? '').isNotEmpty)
          r['word'] as String: (r['frequency'] as int?) ?? 0,
    };
  }

  // ==================== 云同步（WebDAV，V14 新增）====================
  // 合并策略与调用方见 docs/architecture/cloud-sync.md：
  // 日记自 v2（V19）起走三方合并（updated_at LWW + 墓碑跨端传播，见
  // applySyncV2Notes）；物品按 sync_uuid 增量并集（编辑/删除仍不跨端）；
  // 修正对按 (error, corrected) 行级合并（hit_count 取大、last_used_at 取新）

  /// 远端新行的活跃区落位：按 created_at 插进本机当前显示顺序，取显示
  /// 顺序中「最后一条比它新的行」的 sort_order——同值行由 getDiaries 的
  /// created_at DESC 兜底排在其后，于是新笔记按时间各就各位，且**任何
  /// 既有行的 sort_order 都不动**（整区重编号会让所有笔记的载荷指纹
  /// 变化、下一轮同步多传一轮）。活跃区为空（换机全量恢复）保留远端
  /// 原值。返回 sync_uuid → sort_order；归档行不参与，调用方恒写 null。
  Future<Map<String, int?>> _placeIncomingRowsByTime(
    DatabaseExecutor dbClient,
    List<Map<String, dynamic>> incoming,
  ) async {
    final activeRows = await dbClient.query(
      'diary',
      columns: ['created_at', 'sort_order'],
      where: 'is_archived = 0',
      orderBy: '(sort_order IS NULL) ASC, sort_order ASC, created_at DESC',
    );
    // 内存时间线 = 本机当前显示顺序（含新行的落位结果）；order 取
    // 相邻行的原值（含 NULL：NULL 行都在活跃区尾部，同值同样按时间排）
    final timeline = <({int ms, int? order})>[
      for (final row in activeRows)
        (
          ms: _millisOfLocalTime(row['created_at'] as String?),
          order: row['sort_order'] as int?,
        ),
    ];
    // 云端文件序不可信：新行内部先按时间倒序落位（最新先插），同刻按
    // uuid 定序，保证多端对同一批新行算出的相对顺序一致
    final ordered = [...incoming]
      ..sort((a, b) {
        final byTime = _millisOfLocalTime(b['created_at'] as String?)
            .compareTo(_millisOfLocalTime(a['created_at'] as String?));
        if (byTime != 0) return byTime;
        return (a['sync_uuid'] as String? ?? '')
            .compareTo(b['sync_uuid'] as String? ?? '');
      });
    final placements = <String, int?>{};
    for (final row in ordered) {
      final ms = _millisOfLocalTime(row['created_at'] as String?);
      var anchor = -1; // 显示顺序里最后一条比它新的行
      for (var i = 0; i < timeline.length; i++) {
        if (timeline[i].ms > ms) anchor = i;
      }
      final order = timeline.isEmpty
          ? row['sort_order'] as int?
          : timeline[anchor < 0 ? 0 : anchor].order;
      placements[row['sync_uuid'] as String] = order;
      timeline.insert(anchor + 1, (ms: ms, order: order));
    }
    return placements;
  }

  /// 插入远端日记（云同步下载合并用）：sync_uuid 保留远端值保证跨端同一
  /// 身份；去重（uuid / content+created_at / 墓碑）由同步服务层算好后只传
  /// 待插行，这里 ConflictAlgorithm.ignore 兜底 uuid 撞车
  Future<int> insertRemoteDiaries(List<Map<String, dynamic>> diaries) async {
    if (diaries.isEmpty) return 0;
    final dbClient = await db;
    // 排序决策：本地活跃区为空（换机全量恢复）→ 尊重远端 sort_order
    //（NULL 的行由首开回填按时间兜底）；非空 → 新行按 created_at 插进
    // 本机现有顺序（用户反馈：电脑端补同步的旧笔记不该一口气堆到最前面）
    final activeCount = Sqflite.firstIntValue(await dbClient.rawQuery(
            'SELECT COUNT(*) FROM diary WHERE is_archived = 0')) ??
        0;
    final placements = activeCount == 0
        ? const <String, int?>{}
        : await _placeIncomingRowsByTime(dbClient, [
            for (final d in diaries)
              if ((d['is_archived'] ?? 0) == 0)
                {
                  'sync_uuid': d['sync_uuid'],
                  'created_at': d['created_at'],
                  'sort_order': d['sort_order'],
                },
          ]);
    final batch = dbClient.batch();
    for (final d in diaries) {
      batch.insert('diary', {
        'content': d['content'],
        'created_at': d['created_at'],
        // P1 不同步音频本体，远端落库 audio_path 置空（文件名留在云端
        // JSON 里，P2 音频同步启用时回填）
        'audio_path': null,
        'duration': d['duration'],
        'is_archived': d['is_archived'] ?? 0,
        'is_locked': d['is_locked'] ?? 0,
        'tag': d['tag'],
        'sync_uuid': d['sync_uuid'],
        // 归档行恒 NULL；活跃行按上文排序决策赋值
        'sort_order': (d['is_archived'] ?? 0) != 0
            ? null
            : (activeCount == 0
                ? d['sort_order']
                : placements[d['sync_uuid']]),
        // v19：v1 导入行没有 updated_at（= 手机端 P1 不传播编辑），
        // 按 created_at 瞬时落库，不会无端赢过真实编辑
        'updated_at': (d['updated_at'] as int?) ??
            _millisOfLocalTime(d['created_at'] as String?),
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    await batch.commit(noResult: true);
    log("[DbHelper] 云同步插入 ${diaries.length} 条远端日记");
    return diaries.length;
  }

  /// 插入远端物品（云同步下载合并用，语义同 insertRemoteDiaries）
  Future<int> insertRemoteItems(List<Map<String, dynamic>> items) async {
    if (items.isEmpty) return 0;
    final dbClient = await db;
    final batch = dbClient.batch();
    for (final i in items) {
      batch.insert(
        'items',
        {
          'name': i['name'],
          'location': i['location'],
          'sync_uuid': i['sync_uuid'],
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
    await batch.commit(noResult: true);
    log("[DbHelper] 云同步插入 ${items.length} 条远端物品");
    return items.length;
  }

  // ==================== 云同步 v2（notes / 墓碑 / 透传元数据） ====================

  /// 全量 v2 旁路元数据（key = note_uuid）。坏 JSON 由调用方按空处理
  Future<Map<String, Map<String, dynamic>>> loadSyncNoteMeta() async {
    final dbClient = await db;
    final rows = await dbClient.query('sync_note_meta');
    return {for (final r in rows) (r['note_uuid'] as String): r};
  }

  /// 墓碑原始行（key = uuid）：v2 上传需要 deleted_at 与 kind
  Future<Map<String, Map<String, dynamic>>> loadSyncTombstoneRows() async {
    final dbClient = await db;
    final rows = await dbClient.query('sync_deleted');
    return {for (final r in rows) (r['uuid'] as String): r};
  }

  /// 落库远端 v2 墓碑（kind='diary'）：本地 v1 导入与截图清理都靠它防复活
  Future<void> applyRemoteTombstones(Map<String, int> deletedAtMs) async {
    if (deletedAtMs.isEmpty) return;
    final dbClient = await db;
    final batch = dbClient.batch();
    for (final entry in deletedAtMs.entries) {
      batch.insert(
        'sync_deleted',
        {
          'uuid': entry.key,
          'kind': 'diary',
          'deleted_at': DateTime.fromMillisecondsSinceEpoch(entry.value)
              .toIso8601String(),
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  /// 删除本地墓碑（远端有更晚编辑 → 复活；撤销删除也走这里）
  Future<void> removeSyncTombstones(Iterable<String> uuids) async {
    final list = uuids.toList();
    if (list.isEmpty) return;
    final dbClient = await db;
    final batch = dbClient.batch();
    for (final uuid in list) {
      batch.delete('sync_deleted', where: 'uuid = ?', whereArgs: [uuid]);
    }
    await batch.commit(noResult: true);
  }

  /// 应用 v2 合并结果：删除远端墓碑命中的行 + 覆盖/插入 LWW 胜出的行 +
  /// 重写旁路元数据。单事务，避免中途失败留下半套状态。
  ///
  /// upserts 行字段：sync_uuid/content/created_at(本地无 Z)/duration/
  /// is_archived/is_locked/tag/sort_order/updated_at(ms)。
  /// 新行的活跃区排序沿用 v1 语义：本地活跃区空 → 尊重远端 sort_order，
  /// 否则按 created_at 插进本机现有顺序（见 _placeIncomingRowsByTime），
  /// 不搅乱本机手工顺序。
  Future<int> applySyncV2Notes({
    required List<Map<String, dynamic>> upserts,
    required List<String> deletes,
    required List<Map<String, dynamic>> metaRows,
  }) async {
    final dbClient = await db;
    var changed = 0;
    await dbClient.transaction((txn) async {
      for (final uuid in deletes) {
        final n = await txn.delete(
          'diary',
          where: 'sync_uuid = ?',
          whereArgs: [uuid],
        );
        changed += n;
        await txn.delete(
          'sync_note_meta',
          where: 'note_uuid = ?',
          whereArgs: [uuid],
        );
      }

      final existingRows = await txn.query(
        'diary',
        columns: ['id', 'sync_uuid'],
        where: 'sync_uuid IS NOT NULL',
      );
      final existingIds = <String, int>{
        for (final r in existingRows) (r['sync_uuid'] as String): r['id'] as int,
      };
      final activeCount = Sqflite.firstIntValue(await txn.rawQuery(
            'SELECT COUNT(*) FROM diary WHERE is_archived = 0')) ??
          0;
      final reuseRemoteOrder = activeCount == 0;

      // 第一遍：已有行按 LWW 结果落库（远端胜出可能改 sort_order），
      // 新行先收集，等已有行顺序定稿后再算落位
      final inserts = <Map<String, dynamic>>[];
      for (final row in upserts) {
        final uuid = row['sync_uuid'] as String;
        final id = existingIds[uuid];
        if (id == null) {
          inserts.add(row);
          continue;
        }
        final archived = (row['is_archived'] as int? ?? 0) != 0;
        final remoteOrder = row['sort_order'] as int?;
        final patch = <String, dynamic>{
          'content': row['content'],
          'created_at': row['created_at'],
          'duration': row['duration'],
          'is_archived': archived ? 1 : 0,
          'is_locked': row['is_locked'] ?? 0,
          'tag': row['tag'],
          'updated_at': row['updated_at'],
        };
        // 归档行恒 NULL；活跃行采用远端顺序（电脑端合并同语义，排序
        // 差异靠基线哈希判定为远端变更，双方最终收敛）。远端没给顺序
        // （旧数据/设备视图偏好）时保留本机值，不把列表打回时间序
        if (archived) {
          patch['sort_order'] = null;
        } else if (remoteOrder != null) {
          patch['sort_order'] = remoteOrder;
        }
        final n = await txn.update(
          'diary',
          patch,
          where: 'id = ?',
          whereArgs: [id],
        );
        changed += n;
      }

      // 第二遍：新行按 created_at 插进已定稿的本机顺序
      final newOrders = (reuseRemoteOrder || inserts.isEmpty)
          ? const <String, int?>{}
          : await _placeIncomingRowsByTime(txn, [
              for (final row in inserts)
                if ((row['is_archived'] as int? ?? 0) == 0) row,
            ]);
      for (final row in inserts) {
        final uuid = row['sync_uuid'] as String;
        final archived = (row['is_archived'] as int? ?? 0) != 0;
        final remoteOrder = row['sort_order'] as int?;
        await txn.insert('diary', {
          'content': row['content'],
          'created_at': row['created_at'],
          'audio_path': null,
          'duration': row['duration'],
          'is_archived': archived ? 1 : 0,
          'is_locked': row['is_locked'] ?? 0,
          'tag': row['tag'],
          'sync_uuid': uuid,
          'sort_order': archived
              ? null
              : (reuseRemoteOrder ? remoteOrder : newOrders[uuid]),
          'updated_at': row['updated_at'],
        });
        changed++;
      }

      for (final row in metaRows) {
        await txn.insert(
          'sync_note_meta',
          row,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
    return changed;
  }

  /// 云同步下载录音成功后按 sync_uuid 回填 audio_path（插入远端日记时
  /// audio_path 置空，音频补齐后恢复可播放）。同步的附属恢复而非用户侧
  /// 变更（audio basename 与云端 JSON 本就一致），不 bump 数据版本；
  /// 行不存在（uuid 撞车没插进来的兜底失败）返回 0，调用方忽略即可
  Future<int> updateDiaryAudioPathByUuid(String uuid, String audioPath) async {
    if (uuid.isEmpty || audioPath.isEmpty) return 0;
    final dbClient = await db;
    return await dbClient.update(
      'diary',
      {'audio_path': audioPath},
      where: 'sync_uuid = ?',
      whereArgs: [uuid],
    );
  }

  /// 云同步下载截图成功后按 sync_uuid 回填 image_path。同
  /// updateDiaryAudioPathByUuid：附属恢复不 bump 数据版本，也不清
  /// CloudSyncDataVersion（下一次 markSynced 统一快照）
  Future<int> updateDiaryImagePathByUuid(String uuid, String imagePath) async {
    if (uuid.isEmpty || imagePath.isEmpty) return 0;
    final dbClient = await db;
    return await dbClient.update(
      'diary',
      {'image_path': imagePath},
      where: 'sync_uuid = ?',
      whereArgs: [uuid],
    );
  }

  /// 云同步多图：某条笔记来自其他设备的全部已落盘图片（按 position/sha
  /// 稳定排序）。手机自拍截图在 diary.image_path，不在本表，调用方自行拼接
  Future<List<Map<String, dynamic>>> getDiaryImages(String noteUuid) async {
    if (noteUuid.isEmpty) return const [];
    final dbClient = await db;
    return await dbClient.query(
      'diary_images',
      where: "note_uuid = ? AND image_path IS NOT NULL AND image_path <> ''",
      whereArgs: [noteUuid],
      orderBy: 'position ASC, sha256 ASC',
    );
  }

  /// 同步用：全量多图行（含 image_path 为空/文件已丢的，供对账与补下）
  Future<List<Map<String, dynamic>>> loadDiaryImageRows() async {
    final dbClient = await db;
    return await dbClient.query('diary_images');
  }

  /// 落盘/更新一条云端图片记录。唯一键 (note_uuid, device_id, sha256)，
  /// 同一张图重复下载只覆盖路径，不产生重复行
  Future<int> upsertDiaryImage({
    required String noteUuid,
    required String deviceId,
    required String sha256,
    required String imagePath,
    String? remoteName,
    String? mimeType,
    int? byteSize,
    int position = 0,
    String? updatedAt,
  }) async {
    if (noteUuid.isEmpty || sha256.isEmpty) return 0;
    final dbClient = await db;
    return await dbClient.insert(
      'diary_images',
      {
        'note_uuid': noteUuid,
        'device_id': deviceId,
        'sha256': sha256,
        'image_path': imagePath,
        'remote_name': remoteName,
        'mime_type': mimeType,
        'byte_size': byteSize,
        'position': position,
        'updated_at': updatedAt,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<int> deleteDiaryImageRow(int id) async {
    final dbClient = await db;
    return await dbClient.delete(
      'diary_images',
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 清空某条笔记的全部下载图（笔记已在本地删除时由同步对账调用；
  /// 文件由调用方删除）
  Future<int> deleteDiaryImagesForNote(String noteUuid) async {
    if (noteUuid.isEmpty) return 0;
    final dbClient = await db;
    return await dbClient.delete(
      'diary_images',
      where: 'note_uuid = ?',
      whereArgs: [noteUuid],
    );
  }

  /// 修正对全量原始行（含 created_at/last_used_at，云同步合并裁决用；
  /// getAllCorrectionPairs 只返回业务字段不够用）
  Future<List<Map<String, dynamic>>> getAllCorrectionPairRows() async {
    final dbClient = await db;
    return await dbClient.query('correction_pairs');
  }

  /// 云同步修正对行级合并：按 (error_text, corrected_text) 对齐，
  /// 已存在 → hit_count 取双方较大值、last_used_at 取较新（ISO 字符串
  /// 字典序即时间序），任一字段变化才写库；不存在 → 整行插入。
  /// 事务收尾沿用 500 条容量上限按 last_used_at 淘汰（同 learnCorrectionPairs）。
  /// 返回发生写入的行数（新增+更新）
  Future<int> mergeRemoteCorrectionPairs(
    List<Map<String, dynamic>> remoteEntries,
  ) async {
    if (remoteEntries.isEmpty) return 0;
    final dbClient = await db;
    int changed = 0;
    await dbClient.transaction((txn) async {
      for (final e in remoteEntries) {
        final error = (e['error_text'] as String?) ?? '';
        final correct = (e['corrected_text'] as String?) ?? '';
        if (error.isEmpty || error == correct) continue;
        final remoteHit = (e['hit_count'] as int?) ?? 1;
        final remoteLast = e['last_used_at'] as String?;
        final rows = await txn.query(
          'correction_pairs',
          columns: ['id', 'hit_count', 'last_used_at'],
          where: 'error_text = ? AND corrected_text = ?',
          whereArgs: [error, correct],
          limit: 1,
        );
        if (rows.isEmpty) {
          await txn.insert('correction_pairs', {
            'error_text': error,
            'corrected_text': correct,
            'hit_count': remoteHit,
            'created_at': e['created_at'],
            'last_used_at': remoteLast,
          });
          changed++;
        } else {
          final localHit = (rows.first['hit_count'] as int?) ?? 1;
          final localLast = rows.first['last_used_at'] as String?;
          final mergedHit = remoteHit > localHit ? remoteHit : localHit;
          final mergedLast = _newerIso(remoteLast, localLast);
          if (mergedHit != localHit || mergedLast != localLast) {
            await txn.update(
              'correction_pairs',
              {'hit_count': mergedHit, 'last_used_at': mergedLast},
              where: 'id = ?',
              whereArgs: [rows.first['id']],
            );
            changed++;
          }
        }
      }
      // 容量控制：超出上限时淘汰最久未命中的行（与 learnCorrectionPairs 一致）
      await txn.rawDelete(
        'DELETE FROM correction_pairs WHERE id IN ('
        'SELECT id FROM correction_pairs ORDER BY last_used_at DESC LIMIT -1 OFFSET ?)',
        [_kCorrectionPairsCap],
      );
    });
    if (changed > 0) {
      log("[DbHelper] 云同步修正对合并写入 $changed 行");
    }
    return changed;
  }

  /// 两个 ISO8601 字符串取较新者（同格式字典序=时间序；null 视为最旧）
  static String? _newerIso(String? a, String? b) {
    if (a == null) return b;
    if (b == null) return a;
    return a.compareTo(b) >= 0 ? a : b;
  }
}
