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

  setUp(() {
    Get.testMode = true;
    Get.put<AppSettingsController>(_TestSettingsController());
    binding.defaultBinaryMessenger.setMockMessageHandler(
      _wakelockChannel,
      (_) async => const StandardMessageCodec().encodeMessage([null]),
    );
  });

  tearDown(() {
    binding.defaultBinaryMessenger.setMockMessageHandler(
      _wakelockChannel,
      null,
    );
    Get.reset();
  });

  _TestRoomController createController(_TestLiveSite site) {
    final controller = _TestRoomController(site)
      ..detail.value = _roomDetail()
      ..liveStatus.value = true
      ..currentQuality = 0
      ..currentLineIndex = 0;
    controller.qualites.assignAll([_quality()]);
    controller.playUrls.assignAll(_originalUrls);
    addTearDown(controller.disposeForTest);
    return controller;
  }

  testWidgets('keeps current lines while refreshing and ignores old end events',
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

    // Opening new media can synchronously report completion of the old media.
    controller.fakePlayer.onOpen = () {
      unawaited(controller.mediaEnd());
      unawaited(controller.mediaError('old media unloaded'));
    };
    pendingUrls.complete(LivePlayUrl(urls: _refreshedUrls));
    await refresh;

    expect(controller.playUrls, _refreshedUrls);
    expect(controller.fakePlayer.openedUris, [_refreshedUrls.first]);
    expect(controller.liveStatus.value, isTrue);
    expect(controller.mediaErrorRetryCount, 0);
    expect(site.urlRequests, 1);
    expect(site.detailRequests, 0);
  });

  testWidgets('coalesces concurrent error and completed recovery events',
      (tester) async {
    final pendingUrls = Completer<LivePlayUrl>();
    final site = _TestLiveSite()..requestUrls = () => pendingUrls.future;
    final controller = createController(site);

    final recovery = controller.mediaError('connection reset');
    await controller.mediaEnd();
    await controller.mediaError('duplicate error');

    expect(site.urlRequests, 1);
    expect(controller.mediaErrorRetryCount, 1);
    expect(controller.playUrls, _originalUrls);
    expect(controller.liveStatus.value, isTrue);

    pendingUrls.complete(LivePlayUrl(urls: _refreshedUrls));
    await recovery;

    expect(controller.fakePlayer.openedUris, [_refreshedUrls.first]);
    expect(controller.liveStatus.value, isTrue);
    expect(controller.mediaErrorRetryCount, 1);
  });

  testWidgets('recovers when new media completes before opening finishes',
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

    expect(site.urlRequests, 2);
    expect(controller.fakePlayer.openedUris, [
      _refreshedUrls.first,
      _refreshedUrls.first,
    ]);
    expect(controller.fakePlayer.completed, isFalse);
    expect(controller.mediaErrorRetryCount, 1);
    expect(controller.liveStatus.value, isTrue);
  });

  testWidgets('manual line change cancels a delayed second retry',
      (tester) async {
    final site = _TestLiveSite();
    final controller = createController(site);
    await controller.mediaError('first failure');

    final delayedRetry = controller.mediaError('second failure');
    expect(controller.mediaErrorRetryCount, 2);
    await controller.changePlayLine(1);
    await tester.pump(const Duration(seconds: 1));
    await delayedRetry;

    expect(site.urlRequests, 1);
    expect(controller.currentLineIndex, 1);
    expect(controller.mediaErrorRetryCount, 0);
    expect(controller.fakePlayer.openedUris,
        [_refreshedUrls.first, _refreshedUrls.last]);
    expect(controller.liveStatus.value, isTrue);
  });

  testWidgets('refreshes the selected backup line without returning to primary',
      (tester) async {
    final site = _TestLiveSite();
    final controller = createController(site)..currentLineIndex = 1;

    await controller.mediaError('backup connection expired');

    expect(controller.currentLineIndex, 1);
    expect(controller.fakePlayer.openedUris, [_refreshedUrls.last]);
    expect(controller.mediaErrorRetryCount, 1);
    expect(site.urlRequests, 1);
    expect(controller.liveStatus.value, isTrue);
  });

  testWidgets('moves to a remaining backup after exhausting current retries',
      (tester) async {
    final site = _TestLiveSite();
    final controller = createController(site)..mediaErrorRetryCount = 2;

    await controller.mediaEnd();

    expect(controller.currentLineIndex, 1);
    expect(controller.fakePlayer.openedUris, [_originalUrls.last]);
    expect(controller.mediaErrorRetryCount, 0);
    expect(site.urlRequests, 0);
    expect(site.detailRequests, 0);
    expect(controller.liveStatus.value, isTrue);
  });

  testWidgets('exhausted lines do not mark a room offline while still live',
      (tester) async {
    final site = _TestLiveSite();
    final controller = createController(site)
      ..currentLineIndex = 1
      ..mediaErrorRetryCount = 2;

    await controller.mediaEnd();

    expect(site.detailRequests, 1);
    expect(controller.liveStatus.value, isTrue);
    expect(controller.fakePlayer.stopCalls, 0);
    expect(controller.errorMsg.value, isNotEmpty);
  });

  testWidgets('marks the room offline only after platform confirmation',
      (tester) async {
    final site = _TestLiveSite()
      ..requestDetail = () async => _roomDetail(status: false);
    final controller = createController(site)
      ..currentLineIndex = 1
      ..mediaErrorRetryCount = 2;

    await controller.mediaEnd();

    expect(site.detailRequests, 1);
    expect(controller.liveStatus.value, isFalse);
    expect(controller.fakePlayer.stopCalls, 1);
    expect(controller.errorMsg.value, isEmpty);
  });

  testWidgets('recorded playback remains available after exhausting lines',
      (tester) async {
    final site = _TestLiveSite()
      ..requestDetail = () async => _roomDetail(status: false, isRecord: true);
    final controller = createController(site)
      ..currentLineIndex = 1
      ..mediaErrorRetryCount = 2;

    await controller.mediaEnd();

    expect(controller.liveStatus.value, isTrue);
    expect(controller.fakePlayer.stopCalls, 0);
    expect(controller.detail.value!.isRecord, isTrue);
  });

  testWidgets('a failed status query does not mark the room offline',
      (tester) async {
    final site = _TestLiveSite()
      ..requestDetail =
          () async => throw StateError('temporary network failure');
    final controller = createController(site)
      ..currentLineIndex = 1
      ..mediaErrorRetryCount = 2;

    await controller.mediaEnd();

    expect(site.detailRequests, 1);
    expect(controller.liveStatus.value, isTrue);
    expect(controller.fakePlayer.stopCalls, 0);
    expect(controller.errorMsg.value, isNotEmpty);
  });

  testWidgets('a failed URL refresh reconnects using the existing current line',
      (tester) async {
    final site = _TestLiveSite()
      ..requestUrls = () async => throw StateError('temporary URL failure');
    final controller = createController(site);

    await controller.mediaError('connection reset');

    expect(controller.playUrls, _originalUrls);
    expect(controller.currentLineIndex, 0);
    expect(controller.liveStatus.value, isTrue);
    expect(controller.fakePlayer.stopCalls, 0);
    expect(controller.fakePlayer.openedUris, [_originalUrls.first]);
    expect(controller.mediaErrorRetryCount, 1);
    expect(controller.errorMsg.value, isEmpty);
  });

  testWidgets('failed URL refresh and fallback do not mark the room offline',
      (tester) async {
    final site = _TestLiveSite()
      ..requestUrls = () async => throw StateError('temporary URL failure');
    final controller = createController(site);
    controller.fakePlayer.openFailure =
        StateError('fallback connection failure');

    await controller.mediaError('connection reset');

    expect(controller.playUrls, _originalUrls);
    expect(controller.liveStatus.value, isTrue);
    expect(controller.fakePlayer.stopCalls, 0);
    expect(controller.errorMsg.value, isNotEmpty);
  });

  testWidgets('resets retry budget only after ten seconds of stable playback',
      (tester) async {
    final controller = createController(_TestLiveSite())
      ..mediaErrorRetryCount = 2;

    controller.onPlayingChanged(true);
    await tester.pump(const Duration(seconds: 9));
    expect(controller.mediaErrorRetryCount, 2);
    await tester.pump(const Duration(seconds: 1));
    expect(controller.mediaErrorRetryCount, 0);
  });

  testWidgets('interrupted playback does not restore retry budget',
      (tester) async {
    final controller = createController(_TestLiveSite())
      ..mediaErrorRetryCount = 2;

    controller.onPlayingChanged(true);
    await tester.pump(const Duration(seconds: 9));
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
    await tester.pump(const Duration(seconds: 9));
    controller.fakePlayer.buffering = true;
    controller.onBufferingChanged(true);
    await tester.pump(const Duration(seconds: 11));
    expect(controller.mediaErrorRetryCount, 2);

    controller.fakePlayer.buffering = false;
    controller.onBufferingChanged(false);
    await tester.pump(const Duration(seconds: 9));
    expect(controller.mediaErrorRetryCount, 2);
    await tester.pump(const Duration(seconds: 1));
    expect(controller.mediaErrorRetryCount, 0);
  });

  testWidgets('resume replaces a URL request interrupted by going background',
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
    await controller.mediaEnd();

    expect(controller.fakePlayer.openedUris, isEmpty);
    expect(controller.liveStatus.value, isTrue);
    site.requestUrls = () async => LivePlayUrl(urls: _refreshedUrls);
    controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await controller.mediaEnd();
    await controller.mediaError('old background connection');
    expect(site.detailRequests, 1);
    expect(site.urlRequests, 1);

    pendingDetail.complete(_roomDetail());
    await tester.pump();

    expect(site.urlRequests, 2);
    expect(controller.fakePlayer.openedUris, [_refreshedUrls.first]);
    expect(controller.liveStatus.value, isTrue);
    expect(controller.mediaErrorRetryCount, 0);
    await tester.pump(const Duration(seconds: 1));
  });
}

