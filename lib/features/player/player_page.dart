import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_lyric/flutter_lyric.dart';

import '../../core/constants/layout.dart';
import '../../core/database/database.dart';
import '../../core/models/lyric_text_size.dart';
import '../../core/services/lyrics_view_model.dart';
import '../../core/services/service_locator.dart';
import '../../widgets/player_bar.dart';
import '../../widgets/song_info_card.dart';
import '../album/album_page.dart';
import '../artist/artist_page.dart';
import '../playlist/song_actions.dart';
import '../shell/shell_page.dart';
import 'lyrics_view.dart';
import 'player_ui_state.dart';
import 'player_view_model.dart';
import 'queue_view.dart';

class PlayerPage extends StatefulWidget {
  /// 全屏播放页的路由名（用于全局底栏在播放页打开时隐藏）。
  static const String routeName = '/player';

  /// 跨会话保留的播放器界面状态（App 持有，pop 不销毁）。
  final PlayerUiState uiState;

  /// 点歌手/专辑：用详情页替换播放器路由并切到对应 shell tab。
  final void Function(Widget page, NavigationItem tab) onOpenDetail;

  const PlayerPage({
    super.key,
    required this.uiState,
    required this.onOpenDetail,
  });

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

// 宽模式断点：窗口宽度低于此值时进入单栏窄模式。
// 500 ≤ 50% 窗口宽（即窗口 ≥ 1000）时转宽版（用户 2026-08-17 定，先实现看效果）。
const double _kWideBreakpoint = 1000;

// 宽模式下信息卡最小宽度（用户 2026-08-17：500~40%）。
const double _kMinInfoCardWidth = 500;

// 宽模式下信息卡最大宽度 = 窗口全宽的 40%。
const double _kInfoCardFactor = 0.40;

/// 宽模式下信息卡宽度：最窄 [_kMinInfoCardWidth]，最宽为窗口全宽的
/// [_kInfoCardFactor]。
double wideInfoCardWidth(double windowWidth) {
  return math.max(_kMinInfoCardWidth, windowWidth * _kInfoCardFactor);
}

class _PlayerPageState extends State<PlayerPage> {
  final _viewModel = PlayerViewModel();

  /// 歌词视图模型：ServiceLocator 注册的常驻服务（与 PlayerService 同生命周期，
  /// 播放页关闭再打开不重新读盘/解析；播放页外切歌也持续跟踪）。
  /// 页面只消费 controller / hasTranslationNotifier / 翻译开关，不负责销毁。
  LyricsViewModel get _lyrics => ServiceLocator.lyrics;

  // 宽模式下右栏显示队列(true)还是歌词(false)（外置于 uiState，重开保留）。
  bool get _showQueue => widget.uiState.showQueue;

  // 窄模式当前标签（默认播放器；外置于 uiState，重开保留）。
  NarrowTab get _narrowTab => widget.uiState.narrowTab;

  /// 点「播放列表/播放队列」按钮新打开队列时置 true：QueueView 挂载首帧若
  /// 当前播放项不在视口（定位按钮可见）则自动定位。页面级一次性意图，重开
  /// 播放页即复位（不影响重开页面恢复滚动位置的行为）。
  bool _locateOnQueueOpen = false;

  @override
  void initState() {
    super.initState();
    // 点击歌词行 → 跳转播放位置。
    _lyrics.controller.setOnTapLineCallback((duration) {
      ServiceLocator.player.seek(duration);
    });
    // 常驻 VM 的翻译开关与跨会话 uiState 对齐（仅值不同才重载，幂等兜底）。
    _lyrics.setShowTranslation(widget.uiState.showTranslation);
    // 打开播放页即对账：把状态对齐到引擎真实值（兜住卡死/热重载失同步）。
    WidgetsBinding.instance.addPostFrameCallback((_) => _viewModel.resync());
  }

  @override
  void dispose() {
    // 注意：歌词 VM 是 ServiceLocator 常驻服务，不在此 dispose（否则关闭播放页
    // 又会销毁歌词内容，重开重新加载的问题会回来）。
    _viewModel.dispose();
    super.dispose();
  }

