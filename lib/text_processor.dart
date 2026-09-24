import 'app_logger.dart';
import 'dart:io';
import 'dart:async';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'hotword/phoneme.dart';
import 'hotword/phoneme_corrector.dart';
import 'utils/cloud_sync_data_version.dart'; // 云同步待同步检测：热词编辑 bump 数据版本

class TextProcessor {
  // 存放规则的仓库
  final Map<RegExp, String> _ruleMap = {};
  final Map<String, String> _hotwordMap = {};

  // 音素热词（zcode: 2026-09 借鉴 CapsWriter-Offline——发音超过阈值才替换，
  // 短热词（音素 <4）只提示不替换，见 docs/architecture/phoneme-hotword.md）
  final List<PhonemeEntry> _phonemeEntries = [];
  PhonemeCorrector? _corrector;
  bool _phonemeEnabled = true;
  double _phonemeThreshold = PhonemeHotwordConfig.defaultThreshold;

  /// 最近一次 [process] 的音素相似命中（未替换、仅提示）。
  /// 日记/录入链路在识别后读取并弹一键替换提示；无人读取则自然丢弃。
  List<PhonemeMatch> lastPhonemeSimilars = const [];

  // 1. 找到手机里专门存这个 APP 数据的地方
  Future<File> get _localFile async {
    final directory = await getApplicationDocumentsDirectory();
    // 我们把用户自定义的热词存成这个文件
    return File('${directory.path}/user_hotwords.txt');
  }

  // 2. 加载配置（APP启动时，或者你点击保存时调用）
  Future<void> loadConfigs() async {
    _ruleMap.clear();
    _hotwordMap.clear();

    try {
      // 加载正则规则（这个通常改得少，依然从 assets 读取）
      final rulesContent = await rootBundle.loadString('assets/rules.txt');
      _parseRules(rulesContent);

      // 【重点】加载热词：先看手机本地有没有用户存过的
      String hotwordsContent;
      final localFile = await _localFile;

      if (await localFile.exists()) {
        // 如果有本地文件，就读本地的
        hotwordsContent = await localFile.readAsString();
      } else {
        // 如果没有（比如第一次装APP），就读你打包在 assets 里的初始热词
        hotwordsContent = await rootBundle.loadString('assets/hotwords.txt');
        // 顺便把初始热词存一份到本地，方便以后用户修改
        await localFile.writeAsString(hotwordsContent);
      }
      _parseHotwords(hotwordsContent);
    } catch (e) {
      log("加载配置出错: $e");
    }
    await _rebuildPhonemeCorrector();
  }

  // 3. 【核心方法一】获取本地文件内容（给设置页面的文本框显示用）
  Future<String> getLocalContent() async {
    final file = await _localFile;
    if (await file.exists()) {
      return await file.readAsString();
    }
    // 万一文件不存在，返回空或者从 assets 读
    return await rootBundle.loadString('assets/hotwords.txt');
  }

  // 4. 【核心方法二】保存用户修改的内容到本地
  Future<void> saveContent(String content) async {
    final file = await _localFile;
    await file.writeAsString(content); // 写入手机硬盘
    _parseHotwords(content); // 同时更新当前正在运行的程序，让它立即生效
    log('热词已保存: ${content.length} 字符, ${_hotwordMap.length} 条规则生效');
    // 注意顺序：同步链路下载合并热词也走这里，bump 后紧跟 markSynced 快照，不误报
    unawaited(CloudSyncDataVersion.bump()); // 本地有变更未上云，入口行提示用
    await _rebuildPhonemeCorrector();
  }

