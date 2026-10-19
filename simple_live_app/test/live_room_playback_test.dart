import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_core/simple_live_core.dart';

const _originalUrls = [
  'https://stream.example/primary.flv',
  'https://stream.example/backup.flv',
];
const _refreshedUrls = [
  'https://stream.example/primary.flv?token=new',
  'https://stream.example/backup.flv?token=new',
];
const _wakelockChannel =
    'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final activeControllers = <_TestRoomController>[];

  void testWidgets(
    String description,
    Future<void> Function(WidgetTester) callback,
  ) {
    _playbackTest(description, (tester) async {
      try {
        await callback(tester);
      } finally {
        for (final controller in activeControllers) {
          controller.disposeForTest();
        }
        activeControllers.clear();
      }
    });
  }

  setUp(() {
    Get.testMode = true;
    Get.put<AppSettingsController>(_TestSettingsController());
    binding.defaultBinaryMessenger.setMockMessageHandler(
      _wakelockChannel,
      (_) async => const StandardMessageCodec().encodeMessage([null]),
    );
  });

  tearDown(() {
    binding.defaultBinaryMessenger
        .setMockMessageHandler(_wakelockChannel, null);
    Get.reset();
  });

  _TestRoomController createController(_TestLiveSite site, {int line = 0}) {
    final controller = _TestRoomController(site)
      ..detail.value = _roomDetail(signature: 'old')
      ..liveStatus.value = true
      ..currentQuality = 0
      ..currentLineIndex = line;
    controller.qualites.assignAll([_quality()]);
    controller.currentQualityInfo.value = 'Source';
    controller.playUrls.assignAll(_originalUrls);
    controller.fakePlayer.currentPlaylist =
        Playlist(_originalUrls.map(Media.new).toList(), index: line);
    activeControllers.add(controller);
    return controller;
  }

  Future<void> completePlayback(_TestRoomController controller) {
    controller.fakePlayer.completed = true;
    return controller.mediaEnd();
  }

  Future<void> advancePlayback(
    WidgetTester tester,
    _TestRoomController controller,
    int seconds,
  ) async {
    for (var second = 0; second < seconds; second += 1) {
      controller.fakePlayer.position += const Duration(seconds: 1);
      await tester.pump(const Duration(seconds: 1));
    }
  }

  testWidgets('refresh keeps current lines and ignores old media events',
      (tester) async {
    final pendingUrls = Completer<LivePlayUrl>();
    final site = _TestLiveSite()..requestUrls = () => pendingUrls.future;
    final controller = createController(site);

    final refresh = controller.getPlayUrl();
    await controller.mediaEnd();
    await controller.mediaError('old connection closed');

    expect(controller.playUrls, _originalUrls);
    expect(controller.currentLineIndex, 0);
    expect(controller.liveStatus.value, isTrue);
    expect(site.urlRequests, 1);
    expect(site.detailRequests, 0);

    controller.fakePlayer.onOpen = () {
      unawaited(controller.mediaEnd());
      unawaited(controller.mediaError('old media unloaded'));
    };
    pendingUrls.complete(LivePlayUrl(urls: _refreshedUrls));
    await refresh;
    for (var second = 1; second <= 5; second += 1) {
      controller.fakePlayer.position = Duration(seconds: second);
      await tester.pump(const Duration(seconds: 1));
    }

    expect(controller.playUrls, _refreshedUrls);
    expect(controller.fakePlayer.openedUris, [_refreshedUrls.first]);
    expect(controller.liveStatus.value, isTrue);
    expect(controller.mediaErrorRetryCount, 0);
    expect(site.urlRequests, 1);
  });

  testWidgets('opens all playlist lines with selected index headers and HTTPS',
      (tester) async {
    const headers = {'Referer': 'https://platform.example/room'};
    final site = _TestLiveSite();
    site.requestUrls = () async => LivePlayUrl(
          urls: [
            'http://stream.example/primary.flv',
            'http://stream.example/backup.flv',
          ],
          headers: headers,
        );
    AppSettingsController.instance.playerForceHttps.value = true;
    final controller = createController(site, line: 1);

    await controller.getPlayUrl(preserveLine: true);

    final playlist = controller.fakePlayer.openedPlaylists.single;
    expect(playlist.index, 1);
    expect(playlist.medias.map((media) => media.uri), _originalUrls);
    expect(
        playlist.medias.map((media) => media.httpHeaders), [headers, headers]);
    expect(controller.fakePlayer.jumpedIndexes, isEmpty);
    expect(controller.currentLineIndex, 1);
    expect(site.urlRequests, 1);
  });

  testWidgets('native playlist advancement preserves the pending retry budget',
      (tester) async {
    final site = _TestLiveSite();
    final controller = createController(site)..mediaErrorRetryCount = 2;
    controller.fakePlayer.currentPlaylist = Playlist(
      _originalUrls.map(Media.new).toList(),
      index: 1,
    );

    controller.syncPlayLine();

    expect(controller.currentLineIndex, 1);
    expect(controller.mediaErrorRetryCount, 2);
    expect(controller.fakePlayer.openedUris, isEmpty);
    expect(controller.fakePlayer.jumpedIndexes, isEmpty);
    await completePlayback(controller);
    expect(controller.fakePlayer.jumpedIndexes, isEmpty);
    expect(controller.fakePlayer.openedUris, [_refreshedUrls.last]);
    expect(controller.mediaErrorRetryCount, 3);
    expect(site.urlRequests, 1);
    expect(site.detailRequests, 1);
  });

  testWidgets('a native backup restores retries only after stable playback',
      (tester) async {
    final controller = createController(_TestLiveSite())
      ..mediaErrorRetryCount = 2;
    controller.fakePlayer.currentPlaylist = Playlist(
      _originalUrls.map(Media.new).toList(),
      index: 1,
    );
    await Future<void>.microtask(controller.syncPlayLine);

    expect(controller.currentLineIndex, 1);
    expect(controller.mediaErrorRetryCount, 2);
    controller.onPlayingChanged(true);
    await advancePlayback(tester, controller, 9);
    expect(controller.mediaErrorRetryCount, 2);
    await advancePlayback(tester, controller, 1);
    expect(controller.mediaErrorRetryCount, 0);
    expect(controller.fakePlayer.jumpedIndexes, isEmpty);
  });

  testWidgets('native line changes interrupt consecutive healthy samples',
      (tester) async {
    final controller = createController(_TestLiveSite())
      ..mediaErrorRetryCount = 2;
    controller.onPlayingChanged(true);
    await advancePlayback(tester, controller, 5);

    controller.fakePlayer.currentPlaylist = Playlist(
      _originalUrls.map(Media.new).toList(),
      index: 1,
    );
    controller.fakePlayer.position = Duration.zero;
    await Future<void>.microtask(controller.syncPlayLine);
    await tester.pump(const Duration(seconds: 1));
    await advancePlayback(tester, controller, 9);
    expect(controller.mediaErrorRetryCount, 2);
    await advancePlayback(tester, controller, 1);

    expect(controller.mediaErrorRetryCount, 0);
    expect(controller.fakePlayer.jumpedIndexes, isEmpty);
  });

  testWidgets(
      'stale native playlists cannot replace the current line selection',
      (tester) async {
    final controller = createController(_TestLiveSite())
      ..mediaErrorRetryCount = 2;
    controller.fakePlayer.currentPlaylist = Playlist(
      _refreshedUrls.map(Media.new).toList(),
      index: 1,
    );

    controller.syncPlayLine();

    expect(controller.currentLineIndex, 0);
    expect(controller.mediaErrorRetryCount, 2);
  });

  testWidgets('an old-line error preserves an advancing native backup',
      (tester) async {
    final site = _TestLiveSite();
    final controller = createController(site);
    controller.fakePlayer.currentPlaylist = Playlist(
      _originalUrls.map(Media.new).toList(),
      index: 1,
    );
    controller.syncPlayLine();

    final oldError = controller.mediaError('old primary connection warning');
    for (var second = 1; second <= 5; second += 1) {
      controller.fakePlayer.position = Duration(seconds: second);
      await tester.pump(const Duration(seconds: 1));
    }
    await oldError;

    expect(controller.currentLineIndex, 1);
    expect(controller.fakePlayer.currentPlaylist.index, 1);
    expect(controller.fakePlayer.openedUris, isEmpty);
    expect(controller.fakePlayer.jumpedIndexes, isEmpty);
    expect(site.detailRequests, 0);
    expect(site.urlRequests, 0);
  });

  testWidgets('temporary native index changes during jump do not reset retries',
      (tester) async {
    final controller = createController(_TestLiveSite(), line: 1);
    int? lineDuringJump;
    int? retriesDuringJump;
    controller.fakePlayer.onJump = () {
      final targetPlaylist = controller.fakePlayer.currentPlaylist;
      controller.fakePlayer.currentPlaylist = Playlist(targetPlaylist.medias);
      controller.syncPlayLine();
      lineDuringJump = controller.currentLineIndex;
      retriesDuringJump = controller.mediaErrorRetryCount;
      controller.fakePlayer.currentPlaylist = targetPlaylist;
    };

    await completePlayback(controller);

    expect(lineDuringJump, 1);
    expect(retriesDuringJump, 1);
    expect(controller.currentLineIndex, 1);
    expect(controller.fakePlayer.currentPlaylist.index, 1);
    expect(controller.mediaErrorRetryCount, 1);
    expect(controller.fakePlayer.jumpedIndexes, [1]);
  });

  for (final missingPlaylist in [false, true]) {
    testWidgets(
        'manual selection rebuilds a ${missingPlaylist ? 'missing' : 'stale'} actual playlist',
        (tester) async {
      final site = _TestLiveSite();
      final controller = createController(site);
      controller.fakePlayer.currentPlaylist = missingPlaylist
          ? const Playlist([])
          : Playlist(_refreshedUrls.map(Media.new).toList());

      await controller.changePlayLine(1);

      final playlist = controller.fakePlayer.openedPlaylists.single;
      expect(playlist.medias.map((media) => media.uri), _originalUrls);
      expect(playlist.index, 1);
      expect(controller.fakePlayer.jumpedIndexes, isEmpty);
      expect(controller.currentLineIndex, 1);
      expect(site.detailRequests, 0);
      expect(site.urlRequests, 0);
    });
  }

  testWidgets(
      'native advancement during playlist opening is synchronized after load',
      (tester) async {
    final site = _TestLiveSite();
    final controller = createController(site);
    controller.fakePlayer.onOpen = () {
      final playlist = controller.fakePlayer.currentPlaylist;
      controller.fakePlayer.currentPlaylist =
          Playlist(playlist.medias, index: 1);
      controller.syncPlayLine();
      unawaited(controller.mediaError('old primary warning'));
    };

    await controller.getPlayUrl();
    for (var second = 1; second <= 5; second += 1) {
      controller.fakePlayer.position = Duration(seconds: second);
      await tester.pump(const Duration(seconds: 1));
    }

    expect(controller.currentLineIndex, 1);
    expect(controller.fakePlayer.currentPlaylist.index, 1);
    expect(controller.fakePlayer.openedPlaylists, hasLength(1));
    expect(controller.fakePlayer.jumpedIndexes, isEmpty);
    expect(site.urlRequests, 1);
    expect(site.detailRequests, 0);
    expect(controller.mediaErrorRetryCount, 0);
  });

  testWidgets('a stale completed event does not restart current playing media',
      (tester) async {
    final site = _TestLiveSite();
    final controller = createController(site);

    await controller.mediaEnd();

    expect(controller.fakePlayer.openedUris, isEmpty);
    expect(site.detailRequests, 0);
    expect(controller.mediaErrorRetryCount, 0);
  });

  testWidgets('player log errors do not restart media that continues advancing',
      (tester) async {
    final site = _TestLiveSite();
    final controller = createController(site);

    final error = controller.mediaError('mpv warning');
    for (var second = 1; second <= 5; second += 1) {
      controller.fakePlayer.position = Duration(seconds: second);
      await tester.pump(const Duration(seconds: 1));
    }
    await error;

    expect(controller.fakePlayer.openedUris, isEmpty);
    expect(controller.fakePlayer.jumpedIndexes, isEmpty);
    expect(controller.mediaErrorRetryCount, 0);
    expect(site.urlRequests, 0);
    expect(controller.liveStatus.value, isTrue);
  });

  testWidgets(
      'coalesces repeated stalled errors into one current-line reconnect',
      (tester) async {
    final site = _TestLiveSite();
    final controller = createController(site);

    final error = controller.mediaError('connection stalled');
    final duplicate = controller.mediaError('duplicate warning');
    await tester.pump(const Duration(seconds: 4));
    expect(controller.fakePlayer.openedUris, isEmpty);
    await tester.pump(const Duration(seconds: 1));
    await Future.wait([error, duplicate]);

    expect(controller.fakePlayer.openedUris, isEmpty);
    expect(controller.fakePlayer.jumpedIndexes, [0]);
    expect(controller.mediaErrorRetryCount, 1);
    expect(site.urlRequests, 0);
    expect(site.detailRequests, 0);
  });

  testWidgets('brief initial progress does not hide a later stalled connection',
      (tester) async {
    final controller = createController(_TestLiveSite());
    final error = controller.mediaError('connection warning');
    controller.fakePlayer.position = const Duration(seconds: 1);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 4));
    expect(controller.fakePlayer.openedUris, isEmpty);
    await tester.pump(const Duration(seconds: 1));
    await error;

    expect(controller.fakePlayer.openedUris, isEmpty);
    expect(controller.fakePlayer.jumpedIndexes, [0]);
    expect(controller.mediaErrorRetryCount, 1);
  });

  testWidgets('backward timestamps do not dismiss an error observation',
      (tester) async {
    final controller = createController(_TestLiveSite());
    controller.fakePlayer.position = const Duration(seconds: 10);
    final error = controller.mediaError('timestamp discontinuity');

    for (var second = 1; second <= 5; second += 1) {
      controller.fakePlayer.position = Duration(seconds: 10 - second);
      await tester.pump(const Duration(seconds: 1));
    }
    await error;

    expect(controller.fakePlayer.jumpedIndexes, [0]);
    expect(controller.mediaErrorRetryCount, 1);
  });

  testWidgets('advancing timestamps dismiss errors even while buffering',
      (tester) async {
    final site = _TestLiveSite();
    final controller = createController(site)..mediaErrorRetryCount = 2;
    controller.fakePlayer.buffering = true;
    final error = controller.mediaError('buffered transport warning');

    await advancePlayback(tester, controller, 5);
    await error;

    expect(controller.fakePlayer.jumpedIndexes, isEmpty);
    expect(controller.fakePlayer.openedUris, isEmpty);
    expect(controller.mediaErrorRetryCount, 2);
    expect(site.detailRequests, 0);
    expect(site.urlRequests, 0);
  });

  testWidgets('native next rebases an outstanding error observation',
      (tester) async {
    final controller = createController(_TestLiveSite());
    controller.fakePlayer.position = const Duration(seconds: 100);
    final warning = controller.mediaError('old primary warning');
    await tester.pump(const Duration(seconds: 4));

    controller.fakePlayer.currentPlaylist = Playlist(
      _originalUrls.map(Media.new).toList(),
      index: 1,
    );
    controller.fakePlayer.position = Duration.zero;
    controller.syncPlayLine();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 4));
    expect(controller.fakePlayer.jumpedIndexes, isEmpty);
    await tester.pump(const Duration(seconds: 1));
    await warning;

    expect(controller.currentLineIndex, 1);
    expect(controller.fakePlayer.jumpedIndexes, [1]);
    expect(controller.mediaErrorRetryCount, 1);
  });

  testWidgets('an error while deliberately paused does not resume playback',
      (tester) async {
    final controller = createController(_TestLiveSite());
    controller.fakePlayer.playing = false;

    await controller.mediaError('late player warning');
    await tester.pump(const Duration(seconds: 6));

    expect(controller.fakePlayer.openedUris, isEmpty);
    expect(controller.fakePlayer.playing, isFalse);
    expect(controller.mediaErrorRetryCount, 0);
  });

  testWidgets(
      'completed media immediately reconnects the existing current line',
      (tester) async {
    final site = _TestLiveSite();
    final controller = createController(site, line: 1);

    await completePlayback(controller);

    expect(controller.fakePlayer.openedUris, isEmpty);
    expect(controller.fakePlayer.jumpedIndexes, [1]);
    expect(controller.currentLineIndex, 1);
    expect(controller.mediaErrorRetryCount, 1);
    expect(site.detailRequests, 0);
    expect(site.urlRequests, 0);
    expect(controller.liveStatus.value, isTrue);
  });

  testWidgets(
      'second completed failure delays then jumps without refreshing URLs',
      (tester) async {
    final site = _TestLiveSite();
    final controller = createController(site, line: 1)
      ..mediaErrorRetryCount = 1;

    final retry = completePlayback(controller);
    expect(controller.fakePlayer.jumpedIndexes, isEmpty);
    await tester.pump(const Duration(seconds: 1));
    await retry;

    expect(controller.fakePlayer.openedUris, isEmpty);
    expect(controller.fakePlayer.jumpedIndexes, [1]);
    expect(controller.mediaErrorRetryCount, 2);
    expect(site.detailRequests, 0);
    expect(site.urlRequests, 0);
  });

  testWidgets(
      'progress during a delayed retry preserves the resumed connection',
      (tester) async {
    final site = _TestLiveSite();
    final controller = createController(site)..mediaErrorRetryCount = 1;
    controller.fakePlayer.position = const Duration(seconds: 10);

    final retry = completePlayback(controller);
    controller.fakePlayer.completed = false;
    controller.fakePlayer.buffering = true;
    controller.fakePlayer.position = const Duration(seconds: 11);
    await tester.pump(const Duration(seconds: 1));
    await retry;

    expect(controller.fakePlayer.jumpedIndexes, isEmpty);
    expect(controller.fakePlayer.openedUris, isEmpty);
    expect(controller.mediaErrorRetryCount, 2);
    expect(controller.currentLineIndex, 0);
    expect(site.detailRequests, 0);
    expect(site.urlRequests, 0);
  });

  testWidgets('native next during a delayed retry preserves the new line',
      (tester) async {
    final site = _TestLiveSite();
    final controller = createController(site)..mediaErrorRetryCount = 1;
    controller.fakePlayer.position = const Duration(seconds: 100);

    final retry = completePlayback(controller);
    controller.fakePlayer.currentPlaylist = Playlist(
      _originalUrls.map(Media.new).toList(),
      index: 1,
    );
    controller.fakePlayer.completed = false;
    controller.fakePlayer.position = Duration.zero;
    await tester.pump(const Duration(seconds: 1));
    await retry;

    expect(controller.fakePlayer.jumpedIndexes, isEmpty);
    expect(controller.fakePlayer.openedUris, isEmpty);
    expect(controller.mediaErrorRetryCount, 2);
    expect(controller.currentLineIndex, 1);
    expect(site.detailRequests, 0);
    expect(site.urlRequests, 0);
  });

  testWidgets('completion cancels a pending warning check without double retry',
      (tester) async {
    final controller = createController(_TestLiveSite());
    final warning = controller.mediaError('connection stalled');

    await completePlayback(controller);
    await warning;
    await tester.pump(const Duration(seconds: 6));

    expect(controller.fakePlayer.openedUris, isEmpty);
    expect(controller.fakePlayer.jumpedIndexes, [0]);
    expect(controller.mediaErrorRetryCount, 1);
  });

  testWidgets('new errors do not inherit an older completed-media observation',
      (tester) async {
    final site = _TestLiveSite();
    final controller = createController(site);
    final oldWarning = controller.mediaError('old connection warning');
    var firstOpen = true;
    controller.fakePlayer.onJump = () {
      if (firstOpen) {
        firstOpen = false;
        unawaited(controller.mediaError('new connection failed to advance'));
      }
    };

    controller.fakePlayer.completed = true;
    await controller.mediaError('completed connection');
    await oldWarning;
    expect(controller.fakePlayer.openedUris, isEmpty);
    expect(controller.fakePlayer.jumpedIndexes, [0]);
    await tester.pump(const Duration(seconds: 5));
    expect(controller.mediaErrorRetryCount, 2);
    await tester.pump(const Duration(seconds: 1));

    expect(site.detailRequests, 0);
    expect(controller.fakePlayer.openedUris, isEmpty);
    expect(controller.fakePlayer.jumpedIndexes, [0, 0]);
  });

  testWidgets('continuous failure refreshes room signatures quality and URLs',
      (tester) async {
    final site = _TestLiveSite();
    site.requestDetail = () async => _roomDetail(signature: 'new');
    site.requestQualities = () async => [
          _quality(name: 'Low', signature: 'new-low'),
          _quality(signature: 'new-source'),
        ];
    final controller = createController(site, line: 1)
      ..mediaErrorRetryCount = 2;

    final retry = completePlayback(controller);
    await tester.pump(const Duration(seconds: 1));
    await retry;

    expect(site.detailRequests, 1);
    expect(site.qualityDetails.single.data, 'new');
    expect(site.urlDetails.single.data, 'new');
    expect(site.urlQualities.single.data, 'new-source');
    expect(controller.currentQuality, 1);
    expect(controller.currentQualityInfo.value, 'Source');
    expect(controller.currentLineIndex, 1);
    expect(controller.fakePlayer.openedUris, [_refreshedUrls.last]);
    expect(controller.mediaErrorRetryCount, 3);
  });

  testWidgets('manual line selection invalidates a delayed second retry',
      (tester) async {
    final site = _TestLiveSite();
    final controller = createController(site)..mediaErrorRetryCount = 1;

    final retry = completePlayback(controller);
    await controller.changePlayLine(1);
    await tester.pump(const Duration(seconds: 1));
    await retry;

    expect(site.detailRequests, 0);
    expect(site.urlRequests, 0);
    expect(controller.currentLineIndex, 1);
    expect(controller.mediaErrorRetryCount, 0);
    expect(controller.fakePlayer.openedUris, isEmpty);
    expect(controller.fakePlayer.jumpedIndexes, [1]);
  });

  testWidgets('manual selection invalidates an already pending room refresh',
      (tester) async {
    final pendingDetail = Completer<LiveRoomDetail>();
    final site = _TestLiveSite()..requestDetail = () => pendingDetail.future;
    final controller = createController(site)..mediaErrorRetryCount = 2;

    final retry = completePlayback(controller);
    await tester.pump(const Duration(seconds: 1));
    expect(site.detailRequests, 1);
    await controller.changePlayLine(1);
    pendingDetail.complete(_roomDetail(signature: 'stale'));
    await retry;

    expect(controller.detail.value!.data, 'old');
    expect(site.urlRequests, 0);
    expect(controller.currentLineIndex, 1);
    expect(controller.fakePlayer.openedUris, isEmpty);
    expect(controller.fakePlayer.jumpedIndexes, [1]);
  });

  testWidgets(
      'three automatic attempts stop after the refreshed stream also fails',
      (tester) async {
    final site = _TestLiveSite();
    final controller = createController(site);

    await completePlayback(controller);
    final secondRetry = completePlayback(controller);
    await tester.pump(const Duration(seconds: 1));
    await secondRetry;
    expect(controller.fakePlayer.jumpedIndexes, [0, 0]);
    await completePlayback(controller);

    expect(controller.mediaErrorRetryCount, 3);
    expect(controller.fakePlayer.openedUris, [_refreshedUrls.first]);
    expect(controller.fakePlayer.stopCalls, 0);
    expect(site.detailRequests, 1);
    expect(site.urlRequests, 1);

    controller.fakePlayer.onStop = () {
      controller.fakePlayer.completed = true;
      unawaited(controller.mediaEnd());
      unawaited(controller.mediaError('late stop callback'));
    };
    await completePlayback(controller);
    for (var event = 0; event < 50; event += 1) {
      await controller.mediaError('late decoder callback');
      await completePlayback(controller);
    }
    await tester.pump(const Duration(minutes: 3));

    expect(controller.fakePlayer.jumpedIndexes, [0, 0]);
    expect(controller.fakePlayer.openedUris, [_refreshedUrls.first]);
    expect(controller.fakePlayer.stopCalls, 1);
    expect(controller.mediaErrorRetryCount, 3);
    expect(controller.liveStatus.value, isTrue);
    expect(controller.errorMsg.value, contains('手动刷新'));
    expect(site.detailRequests, 1);
    expect(site.urlRequests, 1);
  });

  testWidgets(
      'exhausted retries stop instead of opening another available line',
      (tester) async {
    final site = _TestLiveSite();
    final controller = createController(site)..mediaErrorRetryCount = 3;

    await completePlayback(controller);
    await tester.pump(const Duration(minutes: 3));

    expect(controller.currentLineIndex, 0);
    expect(controller.fakePlayer.jumpedIndexes, isEmpty);
    expect(controller.fakePlayer.openedUris, isEmpty);
    expect(controller.fakePlayer.stopCalls, 1);
    expect(controller.liveStatus.value, isTrue);
    expect(controller.errorMsg.value, contains('手动刷新'));
    expect(site.detailRequests, 0);
    expect(site.urlRequests, 0);
  });

  testWidgets(
      'the third connection stops only after an error confirms a freeze',
      (tester) async {
    final site = _TestLiveSite();
    final controller = createController(site)..mediaErrorRetryCount = 3;
    final harmless = controller.mediaError('old warning on refreshed stream');
    await advancePlayback(tester, controller, 5);
    await harmless;
    expect(controller.fakePlayer.stopCalls, 0);

    final failed = controller.mediaError('refreshed stream stopped');
    await tester.pump(const Duration(seconds: 4));
    expect(controller.fakePlayer.stopCalls, 0);
    await tester.pump(const Duration(seconds: 1));
    await failed;

    expect(controller.fakePlayer.stopCalls, 1);
    expect(controller.fakePlayer.jumpedIndexes, isEmpty);
    expect(controller.fakePlayer.openedUris, isEmpty);
    expect(controller.mediaErrorRetryCount, 3);
    expect(controller.errorMsg.value, contains('手动刷新'));
    expect(controller.liveStatus.value, isTrue);
    expect(site.detailRequests, 0);
    expect(site.urlRequests, 0);
  });

  testWidgets('late native playback cannot unlock an exhausted retry cap',
      (tester) async {
    final site = _TestLiveSite();
    final controller = createController(site)..mediaErrorRetryCount = 3;
    await completePlayback(controller);

    controller.fakePlayer.playing = true;
    controller.fakePlayer.completed = false;
    controller.onPlayingChanged(true);
    await advancePlayback(tester, controller, 20);
    await completePlayback(controller);

    expect(controller.mediaErrorRetryCount, 3);
    expect(controller.errorMsg.value, contains('手动刷新'));
    expect(controller.fakePlayer.stopCalls, 1);
    expect(controller.fakePlayer.jumpedIndexes, isEmpty);
    expect(controller.fakePlayer.openedUris, isEmpty);
    expect(site.detailRequests, 0);
    expect(site.urlRequests, 0);
  });

  testWidgets(
      'failed player operations consume only the three remaining attempts',
      (tester) async {
    final site = _TestLiveSite();
    final controller = createController(site);
    controller.fakePlayer.onJump = () => throw StateError('jump failed');
    controller.fakePlayer.onOpen = () => throw StateError('open failed');

    final recovery = completePlayback(controller);
    expect(controller.fakePlayer.jumpedIndexes, [0]);
    await tester.pump(const Duration(seconds: 1));
    await recovery;
    await tester.pump(const Duration(minutes: 3));

    expect(controller.fakePlayer.jumpedIndexes, [0, 0]);
    expect(controller.fakePlayer.openedPlaylists, hasLength(1));
    expect(controller.fakePlayer.stopCalls, 1);
    expect(controller.mediaErrorRetryCount, 3);
    expect(controller.liveStatus.value, isTrue);
    expect(controller.errorMsg.value, contains('手动刷新'));
    expect(site.detailRequests, 1);
    expect(site.urlRequests, 1);
  });

  for (final failedStage in ['detail', 'quality', 'url', 'open']) {
    testWidgets('a failed third $failedStage attempt waits for manual refresh',
        (tester) async {
      final site = _TestLiveSite();
      final controller = createController(site)..mediaErrorRetryCount = 2;
      if (failedStage == 'detail') {
        site.requestDetail = () async => throw StateError('detail failed');
      } else if (failedStage == 'quality') {
        site.requestQualities = () async => throw StateError('quality failed');
      } else if (failedStage == 'url') {
        site.requestUrls = () async => throw StateError('url failed');
      } else {
        controller.fakePlayer.onOpen = () => throw StateError('open failed');
      }

      await completePlayback(controller);
      final requests = site.detailRequests;
      await controller.mediaError('late failure');
      await completePlayback(controller);
      await tester.pump(const Duration(minutes: 3));

      expect(controller.mediaErrorRetryCount, 3);
      expect(controller.fakePlayer.stopCalls, 1);
      expect(controller.fakePlayer.jumpedIndexes, isEmpty);
      expect(controller.liveStatus.value, isTrue);
      expect(controller.errorMsg.value, contains('手动刷新'));
      expect(site.detailRequests, requests);
      expect(site.detailRequests, 1);
      expect(site.urlRequests, lessThanOrEqualTo(1));
    });
  }

  testWidgets(
      'callbacks inside automatic operations cannot exceed the retry cap',
      (tester) async {
    final site = _TestLiveSite();
    final controller = createController(site);
    void emitFailures() {
      controller.fakePlayer.completed = true;
      for (var event = 0; event < 10; event += 1) {
        unawaited(controller.mediaEnd());
        unawaited(controller.mediaError('operation callback'));
      }
    }

    controller.fakePlayer.onJump = emitFailures;
    controller.fakePlayer.onOpen = emitFailures;

    final recovery = completePlayback(controller);
    await tester.pump(const Duration(seconds: 1));
    await recovery;
    await tester.pump();
    await tester.pump(const Duration(minutes: 3));

    expect(controller.fakePlayer.jumpedIndexes, [0, 0]);
    expect(controller.fakePlayer.openedPlaylists, hasLength(1));
    expect(controller.fakePlayer.stopCalls, 1);
    expect(controller.mediaErrorRetryCount, 3);
    expect(controller.liveStatus.value, isTrue);
    expect(controller.errorMsg.value, contains('手动刷新'));
    expect(site.detailRequests, 1);
    expect(site.urlRequests, 1);
  });

  for (final manualAction in ['urls', 'qualities', 'line']) {
    testWidgets('manual $manualAction resets a stopped automatic retry cap',
        (tester) async {
      final site = _TestLiveSite();
      final controller = createController(site)..mediaErrorRetryCount = 3;
      await completePlayback(controller);
      expect(controller.errorMsg.value, contains('手动刷新'));

      if (manualAction == 'urls') {
        await controller.getPlayUrl();
      } else if (manualAction == 'qualities') {
        await controller.getPlayQualites();
      } else {
        await controller.changePlayLine(1);
        expect(controller.fakePlayer.jumpedIndexes, isEmpty);
        final playlist = controller.fakePlayer.openedPlaylists.single;
        expect(playlist.index, 1);
        expect(playlist.medias.map((media) => media.uri), _originalUrls);
        expect(site.detailRequests, 0);
        expect(site.urlRequests, 0);
      }
      expect(controller.mediaErrorRetryCount, 0);
      expect(controller.errorMsg.value, isEmpty);
      expect(controller.fakePlayer.playing, isTrue);
      await completePlayback(controller);

      expect(controller.mediaErrorRetryCount, 1);
      expect(controller.fakePlayer.jumpedIndexes.last,
          controller.currentLineIndex);
      expect(controller.fakePlayer.stopCalls, 1);
      expect(controller.liveStatus.value, isTrue);
    });
  }

  testWidgets('a newly entered room starts with an independent retry budget',
      (tester) async {
    final stopped = createController(_TestLiveSite())..mediaErrorRetryCount = 3;
    await completePlayback(stopped);
    final fresh = createController(_TestLiveSite());

    await completePlayback(fresh);
    await stopped.mediaError('old room callback');

    expect(fresh.fakePlayer.jumpedIndexes, [0]);
    expect(fresh.mediaErrorRetryCount, 1);
    expect(fresh.fakePlayer.stopCalls, 0);
    expect(stopped.fakePlayer.stopCalls, 1);
    expect(stopped.errorMsg.value, contains('手动刷新'));
  });

  testWidgets('only platform confirmation marks a refreshed room offline',
      (tester) async {
    final site = _TestLiveSite()
      ..requestDetail = () async => _roomDetail(status: false);
    final controller = createController(site)..mediaErrorRetryCount = 2;

    await completePlayback(controller);

    expect(site.detailRequests, 1);
    expect(controller.liveStatus.value, isFalse);
    expect(controller.fakePlayer.stopCalls, 1);
    expect(site.urlRequests, 0);
  });

  testWidgets(
      'a recorded stream survives false live status on the third attempt',
      (tester) async {
    final site = _TestLiveSite()
      ..requestDetail = () async => _roomDetail(status: false, isRecord: true);
    final controller = createController(site)..mediaErrorRetryCount = 2;

    await completePlayback(controller);

    expect(controller.liveStatus.value, isTrue);
    expect(controller.detail.value!.isRecord, isTrue);
    expect(controller.fakePlayer.stopCalls, 0);
    expect(controller.fakePlayer.openedUris, [_refreshedUrls.first]);
    expect(controller.mediaErrorRetryCount, 3);
  });

  testWidgets('new media completing inside open still receives a recovery',
      (tester) async {
    final site = _TestLiveSite();
    final controller = createController(site);
    var firstOpen = true;
    controller.fakePlayer.onOpen = () {
      if (firstOpen) {
        firstOpen = false;
        controller.fakePlayer.completed = true;
        unawaited(controller.mediaEnd());
      }
    };

    await controller.getPlayUrl();
    await tester.pump();

    expect(site.urlRequests, 1);
    expect(controller.fakePlayer.openedUris, [_refreshedUrls.first]);
    expect(controller.fakePlayer.jumpedIndexes, [0]);
    expect(controller.fakePlayer.completed, isFalse);
    expect(controller.mediaErrorRetryCount, 1);
    expect(controller.liveStatus.value, isTrue);
  });

  testWidgets('an error during open is recovered if playback never advances',
      (tester) async {
    final site = _TestLiveSite();
    final controller = createController(site);
    var firstOpen = true;
    controller.fakePlayer.onOpen = () {
      if (firstOpen) {
        firstOpen = false;
        unawaited(controller.mediaError('new connection failed to advance'));
      }
    };

    await controller.getPlayUrl();
    await tester.pump(const Duration(seconds: 4));
    expect(controller.fakePlayer.openedUris, [_refreshedUrls.first]);
    await tester.pump(const Duration(seconds: 1));

    expect(controller.fakePlayer.openedUris, [_refreshedUrls.first]);
    expect(controller.fakePlayer.jumpedIndexes, [0]);
    expect(site.urlRequests, 1);
    expect(controller.mediaErrorRetryCount, 1);
  });

  testWidgets('backgrounding cancels an outstanding error observation',
      (tester) async {
    final controller = createController(_TestLiveSite());
    final warning = controller.mediaError('connection warning');
    await tester.pump(const Duration(seconds: 2));

    controller.didChangeAppLifecycleState(AppLifecycleState.paused);
    await warning;
    await tester.pump(const Duration(seconds: 6));

    expect(controller.fakePlayer.openedUris, isEmpty);
    expect(controller.mediaErrorRetryCount, 0);
  });

  testWidgets('backgrounding cancels a delayed automatic retry',
      (tester) async {
    final site = _TestLiveSite();
    final controller = createController(site)..mediaErrorRetryCount = 1;
    final retry = completePlayback(controller);

    controller.didChangeAppLifecycleState(AppLifecycleState.paused);
    await tester.pump(const Duration(seconds: 1));
    await retry;
    await tester.pump(const Duration(minutes: 3));

    expect(site.detailRequests, 0);
    expect(site.urlRequests, 0);
    expect(controller.fakePlayer.jumpedIndexes, isEmpty);
    expect(controller.fakePlayer.openedUris, isEmpty);
  });

  testWidgets('background resume cannot clear a stopped automatic retry cap',
      (tester) async {
    final site = _TestLiveSite();
    final controller = createController(site)..mediaErrorRetryCount = 3;
    await completePlayback(controller);

    controller.didChangeAppLifecycleState(AppLifecycleState.paused);
    await controller.mediaError('late background error');
    await tester.pump(const Duration(minutes: 3));
    controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump(const Duration(seconds: 10));
    await completePlayback(controller);

    expect(controller.mediaErrorRetryCount, 3);
    expect(controller.fakePlayer.stopCalls, 1);
    expect(controller.fakePlayer.jumpedIndexes, isEmpty);
    expect(controller.fakePlayer.openedUris, isEmpty);
    expect(controller.errorMsg.value, contains('手动刷新'));
    expect(controller.liveStatus.value, isTrue);
    expect(site.detailRequests, 0);
    expect(site.urlRequests, 0);
  });

  testWidgets(
      'a failed background refresh stops without a foreground retry chain',
      (tester) async {
    final pendingUrls = Completer<LivePlayUrl>();
    final site = _TestLiveSite()..requestUrls = () => pendingUrls.future;
    final controller = createController(site);
    final oldLoad = controller.getPlayUrl();
    controller.didChangeAppLifecycleState(AppLifecycleState.paused);
    pendingUrls.complete(LivePlayUrl(urls: _refreshedUrls));
    await oldLoad;
    site.requestDetail = () async => throw StateError('resume API failed');

    controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump(const Duration(minutes: 3));
    await controller.mediaError('late resume failure');
    await completePlayback(controller);

    expect(controller.fakePlayer.stopCalls, 1);
    expect(controller.fakePlayer.jumpedIndexes, isEmpty);
    expect(controller.fakePlayer.openedUris, isEmpty);
    expect(controller.errorMsg.value, contains('手动刷新'));
    expect(controller.liveStatus.value, isTrue);
    expect(site.detailRequests, 1);
    expect(site.urlRequests, 1);
  });

  testWidgets('closing cancels error observations and delayed retries',
      (tester) async {
    final observed = createController(_TestLiveSite());
    final warning = observed.mediaError('connection warning');
    final retrySite = _TestLiveSite();
    final retrying = createController(retrySite)..mediaErrorRetryCount = 1;
    final retry = completePlayback(retrying);

    observed.onDelete();
    retrying.onDelete();
    await tester.pump(const Duration(seconds: 1));
    await Future.wait([warning, retry]);
    await tester.pump(const Duration(minutes: 3));

    expect(observed.fakePlayer.jumpedIndexes, isEmpty);
    expect(retrying.fakePlayer.jumpedIndexes, isEmpty);
    expect(retrying.fakePlayer.openedUris, isEmpty);
    expect(retrySite.detailRequests, 0);
    expect(observed.fakePlayer.disposeCalls, 1);
    expect(retrying.fakePlayer.disposeCalls, 1);
  });

  testWidgets('ten seconds of stable playback restores the retry budget',
      (tester) async {
    final controller = createController(_TestLiveSite())
      ..mediaErrorRetryCount = 2;

    controller.onPlayingChanged(true);
    await advancePlayback(tester, controller, 9);
    expect(controller.mediaErrorRetryCount, 2);
    await advancePlayback(tester, controller, 1);
    expect(controller.mediaErrorRetryCount, 0);
  });

  testWidgets('one timestamp jump does not count as ten healthy samples',
      (tester) async {
    final controller = createController(_TestLiveSite())
      ..mediaErrorRetryCount = 2;

    controller.onPlayingChanged(true);
    await tester.pump(const Duration(seconds: 9));
    controller.fakePlayer.position = const Duration(seconds: 100);
    await tester.pump(const Duration(seconds: 1));

    expect(controller.mediaErrorRetryCount, 2);
    expect(controller.fakePlayer.jumpedIndexes, isEmpty);
  });

  testWidgets('brief progress followed by a freeze does not restore retries',
      (tester) async {
    final controller = createController(_TestLiveSite())
      ..mediaErrorRetryCount = 2;

    controller.onPlayingChanged(true);
    await advancePlayback(tester, controller, 1);
    await tester.pump(const Duration(seconds: 9));

    expect(controller.mediaErrorRetryCount, 2);
    expect(controller.fakePlayer.jumpedIndexes, isEmpty);
  });

  testWidgets('playing without progress does not restore the retry budget',
      (tester) async {
    final controller = createController(_TestLiveSite())
      ..mediaErrorRetryCount = 2;

    controller.onPlayingChanged(true);
    await tester.pump(const Duration(seconds: 11));

    expect(controller.mediaErrorRetryCount, 2);
  });

  testWidgets('interrupted playback does not restore the retry budget',
      (tester) async {
    final controller = createController(_TestLiveSite())
      ..mediaErrorRetryCount = 2;

    controller.onPlayingChanged(true);
    await advancePlayback(tester, controller, 9);
    controller.fakePlayer.playing = false;
    controller.onPlayingChanged(false);
    await tester.pump(const Duration(seconds: 2));

    expect(controller.mediaErrorRetryCount, 2);
  });

  testWidgets('buffering restarts the ten-second stable playback interval',
      (tester) async {
    final controller = createController(_TestLiveSite())
      ..mediaErrorRetryCount = 2;

    controller.onPlayingChanged(true);
    await advancePlayback(tester, controller, 9);
    controller.fakePlayer.buffering = true;
    controller.onBufferingChanged(true);
    await tester.pump(const Duration(seconds: 11));
    expect(controller.mediaErrorRetryCount, 2);

    controller.fakePlayer.buffering = false;
    controller.onBufferingChanged(false);
    await advancePlayback(tester, controller, 9);
    expect(controller.mediaErrorRetryCount, 2);
    await advancePlayback(tester, controller, 1);
    expect(controller.mediaErrorRetryCount, 0);
  });

  testWidgets('buffering between stable samples still interrupts stability',
      (tester) async {
    final controller = createController(_TestLiveSite())
      ..mediaErrorRetryCount = 2;
    controller.onPlayingChanged(true);
    await advancePlayback(tester, controller, 9);

    controller.fakePlayer.buffering = true;
    controller.onBufferingChanged(true);
    await tester.pump(const Duration(milliseconds: 100));
    controller.fakePlayer.buffering = false;
    controller.onBufferingChanged(false);
    controller.fakePlayer.position += const Duration(seconds: 1);
    await tester.pump(const Duration(milliseconds: 900));
    expect(controller.mediaErrorRetryCount, 2);
    await advancePlayback(tester, controller, 9);
    expect(controller.mediaErrorRetryCount, 2);
    await advancePlayback(tester, controller, 1);

    expect(controller.mediaErrorRetryCount, 0);
    expect(controller.fakePlayer.jumpedIndexes, isEmpty);
  });

  for (final buffering in [false, true]) {
    testWidgets(
        'four minutes of silent frozen playback with buffering=$buffering never reload',
        (tester) async {
      final site = _TestLiveSite();
      final controller = createController(site)..mediaErrorRetryCount = 2;
      controller.fakePlayer.buffering = buffering;
      controller.onPlayingChanged(true);
      controller.onBufferingChanged(buffering);

      await tester.pump(const Duration(minutes: 4));

      expect(controller.fakePlayer.jumpedIndexes, isEmpty);
      expect(controller.fakePlayer.openedUris, isEmpty);
      expect(controller.fakePlayer.stopCalls, 0);
      expect(controller.mediaErrorRetryCount, 2);
      expect(controller.liveStatus.value, isTrue);
      expect(controller.errorMsg.value, isEmpty);
      expect(site.detailRequests, 0);
      expect(site.urlRequests, 0);
    });
  }

  testWidgets('a cleared error observation cannot reload a later silent freeze',
      (tester) async {
    final site = _TestLiveSite();
    final controller = createController(site);
    controller.onPlayingChanged(true);
    final warning = controller.mediaError('old harmless warning');
    await advancePlayback(tester, controller, 5);
    await warning;

    await tester.pump(const Duration(minutes: 4));

    expect(controller.fakePlayer.jumpedIndexes, isEmpty);
    expect(controller.fakePlayer.openedUris, isEmpty);
    expect(controller.fakePlayer.stopCalls, 0);
    expect(site.detailRequests, 0);
    expect(site.urlRequests, 0);
  });

  for (final freezeSample in [false, true]) {
    testWidgets(
        'four minutes of ${freezeSample ? 'one-second stalls' : 'brief buffering'} every eight seconds preserve playback',
        (tester) async {
      final site = _TestLiveSite();
      final controller = createController(site)..mediaErrorRetryCount = 2;
      controller.onPlayingChanged(true);

      for (var cycle = 0; cycle < 30; cycle += 1) {
        controller.fakePlayer.buffering = true;
        controller.onBufferingChanged(true);
        if (freezeSample) {
          await tester.pump(const Duration(seconds: 1));
        } else {
          await tester.pump(const Duration(milliseconds: 100));
        }
        controller.fakePlayer.buffering = false;
        controller.onBufferingChanged(false);
        if (!freezeSample) {
          controller.fakePlayer.position += const Duration(seconds: 1);
          await tester.pump(const Duration(milliseconds: 900));
        }
        await advancePlayback(tester, controller, 7);

        expect(controller.fakePlayer.jumpedIndexes, isEmpty);
        expect(controller.fakePlayer.openedUris, isEmpty);
        expect(site.detailRequests, 0);
        expect(site.urlRequests, 0);
      }

      expect(controller.liveStatus.value, isTrue);
      expect(controller.mediaErrorRetryCount, 2);
    });
  }

  testWidgets('advancing playback ignores a persistent buffering flag',
      (tester) async {
    final site = _TestLiveSite();
    final controller = createController(site)..mediaErrorRetryCount = 2;
    controller.fakePlayer.buffering = true;
    controller.onBufferingChanged(true);

    await advancePlayback(tester, controller, 120);

    expect(controller.fakePlayer.jumpedIndexes, isEmpty);
    expect(controller.fakePlayer.openedUris, isEmpty);
    expect(controller.mediaErrorRetryCount, 2);
    expect(site.detailRequests, 0);
    expect(site.urlRequests, 0);
  });

  testWidgets('native line changes cannot turn a silent freeze into a reload',
      (tester) async {
    final site = _TestLiveSite();
    final controller = createController(site)..mediaErrorRetryCount = 2;
    controller.fakePlayer.position = const Duration(seconds: 100);
    controller.onPlayingChanged(true);
    await tester.pump(const Duration(seconds: 14));

    controller.fakePlayer.currentPlaylist = Playlist(
      _originalUrls.map(Media.new).toList(),
      index: 1,
    );
    controller.fakePlayer.position = Duration.zero;
    controller.syncPlayLine();
    await tester.pump(const Duration(minutes: 4));

    expect(controller.currentLineIndex, 1);
    expect(controller.fakePlayer.jumpedIndexes, isEmpty);
    expect(controller.fakePlayer.openedUris, isEmpty);
    expect(controller.fakePlayer.stopCalls, 0);
    expect(controller.mediaErrorRetryCount, 2);
    expect(site.detailRequests, 0);
    expect(site.urlRequests, 0);
  });

  testWidgets('ten healthy samples clear earlier short buffering',
      (tester) async {
    final controller = createController(_TestLiveSite())
      ..mediaErrorRetryCount = 2;
    controller.fakePlayer.buffering = true;
    controller.onBufferingChanged(true);
    await tester.pump(const Duration(seconds: 3));

    controller.fakePlayer.buffering = false;
    controller.onBufferingChanged(false);
    await advancePlayback(tester, controller, 10);
    expect(controller.mediaErrorRetryCount, 0);
    controller.fakePlayer.buffering = true;
    controller.onBufferingChanged(true);
    await tester.pump(const Duration(seconds: 14));

    expect(controller.fakePlayer.jumpedIndexes, isEmpty);
  });

  testWidgets('duplicate playing and buffering events never create a retry',
      (tester) async {
    final site = _TestLiveSite();
    final controller = createController(site)..mediaErrorRetryCount = 2;
    controller.fakePlayer.buffering = true;
    controller.onBufferingChanged(true);

    for (var second = 0; second < 240; second += 1) {
      await tester.pump(const Duration(seconds: 1));
      controller.onPlayingChanged(true);
      controller.onBufferingChanged(true);
    }

    expect(controller.fakePlayer.jumpedIndexes, isEmpty);
    expect(controller.fakePlayer.openedUris, isEmpty);
    expect(controller.fakePlayer.stopCalls, 0);
    expect(controller.mediaErrorRetryCount, 2);
    expect(site.detailRequests, 0);
    expect(site.urlRequests, 0);
  });

  testWidgets('paused playback ignores a stale buffering flag', (tester) async {
    final controller = createController(_TestLiveSite());
    controller.fakePlayer.buffering = true;
    controller.onBufferingChanged(true);
    await tester.pump(const Duration(seconds: 14));

    controller.fakePlayer.playing = false;
    controller.onPlayingChanged(false);
    controller.onBufferingChanged(true);
    await tester.pump(const Duration(seconds: 30));

    expect(controller.fakePlayer.jumpedIndexes, isEmpty);
    expect(controller.fakePlayer.playing, isFalse);
    expect(controller.mediaErrorRetryCount, 0);
  });

  for (final close in [false, true]) {
    testWidgets(
        '${close ? 'closing' : 'backgrounding'} cancels stable retry budget observation',
        (tester) async {
      final site = _TestLiveSite();
      final controller = createController(site)..mediaErrorRetryCount = 2;
      controller.onPlayingChanged(true);
      await advancePlayback(tester, controller, 9);

      if (close) {
        controller.onDelete();
      } else {
        controller.didChangeAppLifecycleState(AppLifecycleState.paused);
      }
      controller.fakePlayer.position = const Duration(seconds: 100);
      await tester.pump(const Duration(minutes: 3));

      expect(controller.mediaErrorRetryCount, 2);
      expect(controller.fakePlayer.jumpedIndexes, isEmpty);
      expect(controller.fakePlayer.openedUris, isEmpty);
      expect(site.detailRequests, 0);
      expect(site.urlRequests, 0);
    });
  }

  testWidgets('open and retry jumps cannot arm silent playback recovery',
      (tester) async {
    final site = _TestLiveSite();
    final controller = createController(site);

    await controller.getPlayUrl();
    await tester.pump(const Duration(minutes: 3));
    expect(controller.fakePlayer.jumpedIndexes, isEmpty);
    await completePlayback(controller);
    await tester.pump(const Duration(minutes: 3));
    expect(controller.fakePlayer.jumpedIndexes, [0]);
    expect(controller.mediaErrorRetryCount, 1);

    final secondRetry = completePlayback(controller);
    await tester.pump(const Duration(seconds: 1));
    await secondRetry;
    await tester.pump(const Duration(minutes: 3));
    expect(controller.fakePlayer.jumpedIndexes, [0, 0]);
    expect(controller.mediaErrorRetryCount, 2);
    await completePlayback(controller);
    await tester.pump(const Duration(minutes: 3));

    expect(controller.fakePlayer.jumpedIndexes, [0, 0]);
    expect(controller.fakePlayer.openedPlaylists, hasLength(2));
    expect(controller.fakePlayer.stopCalls, 0);
    expect(controller.mediaErrorRetryCount, 3);
    expect(site.detailRequests, 1);
    expect(site.urlRequests, 2);
  });

  testWidgets(
      'stable playback restores the three-attempt budget after a reload',
      (tester) async {
    final site = _TestLiveSite();
    final controller = createController(site)..mediaErrorRetryCount = 2;
    await completePlayback(controller);
    expect(controller.mediaErrorRetryCount, 3);

    await advancePlayback(tester, controller, 9);
    expect(controller.mediaErrorRetryCount, 3);
    await advancePlayback(tester, controller, 1);
    expect(controller.mediaErrorRetryCount, 0);
    await completePlayback(controller);

    expect(controller.mediaErrorRetryCount, 1);
    expect(controller.fakePlayer.jumpedIndexes, [0]);
    expect(controller.fakePlayer.stopCalls, 0);
    expect(site.detailRequests, 1);
    expect(site.urlRequests, 1);
  });

  testWidgets('resume replaces a URL request interrupted by the background',
      (tester) async {
    final pendingUrls = Completer<LivePlayUrl>();
    final pendingDetail = Completer<LiveRoomDetail>();
    final site = _TestLiveSite();
    site.requestUrls = () => pendingUrls.future;
    site.requestDetail = () => pendingDetail.future;
    final controller = createController(site);

    final oldRefresh = controller.getPlayUrl();
    controller.didChangeAppLifecycleState(AppLifecycleState.paused);
    pendingUrls
        .complete(LivePlayUrl(urls: ['https://stream.example/stale.flv']));
    await oldRefresh;
    await completePlayback(controller);

    expect(controller.fakePlayer.openedUris, isEmpty);
    site.requestUrls = () async => LivePlayUrl(urls: _refreshedUrls);
    controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await controller.mediaError('old background connection');
    expect(site.detailRequests, 1);
    expect(site.urlRequests, 1);

    pendingDetail.complete(_roomDetail(signature: 'resume'));
    await tester.pump();

    expect(site.urlRequests, 2);
    expect(controller.fakePlayer.openedUris, [_refreshedUrls.first]);
    expect(controller.detail.value!.data, 'resume');
    expect(controller.liveStatus.value, isTrue);
    for (var second = 1; second <= 5; second += 1) {
      controller.fakePlayer.position = Duration(seconds: second);
      await tester.pump(const Duration(seconds: 1));
    }
  });
}

