import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../core/utils.dart';
import '../data/repositories.dart';
import '../models.dart';
import 'limits.dart';
import 'llm_types.dart';

const int _requestTimeoutMs = 120000;
const int _maxRequestAttempts = 3;
const int _maxServerErrorAttempts = 2;
/// 触发速率限制（429）时更耐心地退避重试，减少长任务因限流中断。
const int _maxRateLimitAttempts = 5;
const Set<int> _retryableStatusCodes = {408, 429, 500, 502, 503, 504};

Map<String, dynamic> _parseJsonObject(String value) {
  try {
    final parsed = jsonDecode(value);
    if (parsed is Map) return parsed.map((key, item) => MapEntry('$key', item));
    return <String, dynamic>{};
  } catch (_) {
    return <String, dynamic>{};
  }
}

Map<String, dynamic>? _openAiExtraContent(Map<String, dynamic> call) {
  final candidates = [
    call['extra_content'],
    call['extraContent'],
    call['provider_metadata'],
    call['providerMetadata'],
  ];
  for (final candidate in candidates) {
    if (candidate is! Map || candidate.isEmpty) continue;
    final record = asRecord(candidate);
    if (record['openAiExtraContent'] is Map) {
      return asRecord(record['openAiExtraContent']);
    }
    final signature = record['geminiThoughtSignature'];
    if (signature is String && signature.trim().isNotEmpty) {
      return {
        'google': {'thought_signature': signature}
      };
    }
    return record;
  }
  final signature = call['thought_signature'] ?? call['thoughtSignature'];
  if (signature is String && signature.trim().isNotEmpty) {
    return {
      'google': {'thought_signature': signature}
    };
  }
  return null;
}

String _errorDetail(Map<String, dynamic> data, String text, String statusText) {
  final candidates = <String>[];
  final error = data['error'];
  if (error is Map) {
    final message = error['message'];
    final detail = error['detail'];
    if (message is String && message.trim().isNotEmpty) candidates.add(message);
    if (detail is String && detail.trim().isNotEmpty) candidates.add(detail);
  } else if (error is String && error.trim().isNotEmpty) {
    candidates.add(error);
  }
  if (data['message'] is String && (data['message'] as String).trim().isNotEmpty) {
    candidates.add(data['message'] as String);
  }
  if (data['detail'] is String && (data['detail'] as String).trim().isNotEmpty) {
    candidates.add(data['detail'] as String);
  }
  final primary = candidates.isEmpty ? null : candidates.first.trim();
  if (primary != null && !RegExp(r'^\d{3}$').hasMatch(primary)) return primary;
  final raw = text.trim();
  if (raw.isNotEmpty && !RegExp(r'^\{?\s*"?error"?\s*:\s*"?\d{3}"?\s*\}?$', caseSensitive: false).hasMatch(raw)) {
    return raw.length > 4000 ? raw.substring(0, 4000) : raw;
  }
  return primary ?? (statusText.isNotEmpty ? statusText : '供应商未返回错误详情');
}

int _retryDelay(http.Response response, int attempt) {
  final isRateLimit = response.statusCode == 429;
  final retryAfter = response.headers['retry-after'];
  if (retryAfter != null) {
    final seconds = int.tryParse(retryAfter);
    if (seconds != null && seconds >= 0) {
      final ms = seconds * 1000;
      // 供应商明确给出的等待时间优先，但限制上限避免卡太久。
      return ms.clamp(1000, isRateLimit ? 60000 : 30000);
    }
    final date = DateTime.tryParse(retryAfter);
    if (date != null) {
      final delta = date.difference(DateTime.now()).inMilliseconds;
      return delta.clamp(1000, isRateLimit ? 60000 : 30000);
    }
  }
  if (isRateLimit) {
    // 4s, 8s, 16s, 32s，封顶 45s。
    return (4000 * (1 << attempt)).clamp(4000, 45000);
  }
  return (1500 * (1 << attempt)).clamp(0, 8000);
}

