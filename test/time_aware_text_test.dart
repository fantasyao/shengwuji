import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shengwuji_app/models/time_entity.dart';
import 'package:shengwuji_app/theme/app_theme.dart';
import 'package:shengwuji_app/widgets/time_aware_text.dart';

/// TimeAwareText 折叠参数透传：maxLines/overflow 必须同时到达
/// 空实体分支（Text）与富文本分支（Text.rich）两条渲染路径。
/// ⚠️ 只透传其一的回归会撞上「ellipsis + maxLines:null 按单行渲染」坑。
void main() {
  final entity = TimeEntity(
    text: '明天',
    start: 0,
    end: 2,
    typeName: 'relative',
    value: '2026-10-20 09:00',
  );

  Future<void> pump(
    WidgetTester tester, {
    required String text,
    List<TimeEntity> entities = const [],
    int? maxLines,
    TextOverflow? overflow,
    ValueChanged<TimeEntity>? onTimeTap,
    ValueChanged<Uri>? onLinkTap,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        // AppThemeExtension.of 经 Theme.extension 解析，必须挂应用主题
        theme: AppThemes.defaultTheme.toThemeData(),
        home: Scaffold(
          body: TimeAwareText(
            text: text,
            timeEntities: entities,
            onTimeTap: onTimeTap ?? (_) {},
            onLinkTap: onLinkTap,
            maxLines: maxLines,
            overflow: overflow,
          ),
        ),
      ),
    );
  }

  RichText richTextOf(WidgetTester tester) =>
      tester.widget<RichText>(find.byType(RichText));

  testWidgets('空实体分支：maxLines/overflow 透传到 Text', (tester) async {
    await pump(
      tester,
      text: '没有时间实体的普通文本',
      maxLines: 5,
      overflow: TextOverflow.ellipsis,
    );
    expect(richTextOf(tester).maxLines, 5);
    expect(richTextOf(tester).overflow, TextOverflow.ellipsis);
  });

  testWidgets('空实体分支：不传参时 maxLines 不受限、overflow 非省略号', (tester) async {
    await pump(tester, text: '普通文本');
    expect(richTextOf(tester).maxLines, isNull);
    // RichText 的 overflow 缺省即 clip（框架内部默认值，永远不会是 null），
    // 断言契约「不是 ellipsis」而非「是 null」
    expect(richTextOf(tester).overflow, isNot(TextOverflow.ellipsis));
  });

  testWidgets('富文本分支：maxLines/overflow 透传到 Text.rich', (tester) async {
    await pump(
      tester,
      text: '明天下午三点开会',
      entities: [entity],
      maxLines: 5,
      overflow: TextOverflow.ellipsis,
    );
    expect(richTextOf(tester).maxLines, 5);
    expect(richTextOf(tester).overflow, TextOverflow.ellipsis);
  });

  testWidgets('富文本分支：不传参时不受限（展开态不截断）', (tester) async {
    await pump(tester, text: '明天下午三点开会', entities: [entity]);
    expect(richTextOf(tester).maxLines, isNull);
    expect(richTextOf(tester).overflow, isNot(TextOverflow.ellipsis));
  });

  testWidgets('无时间实体也识别链接：点击回调规范化 URL', (tester) async {
    Uri? tapped;
    await pump(
      tester,
      text: '看 https://a.com/x 这个页面',
      onLinkTap: (uri) => tapped = uri,
    );

    await tester.tapOnText(find.textRange.ofSubstring('https://a.com/x'));
    await tester.pump();

    expect(tapped, Uri.parse('https://a.com/x'));
  });

  testWidgets('链接与时间实体共存：各自点击互不串台', (tester) async {
    TimeEntity? timeTapped;
    Uri? linkTapped;
    final time = TimeEntity(
      text: '明天',
      start: 0,
      end: 2,
      typeName: 'relative',
      value: '2026-10-20 09:00',
    );
    await pump(
      tester,
      text: '明天看 https://a.com/x',
      entities: [time],
      onTimeTap: (e) => timeTapped = e,
      onLinkTap: (uri) => linkTapped = uri,
    );

    await tester.tapOnText(find.textRange.ofSubstring('https://a.com/x'));
    await tester.pump();
    expect(linkTapped, Uri.parse('https://a.com/x'));
    expect(timeTapped, isNull);

    await tester.tapOnText(find.textRange.ofSubstring('明天'));
    await tester.pump();
    expect(timeTapped, same(time));
  });

  testWidgets('URL 里的日期让位给链接：点网址只跳浏览器，不触发时间点击', (tester) async {
    TimeEntity? timeTapped;
    Uri? linkTapped;
    // 时间解析可能把 URL 路径里的 2026/10/27 当成日期实体
    final urlDate = TimeEntity(
      text: '2026/10/27',
      start: '链接 https://a.com/'.length,
      end: '链接 https://a.com/2026/10/27'.length,
      typeName: 'absolute',
      value: '2026-10-27 00:00',
    );
    await pump(
      tester,
      text: '链接 https://a.com/2026/10/27',
      entities: [urlDate],
      onTimeTap: (e) => timeTapped = e,
      onLinkTap: (uri) => linkTapped = uri,
    );

    await tester.tapOnText(
      find.textRange.ofSubstring('https://a.com/2026/10/27'),
    );
    await tester.pump();

    expect(linkTapped, Uri.parse('https://a.com/2026/10/27'));
    expect(timeTapped, isNull, reason: 'URL 内的时间实体必须让位给链接');
  });

  testWidgets('链接未知回调时不显示可点击样式（文字仍是普通文本）', (tester) async {
    await pump(tester, text: '看 https://a.com/x 这个页面');
    final rich = richTextOf(tester);
    // 无回调 → 单段普通文本，没有任何下划线/链接 recognizer
    expect(rich.text.toPlainText(), '看 https://a.com/x 这个页面');
    final span = rich.text as TextSpan;
    expect(span.children, isNull);
  });

  testWidgets('外层卡片单击/双击手势下点链接：只跳链接，不触发复制/编辑', (tester) async {
    Uri? tapped;
    int cardTap = 0;
    int cardDoubleTap = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppThemes.defaultTheme.toThemeData(),
        home: Scaffold(
          body: GestureDetector(
            // 随手记卡片外层同款手势（diary_tab：单击复制 / 双击编辑）
            onTap: () => cardTap++,
            onDoubleTap: () => cardDoubleTap++,
            child: TimeAwareText(
              text: '看 https://a.com/x 这个页面',
              timeEntities: const [],
              onTimeTap: (_) {},
              onLinkTap: (uri) => tapped = uri,
            ),
          ),
        ),
      ),
    );

    await tester.tapOnText(find.textRange.ofSubstring('https://a.com/x'));
    // 外层有 onDoubleTap：单击要等 300ms 双击判定窗口关闭才结算
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(tapped, Uri.parse('https://a.com/x'));
    expect(cardTap, 0, reason: '点链接不应同时触发卡片复制');
    expect(cardDoubleTap, 0);
  });
}
