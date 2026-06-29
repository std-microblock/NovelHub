import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/llm/llm_client.dart';
import '../../../domain/conversation.dart' show Message, MessageRole;
import '../../../domain/rich_text.dart';
import '../../../state/editor_state.dart';
import '../../../state/providers.dart';
import 'ask_user_card.dart';
import 'message_tile.dart';
import 'ref_badge.dart';
import 'rich_text_controller.dart';

/// Lower pane: a resizable conversation panel + a redesigned input composer.
/// Errors surface inline; the composer's left button opens a model switcher;
/// Enter / Ctrl+Enter send behavior is configurable in settings.
class AgentPane extends ConsumerStatefulWidget {
  final EditorState editor;
  /// Current panel height (portrait). `double.infinity` in landscape / unset.
  final double panelHeight;
  /// Fully-collapsed height = header only. The drag clamp stops here so the
  /// panel can shrink to just the "Agent" title (composer hidden).
  final double headerHeight;
  /// Half-collapsed height = header + composer (input visible, messages
  /// hidden). The damping band sits below this.
  final double midHeight;
  /// Position-based drag callbacks — the same ones the strip handle uses.
  /// Wired to the "Agent" header row so dragging the title / blank header area
  /// resizes the panel. [onDragEnd] triggers snap-to-nearest-resting-state.
  final void Function(double startGlobalY)? onDragStart;
  final void Function(double globalY)? onDragUpdate;
  final VoidCallback? onDragEnd;
  /// Tapped the "Agent" title / blank header area → toggle expand / collapse.
  final VoidCallback? onToggleExpand;
  /// Reports measured header height and (when the composer is rendered)
  /// header + composer height, so EditorScreen can size its drag clamp and
  /// snap bands. When fully collapsed the composer isn't rendered, so only the
  /// header height is reported (EditorScreen keeps the last known midH).
  final void Function(double headerH, double midH)? onMeasureHeights;
  const AgentPane({
    super.key,
    required this.editor,
    this.panelHeight = double.infinity,
    this.headerHeight = 0,
    this.midHeight = 0,
    this.onDragStart,
    this.onDragUpdate,
    this.onDragEnd,
    this.onToggleExpand,
    this.onMeasureHeights,
  });

  @override
  ConsumerState<AgentPane> createState() => _AgentPaneState();
}

class _AgentPaneState extends ConsumerState<AgentPane> {
  final _scroll = ScrollController();
  bool _autoScroll = true;
  bool _showJumpButton = false;
  // Last user-driven scroll offset, used to tell an upward flick from growth.
  double _lastUserPixels = double.infinity;
  // Keys used to measure the header / composer height so EditorScreen can
  // clamp the panel's drag range (header-only floor, header+composer band).
  final _headerKey = GlobalKey();
  final _composerKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  /// Track whether the user is at the bottom. When the user scrolls away from
  /// the bottom (manually, or via drag), auto-scroll is suspended; tapping the
  /// floating "jump to bottom" button re-enables it.
  ///
  /// Uses hysteresis (two thresholds) so the jump-button / auto-scroll flag
  /// doesn't thrash on/off when the user idles near the boundary.
  ///
  /// The jump button's visibility is derived purely from `_autoScroll` (shown
  /// when not at bottom), so a single state flip drives it — no separate
  /// `_showJumpButton` recomputation that could flip per-scroll-event.
  void _onScroll() {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    final distance = pos.maxScrollExtent - pos.pixels;
    final bool atBottom = _autoScroll ? distance < 96 : distance < 32;
    if (atBottom != _autoScroll) {
      _autoScroll = atBottom;
      setState(() => _showJumpButton = !atBottom);
    }
    // Keep the baseline current so the next upward flick registers cleanly
    // (programmatic jumpTo also routes through here with distance≈0, which we
    // don't want to read as a user scroll-up).
    _lastUserPixels = pos.pixels;
  }

