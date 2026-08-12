// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';

/// One light behind a hub: its owner-given name, an on/off switch, and a
/// brightness slider in the device's own range.
///
/// Pure view — the screen owns state, sending and read-back. Two rules from
/// the spec's data shape live here as behaviour:
///
///  * an unknown reading renders as "State unknown" with the switch showing
///    off-but-enabled, never a fabricated state;
///  * the slider commits on `onChangeEnd`, not per pixel of drag, with the
///    dragged value held locally until the next reading arrives — one write
///    per gesture is what keeps a bridge that throttles chatty clients
///    happy, without any debounce machinery.
class HubChildLightCard extends StatefulWidget {
  final String label;
  final bool? isOn;
  final double? brightness;
  final double brightnessMin;
  final double brightnessMax;

  /// Disables every control — a send for this child is in flight.
  final bool busy;

  /// Null when the matching role resolved no command (the control hides).
  final ValueChanged<bool>? onToggle;
  final ValueChanged<double>? onBrightness;

  const HubChildLightCard({
    super.key,
    required this.label,
    required this.isOn,
    required this.brightness,
    this.brightnessMin = 1,
    this.brightnessMax = 254,
    this.busy = false,
    this.onToggle,
    this.onBrightness,
  });

  @override
  State<HubChildLightCard> createState() => _HubChildLightCardState();
}

class _HubChildLightCardState extends State<HubChildLightCard> {
  /// The value mid-drag, shown instead of the reading until the drag commits
  /// and the next refresh replaces it.
  double? _dragging;

  @override
  void didUpdateWidget(covariant HubChildLightCard old) {
    super.didUpdateWidget(old);
    // A new reading arrived: the device has answered, so it owns the slider
    // again.
    if (old.brightness != widget.brightness) _dragging = null;
  }

  double get _sliderValue =>
      (_dragging ?? widget.brightness ?? widget.brightnessMin)
          .clamp(widget.brightnessMin, widget.brightnessMax);

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final isOn = widget.isOn;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  (isOn ?? false) ? Icons.lightbulb : Icons.lightbulb_outline,
                  color: (isOn ?? false)
                      ? scheme.primary
                      : scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(widget.label,
                          style: text.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w600)),
                      if (isOn == null)
                        Text('State unknown', style: text.bodySmall),
                    ],
                  ),
                ),
                if (widget.busy)
                  const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  Switch(
                    value: isOn ?? false,
                    onChanged: widget.onToggle,
                  ),
              ],
            ),
            if (widget.onBrightness != null) ...[
              const SizedBox(height: 4),
              Row(
                children: [
                  Icon(Icons.brightness_6,
                      size: 18, color: scheme.onSurfaceVariant),
                  Expanded(
                    child: Slider(
                      min: widget.brightnessMin,
                      max: widget.brightnessMax,
                      value: _sliderValue,
                      label: '${_sliderValue.round()}',
                      onChanged: widget.busy
                          ? null
                          : (value) => setState(() => _dragging = value),
                      onChangeEnd: widget.busy
                          ? null
                          : (value) =>
                              widget.onBrightness?.call(value.roundToDouble()),
                    ),
                  ),
                  Text('${_sliderValue.round()}',
                      style: text.bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant)),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
