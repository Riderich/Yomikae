import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/pages/layout/mobile_v2/notification/tap_menu_button_notification.dart';
import 'package:jhentai/src/pages/layout/mobile_v2/notification/tap_tab_bat_button_notification.dart';
import 'package:jhentai/src/service/follow_service.dart';
import 'package:jhentai/src/utils/route_util.dart';
import 'package:jhentai/src/widget/will_pop_interceptor.dart';

import 'discover_page.dart';
import 'find_page.dart';
import 'follow_page.dart';
import 'shelf_page.dart';

/// Phone layout: four tabs at the bottom, nothing hidden in drawers.
///
/// * Discover: the dashboard (rank list, popular, latest)
/// * Find: search, categories, tag browser, quick searches
/// * Follow: followed uploaders / artists / circles / tags and their new galleries
/// * Shelf: favourites, taste, history, downloads (settings in its app bar)
class ModernLayoutPage extends StatefulWidget {
  const ModernLayoutPage({super.key});

  @override
  State<ModernLayoutPage> createState() => _ModernLayoutPageState();
}

class _ModernLayoutPageState extends State<ModernLayoutPage> {
  int _index = 0;

  /// Tabs are built on first visit and then kept alive.
  final Set<int> _visited = {0};

  static final List<Widget Function()> _tabs = [
    () => const DiscoverPage(),
    () => const FindPage(),
    () => const FollowPage(),
    () => const ShelfPage(),
  ];

  final Map<int, Widget> _built = {};

  void _select(int index) {
    if (index == _index) {
      return;
    }
    setState(() {
      _index = index;
      _visited.add(index);
    });
  }

  @override
  Widget build(BuildContext context) {
    return WillPopInterceptor(
      child: Scaffold(
        body: NotificationListener<TapTabBarButtonNotification>(
          // the dashboard's "see all" buttons
          onNotification: (notification) {
            toRoute(notification.routeName);
            return true;
          },
          child: NotificationListener<TapMenuButtonNotification>(
            onNotification: (_) => true,
            child: Stack(
              children: [
                for (int i = 0; i < _tabs.length; i++)
                  if (_visited.contains(i))
                    Offstage(
                      offstage: _index != i,
                      child: TickerMode(enabled: _index == i, child: _built.putIfAbsent(i, _tabs[i])),
                    ),
              ],
            ),
          ),
        ),
        bottomNavigationBar: GetBuilder<FollowService>(
          id: FollowService.entriesId,
          builder: (_) => NavigationBar(
            labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
            selectedIndex: _index,
            onDestinationSelected: _select,
            destinations: [
              NavigationDestination(icon: const Icon(Icons.explore_outlined), selectedIcon: const Icon(Icons.explore), label: 'discover'.tr),
              NavigationDestination(icon: const Icon(Icons.manage_search), selectedIcon: const Icon(Icons.manage_search), label: 'find'.tr),
              NavigationDestination(
                icon: Badge(
                  isLabelVisible: followService.totalNewCount > 0,
                  label: Text(followService.totalNewCount > 99 ? '99+' : '${followService.totalNewCount}'),
                  child: const Icon(Icons.star_outline),
                ),
                selectedIcon: Badge(
                  isLabelVisible: followService.totalNewCount > 0,
                  label: Text(followService.totalNewCount > 99 ? '99+' : '${followService.totalNewCount}'),
                  child: const Icon(Icons.star),
                ),
                label: 'follow'.tr,
              ),
              NavigationDestination(icon: const Icon(Icons.collections_bookmark_outlined), selectedIcon: const Icon(Icons.collections_bookmark), label: 'bookshelf'.tr),
            ],
          ),
        ),
      ),
    );
  }
}
