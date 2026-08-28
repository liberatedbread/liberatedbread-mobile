// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The channels that are the same everywhere.
//
// FRS, GMRS, MURS and the NOAA weather channels are allocations, not
// listings: they do not depend on where you are standing, they do not go
// stale, and they need no network. That makes them the tier of suggestion
// that always works -- on a plane, in a canyon, with the radio source
// settings all switched off.

import '../models/radio_channel.dart';

/// The FRS/GMRS channel plan, 47 CFR Part 95 subparts B and E.
///
/// Channels 1-7 and 15-22 are the 462 MHz interstitial and main channels;
/// 8-14 are the 467 MHz low-power channels, which is why they are marked
/// [PowerLevel.low] -- a handheld is limited to half a watt there.
const List<int> _frsChannelHz = [
  462562500,
  462587500,
  462612500,
  462637500,
  462662500,
  462687500,
  462712500,
  467562500,
  467587500,
  467612500,
  467637500,
  467662500,
  467687500,
  467712500,
  462550000,
  462575000,
  462600000,
  462625000,
  462650000,
  462675000,
  462700000,
  462725000,
];

/// The eight GMRS repeater pairs: output on the 462 MHz main channels,
/// input 5 MHz up. Channels 15-22 of the plan above, in their duplex form.
const int _gmrsRepeaterOffsetHz = 5000000;

/// MURS, 47 CFR Part 95 subpart J. The first three are narrowband; the last
/// two may be wide, and are the ones the retail "blister pack" radios use.
const List<({String name, int hz, ChannelMode mode})> _mursChannels = [
  (name: 'MURS 1', hz: 151820000, mode: ChannelMode.nfm),
  (name: 'MURS 2', hz: 151880000, mode: ChannelMode.nfm),
  (name: 'MURS 3', hz: 151940000, mode: ChannelMode.nfm),
  (name: 'MURS 4', hz: 154570000, mode: ChannelMode.fm),
  (name: 'MURS 5', hz: 154600000, mode: ChannelMode.fm),
];

/// The seven NOAA Weather Radio channels, in the order radios number them.
///
/// This is the whole weather tier, and it is deliberately the whole tier: a
/// located transmitter list would tell you which of these seven your nearest
/// station uses, but all seven fit in any radio with room to spare, and
/// scanning them is how you find out what you can actually hear from where
/// you are standing. See assets/radio/README.md.
const List<int> _weatherChannelsHz = [
  162550000,
  162400000,
  162475000,
  162425000,
  162450000,
  162500000,
  162525000,
];

/// FRS/GMRS simplex channels 1-22.
List<RadioChannel> frsGmrsChannels() => [
      for (var i = 0; i < _frsChannelHz.length; i++)
        RadioChannel(
          name: 'GMRS ${i + 1}',
          rxFreqHz: _frsChannelHz[i],
          txFreqHz: _frsChannelHz[i],
          // 8-14 are the low-power channels; the rest are marked high and the
          // radio's own settings decide from there.
          power: (i >= 7 && i <= 13) ? PowerLevel.low : PowerLevel.high,
          // The whole FRS/GMRS plan is narrowband except the 462 MHz main
          // channels, which GMRS licensees may use wide. Narrow is the safe
          // default: a narrow radio hears a wide station, just quieter.
          mode: ChannelMode.nfm,
          comment: 'FRS/GMRS channel ${i + 1}',
        ),
    ];

/// The eight GMRS repeater pairs (channels 15-22 with a +5 MHz input).
List<RadioChannel> gmrsRepeaterChannels() => [
      for (var i = 14; i < _frsChannelHz.length; i++)
        RadioChannel(
          name: 'RPT ${i + 1}',
          rxFreqHz: _frsChannelHz[i],
          txFreqHz: _frsChannelHz[i] + _gmrsRepeaterOffsetHz,
          mode: ChannelMode.nfm,
          comment: 'GMRS repeater ${i + 1} — set the tone your repeater wants',
        ),
    ];

List<RadioChannel> mursChannels() => [
      for (final channel in _mursChannels)
        RadioChannel(
          name: channel.name,
          rxFreqHz: channel.hz,
          txFreqHz: channel.hz,
          mode: channel.mode,
          comment: 'MURS — no licence required',
        ),
    ];

/// NOAA Weather Radio, receive-only. These frequencies are a government
/// broadcast service: nothing may transmit on them, so the channels are built
/// [RadioChannel.receiveOnly] rather than being left to a band-limit check.
List<RadioChannel> weatherChannels() => [
      for (var i = 0; i < _weatherChannelsHz.length; i++)
        RadioChannel.receiveOnly(
          name: 'WX${i + 1}',
          freqHz: _weatherChannelsHz[i],
          comment: 'NOAA Weather Radio',
        ),
    ];

/// The national simplex calling frequencies, which are where you call CQ and
/// where someone answers a call for help.
List<RadioChannel> callingChannels() => const [
      RadioChannel(
        name: '2m Call',
        rxFreqHz: 146520000,
        txFreqHz: 146520000,
        comment: '2 m national simplex calling',
      ),
      RadioChannel(
        name: '70cm Call',
        rxFreqHz: 446000000,
        txFreqHz: 446000000,
        comment: '70 cm national simplex calling',
      ),
    ];

/// Everything above, in the order a suggestion list should show it.
List<RadioChannel> allPresetChannels() => [
      ...callingChannels(),
      ...frsGmrsChannels(),
      ...gmrsRepeaterChannels(),
      ...mursChannels(),
      ...weatherChannels(),
    ];