LivePlayQuality _quality() => LivePlayQuality(quality: 'Source', data: 0);

LiveRoomDetail _roomDetail({bool status = true, bool isRecord = false}) {
  return LiveRoomDetail(
    roomId: 'test-room',
    title: 'Test broadcast',
    cover: '',
    userName: 'Test broadcaster',
    userAvatar: '',
    online: 42,
    status: status,
    isRecord: isRecord,
    url: 'https://example.com/test-room',
  );
}

class _TestSettingsController extends AppSettingsController {
  @override
  // Settings defaults suffice; persistence is intentionally not initialized.
  // ignore: must_call_super
  void onInit() {}
}

class _TestLiveSite extends LiveSite {
  int urlRequests = 0;
  int detailRequests = 0;
  Future<LivePlayUrl> Function() requestUrls =
      () async => LivePlayUrl(urls: _refreshedUrls);
  Future<LiveRoomDetail> Function() requestDetail = () async => _roomDetail();

  @override
  Future<LivePlayUrl> getPlayUrls({
    required LiveRoomDetail detail,
    required LivePlayQuality quality,
  }) {
    urlRequests += 1;
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
  }) async =>
      [_quality()];
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

  void disposeForTest() {
    // No native player or platform services were initialized by these tests.
    onPlayingChanged(false);
    didChangeAppLifecycleState(AppLifecycleState.paused);
    scrollController.dispose();
  }
}

class _TestPlayer extends Fake implements Player {
  final openedUris = <String>[];
  bool playing = true;
  bool completed = false;
  bool buffering = false;
  int stopCalls = 0;
  void Function()? onOpen;
  Object? openFailure;

  @override
  PlayerState get state => PlayerState(
        playing: playing,
        completed: completed,
        buffering: buffering,
      );

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    expect(playable, isA<Media>());
    openedUris.add((playable as Media).uri);
    if (openFailure != null) {
      throw openFailure!;
    }
    playing = play;
    completed = false;
    onOpen?.call();
  }

  @override
  Future<void> play() async {
    playing = true;
  }

  @override
  Future<void> stop() async {
    stopCalls += 1;
    playing = false;
  }
}