  /// A *user* dragged the message list (as opposed to a programmatic jumpTo).
  /// UserScrollNotification is emitted only by real gestures — the per-frame
  /// jumpTo during streaming does NOT produce it — so this is the reliable way
  /// to tell "the user is reading history" from "content grew". Dragging toward
  /// the top of the list (pixels decreasing vs. the last user-driven position)
  /// suspends auto-scroll; the hysteresis in [_onScroll] re-enables it once the
  /// user scrolls back to the bottom. This is necessary because jumpTo itself
  /// fires [_onScroll] with distance≈0, which would otherwise keep _autoScroll
  /// pinned to true forever and swallow every upward flick.
  bool _onUserScroll(UserScrollNotification n) {
    final p = n.metrics.pixels;
    if (p < _lastUserPixels && _autoScroll) {
      _autoScroll = false;
      if (mounted) setState(() => _showJumpButton = true);
    }
    _lastUserPixels = p;
    return false;
  }

  /// Streaming-time auto-scroll: while the user is pinned to the bottom, jump
  /// to the bottom immediately after each content/layout growth so new content
  /// grows upward with the bottom edge always in view — no visible "write past
  /// the bottom then animate to catch up" effect. The user's scroll-up is still
  /// respected (the hysteresis in [_onScroll] flips [_autoScroll] off). No
  /// animation while streaming pinned; the smooth [animateTo] is reserved for
  /// the manual jump-to-bottom button ([_jumpToBottom]).
  void _maybeAutoScroll() {
    if (!_autoScroll || !_scroll.hasClients) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients || !_autoScroll) return;
      // jumpTo (not animateTo) so the bottom stays pinned frame-by-frame as
      // maxScrollExtent grows during streaming.
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  /// Measure the header height and (when the composer is rendered) header +
  /// composer height, reporting both up so EditorScreen can size its drag
  /// clamp and snap bands. When fully collapsed the composer isn't rendered,
  /// so only the header height is reported (EditorScreen keeps the last known
  /// midH).
  void _measureHeights() {
    final cb = widget.onMeasureHeights;
    if (cb == null) return;
    final headerCtx = _headerKey.currentContext;
    if (headerCtx == null) return;
    final headerBox = headerCtx.findRenderObject() as RenderBox?;
    if (headerBox == null || !headerBox.attached || headerBox.size.isEmpty) {
      return;
    }
    final headerH = headerBox.size.height;
    double midH = headerH;
    final composerCtx = _composerKey.currentContext;
    if (composerCtx != null) {
      final composerBox = composerCtx.findRenderObject() as RenderBox?;
      if (composerBox != null &&
          composerBox.attached &&
          !composerBox.size.isEmpty) {
        midH = headerH + composerBox.size.height;
      }
    }
    cb(headerH, midH);
  }

  void _scheduleMeasureHeights() {
    if (widget.onMeasureHeights == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => _measureHeights());
  }

