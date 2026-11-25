import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';
import 'package:jhentai/src/extension/widget_extension.dart';
import 'package:jhentai/src/mixin/scroll_status_listener.dart';
import 'package:jhentai/src/mixin/scroll_status_listener_state.dart';
import 'package:jhentai/src/mixin/window_widget_mixin.dart';
import 'package:jhentai/src/model/read_page_info.dart';
import 'package:jhentai/src/pages/read/layout/horizontal_list/horizontal_list_layout.dart';
import 'package:jhentai/src/pages/read/layout/horizontal_page/horizontal_page_layout.dart';
import 'package:jhentai/src/pages/read/read_page_logic.dart';
import 'package:jhentai/src/pages/read/read_page_state.dart';
import 'package:jhentai/src/pages/read/translation_progress.dart';
import 'package:jhentai/src/service/super_resolution_service.dart';
import 'package:jhentai/src/service/image_translation_service.dart';
import 'package:jhentai/src/widget/eh_mouse_button_listener.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:window_manager/window_manager.dart';

import '../../config/ui_config.dart';
import '../../service/gallery_download/gallery_download_service.dart';
import '../../setting/keyboard_shortcut_setting.dart';
import '../../setting/read_setting.dart';
import '../../utils/route_util.dart';
import '../../utils/screen_size_util.dart';
import '../../widget/eh_image.dart';
import '../../widget/eh_keyboard_listener.dart';
import '../../widget/eh_read_page_stack.dart';
import '../../widget/eh_thumbnail.dart';
import '../../widget/eh_wheel_speed_controller_for_read_page.dart';
import '../../widget/loading_state_indicator.dart';
import 'layout/horizontal_double_column/horizontal_double_column_layout.dart';
import 'layout/vertical_list/vertical_list_layout.dart';

class ReadPage extends StatefulWidget {
  const ReadPage({super.key});

  @override
  State<ReadPage> createState() => _ReadPageState();
}

