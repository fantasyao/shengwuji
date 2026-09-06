import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shengwuji_app/widgets/calendar_confirm_sheet.dart';

/// CalendarConfirmSheet 交互回归：悬浮窗闹钟的转轮确认弹层。
/// 验证确认/取消返回值、识别提示行、响铃开关及无通知权限时的禁用降级
///（转轮本体是 Cupertino 组件，滚动交互不在本测试范围——确认返回的是
/// onDateTimeChanged 回写前的预填/滚动值）
void main() {
  final initial = DateTime(2026, 9, 5, 20);

  // 闭包持有弹层返回值：showCalendarConfirmSheet 在点「确认/取消」后才返回，
  // holder 让测试在弹层打开 → 操作 → 收起后断言
  final holder = ObjectHolder<CalendarConfirmResult?>();

  Future<void> openSheet(
    WidgetTester tester, {
    String eventTitle = '提醒我去看电影',
    String? recognizedPhrase = '周六晚上八点',
    bool alarmAvailable = true,
  }) async {
    holder.value = null;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () async {
                  holder.value = await showCalendarConfirmSheet(
                    context,
                    eventTitle: eventTitle,
                    initialTime: initial,
                    recognizedPhrase: recognizedPhrase,
                    alarmAvailable: alarmAvailable,
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('弹层背景不透明（真机踩坑回归：transparent 背景在悬浮窗 engine 里下层文字全透出）',
      (tester) async {
    await openSheet(tester);
    // 弹层自身的 Material 以顶部圆角 16 的 shape 标识（对齐付款方式弹层同款）
    final sheetMaterial = tester
        .widgetList<Material>(
          find.byWidgetPredicate((w) {
            if (w is! Material) return false;
            final shape = w.shape;
            if (shape is! RoundedRectangleBorder) return false;
            final radius = shape.borderRadius;
            return radius is BorderRadius &&
                radius.topLeft == const Radius.circular(16);
          }),
        )
        .single;
    expect(sheetMaterial.color, isNotNull);
    expect(sheetMaterial.color!.a, 1.0);
  });

  testWidgets('确认：返回预填时间 + 响铃开（默认）', (tester) async {
    await openSheet(tester);
    await tester.tap(find.byKey(const ValueKey('calendar_confirm_ok')));
    await tester.pumpAndSettle();
    expect(holder.value, isNotNull);
    expect(holder.value!.time, initial);
    expect(holder.value!.enableAlarm, true);
  });

  testWidgets('取消：返回 null', (tester) async {
    await openSheet(tester);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(holder.value, isNull);
  });

  testWidgets('识别提示行展示原文短语 + 事件标题', (tester) async {
    await openSheet(tester);
    expect(find.text('识别到：周六晚上八点（可转轮调整）'), findsOneWidget);
    expect(find.text('提醒我去看电影'), findsOneWidget);
    expect(find.text('添加日历提醒'), findsOneWidget);
  });

  testWidgets('未识别到时间：无提示行（转轮仍预填默认时刻可改）', (tester) async {
    await openSheet(tester, recognizedPhrase: null);
    expect(find.textContaining('识别到'), findsNothing);
    expect(
      find.byKey(const ValueKey('calendar_confirm_picker')),
      findsOneWidget,
    );
  });

  testWidgets('响铃开关可切换：确认返回关', (tester) async {
    await openSheet(tester);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('calendar_confirm_ok')));
    await tester.pumpAndSettle();
    expect(holder.value!.enableAlarm, false);
  });

  testWidgets('无通知权限：响铃开关禁用置关 + 提示行，确认返回 enableAlarm=false',
      (tester) async {
    await openSheet(tester, alarmAvailable: false);
    expect(find.text('未授予通知权限，响铃不可用（仅日历事件）'), findsOneWidget);
    final switchFinder = find.byType(Switch);
    expect(tester.widget<Switch>(switchFinder).onChanged, isNull);
    // 禁用态点击不改变值
    await tester.tap(switchFinder);
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(switchFinder).value, false);
    await tester.tap(find.byKey(const ValueKey('calendar_confirm_ok')));
    await tester.pumpAndSettle();
    expect(holder.value!.enableAlarm, false);
    expect(holder.value!.time, initial);
  });
}

/// 测试用简易值容器（闭包跨 build 持有弹层返回值）
class ObjectHolder<T> {
  T? value;
}
