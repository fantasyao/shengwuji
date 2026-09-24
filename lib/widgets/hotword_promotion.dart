import 'package:flutter/material.dart';

import '../hotword/phoneme_corrector.dart';
import '../text_processor.dart';
import '../utils/correction_learner.dart';

/// 「一键修正」采纳后的追问：某修正对命中次数达 [阈值] 时，提议把它加入
/// 音素热词——修正对只在「一字不差」时提示，升级成热词后发音近似的写法
/// 也会自动替换（用户配置优先于学习结果，所以升级是单向增强）。
///
/// diary / 录入两条链路的「一键修正」onPressed 末尾各调用一次；
/// 采纳动作会让该对 hit_count+1，这里用采纳前计数 +1 预估最新次数。
Future<void> maybePromptHotwordPromotion(
  BuildContext context, {
  required List<CorrectionPair> matches,
  required TextProcessor processor,
}) async {
  if (matches.isEmpty) return;
  final best = matches.reduce((a, b) => a.hitCount >= b.hitCount ? a : b);
  final hitAfter = best.hitCount + 1;
  if (hitAfter < PhonemeHotwordConfig.promotionHitThreshold) return;
  // 删除型修正对（correct 为空 = 用户删掉口水词）没有可升级的目标词
  if (best.correct.isEmpty) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        '这个改法已出现 $hitAfter 次，加入热词后发音相似的写法也会自动替换',
      ),
      action: SnackBarAction(
        label: '加入热词',
        onPressed: () async {
          // await 前捕获 messenger：写热词后仍能用同一 ScaffoldMessenger 反馈，
          // 规避 use_build_context_synchronously
          final messenger = ScaffoldMessenger.of(context);
          final added =
              await processor.appendHotwordPair(best.correct, best.error);
          messenger.showSnackBar(
            SnackBar(
              content: Text(
                added
                    ? '✅ 已加入热词：「${best.correct} | ${best.error}」'
                    : '热词里已有这条，无需重复添加',
              ),
            ),
          );
        },
      ),
      persist: false, // ⚠️ Flutter 的 SnackBar 带 action 时 persist 默认 true=永不超时消失，必须显式关
      duration: const Duration(seconds: 6),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
  );
}
