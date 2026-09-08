import 'package:flutter/material.dart';

import '../../core/database/database.dart';
import '../../core/services/player_service.dart';
import '../../widgets/song_tile.dart';
import 'player_ui_state.dart';
import 'player_view_model.dart';

/// 队列底部状态行文案：跟随循环/随机模式变化。
///
/// - off + 未随机：顺序播放（滚动到底显示「· 到底了」）
/// - off + 随机：随机播放（滚动到底显示「· 到底了」）
/// - all：循环整个列表（随机循环时也显示「随机播放」，到底不变）
/// - one：单曲循环
///
/// [atBottom]：列表滚动到底时传 true，追加「· 到底了」（仅不循环模式有意义）。
String queueFooterText(
  PlayerRepeatMode repeatMode,
  bool isShuffled, {
  bool atBottom = false,
}) {
  switch (repeatMode) {
    case PlayerRepeatMode.one:
      return '单曲循环播放';
    case PlayerRepeatMode.all:
      return isShuffled ? '随机播放' : '循环列表播放';
    case PlayerRepeatMode.off:
      final base = isShuffled ? '随机播放' : '顺序播放';
      return atBottom ? '$base · 到底了' : base;
  }
}

/// 队列底部状态行图标：与文案同步。
IconData _queueFooterIcon(PlayerRepeatMode repeatMode, bool isShuffled) {
  switch (repeatMode) {
    case PlayerRepeatMode.one:
      return Icons.repeat_one_rounded;
    case PlayerRepeatMode.all:
      return isShuffled ? Icons.shuffle_rounded : Icons.repeat_rounded;
    case PlayerRepeatMode.off:
      return isShuffled ? Icons.shuffle_rounded : Icons.playlist_play_rounded;
  }
}

/// 判断固定行高列表的第 [index] 项是否落在可见区间 [pixels, pixels+viewportDimension) 内。
///
/// 部分可见也算可见；只有完全在视口外才返回 false（用于「定位」按钮显隐）。
bool isQueueItemInView({
  required int index,
  required double itemExtent,
  required double pixels,
  required double viewportDimension,
}) {
  final top = index * itemExtent;
  final bottom = top + itemExtent;
  return bottom > pixels && top < pixels + viewportDimension;
}

/// 当前播放队列视图：清空 / 选择删除 / 手动排序。
class QueueView extends StatefulWidget {
  final PlayerViewModel viewModel;
  final ThemeData theme;

  /// 窄版内嵌时传 true：「共 N 首」左侧加 margin（宽版右栏为 false，无 margin）。
  final bool isNarrow;

  /// 跨会话播放器界面状态：滚动位置/当前歌在此读写，重开不重滚。
  final PlayerUiState uiState;

  /// 点「播放列表」按钮新打开队列时为 true：挂载后若当前播放项不在视口内
  /// （即「定位」按钮可见）则自动定位到当前播放项。
  final bool locateOnOpen;

  const QueueView({
    super.key,
    required this.viewModel,
    required this.theme,
    this.isNarrow = false,
    required this.uiState,
    this.locateOnOpen = false,
  });

  @override
  State<QueueView> createState() => _QueueViewState();
}

class _QueueViewState extends State<QueueView> {
  bool _deleteMode = false;
  bool _reorderMode = false;
  final Set<int> _selectedIndices = {};
  late final ScrollController _scrollController;

  // 顶部边缘淡出：列表滚离顶部时淡入（回顶消失）。
  bool _topFaded = false;
  // 底部边缘淡出：列表滚离底部时淡入（回底消失）。
  bool _bottomFaded = false;

  // 「定位」按钮：当前高亮项不在视口内时显示。
  bool _showLocate = false;

  // 上次已知的当前播放索引；变化时自动滚动到高亮项。
  int? _lastCurrentIndex;

  PlayerViewModel get vm => widget.viewModel;
  ThemeData get theme => widget.theme;

