import 'dart:convert';

import '../core/utils.dart';
import '../data/chapter_draft_repositories.dart';
import '../data/note_repositories.dart';
import '../data/observation_repositories.dart';
import '../data/project_controls_repositories.dart';
import '../data/repositories.dart';
import '../data/story_state_repositories.dart';
import '../data/style_repositories.dart';
import '../llm/client.dart';
import '../llm/llm_types.dart';
import '../models.dart';
import '../story_models.dart';
import 'prompts.dart';

enum ChapterStage { preparing, planning, writing, reviewing, settling, committing, done }

class ChapterPipelineProgress {
  final ChapterStage stage;
  final String label;

  const ChapterPipelineProgress({required this.stage, required this.label});
}

class ChapterPipelineResult {
  final String chapterId;
  final String title;
  final int chapterNumber;
  final int wordCount;
  final String reviewSummary;
  final List<Observation> observations;
  final StoryState storyState;
  final String? settleError;

  const ChapterPipelineResult({
    required this.chapterId,
    required this.title,
    required this.chapterNumber,
    required this.wordCount,
    required this.reviewSummary,
    required this.observations,
    required this.storyState,
    this.settleError,
  });
}

/// 从模型输出中提取第一个 JSON 对象，容忍代码块和前后说明文字。
Map<String, dynamic>? extractJsonObject(String text) {
  final trimmed = text.trim();
  final fenced = RegExp(r'```(?:json)?\s*([\s\S]*?)```', caseSensitive: false).firstMatch(trimmed);
  final candidate = fenced?.group(1) ?? trimmed;
  final start = candidate.indexOf('{');
  final end = candidate.lastIndexOf('}');
  if (start < 0 || end <= start) return null;
  try {
    final decoded = json.decode(candidate.substring(start, end + 1));
    if (decoded is Map) return decoded.map((key, value) => MapEntry('$key', value));
  } catch (_) {}
  return null;
}

List<Map<String, dynamic>> _extractObservationList(Map<String, dynamic> json) {
  final raw = json['observations'];
  if (raw is! List) return [];
  return raw.whereType<Map>().map((item) => item.map((key, value) => MapEntry('$key', value))).toList();
}

String? _truncate(String value, int maximum) {
  final trimmed = value.trim();
  if (trimmed.length <= maximum) return trimmed.isEmpty ? null : trimmed;
  return '${trimmed.substring(0, maximum)}…';
}

Future<String> _buildContextBlock({
  required Project project,
  required ProjectControls controls,
  required StoryState state,
  required int chapterNumber,
}) async {
  final chapters = await listChapters(project.id);
  final characters = await listCharacters(project.id);
  final worldInfo = await getOrCreateWorldInfo(project.id);
  final worldEntries = await listWorldInfoEntries(worldInfo.id);
  final notes = await listNotes(project.id);
  final sections = <String>[];

  final controlsBlock = renderControlsBlock(controls);
  if (controlsBlock.isNotEmpty) sections.add(controlsBlock);

  if (state.summaries.isNotEmpty) {
    final recent = StoryState(
      chapter: state.chapter,
      lastAppliedChapter: state.lastAppliedChapter,
      summaries: state.summaries.length > 8
          ? state.summaries.sublist(state.summaries.length - 8)
          : state.summaries,
    );
    sections.add('### 最近章节摘要\n${renderChapterSummariesProjection(recent)}');
  }
  if (state.openHooks.isNotEmpty) {
    sections.add('### 未回收伏笔\n${renderOpenHooksBrief(state)}');
  }
  if (state.facts.any((fact) => fact.active)) {
    sections.add('### 当前世界状态\n${renderCurrentStateProjection(state)}');
  }

  if (characters.isNotEmpty) {
    final lines = characters
        .take(30)
        .map((character) =>
            '- ${character.name}：${_truncate(character.description, 200) ?? '暂无设定'}')
        .join('\n');
    sections.add('### 角色\n$lines');
  }
  final enabledEntries = worldEntries.where((entry) => entry.isEnabled).take(30).toList();
  if (enabledEntries.isNotEmpty) {
    final lines =
        enabledEntries.map((entry) => '- ${entry.name}：${_truncate(entry.content, 240) ?? ''}').join('\n');
    sections.add('### 世界书\n$lines');
  }
  if (notes.isNotEmpty) {
    final lines = notes
        .take(20)
        .map((note) => '- [${note.scope.wire}] ${note.title}：${_truncate(note.content, 160) ?? ''}')
        .join('\n');
    sections.add('### 笔记（大纲 / 伏笔规划）\n$lines');
  }

  final previous = _previousChapter(chapters, state.lastAppliedChapter);
  if (previous != null && previous.content.trim().isNotEmpty) {
    final tail = previous.content.trim();
    sections.add('### 上一章结尾\n${tail.length > 1500 ? tail.substring(tail.length - 1500) : tail}');
  }

  return sections.isEmpty ? '（暂无额外上下文）' : sections.join('\n\n');
}

