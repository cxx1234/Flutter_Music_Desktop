import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../core/database/database.dart';
import '../../core/database/song_sort_order.dart';
import '../../core/services/library_scanner_service.dart';
import '../../core/services/service_locator.dart';
import '../../core/utils/index_letters.dart';
import '../../core/utils/memoized_filter.dart';
import '../../core/utils/search_util.dart';
import '../../widgets/animated_collapse.dart';
import '../../widgets/card_surface.dart';
import '../../widgets/index_scrollbar.dart';
import '../../widgets/page_toolbar.dart';
import '../../widgets/search_empty_state.dart';
import '../../widgets/song_tile.dart';
import '../../widgets/toolbar_search_field.dart';
import '../playlist/song_actions.dart';
import '../shell/shell_controller.dart';
import 'library_view_model.dart';

class LibraryPage extends StatefulWidget {
  final bool isInitialized;

  /// Shell 控制器（macOS 菜单「导入文件夹」动作由此到达本页）。
  final ShellController? controller;

  const LibraryPage({super.key, this.isInitialized = false, this.controller});

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  final _viewModel = LibraryViewModel();
  List<String> _musicFolders = [];
  bool _ready = false;
  Timer? _readyTimer;

  /// 扫描结果横幅自动收起计时器（保活后 VM 常驻，横幅不再随切 tab 消失）。
  Timer? _scanResultDismissTimer;
  static const _scanResultDismissDelay = Duration(seconds: 4);
  bool _searchActive = false;
  String _query = '';
  final _songFilterCache = QueryFilterCache<Song>();
  final _songScrollController = ScrollController();
  StreamSubscription<ShellAction>? _actionSub;

  @override
  void initState() {
    super.initState();
    _viewModel.addListener(_onViewModelChanged);
    _loadFolders();
    _scheduleReadyRetry();
    _actionSub = widget.controller?.actions.listen(_onShellAction);
  }

  /// macOS 菜单「导入文件夹」动作：直接弹文件夹选择器。
  void _onShellAction(ShellAction action) {
    if (action == ShellAction.importFolder) {
      _pickFolder();
    }
  }

  @override
  void dispose() {
    _actionSub?.cancel();
    _readyTimer?.cancel();
    _scanResultDismissTimer?.cancel();
    _songScrollController.dispose();
    _viewModel.removeListener(_onViewModelChanged);
    _viewModel.dispose();
    super.dispose();
  }