  void _jumpToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll
          .animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      )
          .then((_) {
        if (!mounted) return;
        setState(() {
          _autoScroll = true;
          _showJumpButton = false;
        });
      });
    });
  }

  void _send() {
    final editor = ref.read(editorStateProvider);
    if (editor.agentRunning) {
      ref.read(editorStateProvider.notifier).stop();
      return;
    }
    ref.read(editorStateProvider.notifier).send('');
    // Scroll the just-sent user bubble into view before streaming starts.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final editor = ref.watch(editorStateProvider);
    final notifier = ref.read(editorStateProvider.notifier);
    final messages = editor.conversation.messages;
    final streaming = editor.streamingMessages;
    // The last assistant message in the streaming list is the in-progress one.
    final streamingActive = streaming.isNotEmpty &&
        editor.agentRunning &&
        streaming.last.role == MessageRole.assistant;

    // Only auto-scroll while the agent is actively streaming new content.
    // Doing this on every rebuild (incl. typing in the composer, which also
    // rebuilds this pane) caused the list to jump on every keystroke.
    if (streamingActive) _maybeAutoScroll();

    final scheme = Theme.of(context).colorScheme;

    // Composer height (header→mid gap), used to pad the message list so its last
    // item isn't hidden behind the pinned composer, and to place the jump btn.
    final composerH =
        (widget.midHeight - widget.headerHeight).clamp(0.0, double.infinity);
    final expanded = widget.panelHeight > widget.midHeight + 48.0;

    // Report measured header / header+composer heights up to EditorScreen so its
    // drag clamp and snap bands stay in sync with the actual widget sizes.
    _scheduleMeasureHeights();

    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
      ),
      child: Column(
        children: [
          // Header. The leading group (grip + icon + "Agent" title + blank
          // spacer) forwards the same position-based drag callbacks the panel
          // uses, so dragging the title / empty header area resizes the panel.
          // A tap (with no drag) toggles expand / collapse. The trailing action
          // buttons stay outside the gesture detector so they remain tappable.
          Padding(
            key: _headerKey,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onVerticalDragStart: widget.onDragStart == null
                        ? null
                        : (d) => widget.onDragStart!(d.globalPosition.dy),
                    onVerticalDragUpdate: widget.onDragUpdate == null
                        ? null
                        : (d) => widget.onDragUpdate!(d.globalPosition.dy),
                    onVerticalDragEnd: widget.onDragEnd == null
                        ? null
                        : (_) => widget.onDragEnd!(),
                    onTap: widget.onToggleExpand,
                    child: Row(
                      children: [
                        // Six-dot grip: visual affordance that this row drags
                        // the whole panel (the standalone separator strip was
                        // removed; this is the only drag handle now).
                        Icon(Icons.drag_indicator,
                            size: 20, color: scheme.onSurfaceVariant),
                        const SizedBox(width: 2),
                        Icon(Icons.auto_awesome,
                            size: 16, color: scheme.primary),
                        const SizedBox(width: 6),
                        Text('Agent',
                            style: Theme.of(context).textTheme.titleSmall),
                        const Spacer(),
                      ],
                    ),
                  ),
                ),
                if (editor.editingMessageId != null)
                  TextButton.icon(
                    icon: const Icon(Icons.close, size: 16),
                    label: const Text('取消编辑'),
                    onPressed: notifier.clearDraft,
                  ),
                IconButton(
                  icon: const Icon(Icons.cleaning_services_outlined,
                      size: 18),
                  tooltip: '清空上下文',
                  onPressed: editor.agentRunning
                      ? null
                      : () => _confirmClear(context, notifier),
                ),
              ],
            ),
          ),
          // Error banner — only when there's room (expanded state).
          if (expanded && editor.lastError != null)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.symmetric(horizontal: 12),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: scheme.errorContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(Icons.error_outline,
                      size: 16, color: scheme.onErrorContainer),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      editor.lastError!,
                      style: TextStyle(
                          fontSize: 12, color: scheme.onErrorContainer),
                      maxLines: 5,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.refresh, size: 16),
                    tooltip: '重试',
                    onPressed: editor.agentRunning
                        ? null
                        : () {
                            final lastUser = messages.lastWhere(
                              (m) => m.role == MessageRole.user,
                              orElse: () => Message(
                                  id: '',
                                  role: MessageRole.user,
                                  turnId: '',
                                  createdAt: 0),
                            );
                            if (lastUser.id.isNotEmpty) {
                              notifier.loadMessageForEdit(lastUser.id);
                              _send();
                            }
                          },
                  ),
                ],
              ),
            ),
          // Body: a Stack so the composer can be pinned to the bottom edge and
          // smoothly clipped into view as the panel grows — instead of popping
          // in/out at a height threshold. The message list fills the space
          // above the composer; when the panel is collapsed below header +
          // composer, the composer slides out under the Stack's clip (no flex
          // overflow, since the Column is just header [+banner] + Expanded).
          Expanded(
            child: Stack(
              clipBehavior: Clip.hardEdge,
              children: [
                // Messages (or the empty placeholder), padded at the bottom so
                // the last item clears the pinned composer.
                Positioned.fill(
                  child: messages.isEmpty && streaming.isEmpty
                      ? Center(
                          child: Text(
                            '向 Agent 发送消息来开始写作…',
                            style: TextStyle(color: scheme.onSurfaceVariant),
                          ),
                        )
                      : NotificationListener<UserScrollNotification>(
                          onNotification: _onUserScroll,
                          child: _TurnList(
                            controller: _scroll,
                            bottomPadding: composerH + 8,
                          ),
                        ),
                ),
                // Jump-to-bottom button: sits just above the composer; only
                // meaningful in the expanded state. Toggled via opacity (not
                // conditionally rendered) so showing/hiding doesn't re-lay-out
                // the ListView and "jolt" the content.
                if (expanded)
                  Positioned(
                    right: 12,
                    bottom: composerH + 8,
                    child: IgnorePointer(
                      ignoring: !_showJumpButton,
                      child: AnimatedOpacity(
                        duration: const Duration(milliseconds: 150),
                        curve: Curves.easeOut,
                        opacity: _showJumpButton ? 1 : 0,
                        child: _JumpToBottomButton(
                          onTap: _jumpToBottom,
                        ),
                      ),
                    ),
                  ),
                // Composer pinned to the bottom edge. When the panel is too
                // short to show it (fully-collapsed = header only), it's
                // clipped by the Stack instead of vanishing abruptly — so it
                // slides in/out smoothly as the panel is dragged.
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: _Composer(
                    key: _composerKey,
                    content: editor.draftContent,
                    running: editor.agentRunning,
                    editing: editor.editingMessageId != null,
                    hasSelection: editor.selectedParagraphIds.isNotEmpty,
                    onSend: _send,
                    onChanged: (c) =>
                        ref.read(editorStateProvider.notifier).setDraftContent(c),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _confirmClear(BuildContext context, EditorStateNotifier notifier) {
    showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空上下文'),
        content: const Text('将清除当前会话的消息历史，但已写入的文本会保留。是否继续？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('清空')),
        ],
      ),
    ).then((ok) {
      if (ok == true) notifier.clearContext();
    });
  }
}

/// The rounded input composer. Left button = model switcher; right = send.
/// The text area is a rich-text editor: typed text runs interleaved with
/// inline reference badges (selected paragraph ranges). Refs are inserted by
/// the "+" button (when paragraphs are selected) at the end of the trailing
/// text run; backspace on an empty trailing run removes the preceding badge.
/// The rounded input composer. A true rich-text editor: a TextField whose
/// controller ([RichTextEditingController]) renders inline `@@\${<json>}\$@@`
/// tokens as badge WidgetSpans while keeping the tokenized string as the
/// underlying value. Left button = model switcher; + = insert selected
/// paragraphs as a ref badge at the cursor; right = send.
class _Composer extends ConsumerStatefulWidget {
  final String content;
  final bool running;
  final bool editing;
  final bool hasSelection;
  final VoidCallback onSend;
  final void Function(String content) onChanged;
  const _Composer({
    super.key,
    required this.content,
    required this.running,
    required this.editing,
    required this.hasSelection,
    required this.onSend,
    required this.onChanged,
  });

  @override
  ConsumerState<_Composer> createState() => _ComposerState();
}

class _ComposerState extends ConsumerState<_Composer> {
  late final RichTextEditingController _ctrl;

  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _ctrl = RichTextEditingController(
      richText: widget.content,
      tokenBuilder: _buildBadge,
    );
    _ctrl.addListener(_onChanged);
    _focus.onKeyEvent = _onKey;
  }

  Widget _buildBadge(RichToken t) {
    return RefBadge(
      token: t,
      closable: true,
      onTap: () => _showRefContent(t),
      onClose: () => _ctrl.removeTokenWhere((x) => identical(x, t)),
    );
  }

  void _showRefContent(RichToken t) {
    final scheme = Theme.of(context).colorScheme;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.bookmark, size: 18, color: scheme.primary),
            const SizedBox(width: 6),
            Text(t.label),
          ],
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: SelectableText(
              t.content.isEmpty ? '（无内容）' : t.content,
              style: TextStyle(
                  fontSize: 13,
                  height: 1.5,
                  fontFamily: 'monospace',
                  color: scheme.onSurface),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  void _insertRef() {
    final notifier = ref.read(editorStateProvider.notifier);
    final token = notifier.buildRefTokenForSelection();
    if (token == null) return;
    _ctrl.insertToken(token);
    // insertToken already notified → _onChanged reported the new draft.
    _focus.requestFocus();
  }

  void _onChanged() {
    // Suppress the listener-driven report while we are programmatically
    // applying an external value (in didUpdateWidget) — otherwise the
    // controller's notifyListeners would write back to the provider during
    // the widget build and throw "modified a provider while building".
    if (_suppressNotify) return;
    widget.onChanged(_ctrl.toRichText());
  }

  bool _suppressNotify = false;

  @override
  void didUpdateWidget(covariant _Composer oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Sync the external draft into the controller when they diverge — e.g.
    // the state cleared draftContent='' on send, or loaded a message for edit.
    // Deferred to a post-frame callback so that writing the controller value
    // (which fires notifyListeners) does not happen synchronously inside a
    // build pass, which would re-enter the provider and crash.
    if (widget.content != _ctrl.toRichText()) {
      final offset = _ctrl.selection.baseOffset;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        // Re-check: the user may have typed in the meantime.
        if (widget.content == _ctrl.toRichText()) return;
        _suppressNotify = true;
        _ctrl.setRichText(widget.content);
        final len = _ctrl.text.length;
        final pos = offset.clamp(0, len).toInt();
        _ctrl.selection = TextSelection.collapsed(offset: pos);
        _suppressNotify = false;
      });
    }
  }

  @override
  void dispose() {
    _ctrl.removeListener(_onChanged);
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Enter / Ctrl+Enter send (read from prefs); backspace just before a
  /// token is nudged to skip over it (so we don\'t split a token).
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final isEnter = event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter;
    if (isEnter) {
      final behavior = ref.read(sendBehaviorProvider);
      final ctrl = HardwareKeyboard.instance.isControlPressed ||
          HardwareKeyboard.instance.isMetaPressed;
      final shouldSend =
          behavior == SendBehavior.enterToSend ? !ctrl : ctrl;
      if (shouldSend) {
        widget.onSend();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final providers = ref.watch(providerConfigListProvider).valueOrNull ?? [];
    final activeId = ref.watch(activeProviderIdProvider).valueOrNull;
    final active = ref.watch(activeProviderConfigProvider);

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 14),
      child: Container(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: scheme.outlineVariant, width: 0.8),
        ),
        padding: const EdgeInsets.fromLTRB(10, 8, 8, 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _ctrl,
              focusNode: _focus,
              minLines: 1,
              maxLines: 6,
              style: TextStyle(color: scheme.onSurface, fontSize: 14),
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                isCollapsed: true,
                contentPadding:
                    const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
                hintText: widget.editing ? '编辑消息…' : '给 AI 发消息…',
                hintStyle: TextStyle(color: scheme.onSurfaceVariant),
                border: InputBorder.none,
              ),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                _ModelSwitcher(
                  providers: providers,
                  activeId: activeId,
                  active: active,
                  onChanged: (id) =>
                      ref.read(activeProviderIdProvider.notifier).set(id),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.add, size: 18),
                  tooltip: widget.hasSelection ? '插入选段' : '无选中段落',
                  color: widget.hasSelection
                      ? scheme.primary
                      : scheme.onSurfaceVariant,
                  onPressed: widget.hasSelection ? _insertRef : null,
                ),
                _SendButton(running: widget.running, onTap: widget.onSend),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _TurnList extends ConsumerWidget {
  final ScrollController controller;
  /// Extra bottom padding so the last item clears the pinned composer overlay.
  final double bottomPadding;
  const _TurnList({required this.controller, this.bottomPadding = 8});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(editorStateProvider.notifier);
    // Watch only the slices this list actually depends on, so a draft edit
    // (which changes EditorState.draftContent and rebuilds the pane above)
    // does NOT rebuild the whole message list.
    final committed = ref.watch(
        editorStateProvider.select((s) => s.conversation.messages));
    final streaming =
        ref.watch(editorStateProvider.select((s) => s.streamingMessages));
    final agentRunning =
        ref.watch(editorStateProvider.select((s) => s.agentRunning));

    final streamingActive = streaming.isNotEmpty &&
        agentRunning &&
        streaming.last.role == MessageRole.assistant;
    final isStreaming = streamingActive && streaming.isNotEmpty;
    final streamingTurnId = streaming.isNotEmpty
        ? streaming.first.turnId
        : null;

    // Build ordered list of clusters preserving insertion order.
    final order = <String>[];
    final byTurn = <String, List<Message>>{};
    for (final m in [...committed, ...streaming]) {
      (byTurn[m.turnId] ??= []).add(m);
      if (!order.contains(m.turnId)) order.add(m.turnId);
    }

    return ListView.builder(
      controller: controller,
      padding: EdgeInsets.fromLTRB(12, 8, 12, bottomPadding),
      itemCount: order.length,
      itemBuilder: (context, i) {
        final turnId = order[i];
        final msgs = byTurn[turnId]!;
        final thisTurnStreaming = isStreaming && turnId == streamingTurnId;
        return _TurnCluster(
          messages: msgs,
          streaming: thisTurnStreaming,
          onRetry: () => notifier.retryTurn(turnId),
          onDelete: () => notifier.deleteTurn(turnId),
          onRevert: () => notifier.revertTurn(turnId),
          onEdit: () => notifier.editTurn(turnId),
        );
      },
    );
  }
}

