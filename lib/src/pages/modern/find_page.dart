import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/config/ui_config.dart';
import 'package:jhentai/src/model/search_config.dart';
import 'package:jhentai/src/routes/routes.dart';
import 'package:jhentai/src/service/quick_search_service.dart';
import 'package:jhentai/src/utils/route_util.dart';
import 'package:jhentai/src/utils/search_util.dart';

/// Everything for looking for galleries in one place: the search box, the ten
/// categories, a browsable tag directory and the saved quick searches.
class FindPage extends StatelessWidget {
  const FindPage({super.key});

  static const List<(String, void Function(SearchConfig))> categories = [
    ('Doujinshi', _doujinshi),
    ('Manga', _manga),
    ('Artist CG', _artistCG),
    ('Game CG', _gameCG),
    ('Western', _western),
    ('Non-H', _nonH),
    ('Image Set', _imageSet),
    ('Cosplay', _cosplay),
    ('Asian Porn', _asianPorn),
    ('Misc', _misc),
  ];

  static void _doujinshi(SearchConfig c) => c.includeDoujinshi = true;
  static void _manga(SearchConfig c) => c.includeManga = true;
  static void _artistCG(SearchConfig c) => c.includeArtistCG = true;
  static void _gameCG(SearchConfig c) => c.includeGameCg = true;
  static void _western(SearchConfig c) => c.includeWestern = true;
  static void _nonH(SearchConfig c) => c.includeNonH = true;
  static void _imageSet(SearchConfig c) => c.includeImageSet = true;
  static void _cosplay(SearchConfig c) => c.includeCosplay = true;
  static void _asianPorn(SearchConfig c) => c.includeAsianPorn = true;
  static void _misc(SearchConfig c) => c.includeMisc = true;

  /// Tag namespaces worth browsing, with an icon each.
  static const List<(String, IconData)> namespaces = [
    ('artist', Icons.brush_outlined),
    ('group', Icons.groups_outlined),
    ('parody', Icons.movie_outlined),
    ('character', Icons.face_outlined),
    ('female', Icons.female),
    ('male', Icons.male),
    ('mixed', Icons.join_inner),
    ('other', Icons.label_outline),
    ('language', Icons.translate),
    ('cosplayer', Icons.camera_alt_outlined),
  ];

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text('find'.tr), centerTitle: false),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: [
          _buildSearchBox(context, colors),
          _buildHeader(context, 'category'.tr),
          _buildCategories(),
          _buildHeader(context, 'browseTags'.tr, subtitle: 'browseTagsHint'.tr),
          _buildNamespaces(context, colors),
          _buildHeader(
            context,
            'quickSearch'.tr,
            trailing: TextButton(onPressed: () => toRoute(Routes.quickSearch), child: Text('manage'.tr)),
          ),
          _buildQuickSearches(context),
        ],
      ),
    );
  }

  Widget _buildSearchBox(BuildContext context, ColorScheme colors) {
    return Material(
      color: colors.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(28),
      child: InkWell(
        borderRadius: BorderRadius.circular(28),
        onTap: () => toRoute(Routes.mobileV2Search),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          child: Row(
            children: [
              Icon(Icons.search, color: colors.onSurfaceVariant),
              const SizedBox(width: 12),
              Expanded(child: Text('searchHint'.tr, style: TextStyle(color: colors.onSurfaceVariant))),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, String title, {String? subtitle, Widget? trailing}) {
    return Padding(
      padding: const EdgeInsets.only(top: 24, bottom: 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                if (subtitle != null) Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          if (trailing != null) trailing,
        ],
      ),
    );
  }

  Widget _buildCategories() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: categories.map((entry) {
        final (String name, void Function(SearchConfig) enable) = entry;
        final Color color = UIConfig.galleryCategoryColor[name] ?? Colors.grey;
        return ActionChip(
          avatar: CircleAvatar(backgroundColor: color, radius: 6),
          label: Text(name),
          onPressed: () {
            final SearchConfig config = SearchConfig()..disableAllCategories();
            enable(config);
            newSearch(rewriteSearchConfig: config, forceNewRoute: true);
          },
        );
      }).toList(),
    );
  }

  Widget _buildNamespaces(BuildContext context, ColorScheme colors) {
    return GridView.count(
      crossAxisCount: 4,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      childAspectRatio: 1.1,
      children: namespaces.map((entry) {
        final (String namespace, IconData icon) = entry;
        return Material(
          color: colors.secondaryContainer.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () => toRoute(Routes.tagBrowser, arguments: namespace),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, color: colors.onSecondaryContainer),
                const SizedBox(height: 6),
                Text(namespace.tr, style: TextStyle(color: colors.onSecondaryContainer, fontSize: 13)),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildQuickSearches(BuildContext context) {
    return GetBuilder<QuickSearchService>(
      builder: (_) {
        final List<MapEntry<String, SearchConfig>> entries = quickSearchService.quickSearchConfigs.entries.toList();
        if (entries.isEmpty) {
          return Text('quickSearchEmptyHint'.tr, style: Theme.of(context).textTheme.bodySmall);
        }
        return Wrap(
          spacing: 8,
          runSpacing: 8,
          children: entries
              .map((e) => ActionChip(
                    avatar: const Icon(Icons.bolt, size: 18),
                    label: Text(e.key),
                    onPressed: () => newSearch(rewriteSearchConfig: e.value.copyWith(), forceNewRoute: true),
                  ))
              .toList(),
        );
      },
    );
  }
}