  /// 兜底：ServiceLocator 尚未就绪时轮询等待，就绪后自动加载。
  ///
  /// 不依赖 [didUpdateWidget] —— Flutter 的 `MaterialApp.home` 参数变化
  /// 不会刷新 Navigator 里已存在的初始 route，导致 `isInitialized` 信号
  /// 从未到达本页面，启动后不做任何操作会一直转圈。
  void _scheduleReadyRetry() {
    _readyTimer?.cancel();
    if (widget.isInitialized || ServiceLocator.isReady) return;
    _readyTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (widget.isInitialized || ServiceLocator.isReady) {
        _readyTimer?.cancel();
        _readyTimer = null;
        _loadFolders();
      }
    });
  }

  @override
  void didUpdateWidget(LibraryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isInitialized && !oldWidget.isInitialized) {
      _loadFolders();
    }
  }

  void _onViewModelChanged() {
    if (mounted) setState(() {});
    _scheduleScanResultDismissIfNeeded();
    _showScanErrorSnackIfNeeded();
  }

  /// 上次已提示过的扫描错误（避免同一条错误反复弹 SnackBar）。
  String? _lastShownScanError;

  /// 扫描抛异常时用全局 SnackBar 提示（与播放错误的底栏横幅同一机制）。
  ///
  /// 只在新进入错误态且错误内容变化时弹一次；离开错误态后重置，允许下次重弹。
  void _showScanErrorSnackIfNeeded() {
    if (!mounted) return;
    final err = _viewModel.errorMessage;
    if (!_viewModel.isError || err == null) {
      _lastShownScanError = null;
      return;
    }
    if (err == _lastShownScanError) return;
    _lastShownScanError = err;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('扫描失败：$err')));
  }

  /// 扫描结果横幅出现 N 秒后自动收起。
  ///
  /// 页面全部保活后 VM 常驻，结果横幅不再随切换 tab 被清掉，必须主动定时
  /// 清除，否则会一直挂在页面上（用户反馈"结果 tip 不会消失"）。
  void _scheduleScanResultDismissIfNeeded() {
    final result = _viewModel.scanResult;
    if (result == null || _viewModel.isScanning) {
      _scanResultDismissTimer?.cancel();
      _scanResultDismissTimer = null;
      return;
    }
    // 同一次结果只排一次计时（进度/播放器等 notify 不重置倒计时）。
    if (_scanResultDismissTimer != null) return;
    _scanResultDismissTimer = Timer(_scanResultDismissDelay, () {
      if (mounted) _viewModel.clearScanResult();
    });
  }

  void _loadFolders() {
    // 初始化完成前等待 didUpdateWidget / 轮询兜底触发；ServiceLocator 已
    // 就绪时即使 isInitialized 信号意外丢失也能立即加载，避免一直转圈。
    if (!widget.isInitialized && !ServiceLocator.isReady) return;
    _readyTimer?.cancel();
    _readyTimer = null;
    final folders = ServiceLocator.settings.musicFolders;
    if (mounted) {
      setState(() {
        _musicFolders = folders;
        _ready = true;
      });
    }
    _viewModel.initialize();
  }

  Future<void> _pickFolder() async {
    final path = await FilePicker.getDirectoryPath();
    if (path == null || !mounted) return;

    // Create a macOS security-scoped bookmark so the folder remains
    // accessible after app restarts.
    final bookmark = await ServiceLocator.sandbox.createBookmark(path);
    await ServiceLocator.settings.addMusicFolder(path, bookmark: bookmark);
    setState(() => _musicFolders = ServiceLocator.settings.musicFolders);
    _viewModel.startScan();
  }

  Future<void> _removeFolder(String path) async {
    await _viewModel.removeFolder(path);
    setState(() => _musicFolders = ServiceLocator.settings.musicFolders);
  }

  // ─── Search ─────────────────────────────────────────────

  /// 搜索模式下的过滤结果；查询为空时返回全量歌曲。
  /// 经 QueryFilterCache 缓存：query / 源列表均未变时不重复 O(n) 过滤
  /// （页面常因数据刷新、播放态等无关原因重建）。
  List<Song> get _filteredSongs => _songFilterCache.get(
    normalizeQuery(_query),
    _viewModel.songs,
    (q, source) => source
        .where(
          (s) =>
              containsIgnoreCase(s.title, q) ||
              containsIgnoreCase(s.artist, q) ||
              containsIgnoreCase(s.album, q),
        )
        .toList(),
  );

  void _enterSearch() => setState(() => _searchActive = true);

  void _exitSearch() => setState(() {
    _searchActive = false;
    _query = '';
  });

  /// 扫描状态条是否应显示（扫描中 / 有结果）。错误改走全局 SnackBar，
  /// 不再占用状态条。
  bool get _scanStatusActive =>
      _viewModel.isScanning || _viewModel.scanResult != null;

  // ─── Build ──────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (!_ready) {
      return _buildLoadingState(theme);
    }

    final filtered = _filteredSongs;

    // 单一树：搜索模式下通过 AnimatedCollapse 淡出+塌陷隐藏沙箱警告 /
    // 扫描进度 / 扫描结果 / 文件夹列表，歌曲列表随之平滑上移（平移效果）。
    return Column(
      children: [
        _buildAppBar(),
        AnimatedCollapse(
          visible: !_searchActive && ServiceLocator.sandboxRestoreFailures > 0,
          child: _buildSandboxWarning(theme),
        ),
        // 统一扫描状态条：进度 / 结果 共用一个槽位。
        // - 外层 AnimatedCollapse：整条出现/收起带动画（不再硬蹦）；
        // - 内层 AnimatedSwitcher：扫描完成时 进度→结果 原位交叉淡入淡出。
        // 扫描异常改走全局 SnackBar（_showScanErrorSnackIfNeeded），不占状态条。
        // 进度刷新仍走 scanProgressNotifier（ValueListenableBuilder），只重建
        // 进度条自身、不触发整页 setState；进度条固定高度 → AnimatedSize 在
        // tick 期间尺寸不变，不会反复动画/向下传播重排。
        AnimatedCollapse(
          visible: !_searchActive && _scanStatusActive,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 250),
            child: _viewModel.isScanning
                ? KeyedSubtree(
                    key: const ValueKey('scan-progress'),
                    child: _buildScanProgress(theme),
                  )
                : _viewModel.scanResult != null
                ? KeyedSubtree(
                    key: const ValueKey('scan-result'),
                    child: _buildScanResult(theme),
                  )
                : const SizedBox.shrink(),
          ),
        ),
        const Divider(height: 1),
        AnimatedCollapse(
          visible: !_searchActive && _musicFolders.isNotEmpty,
          child: _buildFolderList(theme),
        ),
        if (!_searchActive) ...[
          if (_musicFolders.isEmpty && !_viewModel.isScanning)
            _buildEmptyState(theme),
          if (_viewModel.songs.isNotEmpty)
            _buildSongList(theme, _viewModel.songs),
        ] else ...[
          if (filtered.isEmpty)
            Expanded(child: SearchEmptyState(query: _query))
          else
            _buildSongList(theme, filtered),
        ],
      ],
    );
  }

  Widget _buildLoadingState(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.library_music, size: 64, color: theme.colorScheme.primary),
          const SizedBox(height: 16),
          Text('你的音乐库', style: theme.textTheme.headlineSmall),
          const SizedBox(height: 8),
          const CircularProgressIndicator(),
        ],
      ),
    );
  }

  Widget _buildEmptyState(ThemeData theme) {
    return Expanded(
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.library_music,
              size: 64,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: 16),
            Text('你的音乐库', style: theme.textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text(
              '导入音乐文件夹以开始使用',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _pickFolder,
              icon: const Icon(Icons.folder_open),
              label: const Text('导入文件夹'),
            ),
          ],
        ),
      ),
    );
  }

  /// macOS 沙箱权限恢复失败的提示横幅 + 重新授权入口。
  Widget _buildSandboxWarning(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Material(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Row(
            children: [
              Icon(
                Icons.lock_outline,
                size: 16,
                color: theme.colorScheme.onErrorContainer,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '音乐文件夹访问权限已失效，请重新授权',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onErrorContainer,
                  ),
                ),
              ),
              TextButton(
                onPressed: _reauthorizeFolder,
                child: const Text('重新授权'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 重新授权音乐文件夹：重新选择文件夹并刷新 bookmark，随后重扫恢复数据。
  Future<void> _reauthorizeFolder() async {
    final path = await FilePicker.getDirectoryPath();
    if (path == null || !mounted) return;

    final bookmark = await ServiceLocator.sandbox.createBookmark(path);
    await ServiceLocator.settings.updateMusicFolderBookmark(path, bookmark);
    ServiceLocator.clearSandboxRestoreFailures();
    setState(() => _musicFolders = ServiceLocator.settings.musicFolders);
    _viewModel.startScan();
  }

  Widget _buildAppBar() {
    if (_searchActive) {
      final count = _filteredSongs.length;
      return PageToolbar(
        title: '音乐库',
        subtitle: '匹配 $count 首',
        actions: [
          ToolbarSearchField(
            hintText: '搜索歌曲',
            onChanged: (v) => setState(() => _query = v),
            onClose: _exitSearch,
          ),
        ],
      );
    }
    return PageToolbar(
      title: '音乐库',
      subtitle: _viewModel.songs.isNotEmpty
          ? '${_viewModel.songs.length} 首'
          : null,
      actions: [
        IconButton(
          icon: const Icon(Icons.search),
          tooltip: '搜索',
          onPressed: _enterSearch,
        ),
        if (_viewModel.songs.isNotEmpty)
          PopupMenuButton<SongSortOrder>(
            tooltip: '排序',
            icon: const Icon(Icons.sort),
            // 默认 iconTheme.color 是固定纯黑/纯白（M2 遗留），显式指定跟随主题。
            iconColor: Theme.of(context).colorScheme.onSurfaceVariant,
            onSelected: _viewModel.setSortOrder,
            itemBuilder: (context) => [
              for (final order in SongSortOrder.values)
                CheckedPopupMenuItem(
                  value: order,
                  checked: order == _viewModel.sortOrder,
                  child: Text(order.label),
                ),
            ],
          ),
        if (_musicFolders.isNotEmpty) ...[
          if (!_viewModel.isScanning)
            GestureDetector(
              // 桌面右键：直接强制刷新（忽略 mtime/大小变化检测，全量重解析）。
              onSecondaryTapDown: (_) => _viewModel.forceScan(),
              child: IconButton(
                onPressed: _viewModel.startScan,
                onLongPress: _viewModel.forceScan,
                icon: const Icon(Icons.refresh),
                tooltip: '重新扫描（右键/长按强制刷新）',
              ),
            ),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: _pickFolder,
            icon: const Icon(Icons.folder_open, size: 18),
            label: const Text('导入文件夹'),
          ),
        ],
      ],
    );
  }

  Widget _buildScanProgress(ThemeData theme) {
    // 进度走独立 ValueNotifier + RepaintBoundary：进度刷新只重建本区域，
    // 且固定高度（尺寸不变），不触发整页 setState / AnimatedSize / 布局传播。
    return RepaintBoundary(
      child: ValueListenableBuilder<ScanProgress?>(
        valueListenable: _viewModel.scanProgressNotifier,
        builder: (context, progress, _) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
            child: SizedBox(
              height: 48, // 固定高度：进度刷新不改变尺寸
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: 12),
                      if (progress != null && progress.phase == 'collecting')
                        const Text('正在扫描文件夹...')
                      else if (progress != null && progress.phase == 'parsing')
                        Text(
                          '正在解析元数据 ${progress.processed}/${progress.total}...',
                        )
                      else
                        const Text('正在处理...'),
                      const Spacer(),
                      if (progress != null && progress.currentFile.isNotEmpty)
                        Flexible(
                          child: Text(
                            progress.currentFile,
                            maxLines: 1,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                  ),
                  if (progress != null && progress.total > 0) ...[
                    const SizedBox(height: 8),
                    LinearProgressIndicator(
                      value: progress.processed / progress.total,
                      minHeight: 4,
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildScanResult(ThemeData theme) {
    final result = _viewModel.scanResult;
    // AnimatedCollapse 的 child 在隐藏时仍会被构建（淡出结束才卸载），而
    // 可见性条件依赖 scanResult != null，因此此处必须容忍 null 并返回空。
    if (result == null) return const SizedBox.shrink();
    return Padding(
      // 底部比顶部多留 5pt：给扫描结果文字与下方分隔线/文件夹列表之间留白。
      padding: const EdgeInsets.fromLTRB(24, 4, 24, 9),
      child: Row(
        children: [
          Icon(
            result.errors > 0 ? Icons.warning_amber : Icons.check_circle,
            size: 16,
            color: result.errors > 0
                ? Colors.orange
                : theme.colorScheme.primary,
          ),
          const SizedBox(width: 8),
          Text(
            '扫描完成：${scanResultText(result)}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFolderList(ThemeData theme) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 160),
      child: Material(
        type: MaterialType.transparency,
        clipBehavior: Clip.hardEdge,
        child: ListView.builder(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          shrinkWrap: true,
          itemCount: _musicFolders.length,
          itemBuilder: (context, index) {
            final folder = _musicFolders[index];
            // 每个卡片底部留 8pt 间距，避免多个卡片叠在一起。
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: CardSurface(
                child: ListTile(
                  dense: true,
                  leading: const Icon(Icons.folder),
                  title: Text(
                    folder,
                    style: theme.textTheme.bodySmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                  // 整个 trailing（刷新 + 移除）整体向左平移 1.5pt。
                  trailing: Transform.translate(
                    offset: const Offset(-1.5, 0),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (!_viewModel.isScanning)
                          IconButton(
                            icon: const Icon(Icons.refresh, size: 18),
                            tooltip: '重新扫描此文件夹',
                            onPressed: () => _viewModel.rescanFolder(folder),
                          ),
                        IconButton(
                          icon: const Icon(Icons.delete_outline, size: 18),
                          tooltip: '移除',
                          onPressed: () => _removeFolder(folder),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  /// 第 [index] 行的索引字母；仅按标题排序时有字母概念，其余排序返回
  /// null（滑块照常，但拖动不弹字母）。
  String? _letterForSong(Song song) {
    if (_viewModel.sortOrder != SongSortOrder.title) return null;
    return indexLetterFor(song.titleSortKey, song.title);
  }

  Widget _buildSongList(ThemeData theme, List<Song> songs) {
    return Expanded(
      child: IndexScrollbar(
        controller: _songScrollController,
        itemCount: songs.length,
        itemExtent: 72,
        letterOfIndex: (i) => _letterForSong(songs[i]),
        child: Material(
          type: MaterialType.transparency,
          clipBehavior: Clip.hardEdge,
          child: ListView.builder(
            controller: _songScrollController,
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            itemExtent: 72,
            itemCount: songs.length,
            itemBuilder: (context, index) {
              final song = songs[index];
              final isCurrentSong = song.id == _viewModel.currentSong?.id;
              return SongTile(
                song: song,
                isCurrentSong: isCurrentSong,
                isPlaying: isCurrentSong && _viewModel.isPlaying,
                onTap: () => _viewModel.playSongsFromList(songs, index),
                menuBuilder: (song) => songMenuItems(song),
                onMenuSelected: (song, value) async {
                  await handleSongMenuAction(context, song, value);
                  await _viewModel.reloadSongs();
                },
              );
            },
          ),
        ),
      ),
    );
  }
}

/// 扫描结果横幅文案：按 添加/更新/无新文件/移除/失败 拼接。
///
/// 强制刷新会把全部已存在文件重解析，此时 `updated` 可能很大而 `added` 为 0，
/// 不能沿用旧的「添加 N 首 / 无新文件」二分口径，否则会误报成「添加了全部歌曲」。
String scanResultText(ScanResult result) {
  final parts = <String>[
    if (result.added > 0) '添加 ${result.added} 首',
    if (result.updated > 0) '更新 ${result.updated} 首',
    if (result.added == 0 && result.updated == 0) '无新文件',
    if (result.markedMissing > 0) '${result.markedMissing} 首已移除',
    if (result.purged > 0) '清理 ${result.purged} 条残留',
    if (result.errors > 0) '${result.errors} 处失败',
  ];
  return parts.join('，');
}
