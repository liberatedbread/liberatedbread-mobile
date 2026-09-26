// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/log.dart';
import '../providers/spec_codec_provider.dart';
import '../services/print/label_content.dart';
import '../services/print/label_renderer.dart';
import '../services/print/os_print_service.dart';
import '../services/print/pdf_documents.dart';
import '../services/print/photo_source.dart';
import '../services/print/print_target.dart';
import '../services/spec_codec.dart';

/// Compose a label — text lines, a date, a QR code, or a photo — and print it
/// on a label printer, with a preview of exactly the dots that will burn.
///
/// Printer-agnostic: the [target] says how wide the head is and how to send
/// the job, so the same screen serves a Brother QL on the network and a BLE
/// thermal printer.
class PrintLabelScreen extends ConsumerStatefulWidget {
  final LabelPrintTarget target;

  /// Prefilled content (a device's asset label); a blank one-line label when
  /// null.
  final LabelContent? initial;

  /// A photo to start in photo mode with (one shared into the app).
  final Uint8List? initialPhoto;

  const PrintLabelScreen({
    super.key,
    required this.target,
    this.initial,
    this.initialPhoto,
  });

  @override
  ConsumerState<PrintLabelScreen> createState() => _PrintLabelScreenState();
}

/// The preview's mono raster and the image drawn from it.
class _Preview {
  final Uint8List rgb;
  final int width;
  final int height;
  final ui.Image image;
  const _Preview(this.rgb, this.width, this.height, this.image);
}

/// What the label is made of.
enum _Mode { text, photo }

class _PrintLabelScreenState extends ConsumerState<PrintLabelScreen> {
  _Mode _mode = _Mode.text;
  Uint8List? _photo;
  PrintDither _dither = PrintDither.floydSteinberg;

  /// The luma a photo pixel must reach to stay white: the brightness knob.
  double _photoThreshold = 128;

  late LabelContent _content;
  late final List<TextEditingController> _lines;
  late final TextEditingController _qr;
  bool _withDate = false;
  int _copies = 1;

  _Preview? _preview;
  bool _rendering = false;
  bool _printing = false;
  String? _error;

  Timer? _debounce;

  /// Bumped per render so a slow render cannot overwrite a newer one.
  int _renderEpoch = 0;

  @override
  void initState() {
    super.initState();
    final geometry = widget.target.geometry;
    // Narrow heads read along the tape: across 12 mm a line fits a word.
    final narrow = geometry.widthDots * 25.4 / geometry.dpi < 25;
    final initial = widget.initial ?? LabelContent(alongTape: narrow);
    _content = initial;
    _lines = [
      for (final line in initial.lines.isEmpty ? [''] : initial.lines)
        TextEditingController(text: line),
    ];
    _qr = TextEditingController(text: initial.qrData ?? '');
    _withDate = initial.dateLine != null;
    if (widget.initialPhoto != null) {
      _mode = _Mode.photo;
      _photo = widget.initialPhoto;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _scheduleRender());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    for (final c in _lines) {
      c.dispose();
    }
    _qr.dispose();
    _preview?.image.dispose();
    super.dispose();
  }

  void _update(LabelContent Function(LabelContent) change) {
    setState(() => _content = change(_content));
    _scheduleRender();
  }

  void _syncText() {
    final date = _withDate
        ? MaterialLocalizations.of(context).formatMediumDate(DateTime.now())
        : null;
    _update(
      (c) => c.copyWith(
        lines: [for (final l in _lines) l.text],
        qrData: () => _qr.text.trim().isEmpty ? null : _qr.text,
        dateLine: () => date,
      ),
    );
  }