Future<Map<String, dynamic>> _requestJson(
  String url,
  Map<String, String> headers,
  Map<String, dynamic> body,
) async {
  final configured = int.tryParse(await getSetting('connections.requestTimeout') ?? '');
  final requestTimeout = (configured != null && configured >= 10000 && configured <= 300000)
      ? configured
      : _requestTimeoutMs;
  Object? lastError;
  final client = http.Client();
  try {
    for (var attempt = 0; attempt < _maxRateLimitAttempts; attempt += 1) {
      try {
        final response = await client
            .post(Uri.parse(url), headers: headers, body: jsonEncode(body))
            .timeout(Duration(milliseconds: requestTimeout));
        final text = response.body;
        Map<String, dynamic> data = <String, dynamic>{};
        if (text.isNotEmpty) {
          Object? parsed;
          try {
            parsed = jsonDecode(text);
          } catch (_) {
            if (response.statusCode >= 200 && response.statusCode < 300) {
              throw Exception('模型服务返回了无法解析的非 JSON 响应：${text.trim().substring(0, text.trim().length > 300 ? 300 : text.trim().length)}');
            }
          }
          if (parsed is Map) {
            data = parsed.map((key, item) => MapEntry('$key', item));
          } else if (parsed != null && response.statusCode >= 200 && response.statusCode < 300) {
            throw Exception('模型服务返回的 JSON 不是对象：${text.trim()}');
          }
        } else if (response.statusCode >= 200 && response.statusCode < 300) {
          throw Exception('模型服务返回了空响应体');
        }
        if (response.statusCode >= 200 && response.statusCode < 300) return data;
        final detail = _errorDetail(data, text, response.reasonPhrase ?? '');
        final requestError = Exception('HTTP ${response.statusCode}: $detail');
        lastError = requestError;
        final maxAttempts = response.statusCode == 429 ? _maxRateLimitAttempts : _maxServerErrorAttempts;
        if (!_retryableStatusCodes.contains(response.statusCode) || attempt + 1 >= maxAttempts) {
          throw requestError;
        }
        await Future<void>.delayed(Duration(milliseconds: _retryDelay(response, attempt)));
      } on TimeoutException {
        lastError = Exception('模型请求超时，请检查网络或 Base URL');
        if (attempt + 1 >= _maxRequestAttempts) throw lastError;
        await Future<void>.delayed(Duration(milliseconds: (1000 * (1 << attempt)).clamp(0, 4000)));
      } on SocketException catch (error) {
        lastError = Exception('fetch failed: ${error.message}');
        if (attempt + 1 >= _maxRequestAttempts) throw lastError;
        await Future<void>.delayed(Duration(milliseconds: (1000 * (1 << attempt)).clamp(0, 4000)));
      } on http.ClientException catch (error) {
        lastError = Exception('fetch failed: ${error.message}');
        if (attempt + 1 >= _maxRequestAttempts) throw lastError;
        await Future<void>.delayed(Duration(milliseconds: (1000 * (1 << attempt)).clamp(0, 4000)));
      }
    }
  } finally {
    client.close();
  }
  throw lastError ?? Exception('模型请求失败');
}

class ModelCallOptions {
  /// 保证本次请求至少有这么多输出 Token，用于结构上必须长输出的步骤。
  final int? minOutputTokens;

  const ModelCallOptions({this.minOutputTokens});
}

/// 模型在返回正文前就耗尽了输出 Token；调用方会据此自动放宽上限重试。
class OutputTruncatedException implements Exception {
  final int limit;
  final String provider;

  const OutputTruncatedException(this.limit, this.provider);

  @override
  String toString() =>
      '$provider 在返回正文前就用完了 $limit 个输出 Token（思考型模型的推理过程也计入该上限）。';
}

int _resolveOutputTokens(ModelSelection selection, ModelCallOptions? options) {
  final configured = normalizeMaxOutputTokens(selection.model.maxTokens);
  final min = options?.minOutputTokens;
  if (min == null) return configured;
  return configured > min ? configured : (min > maxConfiguredOutputTokens ? maxConfiguredOutputTokens : min);
}

