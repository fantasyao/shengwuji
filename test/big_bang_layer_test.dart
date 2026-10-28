import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shengwuji_app/overlay/big_bang_tokenizer.dart';
import 'package:shengwuji_app/overlay/overlay_constants.dart';
import 'package:shengwuji_app/overlay/widgets/big_bang_layer.dart';

void main() {
  // 词块序列：苹果(0) ，(1) 牛奶(2) ' '(3) bread(4)
  final tokens = BigBangTokenizer.fromRawTokens([
    '苹果',
    '，',
    '牛奶',
    ' ',
    'bread',
  ]);

  Future<
    ({
      List<String> copied,
      List<String> searched,
      List<String> haptics,
      List<bool> closed,
    })
  >
  pumpLayer(
    WidgetTester tester, {
    Future<bool> Function(String)? onCopy,
    Future<bool> Function(String)? onSearch,
  }) async {
    final copied = <String>[];
    final searched = <String>[];
    final haptics = <String>[];
    // List 作可变容器：记录闭包副作用（record 按值快照会吞掉后置变更）
    final closed = <bool>[false];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BigBangLayer(
            text: '苹果，牛奶 bread',
            initialTokens: tokens,
            onClose: () => closed[0] = true,
            onCopy:
                onCopy ??
                (text) async {
                  copied.add(text);
                  return true;
                },
            onSearch: onSearch == null
                ? null
                : (text) async {
                    searched.add(text);
                    return await onSearch(text);
                  },
            onHaptic: haptics.add,
          ),
        ),
      ),
    );
    // 首帧后的 postFrame 词块 Rect 缓存落地
    await tester.pump();
    return (
      copied: copied,
      searched: searched,
      haptics: haptics,
      closed: closed,
    );
  }

  testWidgets('点选词块 toggle：选中计数与震动', (tester) async {
    final r = await pumpLayer(tester);
    expect(find.text('已选 0 字'), findsOneWidget);

    await tester.tap(find.text('苹果'));
    await tester.pump();
    expect(find.text('已选 2 字'), findsOneWidget);
    expect(r.haptics, isNotEmpty);

    // 再点 = 取消
    await tester.tap(find.text('苹果').first);
    await tester.pump();
    expect(find.text('已选 0 字'), findsOneWidget);
  });

  testWidgets('标点词块不可选：点击不计入选择', (tester) async {
    await pumpLayer(tester);
    await tester.tap(find.text('，'));
    await tester.pump();
    expect(find.text('已选 0 字'), findsOneWidget);
  });

  testWidgets('全选/清空', (tester) async {
    await pumpLayer(tester);
    await tester.tap(find.text('全选'));
    await tester.pump();
    // 2 + 2 + 5 = 9 个可选字符
    expect(find.text('已选 9 字'), findsOneWidget);

    await tester.tap(find.text('清空'));
    await tester.pump();
    expect(find.text('已选 0 字'), findsOneWidget);
  });

  testWidgets('复制：无选择时不触发；有选择时传出拼接文本并关闭', (tester) async {
    final r = await pumpLayer(tester);
    await tester.tap(find.text('复制'));
    await tester.pump();
    expect(r.copied, isEmpty);
    expect(r.closed.first, isFalse);

    await tester.tap(find.text('苹果'));
    await tester.pump();
    await tester.tap(find.text('复制'));
    // _doCopy 的 await 链：settle 跑干净微任务与帧
    await tester.pumpAndSettle();
    expect(r.copied, ['苹果']);
    expect(r.closed.first, isTrue);
  });

  testWidgets('复制失败不关闭', (tester) async {
    final r = await pumpLayer(tester, onCopy: (_) async => false);
    await tester.tap(find.text('苹果'));
    await tester.pump();
    await tester.tap(find.text('复制'));
    await tester.pumpAndSettle();
    expect(r.closed.first, isFalse);
  });

  testWidgets('滑动连选：锚点到终点区间整体置选，标点空白原文带出', (tester) async {
    final r = await pumpLayer(tester);
    final start = tester.getCenter(find.text('苹果'));
    final end = tester.getCenter(find.text('bread'));
    final gesture = await tester.startGesture(start);
    // 先小幅移动（未超 slop，仍可能是点按，不进连选）
    await gesture.moveBy(const Offset(3, 0));
    await tester.pump();
    expect(find.text('已选 0 字'), findsOneWidget);
    // 继续移动到终点词块
    await gesture.moveTo(end);
    await tester.pump();
    expect(find.text('已选 9 字'), findsOneWidget);
    await gesture.up();
    await tester.pump();

    await tester.tap(find.text('复制'));
    await tester.pump();
    expect(r.copied, ['苹果，牛奶 bread']);
  });

  testWidgets('短按（未超 slop 松手）落回点选 toggle', (tester) async {
    await pumpLayer(tester);
    final center = tester.getCenter(find.text('牛奶'));
    final gesture = await tester.startGesture(center);
    await gesture.moveBy(const Offset(3, 0));
    await gesture.up();
    await tester.pump();
    expect(find.text('已选 2 字'), findsOneWidget);
  });

  testWidgets('两次滑选：第二轮追加不覆盖第一轮（真机反馈回归）', (tester) async {
    final r = await pumpLayer(tester);
    // 第一轮：开头 苹果 → 牛奶（区间含标点，已选 2+2=4 字）
    final g1 = await tester.startGesture(tester.getCenter(find.text('苹果')));
    await g1.moveTo(tester.getCenter(find.text('牛奶')));
    await tester.pump();
    expect(find.text('已选 4 字'), findsOneWidget);
    await g1.up();
    await tester.pump();
    // 第二轮：末尾 bread 上滑选追加
    final g2 = await tester.startGesture(tester.getCenter(find.text('bread')));
    await g2.moveBy(const Offset(30, 0));
    await tester.pump();
    // 第一轮的 4 字不丢，bread 5 字追加 = 9 字
    expect(find.text('已选 9 字'), findsOneWidget);
    await g2.up();
    await tester.pump();

    await tester.tap(find.text('复制'));
    await tester.pump();
    expect(r.copied, ['苹果，牛奶 bread']);
  });

  testWidgets('先点选再滑选：滑选追加到点选之上', (tester) async {
    await pumpLayer(tester);
    await tester.tap(find.text('bread'));
    await tester.pump();
    expect(find.text('已选 5 字'), findsOneWidget);
    // 在开头词块上滑选，bread 的点选不丢
    final g = await tester.startGesture(tester.getCenter(find.text('苹果')));
    await g.moveBy(const Offset(30, 0));
    await tester.pump();
    expect(find.text('已选 7 字'), findsOneWidget);
    await g.up();
  });

  group('滑动取消（原版大爆炸语义：在已选词块上滑动 = 取消）', () {
    testWidgets('在已选词块上滑过即取消选择', (tester) async {
      final r = await pumpLayer(tester);
      await tester.tap(find.text('全选'));
      await tester.pump();
      expect(find.text('已选 9 字'), findsOneWidget);

      // 锚点 苹果 已选中 → 取消轮：滑到 牛奶 把区间 0..2 的可选词剔除
      final g = await tester.startGesture(tester.getCenter(find.text('苹果')));
      await g.moveTo(tester.getCenter(find.text('牛奶')));
      await tester.pump();
      // 只剩 bread 5 字
      expect(find.text('已选 5 字'), findsOneWidget);
      await g.up();
      await tester.pump();

      // 取消后再复制，只传出剩下的 bread
      await tester.tap(find.text('复制'));
      await tester.pumpAndSettle();
      expect(r.copied, ['bread']);
    });

    testWidgets('取消轮拖回缩小区间可恢复（基线不动）', (tester) async {
      await pumpLayer(tester);
      await tester.tap(find.text('全选'));
      await tester.pump();
      expect(find.text('已选 9 字'), findsOneWidget);

      final g = await tester.startGesture(tester.getCenter(find.text('苹果')));
      // 划到 bread：整段剔除
      await g.moveTo(tester.getCenter(find.text('bread')));
      await tester.pump();
      expect(find.text('已选 0 字'), findsOneWidget);
      // 拖回 牛奶：区间缩到 0..2，bread 恢复（苹果/牛奶在区间内仍被剔除）
      await g.moveTo(tester.getCenter(find.text('牛奶')));
      await tester.pump();
      expect(find.text('已选 5 字'), findsOneWidget);
      // 拖回锚点：只剩锚点被剔除，牛奶/bread 恢复
      await g.moveTo(tester.getCenter(find.text('苹果')));
      await tester.pump();
      expect(find.text('已选 7 字'), findsOneWidget);
      await g.up();
    });

    testWidgets('追加轮经过已选词块不取消（模式只看锚点）', (tester) async {
      await pumpLayer(tester);
      await tester.tap(find.text('牛奶'));
      await tester.pump();
      expect(find.text('已选 2 字'), findsOneWidget);

      // 锚点 苹果 未选中 → 追加轮：区间覆盖已选的 牛奶，保持选中不剔除
      final g = await tester.startGesture(tester.getCenter(find.text('苹果')));
      await g.moveTo(tester.getCenter(find.text('bread')));
      await tester.pump();
      expect(find.text('已选 9 字'), findsOneWidget);
      await g.up();
    });

    testWidgets('取消后新一轮可重新追加（模式每轮独立判定）', (tester) async {
      await pumpLayer(tester);
      await tester.tap(find.text('全选'));
      await tester.pump();
      // 第一轮：取消 苹果/牛奶
      final g1 = await tester.startGesture(tester.getCenter(find.text('苹果')));
      await g1.moveTo(tester.getCenter(find.text('牛奶')));
      await tester.pump();
      expect(find.text('已选 5 字'), findsOneWidget);
      await g1.up();
      await tester.pump();
      // 第二轮：苹果 已未选中 → 追加轮，重新选回
      final g2 = await tester.startGesture(tester.getCenter(find.text('苹果')));
      await g2.moveBy(const Offset(30, 0));
      await tester.pump();
      expect(find.text('已选 7 字'), findsOneWidget);
      await g2.up();
    });
  });

  testWidgets('搜索：有选择时传出拼接文本，成功后关闭', (tester) async {
    final r = await pumpLayer(tester, onSearch: (_) async => true);
    // 搜索按钮已渲染
    expect(find.byIcon(Icons.search), findsOneWidget);
    // 无选择时禁用：点了不触发
    await tester.tap(find.byIcon(Icons.search));
    await tester.pumpAndSettle();
    expect(r.searched, isEmpty);
    expect(r.closed.first, isFalse);

    await tester.tap(find.text('苹果'));
    await tester.pump();
    await tester.tap(find.byIcon(Icons.search));
    await tester.pumpAndSettle();
    expect(r.searched, ['苹果']);
    expect(r.closed.first, isTrue);
  });

  testWidgets('搜索失败不关闭', (tester) async {
    final r = await pumpLayer(tester, onSearch: (_) async => false);
    await tester.tap(find.text('苹果'));
    await tester.pump();
    await tester.tap(find.byIcon(Icons.search));
    await tester.pumpAndSettle();
    expect(r.searched, ['苹果']);
    expect(r.closed.first, isFalse);
  });

  testWidgets('onSearch 为 null 时不渲染搜索按钮（旧行为不变）', (tester) async {
    await pumpLayer(tester);
    expect(find.byIcon(Icons.search), findsNothing);
    // 复制按钮仍在
    expect(find.text('复制'), findsOneWidget);
  });

  testWidgets('四角圆弧：白色主体按 bigBangCornerRadius 裁切', (tester) async {
    await pumpLayer(tester);
    final material = tester.widget<Material>(
      find.byWidgetPredicate(
        (w) =>
            w is Material &&
            w.borderRadius ==
                BorderRadius.circular(OverlayConstants.bigBangCornerRadius),
      ),
    );
    expect(
      material.borderRadius,
      BorderRadius.circular(OverlayConstants.bigBangCornerRadius),
    );
    expect(material.clipBehavior, Clip.antiAlias);
    // 常量数值钉死（防对账漂移）
    expect(OverlayConstants.bigBangCornerRadius, 20.0);
  });

  testWidgets('浅色配色：白色主体 + 顶部/底部/圆角缺口压暗遮罩 + 词块深字浅底', (
    tester,
  ) async {
    await pumpLayer(tester);
    // 主体 Material 用 bigBangBackground（白色），数值钉死
    expect(OverlayConstants.bigBangBackground, const Color(0xFAFFFFFF));
    final material = tester.widget<Material>(
      find.byWidgetPredicate(
        (w) =>
            w is Material &&
            w.borderRadius ==
                BorderRadius.circular(OverlayConstants.bigBangCornerRadius),
      ),
    );
    expect(material.color, OverlayConstants.bigBangBackground);
    // 压暗遮罩：顶部留白 + 圆角缺口层 + 底部关闭条共 3 处
    expect(
      find.byWidgetPredicate(
        (w) => w is Container && w.color == OverlayConstants.bigBangScrimColor,
      ),
      findsNWidgets(3),
    );
    // 未选中词块：深字（black87）浅底（black 5%）
    final tokenText = tester.widget<Text>(find.text('牛奶'));
    expect(tokenText.style?.color, Colors.black87);
  });

  testWidgets('深色配色：isDark=true 主体换深色底 + 词块浅字深底', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BigBangLayer(
            text: '苹果，牛奶 bread',
            initialTokens: tokens,
            isDark: true,
            onClose: () {},
            onCopy: (_) async => true,
          ),
        ),
      ),
    );
    await tester.pump();
    // 主体 Material 用 bigBangBackgroundDark（深色），数值钉死
    expect(OverlayConstants.bigBangBackgroundDark, const Color(0xFA101319));
    final material = tester.widget<Material>(
      find.byWidgetPredicate(
        (w) =>
            w is Material &&
            w.borderRadius ==
                BorderRadius.circular(OverlayConstants.bigBangCornerRadius),
      ),
    );
    expect(material.color, OverlayConstants.bigBangBackgroundDark);
    // 压暗遮罩深浅共用（35% 黑），仍 3 处
    expect(
      find.byWidgetPredicate(
        (w) => w is Container && w.color == OverlayConstants.bigBangScrimColor,
      ),
      findsNWidgets(3),
    );
    // 未选中词块：浅字（white 87%）深底（white 7%）
    final tokenText = tester.widget<Text>(find.text('牛奶'));
    expect(tokenText.style?.color, Colors.white.withValues(alpha: 0.87));
  });

  testWidgets('isDark 缺省跟随 Theme brightness（主 App 路由路径）', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: Brightness.dark),
        home: Scaffold(
          body: BigBangLayer(
            text: '苹果，牛奶 bread',
            initialTokens: tokens,
            onClose: () {},
            onCopy: (_) async => true,
          ),
        ),
      ),
    );
    await tester.pump();
    final material = tester.widget<Material>(
      find.byWidgetPredicate(
        (w) =>
            w is Material &&
            w.borderRadius ==
                BorderRadius.circular(OverlayConstants.bigBangCornerRadius),
      ),
    );
    // 不传 isDark 时随 Theme 深色 → 深色底；浅色主题（既有测试）→ 白底
    expect(material.color, OverlayConstants.bigBangBackgroundDark);
  });

  testWidgets('topInset：顶部留白高度生效，层内容整体下移', (tester) async {
    // 默认 = 面板状态栏避让（40，与 _buildHeader 同源常量）
    await pumpLayer(tester);
    final defaultTop = tester.getTopLeft(find.text('大爆炸')).dy;
    expect(defaultTop, greaterThanOrEqualTo(40));
    expect(defaultTop, lessThan(40 + 40)); // 顶栏自身高度内

    // 自定义 topInset（如叠加面板高度档下压偏移 224 → 264）
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BigBangLayer(
            text: '苹果，牛奶 bread',
            initialTokens: tokens,
            topInset: 264,
            onClose: () {},
            onCopy: (_) async => true,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.getTopLeft(find.text('大爆炸')).dy, greaterThanOrEqualTo(264));
  });

  testWidgets('词块内容纵向居中：短内容居中于词块区而非贴顶', (tester) async {
    await pumpLayer(tester);
    // 词块区 = 顶栏与底栏之间的 SingleChildScrollView 视口（上下 padding
    // 12/12 对称，内容区中心 == 视口中心）
    final areaRect = tester.getRect(find.byType(SingleChildScrollView));
    final tokenCenter = tester.getCenter(find.text('苹果'));
    expect(
      (tokenCenter.dy - areaRect.center.dy).abs(),
      lessThan(30),
      reason: '短内容应纵向居中于词块区（贴顶时 dy 会远小于视口中心）',
    );
  });

  group('底部透明关闭条', () {
    testWidgets('点击条带任意位置（非按钮区）关闭', (tester) async {
      final r = await pumpLayer(tester);
      // 条带 = 屏幕底部 48dp（默认 800×600 视口下中心 y=576），避开中间
      // ✕ 按钮（x≈400）点左侧空白区——验证整条可点而非只有按钮可点
      await tester.tapAt(const Offset(100, 576));
      await tester.pump();
      expect(r.closed.first, isTrue);
    });

    testWidgets('点击条带中间 ✕ 按钮关闭', (tester) async {
      final r = await pumpLayer(tester);
      // 顶栏与底部条各一枚 close 图标，底部条那枚是最后一个
      await tester.tap(find.byIcon(Icons.close).last);
      await tester.pump();
      expect(r.closed.first, isTrue);
    });
  });

  group('二次爆炸（底栏刀按钮）', () {
    testWidgets('刀按钮渲染；无选中禁用：tokens 不变、无震动', (tester) async {
      final r = await pumpLayer(tester);
      expect(find.byIcon(Icons.content_cut), findsOneWidget);
      await tester.tap(find.byIcon(Icons.content_cut));
      await tester.pump();
      expect(r.haptics, isEmpty);
      expect(find.text('苹果'), findsOneWidget);
      expect(find.text('bread'), findsOneWidget);
      expect(find.text('已选 0 字'), findsOneWidget);
    });

    testWidgets('选中词炸成单字且保持选中；未选中词不动；复制传出原词文本', (tester) async {
      final r = await pumpLayer(tester);
      await tester.tap(find.text('苹果'));
      await tester.pump();
      expect(find.text('已选 2 字'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.content_cut));
      await tester.pump();
      // 「苹果」→ 苹/果 两个单字词块均选中（单字只出现在词块区，
      // 底栏预览是完整「苹果」不撞 find.text 精确匹配）。
      // 注：不断言震动次数——_tick 有 40ms 节流，测试内两次 tap 间隔
      // 远小于 40ms 会被节流吞掉，计数断言依赖真实时钟不稳定
      expect(find.text('苹'), findsOneWidget);
      expect(find.text('果'), findsOneWidget);
      expect(find.text('已选 2 字'), findsOneWidget);
      // 未选中的词块原样不动
      expect(find.text('牛奶'), findsOneWidget);
      expect(find.text('bread'), findsOneWidget);

      // 选中跟随的直接收益：爆炸后立即复制传出 == 原词文本
      await tester.tap(find.text('复制'));
      await tester.pumpAndSettle();
      expect(r.copied, ['苹果']);
      expect(r.closed.first, isTrue);
    });

    testWidgets('英文逐字母：bread 炸成 5 个单字，复制得 bread', (tester) async {
      final r = await pumpLayer(tester);
      await tester.tap(find.text('bread'));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.content_cut));
      await tester.pump();
      expect(find.text('b'), findsOneWidget);
      expect(find.text('d'), findsOneWidget);
      expect(find.text('已选 5 字'), findsOneWidget);

      await tester.tap(find.text('复制'));
      await tester.pumpAndSettle();
      expect(r.copied, ['bread']);
    });

    testWidgets('幂等：选中全是单字时刀按钮禁用', (tester) async {
      final r = await pumpLayer(tester);
      await tester.tap(find.text('苹果'));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.content_cut));
      await tester.pump();
      expect(find.text('已选 2 字'), findsOneWidget);

      final hapticsBefore = r.haptics.length;
      await tester.tap(find.byIcon(Icons.content_cut));
      await tester.pump();
      // 已炸成单字：无可再炸，不动、不震
      expect(r.haptics.length, hapticsBefore);
      expect(find.text('已选 2 字'), findsOneWidget);
      expect(find.text('苹'), findsOneWidget);
    });

    testWidgets('爆炸后逐字微调：点掉多余单字再搜索', (tester) async {
      final r = await pumpLayer(tester, onSearch: (_) async => true);
      await tester.tap(find.text('苹果'));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.content_cut));
      await tester.pump();
      // 点掉「苹」只留「果」
      await tester.tap(find.text('苹'));
      await tester.pump();
      expect(find.text('已选 1 字'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.search));
      await tester.pumpAndSettle();
      expect(r.searched, ['果']);
    });

    testWidgets('爆炸不破坏拼接==原文：爆炸后全选复制得完整原文', (tester) async {
      final r = await pumpLayer(tester);
      await tester.tap(find.text('苹果'));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.content_cut));
      await tester.pump();

      await tester.tap(find.text('全选'));
      await tester.pump();
      expect(find.text('已选 9 字'), findsOneWidget);
      await tester.tap(find.text('复制'));
      await tester.pumpAndSettle();
      expect(r.copied, ['苹果，牛奶 bread']);
    });

    testWidgets('emoji 词爆炸不劈代理对（UTF-16 安全）', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BigBangLayer(
              text: '赞😀赞',
              initialTokens: BigBangTokenizer.fromRawTokens(['赞😀赞']),
              onClose: () {},
              onCopy: (_) async => true,
              onHaptic: (_) {},
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.text('赞😀赞'));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.content_cut));
      await tester.pump();
      // 赞/😀/赞 三个 token：😀 整体一个不可选 token 保留，两个「赞」均选中
      expect(find.text('😀'), findsOneWidget);
      expect(find.text('赞'), findsNWidgets(2));
      expect(find.text('已选 2 字'), findsOneWidget);
    });

    testWidgets('爆炸后滑选命中新单字词块（Rect 缓存随 index 漂移重建）', (tester) async {
      await pumpLayer(tester);
      await tester.tap(find.text('苹果'));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.content_cut));
      await tester.pump();
      // 清空后在新词块上滑选——命中测试走重建后的 Rect 缓存
      await tester.tap(find.text('清空'));
      await tester.pump();
      final g = await tester.startGesture(tester.getCenter(find.text('苹')));
      await g.moveTo(tester.getCenter(find.text('果')));
      await tester.pump();
      expect(find.text('已选 2 字'), findsOneWidget);
      await g.up();
    });
  });
}
