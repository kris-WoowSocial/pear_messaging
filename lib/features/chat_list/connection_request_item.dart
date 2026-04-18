import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../../core/constants/app_colors.dart';
import '../../core/services/connection_request_service.dart';
import '../../core/utils/string_utils.dart';
import '../../storage/models/connection_request_entity.dart';
import '../../storage/models/message_entity.dart';

class ConnectionRequestItem extends StatefulWidget {
  final ConnectionRequestEntity request;
  final VoidCallback? onTap;

  const ConnectionRequestItem({
    Key? key,
    required this.request,
    this.onTap,
  }) : super(key: key);

  @override
  State<ConnectionRequestItem> createState() => _ConnectionRequestItemState();
}

class _ConnectionRequestItemState extends State<ConnectionRequestItem> {
  @override
  void initState() {
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    // Always use @user_ format - no name fetching or display names
    final senderName =
        StringUtils.generateFriendlyName(widget.request.senderDeviceId);

    debugPrint(
        '🔍 DEBUG ConnectionRequestItem: Using @user_ format for ${widget.request.senderDeviceId} -> $senderName');

    // Format the message content for display
    String displayMessage = '';
    if (widget.request.messageContent != null &&
        widget.request.messageContent!.isNotEmpty) {
      if (widget.request.messageType == MessageType.image) {
        displayMessage = '📷 Photo';
      } else {
        displayMessage = widget.request.messageContent!;
        // Truncate long messages
        if (displayMessage.length > 50) {
          displayMessage = '${displayMessage.substring(0, 50)}...';
        }
      }
    } else {
      displayMessage = 'Wants to connect';
    }

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.blue.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.blue.shade200, width: 1),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        // Remove onTap to prevent navigation to chat screen
        // Users should only interact via Accept/Reject buttons
        leading: Container(
          width: 50,
          height: 50,
          decoration: BoxDecoration(
            color: Colors.blue.shade100,
            shape: BoxShape.circle,
          ),
          child: const Icon(
            Icons.person_add,
            color: AppColors.primary,
            size: 24,
          ),
        ),
        title: Row(
          children: [
            Expanded(
              child: Text(
                senderName,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 16,
                  color: Colors.black87,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.orange.shade100,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                'Connection Request',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: Colors.orange.shade800,
                ),
              ),
            ),
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 4),
            Text(
              displayMessage,
              style: const TextStyle(
                fontSize: 14,
                color: Colors.black54,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                // Accept button
                Expanded(
                  child: ElevatedButton(
                    onPressed: () => _acceptRequest(context),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      elevation: 1,
                    ),
                    child: const Text(
                      'Accept',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // Reject button
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => _rejectRequest(context),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.red,
                      side: const BorderSide(color: Colors.red),
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    child: const Text(
                      'Reject',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _acceptRequest(BuildContext context) async {
    try {
      final connectionRequestService = Get.find<ConnectionRequestService>();
      await connectionRequestService.acceptConnectionRequest(
          widget.request.id, widget.request.senderDeviceId);
    } catch (e) {
      debugPrint('Error accepting connection request: $e');
    }
  }

  void _rejectRequest(BuildContext context) {
    final connectionRequestService = Get.find<ConnectionRequestService>();
    connectionRequestService.blockConnectionRequest(
        widget.request.id, widget.request.senderDeviceId);
  }
}