Future<ModelTurn> _callOpenAi(
  ModelSelection selection,
  List<AgentMessage> messages,
  List<AgentToolDefinition> tools,
  ModelCallOptions? options,
) async {
  final maxOutputTokens = _resolveOutputTokens(selection, options);
  final data = await _requestJson(
    '${normalizeBaseUrl(selection.provider.baseUrl)}/chat/completions',
    {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer ${selection.apiKey}',
    },
    {
      'model': selection.model.modelId,
      'temperature': selection.model.temperature,
      'max_tokens': maxOutputTokens,
      'messages': messages.map((message) {
        final hasCalls = message.toolCalls?.isNotEmpty ?? false;
        return {
          'role': message.role,
          'content': hasCalls ? (message.content.isEmpty ? null : message.content) : message.content,
          if (hasCalls)
            'tool_calls': message.toolCalls!.map((call) {
              final extra = call.providerMetadata?.openAiExtraContent;
              return {
                'id': call.id,
                'type': 'function',
                'function': {'name': call.name, 'arguments': jsonEncode(call.arguments)},
                'extra_content': ?extra,
              };
            }).toList(),
          if (message.toolCallId != null) 'tool_call_id': message.toolCallId,
        };
      }).toList(),
      if (tools.isNotEmpty) ...{
        'tools': tools
            .map((tool) => {
                  'type': 'function',
                  'function': {
                    'name': tool.name,
                    'description': tool.description,
                    'parameters': tool.parameters,
                  },
                })
            .toList(),
        'tool_choice': 'auto',
      },
    },
  );
  final choices = data['choices'];
  final choice = (choices is List && choices.isNotEmpty && choices.first is Map)
      ? asRecord(choices.first)
      : <String, dynamic>{};
  final message = choice['message'] is Map ? asRecord(choice['message']) : <String, dynamic>{};
  final finishReason = choice['finish_reason'] is String ? choice['finish_reason'] as String : '';
  final rawCalls = message['tool_calls'];
  final toolCalls = <AgentToolCall>[];
  if (rawCalls is List) {
    for (final item in rawCalls) {
      if (item is! Map) continue;
      final call = asRecord(item);
      final function = call['function'] is Map ? asRecord(call['function']) : <String, dynamic>{};
      final metadata = _openAiExtraContent(call);
      toolCalls.add(AgentToolCall(
        id: '${call['id'] ?? ''}',
        name: '${function['name'] ?? ''}',
        arguments: _parseJsonObject('${function['arguments'] ?? '{}'}'),
        providerMetadata: metadata == null ? null : ProviderMetadata(openAiExtraContent: metadata),
      ));
    }
  }
  final content = message['content'] is String ? message['content'] as String : '';
  if (content.trim().isEmpty && toolCalls.isEmpty) {
    if (finishReason == 'length') {
      throw OutputTruncatedException(maxOutputTokens, '模型');
    }
    if (finishReason.isNotEmpty && finishReason != 'stop') {
      throw Exception('模型没有返回内容，finish_reason=$finishReason');
    }
  }
  return ModelTurn(content: content, toolCalls: toolCalls);
}

Object? _toGeminiSchema(Object? value) {
  if (value is List) return value.map(_toGeminiSchema).toList();
  if (value is! Map) return value;
  final source = asRecord(value);
  final output = <String, dynamic>{};
  for (final entry in source.entries) {
    final key = entry.key;
    final item = entry.value;
    if (key == 'type' && item is String) {
      output[key] = item.toUpperCase();
    } else if (key == 'required' && item is List && item.isEmpty) {
      continue;
    } else if (key != 'additionalProperties') {
      output[key] = _toGeminiSchema(item);
    }
  }
  if (output['type'] == null && source['properties'] is Map) output['type'] = 'OBJECT';
  if (output['type'] == null && source.containsKey('items')) output['type'] = 'ARRAY';
  if (output['type'] == null && source['enum'] is List && (source['enum'] as List).isNotEmpty) {
    final sample = (source['enum'] as List).first;
    output['type'] = sample is num
        ? 'NUMBER'
        : sample is bool
            ? 'BOOLEAN'
            : 'STRING';
  }
  output['type'] ??= 'STRING';
  return output;
}

List<Map<String, dynamic>> _geminiContents(List<AgentMessage> messages) {
  final contents = <Map<String, dynamic>>[];
  for (final message in messages) {
    if (message.role == 'system') continue;
    if (message.role == 'tool') {
      final part = {
        'functionResponse': {
          'name': message.toolName,
          'response': _parseJsonObject(message.content),
        }
      };
      if (contents.isNotEmpty) {
        final previous = contents.last;
        final parts = previous['parts'];
        if (previous['role'] == 'user' &&
            parts is List &&
            parts.every((item) => item is Map && item.containsKey('functionResponse'))) {
          parts.add(part);
          continue;
        }
      }
      contents.add({
        'role': 'user',
        'parts': [part],
      });
      continue;
    }
    final parts = <Map<String, dynamic>>[];
    if (message.content.isNotEmpty) parts.add({'text': message.content});
    for (final call in message.toolCalls ?? <AgentToolCall>[]) {
      parts.add({
        'functionCall': {'name': call.name, 'args': call.arguments},
        if (call.providerMetadata?.geminiThoughtSignature != null)
          'thoughtSignature': call.providerMetadata!.geminiThoughtSignature,
      });
    }
    if (parts.isNotEmpty) {
      contents.add({
        'role': message.role == 'assistant' ? 'model' : 'user',
        'parts': parts,
      });
    }
  }
  return contents;
}

