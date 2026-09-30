import 'dart:convert';

import '../core/utils.dart';
import '../story_models.dart';
import 'database.dart';

Future<StoryState> getStoryState(String projectId) async {
  final db = await getDatabase();
  final rows = await db.query('story_state', where: 'project_id = ?', whereArgs: [projectId], limit: 1);
  if (rows.isEmpty) return const StoryState();
  try {
    final decoded = json.decode(rows.first['state_json'] as String);
    if (decoded is Map) {
      return StoryState.fromJson(decoded.map((key, value) => MapEntry('$key', value)));
    }
  } catch (_) {}
  return const StoryState();
}

Future<void> saveStoryState(String projectId, StoryState state) async {
  final db = await getDatabase();
  final payload = json.encode(state.toJson());
  final updated = await db.update(
    'story_state',
    {'state_json': payload, 'updated_at': nowIso()},
    where: 'project_id = ?',
    whereArgs: [projectId],
  );
  if (updated == 0) {
    await db.insert('story_state', {
      'project_id': projectId,
      'state_json': payload,
      'updated_at': nowIso(),
    });
  }
}

Future<void> clearStoryState(String projectId) async {
  final db = await getDatabase();
  await db.delete('story_state', where: 'project_id = ?', whereArgs: [projectId]);
}

/// 校验故事状态，返回问题列表；空列表表示合法。
List<String> validateStoryState(StoryState state) {
  final issues = <String>[];
  final hookIds = <String>{};
  for (final hook in state.hooks) {
    if (hook.hookId.trim().isEmpty) issues.add('存在空 hook id');
    if (!hookIds.add(hook.hookId)) issues.add('重复的 hook id：${hook.hookId}');
  }
  final summaryChapters = <int>{};
  for (final row in state.summaries) {
    if (row.chapter < 1) issues.add('章节摘要章节号非法：${row.chapter}');
    if (!summaryChapters.add(row.chapter)) issues.add('重复的章节摘要：第 ${row.chapter} 章');
  }
  if (state.chapter > state.lastAppliedChapter) {
    issues.add('当前状态章节 ${state.chapter} 超过 manifest 的 ${state.lastAppliedChapter}');
  }
  return issues;
}

/// 提交一章的增量状态变更。不可变更新 + 结构校验，坏数据直接拒绝。
StoryState applyStoryStateDelta(
  StoryState snapshot,
  StoryStateDelta delta, {
  bool allowReapply = false,
}) {
  if (delta.chapter < 1) throw Exception('delta 章节号必须大于 0');
  if (allowReapply ? delta.chapter < snapshot.lastAppliedChapter : delta.chapter <= snapshot.lastAppliedChapter) {
    throw Exception('delta 章节 ${delta.chapter} 早于或等于已应用的 ${snapshot.lastAppliedChapter}');
  }
  final summary = delta.chapterSummary;
  if (summary != null && summary.chapter != delta.chapter) {
    throw Exception('章节摘要章节 ${summary.chapter} 与 delta 章节 ${delta.chapter} 不一致');
  }
  if (summary != null &&
      !allowReapply &&
      snapshot.summaries.any((row) => row.chapter == summary.chapter)) {
    throw Exception('第 ${summary.chapter} 章已存在摘要');
  }

  final hooks = _applyHookOps(snapshot.hooks, delta);
  final facts = _applyFactOps(snapshot.facts, delta);
  final summaries = [
    ...(allowReapply && summary != null
        ? snapshot.summaries.where((row) => row.chapter != summary.chapter)
        : snapshot.summaries),
    ?summary,
  ]..sort((left, right) => left.chapter.compareTo(right.chapter));

  final next = snapshot.copyWith(
    lastAppliedChapter: delta.chapter,
    chapter: delta.chapter,
    hooks: hooks,
    facts: facts,
    summaries: summaries,
  );
  final issues = validateStoryState(next);
  if (issues.isNotEmpty) throw Exception(issues.join('；'));
  return next;
}

