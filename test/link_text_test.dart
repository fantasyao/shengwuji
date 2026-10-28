import 'package:flutter/material.dart' show TextDecoration, TextStyle;
import 'package:flutter_test/flutter_test.dart';
import 'package:shengwuji_app/utils/link_text.dart';

/// 正文链接识别（2026-10-27）：随手记/悬浮窗正文网址下划线 + 点击浏览器。
/// 识别规则直接决定用户在正文里看到哪些蓝色/白色下划线，边界用例都锁住。
void main() {
  List<String> urlsOf(String text) =>
      findTextLinks(text).map((l) => l.url).toList();

  group('findTextLinks 基础识别', () {
    test('http/https 链接按出现顺序返回，区间与原文对齐', () {
      const text = '早上看 https://a.com/x 和 http://b.cn/y?q=1&z=2 两个页面';
      final links = findTextLinks(text);
      expect(links.map((l) => l.url), [
        'https://a.com/x',
        'http://b.cn/y?q=1&z=2',
      ]);
      expect(text.substring(links[0].start, links[0].end), 'https://a.com/x');
      expect(
        text.substring(links[1].start, links[1].end),
        'http://b.cn/y?q=1&z=2',
      );
    });

    test('www. 前缀补 https://，原文范围保持 www 字面量', () {
      const text = '去 www.example.com/a 看看';
      final links = findTextLinks(text);
      expect(links, hasLength(1));
      expect(links.single.url, 'https://www.example.com/a');
      expect(links.single.raw, 'www.example.com/a');
    });

    test('大写 scheme 识别，URL 保留原文大小写', () {
      final links = findTextLinks('HTTPS://Example.COM/Path');
      expect(links, hasLength(1));
      expect(links.single.url, 'HTTPS://Example.COM/Path');
    });

    test('中文紧贴网址时只截到 ASCII 边界（不吞后面的中文）', () {
      const text = '看https://a.com/abc然后去吃饭';
      final links = findTextLinks(text);
      expect(links.single.raw, 'https://a.com/abc');
      expect(text.substring(links.single.end), '然后去吃饭');
    });

    test('句末英文标点不进入链接', () {
      final links = findTextLinks('见 https://a.com/x, 以及 https://b.com/y.');
      expect(links.map((l) => l.raw), ['https://a.com/x', 'https://b.com/y']);
    });

    test('中文标点/全角括号包裹时链接范围干净', () {
      const text = '（参考 https://a.com/x，还有「https://b.com/y」）';
      expect(urlsOf(text), ['https://a.com/x', 'https://b.com/y']);
    });

    test('成对括号属于 URL，仅去掉多余的外层右括号', () {
      final links = findTextLinks(
        '(见 https://en.wikipedia.org/wiki/Foo_(bar))',
      );
      expect(links.single.raw, 'https://en.wikipedia.org/wiki/Foo_(bar)');
    });

    test('query/fragment/百分号编码完整保留', () {
      const text = 'https://a.com/p?x=1&y=%E4%B8%AD#sec';
      expect(urlsOf(text), [text]);
    });
  });

  group('findTextLinks 不误判', () {
    test('裸域名、邮箱、普通英文不算链接', () {
      expect(
        findTextLinks('bilibili.com 和 a@b.com、u@www.example.com 以及 v1.2.3'),
        isEmpty,
      );
    });

    test('只有 scheme 没有主体不算链接', () {
      expect(findTextLinks('https:// 后面没东西'), isEmpty);
      expect(findTextLinks('www.'), isEmpty);
    });

    test('空文本返回空列表', () {
      expect(findTextLinks(''), isEmpty);
    });
  });

  group('buildLinkSpans', () {
    const linkStyle = TextStyle(decoration: TextDecoration.underline);

    test('无链接时退回单段普通文本', () {
      final spans = buildLinkSpans(
        text: '普通文本',
        linkStyle: linkStyle,
        onLinkTap: (_) {},
      );
      expect(spans, hasLength(1));
      expect(spans.single.text, '普通文本');
      expect(spans.single.recognizer, isNull);
    });

    test('未给回调时不渲染链接（不显示点不动的下划线）', () {
      final spans = buildLinkSpans(
        text: '看 https://a.com/x 吧',
        linkStyle: linkStyle,
        onLinkTap: null,
      );
      expect(spans, hasLength(1));
      expect(spans.single.text, '看 https://a.com/x 吧');
    });

    test('普通/链接交替切段，链接段带 recognizer 与样式', () {
      final spans = buildLinkSpans(
        text: '看 https://a.com/x 吧',
        linkStyle: linkStyle,
        onLinkTap: (_) {},
      );
      expect(spans.map((s) => s.text), ['看 ', 'https://a.com/x', ' 吧']);
      expect(spans[1].recognizer, isNotNull);
      expect(spans[1].style, linkStyle);
    });
  });

  test('combineUnderline 保留归档删除线', () {
    expect(combineUnderline(null), TextDecoration.underline);
    expect(
      combineUnderline(TextDecoration.lineThrough),
      TextDecoration.combine([
        TextDecoration.lineThrough,
        TextDecoration.underline,
      ]),
    );
  });
}
