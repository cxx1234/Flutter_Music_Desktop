# 性能与待优化项清单

> 删除线 = 已完成；其余为待办。详细完成记录见 git 提交与仓库记忆。
> 最后更新：2026-09-03（2026-09-03 全项目三路只读审计并入；★=本次新增，○=可选）

## 1. 渲染 / UI 类

- ~~P1 高频重建削减（播放页局部化、`uiListenable`、进度条自订阅、`PlayQueue.songs` 缓存视图）~~
- ~~P2 封面降采样解码（`cacheWidth` + `gaplessPlayback`）~~
- ~~1.1 搜索过滤结果缓存（`QueryFilterCache`，四页过滤 getter 接入）~~
- ~~1.2 关键区域加 `RepaintBoundary`（歌词区 / 播放页封面信息卡 / `CoverCard` 网格；不含长列表逐行）~~
- ~~1.3 歌手详情定向查专辑（`getAlbumsByIds` 空集合短路，替代全表拉取）~~
- ~~1.4 `NowPlayingBar` 订阅收窄 + 底栏背景进度填充（可开关：设置 › 外观，见 §6）~~

### 1.x 第二批待办（2026-09-03 审计）
- U1 ★ 进度条拖动每 tick seek（无 onChangeEnd 落点）— `player_progress_bar.dart:47`。仿音量滑块：拖动中预览、结束提交一次。
- U2 ★ 音乐库每次播放/暂停/切歌整页 setState（行内播放图标）— `library_page.dart:104`。行内图标局部订阅。
- U3 ★ `SongTile` build 真构建整份菜单（含 O(n) 队列查）— `song_tile.dart:~239`。以 `menuBuilder != null` 判有无。
- U4 ★ 菜单动作后无条件整表重查 — `album_page.dart:323` / `artist_page.dart:347` / `library_page.dart:608`。仅需刷新项才重查。
- U5 ★ 播放中行图标 60fps 动画在 offstage 页仍跑 — `song_tile` `_AnimatedPlayingIcon`。不可见时停。
- L1 ★ `queue_view` 删除后 await 中 setState 未复查 mounted — `queue_view.dart:252-263`。
- L2 ★ `library_page` 多处 await 后 setState 未复查 mounted — `:171/177/366`。
- L3 ★ 收藏跨视图不一致（歌曲操作只写 DB，播放页红心可能 stale）— `song_actions.dart:58`。统一走 `toggleFavoriteForCurrent`。
- L4 ★ 设置页缓存大小只在 initState 载、保活切回不刷新 — `settings_page.dart`。active + didUpdateWidget。

---

## 2. 启动 / 数据层类

- ~~P3 DB schema v6（7 索引）+ WAL + 队列恢复批量查询~~

### 2.1 启动路径串行阻塞
- 位置：`service_locator.dart:137-169` `_doInitialize()`。
- 改法：`Future.wait` 并行独立步骤（settings/DB 开库、backfill、restoreQueue、sandbox）。

### 2.2 每次启动全盘遍历阻塞首屏
- 位置：`library_view_model.dart:117`。
- 改法：先加载歌曲列表再后台 quickSync。

### 2.3 数据库跑主 isolate
- 位置：`database.dart:51` `create()`。
- 前置：WAL 已开。风险：中（需全量测试 + 真实库验证）。
- 改法：`createInBackground`/`readPool`。

### 2.4 `getExistingFileStats` 拉全行
- 位置：`database.dart:124`。
- 改法：投影 `file_path/last_modified_ms/file_size` 三列。

### 2.5 `backfillSortKeys` 每次启动全表扫
- 位置：`song_repository.dart:150`。
- 改法：先 `COUNT` 判断是否为 0，或迁移后一次性标记。

### 2.6 watch 流全是死代码
- 位置：`database.dart` 6 个 `watch*` 方法。
- 改法：清理，或改用 drift 流式更新替代手动 reload。

