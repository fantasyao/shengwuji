import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shengwuji_app/utils/alarm_ringing_notifier.dart';

/// 闹钟响铃状态（性能审查 Top5 回归）：
/// 替代全局 2 秒 prefs 轮询后，响铃态只有两个入口——
/// ① 冷启动 restoreOnce 读原生写入的 SharedPreferences 标志；
/// ② 原生推送事件 onAlarmRinging / onAlarmStopped。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AlarmRingingNotifier', () {
    test('restoreOnce：冷启动标志为 true → 恢复响铃态（进程被杀期间闹钟触发过）',
        () async {
      SharedPreferences.setMockInitialValues({'is_alarm_ringing': true});
      final n = AlarmRingingNotifier();
      await n.restoreOnce();
      expect(n.ringing, isTrue);
      n.dispose();
    });

    test('restoreOnce：标志为 false/缺省 → 不响铃', () async {
      SharedPreferences.setMockInitialValues({'is_alarm_ringing': false});
      final n = AlarmRingingNotifier();
      await n.restoreOnce();
      expect(n.ringing, isFalse);
      n.dispose();
    });

    test('handleNativeEvent：onAlarmRinging 置响铃，重复推送幂等不发通知', () async {
      SharedPreferences.setMockInitialValues({});
      final n = AlarmRingingNotifier();
      var notifyCount = 0;
      n.addListener(() => notifyCount++);

      n.handleNativeEvent('onAlarmRinging');
      n.handleNativeEvent('onAlarmRinging');

      expect(n.ringing, isTrue);
      expect(notifyCount, 1);
      n.dispose();
    });

    test('handleNativeEvent：onAlarmStopped 收起；未知方法名忽略', () async {
      SharedPreferences.setMockInitialValues({});
      final n = AlarmRingingNotifier();
      n.handleNativeEvent('onAlarmRinging');
      n.handleNativeEvent('onShortcutLaunch'); // 同通道无关事件不误伤
      n.handleNativeEvent('onUnknown');
      expect(n.ringing, isTrue);

      var notifyCount = 0;
      n.addListener(() => notifyCount++);
      n.handleNativeEvent('onAlarmStopped');
      expect(n.ringing, isFalse);
      expect(notifyCount, 1);

      n.handleNativeEvent('onAlarmStopped'); // 同值幂等
      expect(notifyCount, 1);
      n.dispose();
    });

    test('markStopped：横幅按钮乐观收起，后续同值事件幂等', () async {
      SharedPreferences.setMockInitialValues({});
      final n = AlarmRingingNotifier();
      n.handleNativeEvent('onAlarmRinging');

      var notifyCount = 0;
      n.addListener(() => notifyCount++);
      n.markStopped();
      n.markStopped(); // 已停止再点停止：无变化不通知
      n.handleNativeEvent('onAlarmStopped'); // 原生回执同值幂等
      expect(n.ringing, isFalse);
      expect(notifyCount, 1);
      n.dispose();
    });
  });
}
