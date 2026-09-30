// 领域模型。字段命名与 OpenFicM 移动端保持一致，便于对照。

enum ProviderType {
  openaiCompatible('openai-compatible'),
  googleGenai('google-genai'),
  anthropic('anthropic');

  const ProviderType(this.wire);
  final String wire;

  static ProviderType fromWire(String value) {
    return ProviderType.values.firstWhere(
      (type) => type.wire == value,
      orElse: () => ProviderType.openaiCompatible,
    );
  }
}

class Project {
  final String id;
  final String title;
  final String description;
  final String createdAt;
  final String updatedAt;

  const Project({
    required this.id,
    required this.title,
    required this.description,
    required this.createdAt,
    required this.updatedAt,
  });
}

class Volume {
  final String id;
  final String projectId;
  final String title;
  final int orderIndex;

  const Volume({
    required this.id,
    required this.projectId,
    required this.title,
    required this.orderIndex,
  });
}

class Chapter {
  final String id;
  final String projectId;
  final String volumeId;
  final String title;
  final String content;
  final int orderIndex;
  final String updatedAt;

  const Chapter({
    required this.id,
    required this.projectId,
    required this.volumeId,
    required this.title,
    required this.content,
    required this.orderIndex,
    required this.updatedAt,
  });
}

enum NoteScope {
  project('project'),
  volume('volume'),
  chapter('chapter');

  const NoteScope(this.wire);
  final String wire;
}

class Note {
  final String id;
  final String projectId;
  final String? volumeId;
  final String? chapterId;
  final String title;
  final String content;
  final int orderIndex;
  final String createdAt;
  final String updatedAt;

  const Note({
    required this.id,
    required this.projectId,
    this.volumeId,
    this.chapterId,
    required this.title,
    required this.content,
    required this.orderIndex,
    required this.createdAt,
    required this.updatedAt,
  });

  NoteScope get scope {
    if (chapterId != null) return NoteScope.chapter;
    if (volumeId != null) return NoteScope.volume;
    return NoteScope.project;
  }
}

class StyleSource {
  final String id;
  final String title;
  final String fileName;
  final String format;
  final String fileUri;
  final int sizeBytes;
  final String contentHash;
  final int characterCount;
  final String createdAt;
  final String updatedAt;

  const StyleSource({
    required this.id,
    required this.title,
    required this.fileName,
    required this.format,
    required this.fileUri,
    required this.sizeBytes,
    required this.contentHash,
    required this.characterCount,
    required this.createdAt,
    required this.updatedAt,
  });
}

enum StyleProfileKind {
  reference('reference'),
  author('author');

  const StyleProfileKind(this.wire);
  final String wire;

  static StyleProfileKind fromWire(String value) {
    return value == 'author' ? StyleProfileKind.author : StyleProfileKind.reference;
  }
}

class StyleProfile {
  final String id;
  final String seriesId;
  final String? projectId;
  final String? sourceId;
  final StyleProfileKind kind;
  final String name;
  final int version;
  final String guide;
  final String createdAt;
  final String updatedAt;

  const StyleProfile({
    required this.id,
    required this.seriesId,
    this.projectId,
    this.sourceId,
    required this.kind,
    required this.name,
    required this.version,
    required this.guide,
    required this.createdAt,
    required this.updatedAt,
  });
}

enum ChapterDraftStatus {
  generated('generated'),
  revised('revised'),
  evolved('evolved');

  const ChapterDraftStatus(this.wire);
  final String wire;

  static ChapterDraftStatus fromWire(String value) {
    return ChapterDraftStatus.values.firstWhere(
      (status) => status.wire == value,
      orElse: () => ChapterDraftStatus.generated,
    );
  }
}

class ChapterDraftSnapshot {
  final String id;
  final String projectId;
  final String chapterId;
  final String? styleProfileId;
  final String aiDraft;
  final String? authorRevision;
  final ChapterDraftStatus status;
  final String createdAt;
  final String updatedAt;

  const ChapterDraftSnapshot({
    required this.id,
    required this.projectId,
    required this.chapterId,
    this.styleProfileId,
    required this.aiDraft,
    this.authorRevision,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
  });
}

class Provider {
  final String id;
  final String name;
  final ProviderType type;
  final String baseUrl;
  final String apiKeyRef;
  final String createdAt;

  const Provider({
    required this.id,
    required this.name,
    required this.type,
    required this.baseUrl,
    required this.apiKeyRef,
    required this.createdAt,
  });
}

