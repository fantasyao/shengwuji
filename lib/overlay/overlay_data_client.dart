import 'dart:developer';
import 'dart:io';
import '../db_helper.dart';
import '../sync/cloud_sync_service.dart';
import '../text_processor.dart';

/// 悬浮窗 engine 侧的数据客户端
///
/// 悬浮窗运行在独立 FlutterEngine（overlayMain 入口）中，插件由原生层
/// FlutterEngineGroup.createAndRunEngine 自动注册，因此这里可直接使用
/// sqflite 访问数据库（DbHelper 无 context/SharedPreferences 依赖，可直接复用），
/// 无需再经 MethodChannel 跨 engine 转发到主 isolate。
class OverlayDataClient {
  final DbHelper _dbHelper = DbHelper();

  /// 下拉刷新云同步：与主 App 设置页同一套 WebDAV 引擎。悬浮窗 engine 直连
  /// 同一数据库；热词读写走本地 user_hotwords.txt（TextProcessor 同一路径）
  late final CloudSyncService _cloudSyncService = CloudSyncService(
    dbHelper: _dbHelper,
    processor: TextProcessor(),
  );

  /// 查询全部 diary 记录（含已归档）
  Future<List<Map<String, dynamic>>> getDiaries() async {
    try {
      final list = await _dbHelper.getDiaries();
      // ⚠️ sqflite query 返回 QueryResultSet（只读 List）包裹 QueryRow（只读 Map），
      // 上层对列表元素赋值（乐观 UI 替换条目）或改行字段都会抛
      // "Unsupported operation: read-only"——在客户端边界统一物化成
      // 普通可变 List + 可变 Map，调用方（OverlayHome）可自由修改
      final mutable = list.map((row) => Map<String, dynamic>.of(row)).toList();
      print('📥 [OverlayDataClient] queryDiaries 返回 ${mutable.length} 条');
      return mutable;
    } catch (e, stack) {
      print('❌ [OverlayDataClient] 直连查询 diary 失败: $e');
      log('queryDiaries error', error: e, stackTrace: stack);
      rethrow; // 向上抛出，让 UI 展示错误态，而不是伪装成空数据
    }
  }

  /// 某条日记的全部图片路径：手机自拍截图（diary.image_path）在前，
  /// 云同步下收的电脑端多图（diary_images）按 position 跟随其后
  Future<List<String>> getDiaryImagePaths(Map<String, dynamic> diary) async {
    final paths = <String>[];
    final own = diary['image_path'] as String?;
    if (own != null && own.isNotEmpty) paths.add(own);
    final uuid = diary['sync_uuid'] as String?;
    if (uuid != null && uuid.isNotEmpty) {
      try {
        for (final row in await _dbHelper.getDiaryImages(uuid)) {
          final path = row['image_path'] as String?;
          if (path != null && path.isNotEmpty) paths.add(path);
        }
      } catch (e) {
        print('⚠️ [OverlayDataClient] 查询图片列表失败: $e');
      }
    }
    return paths;
  }

  /// 归档日记（仅置 is_archived=1 标记，不删音频文件——悬浮窗侧归档可恢复，
  /// 区别于主 App diary_tab 左滑归档的删音频逻辑；DbHelper.archiveDiary 本身也只改标记）
  Future<void> archiveDiary(int id) async {
    try {
      await _dbHelper.archiveDiary(id);
      print('📦 [OverlayDataClient] archiveDiary($id) 成功');
    } catch (e, stack) {
      print('❌ [OverlayDataClient] 直连归档 diary($id) 失败: $e');
      log('archiveDiary error', error: e, stackTrace: stack);
      rethrow; // 向上抛出，让调用方（OverlayHome._toggleArchive）回滚乐观 UI
    }
  }

  /// 恢复日记（置 is_archived=0；归档时音频未删，恢复后可正常播放）
  Future<void> restoreDiary(int id) async {
    try {
      await _dbHelper.restoreDiary(id);
      print('📤 [OverlayDataClient] restoreDiary($id) 成功');
    } catch (e, stack) {
      print('❌ [OverlayDataClient] 直连恢复 diary($id) 失败: $e');
      log('restoreDiary error', error: e, stackTrace: stack);
      rethrow; // 向上抛出，让调用方（OverlayHome._toggleArchive）回滚乐观 UI
    }
  }