### 2.7 ★ `getAllFilePaths` 拉全行（每次 quickSync 后同步队列用）
- 位置：`database.dart:219-227`。
- 改法：`selectOnly(songs.filePath)`。

### 2.8 ★ dateAdded / playCount / year 排序无复合索引
- 位置：`database.dart:350-356` `getAvailableSongs`（现仅 `(is_available,title_sort_key)` 有索引）。
- 改法：按需补 `(is_available,date_added)` / `(is_available,play_count)`。

### 2.9 ★ `LyricsViewModel` 构造即读当前歌歌词（启动期一次 I/O + isolate）
- 位置：`lyrics_view_model.dart:63-66`。
- 改法：延迟到播放页首次可见/首次播放再载。

## 3. 扫描 / 元数据类

- ~~3.1 元数据解析并发 + Isolate（受限并发 worker 池 + 100ms 进度节流）~~
- ~~3.2 变化检测移后台 isolate（`detectChangedFiles` + `Isolate.run`；⚠️ 闭包勿捕获 UI 回调，防 unsendable）~~
- ~~3.3 扫描事务查询去重（artist/album 批量缓存 + dateAdded 批量）~~
- ~~3.4 文件夹并行遍历（`Future.wait`）~~

### 3.5 第二批待办（2026-09-03 审计）
- 3.5 ★ 扫描无条件拉 `existingStamps`（仅 force 分支使用）— `library_scanner_service.dart:174-175`。移进用时分支。
- 3.6 ★ 每次 quickSync 都跑 `cleanupOrphans` + 孤儿封面清理（无增删也全量清）— `library_scanner_service.dart:263-264`。仅确有增删改/恢复才清；quick 跳过。
- 3.7 ★ `cleanupOrphans` 3 段全表扫 + `NOT IN` 删除 — `database.dart:298-340`。改一条 `DELETE … WHERE NOT EXISTS`。
- 3.8 ★ `restoreFiles` 逐文件 UPDATE — `song_repository.dart:546-550`。仿 `markMissingFiles` 用 `isIn` 批量。
- ~~3.9 ★ `_runScan` 无单飞守卫，多入口（startScan/forceScan/rescan/quickSync）可能并发双跑事务 — `library_view_model.dart`。已加 `_scanInProgress` 单飞守卫（`_runScan`/`_quickSync` 共用；UI 刷新按钮扫描中已隐藏，VM 层兜底，2026-09-08 ✅）~~

---

## 4. 后台 / 媒体控制类

### 4.1 每秒重读封面文件 + 解码
- 位置：`media_control_service.dart:42-49` + `MediaControlsPlugin.swift:104-122`。
- 改法：仅切歌传封面，位置用独立轻量更新（只更新 `ElapsedPlaybackTime`）。

### 4.2 日志每行 flush
- 位置：`logger.dart:229-232`。
- 改法：批量缓冲 + 周期 flush（保持崩溃前落盘语义）。

### 4.3-4.5 第二批待办（2026-09-03 审计）
- 4.3 ★ 媒体键操作 fire-and-forget 未串行，与扫描 `_rebuildSequence` 并发有风险 — `media_control_service.dart:55-72`。加操作串行/统一入口。
- 4.4 ★ 媒体键 EventChannel `onError: (_){}` 静默吞 — `macos_media_controls.dart:30`。至少 `AppLogger.warning`。
- ~~4.5 ★ folder watcher 无防抖且扫描写库期间仍并发触发 — `folder_watcher_service.dart`。已改去抖批量（500ms 窗口聚合 + 一次 flush）+ `suspend()` 扫描期缓冲、`resumeAfterScan` 扫完跳过已扫描文件再批处理（2026-09-08 ✅）~~

## 5. 播放器 / 持久化类

- ~~P4 写盘防抖（队列 debounce + 串行写链 + 生命周期 flush、音量拖动结束落盘）~~
- ~~5.2 封面缓存扩展名不一致~~

### 5.1 大队列 `setAudioSources` 一次性构建
- 位置：`player_service.dart:419-427`（`playFromList`）/ `923-931`（`_rebuildSequence`）。
- 改法：分批 `addAudioSources` + 加载反馈。

