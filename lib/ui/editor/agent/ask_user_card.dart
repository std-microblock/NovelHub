import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../domain/conversation.dart';
import '../../../state/providers.dart' show editorStateProvider;

/// One question within an `ask_user` call. A call may carry several of these
/// (the `questions` array); when absent the legacy flat form is normalized
/// into a single-item list.
class AskUserQuestion {
  final String question;
  final String? header;
  final List<String> options;
  final bool multiSelect;
  final bool allowOther;

  const AskUserQuestion({
    required this.question,
    this.header,
    required this.options,
    required this.multiSelect,
    required this.allowOther,
  });

  /// Fill-in mode: no options given.
  bool get isFillIn => options.isEmpty;
}

/// Parsed view of an `ask_user` tool-call's arguments. Holds one or more
/// [AskUserQuestion]s; [isMulti] is true when the call declared several and
/// the card should render a tabbed layout.
class AskUserSpec {
  final List<AskUserQuestion> questions;

  const AskUserSpec(this.questions);

  bool get isMulti => questions.length > 1;
  bool get isEmpty => questions.isEmpty;

  static AskUserSpec? tryParse(ToolCall call) {
    if (call.name != 'ask_user') return null;
    Map<String, dynamic>? args;
    try {
      if (call.arguments.trim().isNotEmpty) {
        args = (jsonDecode(call.arguments) as Map).cast<String, dynamic>();
      }
    } catch (_) {
      args = null;
    }

    final qs = <AskUserQuestion>[];
    final rawQuestions = args?['questions'];
    if (rawQuestions is List) {
      for (final q in rawQuestions) {
        if (q is! Map) continue;
        final parsed = _parseQuestion(q.cast<String, dynamic>());
        if (parsed != null) qs.add(parsed);
      }
    }

    if (qs.isEmpty) {
      if (call.arguments.trim().isEmpty) return null;
      qs.add(const AskUserQuestion(
        question: '（问题加载中…）',
        options: [],
        multiSelect: false,
        allowOther: false,
      ));
    }
    return AskUserSpec(qs);
  }

  static AskUserQuestion? _parseQuestion(Map<String, dynamic> m) {
    final question = (m['question'] as String?) ?? '';
    if (question.isEmpty && m.isEmpty) return null;
    final options = ((m['options'] as List?) ?? [])
        .map((e) => e.toString())
        .toList(growable: false);
    return AskUserQuestion(
      question: question.isEmpty ? '（问题加载中…）' : question,
      header: m['header'] as String?,
      options: options,
      multiSelect: (m['multi_select'] as bool?) ?? false,
      allowOther: (m['allow_other'] as bool?) ?? false,
    );
  }
}

/// The interactive card shown when an `ask_user` tool call is awaiting the
/// user. Renders one of three modes per question:
///   - fill-in (no options) → a TextField;
///   - single-select → radio list;
///   - multi-select → checkbox list.
/// When [AskUserQuestion.allowOther] is set, an extra "其他" row with a
/// TextField is appended. When the spec carries several questions they are
/// presented as tabs (one per question); a single "提交" returns all answers.
/// On submit/skip it calls back into [EditorStateNotifier].
class AskUserCard extends ConsumerStatefulWidget {
  final ToolCall call;
  final AskUserSpec spec;

  const AskUserCard({
    super.key,
    required this.call,
    required this.spec,
  });

  @override
  ConsumerState<AskUserCard> createState() => _AskUserCardState();
}

class _AskUserCardState extends ConsumerState<AskUserCard> {
  final List<_QState> _states = [];
  int _index = 0;

  @override
  void initState() {
    super.initState();
    _syncStates();
  }

  @override
  void didUpdateWidget(covariant AskUserCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The spec can change if the call args resolve further after the card is
    // first mounted (edge case while the loop flips to pending). Keep the
    // per-question state list the same length as the spec, reusing existing
    // state where the question text matches so the user's in-progress answers
    // survive.
    _syncStates();
    if (_index >= widget.spec.questions.length) _index = 0;
  }

