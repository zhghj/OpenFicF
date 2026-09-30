// 长篇故事状态模型。参考 InkOS 的 runtime state / observation / input-governance 设计，
// 但使用独立实现，保持与 OpenFicF 现有数据层一致。

enum HookStatus {
  open('open'),
  progressing('progressing'),
  deferred('deferred'),
  resolved('resolved'),
  superseded('superseded');

  const HookStatus(this.wire);
  final String wire;

  static HookStatus fromWire(String value) {
    return HookStatus.values.firstWhere(
      (status) => status.wire == value,
      orElse: () => HookStatus.open,
    );
  }
}

class HookRecord {
  final String hookId;
  final int startChapter;
  final String type;
  final HookStatus status;
  final int lastAdvancedChapter;
  final String expectedPayoff;
  final String notes;
  final List<String> dependsOn;
  final String? paysOffInArc;

  const HookRecord({
    required this.hookId,
    required this.startChapter,
    required this.type,
    required this.status,
    required this.lastAdvancedChapter,
    required this.expectedPayoff,
    required this.notes,
    this.dependsOn = const [],
    this.paysOffInArc,
  });

  HookRecord copyWith({
    HookStatus? status,
    int? lastAdvancedChapter,
    String? type,
    String? expectedPayoff,
    String? notes,
  }) {
    return HookRecord(
      hookId: hookId,
      startChapter: startChapter,
      type: type ?? this.type,
      status: status ?? this.status,
      lastAdvancedChapter: lastAdvancedChapter ?? this.lastAdvancedChapter,
      expectedPayoff: expectedPayoff ?? this.expectedPayoff,
      notes: notes ?? this.notes,
      dependsOn: dependsOn,
      paysOffInArc: paysOffInArc,
    );
  }

  Map<String, dynamic> toJson() => {
        'hookId': hookId,
        'startChapter': startChapter,
        'type': type,
        'status': status.wire,
        'lastAdvancedChapter': lastAdvancedChapter,
        'expectedPayoff': expectedPayoff,
        'notes': notes,
        if (dependsOn.isNotEmpty) 'dependsOn': dependsOn,
        if (paysOffInArc != null) 'paysOffInArc': paysOffInArc,
      };

  factory HookRecord.fromJson(Map<String, dynamic> json) => HookRecord(
        hookId: '${json['hookId'] ?? ''}',
        startChapter: _asInt(json['startChapter']),
        type: '${json['type'] ?? ''}',
        status: HookStatus.fromWire('${json['status'] ?? 'open'}'),
        lastAdvancedChapter: _asInt(json['lastAdvancedChapter']),
        expectedPayoff: '${json['expectedPayoff'] ?? ''}',
        notes: '${json['notes'] ?? ''}',
        dependsOn: (json['dependsOn'] as List<dynamic>? ?? []).whereType<String>().toList(),
        paysOffInArc: json['paysOffInArc'] as String?,
      );
}

class ChapterSummaryRow {
  final int chapter;
  final String title;
  final String characters;
  final String events;
  final String stateChanges;
  final String hookActivity;
  final String mood;
  final String chapterType;

  const ChapterSummaryRow({
    required this.chapter,
    required this.title,
    required this.characters,
    required this.events,
    required this.stateChanges,
    required this.hookActivity,
    required this.mood,
    required this.chapterType,
  });

  Map<String, dynamic> toJson() => {
        'chapter': chapter,
        'title': title,
        'characters': characters,
        'events': events,
        'stateChanges': stateChanges,
        'hookActivity': hookActivity,
        'mood': mood,
        'chapterType': chapterType,
      };

  factory ChapterSummaryRow.fromJson(Map<String, dynamic> json) => ChapterSummaryRow(
        chapter: _asInt(json['chapter']),
        title: '${json['title'] ?? ''}',
        characters: '${json['characters'] ?? ''}',
        events: '${json['events'] ?? ''}',
        stateChanges: '${json['stateChanges'] ?? ''}',
        hookActivity: '${json['hookActivity'] ?? ''}',
        mood: '${json['mood'] ?? ''}',
        chapterType: '${json['chapterType'] ?? ''}',
      );
}

class CurrentStateFact {
  final String subject;
  final String predicate;
  final String object;
  final int validFromChapter;
  final int? validUntilChapter;
  final int sourceChapter;

  const CurrentStateFact({
    required this.subject,
    required this.predicate,
    required this.object,
    required this.validFromChapter,
    required this.validUntilChapter,
    required this.sourceChapter,
  });

  CurrentStateFact copyWith({int? validUntilChapter}) => CurrentStateFact(
        subject: subject,
        predicate: predicate,
        object: object,
        validFromChapter: validFromChapter,
        validUntilChapter: validUntilChapter,
        sourceChapter: sourceChapter,
      );

  bool get active => validUntilChapter == null;

  Map<String, dynamic> toJson() => {
        'subject': subject,
        'predicate': predicate,
        'object': object,
        'validFromChapter': validFromChapter,
        'validUntilChapter': validUntilChapter,
        'sourceChapter': sourceChapter,
      };

