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

class DbHelper {
  static Database? _db;

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
      // v14 自愈：先核 schema 再回填。版本号不可信的原因见 _ensureSyncSchema
      try {
        await _ensureSyncSchema(dbClient);
      } catch (e) {
        log("[DbHelper] ⚠️ sync 表结构自愈失败（写入将不可用，重启重试）：$e");
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
      return dbClient;
    } catch (e) {
      _opening = null;
      rethrow;
    }
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
    // 版本升级：3->4 时长, 4->5 归档, 5->6 导出标记, 6->7 lists 表, 7->8 清单合并到日记, 8->9 dismissed_splits 表, 9->10 diary.tag 标注列, 10->11 correction_pairs 错误-修正表, 11->12 上下文纠错统计表, 12->13 修正对语境档案表, 13->14 云同步列（sync_uuid + 墓碑表）, 14->15 diary.is_locked 笔记锁定列
    return await openDatabase(
      path,
      version: 15,
      onCreate: (db, version) async {
        // 创建物品表：id, name (物品), location (位置)
        // sync_uuid：云同步全局唯一身份（本地自增 id 两台设备会撞，合并键必须用它）
        await db.execute(
          "CREATE TABLE items(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, location TEXT, sync_uuid TEXT)",
        );
        // 创建日记表，包含音频时长字段；tag = 标注（悬浮窗标注功能，
        // 'urgent'/'star'/'idea'，NULL=无标注）；is_locked = 用户手动锁定的
        // 笔记（防锁屏悬浮窗偷看：全链路打码 + 设备凭据认证后可看）
        await db.execute(
          "CREATE TABLE diary(id INTEGER PRIMARY KEY AUTOINCREMENT, content TEXT, created_at TEXT, audio_path TEXT, duration INTEGER, is_archived INTEGER DEFAULT 0, exported_at TEXT, tag TEXT, sync_uuid TEXT, is_locked INTEGER DEFAULT 0)",
        );
        // dismissed_splits 表：用户在日记页 ✕ 掉的物品转存内容（V9 新增）
        // 同一 content UNIQUE，避免重复入库
        await db.execute(
          "CREATE TABLE dismissed_splits(id INTEGER PRIMARY KEY AUTOINCREMENT, content TEXT NOT NULL UNIQUE, created_at TEXT)",
        );
        // correction_pairs 表：错误-修正学习表（V11 新增）。
        // 用户手动修改识别文本时，对比「识别原文 → 保存文字」学到的片段级
        // 替换对（见 CorrectionLearner）；下次识别再出现相同错误片段时
        // 提示用户一键修正。(error_text, corrected_text) 联合 UNIQUE 去重
        await db.execute(
          "CREATE TABLE correction_pairs(id INTEGER PRIMARY KEY AUTOINCREMENT, error_text TEXT NOT NULL, corrected_text TEXT NOT NULL, hit_count INTEGER NOT NULL DEFAULT 1, created_at TEXT, last_used_at TEXT, UNIQUE(error_text, corrected_text))",
        );
        // correction_context_stats 表：同音词×上下文词共现统计（V12 新增）。
        // 用户编辑/一键修正确认了同音组纠错（如 质朴→智谱）时累加
        // 「用户选的词 × 上下文词」计数，供 ContextScorer 做上下文加权评分；
        // 与 correction_pairs 互补：同音组对绝不进盲替换表，只进这里
        await db.execute(
          "CREATE TABLE correction_context_stats(source_word TEXT NOT NULL, context_word TEXT NOT NULL, count INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(source_word, context_word))",
        );
        // correction_user_words 表：用户选用词频（V12 新增）。
        // log(1+frequency)×小系数 作为评分弱先验（只做 tiebreaker，
        // 不允许词频单独决定替换）
        await db.execute(
          "CREATE TABLE correction_user_words(word TEXT PRIMARY KEY, frequency INTEGER NOT NULL DEFAULT 0, last_used_at TEXT)",
        );
        // correction_pair_contexts 表：修正对语境档案（V13 新增）。
        // 普通修正对（非同音组）被学到时，顺带记录错误片段在识别原文中
        // 出现位置的左右邻接字符（PairContextGate 归一化）；提示一键修正前
        // 比对当前文本的邻接字符，语境吻合才弹提示（语境门控），
        // 「互联网影视可控」学到的「影视→隐私」不会打扰「今晚看的影视不错」
        await db.execute(
          "CREATE TABLE correction_pair_contexts(error_text TEXT NOT NULL, corrected_text TEXT NOT NULL, left_context TEXT NOT NULL DEFAULT '', right_context TEXT NOT NULL DEFAULT '', hit_count INTEGER NOT NULL DEFAULT 1, PRIMARY KEY(error_text, corrected_text, left_context, right_context))",
        );
        // sync_deleted 表：云同步删除墓碑（V14 新增）。
        // 本地删除日记/物品时记下其 sync_uuid，云同步下载合并时 uuid 命中
        // 墓碑的远端条目不再插回本地（防复活）。P1 删除不跨端传播，
        // 墓碑只在本地生效
        await db.execute(
          "CREATE TABLE sync_deleted(uuid TEXT PRIMARY KEY, kind TEXT NOT NULL, deleted_at TEXT NOT NULL)",
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
        //（悬浮窗日记卡片标注功能：'urgent'/'star'/'idea'，NULL=无标注）
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

  // 内置说明卡片：首次创建数据库时调用，写入 8 条功能引导作为普通日记
  // 用户可左滑删除任意一条，删除后不会重生（除非清除数据/重装）
  // 时间戳策略：offsetSec 越大 → created_at 越新 → 排序越靠前
  Future<void> _seedTutorialDiaries(Database db) async {
    final baseTime = DateTime.now();
    final tutorials = <Map<String, dynamic>>[
      {
        'content': '📋 点击复制\n轻点任意日记卡片，内容即刻复制到剪贴板，无提示音，可直接粘贴到任意位置。',
        'offsetSec': 8,
      },
      {'content': '✏️ 长按编辑\n长按日记卡片，从底部弹出抽屉，可修改文字后保存。', 'offsetSec': 7},
      {
        'content': '💬 双击跳 AI\n双击日记卡片，一键将内容分享到 ChatGPT、DeepSeek、Kimi 等应用继续对话。',
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
  // 设计：onCreate 的 8 条基础卡保持不变，v18+ 的新卡统一只走本增量通道——
  //       新装用户 = onCreate 8 条 + 首次 seedVersionedTutorials 增量 1 条，
  //       单一事实来源，文案不需两处维护。

  /// v1.0.18(+18) 新增：上滑麦克风按钮新建文本笔记
  static const String _kTutorialSwipeFabText =
      '⌨️ 上滑建文本笔记\n在日记页按住底部麦克风圆钮向上滑动，拉出「Aa」标记后松手，即刻新建一条空白文本笔记，直接打字，无需语音。';

  /// v1.1.0(+19) 新增：悬浮窗语音定闹钟
  static const String _kTutorialOverlayAlarmText =
      '⏰ 悬浮窗语音定闹钟\n悬浮窗卡片上点闹钟按钮，说一句「周六晚上八点提醒我去看电影」，app 自动认出时间，拨动转轮确认后写入系统日历，到点响铃。「晚上八点」「两点半」这样随口说也能听懂。';

  /// 版本化说明卡片注册表：build number → 该版本新增的说明卡片文案
  /// ⚠️ key 必须用 int 的 build number（不能用版本字符串比较：
  ///    '1.0.9' > '1.0.17' 按字符串序为 true，会误判）
  static const Map<int, List<String>> _versionedTutorials = {
    18: [_kTutorialSwipeFabText], // v1.0.18：上滑麦克风新建文本笔记
    19: [_kTutorialOverlayAlarmText], // v1.1.0：悬浮窗语音定闹钟
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
      // created_at 取 now+10s：保证排在 onCreate 那 8 条基础卡
      // （baseTime+1~8s）之上，出现在列表最顶部；相对时间显示上无感
      final createdAt = DateTime.now()
          .add(const Duration(seconds: 10))
          .toIso8601String();
      final batch = dbClient.batch();
      for (final content in newTutorials) {
        batch.insert('diary', {
          'content': content,
          'created_at': createdAt,
          'audio_path': null,
          'duration': 0,
          'is_archived': 0,
          'exported_at': null,
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
    String now = DateTime.now().toIso8601String();
    final map = {
      'content': content,
      'created_at': now,
      'audio_path': audioPath,
      'duration': duration,
      'sync_uuid': const Uuid().v4(),
    };
    final id = await dbClient.insert('diary', map);
    unawaited(CloudSyncDataVersion.bump()); // 本地有变更未上云，入口行提示用
    log("日记已保存: $content, audio: $audioPath, duration: ${duration}秒");
    return id;
  }

  // 2. 查询所有日记（支持搜索关键词）
  Future<List<Map<String, dynamic>>> getDiaries({String? keyword}) async {
    final dbClient = await db;
    if (keyword != null && keyword.isNotEmpty) {
      return await dbClient.rawQuery(
        '''
        SELECT * FROM diary
        WHERE content LIKE ?
        ORDER BY
          is_archived ASC,
          created_at DESC
      ''',
        ['%$keyword%'],
      );
    }
    return await dbClient.rawQuery('''
      SELECT * FROM diary
      ORDER BY
        is_archived ASC,
        created_at DESC
    ''');
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
  Future<int> archiveDiary(int id) async {
    final dbClient = await db;
    final count = await dbClient.update(
      'diary',
      {'is_archived': 1},
      where: 'id = ?',
      whereArgs: [id],
    );
    unawaited(CloudSyncDataVersion.bump()); // 归档位随同步载荷上云，算变更
    return count;
  }

  // 恢复日记（将 is_archived 标记为 0）
  Future<int> restoreDiary(int id) async {
    final dbClient = await db;
    final count = await dbClient.update(
      'diary',
      {'is_archived': 0},
      where: 'id = ?',
      whereArgs: [id],
    );
    unawaited(CloudSyncDataVersion.bump());
    return count;
  }

  // 4. 更新日记内容
  Future<int> updateDiary(int id, String content) async {
    final dbClient = await db;
    final count = await dbClient.update(
      'diary',
      {'content': content},
      where: 'id = ?',
      whereArgs: [id],
    );
    unawaited(CloudSyncDataVersion.bump());
    return count;
  }

  // 5. 更新日记标注（悬浮窗标注功能）：tag 取值见 DiaryTag 常量
  //（'urgent'/'star'/'idea'），传 null = 取消标注。
  // 调用方：OverlayHome._setDiaryTag（悬浮窗展开卡标注行）
  Future<int> updateDiaryTag(int id, String? tag) async {
    final dbClient = await db;
    final count = await dbClient.update(
      'diary',
      {'tag': tag},
      where: 'id = ?',
      whereArgs: [id],
    );
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
      {'is_locked': locked ? 1 : 0},
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
        // 备份 CSV 不带 uuid，导入行生成新身份（内容级去重在导入方做）
        'sync_uuid': const Uuid().v4(),
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
  // 日记/物品按 sync_uuid 增量并集（编辑/删除 P1 不跨端），修正对按
  // (error, corrected) 行级合并（hit_count 取大、last_used_at 取新）

  /// 插入远端日记（云同步下载合并用）：sync_uuid 保留远端值保证跨端同一
  /// 身份；去重（uuid / content+created_at / 墓碑）由同步服务层算好后只传
  /// 待插行，这里 ConflictAlgorithm.ignore 兜底 uuid 撞车
  Future<int> insertRemoteDiaries(List<Map<String, dynamic>> diaries) async {
    if (diaries.isEmpty) return 0;
    final dbClient = await db;
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
