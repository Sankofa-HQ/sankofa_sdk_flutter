import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'brand.dart';
import 'branching.dart';
import 'pulse_models.dart';
import 'translator.dart';

/// Pure-Flutter survey renderer. Wraps every supported question kind
/// in Material widgets — Theme.of(context) drives the look so the
/// host app's brand colors apply automatically. Survey-level
/// `theme.primary_color` overrides the seed when present.
///
/// Lifecycle: caller mounts via `showDialog` (or `Navigator.push`
/// for full-screen). The dialog drives the back/next/submit state
/// machine and assembles the [PulseSubmitPayload] on submit.
class SankofaSurveyDialog extends StatefulWidget {
  final PulseSurvey survey;
  final List<PulseBranchingRule> branchingRules;
  final PulseTranslator? translator;
  final Map<String, Object?> initialAnswers;
  final String? initialQuestionId;
  final void Function(Map<String, Object?> answers, String currentQuestionId)? onProgress;
  final void Function(PulseSubmitPayload payload) onSubmit;
  final VoidCallback onDismiss;

  const SankofaSurveyDialog({
    super.key,
    required this.survey,
    this.branchingRules = const [],
    this.translator,
    this.initialAnswers = const {},
    this.initialQuestionId,
    this.onProgress,
    required this.onSubmit,
    required this.onDismiss,
  });

  @override
  State<SankofaSurveyDialog> createState() => _SankofaSurveyDialogState();
}

class _SankofaSurveyDialogState extends State<SankofaSurveyDialog> {
  late final List<PulseQuestion> _questions;
  late final Map<String, Object?> _answers;
  int _index = 0;
  String? _error;

  /// Stack of indices the respondent has visited; used to retrace
  /// Back across skip-logic jumps. We push on every forward step
  /// (whether a fall-through or a branching jump) and pop on Back.
  final List<int> _history = <int>[];

  @override
  void initState() {
    super.initState();
    _questions = [...widget.survey.questions]
      ..sort((a, b) => a.orderIndex.compareTo(b.orderIndex));
    _answers = Map<String, Object?>.from(widget.initialAnswers);
    final initialId = widget.initialQuestionId;
    if (initialId != null) {
      final target = _questions.indexWhere((q) => q.id == initialId);
      if (target >= 0) _index = target;
    }
  }

  PulseQuestion? get _current =>
      _index >= 0 && _index < _questions.length ? _questions[_index] : null;

  bool _hasAnswer(String qid) {
    final v = _answers[qid];
    if (v == null) return false;
    if (v is String) return v.trim().isNotEmpty;
    if (v is List) return v.isNotEmpty;
    if (v is Map) return v.isNotEmpty;
    return true;
  }

  void _goBack() {
    if (_history.isEmpty) return;
    setState(() {
      _index = _history.removeLast();
      _error = null;
    });
  }

  void _goForward() {
    final q = _current;
    if (q == null) return;
    if (q.required && !_hasAnswer(q.id)) {
      setState(() => _error = 'This question is required.');
      return;
    }
    // Ask the branching evaluator first. The Outcome can:
    //  - end the survey early (sentinel)
    //  - jump to a target question id
    //  - fall through (next by order_index)
    final outcome = resolvePulseBranching(
      widget.branchingRules,
      q.id,
      _answers,
    );
    if (outcome.nextQuestionId == pulseBranchingEndOfSurvey) {
      _submit();
      return;
    }
    if (outcome.nextQuestionId.isNotEmpty) {
      final target = _questions.indexWhere((x) => x.id == outcome.nextQuestionId);
      if (target >= 0) {
        setState(() {
          _history.add(_index);
          _index = target;
          _error = null;
        });
        _emitProgress();
        return;
      }
      // Target id not found in this survey — fall through rather
      // than getting stuck. A "skip to a question that no longer
      // exists" is a survey-builder error, not something to crash
      // the host on.
    }
    if (_index == _questions.length - 1) {
      _submit();
    } else {
      setState(() {
        _history.add(_index);
        _index += 1;
        _error = null;
      });
      _emitProgress();
    }
  }

