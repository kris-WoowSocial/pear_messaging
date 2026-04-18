import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../core/constants/app_colors.dart';
import '../../core/constants/app_sizes.dart';
import '../../core/services/encryption_service.dart';
import '../../core/services/image_cache_service.dart';
import '../../core/services/media_upload_service.dart';
import '../../core/services/url_preview_service.dart';
import '../../core/utils/time_utils.dart';
import '../../storage/models/message_entity.dart';
import 'chat_controller.dart';
import 'chat_message_model.dart';
import '../../core/widgets/report_bottom_sheet.dart';
import 'widgets/quoted_message_bubble.dart';

class ChatMessageBubble extends StatefulWidget {
  final ChatMessageModel message;

  const ChatMessageBubble({super.key, required this.message});

  @override
  State<ChatMessageBubble> createState() => _ChatMessageBubbleState();
}

class _ChatMessageBubbleState extends State<ChatMessageBubble> {
  final RxBool _isExpanded = false.obs;
  final RxBool _showExpandButton = false.obs;
  final Rx<UrlPreview?> _urlPreview = Rx<UrlPreview?>(null);
  final RxBool _isPreviewLoading = false.obs;

  static const int _maxLines = 7;
  String _lastProcessedContent = '';

  late final UrlPreviewService _urlPreviewService;
  final Rx<Uint8List?> _cachedImageData = Rx<Uint8List?>(null);
  final RxBool _isLoadingImage = false.obs;
  final RxBool _isExpired = false.obs;
  final RxDouble _downloadProgress = 0.0.obs;

  // Static in-memory cache shared across all bubble instances
  static final Map<String, Uint8List> _memoryCache = {};

