import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/llm/llm_client.dart';
import '../../../domain/conversation.dart' show Message, MessageRole;
import '../../../domain/rich_text.dart';
import '../../../state/editor_state.dart';
import '../../../state/providers.dart';
import 'message_tile.dart';
import 'ref_badge.dart';
import 'rich_text_controller.dart';

/// Lower pane: a resizable conversation panel + a redesigned input composer.
/// Errors surface inline; the composer's left button opens a model switcher;
/// Enter / Ctrl+Enter send behavior is configurable in settings.
class AgentPane extends ConsumerStatefulWidget {
  final EditorState editor;
  const AgentPane({super.key, required this.editor});

  @override
  ConsumerState<AgentPane> createState() => _AgentPaneState();
}

class _AgentPaneState extends ConsumerState<AgentPane> {
  final _scroll = ScrollController();
  bool _autoScroll = true;
  bool _showJumpButton = false;

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
  /// doesn't thrash on/off when the user idles near the boundary — that
  /// thrash was the source of the "flicker when scrolling up" bug.
  void _onScroll() {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    final distance = pos.maxScrollExtent - pos.pixels;
    final bool atBottom = _autoScroll ? distance < 96 : distance < 32;
    final bool showButton = !_autoScroll;
    bool changed = false;
    if (atBottom != _autoScroll) {
      _autoScroll = atBottom;
      _showJumpButton = !atBottom;
      changed = true;
    } else if (showButton != _showJumpButton) {
      _showJumpButton = showButton;
      changed = true;
    }
    if (changed) setState(() {});
  }

  void _scrollToBottom() {
    if (!_autoScroll) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients || !_autoScroll) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
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
    if (streamingActive) _scrollToBottom();