  /// 追加一条音素热词（修正对「加入热词」升级通道用）：
  /// target=正词，alias=可触发替换的错误写法。
  /// 已存在同 target+alias（任意格式解析后）时不动文件返回 false。
  Future<bool> appendHotwordPair(String target, String alias) async {
    target = target.trim();
    alias = alias.trim();
    if (target.isEmpty || alias.isEmpty) return false;
    final exists = _phonemeEntries.any(
      (e) => e.target == target && e.aliases.contains(alias),
    );
    if (exists) return false;
    final file = await _localFile;
    final content = await getLocalContent();
    final newLine = '$target | $alias';
    final newContent =
        (content.isEmpty || content.endsWith('\n'))
            ? '$content$newLine\n'
            : '$content\n$newLine\n';
    await file.writeAsString(newContent);
    _parseHotwords(newContent);
    log('音素热词已追加: $newLine');
    unawaited(CloudSyncDataVersion.bump());
    await _rebuildPhonemeCorrector();
    return true;
  }

  // 解析逻辑（保持不变）
  void _parseRules(String content) {
    for (var line in content.split('\n')) {
      final parts = line.trim().split(' === ');
      if (parts.length == 2) {
        _ruleMap[RegExp(parts[0], caseSensitive: false)] = parts[1];
      }
    }
  }

  /// 双格式解析见 parseHotwordEntries（老「 = 」字面+音素双登记，新「 | 」仅音素）
  void _parseHotwords(String content) {
    _hotwordMap.clear();
    _phonemeEntries.clear();
    _phonemeEntries.addAll(
      parseHotwordEntries(
        content,
        onLiteralPair: (wrong, right) => _hotwordMap[wrong] = right,
      ),
    );
  }

  /// 设置页改音素热词开关/阈值后调用：重读 prefs 并重建纠错器（立即生效）
  Future<void> reloadPhonemeConfig() => _rebuildPhonemeCorrector();

  /// 读取开关/阈值 prefs 并重建音素纠错器（字典进程级缓存，幂等）。
  /// 字典加载失败时音素层整体停用（_corrector 置空），字面替换不受影响。
  Future<void> _rebuildPhonemeCorrector() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _phonemeEnabled =
          prefs.getBool(PhonemeHotwordConfig.enabledPrefKey) ?? true;
      _phonemeThreshold = PhonemeHotwordConfig.normalizeThreshold(
        prefs.getDouble(PhonemeHotwordConfig.thresholdPrefKey) ??
            PhonemeHotwordConfig.defaultThreshold,
      );
      await PinyinDict.ensureLoaded();
      final corrector = PhonemeCorrector(threshold: _phonemeThreshold);
      corrector.updateHotwords(_phonemeEntries);
      _corrector = corrector;
      log(
        '音素热词: ${_phonemeEnabled ? '开启' : '关闭'}, '
        '阈值 $_phonemeThreshold, ${_phonemeEntries.length} 条',
      );
    } catch (e) {
      _corrector = null;
      log('音素热词初始化失败（仅字面替换生效）: $e');
    }
  }

  // 识别后处理文本的方法
  String process(String text, {bool removeSpaces = true}) {
    if (text.isEmpty) return text;
    lastPhonemeSimilars = const [];

    // 1. 可选：是否去掉所有空格 (包括普通空格和全角空格)
    String result = removeSpaces ? text.replaceAll(RegExp(r'\s+'), '') : text;

    // 2. 再进行正则规则库和热词表的替换
    _ruleMap.forEach((reg, repl) => result = result.replaceAll(reg, repl));
    _hotwordMap.forEach(
      (wrong, correct) => result = result.replaceAll(wrong, correct),
    );

    // 3. 音素热词：识别文本发音与热词（目标+别名）相似度超阈值才替换；
    //    低于强制阈值但达相似阈值的记入 lastPhonemeSimilars 供 UI 提示
    final corrector = _corrector;
    if (_phonemeEnabled && corrector != null && corrector.hotwords.isNotEmpty) {
      final phonemeResult = corrector.correct(result);
      if (phonemeResult.matches.isNotEmpty) {
        log('音素热词替换: ${phonemeResult.matches.join('、')}');
      }
      if (phonemeResult.similars.isNotEmpty) {
        log('音素热词相似(仅提示): ${phonemeResult.similars.join('、')}');
      }
      lastPhonemeSimilars = phonemeResult.similars;
      result = phonemeResult.text;
    }

    return result;
  }
}