  void _scheduleRender() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 150), _render);
  }

  Future<void> _render() async {
    final epoch = ++_renderEpoch;
    final codec = ref.read(specCodecProvider);
    setState(() => _rendering = true);
    try {
      final photo = _photo;
      final isPhoto = _mode == _Mode.photo && photo != null;
      final label = isPhoto
          ? await renderPhoto(
              photo,
              widget.target.geometry,
              alongTape: _content.alongTape,
            )
          : await renderLabel(_content, widget.target.geometry);
      final rgb = await codec.prepareMonoRaster(
        rgba: label.rgba,
        width: label.width,
        height: label.height,
        // Text wants a hard edge; a photo wants its tones as dot density.
        dither: isPhoto ? _dither : PrintDither.threshold,
        threshold: isPhoto ? _photoThreshold.round() : 160,
      );
      final image = await _imageFromRgb(rgb, label.width, label.height);
      if (!mounted || epoch != _renderEpoch) {
        image.dispose();
        return;
      }
      setState(() {
        _preview?.image.dispose();
        _preview = _Preview(rgb, label.width, label.height, image);
        _rendering = false;
        _error = null;
      });
    } on Object catch (e) {
      Log.spec.warning('label render failed', error: e);
      if (!mounted || epoch != _renderEpoch) return;
      setState(() {
        _rendering = false;
        _error = _mode == _Mode.photo
            ? 'Could not read that photo.'
            : 'Could not draw the label.';
      });
    }
  }

  Future<void> _print() async {
    final preview = _preview;
    if (preview == null || !_hasContent) return;
    setState(() {
      _printing = true;
      _error = null;
    });
    final messenger = ScaffoldMessenger.of(context);
    final outcome = await widget.target.printMono(
      preview.rgb,
      preview.width,
      preview.height,
      copies: _copies,
    );
    if (!mounted) return;
    setState(() => _printing = false);
    switch (outcome) {
      case PrintOk():
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              _copies == 1 ? 'Label sent.' : '$_copies labels sent.',
            ),
          ),
        );
      case PrintFailed(:final reason):
        setState(() => _error = reason);
    }
  }

  /// The label at its true size on a page, through the system print dialog
  /// — for sticker sheets on an office printer.
  Future<void> _printOnPaper() async {
    final preview = _preview;
    if (preview == null) return;
    try {
      await ref
          .read(osPrintServiceProvider)
          .printDocument(
            name: 'Label',
            build: (format) => labelImagePdf(
              format: format,
              rgb: preview.rgb,
              width: preview.width,
              height: preview.height,
              dpi: widget.target.geometry.dpi,
            ),
          );
    } on Object catch (e) {
      Log.spec.warning('printing the label on paper failed', error: e);
      if (mounted) setState(() => _error = 'Could not open the print dialog.');
    }
  }

  bool get _hasContent =>
      _mode == _Mode.photo ? _photo != null : !_content.isEmpty;

  Future<void> _pickPhoto(Future<Uint8List?> Function() pick) async {
    try {
      var bytes = await pick();
      if (bytes == null || !mounted) return;
      if (isPdf(bytes)) {
        // A document's first page, at the printer's own resolution.
        final pages = await ref
            .read(osPrintServiceProvider)
            .rasterizePdf(bytes, dpi: widget.target.geometry.dpi);
        if (pages.isEmpty || !mounted) return;
        bytes = pages.first;
      }
      setState(() => _photo = bytes);
      _scheduleRender();
    } on Object catch (e) {
      Log.spec.warning('photo pick failed', error: e);
      if (mounted) setState(() => _error = 'Could not open that photo.');
    }
  }

  List<Widget> _photoControls(TextTheme text) {
    final source = ref.read(photoSourceProvider);
    return [
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          OutlinedButton.icon(
            onPressed: () =>
                unawaited(_pickPhoto(() => source.pick(camera: false))),
            icon: const Icon(Icons.photo_library_outlined),
            label: const Text('Choose a photo'),
          ),
          if (source.canUseCamera)
            OutlinedButton.icon(
              onPressed: () =>
                  unawaited(_pickPhoto(() => source.pick(camera: true))),
              icon: const Icon(Icons.photo_camera_outlined),
              label: const Text('Take a photo'),
            ),
          OutlinedButton.icon(
            onPressed: () => unawaited(_pickPhoto(source.pickFile)),
            icon: const Icon(Icons.folder_open_outlined),
            label: const Text('Open a file'),
          ),
        ],
      ),
      const SizedBox(height: 16),
      Text('Shading', style: text.titleSmall),
      const SizedBox(height: 8),
      SegmentedButton<PrintDither>(
        segments: const [
          ButtonSegment(
            value: PrintDither.floydSteinberg,
            label: Text('Smooth'),
          ),
          ButtonSegment(value: PrintDither.atkinson, label: Text('Crisp')),
          ButtonSegment(value: PrintDither.threshold, label: Text('Solid')),
        ],
        selected: {_dither},
        onSelectionChanged: (s) {
          setState(() => _dither = s.first);
          _scheduleRender();
        },
      ),
      const SizedBox(height: 8),
      Row(
        children: [
          const Icon(Icons.brightness_low, size: 20),
          Expanded(
            child: Slider(
              value: _photoThreshold,
              min: 48,
              max: 208,
              label: 'Brightness',
              onChanged: (v) => setState(() => _photoThreshold = v),
              onChangeEnd: (_) => _scheduleRender(),
            ),
          ),
          const Icon(Icons.brightness_high, size: 20),
        ],
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final geometry = widget.target.geometry;
    final qrTooLong = _qr.text.trim().isNotEmpty && !fitsInQr(_qr.text.trim());

    return Scaffold(
      appBar: AppBar(
        title: const Text('Print a label'),
        actions: [
          IconButton(
            tooltip: 'Print on a regular printer',
            icon: const Icon(Icons.local_printshop_outlined),
            onPressed: _preview != null && _hasContent
                ? () => unawaited(_printOnPaper())
                : null,
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
          children: [
            Text(
              [
                widget.target.name,
                if (geometry.mediaName != null) geometry.mediaName!,
              ].join(' · '),
              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
            if (!geometry.hardwareTested) ...[
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.science_outlined,
                    size: 18,
                    color: scheme.tertiary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Printing on this model follows community documentation '
                      "and hasn't been tried on one by this project yet. If a "
                      'label comes out wrong, the diagnostics log helps.',
                      style: text.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 12),
            _PreviewCard(preview: _preview, rendering: _rendering),
            const SizedBox(height: 16),
            SegmentedButton<_Mode>(
              segments: const [
                ButtonSegment(
                  value: _Mode.text,
                  label: Text('Text'),
                  icon: Icon(Icons.text_fields),
                ),
                ButtonSegment(
                  value: _Mode.photo,
                  label: Text('Photo'),
                  icon: Icon(Icons.image_outlined),
                ),
              ],
              selected: {_mode},
              onSelectionChanged: (s) {
                setState(() => _mode = s.first);
                _scheduleRender();
              },
            ),
            const SizedBox(height: 16),
            if (_mode == _Mode.photo) ..._photoControls(text),
            if (_mode == _Mode.text)
              for (var i = 0; i < _lines.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: TextField(
                    key: ValueKey('label-line-$i'),
                    controller: _lines[i],
                    decoration: InputDecoration(
                      labelText: _lines.length == 1 ? 'Text' : 'Line ${i + 1}',
                      border: const OutlineInputBorder(),
                      suffixIcon: _lines.length > 1
                          ? IconButton(
                              tooltip: 'Remove line',
                              icon: const Icon(Icons.close),
                              onPressed: () {
                                setState(() => _lines.removeAt(i).dispose());
                                _syncText();
                              },
                            )
                          : null,
                    ),
                    onChanged: (_) => _syncText(),
                  ),
                ),
            if (_mode == _Mode.text && _lines.length < LabelContent.maxLines)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () =>
                      setState(() => _lines.add(TextEditingController())),
                  icon: const Icon(Icons.add),
                  label: const Text('Add a line'),
                ),
              ),
            if (_mode == _Mode.text) ...[
              const SizedBox(height: 8),
              SegmentedButton<LabelTextSize>(
                segments: const [
                  ButtonSegment(
                    value: LabelTextSize.small,
                    label: Text('Small'),
                  ),
                  ButtonSegment(
                    value: LabelTextSize.medium,
                    label: Text('Medium'),
                  ),
                  ButtonSegment(
                    value: LabelTextSize.large,
                    label: Text('Large'),
                  ),
                ],
                selected: {_content.size},
                onSelectionChanged: (s) =>
                    _update((c) => c.copyWith(size: s.first)),
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text("Add today's date"),
                value: _withDate,
                onChanged: (v) {
                  _withDate = v;
                  _syncText();
                },
              ),
              const SizedBox(height: 8),
              TextField(
                key: const ValueKey('label-qr'),
                controller: _qr,
                decoration: InputDecoration(
                  labelText: 'QR code (optional)',
                  helperText: 'A link or any text',
                  errorText: qrTooLong ? 'Too long for a QR code' : null,
                  border: const OutlineInputBorder(),
                ),
                onChanged: (_) => _syncText(),
              ),
            ],
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                _mode == _Mode.photo
                    ? 'Photo along the tape'
                    : 'Text along the tape',
              ),
              subtitle: const Text('Rotate to run the length of the label'),
              value: _content.alongTape,
              onChanged: (v) => _update((c) => c.copyWith(alongTape: v)),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(child: Text('Copies', style: text.bodyLarge)),
                IconButton(
                  tooltip: 'Fewer copies',
                  onPressed: _copies > 1
                      ? () => setState(() => _copies--)
                      : null,
                  icon: const Icon(Icons.remove),
                ),
                Text('$_copies', style: text.titleMedium),
                IconButton(
                  tooltip: 'More copies',
                  onPressed: _copies < 20
                      ? () => setState(() => _copies++)
                      : null,
                  icon: const Icon(Icons.add),
                ),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: text.bodyMedium?.copyWith(color: scheme.error),
              ),
            ],
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed:
                  _preview != null && _hasContent && !_printing && !_rendering
                  ? () => unawaited(_print())
                  : null,
              icon: _printing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.print_outlined),
              label: Text(_printing ? 'Sending…' : 'Print'),
            ),
          ],
        ),
      ),
    );
  }
}

