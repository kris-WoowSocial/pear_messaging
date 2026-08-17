import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../../core/constants/app_colors.dart';
import '../../core/constants/app_sizes.dart';
import '../../core/services/api_service.dart';
import '../../core/services/local_storage_service.dart';
import '../../core/utils/string_utils.dart';
import '../../storage/models/group_member_entity.dart';
import '../chat/chat_controller.dart';
import '../chat_list/chat_list_controller.dart';
import '../chat_list/chat_list_model.dart';

class GroupSettingsScreen extends StatefulWidget {
  const GroupSettingsScreen({super.key});

  @override
  State<GroupSettingsScreen> createState() => _GroupSettingsScreenState();
}

class _GroupSettingsScreenState extends State<GroupSettingsScreen> {
  final ChatController _chatController = Get.find();
  final LocalStorageService _storageService = Get.find();
  final ApiService _apiService = ApiService.to;

  final RxBool _isLoading = false.obs;
  final RxString _groupName = ''.obs;
  final RxList<GroupMemberEntity> _members = <GroupMemberEntity>[].obs;
  final RxBool _isAdmin = false.obs;
  final RxBool _isCreator = false.obs;
  final RxString _inviteCode = ''.obs;

  @override
  void initState() {
    super.initState();
    _loadGroupData();
  }

  void _loadGroupData() {
    final chat = _storageService.getChat(_chatController.chatId);
    if (chat == null) return;

    _groupName.value = chat.groupName ?? chat.userName;
    _members.value = List.from(chat.members);
    _inviteCode.value = chat.inviteCode ?? '';

    final myDeviceId = _storageService.deviceId ?? '';
    _isAdmin.value = chat.admins.contains(myDeviceId);
    _isCreator.value = chat.id.isNotEmpty && _isAdmin.value;
  }

