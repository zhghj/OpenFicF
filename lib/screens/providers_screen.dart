import 'package:flutter/material.dart';

import '../data/repositories.dart';
import '../llm/limits.dart';
import '../models.dart';
import '../services/model_catalog.dart';
import '../widgets/common.dart';

class ProvidersScreen extends StatefulWidget {
  const ProvidersScreen({super.key});

  @override
  State<ProvidersScreen> createState() => _ProvidersScreenState();
}

class _ProvidersScreenState extends State<ProvidersScreen> {
  List<Provider> _providers = [];
  List<LlmModel> _models = [];
  String? _activeModelId;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final providers = await listProviders();
      final models = await listModels();
      final activeId = await getSetting('activeModelId');
      if (!mounted) return;
      setState(() {
        _providers = providers;
        _models = models;
        _activeModelId = activeId;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _loading = false);
      showErrorSnack(context, error);
    }
  }

  Future<void> _editProvider([Provider? provider]) async {
    final nameController = TextEditingController(text: provider?.name ?? '');
    final urlController = TextEditingController(text: provider?.baseUrl ?? '');
    final keyController = TextEditingController();
    var type = provider?.type ?? ProviderType.openaiCompatible;
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(provider == null ? '新建供应商' : '编辑供应商'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(controller: nameController, decoration: const InputDecoration(labelText: '名称')),
                const SizedBox(height: 12),
                DropdownButtonFormField<ProviderType>(
                  isExpanded: true,
                  initialValue: type,
                  decoration: const InputDecoration(labelText: '协议类型'),
                  items: const [
                    DropdownMenuItem(
                        value: ProviderType.openaiCompatible, child: Text('OpenAI-compatible')),
                    DropdownMenuItem(value: ProviderType.googleGenai, child: Text('Google Gemini')),
                    DropdownMenuItem(value: ProviderType.anthropic, child: Text('Anthropic')),
                  ],
                  onChanged: (value) => setDialogState(() => type = value!),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: urlController,
                  decoration: const InputDecoration(
                    labelText: 'Base URL',
                    hintText: 'https://api.example.com/v1',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: keyController,
                  obscureText: true,
                  decoration: InputDecoration(
                    labelText: 'API Key',
                    hintText: provider == null ? 'sk-…' : '留空则保持原 Key 不变',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('保存')),
          ],
        ),
      ),
    );
    if (saved != true) return;
    try {
      var apiKey = keyController.text.trim();
      if (apiKey.isEmpty && provider != null) {
        apiKey = await getProviderApiKey(provider);
      }
      await saveProvider(
        id: provider?.id,
        name: nameController.text,
        type: type,
        baseUrl: urlController.text,
        apiKey: apiKey,
      );
      await _load();
    } catch (error) {
      if (mounted) showErrorSnack(context, error);
    }
  }

  Future<void> _deleteProvider(Provider provider) async {
    final confirmed = await confirmDialog(
      context,
      title: '删除供应商',
      message: '确定删除《${provider.name}》及其全部模型配置吗？API Key 也会一并删除。',
      confirmLabel: '删除',
      destructive: true,
    );
    if (!confirmed) return;
    try {
      await deleteProvider(provider);
      await _load();
    } catch (error) {
      if (mounted) showErrorSnack(context, error);
    }
  }

  Future<void> _fetchModels(Provider provider) async {
    showMessageSnack(context, '正在获取模型列表…');
    try {
      final apiKey = await getProviderApiKey(provider);
      final models = await fetchProviderModels(provider, apiKey);
      if (!mounted) return;
      if (models.isEmpty) {
        showMessageSnack(context, '供应商没有返回可用模型');
        return;
      }
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (context) => _RemoteModelSheet(
          provider: provider,
          models: models,
          existing: _models.where((model) => model.providerId == provider.id).map((m) => m.modelId).toSet(),
          onAdd: (model) => _addModel(provider, model),
        ),
      );
    } catch (error) {
      if (mounted) showErrorSnack(context, error);
    }
  }

  Future<void> _addModel(Provider provider, RemoteModel remote) async {
    final nameController = TextEditingController(text: remote.name);
    final idController = TextEditingController(text: remote.id);
    final tempController = TextEditingController(text: '0.8');
    final tokensController = TextEditingController(text: '$defaultMaxOutputTokens');
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('添加模型'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: nameController, decoration: const InputDecoration(labelText: '显示名称')),
              const SizedBox(height: 12),
              TextField(controller: idController, decoration: const InputDecoration(labelText: '模型 ID')),
              const SizedBox(height: 12),
              TextField(
                controller: tempController,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: '温度（0-2）'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: tokensController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: '最大输出 Token'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('添加')),
        ],
      ),
    );
    if (saved != true) return;
    try {
      await saveModel(
        providerId: provider.id,
        name: nameController.text,
        modelId: idController.text,
        temperature: double.tryParse(tempController.text.trim()) ?? 0.8,
        maxTokens: int.tryParse(tokensController.text.trim()) ?? defaultMaxOutputTokens,
      );
      await _load();
    } catch (error) {
      if (mounted) showErrorSnack(context, error);
    }
  }

  Future<void> _editModel(LlmModel model) async {
    final nameController = TextEditingController(text: model.name);
    final tempController = TextEditingController(text: model.temperature.toString());
    final tokensController = TextEditingController(text: '${model.maxTokens}');
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('编辑模型'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: nameController, decoration: const InputDecoration(labelText: '显示名称')),
            const SizedBox(height: 12),
            TextField(
              controller: tempController,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: '温度（0-2）'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: tokensController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: '最大输出 Token'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('保存')),
        ],
      ),
    );
    if (saved != true) return;
    try {
      await saveModel(
        id: model.id,
        providerId: model.providerId,
        name: nameController.text,
        modelId: model.modelId,
        temperature: double.tryParse(tempController.text.trim()) ?? model.temperature,
        maxTokens: int.tryParse(tokensController.text.trim()) ?? model.maxTokens,
      );
      await _load();
    } catch (error) {
      if (mounted) showErrorSnack(context, error);
    }
  }

  Future<void> _setActive(LlmModel model) async {
    await setSetting('activeModelId', model.id);
    await _load();
    if (mounted) showMessageSnack(context, '已设为默认模型：${model.name}');
  }

  Future<void> _deleteModel(LlmModel model) async {
    final confirmed = await confirmDialog(
      context,
      title: '删除模型',
      message: '确定删除《${model.name}》吗？',
      confirmLabel: '删除',
      destructive: true,
    );
    if (!confirmed) return;
    try {
      await deleteModel(model.id);
      await _load();
    } catch (error) {
      if (mounted) showErrorSnack(context, error);
    }
  }

  String _providerName(String id) {
    for (final provider in _providers) {
      if (provider.id == id) return provider.name;
    }
    return '未知供应商';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('模型与供应商'),
        actions: [
          IconButton(onPressed: () => _editProvider(), icon: const Icon(Icons.add)),
        ],
      ),
      body: _loading
          ? const LoadingView()
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [
                Text('供应商', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                if (_providers.isEmpty)
                  const Card(
                    child: ListTile(
                      title: Text('还没有供应商'),
                      subtitle: Text('添加一个供应商，填入 Base URL 和 API Key。'),
                    ),
                  ),
                for (final provider in _providers)
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.dns_outlined),
                      title: Text(provider.name),
                      subtitle: Text('${provider.type.wire}\n${provider.baseUrl}'),
                      isThreeLine: true,
                      trailing: PopupMenuButton<String>(
                        onSelected: (value) {
                          if (value == 'fetch') _fetchModels(provider);
                          if (value == 'edit') _editProvider(provider);
                          if (value == 'delete') _deleteProvider(provider);
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(value: 'fetch', child: Text('获取模型列表')),
                          PopupMenuItem(value: 'edit', child: Text('编辑')),
                          PopupMenuItem(value: 'delete', child: Text('删除')),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: 20),
                Text('模型', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                if (_models.isEmpty)
                  const Card(
                    child: ListTile(
                      title: Text('还没有模型'),
                      subtitle: Text('在供应商菜单里“获取模型列表”并添加，或手动配置。'),
                    ),
                  ),
                for (final model in _models)
                  Card(
                    child: ListTile(
                      leading: Icon(
                        model.id == _activeModelId ? Icons.check_circle : Icons.memory,
                        color: model.id == _activeModelId
                            ? Theme.of(context).colorScheme.primary
                            : null,
                      ),
                      title: Text(model.name),
                      subtitle: Text(
                        '${model.modelId} · ${_providerName(model.providerId)}\n'
                        '温度 ${model.temperature} · 最大输出 ${model.maxTokens}',
                      ),
                      isThreeLine: true,
                      onTap: () => _setActive(model),
                      trailing: PopupMenuButton<String>(
                        onSelected: (value) {
                          if (value == 'active') _setActive(model);
                          if (value == 'edit') _editModel(model);
                          if (value == 'delete') _deleteModel(model);
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(value: 'active', child: Text('设为默认模型')),
                          PopupMenuItem(value: 'edit', child: Text('编辑')),
                          PopupMenuItem(value: 'delete', child: Text('删除')),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}

class _RemoteModelSheet extends StatelessWidget {
  final Provider provider;
  final List<RemoteModel> models;
  final Set<String> existing;
  final void Function(RemoteModel) onAdd;

  const _RemoteModelSheet({
    required this.provider,
    required this.models,
    required this.existing,
    required this.onAdd,
  });

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      builder: (context, controller) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text('${provider.name} · ${models.length} 个模型',
                style: Theme.of(context).textTheme.titleMedium),
          ),
          Expanded(
            child: ListView.builder(
              controller: controller,
              itemCount: models.length,
              itemBuilder: (context, index) {
                final model = models[index];
                final added = existing.contains(model.id);
                return ListTile(
                  title: Text(model.name),
                  subtitle: Text(model.id),
                  trailing: added
                      ? const Icon(Icons.check)
                      : IconButton(
                          icon: const Icon(Icons.add),
                          onPressed: () => onAdd(model),
                        ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}