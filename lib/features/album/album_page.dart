import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/database/database.dart';
import '../../core/services/folder_watcher_service.dart';
import '../../core/services/service_locator.dart';
import '../../core/utils/grid_layout.dart';
import '../../core/utils/memoized_filter.dart';
import '../../core/utils/search_util.dart';
import '../../widgets/cached_album_art.dart';
import '../../widgets/cover_card.dart';
import '../../widgets/detail_header.dart';
import '../../widgets/detail_top_bar.dart';
import '../../widgets/page_toolbar.dart';
import '../../widgets/play_all_button.dart';
import '../../widgets/search_empty_state.dart';
import '../../widgets/song_tile.dart';
import '../../widgets/toolbar_search_field.dart';
import '../playlist/song_actions.dart';
import 'album_view_model.dart';

/// 专辑副标题：优先显示 albumArtist；无则显示「多位歌手」。
String _albumSubtitle(Album album) {
  final artist = album.albumArtist?.trim();
  return (artist == null || artist.isEmpty) ? '多位歌手' : artist;
}

class AlbumsPage extends StatefulWidget {
  /// 是否为当前选中的 tab；从非激活切回激活时重新加载数据（保活下的
  /// 跨页数据新鲜度：扫描/删文件夹等变更后切回本页能看到最新数据）。
  final bool active;

  const AlbumsPage({super.key, this.active = true});

  @override
  State<AlbumsPage> createState() => _AlbumsPageState();
}

class _AlbumsPageState extends State<AlbumsPage> {
  final _viewModel = AlbumsViewModel();
  bool _searchActive = false;
  String _query = '';
  final _albumFilterCache = QueryFilterCache<Album>();
  StreamSubscription<FolderWatcherEvent>? _folderWatcherSub;

  @override
  void initState() {
    super.initState();
    _viewModel.addListener(_onChanged);
    _viewModel.load();
    _attachFolderWatcher();
  }

  /// 订阅文件夹监听事件：正看着本 tab 时外部文件增删也能实时刷新（保活页
  /// 平时靠 `active` 激活刷新，监听覆盖「停留在本页」的即时变更）。
  void _attachFolderWatcher() {
    if (!ServiceLocator.isReady) return;
    _folderWatcherSub ??= ServiceLocator.folderWatcher.events.listen((_) {
      if (mounted) _viewModel.load();
    });
  }

  @override
  void didUpdateWidget(AlbumsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) {
      _viewModel.load();
    }
  }

  @override
  void dispose() {
    _folderWatcherSub?.cancel();
    _folderWatcherSub = null;
    _viewModel.removeListener(_onChanged);
    _viewModel.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  // ─── Search ─────────────────────────────────────────────

  List<Album> get _filteredAlbums => _albumFilterCache.get(
    normalizeQuery(_query),
    _viewModel.albums,
    (q, source) => source
        .where(
          (a) =>
              containsIgnoreCase(a.name, q) ||
              containsIgnoreCase(a.albumArtist, q),
        )
        .toList(),
  );

  void _enterSearch() => setState(() => _searchActive = true);

  void _exitSearch() => setState(() {
    _searchActive = false;
    _query = '';
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (_viewModel.loading) {
      return const Center(child: CircularProgressIndicator());
    }

    final albums = _filteredAlbums;

    return Column(
      children: [
        _buildAppBar(albums.length),
        const Divider(height: 1),
        if (albums.isEmpty)
          _searchActive
              ? Expanded(child: SearchEmptyState(query: _query))
              : _buildEmptyState(theme)
        else
          Expanded(child: _buildGrid(albums)),
      ],
    );
  }

  Widget _buildAppBar(int count) {
    return PageToolbar(
      title: '专辑',
      subtitle: _searchActive ? '匹配 $count 张' : '$count 张',
      actions: _searchActive
          ? [
              ToolbarSearchField(
                hintText: '搜索专辑',
                onChanged: (v) => setState(() => _query = v),
                onClose: _exitSearch,
              ),
            ]
          : [
              IconButton(
                icon: const Icon(Icons.search),
                tooltip: '搜索',
                onPressed: _enterSearch,
              ),
            ],
    );
  }

  Widget _buildEmptyState(ThemeData theme) {
    return Expanded(
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.album, size: 64, color: theme.colorScheme.primary),
            const SizedBox(height: 16),
            Text('暂无专辑', style: theme.textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text(
              '导入音乐文件夹后会自动按专辑归类',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGrid(List<Album> albums) {
    return Material(
      type: MaterialType.transparency,
      clipBehavior: Clip.hardEdge,
      child: GridView.builder(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        gridDelegate: const SliverGridDelegateWithClampedExtent(
          maxCrossAxisExtent: 200,
          minCrossAxisCount: 2,
          maxCrossAxisCount: 8,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 0.76,
        ),
        itemCount: albums.length,
        itemBuilder: (context, index) {
          final album = albums[index];
          return CoverCard(
            cover: CachedAlbumArt(
              albumArtFilePath: album.albumArtFilePath,
              hasEmbeddedArt: album.albumArtFilePath != null,
              size: double.infinity,
              borderRadius: 0,
            ),
            title: album.name,
            subtitle: _albumSubtitle(album),
            onTap: () => _openAlbumDetail(context, album),
          );
        },
      ),
    );
  }

  void _openAlbumDetail(BuildContext context, Album album) {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => AlbumDetailPage(album: album)));
  }
}

// ─── Album Detail Page ─────────────────────────────────────

class AlbumDetailPage extends StatelessWidget {
  final Album album;

  const AlbumDetailPage({super.key, required this.album});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: DetailTopBar(title: album.name),
      body: _AlbumDetailContent(album: album),
    );
  }
}

