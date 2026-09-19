import 'package:flutter_test/flutter_test.dart';
import 'package:shengwuji_app/correction/context_corrector.dart';
import 'package:shengwuji_app/utils/correction_learner.dart';

/// 生产默认路径回归（f9e781e「注入参数须测默认路径」教训）：
/// ContextCorrector.ensureLoaded 负责把 jieba 注入 CorrectionLearner，
/// 这里验证不依赖任何手工注入时取词补全真实生效。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() => CorrectionLearner.wordSegmenter = null);

  test('ensureLoaded 注入 jieba 后，取词补全到完整词', () async {
    await ContextCorrector.instance.ensureLoaded();
    expect(
      CorrectionLearner.wordSegmenter,
      isNotNull,
      reason: 'jieba 初始化失败时取词会静默回退固定吸收，需检查词典 asset 与拷贝流程',
    );
    final pairs = CorrectionLearner.extract('管管雎鸠', '关关雎鸠');
    expect(
      pairs,
      contains(const CorrectionPair(error: '管管雎鸠', correct: '关关雎鸠')),
    );
    final tiZhi = CorrectionLearner.extract(
      '能把我的体直给降下去么',
      '能把我的体脂给降下去么',
    );
    expect(
      tiZhi,
      contains(const CorrectionPair(error: '体直', correct: '体脂')),
    );
  });
}
