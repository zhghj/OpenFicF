import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

Database? _database;

const _databaseName = 'openfic.db';
const _databaseVersion = 4;

Future<Database> getDatabase() async {
  if (_database != null) return _database!;
  final directory = await getDatabasesPath();
  final path = p.join(directory, _databaseName);
  _database = await openDatabase(
    path,
    version: _databaseVersion,
    onConfigure: (db) async {
      await db.execute('PRAGMA foreign_keys = ON');
    },
    onCreate: (db, version) async {
      await _createSchema(db);
      await _createStoryTables(db);
      await _createCanonTables(db);
      await _runLegacyMigrations(db);
    },
    onUpgrade: (db, oldVersion, newVersion) async {
      if (oldVersion < 2) {
        await _createStoryTables(db);
      }
      if (oldVersion < 3) {
        await _createCanonTables(db);
      }
      if (oldVersion < 4) {
        await _addCanonAliasesColumn(db);
      }
    },
  );
  return _database!;
}

Future<void> _createSchema(Database db) async {
  await db.execute('''
    CREATE TABLE IF NOT EXISTS projects (
      id TEXT PRIMARY KEY NOT NULL,
      title TEXT NOT NULL,
      description TEXT NOT NULL DEFAULT '',
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );
  ''');
  await db.execute('''
    CREATE TABLE IF NOT EXISTS volumes (
      id TEXT PRIMARY KEY NOT NULL,
      project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
      title TEXT NOT NULL,
      order_index INTEGER NOT NULL
    );
  ''');
  await db.execute('''
    CREATE TABLE IF NOT EXISTS chapters (
      id TEXT PRIMARY KEY NOT NULL,
      project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
      volume_id TEXT NOT NULL REFERENCES volumes(id) ON DELETE CASCADE,
      title TEXT NOT NULL,
      content TEXT NOT NULL DEFAULT '',
      order_index INTEGER NOT NULL,
      updated_at TEXT NOT NULL
    );
  ''');
  await db.execute('''
    CREATE TABLE IF NOT EXISTS style_sources (
      id TEXT PRIMARY KEY NOT NULL,
      title TEXT NOT NULL,
      file_name TEXT NOT NULL,
      format TEXT NOT NULL,
      file_uri TEXT NOT NULL,
      size_bytes INTEGER NOT NULL,
      content_hash TEXT NOT NULL UNIQUE,
      character_count INTEGER NOT NULL,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );
  ''');
  await db.execute('''
    CREATE TABLE IF NOT EXISTS style_profiles (
      id TEXT PRIMARY KEY NOT NULL,
      series_id TEXT NOT NULL,
      project_id TEXT REFERENCES projects(id) ON DELETE CASCADE,
      source_id TEXT REFERENCES style_sources(id) ON DELETE CASCADE,
      kind TEXT NOT NULL,
      name TEXT NOT NULL,
      version INTEGER NOT NULL,
      guide TEXT NOT NULL,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      UNIQUE(series_id, version)
    );
  ''');
  await db.execute('''
    CREATE TABLE IF NOT EXISTS chapter_drafts (
      id TEXT PRIMARY KEY NOT NULL,
      project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
      chapter_id TEXT NOT NULL REFERENCES chapters(id) ON DELETE CASCADE,
      style_profile_id TEXT REFERENCES style_profiles(id) ON DELETE SET NULL,
      ai_draft TEXT NOT NULL,
      author_revision TEXT,
      status TEXT NOT NULL,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );
  ''');
  // FTS5 在部分 Android 系统 SQLite 上不可用，失败时由仓储降级为 LIKE 查询。
  try {
    await db.execute('''
      CREATE VIRTUAL TABLE IF NOT EXISTS chapter_fts USING fts5(
        chapter_id UNINDEXED,
        project_id UNINDEXED,
        title,
        content,
        tokenize='unicode61'
      );
    ''');
  } catch (_) {
    // 忽略：搜索会退回到 LIKE。
  }
  await db.execute('''
    CREATE TABLE IF NOT EXISTS providers (
      id TEXT PRIMARY KEY NOT NULL,
      name TEXT NOT NULL,
      type TEXT NOT NULL,
      base_url TEXT NOT NULL,
      api_key_ref TEXT NOT NULL,
      created_at TEXT NOT NULL
    );
  ''');
  await db.execute('''
    CREATE TABLE IF NOT EXISTS models (
      id TEXT PRIMARY KEY NOT NULL,
      provider_id TEXT NOT NULL REFERENCES providers(id) ON DELETE CASCADE,
      name TEXT NOT NULL,
      model_id TEXT NOT NULL,
      temperature REAL NOT NULL DEFAULT 0.8,
      max_tokens INTEGER NOT NULL DEFAULT 4096
    );
  ''');
  await db.execute('''
    CREATE TABLE IF NOT EXISTS chat_sessions (
      id TEXT PRIMARY KEY NOT NULL,
      project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
      title TEXT NOT NULL,
      model_id TEXT REFERENCES models(id) ON DELETE SET NULL,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );
  ''');
  await db.execute('''
    CREATE TABLE IF NOT EXISTS chat_messages (
      id TEXT PRIMARY KEY NOT NULL,
      project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
      session_id TEXT NOT NULL REFERENCES chat_sessions(id) ON DELETE CASCADE,
      role TEXT NOT NULL,
      content TEXT NOT NULL,
      metadata_json TEXT,
      created_at TEXT NOT NULL
    );
  ''');
  await db.execute('''
    CREATE TABLE IF NOT EXISTS app_settings (
      key TEXT PRIMARY KEY NOT NULL,
      value TEXT NOT NULL
    );
  ''');
  await db.execute('''
    CREATE TABLE IF NOT EXISTS characters (
      id TEXT PRIMARY KEY NOT NULL,
      project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
      name TEXT NOT NULL,
      description TEXT NOT NULL DEFAULT '',
      image_path TEXT,
      is_favorited INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );
  ''');
  await db.execute('''
    CREATE TABLE IF NOT EXISTS world_info (
      id TEXT PRIMARY KEY NOT NULL,
      project_id TEXT NOT NULL UNIQUE REFERENCES projects(id) ON DELETE CASCADE,
      name TEXT NOT NULL,
      description TEXT NOT NULL DEFAULT '',
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );
  ''');
  await db.execute('''
    CREATE TABLE IF NOT EXISTS world_info_entries (
      id TEXT PRIMARY KEY NOT NULL,
      world_info_id TEXT NOT NULL REFERENCES world_info(id) ON DELETE CASCADE,
      uid INTEGER NOT NULL,
      name TEXT NOT NULL,
      entry_order INTEGER NOT NULL,
      content TEXT NOT NULL DEFAULT '',
      token_count INTEGER NOT NULL DEFAULT 0,
      is_enabled INTEGER NOT NULL DEFAULT 1,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );
  ''');
  await db.execute('''
    CREATE TABLE IF NOT EXISTS vector_chunks (
      id TEXT PRIMARY KEY NOT NULL,
      project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
      source_type TEXT NOT NULL,
      source_id TEXT NOT NULL,
      chunk_index INTEGER NOT NULL,
      title TEXT NOT NULL,
      content TEXT NOT NULL,
      embedding BLOB,
      source_updated_at TEXT NOT NULL,
      UNIQUE(source_id, chunk_index)
    );
  ''');
  await db.execute('''
    CREATE TABLE IF NOT EXISTS notes (
      id TEXT PRIMARY KEY NOT NULL,
      project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
      volume_id TEXT REFERENCES volumes(id) ON DELETE SET NULL,
      chapter_id TEXT REFERENCES chapters(id) ON DELETE SET NULL,
      title TEXT NOT NULL,
      content TEXT NOT NULL DEFAULT '',
      order_index INTEGER NOT NULL,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );
  ''');
  await db.execute('CREATE INDEX IF NOT EXISTS idx_volumes_project_order ON volumes(project_id, order_index)');
  await db.execute('CREATE INDEX IF NOT EXISTS idx_chapters_volume_order ON chapters(volume_id, order_index)');
  await db.execute('CREATE INDEX IF NOT EXISTS idx_notes_project_scope ON notes(project_id, volume_id, chapter_id, order_index)');
  await db.execute('CREATE INDEX IF NOT EXISTS idx_style_sources_updated ON style_sources(updated_at DESC)');
  await db.execute('CREATE INDEX IF NOT EXISTS idx_style_profiles_scope_updated ON style_profiles(kind, project_id, updated_at DESC)');
  await db.execute('CREATE INDEX IF NOT EXISTS idx_style_profiles_source_version ON style_profiles(source_id, version DESC)');
  await db.execute('CREATE INDEX IF NOT EXISTS idx_chapter_drafts_chapter_updated ON chapter_drafts(chapter_id, updated_at DESC)');
  await db.execute('CREATE INDEX IF NOT EXISTS idx_messages_project_created ON chat_messages(project_id, created_at)');
  await db.execute('CREATE INDEX IF NOT EXISTS idx_messages_session_created ON chat_messages(session_id, created_at)');
  await db.execute('CREATE INDEX IF NOT EXISTS idx_characters_project_updated ON characters(project_id, updated_at)');
  await db.execute('CREATE INDEX IF NOT EXISTS idx_world_entries_book_order ON world_info_entries(world_info_id, entry_order)');
  await db.execute('CREATE INDEX IF NOT EXISTS idx_vector_chunks_project_source ON vector_chunks(project_id, source_type, source_id)');
}