class LlmModel {
  final String id;
  final String providerId;
  final String name;
  final String modelId;
  final double temperature;
  final int maxTokens;

  const LlmModel({
    required this.id,
    required this.providerId,
    required this.name,
    required this.modelId,
    required this.temperature,
    required this.maxTokens,
  });
}

class ChatSession {
  final String id;
  final String projectId;
  final String title;
  final String? modelId;
  final String createdAt;
  final String updatedAt;

  const ChatSession({
    required this.id,
    required this.projectId,
    required this.title,
    this.modelId,
    required this.createdAt,
    required this.updatedAt,
  });
}

class ChatMessage {
  final String id;
  final String projectId;
  final String sessionId;
  final String role;
  final String content;
  final ChatMessageMetadata? metadata;
  final String createdAt;

  const ChatMessage({
    required this.id,
    required this.projectId,
    required this.sessionId,
    required this.role,
    required this.content,
    this.metadata,
    required this.createdAt,
  });
}

class ChatMessageMetadata {
  final AgentRunTrace? agentTrace;
  final String? taskStatus;
  final String? errorMessage;
  final String? errorDetail;
  final RetryContext? retryContext;

  const ChatMessageMetadata({
    this.agentTrace,
    this.taskStatus,
    this.errorMessage,
    this.errorDetail,
    this.retryContext,
  });

  Map<String, dynamic> toJson() => {
        if (agentTrace != null) 'agentTrace': agentTrace!.toJson(),
        if (taskStatus != null) 'taskStatus': taskStatus,
        if (errorMessage != null) 'errorMessage': errorMessage,
        if (errorDetail != null) 'errorDetail': errorDetail,
        if (retryContext != null) 'retryContext': retryContext!.toJson(),
      };

  factory ChatMessageMetadata.fromJson(Map<String, dynamic> json) {
    return ChatMessageMetadata(
      agentTrace: json['agentTrace'] is Map<String, dynamic>
          ? AgentRunTrace.fromJson(json['agentTrace'] as Map<String, dynamic>)
          : null,
      taskStatus: json['taskStatus'] as String?,
      errorMessage: json['errorMessage'] as String?,
      errorDetail: json['errorDetail'] as String?,
      retryContext: json['retryContext'] is Map<String, dynamic>
          ? RetryContext.fromJson(json['retryContext'] as Map<String, dynamic>)
          : null,
    );
  }
}

class RetryContext {
  final String userMessageId;
  final String modelId;
  final String? agentId;

  const RetryContext({
    required this.userMessageId,
    required this.modelId,
    this.agentId,
  });

  Map<String, dynamic> toJson() => {
        'userMessageId': userMessageId,
        'modelId': modelId,
        'agentId': agentId,
      };

  factory RetryContext.fromJson(Map<String, dynamic> json) => RetryContext(
        userMessageId: json['userMessageId'] as String? ?? '',
        modelId: json['modelId'] as String? ?? '',
        agentId: json['agentId'] as String?,
      );
}

class AgentTraceEvent {
  final String id;
  final String kind;
  final String status;
  final String title;
  final String agentName;
  final String? toolName;
  final String? detail;
  final String? input;
  final String? output;
  final String startedAt;
  final String? completedAt;

  const AgentTraceEvent({
    required this.id,
    required this.kind,
    required this.status,
    required this.title,
    required this.agentName,
    this.toolName,
    this.detail,
    this.input,
    this.output,
    required this.startedAt,
    this.completedAt,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind,
        'status': status,
        'title': title,
        'agentName': agentName,
        if (toolName != null) 'toolName': toolName,
        if (detail != null) 'detail': detail,
        if (input != null) 'input': input,
        if (output != null) 'output': output,
        'startedAt': startedAt,
        if (completedAt != null) 'completedAt': completedAt,
      };

  factory AgentTraceEvent.fromJson(Map<String, dynamic> json) => AgentTraceEvent(
        id: json['id'] as String? ?? '',
        kind: json['kind'] as String? ?? 'tool',
        status: json['status'] as String? ?? 'running',
        title: json['title'] as String? ?? '',
        agentName: json['agentName'] as String? ?? '',
        toolName: json['toolName'] as String?,
        detail: json['detail'] as String?,
        input: json['input'] as String?,
        output: json['output'] as String?,
        startedAt: json['startedAt'] as String? ?? '',
        completedAt: json['completedAt'] as String?,
      );
}

class AgentRunTrace {
  final int version;
  final String id;
  final String status;
  final String primaryAgentId;
  final String primaryAgentName;
  final bool collaborationRequired;
  final String startedAt;
  final String? completedAt;
  final List<AgentTraceEvent> events;

