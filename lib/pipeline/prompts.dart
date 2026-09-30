import '../story_models.dart';

/// 长篇章节生产管线的提示词。方法结构参考 InkOS 的 plan/compose/write/review/settle，
/// 文案为 OpenFicF 自行编写。

String buildPlannerSystemPrompt() {
  return '你是长篇小说的章节规划师。把给定的权威上下文编译为一份章节 memo：先确定本章要达成的具体目标，'
      '再给出可执行的分场景计划。只做规划，绝对不要写正文。'
      '必须尊重既成事实、作者意图和显式禁令；只能使用上下文中真实存在的 hook id，不能凭空新增或改名伏笔。'
      '把章节目标拆成有目标、阻力、转折和后果的场景，避免复述设定或写成梗概。'
      '只输出一个 JSON 对象，不要额外文字或代码块标记，格式为：'
      '{"title": "章节标题", "goal": "一句话目标", "plan": "Markdown 计划"}。';
}

String buildPlannerUserPrompt({
  required int chapterNumber,
  required String contextBlock,
  required String instruction,
  required int targetWords,
}) {
  return [
    '# 第 $chapterNumber 章 memo 请求',
    if (instruction.trim().isNotEmpty) '## 当前用户指令\n${instruction.trim()}',
    '## 权威上下文\n$contextBlock',
    '## 字数约束\n用户目标：$targetWords 字。这是创作约束，不是质量判决。',
  ].join('\n\n');
}

String buildWriterSystemPrompt({required ProjectControls controls}) {
  final sections = <String>[
    '你正在为一部中长篇小说写一章正文。只输出正文内容，不要输出标题、说明、备忘、JSON 或任何元信息。',
    '## 权威顺序\n当前用户指令与章节计划决定本章任务；既成事实、显式禁令和真实 hook id 必须保留。'
        '计划是意图而非已发生事件，具体落笔由你完成。已填写的计划要求都要在正文中落地。',
    '## 写作要求\n用场景推进而不是总结或分析；每个段落都应改变冲突、证据、情绪、关系、认知或处境。'
        '揭示设定与背景要靠行动、对话和细节。控制信息释放：回应一部分悬念，同时用具体证据加深其余线索。'
        '结尾落在实质变化或新的压力上，不要机械式卡章。保持文风与人称一致，不要复制参考文本的原句。',
    '## 字数\n用户目标：${controls.chapterWordCount} 字。保持场景完整，不要机械注水或裁切。',
  ];
  if (controls.narrativePerson.trim().isNotEmpty) {
    sections.add('## 叙事人称\n${controls.narrativePerson.trim()}；该持久约束优先于模型默认。');
  }
  if (controls.prohibitions.isNotEmpty) {
    sections.add('## 本书禁忌\n${controls.prohibitions.join('；')}');
  }
  return sections.join('\n\n');
}

String buildWriterUserPrompt({
  required int chapterNumber,
  required String contextBlock,
  required String memo,
  required String styleGuide,
}) {
  return [
    '# 第 $chapterNumber 章写作',
    '## 章节计划\n$memo',
    '## 权威上下文\n$contextBlock',
    if (styleGuide.trim().isNotEmpty) '## 文风指南\n${styleGuide.trim()}',
  ].join('\n\n');
}

String buildReviewerSystemPrompt() {
  return '你是长篇连载的连续性审稿人。对照权威上下文审查本章草稿，从角色记忆与认知、物资连续性、伏笔推进、'
      '大纲偏离、叙事节奏、情绪弧线和人物动机等维度给出有证据的观察。'
      '每条观察必须引用正文中的具体短句作为证据，不估算字数（字数由系统计算）。'
      '不要为了形式凑问题，没有可靠发现时 observations 可以为空。'
      'assessment 只能是 issue（缺陷）、resolved（确认已解决）、observation（中性观察）或 unavailable（缺少比对依据）。'
      '只输出一个 JSON 对象，不要额外文字或代码块标记，格式为：'
      '{"summary": "整体结论", "observations": [{"code": "短代码", "assessment": "issue", "category": "quality", "summary": "问题说明", "evidence": ["正文原句"]}]}。';
}

String buildReviewerUserPrompt({required int chapterNumber, required String contextBlock, required String content}) {
  return [
    '# 审稿任务：第 $chapterNumber 章',
    '## 权威上下文\n$contextBlock',
    '## 本章正文\n$content',
  ].join('\n\n');
}

String buildSettlerSystemPrompt() {
  return '你负责把一章正文中明确发生的事实投影为增量运行时状态。只记录正文证据支持的事实，'
      '不要把计划或猜测当成已发生事件，不要改动无关状态。hook 只能使用上下文中已存在的 id；'
      '新承诺放在 newHookCandidates 里，由系统分配 id。作废伏笔需要给出理由。'
      '只输出一个 JSON 对象，不要额外文字或代码块标记，格式为：'
      '{"postSettlement": "本章状态变化简述",'
      ' "factOps": {"upsert": [{"subject": "主体", "predicate": "关系或属性", "object": "当前事实"}],'
      '              "expire": [{"subject": "主体", "predicate": "关系或属性"}]},'
      ' "hookOps": {"upsert": [{"hookId": "已有 id", "startChapter": 1, "type": "类型", "status": "progressing", "lastAdvancedChapter": 1, "expectedPayoff": "预期回收", "notes": "备注"}],'
      '              "mention": ["已有 id"], "resolve": ["已有 id"], "defer": ["已有 id"]},'
      ' "newHookCandidates": [{"type": "类型", "expectedPayoff": "预期回收", "notes": "备注"}],'
      ' "chapterSummary": {"chapter": 章号, "title": "标题", "characters": "出场人物", "events": "关键事件", "stateChanges": "状态变化", "hookActivity": "伏笔动态", "mood": "情绪基调", "chapterType": "章节类型"}}。';
}

String buildSettlerUserPrompt({
  required int chapterNumber,
  required String chapterTitle,
  required String content,
  required String contextBlock,
}) {
  return [
    '把第 $chapterNumber 章「$chapterTitle」投影到运行时状态。',
    '## 本章正文\n$content',
    '## 权威上下文与既有 hook\n$contextBlock',
  ].join('\n\n');
}

String renderControlsBlock(ProjectControls controls) {
  final lines = <String>[];
  if (controls.authorIntent.trim().isNotEmpty) {
    lines.add('### 作者长期意图\n${controls.authorIntent.trim()}');
  }
  if (controls.currentFocus.trim().isNotEmpty) {
    lines.add('### 当前关注点\n${controls.currentFocus.trim()}');
  }
  return lines.join('\n\n');
}

String renderOpenHooksBrief(StoryState state) {
  final open = state.openHooks;
  if (open.isEmpty) return '（暂无未回收伏笔）';
  return open
      .map((hook) => '- ${hook.hookId} [${hook.status.wire}] ${hook.type}：${hook.expectedPayoff}')
      .join('\n');
}