import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/config/ui_config.dart';
import 'package:jhentai/src/l18n/locale_text.dart';
import 'package:jhentai/src/model/search_config.dart';
import 'package:jhentai/src/pages/modern/find_page.dart';
import 'package:jhentai/src/pages/modern/follow_page.dart';
import 'package:jhentai/src/pages/modern/taste_view.dart';
import 'package:jhentai/src/service/follow_service.dart';
import 'package:jhentai/src/service/quick_search_service.dart';
import 'package:jhentai/src/service/taste_service.dart';
import 'package:jhentai/src/setting/user_setting.dart';

/// Renders the modern layout's pages at phone size to PNG files for review.
///
///   JHENTAI_RENDER_FONT=<cjk .ttf> JHENTAI_UI_OUT=<dir> flutter test test/modern_ui_render_test.dart
///
/// Needs the Material icon font of the Flutter SDK (found next to the flutter
/// executable) so icons are drawn instead of boxes.
void main() {
  final String? font = Platform.environment['JHENTAI_RENDER_FONT'];
  final String? out = Platform.environment['JHENTAI_UI_OUT'];
  final bool skip = font == null || out == null;

  Future<void> loadFonts() async {
    final FontLoader cjk = FontLoader('TestCJK')..addFont(Future.value(ByteData.sublistView(File(font!).readAsBytesSync())));
    await cjk.load();
    final String flutterRoot = File(Platform.resolvedExecutable).parent.parent.parent.parent.parent.parent.path;
    final File icons = File('$flutterRoot/bin/cache/artifacts/material_fonts/materialicons-regular.otf');
    final FontLoader material = FontLoader('MaterialIcons')..addFont(Future.value(ByteData.sublistView(icons.readAsBytesSync())));
    await material.load();
  }

  Future<void> render(WidgetTester tester, String name, Widget page) async {
    tester.view.physicalSize = const Size(390 * 2, 844 * 2);
    tester.view.devicePixelRatio = 2;
    final GlobalKey key = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(
      key: key,
      child: GetMaterialApp(
        debugShowCheckedModeBanner: false,
        translations: LocaleText(),
        locale: const Locale('zh', 'CN'),
        theme: ThemeData(useMaterial3: true, colorSchemeSeed: UIConfig.defaultLightThemeColor, fontFamily: 'TestCJK'),
        home: page,
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.runAsync(() async {
      final RenderRepaintBoundary boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final ui.Image image = await boundary.toImage(pixelRatio: 2);
      final ByteData? png = await image.toByteData(format: ui.ImageByteFormat.png);
      File('$out/$name.png').writeAsBytesSync(png!.buffer.asUint8List());
    });
  }

  setUpAll(() {
    Get.put(quickSearchService);
    Get.put(followService);
    Get.put(tasteService);
    quickSearchService.quickSearchConfigs['汉化组 · 某某汉化'] = SearchConfig(keyword: 'uploader:"someone"');
    quickSearchService.quickSearchConfigs['全彩 中文'] = SearchConfig(keyword: 'language:chinese other:"full color\$"');
  });

  testWidgets('find page', (tester) async {
    await tester.runAsync(loadFonts);
    await render(tester, 'find', const FindPage());
  }, skip: skip);

  testWidgets('follow page', (tester) async {
    await tester.runAsync(loadFonts);
    followService.lastCheckTime = DateTime.now(); // no network in tests
    followService.entries = [
      FollowEntry(namespace: 'uploader', key: 'example_group', newCount: 3),
      FollowEntry(namespace: 'artist', key: 'example artist', label: '示例画师', newCount: 1),
      FollowEntry(namespace: 'group', key: 'example circle', label: '示例社团'),
      FollowEntry(namespace: 'female', key: 'glasses', label: '眼镜'),
    ];
    await render(tester, 'follow', const FollowPage());
  }, skip: skip);

  testWidgets('taste view', (tester) async {
    await tester.runAsync(loadFonts);
    userSetting.ipbMemberId.value = 1;
    tasteService.galleries = {for (int i = 0; i < 128; i++) i: TasteGallery(gid: i, token: 'abcdefghij', title: '', category: 'Manga', tags: const [])};
    tasteService.updateTime = DateTime(2026, 11, 22, 21, 30);
    tasteService.sections = {
      TasteSection.artist: [TasteItem('artist', 'artist a', 12, label: '画师A'), TasteItem('artist', 'artist b', 8, label: '画师B'), TasteItem('artist', 'artist c', 5)],
      TasteSection.group: [TasteItem('group', 'circle a', 9, label: '社团A'), TasteItem('group', 'circle b', 4)],
      TasteSection.uploader: [TasteItem('uploader', 'example_group', 21), TasteItem('uploader', 'another_group', 7)],
      TasteSection.tag: [
        TasteItem('female', 'glasses', 30, label: '眼镜'),
        TasteItem('female', 'ponytail', 18, label: '马尾'),
        TasteItem('other', 'full color', 15, label: '全彩'),
        TasteItem('male', 'teacher', 6, label: '老师'),
      ],
    };
    await render(tester, 'taste', const Scaffold(body: SafeArea(child: TasteView())));
  }, skip: skip);
}
