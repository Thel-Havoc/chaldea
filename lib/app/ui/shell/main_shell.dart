/// MainShell — top-level scaffold with NavigationRail.
///
/// Destinations: Roster (active) | Quest (stub) | Results (stub).
/// Designed to grow: add destinations here as phases are completed.
library;

import 'package:flutter/material.dart';

import '../quest/quest_screen.dart';
import '../quest/results_screen.dart';
import '../roster/roster_screen.dart';

class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _selectedIndex = 0;

  static const _destinations = [
    NavigationRailDestination(
      icon: Icon(Icons.people_outline),
      selectedIcon: Icon(Icons.people),
      label: Text('Roster'),
    ),
    NavigationRailDestination(
      icon: Icon(Icons.search_outlined),
      selectedIcon: Icon(Icons.search),
      label: Text('Quest'),
    ),
    NavigationRailDestination(
      icon: Icon(Icons.emoji_events_outlined),
      selectedIcon: Icon(Icons.emoji_events),
      label: Text('Results'),
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: _selectedIndex,
            onDestinationSelected: (i) => setState(() => _selectedIndex = i),
            labelType: NavigationRailLabelType.all,
            destinations: _destinations,
          ),
          const VerticalDivider(width: 1),
          Expanded(child: _buildPage()),
        ],
      ),
    );
  }

  Widget _buildPage() {
    switch (_selectedIndex) {
      case 0:
        return const RosterScreen();
      case 1:
        return const QuestScreen();
      case 2:
        return const ResultsScreen();
      default:
        return const SizedBox.shrink();
    }
  }
}