  factory CurrentStateFact.fromJson(Map<String, dynamic> json) => CurrentStateFact(
        subject: '${json['subject'] ?? ''}',
        predicate: '${json['predicate'] ?? ''}',
        object: '${json['object'] ?? ''}',
        validFromChapter: _asInt(json['validFromChapter']),
        validUntilChapter: json['validUntilChapter'] == null ? null : _asInt(json['validUntilChapter']),
        sourceChapter: _asInt(json['sourceChapter']),
      );
}

/// 权威故事状态快照：manifest + 当前事实 + 伏笔 + 章节摘要。
class StoryState {
  final int schemaVersion;
  final int lastAppliedChapter;
  final int chapter;
  final List<CurrentStateFact> facts;
  final List<HookRecord> hooks;
  final List<ChapterSummaryRow> summaries;

  const StoryState({
    this.schemaVersion = 2,
    this.lastAppliedChapter = 0,
    this.chapter = 0,
    this.facts = const [],
    this.hooks = const [],
    this.summaries = const [],
  });

  bool get isEmpty => lastAppliedChapter == 0 && hooks.isEmpty && summaries.isEmpty && facts.isEmpty;

  List<HookRecord> get openHooks => hooks
      .where((hook) => hook.status == HookStatus.open || hook.status == HookStatus.progressing || hook.status == HookStatus.deferred)
      .toList();

  StoryState copyWith({
    int? lastAppliedChapter,
    int? chapter,
    List<CurrentStateFact>? facts,
    List<HookRecord>? hooks,
    List<ChapterSummaryRow>? summaries,
  }) {
    return StoryState(
      schemaVersion: schemaVersion,
      lastAppliedChapter: lastAppliedChapter ?? this.lastAppliedChapter,
      chapter: chapter ?? this.chapter,
      facts: facts ?? this.facts,
      hooks: hooks ?? this.hooks,
      summaries: summaries ?? this.summaries,
    );
  }

  Map<String, dynamic> toJson() => {
        'schemaVersion': schemaVersion,
        'lastAppliedChapter': lastAppliedChapter,
        'chapter': chapter,
        'facts': facts.map((fact) => fact.toJson()).toList(),
        'hooks': hooks.map((hook) => hook.toJson()).toList(),
        'summaries': summaries.map((row) => row.toJson()).toList(),
      };

  factory StoryState.fromJson(Map<String, dynamic> json) => StoryState(
        schemaVersion: _asInt(json['schemaVersion'], 2),
        lastAppliedChapter: _asInt(json['lastAppliedChapter']),
        chapter: _asInt(json['chapter']),
        facts: (json['facts'] as List<dynamic>? ?? [])
            .whereType<Map<String, dynamic>>()
            .map(CurrentStateFact.fromJson)
            .toList(),
        hooks: (json['hooks'] as List<dynamic>? ?? [])
            .whereType<Map<String, dynamic>>()
            .map(HookRecord.fromJson)
            .toList(),
        summaries: (json['summaries'] as List<dynamic>? ?? [])
            .whereType<Map<String, dynamic>>()
            .map(ChapterSummaryRow.fromJson)
            .toList(),
      );
}

class StateFactInput {
  final String subject;
  final String predicate;
  final String object;

  const StateFactInput({required this.subject, required this.predicate, required this.object});

  factory StateFactInput.fromJson(Map<String, dynamic> json) => StateFactInput(
        subject: '${json['subject'] ?? ''}',
        predicate: '${json['predicate'] ?? ''}',
        object: '${json['object'] ?? ''}',
      );
}

class StateFactSelector {
  final String subject;
  final String predicate;
  final String? object;

  const StateFactSelector({required this.subject, required this.predicate, this.object});

  factory StateFactSelector.fromJson(Map<String, dynamic> json) => StateFactSelector(
        subject: '${json['subject'] ?? ''}',
        predicate: '${json['predicate'] ?? ''}',
        object: json['object'] as String?,
      );
}

class NewHookCandidate {
  final String type;
  final String expectedPayoff;
  final String notes;

  const NewHookCandidate({required this.type, required this.expectedPayoff, required this.notes});

  factory NewHookCandidate.fromJson(Map<String, dynamic> json) => NewHookCandidate(
        type: '${json['type'] ?? ''}',
        expectedPayoff: '${json['expectedPayoff'] ?? ''}',
        notes: '${json['notes'] ?? ''}',
      );
}

/// 一章带来的增量状态变更，提交前由 reducer 校验。
class StoryStateDelta {
  final int chapter;
  final List<StateFactInput> factUpserts;
  final List<StateFactSelector> factExpires;
  final List<HookRecord> hookUpserts;
  final List<String> hookResolves;
  final List<String> hookDefers;
  final List<String> hookMentions;
  final List<NewHookCandidate> newHookCandidates;
  final ChapterSummaryRow? chapterSummary;
  final String postSettlement;

