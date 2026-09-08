import 'package:flutter/material.dart';

import '../../core/database/database.dart';
import '../../core/services/service_locator.dart';
import 'playlist_picker_sheet.dart';

/// 歌曲"更多"菜单项。
///
/// 队列相关操作依赖实时播放状态（本函数在菜单打开时求值）：
/// - 目标歌曲已在队列任意位置（含正在播放的当前曲）→ 队列操作置灰禁用（彻底去重）；
/// - 随机播放开启时，「播放下一首」无法保证精确的"下一首"语义 → 隐藏该项。
List<PopupMenuEntry<String>> songMenuItems(Song song) {
  final player = ServiceLocator.player;
  final inQueue = player.queue.any((s) => s.id == song.id);
  final shuffled = player.isShuffled;
  return [
    if (!shuffled)
      PopupMenuItem(
        value: 'playNext',
        enabled: !inQueue,
        child: const Text('下一首播放'),
      ),
    PopupMenuItem(
      value: 'addQueue',
      enabled: !inQueue,
      child: const Text('添加到播放队列'),
    ),
    const PopupMenuItem(value: 'playlist', child: Text('添加到播放列表')),
    PopupMenuItem(
      value: 'favorite',
      child: Text(song.isFavorite == 1 ? '取消喜欢' : '喜欢'),
    ),
  ];
}

/// 正在播放页（信息卡）的"更多"菜单项。
///
/// 当前曲必然已在逻辑队列中（正在播放），「播放下一首 / 添加到播放队列」
/// 对它毫无意义（总是置灰）→ 仅保留「添加到播放列表」与「喜欢」。
/// 此菜单与通用 [songMenuItems] 分开，避免队列操作出现在正在播放的信息卡上。
List<PopupMenuEntry<String>> currentSongMenuItems(Song song) {
  return [const PopupMenuItem(value: 'playlist', child: Text('添加到播放列表'))];
}

/// 处理歌曲"更多"菜单点击。
Future<void> handleSongMenuAction(
  BuildContext context,
  Song song,
  String value,
) async {
  if (value == 'favorite') {
    await ServiceLocator.songRepo.toggleFavorite(song.id);
  } else if (value == 'playlist') {
    await showPlaylistPicker(context, [song]);
  } else if (value == 'playNext') {
    await _addToQueue(context, song, next: true);
  } else if (value == 'addQueue') {
    await _addToQueue(context, song, next: false);
  }
}

/// 「播放下一首 / 添加到播放队列」公共实现。
///
/// 空队列时 playNext / addToQueue 都会自动开始播放，因此提示文案需区分：
/// 空队列（自动开播）→「已开始播放」，否则按操作分别提示
/// 「已加入下一首播放」/「已添加到播放队列」。
Future<void> _addToQueue(
  BuildContext context,
  Song song, {
  required bool next,
}) async {
  final wasEmpty = ServiceLocator.player.queue.isEmpty;
  if (next) {
    await ServiceLocator.player.playNext([song]);
  } else {
    await ServiceLocator.player.addToQueue([song]);
  }
  if (!context.mounted) return;
  final message = wasEmpty ? '已开始播放' : (next ? '已加入下一首播放' : '已添加到播放队列');
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}
