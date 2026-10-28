import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shengwuji_app/utils/text_measure.dart';

/// textExceedsLines：日记卡片长文折叠判定的实测函数。
/// 关键契约：实测行数而非字符数估算（中英文混排/宽字符才准）；
/// textScaler 必须与渲染环境一致（系统大字体用户行数更多）。
void main() {
  const style = TextStyle(fontSize: 16, height: 1.5);
  // 16 号字中文约 16px 宽：200px 宽度一行约 12 字
  const width = 200.0;

  testWidgets('短文本（1 行）不超阈值', (tester) async {
    expect(
      textExceedsLines(
        text: '钥匙放在客厅',
        style: style,
        maxWidth: width,
        maxLines: 5,
      ),
      isFalse,
    );
  });

  testWidgets('空文本不超阈值', (tester) async {
    expect(
      textExceedsLines(text: '', style: style, maxWidth: width, maxLines: 5),
      isFalse,
    );
  });

  testWidgets('长文本换行超过 5 行 → 超阈值', (tester) async {
    // 约 120 字 ÷ 每行约 12 字 ≈ 10 行
    final longText = '今天去超市买了很多东西，' * 12;
    expect(
      textExceedsLines(
        text: longText,
        style: style,
        maxWidth: width,
        maxLines: 5,
      ),
      isTrue,
    );
  });

  testWidgets('恰好 5 行以内不折叠（边界）', (tester) async {
    // 4 行文本（每行末尾显式换行，不受宽度估算误差影响）
    final text = '第一行\n第二行\n第三行\n第四行';
    expect(
      textExceedsLines(
        text: text,
        style: style,
        maxWidth: width,
        maxLines: 5,
      ),
      isFalse,
    );
  });

  testWidgets('显式换行 6 行 → 超阈值', (tester) async {
    final text = '一\n二\n三\n四\n五\n六';
    expect(
      textExceedsLines(
        text: text,
        style: style,
        maxWidth: width,
        maxLines: 5,
      ),
      isTrue,
    );
  });

  testWidgets('textScaler 放大后同一文本行数变多（大字体用户不误判）', (tester) async {
    // 约 36 字：scaler 1.0 时每行 12 字 ≈ 3 行；scaler 2.0 时每行 6 字 ≈ 6 行
    final text = '今天去超市买了很多东西，' * 3;
    expect(
      textExceedsLines(
        text: text,
        style: style,
        maxWidth: width,
        maxLines: 5,
      ),
      isFalse,
    );
    expect(
      textExceedsLines(
        text: text,
        style: style,
        maxWidth: width,
        maxLines: 5,
        textScaler: const TextScaler.linear(2.0),
      ),
      isTrue,
    );
  });

  testWidgets('宽度足够宽时长文本也不超阈值（宽度参与实测）', (tester) async {
    final text = '今天去超市买了很多东西，' * 12;
    expect(
      textExceedsLines(
        text: text,
        style: style,
        maxWidth: 10000,
        maxLines: 5,
      ),
      isFalse,
    );
  });
}
