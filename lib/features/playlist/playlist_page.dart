import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../core/database/database.dart';
import '../../core/services/folder_watcher_service.dart';
import '../../core/services/service_locator.dart';
import '../../core/utils/grid_layout.dart';
import '../../core/utils/memoized_filter.dart';
import '../../core/utils/search_util.dart';
import '../../widgets/card_surface.dart';
import '../../widgets/cover_card.dart';
import '../../widgets/page_toolbar.dart';
import '../../widgets/search_empty_state.dart';
import '../../widgets/toolbar_search_field.dart';
import '../shell/shell_controller.dart';
import 'favorites_page.dart';
import 'playlist_cover.dart';
import 'playlist_detail_page.dart';
import 'playlist_io.dart';
import 'playlist_view_model.dart';

class PlaylistPage extends StatefulWidget {
  /// 是否为当前选中的 tab；从非激活切回激活时重新加载数据（保活下的
  /// 跨页数据新鲜度：扫描/删文件夹等变更后切回本页能看到最新数据）。
  final bool active;

  /// Shell 控制器（macOS 菜单「新建播放列表」动作由此到达本页）。
  final ShellController? controller;

  const PlaylistPage({super.key, this.active = true, this.controller});

  @override
  State<PlaylistPage> createState() => _PlaylistPageState();
}

class _PlaylistPageState extends State<PlaylistPage> {
  final _viewModel = PlaylistsViewModel();
  bool _searchActive = false;
  String _query = '';
  final _playlistFilterCache = QueryFilterCache<Playlist>();
  StreamSubscription<ShellAction>? _actionSub;
  StreamSubscription<FolderWatcherEvent>? _folderWatcherSub;

  @override
  void initState() {
    super.initState();
    _viewModel.addListener(_onChanged);
    _viewModel.load();
    _actionSub = widget.controller?.actions.listen(_onShellAction);
    _attachFolderWatcher();
  }

  /// 订阅文件夹监听事件：外部文件增删后实时刷新列表与各播放列表计数（保活页
  /// 平时靠 `active` 激活刷新，监听覆盖「停留在本页」的即时变更）。
  void _attachFolderWatcher() {
    if (!ServiceLocator.isReady) return;
    _folderWatcherSub ??= ServiceLocator.folderWatcher.events.listen((_) {
      if (mounted) _viewModel.load();
    });
  }

