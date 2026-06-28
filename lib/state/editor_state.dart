/// Editor state: document + timeline + conversation + selection/mode, plus
/// orchestration of agent turns (send / resend / revert / clear context).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/llm/streaming_retry.dart' show CancelToken;
import '../domain/conversation.dart';
import '../domain/entities.dart';
import '../domain/paragraph_doc.dart';
import '../domain/rich_text.dart';
import '../domain/timeline.dart';
import 'providers.dart';

enum EditorMode { select, edit }

/// Immutable snapshot of editor UI state. The ParagraphDoc is mutable but
/// referenced by identity; consumers rebuild on [bump] changes.
class EditorState {
  final Novel novel;
  final Chapter chapter;
  final ParagraphDoc doc;
  final Timeline timeline;
  final Conversation conversation;
  final EditorMode mode;
  final Set<String> selectedParagraphIds;
  final bool agentRunning;
  /// Messages produced by the in-progress agent turn (assistant rounds +
  /// interleaved tool messages). Empty when no turn is running. The last
  /// assistant element is the currently-streaming message.
  final List<Message> streamingMessages;
  final String? lastError;
  final String? editingMessageId;
  /// The draft rich-text content: a plain string carrying inline
  /// `@@${<json>}$@@` tokens (see domain/rich_text.dart). Self-contained —
  /// no separate ref list needed.
  final String draftContent;

  EditorState({
    required this.novel,
    required this.chapter,
    required this.doc,
    required this.timeline,
    required this.conversation,
    this.mode = EditorMode.select,
    this.selectedParagraphIds = const {},
    this.agentRunning = false,
    this.streamingMessages = const [],
    this.lastError,
    this.editingMessageId,
    this.draftContent = '',
  });

  /// The full chapter body as a single editable string (`\n\n`-joined).
  String get chapterBody =>
      chapter.paragraphs.map((p) => p.text).join('\n\n');

  EditorState copyWith({
    Novel? novel,
    Chapter? chapter,
    ParagraphDoc? doc,
    Timeline? timeline,
    Conversation? conversation,
    EditorMode? mode,
    Set<String>? selectedParagraphIds,
    bool? agentRunning,
    List<Message>? streamingMessages,
    Object? lastError = _sentinel,
    Object? editingMessageId = _sentinel,
    String? draftContent,
  }) =>
      EditorState(
        novel: novel ?? this.novel,
        chapter: chapter ?? this.chapter,
        doc: doc ?? this.doc,
        timeline: timeline ?? this.timeline,
        conversation: conversation ?? this.conversation,
        mode: mode ?? this.mode,
        selectedParagraphIds:
            selectedParagraphIds ?? this.selectedParagraphIds,
        agentRunning: agentRunning ?? this.agentRunning,
        streamingMessages: streamingMessages ?? this.streamingMessages,
        lastError: identical(lastError, _sentinel)
            ? this.lastError
            : lastError?.toString(),
        editingMessageId: identical(editingMessageId, _sentinel)
            ? this.editingMessageId
            : editingMessageId?.toString(),
        draftContent: draftContent ?? this.draftContent,
      );
}

const _sentinel = Object();

class EditorStateNotifier extends StateNotifier<EditorState> {
  final Ref _ref;
  int _nowTick = 0;
  String? _novelId;
  String? _chapterId;
  CancelToken? _cancelToken;

  EditorStateNotifier(this._ref)
      : super(EditorState(
          novel: _placeholderNovel(),
          chapter: _placeholderNovel().chapters.first,
          doc: ParagraphDoc(_placeholderNovel().chapters.first),
          timeline: Timeline(ParagraphDoc(_placeholderNovel().chapters.first)),
          conversation: Conversation(
              id: 'init', novelId: '', chapterId: ''),
        )) {
    _ref.listen<AsyncValue<Novel?>>(currentNovelProvider, (prev, next) {
      _maybeRebuild();
    });
  }

  static Novel _placeholderNovel() => Novel.create(title: '');