    final scheme = Theme.of(context).colorScheme;

    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
      ),
      child: Column(
        children: [
          // Header.
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              children: [
                Icon(Icons.auto_awesome, size: 16, color: scheme.primary),
                const SizedBox(width: 6),
                Text('Agent', style: Theme.of(context).textTheme.titleSmall),
                const Spacer(),
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
          // Error banner.
          if (editor.lastError != null)
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
          const SizedBox(height: 2),
          // Messages, grouped by turn (user msg + its assistant/tool replies).
          Expanded(
            child: messages.isEmpty && streaming.isEmpty
                ? Center(
                    child: Text(
                      '向 Agent 发送消息来开始写作…',
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                  )
                : Stack(
                    children: [
                      _TurnList(
                        controller: _scroll,
                        committed: messages,
                        streaming: streaming,
                        streamingActive: streamingActive,
                      ),
                      // Jump-to-bottom button: always in the tree, toggled via
                      // opacity rather than conditionally rendered, so showing/
                      // hiding it doesn't change the Stack's child structure
                      // (which re-laid-out the ListView and made the content
                      // "jolt" each time the button appeared).
                      Positioned(
                        right: 12,
                        bottom: 8,
                        child: IgnorePointer(
                          ignoring: !_showJumpButton,
                          child: AnimatedOpacity(
                            duration:
                                const Duration(milliseconds: 150),
                            curve: Curves.easeOut,
                            opacity: _showJumpButton ? 1 : 0,
                            child: _JumpToBottomButton(
                              onTap: _jumpToBottom,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
          ),
          // Composer.
          _Composer(
            content: editor.draftContent,
            running: editor.agentRunning,
            editing: editor.editingMessageId != null,
            hasSelection: editor.selectedParagraphIds.isNotEmpty,
            onSend: _send,
            onChanged: (c) =>
                ref.read(editorStateProvider.notifier).setDraftContent(c),
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
  final List<Message> committed;
  final List<Message> streaming;
  final bool streamingActive;
  const _TurnList({
    required this.controller,
    required this.committed,
    required this.streaming,
    required this.streamingActive,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(editorStateProvider.notifier);
    final editingTurnId =
        ref.watch(editorStateProvider).editingMessageId;

    // Build ordered list of clusters preserving insertion order.
    final order = <String>[];
    final byTurn = <String, List<Message>>{};
    for (final m in [...committed, ...streaming]) {
      (byTurn[m.turnId] ??= []).add(m);
      if (!order.contains(m.turnId)) order.add(m.turnId);
    }

    final isStreaming = streamingActive && streaming.isNotEmpty;
    final streamingTurnId = streaming.isNotEmpty
        ? streaming.first.turnId
        : null;

    return ListView.builder(
      controller: controller,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      itemCount: order.length,
      itemBuilder: (context, i) {
        final turnId = order[i];
        final msgs = byTurn[turnId]!;
        final thisTurnStreaming = isStreaming && turnId == streamingTurnId;
        return _TurnCluster(
          messages: msgs,
          streaming: thisTurnStreaming,
          showActions: !thisTurnStreaming,
          editingThisTurn: editingTurnId != null &&
              msgs.any((m) => m.id == editingTurnId),
          onRetry: () => notifier.retryTurn(turnId),
          onDelete: () => notifier.deleteTurn(turnId),
          onRevert: () => notifier.revertTurn(turnId),
          onEdit: () => notifier.editTurn(turnId),
          onCopy: () {
            final assistantText = msgs
                .where((m) => m.role == MessageRole.assistant)
                .map((m) => m.content)
                .join('\n\n');
            Clipboard.setData(ClipboardData(text: assistantText));
          },
        );
      },
    );
  }
}

/// One turn cluster: the user message bubble + its assistant/tool replies,
/// followed by a shared action bar (right-aligned mini buttons).
class _TurnCluster extends ConsumerWidget {
  final List<Message> messages;
  final bool streaming;
  final bool showActions;
  final bool editingThisTurn;
  final VoidCallback onRetry;
  final VoidCallback onDelete;
  final VoidCallback onRevert;
  final VoidCallback onEdit;
  final VoidCallback onCopy;
  const _TurnCluster({
    required this.messages,
    required this.streaming,
    required this.showActions,
    required this.editingThisTurn,
    required this.onRetry,
    required this.onDelete,
    required this.onRevert,
    required this.onEdit,
    required this.onCopy,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final running = ref.watch(editorStateProvider).agentRunning;
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
      children.add(MessageTile(
        key: ValueKey(m.id),
        message: m,
        streaming: streaming && i == messages.length - 1,
      ));
      if (m.role == MessageRole.assistant) {
        for (final tc in m.toolCalls) {
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
    if (showActions) {
      children.add(_TurnActionBar(
        running: running,
        editing: editingThisTurn,
        onRetry: onRetry,
        onDelete: onDelete,
        onRevert: onRevert,
        onEdit: onEdit,
        onCopy: onCopy,
      ));
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

/// Right-aligned mini icon buttons shared by a whole turn.
class _TurnActionBar extends ConsumerWidget {
  final bool running;
  final bool editing;
  final VoidCallback onRetry;
  final VoidCallback onDelete;
  final VoidCallback onRevert;
  final VoidCallback onEdit;
  final VoidCallback onCopy;
  const _TurnActionBar({
    required this.running,
    required this.editing,
    required this.onRetry,
    required this.onDelete,
    required this.onRevert,
    required this.onEdit,
    required this.onCopy,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    Widget btn(IconData icon, String tip, VoidCallback? onTap,
            {Color? color}) =>
        Tooltip(
          message: tip,
          child: InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: running ? null : onTap,
            child: Padding(
              padding: const EdgeInsets.all(5),
              child: Icon(icon, size: 15, color: color ?? scheme.onSurfaceVariant),
            ),
          ),
        );

    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          btn(Icons.content_copy, '复制回复', onCopy),
          const SizedBox(width: 2),
          editing
              ? btn(Icons.close, '取消编辑',
                  () => ref.read(editorStateProvider.notifier).clearDraft(),
                  color: scheme.primary)
              : btn(Icons.edit_outlined, '编辑', onEdit),
          const SizedBox(width: 2),
          btn(Icons.refresh, '重试', onRetry),
          const SizedBox(width: 2),
          btn(Icons.undo, '撤回', onRevert),
          const SizedBox(width: 2),
          btn(Icons.delete_outline, '删除', onDelete),
        ],
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
