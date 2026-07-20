import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart'
    hide NotificationVisibility;
import 'package:flutter_overlay_window/flutter_overlay_window.dart' as overlay
    show NotificationVisibility;
import 'package:external_app_launcher/external_app_launcher.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_master_app/config/app_config.dart';
import 'package:webview_master_app/utils/ringtone_player.dart';

/// Background message handler for Firebase Cloud Messaging
/// This must be a top-level function
/// Handles notifications when app is in background or terminated state
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  final data = message.data;

  debugPrint('================ FCM RECEIVED (BACKGROUND/TERMINATED) ================');
  debugPrint('📦 Raw message.toMap(): ${message.toMap()}');
  debugPrint('📝 Title: ${message.notification?.title}');
  debugPrint('📝 Body: ${message.notification?.body}');
  debugPrint('📋 Data: $data');
  debugPrint('🆔 MessageId: ${message.messageId}');
  debugPrint('🆔 OrderId: ${data['orderId'] ?? data['order_id'] ?? data['id']}');
  debugPrint('🏷️ Type: ${data['type']}');
  debugPrint('👤 UserId: ${data['userId'] ?? data['user_id']}');
  debugPrint('🚚 DeliveryPartnerId: ${data['deliveryPartnerId'] ?? data['delivery_partner_id'] ?? data['partnerId'] ?? data['riderId']}');
  debugPrint('📱 App State: background/terminated');
  debugPrint('========================================================================');

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
  debugPrint('🔔 Sound/ringtone trigger status: ${isOrder ? "WILL TRIGGER" : "SKIPPED (not an order message)"}');

  if (isOrder) {
    // Persist the order so the main isolate can show the in-app popup when
    // the app opens, regardless of whether it was in the background or was
    // completely terminated at the time the FCM message arrived.
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('pending_order', jsonEncode({
        'orderId': data['orderId'] ?? data['order_id'] ?? data['id'] ?? '',
        'title': message.notification?.title ?? data['title']?.toString() ?? 'New Order',
        'body': message.notification?.body ?? data['body']?.toString() ?? 'You have a new delivery order',
      }));
      debugPrint('💾 Pending order saved to SharedPreferences for in-app popup');
    } catch (e) {
      debugPrint('⚠️ Could not save pending order to SharedPreferences: $e');
    }

    bool overlayReady = false;
    try {
      // Make sure the overlay (foreground service) is running so it can
      // sustain the looping ringtone while the app is backgrounded/terminated.
      final overlayPermission = await FlutterOverlayWindow.isPermissionGranted();
      final overlayActive = await FlutterOverlayWindow.isActive();
      debugPrint('🪟 Overlay permission granted: $overlayPermission, overlay active: $overlayActive');

      if (overlayPermission) {
        if (!overlayActive) {
          debugPrint('🪟 Showing overlay window...');
          await FlutterOverlayWindow.showOverlay(
            enableDrag: true,
            overlayTitle: "Maava Restaurent Overlay",
            overlayContent: "Tap to open app",
            flag: OverlayFlag.defaultFlag,
            visibility: overlay.NotificationVisibility.visibilityPublic,
            alignment: OverlayAlignment.topLeft,
            startPosition: const OverlayPosition(20, 100),
            positionGravity: PositionGravity.none,
            height: 160,
            width: 160,
          );
          debugPrint('🪟 Overlay window shown');
        }
        overlayReady = true;
      } else {
        debugPrint('⚠️ Overlay permission NOT granted - "Display over other apps" must be enabled for ringtone to loop in background');
      }

      debugPrint('🔔 New order detected, notifying overlay (ringtone trigger via overlay)...');
      await FlutterOverlayWindow.shareData(jsonEncode({
        'type': 'NEW_ORDER',
        'orderId': data['orderId'] ?? data['id'],
        'title': message.notification?.title ?? 'New Order',
        'body': message.notification?.body ?? 'You have a new delivery order',
      }));
      debugPrint('🔔 Overlay shareData(NEW_ORDER) sent - overlay should start ringtone');

      // Give the overlay a moment to receive and start the ringtone before
      // the app opens (which sends CLEAR_ORDER). Without this delay the
      // app can open so fast that CLEAR_ORDER reaches the overlay before
      // NEW_ORDER, causing the ringtone to keep playing after launch.
      await Future.delayed(const Duration(milliseconds: 600));

      // Auto-open application
      debugPrint('🚀 AUTO-OPEN: calling LaunchApp.openApp() for com.maava.delivery...');
      await LaunchApp.openApp(
        androidPackageName: 'com.maava.delivery',
        openStore: false,
      );
      debugPrint('🚀 AUTO-OPEN: LaunchApp.openApp() call completed');
    } catch (e) {
      debugPrint('❌ Failed to notify overlay or auto-open app: $e');
    }

    // If the overlay isn't available to sustain a continuous ring, fall
    // back to playing the ringtone directly in this isolate as a
    // best-effort single attempt.
    if (!overlayReady) {
      debugPrint('🔔 RINGTONE TRIGGER: overlay unavailable, falling back to direct play in background isolate');
      unawaited(RingtonePlayer().play());
    }
  }

  // Initialize notification plugin for background messages
  final FlutterLocalNotificationsPlugin notificationsPlugin =
      FlutterLocalNotificationsPlugin();

  // Use AppConfig for consistency
  const AndroidInitializationSettings androidSettings =
      AndroidInitializationSettings(AppConfig.notificationIcon);

  const DarwinInitializationSettings iosSettings = DarwinInitializationSettings(
    requestAlertPermission: true,
    requestBadgePermission: true,
    requestSoundPermission: true,
  );

  const InitializationSettings initSettings = InitializationSettings(
    android: androidSettings,
    iOS: iosSettings,
  );

  await notificationsPlugin.initialize(initSettings);

  // Create notification channel for Android using AppConfig
  final AndroidNotificationChannel channel = AndroidNotificationChannel(
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

  // Dedicated high-priority channel for new order alerts, with a custom
  // ringtone and alarm audio attributes so it is audible on the lock
  // screen and over silent/vibrate modes.
  final AndroidNotificationChannel orderChannel = AndroidNotificationChannel(
    AppConfig.orderNotificationChannelId,
    AppConfig.orderNotificationChannelName,
    description: AppConfig.orderNotificationChannelDescription,
    importance: Importance.max,
    playSound: true,
    sound:
        RawResourceAndroidNotificationSound(AppConfig.orderRingtoneRawResource),
    audioAttributesUsage: AudioAttributesUsage.alarm,
    enableVibration: true,
    vibrationPattern: Int64List.fromList(
        <int>[0, 1000, 500, 1000, 500, 1000, 500, 1000]),
    showBadge: true,
    enableLights: true,
    ledColor: AppConfig.notificationColor,
  );

  // The backend sends `notification.android.channelId: "maava_channel"` for
  // order pushes. Create that exact channel with the same alarm-style
  // settings so the system's auto-displayed notification (for messages that
  // include a `notification` payload, which we don't re-show ourselves)
  // still rings loudly and shows on the lock screen.
  final AndroidNotificationChannel fcmOrderChannel = AndroidNotificationChannel(
    AppConfig.fcmOrderChannelId,
    AppConfig.orderNotificationChannelName,
    description: AppConfig.orderNotificationChannelDescription,
    importance: Importance.max,
    playSound: true,
    sound:
        RawResourceAndroidNotificationSound(AppConfig.orderRingtoneRawResource),
    audioAttributesUsage: AudioAttributesUsage.alarm,
    enableVibration: true,
    vibrationPattern: Int64List.fromList(
        <int>[0, 1000, 500, 1000, 500, 1000, 500, 1000]),
    showBadge: true,
    enableLights: true,
    ledColor: AppConfig.notificationColor,
  );

  final androidPlugin = notificationsPlugin
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
  // Silent channel used exclusively to fire the full-screen intent PendingIntent
  // that opens the app from a locked screen.  Sound is disabled because the
  // system's auto-displayed notification (for notification-payload messages) and
  // the overlay AudioPlayer already handle audio — we only need the FSI trigger.
  final AndroidNotificationChannel orderFsiSilentChannel = AndroidNotificationChannel(
    'maava_order_fsi_silent',
    'Order Alerts (Lock Screen)',
    description: 'Opens the app from a locked screen via full-screen intent; audio handled by overlay.',
    importance: Importance.max,
    playSound: false,
    enableVibration: false,
    showBadge: false,
  );

  await androidPlugin?.createNotificationChannel(channel);
  await androidPlugin?.createNotificationChannel(orderChannel);
  await androidPlugin?.createNotificationChannel(fcmOrderChannel);
  await androidPlugin?.createNotificationChannel(orderFsiSilentChannel);

  RemoteNotification? notification = message.notification;

  // Create unique ID for this notification
  final String notificationId = message.messageId ??
      '${message.sentTime?.millisecondsSinceEpoch ?? DateTime.now().millisecondsSinceEpoch}';

  debugPrint('📨 Background notification ID: $notificationId');

  // Messages that include a `notification` payload are auto-displayed by the
  // Android FCM SDK. For non-order messages we skip our local notification to
  // avoid duplicates. For ORDER messages we ALSO post a silent full-screen
  // intent notification on the dedicated FSI channel: the system notification
  // handles audio while the FSI fires the PendingIntent that opens the app
  // from the locked screen. LaunchApp.openApp() alone cannot pierce the
  // Android 14+ keyguard, but a system-driven PendingIntent can.
  if (notification != null && !isOrder) {
    debugPrint('🖼️ POPUP: skipped local show - system will auto-display notification payload via default channel: ${notification.title}');
  } else if (notification != null && isOrder) {
    // System auto-displays its notification (with audio). We add a separate
    // silent FSI notification whose sole job is to fire the PendingIntent that
    // brings MainActivity to the foreground over the lock screen.
    final int fsiId = (notificationId.hashCode.abs() % 2147483646) + 1;
    final String fsiTitle = notification.title ?? data['title']?.toString() ?? 'New Order';
    final String fsiBody  = notification.body  ?? data['body']?.toString()  ?? 'You have a new delivery order';
    final AndroidNotificationDetails fsiAndroidDetails = AndroidNotificationDetails(
      'maava_order_fsi_silent',
      'Order Alerts (Lock Screen)',
      channelDescription: 'Opens the app from a locked screen via full-screen intent; audio handled by overlay.',
      importance: Importance.max,
      priority: Priority.max,
      fullScreenIntent: true,
      playSound: false,
      enableVibration: false,
      autoCancel: true,
      icon: AppConfig.notificationIcon,
      visibility: NotificationVisibility.public,
    );
    await notificationsPlugin.show(
      fsiId,
      fsiTitle,
      fsiBody,
      NotificationDetails(android: fsiAndroidDetails),
      payload: data.toString(),
    );
    debugPrint('🚀 FSI notification posted for order (locked-screen launch): $fsiTitle (ID: $fsiId)');
  } else if (data.isNotEmpty) {
    // Handle data-only messages (messages without notification payload)
    debugPrint('📨 Data-only message received in background');
    debugPrint('🖼️ POPUP: will show local notification (channel=${isOrder ? AppConfig.orderNotificationChannelId : AppConfig.notificationChannelId}, fullScreenIntent=$isOrder)');
    final title = data['title']?.toString() ?? 'Notification';
    final body = data['body']?.toString() ?? data['message']?.toString() ?? '';

    // Android notification details using AppConfig
    final AndroidNotificationDetails androidDetails =
        AndroidNotificationDetails(
      isOrder
          ? AppConfig.orderNotificationChannelId
          : AppConfig.notificationChannelId,
      isOrder
          ? AppConfig.orderNotificationChannelName
          : AppConfig.notificationChannelName,
      channelDescription: isOrder
          ? AppConfig.orderNotificationChannelDescription
          : AppConfig.notificationChannelDescription,
      importance: isOrder ? Importance.max : Importance.high,
      priority: isOrder ? Priority.max : Priority.high,
      playSound: true,
      sound: isOrder
          ? RawResourceAndroidNotificationSound(
              AppConfig.orderRingtoneRawResource)
          : null,
      audioAttributesUsage: isOrder
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
      fullScreenIntent: isOrder,
      visibility: isOrder ? NotificationVisibility.public : null,
    );

    // iOS notification details
    const DarwinNotificationDetails iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );

    final NotificationDetails notificationDetails = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    // Generate notification ID from data
    final int localNotificationId = notificationId.hashCode.abs() % 2147483647;

    await notificationsPlugin.show(
      localNotificationId,
      title,
      body,
      notificationDetails,
      payload: data.toString(),
    );

    debugPrint('🖼️ POPUP: shown - $title (ID: $localNotificationId)');
    debugPrint(
        '✅ Background data-only notification shown: $title (ID: $localNotificationId)');
  } else {
    debugPrint('🖼️ POPUP: skipped - no notification payload and no data');
  }
}
