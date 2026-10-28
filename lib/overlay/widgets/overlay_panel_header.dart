import 'package:flutter/material.dart';

/// 展开面板按钮条（OverlayHome._buildPanel 的 header；默认在列表上方，
/// 设置页「按钮位置」可切到列表下方）
///
/// 深色半透明工具条：黑 72% 半透明底 + 白图标，与录音胶囊/停止提示胶囊
/// 同视觉家族。为什么自带深色底——悬浮窗面板背景透明，垫在任意应用/壁纸
/// 上，此前主题浅灰图标（ext.textHint）裸放在白色背景的应用上会看不清
/// （2026-09-13 用户实测反馈）；自带深色底才有跨背景的对比度保障（白图标
/// 对黑 72% 底，即使垫纯白背景等效底色也接近 #4a4a4a，对比度 ≈ 8:1）。
/// 这也是闪念原型里「黑色半透明工具条」设计的正式落地（早前被降级为裸图标）。
///
/// 纯渲染组件：交互回调全部上抛；停靠侧镜像（贴停靠缘对齐、阴影投射方向）
/// 与条件渲染（空列表不渲染全部展开）由参数驱动；模块自身不关心在列表
/// 上方还是下方（位置由 OverlayHome 的 Column 顺序决定）。
/// 按钮从停靠缘向外依次：新增笔记 / 剪贴板存为笔记 / 全部展开·收起
///（空列表不渲染）/ 打开随手记 / 语音速记录音（麦克风图标，2026-10-19 起
/// 替代原收起 chevron——收起面板由空白区点击/滑动承担）。
class OverlayPanelHeader extends StatelessWidget {
  const OverlayPanelHeader({
    super.key,
    required this.dockLeft,
    required this.diariesNotEmpty,
    required this.allExpanded,
    required this.onNewNote,
    required this.onSaveClipboard,
    required this.onToggleExpandAll,
    required this.onOpenDiaryPage,
    required this.onStartVoiceMemo,
  });

  /// 停靠侧：false（默认）= 屏幕右缘（历史行为），true = 左缘。
  /// 工具条贴停靠缘对齐、阴影朝屏幕内侧投射随侧镜像
  final bool dockLeft;

  /// 日记列表非空才渲染「全部展开/收起」按钮（空列表无意义，历史行为）
  final bool diariesNotEmpty;

  /// 当前是否全部展开（true = unfold_less「全部收起」，false = unfold_more）
  final bool allExpanded;

  final VoidCallback onNewNote;

  /// 剪贴板存为笔记：读系统剪贴板最后一条文本直接落库（2026-10-27），
  /// 省掉「新增→粘贴→保存」三步（用户诉求）。空剪贴板/读取失败由调用方 Toast
  final VoidCallback onSaveClipboard;

  final VoidCallback onToggleExpandAll;
  final VoidCallback onOpenDiaryPage;

  /// 语音速记录音按钮（2026-10-19 起替代原「收起」chevron——收起面板改由
  /// 空白区点击/滑动承担，见 floating-window.md「展开面板视觉」）：点击经
  /// 原生通道走音量键「悬浮窗录音」同一 triggerVoiceMemoOverlay 链路开录，
  /// 窗口随状态机 resize 成随时间变长的录音胶囊
  final VoidCallback onStartVoiceMemo;

  @override
  Widget build(BuildContext context) {
    return Align(
      // 工具条贴停靠缘（Row.min 收缩到内容宽，Align 决定贴哪侧——
      // 与录音胶囊 Align.centerRight/centerLeft 同款镜像规则）
      alignment: dockLeft ? Alignment.centerLeft : Alignment.centerRight,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        decoration: BoxDecoration(
          // 与录音胶囊/停止提示胶囊同款黑 72% 半透明底（跨背景对比度见类文档）
          color: Colors.black.withValues(alpha: 0.72),
          // 圆角 24 超过半高（IconButton compact 高约 40）时 Skia 自动缩到
          // 半高 = 全圆角工具条，系统字体放大变高也保持两端圆头
          //（同 _StopHintPill 的圆角技巧）
          borderRadius: BorderRadius.circular(24),
          // 家族阴影（不透明实体可画 boxShadow，透明窗口背景不能画的教训
          // 不适用于本实体）：朝屏幕内侧投射、背离停靠缘，随侧镜像
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.22),
              blurRadius: 8,
              offset: Offset(dockLeft ? 2 : -2, 0),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              onPressed: onNewNote,
              icon: const Icon(Icons.add, color: Colors.white),
              tooltip: '新增笔记',
              visualDensity: VisualDensity.compact,
            ),
            // 剪贴板存为笔记（2026-10-27 用户需求）：紧挨「新增」右侧，一键把
            // 剪贴板最后一条文本直接存成笔记，省掉新增→粘贴→保存三步
            IconButton(
              onPressed: onSaveClipboard,
              icon: const Icon(Icons.content_paste, color: Colors.white),
              tooltip: '剪贴板存为笔记',
              visualDensity: VisualDensity.compact,
            ),
            // 全部展开/收起按钮（「打开随手记」按钮左侧；空列表不渲染）
            if (diariesNotEmpty)
              IconButton(
                onPressed: onToggleExpandAll,
                icon: Icon(
                  allExpanded ? Icons.unfold_less : Icons.unfold_more,
                  color: Colors.white,
                ),
                tooltip: allExpanded ? '全部收起' : '全部展开',
                visualDensity: VisualDensity.compact,
              ),
            // 打开主 App 随手记按钮（收起按钮左侧）：悬浮窗跳回主 App 日记页
            // 的唯一入口。图标与主 App 底部导航「随手记」同款（Icons.book），
            // 落地页即该 tab——同图标同词汇降低认知成本
            IconButton(
              onPressed: onOpenDiaryPage,
              icon: const Icon(Icons.book, color: Colors.white),
              tooltip: '打开随手记',
              visualDensity: VisualDensity.compact,
            ),
            // 语音速记录音按钮（工具条末位，原收起 chevron 位置）：麦克风图标。
            // 点击开始录音，面板窗口随即切换为随时间变长的录音胶囊
            IconButton(
              onPressed: onStartVoiceMemo,
              icon: const Icon(Icons.mic, color: Colors.white),
              tooltip: '语音速记',
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
      ),
    );
  }
}