List<HookRecord> _applyHookOps(List<HookRecord> hooks, StoryStateDelta delta) {
  final byId = <String, HookRecord>{for (final hook in hooks) hook.hookId: hook};

  for (final hook in delta.hookUpserts) {
    final existing = byId[hook.hookId];
    if (existing == null) {
      byId[hook.hookId] = hook;
    } else {
      byId[hook.hookId] = _mergeHook(existing, hook);
    }
  }
  for (final hookId in delta.hookResolves) {
    final existing = byId[hookId];
    if (existing == null) throw Exception('无法回收不存在的伏笔 $hookId');
    if (existing.status == HookStatus.superseded) throw Exception('无法回收已作废的伏笔 $hookId');
    byId[hookId] = existing.copyWith(
      status: HookStatus.resolved,
      lastAdvancedChapter:
          existing.lastAdvancedChapter > delta.chapter ? existing.lastAdvancedChapter : delta.chapter,
    );
  }
  for (final hookId in delta.hookDefers) {
    final existing = byId[hookId];
    if (existing == null) throw Exception('无法延后不存在的伏笔 $hookId');
    if (existing.status == HookStatus.superseded) throw Exception('无法延后已作废的伏笔 $hookId');
    byId[hookId] = existing.copyWith(status: HookStatus.deferred);
  }
  for (final candidate in delta.newHookCandidates) {
    final id = _nextHookId(byId.keys, delta.chapter);
    byId[id] = HookRecord(
      hookId: id,
      startChapter: delta.chapter,
      type: candidate.type,
      status: HookStatus.open,
      lastAdvancedChapter: delta.chapter,
      expectedPayoff: candidate.expectedPayoff,
      notes: candidate.notes,
    );
  }

  final list = byId.values.toList()
    ..sort((left, right) {
      final byStart = left.startChapter.compareTo(right.startChapter);
      if (byStart != 0) return byStart;
      final byAdvanced = left.lastAdvancedChapter.compareTo(right.lastAdvancedChapter);
      if (byAdvanced != 0) return byAdvanced;
      return left.hookId.compareTo(right.hookId);
    });
  return list;
}

HookRecord _mergeHook(HookRecord existing, HookRecord incoming) {
  if (existing.status == HookStatus.superseded) return existing;
  if (incoming.status == HookStatus.superseded) {
    if (existing.status == HookStatus.resolved) {
      throw Exception('不能作废已回收的伏笔 ${existing.hookId}');
    }
    final notes = incoming.notes.trim();
    if (notes.isEmpty) throw Exception('作废伏笔 ${existing.hookId} 必须填写理由');
    return existing.copyWith(
      status: HookStatus.superseded,
      notes: existing.notes.isEmpty ? notes : '${existing.notes}\n$notes',
    );
  }
  final advanced = existing.lastAdvancedChapter > incoming.lastAdvancedChapter
      ? existing.lastAdvancedChapter
      : incoming.lastAdvancedChapter;
  return HookRecord(
    hookId: existing.hookId,
    startChapter: existing.startChapter < incoming.startChapter ? existing.startChapter : incoming.startChapter,
    type: incoming.type.trim().isNotEmpty ? incoming.type : existing.type,
    status: existing.status == HookStatus.resolved ? HookStatus.resolved : incoming.status,
    lastAdvancedChapter: advanced,
    expectedPayoff:
        incoming.expectedPayoff.trim().isNotEmpty ? incoming.expectedPayoff : existing.expectedPayoff,
    notes: incoming.notes.trim().isNotEmpty ? incoming.notes : existing.notes,
    dependsOn: existing.dependsOn,
    paysOffInArc: existing.paysOffInArc,
  );
}

List<CurrentStateFact> _applyFactOps(List<CurrentStateFact> facts, StoryStateDelta delta) {
  var next = facts.map((fact) => fact.copyWith()).toList();

  bool sameKey(CurrentStateFact fact, StateFactSelector selector) {
    return fact.subject == selector.subject.trim() &&
        fact.predicate == selector.predicate.trim() &&
        (selector.object == null || fact.object == selector.object!.trim());
  }

  for (final selector in delta.factExpires) {
    next = next
        .map((fact) => fact.active && sameKey(fact, selector)
            ? fact.copyWith(validUntilChapter: (delta.chapter - 1).clamp(0, 1 << 30))
            : fact)
        .toList();
  }

  for (final input in delta.factUpserts) {
    final subject = input.subject.trim();
    final predicate = input.predicate.trim();
    final object = input.object.trim();
    if (subject.isEmpty || predicate.isEmpty || object.isEmpty) continue;
    final exact = next.any((candidate) =>
        candidate.active &&
        candidate.subject == subject &&
        candidate.predicate == predicate &&
        candidate.object == object);
    if (exact) continue;
    next = next
        .map((candidate) => candidate.active &&
                candidate.subject == subject &&
                candidate.predicate == predicate
            ? candidate.copyWith(validUntilChapter: (delta.chapter - 1).clamp(0, 1 << 30))
            : candidate)
        .toList();
    next.add(CurrentStateFact(
      subject: subject,
      predicate: predicate,
      object: object,
      validFromChapter: delta.chapter,
      validUntilChapter: null,
      sourceChapter: delta.chapter,
    ));
  }

  next.sort((left, right) {
    final byPredicate = left.predicate.compareTo(right.predicate);
    if (byPredicate != 0) return byPredicate;
    return left.object.compareTo(right.object);
  });
  return next;
}

String _nextHookId(Iterable<String> existing, int chapter) {
  var index = 1;
  while (existing.contains('h$chapter-$index')) {
    index += 1;
  }
  return 'h$chapter-$index';
}