/// 长篇故事状态相关表（v2）。镜像 InkOS 的 canonical state + observation + 控制文档。
Future<void> _createStoryTables(Database db) async {
  await db.execute('''
    CREATE TABLE IF NOT EXISTS story_state (
      project_id TEXT PRIMARY KEY NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
      state_json TEXT NOT NULL DEFAULT '{}',
      updated_at TEXT NOT NULL
    );
  ''');
  await db.execute('''
    CREATE TABLE IF NOT EXISTS chapter_observations (
      id TEXT PRIMARY KEY NOT NULL,
      project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
      chapter_id TEXT REFERENCES chapters(id) ON DELETE CASCADE,
      code TEXT NOT NULL,
      summary TEXT NOT NULL,
      evidence_json TEXT NOT NULL DEFAULT '[]',
      assessment TEXT NOT NULL,
      category TEXT,
      created_at TEXT NOT NULL
    );
  ''');
  await db.execute('''
    CREATE TABLE IF NOT EXISTS project_controls (
      project_id TEXT PRIMARY KEY NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
      controls_json TEXT NOT NULL DEFAULT '{}',
      updated_at TEXT NOT NULL
    );
  ''');
  await db.execute('''
    CREATE INDEX IF NOT EXISTS idx_observations_project_chapter
      ON chapter_observations(project_id, chapter_id, created_at);
  ''');
}

