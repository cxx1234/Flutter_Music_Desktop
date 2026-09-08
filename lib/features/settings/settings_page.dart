import 'package:flutter/material.dart';

import '../../core/models/accent_color.dart';
import '../../core/services/album_art_cache_service.dart';
import '../../core/services/service_locator.dart';
import '../../widgets/page_toolbar.dart';
import '../shell/shell_controller.dart';
import 'about_page.dart';
import 'log_page.dart';

/// 设置页：分组卡片（音乐库 / 播放设置 / 外观 / 通用）。
class SettingsPage extends StatefulWidget {
  /// Shell 控制器（「音乐库 › 强制刷新」动作由此切到音乐库并触发）。
  final ShellController? controller;

  const SettingsPage({super.key, this.controller});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  /// 续播开关（启动时从设置读取，默认开）。
  bool _resumePlayback = true;

  /// 主题模式（启动时从设置读取，默认跟随系统）。
  ThemeMode _themeMode = ThemeMode.system;

  /// 界面强调色（启动时从设置读取，默认石墨灰）。
  AccentColor _accent = AccentColor.graphite;

  /// 底栏播放进度填充开关（启动时从设置读取，默认开）。
  bool _nowPlayingBarFill = true;

  /// 封面缓存大小（字节）；null = 尚未加载成功。
  int? _cacheSizeBytes;

  @override
  void initState() {
    super.initState();
    // 设置页是 Shell 惰性保活 tab，首次选中才构建；此时 ServiceLocator 通常
    // 已就绪，但仍加守卫兜底（用户可能初始化完成前就切到设置）。
    if (ServiceLocator.isReady) {
      _resumePlayback = ServiceLocator.settings.resumePlaybackPosition;
      _themeMode = ServiceLocator.settings.themeMode;
      _accent = ServiceLocator.settings.accentColor;
      _nowPlayingBarFill = ServiceLocator.settings.nowPlayingBarFill;
    }
    _loadCacheSize();
  }

  Future<void> _loadCacheSize() async {
    final size = await AlbumArtCacheService().cacheSizeBytes();
    if (!mounted) return;
    setState(() => _cacheSizeBytes = size);
  }

