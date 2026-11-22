import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/pages/gallery/dashboard/dashboard_page.dart';
import 'package:jhentai/src/routes/routes.dart';
import 'package:jhentai/src/utils/route_util.dart';

/// The dashboard (rank list, popular, latest) with a plain app bar: search and
/// a filter for the latest list (categories, language, rating ...).
class DiscoverPage extends DashboardPage {
  const DiscoverPage({super.key});

  @override
  AppBar? buildAppBar(BuildContext context) {
    return AppBar(
      title: Text('discover'.tr),
      centerTitle: false,
      actions: [
        IconButton(icon: const Icon(Icons.search), tooltip: 'search'.tr, onPressed: () => toRoute(Routes.mobileV2Search)),
        IconButton(icon: const Icon(Icons.filter_alt_outlined), tooltip: 'filter'.tr, onPressed: logic.handleTapFilterButton),
      ],
    );
  }
}