void _playbackTest(
  String description,
  Future<void> Function(WidgetTester) callback,
) {
  testWidgets(description, callback);
}

LivePlayQuality _quality({String name = 'Source', String signature = 'old'}) =>
    LivePlayQuality(quality: name, data: signature);

LiveRoomDetail _roomDetail({
  bool status = true,
  bool isRecord = false,
  String signature = 'new',
}) {
  return LiveRoomDetail(
    roomId: 'test-room',
    title: 'Test broadcast',
    cover: '',
    userName: 'Test broadcaster',
    userAvatar: '',
    online: 42,
    status: status,
    isRecord: isRecord,
    data: signature,
    url: 'https://example.com/test-room',
  );
}

class _TestSettingsController extends AppSettingsController {
  @override
  // Persistence is deliberately not initialized for these tests.
  // ignore: must_call_super
  void onInit() {}
}

class _TestLiveSite extends LiveSite {
  int urlRequests = 0;
  int detailRequests = 0;
  final qualityDetails = <LiveRoomDetail>[];
  final urlDetails = <LiveRoomDetail>[];
  final urlQualities = <LivePlayQuality>[];
  Future<LivePlayUrl> Function() requestUrls =
      () async => LivePlayUrl(urls: _refreshedUrls);
  Future<LiveRoomDetail> Function() requestDetail = () async => _roomDetail();
  Future<List<LivePlayQuality>> Function() requestQualities =
      () async => [_quality(signature: 'new')];

