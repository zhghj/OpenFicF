import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// API Key 统一写入系统安全存储，SQLite 只保存引用键。
class SecureStore {
  static const _storage = FlutterSecureStorage();

  static Future<String?> read(String key) => _storage.read(key: key);

  static Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  static Future<void> delete(String key) => _storage.delete(key: key);
}