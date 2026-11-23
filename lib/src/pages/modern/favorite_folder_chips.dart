import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/setting/favorite_setting.dart';

/// "All" plus one chip per favourites folder that has analysed galleries.
/// Hidden when the favourites are all in one folder.
class FavoriteFolderChips extends StatelessWidget {
  final int? selected;

  /// folder -> galleries
  final Map<int, int> counts;
  final ValueChanged<int?> onSelected;
  final bool enabled;

  const FavoriteFolderChips({super.key, required this.selected, required this.counts, required this.onSelected, this.enabled = true});

  static String folderName(int folder) {
    final List<String> names = favoriteSetting.favoriteTagNames;
    return folder < names.length && names[folder].isNotEmpty ? names[folder] : 'Favorite $folder';
  }

  @override
  Widget build(BuildContext context) {
    if (counts.length < 2) {
      return const SizedBox.shrink();
    }
    final int total = counts.values.fold(0, (a, b) => a + b);
    Widget chip(int? folder, String label, int count) => Padding(
          padding: const EdgeInsets.only(right: 8),
          child: ChoiceChip(
            label: Text('$label  $count'),
            selected: selected == folder,
            onSelected: enabled ? (_) => onSelected(folder) : null,
          ),
        );
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          chip(null, 'allFavorites'.tr, total),
          for (MapEntry<int, int> e in counts.entries) chip(e.key, folderName(e.key), e.value),
        ],
      ),
    );
  }
}
