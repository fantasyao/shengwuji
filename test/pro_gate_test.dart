import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shengwuji_app/utils/pro_gate.dart';

/// ProGate 试用窗口判定回归：
/// 永久解锁（is_pro_unlocked + pro_license_code 双要素）与 7 天试用
/// （pro_trial_deadline_ms）任一满足即可用；
/// ⚠️ 裸 is_pro_unlocked=true（旧版君子协定遗留，无码记录）不算解锁——
/// 存量免费解锁用户升级即失效（2026-09-19 拍板）；
/// 试用一次性（过期后 startTrial 不重置）；时间判定纯函数支持注入 nowMs 单测，
/// 默认路径（不传 nowMs 走真实时钟）同样覆盖——防注入参数引入后默认路径漏测。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  final now = DateTime.parse('2026-09-19 12:00:00').millisecondsSinceEpoch;

  // 授权码体系下的完整永久解锁态（双要素）
  const licensed = {
    'is_pro_unlocked': true,
    'pro_license_code': 'SXQBXPE5ILKVXU6U',
  };

  Future<SharedPreferences> loadPrefs(Map<String, Object> values) async {
    SharedPreferences.setMockInitialValues(values);
    return SharedPreferences.getInstance();
  }

  group('isProActiveWithPrefs（注入时钟）', () {
    test('未解锁未试用：不可用', () async {
      final prefs = await loadPrefs({});
      expect(ProGate.isProActiveWithPrefs(prefs, nowMs: now), isFalse);
    });

    test('试用中（deadline 在未来）：可用', () async {
      final prefs = await loadPrefs({'pro_trial_deadline_ms': now + 1000});
      expect(ProGate.isProActiveWithPrefs(prefs, nowMs: now), isTrue);
    });

    test('恰好到期边界（now == deadline）：不可用', () async {
      final prefs = await loadPrefs({'pro_trial_deadline_ms': now});
      expect(ProGate.isProActiveWithPrefs(prefs, nowMs: now), isFalse);
    });

    test('试用已过期：不可用', () async {
      final prefs = await loadPrefs({'pro_trial_deadline_ms': now - 1});
      expect(ProGate.isProActiveWithPrefs(prefs, nowMs: now), isFalse);
    });

    test('永久解锁（布尔+码记录双要素）：即使无试用记录也可用', () async {
      final prefs = await loadPrefs(licensed);
      expect(ProGate.isProActiveWithPrefs(prefs, nowMs: now), isTrue);
    });

    test('永久解锁：试用过期后仍可用', () async {
      final prefs = await loadPrefs({
        ...licensed,
        'pro_trial_deadline_ms': now - 999999,
      });
      expect(ProGate.isProActiveWithPrefs(prefs, nowMs: now), isTrue);
    });

    test('存量君子协定用户（裸 is_pro_unlocked=true 无码记录）：不可用', () async {
      final prefs = await loadPrefs({'is_pro_unlocked': true});
      expect(ProGate.isProActiveWithPrefs(prefs, nowMs: now), isFalse);
      expect(await ProGate.isUnlocked(), isFalse);
    });

    test('仅有码记录缺解锁布尔（异常态）：不可用（双要素缺一不可）', () async {
      final prefs = await loadPrefs({'pro_license_code': 'SXQBXPE5ILKVXU6U'});
      expect(ProGate.isProActiveWithPrefs(prefs, nowMs: now), isFalse);
    });
  });

  group('默认路径（不传 nowMs，真实时钟）', () {
    test('deadline 在 1 小时后：isProActive 为 true', () async {
      final prefs = await loadPrefs({
        'pro_trial_deadline_ms':
            DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch,
      });
      expect(ProGate.isProActiveWithPrefs(prefs), isTrue);
      expect(await ProGate.isProActive(), isTrue);
    });

    test('deadline 在 1 小时前：isProActive 为 false', () async {
      final past = DateTime.now()
          .subtract(const Duration(hours: 1))
          .millisecondsSinceEpoch;
      final prefs = await loadPrefs({'pro_trial_deadline_ms': past});
      expect(ProGate.isProActiveWithPrefs(prefs), isFalse);
      expect(await ProGate.isProActive(), isFalse);
    });
  });

  group('remainingTrialDaysWithPrefs', () {
    test('未开试用：0', () async {
      final prefs = await loadPrefs({});
      expect(ProGate.remainingTrialDaysWithPrefs(prefs, nowMs: now), 0);
    });

    test('剩 3.5 天：向上取整为 4', () async {
      final ms = (3.5 * Duration.millisecondsPerDay).round();
      final prefs = await loadPrefs({'pro_trial_deadline_ms': now + ms});
      expect(ProGate.remainingTrialDaysWithPrefs(prefs, nowMs: now), 4);
    });

    test('已过期：0', () async {
      final prefs = await loadPrefs({'pro_trial_deadline_ms': now - 100});
      expect(ProGate.remainingTrialDaysWithPrefs(prefs, nowMs: now), 0);
    });
  });

  group('startTrial（一次性）', () {
    test('首次开启：成功且 deadline ≈ now + 7 天', () async {
      SharedPreferences.setMockInitialValues({});
      final before = DateTime.now();
      expect(await ProGate.startTrial(), isTrue);
      final prefs = await SharedPreferences.getInstance();
      final deadline = prefs.getInt(ProGate.kKeyTrialDeadlineMs)!;
      final lower = before.add(ProGate.trialDuration).millisecondsSinceEpoch;
      final upper =
          DateTime.now().add(ProGate.trialDuration).millisecondsSinceEpoch;
      expect(deadline, inInclusiveRange(lower, upper));
    });

    test('已开过试用（未过期）：不重置', () async {
      var prefs = await loadPrefs({'pro_trial_deadline_ms': now + 1000});
      final original = prefs.getInt(ProGate.kKeyTrialDeadlineMs);
      expect(await ProGate.startTrial(), isFalse);
      prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(ProGate.kKeyTrialDeadlineMs), original);
    });

    test('试用已过期：同样不可重开（一次性）', () async {
      await loadPrefs({'pro_trial_deadline_ms': now - 999999});
      expect(await ProGate.startTrial(), isFalse);
    });

    test('永久解锁用户：startTrial 仍按自身逻辑（未开过则可开，互不干扰）', () async {
      await loadPrefs(licensed);
      // 永久解锁不受试用影响；startTrial 只看试用 key 自身
      expect(await ProGate.startTrial(), isTrue);
    });

    test('isUnlocked 组合判定：双要素齐才为 true（默认路径真实读取）', () async {
      await loadPrefs({'is_pro_unlocked': true});
      expect(await ProGate.isUnlocked(), isFalse);
      await loadPrefs(licensed);
      expect(await ProGate.isUnlocked(), isTrue);
    });
  });
}
