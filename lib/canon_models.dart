// 同人正典模型：导入的原作素材 + 分片蒸馏出的正典条目。
// 条目可被选取（启用）、维护（编辑），并应用到角色/世界书/笔记等其它资料。

enum CanonCategory {
  timeline('timeline', '时间线'),
  character('character', '角色卡'),
  world('world', '世界观'),
  relationship('relationship', '人物关系'),
  other('other', '其它');

  const CanonCategory(this.wire, this.label);
  final String wire;
  final String label;

  static CanonCategory fromWire(String value) {
    return CanonCategory.values.firstWhere(
      (category) => category.wire == value,
      orElse: () => CanonCategory.other,
    );
  }
}

class CanonSource {
  final String id;
  final String projectId;
  final String title;
  final String fileName;
  final String format;
  final String fileUri;
  final int sizeBytes;
  final String contentHash;
  final int characterCount;
  final int coveredUntil;
  final int chunkCount;
  final String createdAt;
  final String updatedAt;

  const CanonSource({
    required this.id,
    required this.projectId,
    required this.title,
    required this.fileName,
    required this.format,
    required this.fileUri,
    required this.sizeBytes,
    required this.contentHash,
    required this.characterCount,
    required this.coveredUntil,
    required this.chunkCount,
    required this.createdAt,
    required this.updatedAt,
  });

  bool get complete => chunkCount > 0 && coveredUntil >= chunkCount;

  CanonSource copyWith({int? coveredUntil, int? chunkCount, String? updatedAt}) => CanonSource(
        id: id,
        projectId: projectId,
        title: title,
        fileName: fileName,
        format: format,
        fileUri: fileUri,
        sizeBytes: sizeBytes,
        contentHash: contentHash,
        characterCount: characterCount,
        coveredUntil: coveredUntil ?? this.coveredUntil,
        chunkCount: chunkCount ?? this.chunkCount,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );
}

class CanonEntry {
  final String id;
  final String projectId;
  final String sourceId;
  final CanonCategory category;
  final String title;
  final String summary;
  final String detail;
  final String evidence;
  final List<String> aliases;
  final int orderIndex;
  final bool isEnabled;
  final String? appliedType;
  final String? appliedId;
  final String createdAt;
  final String updatedAt;

  const CanonEntry({
    required this.id,
    required this.projectId,
    required this.sourceId,
    required this.category,
    required this.title,
    required this.summary,
    required this.detail,
    required this.evidence,
    this.aliases = const [],
    required this.orderIndex,
    required this.isEnabled,
    this.appliedType,
    this.appliedId,
    required this.createdAt,
    required this.updatedAt,
  });

  /// 标题与全部别名组成的可匹配名称集合（小写）。
  Set<String> get nameKeys => {
        title.trim().toLowerCase(),
        for (final alias in aliases) alias.trim().toLowerCase(),
      }..removeWhere((name) => name.isEmpty);

  CanonEntry copyWith({
    CanonCategory? category,
    String? title,
    String? summary,
    String? detail,
    String? evidence,
    List<String>? aliases,
    bool? isEnabled,
    String? appliedType,
    String? appliedId,
  }) {
    return CanonEntry(
      id: id,
      projectId: projectId,
      sourceId: sourceId,
      category: category ?? this.category,
      title: title ?? this.title,
      summary: summary ?? this.summary,
      detail: detail ?? this.detail,
      evidence: evidence ?? this.evidence,
      aliases: aliases ?? this.aliases,
      orderIndex: orderIndex,
      isEnabled: isEnabled ?? this.isEnabled,
      appliedType: appliedType ?? this.appliedType,
      appliedId: appliedId ?? this.appliedId,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }
}

class ParsedCanonChunk {
  final String label;
  final String text;

  const ParsedCanonChunk({required this.label, required this.text});
}