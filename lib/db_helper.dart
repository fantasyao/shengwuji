import 'app_logger.dart';
import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

class DbHelper {
  static Database? _db;

  // 获取数据库实例
  Future<Database> get db async {
    if (_db != null) return _db!;
    _db = await initDb();
    return _db!;
  }

  // 初始化数据库
  initDb() async {
    String path = join(await getDatabasesPath(), 'items.db');
    // 版本升级：3->4 时长, 4->5 归档, 5->6 导出标记, 6->7 lists 表, 7->8 清单合并到日记, 8->9 dismissed_splits 表
    return await openDatabase(
      path,
      version: 9,
      onCreate: (db, version) async {
        // 创建物品表：id, name (物品), location (位置)
        await db.execute(
          "CREATE TABLE items(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, location TEXT)",
        );
        // 创建日记表，包含音频时长字段
        await db.execute(
          "CREATE TABLE diary(id INTEGER PRIMARY KEY AUTOINCREMENT, content TEXT, created_at TEXT, audio_path TEXT, duration INTEGER, is_archived INTEGER DEFAULT 0, exported_at TEXT)",
        );
        // dismissed_splits 表：用户在日记页 ✕ 掉的物品转存内容（V9 新增）
        // 同一 content UNIQUE，避免重复入库
        await db.execute(
          "CREATE TABLE dismissed_splits(id INTEGER PRIMARY KEY AUTOINCREMENT, content TEXT NOT NULL UNIQUE, created_at TEXT)",
        );
        // 首次创建数据库时内置说明卡片（点击复制、长按编辑等 8 条功能引导）
        await _seedTutorialDiaries(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        // 数据库升级：从版本3升级到版本4，添加 duration 字段
        if (oldVersion < 4) {
          await db.execute("ALTER TABLE diary ADD COLUMN duration INTEGER");
        }
        // 数据库升级：从版本4升级到版本5，添加 is_archived 字段
        if (oldVersion < 5) {
          await db.execute(
            "ALTER TABLE diary ADD COLUMN is_archived INTEGER DEFAULT 0",
          );
        }
        // 数据库升级：从版本5升级到版本6，添加 exported_at 字段（增量导出标记）
        if (oldVersion < 6) {
          await db.execute("ALTER TABLE diary ADD COLUMN exported_at TEXT");
        }
        // 数据库升级：从版本6升级到版本7，新增 lists 表（清单存储）
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
            // 读取 lists 表所有数据，按创建时间排序
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

              // 解析 items_json，转为 markdown 任务列表格式
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

              // 标题 + 清单条目组合为 content
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

            // 删除 lists 表
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
      },
    );
  }

  // 内置说明卡片：首次创建数据库时调用，写入 8 条功能引导作为普通日记
  // 用户可左滑删除任意一条，删除后不会重生（除非清除数据/重装）
  // 时间戳策略：offsetSec 越大 → created_at 越新 → 排序越靠前
  Future<void> _seedTutorialDiaries(Database db) async {
    final baseTime = DateTime.now();
    // 顺序：点击复制 → 长按编辑 → 双击跳AI → 左滑 → 搬家模式 → 语音代办 → 撤销命令 → 时间识别
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
        'content': '📦 搬家模式\n录制页开启搬家模式后，双手不用看屏幕：持续录音 + Silero VAD 自动切段识别 + TTS 播报“已保存X到Y”，连说多件物品也逐条入库。',
        'offsetSec': 4,
      },
      {
        'content': '✅ 语音代办清单\n开口必须以“代办”或“待办”起头，再用顿号、“还有”、“再买”连接多个事项，系统才会自动拆分为待办清单（说正常话不会误判）。',
        'offsetSec': 3,
      },
      {
        'content': '↩️ 搬家模式撤销\n搬家模式中 TTS 念错时（如把“电扇”念成“电脑”），10 秒内说“不对”/“撤销”/“错了”等关键词，自动删除上一条物品记录并播报“已撤销”。',
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

  // 插入数据
  Future<void> insertItem(String name, String location) async {
    final dbClient = await db;
    await dbClient.insert('items', {'name': name, 'location': location});
    log("已保存: $name 在 $location");
  }

  /// 搬家模式专用：插入物品并返回 rowid（用于撤销）
  /// 与 insertItem 的区别：返回 rowid 而非 void，调用方拿到 id 后可在撤销时按 id 删除
  /// 不修改老 insertItem，避免影响 RecordTab 现有保存流程
  Future<int> insertItemReturningId(String name, String location) async {
    final dbClient = await db;
    final id = await dbClient.insert('items', {'name': name, 'location': location});
    log("📦 [DB] 已保存(id=$id): $name 在 $location");
    return id;
  }

  /// 按 id 删除物品（搬家模式撤销用）
  /// 注意：项目中没有老的 deleteItem(id)，文档超前；本方法是新建，不存在命名冲突
  Future<void> deleteItemById(int id) async {
    final dbClient = await db;
    await dbClient.delete('items', where: 'id = ?', whereArgs: [id]);
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
    };
    final id = await dbClient.insert('diary', map);
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

  // 3. 删除某条日记
  Future<int> deleteDiary(int id) async {
    final dbClient = await db;
    return await dbClient.delete('diary', where: 'id = ?', whereArgs: [id]);
  }

  // 归档日记（删除音频文件，标记归档状态）
  Future<int> archiveDiary(int id) async {
    final dbClient = await db;
    return await dbClient.update(
      'diary',
      {'is_archived': 1},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  // 4. 更新日记内容
  Future<int> updateDiary(int id, String content) async {
    final dbClient = await db;
    return await dbClient.update(
      'diary',
      {'content': content},
      where: 'id = ?',
      whereArgs: [id],
    );
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
      });
    }
    await batch.commit(noResult: true);
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
      });
    }
    await batch.commit(noResult: true);
    log("批量插入 ${diaries.length} 条日记数据");
  }

  // 清空所有数据（用于导入前）
  Future<void> clearAllData() async {
    final dbClient = await db;
    await dbClient.delete('items');
    await dbClient.delete('diary');
    log("已清空所有数据");
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
}
