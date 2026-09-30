import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../agent/runtime.dart';
import '../core/utils.dart';
import '../data/repositories.dart';
import '../models.dart';
import '../services/active_model.dart';
import '../settings/config.dart';
import '../widgets/agent_run_view.dart';
import '../widgets/common.dart';

class AssistantScreen extends StatefulWidget {
  final Project project;

  const AssistantScreen({super.key, required this.project});

  @override
  State<AssistantScreen> createState() => _AssistantScreenState();
}

class _AssistantScreenState extends State<AssistantScreen> {
  static const int _pageSize = 30;

  final _inputController = TextEditingController();
  final _scrollController = ScrollController();

  List<ChatSession> _sessions = [];
  ChatSession? _session;
  List<ChatMessage> _messages = [];
  List<LlmModel> _models = [];
  String? _activeModelId;
  bool _loading = true;
  bool _running = false;
  AgentRunTrace? _liveTrace;
  int? _oldestRowId;
  bool _hasMoreOlder = false;
  bool _loadingOlder = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _load();
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    if (_scrollController.position.pixels <= 80 && _hasMoreOlder && !_loadingOlder) {
      _loadOlder();
    }
  }

  Future<void> _load() async {
    try {
      final sessions = await listChatSessions(widget.project.id);
      final models = await listModels();
      final activeId = await getSetting('activeModelId');
      final storedSessionId = await getSetting('assistant.activeSession.${widget.project.id}');
      ChatSession? session;
      for (final item in sessions) {
        if (item.id == storedSessionId) session = item;
      }
      session ??= sessions.isEmpty ? null : sessions.first;
      if (!mounted) return;
      setState(() {
        _sessions = sessions;
        _models = models;
        _activeModelId = activeId;
        _session = session;
        _loading = false;
      });
      if (session != null) await _loadLatest(session.id);
    } catch (error) {
      if (!mounted) return;
      setState(() => _loading = false);
      showErrorSnack(context, error);
    }
  }

  /// 只加载最新一页消息，保证最新请求可见并减少加载压力。
  Future<List<ChatMessage>> _loadLatest(String sessionId, {bool scroll = true}) async {
    final page = await listRecentMessagePage(sessionId, limit: _pageSize);
    if (!mounted) return page.messages;
    setState(() {
      _messages = page.messages;
      _oldestRowId = page.oldestRowId;
      _hasMoreOlder = page.hasMore;
    });
    if (scroll) _scrollToBottom();
    return page.messages;
  }

  /// 向上滚动时加载更早的一页，并保持视口位置不跳动。
  Future<void> _loadOlder() async {
    final session = _session;
    if (session == null || !_hasMoreOlder || _loadingOlder || _oldestRowId == null) return;
    setState(() => _loadingOlder = true);
    try {
      final page = await listRecentMessagePage(session.id, limit: _pageSize, beforeRowId: _oldestRowId);
      if (!mounted) return;
      final beforeMax = _scrollController.hasClients ? _scrollController.position.maxScrollExtent : 0.0;
      setState(() {
        _messages = [...page.messages, ..._messages];
        _oldestRowId = page.oldestRowId ?? _oldestRowId;
        _hasMoreOlder = page.hasMore;
        _loadingOlder = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scrollController.hasClients) return;
        final afterMax = _scrollController.position.maxScrollExtent;
        final delta = afterMax - beforeMax;
        _scrollController.jumpTo((_scrollController.offset + delta).clamp(0.0, afterMax));
      });
    } catch (error) {
      if (mounted) {
        setState(() => _loadingOlder = false);
        showErrorSnack(context, error);
      }
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _createSession() async {
    try {
      final session = await createChatSession(widget.project.id, _activeModelId);
      await setSetting('assistant.activeSession.${widget.project.id}', session.id);
      await _load();
    } catch (error) {
      if (mounted) showErrorSnack(context, error);
    }
  }

  Future<void> _selectSession(ChatSession session) async {
    await setSetting('assistant.activeSession.${widget.project.id}', session.id);
    setState(() {
      _session = session;
      _messages = [];
      _liveTrace = null;
      _oldestRowId = null;
      _hasMoreOlder = false;
      _loadingOlder = false;
    });
    await _loadLatest(session.id);
  }

  Future<void> _deleteSession(ChatSession session) async {
    final confirmed = await confirmDialog(
      context,
      title: '删除对话',
      message: '确定删除这个对话及其全部消息吗？',
      confirmLabel: '删除',
      destructive: true,
    );
    if (!confirmed) return;
    try {
      await deleteChatSession(session.id);
      await _load();
    } catch (error) {
      if (mounted) showErrorSnack(context, error);
    }
  }

  Future<void> _renameSession(ChatSession session) async {
    final title = await promptText(context, title: '重命名对话', initialValue: session.title);
    if (title == null || title.isEmpty) return;
    try {
      await updateChatSession(id: session.id, title: title);
      await _load();
    } catch (error) {
      if (mounted) showErrorSnack(context, error);
    }
  }

  Future<void> _setSessionModel(LlmModel model) async {
    final session = _session;
    if (session == null) return;
    try {
      await updateChatSession(id: session.id, modelId: model.id);
      await _load();
    } catch (error) {
      if (mounted) showErrorSnack(context, error);
    }
  }

  Future<ModelSelection?> _resolveSelection() async {
    final session = _session;
    final fixture = await getActiveModelSelection();
    if (session?.modelId != null) {
      final models = await listModels();
      LlmModel? model;
      for (final item in models) {
        if (item.id == session!.modelId) model = item;
      }
      if (model != null) {
        final providers = await listProviders();
        for (final provider in providers) {
          if (provider.id == model.providerId) {
            final apiKey = await getProviderApiKey(provider);
            if (apiKey.isNotEmpty) {
              return ModelSelection(provider: provider, model: model, apiKey: apiKey);
            }
          }
        }
      }
    }
    return fixture;
  }

  String _toolLabel(String name) {
  for (final tool in toolCatalog) {
    if (tool.key == name) return tool.name;
  }
  return name;
}

/// 允许用户在批准写入前补充内容；返回应追加到的参数字段。
String? _supplementField(String name) {
  switch (name) {
    case 'create_character':
    case 'edit_character':
      return 'description';
    case 'create_world_entry':
    case 'edit_world_entry':
    case 'write_note':
    case 'edit_note':
      return 'content';
    case 'create_canon_entry':
    case 'update_canon_entry':
      return 'detail';
    case 'update_world_info':
      return 'description';
    case 'upsert_hook':
      return 'notes';
    case 'upsert_state_fact':
      return 'object';
    case 'write_chapter_summary':
      return 'events';
    default:
      return null;
  }
}

String _supplementLabel(String name) {
  switch (_supplementField(name)) {
    case 'description':
      return '补充设定（可选，会追加到描述）';
    case 'content':
      return '补充内容（可选，会追加到正文/内容）';
    case 'detail':
      return '补充细节（可选，会追加到详情）';
    case 'notes':
      return '补充备注（可选）';
    case 'object':
      return '补充事实（可选，会追加到事实）';
    case 'events':
      return '补充事件（可选）';
    default:
      return '补充内容（可选）';
  }
}

Map<String, dynamic> _mergeSupplement(String name, Map<String, dynamic> args, String supplement) {
  final field = _supplementField(name);
  final next = Map<String, dynamic>.from(args);
  if (field == null) return next;
  final existing = next[field];
  final base = existing is String ? existing.trim() : '';
  next[field] = [
    if (base.isNotEmpty) base,
    if (field == 'notes' || field == 'object') supplement else '补充：$supplement',
  ].join(field == 'notes' || field == 'object' ? '\n' : '\n\n');
  return next;
}

Future<Map<String, dynamic>?> _approveTool(String name, Map<String, dynamic> args) async {
  if (!mounted) return null;
  final supplementController = TextEditingController();
  final field = _supplementField(name);
  final json = args.isEmpty ? '（无参数）' : const JsonEncoder.withIndent('  ').convert(args);
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      scrollable: true,
      title: Text('允许调用「${_toolLabel(name)}」？'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(json,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(fontFamily: 'monospace', height: 1.35)),
            if (field != null) ...[
              const SizedBox(height: 12),
              TextField(
                controller: supplementController,
                minLines: 2,
                maxLines: 6,
                decoration: InputDecoration(labelText: _supplementLabel(name)),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('拒绝')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('允许')),
      ],
    ),
  );
  if (result != true) return null;
  if (field == null) return args;
  final supplement = supplementController.text.trim();
  if (supplement.isEmpty) return args;
  return _mergeSupplement(name, args, supplement);
}

  Future<AgentClarificationResponse> _askUser(AgentClarificationRequest request) async {
    if (!mounted) return const AgentClarificationResponse(answers: [], cancelled: true);
    final answers = <AgentClarificationAnswer>[];
    var cancelled = false;
    for (final question in request.questions) {
      if (!mounted) break;
      final answer = await _showQuestion(question);
      if (answer == null) {
        cancelled = true;
        break;
      }
      answers.add(AgentClarificationAnswer(question: question.title, answer: answer));
    }
    return AgentClarificationResponse(answers: answers, cancelled: cancelled);
  }

  Future<String?> _showQuestion(AgentClarificationQuestion question) async {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: Text(question.title),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (question.description != null) ...[
                Text(question.description!,
                    style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 12),
              ],
              for (final option in question.options)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context, option.label),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(option.label, textAlign: TextAlign.left),
                        if (option.description != null)
                          Text(option.description!,
                              style: Theme.of(context).textTheme.bodySmall,
                              textAlign: TextAlign.left),
                      ],
                    ),
                  ),
                ),
              TextField(
                controller: controller,
                decoration: const InputDecoration(hintText: '或自行输入答案（可补充条目）'),
                maxLines: 4,
                minLines: 1,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('跳过')),
          FilledButton(
            onPressed: () {
              final text = controller.text.trim();
              if (text.isNotEmpty) Navigator.pop(context, text);
            },
            child: const Text('提交'),
          ),
        ],
      ),
    );
  }

  Future<void> _send() async {
    final session = _session;
    final text = _inputController.text.trim();
    if (session == null || text.isEmpty || _running) return;
    _inputController.clear();
    final selection = await _resolveSelection();
    if (!mounted) return;
    if (selection == null) {
      showMessageSnack(context, '请先在设置中配置供应商、模型，并设为默认模型');
      return;
    }
    try {
      await addMessage(session.id, 'user', text);
      setState(() {
        _running = true;
        _liveTrace = null;
      });
      final history = await _loadLatest(session.id);
      await _runAgent(selection, history);
    } catch (error) {
      if (mounted) {
        setState(() => _running = false);
        showErrorSnack(context, error);
      }
    }
  }

  Future<void> _runAgent(ModelSelection selection, List<ChatMessage> history) async {
    final session = _session!;
    try {
      final result = await runAgent(
        project: widget.project,
        selection: selection,
        history: history,
        agentId: await getSetting('agent.activeDefinitionId'),
        approveTool: _approveTool,
        askUser: _askUser,
        onTrace: (trace) {
          if (mounted) {
            setState(() => _liveTrace = trace);
            _scrollToBottom();
          }
        },
      );
      await addMessage(
        session.id,
        'assistant',
        result.content,
        ChatMessageMetadata(agentTrace: result.trace, taskStatus: 'completed'),
      );
    } catch (error) {
      final message = errorText(error);
      final trace = error is AgentRunError ? error.trace : null;
      final lastUser = history.lastWhere((m) => m.role == 'user', orElse: () => history.last);
      await addMessage(
        session.id,
        'assistant',
        '本次任务失败：$message',
        ChatMessageMetadata(
          taskStatus: 'failed',
          errorMessage: message,
          agentTrace: trace,
          retryContext: RetryContext(
            userMessageId: lastUser.id,
            modelId: selection.model.id,
            agentId: null,
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _running = false);
        await _loadLatest(session.id);
      }
    }
  }

  Future<void> _retry(ChatMessage failedMessage) async {
    final session = _session;
    final retryContext = failedMessage.metadata?.retryContext;
    if (session == null || retryContext == null || _running) return;
    final selection = await _resolveSelection();
    if (!mounted) return;
    if (selection == null) {
      showMessageSnack(context, '请先在设置中配置默认模型');
      return;
    }
    try {
      await deleteMessagesFrom(session.id, failedMessage.id);
      setState(() {
        _running = true;
        _liveTrace = null;
      });
      final history = await _loadLatest(session.id);
      await _runAgent(selection, history);
    } catch (error) {
      if (mounted) {
        setState(() => _running = false);
        showErrorSnack(context, error);
      }
    }
  }

  Future<void> _editUserMessage(ChatMessage message) async {
    final session = _session;
    if (session == null || _running) return;
    final content = await promptText(
      context,
      title: '编辑你的消息',
      initialValue: message.content,
      maxLines: 6,
    );
    if (content == null || content.isEmpty) return;
    final selection = await _resolveSelection();
    if (!mounted) return;
    if (selection == null) {
      showMessageSnack(context, '请先在设置中配置默认模型');
      return;
    }
    try {
      await replaceUserMessageBranch(session.id, message.id, content);
      setState(() {
        _running = true;
        _liveTrace = null;
      });
      final history = await _loadLatest(session.id);
      await _runAgent(selection, history);
    } catch (error) {
      if (mounted) {
        setState(() => _running = false);
        showErrorSnack(context, error);
      }
    }
  }

  Future<void> _copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) showMessageSnack(context, '已复制');
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    return Scaffold(
      appBar: AppBar(
        title: _SessionTitle(
          session: session,
          sessions: _sessions,
          models: _models,
          onSelect: _selectSession,
          onCreate: _createSession,
          onModelSelected: _setSessionModel,
        ),
        actions: [
          IconButton(
            tooltip: '新建对话',
            onPressed: _createSession,
            icon: const Icon(Icons.add_comment_outlined),
          ),
          if (session != null)
            PopupMenuButton<String>(
              onSelected: (value) {
                if (value == 'rename') _renameSession(session);
                if (value == 'delete') _deleteSession(session);
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'rename', child: Text('重命名对话')),
                PopupMenuItem(value: 'delete', child: Text('删除对话')),
              ],
            ),
        ],
      ),
      body: _loading
          ? const LoadingView()
          : session == null
              ? EmptyState(
                  icon: Icons.auto_awesome_outlined,
                  title: '还没有对话',
                  subtitle: '新建一个对话，让 Agent 读取作品资料协助创作。',
                  action: FilledButton.icon(
                    onPressed: _createSession,
                    icon: const Icon(Icons.add),
                    label: const Text('新建对话'),
                  ),
                )
              : Column(
                  children: [
                    Expanded(
                      child: ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.all(12),
                        itemCount: _messages.length +
                            (_running ? 1 : 0) +
                            ((_hasMoreOlder || _loadingOlder) ? 1 : 0),
                        itemBuilder: (context, index) {
                          final showHeader = _hasMoreOlder || _loadingOlder;
                          if (showHeader && index == 0) {
                            return Padding(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              child: Center(
                                child: _loadingOlder
                                    ? const SizedBox(
                                        width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                                    : TextButton.icon(
                                        onPressed: _loadOlder,
                                        icon: const Icon(Icons.history, size: 18),
                                        label: const Text('加载更早的消息'),
                                      ),
                              ),
                            );
                          }
                          final messageIndex = showHeader ? index - 1 : index;
                          if (messageIndex >= _messages.length) {
                            return Padding(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              child: _liveTrace != null
                                  ? AgentRunView(trace: _liveTrace!)
                                  : const Row(
                                      children: [
                                        SizedBox(
                                            width: 16,
                                            height: 16,
                                            child: CircularProgressIndicator(strokeWidth: 2)),
                                        SizedBox(width: 8),
                                        Text('Agent 正在思考…'),
                                      ],
                                    ),
                            );
                          }
                          final message = _messages[messageIndex];
                          return _MessageBubble(
                            message: message,
                            onCopy: () => _copy(message.content),
                            onRetry: message.metadata?.taskStatus == 'failed'
                                ? () => _retry(message)
                                : null,
                            onEdit: message.role == 'user' ? () => _editUserMessage(message) : null,
                          );
                        },
                      ),
                    ),
                    SafeArea(
                      top: false,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _inputController,
                                minLines: 1,
                                maxLines: 5,
                                enabled: !_running,
                                decoration: const InputDecoration(hintText: '描述你的创作任务…'),
                                onSubmitted: (_) => _send(),
                              ),
                            ),
                            const SizedBox(width: 8),
                            IconButton.filled(
                              onPressed: _running ? null : _send,
                              icon: _running
                                  ? const SizedBox(
                                      width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                                  : const Icon(Icons.send),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
    );
  }
}

