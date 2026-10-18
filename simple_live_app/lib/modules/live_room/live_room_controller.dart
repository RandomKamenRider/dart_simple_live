import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:share_plus/share_plus.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:simple_live_app/modules/live_room/player/player_controller.dart';
import 'package:simple_live_app/modules/settings/danmu_settings_page.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/follow_service.dart';
import 'package:simple_live_app/widgets/desktop_refresh_button.dart';
import 'package:simple_live_app/widgets/follow_user_item.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

class LiveRoomController extends PlayerController with WidgetsBindingObserver {
  final Site pSite;
  final String pRoomId;
  late LiveDanmaku liveDanmaku;
  LiveRoomController({
    required this.pSite,
    required this.pRoomId,
  }) {
    rxSite = pSite.obs;
    rxRoomId = pRoomId.obs;
    liveDanmaku = site.liveSite.getDanmaku();
    // 抖音应该默认是竖屏的
    if (site.id == "douyin") {
      isVertical.value = true;
    }
  }

  late Rx<Site> rxSite;
  Site get site => rxSite.value;
  late Rx<String> rxRoomId;
  String get roomId => rxRoomId.value;

  Rx<LiveRoomDetail?> detail = Rx<LiveRoomDetail?>(null);
  var online = 0.obs;
  var followed = false.obs;
  var liveStatus = false.obs;
  RxList<LiveSuperChatMessage> superChats = RxList<LiveSuperChatMessage>();

  /// 滚动控制
  final ScrollController scrollController = ScrollController();

  /// 聊天信息
  RxList<LiveMessage> messages = RxList<LiveMessage>();

  /// 清晰度数据
  RxList<LivePlayQuality> qualites = RxList<LivePlayQuality>();

  /// 当前清晰度
  var currentQuality = -1;
  var currentQualityInfo = "".obs;

  /// 线路数据
  RxList<String> playUrls = RxList<String>();

  Map<String, String>? playHeaders;

  /// 当前线路
  var currentLineIndex = -1;
  var currentLineInfo = "".obs;

  /// 退出倒计时
  var countdown = 60.obs;

  Timer? autoExitTimer;

  /// 设置的自动关闭时间（分钟）
  var autoExitMinutes = 60.obs;

  ///是否延迟自动关闭
  var delayAutoExit = false.obs;

  /// 是否启用自动关闭
  var autoExitEnable = false.obs;

  /// 是否禁用自动滚动聊天栏
  /// - 当用户向上滚动聊天栏时，不再自动滚动
  var disableAutoScroll = false.obs;

  /// 是否处于后台
  var isBackground = false;

  /// 进入后台的时间点，用于判断返回前台后是否需要重新拉流
  DateTime? _enterBackgroundTime;

  /// 返回前台后，后台停留超过该时长则强制重新拉取直播流
  /// 直播地址通常带有时效签名，长时间挂后台后旧连接会失效或落后于真实进度
  static const Duration _backgroundReloadThreshold = Duration(seconds: 5);

  /// 返回前台后延迟重连弹幕，等待 Android 网络与 DNS 恢复
  Timer? _danmakuResumeTimer;

  /// 当前后台恢复操作代次；存在时忽略旧播放连接产生的结束和错误事件。
  int? _backgroundReloadGeneration;

  bool get _isReloadingAfterBackground =>
      _backgroundReloadGeneration == _streamOperationGeneration;

  /// 播放数据加载代次，用于丢弃旧异步请求的结果。
  int _streamOperationGeneration = 0;

  int? _streamLoadGeneration;
  int? _mediaRecoveryGeneration;
  Timer? _playbackStableTimer;
  bool _resumeStreamPending = false;
  int? _pendingPlaybackFailureGeneration;
  String? _pendingPlaybackError;

  bool get _isChangingStream =>
      _streamLoadGeneration == _streamOperationGeneration ||
      _mediaRecoveryGeneration == _streamOperationGeneration ||
      _isReloadingAfterBackground;

  /// 直播间加载失败
  var loadError = false.obs;
  Object? error;
  StackTrace? _loadErrorStackTrace;

  // 开播时长状态变量
  var liveDuration = "00:00:00".obs;
  Timer? _liveDurationTimer;

  @override
  void onInit() {
    WidgetsBinding.instance.addObserver(this);
    if (FollowService.instance.followList.isEmpty) {
      FollowService.instance.loadData();
    }
    initAutoExit();
    showDanmakuState.value = AppSettingsController.instance.danmuEnable.value;
    followed.value = DBService.instance.getFollowExist("${site.id}_$roomId");
    loadData();

    scrollController.addListener(scrollListener);

    super.onInit();
  }

  void scrollListener() {
    if (scrollController.position.userScrollDirection ==
        ScrollDirection.forward) {
      disableAutoScroll.value = true;
    }
  }

  /// 初始化自动关闭倒计时
  void initAutoExit() {
    if (AppSettingsController.instance.autoExitEnable.value) {
      autoExitEnable.value = true;
      autoExitMinutes.value =
          AppSettingsController.instance.autoExitDuration.value;
      setAutoExit();
    } else {
      autoExitMinutes.value =
          AppSettingsController.instance.roomAutoExitDuration.value;
    }
  }

