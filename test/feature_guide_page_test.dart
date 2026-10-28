import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shengwuji_app/settings/feature_guide_page.dart';
import 'package:shengwuji_app/theme/app_theme.dart';

/// 「功能说明」二级页回归：页面是纯展示，锁的是「全量分区 + 关键说法」契约。
/// 文案改动（尤其触发词、示例句）需同步这里，防止说明与实际功能漂移。
void main() {
  Future<void> pumpPage(WidgetTester tester) async {
    // 页面很长，ListView 懒构建——拉高视口让所有分区一次性进树
    tester.view.physicalSize = const Size(1080, 20000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppThemes.defaultTheme.toThemeData(),
        home: const FeatureGuidePage(),
      ),
    );
    await tester.pump();
  }

  testWidgets('渲染全部分区标题', (tester) async {
    await pumpPage(tester);

    for (final title in [
      '存物品（存物品页）',
      '查物品（查物品页）',
      '随手记（日记页）',
      '悬浮窗',
      '搜索与按键快捷方式',
      '语音识别与修正',
      '数据与同步',
      '外观、字体与安全',
    ]) {
      expect(find.text(title), findsOneWidget, reason: '缺少分区：$title');
    }
  });

  testWidgets('关键操作说法与触发词都在', (tester) async {
    await pumpPage(tester);

    for (final text in [
      '钥匙放在客厅抽屉里',
      '已保存 X 到 Y',
      '不对 / 撤销 / 错了',
      '客厅里有什么',
      '上滑新建文本笔记',
      'Obsidian',
      '第一次触发开始录音，第二次触发停止并转写',
      '截图并保存为这条笔记的附件',
      '黑屏',
      'AI 键',
      '待办',
      '热词',
      // 五个易漂移事实（2026-10-25 用户核对实际行为后定版）：加标注只在悬浮窗、
      // 截图随云同步双向、悬浮窗录音的按键绑定只写一处、黑屏分「新起/在录」两种、
      // 同步除手动外还有两处下拉刷新
      '加 / 改标注，得在悬浮窗里做',
      '截图不进本地备份 ZIP，但会随云端同步',
      '悬浮窗面板下拉刷新',
      '已经在录的那段',
      '按住说话',
    ]) {
      expect(find.textContaining(text), findsWidgets, reason: '缺少说明：$text');
    }
  });
}
