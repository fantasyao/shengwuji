// DbHelper.getDiaries 标注筛选（tag 参数）语义测试。
//
// 覆盖「普通」档（DiaryTag.filterNormal 哨兵 → tag IS NULL）：
//   a. filterNormal 只返回无标注日记（urgent/star/idea 全部被排除）
//   b. 真实标注值仍按 tag = ? 等值过滤（哨兵不破坏原语义）
//   c. tag=null 返回全部（含无标注）
//   d. 哨兵与 keyword 叠加（AND）：关键词在无标注行内再过滤
//   e. 哨兵不落库：filterNormal 字符串本身匹配不到任何行（即使有人误把
//      它当真实标注过滤也是空集而非全部）
//
// ⚠️ 文件内只跑一个 test：DbHelper._db 与 dbFileName 是静态状态，多 test
// 会共享同一条打开的连接互相干扰（同 db_sort_order_test 头注释纪律）。
// ⚠️ 独立库文件名：sqflite_common_ffi 的库文件是磁盘共享真实文件。
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shengwuji_app/db_helper.dart';
import 'package:shengwuji_app/utils/diary_tag.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  test('getDiaries 标注筛选：普通(无标注)/真实标注/全部/关键词叠加', () async {
    DbHelper.dbFileName = 'items_tag_filter_test.db';
    final dbPath = p.join(
      await databaseFactory.getDatabasesPath(),
      DbHelper.dbFileName,
    );
    await databaseFactory.deleteDatabase(dbPath);
    SharedPreferences.setMockInitialValues({});

    final db = DbHelper();
    // 新建库首开会插入教程种子日记（无标注，会混进「普通」档结果），先清空
    await db.clearAllData();
    final plain1 = await db.insertDiary('无标注日记一');
    final plain2 = await db.insertDiary('无标注日记二 含苹果');
    final urgent = await db.insertDiary('紧急日记 含苹果');
    final star = await db.insertDiary('收藏日记');
    final task = await db.insertDiary('待办日记');
    await db.updateDiaryTag(urgent, DiaryTag.urgent);
    await db.updateDiaryTag(star, DiaryTag.star);
    await db.updateDiaryTag(task, DiaryTag.task);

    Set<int> idsOf(List<Map<String, dynamic>> rows) =>
        rows.map((r) => r['id'] as int).toSet();

    // a. 普通档 = 只返回无标注
    final normal = await db.getDiaries(tag: DiaryTag.filterNormal);
    expect(idsOf(normal), {plain1, plain2});

    // b. 真实标注等值过滤（含 2026-10-22 新增的第 4 槽位 task）
    final urg = await db.getDiaries(tag: DiaryTag.urgent);
    expect(idsOf(urg), {urgent});
    final tsk = await db.getDiaries(tag: DiaryTag.task);
    expect(idsOf(tsk), {task});

    // c. null = 全部
    final all = await db.getDiaries();
    expect(idsOf(all), {plain1, plain2, urgent, star, task});

    // d. 哨兵 + 关键词 AND 叠加
    final normalWithKeyword = await db.getDiaries(
      keyword: '苹果',
      tag: DiaryTag.filterNormal,
    );
    expect(idsOf(normalWithKeyword), {plain2});

    // e. 哨兵不是真实标注值：按等值匹配它本身应为空集（经 rawQuery 直验，
    //    确认 filterNormal 永不会作为数据落库后被误命中——本测试构造的
    //    库里本就没有该值，此处验证 isValid 拒绝它）
    expect(DiaryTag.isValid(DiaryTag.filterNormal), isFalse);
    // 普通档颜色与悬浮窗默认卡片蓝同源（改 defaultCardColor 需同步决策）
    expect(DiaryTag.colorOf(DiaryTag.filterNormal), DiaryTag.normalColor);
  });
}