  @override
  void initState() {
    super.initState();
    _lastProcessedContent = widget.message.content;
    _checkTextLength();

    // Initialize URL preview service
    try {
      _urlPreviewService = Get.find<UrlPreviewService>();
      _loadUrlPreview();
    } catch (e) {
      debugPrint('⚠️ Could not initialize UrlPreviewService: $e');
    }

    // For image messages, check cache synchronously for instant display
    if (widget.message.isImage) {
      _checkCacheSynchronously();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Re-check text length when dependencies change (like theme changes)
    if (_lastProcessedContent != widget.message.content) {
      _lastProcessedContent = widget.message.content;
      _resetAndCheckTextLength();
    }
  }

  /// Check cache synchronously for instant display of cached images
  void _checkCacheSynchronously() {
    try {
      final cacheService = Get.find<ImageCacheService>();

      // Check static memory cache first
      final memCached = _memoryCache[widget.message.id];
      if (memCached != null) {
        _cachedImageData.value = memCached;
        return;
      }

      // Check service memory cache (synchronous)
      final syncCached = cacheService.getCachedImageByIdSync(widget.message.id);
      if (syncCached != null) {
        _cachedImageData.value = syncCached;
        _memoryCache[widget.message.id] = syncCached;
        return;
      }

      // If not in memory cache, check if it exists in disk cache
      if (cacheService.isImageCachedById(widget.message.id)) {
        // Image is in disk cache, load it asynchronously
        _preloadImageData();
      }
    } catch (e) {
      debugPrint('❌ Error checking cache synchronously: $e');
    }
  }

  @override
  void didUpdateWidget(ChatMessageBubble oldWidget) {
    super.didUpdateWidget(oldWidget);

    // If message content changed, reset state and reload
    if (oldWidget.message.content != widget.message.content ||
        oldWidget.message.id != widget.message.id) {
      _resetAndCheckTextLength();
      _cachedImageData.value = null;
      _isLoadingImage.value = false;
      _lastProcessedContent = widget.message.content;

      // Reload image if this is an image message
      if (widget.message.isImage) {
        _preloadImageData();
      }
    }
  }

  /// Reset state and re-check text length
  void _resetAndCheckTextLength() {
    _isExpanded.value = false;
    _showExpandButton.value = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _checkTextLength();
      }
    });
  }

  void _preloadImageData() async {
    if (_isLoadingImage.value) return;

    // Check static memory cache first — instant, no disk I/O
    final memCached = _memoryCache[widget.message.id];
    if (memCached != null) {
      _cachedImageData.value = memCached;
      return;
    }

    // Clear any existing cached data first to prevent showing wrong image
    _cachedImageData.value = null;
    _isLoadingImage.value = true;

    try {
      final imageData = await _processImageData();
      // Only set the cached data if we're still loading the same message
      if (_isLoadingImage.value) {
        _cachedImageData.value = imageData;
        _isLoadingImage.value = false;
      }
    } catch (e) {
      debugPrint('❌ Error preloading image: $e');
      _isLoadingImage.value = false;
      // Retry after a short delay
      Future.delayed(const Duration(seconds: 2), () {
        if (_cachedImageData.value == null && !_isLoadingImage.value) {
          _preloadImageData();
        }
      });
    }
  }

  void _checkTextLength() {
    // Skip for non-text messages
    if (widget.message.isImage ||
        widget.message.content.startsWith('MEDIA:') ||
        widget.message.content.startsWith('IMAGE:')) {
      _showExpandButton.value = false;
      return;
    }

    // Create text painter to measure text with proper styling
    final textPainter = TextPainter(
      text: TextSpan(
        text: widget.message.content,
        style: TextStyle(
          fontSize: AppSizes.fontM,
          fontWeight: FontWeight.w500, // Match actual text style
          color: Colors.black, // Match actual text color
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: _maxLines,
    );

    // Layout the text with the same constraints as the actual text widget
    // Use a reasonable width that matches the bubble constraints
    final maxWidth = AppSizes.maxMessageWidth - (AppSizes.paddingM * 2);
    textPainter.layout(maxWidth: maxWidth);

    // Check if text exceeds the max lines
    final didExceedMaxLines = textPainter.didExceedMaxLines;

    // Additional safety check: also consider character count for very long single lines
    final isLongContent = widget.message.content.length > 200;

    // Update reactive variable
    _showExpandButton.value = didExceedMaxLines || isLongContent;

    debugPrint('🔍 Text check for message ${widget.message.id}: '
        'length=${widget.message.content.length}, '
        'didExceedMaxLines=$didExceedMaxLines, '
        'isLongContent=$isLongContent, '
        'showExpandButton=${_showExpandButton.value}');
  }

  @override
  Widget build(BuildContext context) {
    final hasLinks = _hasLinks(widget.message.content);
    final shouldWrapToContent = _shouldWrapToContent();

    return GestureDetector(
      onPanEnd: (details) {
        // Check if it's a horizontal swipe
        if (details.velocity.pixelsPerSecond.dx.abs() > 300) {
          // Swipe right for received messages, swipe left for sent messages
          if ((widget.message.isMe &&
                  details.velocity.pixelsPerSecond.dx < -300) ||
              (!widget.message.isMe &&
                  details.velocity.pixelsPerSecond.dx > 300)) {
            try {
              final chatController = Get.find<ChatController>();
              chatController.startReply(widget.message);
            } catch (e) {
              debugPrint('⚠️ Could not start reply: $e');
            }
          }
        }
      },
      child: Align(
        alignment:
            widget.message.isMe ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          margin: EdgeInsets.only(
            left: widget.message.isMe ? 50 : AppSizes.paddingM,
            right: widget.message.isMe ? AppSizes.paddingM : 50,
            top: AppSizes.paddingXS,
            bottom: AppSizes.paddingXS,
          ),
          child: Column(
            crossAxisAlignment: widget.message.isMe
                ? CrossAxisAlignment.end
                : CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisSize: MainAxisSize.max,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (widget.message.isMe &&
                      widget.message.status == MessageStatus.failed)
                    GestureDetector(
                      onTap: () {
                        try {
                          Get.find<ChatController>()
                              .retrySendMessage(widget.message.id);
                        } catch (e) {
                          debugPrint('⚠️ Could not retry message: $e');
                        }
                      },
                      child: const Padding(
                        padding: EdgeInsets.only(right: 6, bottom: 10),
                        child: Icon(
                          Icons.refresh_rounded,
                          size: 18,
                          color: Colors.red,
                        ),
                      ),
                    ),
                  // Use Flexible to prevent overflow
                  Flexible(
                    child: shouldWrapToContent
                        ? _buildContentWrappedBubble(hasLinks)
                        : _buildFullWidthBubble(hasLinks),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Determine if message should wrap to content or use full width
  bool _shouldWrapToContent() {
    // Always wrap to content for non-text messages
    if (widget.message.isImage ||
        widget.message.content.startsWith('MEDIA:') ||
        widget.message.content.startsWith('IMAGE:')) {
      return true;
    }

    // Wrap to content for short text messages
    final contentLength = widget.message.content.trim().length;
    return contentLength <= AppSizes.contentWrapThreshold;
  }

  /// Build bubble that wraps to content size
  Widget _buildContentWrappedBubble(bool hasLinks) {
    return GestureDetector(
      onLongPress: () => _showMessageOptions(Get.context!, hasLinks),
      child: Container(
        constraints: BoxConstraints(
          minWidth: AppSizes.minMessageWidth,
          maxWidth: AppSizes.maxMessageWidth,
        ),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSizes.paddingM,
          vertical: AppSizes.paddingS,
        ),
        decoration: BoxDecoration(
          color: widget.message.isMe
              ? AppColors.senderBubble
              : AppColors.receiverBubble,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(AppSizes.radiusL),
            topRight: const Radius.circular(AppSizes.radiusL),
            bottomLeft: Radius.circular(
              widget.message.isMe ? AppSizes.radiusL : AppSizes.radiusXS,
            ),
            bottomRight: Radius.circular(
              widget.message.isMe ? AppSizes.radiusXS : AppSizes.radiusL,
            ),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildMessageContent(),
            if (hasLinks) _buildLinkPreview(),
            const SizedBox(height: 4),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  TimeUtils.formatMessageTime(widget.message.timestamp),
                  style: TextStyle(
                    color: widget.message.isMe
                        ? Colors.black.withOpacity(0.4)
                        : Colors.black,
                    fontSize: AppSizes.fontXS,
                  ),
                ),
                if (widget.message.isMe) ...[
                  const SizedBox(width: 4),
                  _buildStatusIcon(widget.message.status),
                ],
                // Reply icon
                GestureDetector(
                  onTap: () {
                    try {
                      final chatController = Get.find<ChatController>();
                      chatController.startReply(widget.message);
                    } catch (e) {
                      debugPrint('⚠️ Could not start reply: $e');
                    }
                  },
                  child: Container(
                    padding: EdgeInsets.all(2),
                    child: Icon(
                      Icons.reply,
                      size: 16,
                      color: widget.message.isMe
                          ? Colors.black.withValues(alpha: 0.4)
                          : Colors.black.withValues(alpha: 0.6),
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

  /// Build bubble that can use full width (for longer messages)
  Widget _buildFullWidthBubble(bool hasLinks) {
    return Flexible(
      child: GestureDetector(
        onLongPress: () => _showMessageOptions(Get.context!, hasLinks),
        child: Container(
          constraints: BoxConstraints(maxWidth: AppSizes.maxMessageWidth),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSizes.paddingM,
            vertical: AppSizes.paddingS,
          ),
          decoration: BoxDecoration(
            color: widget.message.isMe
                ? AppColors.senderBubble
                : AppColors.receiverBubble,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(AppSizes.radiusL),
              topRight: const Radius.circular(AppSizes.radiusL),
              bottomLeft: Radius.circular(
                widget.message.isMe ? AppSizes.radiusL : AppSizes.radiusXS,
              ),
              bottomRight: Radius.circular(
                widget.message.isMe ? AppSizes.radiusXS : AppSizes.radiusL,
              ),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildMessageContent(),
              if (hasLinks) _buildLinkPreview(),
              const SizedBox(height: 4),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    TimeUtils.formatMessageTime(widget.message.timestamp),
                    style: TextStyle(
                      color: widget.message.isMe
                          ? Colors.black.withOpacity(0.4)
                          : Colors.black,
                      fontSize: AppSizes.fontXS,
                    ),
                  ),
                  if (widget.message.isMe) ...[
                    const SizedBox(width: 4),
                    _buildStatusIcon(widget.message.status),
                  ],
                  // Reply icon
                  GestureDetector(
                    onTap: () {
                      try {
                        final chatController = Get.find<ChatController>();
                        chatController.startReply(widget.message);
                      } catch (e) {
                        debugPrint('⚠️ Could not start reply: $e');
                      }
                    },
                    child: Container(
                      padding: EdgeInsets.all(2),
                      child: Icon(
                        Icons.reply,
                        size: 16,
                        color: widget.message.isMe
                            ? Colors.black.withValues(alpha: 0.4)
                            : Colors.black.withValues(alpha: 0.6),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMessageContent() {
    // Check if this is an image message (type flag OR content prefix as fallback)
    final content = widget.message.content;
    if (widget.message.isImage ||
        content.startsWith('MEDIA:') ||
        content.startsWith('IMAGE:')) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Add quoted bubble if this is a reply
          if (widget.message.replyTo != null) _buildQuotedBubble(),
          _buildImageContent(),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Add quoted bubble if this is a reply
        if (widget.message.replyTo != null) _buildQuotedBubble(),
        Obx(() => _buildTextWithLinks(
              widget.message.content,
              style: TextStyle(
                color: Colors.black,
                fontSize: AppSizes.fontM,
                fontWeight: FontWeight.w500,
              ),
              maxLines: _isExpanded.value ? null : _maxLines,
              overflow: _isExpanded.value ? null : TextOverflow.ellipsis,
            )),
        Obx(() {
          if (!_showExpandButton.value) return const SizedBox.shrink();
          return Column(
            children: [
              // Only show if text is long enough
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerRight,
                child: GestureDetector(
                  onTap: () {
                    _isExpanded.value = !_isExpanded.value;
                  },
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    child: Text(
                      _isExpanded.value ? 'Show less' : 'See more',
                      style: TextStyle(
                        color: widget.message.isMe
                            ? Colors.blue.shade600
                            : Colors.blue.shade700,
                        fontSize: AppSizes.fontS,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        }),
      ],
    );
  }

  /// Build text with clickable links (WhatsApp-style)
  Widget _buildTextWithLinks(
    String text, {
    TextStyle? style,
    int? maxLines,
    TextOverflow? overflow,
  }) {
    final links = _extractLinks(text);

    if (links.isEmpty) {
      // No links, return normal text
      return Text(
        text,
        style: style,
        maxLines: maxLines,
        overflow: overflow,
      );
    }

    // Build rich text with clickable links
    final spans = <TextSpan>[];
    final urlRegex = RegExp(
      r'(?:(?:https?|ftp):\/\/)?(?:www\.)?[a-zA-Z0-9-]+\.[a-zA-Z]{2,}(?:[\/\w\.-]*)*\/?(?:\?[^\s]*)?(?:\#[^\s]*)?',
      caseSensitive: false,
    );
    int lastEnd = 0;

    for (final match in urlRegex.allMatches(text)) {
      // Add text before the link
      if (match.start > lastEnd) {
        spans.add(TextSpan(
          text: text.substring(lastEnd, match.start),
          style: style,
        ));
      }

      // Add the clickable link
      var originalUrl = match.group(0)!;
      var launchUrl = originalUrl;

      // Add https:// if missing for proper URL launching
      if (!launchUrl.startsWith('http') && !launchUrl.startsWith('ftp')) {
        launchUrl = 'https://$launchUrl';
      }

      spans.add(TextSpan(
        text: originalUrl, // Show original text (without added https://)
        style: (style ?? const TextStyle()).copyWith(
          color: Colors.blue,
          decoration: TextDecoration.underline,
          decorationColor: Colors.blue,
        ),
        recognizer: TapGestureRecognizer()..onTap = () => _launchUrl(launchUrl),
      ));

      lastEnd = match.end;
    }

    // Add remaining text after the last link
    if (lastEnd < text.length) {
      spans.add(TextSpan(
        text: text.substring(lastEnd),
        style: style,
      ));
    }

    return RichText(
      text: TextSpan(children: spans),
      maxLines: maxLines,
      // overflow: overflow,
    );
  }

  /// Load URL preview for this message
  void _loadUrlPreview() async {
    final urls = _extractLinks(widget.message.content);
    if (urls.isEmpty) return;

    // Show loading state
    _isPreviewLoading.value = true;

    try {
      // Preview the first URL found
      final preview = await _urlPreviewService.previewUrl(urls.first);
      if (mounted) {
        _urlPreview.value = preview;
        _isPreviewLoading.value = false;
      }
    } catch (e) {
      debugPrint('⚠️ Error loading URL preview: $e');
      if (mounted) {
        _isPreviewLoading.value = false;
      }
    }
  }

  Widget _buildImageContent() {
    // Only trigger lazy load if image is not cached and not already loading
    if (_cachedImageData.value == null && !_isLoadingImage.value) {
      // Check if we should show loading state or load asynchronously
      try {
        final cacheService = Get.find<ImageCacheService>();
        // If image exists in cache, load it without showing loading state
        if (cacheService.isImageCachedById(widget.message.id)) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _preloadImageData();
          });
        } else {
          // Image not cached, will show loading state
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _preloadImageData();
          });
        }
      } catch (e) {
        // Fallback to normal loading
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _preloadImageData();
        });
      }
    }

    return Obx(() {
      // Check if message is still being sent (uploading state)
      if (widget.message.status == MessageStatus.sending) {
        // Try to get upload progress from ChatController
        RxDouble? uploadProgress;
        try {
          final chatController = Get.find<ChatController>();
          uploadProgress = chatController.uploadProgressMap[widget.message.id];
        } catch (_) {}

        return ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            width: 200,
            height: 200,
            child: Stack(
              fit: StackFit.expand,
              children: [
                // Image preview (already cached for sender)
                if (_cachedImageData.value != null)
                  Image.memory(
                    _cachedImageData.value!,
                    width: 200,
                    height: 200,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                  )
                else
                  Container(
                    color: Colors.grey[300],
                    child: const Center(
                        child: Icon(Icons.image, color: Colors.grey)),
                  ),
                // Dark scrim
                Container(color: Colors.black.withOpacity(0.45)),
                // Progress ring + percentage (WhatsApp-style)
                Center(
                  child: uploadProgress != null
                      ? Obx(() {
                          final pct = uploadProgress!.value;
                          return Stack(
                            alignment: Alignment.center,
                            children: [
                              SizedBox(
                                width: 52,
                                height: 52,
                                child: CircularProgressIndicator(
                                  value: pct > 0 ? pct : null,
                                  strokeWidth: 3,
                                  color: Colors.white,
                                  backgroundColor:
                                      Colors.white.withOpacity(0.3),
                                ),
                              ),
                              if (pct > 0)
                                Text(
                                  '${(pct * 100).toInt()}%',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                            ],
                          );
                        })
                      : const SizedBox(
                          width: 52,
                          height: 52,
                          child: CircularProgressIndicator(
                            strokeWidth: 3,
                            color: Colors.white,
                          ),
                        ),
                ),
              ],
            ),
          ),
        );
      }

      // Loading state with progress
      if (_isLoadingImage.value) {
        return Container(
          width: 200,
          height: 200,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            color: Colors.grey[200],
          ),
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Stack(
                  alignment: Alignment.center,
                  children: [
                    SizedBox(
                      width: 50,
                      height: 50,
                      child: CircularProgressIndicator(
                        strokeWidth: 3,
                        value: _downloadProgress.value > 0
                            ? _downloadProgress.value
                            : null,
                        valueColor:
                            const AlwaysStoppedAnimation<Color>(Colors.blue),
                      ),
                    ),
                    if (_downloadProgress.value > 0)
                      Text(
                        '${(_downloadProgress.value * 100).toStringAsFixed(0)}%',
                        style: const TextStyle(
                          color: Colors.blue,
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  _downloadProgress.value > 0
                      ? 'Downloading ${(_downloadProgress.value * 100).toStringAsFixed(0)}%'
                      : 'Loading image...',
                  style: const TextStyle(
                    color: Colors.grey,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        );
      }

      // Normal image display for sent messages - use cached data if available
      final imageData = _cachedImageData.value;
      if (imageData != null) {
        return GestureDetector(
          onTap: () => _showFullScreenImage(imageData),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.memory(
              imageData,
              width: 200,
              height: 200,
              fit: BoxFit.cover,
              gaplessPlayback: true, // Prevent flashing during rebuilds
              errorBuilder: (context, error, stackTrace) {
                debugPrint('❌ Error loading cached image: $error');
                return Container(
                  width: 200,
                  height: 100,
                  color: Colors.grey[300],
                  child: const Center(
                    child: Icon(Icons.broken_image, color: Colors.grey),
                  ),
                );
              },
            ),
          ),
        );
      }

      // Expired state — image deleted from server and not in local cache
      if (_isExpired.value) {
        return Container(
          width: 200,
          height: 80,
          decoration: BoxDecoration(
            color: Colors.grey[200],
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.image_not_supported_outlined,
                  color: Colors.grey[500], size: 20),
              const SizedBox(width: 8),
              Text(
                'Image no longer available',
                style: TextStyle(color: Colors.grey[600], fontSize: 12),
              ),
            ],
          ),
        );
      }

      // Error state — tap to retry
      return GestureDetector(
        onTap: () {
          _isExpired.value = false;
          _preloadImageData();
        },
        child: Container(
          width: 200,
          height: 200,
          decoration: BoxDecoration(
            color: Colors.grey[200],
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.refresh, color: Colors.grey[600], size: 32),
              const SizedBox(height: 8),
              Text(
                'Tap to retry',
                style: TextStyle(
                  color: Colors.grey[600],
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      );
    });
  }

  Future<Uint8List?> _processImageData() async {
    try {
      final cacheService = Get.find<ImageCacheService>();

      // Check static memory cache first (fastest — no disk I/O, no hashing)
      final memCached = _memoryCache[widget.message.id];
      if (memCached != null) {
        return memCached;
      }

      // Check Hive disk cache by message ID (fast — no SHA256, off main thread)
      final cachedById =
          await cacheService.getCachedImageById(widget.message.id);
      if (cachedById != null) {
        _memoryCache[widget.message.id] = cachedById;
        return cachedById;
      }

      // --- New MEDIA: token path ---
      if (widget.message.content.startsWith('MEDIA:')) {
        final token = widget.message.content.substring(6);
        debugPrint('📥 Downloading media token: $token');

        final encryptedBlob = await MediaUploadService.downloadImage(
          token,
          onProgress: (progress) {
            _downloadProgress.value = progress;
          },
        );

        if (encryptedBlob == null) {
          // 410 Gone — server deleted after first download or TTL expired
          debugPrint('⚠️ Media expired or already downloaded: $token');
          _isExpired.value = true;
          return null;
        }

        // Decrypt (XOR) → base64 string → image bytes
        final base64Image = EncryptionService.decryptMessage(encryptedBlob);
        final imageBytes = await compute(_decodeBase64Image, base64Image);

        if (imageBytes.isEmpty) {
          debugPrint('❌ Decoded image is empty for token: $token');
          return null;
        }

        // Cache so it never needs to be re-downloaded
        _memoryCache[widget.message.id] = imageBytes;
        await cacheService.cacheImageById(widget.message.id, imageBytes);
        debugPrint('✅ Media downloaded and cached: ${widget.message.id}');
        return imageBytes;
      }

      // --- Legacy IMAGE: base64 path (backward compat) ---
      final content = widget.message.content.startsWith('IMAGE:')
          ? widget.message.content.substring(6)
          : widget.message.content;

      if (content.length < 100) {
        debugPrint('❌ Content too short to be an image: ${widget.message.id}');
        return null;
      }

      final processedImage = await compute(_decodeBase64Image, content);

      if (processedImage.isEmpty) {
        debugPrint(
            '❌ Decoded image is empty for message: ${widget.message.id}');
        return null;
      }

      _memoryCache[widget.message.id] = processedImage;
      await cacheService.cacheImageById(widget.message.id, processedImage);
      return processedImage;
    } catch (e) {
      debugPrint('❌ Error processing image data: $e');
      return null;
    }
  }

  static Uint8List _decodeBase64Image(String base64String) {
    try {
      return base64Decode(base64String);
    } catch (_) {
      return Uint8List(0);
    }
  }

  void _showFullScreenImage(Uint8List imageBytes) {
    Get.dialog(
      Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: EdgeInsets.zero,
        child: Stack(
          children: [
            // Full screen image
            GestureDetector(
              onTap: () => Get.back(),
              child: Container(
                color: Colors.black,
                child: Center(
                  child: InteractiveViewer(
                    minScale: 0.5,
                    maxScale: 4.0,
                    child: Image.memory(imageBytes, fit: BoxFit.contain),
                  ),
                ),
              ),
            ),
            // Close button
            Positioned(
              top: 40,
              right: 16,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white, size: 30),
                onPressed: () => Get.back(),
              ),
            ),
          ],
        ),
      ),
      barrierColor: Colors.black87,
    );
  }

  Widget _buildLinkPreview() {
    // Show enhanced URL preview if available
    return Obx(() {
      // Show loading state
      if (_isPreviewLoading.value) {
        return Container(
          margin: const EdgeInsets.only(top: 8),
          height: 100,
          decoration: BoxDecoration(
            color: widget.message.isMe ? Colors.white : Colors.grey.shade100,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: widget.message.isMe
                  ? Colors.grey.shade300
                  : Colors.grey.shade200,
            ),
          ),
          child: const Center(
            child: CircularProgressIndicator(),
          ),
        );
      }

      // Show enhanced preview if available
      if (_urlPreview.value != null) {
        return GestureDetector(
          onTap: () => _launchUrl(_urlPreview.value!.url),
          child: Container(
            margin: const EdgeInsets.only(top: 8),
            decoration: BoxDecoration(
              color: widget.message.isMe ? Colors.white : Colors.grey.shade50,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: widget.message.isMe
                    ? Colors.grey.shade300
                    : Colors.grey.shade200,
                width: 1,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_urlPreview.value!.imageUrl != null)
                  _buildPreviewImage(_urlPreview.value!.imageUrl!),
                _buildPreviewContent(_urlPreview.value!),
              ],
            ),
          ),
        );
      }

      // Fallback to simple link preview
      final links = _extractLinks(widget.message.content);
      if (links.isEmpty) return const SizedBox.shrink();

      final firstLink = links.first;
      return GestureDetector(
        onTap: () => _launchUrl(firstLink),
        child: Container(
          margin: const EdgeInsets.only(top: 8),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: widget.message.isMe
                ? AppColors.primaryLight.withOpacity(0.1)
                : Colors.grey.shade100,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: widget.message.isMe
                  ? AppColors.primary.withOpacity(0.3)
                  : Colors.grey.shade300,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.link,
                    size: 16,
                    color: widget.message.isMe
                        ? AppColors.primary
                        : AppColors.textSecondary,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _getDomainFromUrl(firstLink),
                      style: TextStyle(
                        fontSize: AppSizes.fontS,
                        fontWeight: FontWeight.w600,
                        color: widget.message.isMe
                            ? AppColors.primary
                            : AppColors.textPrimary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Icon(
                    Icons.open_in_new,
                    size: 14,
                    color: widget.message.isMe
                        ? AppColors.primary.withOpacity(0.7)
                        : AppColors.textSecondary,
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                firstLink,
                style: TextStyle(
                  fontSize: AppSizes.fontXS,
                  color: widget.message.isMe
                      ? AppColors.textLight.withOpacity(0.8)
                      : AppColors.textSecondary,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      );
    });
  }

  Widget _buildPreviewImage(String imageUrl) {
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(11)),
      child: CachedNetworkImage(
        imageUrl: imageUrl,
        height: 150,
        width: double.infinity,
        fit: BoxFit.cover,
        placeholder: (context, url) => Container(
          height: 150,
          color: Colors.grey.shade200,
          child: const Center(
            child: CircularProgressIndicator(),
          ),
        ),
        errorWidget: (context, url, error) => Container(
          height: 150,
          color: Colors.grey.shade200,
          child: const Icon(
            Icons.broken_image,
            size: 40,
            color: Colors.grey,
          ),
        ),
      ),
    );
  }

  Widget _buildPreviewContent(UrlPreview preview) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (preview.siteName != null) ...[
            Text(
              preview.siteName!,
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey.shade600,
                fontWeight: FontWeight.w500,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 4),
          ],
          Text(
            preview.title,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: Colors.black87,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          if (preview.description.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              preview.description,
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey.shade700,
                height: 1.3,
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          const SizedBox(height: 8),
          Text(
            _getDomainFromUrl(preview.url),
            style: TextStyle(
              fontSize: 11,
              color: Colors.blue.shade600,
              fontWeight: FontWeight.w500,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  bool _hasLinks(String text) {
    // Enhanced regex to catch more URL patterns including complex paths
    final urlRegex = RegExp(
      r'(?:(?:https?|ftp):\/\/)?(?:www\.)?[a-zA-Z0-9-]+\.[a-zA-Z]{2,}(?:[\/\w\.-]*)*\/?(?:\?[^\s]*)?(?:\#[^\s]*)?',
      caseSensitive: false,
    );
    return urlRegex.hasMatch(text);
  }

  List<String> _extractLinks(String text) {
    // Enhanced regex to catch more URL patterns including complex paths
    final urlRegex = RegExp(
      r'(?:(?:https?|ftp):\/\/)?(?:www\.)?[a-zA-Z0-9-]+\.[a-zA-Z]{2,}(?:[\/\w\.-]*)*\/?(?:\?[^\s]*)?(?:\#[^\s]*)?',
      caseSensitive: false,
    );

    final links = <String>[];

    for (final match in urlRegex.allMatches(text)) {
      var url = match.group(0)!;

      // Add https:// if missing for proper URL launching
      if (!url.startsWith('http') && !url.startsWith('ftp')) {
        url = 'https://$url';
      }
      links.add(url);
      debugPrint('🔗 Extracted URL: $url');
    }
    debugPrint('🔗 Total URLs extracted: ${links.length}');

    return links;
  }

  String _getDomainFromUrl(String url) {
    try {
      final uri = Uri.parse(url);
      return uri.host;
    } catch (e) {
      return 'Link';
    }
  }

  void _showMessageOptions(BuildContext context, bool hasLinks) {
    final links = _extractLinks(widget.message.content);

    Get.bottomSheet(
      Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Text(
              'Message Options',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),

            // Message preview
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.grey[100],
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                widget.message.content,
                style: const TextStyle(fontSize: 14),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(height: 20),

            // Reply button - always show for all messages
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () {
                  Get.back();
                  try {
                    final chatController = Get.find<ChatController>();
                    chatController.startReply(widget.message);
                  } catch (e) {
                    debugPrint('⚠️ Could not start reply: $e');
                    Get.snackbar(
                      'Error',
                      'Could not reply to message',
                      snackPosition: SnackPosition.BOTTOM,
                      backgroundColor: Colors.red.shade100,
                    );
                  }
                },
                icon: const Icon(Icons.reply, size: 18),
                label: const Text('Reply'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
            const SizedBox(height: 12),

            // Action buttons
            if (hasLinks && links.isNotEmpty) ...[
              // Link actions only
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () {
                        Get.back();
                        _openLink(links.first);
                      },
                      icon: const Icon(Icons.open_in_new),
                      label: const Text('Open Link'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blue,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () {
                        Get.back();
                        _copyLink(links.first);
                      },
                      icon: const Icon(Icons.copy),
                      label: const Text('Copy Link'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
                  ),
                ],
              ),
            ] else ...[
              // Text copy only (when no links)
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () {
                    Get.back();
                    _copyText(widget.message.content);
                  },
                  icon: const Icon(Icons.copy),
                  label: const Text('Copy Text'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.grey[600],
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 8),

            // Report message button
            if (!widget.message.isMe) ...[
              const SizedBox(height: 4),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () {
                    Get.back();
                    ReportBottomSheet.show(
                      targetType: 'message',
                      targetId: widget.message.id,
                    );
                  },
                  icon: const Icon(Icons.flag_outlined, size: 18),
                  label: const Text('Report Message'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red.shade50,
                    foregroundColor: Colors.red.shade700,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    elevation: 0,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
      isScrollControlled: true,
    );
  }

  void _openLink(String url) async {
    try {
      final uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(
          uri,
          mode: LaunchMode.externalApplication,
        );
        debugPrint('✅ Launched URL: $url');
      } else {
        // Fallback: copy to clipboard and show dialog
        await Clipboard.setData(ClipboardData(text: url));
        Get.snackbar(
          'Cannot Open Link',
          'Link copied to clipboard. Please open it manually in your browser.',
          snackPosition: SnackPosition.BOTTOM,
          duration: const Duration(seconds: 3),
          backgroundColor: Colors.orange.shade100,
          colorText: Colors.orange.shade800,
        );
        debugPrint('⚠️ Could not launch URL: $url');
      }
    } catch (e) {
      // Error handling: copy to clipboard and show dialog
      await Clipboard.setData(ClipboardData(text: url));
      Get.snackbar(
        'Error Opening Link',
        'Link copied to clipboard. Please open it manually in your browser.',
        snackPosition: SnackPosition.BOTTOM,
        duration: const Duration(seconds: 3),
        backgroundColor: Colors.red.shade100,
        colorText: Colors.red.shade800,
      );
      debugPrint('❌ Error launching URL: $url - $e');
    }
  }

  /// Launch URL directly (for inline clickable links)
  Future<void> _launchUrl(String url) async {
    try {
      final uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(
          uri,
          mode: LaunchMode.externalApplication,
        );
        debugPrint('✅ Launched URL: $url');
      } else {
        // Fallback to copy method
        _openLink(url);
      }
    } catch (e) {
      // Fallback to copy method
      _openLink(url);
    }
  }

  void _copyLink(String url) {
    Clipboard.setData(ClipboardData(text: url));
    Get.snackbar(
      'Copied',
      'Link copied to clipboard',
      snackPosition: SnackPosition.BOTTOM,
      duration: const Duration(seconds: 2),
    );
  }

  void _copyText(String text) {
    Clipboard.setData(ClipboardData(text: text));
    Get.snackbar(
      'Copied',
      'Text copied to clipboard',
      snackPosition: SnackPosition.BOTTOM,
      duration: const Duration(seconds: 2),
    );
  }

  Widget _buildStatusIcon(MessageStatus status) {
    switch (status) {
      case MessageStatus.sending:
        return Icon(
          Icons.access_time,
          size: 14,
          color: AppColors.textPrimary.withValues(alpha: 0.7),
        );
      case MessageStatus.sent:
        return Icon(
          Icons.check,
          size: 14,
          color: AppColors.textPrimary.withValues(alpha: 0.7),
        );
      case MessageStatus.delivered:
        return Icon(
          Icons.done_all,
          size: 14,
          color: AppColors.textPrimary.withValues(alpha: 0.7),
        );
      case MessageStatus.read:
        return Icon(
          Icons.done_all,
          size: 14,
          color: Colors.blue, // Blue color for read messages (WhatsApp style)
        );
      case MessageStatus.failed:
        return Icon(Icons.error_outline, size: 14, color: Colors.red);
    }
  }

  Widget _buildQuotedBubble() {
    if (widget.message.replyTo == null) return const SizedBox.shrink();

    return QuotedMessageBubble(
      replyTo: widget.message.replyTo!,
      onTap: () {
        // Get the chat controller and scroll to the original message
        final chatController = Get.find<ChatController>();
        chatController.scrollToMessage(widget.message.replyTo!.messageId);
      },
    );
  }
}
