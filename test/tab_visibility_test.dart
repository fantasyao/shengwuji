import 'package:flutter_test/flutter_test.dart';
import 'package:shengwuji_app/utils/tab_visibility.dart';

void main() {
  group('visibleTabStack（主界面 Tab 可见性推导）', () {
    test('默认路径：开关都不传（=false）→ 四页齐全（回归锁死：prefs 无 key / '
        'MainScaffold 不传参时老用户行为不变）', () {
      expect(visibleTabStack(), [0, 1, 2, 3]);
      expect(
        visibleTabStack(recordTabHidden: false, listTabHidden: false),
        [0, 1, 2, 3],
      );
    });

    test('只藏存物品页 → 查物品/随手记/设置，相对顺序不变且不占位', () {
      expect(visibleTabStack(recordTabHidden: true), [1, 2, 3]);
    });

    test('只藏查物品页 → 存物品/随手记/设置', () {
      expect(visibleTabStack(listTabHidden: true), [0, 2, 3]);
    });

    test('两页都藏 → 只剩随手记+设置（此时 IndexedStack 显示下标与语义索引错位）', () {
      expect(visibleTabStack(recordTabHidden: true, listTabHidden: true), [
        2,
        3,
      ]);
    });

    test('随手记与设置恒在（外部入口：快捷方式/分享/音量键/悬浮窗跳语义索引 2，'
        '设置页是开关宿主）', () {
      for (final r in [false, true]) {
        for (final l in [false, true]) {
          final stack = visibleTabStack(
            recordTabHidden: r,
            listTabHidden: l,
          );
          expect(stack, contains(tabIndexDiary), reason: 'r=$r l=$l');
          expect(stack, contains(tabIndexSettings), reason: 'r=$r l=$l');
        }
      }
    });

    test('语义索引常量与四页装配顺序一致（防有人调常量值而忘了装配方）', () {
      expect(tabIndexRecord, 0);
      expect(tabIndexList, 1);
      expect(tabIndexDiary, 2);
      expect(tabIndexSettings, 3);
    });
  });
}
