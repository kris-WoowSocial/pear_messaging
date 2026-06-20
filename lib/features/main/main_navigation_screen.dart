import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../../core/constants/app_colors.dart';
import '../../core/services/call_history_service.dart';
import '../../core/services/branch_service.dart';
import '../chat_list/chat_list_screen.dart';
import '../call_history/call_history_screen.dart';
import '../call_history/call_history_controller.dart';

/// Main Navigation Screen - 3-tab bottom navigation
/// Tabs: Invite (share sheet) | Chats | Calls
class MainNavigationScreen extends StatefulWidget {
  const MainNavigationScreen({super.key});

  @override
  State<MainNavigationScreen> createState() => _MainNavigationScreenState();
}

class _MainNavigationScreenState extends State<MainNavigationScreen> {
  int _currentIndex = 1; // Start on Chats tab (center)

  // Cached pages to preserve state (only 2 actual screens)
  late final List<Widget> _pages;

  @override
  void initState() {
    super.initState();
    _pages = [
      ChatListScreen(), // Index 1 - Chats (default)
      const CallHistoryScreen(), // Index 2 - Calls
    ];

    // Initialize CallHistoryController for the calls tab
    Get.put(CallHistoryController());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex == 0
            ? 0
            : _currentIndex - 1, // Adjust for Invite tab being action-only
        children: _pages,
      ),
      bottomNavigationBar: Obx(() {
        // Get missed call count for badge
        final missedCalls = Get.find<CallHistoryService>().getMissedCallCount();

        return BottomNavigationBar(
          currentIndex: _currentIndex,
          onTap: (index) {
            if (index == 0) {
              // Invite tab - open share sheet directly
              _showShareSheet();
            } else {
              // Chats or Calls - switch to that screen
              setState(() {
                _currentIndex = index;
              });

              // Refresh call history when switching to calls tab
              if (index == 2) {
                try {
                  Get.find<CallHistoryController>().refresh();
                } catch (e) {
                  debugPrint('⚠️ Could not refresh call history: $e');
                }
              }
            }
          },
          backgroundColor: AppColors.surface,
          selectedItemColor: AppColors.primary,
          unselectedItemColor: Colors.grey,
          type: BottomNavigationBarType.fixed,
          selectedLabelStyle: const TextStyle(fontWeight: FontWeight.w600),
          items: [
            // Invite tab (opens share sheet)
            const BottomNavigationBarItem(
              icon: Icon(Icons.person_add_outlined),
              activeIcon: Icon(Icons.person_add),
              label: 'Invite',
            ),

            // Chats tab
            const BottomNavigationBarItem(
              icon: Icon(Icons.chat_bubble_outline),
              activeIcon: Icon(Icons.chat_bubble),
              label: 'Chats',
            ),

            // Calls tab with badge
            BottomNavigationBarItem(
              icon: missedCalls > 0
                  ? Stack(
                      children: [
                        const Icon(Icons.phone_outlined),
                        Positioned(
                          right: 0,
                          top: 0,
                          child: Container(
                            padding: const EdgeInsets.all(2),
                            decoration: const BoxDecoration(
                              color: Colors.red,
                              shape: BoxShape.circle,
                            ),
                            constraints: const BoxConstraints(
                              minWidth: 14,
                              minHeight: 14,
                            ),
                            child: Text(
                              missedCalls > 99 ? '99+' : '$missedCalls',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 8,
                                fontWeight: FontWeight.bold,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                      ],
                    )
                  : const Icon(Icons.phone_outlined),
              activeIcon: const Icon(Icons.phone),
              label: 'Calls',
            ),
          ],
        );
      }),
    );
  }

  /// Show share sheet for inviting friends
  /// Uses Branch SDK share (same as old FAB behavior)
  void _showShareSheet() async {
    try {
      // Get or initialize Branch service
      BranchService branchService;
      try {
        branchService = Get.find<BranchService>();
      } catch (e) {
        // Branch service not initialized, create one
        branchService = BranchService();
        Get.put(branchService);
        await branchService.init();
      }

      // Share via Branch (generates link + opens native share sheet)
      await branchService.shareApp();
    } catch (e) {
      debugPrint('❌ Error sharing app: $e');
      Get.snackbar(
        'Share Failed',
        'Unable to share the app. Please try again.',
        snackPosition: SnackPosition.BOTTOM,
      );
    }
  }
}
