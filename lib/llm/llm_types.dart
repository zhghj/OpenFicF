class ProviderMetadata {
  final String? geminiThoughtSignature;
  final Map<String, dynamic>? openAiExtraContent;

  const ProviderMetadata({this.geminiThoughtSignature, this.openAiExtraContent});
}

class AgentToolCall {
  final String id;
  final String name;
  final Map<String, dynamic> arguments;
  final ProviderMetadata? providerMetadata;

  const AgentToolCall({
    required this.id,
    required this.name,
    required this.arguments,
    this.providerMetadata,
  });
}

class AgentMessage {
  final String role;
  final String content;
  final List<AgentToolCall>? toolCalls;
  final String? toolCallId;
  final String? toolName;

  const AgentMessage({
    required this.role,
    required this.content,
    this.toolCalls,
    this.toolCallId,
    this.toolName,
  });
}

class AgentToolDefinition {
  final String name;
  final String description;
  final Map<String, dynamic> parameters;

  const AgentToolDefinition({
    required this.name,
    required this.description,
    required this.parameters,
  });
}

class ModelTurn {
  final String content;
  final List<AgentToolCall> toolCalls;

  const ModelTurn({required this.content, required this.toolCalls});
}