  /// Rebuild doc + conversation ONLY when the novel id or chapter id actually
  /// changes. Persisting a novel swaps its object identity in
  /// novelListProvider → currentNovelProvider re-emits, but the id is the
  /// same, so we must NOT throw away the live conversation/editor state.
  void _maybeRebuild() {
    final novel = _ref.read(currentNovelProvider).valueOrNull;
    if (novel == null) return;
    final chapterId =
        _ref.read(currentNovelProvider.notifier).currentChapterId ??
            novel.chapters.first.id;
    final chapter = novel.chapters.firstWhere(
      (c) => c.id == chapterId,
      orElse: () => novel.chapters.first,
    );
    if (novel.id == _novelId && chapterId == _chapterId) {
      // Same novel+chapter: keep editor state, just refresh the novel ref so
      // the editor sees any externally-loaded changes (e.g. settings).
      state = state.copyWith(novel: novel, chapter: chapter);
      return;
    }
    _novelId = novel.id;
    _chapterId = chapterId;
    final doc = ParagraphDoc(chapter);
    // Load any persisted conversation for this chapter.
    final conv = _loadConversation(novel, chapter.id);
    state = EditorState(
      novel: novel,
      chapter: chapter,
      doc: doc,
      timeline: Timeline(doc),
      conversation: conv,
    );
  }

  /// Load the persisted conversation for a chapter (from the novel's
  /// conversationsJson), or create a fresh empty one.
  Conversation _loadConversation(Novel novel, String chapterId) {
    for (final raw in novel.conversationsJson) {
      final c = Conversation.fromJson(raw);
      if (c.chapterId == chapterId) return c;
    }
    return Conversation.create(novelId: novel.id, chapterId: chapterId);
  }

  /// Public hook for when the chapter changes via the top bar dropdown.
  void onChapterChanged(String chapterId) {
    _ref.read(currentNovelProvider.notifier).selectChapter(chapterId);
    _chapterId = null; // force rebuild to pick up new chapter id
    _maybeRebuild();
  }

  // --- mode / selection ---

  void setMode(EditorMode mode) =>
      state = state.copyWith(mode: mode);

  void toggleParagraphSelection(String id) {
    final sel = {...state.selectedParagraphIds};
    if (sel.contains(id)) {
      sel.remove(id);
    } else {
      sel.add(id);
    }
    state = state.copyWith(selectedParagraphIds: sel);
  }

  void clearSelection() =>
      state = state.copyWith(selectedParagraphIds: {});

  // --- doc edits from the editor (edit mode) ---

  /// Replace the whole chapter body from a single text field. Paragraphs are
  /// split on double-newline (`\n\n`), so pressing Enter twice creates a new
  /// paragraph automatically. Blank trailing splits are kept as empty
  /// paragraphs so the writer can keep typing.
  void setChapterBody(String body) {
    final paragraphs = body.split('\n\n');
    state.chapter.paragraphs
      ..clear()
      ..addAll(paragraphs.map((t) => Paragraph.create(t)));
    _bump();
  }

  void editParagraphText(String id, String text) {
    final idx = state.chapter.paragraphs.indexWhere((p) => p.id == id);
    if (idx >= 0) state.chapter.paragraphs[idx].text = text;
    _bump();
  }

  void _bump() {
    _nowTick++;
    // Re-emit by creating a shallow copy so Riverpod sees a change.
    state = state.copyWith();
  }

  Future<void> persistNovel() async {
    // Persist the current conversation alongside the novel (upsert into the
    // novel's conversationsJson by chapter id).
    final novel = state.novel;
    final conv = state.conversation;
    final updated = <Map<String, dynamic>>[];
    bool replaced = false;
    for (final raw in novel.conversationsJson) {
      if (raw['chapterId'] == conv.chapterId) {
        updated.add(conv.toJson());
        replaced = true;
      } else {
        updated.add(raw);
      }
    }
    if (!replaced) updated.add(conv.toJson());
    novel.conversationsJson = updated;
    await _ref.read(appRepositoryProvider).saveNovel(novel);
    _ref.read(novelListProvider.notifier).save(novel);
  }

  // --- agent ---

  /// The composer calls this whenever the rich-text draft content changes
  /// (typing, deleting a badge, etc.). Stores the new tokenized string.
  void setDraftContent(String content) {
    state = state.copyWith(draftContent: content);
  }

