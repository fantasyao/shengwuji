import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme_extension.dart';
import 'settings_widgets.dart';

/// 「功能说明」二级页：按页面 / 使用场景整理全量功能与常用说法。
///
/// 与随手记里的内置说明卡片互补：说明卡是日记行，可能被用户删除且旧文案
/// 不会随版本更新；本页是常驻入口，升级用户也能随时查到最新说法。
/// 内容改动需同步 test/feature_guide_page_test.dart 的关键词断言。
class FeatureGuidePage extends StatelessWidget {
  const FeatureGuidePage({super.key});

  static const List<_GuideSection> _sections = [
    _GuideSection(
      title: '存物品（存物品页）',
      items: [
        _GuideItem(
          icon: Icons.inventory_2_outlined,
          title: '一句话录入物品',
          body:
              '按「物品 + 在 / 放在 + 位置」的顺序说。例：钥匙放在客厅抽屉里、充电器在书桌右边。'
              '也认「放进 / 放到 / 搁在 / 藏在」；物品名至少 2 个字，前半句是物品、后半句是位置。',
        ),
        _GuideItem(
          icon: Icons.moving,
          title: '搬家模式',
          body:
              '打开后手机放一旁就行：app 会一直听，自动按说话的停顿分段，说一句存一条，'
              '保存后播报「已保存 X 到 Y」。同样用「放在 / 在」分隔；搬家时容器名可以直接说'
              '「3号盒子」「红色袋子」，不需要加「里 / 上」这类方位词。',
        ),
        _GuideItem(
          icon: Icons.undo,
          title: '搬家模式说错了',
          body:
              '保存后 10 秒内说「不对 / 撤销 / 错了 / 取消 / 删掉 / 删除」等短词，'
              '会自动删掉上一条并播报「已撤销」；也可以点页面里的撤销按钮。',
        ),
        _GuideItem(
          icon: Icons.exit_to_app,
          title: '搬家模式什么时候结束',
          body: '把 app 退到后台会自动结束搬家模式。录音期间屏幕保持常亮，长时间无操作会自动变暗省电。',
        ),
        _GuideItem(
          icon: Icons.checklist,
          title: '语音待办清单',
          body:
              '开口先说「待办」或「代办」，再用顿号、逗号、「还有 / 再买」等把至少两件事连起来。'
              '例：待办，买牛奶、交电费、明天下午三点开会。没以「待办 / 代办」开头的正常说话不会被误判成清单。',
        ),
      ],
    ),
    _GuideSection(
      title: '查物品（查物品页）',
      items: [
        _GuideItem(
          icon: Icons.search,
          title: '正着查：物品在哪里',
          body:
              '说「钥匙在哪里」「钥匙放哪了」「钱包在什么地方」，系统按物品名去找位置。'
              '常见说法还有「在哪儿 / 在哪 / 什么位置 / 哪儿了」等。',
        ),
        _GuideItem(
          icon: Icons.location_on_outlined,
          title: '反着查：哪里有什么',
          body: '说「客厅里有什么」「抽屉都有什么」「柜子里有些什么」，系统按位置列出里面的物品。',
        ),
        _GuideItem(
          icon: Icons.filter_alt_outlined,
          title: '搜索框过滤',
          body: '列表顶部搜索框输入物品名或位置关键词，即可过滤当前物品列表。',
        ),
      ],
    ),
    _GuideSection(
      title: '随手记（日记页）',
      items: [
        _GuideItem(
          icon: Icons.touch_app_outlined,
          title: '卡片手势',
          body:
              '单击卡片复制内容；双击弹出编辑抽屉；长按把文字炸成词块（点选 / 滑动连选，可一键复制或搜索）。'
              '单击与双击可在「设置 → 日记智能与交互」里交换，长按大爆炸不受影响。',
        ),
        _GuideItem(
          icon: Icons.swipe_left_alt,
          title: '归档与恢复',
          body:
              '把活跃笔记向左滑会归档，归档后可恢复；已归档的笔记再向左滑则彻底删除。'
              '卡片上的圆圈也可以归档 / 恢复。',
        ),
        _GuideItem(
          icon: Icons.filter_alt_outlined,
          title: '顶部筛选',
          body:
              '搜索框右侧的筛选按钮可展开筛选行：普通，以及 4 个标注（紧急 / 收藏 / 灵感 / 任务）。'
              '点一次图标筛选，再点一次取消筛选、恢复全部；再点筛选按钮收起。',
        ),
        _GuideItem(
          icon: Icons.label_outline,
          title: '标注（加标注在悬浮窗里）',
          body:
              '日记页只显示标注：卡片上的小色点标记这条笔记的标注，搜索框右侧的筛选按钮可按标注筛。'
              '要给笔记加 / 改标注，得在悬浮窗里做——展开卡片，时间行有一排标注按钮，'
              '点一下即标注、再点同一个取消（紧急 / 收藏 / 灵感 / 任务）。'
              '「设置 → 标签外观」可以换 4 个标注的图标和颜色，悬浮窗与电脑访问页同步显示。',
        ),
        _GuideItem(
          icon: Icons.download_outlined,
          title: '导出到文件夹（推荐 Obsidian）',
          body:
              '点右上角的下载按钮，把还没导出的活跃笔记写成 Markdown 文件、存进你选择的文件夹；'
              '长按下载按钮可以重新选目录并重新导出全部。推荐直接选 Obsidian 仓库文件夹，'
              '导出后就能在 Obsidian 里按文件浏览。',
        ),
        _GuideItem(
          icon: Icons.smart_toy_outlined,
          title: 'AI 对话',
          body:
              '点卡片底部的对话图标，内容会自动复制并跳转到默认 AI 应用继续聊。'
              '「设置 → AI 应用分享」可换内置应用，也能添加手机里任意已安装的 AI 应用（最多 3 个）。',
        ),
        _GuideItem(
          icon: Icons.keyboard_alt_outlined,
          title: '上滑新建文本笔记',
          body: '按住底部麦克风圆钮向上滑，拉出「Aa」标记后松手，会新建一条空白文本笔记，直接打字，无需语音。',
        ),
        _GuideItem(
          icon: Icons.alarm,
          title: '时间自动变闹钟',
          body: '正文里写到「明天下午3点」「周六晚上八点」等时间，对应文字会变蓝；点一下即可设系统闹钟。',
        ),
        _GuideItem(
          icon: Icons.lock_outline,
          title: '笔记锁定',
          body:
              '卡片上的锁按钮可给单条笔记上锁，正文打码，用指纹或锁屏密码解锁，息屏后自动重新上锁。'
              '总开关在「设置 → 日记智能与交互」。',
        ),
        _GuideItem(
          icon: Icons.ios_share,
          title: '从其他 App 分享文字',
          body: '在浏览器、微信等应用里选中文字 → 系统分享 → 选择「声物记」，会直接保存成一条文本笔记。',
        ),
      ],
    ),
    _GuideSection(
      title: '悬浮窗',
      items: [
        _GuideItem(
          icon: Icons.picture_in_picture_alt_outlined,
          title: '呼出与收起',
          body:
              '在「设置 → 音量键快捷操作」把任一长按槽位设为「显示悬浮窗」：按一下显示并展开面板，再按一下隐藏。'
              '也可以点贴边把手，或朝屏幕内侧滑动展开；点面板外空白处、或朝停靠边缘滑动即可收起。',
        ),
        _GuideItem(
          icon: Icons.open_with,
          title: '长按把手挪动位置',
          body: '长按屏幕边缘的把手上下来回拖，松手后记住新位置。停靠左缘还是右缘，可在「设置 → 悬浮窗」切换。',
        ),
        _GuideItem(
          icon: Icons.archive_outlined,
          title: '卡片归档 / 删除',
          body:
              '把卡片朝屏幕内侧滑走（默认右缘停靠时是左滑）会归档；点卡片顶部的圆圈也能归档，归档后再点圆圈恢复。'
              '在「设置 → 悬浮窗」开启「滑动直接删除笔记」后，滑走 = 直接删除，删除后 3 秒内可点「撤销」。',
        ),
        _GuideItem(
          icon: Icons.swap_vert,
          title: '长按拖动排序',
          body: '展开列表里，长按活跃卡片的收起态可上下拖动排序；展开卡、归档卡和编辑中的卡片不能拖。',
        ),
        _GuideItem(
          icon: Icons.copy_all_outlined,
          title: '展开卡片与复制 / 截图',
          body:
              '点卡片展开。展开卡正文长按 = 大爆炸分词；底部复制按钮点一下 = 复制内容，长按 = 截图并保存为这条笔记的附件。'
              '截图功能需要 Android 11 及以上；截图不进本地备份 ZIP，但会随云端同步在多台设备之间双向传输；'
              '第一次长按如果提示失败，请到系统设置里把无障碍服务关掉再重开一次。',
        ),
        _GuideItem(
          icon: Icons.mic_none,
          title: '悬浮窗语音录音',
          body:
              '展开面板顶部有录音按钮，点一下开始录音；面板收成一颗录音胶囊，点胶囊右端的停止按钮即停止并转写，'
              '结果直接存成一条笔记。很适合边走边说、不需要打开 app。'
              '录音时如果说的内容以「搜索」开头（如「搜索明天天气」），'
              '转写后会直接打开浏览器搜索，这条笔记仍然会保存。',
        ),
        _GuideItem(
          icon: Icons.tune,
          title: '语音搜索设置',
          body:
              '「设置 → 悬浮窗 → 语音搜索跳转」可以开关该功能、修改触发词（默认「搜索一下 / 搜索 / 搜一下」）；'
              '用哪个搜索引擎、哪个浏览器打开，在「设置 → 大爆炸搜索」里选。',
        ),
        _GuideItem(
          icon: Icons.calendar_month_outlined,
          title: '语音定闹钟',
          body: '展开卡上点闹钟按钮，说「周六晚上八点提醒我去看电影」，识别出时间后拨动转轮确认，即可写入系统日历并按设定响铃。',
        ),
        _GuideItem(
          icon: Icons.visibility_off_outlined,
          title: '外观与自动隐藏',
          body: '「设置 → 悬浮窗」可调自动隐藏时长、停靠侧、隐藏后是否保留贴边竖线、面板字号与可见条数、把手大小（Pro 功能）。',
        ),
      ],
    ),
    _GuideSection(
      title: '搜索与按键快捷方式',
      items: [
        _GuideItem(
          icon: Icons.travel_explore,
          title: '大爆炸搜索',
          body:
              '随手记卡片长按、悬浮窗展开卡正文长按，都能把文字炸成词块；点选或滑动连选后，可一键复制或联网搜索。'
              '搜索引擎和浏览器在「设置 → 大爆炸搜索」里选。',
        ),
        _GuideItem(
          icon: Icons.volume_up,
          title: '音量键手势',
          body:
              '「设置 → 音量键快捷操作」里，音量加 / 减的「长按」和「双击」共 4 个槽位，可分别设为：'
              '显示悬浮窗、悬浮窗录音、悬浮窗笔记、剪贴板笔记（把最近复制的文字直接存成随手记，'
              '不展开悬浮窗）、App 内录音、App 内笔记、按住说话（只有长按槽位有）或无动作；'
              '长按触发时长也可调。这套槽位是本 app 通过自己的无障碍服务拦音量键实现的，'
              '系统里其他实体按键要用下面的快捷方式。前置条件是开启本 app 的无障碍服务。',
        ),
        _GuideItem(
          icon: Icons.settings_remote,
          title: 'AI 键 / 自定义侧键',
          body:
              '声物记向系统提供了几个快捷方式，在手机系统设置里把 AI 键、自定义侧键等映射过去'
              '（执行链路与上面的音量键手势一致，但走系统自身的按键调用渠道，比音量键手势可靠）：'
              '「悬浮窗录音（再触发停止）」第一次触发开始录音，第二次触发停止并转写，非滑动式按键用它；'
              '「显示悬浮窗（再触发隐藏）」按一下展开、再按一下隐藏；'
              '「快速录音」适合滑动式按键，上滑开始、滑回退出后自动停止并转写；'
              '「文本笔记」直接新建空白文本笔记。',
        ),
        _GuideItem(
          icon: Icons.screen_lock_portrait_outlined,
          title: '黑屏与退出时的行为',
          body:
              '分两种情况。**想新起一段录音**：完全黑屏时不行——部分手机不会把普通音量键事件交给 app，'
              '悬浮窗在息屏时也会收掉，音量键手势唤不起来；要先点亮屏幕，'
              '有 AI 键或其他自定义键的手机建议改用上面的系统快捷方式。'
              '**已经在录的那段**：不会被息屏打断，录音中悬浮窗会强制屏幕常亮，你按电源键息屏后录音和转写继续跑，'
              '只是黑屏期间看不见胶囊也点不到停止按钮，最长录 5 分钟会自动停止并转写。'
              '另外，用快捷方式或音量键在 app 内拉起的录音，退出 app 且屏幕亮着时会自动停止并转写；息屏则继续录。',
        ),
        _GuideItem(
          icon: Icons.stop_circle_outlined,
          title: '录音怎么停',
          body:
              '普通录音松开麦克风按钮即停。也可在设置里开启「录音中单击音量键结束录音」——耳机线控键、蓝牙播放键、'
              '相机键同样有效；它和「按音量减保持静音」二选一。还可以开启「说完自动停止」，'
              '说完后静音 3 / 5 / 8 秒自动停并转写。',
        ),
      ],
    ),
    _GuideSection(
      title: '语音识别与修正',
      items: [
        _GuideItem(
          icon: Icons.offline_bolt_outlined,
          title: '完全离线',
          body: '语音识别模型内置在手机里，录音和转写都在本地完成，不联网、不上传任何内容。',
        ),
        _GuideItem(
          icon: Icons.spellcheck,
          title: '热词',
          body:
              '「设置 → 识别与修正」可添加常说的词，支持「正词 | 别名1 | 别名2」写法。'
              '热词按发音模糊匹配，平翘舌、前后鼻音、n/l 等常见听错会自动纠正。',
        ),
        _GuideItem(
          icon: Icons.auto_fix_high_outlined,
          title: '自动学习你的修正',
          body:
              '手动改识别文字后，app 会记住「错 → 对」；下次再遇到会提示一键修正。'
              '同一处反复改 3 次，会主动提议把这个词加入热词。',
        ),
        _GuideItem(
          icon: Icons.translate,
          title: '同音词上下文纠错',
          body:
              '按前后文自动选择「智谱 / 质朴」「通义 / 同意」等同音写法，置信度不够时保持原文，宁漏勿错。'
              '可以在「设置 → 识别与修正」里关闭。',
        ),
      ],
    ),
    _GuideSection(
      title: '数据与同步',
      items: [
        _GuideItem(
          icon: Icons.backup_outlined,
          title: '本地备份',
          body:
              '「设置 → 数据备份」可导出 ZIP，包含笔记、物品、录音、热词、修正对和标签外观；'
              '换机或误删时用「导入备份」恢复。',
        ),
        _GuideItem(
          icon: Icons.cloud_sync_outlined,
          title: '云端同步（WebDAV）',
          body:
              '支持坚果云等 WebDAV 网盘，多台设备的数据会自动合并。同步有三个触发入口：'
              '「设置 → 云端同步」点立即同步、随手记列表下拉刷新、悬浮窗面板下拉刷新；'
              'app 不会自己后台联网同步。日记的文字与截图附件双向同步，物品、热词、修正对补齐新增；'
              '录音文件要另开「同步录音文件」开关才传。',
        ),
        _GuideItem(
          icon: Icons.computer_outlined,
          title: '电脑访问',
          body: '手机和电脑连同一 Wi-Fi，用电脑浏览器打开 app 里显示的网址，就能查看、编辑笔记、回放录音和删除。',
        ),
      ],
    ),
    _GuideSection(
      title: '外观、字体与安全',
      items: [
        _GuideItem(
          icon: Icons.palette_outlined,
          title: '主题与深色模式',
          body:
              '内置默认青、暖橙、墨绿、晴空蓝、新拟物 5 套主题；也可以自选主色生成一套（Pro）。'
              '深色模式可跟随系统或手动切换。',
        ),
        _GuideItem(
          icon: Icons.text_fields,
          title: '字体与字号',
          body: '字号支持五档全局缩放；字体可在霞鹜文楷和系统默认之间切换。',
        ),
        _GuideItem(
          icon: Icons.apps_outlined,
          title: '桌面图标',
          body: '4 套图标包可选（部分 Pro）。切换后 Android 会用 1～3 秒重启 app，属于系统的正常行为。',
        ),
        _GuideItem(
          icon: Icons.workspace_premium,
          title: 'Pro 解锁',
          body:
              '悬浮窗整体、晴空蓝 / 新拟物主题和部分图标包为 Pro 功能。可先免费试用 7 天，'
              '或凭一机一码的授权码解锁；试用满意后再付费。',
        ),
      ],
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final ext = AppThemeExtension.of(context);
    return Scaffold(
      backgroundColor: ext.scaffoldBackground,
      appBar: AppBar(
        title: Text(
          '功能说明',
          style: TextStyle(color: ext.textPrimary, fontWeight: FontWeight.bold),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        systemOverlayStyle: ext.isDarkOverlay
            ? SystemUiOverlayStyle.light
            : SystemUiOverlayStyle.dark,
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          SettingsCard(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.menu_book_outlined, color: ext.primary, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '下面按使用场景整理了声物记的主要功能。第一次用，建议先看「存物品」和「随手记」；'
                    '其余功能用到时再回来查。说明会随版本更新，随时可以在这里查看。',
                    style: TextStyle(
                      color: ext.textSecondary,
                      fontSize: 13,
                      height: 1.6,
                    ),
                  ),
                ),
              ],
            ),
          ),
          for (final section in _sections) ...[
            const SizedBox(height: 24),
            SettingsSectionTitle(section.title),
            SettingsCard(
              child: Column(
                children: [
                  for (var i = 0; i < section.items.length; i++) ...[
                    if (i > 0) const Divider(height: 22),
                    _buildItem(context, section.items[i]),
                  ],
                ],
              ),
            ),
          ],
          const SizedBox(height: 40),
        ],
      ),
    );
  }

  Widget _buildItem(BuildContext context, _GuideItem item) {
    final ext = AppThemeExtension.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: ext.primary.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(9),
          ),
          alignment: Alignment.center,
          child: Icon(item.icon, color: ext.primary, size: 18),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                item.title,
                style: TextStyle(
                  color: ext.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                item.body,
                style: TextStyle(
                  color: ext.textSecondary,
                  fontSize: 12,
                  height: 1.65,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _GuideSection {
  const _GuideSection({required this.title, required this.items});

  final String title;
  final List<_GuideItem> items;
}

class _GuideItem {
  const _GuideItem({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;
}