  /// 歌词翻译显示开关（LyricsView 已更新 uiState，这里触发重新加载 + 写盘）。
  void _toggleTranslation() {
    _lyrics.setShowTranslation(widget.uiState.showTranslation);
    // 写盘持久化：跨重启保留翻译开关状态。
    unawaited(
      ServiceLocator.settings.setShowTranslation(
        widget.uiState.showTranslation,
      ),
    );
  }

  /// 歌词字号档位变化（LyricsView 已更新 uiState，这里写盘持久化）。
  void _onTextSizeChanged(LyricTextSize size) {
    unawaited(ServiceLocator.settings.setLyricTextSize(size));
  }

  /// 顶部栏：红绿灯预留区 + 下方 56 控件区（播放器/歌词/播放列表切换）。
  PreferredSize _buildAppBar(ThemeData theme, bool narrow) {
    return PreferredSize(
      // 总高 = 顶部红绿灯预留（macOS 45）+ 下方 56 控件区；
      // 控件固定在下方区域内，不再随 AppBar 整体垂直居中。
      preferredSize: Size.fromHeight(
        kToolbarHeight + layoutConfig.playerTopBarTopReserve,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 顶部红绿灯预留区（macOS 45，其余 0）。
          SizedBox(height: layoutConfig.playerTopBarTopReserve),
          AppBar(
            toolbarHeight: kToolbarHeight,
            leading: IconButton(
              icon: const Icon(Icons.keyboard_arrow_down),
              tooltip: '收起',
              onPressed: () => Navigator.of(context).pop(),
            ),
            title: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.music_note_rounded),
                const SizedBox(width: 8),
                // 字号与 DetailTopBar 标题一致（titleMedium）。
                Text('正在播放', style: theme.textTheme.titleMedium),
              ],
            ),
            centerTitle: false,
            actions: [
              if (narrow) ...[
                // 窄模式：切换歌词/播放队列（选中高亮 + 图标换关闭，再点退出）
                _AppBarTab(
                  icon: Icons.lyrics_rounded,
                  label: '歌词',
                  selected: _narrowTab == NarrowTab.lyrics,
                  closeWhenSelected: true,
                  onTap: () => setState(() {
                    final cur = widget.uiState.narrowTab;
                    widget.uiState.narrowTab = cur == NarrowTab.lyrics
                        ? NarrowTab.player
                        : NarrowTab.lyrics;
                  }),
                ),
                _AppBarTab(
                  icon: Icons.queue_music_rounded,
                  label: '播放列表',
                  iconSize: 24,
                  selected: _narrowTab == NarrowTab.queue,
                  closeWhenSelected: true,
                  onTap: () => setState(() {
                    final cur = widget.uiState.narrowTab;
                    if (cur == NarrowTab.queue) {
                      widget.uiState.narrowTab = NarrowTab.player;
                    } else {
                      // 从播放器/歌词切到队列：让队列打开后若当前项不在视口则自动定位。
                      _locateOnQueueOpen = true;
                      widget.uiState.narrowTab = NarrowTab.queue;
                    }
                  }),
                ),
              ] else ...[
                // 宽模式：切换右栏内容（选中高亮 + 显示文字）
                _AppBarTab(
                  icon: Icons.lyrics_rounded,
                  label: '歌词',
                  selected: !_showQueue,
                  onTap: () => setState(() => widget.uiState.showQueue = false),
                ),
                _AppBarTab(
                  icon: Icons.queue_music_rounded,
                  label: '播放列表',
                  iconSize: 24,
                  selected: _showQueue,
                  onTap: () => setState(() {
                    if (!widget.uiState.showQueue) {
                      // 从歌词切到队列：让队列打开后若当前项不在视口则自动定位。
                      _locateOnQueueOpen = true;
                    }
                    widget.uiState.showQueue = true;
                  }),
                ),
              ],
              const SizedBox(width: 8),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < _kWideBreakpoint;

        return Scaffold(
          appBar: _buildAppBar(theme, narrow),
          body: ListenableBuilder(
            listenable: _viewModel,
            builder: (context, _) {
              final song = _viewModel.currentSong;

              // ── Empty state ────────────────────────────
              if (song == null) {
                return Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.music_note_rounded,
                        size: 120,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(height: 24),
                      Text('未在播放', style: theme.textTheme.headlineMedium),
                      const SizedBox(height: 8),
                      Text(
                        '选择一首歌曲开始播放',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                );
              }

              // ── 窄模式：播放器 / 歌词·队列（整体淡入淡出过渡）──
              if (narrow) {
                return AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  child: _narrowTab == NarrowTab.player
                      ? KeyedSubtree(
                          key: const ValueKey('player'),
                          child: _buildNarrowPlayer(context, theme, song),
                        )
                      : KeyedSubtree(
                          key: const ValueKey('lyricsqueue'),
                          child: _buildNarrowLyricsQueue(context, theme, song),
                        ),
                );
              }

              // ── 宽模式：信息卡（纵排）| 队列/歌词。底部全宽播放条已抽到
              //    Scaffold.bottomNavigationBar（SnackBar 会自动顶到其上方）。──
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    width: wideInfoCardWidth(constraints.maxWidth),
                    child: _buildWideInfo(context, theme, song),
                  ),
                  Expanded(
                    child: _RightPanel(
                      viewModel: _viewModel,
                      theme: theme,
                      showQueue: _showQueue,
                      uiState: widget.uiState,
                      locateOnOpen: _locateOnQueueOpen,
                      lyricsController: _lyrics.controller,
                      hasTranslation: _lyrics.hasTranslationNotifier,
                      onToggleTranslation: _toggleTranslation,
                      onTextSizeChanged: _onTextSizeChanged,
                    ),
                  ),
                ],
              );
            },
          ),
          // 底部全宽播放条挂在 Scaffold.bottomNavigationBar：SnackBar(fixed)
          // 会被自动顶到播放条上方，不再遮挡播放控制/进度/音量。
          bottomNavigationBar: ListenableBuilder(
            listenable: _viewModel,
            builder: (context, _) {
              // 空态（无可播歌曲）不显示播放条。
              if (_viewModel.currentSong == null) {
                return const SizedBox.shrink();
              }
              return PlayerBar(
                player: ServiceLocator.player,
                theme: theme,
                onSeek: _viewModel.seek,
                compact: narrow,
              );
            },
          ),
        );
      },
    );
  }

  // ─── 信息模块构建 / 详情跳转 / 收藏 ─────────────────────

  /// 宽模式信息卡：高度足够 → 宽版纵排；高度不足（放不下封面）→ 窄版横排。
  Widget _buildWideInfo(BuildContext context, ThemeData theme, Song song) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final cardWidth = constraints.maxWidth;
        // 估算宽版纵排封面（与 SongInfoCard 内部一致：max(宽×0.8, _kMinCover=380)，
        // 宽取 padding 后的实际内容宽）。
        final coverSize = math.max((cardWidth - 80) * 0.8, 380);
        // 宽版纵排总高 ≈ 封面 + 文本区（间距28+title32+4+歌手24+4+meta16）
        // + 上下 padding 48。
        final wideNeeds = coverSize + 156;
        final useWide = constraints.maxHeight >= wideNeeds;

        final card = useWide
            ? _buildSongInfoCard(
                context,
                theme,
                song,
                isNarrow: false,
                compact: false,
              )
            : _buildSongInfoCard(
                context,
                theme,
                song,
                isNarrow: true,
                compact: false,
              );

        // 高度不足切窄版横排；两种形态都保留滚动兜底（极端矮窗）。
        return SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 40,
                  vertical: 24,
                ),
                child: card,
              ),
            ),
          ),
        );
      },
    );
  }

  /// 窄模式播放器：信息卡（高度够 → 竖版封面在上，不够 → 横版封面在左；
  /// 矮窗可滚动）。底部播放条由 Scaffold.bottomNavigationBar 承载。
  Widget _buildNarrowPlayer(BuildContext context, ThemeData theme, Song song) {
    return Column(
      children: [
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final cardWidth = constraints.maxWidth;
              // 估算竖版封面（与 SongInfoCard 纵排一致：max(宽×0.8, _kMinCover=380)，
              // 宽取 padding 后的实际内容宽）+ 文本区 + padding。
              final coverSize = math.max((cardWidth - 64) * 0.8, 380);
              final verticalNeeds = coverSize + 156;
              // 高度足够 → 竖版；不足 → 横版。
              final useVertical = constraints.maxHeight >= verticalNeeds;
              return SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 32,
                        vertical: 24,
                      ),
                      child: _InfoReveal(
                        child: _buildSongInfoCard(
                          context,
                          theme,
                          song,
                          isNarrow: !useVertical,
                          compact: false,
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  /// 窄模式歌词/队列：内容块 + 迷你信息条。底部播放条由
  /// Scaffold.bottomNavigationBar 承载。
  Widget _buildNarrowLyricsQueue(
    BuildContext context,
    ThemeData theme,
    Song song,
  ) {
    return Column(
      children: [
        Expanded(
          child: _NarrowLyricsQueue(
            viewModel: _viewModel,
            theme: theme,
            tab: _narrowTab,
            uiState: widget.uiState,
            locateOnOpen: _locateOnQueueOpen,
            lyricsController: _lyrics.controller,
            hasTranslation: _lyrics.hasTranslationNotifier,
            onToggleTranslation: _toggleTranslation,
            onTextSizeChanged: _onTextSizeChanged,
          ),
        ),
        _InfoReveal(
          child: _buildSongInfoCard(
            context,
            theme,
            song,
            isNarrow: true,
            compact: true,
          ),
        ),
      ],
    );
  }

  /// 共享 SongInfoCard 构建（like/more/详情回调由页面注入）。
  Widget _buildSongInfoCard(
    BuildContext context,
    ThemeData theme,
    Song song, {
    required bool isNarrow,
    required bool compact,
  }) {
    // 封面信息卡自成一合成层：封面绘制/涟漪等不波及播放页其它区域
    // （宽信息卡、窄竖/横版、迷你信息条共用此处）。
    return RepaintBoundary(
      child: SongInfoCard(
        song: song,
        theme: theme,
        isNarrow: isNarrow,
        compact: compact,
        onLike: _toggleLike,
        onOpenArtist: () => _openArtist(context, song),
        onOpenAlbum: () => _openAlbum(context, song),
        // 正在播放的信息卡显示的是当前曲（已在队列中）→ 用专用菜单，
        // 不含「播放下一首 / 添加到播放队列」等队列操作。
        menuBuilder: currentSongMenuItems,
        onMenuSelected: (s, v) => handleSongMenuAction(context, s, v),
      ),
    );
  }

  /// 收藏切换（引擎 + 队列刷新，UI 经 notify 自动更新）。
  void _toggleLike() {
    ServiceLocator.player.toggleFavoriteForCurrent();
  }

  // 跳歌手详情：优先按 FK 取，其次按名字回退（兜底老数据）。
  // 打开即关掉播放器（详情页替换其路由）并让 Shell 切到「歌手」tab。
  Future<void> _openArtist(BuildContext context, Song song) async {
    final db = ServiceLocator.database;
    final Artist? artist = song.artistId != null
        ? await db.getArtistById(song.artistId!)
        : null;
    final resolved =
        artist ??
        (song.artist != null ? await db.getArtistByName(song.artist!) : null);
    if (resolved == null || !context.mounted) return;
    widget.onOpenDetail(
      ArtistDetailPage(artist: resolved),
      NavigationItem.artists,
    );
  }

  // 跳专辑详情：优先按 FK 取，其次按名字回退（兜底老数据）。
  Future<void> _openAlbum(BuildContext context, Song song) async {
    final db = ServiceLocator.database;
    final Album? byId = song.albumId != null
        ? await db.getAlbumById(song.albumId!)
        : null;
    final resolved =
        byId ??
        (song.album != null
            ? song.artistId != null
                  ? await db.getAlbumByNameAndArtist(
                      song.album!,
                      song.artistId!,
                    )
                  : await db.getAlbumByName(song.album!)
            : null);
    if (resolved == null || !context.mounted) return;
    widget.onOpenDetail(
      AlbumDetailPage(album: resolved),
      NavigationItem.albums,
    );
  }
}

// ─── 共享切换过渡：歌词 ↔ 播放列表（淡入 + 朝标签方向轻滑）────

class _FadeSlideTransition extends StatelessWidget {
  /// 滑动方向：+1 向右（切到播放列表），-1 向左（切到歌词）。
  final int direction;
  final Animation<double> animation;
  final Widget child;

  const _FadeSlideTransition({
    required this.direction,
    required this.animation,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: animation,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: Offset(direction * 0.12, 0),
          end: Offset.zero,
        ).animate(animation),
        child: child,
      ),
    );
  }
}

// ─── 窄版歌词/队列模式：内容块 + 迷你播放器，切换时同步滑动 ──

class _NarrowLyricsQueue extends StatefulWidget {
  final PlayerViewModel viewModel;
  final ThemeData theme;

  /// 当前标签（lyrics 或 queue）。
  final NarrowTab tab;

  /// 跨会话播放器界面状态（转交给 QueueView 恢复滚动）。
  final PlayerUiState uiState;

  /// 点「播放列表」按钮打开队列时置 true（转交 QueueView 首帧定位）。
  final bool locateOnOpen;

  /// 歌词控制器（页面级共享，宽/窄两处同一实例）。
  final LyricController lyricsController;

  /// 当前歌词是否含翻译副行（无翻译时禁用翻译开关）。
  final ValueListenable<bool>? hasTranslation;

  /// 翻译显示开关变化回调（页面级，触发歌词重载）。
  final VoidCallback? onToggleTranslation;

  /// 歌词字号档位变化回调（页面级，负责写盘持久化）。
  final ValueChanged<LyricTextSize>? onTextSizeChanged;

  const _NarrowLyricsQueue({
    required this.viewModel,
    required this.theme,
    required this.tab,
    required this.uiState,
    required this.lyricsController,
    this.hasTranslation,
    this.onToggleTranslation,
    this.onTextSizeChanged,
    this.locateOnOpen = false,
  });

  @override
  State<_NarrowLyricsQueue> createState() => _NarrowLyricsQueueState();
}

class _NarrowLyricsQueueState extends State<_NarrowLyricsQueue> {
  // 切换方向：+1 右（切到播放列表），-1 左（切到歌词）。
  int _direction = 1;

  @override
  void didUpdateWidget(_NarrowLyricsQueue oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.tab != oldWidget.tab) {
      _direction = widget.tab == NarrowTab.queue ? 1 : -1;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isQueue = widget.tab == NarrowTab.queue;
    // 内容块：歌词 ↔ 队列（淡入 + 朝标签方向滑动）。
    // 迷你信息条与底部播放条由页面在下方叠加。
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 250),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) => _FadeSlideTransition(
        direction: _direction,
        animation: animation,
        child: child,
      ),
      child: isQueue
          ? KeyedSubtree(
              key: const ValueKey('queue'),
              child: QueueView(
                viewModel: widget.viewModel,
                theme: widget.theme,
                isNarrow: true,
                uiState: widget.uiState,
                locateOnOpen: widget.locateOnOpen,
              ),
            )
          : KeyedSubtree(
              key: const ValueKey('lyrics'),
              child: LyricsView(
                controller: widget.lyricsController,
                theme: widget.theme,
                uiState: widget.uiState,
                isNarrow: true,
                hasTranslation: widget.hasTranslation,
                onToggleTranslation: widget.onToggleTranslation,
                onTextSizeChanged: widget.onTextSizeChanged,
              ),
            ),
    );
  }
}