class _AlbumDetailContent extends StatefulWidget {
  final Album album;

  const _AlbumDetailContent({required this.album});

  @override
  State<_AlbumDetailContent> createState() => _AlbumDetailContentState();
}

class _AlbumDetailContentState extends State<_AlbumDetailContent> {
  List<Song> _songs = [];

  /// 平铺的行结构：多碟时含 `Disc N` 标题行，单碟时全是歌曲行。
  List<_AlbumRow> _rows = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final songs = await ServiceLocator.songRepo.getSongsByAlbum(
      widget.album.id,
    );
    if (mounted) {
      setState(() {
        _songs = songs;
        _rows = _buildRows(songs);
        _loading = false;
      });
    }
  }

  /// 是否多碟专辑（出现 >1 个不同的碟号）。
  bool _hasMultipleDiscs(List<Song> songs) =>
      songs.map((s) => s.discNumber ?? 1).toSet().length > 1;

  /// 按碟分组生成平铺行：多碟时在每组前插入 `Disc N` 标题行。
  List<_AlbumRow> _buildRows(List<Song> songs) {
    if (!_hasMultipleDiscs(songs)) {
      return [for (var i = 0; i < songs.length; i++) _AlbumRow.song(i)];
    }
    final indicesByDisc = <int, List<int>>{};
    for (var i = 0; i < songs.length; i++) {
      final disc = songs[i].discNumber ?? 1;
      indicesByDisc.putIfAbsent(disc, () => []).add(i);
    }
    final discs = indicesByDisc.keys.toList()..sort();
    final rows = <_AlbumRow>[];
    for (final disc in discs) {
      rows.add(_AlbumRow.header(disc));
      rows.addAll([for (final i in indicesByDisc[disc]!) _AlbumRow.song(i)]);
    }
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    final player = ServiceLocator.player;

    if (_loading) return const Center(child: CircularProgressIndicator());

    return ListenableBuilder(
      listenable: player.currentSongNotifier,
      builder: (context, _) {
        return Column(
          children: [
            // Album header（底部 Material 阴影分隔列表区）
            DetailHeader(
              cover: CachedAlbumArt(
                albumArtFilePath: widget.album.albumArtFilePath,
                hasEmbeddedArt: widget.album.albumArtFilePath != null,
                size: 140,
                borderRadius: 12,
              ),
              title: widget.album.name,
              subtitle: _albumSubtitle(widget.album),
              info: '${_songs.length} 首歌曲',
              action: PlayAllButton(
                onPlayAll: () =>
                    ServiceLocator.player.playFromList(_songs, startIndex: 0),
              ),
            ),
            // Song list
            Expanded(
              child: Material(
                type: MaterialType.transparency,
                clipBehavior: Clip.hardEdge,
                child: ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                  itemCount: _rows.length,
                  itemBuilder: (context, index) {
                    final row = _rows[index];
                    if (row.isHeader) {
                      return _DiscHeader(disc: row.disc!);
                    }
                    final song = _songs[row.songIndex];
                    final isCurrent = song.id == player.currentSong?.id;
                    return SongTile(
                      song: song,
                      isCurrentSong: isCurrent,
                      onTap: () => ServiceLocator.player.playFromList(
                        _songs,
                        startIndex: row.songIndex,
                      ),
                      leadingText: song.trackNumber?.toString() ?? '',
                      menuBuilder: (song) => songMenuItems(song),
                      onMenuSelected: (song, value) async {
                        await handleSongMenuAction(context, song, value);
                        await _load();
                      },
                    );
                  },
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 专辑详情列表中的一行：`Disc N` 标题行或歌曲行。
class _AlbumRow {
  final int? disc;
  final int songIndex;

  const _AlbumRow.header(this.disc) : songIndex = -1;
  const _AlbumRow.song(this.songIndex) : disc = null;

  bool get isHeader => disc != null;
}

/// 多碟专辑的分碟标题行。
class _DiscHeader extends StatelessWidget {
  final int disc;

  const _DiscHeader({required this.disc});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 16, 0, 4),
      child: Text(
        'Disc $disc',
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