/// 同人正典相关表（v3）：导入的原作素材与分片蒸馏出的正典条目。
Future<void> _addCanonAliasesColumn(Database db) async {
  try {
    await db.execute("ALTER TABLE canon_entries ADD COLUMN aliases TEXT NOT NULL DEFAULT '[]'");
  } catch (_) {
    // 列已存在时忽略。
  }
}

Future<void> _createCanonTables(Database db) async {
  await db.execute('''
    CREATE TABLE IF NOT EXISTS canon_sources (
      id TEXT PRIMARY KEY NOT NULL,
      project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
      title TEXT NOT NULL,
      file_name TEXT NOT NULL,
      format TEXT NOT NULL,
      file_uri TEXT NOT NULL,
      size_bytes INTEGER NOT NULL,
      content_hash TEXT NOT NULL,
      character_count INTEGER NOT NULL,
      covered_until INTEGER NOT NULL DEFAULT 0,
      chunk_count INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      UNIQUE(project_id, content_hash)
    );
  ''');
  await db.execute('''
    CREATE TABLE IF NOT EXISTS canon_entries (
      id TEXT PRIMARY KEY NOT NULL,
      project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
      source_id TEXT NOT NULL REFERENCES canon_sources(id) ON DELETE CASCADE,
      category TEXT NOT NULL,
      title TEXT NOT NULL,
      summary TEXT NOT NULL DEFAULT '',
      detail TEXT NOT NULL DEFAULT '',
      evidence TEXT NOT NULL DEFAULT '',
      aliases TEXT NOT NULL DEFAULT '[]',
      order_index INTEGER NOT NULL DEFAULT 0,
      is_enabled INTEGER NOT NULL DEFAULT 1,
      applied_type TEXT,
      applied_id TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );
  ''');
  await db.execute('''
    CREATE INDEX IF NOT EXISTS idx_canon_sources_project
      ON canon_sources(project_id, updated_at DESC);
  ''');
  await db.execute('''
    CREATE INDEX IF NOT EXISTS idx_canon_entries_source_category
      ON canon_entries(source_id, category, order_index);
  ''');
  await db.execute('''
    CREATE INDEX IF NOT EXISTS idx_canon_entries_project
      ON canon_entries(project_id, is_enabled, category);
  ''');
}

Future<void> _runLegacyMigrations(Database db) async {
  // 迁移历史上的内联作者文风设置，保持与 OpenFicM 一致。
  await db.execute('''
    INSERT OR IGNORE INTO style_profiles(
      id, series_id, project_id, source_id, kind, name, version, guide, created_at, updated_at
    )
    SELECT
      'legacy-author-' || project.id,
      'author-' || project.id,
      project.id,
      NULL,
      'author',
      '我的作者文风',
      1,
      setting.value,
      project.updated_at,
      project.updated_at
    FROM projects project
    JOIN app_settings setting
      ON setting.key = 'plugin.lorn-style-evolution.guide.' || project.id
    WHERE TRIM(setting.value) <> '';
  ''');
  await db.execute('''
    INSERT OR IGNORE INTO app_settings(key, value)
    SELECT 'style.activeProfile.' || project.id, 'legacy-author-' || project.id
    FROM projects project
    JOIN style_profiles profile ON profile.id = 'legacy-author-' || project.id;
  ''');
  await db.delete('app_settings', where: "key LIKE 'plugin.lorn-style-evolution.guide.%'");
  await db.execute('''
    DELETE FROM chat_sessions
    WHERE model_id IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM models WHERE models.id = chat_sessions.model_id);
  ''');
  await db.execute('''
    DELETE FROM models
    WHERE NOT EXISTS (SELECT 1 FROM providers WHERE providers.id = models.provider_id);
  ''');
  await db.execute('''
    DELETE FROM app_settings
    WHERE key = 'activeModelId'
      AND NOT EXISTS (SELECT 1 FROM models WHERE models.id = app_settings.value);
  ''');
}