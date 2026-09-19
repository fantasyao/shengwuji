import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme_extension.dart';
import '../widgets/neu_widgets.dart';
import 'diary_server_controller.dart';
import 'diary_web_server.dart';

/// 设置页「电脑访问」卡片：开关 + 状态 + 局域网地址展示。
///
/// 从 settings_tab 抽出为独立组件（照 OverlayPanelHeader 的 widgets/ 提取
/// 惯例），状态直接订阅 [DiaryServerController.status]——开关动作发生在
/// 本卡片，但服务的启动/停止/自恢复可以发生在任何位置（main.dart 冷启动
/// 自恢复），单一数据源不会出现"开关显示与实际状态不一致"。
class WebServerSettingsCard extends StatelessWidget {
  const WebServerSettingsCard({
    super.key,
    required this.controller,
    this.lanAddressesLoader,
  });

  final DiaryServerController controller;

  /// 局域网地址加载器（测试注入固定值；生产用 DiaryServerController.lanAddresses）
  final Future<List<String>> Function()? lanAddressesLoader;

  @override
  Widget build(BuildContext context) {
    final ext = AppThemeExtension.of(context);
    return ValueListenableBuilder<DiaryServerStatus>(
      valueListenable: controller.status,
      builder: (context, status, _) {
        final isOn =
            status.phase == DiaryServerPhase.running ||
            status.phase == DiaryServerPhase.starting;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.computer_outlined, color: ext.primary, size: 18),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '电脑访问服务',
                    // 与设置页其他卡片标题（如「数据备份」）同款：textPrimary+14+bold，
                    // 原先 textSecondary+13 偏暗不统一
                    style: TextStyle(
                      color: ext.textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                // 新拟物主题：凹槽轨道+凸滑块开关；其余主题保持 M3 Switch
                if (ext.isNeumorphic)
                  NeuSwitch(value: isOn, onChanged: _onToggle)
                else
                  Switch(value: isOn, onChanged: _onToggle),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '开启后，同一 Wi-Fi 下的电脑浏览器打开下方地址，即可查看、编辑、删除随手记'
              '（含录音播放）；手机这边新增的日记也会实时出现在电脑上。运行期间通知栏'
              '有一条常驻通知保持服务不中断',
              style: TextStyle(fontSize: 12, color: ext.textHint),
            ),
            if (status.phase == DiaryServerPhase.starting) ...[
              const SizedBox(height: 10),
              const LinearProgressIndicator(minHeight: 2),
            ],
            if (status.phase == DiaryServerPhase.error) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  Icon(Icons.error_outline, color: ext.warningText, size: 15),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(
                      status.message ?? '启动失败',
                      style: TextStyle(fontSize: 12, color: ext.warningText),
                    ),
                  ),
                ],
              ),
            ],
            if (status.phase == DiaryServerPhase.running) ...[
              const Divider(height: 24),
              _buildAddressList(context),
              const SizedBox(height: 6),
              Text(
                '手机与电脑需连同一 Wi-Fi；端口固定 9527，地址可收藏到浏览器书签',
                style: TextStyle(fontSize: 11, color: ext.textHint),
              ),
            ],
          ],
        );
      },
    );
  }

  /// 开关切换（starting 中忽略——controller 有并发守卫，这里也挡一层防抖）
  void _onToggle(bool value) {
    if (controller.status.value.phase == DiaryServerPhase.starting) return;
    if (value) {
      controller.start();
    } else {
      controller.stop();
    }
  }

  /// 局域网地址行：http://ip:9527 + 复制按钮
  Widget _buildAddressList(BuildContext context) {
    final ext = AppThemeExtension.of(context);
    final loader = lanAddressesLoader ?? DiaryServerController.lanAddresses;
    return FutureBuilder<List<String>>(
      future: loader(),
      builder: (context, snapshot) {
        final addresses = snapshot.data ?? const <String>[];
        if (addresses.isEmpty) {
          return Text(
            '未获取到局域网地址（Wi-Fi 未连接？）',
            style: TextStyle(fontSize: 12, color: ext.warningText),
          );
        }
        return Column(
          children: [
            for (final ip in addresses)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'http://$ip:$kDiaryServerPort',
                        style: TextStyle(
                          fontSize: 14,
                          color: ext.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: Icon(Icons.copy, size: 17, color: ext.textHint),
                      tooltip: '复制地址',
                      constraints: const BoxConstraints(),
                      padding: EdgeInsets.zero,
                      onPressed: () => _copyAddress(context, ip),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }

  void _copyAddress(BuildContext context, String ip) {
    Clipboard.setData(ClipboardData(text: 'http://$ip:$kDiaryServerPort'));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('地址已复制，粘贴到电脑浏览器打开即可')),
    );
  }
}