class _SessionTitle extends StatelessWidget {
  final ChatSession? session;
  final List<ChatSession> sessions;
  final List<LlmModel> models;
  final void Function(ChatSession) onSelect;
  final VoidCallback onCreate;
  final void Function(LlmModel) onModelSelected;

  const _SessionTitle({
    required this.session,
    required this.sessions,
    required this.models,
    required this.onSelect,
    required this.onCreate,
    required this.onModelSelected,
  });

  @override
  Widget build(BuildContext context) {
    if (session == null) return const Text('助手');
    LlmModel? currentModel;
    for (final model in models) {
      if (model.id == session!.modelId) currentModel = model;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Flexible(
              child: PopupMenuButton<String>(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(session!.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                    const Icon(Icons.expand_more, size: 18),
                  ],
                ),
                itemBuilder: (_) => [
                  for (final item in sessions)
                    PopupMenuItem(
                      value: 'select:${item.id}',
                      child: Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                  const PopupMenuItem(value: 'new', child: Text('＋ 新建对话')),
                ],
                onSelected: (value) {
                  if (value == 'new') {
                    onCreate();
                  } else if (value.startsWith('select:')) {
                    final id = value.substring('select:'.length);
                    for (final item in sessions) {
                      if (item.id == id) onSelect(item);
                    }
                  }
                },
              ),
            ),
          ],
        ),
        PopupMenuButton<String>(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.memory, size: 12, color: Theme.of(context).colorScheme.outline),
              const SizedBox(width: 4),
              Text(
                currentModel?.name ?? '默认模型',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
          itemBuilder: (_) => [
            for (final model in models)
              PopupMenuItem(value: model.id, child: Text('${model.name}（${model.modelId}）')),
          ],
          onSelected: (id) {
            for (final model in models) {
              if (model.id == id) onModelSelected(model);
            }
          },
        ),
      ],
    );
  }
}

