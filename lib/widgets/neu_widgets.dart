/// 新拟物（Neumorphism）组件库——仅在第 5 套「新拟物」主题下使用
///
/// ⚠️ 非拟物主题不要引用本文件的组件/装饰：阴影色槽（neuShadowDark/Light）
/// 在旧主题下只是占位值，画出来不是拟物效果。调用方应先判
/// `AppThemeExtension.of(context).isNeumorphic` 再分支。
///
/// 视觉规范（2026-09-17 预览拍板）：
/// - 底色与页面同色（scaffoldBackground == cardBackground == #E0E5EC）
/// - 轻盈档阴影：凸起外 4px/blur8 双向（暗右下+亮左上），凹陷以渐变近似 2px/blur4
/// - 圆角档：24 搜索框 · 18 卡片/大按钮 · 12 小按钮
/// - 主 CTA 纯同色凸起 + 品牌青文字（不用彩色渐变底）
/// - 开关：凹槽轨道 + 凸起滑块，选中轨道染品牌青
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme_extension.dart';

/// 凸起装饰：双向外阴影（暗色右下投影 + 亮色左上高光）
BoxDecoration neuRaisedDecoration(
  BuildContext context, {
  double radius = 18,
  double offset = 4,
  double blur = 8,
}) {
  final ext = AppThemeExtension.of(context);
  return BoxDecoration(
    color: ext.cardBackground,
    borderRadius: BorderRadius.circular(radius),
    boxShadow: [
      BoxShadow(
        color: ext.neuShadowDark,
        offset: Offset(offset, offset),
        blurRadius: blur,
      ),
      BoxShadow(
        color: ext.neuShadowLight,
        offset: Offset(-offset, -offset),
        blurRadius: blur,
      ),
    ],
  );
}

/// 凹陷容器（常驻）：底色 + 双轴渐变内晕影（与 [NeuSwitch] 同款 painter，
/// 引擎无关）
///
/// 边缘暗/亮晕影 ~8px 渐隐、中段全透明，无实色壳、无硬边；child 浮在
/// 晕影之上（CSS 层序：inset 阴影画在 background 上、content 下）。
/// 用于输入框、搜索框等常驻凹陷大件。
///
/// ⚠️ 三层实色壳方案已废弃（2026-09-19 用户真机反馈输入框/搜索框「边缘
/// 阴影不对、有分界」）：壳层是中性实色，与底色是像素级硬分界、无渐变
/// 过渡，与开关同病；对角单渐变版顶/底边整条是空的。勿回退，见
/// [_InsetShadowPainter] doc 三轮教训。
class NeuInset extends StatelessWidget {
  final Widget child;

  final double radius;

  final EdgeInsetsGeometry? padding;

  const NeuInset({
    super.key,
    required this.child,
    this.radius = 18,
    this.padding,
  });

  @override
  Widget build(BuildContext context) {
    final ext = AppThemeExtension.of(context);
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        color: ext.cardBackground,
      ),
        child: CustomPaint(
          painter: _InsetShadowPainter(
            radius: radius,
            dark: ext.neuShadowDark.withValues(alpha: 0.9),
            light: ext.neuShadowLight.withValues(alpha: 0.9),
          ),
          child: padding == null
              ? child
              : Padding(padding: padding!, child: child),
        ),
    );
  }
}

/// 拟物语音圆钮：与背景同色的凸起圆 + 中心状态内容（无凹环）
///
/// 2026-09-18 用户定稿：三处语音按钮（随手记浮动钮/查物品浮动钮/存物品
/// 钉底栏圆钮）为「灰底凸起 + 中心图标直接落在凸面上」的无坑版；状态语义
/// （就绪青/录音红/处理橙/禁用灰）由中心图标颜色表达，底色不随状态变化。
/// 中心内容颜色由调用方按状态传入；手势由调用方在外层包 GestureDetector。
/// 曾试过中心凹环版（insetRing=true），真机对比后全量定稿无环。
class NeuVoiceFab extends StatelessWidget {
  final double size;

  final Widget child;

  /// true 回退到「凸起底 + 凹陷圆环」的历史方案（环径 0.68×size）
  final bool insetRing;

  const NeuVoiceFab({
    super.key,
    required this.size,
    required this.child,
    this.insetRing = false,
  });

