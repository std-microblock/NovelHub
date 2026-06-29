/// Editor state: document + timeline + conversation + selection/mode, plus
/// orchestration of agent turns (send / resend / revert / clear context).
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/llm/streaming_retry.dart' show CancelToken;
import '../domain/conversation.dart';
import '../domain/entities.dart';
import '../domain/novel_doc.dart';
import '../domain/rich_text.dart';
import '../domain/timeline.dart';
import 'providers.dart';

enum EditorMode { select, edit }

/// Immutable snapshot of editor UI state. The NovelDoc is mutable but
/// referenced by identity; consumers rebuild on [bump] changes.
class EditorState {
  final Novel novel;
  final Chapter chapter;
  final NovelDoc novelDoc;
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
  /// Tool-call ids of `ask_user` calls currently awaiting the user's answer.
  /// Only populated while a turn is live and paused on a question. The UI
  /// renders an interactive card for these; once answered the id leaves this
  /// set and the persisted tool-result renders a read-only summary.
  final Set<String> pendingAskUserIds;

  EditorState({
    required this.novel,
    required this.chapter,
    required this.novelDoc,
    required this.timeline,
    required this.conversation,
    this.mode = EditorMode.select,
    this.selectedParagraphIds = const {},
    this.agentRunning = false,
    this.streamingMessages = const [],
    this.lastError,
    this.editingMessageId,
    this.draftContent = '',
    this.pendingAskUserIds = const {},
  });

  /// The full chapter body as a single editable string (`\n\n`-joined).
  String get chapterBody =>
      chapter.paragraphs.map((p) => p.text).join('\n\n');

  EditorState copyWith({
    Novel? novel,
    Chapter? chapter,
    NovelDoc? novelDoc,
    Timeline? timeline,
    Conversation? conversation,
    EditorMode? mode,
    Set<String>? selectedParagraphIds,
    bool? agentRunning,
    List<Message>? streamingMessages,
    Object? lastError = _sentinel,
    Object? editingMessageId = _sentinel,
    String? draftContent,
    Set<String>? pendingAskUserIds,
  }) =>
      EditorState(
        novel: novel ?? this.novel,
        chapter: chapter ?? this.chapter,
        novelDoc: novelDoc ?? this.novelDoc,
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
        pendingAskUserIds: pendingAskUserIds ?? this.pendingAskUserIds,
      );
}

const _sentinel = Object();

class EditorStateNotifier extends StateNotifier<EditorState> {
  final Ref _ref;
  int _nowTick = 0;
  String? _novelId;
  String? _chapterId;
  CancelToken? _cancelToken;
  /// Pending `ask_user` completers keyed by tool-call id. Each holds the loop
  /// paused until the user answers / skips; completed with `null` on cancel.
  final Map<String, Completer<String?>> _pendingAsk = {};

  EditorStateNotifier(this._ref)
      : super(EditorState(
          novel: _placeholderNovel(),
          chapter: _placeholderNovel().chapters.first,
          novelDoc: NovelDoc(_placeholderNovel()),
          timeline: Timeline(NovelDoc(_placeholderNovel())),
          conversation: Conversation(
              id: 'init', novelId: '', chapterId: ''),
        )) {
    _ref.listen<AsyncValue<Novel?>>(currentNovelProvider, (prev, next) {
      _maybeRebuild();
    });
  }

  static Novel _placeholderNovel() => Novel.create(title: '');

