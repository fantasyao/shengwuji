import 'package:flutter/services.dart';

/// 单个图标包定义
class IconPack {
  final String id;
  final String name;
  final int backgroundColor;  // 0xFF...... 格式
  final int foregroundColor;   // UI 预览用（资源里已染色）
  final bool isPro;
  const IconPack({
    required this.id,
    required this.name,
    required this.backgroundColor,
    required this.foregroundColor,
    this.isPro = false,
  });
}

/// 4 套图标包注册表
class IconPacks {
  static const defaultPack = IconPack(
    id: 'default', name: '默认',
    backgroundColor: 0xFF2C3E50, foregroundColor: 0xFFFFFFFF,
  );
  static const warm = IconPack(
    id: 'warm', name: '暖橙',
    backgroundColor: 0xFFE65100, foregroundColor: 0xFFFFFFFF,
  );
  static const festive = IconPack(
    id: 'festive', name: '节日红',
    backgroundColor: 0xFFC62828, foregroundColor: 0xFFFFFFFF, isPro: true,
  );
  static const minimal = IconPack(
    id: 'minimal', name: '极简白',
    backgroundColor: 0xFFFAFAFA, foregroundColor: 0xFF2C3E50, isPro: true,
  );

  static const all = [defaultPack, warm, festive, minimal];

  static IconPack? findById(String? id) {
    if (id == null) return null;
    for (final p in all) {
      if (p.id == id) return p;
    }
    return null;
  }
}

/// MethodChannel 包装
///
/// ⚠️ 切换后 APP 进程会被系统杀死（1-3 秒内），调用方应在 UI 上提示用户"应用会短暂重启"。
class IconPackSwitcher {
  static const _channel = MethodChannel('com.shengwuji.app/app');

  /// 切换到指定图标包
  ///
  /// [packId] "default" / "warm" / "festive" / "minimal"
  /// 返回 true 如果原生层成功执行（不代表进程不会死）
  static Future<bool> switchTo(String packId) async {
    try {
      final r = await _channel.invokeMethod<bool>('setIconPack', {'packId': packId});
      return r ?? false;
    } on PlatformException catch (e) {
      print('❌ [IconPackSwitcher] 切换失败: ${e.message}');
      return false;
    }
  }

  /// 查询当前图标包 ID
  ///
  /// 从原生层 `getComponentEnabledSetting` 读取，
  /// 不依赖 SharedPreferences（系统 ComponentEnabledSetting 才是真正状态源）。
  static Future<String> getCurrentPackId() async {
    try {
      return await _channel.invokeMethod<String>('getCurrentIconPack') ?? 'default';
    } on PlatformException catch (e) {
      print('❌ [IconPackSwitcher] 查询失败: ${e.message}');
      return 'default';
    }
  }
}
