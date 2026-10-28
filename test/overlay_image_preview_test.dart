// 悬浮窗图片附件预览层手势回归（2026-10-21，2026-10-24 扩展多图图集）：
// - 单击图片 / 右上角 ✕ 关闭预览
// - 单图右滑超过阈值关闭、未过阈值回弹不关闭、左滑交给 InteractiveViewer 不关闭
// - 多图左右滑动切换、页码指示；多图右滑不再关闭
// - 左上角删除钮（2026-10-25）：只在本机自拍截图页进确认态，电脑端图页只提示
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shengwuji_app/overlay/widgets/overlay_image_preview.dart';

/// 1×1 透明 PNG（Image.file 在测试环境能真实解码，避免命中 errorBuilder）
const String _kOnePixelPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAFgwJ/lK3Q6wAAAABJRU5ErkJggg==';

void main() {
  late String imagePath;
  late String otherImagePath;
  var closeCount = 0;
  var deleteCount = 0;
  var foreignTapCount = 0;

  setUpAll(() {
    final bytes = base64Decode(_kOnePixelPngBase64);
    final file = File(
      '${Directory.systemTemp.path}/overlay_image_preview_test.png',
    );
    file.writeAsBytesSync(bytes);
    imagePath = file.path;
    // 第二张（电脑端同步来的图用）：同内容不同路径，删除钮按路径判归属
    final other = File(
      '${Directory.systemTemp.path}/overlay_image_preview_test_other.png',
    );
    other.writeAsBytesSync(bytes);
    otherImagePath = other.path;
  });

  setUp(() {
    closeCount = 0;
    deleteCount = 0;
    foreignTapCount = 0;
  });

  Future<void> pumpPreview(
    WidgetTester tester, {
    List<String>? imagePaths,
    String? ownImagePath,
    VoidCallback? onOwnImageDelete,
    VoidCallback? onForeignImageTap,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: OverlayImagePreview(
            imagePaths: imagePaths ?? [imagePath],
            onClose: () => closeCount++,
            ownImagePath: ownImagePath,
            onOwnImageDelete: onOwnImageDelete,
            onForeignImageTap: onForeignImageTap,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('单击图片关闭预览', (tester) async {
    await pumpPreview(tester);
    await tester.tap(find.byType(OverlayImagePreview));
    await tester.pump();
    expect(closeCount, 1);
  });

  testWidgets('右上角关闭按钮仍可关闭', (tester) async {
    await pumpPreview(tester);
    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    expect(closeCount, 1);
  });

  testWidgets('右滑超过阈值关闭预览', (tester) async {
    await pumpPreview(tester);
    await tester.drag(find.byType(OverlayImagePreview), const Offset(140, 0));
    await tester.pump();
    expect(closeCount, 1);
  });

  testWidgets('右滑未过阈值回弹且不关闭', (tester) async {
    await pumpPreview(tester);
    await tester.drag(find.byType(OverlayImagePreview), const Offset(30, 0));
    await tester.pumpAndSettle();
    expect(closeCount, 0);
    // 回弹后内容归位（AnimatedContainer transform 无横向位移）
    final container = tester.widget<AnimatedContainer>(
      find.byType(AnimatedContainer),
    );
    expect(container.transform!.getTranslation().x, 0);
  });

  testWidgets('左滑不关闭（留给 InteractiveViewer 处理）', (tester) async {
    await pumpPreview(tester);
    await tester.drag(find.byType(OverlayImagePreview), const Offset(-140, 0));
    await tester.pumpAndSettle();
    expect(closeCount, 0);
  });

  testWidgets('多图左右滑动切换并显示页码', (tester) async {
    await pumpPreview(tester, imagePaths: [imagePath, imagePath]);
    expect(find.text('1 / 2'), findsOneWidget);

    await tester.drag(find.byType(PageView), const Offset(-400, 0));
    await tester.pumpAndSettle();
    expect(find.text('2 / 2'), findsOneWidget);
    expect(closeCount, 0);

    await tester.drag(find.byType(PageView), const Offset(400, 0));
    await tester.pumpAndSettle();
    expect(find.text('1 / 2'), findsOneWidget);
    expect(closeCount, 0);
  });

  testWidgets('多图右滑不再关闭（避免翻页时误退）', (tester) async {
    await pumpPreview(tester, imagePaths: [imagePath, imagePath]);
    await tester.drag(find.byType(OverlayImagePreview), const Offset(140, 0));
    await tester.pumpAndSettle();
    expect(closeCount, 0);
  });

  testWidgets('不传归属参数时不渲染删除钮（主 App 日记页行为不变）', (tester) async {
    await pumpPreview(tester);
    expect(find.byIcon(Icons.delete_outline), findsNothing);
    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    expect(closeCount, 1);
  });

  testWidgets('本机截图页点删除钮进确认态，✓ 才真删且不误关预览', (tester) async {
    await pumpPreview(
      tester,
      ownImagePath: imagePath,
      onOwnImageDelete: () => deleteCount++,
    );
    expect(find.byIcon(Icons.delete_outline), findsOneWidget);

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pump();
    // 确认态整格替换：出现「确认删除？」，删除钮让位
    expect(find.text('确认删除？'), findsOneWidget);
    expect(find.byIcon(Icons.delete_outline), findsNothing);
    expect(deleteCount, 0);
    expect(closeCount, 0);

    final confirmRow = find.byKey(const Key('imageDeleteConfirm'));
    await tester.tap(
      find.descendant(of: confirmRow, matching: find.byIcon(Icons.check)),
    );
    await tester.pump();
    expect(deleteCount, 1);
    expect(closeCount, 0);
  });

  testWidgets('确认态点 ✗ 只退出确认，不删图', (tester) async {
    await pumpPreview(
      tester,
      ownImagePath: imagePath,
      onOwnImageDelete: () => deleteCount++,
    );
    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pump();
    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('imageDeleteConfirm')),
        matching: find.byIcon(Icons.close),
      ),
    );
    await tester.pump();
    expect(deleteCount, 0);
    expect(closeCount, 0);
    expect(find.text('确认删除？'), findsNothing);
    expect(find.byIcon(Icons.delete_outline), findsOneWidget);
  });

  testWidgets('翻页后确认态作废（确认的是上一页那张，不能带过去）', (tester) async {
    await pumpPreview(
      tester,
      imagePaths: [imagePath, otherImagePath],
      ownImagePath: imagePath,
      onOwnImageDelete: () => deleteCount++,
    );
    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pump();
    expect(find.text('确认删除？'), findsOneWidget);

    await tester.drag(find.byType(PageView), const Offset(-400, 0));
    await tester.pumpAndSettle();
    expect(find.text('2 / 2'), findsOneWidget);
    expect(find.text('确认删除？'), findsNothing);
    expect(deleteCount, 0);
    // 翻到电脑端那张后，删除钮回到「提示」语义
    expect(find.byIcon(Icons.delete_outline), findsOneWidget);
  });

  testWidgets('电脑端同步来的那张页上点删除只走提示回调', (tester) async {
    await pumpPreview(
      tester,
      imagePaths: [otherImagePath],
      ownImagePath: imagePath,
      onOwnImageDelete: () => deleteCount++,
      onForeignImageTap: () => foreignTapCount++,
    );
    // 图集里没有本机截图（路径不在列表内）→ 不给删除入口
    expect(find.byIcon(Icons.delete_outline), findsNothing);

    await pumpPreview(
      tester,
      imagePaths: [otherImagePath, imagePath],
      ownImagePath: imagePath,
      onOwnImageDelete: () => deleteCount++,
      onForeignImageTap: () => foreignTapCount++,
    );
    expect(find.byIcon(Icons.delete_outline), findsOneWidget);
    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pump();
    expect(foreignTapCount, 1);
    expect(deleteCount, 0);
    expect(find.text('确认删除？'), findsNothing);
    expect(closeCount, 0);
  });
}
