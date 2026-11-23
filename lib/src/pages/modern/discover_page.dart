import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/config/ui_config.dart';
import 'package:jhentai/src/extension/widget_extension.dart';
import 'package:jhentai/src/pages/gallery/dashboard/dashboard_page.dart';
import 'package:jhentai/src/pages/modern/favorite_folder_chips.dart';
import 'package:jhentai/src/pages/modern/recommend_feedback_sheet.dart';
import 'package:jhentai/src/routes/routes.dart';
import 'package:jhentai/src/service/recommend_service.dart';
import 'package:jhentai/src/utils/route_util.dart';
import 'package:jhentai/src/widget/eh_dashboard_card.dart';

/// The dashboard (rank list, popular, latest) with a plain app bar: search and
/// a filter for the latest list (categories, language, rating ...), and the
/// recommendations on top.
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

  @override
  List<Widget> buildLeadingSlivers(BuildContext context) {
    return [
      SliverToBoxAdapter(
        child: GetBuilder<RecommendService>(
          id: RecommendService.stateId,
          builder: (_) {
            final Recommendation? r = recommendService.current;
            final String? folder = recommendService.folder == null ? null : FavoriteFolderChips.folderName(recommendService.folder!);
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(left: 10, right: 10, top: 4),
                    child: Row(
                      children: [
                        const Text('✨ ', style: TextStyle(fontSize: 16)),
                        Expanded(
                          child: Text(
                            folder == null ? 'recommendForYou'.tr : '${'recommendForYou'.tr} · $folder',
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                          ),
                        ),
                        TextButton(
                          style: TextButton.styleFrom(padding: const EdgeInsets.only(left: 12), visualDensity: const VisualDensity(vertical: -4)),
                          onPressed: () => toRoute(Routes.recommend),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                r == null ? 'recommendOpen'.tr : 'seeAll'.tr,
                                style: TextStyle(color: UIConfig.dashboardPageSeeAllTextColor(context), fontSize: 12, height: 1),
                              ),
                              Icon(Icons.keyboard_arrow_right, color: UIConfig.dashboardPageArrowButtonColor(context)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (r != null && r.galleries.isNotEmpty)
                    SizedBox(
                      height: UIConfig.dashboardCardSize,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        itemCount: r.galleries.length > 20 ? 20 : r.galleries.length,
                        itemBuilder: (_, index) => EHDashboardCard(
                          gallery: r.galleries[index],
                          onLongPress: () => RecommendFeedbackSheet.showForGallery(context, r.galleries[index]),
                        ),
                        separatorBuilder: (_, __) => const VerticalDivider(),
                      ).enableMouseDrag(withScrollBar: false),
                    )
                  else
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      child: Card(
                        margin: EdgeInsets.zero,
                        child: ListTile(
                          leading: const Icon(Icons.auto_awesome_outlined),
                          title: Text('recommendHint'.tr),
                          onTap: () => toRoute(Routes.recommend),
                        ),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    ];
  }
}