/// The label as it will print: black dots on white, at the head's aspect.
class _PreviewCard extends StatelessWidget {
  final _Preview? preview;
  final bool rendering;

  const _PreviewCard({required this.preview, required this.rendering});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final p = preview;
    return Container(
      constraints: const BoxConstraints(minHeight: 80, maxHeight: 320),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      alignment: Alignment.center,
      child: p == null
          ? (rendering
                ? const CircularProgressIndicator(strokeWidth: 2)
                : const SizedBox.shrink())
          : Semantics(
              label: 'Label preview',
              image: true,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  boxShadow: [
                    BoxShadow(
                      color: scheme.shadow.withAlpha(40),
                      blurRadius: 4,
                    ),
                  ],
                ),
                child: RawImage(
                  image: p.image,
                  fit: BoxFit.contain,
                  // Nearest-neighbour: the preview is dots, not a photo.
                  filterQuality: FilterQuality.none,
                ),
              ),
            ),
    );
  }
}

/// RGB888 to a drawable image.
Future<ui.Image> _imageFromRgb(Uint8List rgb, int width, int height) {
  final rgba = Uint8List(width * height * 4);
  for (var i = 0; i < width * height; i++) {
    rgba[i * 4] = rgb[i * 3];
    rgba[i * 4 + 1] = rgb[i * 3 + 1];
    rgba[i * 4 + 2] = rgb[i * 3 + 2];
    rgba[i * 4 + 3] = 255;
  }
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    rgba,
    width,
    height,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  return completer.future;
}