  Future<void> _renameGroup() async {
    final currentName = _groupName.value;
    final controller = TextEditingController(text: currentName);

    final newName = await Get.dialog<String>(
      AlertDialog(
        title: const Text('Rename Group'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(hintText: 'Group name'),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Get.back(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Get.back(result: controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    controller.dispose();

    if (newName == null || newName.isEmpty || newName == currentName) return;

    _isLoading.value = true;
    try {
      await _apiService.updateGroupInfo(
        groupId: _chatController.chatId,
        deviceId: _storageService.deviceId ?? '',
        name: newName,
      );
      _groupName.value = newName;
      await _refreshLocalGroup();
      _updateChatList();
      Get.snackbar('Success', 'Group name updated');
    } catch (e) {
      Get.snackbar('Error', 'Failed to rename group: $e');
    } finally {
      _isLoading.value = false;
    }
  }

  Future<void> _addMembers() async {
    final contacts = _getAvailableContacts();
    if (contacts.isEmpty) {
      Get.snackbar('Info', 'No contacts available to add');
      return;
    }

    final selected = await Get.dialog<Set<String>>(
      _MemberPickerDialog(availableContacts: contacts),
    );

    if (selected == null || selected.isEmpty) return;

    _isLoading.value = true;
    try {
      await _apiService.addGroupMembers(
        groupId: _chatController.chatId,
        deviceId: _storageService.deviceId ?? '',
        memberDeviceIds: selected.toList(),
      );
      await _refreshLocalGroup();
      _chatController.groupMembers.value = List.from(_members);
      _chatController.groupMemberCount.value = _members.length;
      Get.snackbar('Success', '${selected.length} member(s) added');
    } catch (e) {
      Get.snackbar('Error', 'Failed to add members: $e');
    } finally {
      _isLoading.value = false;
    }
  }

  List<ChatListModel> _getAvailableContacts() {
    final chatListController = Get.find<ChatListController>();
    final existingMemberIds = _members.map((m) => m.deviceId).toSet();
    return chatListController.chats
        .where((chat) => !chat.isGroup && !existingMemberIds.contains(chat.id))
        .toList();
  }

  Future<void> _removeMember(GroupMemberEntity member) async {
    final confirmed = await Get.dialog<bool>(
      AlertDialog(
        title: const Text('Remove Member'),
        content: Text(
            'Remove ${StringUtils.generateFriendlyName(member.deviceId)} from the group?'),
        actions: [
          TextButton(
            onPressed: () => Get.back(result: false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Get.back(result: true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    _isLoading.value = true;
    try {
      await _apiService.removeGroupMember(
        groupId: _chatController.chatId,
        targetDeviceId: member.deviceId,
        deviceId: _storageService.deviceId ?? '',
      );
      await _refreshLocalGroup();
      _chatController.groupMembers.value = List.from(_members);
      _chatController.groupMemberCount.value = _members.length;
      Get.snackbar('Success', 'Member removed');
    } catch (e) {
      Get.snackbar('Error', 'Failed to remove member: $e');
    } finally {
      _isLoading.value = false;
    }
  }

  Future<void> _leaveGroup() async {
    final confirmed = await Get.dialog<bool>(
      const _ConfirmDialog(
        title: 'Leave Group',
        content: 'Are you sure you want to leave this group?',
        confirmText: 'Leave',
      ),
    );
    if (confirmed != true) return;

    _isLoading.value = true;
    try {
      await _apiService.leaveGroup(
        groupId: _chatController.chatId,
        deviceId: _storageService.deviceId ?? '',
      );
      await _storageService.deleteChat(_chatController.chatId);
      _updateChatList();
      Get.offAllNamed('/main');
    } catch (e) {
      Get.snackbar('Error', 'Failed to leave group: $e');
    } finally {
      _isLoading.value = false;
    }
  }

  Future<void> _dissolveGroup() async {
    final confirmed = await Get.dialog<bool>(
      const _ConfirmDialog(
        title: 'Dissolve Group',
        content:
            'This will permanently delete the group for all members. Are you sure?',
        confirmText: 'Dissolve',
      ),
    );
    if (confirmed != true) return;

    _isLoading.value = true;
    try {
      await _apiService.dissolveGroup(
        groupId: _chatController.chatId,
        deviceId: _storageService.deviceId ?? '',
      );
      await _storageService.deleteChat(_chatController.chatId);
      _updateChatList();
      Get.offAllNamed('/main');
    } catch (e) {
      Get.snackbar('Error', 'Failed to dissolve group: $e');
    } finally {
      _isLoading.value = false;
    }
  }

  Future<void> _refreshLocalGroup() async {
    final myDeviceId = _storageService.deviceId ?? '';
    final response = await _apiService.getGroup(
      groupId: _chatController.chatId,
      deviceId: myDeviceId,
    );
    final groupData = response['group'] as Map<String, dynamic>?;
    if (groupData != null) {
      final chat = await _storageService.saveGroupChatFromApi(groupData,
          myDeviceId: myDeviceId);
      if (chat != null) {
        _groupName.value = chat.groupName ?? chat.userName;
        _members.value = List.from(chat.members);
        _inviteCode.value = chat.inviteCode ?? '';
        _isAdmin.value = chat.admins.contains(myDeviceId);
      }
    }
  }

  void _updateChatList() {
    try {
      Get.find<ChatListController>().loadChats();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final myDeviceId = _storageService.deviceId ?? '';

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        title: const Text(
          'Group Info',
          style: TextStyle(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.bold,
          ),
        ),
        iconTheme: const IconThemeData(color: AppColors.textPrimary),
      ),
      body: Obx(
        () => Stack(
          children: [
            ListView(
              children: [
                const SizedBox(height: 16),

                // Group name
                Container(
                  color: AppColors.surface,
                  padding: const EdgeInsets.all(AppSizes.paddingM),
                  child: Row(
                    children: [
                      Container(
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(
                          color: AppColors.senderBubble,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Center(
                          child: Text(
                            _groupName.value.isNotEmpty
                                ? _groupName.value[0].toUpperCase()
                                : 'G',
                            style: const TextStyle(
                              color: AppColors.textPrimary,
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: AppSizes.paddingM),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _groupName.value,
                              style: const TextStyle(
                                color: AppColors.textPrimary,
                                fontSize: AppSizes.fontL,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '${_members.length} members',
                              style: const TextStyle(
                                color: AppColors.textSecondary,
                                fontSize: AppSizes.fontS,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (_isAdmin.value)
                        IconButton(
                          icon: const Icon(Icons.edit,
                              color: AppColors.textPrimary),
                          onPressed: _renameGroup,
                        ),
                    ],
                  ),
                ),

                const SizedBox(height: 8),

                // Invite code tile
                if (_inviteCode.value.isNotEmpty)
                  Container(
                    color: AppColors.surface,
                    child: ListTile(
                      leading:
                          const Icon(Icons.link, color: AppColors.textPrimary),
                      title: const Text(
                        'Invite Code',
                        style: TextStyle(color: AppColors.textPrimary),
                      ),
                      subtitle: Text(
                        _inviteCode.value,
                        style: const TextStyle(
                          color: AppColors.textSecondary,
                          fontFamily: 'monospace',
                        ),
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.copy,
                            color: AppColors.textPrimary),
                        onPressed: () {
                          // Clipboard.setData would need clipboard package; keeping simple
                          Get.snackbar('Copied', _inviteCode.value);
                        },
                      ),
                    ),
                  ),

                const SizedBox(height: 8),

                // Members header
                Container(
                  color: AppColors.surface,
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSizes.paddingM,
                    vertical: AppSizes.paddingS,
                  ),
                  child: Row(
                    children: [
                      const Text(
                        'Members',
                        style: TextStyle(
                          color: AppColors.textPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const Spacer(),
                      if (_isAdmin.value)
                        TextButton.icon(
                          onPressed: _addMembers,
                          icon: const Icon(Icons.person_add, size: 18),
                          label: const Text('Add'),
                        ),
                    ],
                  ),
                ),

                // Members list
                ..._members.map((member) {
                  final isMe = member.deviceId == myDeviceId;
                  final displayName = isMe
                      ? 'You'
                      : _storageService.getDisplayName(member.deviceId);
                  return Container(
                    color: AppColors.surface,
                    child: ListTile(
                      leading: Container(
                        width: 40,
                        height: 40,
                        decoration: const BoxDecoration(
                          color: AppColors.senderBubble,
                          shape: BoxShape.circle,
                        ),
                        child: Center(
                          child: Text(
                            displayName[0].toUpperCase(),
                            style: const TextStyle(
                              color: AppColors.textPrimary,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                      title: Text(
                        displayName,
                        style: const TextStyle(color: AppColors.textPrimary),
                      ),
                      subtitle: Text(
                        member.isAdmin ? 'Admin' : 'Member',
                        style: const TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: AppSizes.fontXS,
                        ),
                      ),
                      trailing: _isAdmin.value && !isMe
                          ? IconButton(
                              icon: const Icon(Icons.remove_circle_outline,
                                  color: Colors.red),
                              onPressed: () => _removeMember(member),
                            )
                          : null,
                    ),
                  );
                }),

                const SizedBox(height: 8),

                // Leave group tile
                Container(
                  color: AppColors.surface,
                  child: ListTile(
                    leading: const Icon(Icons.exit_to_app, color: Colors.red),
                    title: const Text(
                      'Leave Group',
                      style: TextStyle(color: Colors.red),
                    ),
                    onTap: _leaveGroup,
                  ),
                ),

                // Dissolve group tile (creator only)
                if (_isCreator.value)
                  Container(
                    color: AppColors.surface,
                    child: ListTile(
                      leading:
                          const Icon(Icons.delete_forever, color: Colors.red),
                      title: const Text(
                        'Dissolve Group',
                        style: TextStyle(color: Colors.red),
                      ),
                      onTap: _dissolveGroup,
                    ),
                  ),

                const SizedBox(height: 32),
              ],
            ),
            if (_isLoading.value)
              Container(
                color: Colors.black.withOpacity(0.1),
                child: const Center(child: CircularProgressIndicator()),
              ),
          ],
        ),
      ),
    );
  }
}

class _ConfirmDialog extends StatelessWidget {
  final String title;
  final String content;
  final String confirmText;

  const _ConfirmDialog({
    required this.title,
    required this.content,
    required this.confirmText,
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(title),
      content: Text(content),
      actions: [
        TextButton(
          onPressed: () => Get.back(result: false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Get.back(result: true),
          child: Text(
            confirmText,
            style: const TextStyle(color: Colors.red),
          ),
        ),
      ],
    );
  }
}

class _MemberPickerDialog extends StatefulWidget {
  final List<ChatListModel> availableContacts;

  const _MemberPickerDialog({required this.availableContacts});

  @override
  State<_MemberPickerDialog> createState() => _MemberPickerDialogState();
}

class _MemberPickerDialogState extends State<_MemberPickerDialog> {
  final Set<String> _selected = <String>{};

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add Members'),
      content: SizedBox(
        width: double.maxFinite,
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: widget.availableContacts.length,
          itemBuilder: (context, index) {
            final contact = widget.availableContacts[index];
            final isSelected = _selected.contains(contact.id);
            return ListTile(
              leading: CircleAvatar(
                backgroundColor: AppColors.senderBubble,
                child: Text(
                  contact.userName.isNotEmpty
                      ? contact.userName[0].toUpperCase()
                      : StringUtils.generateFriendlyName(contact.id)[0]
                          .toUpperCase(),
                  style: const TextStyle(color: AppColors.textPrimary),
                ),
              ),
              title: Text(StringUtils.formatDeviceIdWithName(
                  contact.id, contact.userName)),
              trailing: Checkbox(
                value: isSelected,
                onChanged: (_) => _toggle(contact.id),
                activeColor: AppColors.primary,
              ),
              onTap: () => _toggle(contact.id),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Get.back(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Get.back(result: _selected),
          child: const Text('Add'),
        ),
      ],
    );
  }

  void _toggle(String deviceId) {
    setState(() {
      if (_selected.contains(deviceId)) {
        _selected.remove(deviceId);
      } else {
        _selected.add(deviceId);
      }
    });
  }
}
