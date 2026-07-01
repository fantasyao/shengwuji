import 'dart:io';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

class TextProcessor {
  // 存放规则的仓库
  final Map<RegExp, String> _ruleMap = {};
  final Map<String, String> _hotwordMap = {};

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
      print("加载配置出错: $e");
    }
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

  void _parseHotwords(String content) {
    _hotwordMap.clear();
    for (var line in content.split('\n')) {
      final parts = line.trim().split(' = ');
      if (parts.length == 2) {
        _hotwordMap[parts[0].trim()] = parts[1].trim();
      }
    }
  }

  // 识别后处理文本的方法
  String process(String text, {bool removeSpaces = true}) {
    if (text.isEmpty) return text;

    // 1. 可选：是否去掉所有空格 (包括普通空格和全角空格)
    String result = removeSpaces
        ? text.replaceAll(RegExp(r'\s+'), '')
        : text;

    // 2. 再进行正则规则库和热词表的替换
    _ruleMap.forEach((reg, repl) => result = result.replaceAll(reg, repl));
    _hotwordMap.forEach((wrong, correct) => result = result.replaceAll(wrong, correct));

    return result;
  }
}