  void _syncStates() {
    final qs = widget.spec.questions;
    while (_states.length < qs.length) {
      _states.add(_QState());
    }
    while (_states.length > qs.length) {
      _states.removeLast().dispose();
    }
  }

  @override
  void dispose() {
    for (final s in _states) {
      s.dispose();
    }
    super.dispose();
  }

  bool get _canSubmit => _states.every((s) => s.canSubmit);

  void _submit() {
    final notifier = ref.read(editorStateProvider.notifier);
    final answer = [
      for (var i = 0; i < widget.spec.questions.length; i++)
        _states[i].buildAnswerMap(widget.spec.questions[i]),
    ];
    notifier.answerAskUser(widget.call.id, answer);
  }

  void _skip() {
    ref.read(editorStateProvider.notifier).skipAskUser(widget.call.id);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final spec = widget.spec;
    // Match the assistant message bubble: surfaceContainerHigh bg, onSurface
    // text. (tertiaryContainer renders an unrelated yellow on this theme.)
    final bg = scheme.surfaceContainerHigh;
    return Container(
      constraints: const BoxConstraints(maxWidth: 560),
      margin: const EdgeInsets.only(top: 4, bottom: 2),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (spec.isMulti) ...[
            _tabBar(scheme),
            const SizedBox(height: 8),
          ],
          // IndexedStack instead of TabBarView/PageView: the latter's viewport
          // + animation ticker perturbs the same-frame layout/scheduler timing
          // of the streaming markdown's selection proxy on screen and triggered
          // a NEEDS-LAYOUT crash. IndexedStack lays out only the active child
          // with no extra Ticker.
          IndexedStack(
            index: _index,
            children: [
              for (var i = 0; i < spec.questions.length; i++)
                _questionBody(scheme, spec.questions[i], _states[i]),
            ],
          ),
          if (spec.isMulti) ...[
            const SizedBox(height: 4),
            _tabDots(scheme),
          ],
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              if (spec.isMulti && _index > 0)
                TextButton(
                  onPressed: () => setState(() => _index--),
                  child: const Text('上一题'),
                )
              else
                const SizedBox.shrink(),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextButton(
                    onPressed: _skip,
                    child: const Text('跳过'),
                  ),
                  const SizedBox(width: 6),
                  FilledButton(
                    onPressed: _canSubmit ? _submit : null,
                    child: Text(spec.isMulti ? '提交全部' : '提交'),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _tabBar(ColorScheme scheme) {
    final spec = widget.spec;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(6),
      ),
      padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 2),
      child: Row(
        children: [
          for (var i = 0; i < spec.questions.length; i++)
            Expanded(
              child: _tabChip(
                scheme,
                label: _tabLabel(spec.questions[i], i),
                selected: i == _index,
                onTap: () => setState(() => _index = i),
              ),
            ),
        ],
      ),
    );
  }

