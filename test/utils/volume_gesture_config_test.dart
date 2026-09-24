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

    test('新 key 值为 ptt_record（按住说话动作，实验分支）→ 合法值原样生效，不走推导', () async {
      // 旧 key 故意配成 off（推导会出 none），验证合法新值不被迁移覆盖——
      // ptt_record 只会由设置页写入，迁移推导永不产出它
      SharedPreferences.setMockInitialValues({
        'volume_key_mode': 'off',
        'volume_gesture_long_press_down': VolumeGestureAction.pttRecord,
      });
      final prefs = await SharedPreferences.getInstance();

      final result = await loadVolumeGestureActions(prefs);

      expect(
        result[VolumeGestureSlot.longPressDown],
        VolumeGestureAction.pttRecord,
      );
    });
  });

  // ============================================================
  // VolumeLongPressMs.normalize（长按阈值校验：预设档 + 自定义范围）
  // ============================================================
  group('VolumeLongPressMs.normalize 长按阈值校验', () {
    test('4 个预设档原样返回', () {
      for (final ms in VolumeLongPressMs.choices) {
        expect(VolumeLongPressMs.normalize(ms), ms);
      }
    });

    test('null（从未设置）→ 默认 400', () {
      expect(VolumeLongPressMs.normalize(null), VolumeLongPressMs.defaultMs);
      expect(VolumeLongPressMs.defaultMs, 400);
    });

    test('自定义档（范围内任意值，含边界）原样生效', () {
      // 2026-09-23 新增「自定义」档：合法域从预设集合放开为 [50, 2000]
      // 闭区间，Kotlin 侧 getLongPressDurationMs 同范围校验（跨端硬编码副本）
      expect(VolumeLongPressMs.minMs, 50);
      expect(VolumeLongPressMs.maxMs, 2000);
      expect(VolumeLongPressMs.normalize(50), 50); // 下边界
      expect(VolumeLongPressMs.normalize(2000), 2000); // 上边界
      expect(VolumeLongPressMs.normalize(150), 150); // 用户诉求：<200 的值
    });

    test('旧档位 500/800/1200 在范围内，升级后按原值继续生效', () {
      // 2026-09-21 版曾把「不在新预设集合内」一律回落 400（旧默认 500 就近
      // 迁移）；自定义档放开后范围取代集合成为合法域——旧档位都落在
      // [50,2000] 内，老用户升级后尊重其当年显式选的档位，不再二次改写
      expect(VolumeLongPressMs.normalize(500), 500);
      expect(VolumeLongPressMs.normalize(800), 800);
      expect(VolumeLongPressMs.normalize(1200), 1200);
    });

    test('越界/脏值 → 默认 400', () {
      expect(VolumeLongPressMs.normalize(0), VolumeLongPressMs.defaultMs);
      expect(VolumeLongPressMs.normalize(49), VolumeLongPressMs.defaultMs);
      expect(VolumeLongPressMs.normalize(-500), VolumeLongPressMs.defaultMs);
      expect(VolumeLongPressMs.normalize(2001), VolumeLongPressMs.defaultMs);
      expect(VolumeLongPressMs.normalize(9999), VolumeLongPressMs.defaultMs);
    });

    test('isCustom：不在预设集合内即为自定义档', () {
      for (final ms in VolumeLongPressMs.choices) {
        expect(VolumeLongPressMs.isCustom(ms), isFalse);
      }
      expect(VolumeLongPressMs.isCustom(150), isTrue);
      expect(VolumeLongPressMs.isCustom(500), isTrue);
    });
  });
}