Future<ModelTurn> _callGemini(
  ModelSelection selection,
  List<AgentMessage> messages,
  List<AgentToolDefinition> tools,
  ModelCallOptions? options,
) async {
  final maxOutputTokens = _resolveOutputTokens(selection, options);
  final system = messages
      .where((message) => message.role == 'system')
      .map((message) => message.content)
      .join('\n\n');
  final baseUrl = normalizeBaseUrl(selection.provider.baseUrl);
  final url = '$baseUrl/models/${Uri.encodeComponent(selection.model.modelId)}:generateContent';
  final data = await _requestJson(url, {
    'Content-Type': 'application/json',
    'x-goog-api-key': selection.apiKey,
  }, {
    if (system.isNotEmpty) 'systemInstruction': {
      'parts': [
        {'text': system}
      ]
    },
    'contents': _geminiContents(messages),
    if (tools.isNotEmpty)
      'tools': [
        {
          'functionDeclarations': tools
              .map((tool) => {
                    'name': tool.name,
                    'description': tool.description,
                    'parameters': _toGeminiSchema(tool.parameters),
                  })
              .toList(),
        }
      ],
    'generationConfig': {
      'temperature': selection.model.temperature,
      'maxOutputTokens': maxOutputTokens,
    },
  });
  final candidates = data['candidates'];
  final candidate = (candidates is List && candidates.isNotEmpty && candidates.first is Map)
      ? asRecord(candidates.first)
      : <String, dynamic>{};
  final content = candidate['content'] is Map ? asRecord(candidate['content']) : <String, dynamic>{};
  final parts = content['parts'] is List ? content['parts'] as List : <dynamic>[];
  final finishReason = '${candidate['finishReason'] ?? ''}';
  if (parts.isEmpty) {
    if (finishReason == 'MAX_TOKENS') {
      throw OutputTruncatedException(maxOutputTokens, 'Gemini');
    }
    final promptFeedback = data['promptFeedback'];
    final reason = (promptFeedback is Map && promptFeedback['blockReason'] != null)
        ? '${promptFeedback['blockReason']}'
        : (finishReason.isNotEmpty ? finishReason : '模型没有返回内容');
    throw Exception('Gemini 请求未完成: $reason');
  }
  final toolCalls = <AgentToolCall>[];
  final buffer = StringBuffer();
  for (var index = 0; index < parts.length; index += 1) {
    final part = parts[index];
    if (part is! Map) continue;
    final record = asRecord(part);
    if (record['text'] is String) buffer.write(record['text'] as String);
    final functionCall = record['functionCall'];
    if (functionCall is Map) {
      final call = asRecord(functionCall);
      final signature = record['thoughtSignature'] ?? record['thought_signature'];
      toolCalls.add(AgentToolCall(
        id: 'gemini-${DateTime.now().millisecondsSinceEpoch}-$index',
        name: '${call['name']}',
        arguments: call['args'] is Map ? asRecord(call['args']) : <String, dynamic>{},
        providerMetadata: signature is String
            ? ProviderMetadata(geminiThoughtSignature: signature)
            : null,
      ));
    }
  }
  return ModelTurn(content: buffer.toString(), toolCalls: toolCalls);
}

