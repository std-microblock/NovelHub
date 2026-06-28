/// Riverpod providers wiring repository, LLM clients, editor/conversation
/// state, and the agent loop together. Uses riverpod's core API (no codegen)
/// to stay build_runner-free.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/llm/llm_client.dart';
import '../data/llm/provider_factory.dart';
import '../data/repositories/app_repository.dart';
import '../domain/entities.dart';
import '../agent/agent_loop.dart';
import 'editor_state.dart';

/// Singleton repository. Initialized in main() before runApp.
final appRepositoryProvider = Provider<AppRepository>((ref) {
  throw UnimplementedError('appRepositoryProvider must be overridden in main()');
});

// --- Provider configs (LLM) ---

final providerConfigListProvider =
    StateNotifierProvider<ProviderConfigListNotifier, AsyncValue<List<ProviderConfig>>>(
        (ref) {
  return ProviderConfigListNotifier(ref.watch(appRepositoryProvider));
});

class ProviderConfigListNotifier
    extends StateNotifier<AsyncValue<List<ProviderConfig>>> {
  final AppRepository _repo;
  ProviderConfigListNotifier(this._repo) : super(const AsyncValue.loading()) {
    _load();
  }

  Future<void> _load() async {
    state = AsyncValue.data(await _repo.loadProviders());
  }

  Future<void> add(ProviderConfig config) async {
    final list = [...?state.value, config];
    await _repo.saveProviders(list);
    state = AsyncValue.data(list);
  }

  Future<void> update(ProviderConfig config) async {
    final list = [...?state.value];
    final idx = list.indexWhere((p) => p.id == config.id);
    if (idx >= 0) list[idx] = config;
    await _repo.saveProviders(list);
    state = AsyncValue.data(list);
  }

  Future<void> remove(String id) async {
    final list = [...?state.value];
    list.removeWhere((p) => p.id == id);
    await _repo.saveProviders(list);
    state = AsyncValue.data(list);
  }
}

final activeProviderIdProvider =
    StateNotifierProvider<ActiveProviderIdNotifier, AsyncValue<String?>>((ref) {
  return ActiveProviderIdNotifier(ref.watch(appRepositoryProvider));
});

class ActiveProviderIdNotifier extends StateNotifier<AsyncValue<String?>> {
  final AppRepository _repo;
  ActiveProviderIdNotifier(this._repo)
      : super(const AsyncValue.loading()) {
    _load();
  }

  Future<void> _load() async {
    state = AsyncValue.data(await _repo.getActiveProviderId());
  }

  Future<void> set(String? id) async {
    await _repo.setActiveProviderId(id);
    state = AsyncValue.data(id);
  }
}

/// The resolved active ProviderConfig (global, or novel override applied
/// downstream). Falls back to the first available config.
final activeProviderConfigProvider =
    Provider<ProviderConfig?>((ref) {
  final list = ref.watch(providerConfigListProvider).valueOrNull ?? [];
  final activeId = ref.watch(activeProviderIdProvider).valueOrNull;
  if (list.isEmpty) return null;
  return list.firstWhere(
    (p) => p.id == activeId,
    orElse: () => list.first,
  );
});

/// Builds an LlmClient for the active config.
final llmClientProvider = Provider<LlmClient?>((ref) {
  final config = ref.watch(activeProviderConfigProvider);
  if (config == null) return null;
  return buildLlmClient(config);
});

final agentLoopProvider = Provider<AgentLoop>((ref) {
  final client = ref.watch(llmClientProvider);
  if (client == null) {
    throw StateError('No active LLM provider configured');
  }
  return AgentLoop(client: client);
});

// --- App preferences ---

/// How the Enter key behaves in the composer.
enum SendBehavior { enterToSend, ctrlEnterToSend }

extension SendBehaviorX on SendBehavior {
  String get label => switch (this) {
        SendBehavior.enterToSend => 'Enter 发送（Shift+Enter 换行）',
        SendBehavior.ctrlEnterToSend => 'Ctrl+Enter 发送（Enter 换行）',
      };
  static SendBehavior fromName(String? s) => switch (s) {
        'ctrlEnter' => SendBehavior.ctrlEnterToSend,
        _ => SendBehavior.enterToSend,
      };
  String get name => switch (this) {
        SendBehavior.enterToSend => 'enter',
        SendBehavior.ctrlEnterToSend => 'ctrlEnter',
      };
}

final prefsProvider =
    StateNotifierProvider<PrefsNotifier, Map<String, dynamic>>((ref) {
  return PrefsNotifier(ref.watch(appRepositoryProvider));
});

class PrefsNotifier extends StateNotifier<Map<String, dynamic>> {
  final AppRepository _repo;
  PrefsNotifier(this._repo) : super(const {}) {
    _load();
  }

