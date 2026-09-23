// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The app's channels, as the codeplug codecs in the Rust core see them.
//
// One place for the conversion, because two transports use it: the radio's
// own Bluetooth and a programming cable speak the same UV-17Pro memory
// layout, and a conversion kept inside one driver would be copied into the
// other and then drift.

import '../models/radio_band_limits.dart';
import '../models/radio_channel.dart';
import '../models/radio_profile.dart';
import '../src/rust/api/radio_api.dart' as rust;
import 'radio_programmer.dart';

/// The Rust codec's view of [channel], placed in [slot] (1-based).
rust.RadioChannelDto channelToDto(RadioChannel channel, {required int slot}) {
  rust.ToneDto tone(ToneSetting setting) => rust.ToneDto(
        mode: switch (setting.mode) {
          ToneMode.none => 'none',
          ToneMode.ctcss => 'ctcss',
          ToneMode.dcs => 'dcs',
        },
        ctcssTenthHz: setting.ctcssTenthHz,
        dcsCode: setting.dcsCode,
        dcsInverted: setting.dcsInverted,
      );

  return rust.RadioChannelDto(
    slot: slot,
    name: channel.name,
    rxFreqHz: channel.rxFreqHz,
    txFreqHz: channel.txFreqHz,
    rxOnly: channel.rxOnly,
    txTone: tone(channel.txTone),
    rxTone: tone(channel.rxTone),
    narrow: channel.mode == ChannelMode.nfm,
    lowPower: channel.power == PowerLevel.low,
    skip: false,
  );
}

/// The app's channel for one decoded record.
///
/// A tone the app cannot represent — a CTCSS frequency off the standard
/// table, a DCS code outside the standard set — reads as no tone rather than
/// failing the channel. The frequency is what the channel is for; losing
/// it over its tone would be the wrong trade, and a read-edit-write round
/// trip then makes that tone visible as missing in the editor instead of
/// silently rewriting it.
RadioChannel channelFromDto(rust.RadioChannelDto dto) {
  ToneSetting tone(rust.ToneDto t) => switch (t.mode) {
        'ctcss' when ctcssTonesTenthHz.contains(t.ctcssTenthHz) =>
          ToneSetting.ctcss(t.ctcssTenthHz),
        'dcs' when dcsCodes.contains(t.dcsCode) =>
          ToneSetting.dcs(t.dcsCode, inverted: t.dcsInverted),
        _ => ToneSetting.none,
      };

  return RadioChannel(
    name: dto.name,
    rxFreqHz: dto.rxFreqHz,
    txFreqHz: dto.txFreqHz,
    rxOnly: dto.rxOnly,
    txTone: tone(dto.txTone),
    rxTone: tone(dto.rxTone),
    mode: dto.narrow ? ChannelMode.nfm : ChannelMode.fm,
    power: dto.lowPower ? PowerLevel.low : PowerLevel.high,
  );
}

/// The app's band limits for the codec's.
RadioBandLimits bandLimitsFromDto(rust.BandLimitsDto dto) {
  BandLimit band(rust.BandLimitDto limit) => BandLimit(
        txEnabled: limit.txEnabled,
        lowerMhz: limit.lowerMhz,
        upperMhz: limit.upperMhz,
      );
  return RadioBandLimits(vhf: band(dto.vhf), uhf: band(dto.uhf));
}

/// The codec's view of [limits].
///
/// No layout: the codec works it out from the image it is applied to, rather
/// than trusting one that has crossed the boundary twice.
rust.BandLimitsDto bandLimitsToDto(RadioBandLimits limits) {
  rust.BandLimitDto band(BandLimit limit) => rust.BandLimitDto(
        txEnabled: limit.txEnabled,
        lowerMhz: limit.lowerMhz,
        upperMhz: limit.upperMhz,
      );
  return rust.BandLimitsDto(
    vhf: band(limits.vhf),
    uhf: band(limits.uhf),
    layout: '',
  );
}

/// What a read produced: the channels in slot order, and whether the radio
/// had gaps between them that a plan cannot keep.
class DecodedChannels {
  final List<RadioChannel> channels;

  /// True when the occupied slots were not 1..n. A plan numbers its channels
  /// from 1 with no gaps, so a radio with channels in slots 1, 2 and 7 reads
  /// into a plan whose third channel is the one from slot 7 — and writing
  /// that plan back would move it. Surfaced so the screen can say so.
  final bool hadGaps;

  const DecodedChannels({required this.channels, required this.hadGaps});
}

/// Channels in slot order from a codec's decode, noting any gaps.
DecodedChannels decodedFromDtos(List<rust.RadioChannelDto> dtos) {
  final sorted = [...dtos]..sort((a, b) => a.slot.compareTo(b.slot));
  var hadGaps = false;
  for (var i = 0; i < sorted.length; i++) {
    if (sorted[i].slot != i + 1) hadGaps = true;
  }
  return DecodedChannels(
    channels: [for (final dto in sorted) channelFromDto(dto)],
    hadGaps: hadGaps,
  );
}

/// Turns a read image into channels, dispatching on the radio's family.
///
/// A class rather than a bare function so screens reach it through a
/// provider: the codecs live in the native library, and a widget test's
/// fake-async zone never completes a native call, so screen tests swap in a
/// decoder that does not need one.
class CodeplugDecoder {
  const CodeplugDecoder();

  /// Decode the channels in [codeplug], read from a [profile] radio.
  Future<DecodedChannels> decode(
    RadioCodeplug codeplug,
    RadioProfile profile,
  ) async {
    switch (profile.programmingFamily) {
      case ProgrammingFamily.bleUv17Pro:
      case ProgrammingFamily.serialUv17Pro:
        return decodedFromDtos(await rust.radioDecodeChannels(
          image: codeplug.image,
          modelId: profile.id,
        ));
      case ProgrammingFamily.serialUv5r:
        return decodedFromDtos(await rust.uv5RDecodeChannels(
          image: codeplug.image,
          modelId: profile.id,
        ));
    }
  }
}