  @override
  Future<LivePlayUrl> getPlayUrls({
    required LiveRoomDetail detail,
    required LivePlayQuality quality,
  }) {
    urlRequests += 1;
    urlDetails.add(detail);
    urlQualities.add(quality);
    return requestUrls();
  }

  @override
  Future<LiveRoomDetail> getRoomDetail({required String roomId}) {
    detailRequests += 1;
    return requestDetail();
  }

  @override
  Future<List<LivePlayQuality>> getPlayQualites({
    required LiveRoomDetail detail,
  }) {
    qualityDetails.add(detail);
    return requestQualities();
  }
}

class _TestRoomController extends LiveRoomController {
  _TestRoomController(LiveSite liveSite)
      : super(
          pSite: Site(id: 'test', liveSite: liveSite, logo: '', name: 'Test'),
          pRoomId: 'test-room',
        );

  final fakePlayer = _TestPlayer();

  @override
  Player get player => fakePlayer;

  @override
  Future<void> initializePlayer() async {}

  @override
  Future<int> getQualityLevel() async => 2;

  @override
  Future<void> resetSystem() async {}

  void disposeForTest() {
    onPlayingChanged(false);
    didChangeAppLifecycleState(AppLifecycleState.paused);
    scrollController.dispose();
  }
}

class _TestPlayer extends Fake implements Player {
  final openedUris = <String>[];
  final openedPlaylists = <Playlist>[];
  final jumpedIndexes = <int>[];
  Playlist currentPlaylist = const Playlist([]);
  bool playing = true;
  bool completed = false;
  bool buffering = false;
  Duration position = Duration.zero;
  int stopCalls = 0;
  int disposeCalls = 0;
  void Function()? onOpen;
  void Function()? onJump;
  void Function()? onStop;

  @override
  PlayerState get state => PlayerState(
        playing: playing,
        completed: completed,
        buffering: buffering,
        position: position,
        playlist: currentPlaylist,
      );

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    final playlist = playable as Playlist;
    openedPlaylists.add(playlist);
    currentPlaylist = playlist;
    openedUris.add(playlist.medias[playlist.index].uri);
    playing = play;
    completed = false;
    buffering = false;
    position = Duration.zero;
    onOpen?.call();
  }

  @override
  Future<void> jump(int index) async {
    jumpedIndexes.add(index);
    currentPlaylist = Playlist(currentPlaylist.medias, index: index);
    playing = true;
    completed = false;
    buffering = false;
    position = Duration.zero;
    onJump?.call();
  }

  @override
  Future<void> stop() async {
    stopCalls += 1;
    currentPlaylist = const Playlist([]);
    position = Duration.zero;
    buffering = false;
    completed = false;
    playing = false;
    onStop?.call();
  }

  @override
  Future<void> dispose() async {
    disposeCalls += 1;
  }
}
