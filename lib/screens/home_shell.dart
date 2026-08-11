// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';

import 'saved_devices_screen.dart';
import 'scan_screen.dart';
import 'wifi_scan_screen.dart';

/// The app's three top-level destinations.
///
/// Devices arrive by two different radios and are worth keeping afterwards,
/// which is three jobs and used to be one screen: a BLE scan with a saved-device
/// footer and nowhere at all for Wi-Fi hardware. A bottom bar makes each one
/// reachable in a tap and gives Wi-Fi somewhere to live.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // IndexedStack rather than swapping the child: each tab owns a scan in
      // progress and a list of results, and rebuilding those from scratch every
      // time someone glances at another tab would throw away a scan they are
      // in the middle of.
      //
      // Keeping a tab alive is not the same as letting it work, though. The BLE
      // scan runs continuously, and it is the most expensive thing this app
      // does; running it for a list that is three layers deep in a stack, behind
      // the Wi-Fi tab someone is reading, is spending battery on results nobody
      // can see. So the Nearby tab is told whether it is the visible one, and
      // pauses its radio when it is not — while keeping its state, which is why
      // the IndexedStack is here in the first place.
      body: IndexedStack(
        index: _index,
        children: [
          ScanScreen(active: _index == 0),
          const SavedDevicesScreen(),
          const WifiScanScreen(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (index) => setState(() => _index = index),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.bluetooth_searching_outlined),
            selectedIcon: Icon(Icons.bluetooth_searching),
            label: 'Nearby',
          ),
          NavigationDestination(
            icon: Icon(Icons.memory_outlined),
            selectedIcon: Icon(Icons.memory),
            label: 'Saved',
          ),
          NavigationDestination(
            icon: Icon(Icons.wifi_find_outlined),
            selectedIcon: Icon(Icons.wifi_find),
            label: 'Wi-Fi',
          ),
        ],
      ),
    );
  }
}
