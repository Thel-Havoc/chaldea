/// RosterScreen — three-tab view: Servants | CEs | Mystic Codes.
library;

import 'package:flutter/material.dart';

import 'ce_list_page.dart';
import 'mc_list_page.dart';
import 'servant_list_page.dart';

class RosterScreen extends StatelessWidget {
  const RosterScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Column(
        children: [
          const TabBar(
            tabs: [
              Tab(text: 'Servants'),
              Tab(text: 'Craft Essences'),
              Tab(text: 'Mystic Codes'),
            ],
          ),
          const Expanded(
            child: TabBarView(
              children: [
                ServantListPage(),
                CeListPage(),
                McListPage(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
