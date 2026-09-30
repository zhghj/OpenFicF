import 'package:flutter_test/flutter_test.dart';

import 'package:openfic_f/canon/canon_apply.dart';
import 'package:openfic_f/canon_models.dart';
import 'package:openfic_f/data/story_state_repositories.dart';
import 'package:openfic_f/pipeline/canon_distiller.dart';
import 'package:openfic_f/pipeline/chapter_pipeline.dart';
import 'package:openfic_f/services/disambiguation.dart';
import 'package:openfic_f/story_models.dart';

void main() {
  group('applyStoryStateDelta', () {
    test('应用事实、伏笔与章节摘要', () {
      const snapshot = StoryState();
      final delta = StoryStateDelta(
        chapter: 1,
        factUpserts: const [StateFactInput(subject: '林墨', predicate: '身份', object: '外门弟子')],
        newHookCandidates: const [
          NewHookCandidate(type: '悬念', expectedPayoff: '神秘玉佩的来历', notes: '开篇出现'),
        ],
        chapterSummary: const ChapterSummaryRow(
          chapter: 1,
          title: '第一章 玉佩',
          characters: '林墨',
          events: '获得玉佩',
          stateChanges: '成为外门弟子',
          hookActivity: '新增玉佩来历',
          mood: '低沉',
          chapterType: '开局',
        ),
      );

      final next = applyStoryStateDelta(snapshot, delta);

      expect(next.lastAppliedChapter, 1);
      expect(next.facts.single.object, '外门弟子');
      expect(next.hooks.single.status, HookStatus.open);
      expect(next.hooks.single.hookId, 'h1-1');
      expect(next.summaries.single.chapter, 1);
      expect(validateStoryState(next), isEmpty);
    });

    test('拒绝回退的章节号', () {
      const snapshot = StoryState(lastAppliedChapter: 3, chapter: 3);
      expect(
        () => applyStoryStateDelta(snapshot, const StoryStateDelta(chapter: 3)),
        throwsA(isA<Exception>()),
      );
    });

    test('回收未知伏笔时报错', () {
      const snapshot = StoryState();
      expect(
        () => applyStoryStateDelta(
          snapshot,
          const StoryStateDelta(chapter: 1, hookResolves: ['missing']),
        ),
        throwsA(isA<Exception>()),
      );
    });

    test('新事实会终结同一主体关系的旧值', () {
      const snapshot = StoryState(
        lastAppliedChapter: 1,
        chapter: 1,
        facts: [
          CurrentStateFact(
            subject: '林墨',
            predicate: '境界',
            object: '炼气一层',
            validFromChapter: 1,
            validUntilChapter: null,
            sourceChapter: 1,
          ),
        ],
      );
      final next = applyStoryStateDelta(
        snapshot,
        StoryStateDelta(
          chapter: 2,
          factUpserts: const [StateFactInput(subject: '林墨', predicate: '境界', object: '炼气二层')],
        ),
      );
      final active = next.facts.where((fact) => fact.active).toList();
      expect(active.single.object, '炼气二层');
      expect(next.facts.length, 2);
    });
  });

  group('splitCanonChunks', () {
    test('章节足够多时按章切分', () {
      final text = [
        '第一章 风起',
        '林墨走出山门。',
        '',
        '第二章 入城',
        '城里人来人往。',
        '',
        '第三章 试炼',
        '试炼开始。',
        '',
        '第四章 归来',
        '他回到了山门。',
      ].join('\n');
      final chunks = splitCanonChunks(text);
      expect(chunks.length, 4);
      expect(chunks.first.label, '第一章 风起');
    });

    test('章节不足时按长度聚合片段', () {
      final paragraph = '这是一段很长的正文，用来验证片段聚合逻辑。' * 20;
      final text = List.filled(12, paragraph).join('\n\n');
      final chunks = splitCanonChunks(text);
      expect(chunks.length, greaterThan(1));
      expect(chunks.first.label.startsWith('片段'), isTrue);
      for (final chunk in chunks) {
        expect(chunk.text.length, lessThanOrEqualTo(4000));
      }
    });

    test('空文本返回空列表', () {
      expect(splitCanonChunks('   \n  '), isEmpty);
    });
  });

  group('CanonCategory', () {
    test('未知分类回退为 other', () {
      expect(CanonCategory.fromWire('unknown'), CanonCategory.other);
      expect(CanonCategory.fromWire('timeline'), CanonCategory.timeline);
    });
  });

  group('CanonEntry.nameKeys', () {
    CanonEntry entry(List<String> aliases) => CanonEntry(
          id: '1',
          projectId: 'p',
          sourceId: 's',
          category: CanonCategory.character,
          title: '鲁伯·海格',
          summary: '',
          detail: '',
          evidence: '',
          aliases: aliases,
          orderIndex: 0,
          isEnabled: true,
          createdAt: '',
          updatedAt: '',
        );

    test('标题与别名都参与匹配且大小写无关', () {
      final keys = entry(['海格', 'Rubeus Hagrid']).nameKeys;
      expect(keys.contains('鲁伯·海格'), isTrue);
      expect(keys.contains('海格'), isTrue);
      expect(keys.contains('rubeus hagrid'), isTrue);
    });

    test('空别名被忽略', () {
      expect(entry(['', '  ']).nameKeys, {'鲁伯·海格'});
    });
  });

  group('nextHookId', () {
    test('无冲突时按章节递增', () {
      expect(nextHookId(const StoryState(), 2), 'h2-1');
    });

    test('已有同章节 id 时顺延', () {
      final state = StoryState(hooks: [
        const HookRecord(
          hookId: 'h2-1',
          startChapter: 2,
          type: '悬念',
          status: HookStatus.open,
          lastAdvancedChapter: 2,
          expectedPayoff: '',
          notes: '',
        ),
      ]);
      expect(nextHookId(state, 2), 'h2-2');
    });
  });

  group('canonEntryContent', () {
    test('拼接摘要、详情与依据', () {
      const entry = CanonEntry(
        id: '1',
        projectId: 'p',
        sourceId: 's',
        category: CanonCategory.character,
        title: '海格',
        summary: '半巨人',
        detail: '霍格沃茨钥匙保管员',
        evidence: '“我叫海格”',
        orderIndex: 0,
        isEnabled: true,
        createdAt: '',
        updatedAt: '',
      );
      final content = canonEntryContent(entry);
      expect(content.contains('半巨人'), isTrue);
      expect(content.contains('钥匙保管员'), isTrue);
      expect(content.contains('正典依据'), isTrue);
    });
  });

  group('DisambiguationConfig', () {
    test('未知服务商回退中国大陆可用的百度百科', () {
      expect(DisambiguationProvider.fromWire('unknown'), DisambiguationProvider.baiduBaike);
      expect(DisambiguationProvider.fromWire('serper'), DisambiguationProvider.serper);
      expect(DisambiguationProvider.fromWire('baidu-baike'), DisambiguationProvider.baiduBaike);
      expect(DisambiguationProvider.fromWire('bocha'), DisambiguationProvider.bocha);
    });

    test('默认 Base URL 按服务商与语言区分', () {
      expect(
        DisambiguationConfig.defaultBaseUrl(DisambiguationProvider.wikipedia, 'zh'),
        'https://zh.wikipedia.org',
      );
      expect(
        DisambiguationConfig.defaultBaseUrl(DisambiguationProvider.wikipedia, 'en'),
        'https://en.wikipedia.org',
      );
      expect(
        DisambiguationConfig.defaultBaseUrl(DisambiguationProvider.baiduBaike, 'zh'),
        'https://baike.baidu.com',
      );
      expect(
        DisambiguationConfig.defaultBaseUrl(DisambiguationProvider.bocha, 'zh'),
        'https://api.bochaai.com/v1',
      );
      expect(
        DisambiguationConfig.defaultBaseUrl(DisambiguationProvider.custom, 'zh'),
        '',
      );
    });
  });

  group('extractJsonObject', () {
    test('从代码块中提取 JSON', () {
      final json = extractJsonObject('```json\n{"title":"第一章","goal":"开端"}\n```');
      expect(json, isNotNull);
      expect(json!['title'], '第一章');
    });

    test('容忍前后说明文字', () {
      final json = extractJsonObject('好的，结果如下：{"goal":"x"} 完成');
      expect(json, isNotNull);
      expect(json!['goal'], 'x');
    });
  });
}