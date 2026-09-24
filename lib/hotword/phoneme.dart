/// 音素热词 · 文本→音素序列转换。
///
/// 移植自 CapsWriter-Offline `core/client/hotword/algo_phoneme.py`
/// （Python 侧用 pypinyin，本侧用同源数据字典 assets/pinyin_dict.txt，
/// 见 tools/pinyin/gen_pinyin_dict.py），行为约定保持一致：
/// - 中文每字 → [声母?, 韵母, 声调0-5]，轻声记 5，多音字取 pypinyin 默认读音
/// - 英文按驼峰/字母数字边界拆 token 后逐字母拆分（ascii_split_char=True）
/// - 数字整段一个音素，标点/空格跳过但保留原文字符区间映射
library;

import 'package:flutter/services.dart' show rootBundle;

import '../app_logger.dart';

/// 带语言属性的音素。
class Phoneme {
  const Phoneme(
    this.value,
    this.lang, {
    this.isWordStart = false,
    this.isWordEnd = false,
    this.isTone = false,
    this.charStart = 0,
    this.charEnd = 0,
  });

  /// 音素值（如 'b'、'ing'、'4'（声调）、'h'（英文字母））
  final String value;

  /// 语言类型：'zh' 中文 / 'en' 英文 / 'num' 数字
  final String lang;

  /// 是否字（音节）边界起点：声母或零声母韵母
  final bool isWordStart;

  /// 是否字（音节）边界终点：声调
  final bool isWordEnd;

  /// 是否声调音素（CapsWriter is_tone：值为纯数字）
  final bool isTone;

  final int charStart;
  final int charEnd;

  @override
  String toString() =>
      'Phoneme($value,$lang,s=$isWordStart,e=$isWordEnd[$charStart,$charEnd))';
}

/// 汉字→tone3 拼音字典（进程级缓存：多个 TextProcessor 实例共享，只解析一次）。
class PinyinDict {
  PinyinDict._(this._map);

  static PinyinDict? _instance;
  static Future<PinyinDict>? _loading;

  final Map<String, String> _map;

  static PinyinDict get instance =>
      _instance ?? (throw StateError('PinyinDict 未加载，先 await ensureLoaded()'));

  /// 幂等加载；失败抛异常由调用方决定降级（音素层停用，字面替换不受影响）
  static Future<PinyinDict> ensureLoaded() {
    if (_instance != null) return Future.value(_instance);
    return _loading ??= rootBundle
        .loadString('assets/pinyin_dict.txt')
        .then((content) {
          final map = <String, String>{};
          for (final line in content.split('\n')) {
            final l = line.trim(); // 防 \r\n / 尾空白（行尾 \r 会毁掉 tone 校验）
            final eq = l.indexOf('=');
            if (eq <= 0) continue;
            map[l.substring(0, eq)] = l.substring(eq + 1);
          }
          log('音素热词: 拼音字典已加载 ${map.length} 字');
          return _instance = PinyinDict._(map);
        })
        .catchError((e) {
          _loading = null; // 允许下次重试
          log('音素热词: 拼音字典加载失败: $e');
          throw e;
        });
  }

  /// 测试注入用
  static void debugReset() {
    _instance = null;
    _loading = null;
  }

  String? lookup(String char) => _map[char];
}

/// 声母表（pypinyin Style.INITIALS strict=False 的等价拆分：zh/ch/sh 最长
/// 优先，y/w 按惯用分界算声母；与 tools/pinyin/gen_pinyin_dict.py 同表）。
const List<String> _kInitials = [
  'zh', 'ch', 'sh', //
  'b', 'p', 'm', 'f', 'd', 't', 'n', 'l', //
  'g', 'k', 'h', 'j', 'q', 'x', 'r', 'z', 'c', 's', //
  'y', 'w',
];

bool _isCjk(String c) =>
    c.isNotEmpty && c.codeUnitAt(0) >= 0x4E00 && c.codeUnitAt(0) <= 0x9FFF;

bool _isAsciiAlpha(String c) {
  final v = c.codeUnitAt(0);
  return (v >= 0x61 && v <= 0x7A) || (v >= 0x41 && v <= 0x5A);
}

bool _isAsciiDigit(String c) {
  final v = c.codeUnitAt(0);
  return v >= 0x30 && v <= 0x39;
}