  /// 删除日记（删数据库行 + 删录音文件 + 删截图附件）。文件删除失败不阻塞
  /// 删库结果（try-catch 容错，对齐主 App 物品转存删录音模式）；删库失败
  /// rethrow，让上层（OverlayHome._onCardDelete）回滚/打日志
  Future<void> deleteDiary(
    int id,
    String? audioPath, {
    String? imagePath,
  }) async {
    try {
      await _dbHelper.deleteDiary(id);
      if (audioPath != null && audioPath.isNotEmpty) {
        try {
          await File(audioPath).delete();
        } catch (e) {
          print('⚠️ [OverlayDataClient] 删除录音文件失败（库行已删）: $e');
        }
      }
      if (imagePath != null && imagePath.isNotEmpty) {
        try {
          await File(imagePath).delete();
        } catch (e) {
          print('⚠️ [OverlayDataClient] 删除截图附件失败（库行已删）: $e');
        }
      }
      print('🗑️ [OverlayDataClient] deleteDiary($id) 成功');
    } catch (e, stack) {
      print('❌ [OverlayDataClient] 直连删除 diary($id) 失败: $e');
      log('deleteDiary error', error: e, stackTrace: stack);
      rethrow;
    }
  }

  /// 新增日记（纯文本笔记，无录音）：插入后返回新行 id。
  /// 调用方：OverlayHome._startNewNote（新增笔记占位行）；失败 rethrow
  Future<int> insertDiary(String content) async {
    try {
      final id = await _dbHelper.insertDiary(
        content,
        audioPath: null,
        duration: null,
      );
      print('📝 [OverlayDataClient] insertDiary 成功 id=$id');
      return id;
    } catch (e, stack) {
      print('❌ [OverlayDataClient] 直连插入 diary 失败: $e');
      log('insertDiary error', error: e, stackTrace: stack);
      rethrow;
    }
  }

  /// 只删数据库行、保留录音文件（滑动删除的撤销窗口用：撤销需把行连同
  /// 音频一起还原，音频延迟到窗口到期/被打断时由 [deleteAudioFile] 补删）。
  /// 墓碑由 DbHelper.deleteDiary 内置记录；删库失败 rethrow 让上层回滚
  Future<void> deleteDiaryRowOnly(int id) async {
    try {
      await _dbHelper.deleteDiary(id);
      print('🗑️ [OverlayDataClient] deleteDiaryRowOnly($id) 成功（音频保留待窗口）');
    } catch (e, stack) {
      print('❌ [OverlayDataClient] 直连删除 diary 行($id) 失败: $e');
      log('deleteDiaryRowOnly error', error: e, stackTrace: stack);
      rethrow;
    }
  }

  /// 撤销删除：行原样插回（sync_uuid 保留、墓碑清除），返回新行 id。
  /// 调用方：OverlayHome._undoSwipeDelete；失败 rethrow 让上层打日志+重查
  Future<int> restoreDeletedDiary(Map<String, dynamic> row) async {
    try {
      final newId = await _dbHelper.restoreDeletedDiary(row);
      print('↩️ [OverlayDataClient] restoreDeletedDiary 成功 newId=$newId');
      return newId;
    } catch (e, stack) {
      print('❌ [OverlayDataClient] 直连恢复 diary 行失败: $e');
      log('restoreDeletedDiary error', error: e, stackTrace: stack);
      rethrow;
    }
  }

  /// 删除录音文件（滑动删除撤销窗口到期/被打断时的落定补删）。
  /// 失败只打日志不抛——库行早已删除，此处失败仅残留孤儿文件
  Future<void> deleteAudioFile(String? audioPath) async {
    if (audioPath == null || audioPath.isEmpty) return;
    try {
      await File(audioPath).delete();
      print('🗑️ [OverlayDataClient] 删除录音文件成功: $audioPath');
    } catch (e) {
      print('⚠️ [OverlayDataClient] 删除录音文件失败: $e');
    }
  }

  /// 下拉刷新：执行一次 WebDAV 手动同步（配置/合并/上传全在同步引擎内）。
  /// 调用方（OverlayHome）负责同步后重查列表与 Toast 反馈
  Future<CloudSyncResult> syncFromCloud() async {
    log('☁️ [OverlayDataClient] 下拉刷新触发云同步');
    return _cloudSyncService.sync();
  }

  /// 删除截图附件文件（滑动删除撤销窗口落定补删；重新截图替换旧图也走这里）。
  /// 失败只打日志不抛——与录音文件同语义，库行/字段已更新，最坏残留孤儿文件
  Future<void> deleteImageFile(String? imagePath) async {
    if (imagePath == null || imagePath.isEmpty) return;
    try {
      await File(imagePath).delete();
      print('🗑️ [OverlayDataClient] 删除截图附件成功: $imagePath');
    } catch (e) {
      print('⚠️ [OverlayDataClient] 删除截图附件失败: $e');
    }
  }
}