  /// Rebuild doc + conversation ONLY when the novel id actually changes.
  /// Persisting a novel swaps its object identity in novelListProvider →
  /// currentNovelProvider re-emits, but the id is the same, so we must NOT
  /// throw away the live conversation/editor state. The agent conversation is
  /// per-novel (NOT per-chapter), so switching chapters must NOT rebuild the
  /// doc/timeline/conversation — it only swaps which chapter the editor
  /// displays and which chapter tools target by default.
  void _maybeRebuild() {
    final novel = _ref.read(currentNovelProvider).valueOrNull;
    if (novel == null) return;
    // Source of truth for the selected chapter is currentNovelProvider's
    // currentChapterId (set by the top-bar dropdown). Mirror it locally so
    // _currentChapter stays in sync on chapter switches.
    _chapterId = _ref.read(currentNovelProvider.notifier).currentChapterId ??
        novel.chapters.firstOrNull?.id;
    final chapter = _currentChapter(novel);
    if (novel.id == _novelId) {
      // Same novel (covers both persist re-emits and chapter switches):
      // keep the conversation + NovelDoc + timeline (which hold undo history),
      // just refresh the novel/chapter refs. NovelDoc holds this same novel
      // object by reference, so its events survive.
      state = state.copyWith(novel: novel, chapter: chapter);
      return;
    }
    _novelId = novel.id;
    final novelDoc = NovelDoc(novel);
    // The agent conversation is per-novel: load the novel-level conversation
    // (chapterId == ''), or create a fresh one.
    final conv = _loadNovelConversation(novel);
    state = EditorState(
      novel: novel,
      chapter: _currentChapter(novel),
      novelDoc: novelDoc,
      timeline: Timeline(novelDoc),
      conversation: conv,
    );
  }

  Chapter _currentChapter(Novel novel) {
    final id = _chapterId ?? novel.chapters.firstOrNull?.id;
    return novel.chapters.firstWhere(
      (c) => c.id == id,
      orElse: () => novel.chapters.first,
    );
  }

  /// Load the per-novel conversation (the one whose chapterId is empty),
  /// or create a fresh empty one.
  Conversation _loadNovelConversation(Novel novel) {
    for (final raw in novel.conversationsJson) {
      final c = Conversation.fromJson(raw);
      if ((c.chapterId.isEmpty)) return c;
    }
    return Conversation.create(novelId: novel.id, chapterId: '');
  }

  /// Select a chapter for display / as the default tool target. This does NOT
  /// rebuild the agent conversation or undo timeline (those are per-novel):
  /// it updates the current-chapter source of truth and refreshes the editor
  /// state's chapter ref.
  void selectChapter(String chapterId) {
    _ref.read(currentNovelProvider.notifier).selectChapter(chapterId);
    _chapterId = chapterId;
    final novel = _ref.read(currentNovelProvider).valueOrNull;
    if (novel == null) return;
    final chapter = novel.chapters.firstWhere(
      (c) => c.id == chapterId,
      orElse: () => novel.chapters.first,
    );
    state = state.copyWith(novel: novel, chapter: chapter);
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

  // --- chapter structure (manual, UI-driven) ---

  /// Append a new chapter and switch to it. Mirrors the agent's `add_chapter`
  /// tool path (mutates the NovelDoc + records a timeline event) so manual
  /// chapter creation is undo-consistent with agent-created chapters. A
  /// synthetic messageId tags the event; it is never referenced by any
  /// conversation message so it can't be reverted via the turn undo buttons.
  Future<String?> addChapter(String title) async {
    final t = title.trim();
    if (t.isEmpty) return null;
    final ev = state.novelDoc.addChapter(
      title: t,
      messageId: 'manual-${_tick()}',
    );
    final chapterId = ev.chapterId;
    if (chapterId == null) return null;
    selectChapter(chapterId);
    _bump();
    await persistNovel();
    return chapterId;
  }

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
    final selected = _selectedParagraphEntries();
    if (selected == null) return null;
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

  /// The currently-selected paragraphs as ordered (index, paragraph) entries
  /// in the current chapter, or null if nothing is selected. Read-only.
  List<MapEntry<int, Paragraph>>? _selectedParagraphEntries() {
    if (state.selectedParagraphIds.isEmpty) return null;
    final selected = state.chapter.paragraphs
        .asMap()
        .entries
        .where((e) => state.selectedParagraphIds.contains(e.value.id))
        .toList();
    return selected.isEmpty ? null : selected;
  }

  /// Build the agent-facing message context for an outgoing user message:
  /// the currently-selected paragraphs (with their chapter + 1-based numbers).
  /// Returns '' if nothing is selected. Clears the selection afterward.
  /// This context is persisted on the message and sent to the LLM, but NOT
  /// rendered in the UI bubble.
  String _buildSelectionContext() {
    final selected = _selectedParagraphEntries();
    if (selected == null) return '';
    final startNo = selected.first.key + 1;
    final endNo = selected.last.key + 1;
    final body =
        selected.map((e) => '${e.key + 1} ${e.value.text}').join('\n');
    clearSelection();
    return '【选中段落（章节：${state.chapter.title}，第 $startNo~$endNo 段）】\n$body';
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
    // Attach the currently-selected paragraphs as agent-facing context for
    // this message. Persisted on the message (consistency across sessions)
    // but not rendered in the UI.
    final messageContext = _buildSelectionContext();
    // Store the rich content (with tokens) on the user message; the agent
    // gets the converted plain text + messageContext via _userToLlmText.
    final userMsg = Message.user(
      content,
      createdAt: _tick(),
      turnId: turnId,
      messageContext: messageContext,
    );
    state.conversation.messages.add(userMsg);
    _cancelToken = CancelToken();
    state = state.copyWith(
        agentRunning: true,
        streamingMessages: const [],
        lastError: null,
        draftContent: '',
        editingMessageId: null,
        pendingAskUserIds: const {});

    try {
      final loop = _ref.read(agentLoopProvider);
      await loop.run(
        novel: state.novel,
        novelDoc: state.novelDoc,
        chapterId: state.chapter.id,
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
        onAskUser: (call, ctx) => _handleAskUser(call),
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
          lastError: null,
          pendingAskUserIds: const {});
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
        pendingAskUserIds: const {},
      );
    }
  }

