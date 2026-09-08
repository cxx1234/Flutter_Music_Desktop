import 'package:flutter/material.dart';

import '../../core/database/database.dart';
import '../../core/services/service_locator.dart';
import '../../widgets/detail_header.dart';
import '../../widgets/detail_top_bar.dart';
import '../../widgets/play_all_button.dart';
import '../../widgets/song_tile.dart';

/// "我的收藏"详情页：布局与播放列表详情一致（详情块 + 播放全部 + 列表），可取消喜欢。
class FavoritesPage extends StatefulWidget {
  const FavoritesPage({super.key});

  @override
  State<FavoritesPage> createState() => _FavoritesPageState();
}

class _FavoritesPageState extends State<FavoritesPage> {
  List<Song> _songs = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final songs = await ServiceLocator.songRepo.getFavoriteSongs();
    if (!mounted) return;
    setState(() {
      _songs = songs;
      _loading = false;
    });
  }

  Future<void> _unfavorite(Song song) async {
    await ServiceLocator.songRepo.toggleFavorite(song.id);
    await _load();
  }

  void _playAll() {
    if (_songs.isNotEmpty) {
      ServiceLocator.player.playFromList(_songs, startIndex: 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final player = ServiceLocator.player;

    return Scaffold(
      appBar: const DetailTopBar(title: '我的收藏'),
      body: ListenableBuilder(
        listenable: player.currentSongNotifier,
        builder: (context, _) {
          if (_loading) {
            return const Center(child: CircularProgressIndicator());
          }
          return Column(
            children: [
              // 详情块（底部 Material 阴影分隔列表区）
              DetailHeader(
                cover: Container(
                  color: theme.colorScheme.primaryContainer,
                  child: Icon(
                    Icons.favorite,
                    size: 56,
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
                ),
                title: '我的收藏',
                info: '${_songs.length} 首歌曲',
                action: PlayAllButton(
                  onPlayAll: _playAll,
                  enabled: _songs.isNotEmpty,
                ),
              ),
              if (_songs.isEmpty)
                _buildEmptyState(theme)
              else
                Expanded(
                  child: Material(
                    type: MaterialType.transparency,
                    clipBehavior: Clip.hardEdge,
                    child: ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                      itemCount: _songs.length,
                      itemBuilder: (context, index) {
                        final song = _songs[index];
                        final isCurrent = song.id == player.currentSong?.id;
                        return SongTile(
                          song: song,
                          isCurrentSong: isCurrent,
                          onTap: () => ServiceLocator.player.playFromList(
                            _songs,
                            startIndex: index,
                          ),
                          menuBuilder: (song) => const [
                            PopupMenuItem(value: 'play', child: Text('播放')),
                            PopupMenuItem(
                              value: 'unfavorite',
                              child: Text('取消喜欢'),
                            ),
                          ],
                          onMenuSelected: (song, value) {
                            if (value == 'play') {
                              ServiceLocator.player.playFromList(
                                _songs,
                                startIndex: index,
                              );
                            } else if (value == 'unfavorite') {
                              _unfavorite(song);
                            }
                          },
                        );
                      },
                    ),
                  ),
                ),
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
              Icons.favorite_border,
              size: 64,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: 16),
            Text('还没有收藏的歌曲', style: theme.textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text(
              '在歌曲的"更多"菜单里点"喜欢"即可收藏',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