/// 将文本转为带位置信息的音素序列（对齐 CapsWriter get_phoneme_info，
/// ascii_split_char=True：英文逐字母拆）。
///
/// 标点/空格跳过，但相邻音素的 char 区间保持对原文本的映射，
/// 替换时按区间写回原文。
List<Phoneme> getPhonemeInfo(String text) {
  final seq = <Phoneme>[];
  final dict = PinyinDict._instance;
  var pos = 0;
  while (pos < text.length) {
    final char = text[pos];
    if (_isCjk(char)) {
      pos = _processZh(text, pos, seq, dict);
    } else if (_isAsciiAlpha(char) || _isAsciiDigit(char)) {
      pos = _processEnNum(text, pos, seq);
    } else {
      pos++; // 空格/标点：跳过，保持音素流连续以便匹配
    }
  }
  return seq;
}

/// 处理连续中文片段（CapsWriter _process_zh），返回扫描后的新位置。
int _processZh(String text, int pos, List<Phoneme> seq, PinyinDict? dict) {
  var scan = pos;
  while (scan < text.length && _isCjk(text[scan])) {
    scan++;
  }
  for (var i = pos; i < scan; i++) {
    final char = text[i];
    final py = dict?.lookup(char);
    if (py == null || py.length < 2 || !_isAsciiDigit(py[py.length - 1])) {
      // 字典无读音（生僻字）→ 整字兜底为一个音素（CapsWriter 降级同款）
      seq.add(Phoneme(
        char,
        'zh',
        isWordStart: true,
        isWordEnd: true,
        charStart: i,
        charEnd: i + 1,
      ));
      continue;
    }
    // 拆声母：zh/ch/sh 两字母最长匹配，再单字母（y/w 算声母）
    var initial = '';
    var finalIdx = 0;
    if (py.length >= 3) {
      final head2 = py.substring(0, 2);
      if (head2 == 'zh' || head2 == 'ch' || head2 == 'sh') {
        initial = head2;
        finalIdx = 2;
      }
    }
    if (initial.isEmpty && _kInitials.contains(py[0])) {
      initial = py[0];
      finalIdx = 1;
    }
    final fin = py.substring(finalIdx, py.length - 1);
    final tone = py[py.length - 1];
    if (initial.isNotEmpty) {
      seq.add(Phoneme(initial, 'zh',
          isWordStart: true, charStart: i, charEnd: i + 1));
    }
    if (fin.isNotEmpty) {
      seq.add(Phoneme(fin, 'zh',
          isWordStart: initial.isEmpty, charStart: i, charEnd: i + 1));
    }
    seq.add(Phoneme(tone, 'zh',
        isWordStart: false,
        isWordEnd: true,
        isTone: true,
        charStart: i,
        charEnd: i + 1));
  }
  return scan;
}

/// 处理英文/数字片段（CapsWriter _process_en_num）：驼峰 aA、字母数字 a1、
/// 数字字母 1a 处断开 token，token 小写后逐字母拆分。返回新位置。
int _processEnNum(String text, int pos, List<Phoneme> seq) {
  final start = pos;
  while (pos < text.length) {
    final char = text[pos];
    if (!_isAsciiAlpha(char) && !_isAsciiDigit(char)) break;
    if (pos > start) {
      final prev = text[pos - 1];
      final prevLower = prev.toLowerCase() == prev;
      final prevIsDigit = _isAsciiDigit(prev);
      final curIsDigit = _isAsciiDigit(char);
      final camel = prevLower && char == char.toUpperCase() && !prevIsDigit;
      if (camel ||
          (!prevIsDigit && curIsDigit) ||
          (prevIsDigit && !curIsDigit)) {
        break;
      }
    }
    pos++;
  }
  final token = text.substring(start, pos).toLowerCase();
  final lang = token.codeUnits.every((c) => c >= 0x30 && c <= 0x39)
      ? 'num'
      : 'en';
  for (var i = 0; i < token.length; i++) {
    seq.add(Phoneme(
      token[i],
      lang,
      isWordStart: i == 0,
      isWordEnd: i == token.length - 1,
      charStart: start + i,
      charEnd: start + i + 1,
    ));
  }
  return pos;
}

/// 最长公共子序列长度（英文 token 字符级相似度用，滚动数组）。
int lcsLength(String s1, String s2) {
  if (s1.isEmpty || s2.isEmpty) return 0;
  var prev = List.filled(s2.length + 1, 0);
  var curr = List.filled(s2.length + 1, 0);
  for (var i = 1; i <= s1.length; i++) {
    for (var j = 1; j <= s2.length; j++) {
      curr[j] = s1[i - 1] == s2[j - 1]
          ? prev[j - 1] + 1
          : (prev[j] > curr[j - 1] ? prev[j] : curr[j - 1]);
    }
    final t = prev;
    prev = curr;
    curr = t;
  }
  return prev[s2.length];
}