  /// Build a ref-content [RichToken] for the currently-selected paragraphs,
  /// or null if nothing is selected. Does not mutate state except clearing the
  /// selection afterward (the composer inserts the returned token into the
  /// rich-text editor, which becomes the source of truth for the draft).
  RichToken? buildRefTokenForSelection({bool keepSelection = false}) {
    if (state.selectedParagraphIds.isEmpty) return null;
    final paras = state.chapter.paragraphs;
    final selected = paras
        .asMap()
        .entries
        .where((e) => state.selectedParagraphIds.contains(e.value.id))
        .toList();
    if (selected.isEmpty) return null;
    final startNo = selected.first.key + 1;
    final endNo = selected.last.key + 1;
    final body =
        selected.map((e) => '${e.key + 1} ${e.value.text}').join('\n');
    final token = RichToken.refContent(
      chapter: state.chapter.title,
      start: startNo,
      end: endNo,
      content: body,
      id: 'ref_${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}',
    );
    if (!keepSelection) clearSelection();
    return token;
  }

  /// Insert a reference badge for the currently-selected paragraphs into the
  /// draft at the given character offset (or at the end if null). Clears the
  /// selection. The composer passes the current cursor offset.
  void insertRefAtCursor(int? offset) {
    final token = buildRefTokenForSelection();
    if (token == null) return;
    final serialized = token.serialize();
    final content = state.draftContent;
    final insertAt = (offset == null || offset < 0 || offset > content.length)
        ? content.length
        : offset;
    final newContent = content.substring(0, insertAt) +
        serialized +
        content.substring(insertAt);
    state = state.copyWith(draftContent: newContent);
  }

  /// Remove the first ref-content token whose serialized form appears in the
  /// draft (used when the user deletes a badge in the editor).
  void removeFirstRef() {
    final pieces = parseRich(state.draftContent);
    for (var i = 0; i < pieces.length; i++) {
      if (pieces[i] is TokenPiece) {
        pieces.removeAt(i);
        state = state.copyWith(draftContent: serializeRich(pieces));
        return;
      }
    }
  }

  /// "Edit" entry point: revert the timeline to (and including) this message,
  /// remove this message and everything after it from the conversation, and
  /// load its content into the draft box (badges preserved, since content
  /// carries the inline tokens).
  void loadMessageForEdit(String messageId) {
    final msg = state.conversation.messages.firstWhere(
      (m) => m.id == messageId,
      orElse: () =>
          Message(id: '', role: MessageRole.user, turnId: '', createdAt: 0),
    );
    if (msg.id.isEmpty) return;
    state.timeline.revertTo(messageId, includeMessage: true);
    final msgs = state.conversation.messages;
    final idx = msgs.indexWhere((m) => m.id == messageId);
    if (idx >= 0) msgs.removeRange(idx, msgs.length);
    state = state.copyWith(
        draftContent: msg.content, editingMessageId: messageId);
  }

  void clearDraft() {
    state = state.copyWith(
        draftContent: '', editingMessageId: null);
  }

  Future<void> send(String text) async {
    if (state.agentRunning) return;
    // The composer owns the rich-text draft (with @@$...$@@ tokens). If a
    // plain `text` was passed (e.g. retry with plain content) use it instead.
    final content = text.trim().isNotEmpty && state.draftContent.trim().isEmpty
        ? text.trim()
        : state.draftContent;

    final editingId = state.editingMessageId;
    if (editingId != null) {
      state.timeline.revertTo(editingId, includeMessage: true);
      final msgs = state.conversation.messages;
      final idx = msgs.indexWhere((m) => m.id == editingId);
      if (idx >= 0) msgs.removeRange(idx, msgs.length);
    }

    // Nothing to send? (empty text and no tokens)
    if (content.trim().isEmpty) return;

    final turnId = 'turn_${_tick()}';
    // Store the rich content (with tokens) on the user message; the agent
    // gets the converted plain text via toAgentText at run time.
    final userMsg = Message.user(
      content,
      createdAt: _tick(),
      turnId: turnId,
    );
    state.conversation.messages.add(userMsg);
    _cancelToken = CancelToken();
    state = state.copyWith(
        agentRunning: true,
        streamingMessages: const [],
        lastError: null,
        draftContent: '',
        editingMessageId: null);

    try {
      final loop = _ref.read(agentLoopProvider);
      await loop.run(
        novel: state.novel,
        doc: state.doc,
        chapterTitle: state.chapter.title,
        history: state.conversation.messages
            .where((m) => m.id != userMsg.id)
            .toList(),
        userMessage: userMsg,
        now: _tick(),
        cancelToken: _cancelToken,
        onTurnUpdate: (snap) {
          // The whole turn's messages stream live. Last assistant element
          // is the in-progress one.
          state = state.copyWith(streamingMessages: snap.messages);
        },
      );
      // Commit the turn's messages into the conversation and clear the
      // streaming list IN THE SAME state update so the UI never renders
      // both the committed messages and the streaming bubbles at once.
      final committed = state.streamingMessages
          .where((m) =>
              m.content.isNotEmpty ||
              m.toolCalls.isNotEmpty ||
              m.role == MessageRole.tool)
          .toList();
      state.conversation.messages.addAll(committed);
      _cancelToken = null;
      state = state.copyWith(
          agentRunning: false,
          streamingMessages: const [],
          lastError: null);
      await persistNovel();
    } catch (e) {
      // Commit whatever was streamed before the failure so the user sees it.
      final partial = state.streamingMessages
          .where((m) =>
              m.content.isNotEmpty ||
              m.toolCalls.isNotEmpty ||
              m.role == MessageRole.tool)
          .toList();
      state.conversation.messages.addAll(partial);
      _cancelToken = null;
      state = state.copyWith(
        agentRunning: false,
        streamingMessages: const [],
        lastError: e,
      );
    }
  }

