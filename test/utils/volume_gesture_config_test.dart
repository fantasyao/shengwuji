import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shengwuji_app/utils/volume_gesture_config.dart';

void main() {
  // ============================================================
  // migrateVolumeGestures 纯函数推导
  // ============================================================
  group('migrateVolumeGestures 旧配置迁移推导', () {
    test('全 null（全新安装）→ 出厂默认：下长按速记、下双击文本笔记、上键两槽关闭', () {
      final result = migrateVolumeGestures();

      expect(result[VolumeGestureSlot.longPressUp], VolumeGestureAction.none);
      expect(
        result[VolumeGestureSlot.longPressDown],
        VolumeGestureAction.quickRecord,
      );
      expect(result[VolumeGestureSlot.doubleClickUp], VolumeGestureAction.none);
      expect(
        result[VolumeGestureSlot.doubleClickDown],
        VolumeGestureAction.quickTextNote,
      );
    });

    test("volumeKeyMode='both'（双击默认开）→ 4 槽全开", () {
      final result = migrateVolumeGestures(volumeKeyMode: 'both');

      expect(
        result[VolumeGestureSlot.longPressUp],
        VolumeGestureAction.quickRecord,
      );
      expect(
        result[VolumeGestureSlot.longPressDown],
        VolumeGestureAction.quickRecord,
      );
      expect(
        result[VolumeGestureSlot.doubleClickUp],
        VolumeGestureAction.quickTextNote,
      );
      expect(
        result[VolumeGestureSlot.doubleClickDown],
        VolumeGestureAction.quickTextNote,
      );
    });

    test("volumeKeyMode='off' → 全部槽位 none", () {
      final result = migrateVolumeGestures(volumeKeyMode: 'off');

      expect(result[VolumeGestureSlot.longPressUp], VolumeGestureAction.none);
      expect(result[VolumeGestureSlot.longPressDown], VolumeGestureAction.none);
      expect(result[VolumeGestureSlot.doubleClickUp], VolumeGestureAction.none);
      expect(
        result[VolumeGestureSlot.doubleClickDown],
        VolumeGestureAction.none,
      );
    });

    test(
      "overlay 开 + action='record' → longPressUp=overlayRecord（mode='up' 时仍覆盖）",
      () {
        // mode 缺省（down）：overlay 开即让渡上键
        final r1 = migrateVolumeGestures(
          overlayVolumeUpLongPress: true,
          overlayVolumeUpAction: 'record',
        );
        expect(
          r1[VolumeGestureSlot.longPressUp],
          VolumeGestureAction.overlayRecord,
        );

        // overlay 优先级覆盖 mode：即使 mode 含 up 也不推 quickRecord
        final r2 = migrateVolumeGestures(
          volumeKeyMode: 'up',
          overlayVolumeUpLongPress: true,
          overlayVolumeUpAction: 'record',
        );
        expect(
          r2[VolumeGestureSlot.longPressUp],
          VolumeGestureAction.overlayRecord,
        );
      },
    );

    test("overlay 开 + action 为 null 或 'show' → longPressUp=showOverlay", () {
      // action null → 旧版默认 'show'
      final r1 = migrateVolumeGestures(overlayVolumeUpLongPress: true);
      expect(
        r1[VolumeGestureSlot.longPressUp],
        VolumeGestureAction.showOverlay,
      );

      final r2 = migrateVolumeGestures(
        overlayVolumeUpLongPress: true,
        overlayVolumeUpAction: 'show',
      );
      expect(
        r2[VolumeGestureSlot.longPressUp],
        VolumeGestureAction.showOverlay,
      );
    });

    test("volumeKeyMode='up' + 双击开关关 → doubleClickUp=none（长按不受影响）", () {
      final result = migrateVolumeGestures(
        volumeKeyMode: 'up',
        doubleClickTextNote: false,
      );
      expect(result[VolumeGestureSlot.doubleClickUp], VolumeGestureAction.none);
      // 上键长按不受双击开关影响
      expect(
        result[VolumeGestureSlot.longPressUp],
        VolumeGestureAction.quickRecord,
      );
    });

    test("volumeKeyMode='down' + 双击开关开 → doubleClickUp=none（mode 不含 up）", () {
      final result = migrateVolumeGestures(
        volumeKeyMode: 'down',
        doubleClickTextNote: true,
      );
      expect(result[VolumeGestureSlot.doubleClickUp], VolumeGestureAction.none);
      expect(
        result[VolumeGestureSlot.doubleClickDown],
        VolumeGestureAction.quickTextNote,
      );
    });
  });

  // ============================================================
  // loadVolumeGestureActions（带 SharedPreferences mock）
  // ============================================================
  group('loadVolumeGestureActions', () {
    setUp(() {
      // shared_preferences 包自带的 mock，每个用例重置初始值
      SharedPreferences.setMockInitialValues({});
    });

    test('4 个新 key 全部已写入合法值 → 直接返回新值，不走推导', () async {
      // 旧 key 故意配成会让推导结果完全不同的值（off → 全 none）
      SharedPreferences.setMockInitialValues({
        'volume_key_mode': 'off',
        'volume_gesture_long_press_up': VolumeGestureAction.overlayRecord,
        'volume_gesture_long_press_down': VolumeGestureAction.none,
        'volume_gesture_double_click_up': VolumeGestureAction.showOverlay,
        'volume_gesture_double_click_down': VolumeGestureAction.quickTextNote,
      });
      final prefs = await SharedPreferences.getInstance();

      final result = await loadVolumeGestureActions(prefs);

      // 新 key 原样生效，没有被旧 key（off → 全 none）推导覆盖
      expect(
        result[VolumeGestureSlot.longPressUp],
        VolumeGestureAction.overlayRecord,
      );
      expect(result[VolumeGestureSlot.longPressDown], VolumeGestureAction.none);
      expect(
        result[VolumeGestureSlot.doubleClickUp],
        VolumeGestureAction.showOverlay,
      );
      expect(
        result[VolumeGestureSlot.doubleClickDown],
        VolumeGestureAction.quickTextNote,
      );
    });

    test('新 key 全部缺失 → 从旧 key 推导补齐，且不写回 prefs', () async {
      SharedPreferences.setMockInitialValues({'volume_key_mode': 'both'});
      final prefs = await SharedPreferences.getInstance();

      final result = await loadVolumeGestureActions(prefs);

      // 4 槽全按 both 推导
      expect(
        result[VolumeGestureSlot.longPressUp],
        VolumeGestureAction.quickRecord,
      );
      expect(
        result[VolumeGestureSlot.longPressDown],
        VolumeGestureAction.quickRecord,
      );
      expect(
        result[VolumeGestureSlot.doubleClickUp],
        VolumeGestureAction.quickTextNote,
      );
      expect(
        result[VolumeGestureSlot.doubleClickDown],
        VolumeGestureAction.quickTextNote,
      );
      // 不写回：新 key 在 prefs 里仍然不存在
      for (final slot in VolumeGestureSlot.all) {
        expect(prefs.containsKey(slot), isFalse);
      }
    });

    test('部分新 key 已写入 → 已写的保留，缺失的槽位推导补齐', () async {
      SharedPreferences.setMockInitialValues({
        'volume_key_mode': 'down',
        'volume_gesture_long_press_up': VolumeGestureAction.showOverlay,
      });
      final prefs = await SharedPreferences.getInstance();

      final result = await loadVolumeGestureActions(prefs);

      // 已写的新 key 原样保留（未按 mode='down' 推成 none）
      expect(
        result[VolumeGestureSlot.longPressUp],
        VolumeGestureAction.showOverlay,
      );
      // 缺失的槽位走推导（down → 长按下键速记 + 双击下键文本笔记，上键双击 none）
      expect(
        result[VolumeGestureSlot.longPressDown],
        VolumeGestureAction.quickRecord,
      );
      expect(result[VolumeGestureSlot.doubleClickUp], VolumeGestureAction.none);
      expect(
        result[VolumeGestureSlot.doubleClickDown],
        VolumeGestureAction.quickTextNote,
      );
    });

    test("新 key 存了非法值（'foo'）→ 该槽位回退推导", () async {
      SharedPreferences.setMockInitialValues({
        'overlay_volume_up_long_press': true,
        'volume_gesture_long_press_up': 'foo', // 非法动作值
      });
      final prefs = await SharedPreferences.getInstance();

      final result = await loadVolumeGestureActions(prefs);

      // 非法值不生效，回退到旧 key 推导：overlay 开 + action 缺省 → showOverlay
      expect(
        result[VolumeGestureSlot.longPressUp],
        VolumeGestureAction.showOverlay,
      );
      // 其余槽位也走推导默认（mode 缺省 down）
      expect(
        result[VolumeGestureSlot.longPressDown],
        VolumeGestureAction.quickRecord,
      );
    });

    test('新 key 值为 overlay_new_note（悬浮窗新增笔记动作）→ 合法值原样生效，不走推导', () async {
      // 旧 key 故意配成 off（推导会出 none），验证合法新值不被迁移覆盖
      SharedPreferences.setMockInitialValues({
        'volume_key_mode': 'off',
        'volume_gesture_long_press_down': VolumeGestureAction.overlayNewNote,
      });
      final prefs = await SharedPreferences.getInstance();

      final result = await loadVolumeGestureActions(prefs);

      expect(
        result[VolumeGestureSlot.longPressDown],
        VolumeGestureAction.overlayNewNote,
      );
    });
  });
}
