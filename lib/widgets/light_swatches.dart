// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';

import '../core/color_names.dart';

/// Preset swatches both light cards offer — the BLE [LightControlCard] and
/// the Wi-Fi NetworkLightCard — from one list, so a colour means the same on
/// either screen. Plain RGB values sent verbatim; the device's own
/// gamma/order handling is the spec template's business.
///
/// One copy, not two: the pair had already needed the same semantics fix
/// applied to each separately.
const lightSwatches = <Color>[
  Color(0xFFFFFFFF), // white
  Color(0xFFFFE4B5), // warm white
  Color(0xFFFF0000),
  Color(0xFFFF6600),
  Color(0xFFFFAA00),
  Color(0xFFFFFF00),
  Color(0xFFAAFF00),
  Color(0xFF00FF00),
  Color(0xFF00FFAA),
  Color(0xFF00FFFF),
  Color(0xFF00AAFF),
  Color(0xFF0000FF),
  Color(0xFF6600FF),
  Color(0xFFAA00FF),
  Color(0xFFFF00FF),
  Color(0xFFFF0066),
];

/// One tappable colour swatch, named for a screen reader by
/// [colorSwatchName].
class SwatchButton extends StatelessWidget {
  final Color color;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  const SwatchButton({
    super.key,
    required this.color,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Dark checkmark on light swatches, light on dark ones.
    final luminance = color.computeLuminance();
    // Merged into ONE node: the InkWell inside publishes its own unlabelled
    // tappable node, so the swatch was announced twice — once by colour
    // name, once as a nameless button. Merging keeps the InkWell's tap
    // action on the node the label rides.
    return MergeSemantics(
      child: Semantics(
        label: colorSwatchName(color),
        button: true,
        selected: selected,
        enabled: enabled,
        child: _swatch(scheme, luminance),
      ),
    );
  }

  Widget _swatch(ColorScheme scheme, double luminance) {
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(19),
      child: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? scheme.primary : scheme.outlineVariant,
            width: selected ? 3 : 1,
          ),
        ),
        child: selected
            ? Icon(
                Icons.check,
                size: 18,
                color: luminance > 0.5 ? Colors.black87 : Colors.white,
              )
            : null,
      ),
    );
  }
}
