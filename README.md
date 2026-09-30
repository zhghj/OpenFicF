# OpenFicF

基于 [OpenFic](https://github.com/syrizelink/OpenFic) 与 [OpenFicM](https://github.com/tioners/OpenFicM) 重构的 Flutter 版**本地优先小说创作应用**，优先 Android 端。

作品、章节、角色、世界书、笔记、对话和文风都保存在本机 SQLite，API Key 存在系统安全存储；只有调用你配置的模型 API 时联网。

## 功能

- **书架与写作**：卷/章目录，预览优先编辑器，自动保存，导出章节 / 卷 / 全书为 Markdown。
- **助手与 Agent**：作品级会话，工具权限（允许/询问/禁止），结构化提问，实时 trace，失败重试，历史消息编辑重跑。消息**分页加载**（默认最新 30 条，向上滚动自动加载更早），保证最新请求可见并降低长会话加载压力。
- **本地工具**：读取/搜索章节、角色、世界书与笔记；对话即可维护**角色库、世界书（含说明）、三级笔记、章节、卷、伏笔池、当前世界状态、章节摘要、创作控制与同人正典（新建/编辑/合并/应用/联网消歧）**；支持技能激活与子智能体委派。用户用大段描述交代设定时，Agent 会先读现有资料再逐条落库。
  - **资料整理与关联**：`merge_characters` 合并重复角色卡（可 AI 归并）；`link_characters` 建立人物关系；`link_character_world` 关联角色与世界书；`record_event` 记录事件并关联参与角色。关系/关联写入当前世界状态，供后续创作保持一致。
- **资料**：角色库、世界书、三级笔记（整书/卷/章，可跨级移动）。
- **同人正典**：导入原作（TXT / Markdown / EPUB），**分片蒸馏**出时间线、角色卡、世界观、人物关系等信息；条目可选取（启用）、编辑、删除，并一键应用到角色库 / 世界书 / 笔记，作为参考资料持续维护。Agent 会读取启用条目作为原作权威依据。
  - **实体消歧（别名归并）**：蒸馏时把同一人物的本名、别称、绰号、亲属代称合并到同一张卡；已出现的规范名称会回灌给后续片段复用，减少重复卡。条目支持手动「合并到…」以及「AI 归并」重新生成无重复、无矛盾的复合条目。
  - **联网消歧工具**：可配置多种检索服务，在条目上「联网消歧」把别称解析为规范实体并登记别名；Agent 也可调用 `web_disambiguate` 与 `merge_canon_entries`。**中国大陆可用**：百度百科（免费免 Key）、Bing Web Search、博查 Bocha；Wikidata / Wikipedia / Serper(Google) / Brave 通常需科学上网；另有自定义 JSON 搜索。
  - **创作中按需取用**：Agent 会读取正典条目；需要细节时用 `read_canon_entries` / `search_canon_entries` 检索。`distill_canon` 有约束：正典已完成则跳过、已在任务池蒸馏则跳过、单次对话最多主动蒸馏 1 次，避免反复请求卡住；确需外部事实时用 `web_search`（受联网服务配置）。
- **全局任务池**：整部正典蒸馏可**一键加入任务池**后台执行，支持多任务并发、排队、**暂停 / 继续 / 取消**与实时进度；任务卡显示**预估剩余时间**（按进度外推，非每秒刷新）与可展开的**任务 / 工具输出日志**（固定高度区域）。失败/取消的任务可**重试并从断点继续**（已完成的片段/进度不会被丢弃）。任务不阻塞界面，书架 / 设置 / 正典页均有任务池入口与实时角标。模型调用遇到速率限制（HTTP 429）会按 Retry-After 与指数退避自动重试。
- **文风系统**：导入 TXT / Markdown / EPUB 参考书，多轮参考文风蒸馏，作者文风进化。**可同时启用多份文风**（多本参考文风 + 作者文风一起注入写作提示），支持查看指南、启用/停用、删除。
- **模型与设置**：OpenAI-compatible / Google Gemini / Anthropic 三种协议，获取供应商模型列表，工具权限、上下文、索引、规则、技能、智能体配置。输出 Token 用尽且未产出正文时会**自动放宽上限重试**；上下文设置支持**历史对话压缩**（把超出条数的更早对话摘要保留）。
- **长篇故事状态（参考 InkOS）**：
  - **写下一章**：一键执行「规划 → 写作 → 审稿 → 状态结算 → 保存」的完整章节生产管线。
  - **故事状态**：权威结构化状态——伏笔池（open/progressing/deferred/resolved/superseded）、章节摘要、当前世界状态事实。
  - **审稿意见**：连续性审稿产生有证据的 observation，可在写作页与故事状态页查看。
  - **创作控制**：作者长期意图、当前关注点、每章目标字数、叙事人称与本书禁忌。
  - Agent 会读取伏笔/摘要/当前状态，并可用工具维护作者意图与当前关注点。

## 架构

| 路径 | 说明 |
| --- | --- |
| `lib/models.dart` | 领域模型 |
| `lib/data` | SQLite 初始化与仓储 |
| `lib/llm` | 三种供应商协议与输出截断检测 |
| `lib/agent` | Agent 主循环与本地工具 |
| `lib/settings` | 目录、配置与 Lorn 文风插件 |
| `lib/search` | 本地检索索引 |
| `lib/style` | 参考书导入、解析与抽样 |
| `lib/story_models.dart` | 长篇故事状态模型（伏笔/摘要/事实/观察/控制） |
| `lib/canon_models.dart` | 同人正典模型（原作素材与蒸馏条目） |
| `lib/canon` | 正典导入、解析与文件存储 |
| `lib/pipeline` | 章节生产管线与正典分片蒸馏 |
| `lib/screens` | 书架、写作、助手、资料、设置、文风书库 |
| `assets` | 内置 Agent/Skill 目录（OpenFicM 同源） |

内置 Agent/Skill 随 APK 打包，离线可用。本地语义检索以词频加权方式实现，后续可平滑替换为设备端嵌入模型。

## 开发

需要 Flutter 3.44+ 与 Android SDK。

```bash
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
```

正式包请在 `android/app/build.gradle.kts` 配置签名后再执行 `flutter build apk --release`。

## 许可

Apache License 2.0，参考 OpenFic 与 OpenFicM。