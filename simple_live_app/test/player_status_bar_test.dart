import 'dart:async';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remixicon/remixicon.dart';
import 'package:simple_live_app/modules/live_room/player/player_status_bar.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final batteries = <_FakeBattery>[];

  _FakeBattery createBattery({int level = 100}) {
    final battery = _FakeBattery()..level = level;
    batteries.add(battery);
    return battery;
  }

  void statusTest(
    String description,
    Future<void> Function(WidgetTester tester) callback,
  ) {
    testWidgets(description, (tester) async {
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      try {
        await callback(tester);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        for (final battery in batteries) {
          await battery.close();
        }
        batteries.clear();
        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      }
    });
  }

  for (final viewport in [const Size(844, 390), const Size(390, 844)]) {
    statusTest(
        'clock stays centered and battery fits asymmetric safe area at $viewport',
        (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = viewport;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final battery = createBattery();

      await tester.pumpWidget(_host(
        battery: battery,
        now: () => DateTime(2026, 11, 8, 7, 5),
        safeInsets: const EdgeInsets.only(left: 44, top: 12, right: 8),
      ));
      await tester.pump();

      final status = tester.getRect(find.byType(PlayerStatusBar));
      final clock = tester.getRect(find.text('07:05'));
      final percentage = tester.getRect(find.text('100%'));
      final icon = tester.getRect(find.byIcon(Remix.battery_fill));
      expect(status.height, PlayerStatusBar.height);
      expect(clock.center.dx, closeTo(status.center.dx, 0.01));
      expect(icon.right, closeTo(status.right, 0.01));
      expect(percentage.left, greaterThan(clock.right));
      expect(clock.left, greaterThanOrEqualTo(status.left));
      expect(icon.bottom, lessThanOrEqualTo(status.bottom));
      expect(status.left, greaterThanOrEqualTo(44));
      expect(status.right, lessThanOrEqualTo(viewport.width - 8));
      expect(tester.takeException(), isNull);

      battery.level = 9;
      battery.emit(BatteryState.discharging);
      await tester.pumpAndSettle();

      expect(find.text('9%'), findsOneWidget);
      expect(tester.getRect(find.text('07:05')).center.dx,
          closeTo(clock.center.dx, 0.01));
      expect(tester.getRect(find.byIcon(Remix.battery_low_line)).right,
          closeTo(icon.right, 0.01));
      expect(tester.takeException(), isNull);
    });
  }

  statusTest(
      'clock updates across midnight without reading battery every second',
      (tester) async {
    final battery = createBattery(level: 83);
    var now = DateTime(2026, 11, 8, 23, 59, 59);
    await tester.pumpWidget(_host(battery: battery, now: () => now));
    await tester.pump();
    expect(find.text('23:59'), findsOneWidget);
    expect(find.text('83%'), findsOneWidget);

    now = DateTime(2026, 11, 9);
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('00:00'), findsOneWidget);
    expect(battery.levelReads, 1);
    expect(battery.stateReads, 1);
  });

  statusTest('compact status row fits large system text without overlap',
      (tester) async {
    final battery = createBattery();
    await tester.pumpWidget(_host(
      battery: battery,
      textScaler: const TextScaler.linear(2),
    ));
    await tester.pump();

    final row = tester.getRect(find.byType(PlayerStatusBar));
    final clock = tester.getRect(find.text('13:42'));
    final percentage = tester.getRect(find.text('100%'));
    expect(row.height, 16);
    expect(clock.height, lessThanOrEqualTo(row.height));
    expect(percentage.height, lessThanOrEqualTo(row.height));
    expect(clock.right, lessThan(percentage.left));
    expect(tester.takeException(), isNull);
  });

  statusTest('charging replaces the low battery warning', (tester) async {
    final battery = createBattery(level: 7);
    await tester.pumpWidget(_host(battery: battery));
    await tester.pump();

    expect(find.text('7%'), findsOneWidget);
    expect(tester.widget<Icon>(find.byIcon(Remix.battery_low_line)).color,
        Colors.redAccent);

    battery.emit(BatteryState.charging);
    await tester.pumpAndSettle();

    expect(find.text('7%'), findsOneWidget);
    expect(find.byIcon(Remix.battery_low_line), findsNothing);
    expect(tester.widget<Icon>(find.byIcon(Remix.battery_charge_line)).color,
        Colors.white);
    expect(battery.levelReads, 2);
  });

  statusTest(
      'missing battery data leaves time usable and retries while visible',
      (tester) async {
    final battery = createBattery()
      ..readLevel = () async => throw PlatformException(code: 'unavailable');
    await tester.pumpWidget(_host(
      battery: battery,
      now: () => DateTime(2026, 11, 8, 10, 12),
    ));
    await tester.pump();

    expect(find.text('--%'), findsOneWidget);
    expect(find.text('10:12'), findsOneWidget);
    expect(find.byIcon(Remix.battery_line), findsOneWidget);
    expect(tester.takeException(), isNull);

    battery
      ..readLevel = null
      ..level = 64;
    await tester.pump(const Duration(seconds: 30));

    expect(find.text('64%'), findsOneWidget);
    expect(battery.levelReads, 2);
    expect(tester.takeException(), isNull);
  });

  statusTest('invalid battery percentages are shown as unknown',
      (tester) async {
    final battery = createBattery(level: -1);
    await tester.pumpWidget(_host(battery: battery));
    await tester.pump();
    expect(find.text('--%'), findsOneWidget);

    battery.level = 101;
    battery.emit(BatteryState.discharging);
    await tester.pumpAndSettle();

    expect(find.text('--%'), findsOneWidget);
    expect(find.text('101%'), findsNothing);
  });

  statusTest('hiding controls stops monitoring and showing reads fresh values',
      (tester) async {
    final battery = createBattery(level: 80);
    var now = DateTime(2026, 11, 8, 10, 59);
    await tester.pumpWidget(_host(battery: battery, now: () => now));
    await tester.pump();
    expect(battery.activeListeners, 1);

    await tester
        .pumpWidget(_host(battery: battery, now: () => now, visible: false));
    await tester.pump();
    expect(battery.activeListeners, 0);
    now = DateTime(2026, 11, 8, 11);
    battery.level = 79;
    battery.emit(BatteryState.charging);
    await tester.pump(const Duration(minutes: 2));

    expect(battery.levelReads, 1);
    expect(find.text('10:59'), findsOneWidget);

    await tester.pumpWidget(_host(battery: battery, now: () => now));
    await tester.pump();

    expect(find.text('11:00'), findsOneWidget);
    expect(find.text('79%'), findsOneWidget);
    expect(battery.levelReads, 2);
    expect(battery.activeListeners, 1);
    expect(battery.listenRequests, 2);
  });

  statusTest('backgrounding suspends monitoring until the app resumes',
      (tester) async {
    final battery = createBattery(level: 60);
    var now = DateTime(2026, 11, 8, 12);
    await tester.pumpWidget(_host(battery: battery, now: () => now));
    await tester.pump();

    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    now = DateTime(2026, 11, 8, 12, 5);
    battery.level = 58;
    battery.emit(BatteryState.charging);
    await tester.pump(const Duration(minutes: 5));

    expect(battery.activeListeners, 0);
    expect(battery.levelReads, 1);
    expect(find.text('12:00'), findsOneWidget);

    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();

    expect(find.text('12:05'), findsOneWidget);
    expect(find.text('58%'), findsOneWidget);
    expect(find.byIcon(Remix.battery_charge_line), findsOneWidget);
    expect(battery.levelReads, 2);
    expect(battery.activeListeners, 1);
  });

  statusTest('a stale hidden read cannot overwrite the newly shown battery',
      (tester) async {
    final pending = Completer<int>();
    final battery = createBattery()..readLevel = () => pending.future;
    await tester.pumpWidget(_host(battery: battery));
    await tester.pump();
    await tester.pumpWidget(_host(battery: battery, visible: false));

    battery
      ..readLevel = null
      ..level = 84;
    await tester.pumpWidget(_host(battery: battery));
    await tester.pump();
    expect(find.text('84%'), findsOneWidget);

    pending.complete(2);
    await tester.pump();

    expect(find.text('84%'), findsOneWidget);
    expect(find.text('2%'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  statusTest('disposing with a pending battery read does not update old state',
      (tester) async {
    final pending = Completer<int>();
    final battery = createBattery()..readLevel = () => pending.future;
    await tester.pumpWidget(_host(battery: battery));
    await tester.pump();

    await tester.pumpWidget(const SizedBox.shrink());
    expect(battery.activeListeners, 0);
    pending.complete(92);
    await tester.pump();
    await tester.pump(const Duration(minutes: 1));

    expect(battery.levelReads, 1);
    expect(tester.takeException(), isNull);
  });
}

Widget _host({
  required Battery battery,
  DateTime Function()? now,
  bool visible = true,
  EdgeInsets safeInsets = EdgeInsets.zero,
  TextScaler textScaler = TextScaler.noScaling,
}) {
  return Directionality(
    textDirection: TextDirection.ltr,
    child: MediaQuery(
      data: MediaQueryData(
        padding: safeInsets,
        viewPadding: safeInsets,
        textScaler: textScaler,
      ),
      child: Material(
        color: Colors.black,
        child: Align(
          alignment: Alignment.topCenter,
          child: Padding(
            padding: safeInsets.add(const EdgeInsets.symmetric(horizontal: 12)),
            child: PlayerStatusBar(
              visible: visible,
              battery: battery,
              now: now ?? () => DateTime(2026, 11, 8, 13, 42),
            ),
          ),
        ),
      ),
    ),
  );
}

class _FakeBattery extends Fake implements Battery {
  late final _changes = StreamController<BatteryState>.broadcast(
    onListen: () => activeListeners += 1,
    onCancel: () => activeListeners -= 1,
  );
  int level = 100;
  BatteryState state = BatteryState.discharging;
  int levelReads = 0;
  int stateReads = 0;
  int listenRequests = 0;
  int activeListeners = 0;
  Future<int> Function()? readLevel;

  @override
  Future<int> get batteryLevel async {
    levelReads += 1;
    return readLevel == null ? level : await readLevel!();
  }

  @override
  Future<BatteryState> get batteryState async {
    stateReads += 1;
    return state;
  }

  @override
  Stream<BatteryState> get onBatteryStateChanged {
    listenRequests += 1;
    return _changes.stream;
  }

  void emit(BatteryState value) {
    state = value;
    _changes.add(value);
  }

  Future<void> close() => _changes.close();
}