  Widget _tabChip(ColorScheme scheme,
      {required String label, required bool selected, required VoidCallback onTap}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
        decoration: BoxDecoration(
          color: selected
              ? scheme.primary.withValues(alpha: 0.14)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(4),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 12,
            color: selected
                ? scheme.primary
                : scheme.onSurface.withValues(alpha: 0.7),
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
          ),
        ),
      ),
    );
  }

  String _tabLabel(AskUserQuestion q, int i) =>
      (q.header != null && q.header!.trim().isNotEmpty)
          ? q.header!
          : '问题 ${i + 1}';

  /// A row of dots under the tab view showing which questions are answered.
  Widget _tabDots(ColorScheme scheme) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < _states.length; i++) ...[
          if (i > 0) const SizedBox(width: 6),
          AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              color: _states[i].canSubmit
                  ? scheme.primary
                  : scheme.onSurface.withValues(alpha: 0.25),
              shape: BoxShape.circle,
            ),
          ),
        ],
      ],
    );
  }

  Widget _questionBody(ColorScheme scheme, AskUserQuestion q, _QState s) {
    s.isFillIn = q.isFillIn;
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (q.header != null && q.header!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(q.header!,
                    style: TextStyle(
                        fontSize: 10,
                        color: scheme.primary,
                        fontWeight: FontWeight.w600)),
              ),
            ),
          Text(q.question,
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: scheme.onSurface)),
          const SizedBox(height: 8),
          _buildOptions(scheme, q, s),
          if (q.allowOther && !q.isFillIn) ...[
            const SizedBox(height: 4),
            _otherRow(scheme, q, s),
          ],
        ],
      ),
    );
  }

  Widget _buildOptions(ColorScheme scheme, AskUserQuestion q, _QState s) {
    if (q.isFillIn) {
      return TextField(
        controller: s.fillInCtrl,
        minLines: 1,
        maxLines: 4,
        autofocus: widget.spec.questions.indexOf(q) == 0,
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(
          isDense: true,
          hintText: '输入你的回答…',
          filled: true,
          fillColor: scheme.surface,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
        ),
      );
    }
    if (q.multiSelect) {
      return Column(
        children: [
          for (final opt in q.options)
            _checkRow(
              scheme,
              label: opt,
              checked: s.multi.contains(opt),
              onTap: () => setState(() {
                if (s.multi.contains(opt)) {
                  s.multi.remove(opt);
                } else {
                  s.multi.add(opt);
                }
              }),
            ),
        ],
      );
    }
    // single-select
    return Column(
      children: [
        for (final opt in q.options)
          _radioRow(
            scheme,
            label: opt,
            selected: s.single == opt,
            onTap: () => setState(() {
              s.single = opt;
              s.otherChosen = false;
            }),
          ),
      ],
    );
  }

  Widget _checkRow(ColorScheme scheme,
      {required String label,
      required bool checked,
      required VoidCallback onTap}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 2),
        child: Row(
          children: [
            Icon(
              checked ? Icons.check_box : Icons.check_box_outline_blank,
              size: 18,
              color: scheme.primary,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(label,
                  style:
                      TextStyle(fontSize: 13, color: scheme.onSurface)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _radioRow(ColorScheme scheme,
      {required String label,
      required bool selected,
      required VoidCallback onTap}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 2),
        child: Row(
          children: [
            Icon(
              selected ? Icons.radio_button_checked : Icons.radio_button_off,
              size: 18,
              color: scheme.primary,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(label,
                  style:
                      TextStyle(fontSize: 13, color: scheme.onSurface)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _otherRow(ColorScheme scheme, AskUserQuestion q, _QState s) {
    final isMulti = q.multiSelect;
    return InkWell(
      onTap: () => setState(() {
        if (isMulti) {
          s.otherChosen = !s.otherChosen;
        } else {
          s.otherChosen = true;
          s.single = null;
        }
      }),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 2),
            child: Row(
              children: [
                Icon(
                  isMulti
                      ? (s.otherChosen
                          ? Icons.check_box
                          : Icons.check_box_outline_blank)
                      : (s.otherChosen
                          ? Icons.radio_button_checked
                          : Icons.radio_button_off),
                  size: 18,
                  color: scheme.primary,
                ),
                const SizedBox(width: 8),
                Text('其他',
                    style: TextStyle(
                        fontSize: 13, color: scheme.onSurface)),
              ],
            ),
          ),
          if (s.otherChosen)
            Padding(
              padding: const EdgeInsets.only(left: 26, top: 2),
              child: TextField(
                controller: s.otherCtrl,
                minLines: 1,
                maxLines: 3,
                autofocus: true,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: '输入…',
                  filled: true,
                  fillColor: scheme.surface,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6)),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Mutable answer state for a single question within a (possibly multi)
/// `ask_user` card.
class _QState {
  final TextEditingController fillInCtrl = TextEditingController();
  final TextEditingController otherCtrl = TextEditingController();
  String? single; // selected option label for single-select
  final Set<String> multi = {}; // selected option labels for multi-select
  bool otherChosen = false; // "其他" row active

  bool get canSubmit {
    if (isFillIn) return fillInCtrl.text.trim().isNotEmpty;
    if (multi.isNotEmpty) return true;
    if (single != null) return true;
    return otherChosen && otherCtrl.text.trim().isNotEmpty;
  }

  /// Whether the owning question is fill-in mode (no options). Set by the card
  /// at build time so [canSubmit] knows which controller to consult.
  bool isFillIn = false;

  /// Scalar answer for a single-question card (legacy contract):
  /// string for fill-in / single-select, List<String> for multi-select.
  Object buildAnswer(AskUserQuestion q) {
    if (q.isFillIn) return fillInCtrl.text.trim();
    if (q.multiSelect) {
      final list = <String>[...multi];
      if (q.allowOther && otherChosen && otherCtrl.text.trim().isNotEmpty) {
        list.add(otherCtrl.text.trim());
      }
      return list;
    }
    if (q.allowOther && otherChosen && otherCtrl.text.trim().isNotEmpty) {
      return otherCtrl.text.trim();
    }
    return single ?? '';
  }

  /// Per-question answer object for multi-question cards, carrying the
  /// question text so the model can tell which answer maps to which question.
  Map<String, Object?> buildAnswerMap(AskUserQuestion q) {
    return {
      'question': q.question,
      if (q.header != null && q.header!.isNotEmpty) 'header': q.header,
      'answer': buildAnswer(q),
    };
  }

  void dispose() {
    fillInCtrl.dispose();
    otherCtrl.dispose();
  }
}

/// Read-only summary of an answered `ask_user` call. Renders the question(s) +
/// the user's chosen answer(s) (parsed from the tool-result JSON).
class AskUserAnswered extends StatelessWidget {
  final ToolCall call;
  final String resultContent;
  const AskUserAnswered({
    super.key,
    required this.call,
    required this.resultContent,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Map<String, dynamic>? res;
    try {
      if (resultContent.trim().isNotEmpty) {
        res = (jsonDecode(resultContent) as Map).cast<String, dynamic>();
      }
    } catch (_) {
      res = null;
    }
    final answer = res?['answer'];
    final skipped = (res?['skipped'] as bool?) ?? false;
    final cancelled = (res?['cancelled'] as bool?) ?? false;

    final rows = <_AnsweredRow>[];
    if (cancelled) {
      rows.add(const _AnsweredRow(header: null, question: null, text: '已取消'));
    } else if (skipped || answer == null) {
      rows.add(const _AnsweredRow(header: null, question: null, text: '已跳过'));
    } else if (answer is List) {
      for (final item in answer) {
        if (item is Map) {
          rows.add(_AnsweredRow(
            header: item['header'] as String?,
            question: item['question'] as String?,
            text: _answerText(item['answer']),
          ));
        } else {
          rows.add(_AnsweredRow(header: null, question: null, text: item.toString()));
        }
      }
    } else {
      rows.add(_AnsweredRow(header: null, question: null, text: _answerText(answer)));
    }

    return Container(
      constraints: const BoxConstraints(maxWidth: 560),
      margin: const EdgeInsets.only(top: 4, bottom: 2),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) const SizedBox(height: 6),
            _row(scheme, rows[i]),
          ],
        ],
      ),
    );
  }

  Widget _row(ColorScheme scheme, _AnsweredRow r) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (r.header != null && r.header!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Text(r.header!,
                style: TextStyle(
                    fontSize: 10,
                    color: scheme.primary,
                    fontWeight: FontWeight.w600)),
          ),
        if (r.question != null && r.question!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 3),
            child: Text(r.question!,
                style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurface,
                    fontWeight: FontWeight.w500)),
          ),
        Row(
          children: [
            Icon(Icons.check_circle,
                size: 13, color: scheme.primary.withValues(alpha: 0.8)),
            const SizedBox(width: 5),
            Expanded(
              child: Text(r.text,
                  style: TextStyle(
                      fontSize: 13, color: scheme.onSurface)),
            ),
          ],
        ),
      ],
    );
  }

  static String _answerText(Object? answer) {
    if (answer is List) {
      return answer.map((e) => e.toString()).join('、');
    }
    return answer.toString();
  }
}

class _AnsweredRow {
  final String? header;
  final String? question;
  final String text;
  const _AnsweredRow({
    required this.header,
    required this.question,
    required this.text,
  });
}
