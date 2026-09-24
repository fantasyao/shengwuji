import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shengwuji_app/ai_app_model.dart';

/// 自定义 AI 应用（二级页 + 号添加，上限 3）模型层测试：
/// 序列化往返 / 脏数据容错 / 增删查重与上限 / resolveAppById 解析优先级
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('AIApp 序列化', () {
    test('toJson/fromJson 往返一致', () {
      const app = AIApp(
        id: 'custom_com.example.app',
        name: '测试应用',
        packageName: 'com.example.app',
      );
      final restored = AIApp.fromJson(
        jsonDecode(jsonEncode(app.toJson())) as Map<String, dynamic>,
      );
      expect(restored.id, app.id);
      expect(restored.name, app.name);
      expect(restored.packageName, app.packageName);
    });

    test('自定义应用默认 icon 为 📱、scheme/url 为空', () {
      const app = AIApp(id: 'x', name: 'X', packageName: 'p');
      expect(app.icon, '📱');
      expect(app.scheme, '');
      expect(app.url, '');
    });
  });

  group('loadCustomApps 容错', () {
    test('无偏好时返回空列表', () async {
      expect(await AIApp.loadCustomApps(), isEmpty);
    });

    test('非 JSON 脏数据返回空列表不抛错', () async {
      SharedPreferences.setMockInitialValues({
        AIApp.customAppsPrefsKey: 'not-a-json{',
      });
      expect(await AIApp.loadCustomApps(), isEmpty);
    });

    test('单条缺字段跳过，其余条目保留', () async {
      final good = AIApp(id: 'custom_p.a', name: '好应用', packageName: 'p.a')
          .toJson();
      SharedPreferences.setMockInitialValues({
        AIApp.customAppsPrefsKey: jsonEncode([
          {'id': 'broken'}, // 缺 name/packageName
          good,
        ]),
      });
      final apps = await AIApp.loadCustomApps();
      expect(apps.length, 1);
      expect(apps.first.packageName, 'p.a');
    });
  });

  group('addCustomApp 增删与上限', () {
    test('添加成功：id 带 custom_ 前缀，可读回', () async {
      final err = await AIApp.addCustomApp('豆包', 'com.larus.nova');
      expect(err, isNull);
      final apps = await AIApp.loadCustomApps();
      expect(apps.length, 1);
      expect(apps.first.id, 'custom_com.larus.nova');
      expect(apps.first.packageName, 'com.larus.nova');
    });

    test('与内置包名重复时拒绝', () async {
      final err = await AIApp.addCustomApp(
        '微信分身',
        AIApp.allApps[3].packageName, // com.tencent.mm
      );
      expect(err, isNotNull);
      expect(err, contains('已在应用列表中'));
      expect(await AIApp.loadCustomApps(), isEmpty);
    });

    test('重复添加同一包名拒绝', () async {
      expect(await AIApp.addCustomApp('豆包', 'com.larus.nova'), isNull);
      final err = await AIApp.addCustomApp('豆包二', 'com.larus.nova');
      expect(err, isNotNull);
      expect(err, contains('已添加过'));
      expect((await AIApp.loadCustomApps()).length, 1);
    });

    test('超过 3 个上限拒绝', () async {
      for (var i = 1; i <= AIApp.maxCustomApps; i++) {
        expect(
          await AIApp.addCustomApp('应用$i', 'com.test.app$i'),
          isNull,
        );
      }
      final err = await AIApp.addCustomApp('第四个', 'com.test.app4');
      expect(err, isNotNull);
      expect(err, contains('最多添加'));
      expect((await AIApp.loadCustomApps()).length, AIApp.maxCustomApps);
    });

    test('removeCustomApp 移除指定应用', () async {
      await AIApp.addCustomApp('豆包', 'com.larus.nova');
      await AIApp.addCustomApp('元宝', 'com.tencent.hunyuan');
      final apps = await AIApp.loadCustomApps();
      await AIApp.removeCustomApp(apps.first);
      final rest = await AIApp.loadCustomApps();
      expect(rest.length, 1);
      expect(rest.first.packageName, 'com.tencent.hunyuan');
    });
  });

  group('resolveAppById 解析优先级', () {
    test('内置命中', () async {
      final app = await AIApp.resolveAppById('chatgpt');
      expect(app, isNotNull);
      expect(app!.id, 'chatgpt');
    });

    test('自定义命中', () async {
      await AIApp.addCustomApp('豆包', 'com.larus.nova');
      final app = await AIApp.resolveAppById('custom_com.larus.nova');
      expect(app, isNotNull);
      expect(app!.name, '豆包');
    });

    test('custom_ 前缀但已不存在返回 null（分享侧自行回落默认）', () async {
      expect(await AIApp.resolveAppById('custom_gone.pkg'), isNull);
    });

    test('非 custom_ 的未知 id 返回 null', () async {
      expect(await AIApp.resolveAppById('unknown'), isNull);
    });
  });
}