class _ReadPageState extends State<ReadPage>
    with ScrollStatusListener, WindowListener, WindowWidgetMixin {
  final ReadPageLogic logic = Get.put<ReadPageLogic>(ReadPageLogic());
  final ReadPageState state = Get.find<ReadPageLogic>().state;

  @override
  ScrollStatusListerState get scrollStatusListerState => state;

  @override
  Brightness? get titleBarBrightness => Brightness.dark;

  @override
  Color? get titleBarColor => Colors.black;

  @override
  double get fullScreenTopPadding => 0;

  @override
  Widget build(BuildContext context) {
    Widget child = AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarDividerColor: Colors.transparent,
        statusBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: Brightness.light,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
      ),
      child: Obx(
        () => EHMouseButtonListener(
          mouseHandlers: keyboardShortcutSetting.buildMouseHandlerMap(
            onToNext: logic.toNext,
            onToPrev: logic.toPrev,
            onToLeft: logic.toLeft,
            onToRight: logic.toRight,
            onBack: backRoute,
            onToggleMenu: logic.toggleMenu,
            onToggleFirstPageAlone: logic.handleM,
            onToggleFullScreen: toggleFullScreen,
          ),
          child: EHKeyboardListener(
            focusNode: state.focusNode,
            keyHandlers: {
              LogicalKeyboardKey.escape: backRoute,
              ...keyboardShortcutSetting.buildHandlerMap(
                onToNext: logic.toNext,
                onToPrev: logic.toPrev,
                onToLeft: logic.toLeft,
                onToRight: logic.toRight,
                onBack: backRoute,
                onToggleMenu: logic.toggleMenu,
                onToggleFirstPageAlone: logic.handleM,
                onToggleFullScreen: toggleFullScreen,
              ),
            },
            child: DefaultTextStyle(
              style: DefaultTextStyle.of(context).style.copyWith(
                    color: UIConfig.readPageForeGroundColor,
                    fontSize: 12,
                    decoration: TextDecoration.none,
                  ),
              child: Container(
                color: Colors.black,
                child: Stack(
                  children: [
                    EHReadPageStack(
                      children: [
                        buildGestureRegion(),
                        buildLayout(),
                      ],
                    ),
                    buildRightBottomInfo(context),
                    buildTopMenu(context),
                    buildTranslationProgress(context),
                    buildBottomMenu(context),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );

    return GetBuilder<ReadPageLogic>(
      id: logic.pageId,
      builder: (_) {
        if (readSetting.enableImmersiveMode.isFalse) {
          return buildWindow(child: child);
        }
        return child;
      },
    );
  }

  @override
  Widget buildWindow({required Widget child}) {
    return GetPlatform.isWindows
        ? buildWindowsTitle(child)
        : GetPlatform.isLinux
            ? buildLinuxTitle(child)
            : GetPlatform.isMacOS
                ? buildMaxOSTitle(child)
                : child;
  }

  /// Main region to display images
  Widget buildLayout() {
    Widget child = GetBuilder<ReadPageLogic>(
      id: logic.layoutId,
      builder: (_) {
        return LayoutBuilder(
          builder: (context, constraints) {
            logic.clearImageContainerSized();
            state.displayRegionSize =
                Size(constraints.maxWidth, constraints.maxHeight);

            if (logic.effectiveReadDirection == ReadDirection.top2bottomList) {
              return VerticalListLayout();
            }
            if (logic.isInListReadDirection) {
              return HorizontalListLayout();
            }
            if (logic.isInDoubleColumnReadDirection) {
              return HorizontalDoubleColumnLayout();
            }
            return HorizontalPageLayout();
          },
        );
      },
    );

    return wrapScrollListener(child);
  }

  /// right-bottom info
  Widget buildRightBottomInfo(BuildContext context) {
    return Positioned(
      bottom: 0,
      right: 0,
      child: Obx(
        () {
          if (readSetting.showStatusInfo.isFalse) {
            return const SizedBox();
          }

          Widget child = DefaultTextStyle(
            style: DefaultTextStyle.of(context).style.copyWith(
                  color: UIConfig.readPageForeGroundColor,
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  decoration: TextDecoration.none,
                ),
            child: Container(
              decoration: BoxDecoration(
                color: UIConfig.readPageRightBottomRegionColor,
                borderRadius:
                    const BorderRadius.only(topLeft: Radius.circular(8)),
              ),
              alignment: Alignment.center,
              padding:
                  const EdgeInsets.only(right: 32, bottom: 1, top: 3, left: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  _buildPageNoInfo().marginOnly(right: 10),
                  _buildCurrentTime().marginOnly(right: 10),
                  if (!GetPlatform.isDesktop) _buildBatteryLevel(),
                ],
              ),
            ),
          );

          return GetBuilder<ReadPageLogic>(
            id: logic.rightBottomInfoId,
            builder: (_) => state.isMenuOpen ? child.fadeOut() : child.fadeIn(),
          );
        },
      ),
    );
  }

  Widget _buildPageNoInfo() {
    return GetBuilder<ReadPageLogic>(
      id: logic.pageNoId,
      builder: (_) => Text(
          '${state.readPageInfo.currentImageIndex + 1}/${state.readPageInfo.pageCount}'),
    );
  }

  Widget _buildCurrentTime() {
    return GetBuilder<ReadPageLogic>(
      id: logic.currentTimeId,
      builder: (_) => Text(DateFormat('HH:mm').format(DateTime.now())),
    );
  }

  Widget _buildBatteryLevel() {
    return GetBuilder<ReadPageLogic>(
      id: logic.batteryId,
      builder: (_) => Text('${state.batteryLevel}%'),
    );
  }

  /// gesture for turn page and pop menu
  Widget buildGestureRegion() {
    return Row(
      children: [
        /// left region
        Expanded(
          flex: (100 - readSetting.gestureRegionWidthRatio.value) ~/ 2,
          child: GestureDetector(
              onTap: logic.tapLeftRegion, behavior: HitTestBehavior.opaque),
        ),

        /// center region
        Expanded(
          flex: readSetting.gestureRegionWidthRatio.value,
          child: GestureDetector(
              onTap: logic.tapCenterRegion, behavior: HitTestBehavior.opaque),
        ),

        /// right region: toRight
        Expanded(
            flex: (100 - readSetting.gestureRegionWidthRatio.value) ~/ 2,
            child: GestureDetector(
                onTap: logic.tapRightRegion, behavior: HitTestBehavior.opaque)),
      ],
    );
  }

  /// top menu
  /// Pages done, the step the current page is at, seconds per page and the
  /// time left, while translating and for a moment after.
  Widget buildTranslationProgress(BuildContext context) {
    return GetBuilder<ReadPageLogic>(
      id: logic.translationProgressId,
      builder: (_) => GetBuilder<ReadPageLogic>(
        id: logic.topMenuId,
        builder: (_) {
          final DateTime now = DateTime.now();
          final TranslationProgress p = logic.translationProgress;
          if (!p.visibleAt(now)) {
            return const SizedBox.shrink();
          }
          const TextStyle textStyle = TextStyle(color: Colors.white, fontSize: 13, decoration: TextDecoration.none);
          final TextStyle detailStyle = textStyle.copyWith(fontSize: 12, color: Colors.white70);

          final String title = !p.running
              ? 'translationProgressDone'.trParams({'done': '${p.done - p.failed}'})
              : p.total > 1
                  ? 'translationProgressRange'.trParams({'done': '${p.done}', 'total': '${p.total}'})
                  : 'translationProgressPage'.trParams({'page': '${(p.currentPage ?? 0) + 1}'});
          final double? perPage = p.secondsPerPage;
          final Duration? left = p.remaining(now);
          final List<String> details = [
            if (p.running && p.total > 1 && p.currentPage != null) 'translationProgressPage'.trParams({'page': '${p.currentPage! + 1}'}),
            if (p.running && p.stage != null) p.stage!.tr,
            if (p.running) 'translationProgressElapsed'.trParams({'time': _seconds(p.currentSeconds(now))}),
            if (perPage != null) 'translationProgressSpeed'.trParams({'time': _seconds(perPage)}),
            if (left != null && p.total > 1) 'translationProgressRemaining'.trParams({'time': _seconds(left.inMilliseconds / 1000)}),
            if (p.failed > 0) 'translationProgressFailed'.trParams({'count': '${p.failed}'}),
          ];

          return Positioned(
            top: (state.isMenuOpen ? UIConfig.appBarHeight : 0) + context.mediaQuery.padding.top + 8,
            left: 12,
            right: 12,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: Material(
                  color: Colors.black.withValues(alpha: 0.8),
                  borderRadius: BorderRadius.circular(12),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 8, 6, 10),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.translate, size: 16, color: Colors.white),
                            const SizedBox(width: 8),
                            Expanded(child: Text(title, style: textStyle)),
                            if (logic.isTranslationRangeRunning)
                              TextButton(
                                style: TextButton.styleFrom(
                                  foregroundColor: Colors.white,
                                  visualDensity: VisualDensity.compact,
                                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                ),
                                onPressed: logic.stopTranslationRange,
                                child: Text('stopTranslationRange'.tr),
                              )
                            else
                              const SizedBox(height: 32),
                          ],
                        ),
                        Padding(
                          padding: const EdgeInsets.only(right: 8, top: 2, bottom: 6),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(2),
                            child: LinearProgressIndicator(
                              value: p.running ? p.fraction(now) : 1,
                              minHeight: 4,
                              backgroundColor: Colors.white24,
                            ),
                          ),
                        ),
                        if (details.isNotEmpty) Text(details.join('  ·  '), style: detailStyle),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// "8.2 秒" / "1 分 12 秒"
  static String _seconds(double seconds) {
    if (seconds < 60) {
      return 'translationSeconds'.trParams({'s': seconds < 10 ? seconds.toStringAsFixed(1) : '${seconds.round()}'});
    }
    final int total = seconds.round();
    return 'translationMinutesSeconds'.trParams({'m': '${total ~/ 60}', 's': '${total % 60}'});
  }

  Widget buildTopMenu(BuildContext context) {
    return GetBuilder<ReadPageLogic>(
      id: logic.topMenuId,
      builder: (_) {
        // Slide the whole app bar (leading/title/actions together) in from the
        // top instead of animating its height. Growing the height only animates
        // the middle/trailing slots; the leading is laid out at full toolbar
        // height and pops in place.
        final double menuHeight =
            UIConfig.appBarHeight + context.mediaQuery.padding.top;
        return AnimatedPositioned(
          duration: const Duration(milliseconds: 200),
          curve: Curves.ease,
          top: state.isMenuOpen ? 0 : -menuHeight,
          height: menuHeight,
          width: fullScreenWidth,
          child: AppBar(
            backgroundColor: UIConfig.readPageMenuColor,
            title: Text(state.readPageInfo.galleryTitle,
                style: const TextStyle(color: UIConfig.readPageButtonColor)),
            leading: const BackButton(color: UIConfig.readPageButtonColor),
            actions: [
              GetBuilder<ImageTranslationService>(
                id: imageTranslationService.updateId(
                    state.readPageInfo, state.readPageInfo.currentImageIndex),
                builder: (_) {
                  final ImageTranslationEntry entry =
                      logic.currentTranslationEntry;
                  if (entry.status == ImageTranslationStatus.translating &&
                      !logic.isTranslationRangeRunning) {
                    return const SizedBox(
                      width: 56,
                      height: 56,
                      child: Center(
                          child: SizedBox(
                              width: 22,
                              height: 22,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2))),
                    );
                  }
                  return PopupMenuButton<String>(
                    tooltip: 'imageTranslation'.tr,
                    icon: Icon(
                      Icons.translate,
                      color: entry.status == ImageTranslationStatus.success &&
                              state.showTranslatedImages
                          ? UIConfig.readPageActiveButtonColor(context)
                          : UIConfig.readPageButtonColor,
                    ),
                    onSelected: (value) {
                      if (value == 'translate') {
                        logic.translateCurrentPage();
                      } else if (value == 'range') {
                        logic.showTranslationRangeDialog(context);
                      } else if (value == 'stopRange') {
                        logic.stopTranslationRange();
                      } else if (value == 'toggle') {
                        logic.toggleTranslatedImages();
                      } else if (value == 'settings') {
                        logic.openTranslationSetting();
                      }
                    },
                    itemBuilder: (_) => [
                      PopupMenuItem(
                          value: 'translate',
                          child: Text('translateCurrentPage'.tr)),
                      if (!logic.isTranslationRangeRunning)
                        PopupMenuItem(
                            value: 'range',
                            child: Text('translatePageRange'.tr))
                      else ...[
                        PopupMenuItem<String>(
                            enabled: false,
                            child: Text(
                                '${'translatingPageRange'.tr} ${logic.translationRangeProgress}')),
                        PopupMenuItem(
                            value: 'stopRange',
                            child: Text('stopTranslationRange'.tr)),
                      ],
                      if (entry.status == ImageTranslationStatus.success)
                        PopupMenuItem(
                          value: 'toggle',
                          child: Text(state.showTranslatedImages
                              ? 'showOriginalImage'.tr
                              : 'showTranslatedImage'.tr),
                        ),
                      PopupMenuItem(
                          value: 'settings',
                          child: Text('translationSettings'.tr)),
                    ],
                  );
                },
              ),
              if (GetPlatform.isDesktop &&
                  state.readPageInfo.gid != null &&
                  (state.readPageInfo.mode == ReadMode.downloaded ||
                      state.readPageInfo.mode == ReadMode.archive) &&
                  state.readPageInfo.useSuperResolution)
                TextButton(
                  child: GetBuilder<SuperResolutionService>(
                    id: '${SuperResolutionService.superResolutionId}::${state.readPageInfo.gid}',
                    builder: (_) => Text(
                      'AI' + logic.getSuperResolutionProgress(),
                      style: TextStyle(
                        fontSize: 18,
                        color: state.useSuperResolution
                            ? UIConfig.readPageActiveButtonColor(context)
                            : UIConfig.readPageButtonColor,
                      ),
                    ),
                  ),
                  onPressed: logic.handleTapSuperResolutionButton,
                  style: TextButton.styleFrom(
                    minimumSize: const Size(56, 56),
                  ),
                ),
              Obx(() {
                if (!logic.isInDoubleColumnReadDirection) {
                  return const SizedBox();
                }
                return ElevatedButton(
                  child: Icon(
                    Icons.looks_one,
                    // ElevatedButton M3 default iconSize (18) shrinks a bare child Icon; pin size explicitly
                    size: 24,
                    color: state.displayFirstPageAlone
                        ? UIConfig.readPageActiveButtonColor(context)
                        : UIConfig.readPageButtonColor,
                  ),
                  onPressed: logic.toggleDisplayFirstPageAlone,
                  style: ElevatedButton.styleFrom(
                    elevation: 0,
                    padding: const EdgeInsets.all(0),
                    surfaceTintColor: Colors.transparent,
                    backgroundColor: Colors.transparent,
                    shadowColor: Colors.transparent,
                    minimumSize: const Size(56, 56),
                  ),
                );
              }),
              GetBuilder<ReadPageLogic>(
                id: logic.autoModeId,
                builder: (_) => ElevatedButton(
                  child: Icon(Icons.schedule,
                      size: 24,
                      color: state.autoMode
                          ? UIConfig.readPageActiveButtonColor(context)
                          : UIConfig.readPageButtonColor),
                  onPressed: logic.toggleAutoMode,
                  style: ElevatedButton.styleFrom(
                    elevation: 0,
                    padding: const EdgeInsets.all(0),
                    surfaceTintColor: Colors.transparent,
                    backgroundColor: Colors.transparent,
                    shadowColor: Colors.transparent,
                    minimumSize: const Size(56, 56),
                  ),
                ),
              ),
              if (readSetting.enableBottomMenu.isFalse)
                ElevatedButton(
                  child: const Icon(Icons.settings,
                      size: 24, color: UIConfig.readPageButtonColor),
                  onPressed: () => logic.openReadSetting(context),
                  style: ElevatedButton.styleFrom(
                    elevation: 0,
                    padding: const EdgeInsets.all(0),
                    surfaceTintColor: Colors.transparent,
                    backgroundColor: Colors.transparent,
                    shadowColor: Colors.transparent,
                    minimumSize: const Size(56, 56),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  /// bottom menu
  Widget buildBottomMenu(BuildContext context) {
    return GetBuilder<ReadPageLogic>(
      id: logic.bottomMenuId,
      builder: (_) => Obx(
        () => AnimatedPositioned(
          duration: const Duration(milliseconds: 200),
          curve: Curves.ease,
          bottom: state.isMenuOpen
              ? 0
              : (readSetting.showThumbnails.isTrue
                      ? -UIConfig.readPageBottomThumbnailsRegionHeight
                      : 0) -
                  UIConfig.readPageBottomSliderHeight -
                  (readSetting.enableBottomMenu.isTrue
                      ? UIConfig.readPageBottomActionHeight
                      : 0) -
                  max(MediaQuery.of(context).viewPadding.bottom,
                      UIConfig.readPageBottomSpacingHeight),
          child: ColoredBox(
            color: UIConfig.readPageMenuColor,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (readSetting.showThumbnails.isTrue)
                  Offstage(
                      offstage: !state.isMenuOpen,
                      child: _buildThumbnails(context)),
                _buildSlider(),
                if (readSetting.enableBottomMenu.isTrue) _buildBottomAction(),
                SizedBox(
                    height: max(MediaQuery.of(context).viewPadding.bottom,
                        UIConfig.readPageBottomSpacingHeight)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildThumbnails(BuildContext context) {
    return SizedBox(
      width: fullScreenWidth,
      height: UIConfig.readPageBottomThumbnailsRegionHeight,
      child: Obx(
        () => EHWheelSpeedControllerForReadPage(
          scrollOffsetController: state.thumbnailsScrollOffsetController,
          stopScrollWhenCtrlPressed: false,
          child: ScrollablePositionedList.separated(
            scrollDirection: Axis.horizontal,
            reverse: logic.isInRight2LeftDirection,
            physics: const ClampingScrollPhysics(),
            minCacheExtent: 1 * fullScreenWidth,
            initialScrollIndex: state.readPageInfo.initialIndex,
            itemCount: state.readPageInfo.pageCount,
            itemScrollController: state.thumbnailsScrollController,
            itemPositionsListener: state.thumbnailPositionsListener,
            scrollOffsetController: state.thumbnailsScrollOffsetController,
            itemBuilder: (_, index) => GetBuilder<ReadPageLogic>(
              id: logic.thumbnailNoId,
              builder: (_) => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 6),
                  SizedBox(
                    height: UIConfig.readPageThumbnailHeight,
                    width: UIConfig.readPageThumbnailWidth,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => logic.jump2ImageIndex(index),
                      child: state.readPageInfo.mode == ReadMode.online
                          ? _buildThumbnailInOnlineMode(context, index)
                          : _buildThumbnailInLocalMode(context, index),
                    ),
                  ),
                  const SizedBox(height: 4),
                  GetBuilder<ReadPageLogic>(
                    builder: (_) => Center(
                      child: Container(
                        width: 24,
                        decoration: BoxDecoration(
                          color: state.readPageInfo.currentImageIndex == index
                              ? UIConfig
                                  .readPageBottomCurrentImageHighlightBackgroundColor(
                                      context)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          (index + 1).toString(),
                          style: TextStyle(
                            fontSize: 9,
                            color: state.readPageInfo.currentImageIndex == index
                                ? UIConfig
                                    .readPageBottomCurrentImageHighlightForegroundColor(
                                        context)
                                : null,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const Expanded(child: SizedBox()),
                ],
              ),
            ),
            separatorBuilder: (_, __) => const SizedBox(width: 6),
          ),
        ).enableMouseDrag(withScrollBar: false),
      ),
    );
  }

  Widget _buildThumbnailInOnlineMode(BuildContext context, int index) {
    return GetBuilder<ReadPageLogic>(
      id: '${logic.onlineImageId}::$index',
      builder: (_) {
        if (state.thumbnails[index] == null) {
          if (state.parseImageHrefsStates[index] == LoadingState.idle) {
            logic.beginToParseImageHref(index);
          }

          return Center(child: UIConfig.loadingAnimation(context));
        }

        return LayoutBuilder(
          builder: (_, constraints) => EHThumbnail(
            thumbnail: state.thumbnails[index]!,
            containerHeight: constraints.maxHeight,
            containerWidth: constraints.maxWidth,
            borderRadius: BorderRadius.circular(8),
          ),
        );
      },
    );
  }

  Widget _buildThumbnailInLocalMode(BuildContext context, int index) {
    return GetBuilder<GalleryDownloadService>(
      id: '${galleryDownloadService.downloadImageId}::${state.readPageInfo.gid}::$index',
      builder: (_) {
        if (state.images[index]?.downloadStatus != DownloadStatus.downloaded) {
          return Center(child: UIConfig.loadingAnimation(context));
        }
        return LayoutBuilder(
          builder: (_, constraints) => EHImage(
            galleryImage: state.images[index]!,
            containerHeight: constraints.maxHeight,
            containerWidth: constraints.maxWidth,
            borderRadius: BorderRadius.circular(8),
            maxBytes: 1024 * 50,
            disableAnimation: true,
          ),
        );
      },
    );
  }

  Widget _buildSlider() {
    return GetBuilder<ReadPageLogic>(
      id: logic.sliderId,
      builder: (_) => SizedBox(
        height: UIConfig.readPageBottomSliderHeight,
        width: fullScreenWidth,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text(logic.isInRight2LeftDirection
                    ? state.readPageInfo.pageCount.toString()
                    : (state.readPageInfo.currentImageIndex + 1).toString())
                .marginOnly(left: 36, right: 4),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ExcludeFocus(
                    child: Material(
                      color: Colors.transparent,
                      child: RotatedBox(
                        quarterTurns: logic.isInRight2LeftDirection ? 2 : 0,
                        child: Slider(
                          min: 1,
                          max: state.readPageInfo.pageCount.toDouble(),
                          value: state.readPageInfo.currentImageIndex + 1.0,
                          thumbColor: UIConfig.readPageForeGroundColor,
                          onChanged: logic.handleSlide,
                          onChangeEnd: logic.handleSlideEnd,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Text(logic.isInRight2LeftDirection
                    ? (state.readPageInfo.currentImageIndex + 1).toString()
                    : state.readPageInfo.pageCount.toString())
                .marginOnly(right: 36, left: 4),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomAction() {
    final ReadDirection effectiveDirection = logic.effectiveReadDirection;

    return SizedBox(
      height: UIConfig.readPageBottomActionHeight,
      width: fullScreenWidth,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          Material(
            color: Colors.transparent,
            child: PopupMenuButton<ReadDirection>(
              initialValue: effectiveDirection,
              icon:
                  const Icon(Icons.height, color: UIConfig.readPageButtonColor),
              itemBuilder: (_) => ReadDirection.values
                  .map(
                    (e) => PopupMenuItem<ReadDirection>(
                        child: Text(e.name.tr), value: e),
                  )
                  .toList(),
              onSelected: (ReadDirection value) =>
                  logic.saveReadDirection(value),
            ),
          ),
          Material(
            color: Colors.transparent,
            child: PopupMenuButton<DeviceDirection>(
              initialValue: readSetting.deviceDirection.value,
              icon: const Icon(Icons.screen_rotation,
                  color: UIConfig.readPageButtonColor),
              itemBuilder: (_) => DeviceDirection.values
                  .map(
                    (e) => PopupMenuItem<DeviceDirection>(
                        child: Text(e.name.tr), value: e),
                  )
                  .toList(),
              onSelected: (DeviceDirection value) {
                readSetting.saveDeviceDirection(value);
                logic.onEffectiveSettingChanged();
              },
            ),
          ),
          GestureDetector(
            child: AbsorbPointer(
              child: Material(
                color: Colors.transparent,
                child: PopupMenuButton(
                  icon: const Icon(Icons.settings,
                      color: UIConfig.readPageButtonColor),
                  itemBuilder: (_) => [],
                ),
              ),
            ),
            onTap: () => logic.openReadSetting(context),
          ),
        ],
      ),
    );
  }
}
