// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The app's channels, as the codeplug codecs in the Rust core see them.
//
// One place for the conversion, because two transports use it: the radio's
// own Bluetooth and a programming cable speak the same UV-17Pro memory
// layout, and a conversion kept inside one driver would be copied into the
// other and then drift.

import 'dart:typed_data';

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
    power: channel.power.wireName,
    skip: channel.skip,
  );
}

/// The app's channel for one decoded record.
///
/// A tone the app cannot represent — a CTCSS frequency off the standard
/// table, a DCS code outside [dcsCodes] — reads as no tone rather than
/// failing the channel. The frequency is what the channel is for; losing
/// it over its tone would be the wrong trade, and a read-edit-write round
/// trip then makes that tone visible as missing in the editor instead of
/// silently rewriting it.
RadioChannel channelFromDto(rust.RadioChannelDto dto) {
  ToneSetting tone(rust.ToneDto t) => switch (t.mode) {
    'ctcss' when ctcssTonesTenthHz.contains(t.ctcssTenthHz) =>
      ToneSetting.ctcss(t.ctcssTenthHz),
    'dcs' when dcsCodes.contains(t.dcsCode) => ToneSetting.dcs(
      t.dcsCode,
      inverted: t.dcsInverted,
    ),
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
    // The codec only ever names the three; anything else is a codec this
    // build does not know, and high is what CHIRP reads an unknown level as.
    power: PowerLevel.fromWire(dto.power) ?? PowerLevel.high,
    skip: dto.skip,
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
        return decodedFromDtos(
          await rust.radioDecodeChannels(
            image: codeplug.image,
            modelId: profile.id,
          ),
        );
      case ProgrammingFamily.serialUv5r:
        return decodedFromDtos(
          await rust.uv5RDecodeChannels(
            image: codeplug.image,
            modelId: profile.id,
          ),
        );
    }
  }
}

/// Turns channels into an image, dispatching on the radio's family.
///
/// The same calls the two real drivers make, in one place, so a third
/// caller -- the demo programmer -- encodes exactly what a radio would be
/// sent rather than a copy that drifts. A class for the reason
/// [CodeplugDecoder] is one: the codecs are native, and a test that must not
/// cross into them swaps in a subclass.
class CodeplugEncoder {
  const CodeplugEncoder();

  /// A copy of [base]'s image with [channels] in slots 1 up and every later
  /// slot cleared, for a [profile] radio. Everything the app does not model
  /// survives from [base], which is why a write always reads first.
  Future<Uint8List> encode(
    RadioCodeplug base,
    RadioProfile profile,
    List<RadioChannel> channels,
  ) async {
    final dtos = [
      for (var i = 0; i < channels.length; i++)
        channelToDto(channels[i], slot: i + 1),
    ];
    switch (profile.programmingFamily) {
      case ProgrammingFamily.bleUv17Pro:
      case ProgrammingFamily.serialUv17Pro:
        return rust.radioEncodeChannels(
          image: base.image,
          channels: dtos,
          modelId: profile.id,
        );
      case ProgrammingFamily.serialUv5r:
        return rust.uv5REncodeChannels(
          image: base.image,
          channels: dtos,
          modelId: profile.id,
        );
    }
  }

  /// An image as an unwritten [profile] radio holds one: the model's own
  /// length, every byte 0xFF.
  ///
  /// The length has to be the model's because the codecs check it -- the
  /// older family refuses any other size outright -- and 0xFF because that
  /// is what both codecs read as an empty slot.
  Future<Uint8List> blankImage(RadioProfile profile) async {
    final int length;
    switch (profile.programmingFamily) {
      case ProgrammingFamily.bleUv17Pro:
      case ProgrammingFamily.serialUv17Pro:
        final models = await rust.radioModels();
        length = models.firstWhere((m) => m.id == profile.id).imageLen;
      case ProgrammingFamily.serialUv5r:
        length = await rust.uv5RImageLen();
    }
    return Uint8List(length)..fillRange(0, length, 0xFF);
  }
}
