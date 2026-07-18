import 'dart:async';

import 'package:web_socket_channel/io.dart';

enum SocketStatus { connecting, connected, failed, closed }

class WebScoketUtils {
  SocketStatus status = SocketStatus.closed;

  /// 链接
  final String url;

  /// 备用链接
  final String? backupUrl;

  /// 心跳时间
  final int heartBeatTime;

  /// 接收到信息
  final Function(dynamic)? onMessage;

  /// 连接关闭
  final Function(String msg)? onClose;

  /// 尝试重连
  final Function()? onReconnect;

  /// 准备就绪
  final Function()? onReady;

  /// 心跳
  final Function()? onHeartBeat;

  /// 请求头
  Map<String, dynamic>? headers;
  WebScoketUtils({
    required this.url,
    required this.heartBeatTime,
    this.onMessage,
    this.onClose,
    this.onReconnect,
    this.onReady,
    this.onHeartBeat,
    this.headers,
    this.backupUrl,
  });
  IOWebSocketChannel? webSocket;
  Timer? heartBeatTimer;

  /// 重连次数
  int reconnectTime = 0;
  Timer? reconnectTimer;

  /// 最大重连次数
  int maxReconnectTime = 5;

  /// 用于忽略已被关闭或替换的异步连接结果
  int _connectionGeneration = 0;

  StreamSubscription<dynamic>? streamSubscription;

  void connect({bool retry = false}) async {
    close();
    status = SocketStatus.connecting;
    final connectionGeneration = _connectionGeneration;
    try {
      var wsurl = url;
      if (backupUrl != null && backupUrl!.isNotEmpty && retry) {
        wsurl = backupUrl!;
      }
      final channel = IOWebSocketChannel.connect(
        wsurl,
        connectTimeout: Duration(seconds: 10),
        headers: headers,
      );
      webSocket = channel;

      await channel.ready;
      if (connectionGeneration != _connectionGeneration) {
        await channel.sink.close();
        return;
      }
      ready();
    } catch (e) {
      if (connectionGeneration != _connectionGeneration) {
        return;
      }
      if (!retry) {
        connect(retry: true);
        return;
      }
      onError(e, e);
    }
  }

  /// 连接完成
  void ready() {
    status = SocketStatus.connected;

    streamSubscription = webSocket?.stream.listen(
      (data) => receiveMessage(data),
      onError: (e, s) => onError(e, s),
      onDone: onDone,
    );

    onReady?.call();
    initHeartBeat();
  }

  void initHeartBeat() {
    heartBeatTimer = Timer.periodic(Duration(milliseconds: heartBeatTime), (
      timer,
    ) {
      onHeartBeat?.call();
    });
  }

  void receiveMessage(dynamic data) {
    //接受到一条信息才算重连成功
    reconnectTime = 0;
    onMessage?.call(data);
  }

  void onError(e, s) {
    if (status == SocketStatus.closed) {
      return;
    }
    status = SocketStatus.failed;
    onClose?.call(e.toString());
    reconnect();
  }

  void onDone() {
    if (status == SocketStatus.closed) {
      return;
    }
    onReconnect?.call();
    reconnect();
  }

  void sendMessage(dynamic message) {
    if (status == SocketStatus.connected) {
      webSocket?.sink.add(message);
    }
  }

  void close() {
    _connectionGeneration++;
    status = SocketStatus.closed;

    streamSubscription?.cancel();
    streamSubscription = null;

    reconnectTimer?.cancel();
    reconnectTimer = null;

    webSocket?.sink.close();
    webSocket = null;

    heartBeatTimer?.cancel();
    heartBeatTimer = null;
  }

  void reconnect() {
    status = SocketStatus.closed;
    if (reconnectTime < maxReconnectTime) {
      reconnectTime++;
      reconnectTimer?.cancel();
      reconnectTimer = Timer(const Duration(seconds: 5), () {
        reconnectTimer = null;
        connect();
      });
    } else {
      onClose?.call("重连超过最大次数，与服务器断开连接");
      reconnectTimer?.cancel();
      reconnectTimer = null;
      close();
      return;
    }
  }
}