  const AgentRunTrace({
    this.version = 1,
    required this.id,
    required this.status,
    required this.primaryAgentId,
    required this.primaryAgentName,
    required this.collaborationRequired,
    required this.startedAt,
    this.completedAt,
    required this.events,
  });

  Map<String, dynamic> toJson() => {
        'version': version,
        'id': id,
        'status': status,
        'primaryAgentId': primaryAgentId,
        'primaryAgentName': primaryAgentName,
        'collaborationRequired': collaborationRequired,
        'startedAt': startedAt,
        if (completedAt != null) 'completedAt': completedAt,
        'events': events.map((event) => event.toJson()).toList(),
      };

  factory AgentRunTrace.fromJson(Map<String, dynamic> json) => AgentRunTrace(
        version: json['version'] as int? ?? 1,
        id: json['id'] as String? ?? '',
        status: json['status'] as String? ?? 'running',
        primaryAgentId: json['primaryAgentId'] as String? ?? '',
        primaryAgentName: json['primaryAgentName'] as String? ?? '',
        collaborationRequired: json['collaborationRequired'] as bool? ?? false,
        startedAt: json['startedAt'] as String? ?? '',
        completedAt: json['completedAt'] as String?,
        events: (json['events'] as List<dynamic>? ?? [])
            .whereType<Map<String, dynamic>>()
            .map(AgentTraceEvent.fromJson)
            .toList(),
      );
}

class AgentClarificationOption {
  final String label;
  final String? description;

  const AgentClarificationOption({required this.label, this.description});
}

class AgentClarificationQuestion {
  final String title;
  final String? description;
  final List<AgentClarificationOption> options;

  const AgentClarificationQuestion({
    required this.title,
    this.description,
    required this.options,
  });
}

class AgentClarificationAnswer {
  final String question;
  final String answer;

  const AgentClarificationAnswer({required this.question, required this.answer});
}

class AgentClarificationRequest {
  final String id;
  final String agentName;
  final List<AgentClarificationQuestion> questions;

  const AgentClarificationRequest({
    required this.id,
    required this.agentName,
    required this.questions,
  });
}

class AgentClarificationResponse {
  final List<AgentClarificationAnswer> answers;
  final bool cancelled;

  const AgentClarificationResponse({required this.answers, required this.cancelled});
}

class Character {
  final String id;
  final String projectId;
  final String name;
  final String description;
  final String? imagePath;
  final bool isFavorited;
  final String createdAt;
  final String updatedAt;

  const Character({
    required this.id,
    required this.projectId,
    required this.name,
    required this.description,
    this.imagePath,
    required this.isFavorited,
    required this.createdAt,
    required this.updatedAt,
  });
}

class WorldInfo {
  final String id;
  final String projectId;
  final String name;
  final String description;
  final String createdAt;
  final String updatedAt;

  const WorldInfo({
    required this.id,
    required this.projectId,
    required this.name,
    required this.description,
    required this.createdAt,
    required this.updatedAt,
  });
}

class WorldInfoEntry {
  final String id;
  final String worldInfoId;
  final int uid;
  final String name;
  final int order;
  final String content;
  final int tokenCount;
  final bool isEnabled;
  final String createdAt;
  final String updatedAt;

  const WorldInfoEntry({
    required this.id,
    required this.worldInfoId,
    required this.uid,
    required this.name,
    required this.order,
    required this.content,
    required this.tokenCount,
    required this.isEnabled,
    required this.createdAt,
    required this.updatedAt,
  });
}

class LocalSearchResult {
  final String id;
  final String sourceType;
  final String sourceId;
  final String title;
  final String content;
  final double score;
  final double? rerankScore;

  const LocalSearchResult({
    required this.id,
    required this.sourceType,
    required this.sourceId,
    required this.title,
    required this.content,
    required this.score,
    this.rerankScore,
  });
}

class ModelSelection {
  final Provider provider;
  final LlmModel model;
  final String apiKey;

  const ModelSelection({
    required this.provider,
    required this.model,
    required this.apiKey,
  });
}