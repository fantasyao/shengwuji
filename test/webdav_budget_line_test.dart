import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shengwuji_app/settings/webdav_budget_line.dart';
import 'package:shengwuji_app/sync/webdav_request_counter.dart';
import 'package:shengwuji_app/theme/app_theme.dart';
import 'package:shengwuji_app/theme/app_theme_extension.dart';

void main() {
  Future<void> pumpLine(
    WidgetTester tester,
    WebDavRequestCounter counter,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppThemes.defaultTheme.toThemeData(),
        home: Scaffold(body: WebDavBudgetLine(counter: counter)),
      ),
    );
  }

  testWidgets('正常额度显示本机合计与剩余估算', (tester) async {
    final counter = WebDavRequestCounter(engine: 'main');
    counter.record();
    counter.record();

    await pumpLine(tester, counter);

    expect(find.textContaining('这台手机共发出 2 次请求（含悬浮窗）'), findsOneWidget);
    expect(find.textContaining('还剩 598 次'), findsOneWidget);
    expect(find.textContaining('只统计这台手机'), findsOneWidget);
    expect(find.textContaining('电脑端和其它客户端不计入'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    counter.dispose();
  });

  testWidgets('达到 80% 变红并提示降频与滑出窗口时间', (tester) async {
    final counter = WebDavRequestCounter(engine: 'main', limit: 5);
    for (var i = 0; i < 4; i++) {
      counter.record();
    }

    await pumpLine(tester, counter);

    expect(find.textContaining('这台手机已发出 4 次请求（含悬浮窗）'), findsOneWidget);
    expect(find.textContaining('建议降低同步频率或暂停同步'), findsOneWidget);
    expect(find.textContaining('最早一批约'), findsOneWidget);
    expect(find.textContaining('分钟后滑出窗口'), findsOneWidget);

    final ext = AppThemeExtension.of(
      tester.element(find.byType(WebDavBudgetLine)),
    );
    final message = tester.widget<Text>(find.textContaining('建议降低同步频率或暂停同步'));
    expect(message.style?.color, ext.warningText);

    await tester.pumpWidget(const SizedBox());
    counter.dispose();
  });
}