  @override
  Widget build(BuildContext context) {
    final ext = AppThemeExtension.of(context);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: ext.cardBackground,
        boxShadow: [
          BoxShadow(
            color: ext.neuShadowDark,
            offset: const Offset(4, 4),
            blurRadius: 8,
          ),
          BoxShadow(
            color: ext.neuShadowLight,
            offset: const Offset(-4, -4),
            blurRadius: 8,
          ),
        ],
      ),
      child: Center(
        // 凹环（历史方案）：圆形凹陷，圆角半径=环径一半时圆角矩形即正圆
        child: insetRing
            ? SizedBox(
                width: size * 0.68,
                height: size * 0.68,
                child: NeuInset(
                  radius: size * 0.34,
                  child: Center(child: child),
                ),
              )
            : child,
      ),
    );
  }
}

/// 拟物开关行：凹槽开关在左 + 标题/副标题在右（替代 SwitchListTile）
///
/// 与项目既有 SwitchListTile（controlAffinity.leading + dense）等价的拟物
/// 形态。仅拟物主题使用，调用方一般经 settings_widgets.buildSettingsSwitchTile
/// 分流，不直接判主题。
class NeuSwitchTile extends StatelessWidget {
  final Widget title;

  final Widget? subtitle;

  final bool value;

  final ValueChanged<bool>? onChanged;

  const NeuSwitchTile({
    super.key,
    required this.title,
    this.subtitle,
    required this.value,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          NeuSwitch(value: value, onChanged: onChanged),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                title,
                if (subtitle != null) ...[const SizedBox(height: 2), subtitle!],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 可按压的拟物容器：静止凸起，按住转凹陷
///
/// 用于入口行、次级按钮等「轻操作」；主 CTA 若需要强调可在外部包同款。
/// 按压反馈即时切换（外阴影消失+凹晕影浮现）：凹凸跨 decoration/结构，
/// 隐式动画无法插值且跨引擎行为不稳，即时切换更跟手（同 NeuSwitch 底色）。
class NeuPressable extends StatefulWidget {
  final Widget child;

  /// 点击回调；null 时仍保留按压视觉（用于整卡可点但行为在子节点的场景）
  final VoidCallback? onTap;

  final double radius;

  final EdgeInsetsGeometry? padding;

  const NeuPressable({
    super.key,
    required this.child,
    this.onTap,
    this.radius = 18,
    this.padding,
  });

  @override
  State<NeuPressable> createState() => _NeuPressableState();
}

class _NeuPressableState extends State<NeuPressable> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final ext = AppThemeExtension.of(context);
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: widget.onTap,
      child: Container(
        decoration: BoxDecoration(
          color: ext.cardBackground,
          borderRadius: BorderRadius.circular(widget.radius),
          // 按下时凸起外阴影消失，凹晕影由下层 painter 浮现
          boxShadow: _pressed
              ? const []
              : [
                  BoxShadow(
                    color: ext.neuShadowDark,
                    offset: const Offset(4, 4),
                    blurRadius: 8,
                  ),
                  BoxShadow(
                    color: ext.neuShadowLight,
                    offset: const Offset(-4, -4),
                    blurRadius: 8,
                  ),
                ],
        ),
        child: CustomPaint(
          painter: !_pressed
              ? null
              : _InsetShadowPainter(
                  radius: widget.radius,
                  dark: ext.neuShadowDark.withValues(alpha: 0.9),
                  light: ext.neuShadowLight.withValues(alpha: 0.9),
                ),
          child: widget.padding == null
              ? widget.child
              : Padding(padding: widget.padding!, child: widget.child),
        ),
      ),
    );
  }
}

/// 拟物凸起卡片（无按压交互的静态容器）
class NeuCard extends StatelessWidget {
  final Widget child;

  final double radius;

  final EdgeInsetsGeometry? padding;

  const NeuCard({super.key, required this.child, this.radius = 18, this.padding});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: neuRaisedDecoration(context, radius: radius),
      padding: padding,
      child: child,
    );
  }
}