  void _emitProgress() {
    final cb = widget.onProgress;
    if (cb == null) return;
    final q = _current;
    if (q == null) return;
    try {
      cb(Map<String, Object?>.from(_answers), q.id);
    } catch (_) {
      // Host callback errors must never break navigation.
    }
  }

  void _submit() {
    final answers = <String, Object?>{};
    for (final q in _questions) {
      final v = _answers[q.id];
      if (v == null) continue;
      answers[q.id] = v;
    }
    widget.onSubmit(
      PulseSubmitPayload(surveyId: widget.survey.id, answers: answers),
    );
  }

  // ── Theme resolution ───────────────────────────────────────────
  //
  // We honour the seven theme fields on PulseTheme:
  //   primary_color    → accent (buttons, highlights, ratings)
  //   background_color → dialog window background
  //   foreground_color → primary text (title, prompt, answer text)
  //   muted_color      → secondary text (description, helptext)
  //   border_color     → input field outlines
  //   font_family      → TextStyle.fontFamily for every text view
  //   dark_mode        → "auto" / "light" / "dark" — flips the
  //                      built-in palette when the operator's
  //                      explicit colors aren't set; respects
  //                      the system setting on "auto"
  //
  // Each resolver falls back to a sensible default if the wire value
  // is missing or unparseable, so a theme that ships with only
  // `primary_color` set still renders cleanly.

  bool _isDarkPalette(BuildContext context) {
    switch (widget.survey.theme?.darkMode?.toLowerCase()) {
      case 'dark':
        return true;
      case 'light':
        return false;
      default:
        return Theme.of(context).brightness == Brightness.dark;
    }
  }

  Color? _parseHex(String? hex) {
    if (hex == null || hex.isEmpty) return null;
    final cleaned = hex.replaceAll('#', '').trim();
    if (cleaned.length == 6) {
      final v = int.tryParse('FF$cleaned', radix: 16);
      if (v != null) return Color(v);
    } else if (cleaned.length == 8) {
      final v = int.tryParse(cleaned, radix: 16);
      if (v != null) return Color(v);
    }
    return null;
  }

  Color _accent(BuildContext context) {
    return _parseHex(widget.survey.theme?.primaryColor) ??
        (_isDarkPalette(context)
            ? const Color(0xFFFB7185)
            : const Color(0xFFF43F5E));
  }

  Color _background(BuildContext context) {
    return _parseHex(widget.survey.theme?.backgroundColor) ??
        (_isDarkPalette(context)
            ? const Color(0xFF0A0A0A)
            : const Color(0xFFFFFFFF));
  }

  Color _foreground(BuildContext context) {
    return _parseHex(widget.survey.theme?.foregroundColor) ??
        (_isDarkPalette(context)
            ? const Color(0xFFFAFAFA)
            : const Color(0xFF18181B));
  }

  Color _muted(BuildContext context) {
    return _parseHex(widget.survey.theme?.mutedColor) ??
        (_isDarkPalette(context)
            ? const Color(0xFFA1A1AA)
            : const Color(0xFF71717A));
  }

  Color _border(BuildContext context) {
    return _parseHex(widget.survey.theme?.borderColor) ??
        (_isDarkPalette(context)
            ? const Color(0xFF27272A)
            : const Color(0xFFE4E4E7));
  }

  String? _fontFamily() {
    final f = widget.survey.theme?.fontFamily;
    return (f == null || f.isEmpty) ? null : f;
  }

