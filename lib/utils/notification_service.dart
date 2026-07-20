import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:webview_master_app/services/api_service.dart';
import 'package:webview_master_app/config/app_config.dart';
import 'dart:io' show Platform;
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_overlay_window/flutter_overlay_window.dart'
    hide NotificationVisibility;
import 'package:webview_master_app/utils/ringtone_player.dart';

/// Notification Service - Handles system tray notifications
class NotificationService {
  static final NotificationService _instance = NotificationService._internal();

  factory NotificationService() => _instance;

  NotificationService._internal();

  final FlutterLocalNotificationsPlugin _notificationsPlugin =
      FlutterLocalNotificationsPlugin();

  FirebaseMessaging? _firebaseMessaging;

  bool _isInitialized = false;

  // Track shown notifications to prevent duplicates
  final Set<String> _shownNotificationIds = <String>{};
  final Map<String, DateTime> _notificationTimestamps = <String, DateTime>{};

  // Looping ringtone played for new order alerts in this (main) isolate
  final RingtonePlayer _ringtonePlayer = RingtonePlayer();

  // Broadcast stream for new-order events so the WebView screen can show an
  // in-app popup immediately, even when the app is already in the foreground.
  static final StreamController<Map<String, dynamic>> _orderEventController =
      StreamController<Map<String, dynamic>>.broadcast();

  /// Listen to this stream to receive new-order events in the UI layer.
  static Stream<Map<String, dynamic>> get orderStream =>
      _orderEventController.stream;

  /// Stop the ringtone (this isolate) and ask the overlay isolate to stop
  /// its own ringtone loop too. Call this once the app is genuinely opened
  /// by the user (e.g. notification tap, or auto-open after the device is
  /// unlocked) - not merely because a notification was posted/shown.
  Future<void> stopOrderRingtone() async {
    debugPrint('🔕 stopOrderRingtone() called - stopping ringtone in main isolate and notifying overlay');
    await _ringtonePlayer.stop();
    try {
      await FlutterOverlayWindow.shareData(jsonEncode({'type': 'CLEAR_ORDER'}));
      debugPrint('🔕 Overlay notified with CLEAR_ORDER');
    } catch (e) {
      debugPrint('⚠️ Could not notify overlay to clear order: $e');
    }
  }

  /// Initialize notification service
  Future<void> initialize() async {
    if (_isInitialized) return;

    // Android initialization settings
    const AndroidInitializationSettings androidSettings =
        AndroidInitializationSettings(AppConfig.notificationIcon);

    // iOS initialization settings
    const DarwinInitializationSettings iosSettings =
        DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );

    // Combined initialization settings
    const InitializationSettings initSettings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );

    // Initialize the plugin
    await _notificationsPlugin.initialize(
      initSettings,
      onDidReceiveNotificationResponse: _onNotificationTapped,
    );

    // Create notification channel for Android
    await _createNotificationChannel();

    // Initialize Firebase Messaging
    await _initializeFirebaseMessaging();

    _isInitialized = true;
    debugPrint('✅ Notification service initialized');
  }

  /// Initialize Firebase Cloud Messaging
  Future<void> _initializeFirebaseMessaging() async {
    try {
      _firebaseMessaging = FirebaseMessaging.instance;

      // Request notification permission for iOS (Android permissions handled via PermissionHandler)
      if (Platform.isIOS) {
        NotificationSettings settings =
            await _firebaseMessaging!.requestPermission(
          alert: true,
          badge: true,
          sound: true,
          provisional: false,
        );

        if (settings.authorizationStatus == AuthorizationStatus.authorized) {
          debugPrint('✅ Firebase notification permission granted (iOS)');
        } else if (settings.authorizationStatus ==
            AuthorizationStatus.provisional) {
          debugPrint(
              '⚠️ Firebase notification permission granted provisionally (iOS)');
        } else {
          debugPrint('❌ Firebase notification permission denied (iOS)');
        }
      }

      // Get FCM token
      String? token = await _firebaseMessaging!.getToken();
      if (token != null) {
        debugPrint('📱 FCM Token: $token');
      } else {
        debugPrint('⚠️ FCM Token is null');
      }

      // Listen for token refresh
      _firebaseMessaging!.onTokenRefresh.listen((newToken) {
        debugPrint('🔄 FCM Token refreshed: $newToken');
      });

      // Configure foreground message handler
      FirebaseMessaging.onMessage.listen((RemoteMessage message) {
        debugPrint('📨 Foreground FCM message received: ${message.messageId}');
        _handleForegroundMessage(message);
      });

      // Handle notification tap when app is opened from terminated state
      FirebaseMessaging.instance
          .getInitialMessage()
          .then((RemoteMessage? message) {
        if (message != null) {
          debugPrint('📨 App opened from notification: ${message.messageId}');
          debugPrint('🚀 APP OPENED AUTOMATICALLY - launched from terminated state via notification');
          stopOrderRingtone();

          // Check if this was a new-order notification and emit the event so
          // the in-app popup is shown (SharedPreferences is the primary bridge
          // for this case, but the stream handles apps that were already open).
          final data = message.data;
          final normalizedType = data['type']?.toString().toUpperCase();
          final isOrder = normalizedType == 'ORDER' ||
              normalizedType == 'NEW_ORDER' ||
              normalizedType == 'NEW_ORDER_AVAILABLE';
          if (isOrder) {
            final orderEvent = {
              'orderId': data['orderId'] ?? data['order_id'] ?? data['id'] ?? '',
              'title': message.notification?.title ?? data['title']?.toString() ?? 'New Order',
              'body': message.notification?.body ?? data['body']?.toString() ?? 'You have a new delivery order',
            };
            debugPrint('🎯 ORDER EVENT: emitting from getInitialMessage for in-app popup');
            _orderEventController.add(orderEvent);
          }
        }
      });

      debugPrint('✅ Firebase Messaging initialized');
    } catch (e, stackTrace) {
      debugPrint('❌ Error initializing Firebase Messaging: $e');
      debugPrint('❌ Stack trace: $stackTrace');
      // Continue even if Firebase fails - local notifications will still work
    }
  }

  /// Handle foreground FCM messages
  Future<void> _handleForegroundMessage(RemoteMessage message) async {
    final data = message.data;

    debugPrint('================ FCM RECEIVED (FOREGROUND) ================');
    debugPrint('📦 Raw message.toMap(): ${message.toMap()}');
    debugPrint('📝 Title: ${message.notification?.title}');
    debugPrint('📝 Body: ${message.notification?.body}');
    debugPrint('📋 Data: $data');
    debugPrint('🆔 MessageId: ${message.messageId}');
    debugPrint('🆔 OrderId: ${data['orderId'] ?? data['order_id'] ?? data['id']}');
    debugPrint('🏷️ Type: ${data['type']}');
    debugPrint('👤 UserId: ${data['userId'] ?? data['user_id']}');
    debugPrint('🚚 DeliveryPartnerId: ${data['deliveryPartnerId'] ?? data['delivery_partner_id'] ?? data['partnerId'] ?? data['riderId']}');
    debugPrint('📱 App State: foreground');
    debugPrint('=============================================================');

    RemoteNotification? notification = message.notification;

    // Create unique ID for this notification
    String notificationId = message.messageId ?? '';

    // Clean old notification IDs (older than 5 minutes)
    _cleanOldNotificationIds();

    // Only the dedicated "new order" data type should trigger the order
    // ringtone/alarm channel. Status updates, accept/reject, cancellations,
    // promos, etc. must never play the ringtone, even if their title/body
    // happens to contain the word "order".
    final type = data['type']?.toString();
    final normalizedType = type?.toUpperCase();
    final isOrder = normalizedType == 'ORDER' ||
        normalizedType == 'NEW_ORDER' ||
        normalizedType == 'NEW_ORDER_AVAILABLE';

    debugPrint('🔎 isOrder evaluation: type="$type" (normalized="$normalizedType") -> isOrder=$isOrder');

    // Note: the app is in the foreground/active for FCM.onMessage to fire at
    // all, so the looping order ringtone must NOT be started here (and the
    // overlay must not be told to start its own ringtone either) - per
    // product requirement, the ringtone only plays while the app is in the
    // background, locked, or terminated.
    if (isOrder) {
      debugPrint('🔔 Sound/ringtone trigger status: SKIPPED (app is in foreground/active, ringtone only plays in background/locked/terminated)');
      // Emit the order event so the in-app popup is shown immediately while
      // the app is in the foreground.
      final orderEvent = {
        'orderId': data['orderId'] ?? data['order_id'] ?? data['id'] ?? '',
        'title': message.notification?.title ?? data['title']?.toString() ?? 'New Order',
        'body': message.notification?.body ?? data['body']?.toString() ?? 'You have a new delivery order',
      };
      debugPrint('🎯 ORDER EVENT: emitting to orderStream for in-app popup');
      _orderEventController.add(orderEvent);
    } else {
      debugPrint('🔔 Sound/ringtone trigger status: SKIPPED (not an order message)');
    }

    if (notification != null) {
      debugPrint('📨 Notification title: ${notification.title}');
      debugPrint('📨 Notification body: ${notification.body}');

      // Create a unique ID - use messageId if available, otherwise create from content
      final String uniqueId = notificationId.isNotEmpty
          ? notificationId
          : '${notification.title}_${notification.body}_${message.sentTime?.millisecondsSinceEpoch ?? DateTime.now().millisecondsSinceEpoch}';

      // Check if this notification was already shown (prevent duplicates)
      if (_shownNotificationIds.contains(uniqueId)) {
        debugPrint('⚠️ Duplicate notification detected, skipping: $uniqueId');
        debugPrint('🖼️ POPUP: skipped (duplicate) - $uniqueId');
        return;
      }

      // Mark as shown
      _shownNotificationIds.add(uniqueId);
      _notificationTimestamps[uniqueId] = DateTime.now();

      // Ensure notification service is initialized
      if (!_isInitialized) {
        await initialize();
      }

      // Request permission if not granted
      if (!await Permission.notification.isGranted) {
        debugPrint('⚠️ Notification permission not granted, requesting...');
        final granted = await requestPermission();
        if (!granted) {
          debugPrint(
              '❌ Notification permission denied, cannot show notification');
          return;
        }
      }

      // Show notification
      debugPrint('🖼️ POPUP: showing (notification payload) - $uniqueId, isOrderAlert=$isOrder');
      await showNotification(
        title: notification.title ?? 'Notification',
        body: notification.body ?? '',
        payload: data.toString(),
        imageUrl: notification.android?.imageUrl ??
            notification.apple?.imageUrl?.toString(),
        notificationId: uniqueId,
        isOrderAlert: isOrder,
      );
    } else if (data.isNotEmpty) {
      // Handle data-only messages
      debugPrint('📨 Data-only message received');
      final title = data['title']?.toString() ?? 'Notification';
      final body =
          data['body']?.toString() ?? data['message']?.toString() ?? '';

      // Create unique ID for data-only messages
      final String uniqueId = notificationId.isNotEmpty
          ? notificationId
          : '${title}_${body}_${message.sentTime?.millisecondsSinceEpoch ?? DateTime.now().millisecondsSinceEpoch}';

      // Check for duplicates
      if (_shownNotificationIds.contains(uniqueId)) {
        debugPrint(
            '⚠️ Duplicate data-only notification detected, skipping: $uniqueId');
        debugPrint('🖼️ POPUP: skipped (duplicate) - $uniqueId');
        return;
      }

      // Mark as shown
      _shownNotificationIds.add(uniqueId);
      _notificationTimestamps[uniqueId] = DateTime.now();

      if (!_isInitialized) {
        await initialize();
      }

      if (!await Permission.notification.isGranted) {
        await requestPermission();
      }

      debugPrint('🖼️ POPUP: showing (data-only) - $uniqueId, isOrderAlert=$isOrder');
      await showNotification(
        title: title,
        body: body,
        payload: data.toString(),
        notificationId: uniqueId,
        isOrderAlert: isOrder,
      );
    } else {
      debugPrint('🖼️ POPUP: skipped - no notification payload and no data');
    }
  }

  /// Clean old notification IDs to prevent memory buildup
  void _cleanOldNotificationIds() {
    final now = DateTime.now();
    final keysToRemove = <String>[];

    _notificationTimestamps.forEach((id, timestamp) {
      if (now.difference(timestamp).inMinutes > 5) {
        keysToRemove.add(id);
      }
    });

    for (final id in keysToRemove) {
      _shownNotificationIds.remove(id);
      _notificationTimestamps.remove(id);
    }
  }

  /// Get FCM token
  Future<String?> getFCMToken() async {
    if (_firebaseMessaging == null) {
      await _initializeFirebaseMessaging();
    }
    return await _firebaseMessaging?.getToken();
  }

  Future<bool> saveFCMTokenToBackend({
    required String phone,
    String? platform,
  }) async {
    try {
      // Get FCM token
      final token = await getFCMToken();

      if (token == null || token.isEmpty) {
        debugPrint('❌ Cannot save FCM token: Token is null or empty');
        return false;
      }

      // Save to backend via API service
      final success = await ApiService().saveFCMToken(
        token: token,
        phone: phone,
        platform: platform,
      );

      if (success) {
        debugPrint('✅ FCM token saved to backend successfully');
      } else {
        debugPrint('❌ Failed to save FCM token to backend');
      }

      return success;
    } catch (e, stackTrace) {
      debugPrint('❌ Error saving FCM token to backend: $e');
      debugPrint('❌ Stack trace: $stackTrace');
      return false;
    }
  }

  /// Create Android notification channel
  Future<void> _createNotificationChannel() async {
    try {
      const AndroidNotificationChannel channel = AndroidNotificationChannel(
        AppConfig.notificationChannelId,
        AppConfig.notificationChannelName,
        description: AppConfig.notificationChannelDescription,
        importance: Importance.high,
        playSound: true,
        enableVibration: true,
        showBadge: true,
        enableLights: true,
        ledColor: AppConfig.notificationColor,
      );

      // Dedicated high-priority channel for new order alerts, with a
      // custom looping-friendly ringtone and alarm audio attributes so it
      // is audible on the lock screen and over silent/vibrate modes.
      final AndroidNotificationChannel orderChannel = AndroidNotificationChannel(
        AppConfig.orderNotificationChannelId,
        AppConfig.orderNotificationChannelName,
        description: AppConfig.orderNotificationChannelDescription,
        importance: Importance.max,
        playSound: true,
        sound: RawResourceAndroidNotificationSound(
            AppConfig.orderRingtoneRawResource),
        audioAttributesUsage: AudioAttributesUsage.alarm,
        enableVibration: true,
        vibrationPattern: Int64List.fromList(
            <int>[0, 1000, 500, 1000, 500, 1000, 500, 1000]),
        showBadge: true,
        enableLights: true,
        ledColor: AppConfig.notificationColor,
      );

      // The backend sends `notification.android.channelId: "maava_channel"`
      // for order pushes. Create that exact channel with the same
      // alarm-style settings so the system's auto-displayed notification
      // still rings loudly and shows on the lock screen.
      final AndroidNotificationChannel fcmOrderChannel = AndroidNotificationChannel(
        AppConfig.fcmOrderChannelId,
        AppConfig.orderNotificationChannelName,
        description: AppConfig.orderNotificationChannelDescription,
        importance: Importance.max,
        playSound: true,
        sound: RawResourceAndroidNotificationSound(
            AppConfig.orderRingtoneRawResource),
        audioAttributesUsage: AudioAttributesUsage.alarm,
        enableVibration: true,
        vibrationPattern: Int64List.fromList(
            <int>[0, 1000, 500, 1000, 500, 1000, 500, 1000]),
        showBadge: true,
        enableLights: true,
        ledColor: AppConfig.notificationColor,
      );

      final androidImplementation =
          _notificationsPlugin.resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();

      if (androidImplementation != null) {
        await androidImplementation.createNotificationChannel(channel);
        await androidImplementation.createNotificationChannel(orderChannel);
        await androidImplementation.createNotificationChannel(fcmOrderChannel);
        debugPrint(
            '✅ Notification channel created: ${AppConfig.notificationChannelId}');
        debugPrint(
            '✅ Order alert channel created: ${AppConfig.orderNotificationChannelId}');
        debugPrint(
            '✅ FCM order channel created: ${AppConfig.fcmOrderChannelId}');
        debugPrint('   Channel importance: ${channel.importance}');
        debugPrint('   Channel color: ${AppConfig.notificationColor}');
      } else {
        debugPrint('⚠️ Android notification plugin not available');
      }
    } catch (e) {
      debugPrint('❌ Error creating notification channel: $e');
    }
  }

  /// Handle notification tap
  void _onNotificationTapped(NotificationResponse response) {
    debugPrint('================ NOTIFICATION TAPPED ================');
    debugPrint('📱 Response type: ${response.notificationResponseType}');
    debugPrint('📱 Notification ID: ${response.id}');
    debugPrint('📱 Action ID: ${response.actionId}');
    debugPrint('📱 Payload: ${response.payload}');
    debugPrint('======================================================');
    stopOrderRingtone();
  }

  /// Request notification permission
  Future<bool> requestPermission() async {
    try {
      // Check current permission status
      final currentStatus = await Permission.notification.status;
      debugPrint('🔔 Current notification permission status: $currentStatus');

      if (currentStatus.isGranted) {
        debugPrint('✅ Notification permission already granted');
        return true;
      }

      // For Android 13+, request permission
      if (Platform.isAndroid) {
        final status = await Permission.notification.request();
        debugPrint('🔔 Permission request result: $status');

        if (status.isGranted) {
          debugPrint('✅ Notification permission granted');
          return true;
        } else if (status.isPermanentlyDenied) {
          debugPrint('❌ Notification permission permanently denied');
          debugPrint('⚠️ User needs to enable notifications in app settings');
        } else {
          debugPrint('❌ Notification permission denied');
        }
        return status.isGranted;
      }

      // For iOS, permissions are handled by Firebase
      return currentStatus.isGranted;
    } catch (e) {
      debugPrint('❌ Error requesting notification permission: $e');
      return false;
    }
  }

  /// Request permission to use full-screen intent notifications (Android 14+).
  /// Required for order alerts to auto-launch the app from the background,
  /// lock screen, or terminated state. On older Android versions this
  /// permission is granted automatically.
  Future<void> requestFullScreenIntentPermission() async {
    if (!Platform.isAndroid) return;
    try {
      final androidImplementation =
          _notificationsPlugin.resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();
      final granted =
          await androidImplementation?.requestFullScreenIntentPermission();
      debugPrint('🔔 Full-screen intent permission granted: $granted');
    } catch (e) {
      debugPrint('❌ Error requesting full-screen intent permission: $e');
    }
  }

  /// Show notification in system tray
  Future<void> showNotification({
    required String title,
    required String body,
    String? payload,
    String? imageUrl,
    String? notificationId,
    bool isOrderAlert = false,
  }) async {
    debugPrint('🔔 showNotification called - Title: "$title", Body: "$body"');

    if (!_isInitialized) {
      debugPrint('⚠️ Service not initialized, initializing now...');
      await initialize();
    }

    // Check permission
    final hasPermission = await Permission.notification.isGranted;
    debugPrint('🔔 Permission status: $hasPermission');

    if (!hasPermission) {
      debugPrint('❌ Notification permission not granted');
      debugPrint('⚠️ Requesting notification permission...');
      final granted = await requestPermission();
      if (!granted) {
        debugPrint('❌ Cannot show notification - permission denied');
        debugPrint('⚠️ Please enable notifications in Android Settings');
        return;
      }
    }

    // Generate notification ID - use provided ID or create one based on content
    // This ensures duplicate notifications with same content use same ID and replace each other
    final int localNotificationId;
    if (notificationId != null && notificationId.isNotEmpty) {
      // Use hash of the notification ID for consistent integer ID
      localNotificationId = notificationId.hashCode.abs() % 2147483647;
    } else {
      // Fallback: create ID based on title and body to prevent duplicates of same content
      final contentId = '${title}_$body';
      localNotificationId = contentId.hashCode.abs() % 2147483647;
    }

    // Android notification details
    final AndroidNotificationDetails androidDetails =
        AndroidNotificationDetails(
      isOrderAlert
          ? AppConfig.orderNotificationChannelId
          : AppConfig.notificationChannelId, // Must match channel ID
      isOrderAlert
          ? AppConfig.orderNotificationChannelName
          : AppConfig.notificationChannelName, // Must match channel name
      channelDescription: isOrderAlert
          ? AppConfig.orderNotificationChannelDescription
          : AppConfig.notificationChannelDescription,
      importance: Importance.max,
      priority: Priority.max,
      playSound: true,
      sound: isOrderAlert
          ? RawResourceAndroidNotificationSound(
              AppConfig.orderRingtoneRawResource)
          : null,
      audioAttributesUsage: isOrderAlert
          ? AudioAttributesUsage.alarm
          : AudioAttributesUsage.notification,
      enableVibration: true,
      icon: AppConfig.notificationIcon,
      showWhen: true,
      styleInformation: const BigTextStyleInformation(''),
      color: AppConfig.notificationColor,
      // Order alerts use a full-screen intent so the app auto-launches even
      // from the background, lock screen, or terminated state. Once the app
      // opens, didChangeAppLifecycleState(resumed) stops the ringtone
      // immediately (see webview_screen.dart).
      fullScreenIntent: isOrderAlert,
      visibility: isOrderAlert ? NotificationVisibility.public : null,
    );

    // iOS notification details
    const DarwinNotificationDetails iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );

    // Combined notification details
    final NotificationDetails notificationDetails = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    // Show the notification
    try {
      await _notificationsPlugin.show(
        localNotificationId,
        title,
        body,
        notificationDetails,
        payload: payload,
      );
      debugPrint(
          '✅ Notification displayed successfully - ID: $localNotificationId');
    } catch (e, stackTrace) {
      debugPrint('❌ Error showing notification: $e');
      debugPrint('❌ Stack trace: $stackTrace');
      rethrow;
    }
  }
}