  void setAutoExit() {
    if (!autoExitEnable.value) {
      autoExitTimer?.cancel();
      return;
    }
    autoExitTimer?.cancel();
    countdown.value = autoExitMinutes.value * 60;
    autoExitTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
      countdown.value -= 1;
      if (countdown.value <= 0) {
        timer = Timer(const Duration(seconds: 10), () async {
          await WakelockPlus.disable();
          exit(0);
        });
        autoExitTimer?.cancel();
        var delay = await Utils.showAlertDialog("定时关闭已到时,是否延迟关闭?",
            title: "延迟关闭", confirm: "延迟", cancel: "关闭", selectable: true);
        if (delay) {
          timer.cancel();
          delayAutoExit.value = true;
          showAutoExitSheet();
          setAutoExit();
        } else {
          delayAutoExit.value = false;
          await WakelockPlus.disable();
          exit(0);
        }
      }
    });
  }
  // 弹窗逻辑

  void refreshRoom() {
    //messages.clear();
    superChats.clear();
    liveDanmaku.stop();

    loadData();
  }

  /// 聊天栏始终滚动到底部
  void chatScrollToBottom() {
    if (scrollController.hasClients) {
      // 如果手动上拉过，就不自动滚动到底部
      if (disableAutoScroll.value) {
        return;
      }
      scrollController.jumpTo(scrollController.position.maxScrollExtent);
    }
  }

  /// 初始化弹幕接收事件
  void initDanmau() {
    liveDanmaku.onMessage = onWSMessage;
    liveDanmaku.onClose = onWSClose;
    liveDanmaku.onReady = onWSReady;
  }

  /// 接收到WebSocket信息
  void onWSMessage(LiveMessage msg) {
    if (msg.type == LiveMessageType.chat) {
      if (messages.length > 200 && !disableAutoScroll.value) {
        messages.removeAt(0);
      }

      // 关键词屏蔽检查
      for (var keyword in AppSettingsController.instance.shieldList) {
        Pattern? pattern;
        if (Utils.isRegexFormat(keyword)) {
          String removedSlash = Utils.removeRegexFormat(keyword);
          try {
            pattern = RegExp(removedSlash);
          } catch (e) {
            // should avoid this during add keyword
            Log.d("关键词：$keyword 正则格式错误");
          }
        } else {
          pattern = keyword;
        }
        if (pattern != null && msg.message.contains(pattern)) {
          Log.d("关键词：$keyword\n已屏蔽消息内容：${msg.message}");
          return;
        }
      }

      messages.add(msg);

      WidgetsBinding.instance.addPostFrameCallback(
        (_) => chatScrollToBottom(),
      );
      if (!liveStatus.value || isBackground) {
        return;
      }

      addDanmaku([
        DanmakuContentItem(
          msg.message,
          color: Color.fromARGB(
            255,
            msg.color.r,
            msg.color.g,
            msg.color.b,
          ),
        ),
      ]);
    } else if (msg.type == LiveMessageType.online) {
      online.value = msg.data;
    } else if (msg.type == LiveMessageType.superChat) {
      superChats.add(msg.data);
    }
  }

  /// 添加一条系统消息
  void addSysMsg(String msg) {
    messages.add(
      LiveMessage(
        type: LiveMessageType.chat,
        userName: "LiveSysMessage",
        message: msg,
        color: LiveMessageColor.white,
      ),
    );
  }

  /// 接收到WebSocket关闭信息
  void onWSClose(String msg) {
    addSysMsg(msg);
  }

  /// WebSocket准备就绪
  void onWSReady() {
    addSysMsg("弹幕服务器连接正常");
  }

  /// 加载直播间信息
  Future<void> loadData() async {
    final generation = ++_streamOperationGeneration;
    _streamLoadGeneration = generation;
    _playbackStableTimer?.cancel();
    try {
      SmartDialog.showLoading(msg: "");
      loadError.value = false;
      error = null;
      _loadErrorStackTrace = null;
      update();
      addSysMsg("正在读取直播间信息");
      final roomDetail = await site.liveSite.getRoomDetail(roomId: roomId);
      if (!_isStreamOperationCurrent(generation)) {
        return;
      }
      detail.value = roomDetail;

      if (site.id == Constant.kDouyin) {
        // 1.6.0之前收藏的WebRid
        // 1.6.0收藏的RoomID
        // 1.6.0之后改回WebRid
        if (detail.value!.roomId != roomId) {
          var oldId = roomId;
          rxRoomId.value = detail.value!.roomId;
          if (followed.value) {
            // 更新关注列表
            DBService.instance.deleteFollow("${site.id}_$oldId");
            DBService.instance.addFollow(
              FollowUser(
                id: "${site.id}_$roomId",
                roomId: roomId,
                siteId: site.id,
                userName: detail.value!.userName,
                face: detail.value!.userAvatar,
                addTime: DateTime.now(),
              ),
            );
          } else {
            followed.value =
                DBService.instance.getFollowExist("${site.id}_$roomId");
          }
        }
      }

      getSuperChatMessage();

      addHistory();
      // 确认房间关注状态
      followed.value = DBService.instance.getFollowExist("${site.id}_$roomId");
      online.value = detail.value!.online;
      liveStatus.value = detail.value!.status || detail.value!.isRecord;
      if (liveStatus.value) {
        await getPlayQualites(operationGeneration: generation);
      } else {
        await player.stop();
        if (_isStreamOperationCurrent(generation)) {
          await WakelockPlus.disable();
        }
      }
      if (!_isStreamOperationCurrent(generation)) {
        return;
      }
      if (detail.value!.isRecord) {
        addSysMsg("当前主播未开播，正在轮播录像");
      }
      addSysMsg("开始连接弹幕服务器");
      initDanmau();
      liveDanmaku.start(detail.value?.danmakuData);
      startLiveDurationTimer(); // 启动开播时长定时器
    } catch (e, stackTrace) {
      if (!_isStreamOperationCurrent(generation)) {
        return;
      }
      Log.logPrint(e);
      //SmartDialog.showToast(e.toString());
      loadError.value = true;
      error = e;
      _loadErrorStackTrace = stackTrace;
    } finally {
      if (_streamLoadGeneration == generation) {
        _streamLoadGeneration = null;
      }
      _checkPendingPlaybackFailure(generation);
      SmartDialog.dismiss(status: SmartStatus.loading);
    }
  }

  /// 初始化播放器
  Future<void> getPlayQualites({int? operationGeneration}) async {
    final generation = operationGeneration ?? ++_streamOperationGeneration;
    if (!_isStreamOperationCurrent(generation)) {
      return;
    }
    if (operationGeneration == null) {
      _streamLoadGeneration = generation;
    }
    _playbackStableTimer?.cancel();

    try {
      var playQualites =
          await site.liveSite.getPlayQualites(detail: detail.value!);
      if (!_isStreamOperationCurrent(generation)) {
        return;
      }

      if (playQualites.isEmpty) {
        throw StateError("无法读取播放清晰度");
      }
      var qualityLevel = await getQualityLevel();
      if (!_isStreamOperationCurrent(generation)) {
        return;
      }
      qualites.value = playQualites;
      if (qualityLevel == 2) {
        //最高
        currentQuality = 0;
      } else if (qualityLevel == 0) {
        //最低
        currentQuality = playQualites.length - 1;
      } else {
        //中间值
        int middle = (playQualites.length / 2).floor();
        currentQuality = middle;
      }

      await getPlayUrl(operationGeneration: generation);
    } catch (e) {
      if (!_isStreamOperationCurrent(generation)) {
        return;
      }
      Log.logPrint(e);
      errorMsg.value = "无法读取播放数据，请刷新重试";
      if (operationGeneration != null) {
        rethrow;
      }
      SmartDialog.showToast("无法读取播放清晰度");
    } finally {
      if (operationGeneration == null && _streamLoadGeneration == generation) {
        _streamLoadGeneration = null;
        _checkPendingPlaybackFailure(generation);
      }
    }
  }

  Future<int> getQualityLevel() async {
    var qualityLevel = AppSettingsController.instance.qualityLevel.value;
    try {
      var connectivityResult = await (Connectivity().checkConnectivity());
      if (connectivityResult.first == ConnectivityResult.mobile) {
        qualityLevel =
            AppSettingsController.instance.qualityLevelCellular.value;
      }
    } catch (e) {
      Log.logPrint(e);
    }
    return qualityLevel;
  }

  /// 获取播放地址并初始化播放列表。
  ///
  /// [resetRetryCount] 为 true 时重置错误重试计数（正常首播/切清晰度场景）；
  /// 由错误重试触发时应传 false，以保留计数，避免陷入无限重试而无法切换线路。
  Future<void> getPlayUrl({
    bool resetRetryCount = true,
    int? operationGeneration,
    bool preserveLine = false,
  }) async {
    final generation = operationGeneration ?? ++_streamOperationGeneration;
    if (!_isStreamOperationCurrent(generation) ||
        detail.value == null ||
        currentQuality < 0 ||
        currentQuality >= qualites.length) {
      return;
    }
    if (operationGeneration == null) {
      _streamLoadGeneration = generation;
    }
    _playbackStableTimer?.cancel();
    final quality = qualites[currentQuality];
    final previousLineIndex = currentLineIndex;
    try {
      final playUrl = await site.liveSite
          .getPlayUrls(detail: detail.value!, quality: quality);
      if (!_isStreamOperationCurrent(generation)) {
        return;
      }
      if (playUrl.urls.isEmpty) {
        throw StateError("无法读取播放地址");
      }

      // 保留旧线路直到新地址就绪，避免结束事件把临时空列表误判为关播。
      playUrls.value = playUrl.urls;
      playHeaders = playUrl.headers;
      currentQualityInfo.value = quality.quality;
      currentLineIndex = preserveLine &&
              previousLineIndex >= 0 &&
              previousLineIndex < playUrl.urls.length
          ? previousLineIndex
          : 0;
      if (resetRetryCount) {
        mediaErrorRetryCount = 0;
      }
      await initPlaylist(operationGeneration: generation);
    } catch (failure) {
      if (operationGeneration != null) {
        rethrow;
      }
      if (_isStreamOperationCurrent(generation)) {
        Log.logPrint(failure);
        errorMsg.value = "无法读取播放地址，请刷新重试";
      }
    } finally {
      if (operationGeneration == null && _streamLoadGeneration == generation) {
        _streamLoadGeneration = null;
        _checkPendingPlaybackFailure(generation);
      }
    }
  }

  Future<void> changePlayLine(int index) async {
    if (index < 0 || index >= playUrls.length) {
      return;
    }
    final generation = ++_streamOperationGeneration;
    _streamLoadGeneration = generation;
    _playbackStableTimer?.cancel();
    currentLineIndex = index;
    //重置错误次数
    mediaErrorRetryCount = 0;
    try {
      await initPlaylist(operationGeneration: generation);
    } catch (failure) {
      if (_isStreamOperationCurrent(generation)) {
        Log.logPrint(failure);
        errorMsg.value = "切换线路失败，请刷新重试";
      }
    } finally {
      if (_streamLoadGeneration == generation) {
        _streamLoadGeneration = null;
      }
      _checkPendingPlaybackFailure(generation);
    }
  }

  Future<void> initPlaylist({required int operationGeneration}) async {
    if (!_isStreamOperationCurrent(operationGeneration)) {
      return;
    }
    currentLineInfo.value = "线路${currentLineIndex + 1}";
    errorMsg.value = "";

    if (currentLineIndex < 0 || currentLineIndex >= playUrls.length) {
      return;
    }
    var url = playUrls[currentLineIndex];
    if (AppSettingsController.instance.playerForceHttps.value) {
      url = url.replaceAll("http://", "https://");
    }

    // 初始化播放器并设置 ao 参数
    await initializePlayer();
    if (!_isStreamOperationCurrent(operationGeneration)) {
      return;
    }

    // 各线路是同一直播的备用地址，由控制器统一重试和切换。
    await player.open(Media(url, httpHeaders: playHeaders));
    if (_isStreamOperationCurrent(operationGeneration) &&
        !player.state.playing) {
      await player.play();
    }
  }

  Future<void> setPlayer() async {
    await changePlayLine(currentLineIndex);
  }

  bool _isStreamOperationCurrent(int generation) {
    return generation == _streamOperationGeneration &&
        !isBackground &&
        !isClosed;
  }

  @override
  Future<void> mediaEnd() => _recoverPlayback();

  int mediaErrorRetryCount = 0;
  @override
  Future<void> mediaError(String error) => _recoverPlayback(error: error);

  Future<void> _recoverPlayback({String? error}) async {
    if (isClosed || !liveStatus.value) {
      return;
    }
    if (_isChangingStream) {
      _pendingPlaybackFailureGeneration = _streamOperationGeneration;
      _pendingPlaybackError = error;
      return;
    }
    _playbackStableTimer?.cancel();
    if (isBackground) {
      _resumeStreamPending = true;
      return;
    }
    final generation = ++_streamOperationGeneration;
    _mediaRecoveryGeneration = generation;
    try {
      if (mediaErrorRetryCount < 2) {
        mediaErrorRetryCount += 1;
        Log.d("直播流断开，重试次数：$mediaErrorRetryCount，原因：${error ?? '播放结束'}");
        if (mediaErrorRetryCount == 2) {
          await Future<void>.delayed(const Duration(seconds: 1));
        }
        if (!_isStreamOperationCurrent(generation)) {
          return;
        }
        try {
          await getPlayUrl(
            resetRetryCount: false,
            operationGeneration: generation,
            preserveLine: true,
          );
        } catch (failure) {
          if (!_isStreamOperationCurrent(generation)) {
            return;
          }
          if (currentLineIndex < 0 || currentLineIndex >= playUrls.length) {
            rethrow;
          }
          Log.d("刷新地址失败，尝试重连现有线路：$failure");
          await initPlaylist(operationGeneration: generation);
        }
      } else if (currentLineIndex >= 0 &&
          currentLineIndex + 1 < playUrls.length) {
        await changePlayLine(currentLineIndex + 1);
      } else {
        // 播放连接结束并不能证明主播下播，必须向平台确认状态。
        final refreshedDetail =
            await site.liveSite.getRoomDetail(roomId: roomId);
        if (!_isStreamOperationCurrent(generation)) {
          return;
        }
        detail.value = refreshedDetail;
        online.value = refreshedDetail.online;
        if (!refreshedDetail.status && !refreshedDetail.isRecord) {
          liveStatus.value = false;
          startLiveDurationTimer();
          await player.stop();
          if (_isStreamOperationCurrent(generation)) {
            await WakelockPlus.disable();
          }
        } else {
          errorMsg.value = "直播流已断开，请刷新重试";
        }
      }
    } catch (failure) {
      if (_isStreamOperationCurrent(generation)) {
        Log.logPrint(failure);
        errorMsg.value = "恢复播放失败，请刷新重试";
        addSysMsg("恢复播放失败：$failure");
      }
    } finally {
      if (_mediaRecoveryGeneration == generation) {
        _mediaRecoveryGeneration = null;
      }
      if (_isStreamOperationCurrent(generation) &&
          errorMsg.value.isNotEmpty &&
          (player.state.completed || !player.state.playing)) {
        await WakelockPlus.disable();
      }
      _checkPendingPlaybackFailure(_streamOperationGeneration);
    }
  }

  void _checkPendingPlaybackFailure(int generation) {
    if (_pendingPlaybackFailureGeneration != generation ||
        !_isStreamOperationCurrent(generation) ||
        _isChangingStream) {
      return;
    }
    final error = _pendingPlaybackError;
    _pendingPlaybackFailureGeneration = null;
    _pendingPlaybackError = null;
    // 重开期间的旧连接事件可忽略，但新连接立即失败时仍需继续恢复。
    if (errorMsg.value.isEmpty &&
        (player.state.completed || !player.state.playing)) {
      unawaited(_recoverPlayback(error: error));
    }
  }

  @override
  void onPlayingChanged(bool playing) {
    _playbackStableTimer?.cancel();
    if (!playing || isClosed || player.state.buffering) {
      return;
    }
    // 持续播放后才恢复重试预算，避免连接刚打开就失败时无限重试。
    final generation = _streamOperationGeneration;
    _playbackStableTimer = Timer(const Duration(seconds: 10), () {
      if (_isStreamOperationCurrent(generation) && player.state.playing) {
        mediaErrorRetryCount = 0;
      }
    });
  }

  @override
  void onBufferingChanged(bool buffering) {
    onPlayingChanged(player.state.playing && !buffering);
  }

  /// 读取SC
  void getSuperChatMessage() async {
    try {
      var sc =
          await site.liveSite.getSuperChatMessage(roomId: detail.value!.roomId);
      superChats.addAll(sc);
    } catch (e) {
      Log.logPrint(e);
      addSysMsg("SC读取失败");
    }
  }

  /// 移除掉已到期的SC
  void removeSuperChats() async {
    var now = DateTime.now().millisecondsSinceEpoch;
    superChats.value = superChats
        .where((x) => x.endTime.millisecondsSinceEpoch > now)
        .toList();
  }

  /// 添加历史记录
  void addHistory() {
    if (detail.value == null) {
      return;
    }
    var id = "${site.id}_$roomId";
    var history = DBService.instance.getHistory(id);
    if (history != null) {
      history.updateTime = DateTime.now();
    }
    history ??= History(
      id: id,
      roomId: roomId,
      siteId: site.id,
      userName: detail.value?.userName ?? "",
      face: detail.value?.userAvatar ?? "",
      updateTime: DateTime.now(),
    );

    DBService.instance.addOrUpdateHistory(history);
  }

  /// 关注用户
  void followUser() {
    if (detail.value == null) {
      return;
    }
    var id = "${site.id}_$roomId";
    DBService.instance.addFollow(
      FollowUser(
        id: id,
        roomId: roomId,
        siteId: site.id,
        userName: detail.value?.userName ?? "",
        face: detail.value?.userAvatar ?? "",
        addTime: DateTime.now(),
      ),
    );
    followed.value = true;
    EventBus.instance.emit(Constant.kUpdateFollow, id);
  }

  /// 取消关注用户
  void removeFollowUser() async {
    if (detail.value == null) {
      return;
    }
    if (!await Utils.showAlertDialog("确定要取消关注该用户吗？", title: "取消关注")) {
      return;
    }

    var id = "${site.id}_$roomId";
    DBService.instance.deleteFollow(id);
    followed.value = false;
    EventBus.instance.emit(Constant.kUpdateFollow, id);
  }

  void share() {
    if (detail.value == null) {
      return;
    }
    SharePlus.instance.share(ShareParams(uri: Uri.parse(detail.value!.url)));
  }

  void copyUrl() {
    if (detail.value == null) {
      return;
    }
    Utils.copyToClipboard(detail.value!.url);
    SmartDialog.showToast("已复制直播间链接");
  }

  /// 复制新生成的直播流
  void copyPlayUrl() async {
    // 未开播不复制
    if (!liveStatus.value) {
      return;
    }
    var playUrl = await site.liveSite
        .getPlayUrls(detail: detail.value!, quality: qualites[currentQuality]);
    if (playUrl.urls.isEmpty) {
      SmartDialog.showToast("无法读取播放地址");
      return;
    }
    Utils.copyToClipboard(playUrl.urls.first);
    SmartDialog.showToast("已复制播放直链");
  }

  /// 底部打开播放器设置
  void showDanmuSettingsSheet() {
    Utils.showBottomSheet(
      title: "弹幕设置",
      child: ListView(
        padding: AppStyle.edgeInsetsA12,
        children: [
          DanmuSettingsView(
            danmakuController: danmakuController,
            onTapDanmuShield: () {
              Get.back();
              showDanmuShield();
            },
          ),
        ],
      ),
    );
  }

  void showVolumeSlider(BuildContext targetContext) {
    SmartDialog.showAttach(
      targetContext: targetContext,
      alignment: Alignment.topCenter,
      displayTime: const Duration(seconds: 3),
      maskColor: const Color(0x00000000),
      builder: (context) {
        return Container(
          decoration: BoxDecoration(
            borderRadius: AppStyle.radius12,
            color: Theme.of(context).cardColor,
          ),
          padding: AppStyle.edgeInsetsA4,
          child: Obx(
            () => SizedBox(
              width: 200,
              child: Slider(
                min: 0,
                max: 100,
                value: AppSettingsController.instance.playerVolume.value,
                onChanged: (newValue) {
                  player.setVolume(newValue);
                  AppSettingsController.instance.setPlayerVolume(newValue);
                },
              ),
            ),
          ),
        );
      },
    );
  }

  void showQualitySheet() {
    Utils.showBottomSheet(
      title: "切换清晰度",
      child: RadioGroup(
        groupValue: currentQuality,
        onChanged: (e) {
          Get.back();
          currentQuality = e ?? 0;
          getPlayUrl();
        },
        child: ListView.builder(
          itemCount: qualites.length,
          itemBuilder: (_, i) {
            var item = qualites[i];
            return RadioListTile(
              value: i,
              title: Text(item.quality),
            );
          },
        ),
      ),
    );
  }

  void showPlayUrlsSheet() {
    Utils.showBottomSheet(
      title: "切换线路",
      child: RadioGroup(
        groupValue: currentLineIndex,
        onChanged: (e) {
          Get.back();
          //currentLineIndex = i;
          //setPlayer();
          changePlayLine(e ?? 0);
        },
        child: ListView.builder(
          itemCount: playUrls.length,
          itemBuilder: (_, i) {
            return RadioListTile(
              value: i,
              title: Text("线路${i + 1}"),
              secondary: Text(
                playUrls[i].contains(".flv") ? "FLV" : "HLS",
              ),
            );
          },
        ),
      ),
    );
  }

  void showPlayerSettingsSheet() {
    Utils.showBottomSheet(
      title: "画面尺寸",
      child: Obx(
        () => RadioGroup(
          groupValue: AppSettingsController.instance.scaleMode.value,
          onChanged: (e) {
            AppSettingsController.instance.setScaleMode(e ?? 0);
            updateScaleMode();
          },
          child: ListView(
            padding: AppStyle.edgeInsetsV12,
            children: const [
              RadioListTile(
                value: 0,
                title: Text("适应"),
                visualDensity: VisualDensity.compact,
              ),
              RadioListTile(
                value: 1,
                title: Text("拉伸"),
                visualDensity: VisualDensity.compact,
              ),
              RadioListTile(
                value: 2,
                title: Text("铺满"),
                visualDensity: VisualDensity.compact,
              ),
              RadioListTile(
                value: 3,
                title: Text("16:9"),
                visualDensity: VisualDensity.compact,
              ),
              RadioListTile(
                value: 4,
                title: Text("4:3"),
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
        ),
      ),
    );
  }

  void showDanmuShield() {
    TextEditingController keywordController = TextEditingController();

    void addKeyword() {
      if (keywordController.text.isEmpty) {
        SmartDialog.showToast("请输入关键词");
        return;
      }

      AppSettingsController.instance
          .addShieldList(keywordController.text.trim());
      keywordController.text = "";
    }

    Utils.showBottomSheet(
      title: "关键词屏蔽",
      child: ListView(
        padding: AppStyle.edgeInsetsA12,
        children: [
          TextField(
            controller: keywordController,
            decoration: InputDecoration(
              contentPadding: AppStyle.edgeInsetsH12,
              border: const OutlineInputBorder(),
              hintText: "请输入关键词",
              suffixIcon: TextButton.icon(
                onPressed: addKeyword,
                icon: const Icon(Icons.add),
                label: const Text("添加"),
              ),
            ),
            onSubmitted: (e) {
              addKeyword();
            },
          ),
          AppStyle.vGap12,
          Obx(
            () => Text(
              "已添加${AppSettingsController.instance.shieldList.length}个关键词（点击移除）",
              style: Get.textTheme.titleSmall,
            ),
          ),
          AppStyle.vGap12,
          Obx(
            () => Wrap(
              runSpacing: 12,
              spacing: 12,
              children: AppSettingsController.instance.shieldList
                  .map(
                    (item) => InkWell(
                      borderRadius: AppStyle.radius24,
                      onTap: () {
                        AppSettingsController.instance.removeShieldList(item);
                      },
                      child: Container(
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.grey),
                          borderRadius: AppStyle.radius24,
                        ),
                        padding: AppStyle.edgeInsetsH12.copyWith(
                          top: 4,
                          bottom: 4,
                        ),
                        child: Text(
                          item,
                          style: Get.textTheme.bodyMedium,
                        ),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ),
        ],
      ),
    );
  }

  void showFollowUserSheet() {
    Utils.showBottomSheet(
      title: "关注列表",
      child: Obx(
        () => Stack(
          children: [
            RefreshIndicator(
              onRefresh: FollowService.instance.loadData,
              child: ListView.builder(
                itemCount: FollowService.instance.liveList.length,
                itemBuilder: (_, i) {
                  var item = FollowService.instance.liveList[i];
                  return Obx(
                    () => FollowUserItem(
                      item: item,
                      playing: rxSite.value.id == item.siteId &&
                          rxRoomId.value == item.roomId,
                      onTap: () {
                        Get.back();
                        resetRoom(
                          Sites.allSites[item.siteId]!,
                          item.roomId,
                        );
                      },
                    ),
                  );
                },
              ),
            ),
            if (Platform.isLinux || Platform.isWindows || Platform.isMacOS)
              Positioned(
                right: 12,
                bottom: 12,
                child: Obx(
                  () => DesktopRefreshButton(
                    refreshing: FollowService.instance.updating.value,
                    onPressed: FollowService.instance.loadData,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  void showAutoExitSheet() {
    if (AppSettingsController.instance.autoExitEnable.value &&
        !delayAutoExit.value) {
      SmartDialog.showToast("已设置了全局定时关闭");
      return;
    }
    Utils.showBottomSheet(
      title: "定时关闭",
      child: ListView(
        children: [
          Obx(
            () => SwitchListTile(
              title: Text(
                "启用定时关闭",
                style: Get.textTheme.titleMedium,
              ),
              value: autoExitEnable.value,
              onChanged: (e) {
                autoExitEnable.value = e;

                setAutoExit();
                //controller.setAutoExitEnable(e);
              },
            ),
          ),
          Obx(
            () => ListTile(
              enabled: autoExitEnable.value,
              title: Text(
                "自动关闭时间：${autoExitMinutes.value ~/ 60}小时${autoExitMinutes.value % 60}分钟",
                style: Get.textTheme.titleMedium,
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () async {
                var value = await showTimePicker(
                  context: Get.context!,
                  initialTime: TimeOfDay(
                    hour: autoExitMinutes.value ~/ 60,
                    minute: autoExitMinutes.value % 60,
                  ),
                  initialEntryMode: TimePickerEntryMode.inputOnly,
                  builder: (_, child) {
                    return MediaQuery(
                      data: Get.mediaQuery.copyWith(
                        alwaysUse24HourFormat: true,
                      ),
                      child: child!,
                    );
                  },
                );
                if (value == null || (value.hour == 0 && value.minute == 0)) {
                  return;
                }
                var duration =
                    Duration(hours: value.hour, minutes: value.minute);
                autoExitMinutes.value = duration.inMinutes;
                AppSettingsController.instance
                    .setRoomAutoExitDuration(autoExitMinutes.value);
                //setAutoExitDuration(duration.inMinutes);
                setAutoExit();
              },
            ),
          ),
        ],
      ),
    );
  }

  void openNaviteAPP() async {
    var naviteUrl = "";
    var webUrl = "";
    if (site.id == Constant.kBiliBili) {
      naviteUrl = "bilibili://live/${detail.value?.roomId}";
      webUrl = "https://live.bilibili.com/${detail.value?.roomId}";
    } else if (site.id == Constant.kDouyin) {
      var args = detail.value?.danmakuData as DouyinDanmakuArgs;
      naviteUrl = "snssdk1128://webcast_room?room_id=${args.roomId}";
      webUrl = "https://live.douyin.com/${args.webRid}";
    } else if (site.id == Constant.kHuya) {
      var args = detail.value?.danmakuData as HuyaDanmakuArgs;
      naviteUrl =
          "yykiwi://homepage/index.html?banneraction=https%3A%2F%2Fdiy-front.cdn.huya.com%2Fzt%2Ffrontpage%2Fcc%2Fupdate.html%3Fhyaction%3Dlive%26channelid%3D${args.subSid}%26subid%3D${args.subSid}%26liveuid%3D${args.subSid}%26screentype%3D1%26sourcetype%3D0%26fromapp%3Dhuya_wap%252Fclick%252Fopen_app_guide%26&fromapp=huya_wap/click/open_app_guide";
      webUrl = "https://www.huya.com/${detail.value?.roomId}";
    } else if (site.id == Constant.kDouyu) {
      naviteUrl =
          "douyulink://?type=90001&schemeUrl=douyuapp%3A%2F%2Froom%3FliveType%3D0%26rid%3D${detail.value?.roomId}";
      webUrl = "https://www.douyu.com/${detail.value?.roomId}";
    }
    try {
      await launchUrlString(naviteUrl, mode: LaunchMode.externalApplication);
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast("无法打开APP，将使用浏览器打开");
      await launchUrlString(webUrl, mode: LaunchMode.externalApplication);
    }
  }

  Future<void> resetRoom(Site site, String roomId) async {
    if (this.site == site && this.roomId == roomId) {
      return;
    }

    final generation = ++_streamOperationGeneration;
    _streamLoadGeneration = generation;
    _playbackStableTimer?.cancel();
    _danmakuResumeTimer?.cancel();
    _danmakuResumeTimer = null;
    rxSite.value = site;
    rxRoomId.value = roomId;

    // 清除全部消息
    liveDanmaku.stop();
    messages.clear();
    superChats.clear();
    danmakuController?.clear();

    // 重新设置LiveDanmaku
    liveDanmaku = site.liveSite.getDanmaku();

    // 停止播放
    await player.stop();

    // 刷新信息
    if (_isStreamOperationCurrent(generation)) {
      await loadData();
    }
  }

  void copyErrorDetail() {
    Utils.copyToClipboard('''直播平台：${rxSite.value.name}
房间号：${rxRoomId.value}
错误信息：
${error?.toString()}
----------------
$_loadErrorStackTrace''');
    SmartDialog.showToast("已复制错误信息");
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    if (state == AppLifecycleState.paused) {
      Log.d("进入后台");
      //进入后台，关闭弹幕
      danmakuController?.clear();
      _resumeStreamPending = _resumeStreamPending || _isChangingStream;
      isBackground = true;
      _streamOperationGeneration += 1;
      _playbackStableTimer?.cancel();
      _enterBackgroundTime = DateTime.now();
      _danmakuResumeTimer?.cancel();
      _danmakuResumeTimer = null;
      unawaited(liveDanmaku.stop());
    } else
    //返回前台
    if (state == AppLifecycleState.resumed) {
      Log.d("返回前台");
      isBackground = false;
      // canvas_danmaku 进入后台时会暂停内部渲染，返回前台后不会自动恢复。
      danmakuController?.resume();
      onPlayingChanged(player.state.playing);
      unawaited(_handleResumeFromBackground());
    }
  }

  /// 返回前台后重建弹幕连接。
  ///
  /// Android 从后台恢复时网络与 DNS 可能尚未就绪，因此延迟一次连接；
  /// 若期间再次进入后台，则取消本次恢复，避免后台持续重连。
  void _restartDanmakuAfterResume() {
    _danmakuResumeTimer?.cancel();
    if (!liveStatus.value || detail.value == null) {
      return;
    }

    _danmakuResumeTimer = Timer(const Duration(seconds: 1), () async {
      _danmakuResumeTimer = null;
      if (isBackground || !liveStatus.value || detail.value == null) {
        return;
      }

      try {
        await liveDanmaku.stop();
        if (isBackground) {
          return;
        }
        initDanmau();
        addSysMsg("正在重新连接弹幕服务器");
        await liveDanmaku.start(detail.value?.danmakuData);
      } catch (error) {
        Log.logPrint(error);
        onWSClose("弹幕服务器重连失败：$error");
      }
    });
  }

  /// 返回前台后处理直播流恢复。
  ///
  /// 直播地址带有时效签名，App 挂后台期间连接可能被系统挂起或地址失效，
  /// 播放器若继续使用旧连接会停留在过期缓冲、落后于真实直播进度，
  /// 表现为画面卡住或视频流被截断。因此后台停留超过阈值时重新读取直播间详情，
  /// 生成新的签名、清晰度数据和播放地址后重开播放器。
  Future<void> _handleResumeFromBackground() async {
    final enterTime = _enterBackgroundTime;
    _enterBackgroundTime = null;

    if (enterTime == null) {
      _restartDanmakuAfterResume();
      return;
    }

    final backgroundDuration = DateTime.now().difference(enterTime);
    if (!_resumeStreamPending &&
        (!liveStatus.value ||
            backgroundDuration < _backgroundReloadThreshold)) {
      _restartDanmakuAfterResume();
      return;
    }

    final operationGeneration = ++_streamOperationGeneration;
    _resumeStreamPending = false;
    Log.d("后台停留${backgroundDuration.inSeconds}秒，重新读取直播间和播放数据");
    await _reloadRoomAfterBackground(operationGeneration);
  }

  /// 重新读取直播间详情并重开播放器，用于刷新平台签名和追赶直播进度。
  Future<void> _reloadRoomAfterBackground(int operationGeneration) async {
    if (!_isStreamOperationCurrent(operationGeneration)) {
      return;
    }

    _backgroundReloadGeneration = operationGeneration;
    try {
      final refreshedDetail = await site.liveSite.getRoomDetail(roomId: roomId);
      if (!_isStreamOperationCurrent(operationGeneration)) {
        return;
      }

      detail.value = refreshedDetail;
      online.value = refreshedDetail.online;
      liveStatus.value = refreshedDetail.status || refreshedDetail.isRecord;
      startLiveDurationTimer();

      if (!liveStatus.value) {
        await player.stop();
        if (!_isStreamOperationCurrent(operationGeneration)) {
          return;
        }
        await WakelockPlus.disable();
        if (!_isStreamOperationCurrent(operationGeneration)) {
          return;
        }
        qualites.clear();
        playUrls.clear();
        currentQuality = -1;
        currentLineIndex = -1;
        return;
      }

      mediaErrorRetryCount = 0;
      await getPlayQualites(operationGeneration: operationGeneration);
    } catch (error) {
      if (_isStreamOperationCurrent(operationGeneration)) {
        Log.logPrint(error);
        errorMsg.value = "恢复直播失败，请刷新重试";
        addSysMsg("恢复直播失败：$error");
        SmartDialog.showToast("恢复直播失败，请手动刷新");
      }
    } finally {
      if (_backgroundReloadGeneration == operationGeneration) {
        _backgroundReloadGeneration = null;
        if (_isStreamOperationCurrent(operationGeneration)) {
          _restartDanmakuAfterResume();
          _checkPendingPlaybackFailure(operationGeneration);
        }
      }
    }
  }

  // 用于启动开播时长计算和更新的函数
  void startLiveDurationTimer() {
    // 如果不是直播状态或者 showTime 为空，则不启动定时器
    if (!(detail.value?.status ?? false) || detail.value?.showTime == null) {
      liveDuration.value = "00:00:00"; // 未开播时显示 00:00:00
      _liveDurationTimer?.cancel();
      return;
    }

    try {
      int startTimeStamp = int.parse(detail.value!.showTime!);
      // 取消之前的定时器
      _liveDurationTimer?.cancel();
      // 创建新的定时器，每秒更新一次
      _liveDurationTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        int currentTimeStamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        int durationInSeconds = currentTimeStamp - startTimeStamp;

        int hours = durationInSeconds ~/ 3600;
        int minutes = (durationInSeconds % 3600) ~/ 60;
        int seconds = durationInSeconds % 60;

        String formattedDuration =
            '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
        liveDuration.value = formattedDuration;
      });
    } catch (e) {
      liveDuration.value = "--:--:--"; // 错误时显示 --:--:--
    }
  }

  @override
  void onClose() {
    WidgetsBinding.instance.removeObserver(this);
    scrollController.removeListener(scrollListener);
    autoExitTimer?.cancel();

    _streamOperationGeneration += 1;
    _backgroundReloadGeneration = null;
    _playbackStableTimer?.cancel();
    _danmakuResumeTimer?.cancel();
    _danmakuResumeTimer = null;
    liveDanmaku.stop();
    danmakuController = null;
    _liveDurationTimer?.cancel(); // 页面关闭时取消定时器
    super.onClose();
  }
}