  /// Abort the in-progress agent turn. The streaming loop checks the cancel
  /// token between chunks and returns the partial assistant message, which is
  /// then committed so the user keeps what was generated.
  void stop() {
    if (!state.agentRunning) return;
    _cancelToken?.cancel();
  }

  /// Jump the timeline back to the state at [messageId] without resending.
  void revertTo(String messageId) {
    state.timeline.revertTo(messageId);
    final msgs = state.conversation.messages;
    final idx = msgs.indexWhere((m) => m.id == messageId);
    if (idx >= 0) {
      msgs.removeRange(idx + 1, msgs.length);
    }
    _bump();
  }

  // --- turn-level actions (applied to a whole turn: user msg + its replies) ---

  /// Delete an entire turn (the user message and all its assistant/tool
  /// replies), undoing any document mutations the turn produced.
  void deleteTurn(String turnId) {
    if (state.agentRunning) return;
    // Undo mutations from every message in this turn, newest first.
    final turnMsgs =
        state.conversation.messages.where((m) => m.turnId == turnId).toList();
    for (final m in turnMsgs.reversed) {
      state.timeline.revertTo(m.id, includeMessage: true);
    }
    state.conversation.messages
        .removeWhere((m) => m.turnId == turnId);
    _bump();
    persistNovel();
  }

  /// Revert (without resending) to the state just before a turn: undo that
  /// turn's mutations and drop the turn's user message + replies. Equivalent
  /// to "撤回" this turn.
  void revertTurn(String turnId) => deleteTurn(turnId);

  /// Retry a turn: undo that turn's mutations, drop the turn, then resend the
  /// (edited) user content as a fresh turn. If [newContent] is null, reuse the
  /// original user message content.
  Future<void> retryTurn(String turnId, {String? newContent}) async {
    if (state.agentRunning) return;
    final userMsg = state.conversation.messages.firstWhere(
      (m) => m.turnId == turnId && m.role == MessageRole.user,
      orElse: () =>
          Message(id: '', role: MessageRole.user, turnId: '', createdAt: 0),
    );
    if (userMsg.id.isEmpty) return;
    final content = newContent ?? userMsg.content;
    // Undo + drop the whole turn.
    deleteTurn(turnId);
    // Reload the content into the draft (rich-text preserved) and send.
    state = state.copyWith(draftContent: content);
    await send('');
  }

  /// Load a turn's user message into the input box for editing (revert +
  /// resend happens on send).
  void editTurn(String turnId) {
    final userMsg = state.conversation.messages.firstWhere(
      (m) => m.turnId == turnId && m.role == MessageRole.user,
      orElse: () =>
          Message(id: '', role: MessageRole.user, turnId: '', createdAt: 0),
    );
    if (userMsg.id.isEmpty) return;
    loadMessageForEdit(userMsg.id);
  }

  /// Clear the conversation context but keep the document as-is.
  void clearContext() {
    state = state.copyWith(
      conversation: Conversation.create(
          novelId: state.novel.id, chapterId: state.chapter.id),
      streamingMessages: const [],
      agentRunning: false,
      lastError: null,
      draftContent: '',
      editingMessageId: null,
    );
    persistNovel();
  }

  int _tick() => _nowTick++;
}
