import 'package:flutter/material.dart';

import '../../core/constants/layout.dart';
import '../album/album_page.dart';
import '../artist/artist_page.dart';
import '../library/library_page.dart';
import '../playlist/playlist_page.dart';
import '../settings/settings_page.dart';
import 'shell_controller.dart';

export 'shell_controller.dart';

class ShellPage extends StatefulWidget {
  final bool isInitialized;

  /// Shell tab 外部控制（双向同步）。
  final ShellController controller;

  const ShellPage({
    super.key,
    this.isInitialized = false,
    required this.controller,
  });

  @override
  State<ShellPage> createState() => _ShellPageState();
}

class _ShellPageState extends State<ShellPage> {
  NavigationItem _selected = NavigationItem.library;

  /// 已访问过的 tab：惰性保活——首次选中才构建页面，之后切换不销毁重建
  /// （State / 滚动位置 / 搜索状态保留）。
  final Set<NavigationItem> _visited = {NavigationItem.library};

  @override
  void initState() {
    super.initState();
    // 以控制器当前值为准（兜住 Shell 重建后控制器可能已非初始 tab 的失步）。
    _selected = widget.controller.tab.value;
    widget.controller.tab.addListener(_onExternalTab);
  }

  /// 外部（App/播放页）请求切 tab。
  void _onExternalTab() {
    final requested = widget.controller.tab.value;
    if (requested == _selected) return;
    setState(() {
      _selected = requested;
      _visited.add(requested);
    });
  }

  @override
  void dispose() {
    widget.controller.tab.removeListener(_onExternalTab);
    super.dispose();
  }

  /// 返回 [item] 对应的页面；未访问过的 tab 用空占位（惰性构建）。
  ///
  /// 每次 build 都重建 widget 实例（同类型同位置 → 框架复用 Element/State 保活），
  /// 这样 `LibraryPage(isInitialized:)` 的启动就绪信号能正常走 didUpdateWidget；
  /// 不能缓存 widget 实例，否则参数会变 stale。
  Widget _pageFor(NavigationItem item) {
    if (!_visited.contains(item)) return const SizedBox.shrink();
    final active = _selected == item;
    switch (item) {
      case NavigationItem.library:
        return LibraryPage(
          isInitialized: widget.isInitialized,
          controller: widget.controller,
        );
      case NavigationItem.albums:
        return AlbumsPage(active: active);
      case NavigationItem.artists:
        return ArtistsPage(active: active);
      case NavigationItem.playlists:
        return PlaylistPage(active: active, controller: widget.controller);
      case NavigationItem.settings:
        return SettingsPage(controller: widget.controller);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: Row(
        children: [
          // 左侧边栏顶部预留 layoutConfig.sidebarTopInset（macOS=56）给红绿灯悬浮，
          // 该值与原生层定位一致（红绿灯垂直居中于该区域）。
          Padding(
            padding: EdgeInsets.only(top: layoutConfig.sidebarTopInset),
            child: SizedBox(
              width: layoutConfig.sidebarWidth,
              child: NavigationRail(
                selectedIndex: _selected.index,
                onDestinationSelected: (index) {
                  final item = NavigationItem.values[index];
                  setState(() {
                    _selected = item;
                    _visited.add(item);
                  });
                  // 双向同步：外部（App/播放页）也能读到当前 tab。
                  widget.controller.tab.value = item;
                },
                labelType: NavigationRailLabelType.selected,
                leading: Padding(
                  // 上 10 / 下 15：让音乐图标与下方导航按钮拉开距离。
                  padding: const EdgeInsets.only(top: 10, bottom: 15),
                  child: Icon(
                    Icons.music_note,
                    size: 32,
                    color: theme.colorScheme.primary,
                  ),
                ),
                destinations: [
                  for (final item in NavigationItem.values)
                    NavigationRailDestination(
                      icon: Icon(item.icon, size: 26),
                      label: Text(item.label),
                    ),
                ],
              ),
            ),
          ),
          const VerticalDivider(width: 1),
          // IndexedStack 保活已访问的页面：非选中页不销毁（State 保留），
          // 只是不绘制。未访问的 tab 是空占位，首次选中才构建。
          Expanded(
            child: IndexedStack(
              index: _selected.index,
              children: [
                for (final item in NavigationItem.values) _pageFor(item),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