class _MessageBubble extends StatelessWidget {
  final ChatMessage message;
  final VoidCallback onCopy;
  final VoidCallback? onRetry;
  final VoidCallback? onEdit;

  const _MessageBubble({
    required this.message,
    required this.onCopy,
    this.onRetry,
    this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isUser = message.role == 'user';
    final failed = message.metadata?.taskStatus == 'failed';
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.86),
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isUser
              ? theme.colorScheme.primaryContainer
              : failed
                  ? theme.colorScheme.errorContainer
                  : theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (message.metadata?.agentTrace != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: AgentRunView(trace: message.metadata!.agentTrace!),
              ),
            SelectableText(message.content, style: const TextStyle(height: 1.5)),
            if (message.metadata?.errorDetail != null && message.metadata!.errorDetail!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: EdgeInsets.zero,
                  title: Text('原始错误详情', style: theme.textTheme.bodySmall),
                  children: [
                    SelectableText(message.metadata!.errorDetail!,
                        style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace')),
                  ],
                ),
              ),
            const SizedBox(height: 6),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  formatTimestamp(message.createdAt),
                  style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.outline),
                ),
                if (!isUser) ...[
                  const Spacer(),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    iconSize: 16,
                    onPressed: onCopy,
                    icon: const Icon(Icons.copy_outlined),
                    tooltip: '复制',
                  ),
                  if (onRetry != null)
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      iconSize: 16,
                      onPressed: onRetry,
                      icon: const Icon(Icons.refresh),
                      tooltip: '重试',
                    ),
                ],
                if (isUser && onEdit != null)
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    iconSize: 16,
                    onPressed: onEdit,
                    icon: const Icon(Icons.edit_outlined),
                    tooltip: '编辑并重新运行',
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

