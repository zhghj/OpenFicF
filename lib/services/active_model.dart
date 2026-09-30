import '../data/repositories.dart';
import '../models.dart';

/// 读取当前设置的默认模型及其供应商 Key。
Future<ModelSelection?> getActiveModelSelection() async {
  final activeId = await getSetting('activeModelId');
  if (activeId == null || activeId.isEmpty) return null;
  final models = await listModels();
  LlmModel? model;
  for (final item in models) {
    if (item.id == activeId) {
      model = item;
      break;
    }
  }
  if (model == null) return null;
  final providers = await listProviders();
  Provider? provider;
  for (final item in providers) {
    if (item.id == model.providerId) {
      provider = item;
      break;
    }
  }
  if (provider == null) return null;
  final apiKey = await getProviderApiKey(provider);
  if (apiKey.isEmpty) return null;
  return ModelSelection(provider: provider, model: model, apiKey: apiKey);
}

Future<String> getActiveModelLabel() async {
  final activeId = await getSetting('activeModelId');
  if (activeId == null || activeId.isEmpty) return '未选择模型';
  final models = await listModels();
  for (final item in models) {
    if (item.id == activeId) return '${item.name}（${item.modelId}）';
  }
  return '未选择模型';
}