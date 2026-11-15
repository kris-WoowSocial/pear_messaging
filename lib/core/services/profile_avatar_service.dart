import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:get/get.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../constants/app_colors.dart';
import 'api_service.dart';
import 'local_storage_service.dart';
import 'user_profile_cache.dart';

/// Owns the current user's profile-photo lifecycle: pick → 1:1 crop →
/// compress → upload → live cache update, plus removal and full-screen view.
///
/// The homepage header avatar is the only entry point; this service exposes
/// the bottom sheet it presents.
class ProfileAvatarService extends GetxService {
  final ImagePicker _picker = ImagePicker();
  final RxBool isUploading = false.obs;

  LocalStorageService get _storage => Get.find<LocalStorageService>();
  ApiService get _api => Get.find<ApiService>();
  UserProfileCache get _cache => Get.find<UserProfileCache>();

  Future<ProfileAvatarService> init() async => this;

  /// Bottom sheet presented from the homepage avatar.
  void showAvatarOptions() {
    final hasAvatar = _cache.myAvatarUrl.value.isNotEmpty;
    Get.bottomSheet(
      SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose from Gallery'),
              onTap: () {
                Get.back();
                _pickAndUpload(ImageSource.gallery);
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Take Photo'),
              onTap: () {
                Get.back();
                _pickAndUpload(ImageSource.camera);
              },
            ),
            if (hasAvatar)
              ListTile(
                leading: const Icon(Icons.visibility_outlined),
                title: const Text('View Photo'),
                onTap: () {
                  Get.back();
                  viewPhoto();
                },
              ),
            if (hasAvatar)
              ListTile(
                leading: const Icon(Icons.delete_outline, color: Colors.red),
                title: const Text('Remove Photo',
                    style: TextStyle(color: Colors.red)),
                onTap: () {
                  Get.back();
                  removePhoto();
                },
              ),
          ],
        ),
      ),
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
    );
  }

  /// Full-screen viewer for the current avatar.
  void viewPhoto() {
    final url = _cache.myAvatarUrl.value;
    if (url.isEmpty) return;
    Get.dialog(
      Dialog(
        backgroundColor: Colors.black,
        insetPadding: EdgeInsets.zero,
        child: GestureDetector(
          onTap: Get.back,
          child: InteractiveViewer(
            child: Center(
              child: Image.network(url, fit: BoxFit.contain),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _pickAndUpload(ImageSource source) async {
    final deviceId = _storage.deviceId;
    if (deviceId == null || isUploading.value) return;

    try {
      final picked = await _picker.pickImage(
        source: source,
        maxWidth: 2048,
        maxHeight: 2048,
        imageQuality: 90,
      );
      if (picked == null) return; // cancelled

      final cropped = await ImageCropper().cropImage(
        sourcePath: picked.path,
        aspectRatio: const CropAspectRatio(ratioX: 1, ratioY: 1),
        compressFormat: ImageCompressFormat.jpg,
        uiSettings: [
          AndroidUiSettings(
            toolbarTitle: 'Crop Profile Photo',
            lockAspectRatio: true,
            hideBottomControls: false,
          ),
          IOSUiSettings(
            title: 'Crop Profile Photo',
            aspectRatioLockEnabled: true,
            resetAspectRatioEnabled: false,
          ),
        ],
      );
      if (cropped == null) return; // cancelled

      // Compress to ~640px JPEG before upload (server re-encodes to exact
      // 640x640 when sharp is available).
      final tmpDir = await getTemporaryDirectory();
      final target =
          '${tmpDir.path}/avatar_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final compressed = await FlutterImageCompress.compressAndGetFile(
        cropped.path,
        target,
        minWidth: 640,
        minHeight: 640,
        quality: 85,
        format: CompressFormat.jpeg,
      );
      if (compressed == null) {
        throw Exception('Image compression failed');
      }

      final bytes = await File(compressed.path).readAsBytes();
      if (bytes.length > 5 * 1024 * 1024) {
        throw Exception('Image exceeds 5MB limit');
      }

      isUploading.value = true;
      final res = await _api.uploadAvatar(deviceId, base64Encode(bytes));
      final url = res['avatarUrl']?.toString() ?? '';
      final updatedAt = res['avatarUpdatedAt'] is int
          ? res['avatarUpdatedAt'] as int
          : int.tryParse(res['avatarUpdatedAt']?.toString() ?? '');

      await _cache.setAvatar(deviceId, url, updatedAt: updatedAt);
      Get.snackbar('Profile Photo', 'Profile photo updated',
          snackPosition: SnackPosition.BOTTOM,
          duration: const Duration(seconds: 2));

      // Best-effort temp cleanup
      File(compressed.path).delete().ignore();
      if (cropped.path != picked.path) File(cropped.path).delete().ignore();
    } catch (e) {
      debugPrint('❌ Avatar upload failed: $e');
      Get.snackbar('Profile Photo', 'Could not update photo: $e',
          snackPosition: SnackPosition.BOTTOM,
          duration: const Duration(seconds: 3));
    } finally {
      isUploading.value = false;
    }
  }

  Future<void> removePhoto() async {
    final deviceId = _storage.deviceId;
    if (deviceId == null || isUploading.value) return;

    try {
      isUploading.value = true;
      await _api.removeAvatar(deviceId);
      await _cache.setAvatar(deviceId, null);
    } catch (e) {
      debugPrint('❌ Avatar removal failed: $e');
      Get.snackbar('Profile Photo', 'Could not remove photo: $e',
          snackPosition: SnackPosition.BOTTOM,
          duration: const Duration(seconds: 3));
    } finally {
      isUploading.value = false;
    }
  }
}
