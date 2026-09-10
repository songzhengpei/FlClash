class AppChangelogEntry {
  const AppChangelogEntry({
    required this.version,
    required this.date,
    required this.changes,
  });

  final String version;
  final String date;
  final List<String> changes;
}

const appChangelogEntries = <AppChangelogEntry>[
  AppChangelogEntry(
    version: 'v2.2.1',
    date: '2026-09-10',
    changes: ["修复网络、DNS、自定义规则等设置未正确生效的问题；优化仪表盘延迟数值显示，避免文字拥挤或裁切。"],
  ),
  AppChangelogEntry(
    version: 'v2.2.0',
    date: '2026-09-09',
    changes: ["优化大量订阅下代理界面卡顿问题", "整理了一些启动链路上的时序问题"],
  ),
  AppChangelogEntry(
    version: 'v2.1.9',
    date: '2026-09-07',
    changes: ['降低订阅同步内存占用', '优化代理被回收后的恢复'],
  ),
  AppChangelogEntry(
    version: 'v2.1.8',
    date: '2026-09-07',
    changes: ["提升代理留存能力，优化后台低内存回收"],
  ),
  AppChangelogEntry(
    version: 'v2.1.5',
    date: '2026-09-02',
    changes: [
      "优化代理页超长节点名称显示，卡片折叠展开滚动动画，节点卡片长按显示叶子节点全称",
      "修复双开、分身应用网络受限",
      "更新版本号",
      "优化应用内更新检查与下载，GitHub 访问受限时自动使用加速线路并校验 APK 完整性",
    ],
  ),
  AppChangelogEntry(
    version: 'v2.1.4',
    date: '2026-09-01',
    changes: ['优化流媒体检测YouTube检测结果'],
  ),
  AppChangelogEntry(
    version: 'v2.1.3',
    date: '2026-08-31',
    changes: ["优化代理留存能力", "优化仪表盘UI显示"],
  ),
  AppChangelogEntry(
    version: 'v2.1.2',
    date: '2026-08-25',
    changes: ["优化显示体验", "提升静态色彩模式下的视觉效果"],
  ),
  AppChangelogEntry(
    version: 'v2.1.1',
    date: '2026-08-25',
    changes: [
      "优化 VPN 启停、服务连接及状态同步，减少后台运行、界面重建和首次启动时的异常状态。",
      "优化订阅与配置更新链路，加强 Mihomo 配置校验与字段保护，降低更新失败或配置被意外覆盖的风险。",
      "优化代理组、节点更新及延迟预热流程，减少配置切换时的竞争与等待，提升日常使用流畅度。",
    ],
  ),
  AppChangelogEntry(
    version: 'v2.1.0',
    date: '2026-08-21',
    changes: [
      "重构 Mihomo 配置兼容逻辑，提升原生配置的兼容性与稳定性。",
      "优化代理组选择、节点固定及状态同步，更贴近 Mihomo 原生行为。",
      "优化网络诊断、智能暂停与 VPN 运行逻辑，提升日常使用稳定性。",
      "优化启动、页面切换和后台任务，降低不必要的资源占用。",
    ],
  ),
  AppChangelogEntry(
    version: 'v2.0.9',
    date: '2026-08-17',
    changes: [
      "优化英文界面文案与文字缩放适配，减少多处文本截断。 优化流媒体检测界面及模式选择菜单显示。 修复 Worker 备份恢复时误清空脚本、规则和策略组的问题。 优化订阅类型标签与订阅名称的对齐效果。",
    ],
  ),
  AppChangelogEntry(
    version: 'v2.0.8',
    date: '2026-07-24',
    changes: ["修复仅统计代理流量 优化订阅卡信息布局"],
  ),
  AppChangelogEntry(
    version: 'v2.0.7',
    date: '2026-07-22',
    changes: [
      'changelog207Item1',
      'changelog207Item2',
      'changelog207Item3',
      'changelog207Item4',
    ],
  ),
  AppChangelogEntry(
    version: 'v2.0.5',
    date: '2026-07-19',
    changes: ['changelog205Item1', 'changelog205Item2', 'changelog205Item3'],
  ),
  AppChangelogEntry(
    version: 'v2.0.4',
    date: '2026-07-17',
    changes: ['changelog204Item1', 'changelog204Item2', 'changelog204Item3'],
  ),
];

const lastShownChangelogVersionKey = 'lastShownChangelogVersion';

bool shouldShowChangelogAfterUpdate({
  required bool wasUpdated,
  required String? lastShownVersion,
  List<AppChangelogEntry> entries = appChangelogEntries,
}) {
  if (!wasUpdated || entries.isEmpty) return false;
  return lastShownVersion != entries.first.version;
}