/// 供对话式维护使用的便捷 ID 生成。
String nextHookId(StoryState state, int chapter) =>
    _nextHookId(state.hooks.map((hook) => hook.hookId), chapter <= 0 ? 1 : chapter);

int _effectiveChapter(StoryState state) {
  if (state.chapter > 0) return state.chapter;
  if (state.lastAppliedChapter > 0) return state.lastAppliedChapter;
  return 1;
}

Future<StoryState> _commit(String projectId, StoryState state) async {
  final issues = validateStoryState(state);
  if (issues.isNotEmpty) throw Exception(issues.join('；'));
  await saveStoryState(projectId, state);
  return state;
}

/// 新增或更新一条伏笔（按 hookId 合并）。省略 hookId 时自动分配。
Future<StoryState> upsertHook(
  String projectId, {
  String? hookId,
  required String type,
  String status = 'open',
  String expectedPayoff = '',
  String notes = '',
  int? startChapter,
  int? lastAdvancedChapter,
}) async {
  final state = await getStoryState(projectId);
  final chapter = _effectiveChapter(state);
  final id = (hookId != null && hookId.trim().isNotEmpty)
      ? hookId.trim()
      : nextHookId(state, chapter);
  final existing = state.hooks.where((hook) => hook.hookId == id).toList();
  final hook = HookRecord(
    hookId: id,
    startChapter: startChapter ?? (existing.isNotEmpty ? existing.first.startChapter : chapter),
    type: type.trim().isEmpty ? (existing.isNotEmpty ? existing.first.type : '未分类') : type.trim(),
    status: HookStatus.fromWire(status),
    lastAdvancedChapter: lastAdvancedChapter ??
        (existing.isNotEmpty ? existing.first.lastAdvancedChapter : chapter),
    expectedPayoff: expectedPayoff.trim().isEmpty && existing.isNotEmpty
        ? existing.first.expectedPayoff
        : expectedPayoff.trim(),
    notes: notes.trim().isEmpty && existing.isNotEmpty ? existing.first.notes : notes.trim(),
  );
  final hooks = [
    for (final item in state.hooks) if (item.hookId != id) item,
    hook,
  ]..sort((a, b) => a.startChapter.compareTo(b.startChapter));
  return _commit(projectId, state.copyWith(hooks: hooks));
}

Future<StoryState> setHookStatus(String projectId, String hookId, HookStatus status) async {
  final state = await getStoryState(projectId);
  final exists = state.hooks.any((hook) => hook.hookId == hookId);
  if (!exists) throw Exception('伏笔不存在：$hookId');
  final chapter = _effectiveChapter(state);
  final hooks = state.hooks
      .map((hook) => hook.hookId == hookId
          ? hook.copyWith(
              status: status,
              lastAdvancedChapter: status == HookStatus.resolved
                  ? (hook.lastAdvancedChapter > chapter ? hook.lastAdvancedChapter : chapter)
                  : hook.lastAdvancedChapter,
            )
          : hook)
      .toList();
  return _commit(projectId, state.copyWith(hooks: hooks));
}

Future<StoryState> deleteHook(String projectId, String hookId) async {
  final state = await getStoryState(projectId);
  final hooks = state.hooks.where((hook) => hook.hookId != hookId).toList();
  if (hooks.length == state.hooks.length) throw Exception('伏笔不存在：$hookId');
  return _commit(projectId, state.copyWith(hooks: hooks));
}

/// 设置当前世界状态事实：同一主体+关系的旧值会被标记为失效。
Future<StoryState> upsertStateFact(
  String projectId, {
  required String subject,
  required String predicate,
  required String object,
}) async {
  final state = await getStoryState(projectId);
  final chapter = _effectiveChapter(state);
  final subj = subject.trim();
  final pred = predicate.trim();
  final obj = object.trim();
  if (subj.isEmpty || pred.isEmpty || obj.isEmpty) throw Exception('主体、关系、事实都不能为空');
  final facts = <CurrentStateFact>[];
  for (final fact in state.facts) {
    if (fact.active && fact.subject == subj && fact.predicate == pred) {
      facts.add(fact.copyWith(validUntilChapter: (chapter - 1).clamp(0, 1 << 30)));
    } else {
      facts.add(fact);
    }
  }
  final duplicate = facts.any((fact) =>
      fact.active && fact.subject == subj && fact.predicate == pred && fact.object == obj);
  if (!duplicate) {
    facts.add(CurrentStateFact(
      subject: subj,
      predicate: pred,
      object: obj,
      validFromChapter: chapter,
      validUntilChapter: null,
      sourceChapter: chapter,
    ));
  }
  return _commit(projectId, state.copyWith(
    chapter: state.chapter > 0 ? state.chapter : chapter,
    lastAppliedChapter: state.lastAppliedChapter > 0 ? state.lastAppliedChapter : chapter,
    facts: facts,
  ));
}