/// CSS `inset box-shadow` 的双轴渐变 + 角部径向带近似（四边+四角晕影，引擎无关）
///
/// 中央十字区两条轴向对称渐变（边缘最浓 → ~8px 渐隐 → 中段全透明），
/// 四角各一条径向带补弧（轴带按「到矩形边距离」衰减，角部弧内收会断；
/// 径向按「到圆心距离」衰减，交界连续、沿弧均匀）。两层半透明直接
/// srcOver 叠在底色上，底色/染色不被罩色。
///
/// ⚠️ 三轮教训（2026-09-18，均为真机反馈）：①NeuInset 实色壳=中性硬边；
/// ②对角单渐变=只有两个角部有明暗，顶/底边整条是空的（"像平面"）；
/// ③canvas blur 挖洞（铺满阴影色 + BlendMode.clear/dstOut + MaskFilter，
/// 即 flutter_neumorphic 同款技巧）**依赖 blendMode+maskFilter 组合，真机
/// Impeller 上行为与模拟器不一致**——挖洞失效时阴影色整面罩在底色上：
/// 关闭态阴影消失、开启态绿被冲成泛白青（"#59fff6"）。本版只用
/// LinearGradient+clipRRect 基础原语，全引擎渲染一致；中段强制全透明，
/// 底色/染色不被罩色，边缘浓度所见即所得。
///
/// 层序与 CSS 一致：本 painter 画在 child 之下——child 应是需要浮在
/// 内阴影上的内容（如开关滑块）；纯底加内阴影时 child 传空盒即可。
class _InsetShadowPainter extends CustomPainter {
  _InsetShadowPainter({required this.radius, required this.dark, required this.light});

  final double radius;

  /// 左上暗晕色（CSS `inset +offset` 的阴影色，含 alpha=边缘浓度）
  final Color dark;

  /// 右下亮晕色（CSS `inset -offset` 的高光色，含 alpha=边缘浓度）
  final Color light;

