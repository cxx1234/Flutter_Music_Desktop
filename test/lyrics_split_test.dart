import 'package:flutter_test/flutter_test.dart';

import 'package:txvziwm/core/utils/bilingual_lrc.dart';

void main() {
  group('splitBilingualLine（单行「原文 翻译」拆分）', () {
    test('基本「日文 中文」同行 → 拆出原文与翻译', () {
      final r = splitBilingualLine('あの日1度だけと誓い合った秘め事は 那天我们唯一一次立下誓言所隐藏的秘密');
      expect(r.main, 'あの日1度だけと誓い合った秘め事は');
      expect(r.translation, '那天我们唯一一次立下誓言所隐藏的秘密');
    });

    test('原文内部有空格（「」后）不误切', () {
      final r = splitBilingualLine('「それでも構わない」 そう呟いた戯言は 「即便如此也无所谓」这般轻声呢喃的戏言');
      expect(r.main, '「それでも構わない」 そう呟いた戯言は');
      expect(r.translation, '「即便如此也无所谓」这般轻声呢喃的戏言');
    });

    test('原文以汉字结尾（事/程）不误切', () {
      final r = splitBilingualLine('私の罪は愛を願ってしまった事 我的罪孽是渴求了爱情');
      expect(r.main, '私の罪は愛を願ってしまった事');
      expect(r.translation, '我的罪孽是渴求了爱情');

      final r2 = splitBilingualLine('二度と笑えぬ程 直到再也无法展露笑容');
      expect(r2.main, '二度と笑えぬ程');
      expect(r2.translation, '直到再也无法展露笑容');
    });

    test('原文含连续汉字（幾億/残酷）因带假名后缀不被误切', () {
      final r = splitBilingualLine('幾億の中にアナタがいると信じて良いですか 可以相信在亿万星辰中有你存在吗');
      expect(r.main, '幾億の中にアナタがいると信じて良いですか');
      expect(r.translation, '可以相信在亿万星辰中有你存在吗');

      final r2 = splitBilingualLine('現実と言う 残酷なストーリー 现实这名为残酷的故事剧本');
      expect(r2.main, '現実と言う 残酷なストーリー');
      expect(r2.translation, '现实这名为残酷的故事剧本');
    });

    test('纯日文行（无翻译）→ translation 为空', () {
      final r = splitBilingualLine('ただのテスト行です');
      expect(r.main, 'ただのテスト行です');
      expect(r.translation, '');
    });

    test('纯中文歌词行（无原文）不误拆为翻译', () {
      final r = splitBilingualLine('我的爱情故事是一首老歌');
      expect(r.main, '我的爱情故事是一首老歌');
      expect(r.translation, '');
    });

    test('英文混排：原文含英文、翻译含英文', () {
      final r = splitBilingualLine('空にきえるLove Songs 消逝在天空中的Love Songs');
      expect(r.main, '空にきえるLove Songs');
      expect(r.translation, '消逝在天空中的Love Songs');
    });

    test('Bug 2：日文歌词句尾汉字名词（无翻译）不误拆', () {
      // 用户反馈：`…の所持量`、`…督促状` 被误掐成翻译副行。
      final r = splitBilingualLine('あたしたち秤の上でシーソー 測られるの幸運の所持量');
      expect(r.main, 'あたしたち秤の上でシーソー 測られるの幸運の所持量');
      expect(r.translation, '');

      final r2 = splitBilingualLine('終わりが近づく音、ドクドク鼓動がからかう督促状');
      expect(r2.main, '終わりが近づく音、ドクドク鼓動がからかう督促状');
      expect(r2.translation, '');
    });

    test('Bug 1：纯汉字「原文 翻译」同行（thin space 分隔）可拆分', () {
      // 用户反馈：`体感 即 快感 体感即是快感` 分词失败。
      final r = splitBilingualLine('体感 即 快感\u2009体感即是快感');
      expect(r.main, '体感 即 快感');
      expect(r.translation, '体感即是快感');
    });

    test('日文句尾汉字名词 + 后接翻译：只拆翻译、不误伤名词', () {
      final r = splitBilingualLine('残酷な世界 残酷的世界');
      expect(r.main, '残酷な世界');
      expect(r.translation, '残酷的世界');
    });

    test('日文原文 + 翻译内部带空格分段 → 拆到第一个翻译段', () {
      // 用户反馈：翻译用空格分段（如「夜风拂过 暗夜飘摇 轻奏音色 飘舞静寂」），
      // 修复前起点被推到最后一个汉字段，主歌词混入翻译前几段。
      final r = splitBilingualLine(
        '風に触った闇は揺れて 奏でた音色 静けさを舞う 夜风拂过 暗夜飘摇 轻奏音色 飘舞静寂',
      );
      expect(r.main, '風に触った闇は揺れて 奏でた音色 静けさを舞う');
      expect(r.translation, '夜风拂过 暗夜飘摇 轻奏音色 飘舞静寂');

      final r2 = splitBilingualLine('そうさ 僕らもがき続けてゆくモンスター 没错 我们就是挣扎着活下去的怪物');
      expect(r2.main, 'そうさ 僕らもがき続けてゆくモンスター');
      expect(r2.translation, '没错 我们就是挣扎着活下去的怪物');

      final r3 = splitBilingualLine('浮かぶ月 見つめる僕の目は何色なんだ？ 凝望漂浮的夜月 我的双眼');
      expect(r3.main, '浮かぶ月 見つめる僕の目は何色なんだ？');
      expect(r3.translation, '凝望漂浮的夜月 我的双眼');
    });

    test('英文原文 + 翻译内部带空格分段 → 拆到第一个翻译段', () {
      // 用户反馈：英文歌（如 Dangerous）翻译用空格分段，修复前同被约束误切。
      final r = splitBilingualLine(
        'The way she came into the place I knew right then and there 她走进来所踩的步伐 那时那刻我就察觉',
      );
      expect(
        r.main,
        'The way she came into the place I knew right then and there',
      );
      expect(r.translation, '她走进来所踩的步伐 那时那刻我就察觉');

      final r2 = splitBilingualLine(
        "My baby cried she left me standing alone She's so dangerous. 我的爱人泪下而去 留我一人孑立 她太危险",
      );
      expect(
        r2.main,
        "My baby cried she left me standing alone She's so dangerous.",
      );
      expect(r2.translation, '我的爱人泪下而去 留我一人孑立 她太危险');

      final r3 = splitBilingualLine(
        'DANGEROUS The girl is so dangerous. 危险 这女孩太危险',
      );
      expect(r3.main, 'DANGEROUS The girl is so dangerous.');
      expect(r3.translation, '危险 这女孩太危险');
    });
  });

  group('splitBilingualLrc（整首拆分）', () {
    test('标签保留、原文/翻译各成一条时间轴', () {
      const lrc = '''
[ti:Even if..]
[ar:花たん]
[00:13.45]あの日1度だけと誓い合った秘め事は 那天我们唯一一次立下誓言所隐藏的秘密
[00:21.00]私を無くした 让我失去了自我
[00:24.23]「それでも構わない」 そう呟いた戯言は 「即便如此也无所谓」这般轻声呢喃的戏言
''';
      final r = splitBilingualLrc(lrc);
      // 标签保留在主歌词。
      expect(r.mainLyric, contains('[ti:Even if..]'));
      expect(r.mainLyric, contains('[ar:花たん]'));
      // 主歌词只有原文，不含翻译。
      expect(r.mainLyric, contains('[00:13.45]あの日1度だけと誓い合った秘め事は'));
      expect(r.mainLyric, isNot(contains('那天')));
      // 翻译各成一条时间轴，时间戳与原文一致。
      expect(r.translationLyric, contains('[00:13.45]那天我们唯一一次立下誓言所隐藏的秘密'));
      expect(r.translationLyric, contains('[00:21.00]让我失去了自我'));
      expect(r.translationLyric, contains('[00:24.23]「即便如此也无所谓」这般轻声呢喃的戏言'));
      expect(r.translationLyric, isNot(contains('私を無くした')));
    });

    test('无翻译的整首 → translationLyric 为空', () {
      const lrc = '[00:10.00]ただのテスト行\n[00:20.00]さらにテスト';
      final r = splitBilingualLrc(lrc);
      expect(r.mainLyric, contains('[00:10.00]ただのテスト行'));
      expect(r.translationLyric, isEmpty);
    });

    test('中文歌词整首（无翻译）→ 全部保留为主歌词', () {
      const lrc = '[00:10.00]我的爱情故事\n[00:20.00]是一首老歌';
      final r = splitBilingualLrc(lrc);
      expect(r.mainLyric, contains('[00:10.00]我的爱情故事'));
      expect(r.mainLyric, contains('[00:20.00]是一首老歌'));
      expect(r.translationLyric, isEmpty);
    });

    test('两段式 LRC（原文段 + 翻译段各自时间轴）按段整体拆分，翻译行不被撕裂', () {
      // QQ 音乐格式：前半英文原文、后半中文翻译，翻译段从首个时间戳重新开始。
      const lrc = '''
[ti:Demo]
[ar:Artist]
[00:00.00]Hello world
[00:02.00]Goodbye world
[00:04.00]Again
[ti:Demo]
[ar:Artist]
[00:00.00]你好世界 你好世界
[00:02.00]再见世界 再见世界
[00:04.00]再来一次 再来一次
''';
      final r = splitBilingualLrc(lrc);
      // 主歌词 = 原文段（含标签），不含中文翻译。
      expect(r.mainLyric, contains('[00:00.00]Hello world'));
      expect(r.mainLyric, contains('[00:02.00]Goodbye world'));
      expect(r.mainLyric, isNot(contains('你好')));
      // 翻译轴 = 翻译段整体（中文行不再被单行拆分撕裂），标签行被跳过。
      expect(r.translationLyric, contains('[00:00.00]你好世界 你好世界'));
      expect(r.translationLyric, contains('[00:02.00]再见世界 再见世界'));
      expect(r.translationLyric, contains('[00:04.00]再来一次 再来一次'));
      expect(r.translationLyric, isNot(contains('Hello')));
      expect(r.translationLyric, isNot(contains('[ti:Demo]')));
    });

    test('一行多时间戳 [a][b] 原文 翻译 → 主/翻译都保留全部时间戳', () {
      const lrc = '[00:00.00][00:05.00]Hello world 你好世界';
      final r = splitBilingualLrc(lrc);
      expect(r.mainLyric, contains('[00:00.00][00:05.00]Hello world'));
      expect(r.translationLyric, contains('[00:00.00][00:05.00]你好世界'));
      // 不丢失任何一个时间戳。
      expect(r.mainLyric, contains('[00:05.00]Hello world'));
      expect(r.translationLyric, contains('[00:05.00]你好世界'));
    });

    test('两段式按时间戳值对齐：主/翻译毫秒位数不一致也能识别', () {
      // 主歌词段用 1 位毫秒、翻译段用 2 位毫秒：字符串不同但归一毫秒相同。
      const lrc = '''
[ti:Demo]
[ar:Artist]
[00:00.0]Hello world
[00:02.0]Goodbye world
[00:04.0]Again
[ti:Demo]
[ar:Artist]
[00:00.00]你好世界 你好世界
[00:02.00]再见世界 再见世界
[00:04.00]再来一次 再来一次
''';
      final r = splitBilingualLrc(lrc);
      expect(r.mainLyric, contains('[00:00.0]Hello world'));
      expect(r.mainLyric, isNot(contains('你好')));
      expect(r.translationLyric, contains('[00:00.00]你好世界 你好世界'));
      expect(r.translationLyric, contains('[00:04.00]再来一次 再来一次'));
      expect(r.translationLyric, isNot(contains('Hello')));
    });
  });
}
