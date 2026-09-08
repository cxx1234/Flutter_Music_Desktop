import 'package:file_picker/file_picker.dart';
import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';

import '../../core/database/database.dart';
import '../../core/services/service_locator.dart';
import '../../widgets/cached_album_art.dart';
import '../../widgets/detail_header.dart';
import '../../widgets/detail_top_bar.dart';
import '../../widgets/play_all_button.dart';
import '../../widgets/song_tile.dart';
import 'add_songs_sheet.dart';
import 'playlist_cover.dart';
import 'playlist_io.dart';

/// 播放列表详情页：头部 + 可拖动排序的歌曲列表 + 加歌/重命名/删除。
class PlaylistDetailPage extends StatefulWidget {
  final Playlist playlist;

  const PlaylistDetailPage({super.key, required this.playlist});

  @override
  State<PlaylistDetailPage> createState() => _PlaylistDetailPageState();
}

class _PlaylistDetailPageState extends State<PlaylistDetailPage> {
  List<Song> _songs = [];
  bool _loading = true;
  bool _reorderMode = false;
  late String _name = widget.playlist.name;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final songs = await ServiceLocator.songRepo.getSongsInPlaylist(
      widget.playlist.id,
    );
    if (!mounted) return;
    setState(() {
      _songs = songs;
      _loading = false;
    });
  }

  void _playAll() {
    if (_songs.isNotEmpty) {
      ServiceLocator.player.playFromList(_songs, startIndex: 0);
    }
  }

  /// 按名称排序（复用 title_sort_key 拼音键，升序）整理列表：
  /// 重写 position 后重载，排序可随时切回手动拖拽调整。
  Future<void> _sortByName() async {
    if (_songs.length < 2) return;
    // 稳定排序：主键 titleSortKey（拼音，缺失排末尾），相同再按原标题兜底。
    final ordered = [..._songs]
      ..sort((a, b) {
        final ka = a.titleSortKey;
        final kb = b.titleSortKey;
        if (ka == null && kb == null) return a.title.compareTo(b.title);
        if (ka == null) return 1;
        if (kb == null) return -1;
        final c = ka.compareTo(kb);
        return c != 0 ? c : a.title.compareTo(b.title);
      });
    await ServiceLocator.songRepo.reorderSongsInPlaylist(widget.playlist.id, [
      for (final s in ordered) s.id,
    ]);
    if (!mounted) return;
    // 名称排序后退出手动排序模式，列表按新顺序呈现。
    if (_reorderMode) setState(() => _reorderMode = false);
    await _load();
  }

  Future<void> _addSongs() async {
    final added = await showAddSongsSheet(context, widget.playlist.id);
    if (added != null && added > 0) {
      await _load();
    }
  }

  Future<void> _exportM3u() async {
    final ({Uint8List bytes, int count}) content;
    try {
      content = await buildPlaylistM3u8(widget.playlist.id);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('导出失败：无法生成播放列表内容')));
      return;
    }

    final uri = await FilePicker.saveFile(
      dialogTitle: '导出播放列表',
      fileName: '$_name.m3u8',
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

  Future<void> _rename() async {
    final controller = TextEditingController(text: _name);
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
    final ok = await ServiceLocator.songRepo.updatePlaylist(
      PlaylistsCompanion(
        name: Value(name),
        updatedAt: Value(DateTime.now().millisecondsSinceEpoch),
      ),
      widget.playlist.id,
    );
    if (ok && mounted) {
      setState(() => _name = name);
    }
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除播放列表'),
        content: Text('确定删除"$_name"吗？此操作不可撤销。'),
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
    if (confirmed != true) return;
    await ServiceLocator.songRepo.deletePlaylist(widget.playlist.id);
    if (mounted) Navigator.pop(context);
  }

  Future<void> _removeSong(Song song) async {
    await ServiceLocator.songRepo.removeSongFromPlaylist(
      widget.playlist.id,
      song.id,
    );
    await _load();
  }

  Future<void> _onReorder(int oldIndex, int newIndex) async {
    // onReorderItem 已把 newIndex 调整为移除后的目标位置。
    await ServiceLocator.songRepo.moveSongInPlaylist(
      widget.playlist.id,
      oldIndex,
      newIndex,
    );
    await _load();
  }

  void _toggleReorderMode() {
    setState(() => _reorderMode = !_reorderMode);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final player = ServiceLocator.player;

    return Scaffold(
      appBar: DetailTopBar(
        title: _name,
        actions: [
          IconButton(
            icon: Icon(_reorderMode ? Icons.check : Icons.reorder_rounded),
            tooltip: _reorderMode ? '完成排序' : '手动排序',
            onPressed: _toggleReorderMode,
          ),
          IconButton(
            icon: const Icon(Icons.playlist_add),
            tooltip: '添加歌曲',
            onPressed: _addSongs,
          ),
          PopupMenuButton<String>(
            tooltip: '更多',
            // 默认 iconTheme.color 是固定纯黑/纯白（M2 遗留），显式指定跟随主题。
            iconColor: theme.colorScheme.onSurfaceVariant,
            onSelected: (value) {
              if (value == 'rename') _rename();
              if (value == 'delete') _delete();
              if (value == 'export') _exportM3u();
              if (value == 'sortByName') _sortByName();
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'export', child: Text('导出为 M3U…')),
              PopupMenuItem(value: 'sortByName', child: Text('按名称排序')),
              PopupMenuItem(value: 'rename', child: Text('重命名')),
              PopupMenuItem(value: 'delete', child: Text('删除')),
            ],
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: player.currentSongNotifier,
        builder: (context, _) {
          return Column(
            children: [
              // 头部（底部 Material 阴影分隔列表区）
              DetailHeader(
                cover: PlaylistCover(
                  playlistId: widget.playlist.id,
                  size: 140,
                  borderRadius: 12,
                  revision: _songs.length,
                ),
                title: _name,
                info: '${_songs.length} 首歌曲',
                action: PlayAllButton(
                  onPlayAll: _playAll,
                  enabled: _songs.isNotEmpty,
                ),
              ),
              if (_loading)
                const Expanded(
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (_songs.isEmpty)
                _buildEmptyState(theme)
              else
                Expanded(child: _buildSongListView(theme)),
            ],
          );
        },
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
              Icons.playlist_add,
              size: 64,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: 16),
            Text('播放列表为空', style: theme.textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text(
              '点击右上角"添加歌曲"按钮加入歌曲',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 歌曲列表：默认普通列表（显示序号，不可拖拽）；开启排序后为可拖拽列表。
  Widget _buildSongListView(ThemeData theme) {
    final list = _reorderMode
        ? ReorderableListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            buildDefaultDragHandles: false,
            onReorderItem: _onReorder,
            itemCount: _songs.length,
            itemBuilder: (context, index) => _songRow(theme, index),
          )
        : ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            itemCount: _songs.length,
            itemBuilder: (context, index) => _songRow(theme, index),
          );
    return Material(
      type: MaterialType.transparency,
      clipBehavior: Clip.hardEdge,
      child: list,
    );
  }

  Widget _songRow(ThemeData theme, int index) {
    final song = _songs[index];
    final isCurrent = song.id == ServiceLocator.player.currentSong?.id;
    return _buildSongRow(theme, song, index, isCurrent);
  }

  Widget _buildSongRow(ThemeData theme, Song song, int index, bool isCurrent) {
    return SongTile(
      key: ValueKey(song.id),
      song: song,
      isCurrentSong: isCurrent,
      onTap: () =>
          ServiceLocator.player.playFromList(_songs, startIndex: index),
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 固定宽度槽位：序号与拖拽把手同宽、居中，切换排序模式宽度不跳动。
          // 排序模式下整个槽位都是拖拽命中区。
          if (_reorderMode)
            ReorderableDragStartListener(
              index: index,
              child: SizedBox(
                width: 36,
                height: 32,
                child: Center(
                  child: Icon(
                    Icons.drag_handle,
                    size: 20,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            )
          else
            SizedBox(
              width: 36,
              height: 32,
              child: Center(
                child: Text(
                  '${index + 1}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: isCurrent
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          // 序号/拖拽把手与封面间距（翻倍，避免贴住封面）
          const SizedBox(width: 8),
          SizedBox(
            width: 40,
            height: 40,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: CachedAlbumArt(
                albumArtFilePath: song.albumArtFilePath,
                hasEmbeddedArt: song.hasEmbeddedArt == 1,
                size: 40,
                borderRadius: 6,
              ),
            ),
          ),
        ],
      ),
      menuBuilder: (song) => const [
        PopupMenuItem(value: 'play', child: Text('播放')),
        PopupMenuItem(value: 'remove', child: Text('从播放列表移除')),
      ],
      onMenuSelected: (song, value) {
        if (value == 'play') {
          ServiceLocator.player.playFromList(_songs, startIndex: index);
        } else if (value == 'remove') {
          _removeSong(song);
        }
      },
    );
  }
}
