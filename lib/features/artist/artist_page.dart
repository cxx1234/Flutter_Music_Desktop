import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/database/database.dart';
import '../../core/services/folder_watcher_service.dart';
import '../../core/services/service_locator.dart';
import '../../core/utils/index_letters.dart';
import '../../core/utils/memoized_filter.dart';
import '../../core/utils/search_util.dart';
import '../../widgets/cached_album_art.dart';
import '../../widgets/detail_top_bar.dart';
import '../../widgets/index_scrollbar.dart';
import '../../widgets/list_item_tile.dart';
import '../../widgets/page_toolbar.dart';
import '../../widgets/play_all_button.dart';
import '../../widgets/search_empty_state.dart';
import '../../widgets/song_tile.dart';
import '../../widgets/toolbar_search_field.dart';
import '../album/album_page.dart';
import '../playlist/song_actions.dart';
import 'artist_view_model.dart';

class ArtistsPage extends StatefulWidget {
  /// 是否为当前选中的 tab；从非激活切回激活时重新加载数据（保活下的
  /// 跨页数据新鲜度：扫描/删文件夹等变更后切回本页能看到最新数据）。
  final bool active;

  const ArtistsPage({super.key, this.active = true});

  @override
  State<ArtistsPage> createState() => _ArtistsPageState();
}