// ─── 信息块浮现动画（切换播放器↔歌词/队列时，info 模块缩放淡入）──

class _InfoReveal extends StatelessWidget {
  final Widget child;

  const _InfoReveal({required this.child});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.9, end: 1.0),
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
      builder: (context, t, child) {
        return Transform.scale(
          scale: t,
          alignment: Alignment.center,
          child: child,
        );
      },
      child: child,
    );
  }
}

// ─── Right panel: lyrics / queue content ─────────────────────

class _RightPanel extends StatefulWidget {
  final PlayerViewModel viewModel;
  final ThemeData theme;
  final bool showQueue;

  /// 跨会话播放器界面状态（转交给 QueueView 恢复滚动）。
  final PlayerUiState uiState;

  /// 点「播放列表」按钮打开队列时置 true（转交 QueueView 首帧定位）。
  final bool locateOnOpen;

  /// 歌词控制器（页面级共享，宽/窄两处同一实例）。
  final LyricController lyricsController;

  /// 当前歌词是否含翻译副行（无翻译时禁用翻译开关）。
  final ValueListenable<bool>? hasTranslation;

  /// 翻译显示开关变化回调（页面级，触发歌词重载）。
  final VoidCallback? onToggleTranslation;

  /// 歌词字号档位变化回调（页面级，负责写盘持久化）。
  final ValueChanged<LyricTextSize>? onTextSizeChanged;

