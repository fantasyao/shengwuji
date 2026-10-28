import 'package:flutter/gestures.dart' show TapGestureRecognizer;
import 'package:flutter/painting.dart' show TextDecoration, TextSpan, TextStyle;

/// 正文里可点击的 http(s) 链接（2026-10-27 用户要求：随手记/悬浮窗正文中的
/// 网址显示下划线，点击用系统浏览器打开）。
///
/// 只认 `http://`、`https://` 与 `www.` 前缀——裸域名（`bilibili.com`）不识别，
/// 避免把正文里的普通英文/版本号误判成链接。`www.` 会补 `https://` 后交给
/// 系统浏览器。
class TextLink {
  const TextLink({
    required this.start,
    required this.end,
    required this.raw,
    required this.url,
  });

  /// 在原文中的起止偏移（[end] 不含），调用方按它切段渲染
  final int start;
  final int end;

  /// 原文中的字面文本（下划线范围按它截取，不含尾部标点）
  final String raw;

  /// 规范化后的可打开 URL（`www.` 已补 `https://`）
  final String url;
}

/// URL 主体字符集：RFC 3986 的 unreserved + reserved 常用子集。
/// 刻意不含中文、空白、引号、`<>`、`|`——中文紧贴网址（`看https://a.com然后`）
/// 时能正确截断，尾部中文标点也不会被吞进链接
final RegExp _linkPattern = RegExp(
  r'(?<![A-Za-z0-9@])(https?://|www\.)[A-Za-z0-9\-._~:/?#\[\]@!$&()*+,;=%]+',
  caseSensitive: false,
);

/// 句末/包裹常见标点：链接后紧跟 `。`，`（见 https://a.com）` 时
/// 右括号不属于 URL
const String _trailingPunctuation = '.,;:!?\'"*`';

/// 链接扫描缓存：日记列表/悬浮窗面板每次 setState 都会重扫全部可见正文，
/// 同一段文本短时间反复扫描直接命中。上限 256 条，超出整体清空
///（正常会话到不了；只防极端长文本反复编辑的无界增长）
final Map<String, List<TextLink>> _kLinkCache = <String, List<TextLink>>{};
const int _kLinkCacheLimit = 256;

/// 扫描 [text] 中的 http(s)/www 链接，返回按出现顺序排列、互不重叠的区间。
List<TextLink> findTextLinks(String text) {
  if (text.isEmpty) return const <TextLink>[];
  final cached = _kLinkCache[text];
  if (cached != null) return cached;

  final links = <TextLink>[];
  for (final match in _linkPattern.allMatches(text)) {
    final prefix = match.group(1) ?? '';
    final raw = match.group(0) ?? '';
    final end = _trimTrailing(raw);
    // 只有 scheme / `www.` 没有主体：不是链接
    if (end <= prefix.length) continue;

    final literal = raw.substring(0, end);
    final normalized = literal.toLowerCase().startsWith('www.')
        ? 'https://$literal'
        : literal;
    final uri = Uri.tryParse(normalized);
    // hasAuthority 兜住 `https://` 这类半截输入；Uri 解析失败的脏串也不算链接
    if (uri == null || !uri.hasAuthority) continue;

    links.add(
      TextLink(
        start: match.start,
        end: match.start + end,
        raw: literal,
        url: normalized,
      ),
    );
  }

  if (_kLinkCache.length >= _kLinkCacheLimit) _kLinkCache.clear();
  _kLinkCache[text] = links;
  return links;
}

/// 收缩 [raw] 尾部：句末标点直接去掉；`)]}` 仅在配对失衡时去掉
///（保留 `https://en.wikipedia.org/wiki/Foo_(bar)` 这类合法右括号）
int _trimTrailing(String raw) {
  int end = raw.length;
  while (end > 0) {
    final ch = raw[end - 1];
    if (_trailingPunctuation.contains(ch)) {
      end--;
      continue;
    }
    if ((ch == ')' || ch == ']' || ch == '}') &&
        _countPairs(raw, end, ch) > 0) {
      end--;
      continue;
    }
    break;
  }
  return end;
}

/// 返回 [raw] 前 [end] 个字符中未配对的闭括号数量（>0 = 尾部这个闭括号多余）
int _countPairs(String raw, int end, String closer) {
  final opener = switch (closer) {
    ')' => '(',
    ']' => '[',
    _ => '{',
  };
  int balance = 0;
  for (int i = 0; i < end; i++) {
    if (raw[i] == opener) balance++;
    if (raw[i] == closer) balance--;
  }
  return -balance;
}

/// 把正文按链接切成普通/链接交替的 [TextSpan] 列表；无链接或 [onLinkTap]
/// 为 null 时退回单段普通文本（不显示可点击下划线，避免“像链接但点不动”）。
///
/// [plainStyle] 为 null 时普通段继承外层 TextSpan 样式（悬浮窗正文用法）；
/// [linkStyle] 由调用方给色值/下划线，不改变字宽与行高，测量代码无需同步。
List<TextSpan> buildLinkSpans({
  required String text,
  TextStyle? plainStyle,
  required TextStyle linkStyle,
  void Function(TextLink)? onLinkTap,
}) {
  final links = onLinkTap == null ? const <TextLink>[] : findTextLinks(text);
  if (links.isEmpty) {
    return <TextSpan>[TextSpan(text: text, style: plainStyle)];
  }

  final callback = onLinkTap!;
  final spans = <TextSpan>[];
  int lastEnd = 0;
  for (final link in links) {
    if (link.start > lastEnd) {
      spans.add(
        TextSpan(text: text.substring(lastEnd, link.start), style: plainStyle),
      );
    }
    final recognizer = TapGestureRecognizer()..onTap = () => callback(link);
    spans.add(
      TextSpan(
        text: text.substring(link.start, link.end),
        style: linkStyle,
        recognizer: recognizer,
      ),
    );
    lastEnd = link.end;
  }
  if (lastEnd < text.length) {
    spans.add(TextSpan(text: text.substring(lastEnd), style: plainStyle));
  }
  return spans;
}

/// 链接下划线叠加在既有装饰上（归档卡的删除线不能丢）
TextDecoration combineUnderline(TextDecoration? base) {
  if (base == null) return TextDecoration.underline;
  return TextDecoration.combine([base, TextDecoration.underline]);
}