  /// Abort the in-progress agent turn. The streaming loop checks the cancel
  /// token between chunks and returns the partial assistant message, which is
  /// then committed so the user keeps what was generated.
  void stop() {
    if (!state.agentRunning) return;
    _cancelToken?.cancel();
    // If we're paused on an ask_user, unblock the loop with null so it
    // returns the partial turn (the cancel branch ends the turn).
    _failAllPendingAsk();
  }

  // --- ask_user: pause the loop for a human answer ---

  Future<String?> _handleAskUser(ToolCall call) async {
    final completer = Completer<String?>();
    _pendingAsk[call.id] = completer;
    // Surface this call as pending so the UI swaps the ToolCallBlock for an
    // interactive card. The streaming snapshot (already emitted) carries the
    // assistant message + toolCalls; we just flag which callId is awaiting.
    state = state.copyWith(
        pendingAskUserIds: {...state.pendingAskUserIds, call.id});
    return completer.future;
  }

  /// User submitted an answer for [callId]. [answer] is the structured value
  /// (string for fill-in / single-select; List<String> for multi-select).
  void answerAskUser(String callId, Object answer) {
    final completer = _pendingAsk.remove(callId);
    if (completer == null || completer.isCompleted) return;
    completer.complete(jsonEncode({
      'ok': true,
      'answer': answer,
      'skipped': false,
      'cancelled': false,
    }));
    state = state.copyWith(
        pendingAskUserIds: state.pendingAskUserIds..remove(callId));
  }

  /// User tapped "skip" — no answer, but the model should continue.
  void skipAskUser(String callId) {
    final completer = _pendingAsk.remove(callId);
    if (completer == null || completer.isCompleted) return;
    completer.complete(jsonEncode({
      'ok': false,
      'answer': null,
      'skipped': true,
      'cancelled': false,
    }));
    state = state.copyWith(
        pendingAskUserIds: state.pendingAskUserIds..remove(callId));
  }

  void _failAllPendingAsk() {
    if (_pendingAsk.isEmpty) return;
    final pending = List.of(_pendingAsk.entries);
    _pendingAsk.clear();
    for (final e in pending) {
      if (!e.value.isCompleted) e.value.complete(null);
    }
    state = state.copyWith(pendingAskUserIds: const {});
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

  /// Clear the conversation context but keep the document as-is. The agent
  /// conversation is per-novel, so the new empty conversation is also per-novel
  /// (chapterId == '').
  void clearContext() {
    state = state.copyWith(
      conversation: Conversation.create(
          novelId: state.novel.id, chapterId: ''),
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
