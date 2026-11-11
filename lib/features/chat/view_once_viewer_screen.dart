import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

/// Full-screen view-once photo viewer.
///
/// Android gets FLAG_SECURE (blocks screenshots/recents thumbnails) for the
/// lifetime of this screen. Popping the route signals the caller
/// (ChatController.openViewOncePhoto) to mark the message opened and purge
/// the decrypted bytes.
class ViewOnceViewerScreen extends StatefulWidget {
  final Uint8List imageBytes;

  const ViewOnceViewerScreen({super.key, required this.imageBytes});

  @override
  State<ViewOnceViewerScreen> createState() => _ViewOnceViewerScreenState();
}

class _ViewOnceViewerScreenState extends State<ViewOnceViewerScreen> {
  static const _securityChannel = MethodChannel('com.vant.chat/security');

  @override
  void initState() {
    super.initState();
    if (Platform.isAndroid) {
      _securityChannel
          .invokeMethod('setSecureFlag', {'enable': true})
          .catchError((_) {});
    }
  }

  @override
  void dispose() {
    if (Platform.isAndroid) {
      _securityChannel
          .invokeMethod('setSecureFlag', {'enable': false})
          .catchError((_) {});
    }
    // Zero the decrypted copy held by this screen.
    widget.imageBytes.fillRange(0, widget.imageBytes.length, 0);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          InteractiveViewer(
            minScale: 0.5,
            maxScale: 5.0,
            child: Center(
              child: Image.memory(
                widget.imageBytes,
                fit: BoxFit.contain,
                gaplessPlayback: true,
                errorBuilder: (context, error, stackTrace) => const Icon(
                  Icons.broken_image,
                  color: Colors.white54,
                  size: 64,
                ),
              ),
            ),
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.topLeft,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white, size: 28),
                onPressed: () => Get.back(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