  @override
  void didUpdateWidget(PlaylistPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) {
      _viewModel.load();
    }
  }

  @override
  void dispose() {
    _folderWatcherSub?.cancel();
    _folderWatcherSub = null;
    _actionSub?.cancel();
    _viewModel.removeListener(_onChanged);
    _viewModel.dispose();
    super.dispose();
  }

  /// macOS 菜单动作：新建/导入/导出播放列表。
  void _onShellAction(ShellAction action) {
    switch (action) {
      case ShellAction.newPlaylist:
        _createPlaylist();
      case ShellAction.importPlaylist:
        _importM3u();
      case ShellAction.exportPlaylist:
        _exportPlaylistFromMenu();
      case ShellAction.importFolder:
        break; // 文件夹动作属于音乐库页。
      case ShellAction.forceRescan:
        break; // 强制刷新属于音乐库页。
    }
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  // ─── Actions ───────────────────────────────────────────

  Future<void> _createPlaylist() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('新建播放列表'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '名称',
            hintText: '例如：我的最爱',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;

    final id = await _viewModel.createPlaylist(name);
    await _viewModel.load();
    if (!mounted) return;

    Playlist? created;
    for (final p in _viewModel.playlists) {
      if (p.id == id) {
        created = p;
        break;
      }
    }
    if (created != null) {
      await _openDetail(created);
    }
  }

  Future<void> _importM3u() async {
    final files = await FilePicker.pickFiles(
      dialogTitle: '导入播放列表',
      type: FileType.custom,
      allowedExtensions: const ['m3u', 'm3u8'],
    );
    final filePath = files.isEmpty ? null : files.single.path;
    if (filePath == null || !mounted) return;

    final M3uImportResult imported;
    try {
      imported = await importM3uFromFile(filePath);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('导入失败：无法读取文件')));
      }
      return;
    }
    if (imported.songs.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('未匹配到任何歌曲，请确认歌单中的文件已在音乐库中')),
        );
      }
      return;
    }
    if (!mounted) return;

    // 与导出同理：等播放列表数据就绪再展示「选择目标列表」，否则冷启动
    // 立即导入时已有列表不会出现在可选目标里。
    await _viewModel.ensureLoaded();
    if (!mounted) return;

    final defaultName = p.basenameWithoutExtension(filePath);
    final targetId = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (context) => _ImportTargetSheet(
        songs: imported.songs,
        total: imported.total,
        defaultName: defaultName,
        playlists: _viewModel.playlists,
      ),
    );
    if (targetId == null || !mounted) return;

    int playlistId;
    String targetName;
    if (targetId == _ImportTargetSheet.createNew) {
      playlistId = await _viewModel.createPlaylist(defaultName);
      targetName = defaultName;
    } else {
      playlistId = targetId;
      targetName = _nameOf(targetId) ?? '播放列表';
    }

    final added = await ServiceLocator.songRepo.addSongsToPlaylist(
      playlistId,
      imported.songs.map((s) => s.id).toList(),
    );
    await _viewModel.load();
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '已导入 $added 首到"$targetName"'
          '${imported.skipped > 0 ? '，${imported.skipped} 首未匹配' : ''}',
        ),
      ),
    );
  }

  /// macOS 菜单「导出播放列表」：先选要导出的播放列表，再存为 M3U8。
  Future<void> _exportPlaylistFromMenu() async {
    // 冷启动首次构建时数据可能尚未加载完成（playlists 为空不等于真没有），
    // 先等数据就绪再判断，避免误报「没有可导出的播放列表」。
    await _viewModel.ensureLoaded();
    if (!mounted) return;
    final playlists = _viewModel.playlists;
    if (playlists.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('没有可导出的播放列表')));
      return;
    }

    final selected = await showModalBottomSheet<Playlist>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 24, 12),
              child: Text(
                '选择要导出的播放列表',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final pl in playlists)
                    ListTile(
                      leading: const Icon(Icons.playlist_play),
                      title: Text(pl.name),
                      onTap: () => Navigator.pop(context, pl),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    if (selected == null || !mounted) return;

    final ({Uint8List bytes, int count}) content;
    try {
      content = await buildPlaylistM3u8(selected.id);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('导出失败：无法生成播放列表内容')));
      return;
    }

    final uri = await FilePicker.saveFile(
      dialogTitle: '导出播放列表',
      fileName: '${selected.name}.m3u8',
      bytes: content.bytes,
      type: FileType.custom,
      allowedExtensions: const ['m3u8', 'm3u'],
    );
    if (uri == null || !mounted) return;
    // saveFile 已把 bytes 写入所选位置，uri 非空即成功。
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('已导出 ${content.count} 首歌曲')));
  }

  String? _nameOf(int id) {
    for (final pl in _viewModel.playlists) {
      if (pl.id == id) return pl.name;
    }
    return null;
  }

  Future<void> _rename(Playlist playlist) async {
    final controller = TextEditingController(text: playlist.name);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重命名播放列表'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: '名称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    await _viewModel.renamePlaylist(playlist.id, name);
  }

  Future<void> _delete(Playlist playlist) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除播放列表'),
        content: Text('确定删除"${playlist.name}"吗？此操作不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _viewModel.deletePlaylist(playlist.id);
    }
  }

  /// 播放列表卡片的统一菜单（三点按钮与长按共用），内容保持一致。
  List<PopupMenuEntry<String>> _playlistMenuItems() => const [
    PopupMenuItem(value: 'play', child: Text('播放')),
    PopupMenuItem(value: 'rename', child: Text('重命名')),
    PopupMenuItem(value: 'export', child: Text('导出')),
    PopupMenuItem(value: 'delete', child: Text('删除')),
  ];

  /// 菜单项分发：播放 / 重命名 / 导出 / 删除。
  Future<void> _handlePlaylistMenu(Playlist playlist, String value) async {
    switch (value) {
      case 'play':
        final songs = await ServiceLocator.songRepo.getSongsInPlaylist(
          playlist.id,
        );
        if (!mounted) return;
        if (songs.isEmpty) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('播放列表为空')));
        } else {
          ServiceLocator.player.playFromList(songs, startIndex: 0);
        }
        break;
      case 'rename':
        await _rename(playlist);
        break;
      case 'export':
        await _export(playlist);
        break;
      case 'delete':
        await _delete(playlist);
        break;
    }
  }

  /// 导出播放列表为 M3U 文件。
  Future<void> _export(Playlist playlist) async {
    final ({Uint8List bytes, int count}) content;
    try {
      content = await buildPlaylistM3u8(playlist.id);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('导出失败：无法生成播放列表内容')));
      return;
    }

    final uri = await FilePicker.saveFile(
      dialogTitle: '导出播放列表',
      fileName: '${playlist.name}.m3u8',
      bytes: content.bytes,
      type: FileType.custom,
      allowedExtensions: const ['m3u8', 'm3u'],
    );
    if (uri == null || !mounted) return;
    // saveFile 已把 bytes 写入所选位置，uri 非空即成功。
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('已导出 ${content.count} 首歌曲')));
  }

  /// 长按卡片弹出统一菜单（与右下角三点按钮一致），锚定在卡片位置。
  Future<void> _showPlaylistMenu(Playlist playlist, BuildContext anchor) async {
    final box = anchor.findRenderObject() as RenderBox?;
    final overlay = Overlay.of(anchor).context.findRenderObject() as RenderBox?;
    if (box == null || overlay == null) return;
    final value = await showMenu<String>(
      context: anchor,
      position: RelativeRect.fromRect(
        box.localToGlobal(Offset.zero) & box.size,
        Offset.zero & overlay.size,
      ),
      items: _playlistMenuItems(),
    );
    if (value != null && mounted) {
      await _handlePlaylistMenu(playlist, value);
    }
  }

  Future<void> _openDetail(Playlist playlist) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => PlaylistDetailPage(playlist: playlist)),
    );
    await _viewModel.load();
  }

  Future<void> _openFavorites() async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const FavoritesPage()));
    await _viewModel.load();
  }

  // ─── Search ─────────────────────────────────────────────

  List<Playlist> get _filteredPlaylists => _playlistFilterCache.get(
    normalizeQuery(_query),
    _viewModel.playlists,
    (q, source) => source.where((p) => containsIgnoreCase(p.name, q)).toList(),
  );

  void _enterSearch() => setState(() => _searchActive = true);

  void _exitSearch() => setState(() {
    _searchActive = false;
    _query = '';
  });

  // ─── Build ─────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (_viewModel.loading) {
      return const Center(child: CircularProgressIndicator());
    }

    final playlists = _filteredPlaylists;

    return Column(
      children: [
        _buildAppBar(playlists.length),
        const Divider(height: 1),
        Expanded(
          // “我的收藏”入口始终展示（即使无任何列表/收藏也是空态入口）；
          // 仅搜索模式下隐藏收藏卡片，按匹配结果展示。
          child: _searchActive
              ? (playlists.isEmpty
                    ? SearchEmptyState(query: _query)
                    : _buildContent(theme, playlists))
              : _buildContent(theme, playlists),
        ),
      ],
    );
  }

  Widget _buildAppBar(int count) {
    return PageToolbar(
      title: '播放列表',
      subtitle: _searchActive ? '匹配 $count 个' : '$count 个',
      actions: _searchActive
          ? [
              ToolbarSearchField(
                hintText: '搜索播放列表',
                onChanged: (v) => setState(() => _query = v),
                onClose: _exitSearch,
              ),
            ]
          : [
              IconButton(
                icon: const Icon(Icons.add),
                tooltip: '新建播放列表',
                onPressed: _createPlaylist,
              ),
              IconButton(
                icon: const Icon(Icons.search),
                tooltip: '搜索',
                onPressed: _enterSearch,
              ),
              PopupMenuButton<String>(
                tooltip: '更多',
                // 默认 iconTheme.color 是固定纯黑/纯白（M2 遗留），显式指定跟随主题。
                iconColor: Theme.of(context).colorScheme.onSurfaceVariant,
                onSelected: (value) {
                  if (value == 'import') _importM3u();
                },
                itemBuilder: (context) => const [
                  PopupMenuItem(value: 'import', child: Text('导入播放列表')),
                ],
              ),
            ],
    );
  }

  /// 没有自建播放列表时的空态提示（展示在“我的收藏”卡片下方）。
  Widget _buildEmptyState(ThemeData theme) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.playlist_play, size: 56, color: theme.colorScheme.primary),
          const SizedBox(height: 12),
          Text('暂无播放列表', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            '点击右上角 + 新建播放列表',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _createPlaylist,
            icon: const Icon(Icons.add),
            label: const Text('新建播放列表'),
          ),
        ],
      ),
    );
  }

  Widget _buildContent(ThemeData theme, List<Playlist> playlists) {
    return CustomScrollView(
      slivers: [
        // 搜索模式下收藏卡片收起（AnimatedSize 高度塌陷），网格平滑上移。
        SliverToBoxAdapter(
          child: AnimatedSize(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeInOutCubic,
            child: _searchActive
                ? const SizedBox.shrink()
                : _buildFavoritesCard(theme),
          ),
        ),
        // 没有自建播放列表时，在收藏卡片下方给出空态提示。
        if (!_searchActive && playlists.isEmpty)
          SliverToBoxAdapter(child: _buildEmptyState(theme)),
        if (playlists.isNotEmpty) ...[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
              child: Text(
                '我的播放列表',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithClampedExtent(
                maxCrossAxisExtent: 200,
                minCrossAxisCount: 2,
                maxCrossAxisCount: 8,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: 0.76,
              ),
              delegate: SliverChildBuilderDelegate((context, index) {
                final playlist = playlists[index];
                // Builder 提供卡片自身的 context，findRenderObject 才能取到卡片
                // RenderBox（itemBuilder 的 context 会解析到 RenderSliverGrid）。
                return Builder(
                  builder: (cardContext) => CoverCard(
                    cover: PlaylistCover(
                      playlistId: playlist.id,
                      size: double.infinity,
                      borderRadius: 0,
                      revision: _viewModel.songCountFor(playlist),
                    ),
                    title: playlist.name,
                    subtitle: '${_viewModel.songCountFor(playlist)} 首歌曲',
                    onTap: () => _openDetail(playlist),
                    onLongPress: () => _showPlaylistMenu(playlist, cardContext),
                    trailing: PopupMenuButton<String>(
                      tooltip: '更多',
                      // child 模式：用固定 20×20 盒子承载图标，命中区即 20×20。
                      // （icon 模式内部走 IconButton，默认 48 命中区且不接收
                      //   constraints；PopupMenuButton.constraints 只控制菜单宽度）
                      child: const SizedBox(
                        width: 20,
                        height: 20,
                        child: Icon(Icons.more_vert, size: 16),
                      ),
                      onSelected: (value) =>
                          _handlePlaylistMenu(playlist, value),
                      itemBuilder: (context) => _playlistMenuItems(),
                    ),
                  ),
                );
              }, childCount: playlists.length),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildFavoritesCard(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: CardSurface(
        onTap: _openFavorites,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  Icons.favorite,
                  color: theme.colorScheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('我的收藏', style: theme.textTheme.titleMedium),
                    const SizedBox(height: 2),
                    Text(
                      '${_viewModel.favoriteCount} 首歌曲',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 导入 M3U 时的目标选择弹层：新建（以文件名命名）或加入已有播放列表。
class _ImportTargetSheet extends StatelessWidget {
  /// 选中"新建播放列表"时返回的特殊 id。
  static const int createNew = -1;

  final List<Song> songs;
  final int total;
  final String defaultName;
  final List<Playlist> playlists;

  const _ImportTargetSheet({
    required this.songs,
    required this.total,
    required this.defaultName,
    required this.playlists,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              '导入 ${songs.length} 首歌曲',
              style: theme.textTheme.titleMedium,
            ),
          ),
          if (total > songs.length)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                '${total - songs.length} 首未匹配（不在音乐库中）',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ListTile(
            leading: const Icon(Icons.add),
            title: Text('新建播放列表"$defaultName"'),
            onTap: () => Navigator.pop(context, createNew),
          ),
          if (playlists.isNotEmpty) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text(
                '加入已有播放列表',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: playlists.length,
                itemBuilder: (context, index) {
                  final pl = playlists[index];
                  return ListTile(
                    leading: const Icon(Icons.queue_music_rounded),
                    title: Text(
                      pl.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () => Navigator.pop(context, pl.id),
                  );
                },
              ),
            ),
          ],
        ],
      ),
    );
  }
}
