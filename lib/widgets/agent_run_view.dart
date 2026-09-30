import 'package:flutter/material.dart';

import '../models.dart';

/// 展示一次 Agent 运行的执行日志：调用的工具、参数、结果、技能、提问与子智能体协作。
class AgentRunView extends StatefulWidget {
  final AgentRunTrace trace;
  final bool initiallyExpanded;

  const AgentRunView({super.key, required this.trace, this.initiallyExpanded = true});

  @override
  State<AgentRunView> createState() => _AgentRunViewState();
}

class _AgentRunViewState extends State<AgentRunView> {
  late bool _expanded = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final running = widget.trace.status == 'running';
    final failed = widget.trace.status == 'error';
    final color = failed
        ? theme.colorScheme.error
        : running
            ? theme.colorScheme.primary
            : theme.colorScheme.outline;
    final agentEvents = widget.trace.events.where((event) => event.kind == 'agent').length;

    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  if (running)
                    const SizedBox(
                        width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                  else
                    Icon(failed ? Icons.error_outline : Icons.check_circle_outline, size: 16, color: color),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '执行日志 · ${widget.trace.primaryAgentName} · ${_statusLabel(widget.trace.status)} · '
                      '${widget.trace.events.length} 步'
                      '${agentEvents > 0 ? ' · $agentEvents 次子智能体协作' : ''}',
                      style: theme.textTheme.bodySmall?.copyWith(color: color),
                    ),
                  ),
                  Icon(_expanded ? Icons.expand_less : Icons.expand_more, size: 18),
                ],
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var index = 0; index < widget.trace.events.length; index += 1)
                    _TraceEventTile(event: widget.trace.events[index], step: index + 1),
                ],
              ),
            ),
        ],
      ),
    );
  }

  String _statusLabel(String status) {
    switch (status) {
      case 'running':
        return '进行中';
      case 'error':
        return '出错';
      case 'completed':
        return '完成';
      default:
        return status;
    }
  }
}

class _TraceEventTile extends StatelessWidget {
  final AgentTraceEvent event;
  final int step;

  const _TraceEventTile({required this.event, required this.step});

  IconData get _icon {
    switch (event.kind) {
      case 'agent':
        return Icons.groups_outlined;
      case 'skill':
        return Icons.auto_awesome_outlined;
      case 'question':
        return Icons.help_outline;
      case 'consistency':
        return Icons.fact_check_outlined;
      default:
        return Icons.build_outlined;
    }
  }

  String get _kindLabel {
    switch (event.kind) {
      case 'agent':
        return '子智能体';
      case 'skill':
        return '技能';
      case 'question':
        return '提问';
      case 'consistency':
        return '一致性';
      default:
        return '工具';
    }
  }

  String get _statusLabel {
    switch (event.status) {
      case 'running':
        return '进行中';
      case 'waiting':
        return '等待中';
      case 'completed':
        return '完成';
      case 'error':
        return '失败';
      default:
        return event.status;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = switch (event.status) {
      'error' => theme.colorScheme.error,
      'completed' => theme.colorScheme.primary,
      'waiting' => theme.colorScheme.tertiary,
      _ => theme.colorScheme.outline,
    };
    final mono = theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace', height: 1.35);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(_icon, size: 14, color: color),
              const SizedBox(width: 6),
              Expanded(
                child: Text('$step. ${event.title}',
                    style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600)),
              ),
              const SizedBox(width: 6),
              Text('$_kindLabel · $_statusLabel',
                  style: theme.textTheme.labelSmall?.copyWith(color: color)),
            ],
          ),
          if (event.toolName != null && event.toolName!.isNotEmpty && event.toolName != event.title)
            Padding(
              padding: const EdgeInsets.only(left: 20, top: 2),
              child: Text(event.toolName!,
                  style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.outline)),
            ),
          if (event.detail != null && event.detail!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 20, top: 2),
              child: Text(event.detail!,
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
            ),
          if (event.input != null && event.input!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 20, top: 4),
              child: _logBox(theme, '参数', event.input!, mono, theme.colorScheme.surfaceContainerHigh),
            ),
          if (event.output != null && event.output!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 20, top: 4),
              child: _logBox(theme, '结果', event.output!, mono, theme.colorScheme.surfaceContainerHighest),
            ),
        ],
      ),
    );
  }

  Widget _logBox(ThemeData theme, String label, String value, TextStyle? style, Color color) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(8)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.outline)),
          const SizedBox(height: 2),
          Text(value, style: style, maxLines: 16, overflow: TextOverflow.ellipsis),
        ],
      ),
    );
  }
}