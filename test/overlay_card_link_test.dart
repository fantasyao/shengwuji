import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shengwuji_app/overlay/widgets/overlay_diary_card.dart';
import 'package:shengwuji_app/theme/app_theme.dart';

/// 悬浮窗展开卡正文链接（2026-10-27）：下划线展示 + 点击走父层回调，
/// 且不能抢成「进入编辑」（外层 onTapUp 的字符偏移换算）。
void main() {
  Widget wrap({
    required String content,
    ValueChanged<String>? onLinkTap,
    ValueChanged<int>? onTextTap,
  }) => MaterialApp(
    theme: AppThemes.defaultTeal.toThemeData(),
    home: Scaffold(
      body: SizedBox(
        width: 296,
        child: ListView(
          children: [
            OverlayDiaryCard(
              diary: {'id': 1, 'content': content, 'is_archived': 0},
              maxWidth: 268,
              expanded: true,
              onCheckChanged: (_) {},
              onLinkTap: onLinkTap,
              onTextTap: onTextTap,
            ),
          ],
        ),
      ),
    ),
  );

  testWidgets('点正文链接：回调收到规范化 URL，且不误进编辑态', (tester) async {
    String? opened;
    int? editOffset;
    await tester.pumpWidget(
      wrap(
        content: '看 https://a.com/x 这个页面',
        onLinkTap: (url) => opened = url,
        onTextTap: (offset) => editOffset = offset,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tapOnText(find.textRange.ofSubstring('https://a.com/x'));
    await tester.pumpAndSettle();

    expect(opened, 'https://a.com/x');
    expect(editOffset, isNull, reason: '点链接不应同时进入编辑态');
  });

  testWidgets('点链接外的正文仍进入编辑（原行为不变）', (tester) async {
    String? opened;
    int? editOffset;
    await tester.pumpWidget(
      wrap(
        content: '看 https://a.com/x 这个页面',
        onLinkTap: (url) => opened = url,
        onTextTap: (offset) => editOffset = offset,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tapOnText(find.textRange.ofSubstring('这个页面'));
    await tester.pumpAndSettle();

    expect(editOffset, isNotNull);
    expect(opened, isNull);
  });

  testWidgets('www. 链接点击补 https:// 后回传', (tester) async {
    String? opened;
    await tester.pumpWidget(
      wrap(content: '去 www.example.com/a 看看', onLinkTap: (url) => opened = url),
    );
    await tester.pumpAndSettle();

    await tester.tapOnText(find.textRange.ofSubstring('www.example.com/a'));
    await tester.pumpAndSettle();

    expect(opened, 'https://www.example.com/a');
  });

  testWidgets('不传 onLinkTap：链接无下划线、点击落到编辑（不出现点不动的链接）', (tester) async {
    int? editOffset;
    await tester.pumpWidget(
      wrap(
        content: '看 https://a.com/x 这个页面',
        onTextTap: (offset) => editOffset = offset,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tapOnText(find.textRange.ofSubstring('https://a.com/x'));
    await tester.pumpAndSettle();

    expect(editOffset, isNotNull);
  });
}