Future<StoryState> expireStateFact(
  String projectId, {
  required String subject,
  required String predicate,
  String? object,
}) async {
  final state = await getStoryState(projectId);
  final chapter = _effectiveChapter(state);
  final subj = subject.trim();
  final pred = predicate.trim();
  final obj = object?.trim();
  var changed = false;
  final facts = state.facts.map((fact) {
    final match = fact.active &&
        fact.subject == subj &&
        fact.predicate == pred &&
        (obj == null || obj.isEmpty || fact.object == obj);
    if (match) {
      changed = true;
      return fact.copyWith(validUntilChapter: (chapter - 1).clamp(0, 1 << 30));
    }
    return fact;
  }).toList();
  if (!changed) throw Exception('未找到匹配的当前事实');
  return _commit(projectId, state.copyWith(facts: facts));
}

Future<StoryState> writeChapterSummary(String projectId, ChapterSummaryRow row) async {
  if (row.chapter < 1) throw Exception('章节号必须大于 0');
  if (row.title.trim().isEmpty) throw Exception('章节摘要标题不能为空');
  final state = await getStoryState(projectId);
  final summaries = [
    for (final item in state.summaries) if (item.chapter != row.chapter) item,
    row,
  ]..sort((a, b) => a.chapter.compareTo(b.chapter));
  return _commit(projectId, state.copyWith(summaries: summaries));
}

Future<StoryState> deleteChapterSummary(String projectId, int chapter) async {
  final state = await getStoryState(projectId);
  final summaries = state.summaries.where((row) => row.chapter != chapter).toList();
  if (summaries.length == state.summaries.length) throw Exception('章节摘要不存在：第 $chapter 章');
  return _commit(projectId, state.copyWith(summaries: summaries));
}

// ---------------------------------------------------------------------------
// Markdown 投影（人类可读，权威数据仍是 StoryState）
// ---------------------------------------------------------------------------

String _escapeCell(String value) => value.replaceAll('|', '\\|').replaceAll(RegExp(r'\r?\n'), '<br>').trim();

String renderHooksProjection(StoryState state) {
  final rows = [...state.hooks]..sort((left, right) {
      final byStart = left.startChapter.compareTo(right.startChapter);
      if (byStart != 0) return byStart;
      return left.hookId.compareTo(right.hookId);
    });
  final buffer = StringBuffer('# 伏笔池\n\n');
  buffer.writeln('| hook_id | 起始章节 | 类型 | 状态 | 最近推进 | 预期回收 | 备注 |');
  buffer.writeln('| --- | --- | --- | --- | --- | --- | --- |');
  for (final hook in rows) {
    buffer.writeln('| ${[
      hook.hookId,
      '${hook.startChapter}',
      hook.type,
      hook.status.wire,
      '${hook.lastAdvancedChapter}',
      hook.expectedPayoff,
      hook.notes,
    ].map(_escapeCell).join(' | ')} |');
  }
  return buffer.toString().trimRight();
}

String renderChapterSummariesProjection(StoryState state) {
  final rows = [...state.summaries]..sort((left, right) => left.chapter.compareTo(right.chapter));
  final buffer = StringBuffer('# 章节摘要\n\n');
  buffer.writeln('| 章节 | 标题 | 出场人物 | 关键事件 | 状态变化 | 伏笔动态 | 情绪基调 | 章节类型 |');
  buffer.writeln('| --- | --- | --- | --- | --- | --- | --- | --- |');
  for (final row in rows) {
    buffer.writeln('| ${[
      '${row.chapter}',
      row.title,
      row.characters,
      row.events,
      row.stateChanges,
      row.hookActivity,
      row.mood,
      row.chapterType,
    ].map(_escapeCell).join(' | ')} |');
  }
  return buffer.toString().trimRight();
}

String renderCurrentStateProjection(StoryState state) {
  final facts = state.facts.where((fact) => fact.active || (fact.validUntilChapter ?? 0) >= state.chapter).toList()
    ..sort((left, right) {
      final bySubject = left.subject.compareTo(right.subject);
      if (bySubject != 0) return bySubject;
      return left.predicate.compareTo(right.predicate);
    });
  final buffer = StringBuffer('# 当前状态\n\n> 当前章节：${state.chapter}\n\n');
  buffer.writeln('| 主体 | 关系 / 属性 | 当前事实 | 生效章节 | 来源章节 |');
  buffer.writeln('| --- | --- | --- | --- | --- |');
  for (final fact in facts) {
    buffer.writeln('| ${[
      fact.subject,
      fact.predicate,
      fact.object,
      '${fact.validFromChapter}',
      '${fact.sourceChapter}',
    ].map(_escapeCell).join(' | ')} |');
  }
  return buffer.toString().trimRight();
}