List<Map<String, dynamic>> _anthropicMessages(List<AgentMessage> messages) {
  final output = <Map<String, dynamic>>[];
  for (final message in messages) {
    if (message.role == 'system') continue;
    final role = message.role == 'assistant' ? 'assistant' : 'user';
    final blocks = <Map<String, dynamic>>[];
    if (message.role == 'tool') {
      final result = _parseJsonObject(message.content);
      blocks.add({
        'type': 'tool_result',
        'tool_use_id': message.toolCallId,
        'content': message.content,
        if (result['error'] is String) 'is_error': true,
      });
    } else {
      if (message.content.isNotEmpty) blocks.add({'type': 'text', 'text': message.content});
      for (final call in message.toolCalls ?? <AgentToolCall>[]) {
        blocks.add({
          'type': 'tool_use',
          'id': call.id,
          'name': call.name,
          'input': call.arguments,
        });
      }
    }
    if (blocks.isEmpty) continue;
    if (output.isNotEmpty && output.last['role'] == role && output.last['content'] is List) {
      (output.last['content'] as List).addAll(blocks);
    } else {
      output.add({'role': role, 'content': blocks});
    }
  }
  return output;
}

Future<ModelTurn> _callAnthropic(
  ModelSelection selection,
  List<AgentMessage> messages,
  List<AgentToolDefinition> tools,
  ModelCallOptions? options,
) async {
  final maxOutputTokens = _resolveOutputTokens(selection, options);
  final system = messages
      .where((message) => message.role == 'system')
      .map((message) => message.content)
      .join('\n\n');
  final data = await _requestJson(
    '${normalizeBaseUrl(selection.provider.baseUrl)}/messages',
    {
      'Content-Type': 'application/json',
      'x-api-key': selection.apiKey,
      'anthropic-version': '2023-06-01',
    },
    {
      'model': selection.model.modelId,
      'system': system,
      'temperature': selection.model.temperature,
      'max_tokens': maxOutputTokens,
      'messages': _anthropicMessages(messages),
      if (tools.isNotEmpty)
        'tools': tools
            .map((tool) => {
                  'name': tool.name,
                  'description': tool.description,
                  'input_schema': tool.parameters,
                })
            .toList(),
    },
  );
  final blocks = data['content'] is List ? data['content'] as List : <dynamic>[];
  final buffer = StringBuffer();
  final toolCalls = <AgentToolCall>[];
  for (final block in blocks) {
    if (block is! Map) continue;
    final record = asRecord(block);
    if (record['type'] == 'text' && record['text'] is String) {
      buffer.write(record['text'] as String);
    } else if (record['type'] == 'tool_use') {
      toolCalls.add(AgentToolCall(
        id: '${record['id']}',
        name: '${record['name']}',
        arguments: record['input'] is Map ? asRecord(record['input']) : <String, dynamic>{},
      ));
    }
  }
  final content = buffer.toString();
  if (content.trim().isEmpty && toolCalls.isEmpty && data['stop_reason'] == 'max_tokens') {
    throw OutputTruncatedException(maxOutputTokens, 'Anthropic');
  }
  return ModelTurn(content: content, toolCalls: toolCalls);
}

Future<ModelTurn> _dispatchModelCall(
  ModelSelection selection,
  List<AgentMessage> messages,
  List<AgentToolDefinition> tools,
  ModelCallOptions? options,
) {
  switch (selection.provider.type) {
    case ProviderType.googleGenai:
      return _callGemini(selection, messages, tools, options);
    case ProviderType.anthropic:
      return _callAnthropic(selection, messages, tools, options);
    case ProviderType.openaiCompatible:
      return _callOpenAi(selection, messages, tools, options);
  }
}

/// 调用模型。若输出 Token 用尽且未产出正文，会自动放宽上限重试（最多两次），
/// 相当于“启用模型最大输出”，避免思考型模型因推理占用而上限过低。
Future<ModelTurn> callModel(
  ModelSelection selection,
  List<AgentMessage> messages,
  List<AgentToolDefinition> tools, [
  ModelCallOptions? options,
]) async {
  var effectiveOptions = options;
  for (var attempt = 0; attempt < 3; attempt += 1) {
    try {
      return await _dispatchModelCall(selection, messages, tools, effectiveOptions);
    } on OutputTruncatedException catch (error) {
      final current = _resolveOutputTokens(selection, effectiveOptions);
      final next = (current * 2).clamp(current + 1, maxConfiguredOutputTokens);
      if (next <= current || attempt >= 2) {
        throw Exception(
          '$error 已重试并放宽到上限仍不足；请在“设置 → 模型与供应商”调高该模型的最大输出 Token 数（思考型模型的推理也计入），或换用非思考模型。',
        );
      }
      effectiveOptions = ModelCallOptions(minOutputTokens: next);
    }
  }
  throw Exception('模型调用失败');
}