Chapter? _previousChapter(List<Chapter> chapters, int number) {
  if (chapters.isEmpty) return null;
  if (number >= 1 && number <= chapters.length) return chapters[number - 1];
  return chapters.last;
}

Future<String> _activeStyleGuide(String projectId) async {
  final profiles = await getActiveStyleProfiles(projectId);
  if (profiles.isEmpty) return '';
  return profiles
      .map((profile) =>
          '【${profile.kind == StyleProfileKind.author ? '作者文风' : '参考文风'} · ${profile.name} V${profile.version}】\n${profile.guide.trim()}')
      .join('\n\n');
}

Future<Map<String, dynamic>> _callJson({
  required ModelSelection selection,
  required String system,
  required String user,
  int? minOutputTokens,
}) async {
  final result = await callModel(
    selection,
    [
      AgentMessage(role: 'system', content: system),
      AgentMessage(role: 'user', content: user),
    ],
    const [],
    minOutputTokens == null ? null : ModelCallOptions(minOutputTokens: minOutputTokens),
  );
  final json = extractJsonObject(result.content);
  if (json == null) {
    throw Exception('模型没有返回有效的 JSON：${_truncate(result.content, 200) ?? '空响应'}');
  }
  return json;
}

/// 完整章节生产管线：规划 → 写作 → 审稿 → 状态结算 → 原子提交。
Future<ChapterPipelineResult> runChapterPipeline({
  required Project project,
  required ModelSelection selection,
  String instruction = '',
  int? targetWords,
  void Function(ChapterPipelineProgress progress)? onProgress,
}) async {
  void report(ChapterStage stage, String label) =>
      onProgress?.call(ChapterPipelineProgress(stage: stage, label: label));

  report(ChapterStage.preparing, '正在准备长篇上下文');
  var controls = await getProjectControls(project.id);
  if (targetWords != null && targetWords > 0) {
    controls = ProjectControls(
      authorIntent: controls.authorIntent,
      currentFocus: controls.currentFocus,
      chapterWordCount: targetWords,
      minChapterLength: controls.minChapterLength,
      maxChapterLength: controls.maxChapterLength,
      narrativePerson: controls.narrativePerson,
      prohibitions: controls.prohibitions,
    );
  }
  final state = await getStoryState(project.id);
  final chapters = await listChapters(project.id);
  final chapterNumber =
      (chapters.length > state.lastAppliedChapter ? chapters.length : state.lastAppliedChapter) + 1;
  final contextBlock = await _buildContextBlock(
    project: project,
    controls: controls,
    state: state,
    chapterNumber: chapterNumber,
  );

  report(ChapterStage.planning, '第 $chapterNumber 章：规划章节 memo');
  String title = '第 $chapterNumber 章';
  String memo = '';
  final plannerJson = await _callJson(
    selection: selection,
    system: buildPlannerSystemPrompt(),
    user: buildPlannerUserPrompt(
      chapterNumber: chapterNumber,
      contextBlock: contextBlock,
      instruction: instruction,
      targetWords: controls.chapterWordCount,
    ),
  );
  final plannedTitle = '${plannerJson['title'] ?? ''}'.trim();
  if (plannedTitle.isNotEmpty) title = plannedTitle;
  final goal = '${plannerJson['goal'] ?? ''}'.trim();
  final plan = '${plannerJson['plan'] ?? ''}'.trim();
  memo = [if (goal.isNotEmpty) '目标：$goal', if (plan.isNotEmpty) plan].join('\n\n');
  if (memo.isEmpty) memo = instruction.trim().isEmpty ? '按当前上下文自然推进本章。' : instruction.trim();

  report(ChapterStage.writing, '正在写正文（目标 ${controls.chapterWordCount} 字）');
  final styleGuide = await _activeStyleGuide(project.id);
  final writerResult = await callModel(
    selection,
    [
      AgentMessage(role: 'system', content: buildWriterSystemPrompt(controls: controls)),
      AgentMessage(
        role: 'user',
        content: buildWriterUserPrompt(
          chapterNumber: chapterNumber,
          contextBlock: contextBlock,
          memo: memo,
          styleGuide: styleGuide,
        ),
      ),
    ],
    const [],
    ModelCallOptions(
      minOutputTokens: (controls.chapterWordCount * 2).clamp(4096, 32000),
    ),
  );
  final prose = writerResult.content.trim();
  if (prose.isEmpty) throw Exception('模型没有返回正文内容');
  final wordCount = countChineseCharacters(prose);

  report(ChapterStage.committing, '正在保存章节');
  final volumes = await listVolumes(project.id);
  final volumeId = volumes.isEmpty
      ? (await createVolume(project.id, '正文')).id
      : (volumes.reduce((a, b) => a.orderIndex >= b.orderIndex ? a : b)).id;
  final chapter = await createChapter(project.id, volumeId, title, prose);
  final style = await getActiveStyleProfile(project.id);
  await createChapterDraftSnapshot(
    projectId: project.id,
    chapterId: chapter.id,
    styleProfileId: style?.id,
    aiDraft: prose,
  );

  report(ChapterStage.reviewing, '正在审稿并记录观察');
  String reviewSummary = '';
  var observations = <Observation>[];
  try {
    final reviewJson = await _callJson(
      selection: selection,
      system: buildReviewerSystemPrompt(),
      user: buildReviewerUserPrompt(
        chapterNumber: chapterNumber,
        contextBlock: contextBlock,
        content: prose,
      ),
    );
    reviewSummary = '${reviewJson['summary'] ?? ''}'.trim();
    final parsed = _extractObservationList(reviewJson);
    await replaceChapterObservations(
      project.id,
      chapter.id,
      parsed.map((item) {
        final assessment = '${item['assessment'] ?? 'observation'}';
        return (
          code: '${item['code'] ?? 'observation'}',
          summary: '${item['summary'] ?? ''}',
          evidence: (item['evidence'] as List<dynamic>? ?? []).whereType<String>().toList(),
          assessment: ['issue', 'resolved', 'observation', 'unavailable'].contains(assessment)
              ? assessment
              : 'observation',
          category: item['category'] as String?,
        );
      }).toList(),
    );
    observations = await listChapterObservations(chapter.id);
  } catch (error) {
    reviewSummary = '审稿暂不可用：${errorText(error)}';
    await replaceChapterObservations(project.id, chapter.id, [
      (
        code: 'review-unavailable',
        summary: reviewSummary,
        evidence: <String>[],
        assessment: 'unavailable',
        category: 'execution',
      ),
    ]);
    observations = await listChapterObservations(chapter.id);
  }

  report(ChapterStage.settling, '正在结算故事状态与伏笔');
  var nextState = state;
  String? settleError;
  try {
    final settleJson = await _callJson(
      selection: selection,
      system: buildSettlerSystemPrompt(),
      user: buildSettlerUserPrompt(
        chapterNumber: chapterNumber,
        chapterTitle: title,
        content: prose,
        contextBlock: contextBlock,
      ),
    );
    settleJson['chapter'] = chapterNumber;
    final summary = settleJson['chapterSummary'];
    if (summary is Map) {
      summary['chapter'] = chapterNumber;
    }
    final delta = StoryStateDelta.fromJson(settleJson);
    nextState = applyStoryStateDelta(state, delta);
    await saveStoryState(project.id, nextState);
  } catch (error) {
    settleError = errorText(error);
  }

  report(ChapterStage.done, '已完成第 $chapterNumber 章');
  return ChapterPipelineResult(
    chapterId: chapter.id,
    title: title,
    chapterNumber: chapterNumber,
    wordCount: wordCount,
    reviewSummary: reviewSummary,
    observations: observations,
    storyState: nextState,
    settleError: settleError,
  );
}