  // 展示用队列与当前下标：随机开启时用播放排列（effective），否则用逻辑队列。
  List<Song> get _displayQueue => vm.isShuffled ? vm.effectiveQueue : vm.queue;
  int get _displayIndex => vm.isShuffled ? vm.effectiveIndex : vm.currentIndex;

  // 展示位置 → 逻辑下标（供 jumpTo/removeFromQueue 使用）。
  int _toLogicalIndex(int displayIndex) =>
      vm.isShuffled ? vm.logicalIndexForEffective(displayIndex) : displayIndex;

  @override
  void initState() {
    super.initState();
    // 用上次会话保存的偏移初始化（重开同歌 → 恢复位置，不重滚）。
    _scrollController = ScrollController(
      initialScrollOffset: widget.uiState.queueScrollOffset,
    );
    _lastCurrentIndex = _displayIndex;
    // 重开判断：当前歌与上次会话相同 → 恢复滚动位置；不同（离开期间切歌）→ 跟随当前歌。
    final follow = vm.currentSong?.id != widget.uiState.lastCurrentSongId;
    widget.uiState.lastCurrentSongId = vm.currentSong?.id;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.locateOnOpen) {
        // 点「播放列表」按钮新打开队列：当前播放项不在视口（等同「定位」按钮
        // 可见）→ 自动定位到当前项；已在视口内则仅同步边缘淡出。
        if (_scrollController.hasClients &&
            !_isCurrentInView(_scrollController.position)) {
          _scrollToCurrent();
        } else {
          _refreshFadeState();
        }
      } else if (follow) {
        _scrollToCurrent();
      } else {
        // 恢复位置后按偏移重算边缘淡出（避免遮罩残留）。
        _refreshFadeState();
      }
    });
  }

  @override
  void didUpdateWidget(QueueView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_lastCurrentIndex != _displayIndex) {
      _lastCurrentIndex = _displayIndex;
      widget.uiState.lastCurrentSongId = vm.currentSong?.id;
      // 当前播放项变化后自动滚动到高亮位置（删除/拖拽模式下不打扰用户）。
      if (!_deleteMode && !_reorderMode) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToCurrent());
      }
    }
  }

  @override
  void dispose() {
    // 滚动偏移已由 _handleScroll 实时写回 uiState（dispose 时 Scrollable 已
    // detach、读不到 offset，不能在此时保存）。
    _scrollController.dispose();
    super.dispose();
  }

  // 队列固定行高：itemExtent 保证滚动偏移精确（index * extent），
  // 不会像“逐行估算高度”那样在大列表下累积误差导致高亮滚动失效。
  static const double _kQueueTileExtent = 72;

  // 当前项距视口顶部的预留：避开顶部边缘淡出遮罩（约 32 高）。
  static const double _kCurrentTopInset = 30;

  // 滚动到当前播放项并置于视口顶部下方（先快后慢 easeOutCubic，400ms）。
  void _scrollToCurrent() {
    if (!mounted) return;
    final index = _displayIndex;
    final queue = _displayQueue;
    if (index < 0 || index >= queue.length) return;
    if (!_scrollController.hasClients) return;

    // 偏移 = index * 固定行高 - 顶部预留：当前项贴到视口顶部下方 30pt
    // （列表到底时钳制到底部）。
    final target = (index * _kQueueTileExtent - _kCurrentTopInset).clamp(
      0.0,
      _scrollController.position.maxScrollExtent,
    );
    _scrollController.animateTo(
      target,
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeOutCubic,
    );
  }

  void _toggleDeleteMode() {
    setState(() {
      _deleteMode = !_deleteMode;
      if (!_deleteMode) {
        _selectedIndices.clear();
      }
      _reorderMode = false;
      // 模式切换后列表重建，边缘淡出状态一并复位。
      _topFaded = false;
      _bottomFaded = false;
    });
    // 下一帧列表重建完成后，按当前滚动位置重新计算边缘淡出。
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshFadeState());
  }

  void _toggleReorderMode() {
    // 随机模式下展示的是排列坐标，与逻辑下标不一致，拖拽排序语义混乱——禁用。
    if (vm.isShuffled) return;
    setState(() {
      _reorderMode = !_reorderMode;
      if (_reorderMode) {
        _deleteMode = false;
        _selectedIndices.clear();
      }
      _topFaded = false;
      _bottomFaded = false;
    });
    // 下一帧列表重建完成后，按当前滚动位置重新计算边缘淡出。
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshFadeState());
  }

  // 按当前滚动位置重新计算边缘淡出与定位按钮（模式切换/恢复后调用）。
  void _refreshFadeState() {
    if (!mounted || !_scrollController.hasClients) return;
    final position = _scrollController.position;
    final topFaded = position.extentBefore > 0;
    final bottomFaded = position.extentAfter > 0;
    final showLocate = !_isCurrentInView(position);
    if (topFaded != _topFaded ||
        bottomFaded != _bottomFaded ||
        showLocate != _showLocate) {
      setState(() {
        _topFaded = topFaded;
        _bottomFaded = bottomFaded;
        _showLocate = showLocate;
      });
    }
  }

  Future<void> _confirmClear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空播放列表'),
        content: const Text('确定要清空当前播放列表吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await vm.clearQueue();
    }
  }

  Future<void> _deleteSelected() async {
    // 先把选中项从展示位置换算成逻辑下标，再降序删除——
    // 随机模式下若直接按展示位置删，排列位移会让下标失效。
    final sorted = _selectedIndices.map(_toLogicalIndex).toList()
      ..sort((a, b) => b.compareTo(a));
    for (final i in sorted) {
      await vm.removeFromQueue(i);
    }
    setState(() {
      _selectedIndices.clear();
      _deleteMode = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final queue = _displayQueue;
    if (queue.isEmpty) {
      return Center(
        child: Text(
          '播放列表为空',
          style: theme.textTheme.bodyLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    return Column(
      children: [
        // 工具条：仅提供表面色背景，不再有滚动阴影。
        Material(
          color: theme.colorScheme.surface,
          child: _buildToolbar(queue.length),
        ),
        Expanded(
          // 列表 + 顶部/底部边缘淡出遮罩（随滚动淡入/淡出）。
          child: Stack(
            children: [
              Positioned.fill(
                child: NotificationListener<ScrollNotification>(
                  onNotification: _handleScroll,
                  child: Material(
                    type: MaterialType.transparency,
                    clipBehavior: Clip.hardEdge,
                    child: _reorderMode
                        ? _buildReorderableList(queue)
                        : _buildList(queue),
                  ),
                ),
              ),
              // 顶部边缘淡出：滚离顶部时淡入（回顶消失）。
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: _buildFadeMask(visible: _topFaded, atTop: true),
              ),
              // 底部边缘淡出：滚离底部时淡入（回底消失）。
              // 删除/排序模式下无状态行，隐藏底部遮罩避免盖住末尾内容。
              if (!_deleteMode && !_reorderMode)
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: _buildFadeMask(visible: _bottomFaded, atTop: false),
                ),
            ],
          ),
        ),
        // 状态行：始终钉在底部。
        if (!_deleteMode && !_reorderMode)
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            color: theme.colorScheme.surface,
            child: _buildFooter(),
          ),
      ],
    );
  }

  // 当前高亮项是否在视口内（部分可见也算）——完全不可见时显示「定位」。
  bool _isCurrentInView(ScrollMetrics metrics) {
    final index = _displayIndex;
    if (index < 0 || index >= _displayQueue.length) return true;
    return isQueueItemInView(
      index: index,
      itemExtent: _kQueueTileExtent,
      pixels: metrics.pixels,
      viewportDimension: metrics.viewportDimension,
    );
  }

  // 滚动时实时保存偏移（供重开恢复）并更新两侧边缘淡出、定位按钮显隐。
  bool _handleScroll(ScrollNotification notification) {
    final metrics = notification.metrics;
    // 持续写回：与 dispose 时机解耦（dispose 时 Scrollable 已 detach，读不到 offset）。
    widget.uiState.queueScrollOffset = metrics.pixels;
    final topFaded = metrics.extentBefore > 0;
    final bottomFaded = metrics.extentAfter > 0;
    final showLocate = !_isCurrentInView(metrics);
    if (topFaded != _topFaded ||
        bottomFaded != _bottomFaded ||
        showLocate != _showLocate) {
      setState(() {
        _topFaded = topFaded;
        _bottomFaded = bottomFaded;
        _showLocate = showLocate;
      });
    }
    return false;
  }

  // 列表边缘淡出遮罩：表面色 → 透明，随滚动淡入淡出（柔和盖住内容边缘）。
  Widget _buildFadeMask({required bool visible, required bool atTop}) {
    return AnimatedOpacity(
      opacity: visible ? 1 : 0,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      child: IgnorePointer(
        child: Container(
          height: 32,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: atTop ? Alignment.topCenter : Alignment.bottomCenter,
              end: atTop ? Alignment.bottomCenter : Alignment.topCenter,
              colors: [
                theme.colorScheme.surface,
                theme.colorScheme.surface.withValues(alpha: 0),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // 播放模式合并按钮三态图标：顺序 / 列表循环 / 随机循环。
  IconData _playModeIcon(PlayerRepeatMode repeat, bool shuffled) {
    if (repeat == PlayerRepeatMode.all) {
      return shuffled ? Icons.shuffle_rounded : Icons.repeat_rounded;
    }
    return Icons.playlist_play_rounded;
  }

  String _playModeTooltip(PlayerRepeatMode repeat, bool shuffled) {
    if (repeat == PlayerRepeatMode.all) {
      return shuffled ? '随机播放' : '列表循环';
    }
    return '顺序播放';
  }

  Widget _buildToolbar(int count) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          Padding(
            padding: EdgeInsets.only(left: widget.isNarrow ? 12 : 0),
            child: Text(
              '共 $count 首',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const Spacer(),
          if (_showLocate)
            IconButton(
              icon: const Icon(Icons.my_location_rounded, size: 20),
              tooltip: '定位到当前播放',
              onPressed: _scrollToCurrent,
            ),
          if (_deleteMode) ...[
            IconButton(
              icon: const Icon(Icons.close, size: 20),
              tooltip: '取消',
              onPressed: _toggleDeleteMode,
            ),
            const SizedBox(width: 4),
            IconButton(
              icon: Icon(
                Icons.delete_rounded,
                size: 20,
                color: _selectedIndices.isNotEmpty
                    ? theme.colorScheme.error
                    : null,
              ),
              tooltip: '删除选中 (${_selectedIndices.length})',
              onPressed: _selectedIndices.isNotEmpty ? _deleteSelected : null,
            ),
          ] else if (_reorderMode) ...[
            IconButton(
              icon: const Icon(Icons.check, size: 20),
              tooltip: '完成排序',
              onPressed: _toggleReorderMode,
            ),
          ] else ...[
            // 随机模式下展示的是排列坐标，拖拽排序语义混乱——隐藏手动排序入口。
            // 条件按钮放在常驻按钮左侧：出现/消失只影响左侧，不挤动最右常驻按钮。
            if (!vm.isShuffled)
              IconButton(
                icon: const Icon(Icons.reorder_rounded, size: 20),
                tooltip: '手动排序',
                onPressed: _toggleReorderMode,
              ),
            IconButton(
              icon: const Icon(Icons.checklist_rounded, size: 20),
              tooltip: '选择删除',
              onPressed: _toggleDeleteMode,
            ),
            IconButton(
              icon: const Icon(Icons.delete_sweep_rounded, size: 20),
              tooltip: '清空列表',
              onPressed: _confirmClear,
            ),
            // 单曲循环独立按钮（单曲循环时高亮，关闭回到基础模式）。
            IconButton(
              icon: Icon(
                Icons.repeat_one_rounded,
                size: 20,
                color: vm.repeatMode == PlayerRepeatMode.one
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant,
              ),
              tooltip: '单曲循环',
              onPressed: vm.toggleSingleRepeat,
            ),
            // 播放模式合并按钮：顺序 / 列表循环 / 随机循环 三态循环。
            // 单曲循环时显示基础模式但不高亮（由单曲循环按钮高亮）。
            // 常驻按钮最右：随机开关/定位显隐都不会移动播放模式与单曲循环。
            IconButton(
              icon: Icon(
                _playModeIcon(vm.baseRepeatMode, vm.isShuffled),
                // playlist_play_rounded 字形留白多、观感偏小，放大到 22 与其他图标看齐。
                size: vm.baseRepeatMode == PlayerRepeatMode.all ? 20 : 22,
                color: vm.repeatMode != PlayerRepeatMode.one
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant,
              ),
              tooltip:
                  '播放模式：${_playModeTooltip(vm.baseRepeatMode, vm.isShuffled)}',
              onPressed: vm.cyclePlayMode,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildFooter() {
    final icon = _queueFooterIcon(vm.repeatMode, vm.isShuffled);
    final text = queueFooterText(
      vm.repeatMode,
      vm.isShuffled,
      // 列表滚动到底（extentAfter == 0）时才显示「· 到底了」。
      atBottom: !_bottomFaded,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 16, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildList(List<Song> queue) {
    final displayIndex = _displayIndex;
    return ListView.builder(
      controller: _scrollController,
      itemExtent: _kQueueTileExtent,
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: queue.length,
      itemBuilder: (context, index) {
        final song = queue[index];
        final isCurrent = index == displayIndex;
        final isDimmed = vm.isShuffled && !isCurrent && index < displayIndex;
        return _buildListTile(song, index, isCurrent, isDimmed: isDimmed);
      },
    );
  }

  Widget _buildReorderableList(List<Song> queue) {
    final displayIndex = _displayIndex;
    return ReorderableListView.builder(
      scrollController: _scrollController,
      itemExtent: _kQueueTileExtent,
      padding: const EdgeInsets.symmetric(vertical: 4),
      buildDefaultDragHandles: false,
      itemCount: queue.length,
      onReorderItem: (oldIndex, newIndex) {
        vm.moveInQueue(oldIndex, newIndex);
      },
      itemBuilder: (context, index) {
        final song = queue[index];
        final isCurrent = index == displayIndex;
        final isDimmed = vm.isShuffled && !isCurrent && index < displayIndex;
        return _buildListTile(
          song,
          index,
          isCurrent,
          isDimmed: isDimmed,
          key: ValueKey(song.filePath),
        );
      },
    );
  }

  Widget _buildListTile(
    Song song,
    int index,
    bool isCurrent, {
    bool isDimmed = false,
    Key? key,
  }) {
    // 随机模式下当前歌之前的已播部分置灰淡出（Apple Music 风格）。
    return Opacity(
      opacity: isDimmed ? 0.45 : 1.0,
      child: SongTile(
        key: key,
        song: song,
        isCurrentSong: isCurrent,
        // 队列用 leading 指示当前项（播放图标/序号），隐藏行尾音量图标避免重复
        showCurrentIndicator: false,
        onTap: _deleteMode
            ? () {
                setState(() {
                  if (_selectedIndices.contains(index)) {
                    _selectedIndices.remove(index);
                  } else {
                    _selectedIndices.add(index);
                  }
                });
              }
            : (isCurrent ? null : () => vm.jumpTo(_toLogicalIndex(index))),
        leading: _deleteMode
            ? Checkbox(
                value: _selectedIndices.contains(index),
                onChanged: (checked) {
                  setState(() {
                    if (checked == true) {
                      _selectedIndices.add(index);
                    } else {
                      _selectedIndices.remove(index);
                    }
                  });
                },
              )
            : _reorderMode
            ? ReorderableDragStartListener(
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
            : SizedBox(
                width: 36,
                height: 32,
                child: Center(
                  child: isCurrent
                      ? Icon(
                          Icons.play_arrow_rounded,
                          color: theme.colorScheme.primary,
                          size: 20,
                        )
                      : Text(
                          '${index + 1}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                ),
              ),
      ),
    );
  }
}