/// One turn cluster: the user message bubble + its assistant/tool replies,
/// each carrying its own per-message action chips (no separate action bar).
class _TurnCluster extends ConsumerWidget {
  final List<Message> messages;
  final bool streaming;
  final VoidCallback onRetry;
  final VoidCallback onDelete;
  final VoidCallback onRevert;
  final VoidCallback onEdit;
  const _TurnCluster({
    required this.messages,
    required this.streaming,
    required this.onRetry,
    required this.onDelete,
    required this.onRevert,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final running =
        ref.watch(editorStateProvider.select((s) => s.agentRunning));
    // Build a map of toolCallId -> result content for pairing.
    final resultByToolCall = <String, String>{};
    for (final m in messages) {
      if (m.role == MessageRole.tool && m.toolCallId != null) {
        resultByToolCall[m.toolCallId!] = m.content;
      }
    }

    final children = <Widget>[];
    for (var i = 0; i < messages.length; i++) {
      final m = messages[i];
      if (m.role == MessageRole.tool) {
        continue; // tool results are merged into the caller's ToolCallBlock
      }
      // Assistant message: the model emits text first, then any tool calls, so
      // render the bubble first and the tool-call blocks after it. Tool result
      // messages in between are skipped above.
      final isLastAssistant = m.role == MessageRole.assistant &&
          i == messages.lastIndexWhere((x) => x.role == MessageRole.assistant);
      children.add(MessageTile(
        key: ValueKey(m.id),
        message: m,
        streaming: streaming && i == messages.length - 1,
        // User messages: copy / edit / retry / delete.
        // Assistant messages: copy / retry / revert.
        // Only the final assistant message in a turn carries the chips;
        // earlier assistant fragments (rare) stay bare.
        onCopy: m.role == MessageRole.user
            ? () {
                // Render ref tokens as their readable label instead of raw
                // @@${...}$@@ markup.
                final text = parseRich(m.content)
                    .map((p) => p is TextPiece
                        ? p.text
                        : (p is TokenPiece ? p.token.label : ''))
                    .join();
                Clipboard.setData(ClipboardData(text: text));
              }
            : (m.role == MessageRole.assistant && isLastAssistant
                ? () {
                    final text = m.content;
                    Clipboard.setData(ClipboardData(text: text));
                  }
                : null),
        // Mutating actions are disabled while the agent is running (mirrors the
        // old shared action bar's `running` guard).
        onEdit: !running && m.role == MessageRole.user ? onEdit : null,
        onRetry: !running && (m.role == MessageRole.user || isLastAssistant)
            ? onRetry
            : null,
        onRevert: !running && m.role == MessageRole.assistant && isLastAssistant
            ? onRevert
            : null,
        onDelete: !running && m.role == MessageRole.user ? onDelete : null,
      ));
      if (m.role == MessageRole.assistant) {
        // ask_user only becomes interactive once the loop has actually paused
        // for it — i.e. its callId is in pendingAskUserIds. Before that the
        // tool-call arguments may still be streaming in (the `questions` array
        // incomplete), and rendering AskUserCard mid-stream throws a RangeError
        // (states list sized for a stale spec). While still streaming we render
        // the generic ToolCallBlock placeholder instead.
        final pendingAsk =
            ref.watch(editorStateProvider.select((s) => s.pendingAskUserIds));
        for (final tc in m.toolCalls) {
          if (tc.name == 'ask_user') {
            final result = resultByToolCall[tc.id];
            if (result != null) {
              children.add(AskUserAnswered(
                key: ValueKey('au_${tc.id}'),
                call: tc,
                resultContent: result,
              ));
            } else if (pendingAsk.contains(tc.id)) {
              final spec = AskUserSpec.tryParse(tc);
              if (spec != null) {
                children.add(AskUserCard(
                  key: ValueKey('au_${tc.id}'),
                  call: tc,
                  spec: spec,
                ));
              }
            } else {
              // Args still streaming — show the placeholder block until the
              // loop pauses and the spec is fully resolved.
              children.add(ToolCallBlock(
                key: ValueKey('tc_${tc.id}'),
                call: tc,
                resultContent: null,
                streaming: true,
              ));
            }
            continue;
          }
          // The tool call is "streaming" (args arriving or result pending)
          // while this turn is the live one AND its result hasn't landed yet.
          // We broaden beyond `streaming` (which only covers the assistant-
          // text phase) with `running` so the block stays expanded through the
          // tool-dispatch phase until each call's own result arrives.
          final callStreaming = (streaming || running) &&
              resultByToolCall[tc.id] == null;
          children.add(ToolCallBlock(
            key: ValueKey('tc_${tc.id}'),
            call: tc,
            resultContent: resultByToolCall[tc.id],
            streaming: callStreaming,
          ));
        }
      }
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }
}

/// A popup-menu button showing the active model name; tapping opens the model
/// list to switch.
class _ModelSwitcher extends StatelessWidget {
  final List<ProviderConfig> providers;
  final String? activeId;
  final ProviderConfig? active;
  final ValueChanged<String> onChanged;
  const _ModelSwitcher(
      {required this.providers,
      required this.activeId,
      required this.active,
      required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PopupMenuButton<String>(
      tooltip: '切换模型',
      onSelected: onChanged,
      itemBuilder: (_) => [
        for (final p in providers)
          PopupMenuItem(
            value: p.id,
            child: Row(children: [
              Icon(p.id == activeId ? Icons.check : Icons.circle_outlined,
                  size: 14,
                  color: p.id == activeId ? scheme.primary : null),
              const SizedBox(width: 6),
              Expanded(child: Text('${p.name} · ${p.modelName}')),
            ]),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.auto_awesome, size: 15, color: scheme.primary),
            const SizedBox(width: 4),
            Text(
              active == null ? '未配置模型' : active!.name,
              style: TextStyle(
                  fontSize: 12, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(width: 2),
            Icon(Icons.keyboard_arrow_down,
                size: 14, color: scheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}

class _JumpToBottomButton extends StatelessWidget {
  final VoidCallback onTap;
  const _JumpToBottomButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.primary,
      elevation: 3,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Tooltip(
          message: '回到底部',
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Icon(
              Icons.keyboard_double_arrow_down_rounded,
              size: 20,
              color: scheme.onPrimary,
            ),
          ),
        ),
      ),
    );
  }
}

class _SendButton extends StatelessWidget {
  final bool running;
  final VoidCallback onTap;
  const _SendButton({required this.running, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // While running, the button becomes a stop affordance (still tappable so
    // the user can abort the in-progress turn); otherwise it sends.
    final color = running ? scheme.error : scheme.primary;
    return Tooltip(
      message: running ? '停止生成' : '发送',
      child: Material(
        color: color,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Icon(
              running ? Icons.stop_rounded : Icons.arrow_upward,
              size: 18,
              color: running ? scheme.onError : scheme.onPrimary,
            ),
          ),
        ),
      ),
    );
  }
}
