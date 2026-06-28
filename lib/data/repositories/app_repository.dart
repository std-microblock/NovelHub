/// Persistence layer.
///
/// We keep a thin repository interface so the storage backend can be swapped
/// (JSON files today; Isar schemas later). The JSON-file implementation needs
/// no code generation and works on Android + Windows, which makes the app
/// runnable without build_runner — and the data is human-readable / portable.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../../domain/entities.dart';
import '../llm/llm_client.dart' show ProviderConfig, ProviderType;

/// All app storage (novels + provider configs) behind one interface.
abstract class AppRepository {
  Future<List<Novel>> loadNovels();
  Future<void> saveNovel(Novel novel);
  Future<void> deleteNovel(String novelId);

  Future<List<ProviderConfig>> loadProviders();
  Future<void> saveProviders(List<ProviderConfig> providers);

  /// Active (global default) provider id.
  Future<String?> getActiveProviderId();
  Future<void> setActiveProviderId(String? id);

  /// App preferences (free-form JSON map).
  Future<Map<String, dynamic>> loadPrefs();
  Future<void> savePrefs(Map<String, dynamic> prefs);
}

class JsonAppRepository implements AppRepository {
  final Directory root;

  JsonAppRepository(this.root);

  factory JsonAppRepository.defaultInstance() => JsonAppRepository(
        Directory('${_appDir.path}/novelhub'),
      );

  static late final Directory _appDir;

  static Future<void> init() async {
    final support = await getApplicationSupportDirectory();
    _appDir = support;
  }

  File get _novelsFile => File('${root.path}/novels.json');
  File get _providersFile => File('${root.path}/providers.json');
  File get _activeFile => File('${root.path}/active_provider.json');
  File get _prefsFile => File('${root.path}/prefs.json');

  @override
  Future<List<Novel>> loadNovels() async {
    if (!await _novelsFile.exists()) return [];
    final json = jsonDecode(await _novelsFile.readAsString());
    final list = (json as List).cast<Map<String, dynamic>>();
    return list.map(Novel.fromJson).toList();
  }

  @override
  Future<void> saveNovel(Novel novel) async {
    final novels = await loadNovels();
    final idx = novels.indexWhere((n) => n.id == novel.id);
    if (idx >= 0) {
      novels[idx] = novel;
    } else {
      novels.add(novel);
    }
    await _writeJson(_novelsFile, novels.map((n) => n.toJson()).toList());
  }

  @override
  Future<void> deleteNovel(String novelId) async {
    final novels = await loadNovels();
    novels.removeWhere((n) => n.id == novelId);
    await _writeJson(_novelsFile, novels.map((n) => n.toJson()).toList());
  }

  @override
  Future<List<ProviderConfig>> loadProviders() async {
    if (!await _providersFile.exists()) {
      // Seed a sensible default so the app isn't empty on first run.
      final defaults = [
        ProviderConfig(
          id: 'cfg_default_openai',
          name: 'OpenAI 兼容',
          type: ProviderType.openaiStreaming,
          baseUrl: 'https://api.openai.com/v1',
          apiKey: '',
          modelName: 'gpt-4o-mini',
        ),
      ];
      await saveProviders(defaults);
      return defaults;
    }
    final json = jsonDecode(await _providersFile.readAsString());
    final list = (json as List).cast<Map<String, dynamic>>();
    return list.map(ProviderConfig.fromJson).toList();
  }

  @override
  Future<void> saveProviders(List<ProviderConfig> providers) async {
    await _writeJson(
        _providersFile, providers.map((p) => p.toJson()).toList());
  }

  @override
  Future<String?> getActiveProviderId() async {
    if (!await _activeFile.exists()) return null;
    final json = jsonDecode(await _activeFile.readAsString());
    return (json as Map<String, dynamic>)['id'] as String?;
  }

  @override
  Future<void> setActiveProviderId(String? id) async {
    await _writeJson(_activeFile, {'id': id});
  }

  Future<void> _writeJson(File f, Object data) async {
    if (!root.existsSync()) root.createSync(recursive: true);
    await f.writeAsString(const JsonEncoder.withIndent('  ').convert(data));
  }

  @override
  Future<Map<String, dynamic>> loadPrefs() async {
    if (!await _prefsFile.exists()) return {};
    try {
      final json = jsonDecode(await _prefsFile.readAsString());
      if (json is Map) return Map<String, dynamic>.from(json);
    } catch (_) {}
    return {};
  }

  @override
  Future<void> savePrefs(Map<String, dynamic> prefs) async {
    await _writeJson(_prefsFile, prefs);
  }
}
