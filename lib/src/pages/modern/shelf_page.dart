import 'package:extended_image/extended_image.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/network/eh_request.dart';
import 'package:jhentai/src/pages/download/download_base_page.dart';
import 'package:jhentai/src/pages/favorite/favorite_page.dart';
import 'package:jhentai/src/pages/favorite/favorite_page_logic.dart';
import 'package:jhentai/src/pages/history/history_page.dart';
import 'package:jhentai/src/pages/history/history_page_logic.dart';
import 'package:jhentai/src/routes/routes.dart';
import 'package:jhentai/src/service/taste_service.dart';
import 'package:jhentai/src/setting/user_setting.dart';
import 'package:jhentai/src/utils/route_util.dart';
import 'package:jhentai/src/widget/eh_alert_dialog.dart';

import 'taste_view.dart';

/// The user's own galleries: favourites, their taste, history and downloads.
/// Account and settings live in the app bar.
class ShelfPage extends StatefulWidget {
  const ShelfPage({super.key});

  @override
  State<ShelfPage> createState() => _ShelfPageState();
}

class _ShelfPageState extends State<ShelfPage> with SingleTickerProviderStateMixin {
  late final TabController _tabController = TabController(length: 4, vsync: this);
  final Set<int> _visited = {0};
  final Map<int, Widget> _built = {};

  late final List<Widget Function()> _tabs = [
    () => const FavoritePage(embedded: true),
    () => const TasteView(),
    () => HistoryPage(embedded: true),
    () => const DownloadPage(),
  ];

  @override
  void initState() {
    super.initState();
    _tabController.addListener(() {
      if (!_tabController.indexIsChanging) {
        setState(() => _visited.add(_tabController.index));
      }
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  List<Widget> _actions() {
    switch (_tabController.index) {
      case 0:
        // the page's getter registers the (permanent) logic if the page is not built yet
        final FavoritePageLogic logic = const FavoritePage(embedded: true).logic;
        return [
          IconButton(icon: const Icon(Icons.sort), tooltip: 'sort'.tr, onPressed: logic.handleChangeSortOrder),
          IconButton(icon: const Icon(Icons.filter_alt_outlined), tooltip: 'filter'.tr, onPressed: logic.handleTapFilterButton),
        ];
      case 1:
        return [
          IconButton(icon: const Icon(Icons.refresh), tooltip: 'refresh'.tr, onPressed: tasteService.analyze),
        ];
      case 2:
        final HistoryPageLogic logic = HistoryPage(embedded: true).logic;
        return [
          IconButton(icon: const Icon(Icons.delete_outline), tooltip: 'delete'.tr, onPressed: logic.handleTapDeleteButton),
        ];
      default:
        return [];
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: const _AccountButton(),
        title: Text('bookshelf'.tr),
        centerTitle: false,
        actions: [
          ..._actions(),
          IconButton(icon: const Icon(Icons.settings_outlined), tooltip: 'setting'.tr, onPressed: () => toRoute(Routes.setting)),
        ],
        bottom: TabBar(
          controller: _tabController,
          tabs: [
            Tab(text: 'favorite'.tr),
            Tab(text: 'taste'.tr),
            Tab(text: 'history'.tr),
            Tab(text: 'download'.tr),
          ],
        ),
      ),
      body: Stack(
        children: [
          for (int i = 0; i < _tabs.length; i++)
            if (_visited.contains(i))
              Offstage(
                offstage: _tabController.index != i,
                child: TickerMode(enabled: _tabController.index == i, child: _built.putIfAbsent(i, _tabs[i])),
              ),
        ],
      ),
    );
  }
}

/// Avatar in the app bar: log in, or log out after confirming.
class _AccountButton extends StatelessWidget {
  const _AccountButton();

  @override
  Widget build(BuildContext context) {
    return Obx(
      () => IconButton(
        tooltip: userSetting.nickName.value ?? userSetting.userName.value ?? 'tap2Login'.tr,
        icon: CircleAvatar(
          radius: 15,
          foregroundImage: userSetting.avatarImgUrl.value != null ? ExtendedNetworkImageProvider(userSetting.avatarImgUrl.value!, cache: true) : null,
          child: Icon(userSetting.hasLoggedIn() ? Icons.face_retouching_natural : Icons.face, size: 18),
        ),
        onPressed: () async {
          if (!userSetting.hasLoggedIn()) {
            toRoute(Routes.login);
            return;
          }
          final bool? result = await Get.dialog(EHDialog(title: '${'logout'.tr} ?'));
          if (result == true) {
            await ehRequest.requestLogout();
          }
        },
      ),
    );
  }
}
