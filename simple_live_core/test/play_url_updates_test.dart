import 'dart:async';

import 'package:simple_live_core/simple_live_core.dart';
import 'package:test/test.dart';

void main() {
  setUp(() => CoreLog.enableLog = false);
  tearDown(() => CoreLog.enableLog = true);

  final detail = LiveRoomDetail(
    roomId: 'room',
    title: '',
    cover: '',
    userName: '',
    userAvatar: '',
    online: 0,
    status: true,
    url: '',
    data: 'signature',
  );
  final quality = LivePlayQuality(
    quality: 'source',
    data: DouyuPlayData(0, ['primary', 'backup']),
  );

  test('default site publishes its existing URL response once', () async {
    final updates = await _DefaultSite()
        .getPlayUrlUpdates(detail: detail, quality: quality)
        .toList();

    expect(updates.map((update) => update.urls), [
      ['https://primary.example/live.flv'],
    ]);
  });

  test('first Douyu address is available before backup completes', () async {
    final site = _DouyuSite();
    final iterator = StreamIterator(
      site.getPlayUrlUpdates(detail: detail, quality: quality),
    );
    final first = iterator.moveNext();
    site.responses['primary']!.complete('https://primary.example/live.flv');
    expect(await first, isTrue);
    final firstUpdate = iterator.current;
    expect(firstUpdate.urls, ['https://primary.example/live.flv']);
    expect(site.requests, ['primary']);

    final second = iterator.moveNext();
    site.responses['backup']!.complete('https://backup.example/live.flv');
    expect(await second, isTrue);
    expect(iterator.current.urls, [
      'https://primary.example/live.flv',
      'https://backup.example/live.flv',
    ]);
    expect(firstUpdate.urls, ['https://primary.example/live.flv']);
    expect(await iterator.moveNext(), isFalse);
  });

  test('failed primary continues to a usable backup', () async {
    final site = _DouyuSite();
    final firstRequestStarted = Completer<void>();
    site.onRequest = (cdn) {
      if (cdn == 'primary') firstRequestStarted.complete();
    };
    final result = site.getPlayUrls(detail: detail, quality: quality);
    await firstRequestStarted.future;
    site.responses['primary']!.completeError(StateError('primary failed'));
    site.responses['backup']!.complete('https://backup.example/live.flv');

    expect((await result).urls, ['https://backup.example/live.flv']);
  });

  test('failed backup preserves the first successful response', () async {
    final site = _DouyuSite();
    final backupStarted = Completer<void>();
    site.onRequest = (cdn) {
      if (cdn == 'backup') backupStarted.complete();
    };
    final iterator = StreamIterator(
      site.getPlayUrlUpdates(detail: detail, quality: quality),
    );
    final first = iterator.moveNext();
    site.responses['primary']!.complete('https://primary.example/live.flv');
    expect(await first, isTrue);
    final completed = iterator.moveNext();
    await backupStarted.future;
    site.responses['backup']!.completeError(StateError('backup failed'));

    expect(await completed, isFalse);
  });

  test('all failed addresses preserve the last failure', () async {
    final site = _DouyuSite();
    final primaryStarted = Completer<void>();
    final backupStarted = Completer<void>();
    site.onRequest = (cdn) {
      (cdn == 'primary' ? primaryStarted : backupStarted).complete();
    };
    final result = expectLater(
      site.getPlayUrls(detail: detail, quality: quality),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'backup failed',
        ),
      ),
    );
    await primaryStarted.future;
    site.responses['primary']!.completeError(StateError('primary failed'));
    await backupStarted.future;
    site.responses['backup']!.completeError(StateError('backup failed'));
    await result;
  });

  test('existing Douyu API returns all unique addresses', () async {
    final site = _DouyuSite();
    final result = site.getPlayUrls(detail: detail, quality: quality);
    site.responses['primary']!.complete('https://primary.example/live.flv');
    site.responses['backup']!.complete('https://backup.example/live.flv');

    expect((await result).urls, [
      'https://primary.example/live.flv',
      'https://backup.example/live.flv',
    ]);
  });

  test(
    'duplicate Douyu addresses do not add duplicate playlist entries',
    () async {
      final site = _DouyuSite();
      final result = site
          .getPlayUrlUpdates(detail: detail, quality: quality)
          .toList();
      site.responses['primary']!.complete('https://same.example/live.flv');
      site.responses['backup']!.complete('https://same.example/live.flv');

      expect(await result, hasLength(1));
    },
  );

  test('empty CDN list returns an empty response', () async {
    final result = await _DouyuSite().getPlayUrls(
      detail: detail,
      quality: LivePlayQuality(quality: 'source', data: DouyuPlayData(0, [])),
    );

    expect(result.urls, isEmpty);
  });

  test(
    'Huya yields cumulative addresses with stable request headers',
    () async {
      final site = _HuyaSite();
      final first = _line('primary');
      final second = _line('backup');
      final updates = await site
          .getPlayUrlUpdates(
            detail: detail,
            quality: LivePlayQuality(
              quality: 'source',
              data: {
                'urls': [first, second],
                'bitRate': 0,
              },
            ),
          )
          .toList();

      expect(updates.map((update) => update.urls), [
        ['https://primary.example/live.flv'],
        ['https://primary.example/live.flv', 'https://backup.example/live.flv'],
      ]);
      expect(updates.first.headers!['user-agent'], isNotEmpty);
      expect(updates.last.headers, updates.first.headers);
    },
  );
}

class _DefaultSite extends LiveSite {
  @override
  Future<LivePlayUrl> getPlayUrls({
    required LiveRoomDetail detail,
    required LivePlayQuality quality,
  }) async => LivePlayUrl(urls: ['https://primary.example/live.flv']);
}

class _DouyuSite extends DouyuSite {
  final responses = {
    'primary': Completer<String>(),
    'backup': Completer<String>(),
  };
  final requests = <String>[];
  void Function(String)? onRequest;

  @override
  Future<String> getPlayUrl(String roomId, String args, int rate, String cdn) {
    requests.add(cdn);
    onRequest?.call(cdn);
    return responses[cdn]!.future;
  }
}

class _HuyaSite extends HuyaSite {
  @override
  Future<String> getPlayUrl(HuyaLineModel line, int bitRate) async =>
      'https://${line.cdnType}.example/live.flv';
}

HuyaLineModel _line(String cdn) => HuyaLineModel(
  line: '',
  lineType: HuyaLineType.flv,
  flvAntiCode: '',
  hlsAntiCode: '',
  streamName: '',
  cdnType: cdn,
  presenterUid: 1,
);
