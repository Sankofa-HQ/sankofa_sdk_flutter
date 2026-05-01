import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'branching.dart';
import 'pulse_models.dart';

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
  final void Function(PulseSubmitPayload payload) onSubmit;
  final VoidCallback onDismiss;

  const SankofaSurveyDialog({
    super.key,
    required this.survey,
    this.branchingRules = const [],
    required this.onSubmit,
    required this.onDismiss,
  });

  @override
  State<SankofaSurveyDialog> createState() => _SankofaSurveyDialogState();
}

class _SankofaSurveyDialogState extends State<SankofaSurveyDialog> {
  late final List<PulseQuestion> _questions;
  final Map<String, Object?> _answers = {};
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

  Color _accent(BuildContext context) {
    final theme = widget.survey.theme;
    final primary = theme?.primaryColor;
    if (primary != null && primary.isNotEmpty) {
      final parsed = _parseHex(primary);
      if (parsed != null) return parsed;
    }
    return Theme.of(context).colorScheme.primary;
  }

  Color? _parseHex(String hex) {
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

  @override
  Widget build(BuildContext context) {
    final q = _current;
    final isLast = _index == _questions.length - 1;
    final accent = _accent(context);
    final progress = _questions.isEmpty
        ? 1.0
        : (_index + 1) / _questions.length;

    return Dialog(
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
              _header(context),
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
                          q.prompt,
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        if (q.helptext != null && q.helptext!.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(
                            q.helptext!,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
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
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _history.isNotEmpty ? _goBack : null,
                      child: const Text('Back'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      style: FilledButton.styleFrom(backgroundColor: accent),
                      onPressed: _goForward,
                      child: Text(isLast ? 'Submit' : 'Next'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.survey.name,
                style: Theme.of(context).textTheme.titleMedium,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              if (widget.survey.description != null &&
                  widget.survey.description!.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  widget.survey.description!,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ],
          ),
        ),
        IconButton(
          icon: const Icon(Icons.close, size: 20),
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

  Widget _renderTextField(PulseQuestion q, {required bool multiline}) {
    return TextFormField(
      initialValue: _answers[q.id] as String?,
      maxLines: multiline ? 4 : 1,
      keyboardType:
          multiline ? TextInputType.multiline : TextInputType.text,
      onChanged: (v) {
        _answers[q.id] = v.trim().isEmpty ? null : v;
      },
      decoration: const InputDecoration(border: OutlineInputBorder()),
    );
  }

  Widget _renderNumber(PulseQuestion q) {
    return TextFormField(
      initialValue: (_answers[q.id] as num?)?.toString(),
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp(r'^\-?\d*\.?\d*$')),
      ],
      onChanged: (v) {
        _answers[q.id] = double.tryParse(v);
      },
      decoration: const InputDecoration(border: OutlineInputBorder()),
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
              title: Text(opt.label),
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
            title: Text(opt.label),
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
      title: Text(q.helptext ?? 'I agree'),
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
              Expanded(child: Text(opt.label)),
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

