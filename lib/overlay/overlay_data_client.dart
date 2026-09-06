import 'dart:developer';
import 'dart:io';
import '../db_helper.dart';

/// 悬浮窗 engine 侧的数据客户端
///
/// 悬浮窗运行在独立 FlutterEngine（overlayMain 入口）中，插件由原生层
/// FlutterEngineGroup.createAndRunEngine 自动注册，因此这里可直接使用
/// sqflite 访问数据库（DbHelper 无 context/SharedPreferences 依赖，可直接复用），
/// 无需再经 MethodChannel 跨 engine 转发到主 isolate。
class OverlayDataClient {
  final DbHelper _dbHelper = DbHelper();

  /// 查询全部 diary 记录（含已归档）
  Future<List<Map<String, dynamic>>> getDiaries() async {
    try {
      final list = await _dbHelper.getDiaries();
      // ⚠️ sqflite query 返回 QueryResultSet（只读 List）包裹 QueryRow（只读 Map），
      // 上层对列表元素赋值（乐观 UI 替换条目）或改行字段都会抛
      // "Unsupported operation: read-only"——在客户端边界统一物化成
      // 普通可变 List + 可变 Map，调用方（OverlayHome）可自由修改
      final mutable = list
          .map((row) => Map<String, dynamic>.of(row))
          .toList();
      print('📥 [OverlayDataClient] queryDiaries 返回 ${mutable.length} 条');
      return mutable;
    } catch (e, stack) {
      print('❌ [OverlayDataClient] 直连查询 diary 失败: $e');
      log('queryDiaries error', error: e, stackTrace: stack);
      rethrow; // 向上抛出，让 UI 展示错误态，而不是伪装成空数据
    }
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

  /// 删除日记（删数据库行 + 删录音文件）。录音文件删除失败不阻塞删库结果
  ///（try-catch 容错，对齐主 App 物品转存删录音模式）；删库失败 rethrow，
  /// 让上层（OverlayHome._onCardDelete）回滚/打日志
  Future<void> deleteDiary(int id, String? audioPath) async {
    try {
      await _dbHelper.deleteDiary(id);
      if (audioPath != null && audioPath.isNotEmpty) {
        try {
          await File(audioPath).delete();
        } catch (e) {
          print('⚠️ [OverlayDataClient] 删除录音文件失败（库行已删）: $e');
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
}