  Future<void> _load() async {
    state = await _repo.loadPrefs();
  }

  Future<void> set(String key, dynamic value) async {
    state = {...state, key: value};
    await _repo.savePrefs(state);
  }

  SendBehavior get sendBehavior =>
      SendBehaviorX.fromName(state['sendBehavior'] as String?);
  set sendBehavior(SendBehavior v) => set('sendBehavior', v.name);
}

/// Convenience accessor for the send behavior.
final sendBehaviorProvider = Provider<SendBehavior>(
    (ref) => ref.watch(prefsProvider.notifier).sendBehavior);

// --- Novels ---

final novelListProvider =
    StateNotifierProvider<NovelListNotifier, AsyncValue<List<Novel>>>((ref) {
  return NovelListNotifier(ref.watch(appRepositoryProvider));
});

class NovelListNotifier extends StateNotifier<AsyncValue<List<Novel>>> {
  final AppRepository _repo;
  NovelListNotifier(this._repo) : super(const AsyncValue.loading()) {
    _load();
  }

  Future<void> _load() async {
    state = AsyncValue.data(await _repo.loadNovels());
  }

  Future<Novel> create(String title) async {
    final novel = Novel.create(title: title);
    await _repo.saveNovel(novel);
    state = AsyncValue.data([...?state.value, novel]);
    return novel;
  }

  Future<Novel> duplicate(String novelId) async {
    final novels = [...?state.value];
    final src = novels.firstWhere((n) => n.id == novelId);
    final copy = src.copy()..title = '${src.title} 副本';
    // Give fresh ids to everything so they don't collide.
    final fresh = Novel.create(title: copy.title)
      ..textSettings = src.textSettings
      ..characterSettings = src.characterSettings.map((e) => e.copy()).toList()
      ..textRequirements = src.textRequirements.map((e) => e.copy()).toList()
      ..chapters = src.chapters
          .map((c) => Chapter(
              id: _uuid(), title: c.title, paragraphs: c.paragraphs.map((p) => p.copy()).toList()))
          .toList();
    await _repo.saveNovel(fresh);
    state = AsyncValue.data([...novels, fresh]);
    return fresh;
  }

  Future<void> delete(String novelId) async {
    await _repo.deleteNovel(novelId);
    final list = [...?state.value];
    list.removeWhere((n) => n.id == novelId);
    state = AsyncValue.data(list);
  }

  Future<void> save(Novel novel) async {
    await _repo.saveNovel(novel);
    final list = [...?state.value];
    final idx = list.indexWhere((n) => n.id == novel.id);
    if (idx >= 0) list[idx] = novel;
    state = AsyncValue.data(list);
  }
}

String _uuid() => DateTime.now().microsecondsSinceEpoch.toRadixString(16);

// --- Currently selected novel + chapter ---

final currentNovelIdProvider = StateProvider<String?>((ref) => null);

/// The currently active Novel (mutable, with its own state notifier so edits
/// propagate). The notifier holds the live NovelDoc for the current
/// novel/chapter.
final currentNovelProvider =
    StateNotifierProvider<CurrentNovelNotifier, AsyncValue<Novel?>>((ref) {
  return CurrentNovelNotifier(ref);
});

class CurrentNovelNotifier extends StateNotifier<AsyncValue<Novel?>> {
  final Ref _ref;
  String? _currentChapterId;

  CurrentNovelNotifier(this._ref) : super(const AsyncValue.loading()) {
    _ref.listen<AsyncValue<List<Novel>>>(novelListProvider, (prev, next) {
      _resync();
    });
    _ref.listen<String?>(currentNovelIdProvider, (prev, next) => _resync());
  }

  Future<void> _resync() async {
    final id = _ref.read(currentNovelIdProvider);
    final novels = _ref.read(novelListProvider).valueOrNull ?? [];
    if (id == null || novels.isEmpty) {
      _currentChapterId = null;
      state = const AsyncValue.data(null);
      return;
    }
    final novel = novels.firstWhere(
      (n) => n.id == id,
      orElse: () => novels.first,
    );
    if (_currentChapterId == null ||
        !novel.chapters.any((c) => c.id == _currentChapterId)) {
      _currentChapterId = novel.chapters.firstOrNull?.id;
    }
    state = AsyncValue.data(novel);
  }

  void selectChapter(String chapterId) {
    _currentChapterId = chapterId;
    // trigger rebuild
    final v = state.value;
    if (v != null) state = AsyncValue.data(v);
  }

  String? get currentChapterId => _currentChapterId;
}

// --- Editor / document / conversation ---

/// The mutable NovelDoc + timeline + conversation for the current
/// novel/chapter. Rebuilt when novel or chapter changes.
final editorStateProvider =
    StateNotifierProvider<EditorStateNotifier, EditorState>((ref) {
  return EditorStateNotifier(ref);
});
