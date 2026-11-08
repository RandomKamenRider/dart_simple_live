import 'dart:async';
import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:remixicon/remixicon.dart';

class PlayerStatusBar extends StatefulWidget {
  const PlayerStatusBar({
    super.key,
    required this.visible,
    this.battery,
    this.now = DateTime.now,
  });

  static const height = 16.0;

  final bool visible;
  final Battery? battery;
  final DateTime Function() now;

  @override
  State<PlayerStatusBar> createState() => _PlayerStatusBarState();
}

class _PlayerStatusBarState extends State<PlayerStatusBar>
    with WidgetsBindingObserver {
  late Battery _battery;
  late String _time;
  late bool _foreground;
  int? _level;
  BatteryState? _batteryState;
  Timer? _timer;
  StreamSubscription<BatteryState>? _batterySubscription;
  int _generation = 0;
  int? _batteryRequestGeneration;

  @override
  void initState() {
    super.initState();
    _battery = widget.battery ?? Battery();
    _time = _formatTime(widget.now());
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    _syncMonitoring();
  }

  @override
  void didUpdateWidget(covariant PlayerStatusBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.battery != widget.battery) {
      _stopMonitoring();
      _battery = widget.battery ?? Battery();
    }
    _syncMonitoring();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _syncMonitoring();
  }

  void _syncMonitoring() {
    if (!widget.visible || !_foreground) {
      _stopMonitoring();
      return;
    }
    if (_timer != null) {
      return;
    }
    final generation = ++_generation;
    _updateTime();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      _updateTime();
      if (timer.tick % 30 == 0) {
        unawaited(_updateBattery(generation));
      }
    });
    _batterySubscription = _battery.onBatteryStateChanged.listen(
      (_) => unawaited(_updateBattery(generation)),
      onError: (Object _) {},
    );
    unawaited(_updateBattery(generation));
  }

  String _formatTime(DateTime time) =>
      '${time.hour.toString().padLeft(2, '0')}:'
      '${time.minute.toString().padLeft(2, '0')}';

  void _updateTime() {
    final time = _formatTime(widget.now());
    if (_time != time) {
      setState(() => _time = time);
    }
  }

  Future<void> _updateBattery(int generation) async {
    if (_batteryRequestGeneration == generation) {
      return;
    }
    _batteryRequestGeneration = generation;
    try {
      final level = await _battery.batteryLevel;
      if (!mounted || generation != _generation) {
        return;
      }
      final state = await _battery.batteryState;
      if (!mounted || generation != _generation) {
        return;
      }
      setState(() {
        _level = level >= 0 && level <= 100 ? level : null;
        _batteryState = state;
      });
    } on PlatformException {
      // Keep the clock usable when the platform cannot provide battery data.
    } on MissingPluginException {
      // Some desktop/test hosts do not provide a battery implementation.
    } finally {
      if (_batteryRequestGeneration == generation) {
        _batteryRequestGeneration = null;
      }
    }
  }

  void _stopMonitoring() {
    _generation += 1;
    _timer?.cancel();
    _timer = null;
    unawaited(_batterySubscription?.cancel());
    _batterySubscription = null;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopMonitoring();
    super.dispose();
  }

  IconData get _batteryIcon {
    if (_level == null) return Remix.battery_line;
    if (_batteryState == BatteryState.charging) {
      return Remix.battery_charge_line;
    }
    if (_level! <= 15) return Remix.battery_low_line;
    return _level! > 90 ? Remix.battery_fill : Remix.battery_line;
  }

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(
      color: Colors.white,
      fontSize: 11,
      fontFeatures: [FontFeature.tabularFigures()],
    );
    final charging = _batteryState == BatteryState.charging;
    final lowBattery = _level != null && _level! <= 15 && !charging;
    return IgnorePointer(
      child: SizedBox(
        height: PlayerStatusBar.height,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 64),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(_time, style: style),
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: Semantics(
                label: _level == null
                    ? '电量未知'
                    : '电量 $_level%${charging ? '，充电中' : ''}',
                excludeSemantics: true,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 36,
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerRight,
                        child: Text(
                          _level == null ? '--%' : '$_level%',
                          textAlign: TextAlign.right,
                          style: style,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    SizedBox(
                      width: 24,
                      height: 14,
                      child: FittedBox(
                        fit: BoxFit.fill,
                        child: Stack(
                          alignment: Alignment.centerLeft,
                          children: [
                            Icon(
                              _batteryIcon,
                              size: 16,
                              color:
                                  lowBattery ? Colors.redAccent : Colors.white,
                            ),
                            if (_level != null &&
                                _level! > 15 &&
                                _level! <= 90 &&
                                !charging)
                              ClipRect(
                                child: Align(
                                  alignment: Alignment.centerLeft,
                                  widthFactor: _level! / 100,
                                  child: const Icon(
                                    Remix.battery_fill,
                                    size: 16,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