  const _RightPanel({
    required this.viewModel,
    required this.theme,
    required this.showQueue,
    required this.uiState,
    required this.lyricsController,
    this.hasTranslation,
    this.onToggleTranslation,
    this.onTextSizeChanged,
    this.locateOnOpen = false,
  });

  @override
  State<_RightPanel> createState() => _RightPanelState();
}

class _RightPanelState extends State<_RightPanel> {
  // 切换方向：+1 向右（切到播放列表），-1 向左（切到歌词）。
  int _direction = 1;

  @override
  void didUpdateWidget(_RightPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.showQueue != oldWidget.showQueue) {
      // 内容朝所点标签方向移动：播放列表（右）→ +1，歌词（左）→ -1。
      _direction = widget.showQueue ? 1 : -1;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // ── Content（队列 ↔ 歌词：淡入 + 朝标签方向轻滑）────
        Expanded(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 250),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            transitionBuilder: (child, animation) => _FadeSlideTransition(
              direction: _direction,
              animation: animation,
              child: child,
            ),
            child: widget.showQueue
                ? KeyedSubtree(
                    key: const ValueKey('queue'),
                    child: QueueView(
                      viewModel: widget.viewModel,
                      theme: widget.theme,
                      uiState: widget.uiState,
                      locateOnOpen: widget.locateOnOpen,
                    ),
                  )
                : KeyedSubtree(
                    key: const ValueKey('lyrics'),
                    child: LyricsView(
                      controller: widget.lyricsController,
                      theme: widget.theme,
                      uiState: widget.uiState,
                      hasTranslation: widget.hasTranslation,
                      onToggleTranslation: widget.onToggleTranslation,
                      onTextSizeChanged: widget.onTextSizeChanged,
                    ),
                  ),
          ),
        ),
      ],
    );
  }
}

// ─── AppBar tab（切换歌词/播放列表/右栏内容，选中高亮+文字）────

class _AppBarTab extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  /// 图标尺寸（播放列表因字形偏小用 22，其余 20）；不影响墨迹/命中区。
  final double iconSize;

  /// 选中时把图标换成「关闭」、tooltip 变「关闭」（窄模式标签用，再点退出）。
  final bool closeWhenSelected;

  const _AppBarTab({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.iconSize = 20,
    this.closeWhenSelected = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 未选中=仅图标+tooltip；选中=高亮 + 图标换「关闭」（可选）+ 文本（再点退出）。
    final displayIcon = closeWhenSelected && selected ? Icons.close : icon;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Material(
        color: selected
            ? theme.colorScheme.primaryContainer
            : Colors.transparent,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: Tooltip(
            message: closeWhenSelected && selected ? '关闭' : label,
            child: SizedBox(
              // 固定墨迹高度（不随图标尺寸变化）。
              height: 36,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      displayIcon,
                      size: iconSize,
                      color: selected
                          ? theme.colorScheme.onPrimaryContainer
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                    if (selected) ...[
                      const SizedBox(width: 6),
                      Text(
                        label,
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: theme.colorScheme.onPrimaryContainer,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