  const StoryStateDelta({
    required this.chapter,
    this.factUpserts = const [],
    this.factExpires = const [],
    this.hookUpserts = const [],
    this.hookResolves = const [],
    this.hookDefers = const [],
    this.hookMentions = const [],
    this.newHookCandidates = const [],
    this.chapterSummary,
    this.postSettlement = '',
  });

  factory StoryStateDelta.fromJson(Map<String, dynamic> json) {
    final factOps = json['factOps'] is Map<String, dynamic>
        ? json['factOps'] as Map<String, dynamic>
        : <String, dynamic>{};
    final hookOps = json['hookOps'] is Map<String, dynamic>
        ? json['hookOps'] as Map<String, dynamic>
        : <String, dynamic>{};
    return StoryStateDelta(
      chapter: _asInt(json['chapter']),
      factUpserts: (factOps['upsert'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .map(StateFactInput.fromJson)
          .toList(),
      factExpires: (factOps['expire'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .map(StateFactSelector.fromJson)
          .toList(),
      hookUpserts: (hookOps['upsert'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .map(HookRecord.fromJson)
          .toList(),
      hookResolves: (hookOps['resolve'] as List<dynamic>? ?? []).whereType<String>().toList(),
      hookDefers: (hookOps['defer'] as List<dynamic>? ?? []).whereType<String>().toList(),
      hookMentions: (hookOps['mention'] as List<dynamic>? ?? []).whereType<String>().toList(),
      newHookCandidates: (json['newHookCandidates'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .map(NewHookCandidate.fromJson)
          .toList(),
      chapterSummary: json['chapterSummary'] is Map<String, dynamic>
          ? ChapterSummaryRow.fromJson(json['chapterSummary'] as Map<String, dynamic>)
          : null,
      postSettlement: '${json['postSettlement'] ?? ''}',
    );
  }
}

class Observation {
  final String id;
  final String projectId;
  final String? chapterId;
  final String code;
  final String summary;
  final List<String> evidence;
  final String assessment;
  final String? category;
  final String createdAt;

  const Observation({
    required this.id,
    required this.projectId,
    this.chapterId,
    required this.code,
    required this.summary,
    required this.evidence,
    required this.assessment,
    this.category,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'projectId': projectId,
        'chapterId': chapterId,
        'code': code,
        'summary': summary,
        'evidence': evidence,
        'assessment': assessment,
        'category': category,
        'createdAt': createdAt,
      };

  factory Observation.fromJson(Map<String, dynamic> json) => Observation(
        id: '${json['id'] ?? ''}',
        projectId: '${json['projectId'] ?? ''}',
        chapterId: json['chapterId'] as String?,
        code: '${json['code'] ?? ''}',
        summary: '${json['summary'] ?? ''}',
        evidence: (json['evidence'] as List<dynamic>? ?? []).whereType<String>().toList(),
        assessment: '${json['assessment'] ?? 'observation'}',
        category: json['category'] as String?,
        createdAt: '${json['createdAt'] ?? ''}',
      );
}

/// 每部作品的长期控制文档与字数治理。
class ProjectControls {
  final String authorIntent;
  final String currentFocus;
  final int chapterWordCount;
  final int? minChapterLength;
  final int? maxChapterLength;
  final String narrativePerson;
  final List<String> prohibitions;

  const ProjectControls({
    this.authorIntent = '',
    this.currentFocus = '',
    this.chapterWordCount = 2000,
    this.minChapterLength,
    this.maxChapterLength,
    this.narrativePerson = '',
    this.prohibitions = const [],
  });

  Map<String, dynamic> toJson() => {
        'authorIntent': authorIntent,
        'currentFocus': currentFocus,
        'chapterWordCount': chapterWordCount,
        'minChapterLength': minChapterLength,
        'maxChapterLength': maxChapterLength,
        'narrativePerson': narrativePerson,
        'prohibitions': prohibitions,
      };

  factory ProjectControls.fromJson(Map<String, dynamic> json) => ProjectControls(
        authorIntent: '${json['authorIntent'] ?? ''}',
        currentFocus: '${json['currentFocus'] ?? ''}',
        chapterWordCount: _asInt(json['chapterWordCount'], 2000),
        minChapterLength: json['minChapterLength'] == null ? null : _asInt(json['minChapterLength']),
        maxChapterLength: json['maxChapterLength'] == null ? null : _asInt(json['maxChapterLength']),
        narrativePerson: '${json['narrativePerson'] ?? ''}',
        prohibitions: (json['prohibitions'] as List<dynamic>? ?? []).whereType<String>().toList(),
      );
}

int _asInt(Object? value, [int fallback = 0]) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? fallback;
  return fallback;
}

int countChineseCharacters(String text) {
  return text.replaceAll(RegExp(r'\s+'), '').length;
}

int countEnglishWords(String text) {
  return RegExp(r"[A-Za-z0-9']+").allMatches(text).length;
}