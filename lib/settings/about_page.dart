import 'dart:developer' as dev;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_logger.dart';
import '../theme/app_theme_extension.dart';
import 'settings_widgets.dart';

/// 「关于」二级页（zcode: 2026-09 设置页下沉——更新日志时间线 / 导出运行日志 /
/// 开源许可从主页「关于」卡片搬入，主页只留版本入口行）
class AboutPage extends StatefulWidget {
  const AboutPage({super.key});

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  String _appVersion = '';
  bool _isExportingLog = false; // 运行日志导出中（拉起系统分享面板前禁用按钮+转圈）

  @override
  void initState() {
    super.initState();
    _loadAppVersion();
  }

  // --- 应用版本号 ---
  Future<void> _loadAppVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) {
        setState(() {
          _appVersion = info.version; // 例如 "1.0.6"
        });
      }
    } catch (e) {
      dev.log('读取版本号失败: $e');
      // 回退：使用 pubspec.yaml 中的硬编码版本号
      if (mounted) {
        setState(() {
          _appVersion = '1.6.0'; // 来自 pubspec.yaml version: 1.6.0+27
        });
      }
    }
  }

  /// 导出应用运行日志（日志已由 AppLogger 实时落盘，这里主要耗时在
  /// 拉起系统分享面板——用 loading 态兜底这段延迟）
  Future<void> _exportLog() async {
    if (_isExportingLog) return;
    setState(() => _isExportingLog = true);
    try {
      await AppLogger.exportAndShare();
    } catch (e) {
      dev.log('❌ 导出日志失败: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('导出日志失败: $e')));
      }
    } finally {
      if (mounted) setState(() => _isExportingLog = false);
    }
  }

  /// 打开 App 下载页（GitHub Releases）——用系统浏览器（externalApplication）
  Future<void> _openDownloadPage() async {
    const url = 'https://github.com/fantasyao/shengwuji/releases';
    try {
      final ok = await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
      if (!ok) {
        dev.log('⚠️ 打开下载页失败: launchUrl 返回 false');
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('打开失败，请手动访问: $url')));
        }
      }
    } catch (e) {
      dev.log('⚠️ 打开下载页失败: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('打开失败，请手动访问: $url')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ext = AppThemeExtension.of(context);
    return Scaffold(
      backgroundColor: ext.scaffoldBackground,
      appBar: AppBar(
        title: Text(
          "关于",
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 应用名称和版本号
                Row(
                  children: [
                    Icon(Icons.info_outline, color: ext.primary, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        "声物记",
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: ext.textPrimary,
                        ),
                      ),
                    ),
                    Text(
                      _appVersion.isNotEmpty ? "v$_appVersion" : "",
                      style: TextStyle(fontSize: 14, color: ext.textSecondary),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  "完全离线 · 无需联网",
                  style: TextStyle(fontSize: 12, color: ext.textSecondary),
                ),
                const SizedBox(height: 16),

                // 更新日志（可展开）
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: const EdgeInsets.only(top: 8),
                  dense: true,
                  title: Row(
                    children: [
                      Icon(Icons.history, color: ext.textSecondary, size: 18),
                      const SizedBox(width: 6),
                      Text(
                        "更新日志",
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: ext.textPrimary,
                        ),
                      ),
                    ],
                  ),
                  children: [
                    _buildChangelogItem(
                      version: "v1.6.0",
                      date: "2026-10-27",
                      changes: [
                        "【新功能】云同步升级为双向同步：笔记在电脑端改过 / 删过，同步回手机会跟着更新或删除，手机上的改动也会带到电脑",
                        "【新功能】截图存为笔记附件：悬浮窗长按卡片的复制按钮即可截屏存档（Android 11+），设置里可选「截图后展开笔记卡片」",
                        "【新功能】图片跨端同步：手机截图可同步到电脑，电脑端的多张图也能同步回手机；图集支持左右翻页、张数角标、单独删除本机截图",
                        "【新功能】语音搜索跳转：悬浮窗里说「搜索 + 关键词」自动用浏览器打开搜索并收起面板；触发词可在设置里改，随全量备份导入导出",
                        "【新功能】剪贴板一键存为笔记：悬浮窗新增「剪贴板」按钮，把刚复制的内容直接存成随手记，省掉新增 → 粘贴 → 保存三步；音量键手势可绑「剪贴板笔记」，按一下直接存、不用展开悬浮窗",
                        "【新功能】标签外观可自定义：紧急 / 收藏 / 灵感 / 待办 四个槽位，24 款精选图标 × 10 种颜色任选（新增「待办」标签）",
                        "【新功能】新增全局字体选项（霞鹜文楷 / 系统默认）",
                        "【新功能】随手记长文自动折叠：正文超过 5 行先折叠，点「展开」看全文，带高度动画",
                        "【新功能】正文里的网址可点：随手记与悬浮窗里的 http(s) 链接加下划线，点一下用浏览器打开",
                        "【体验优化】悬浮窗按钮位置可选「顶部 / 底部」：底部模式整块面板贴到屏幕下缘，单手更好够",
                        "【体验优化】悬浮窗面板新增语音速记录音按钮；「全部展开」会记住上次的选择，重开面板不再逐张点开",
                        "【体验优化】随手记与悬浮窗列表下拉即可同步云端，不用再进设置页点「立即同步」",
                        "【体验优化】云同步更省请求：内容没变不再重复上传；设置页显示最近 30 分钟的 WebDAV 请求数，避免撞上网盘限流",
                        "【体验优化】随手记筛选新增「普通」档（只看无标注笔记），标注档改为纯图标更省宽度；去掉「全部」按钮，再点一次当前筛选即取消",
                        "【体验优化】时间识别支持「21号 / 21日」这类月日说法，本月已过自动顺延到下个月",
                        "【体验优化】设置页新增「立即启动悬浮窗」按钮，桌面快捷方式新增「显示悬浮窗」（可供实体按键类 App 映射）",
                        "【体验优化】新增「功能说明」全量操作指南页，老用户也能随时查到最新说法；笔记锁定可整体关闭；新增「后台隐藏」开关，退后台不出现在多任务页、防误划清除",
                        "【体验优化】设置页一级页更清爽：外观 / 日记智能与交互 / 眼不见为净三组下沉到二级页",
                        "【修复】首次启动建库偶发失败后随手记永远停在「加载中」——现在会自动重建缺失的数据表",
                        "【修复】电脑端同步来的笔记在手机悬浮窗里不显示；补同步过来的旧笔记整批置顶，现按创建时间插进原有顺序",
                        "【修复】日历事件关掉响铃后系统日历显示「无提醒」、到点不弹通知（现已补上「开始时」提醒）；日历提醒弹层在小屏上显示不全",
                        "【修复】深色模式下大爆炸分词层仍是白底，夜间刺眼",
                      ],
                    ),
                    _buildChangelogItem(
                      version: "v1.5.0",
                      date: "2026-10-08",
                      changes: [
                        "【新功能】大爆炸分词：长按笔记正文把文字炸成词块，点选 / 滑动连选自由组合，可再炸成单字逐字微调，一键复制或搜索（搜索引擎与浏览器可在设置里选；交互设计借鉴自开源项目 BigBang_NovaText：https://github.com/CashewTeam/BigBang_NovaText）",
                        "【新功能】随手记标签筛选：按 ❗紧急 / ⭐收藏 / 💡灵感 筛选笔记",
                        "【新功能】悬浮窗长按拖动排序：按住卡片拖到想要的位置，主 App 与电脑访问同步跟随",
                        "【新功能】悬浮窗滑走可直接删除（设置里开启），删除后 3 秒内可撤销",
                        "【新功能】深色模式：可跟随系统或手动切换",
                        "【体验优化】随手记卡片手势：单击复制、双击编辑、长按大爆炸（可在设置交换单击与双击）",
                        "【体验优化】悬浮窗面板可调：字体大小五档、可见条数五档（条数越少顶部按钮越靠下，单手更好够）；贴边竖线距屏幕边缘间距可调，贴膜不再被遮",
                        "【体验优化】随手记卡片更紧凑，一屏能看更多笔记",
                        "【体验优化】退到后台自动释放识别引擎更省内存，回前台说话时自动加载",
                        "【体验优化】音量键设置页新增「无障碍保活指南」；给笔记加锁前会先检查是否设了锁屏密码",
                        "【修复】双击音量键占用后，抖音 / B站等 App 里按住音量键无法连续调音量",
                        "【修复】部分高分辨率机型悬浮窗把手不显示、点竖线后消失",
                        "【修复】悬浮窗隐藏后再召唤偶发只出现录音胶囊；「永久」档把手息屏解锁后消失",
                        "【修复】AI 应用选择首次授权后列表空白；悬浮窗 AI 按钮不认自定义添加的应用；识别没错时仍弹「听起来像热词」提示",
                      ],
                    ),
                    _buildChangelogItem(
                      version: "v1.4.0",
                      date: "2026-09-24",
                      changes: [
                        "【新功能】云同步来了（WebDAV）：支持坚果云等 WebDAV 网盘，一键同步笔记、物品、热词与修正对，可开启「同步录音文件」把语音一起备份上云；多台设备数据自动合并，有新数据待同步时会提示",
                        "【新功能】热词升级为音素匹配（灵感来自开源项目 CapsWriter）：按发音（而非文字）模糊比对，平翘舌、前后鼻音、n/l 等常见听错自动纠正；热词新增「正词 | 别名」写法；同一处修正满 3 次会主动提议加入热词",
                        "【新功能】音量键新增「按住说话」：像对讲机一样按住说话、松开自动停止并转写，不用再找屏幕按钮",
                        "【新功能】笔记锁定：单条笔记可上锁，正文打码防偷看，指纹或锁屏密码解锁，锁屏自动重新上锁",
                        "【新功能】AI 应用分享支持自定义：除内置应用外，可添加手机里任意已安装的 AI 应用（最多 3 个）",
                        "【体验优化】悬浮窗息屏自动隐藏：锁屏 / 息屏时钟（AOD）上不再残留把手，亮屏后原样恢复",
                        "【体验优化】音量键长按触发时长更好调：档位整体下调为 0.2 / 0.3 / 0.4 / 0.7 秒四档，还能自定义 50 毫秒～2 秒任意时长",
                        "【体验优化】悬浮窗卡片标注按钮提到时间行直接点，时间改横杠格式更省空间",
                        "【体验优化】修正对管理支持按命中次数、最近命中时间排序，排查高频识别错误更方便",
                        "【体验优化】「听起来像热词」提示更快消失，不再长时间停留",
                        "【界面】自定义主题（Pro）：色盘挑一个主色自动生成整套配色，背景、按钮、选中色还能单独微调",
                        "【界面】悬浮窗把手可自定义：大小三档（标准 / 小 / 迷你）+ 外观三套（双色药丸 / 蓝紫 / 拟物胶囊）",
                        "【界面】启动页焕新：全新「深海极光」渐变配色",
                        "【修复】备份导入后笔记重复、归档笔记复活",
                        "【修复】覆盖安装后首次启动偶发数据库报错",
                        "【修复】息屏时钟（AOD）状态按音量键无法调音量",
                        "【修复】12 小时制手机日历时间拨轮显示不全；日历写入失败时提示更具体",
                        "【修复】把手调小后部分区域点不灵；弹出指纹解锁时悬浮窗自动让位",
                      ],
                    ),
                    _buildChangelogItem(
                      version: "v1.3.0",
                      date: "2026-09-20",
                      changes: [
                        "全新「新拟物」主题：第 5 套皮肤——经典拟物灰底 + 轻盈立体光影，按钮、开关、输入框、底部导航全套凹凸质感（Pro 功能）",
                        "悬浮窗需要 Pro 解锁才能使用：未解锁时按音量键会震动并提示「暂未解锁」，可在设置页解锁或先免费试用 7 天",
                        "Pro 解锁方式升级为授权码：扫码付款后，把付款截图 + App 里显示的安卓 ID 发邮件给作者，收到授权码在 App 里输入即可（绑定手机）",
                        "旧版解锁方式已停用：旧版「点一下就解锁」的方式升级后失效，确已付款的用户可发邮件补发授权码",
                        "音量键长按触发时长可调：设置页新增 快(400毫秒) / 标准(500) / 慢(800) / 很慢(1200) 四档，默认仍是约 0.5 秒",
                        "录音中按一下音量键即可结束：设置页可开启「单击音量键停止录音」——录完点一下就停并转写，不用再长按；耳机线控 / 蓝牙耳机按键 / 相机键同样支持（与「按音量减保持静音」二选一）",
                        "体验优化与修复：设置页标题样式统一、识别修正页开关贴边与同音词示例修正等",
                      ],
                    ),
                    _buildChangelogItem(
                      version: "v1.2.0",
                      date: "2026-09-17",
                      changes: [
                        "电脑在线访问：同一 Wi-Fi 下，用电脑浏览器打开 App 里显示的网址，就能查看 / 编辑日记、回放录音",
                        "悬浮窗把手升级：收起后的竖条可以放在屏幕左边或右边，点一下 / 往里一滑就展开；长按把手支持上下拖动，挪到顺手的位置",
                        "录音更省心：说完话停一下就自动停止录音，不用再手动点",
                        "识别修正（未完成版）：修正对与同音词修复——把常识别错的词教给 App，以后自动改对",
                        "设置页重新整理：常用功能归类到二级页面，操作震感也更舒服",
                        "支持隐藏存物品页和查物品页",
                        "退出 App 时自动停止录音",
                        "新增「悬浮窗语音速记」快捷方式：适合有自定义按键（非滑动式）的手机——按一下弹出悬浮窗开始录音，再按一下停止",
                        "带滑动式按键的手机（如努比亚滑动键）：建议把按键映射到「快速录音」，上滑开始录音、滑回退出时自动停止",
                      ],
                    ),
                    _buildChangelogItem(
                      version: "v1.1.0",
                      date: "2026-09-06",
                      changes: [
                        "全新悬浮窗（闪念胶囊）：把闪念胶囊 1:1 搬进系统级悬浮窗，任意界面长按音量键即呼出——不用跳转 app、不打断当前操作，说完即走，收起后自动隐藏（Pro 功能）",
                        "悬浮窗语音定闹钟：点卡片闹钟按钮说「周六晚上八点提醒我去看电影」，自动识别时间，转轮确认后写入系统日历，到点响铃；「晚上八点」「两点半」等中文说法随口说也能识别",
                        "音量键唤醒悬浮窗：长按音量键唤出并自动展开最近笔记，显示中再按立即隐藏；音量键手势升级为长按 / 双击四槽位自定义",
                        "悬浮窗快速新建：面板顶部「+」一键新建笔记，自动弹起键盘进入编辑；点卡片展开全文直接编辑",
                        "悬浮窗卡片标注：紧急 / 收藏 / 灵感三种标注整卡换色，主 App 日记页同步显示色点",
                        "悬浮窗录音回放：语音速记卡片自带播放按钮，支持重放 / 暂停 / 继续",
                        "悬浮窗录音也支持临时静音：与快捷录音共用「按音量减保持静音」开关，录音期间按音量减，结束后继续保持静音",
                        "日历提醒确认更省心：时间可上下滑动微调、标题所见即所得，响铃开关可只建日历事件；缺权限时自动引导回主 App 授权，无通知权限自动改为仅日历提醒",
                        "悬浮窗语音速记录音上限 60 秒 → 5 分钟；悬浮窗记录与主 App 日记实时同步",
                        "语音转文字不再卡顿：转写挪到后台进行，转写期间刷列表、打字依旧流畅",
                        "备份导出 / 导入更稳更快：打包在后台完成不卡顿，等待期间 app 可正常使用，也修复了备份导入导出会报错的问题",
                        "Pro 解锁更贴心：扫码付款回来后点「已扫码，点击解锁」即可，不用再走付费入口",
                        "搬家模式语音播报更顺滑：播报在后台生成，边收边说不卡顿",
                        "闹钟到点即时提醒：响铃提示立即弹出，不再有可感知的等待",
                        "一批顺滑度优化：日记搜索更跟手、悬浮窗收展更流畅、拖动录音按钮更跟手，整体更省电",
                        "悬浮窗卡片支持左滑归档：往左一划就把笔记收进已归档（和日记页同款手势），已归档的再左滑直接删除；卡片上右滑仍可收起悬浮窗",
                      ],
                    ),
                    _buildChangelogItem(
                      version: "v1.0.17",
                      date: "2026-08-18",
                      changes: [
                        "日记页录音按钮支持上滑-快速新建文本笔记",
                        "设置页将『静音提示』开关与『按音量减保持静音』开关整合在一起",
                        "隐藏日记卡片底部未实现的爱心图标，等待后续功能完善",
                      ],
                    ),
                    _buildChangelogItem(
                      version: "v1.0.16",
                      date: "2026-08-12",
                      changes: [
                        "随手记 / 日记归档后可一键恢复（新增恢复入口）",
                        "日记卡片「单击 / 长按」交互支持自定义交换",
                        "接收系统分享：从其他 App 选文字分享到声物记，存为笔记",
                        "热词配置纳入全量备份 / 恢复",
                      ],
                    ),
                    _buildChangelogItem(
                      version: "v1.0.15",
                      date: "2026-08-07",
                      changes: [
                        "日记卡片改版：日期/时长移至顶部，补全年份与时分格式",
                        "播放按钮升级为带响度波纹的可拖动进度条（拖动跳转/暂停继续）",
                        "转写中按钮区禁用态；修复进度条游标『先走再跳回』与暂停后续播虚高",
                        "搬家模式智能分割失败提示改为可左滑消除的自绘提示条（含手动保存按钮）",
                      ],
                    ),
                    _buildChangelogItem(
                      version: "v1.0.14",
                      date: "2026-08",
                      changes: [
                        "主题系统改版（4 套皮肤预设 + Android 桌面图标包切换，Pro 功能）",
                        "搬家模式增强（语音播报 + 说『不对/撤销』语音撤销 + 屏幕常亮省电遮罩）",
                        "录音防丢失（先落盘再转写，失败可重新转写）",
                        "长录音自动分段，说太久也不丢内容",
                        "待办清单需以『代办/待办』开头才识别，正常说话不会误判",
                        "锁屏隐私保护与音量键键盘修复",
                        "物品列表浮动语音查询按钮",
                        "Pro 弹窗接入真实付款码",
                        "录入/日记页按钮钉底便于单手操作",
                        "修复窄屏卡片底部信息栏溢出",
                        "补齐霞鹜文楷字体 OFL 开源协议",
                      ],
                    ),
                    _buildChangelogItem(
                      version: "v1.0.13",
                      date: "2026-06",
                      changes: [
                        "日记一键转物品（浅橙横条转存按钮）",
                        "设置页新增 Pro 付费解锁弹窗（支持作者）",
                        "录音按钮样式统一",
                        "修复双击音量键键盘抖动",
                      ],
                    ),
                    _buildChangelogItem(
                      version: "v1.0.12",
                      date: "2026-06",
                      changes: [
                        "日记页语音查找物品：说\"游戏机在哪儿\"自动在卡片下方展示物品位置答案，多匹配显示+N 跳转列表",
                      ],
                    ),
                    _buildChangelogItem(
                      version: "v1.0.11",
                      date: "2026-06",
                      changes: ["日记页首次启动内置 7 条功能说明卡片"],
                    ),
                    _buildChangelogItem(
                      version: "v1.0.10",
                      date: "2026-06",
                      changes: ["应用改名「东西放哪儿了→声物记」，包名更新为 com.shengwuji.app"],
                    ),
                    _buildChangelogItem(
                      version: "v1.0.9",
                      date: "2026-06",
                      changes: ["清单合并到日记表(v8)、侧滑圆圈闭合动画、闹钟到点循环响铃、时间识别蓝色高亮设闹钟"],
                    ),
                    _buildChangelogItem(
                      version: "v1.0.8",
                      date: "2026-06",
                      changes: ["清单功能迁移到日记页，新增子弹列表展示"],
                    ),
                    _buildChangelogItem(
                      version: "v1.0.7",
                      date: "2026-06",
                      changes: ["设置页新增版本更新日志、启动页权限说明、录音按钮调优"],
                    ),
                    _buildChangelogItem(
                      version: "v1.0.6",
                      date: "2026-06",
                      changes: ["震感改为原生 VibrationEffect API 驱动线性马达"],
                    ),
                    _buildChangelogItem(
                      version: "v1.0.5",
                      date: "2026-06",
                      changes: ["日记页震感替换为系统 HapticFeedback"],
                    ),
                    _buildChangelogItem(
                      version: "v1.0.4",
                      date: "2026-06",
                      changes: ["启动页去掉模型加载，恢复延迟加载模式"],
                    ),
                    _buildChangelogItem(
                      version: "v1.0.3",
                      date: "2026-06",
                      changes: ["修复快捷方式进入时录音卡死不转写的问题"],
                    ),
                    _buildChangelogItem(
                      version: "v1.0.2",
                      date: "2026-05",
                      changes: ["归档系统、侧滑归档/删除"],
                    ),
                    _buildChangelogItem(
                      version: "v1.0.1",
                      date: "2026-05",
                      changes: ["日记导出为 Markdown"],
                    ),
                    _buildChangelogItem(
                      version: "v1.0.0",
                      date: "2026-05",
                      changes: ["初始版本，支持离线语音识别"],
                      isLast: true,
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                _buildTextBtn(
                  '导出运行日志',
                  Icons.bug_report,
                  _exportLog,
                  busy: _isExportingLog,
                ),
                const SizedBox(height: 8),
                _buildTextBtn(
                  'App 下载地址（GitHub Releases）',
                  Icons.download,
                  _openDownloadPage,
                ),
                const SizedBox(height: 8),
                _buildTextBtn(
                  '开放源代码许可',
                  Icons.description,
                  () => showLicensePage(
                    context: context,
                    applicationName: '声物记',
                    applicationVersion: _appVersion.isNotEmpty
                        ? 'v$_appVersion'
                        : null,
                    applicationLegalese: '© 2026 声物记',
                    applicationIcon: Padding(
                      padding: const EdgeInsets.all(10),
                      child: Image.asset(
                        'assets/icon/app_icon.png',
                        width: 48,
                        height: 48,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 更新日志单条目组件（原 settings_tab._buildChangelogItem 原样搬入）
  Widget _buildChangelogItem({
    required String version,
    required String date,
    required List<String> changes,
    bool isLast = false,
  }) {
    final ext = AppThemeExtension.of(context);
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 时间线竖线 + 圆点
          SizedBox(
            width: 24,
            child: Column(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: ext.primary,
                    shape: BoxShape.circle,
                  ),
                ),
                if (!isLast)
                  Expanded(
                    child: Container(
                      width: 2,
                      color: ext.primary.withValues(alpha: 0.2),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          // 内容区域
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: isLast ? 0 : 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        version,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: ext.primary,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        date,
                        style: TextStyle(fontSize: 11, color: ext.textHint),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (int i = 0; i < changes.length; i++) ...[
                        if (i > 0) const SizedBox(height: 4),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(top: 7),
                              child: Container(
                                width: 4,
                                height: 4,
                                decoration: BoxDecoration(
                                  color: ext.textSecondary,
                                  shape: BoxShape.circle,
                                ),
                              ),
                            ),
                            const SizedBox(width: 7),
                            Expanded(
                              child: Text(
                                changes[i],
                                style: TextStyle(
                                  fontSize: 13,
                                  color: ext.textSecondary,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTextBtn(
    String label,
    IconData icon,
    VoidCallback? onPressed, {
    bool busy = false,
  }) {
    return TextButton.icon(
      onPressed: busy ? null : onPressed,
      icon: busy
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(icon, size: 16),
      label: Text(label, style: const TextStyle(fontSize: 13)),
    );
  }
}
