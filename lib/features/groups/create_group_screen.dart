import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../../core/constants/app_colors.dart';
import '../../core/constants/app_sizes.dart';
import '../../core/utils/string_utils.dart';
import '../chat_list/chat_list_controller.dart';

class CreateGroupScreen extends StatefulWidget {
  const CreateGroupScreen({super.key});

  @override
  State<CreateGroupScreen> createState() => _CreateGroupScreenState();
}

class _CreateGroupScreenState extends State<CreateGroupScreen> {
  final ChatListController _chatListController = Get.find();
  final TextEditingController _nameController = TextEditingController();
  final Set<String> _selectedDeviceIds = <String>{};
  final RxBool _isCreating = false.obs;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _createGroup() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      Get.snackbar('Error', 'Please enter a group name');
      return;
    }
    if (_selectedDeviceIds.isEmpty) {
      Get.snackbar('Error', 'Please select at least one member');
      return;
    }

    _isCreating.value = true;
    try {
      await _chatListController.createGroup(
        name: name,
        memberDeviceIds: _selectedDeviceIds.toList(),
      );
    } finally {
      _isCreating.value = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final contacts = _chatListController.chats
        .where((chat) => !chat.isGroup)
        .toList()
      ..sort((a, b) =>
          a.userName.toLowerCase().compareTo(b.userName.toLowerCase()));

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        title: const Text(
          'New Group',
          style: TextStyle(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.bold,
          ),
        ),
        iconTheme: const IconThemeData(color: AppColors.textPrimary),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Group name input
          Container(
            color: AppColors.surface,
            padding: const EdgeInsets.all(AppSizes.paddingM),
            child: Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: AppColors.senderBubble,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.camera_alt,
                    color: AppColors.textPrimary,
                    size: 24,
                  ),
                ),
                const SizedBox(width: AppSizes.paddingM),
                Expanded(
                  child: TextField(
                    controller: _nameController,
                    decoration: const InputDecoration(
                      hintText: 'Group name',
                      border: UnderlineInputBorder(),
                      focusedBorder: UnderlineInputBorder(
                        borderSide: BorderSide(color: AppColors.textPrimary),
                      ),
                    ),
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: AppSizes.fontL,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),

          // Members header
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSizes.paddingM,
              vertical: AppSizes.paddingS,
            ),
            child: Row(
              children: [
                const Text(
                  'Select members',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: AppSizes.fontM,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                Text(
                  '${_selectedDeviceIds.length} selected',
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: AppSizes.fontS,
                  ),
                ),
              ],
            ),
          ),

          // Contacts list
          Expanded(
            child: contacts.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(AppSizes.paddingM),
                      child: Text(
                        'No contacts available. Start a 1-on-1 chat first.',
                        style: TextStyle(color: AppColors.textSecondary),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                : ListView.builder(
                    itemCount: contacts.length,
                    itemBuilder: (context, index) {
                      final chat = contacts[index];
                      final isSelected = _selectedDeviceIds.contains(chat.id);
                      return ListTile(
                        leading: Container(
                          width: 40,
                          height: 40,
                          decoration: const BoxDecoration(
                            color: AppColors.senderBubble,
                            shape: BoxShape.circle,
                          ),
                          child: Center(
                            child: Text(
                              chat.userName.isNotEmpty
                                  ? chat.userName[0].toUpperCase()
                                  : StringUtils.generateFriendlyName(chat.id)[0]
                                      .toUpperCase(),
                              style: const TextStyle(
                                color: AppColors.textPrimary,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                        title: Text(
                          StringUtils.formatDeviceIdWithName(
                              chat.id, chat.userName),
                          style: const TextStyle(
                            color: AppColors.textPrimary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        trailing: Checkbox(
                          value: isSelected,
                          onChanged: (_) => _toggleSelection(chat.id),
                          activeColor: AppColors.primary,
                        ),
                        onTap: () => _toggleSelection(chat.id),
                      );
                    },
                  ),
          ),

          // Create button
          Container(
            color: AppColors.surface,
            padding: const EdgeInsets.all(AppSizes.paddingM),
            child: SafeArea(
              child: Obx(
                () => SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppSizes.radiusM),
                      ),
                    ),
                    onPressed: _isCreating.value ? null : _createGroup,
                    child: _isCreating.value
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Text(
                            'Create Group',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: AppSizes.fontL,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _toggleSelection(String deviceId) {
    setState(() {
      if (_selectedDeviceIds.contains(deviceId)) {
        _selectedDeviceIds.remove(deviceId);
      } else {
        _selectedDeviceIds.add(deviceId);
      }
    });
  }
}
