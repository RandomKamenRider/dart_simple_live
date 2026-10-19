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

  testWidgets('exhausting current retries switches to an available backup',
      (tester) async {
    final site = _TestLiveSite();
    final controller = createController(site)..mediaErrorRetryCount = 3;

    await completePlayback(controller);

    expect(controller.currentLineIndex, 1);
    expect(controller.fakePlayer.openedUris, isEmpty);
    expect(controller.fakePlayer.jumpedIndexes, [1]);
    expect(controller.mediaErrorRetryCount, 0);
    expect(site.detailRequests, 0);
    expect(controller.liveStatus.value, isTrue);
  });

  testWidgets('failed automatic backup jump schedules a fresh reconnect',
      (tester) async {
    final site = _TestLiveSite();
    final controller = createController(site)..mediaErrorRetryCount = 3;
    var firstOpen = true;
    controller.fakePlayer.onJump = () {
      if (firstOpen) {
        firstOpen = false;
        throw StateError('backup jump failure');
      }
    };

    await completePlayback(controller);
    expect(controller.fakePlayer.openedUris, isEmpty);
    expect(controller.fakePlayer.jumpedIndexes, [1]);
    expect(controller.liveStatus.value, isTrue);
    await tester.pump(const Duration(seconds: 2));

    expect(site.detailRequests, 1);
    expect(controller.fakePlayer.openedUris, [_refreshedUrls.first]);
    expect(controller.liveStatus.value, isTrue);
    expect(controller.errorMsg.value, isEmpty);
  });

  testWidgets('exhausted lines reconnect after backoff while room stays live',
      (tester) async {
    final site = _TestLiveSite();
    final controller = createController(site, line: 1)
      ..mediaErrorRetryCount = 3;

    await completePlayback(controller);
    expect(site.detailRequests, 0);
    expect(controller.liveStatus.value, isTrue);
    await tester.pump(const Duration(seconds: 1));
    expect(site.detailRequests, 0);
    await tester.pump(const Duration(seconds: 1));

    expect(site.detailRequests, 1);
    expect(site.urlRequests, 1);
    expect(controller.liveStatus.value, isTrue);
    expect(controller.fakePlayer.openedUris, [_refreshedUrls.first]);
    expect(controller.fakePlayer.stopCalls, 0);
  });

  testWidgets(
      'resumed progress cancels a queued room refresh before its deadline',
      (tester) async {
    final site = _TestLiveSite();
    final controller = createController(site, line: 1)
      ..mediaErrorRetryCount = 3;
    controller.fakePlayer.position = const Duration(seconds: 100);
    await completePlayback(controller);
    expect(controller.errorMsg.value, isNotEmpty);

    controller.fakePlayer.completed = false;
    controller.fakePlayer.buffering = true;
    controller.fakePlayer.position = const Duration(seconds: 101);
    await tester.pump(const Duration(seconds: 1));
    expect(controller.errorMsg.value, isEmpty);
    expect(site.detailRequests, 0);
    await advancePlayback(tester, controller, 10);

    expect(controller.fakePlayer.jumpedIndexes, isEmpty);
    expect(controller.fakePlayer.openedUris, isEmpty);
    expect(controller.mediaErrorRetryCount, 3);
    expect(site.detailRequests, 0);
    expect(site.urlRequests, 0);
  });

  testWidgets('native next rebases queued refresh timestamps before progress',
      (tester) async {
    final site = _TestLiveSite();
    final controller = createController(site, line: 1)
      ..mediaErrorRetryCount = 3;
    controller.fakePlayer.position = const Duration(seconds: 100);
    await completePlayback(controller);

    controller.fakePlayer.currentPlaylist = Playlist(
      _originalUrls.map(Media.new).toList(),
    );
    controller.fakePlayer.completed = false;
    controller.fakePlayer.position = Duration.zero;
    await tester.pump(const Duration(seconds: 1));
    expect(controller.errorMsg.value, isNotEmpty);
    expect(site.detailRequests, 0);
    controller.fakePlayer.position = const Duration(seconds: 1);
    await tester.pump(const Duration(seconds: 1));
    expect(controller.errorMsg.value, isEmpty);
    await advancePlayback(tester, controller, 5);

    expect(controller.currentLineIndex, 0);
    expect(controller.fakePlayer.jumpedIndexes, isEmpty);
    expect(controller.fakePlayer.openedUris, isEmpty);
    expect(controller.mediaErrorRetryCount, 3);
    expect(site.detailRequests, 0);
    expect(site.urlRequests, 0);
  });

  testWidgets('native next at a queued refresh deadline gets a progress grace',
      (tester) async {
    final site = _TestLiveSite();
    final controller = createController(site, line: 1)
      ..mediaErrorRetryCount = 3;
    controller.fakePlayer.position = const Duration(seconds: 100);
    await completePlayback(controller);
    await tester.pump(const Duration(seconds: 1));

    controller.fakePlayer.currentPlaylist = Playlist(
      _originalUrls.map(Media.new).toList(),
    );
    controller.fakePlayer.completed = false;
    controller.fakePlayer.position = Duration.zero;
    await tester.pump(const Duration(seconds: 1));
    expect(controller.errorMsg.value, isNotEmpty);
    expect(site.detailRequests, 0);
    controller.fakePlayer.position = const Duration(seconds: 1);
    await tester.pump(const Duration(seconds: 1));

    expect(controller.errorMsg.value, isEmpty);
    expect(controller.currentLineIndex, 0);
    expect(controller.fakePlayer.jumpedIndexes, isEmpty);
    expect(controller.fakePlayer.openedUris, isEmpty);
    expect(controller.mediaErrorRetryCount, 3);
    expect(site.detailRequests, 0);
    expect(site.urlRequests, 0);
  });

  testWidgets(
      'a cancelled queued refresh still observes a later genuine freeze',
      (tester) async {
    final site = _TestLiveSite();
    final controller = createController(site, line: 1)
      ..mediaErrorRetryCount = 3;
    controller.fakePlayer.position = const Duration(seconds: 100);
    await completePlayback(controller);

    controller.fakePlayer.completed = false;
    controller.fakePlayer.position = const Duration(seconds: 101);
    await tester.pump(const Duration(seconds: 1));
    expect(controller.errorMsg.value, isEmpty);
    await tester.pump(const Duration(seconds: 14));
    expect(controller.errorMsg.value, isEmpty);
    expect(site.detailRequests, 0);
    await tester.pump(const Duration(seconds: 1));
    expect(controller.errorMsg.value, isNotEmpty);
    expect(controller.mediaErrorRetryCount, 3);
    await tester.pump(const Duration(seconds: 3));
    expect(site.detailRequests, 0);
    await tester.pump(const Duration(seconds: 1));

    expect(site.detailRequests, 1);
    expect(site.urlRequests, 1);
    expect(controller.fakePlayer.openedUris, [_refreshedUrls.first]);
    expect(controller.fakePlayer.jumpedIndexes, isEmpty);
  });

  testWidgets(
      'a queued refresh grace expires when the native line stays frozen',
      (tester) async {
    final site = _TestLiveSite();
    final controller = createController(site, line: 1)
      ..mediaErrorRetryCount = 3;
    controller.fakePlayer.position = const Duration(seconds: 100);
    await completePlayback(controller);
    await tester.pump(const Duration(seconds: 1));

    controller.fakePlayer.currentPlaylist = Playlist(
      _originalUrls.map(Media.new).toList(),
    );
    controller.fakePlayer.completed = false;
    controller.fakePlayer.position = Duration.zero;
    await tester.pump(const Duration(seconds: 1));
    expect(site.detailRequests, 0);
    await tester.pump(const Duration(seconds: 1));

    expect(site.detailRequests, 1);
    expect(site.urlRequests, 1);
    expect(controller.fakePlayer.openedUris, [_refreshedUrls.first]);
    expect(controller.fakePlayer.jumpedIndexes, isEmpty);
  });

  testWidgets('offline platform confirmation stops playback after backoff',
      (tester) async {
    final site = _TestLiveSite()
      ..requestDetail = () async => _roomDetail(status: false);
    final controller = createController(site, line: 1)
      ..mediaErrorRetryCount = 3;

    await completePlayback(controller);
    await tester.pump(const Duration(seconds: 2));

    expect(site.detailRequests, 1);
    expect(controller.liveStatus.value, isFalse);
    expect(controller.fakePlayer.stopCalls, 1);
    expect(site.urlRequests, 0);
  });

  testWidgets(
      'recorded playback is preserved when live platform status is false',
      (tester) async {
    final site = _TestLiveSite()
      ..requestDetail = () async => _roomDetail(status: false, isRecord: true);
    final controller = createController(site, line: 1)
      ..mediaErrorRetryCount = 3;

    await completePlayback(controller);
    await tester.pump(const Duration(seconds: 2));

    expect(controller.liveStatus.value, isTrue);
    expect(controller.detail.value!.isRecord, isTrue);
    expect(controller.fakePlayer.stopCalls, 0);
    expect(controller.fakePlayer.openedUris, [_refreshedUrls.first]);
  });

  testWidgets(
      'temporary status failures retry with bounded exponential backoff',
      (tester) async {
    final site = _TestLiveSite()
      ..requestDetail =
          () async => throw StateError('temporary network failure');
    final controller = createController(site, line: 1)
      ..mediaErrorRetryCount = 3;

    await completePlayback(controller);
    for (final interval in [2, 4, 8, 16, 32, 32]) {
      final previousRequests = site.detailRequests;
      await tester.pump(Duration(seconds: interval - 1));
      expect(site.detailRequests, previousRequests);
      await tester.pump(const Duration(seconds: 1));
      expect(site.detailRequests, previousRequests + 1);
      expect(controller.liveStatus.value, isTrue);
    }
    expect(controller.fakePlayer.stopCalls, 0);
  });

  testWidgets('failed refreshed URLs recover on the scheduled next attempt',
      (tester) async {
    final site = _TestLiveSite()
      ..requestUrls = () async => throw StateError('temporary URL failure');
    final controller = createController(site)..mediaErrorRetryCount = 2;

    final retry = completePlayback(controller);
    await tester.pump(const Duration(seconds: 1));
    await retry;
    expect(controller.playUrls, _originalUrls);
    expect(controller.liveStatus.value, isTrue);
    expect(controller.fakePlayer.openedUris, isEmpty);

    site.requestUrls = () async => LivePlayUrl(urls: _refreshedUrls);
    await tester.pump(const Duration(seconds: 2));

    expect(site.urlRequests, 2);
    expect(controller.fakePlayer.openedUris, [_refreshedUrls.first]);
    expect(controller.liveStatus.value, isTrue);
  });

  testWidgets('manual line selection cancels a scheduled reconnect',
      (tester) async {
    final site = _TestLiveSite();
    final controller = createController(site, line: 1)
      ..mediaErrorRetryCount = 3;

    await completePlayback(controller);
    await controller.changePlayLine(0);
    await tester.pump(const Duration(seconds: 3));

    expect(site.detailRequests, 0);
    expect(controller.fakePlayer.openedUris, isEmpty);
    expect(controller.fakePlayer.jumpedIndexes, [0]);
    expect(controller.currentLineIndex, 0);
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

  testWidgets('backgrounding cancels a scheduled reconnect', (tester) async {
    final site = _TestLiveSite();
    final controller = createController(site, line: 1)
      ..mediaErrorRetryCount = 3;
    await completePlayback(controller);

    controller.didChangeAppLifecycleState(AppLifecycleState.paused);
    await tester.pump(const Duration(seconds: 3));

    expect(site.detailRequests, 0);
    expect(controller.fakePlayer.openedUris, isEmpty);
  });

  testWidgets('closing cancels both observations and scheduled reconnects',
      (tester) async {
    final observed = createController(_TestLiveSite());
    final warning = observed.mediaError('connection warning');
    final reconnectSite = _TestLiveSite();
    final reconnecting = createController(reconnectSite, line: 1)
      ..mediaErrorRetryCount = 3;
    await completePlayback(reconnecting);

    observed.onDelete();
    reconnecting.onDelete();
    await warning;
    await tester.pump(const Duration(seconds: 6));

    expect(observed.fakePlayer.openedUris, isEmpty);
    expect(reconnecting.fakePlayer.openedUris, isEmpty);
    expect(reconnectSite.detailRequests, 0);
    expect(observed.fakePlayer.disposeCalls, 1);
    expect(reconnecting.fakePlayer.disposeCalls, 1);
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

  testWidgets('buffering between health samples still interrupts stability',
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

  testWidgets(
      'silent buffering recovers after fifteen consecutive frozen seconds',
      (tester) async {
    final site = _TestLiveSite();
    final controller = createController(site);
    controller.fakePlayer.buffering = true;
    controller.onBufferingChanged(true);

    await tester.pump(const Duration(seconds: 14));
    expect(controller.fakePlayer.jumpedIndexes, isEmpty);
    await tester.pump(const Duration(seconds: 1));

    expect(controller.fakePlayer.jumpedIndexes, [0]);
    expect(controller.mediaErrorRetryCount, 1);
    expect(site.detailRequests, 0);
    expect(site.urlRequests, 0);
    expect(controller.liveStatus.value, isTrue);
  });

  testWidgets('silent stalled playback recovers even without buffering events',
      (tester) async {
    final controller = createController(_TestLiveSite());
    controller.onPlayingChanged(true);

    await tester.pump(const Duration(seconds: 15));

    expect(controller.fakePlayer.jumpedIndexes, [0]);
    expect(controller.mediaErrorRetryCount, 1);
  });

  testWidgets('a later silent freeze recovers after an advancing error clears',
      (tester) async {
    final controller = createController(_TestLiveSite());
    controller.onPlayingChanged(true);
    final warning = controller.mediaError('old harmless warning');
    await advancePlayback(tester, controller, 5);
    await warning;
    expect(controller.fakePlayer.jumpedIndexes, isEmpty);

    await tester.pump(const Duration(seconds: 14));
    expect(controller.fakePlayer.jumpedIndexes, isEmpty);
    await tester.pump(const Duration(seconds: 1));

    expect(controller.fakePlayer.jumpedIndexes, [0]);
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

  testWidgets('forward timestamps clear the consecutive freeze timeout',
      (tester) async {
    final controller = createController(_TestLiveSite());
    controller.fakePlayer.buffering = true;
    controller.onBufferingChanged(true);
    await tester.pump(const Duration(seconds: 14));

    await advancePlayback(tester, controller, 1);
    await tester.pump(const Duration(seconds: 14));
    expect(controller.fakePlayer.jumpedIndexes, isEmpty);
    await tester.pump(const Duration(seconds: 1));

    expect(controller.fakePlayer.jumpedIndexes, [0]);
    expect(controller.mediaErrorRetryCount, 1);
  });

  testWidgets('native next rebases the silent freeze timeout and timestamps',
      (tester) async {
    final controller = createController(_TestLiveSite());
    controller.fakePlayer.position = const Duration(seconds: 100);
    controller.onPlayingChanged(true);
    await tester.pump(const Duration(seconds: 14));

    controller.fakePlayer.currentPlaylist = Playlist(
      _originalUrls.map(Media.new).toList(),
      index: 1,
    );
    controller.fakePlayer.position = Duration.zero;
    controller.syncPlayLine();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 14));
    expect(controller.fakePlayer.jumpedIndexes, isEmpty);
    await tester.pump(const Duration(seconds: 1));

    expect(controller.currentLineIndex, 1);
    expect(controller.fakePlayer.jumpedIndexes, [1]);
    expect(controller.mediaErrorRetryCount, 1);
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

  testWidgets('duplicate player events cannot postpone stall recovery',
      (tester) async {
    final controller = createController(_TestLiveSite());
    controller.fakePlayer.buffering = true;
    controller.onBufferingChanged(true);

    for (var second = 0; second < 14; second += 1) {
      await tester.pump(const Duration(seconds: 1));
      controller.onPlayingChanged(true);
      controller.onBufferingChanged(true);
      expect(controller.fakePlayer.jumpedIndexes, isEmpty);
    }
    await tester.pump(const Duration(seconds: 1));

    expect(controller.fakePlayer.jumpedIndexes, [0]);
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
        '${close ? 'closing' : 'backgrounding'} cancels the silent stall observer',
        (tester) async {
      final site = _TestLiveSite();
      final controller = createController(site);
      controller.fakePlayer.buffering = true;
      controller.onBufferingChanged(true);
      await tester.pump(const Duration(seconds: 14));

      if (close) {
        controller.onDelete();
      } else {
        controller.didChangeAppLifecycleState(AppLifecycleState.paused);
      }
      await tester.pump(const Duration(seconds: 30));

      expect(controller.fakePlayer.jumpedIndexes, isEmpty);
      expect(controller.fakePlayer.openedUris, isEmpty);
      expect(site.detailRequests, 0);
      expect(site.urlRequests, 0);
    });
  }

  testWidgets('silent failures remain observed after open and each retry jump',
      (tester) async {
    final site = _TestLiveSite();
    final controller = createController(site);

    await controller.getPlayUrl();
    await tester.pump(const Duration(seconds: 15));
    expect(controller.fakePlayer.jumpedIndexes, [0]);
    expect(controller.mediaErrorRetryCount, 1);
    await tester.pump(const Duration(seconds: 15));
    expect(controller.mediaErrorRetryCount, 2);
    expect(controller.fakePlayer.jumpedIndexes, [0]);
    await tester.pump(const Duration(seconds: 1));
    expect(controller.fakePlayer.jumpedIndexes, [0, 0]);
    await tester.pump(const Duration(seconds: 15));

    expect(site.detailRequests, 1);
    expect(site.urlRequests, 2);
    expect(controller.fakePlayer.openedPlaylists, hasLength(2));
    expect(controller.mediaErrorRetryCount, 3);
  });

  testWidgets('healthy playback restores the initial reconnect backoff',
      (tester) async {
    final site = _TestLiveSite();
    final controller = createController(site, line: 1)
      ..mediaErrorRetryCount = 3;

    await completePlayback(controller);
    await tester.pump(const Duration(seconds: 2));
    expect(site.detailRequests, 1);
    controller.fakePlayer.currentPlaylist = Playlist(
      _refreshedUrls.map(Media.new).toList(),
      index: 1,
    );
    controller.syncPlayLine();
    await completePlayback(controller);
    await tester.pump(const Duration(seconds: 3));
    expect(site.detailRequests, 1);
    await tester.pump(const Duration(seconds: 1));
    expect(site.detailRequests, 2);

    await advancePlayback(tester, controller, 10);
    expect(controller.mediaErrorRetryCount, 0);
    controller.mediaErrorRetryCount = 3;
    controller.fakePlayer.currentPlaylist = Playlist(
      _refreshedUrls.map(Media.new).toList(),
      index: 1,
    );
    controller.syncPlayLine();
    await completePlayback(controller);
    await tester.pump(const Duration(seconds: 1));
    expect(site.detailRequests, 2);
    await tester.pump(const Duration(seconds: 1));

    expect(site.detailRequests, 3);
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
    playing = false;
  }

  @override
  Future<void> dispose() async {
    disposeCalls += 1;
  }
}
