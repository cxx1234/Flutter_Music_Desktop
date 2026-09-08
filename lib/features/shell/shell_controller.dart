import 'dart:async';

import 'package:flutter/material.dart';

/// Shell 侧边栏导航项。
enum NavigationItem {
  library('音乐库', Icons.library_music),
  albums('专辑', Icons.album),
  artists('歌手', Icons.person),
  playlists('播放列表', Icons.playlist_play),
  settings('设置', Icons.settings);

  final String label;
  final IconData icon;

  const NavigationItem(this.label, this.icon);
}

/// 外部（App/菜单）可触发的页面动作。
enum ShellAction {
  /// 新建播放列表：切到播放列表页并弹「新建播放列表」对话框。
  newPlaylist,

  /// 添加音乐文件夹：切到音乐库页并弹文件夹选择器。
  importFolder,

  /// 导入播放列表（M3U）：切到播放列表页并弹文件选择器。
  importPlaylist,

  /// 导出播放列表（M3U）：切到播放列表页并选一个列表导出。
  exportPlaylist,

  /// 强制刷新音乐库（全量重解析，忽略变化检测）：切到音乐库页并触发。
  forceRescan,
}

/// 允许外部（App/菜单/播放页）切换 Shell tab 并触发页面动作的控制器。
///
/// Shell 自身点击也写回 [tab] 保持双向同步；ValueNotifier 同值不 notify，无循环。
class ShellController {
  final ValueNotifier<NavigationItem> tab = ValueNotifier(
    NavigationItem.library,
  );

  final _actions = StreamController<ShellAction>.broadcast();

  /// 页面动作事件流（页面在 initState 订阅、dispose 取消）。
  Stream<ShellAction> get actions => _actions.stream;

  /// 请求切换到 [item]，并可选地在下一帧触发 [action]。
  ///
  /// 动作事件延迟到下一帧发送：保证首次切 tab 时页面完成构建/订阅后再到达，
  /// 避免事件先于页面订阅而丢失（广播流无缓冲）。
  void request(NavigationItem item, {ShellAction? action}) {
    tab.value = item;
    if (action != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_actions.isClosed) {
          _actions.add(action);
        }
      });
    }
  }

  void dispose() {
    tab.dispose();
    _actions.close();
  }
}
