/// 主界面底部导航 Tab 的可见性配置（设置页「功能页面」两个隐藏开关）。
///
/// 设计约束：
/// - 重启生效：main() 预读 prefs → AppRoot 静态字段 → MainScaffold 构造参数，
///   进程生命周期内不变（无跨页热更新通道）
/// - 隐藏页不挂载 IndexedStack：对应 GlobalKey 无 state，main.dart 所有
///   读取点均已 null 安全或按可见栈分发后不可达
/// - 随手记/设置不可隐藏：桌面快捷方式、系统分享、音量键、悬浮窗等
///   外部入口全部跳日记页（语义索引 2），设置页是开关自身的宿主页
library;

/// 语义索引：存物品页（RecordTab，语音录入物品，含搬家模式）
const int tabIndexRecord = 0;

/// 语义索引：查物品页（ListTab，物品位置列表）
const int tabIndexList = 1;

/// 语义索引：随手记（DiaryTab）
const int tabIndexDiary = 2;

/// 语义索引：设置（SettingsTab）
const int tabIndexSettings = 3;

/// prefs key：隐藏存物品页（设置页写入，main.dart main() 预读同一 key；默认 false=显示）
const String prefKeyRecordTabHidden = 'record_tab_hidden';

/// prefs key：隐藏查物品页（同上）
const String prefKeyListTabHidden = 'list_tab_hidden';

/// 由两个隐藏开关推导可见 Tab 的语义索引栈（IndexedStack children 与
/// 底部导航 items 按此装配）。
///
/// 隐藏页不占位、其余相对顺序不变；随手记/设置恒在，
/// 返回至少 [tabIndexDiary, tabIndexSettings]。
List<int> visibleTabStack({
  bool recordTabHidden = false,
  bool listTabHidden = false,
}) => [
  if (!recordTabHidden) tabIndexRecord,
  if (!listTabHidden) tabIndexList,
  tabIndexDiary,
  tabIndexSettings,
];