  @override
  Widget build(BuildContext context) {
    final q = _current;
    final isLast = _index == _questions.length - 1;
    final accent = _accent(context);
    final bg = _background(context);
    final fg = _foreground(context);
    final muted = _muted(context);
    // Error red is intentionally NOT theme-resolved — it must always
    // be unmistakable as an error, not blend with the brand.
    final errorColor = _isDarkPalette(context)
        ? const Color(0xFFFCA5A5)
        : const Color(0xFFDC2626);
    final fontFamily = _fontFamily();
    final border = _border(context);
    final progress = _questions.isEmpty
        ? 1.0
        : (_index + 1) / _questions.length;

    final isRtl = pulseLocaleIsRTL(widget.translator?.locale);
    final dialog = Dialog(
      backgroundColor: bg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480, maxHeight: 640),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _header(context, fg: fg, muted: muted, fontFamily: fontFamily),
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 4,
                  valueColor: AlwaysStoppedAnimation<Color>(accent),
                ),
              ),
              const SizedBox(height: 16),
              if (q != null) ...[
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.translator?.questionPrompt(q) ?? q.prompt,
                          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            color: fg,
                            fontFamily: fontFamily,
                          ),
                        ),
                        () {
                          final help =
                              widget.translator?.questionHelptext(q) ?? q.helptext;
                          if (help == null || help.isEmpty) {
                            return const SizedBox.shrink();
                          }
                          return Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              help,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(
                                    color: muted,
                                    fontFamily: fontFamily,
                                  ),
                            ),
                          );
                        }(),
                        const SizedBox(height: 12),
                        _renderInput(context, q, accent),
                      ],
                    ),
                  ),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  style: TextStyle(color: errorColor, fontFamily: fontFamily),
                ),
              ],
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: fg,
                        side: BorderSide(color: border),
                        textStyle: TextStyle(fontFamily: fontFamily),
                      ),
                      onPressed: _history.isNotEmpty ? _goBack : null,
                      child: const Text('Back'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: accent,
                        textStyle: TextStyle(fontFamily: fontFamily),
                      ),
                      onPressed: _goForward,
                      child: Text(isLast ? 'Submit' : 'Next'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _PoweredBySankofa(muted: muted, border: border, fontFamily: fontFamily),
            ],
          ),
        ),
      ),
    );
    // When the survey's resolved translation locale is RTL, force
    // the entire dialog tree into a right-to-left reading order
    // even if the host's MaterialApp/Locale is LTR. This mirrors
    // the Web SDK's `dir="rtl"` attribute on the rendered survey
    // root.
    if (isRtl) {
      return Directionality(textDirection: TextDirection.rtl, child: dialog);
    }
    return dialog;
  }

  Widget _header(
    BuildContext context, {
    required Color fg,
    required Color muted,
    String? fontFamily,
  }) {
    final logoUrl = widget.survey.theme?.logoUrl;
    final showLogo = logoUrl != null && logoUrl.isNotEmpty;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showLogo) ...[
          // 24×24 logo block alongside the survey title. We deliberately
          // avoid networking timeouts on the dialog's first paint —
          // Image.network with errorBuilder shows nothing if the URL
          // is unreachable rather than throwing a default broken-image
          // glyph that would clash with the operator's brand.
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: Image.network(
              logoUrl,
              width: 24,
              height: 24,
              fit: BoxFit.contain,
              errorBuilder: (_, __, ___) => const SizedBox(width: 24, height: 24),
            ),
          ),
          const SizedBox(width: 8),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.translator?.surveyName(widget.survey) ?? widget.survey.name,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: fg,
                  fontFamily: fontFamily,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              () {
                final desc = widget.translator?.surveyDescription(widget.survey)
                    ?? widget.survey.description;
                if (desc == null || desc.isEmpty) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    desc,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: muted,
                      fontFamily: fontFamily,
                    ),
                  ),
                );
              }(),
            ],
          ),
        ),
        IconButton(
          icon: Icon(Icons.close, size: 20, color: muted),
          tooltip: 'Dismiss',
          onPressed: () {
            widget.onDismiss();
            Navigator.of(context).maybePop();
          },
        ),
      ],
    );
  }

  // ── Per-kind renderers ──────────────────────────────────────────

  Widget _renderInput(BuildContext context, PulseQuestion q, Color accent) {
    switch (q.kind) {
      case 'short_text':
        return _renderTextField(q, multiline: false);
      case 'long_text':
        return _renderTextField(q, multiline: true);
      case 'number':
        return _renderNumber(q);
      case 'rating':
        return _renderRating(q, accent);
      case 'nps':
        return _renderNps(q, accent);
      case 'single':
      case 'image_choice':
        return _renderSingle(q, accent);
      case 'multi':
        return _renderMulti(q, accent);
      case 'boolean':
        return _renderBoolean(q);
      case 'slider':
        return _renderSlider(q, accent);
      case 'date':
        return _renderDate(context, q);
      case 'statement':
        return const SizedBox.shrink();
      case 'consent':
        return _renderConsent(q);
      case 'ranking':
        return _renderRanking(q);
      case 'matrix':
        return _renderMatrix(q, accent);
      case 'maxdiff':
        return _renderMaxDiff(q);
      case 'signature':
        return _renderSignature(q);
      case 'file':
      case 'payment':
      default:
        return Text(
          'This question type isn\'t supported on this device yet.',
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        );
    }
  }

  InputDecoration _themedInput(BuildContext context) {
    final border = _border(context);
    return InputDecoration(
      border: OutlineInputBorder(
        borderSide: BorderSide(color: border),
      ),
      enabledBorder: OutlineInputBorder(
        borderSide: BorderSide(color: border),
      ),
      focusedBorder: OutlineInputBorder(
        borderSide: BorderSide(color: _accent(context), width: 2),
      ),
    );
  }

  TextStyle _themedInputStyle(BuildContext context) =>
      TextStyle(color: _foreground(context), fontFamily: _fontFamily());

  Widget _renderTextField(PulseQuestion q, {required bool multiline}) {
    return TextFormField(
      initialValue: _answers[q.id] as String?,
      maxLines: multiline ? 4 : 1,
      style: _themedInputStyle(context),
      keyboardType:
          multiline ? TextInputType.multiline : TextInputType.text,
      onChanged: (v) {
        _answers[q.id] = v.trim().isEmpty ? null : v;
      },
      decoration: _themedInput(context),
    );
  }

  Widget _renderNumber(PulseQuestion q) {
    return TextFormField(
      initialValue: (_answers[q.id] as num?)?.toString(),
      style: _themedInputStyle(context),
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp(r'^\-?\d*\.?\d*$')),
      ],
      onChanged: (v) {
        _answers[q.id] = double.tryParse(v);
      },
      decoration: _themedInput(context),
    );
  }

  Widget _renderRating(PulseQuestion q, Color accent) {
    final min = (q.validation?['min'] as num?)?.toInt() ?? 1;
    final max = (q.validation?['max'] as num?)?.toInt() ?? 5;
    final current = (_answers[q.id] as num?)?.toInt() ?? 0;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var n = min; n <= max; n++)
          IconButton(
            iconSize: 32,
            icon: Icon(
              current >= n ? Icons.star : Icons.star_border,
              color: current >= n ? accent : Colors.grey,
            ),
            onPressed: () => setState(() => _answers[q.id] = n),
          ),
      ],
    );
  }

  Widget _renderNps(PulseQuestion q, Color accent) {
    final current = (_answers[q.id] as num?)?.toInt() ?? -1;
    return Column(
      children: [
        Wrap(
          spacing: 4,
          runSpacing: 4,
          children: [
            for (var n = 0; n <= 10; n++)
              GestureDetector(
                onTap: () => setState(() => _answers[q.id] = n),
                child: Container(
                  width: 32,
                  height: 32,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: current == n ? accent : Colors.grey.shade200,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    '$n',
                    style: TextStyle(
                      color: current == n ? Colors.white : Colors.black87,
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Not at all', style: Theme.of(context).textTheme.bodySmall),
            Text('Extremely', style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ],
    );
  }

  Widget _renderSingle(PulseQuestion q, Color accent) {
    final current = _answers[q.id] as String?;
    final options = q.options ?? const [];
    return RadioGroup<String>(
      groupValue: current,
      onChanged: (v) => setState(() => _answers[q.id] = v),
      child: Column(
        children: [
          for (final opt in options)
            RadioListTile<String>(
              value: opt.key,
              title: Text(widget.translator?.optionLabel(q, opt) ?? opt.label),
              activeColor: accent,
              contentPadding: EdgeInsets.zero,
            ),
        ],
      ),
    );
  }

  Widget _renderMulti(PulseQuestion q, Color accent) {
    final raw = _answers[q.id];
    final current = (raw is List ? raw.cast<String>().toSet() : <String>{});
    final options = q.options ?? const [];
    return Column(
      children: [
        for (final opt in options)
          CheckboxListTile(
            value: current.contains(opt.key),
            title: Text(widget.translator?.optionLabel(q, opt) ?? opt.label),
            activeColor: accent,
            contentPadding: EdgeInsets.zero,
            onChanged: (checked) {
              setState(() {
                if (checked == true) {
                  current.add(opt.key);
                } else {
                  current.remove(opt.key);
                }
                _answers[q.id] = current.toList();
              });
            },
          ),
      ],
    );
  }

  Widget _renderBoolean(PulseQuestion q) {
    final current = _answers[q.id] as bool?;
    return RadioGroup<bool>(
      groupValue: current,
      onChanged: (v) => setState(() => _answers[q.id] = v),
      child: const Row(
        children: [
          Expanded(
            child: RadioListTile<bool>(
              value: true,
              title: Text('Yes'),
              contentPadding: EdgeInsets.zero,
            ),
          ),
          Expanded(
            child: RadioListTile<bool>(
              value: false,
              title: Text('No'),
              contentPadding: EdgeInsets.zero,
            ),
          ),
        ],
      ),
    );
  }

  Widget _renderSlider(PulseQuestion q, Color accent) {
    final min = (q.validation?['min'] as num?)?.toDouble() ?? 0;
    final max = (q.validation?['max'] as num?)?.toDouble() ?? 100;
    final current = (_answers[q.id] as num?)?.toDouble() ?? min;
    final clamped = current.clamp(min, max);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Slider(
          value: clamped.toDouble(),
          min: min,
          max: max,
          activeColor: accent,
          onChanged: (v) => setState(() => _answers[q.id] = v),
        ),
        Center(
          child: Text(
            clamped.toStringAsFixed(0),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    );
  }

  Widget _renderDate(BuildContext context, PulseQuestion q) {
    final raw = _answers[q.id] as String?;
    final shown = raw ?? 'Pick a date…';
    return OutlinedButton(
      onPressed: () async {
        final now = DateTime.now();
        final picked = await showDatePicker(
          context: context,
          initialDate: now,
          firstDate: DateTime(now.year - 100),
          lastDate: DateTime(now.year + 100),
        );
        if (picked != null) {
          setState(() => _answers[q.id] = picked.toIso8601String());
        }
      },
      child: Text(shown),
    );
  }

  Widget _renderConsent(PulseQuestion q) {
    final current = _answers[q.id] as bool? ?? false;
    return CheckboxListTile(
      value: current,
      title: Text(
        widget.translator?.questionHelptext(q) ?? q.helptext ?? 'I agree',
      ),
      contentPadding: EdgeInsets.zero,
      onChanged: (v) => setState(() => _answers[q.id] = v ?? false),
    );
  }

  Widget _renderRanking(PulseQuestion q) {
    final raw = _answers[q.id];
    final order = raw is List ? raw.cast<String>().toList() : <String>[];
    final options = q.options ?? const [];
    // Backfill missing options at the end.
    for (final opt in options) {
      if (!order.contains(opt.key)) order.add(opt.key);
    }
    final labels = {for (final o in options) o.key: o.label};
    return ReorderableListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: order.length,
      buildDefaultDragHandles: true,
      itemBuilder: (context, i) {
        final key = order[i];
        return ListTile(
          key: ValueKey(key),
          contentPadding: EdgeInsets.zero,
          title: Text(labels[key] ?? key),
          trailing: const Icon(Icons.drag_handle),
        );
      },
      onReorder: (oldIndex, newIndex) {
        setState(() {
          if (newIndex > oldIndex) newIndex -= 1;
          final item = order.removeAt(oldIndex);
          order.insert(newIndex, item);
          _answers[q.id] = List<String>.from(order);
        });
      },
    );
  }

  Widget _renderMatrix(PulseQuestion q, Color accent) {
    final rows = (q.validation?['rows'] as List?)
            ?.whereType<Map>()
            .map((m) => MapEntry(
                  m['key']?.toString() ?? '',
                  m['label']?.toString() ?? '',
                ))
            .toList() ??
        const <MapEntry<String, String>>[];
    final scale = (q.validation?['scale'] as List?)
            ?.map((e) => e.toString())
            .toList() ??
        const ['1', '2', '3', '4', '5'];
    final raw = _answers[q.id];
    final current =
        raw is Map ? Map<String, String>.from(raw.cast<String, String>()) : <String, String>{};
    return Column(
      children: [
        for (final row in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Expanded(child: Text(row.value)),
                Wrap(
                  spacing: 4,
                  children: [
                    for (final s in scale)
                      ChoiceChip(
                        label: Text(s),
                        selected: current[row.key] == s,
                        selectedColor: accent.withValues(alpha: 0.18),
                        onSelected: (_) {
                          setState(() {
                            current[row.key] = s;
                            _answers[q.id] = current;
                          });
                        },
                      ),
                  ],
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _renderMaxDiff(PulseQuestion q) {
    final options = q.options ?? const [];
    final raw = _answers[q.id];
    final current = raw is Map<String, dynamic>
        ? Map<String, String?>.from(raw)
        : <String, String?>{'best': null, 'worst': null};
    return Column(
      children: [
        const Text('Pick the best and the worst.', textAlign: TextAlign.left),
        const SizedBox(height: 8),
        for (final opt in options)
          Row(
            children: [
              Expanded(child: Text(widget.translator?.optionLabel(q, opt) ?? opt.label)),
              ChoiceChip(
                label: const Text('Best'),
                selected: current['best'] == opt.key,
                onSelected: (_) {
                  setState(() {
                    if (current['worst'] == opt.key) current['worst'] = null;
                    current['best'] = opt.key;
                    _answers[q.id] = Map<String, dynamic>.from(current);
                  });
                },
              ),
              const SizedBox(width: 4),
              ChoiceChip(
                label: const Text('Worst'),
                selected: current['worst'] == opt.key,
                onSelected: (_) {
                  setState(() {
                    if (current['best'] == opt.key) current['best'] = null;
                    current['worst'] = opt.key;
                    _answers[q.id] = Map<String, dynamic>.from(current);
                  });
                },
              ),
            ],
          ),
      ],
    );
  }

  Widget _renderSignature(PulseQuestion q) {
    return _SignaturePad(
      onChange: (dataUri) {
        _answers[q.id] = dataUri;
      },
    );
  }
}

/// Minimal in-place signature canvas. We render strokes over a
/// transparent white background and emit a base64 PNG data URI on
/// every commit so the answer round-trips unchanged through the
/// JSON serialiser.
class _SignaturePad extends StatefulWidget {
  final ValueChanged<String?> onChange;
  const _SignaturePad({required this.onChange});

  @override
  State<_SignaturePad> createState() => _SignaturePadState();
}

class _SignaturePadState extends State<_SignaturePad> {
  final List<List<Offset>> _strokes = [];
  List<Offset> _current = [];

  Future<void> _commit() async {
    if (_strokes.isEmpty && _current.isEmpty) {
      widget.onChange(null);
      return;
    }
    final recorder = ui.PictureRecorder();
    const size = Size(320, 140);
    final canvas = Canvas(recorder, Offset.zero & size);
    final bg = Paint()..color = Colors.white;
    canvas.drawRect(Offset.zero & size, bg);
    final paint = Paint()
      ..color = Colors.black
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final all = [..._strokes, _current];
    for (final stroke in all) {
      for (var i = 1; i < stroke.length; i++) {
        canvas.drawLine(stroke[i - 1], stroke[i], paint);
      }
    }
    final picture = recorder.endRecording();
    final image = await picture.toImage(size.width.toInt(), size.height.toInt());
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    if (bytes == null) return;
    final encoded = base64Encode(bytes.buffer.asUint8List());
    widget.onChange('data:image/png;base64,$encoded');
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AspectRatio(
          aspectRatio: 16 / 7,
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: Colors.grey.shade300),
              borderRadius: BorderRadius.circular(6),
            ),
            child: GestureDetector(
              onPanStart: (d) {
                setState(() {
                  _current = [d.localPosition];
                });
              },
              onPanUpdate: (d) {
                setState(() {
                  _current.add(d.localPosition);
                });
              },
              onPanEnd: (_) async {
                _strokes.add(List<Offset>.from(_current));
                _current = [];
                await _commit();
              },
              child: CustomPaint(
                painter: _SignaturePainter(_strokes, _current),
                size: Size.infinite,
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: () async {
              setState(() {
                _strokes.clear();
                _current = [];
              });
              widget.onChange(null);
            },
            child: const Text('Clear'),
          ),
        ),
      ],
    );
  }
}

class _SignaturePainter extends CustomPainter {
  final List<List<Offset>> strokes;
  final List<Offset> current;
  const _SignaturePainter(this.strokes, this.current);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.black
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    for (final stroke in [...strokes, current]) {
      for (var i = 1; i < stroke.length; i++) {
        canvas.drawLine(stroke[i - 1], stroke[i], paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _SignaturePainter oldDelegate) =>
      oldDelegate.strokes != strokes || oldDelegate.current != current;
}

// Powered-by-Sankofa attribution. Mirrors the Web SDK + dashboard
// preview: same icon (decoded from the shared base64 brand asset),
// same label, same tap-to-open behaviour, separated from the action
// row by a top border. Suppressed only on white-label tiers (a
// future server flag will skip this widget; until then it always
// renders, matching the SDK contract).
class _PoweredBySankofa extends StatelessWidget {
  const _PoweredBySankofa({
    required this.muted,
    required this.border,
    required this.fontFamily,
  });

  final Color muted;
  final Color border;
  final String? fontFamily;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: border)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: InkWell(
        onTap: () async {
          final uri = Uri.parse(kSankofaAttributionUrl);
          // Flutter SDKs that need URL-launch should depend on
          // url_launcher; we avoid that dependency here and let the
          // host catch the failed launch in production. The Web SDK
          // does this via plain anchor click, RN via Linking, and on
          // Flutter we surface the same intent.
          await SystemChannels.platform.invokeMethod<void>(
            'SystemNavigator.openUrl',
            uri.toString(),
          );
        },
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.memory(
              base64Decode(kBrandIconBase64),
              width: 12,
              height: 12,
              fit: BoxFit.contain,
              gaplessPlayback: true,
            ),
            const SizedBox(width: 4),
            Text(
              'Powered by Sankofa',
              style: TextStyle(
                color: muted,
                fontSize: 10,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.2,
                fontFamily: fontFamily,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