  @override
  void paint(Canvas canvas, Size size) {
    final base = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(radius),
    );
    canvas.clipRRect(base);
    final w = size.width;
    final h = size.height;
    // 胶囊写法（radius 999）按短边一半归一
    final r = radius.clamp(0.0, math.min(w, h) / 2);
    const band = 8.0;
    if (r <= band) {
      // 圆角过小（角部弧太短）退化为整幅双轴，角部占比可忽略
      final rect = Offset.zero & size;
      _axisBand(
        canvas,
        rect,
        dark,
        light,
        vertical: true,
        extent: h,
        band: band,
      );
      _axisBand(
        canvas,
        rect,
        dark,
        light,
        vertical: false,
        extent: w,
        band: band,
      );
      return;
    }
    // ⚠️ 角部必须用径向带补：轴向渐变按「到矩形边的距离」衰减，而圆角
    // 处轮廓内收、弧内区域距两条边都变远 → 角部晕影断裂，观感「像有个
    // 矩形白块盖住阴影」（2026-09-19 真机反馈搜索框）。径向带按「到圆角
    // 圆心距离」衰减：交界线上（x=r 竖线 / y=r 横线）径向距离恰等于轴
    // 向距离，两带公式一致 → 像素级连续；弧上 dist=r 恒定 → 沿弧均匀。
    // 中央竖条：顶暗/底亮带
    final vRect = Rect.fromLTWH(r, 0, w - 2 * r, h);
    canvas.save();
    canvas.clipRect(vRect);
    canvas.drawRect(
      vRect,
      Paint()
        ..shader = _axisGradient(
          dark,
          light,
          vertical: true,
          extent: h,
          band: band,
        ).createShader(vRect),
    );
    canvas.restore();
    // 中央横条：左暗/右亮带
    final hRect = Rect.fromLTWH(0, r, w, h - 2 * r);
    canvas.save();
    canvas.clipRect(hRect);
    canvas.drawRect(
      hRect,
      Paint()
        ..shader = _axisGradient(
          dark,
          light,
          vertical: false,
          extent: w,
          band: band,
        ).createShader(hRect),
    );
    canvas.restore();
    // 四角晕影带 = 相邻两条直边晕影在弧区的平滑过渡（CSS inset 双层阴影的
    // 真实行为：每条边「直着」延伸，弧区颜色沿弧从起始边插值到终止边）。
    // 2026-09-19 用户真机反馈定稿：整弧单色（左上/右上=暗、右下/左下=亮）
    // 会在弧端与直边交界处突变出「明显分界」（右上弧暗 vs 右直边亮、左下
    // 弧亮 vs 左直边暗），必须沿弧插值。
    // ⚠️ 勿改回：①整角 50% 混色——中性灰白段夹在暗亮带间，「像被模糊
    // 东西挡住」；②SweepGradient 沿弧变色+dstOut 径向衰减——saveLayer 内
    // Sweep 在本机/真机渲染相位异常（竖向分界），已从本机 golden 复现后
    // 回退。现方案 = 扇形细分成 12 片楔子逐片 RadialGradient（纯基础
    // 原语），径向几何与单色版完全一致、仅颜色沿弧 lerp。
    _cornerBand(
      canvas,
      Offset(r, r),
      r,
      band,
      startAngle: -math.pi / 2,
      sweepAngle: -math.pi / 2,
      startColor: dark,
      endColor: dark,
    );
    _cornerBand(
      canvas,
      Offset(w - r, r),
      r,
      band,
      startAngle: -math.pi / 2,
      sweepAngle: math.pi / 2,
      startColor: dark,
      endColor: light,
    );
    _cornerBand(
      canvas,
      Offset(w - r, h - r),
      r,
      band,
      startAngle: 0,
      sweepAngle: math.pi / 2,
      startColor: light,
      endColor: light,
    );
    _cornerBand(
      canvas,
      Offset(r, h - r),
      r,
      band,
      startAngle: math.pi / 2,
      sweepAngle: math.pi / 2,
      startColor: light,
      endColor: dark,
    );
  }

  /// 单轴对称晕影带（clip 区域内绘制）：两端最浓 → band px 渐隐 → 中段全透明
  LinearGradient _axisGradient(
    Color dark,
    Color light, {
    required bool vertical,
    required double extent,
    required double band,
  }) {
    final b = (band / extent).clamp(0.0, 0.45);
    final transparentDark = dark.withValues(alpha: 0);
    final transparentLight = light.withValues(alpha: 0);
    return LinearGradient(
      begin: vertical ? Alignment.topCenter : Alignment.centerLeft,
      end: vertical ? Alignment.bottomCenter : Alignment.centerRight,
      colors: [
        dark,
        dark.withValues(alpha: dark.a * 0.45),
        transparentDark,
        transparentLight,
        light.withValues(alpha: light.a * 0.45),
        light,
      ],
      stops: [0.0, b * 0.4, b, 1 - b, 1 - b * 0.4, 1.0],
    );
  }

  void _axisBand(
    Canvas canvas,
    Rect rect,
    Color dark,
    Color light, {
    required bool vertical,
    required double extent,
    required double band,
  }) {
    canvas.drawRect(
      rect,
      Paint()
        ..shader = _axisGradient(
          dark,
          light,
          vertical: vertical,
          extent: extent,
          band: band,
        ).createShader(rect),
    );
  }

  /// 角部径向晕影带：轮廓弧（dist=r）最浓 → 向内 band px 渐隐 → 内芯透明，
  /// 弧上 dist 恒定故沿弧均匀。颜色沿弧从 [startColor]（起始直边端的延续）
  /// 插值到 [endColor]：90° 扇形细分成 12 片楔子，每片独立 clipPath +
  /// RadialGradient——12 片中点取色，相邻色差 ~1/12 全程差，肉眼连续且
  /// 无放射缝（缝若可见只会露出底色、非杂色）。shader 坐标系取圆的外接
  /// 正方形（fromCircle(center, r)）：Alignment.center 即圆心、radius 0.5
  /// = 0.5×2r = 圆角半径。纯基础原语，无 blendMode/无 saveLayer。
  void _cornerBand(
    Canvas canvas,
    Offset center,
    double r,
    double band, {
    required double startAngle,
    required double sweepAngle,
    required Color startColor,
    required Color endColor,
  }) {
    const slices = 12;
    final inner = (r - band) / r;
    final square = Rect.fromCircle(center: center, radius: r);
    for (var i = 0; i < slices; i++) {
      final color = Color.lerp(
        startColor,
        endColor,
        (i + 0.5) / slices,
      )!;
      final wedge =
          Path()
            ..moveTo(center.dx, center.dy)
            ..arcTo(
              square,
              startAngle + sweepAngle * (i / slices),
              sweepAngle / slices,
              false,
            )
            ..close();
      canvas.save();
      canvas.clipPath(wedge);
      canvas.drawRect(
        square,
        Paint()
          ..shader = RadialGradient(
            center: Alignment.center,
            radius: 0.5,
            colors: [
              color.withValues(alpha: 0),
              color.withValues(alpha: color.a * 0.45),
              color,
            ],
            stops: [inner, inner + (1 - inner) * 0.4, 1.0],
          ).createShader(square),
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_InsetShadowPainter oldDelegate) =>
      oldDelegate.radius != radius ||
      oldDelegate.dark != dark ||
      oldDelegate.light != light;
}

/// 拟物开关：凹槽轨道 + 凸起滑块，选中轨道染品牌青
///
/// 轨道 46×26，滑块 22（margin 2，四周 2px 同心间隙：半径 11+2=端弧 13，
/// 圆心重合、贴合紧密，与设计图/HTML 原版参数一致）。仅拟物主题使用。
/// [onChanged] 为 null 时禁用（降透明度、不响应点击），与 M3 Switch 语义一致。
///
/// ⚠️ 凹槽内阴影必须用 [_InsetShadowPainter]（双轴渐变、引擎无关），结构
/// 与 CSS 同构：Container 画底色（选中=CSS 背景渐变
/// 145deg #00A896→#00806F；未选中=底色压暗一档，坑底比白滑块暗）
/// → 内阴影（暗=顶+左、亮=底+右）→ 滑块浮在最上（CSS 层序）。
/// 颜色即时切换、滑块 200ms 滑动（见 build 内注释）。
/// 勿回退的三轮废弃方案见 [_InsetShadowPainter] doc（实色壳硬边 / 对角
/// 单渐变角部-only / canvas blur 挖洞真机 Impeller 上挖洞失效→泛白）。
class NeuSwitch extends StatelessWidget {
  final bool value;

  final ValueChanged<bool>? onChanged;

  const NeuSwitch({super.key, required this.value, this.onChanged});

  @override
  Widget build(BuildContext context) {
    final ext = AppThemeExtension.of(context);
    final bg = ext.cardBackground;
    final enabled = onChanged != null;
    // 内阴影端点浓度（=CSS 阴影色 alpha）：选中照抄设计图 CSS
    // rgba(0,60,52,.45) / rgba(255,255,255,.35) 半透明叠绿；
    // 未选中用主题暗/亮槽（neumorphism.io 配套设计值）
    final shadowDark = value
        ? const Color(0x73003C34)
        : ext.neuShadowDark.withValues(alpha: 0.9);
    final shadowLight = value
        ? const Color(0x59FFFFFF)
        : ext.neuShadowLight.withValues(alpha: 0.9);
    return GestureDetector(
      onTap: enabled ? () => onChanged!(!value) : null,
      child: Opacity(
        opacity: enabled ? 1.0 : 0.45,
        child: SizedBox(
          width: 46,
          height: 26,
          // 底色/内阴影即时切换（普通 Container，无隐式动画）：iOS 原生
          // 开关同款——颜色点下去立刻到位，只有滑块保留 200ms 滑动。
          // ⚠️ 此前底色用 AnimatedContainer 200ms：未选中=纯色、选中=
          // 渐变，Flutter 对 color↔gradient 插值走「旧色渐隐+新色半透明
          // 渐入」路径，中间长期停在灰绿混合态，真机上再叠加整页重建/
          // shader 编译卡顿，观感「缓一秒才变成真正的绿」（2026-09-19
          // 真机反馈）。勿给底色加回隐式动画。
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(13),
              // 未选中凹槽底压暗一档（用户对照设计图：坑底要比白滑块
              // 暗一档才读得出「坑里有圆钮」，纯同色会粘连成平面）
              color: value
                  ? null
                  : Color.alphaBlend(
                      ext.neuShadowDark.withValues(alpha: 0.18),
                      bg,
                    ),
              gradient: value
                  ? const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Color(0xFF00A896), Color(0xFF00806F)],
                    )
                  : null,
            ),
            child: CustomPaint(
              painter: _InsetShadowPainter(
                radius: 13,
                dark: shadowDark,
                light: shadowLight,
              ),
              child: AnimatedAlign(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOutCubic,
                alignment: value
                    ? Alignment.centerRight
                    : Alignment.centerLeft,
                child: Container(
                  width: 22,
                  height: 22,
                  // 滑块比轨道小一圈：胶囊端弧半径 13，滑块半径 11 +
                  // margin 2 → 圆心与端弧圆心重合，四周 2px 同心间隙沿弧
                  // 均匀（2026-09-18 用户对照设计图定稿：贴合紧密；间隙
                  // 沿弧均匀才和谐，染色青从间隙透出一圈光环）
                  margin: const EdgeInsets.all(2),
                  key: const Key('neu_switch_thumb'),
                  decoration: BoxDecoration(
                    color: bg,
                    shape: BoxShape.circle,
                    // 照抄 HTML 原版滑块阴影：2px 2px 5px 黑.28 +
                    // -1px -1px 3px 亮色（光从左上来，投影在右下）
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0x47000000),
                        offset: const Offset(2, 2),
                        blurRadius: 2.5,
                      ),
                      BoxShadow(
                        color: ext.neuShadowLight,
                        offset: const Offset(-1, -1),
                        blurRadius: 1.5,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
