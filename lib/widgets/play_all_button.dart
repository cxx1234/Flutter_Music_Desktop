import 'package:flutter/material.dart';

/// 统一的「播放全部」椭圆形文本按钮（▶ 播放全部）。
///
/// 放在详情块的信息文本下方（专辑/播放列表/我的收藏），或区块标题右侧（歌手歌曲区块）。
/// 列表为空时应置 [enabled] = false，按钮以禁用态呈现。
class PlayAllButton extends StatelessWidget {
  const PlayAllButton({
    super.key,
    required this.onPlayAll,
    this.enabled = true,
  });

  final VoidCallback onPlayAll;

  /// 是否可播放；列表为空时传 false 禁用按钮。
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      onPressed: enabled ? onPlayAll : null,
      style: FilledButton.styleFrom(shape: const StadiumBorder()),
      icon: const Icon(Icons.play_arrow, size: 18),
      label: const Text('播放全部'),
    );
  }
}