/// 只对已有章节做审稿并覆盖观察记录。
Future<({String summary, List<Observation> observations})> reviewExistingChapter({
  required Project project,
  required Chapter chapter,
  required ModelSelection selection,
  int? chapterNumber,
}) async {
  final controls = await getProjectControls(project.id);
  final state = await getStoryState(project.id);
  final chapters = await listChapters(project.id);
  var index = chapters.indexWhere((item) => item.id == chapter.id);
  if (index < 0) index = chapters.length - 1;
  final number = chapterNumber ?? (index + 1);
  final contextBlock = await _buildContextBlock(
    project: project,
    controls: controls,
    state: state,
    chapterNumber: number,
  );
  try {
    final reviewJson = await _callJson(
      selection: selection,
      system: buildReviewerSystemPrompt(),
      user: buildReviewerUserPrompt(
        chapterNumber: number,
        contextBlock: contextBlock,
        content: chapter.content,
      ),
    );
    final summary = '${reviewJson['summary'] ?? ''}'.trim();
    final parsed = _extractObservationList(reviewJson);
    await replaceChapterObservations(
      project.id,
      chapter.id,
      parsed.map((item) {
        final assessment = '${item['assessment'] ?? 'observation'}';
        return (
          code: '${item['code'] ?? 'observation'}',
          summary: '${item['summary'] ?? ''}',
          evidence: (item['evidence'] as List<dynamic>? ?? []).whereType<String>().toList(),
          assessment: ['issue', 'resolved', 'observation', 'unavailable'].contains(assessment)
              ? assessment
              : 'observation',
          category: item['category'] as String?,
        );
      }).toList(),
    );
    return (summary: summary, observations: await listChapterObservations(chapter.id));
  } catch (error) {
    final message = '审稿暂不可用：${errorText(error)}';
    await replaceChapterObservations(project.id, chapter.id, [
      (
        code: 'review-unavailable',
        summary: message,
        evidence: <String>[],
        assessment: 'unavailable',
        category: 'execution',
      ),
    ]);
    return (summary: message, observations: await listChapterObservations(chapter.id));
  }
}