class _ArtistsPageState extends State<ArtistsPage> {
  final _viewModel = ArtistsViewModel();
  bool _searchActive = false;
  String _query = '';
  final _artistFilterCache = QueryFilterCache<Artist>();
  final _scrollController = ScrollController();
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
  void didUpdateWidget(ArtistsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) {
      _viewModel.load();
    }
  }

  @override
  void dispose() {
    _folderWatcherSub?.cancel();
    _folderWatcherSub = null;
    _scrollController.dispose();
    _viewModel.removeListener(_onChanged);
    _viewModel.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  // ─── Search ─────────────────────────────────────────────

  List<Artist> get _filteredArtists => _artistFilterCache.get(
    normalizeQuery(_query),
    _viewModel.artists,
    (q, source) => source.where((a) => containsIgnoreCase(a.name, q)).toList(),
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

    final artists = _filteredArtists;

    return Column(
      children: [
        _buildAppBar(artists.length),
        const Divider(height: 1),
        if (artists.isEmpty)
          _searchActive
              ? Expanded(child: SearchEmptyState(query: _query))
              : _buildEmptyState(theme)
        else
          Expanded(child: _buildList(theme, artists)),
      ],
    );
  }

  Widget _buildAppBar(int count) {
    return PageToolbar(
      title: '歌手',
      subtitle: _searchActive ? '匹配 $count 位' : '$count 位',
      actions: _searchActive
          ? [
              ToolbarSearchField(
                hintText: '搜索歌手',
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
            Icon(Icons.person, size: 64, color: theme.colorScheme.primary),
            const SizedBox(height: 16),
            Text('暂无歌手', style: theme.textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text(
              '导入音乐文件夹后会自动按歌手归类',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildList(ThemeData theme, List<Artist> artists) {
    return IndexScrollbar(
      controller: _scrollController,
      itemCount: artists.length,
      itemExtent: 72,
      letterOfIndex: (i) =>
          indexLetterFor(artists[i].nameSortKey, artists[i].name),
      child: Material(
        type: MaterialType.transparency,
        clipBehavior: Clip.hardEdge,
        child: ListView.builder(
          controller: _scrollController,
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          itemExtent: 72,
          itemCount: artists.length,
          itemBuilder: (context, index) {
            final artist = artists[index];
            final stats = _viewModel.statsFor(artist);
            final albumCount = stats.albumCount;
            final songCount = stats.songCount;
            return ListItemTile(
              leading: CircleAvatar(
                // 44 直径，与 SongTile 默认封面同宽，保证标题位置一致
                radius: 22,
                backgroundColor: theme.colorScheme.primaryContainer,
                child: Text(
                  artist.name.isNotEmpty ? artist.name[0].toUpperCase() : '?',
                  style: TextStyle(
                    color: theme.colorScheme.onPrimaryContainer,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              title: artist.name,
              subtitle:
                  '$songCount 首歌曲${albumCount > 0 ? ' · $albumCount 张专辑' : ''}',
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _openArtistDetail(context, artist),
            );
          },
        ),
      ),
    );
  }

  void _openArtistDetail(BuildContext context, Artist artist) {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => ArtistDetailPage(artist: artist)));
  }
}

// ─── Artist Detail Page ────────────────────────────────────

class ArtistDetailPage extends StatelessWidget {
  final Artist artist;

  const ArtistDetailPage({super.key, required this.artist});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: DetailTopBar(title: artist.name),
      // 监听"当前歌曲"去重通知器：切歌时实时刷新行内 isCurrent 高亮，与其他
      // 详情页（专辑/播放列表/我的收藏）的 ListenableBuilder 用法保持一致。
      body: ListenableBuilder(
        listenable: ServiceLocator.player.currentSongNotifier,
        builder: (context, _) => _ArtistDetailContent(artist: artist),
      ),
    );
  }
}

class _ArtistDetailContent extends StatefulWidget {
  final Artist artist;

  const _ArtistDetailContent({required this.artist});

  @override
  State<_ArtistDetailContent> createState() => _ArtistDetailContentState();
}

class _ArtistDetailContentState extends State<_ArtistDetailContent> {
  List<Album> _albums = [];
  List<Song> _songs = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // 只取该歌手歌曲，再按 songs 的 albumId 集合定向查专辑——
    // 不再无谓地全表拉取所有专辑再内存过滤（旧实现 getAllAlbums）。
    final songs = await ServiceLocator.songRepo.getSongsByArtist(
      widget.artist.id,
    );
    final ids = <int>{
      for (final s in songs)
        if (s.albumId != null) s.albumId!,
    };
    final fetched = await ServiceLocator.songRepo.getAlbumsByIds(ids);

    // 专辑按该歌手歌曲的 albumId 派生：合集/多歌手专辑每位参与歌手都能看到。
    final albumById = {for (final a in fetched) a.id: a};
    final albumsById = <int, Album>{};
    for (final s in songs) {
      final albumId = s.albumId;
      if (albumId == null) continue;
      final album = albumById[albumId];
      if (album != null) albumsById[albumId] = album;
    }
    final albums = albumsById.values.toList()
      ..sort((a, b) {
        final byYear = (a.year ?? 0).compareTo(b.year ?? 0);
        if (byYear != 0) return byYear;
        return a.name.compareTo(b.name);
      });

    if (mounted) {
      setState(() {
        _albums = albums;
        _songs = songs;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());

    // 有界滚动区含 ListTile(SongTile) 交互项，外包透明 Material + Clip.hardEdge
    // 防止墨迹渗入上方标题区（项目约定）。
    return Material(
      type: MaterialType.transparency,
      clipBehavior: Clip.hardEdge,
      child: CustomScrollView(
        slivers: [
          // Albums section
          if (_albums.isNotEmpty) ...[
            SliverToBoxAdapter(
              child: _SectionHeader(title: '专辑 (${_albums.length})'),
            ),
            SliverToBoxAdapter(
              child: Padding(
                // 专辑卡片区域顶部留 5pt，与上方标题栏隔开
                padding: const EdgeInsets.only(top: 5, left: 10),
                child: Column(
                  children: [
                    SizedBox(
                      // 高度 210：容纳封面 150 + 最多两行标题 + 年份行，年份不会被挤掉
                      height: 210,
                      child: ListView.builder(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        itemCount: _albums.length,
                        itemBuilder: (context, index) {
                          final album = _albums[index];
                          return _ArtistAlbumCard(album: album);
                        },
                      ),
                    ),
                    // 横向列表下方的空白区域，分隔专辑卡片与「歌曲」标题
                    const SizedBox(height: 16),
                  ],
                ),
              ),
            ),
          ],

          // Songs section
          SliverToBoxAdapter(
            child: _SectionHeader(
              title: '歌曲 (${_songs.length})',
              trailing: PlayAllButton(
                onPlayAll: () =>
                    ServiceLocator.player.playFromList(_songs, startIndex: 0),
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(24, 0, 8, 16),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate((context, index) {
                final song = _songs[index];
                final player = ServiceLocator.player;
                final isCurrent = song.id == player.currentSong?.id;
                return SongTile(
                  song: song,
                  isCurrentSong: isCurrent,
                  onTap: () => ServiceLocator.player.playFromList(
                    _songs,
                    startIndex: index,
                  ),
                  menuBuilder: (song) => songMenuItems(song),
                  onMenuSelected: (song, value) async {
                    await handleSongMenuAction(context, song, value);
                    await _load();
                  },
                );
              }, childCount: _songs.length),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  final Widget? trailing;

  const _SectionHeader({required this.title, this.trailing});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

class _ArtistAlbumCard extends StatelessWidget {
  final Album album;

  const _ArtistAlbumCard({required this.album});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 卡片自带透明 Material + Clip.hardEdge：InkWell 的墨迹画在最近的 Material
    // 上，若不包这一层会画到外层 CustomScrollView 的 Material，水波/hover 高亮
    // 会渗出横向列表边界；圆角 8 与封面一致，高亮被裁剪在卡片内。
    return Padding(
      padding: const EdgeInsets.only(right: 12),
      child: Material(
        type: MaterialType.transparency,
        clipBehavior: Clip.hardEdge,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          // 悬停/按下高亮，与其余可交互卡片保持一致
          hoverColor: theme.colorScheme.onSurface.withValues(alpha: 0.06),
          onTap: () {
            // 跳转正式专辑详情页（DetailTopBar + 分碟 + 播放全部）
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => AlbumDetailPage(album: album)),
            );
          },
          // 卡片内部 2pt padding：内容内缩，墨迹仍覆盖整卡，hover 高亮更清晰
          child: Padding(
            padding: const EdgeInsets.all(2),
            child: SizedBox(
              width: 150,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: SizedBox(
                      width: 150,
                      height: 150,
                      child: CachedAlbumArt(
                        albumArtFilePath: album.albumArtFilePath,
                        hasEmbeddedArt: album.albumArtFilePath != null,
                        size: 150,
                        borderRadius: 8,
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  // 文本区弹性填满剩余高度：标题在上、年份沉底（spaceBetween），
                  // 两行标题 + 年份也放得下；单行标题时中间空白由 spaceBetween 吸收，
                  // 底部不显空。标题 Flexible 防超长溢出。
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Flexible(
                          child: Text(
                            album.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        // 年份独立文本块：更小一号、颜色更灰；无年份则整块隐藏
                        if (album.year != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            '(${album.year})',
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontSize: 11,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