### 5.3-5.5 第二批待办（2026-09-03 审计）
- 5.3 ★ 位置每几秒整份重写 `play_queue.json`（千首歌可百 KB）— `play_queue.dart:288-317` + `player_service.dart:146-149/301-308`。`positionMs/durationMs` 独立小文件/独立 key。
- 5.4 ★ `settings.json` 写无串行化，并发 setter 可能乱序覆盖 — `settings_service.dart:258-263`。加串行写链。
- 5.5 ○（可选残余）`_positionSub` 每 200ms 仍唤醒订整个 service 的订阅者（媒体控制等）— `player_service.dart:144`。可接受，需再压再处理。

## 6. 用户自规划功能（已完成）

- ~~全局底栏「按播放进度填充」效果（整体背景色从左向右填充，与 1.4 一并落地；可开关：设置 › 外观）~~

## 7. 平台 / 发布检查（2026-09-03）

- R1 版本与 CHANGELOG：当前 `pubspec.yaml` 0.2.2+2；`CHANGELOG.md` 无 0.2.x 条目且有多余重复 `[0.1.0]` 头 → 发版前对齐补录。
- R2 ★ 设置页「清理缓存」仍为占位假功能（`还没做 -ω-`）— `settings_page.dart:55-78`。实现删除或隐藏入口。
- R3 ★ `audio_metadata_reader` 为 git fork 分支依赖未 pin commit — `pubspec.yaml`。固定 commit hash 保证可复现构建。
- R4 ★ 菜单通道名仍 `flutter_music/menu`（改名后唯一未随 `com.jerryc.txvziwm/` 约定）— `AppDelegate.swift:76` + `menu_service.dart:21`。双侧同步改名。
- R5 `Info.plist` `FLTEnableImpeller=false` 全局关 Impeller（Apple Silicon 也受影响）→ 发版决策；上游修复后按架构移除。
- R6 `setTopBarHeight` 为 no-op + Dart 侧 `_syncTopBarHeightToNative` 死调用 → 按 `docs/UI-Rules.md` 清理。
- R7 Windows `WM_GETMINMAXINFO` 最小尺寸未做 — 登记于 `docs/TODO.md` §3 Phase 4。
- R8 Windows/Linux 系统媒体控制（SMTC）未做 → 明确纳入/移出发布范围（`docs/TODO.md` §3 Phase 5）。
- R9 macOS 音乐文件夹权限（`docs/TODO.md` §1 方案 A/B/C）未落地，README 无授权说明 → 至少补 README 一句，理想做方案 A。
- R10 `assets/fonts/BoutiqueBitmap9x9_Circle_Dot.ttf` 无 pubspec 声明、无引用 → 删或声明。
- R11 `docs/TODO.md`：macOS 菜单栏已实质完成未勾 ✅；`windows/runner/Runner.rc` 显示名描述过期（已为 0x4D）→ 同步。
- R12 文档小项：macOS 部署目标 12.0 vs `docs/UI-Rules.md` 写的 11.0；`flutter clean` 会卡 SPM（sqlite3 native assets）需构建文档注明用 `rm -rf build/macos`；`test/log_page_test.dart` 样本含 `MetadataGod` 字样可换中性串；README 补 fork 依赖与授权说明。

## 8. 优先级建议

1. **发布前必须**：R1（版本/CHANGELOG）、R2（清理缓存假功能）、R3（依赖 pin）、R9（授权说明）；`docs/TODO.md` 其余发布项（Windows 最小尺寸/SMTC、macOS 菜单栏勾选）。
2. **低风险顺手**：U3、U5、L1、L2、2.4、2.6、2.7、3.5、3.7、3.8、4.4、5.4、R4、R10、R12。
3. **本轮中风险（建议排期做）**：U1、U4、L3、3.6、4.1、5.1。
4. **第二轮架构优化**：2.1、2.2、2.3、2.8、5.3、R7、R8。
