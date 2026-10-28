// 悬浮窗展开卡截图附件回归（2026-10-21）：
// - 复制按钮 tap = 复制、long press = 截图附件入口（手势竞技场自然分流）
// - 有 image_path 时正文右侧渲染 44dp 缩略图，tap 打开预览回调
// - 锁定打码卡 / 无附件卡不渲染缩略图（图片属于笔记内容）
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shengwuji_app/overlay/overlay_constants.dart';
import 'package:shengwuji_app/overlay/widgets/overlay_diary_card.dart';
import 'package:shengwuji_app/theme/app_theme.dart';

/// 1×1 透明 PNG（Image.file 在测试环境能真实解码，避免 errorBuilder 干扰
/// “缩略图是否存在”的断言）
const String _kOnePixelPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAFgwJ/lK3Q6wAAAABJRU5ErkJggg==';

void main() {
  late String imagePath;

  setUpAll(() {
    final file = File(
      '${Directory.systemTemp.path}/overlay_card_image_attachment_test.png',
    );
    file.writeAsBytesSync(base64Decode(_kOnePixelPngBase64));
    imagePath = file.path;
  });

  Widget wrap({
    String? image,
    bool expanded = true,
    bool lockedHidden = false,
    VoidCallback? onCopy,
    VoidCallback? onCopyLongPress,
    VoidCallback? onImageTap,
  }) {
    return MaterialApp(
      theme: AppThemes.defaultTeal.toThemeData(),
      home: Scaffold(
        body: SizedBox(
          width: 296,
          child: ListView(
            children: [
              OverlayDiaryCard(
                diary: {
                  'id': 1,
                  'content': '截图附件测试正文',
                  'is_archived': 0,
                  'image_path': image,
                },
                maxWidth: 268,
                expanded: expanded,
                lockedHidden: lockedHidden,
                onCopy: onCopy,
                onCopyLongPress: onCopyLongPress,
                onImageTap: onImageTap,
              ),
            ],
          ),
        ),
      ),
    );
  }

  testWidgets('复制按钮：tap 走复制、long press 走截图入口', (tester) async {
    var copyCount = 0;
    var longPressCount = 0;
    await tester.pumpWidget(
      wrap(onCopy: () => copyCount++, onCopyLongPress: () => longPressCount++),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.copy));
    await tester.pump();
    expect(copyCount, 1);
    expect(longPressCount, 0);

    await tester.longPress(find.byIcon(Icons.copy));
    await tester.pump();
    expect(copyCount, 1);
    expect(longPressCount, 1);
  });

  testWidgets('有 image_path：展开态渲染 44dp 缩略图，tap 触发预览回调', (tester) async {
    var previewCount = 0;
    await tester.pumpWidget(
      wrap(image: imagePath, onImageTap: () => previewCount++),
    );
    await tester.pumpAndSettle();

    final imageFinder = find.byType(Image);
    expect(imageFinder, findsOneWidget);
    final size = tester.getSize(imageFinder);
    expect(size.width, 44);
    expect(size.height, 44);

    await tester.tap(imageFinder);
    await tester.pump();
    expect(previewCount, 1);
  });

  testWidgets('无 image_path：不渲染缩略图', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('锁定打码卡：即使有 image_path 也不渲染缩略图（内容不出卡）', (tester) async {
    await tester.pumpWidget(
      wrap(image: imagePath, lockedHidden: true, onImageTap: () {}),
    );
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsNothing);
    // 正文/操作条仍在（打码正文 + 锁按钮由父层传回调才渲染）
    expect(find.text('截图附件测试正文'), findsNothing);
  });

  testWidgets('缩略图在正文右侧：正文宽度被压缩，缩略图贴卡片内容区右缘', (tester) async {
    await tester.pumpWidget(wrap(image: imagePath));
    await tester.pumpAndSettle();

    final thumbRect = tester.getRect(find.byType(Image));
    final cardRect = tester.getRect(find.byType(OverlayDiaryCard));
    // 正文 RichText：卡片内可能还有时间行，按正文内容匹配保唯一
    final bodyRect = tester.getRect(
      find.descendant(
        of: find.byType(OverlayDiaryCard),
        matching: find.byWidgetPredicate(
          (w) => w is RichText && w.text.toPlainText().contains('截图附件测试正文'),
        ),
      ),
    );
    // 缩略图在正文右侧（Row 尾部），不是飘在正文左侧
    expect(thumbRect.left, greaterThanOrEqualTo(bodyRect.right));
    // 缩略图右缘贴内容区右缘：卡片盒右缘 - 外边距 14 - 水平内边距 - 描边
    expect(
      cardRect.right - thumbRect.right,
      closeTo(
        14 + OverlayConstants.cardHPadding + OverlayConstants.cardBorderWidth,
        0.5,
      ),
    );
  });
}
