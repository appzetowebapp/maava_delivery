import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:external_app_launcher/external_app_launcher.dart';
import 'package:webview_master_app/config/app_config.dart';
import 'package:webview_master_app/utils/ringtone_player.dart';

class OverlayBubble extends StatefulWidget {
  const OverlayBubble({super.key});

  @override
  State<OverlayBubble> createState() => _OverlayBubbleState();
}

class _OverlayBubbleState extends State<OverlayBubble> {
  static const platform = MethodChannel('com.maava.delivery/geolocation');

  bool _hasIncomingOrder = false;
  String? _orderId;
  String? _orderTitle;
  String? _orderBody;

  // True while the main app is in the foreground. Used to suppress ringtone
  // playback if a NEW_ORDER message arrives after the app has already opened
  // (race condition: CLEAR_ORDER can arrive before NEW_ORDER).
  bool _appInForeground = false;

  final RingtonePlayer _ringtonePlayer = RingtonePlayer();

  @override
  void initState() {
    super.initState();
    _listenToMessages();
  }

  @override
  void dispose() {
    _ringtonePlayer.dispose();
    super.dispose();
  }

  void _listenToMessages() {
    FlutterOverlayWindow.overlayListener.listen((data) {
      debugPrint('📩 Overlay received data: $data');
      try {
        if (data is String && data.startsWith('{')) {
          final Map<String, dynamic> jsonData = jsonDecode(data);
          if (jsonData['type'] == 'NEW_ORDER') {
            if (_appInForeground) {
              // The main app is already open — do not start the ringtone.
              // This handles the race where CLEAR_ORDER arrived before this
              // NEW_ORDER message was processed by the overlay.
              debugPrint('🔕 Overlay: NEW_ORDER ignored - app is in foreground');
              return;
            }
            setState(() {
              _hasIncomingOrder = true;
              _orderId = jsonData['orderId']?.toString();
              _orderTitle = jsonData['title']?.toString() ?? 'New Order';
              _orderBody = jsonData['body']?.toString() ??
                  'You have a new delivery order';
            });
            _ringtonePlayer.play();
          } else if (jsonData['type'] == 'CLEAR_ORDER') {
            // Mark app as open so any late NEW_ORDER message is ignored.
            _appInForeground = true;
            setState(() {
              _hasIncomingOrder = false;
            });
            _ringtonePlayer.stop();
          } else if (jsonData['type'] == 'APP_PAUSED') {
            // App went to background — allow the next order to ring.
            _appInForeground = false;
            debugPrint('📱 Overlay: APP_PAUSED received, ready for next order');
          }
        }
      } catch (e) {
        debugPrint('❌ Error parsing overlay data: $e');
      }
    });
  }

  Future<void> _openApp() async {
    await _ringtonePlayer.stop();
    try {
      debugPrint('🔵 Launching app directly...');
      await LaunchApp.openApp(
        androidPackageName: 'com.maava.delivery',
        openStore: false,
      );
      await FlutterOverlayWindow.shareData("OPEN_APP");
    } catch (e) {
      debugPrint('❌ Error launching app: $e');
      await FlutterOverlayWindow.shareData("OPEN_APP");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Center(
        child: _hasIncomingOrder ? _buildCompactBubble() : _buildCompactBubble(),
      ),
    );
  }

  Widget _buildCompactBubble() {
    return GestureDetector(
      onTap: _openApp,
      child: Container(
        width: 70,
        height: 70,
        decoration: BoxDecoration(
         // color: Colors.white,
          shape: BoxShape.circle,
        
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: 65,
              height: 65,
              decoration: BoxDecoration(
                color: AppConfig.primaryColor.withOpacity(0.1),
                shape: BoxShape.circle,
                image: const DecorationImage(
                  image: AssetImage('assets/images/logo_icon.png'),
                  fit: BoxFit.cover,
                ),
              ),
            ),
            Positioned(
              top: 5,
              right: 5,
              child: Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: Colors.green,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOrderPopup() {
    return Container(
      width: 150,
      height: 150,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.3),
            blurRadius: 15,
            spreadRadius: 3,
          ),
        ],
        border: Border.all(
          color: AppConfig.primaryColor,
          width: 2,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.shopping_bag, color: Colors.orange, size: 30),
          const SizedBox(height: 5),
          Text(
            _orderTitle ?? 'New Order',
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: Colors.black87,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          ),
          const Spacer(),
          Row(
            children: [
              Expanded(
                child: ElevatedButton(
                  onPressed: () async {
                    debugPrint('✅ Order accepted from overlay');
                    await FlutterOverlayWindow.shareData(jsonEncode({
                      'action': 'ACCEPT_ORDER',
                      'orderId': _orderId,
                    }));
                    setState(() {
                      _hasIncomingOrder = false;
                    });
                    await _openApp();
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                    foregroundColor: Colors.white,
                    padding: EdgeInsets.zero,
                    minimumSize: const Size(0, 35),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: const Text('Accept', style: TextStyle(fontSize: 12)),
                ),
              ),
              const SizedBox(width: 5),
              Expanded(
                child: ElevatedButton(
                  onPressed: () async {
                    debugPrint('❌ Order rejected from overlay');
                    await _ringtonePlayer.stop();
                    await FlutterOverlayWindow.shareData(jsonEncode({
                      'action': 'REJECT_ORDER',
                      'orderId': _orderId,
                    }));
                    setState(() {
                      _hasIncomingOrder = false;
                    });
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red,
                    foregroundColor: Colors.white,
                    padding: EdgeInsets.zero,
                    minimumSize: const Size(0, 35),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: const Text('Reject', style: TextStyle(fontSize: 12)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