  /// 清理缓存：功能未实现。先弹确认框（占位文案），确认后提示占位。
  Future<void> _clearCache() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清理缓存'),
        content: const Text('还没做 -ω-;'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('清理'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('还没做 -ω-;')));
  }

  /// 字节数 → 人类可读（B/KB/MB）。
  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  /// 选项副标题样式：比 bodySmall 再小一档、偏灰（与 SongTile 副标题一致）。
  TextStyle _subtitleStyle(ThemeData theme) => theme.textTheme.bodySmall!
      .copyWith(fontSize: 11, color: theme.colorScheme.onSurfaceVariant);

  /// 选项行的标题+副标题组合块（两行整体垂直居中，与 SongTile 一致）。
  Widget _buildOptionText(ThemeData theme, String title, String subtitle) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: theme.textTheme.titleMedium),
        Text(subtitle, style: _subtitleStyle(theme)),
      ],
    );
  }

  /// 主题行 leading 图标：跟随当前主题亮度 —— 深色显示月亮、浅色显示太阳。
  IconData _themeIndicatorIcon(ThemeData theme) =>
      theme.brightness == Brightness.dark ? Icons.dark_mode : Icons.light_mode;

  /// 主题模式 → 展示文案。
  String _themeModeLabel(ThemeMode mode) => switch (mode) {
    ThemeMode.system => '跟随系统',
    ThemeMode.light => '浅色',
    ThemeMode.dark => '深色',
  };

  /// 主题模式 → 图标（分段按钮窄版用）。
  IconData _themeModeIcon(ThemeMode mode) => switch (mode) {
    ThemeMode.system => Icons.brightness_auto,
    ThemeMode.light => Icons.light_mode_outlined,
    ThemeMode.dark => Icons.dark_mode_outlined,
  };

  /// 切换续播开关（UI 状态 + 写盘）。
  void _setResumePlayback(bool value) {
    setState(() => _resumePlayback = value);
    ServiceLocator.settings.setResumePlaybackPosition(value);
  }

  /// 切换底栏播放进度填充开关（UI 状态 + 写盘 + 通知底栏即时生效）。
  void _setNowPlayingBarFill(bool value) {
    setState(() => _nowPlayingBarFill = value);
    ServiceLocator.settings.setNowPlayingBarFill(value);
  }

  /// 跟随系统圆点的兜底监听源（非 macOS / 未就绪时无系统色服务）。
  static final ValueNotifier<Color?> _noSystemColor = ValueNotifier<Color?>(
    null,
  );

  /// 切换界面强调色（UI 状态 + 写盘 → MaterialApp 即时换肤）。
  void _setAccentColor(AccentColor accent) {
    setState(() => _accent = accent);
    ServiceLocator.settings.setAccentColor(accent);
  }

  /// 底色相对亮度 → 覆盖前景色：深底用白、浅底用深黑灰（对勾可见）。
  Color _contrastOn(Color background) =>
      background.computeLuminance() > 0.5 ? Colors.black87 : Colors.white;

  /// 44×26 紧凑开关：M3 Switch 默认 52×32，非等比缩放（视觉+命中区同步）。
  Widget _buildCompactSwitch({
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    const targetW = 44.0, targetH = 26.0;
    const defaultW = 52.0, defaultH = 32.0;
    return SizedBox(
      width: targetW,
      height: targetH,
      child: Transform(
        alignment: Alignment.center,
        transform: Matrix4.diagonal3Values(
          targetW / defaultW,
          targetH / defaultH,
          1,
        ),
        child: Switch(value: value, onChanged: onChanged),
      ),
    );
  }

  /// 音乐库 › 强制刷新：切回音乐库 tab 并触发全量重解析（与旧长按/右键一致）。
  ///
  /// 无文件夹时按钮已置灰（onTap:null），此处只负责跳转并触发。
  void _forceRescan() {
    final controller = widget.controller;
    if (controller == null || !mounted) return;
    controller.request(NavigationItem.library, action: ShellAction.forceRescan);
  }

  /// 「音乐库」分组卡片：目前为强制刷新入口。无文件夹时禁用（ListTile 置灰）。
  Widget _buildLibraryCard() {
    final theme = Theme.of(context);
    final hasFolders =
        ServiceLocator.isReady &&
        ServiceLocator.settings.musicFolders.isNotEmpty;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 24),
      elevation: 0,
      color: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        minVerticalPadding: 16,
        enabled: hasFolders,
        leading: const Icon(Icons.refresh),
        title: _buildOptionText(
          theme,
          '强制刷新',
          hasFolders ? '重新解析全部歌曲，修复异常元数据/封面' : '请先在音乐库添加文件夹',
        ),
        subtitle: null,
        trailing: Icon(
          Icons.chevron_right,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        onTap: hasFolders ? _forceRescan : null,
      ),
    );
  }

  Widget _buildPlaybackCard() {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 24),
      elevation: 0,
      color: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        minVerticalPadding: 16,
        leading: const Icon(Icons.replay_rounded),
        title: _buildOptionText(theme, '续播上次播放位置', '启动后恢复上次播放进度'),
        subtitle: null,
        trailing: _buildCompactSwitch(
          value: _resumePlayback,
          onChanged: _setResumePlayback,
        ),
        onTap: () => _setResumePlayback(!_resumePlayback),
      ),
    );
  }

  /// 「主题色」行：行内直排圆点（首项「跟随系统」+ 预设色板），点选即换肤。
  Widget _buildAccentRow(ThemeData theme) {
    // 跟随系统圆点的实时预览色：仅 macOS 有 SystemAccentService，
    // 其余平台用兜底空 notifier（恒定 null，不触发重建）。
    final systemAccent = ServiceLocator.isReady
        ? ServiceLocator.systemAccent
        : null;
    final systemColorListenable =
        systemAccent?.systemAccentNotifier ?? _noSystemColor;

    const dotsGap = 6.0;
    final count = AccentColor.values.length;
    final fullMinWidth = 16.0 * count + dotsGap * (count - 1);

    return SizedBox(
      height: 72,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            const Icon(Icons.palette_outlined),
            const SizedBox(width: 16),
            // 文本块给上限宽度，剩余宽度尽量留给色板；极窄时文本省略号。
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 150),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('主题色', style: theme.textTheme.titleMedium),
                  Text(
                    '选择界面强调色或跟随系统',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: _subtitleStyle(theme),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: ValueListenableBuilder<Color?>(
                valueListenable: systemColorListenable,
                builder: (context, systemColor, _) => LayoutBuilder(
                  builder: (context, constraints) {
                    final available = constraints.maxWidth;
                    if (available >= fullMinWidth) {
                      // 宽度足够：圆点自适应填满（上限 24），右对齐。
                      final size = ((available - dotsGap * (count - 1)) / count)
                          .clamp(16.0, 24.0)
                          .floorToDouble();
                      return Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: _accentDots(
                          theme,
                          size: size,
                          systemColor: systemColor,
                        ),
                      );
                    }
                    // 极端窄：固定 20 圆点 + 横向滚动兜底（不溢出）。
                    return SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: _accentDots(
                          theme,
                          size: 20,
                          systemColor: systemColor,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 色板圆点列表（预设=实色圆；跟随系统=实时系统色或 auto 图标）。
  List<Widget> _accentDots(
    ThemeData theme, {
    required double size,
    required Color? systemColor,
  }) => [
    for (final accent in AccentColor.values) ...[
      if (accent != AccentColor.values.first) const SizedBox(width: 6),
      _buildAccentDot(
        theme: theme,
        accent: accent,
        size: size,
        systemColor: systemColor,
      ),
    ],
  ];

  /// 单个圆点：选中=描边+对勾；跟随系统无系统色=描边+auto 图标。
  Widget _buildAccentDot({
    required ThemeData theme,
    required AccentColor accent,
    required double size,
    required Color? systemColor,
  }) {
    final scheme = theme.colorScheme;
    final isSystem = accent.followsSystem;
    final selected = _accent == accent;
    final fill = isSystem ? systemColor : accent.seed;
    final noFill = fill == null;

    final Widget child;
    if (selected) {
      child = Icon(
        Icons.check,
        size: size * 0.6,
        color: _contrastOn(fill ?? scheme.surface),
      );
    } else if (isSystem && noFill) {
      child = Icon(
        Icons.auto_awesome,
        size: size * 0.55,
        color: scheme.onSurfaceVariant,
      );
    } else {
      child = const SizedBox.shrink();
    }

    return Tooltip(
      message: accent.label,
      child: GestureDetector(
        onTap: () => _setAccentColor(accent),
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: fill,
            border: Border.all(
              color: selected
                  ? scheme.onSurface
                  : (isSystem && noFill
                        ? scheme.outlineVariant
                        : Colors.transparent),
              width: selected ? 2 : 1,
            ),
          ),
          child: Center(child: child),
        ),
      ),
    );
  }

  Widget _buildAppearanceCard() {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 24),
      elevation: 0,
      color: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          // 底栏播放进度填充开关（「外观」分组）。
          ListTile(
            // 与其它设置行一致的行高（续播/通用各行均为 16）。
            minVerticalPadding: 16,
            leading: const Icon(Icons.timeline_rounded),
            title: _buildOptionText(theme, '底栏播放进度填充', '播放时底栏背景从左向右显示进度'),
            trailing: _buildCompactSwitch(
              value: _nowPlayingBarFill,
              onChanged: _setNowPlayingBarFill,
            ),
            onTap: () => _setNowPlayingBarFill(!_nowPlayingBarFill),
          ),
          SizedBox(
            height: 72,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  // 宽度不足以容纳文字版三按钮时，收成图标版 + tooltip。
                  final compact = constraints.maxWidth < 550;
                  return Row(
                    children: [
                      // 跟随当前主题亮度：深色显示月亮、浅色显示太阳。
                      Icon(_themeIndicatorIcon(theme)),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('主题模式', style: theme.textTheme.titleMedium),
                            Text('选择应用的明暗外观', style: _subtitleStyle(theme)),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      SegmentedButton<ThemeMode>(
                        showSelectedIcon: false,
                        segments: [
                          for (final mode in ThemeMode.values)
                            if (compact)
                              ButtonSegment(
                                value: mode,
                                icon: Icon(_themeModeIcon(mode)),
                                tooltip: _themeModeLabel(mode),
                              )
                            else
                              ButtonSegment(
                                value: mode,
                                icon: Icon(_themeModeIcon(mode)),
                                label: Text(_themeModeLabel(mode)),
                              ),
                        ],
                        selected: {_themeMode},
                        onSelectionChanged: (selection) {
                          final mode = selection.first;
                          setState(() => _themeMode = mode);
                          ServiceLocator.settings.setThemeMode(mode);
                        },
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
          _buildAccentRow(theme),
        ],
      ),
    );
  }

  Widget _buildGeneralCard() {
    final theme = Theme.of(context);
    final chevronColor = theme.colorScheme.onSurfaceVariant;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 24),
      elevation: 0,
      color: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          ListTile(
            minVerticalPadding: 16,
            leading: const Icon(Icons.receipt_long_outlined),
            title: _buildOptionText(theme, '日志', '查看应用运行日志'),
            subtitle: null,
            trailing: Icon(Icons.chevron_right, color: chevronColor),
            onTap: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const LogPage())),
          ),
          ListTile(
            minVerticalPadding: 16,
            leading: const Icon(Icons.photo_library_outlined),
            title: _buildOptionText(theme, '缓存', '封面图片缓存（可安全清理）'),
            subtitle: null,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _cacheSizeBytes == null
                      ? '…'
                      : _formatBytes(_cacheSizeBytes!),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 12),
                TextButton.icon(
                  onPressed: _clearCache,
                  icon: const Icon(Icons.cleaning_services, size: 18),
                  label: const Text('清理'),
                ),
              ],
            ),
          ),
          ListTile(
            minVerticalPadding: 16,
            leading: const Icon(Icons.info_outline),
            title: _buildOptionText(
              theme,
              '关于',
              '版本 ${ServiceLocator.appVersion ?? ''} · 开源许可',
            ),
            subtitle: null,
            trailing: Icon(Icons.chevron_right, color: chevronColor),
            onTap: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const AboutPage())),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
      child: Text(
        title,
        style: theme.textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const PageToolbar(title: '设置'),
        const Divider(height: 1),
        Expanded(
          // 项目约定：含 ListTile/InkWell 的滚动区必须外包透明 Material +
          // Clip.hardEdge，防止墨水波纹渗出到标题区。
          child: Material(
            type: MaterialType.transparency,
            clipBehavior: Clip.hardEdge,
            child: ListView(
              padding: const EdgeInsets.only(bottom: 24),
              children: [
                _buildSectionHeader('音乐库'),
                _buildLibraryCard(),
                _buildSectionHeader('播放设置'),
                _buildPlaybackCard(),
                _buildSectionHeader('外观'),
                _buildAppearanceCard(),
                _buildSectionHeader('通用'),
                _buildGeneralCard(),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
