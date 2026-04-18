import 'dart:async';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:get/get.dart';

class UrlPreview {
  final String url;
  final String title;
  final String description;
  final String? imageUrl;
  final String? siteName;

  UrlPreview({
    required this.url,
    required this.title,
    required this.description,
    this.imageUrl,
    this.siteName,
  });
}

class UrlPreviewService extends GetxService {
  static const Duration _timeout = Duration(seconds: 5);
  static const int _maxDescriptionLength = 200;

  final Map<String, UrlPreview> _cache = {};
  Timer? _debounceTimer;

  /// Initialize the URL preview service
  Future<UrlPreviewService> init() async {
    debugPrint('✅ UrlPreviewService initialized');
    return this;
  }

  /// Preview URL with debouncing (for typing)
  Future<UrlPreview?> previewUrlWithDebounce(
      String url, Function(UrlPreview?) callback) async {
    // Cancel previous timer
    _debounceTimer?.cancel();

    // Debounce for 1 second
    _debounceTimer = Timer(const Duration(seconds: 1), () async {
      final preview = await previewUrl(url);
      callback(preview);
    });

    return null;
  }

  /// Preview URL immediately (for sent messages)
  Future<UrlPreview?> previewUrl(String url) async {
    debugPrint('🔗 Starting URL preview for: $url');

    // Check cache first
    if (_cache.containsKey(url)) {
      debugPrint('🔗 Using cached preview for: $url');
      return _cache[url];
    }

    try {
      // Normalize URL
      final normalizedUrl = _normalizeUrl(url);
      debugPrint('🔗 Normalized URL: $normalizedUrl');

      // Make HTTP request
      debugPrint('🔗 Making HTTP request to: $normalizedUrl');
      final response = await http.get(
        Uri.parse(normalizedUrl),
        headers: {
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36',
          'Accept':
              'text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8',
          'Accept-Language': 'en-US,en;q=0.5',
          'Accept-Encoding': 'gzip, deflate',
          'Connection': 'keep-alive',
        },
      ).timeout(_timeout);

      debugPrint('🔗 Response status: ${response.statusCode}');
      debugPrint(
          '🔗 Response content-type: ${response.headers['content-type']}');
      debugPrint('🔗 Response body length: ${response.body.length}');

      if (response.statusCode == 200) {
        final preview = _parseHtml(response.body, normalizedUrl);
        if (preview != null) {
          _cache[url] = preview;
          debugPrint('✅ Successfully parsed preview for: $url');
          debugPrint('   Title: ${preview.title}');
          debugPrint('   Description: ${preview.description}');
          debugPrint('   Image: ${preview.imageUrl}');
          return preview;
        } else {
          debugPrint('⚠️ Failed to parse HTML for: $url');
        }
      } else {
        debugPrint('⚠️ HTTP error ${response.statusCode} for: $url');
      }
    } catch (e) {
      debugPrint('⚠️ Error previewing URL $url: $e');
      debugPrint('⚠️ Stack trace: ${StackTrace.current}');
    }

    return null;
  }

  /// Normalize URL (add protocol if missing)
  String _normalizeUrl(String url) {
    if (!url.startsWith('http')) {
      return 'https://$url';
    }
    return url;
  }

  /// Parse HTML and extract Open Graph meta tags
  UrlPreview? _parseHtml(String html, String url) {
    try {
      debugPrint('🔗 Parsing HTML for: $url');
      debugPrint('🔗 HTML length: ${html.length}');

      // Extract title
      String title = '';
      final titleMatch =
          RegExp(r'<title[^>]*>(.*?)</title>', caseSensitive: false)
              .firstMatch(html);
      if (titleMatch != null) {
        title = titleMatch.group(1)?.trim() ?? '';
        debugPrint('🔗 Found title: $title');
      } else {
        debugPrint('⚠️ No title tag found');
      }

      // Extract Open Graph tags
      String? ogTitle;
      String? ogDescription;
      String? ogImage;
      String? ogSiteName;

      // More flexible regex patterns for Open Graph tags
      // Handle both property-content and content-property order
      var ogTitleMatch = RegExp(
              r'<meta[^>]*property\s*=\s*["\x27]og:title["\x27][^>]*content\s*=\s*["\x27]([^"\x27]*)["\x27]',
              caseSensitive: false)
          .firstMatch(html);
      ogTitleMatch ??= RegExp(
              r'<meta[^>]*content\s*=\s*["\x27]([^"\x27]*)["\x27][^>]*property\s*=\s*["\x27]og:title["\x27]',
              caseSensitive: false)
          .firstMatch(html);
      if (ogTitleMatch != null) {
        ogTitle = ogTitleMatch.group(1);
        debugPrint('🔗 Found og:title: $ogTitle');
      } else {
        debugPrint('⚠️ No og:title found');
      }

      var ogDescMatch = RegExp(
              r'<meta[^>]*property\s*=\s*["\x27]og:description["\x27][^>]*content\s*=\s*["\x27]([^"\x27]*)["\x27]',
              caseSensitive: false)
          .firstMatch(html);
      ogDescMatch ??= RegExp(
              r'<meta[^>]*content\s*=\s*["\x27]([^"\x27]*)["\x27][^>]*property\s*=\s*["\x27]og:description["\x27]',
              caseSensitive: false)
          .firstMatch(html);
      if (ogDescMatch != null) {
        ogDescription = ogDescMatch.group(1);
        debugPrint('🔗 Found og:description: $ogDescription');
      } else {
        debugPrint('⚠️ No og:description found');
      }

      var ogImageMatch = RegExp(
              r'<meta[^>]*property\s*=\s*["\x27]og:image["\x27][^>]*content\s*=\s*["\x27]([^"\x27]*)["\x27]',
              caseSensitive: false)
          .firstMatch(html);
      ogImageMatch ??= RegExp(
              r'<meta[^>]*content\s*=\s*["\x27]([^"\x27]*)["\x27][^>]*property\s*=\s*["\x27]og:image["\x27]',
              caseSensitive: false)
          .firstMatch(html);
      if (ogImageMatch != null) {
        ogImage = ogImageMatch.group(1);
        debugPrint('🔗 Found og:image: $ogImage');
      } else {
        debugPrint('⚠️ No og:image found');
      }

      var ogSiteMatch = RegExp(
              r'<meta[^>]*property\s*=\s*["\x27]og:site_name["\x27][^>]*content\s*=\s*["\x27]([^"\x27]*)["\x27]',
              caseSensitive: false)
          .firstMatch(html);
      ogSiteMatch ??= RegExp(
              r'<meta[^>]*content\s*=\s*["\x27]([^"\x27]*)["\x27][^>]*property\s*=\s*["\x27]og:site_name["\x27]',
              caseSensitive: false)
          .firstMatch(html);
      if (ogSiteMatch != null) {
        ogSiteName = ogSiteMatch.group(1);
        debugPrint('🔗 Found og:site_name: $ogSiteName');
      } else {
        debugPrint('⚠️ No og:site_name found');
      }

      // Fallback to description meta tag with more flexible pattern
      String? description;
      var descMatch = RegExp(
              r'<meta[^>]*name\s*=\s*["\x27]description["\x27][^>]*content\s*=\s*["\x27]([^"\x27]*)["\x27]',
              caseSensitive: false)
          .firstMatch(html);
      descMatch ??= RegExp(
              r'<meta[^>]*content\s*=\s*["\x27]([^"\x27]*)["\x27][^>]*name\s*=\s*["\x27]description["\x27]',
              caseSensitive: false)
          .firstMatch(html);
      if (descMatch != null) {
        description = descMatch.group(1);
      }

      // Use Open Graph tags with fallbacks
      final finalTitle = ogTitle ?? title;
      final finalDescription = ogDescription ?? description ?? '';
      final finalImage = ogImage;
      final finalSiteName = ogSiteName;

      debugPrint('🔗 Final values:');
      debugPrint('   Title: "$finalTitle"');
      debugPrint('   Description: "$finalDescription"');
      debugPrint('   Image: "$finalImage"');
      debugPrint('   Site Name: "$finalSiteName"');

      if (finalTitle.isNotEmpty) {
        final cleanedTitle = _cleanText(finalTitle);
        final cleanedDescription = _cleanText(finalDescription).length >
                _maxDescriptionLength
            ? '${_cleanText(finalDescription).substring(0, _maxDescriptionLength)}...'
            : _cleanText(finalDescription);

        debugPrint('✅ Creating UrlPreview with cleaned title: "$cleanedTitle"');

        return UrlPreview(
          url: url,
          title: cleanedTitle,
          description: cleanedDescription,
          imageUrl: finalImage,
          siteName: finalSiteName,
        );
      } else {
        debugPrint('⚠️ No title found, cannot create preview');
      }
    } catch (e) {
      debugPrint('⚠️ Error parsing HTML: $e');
      debugPrint('⚠️ Stack trace: ${StackTrace.current}');
    }

    return null;
  }

  /// Clean text by removing HTML tags and extra whitespace
  String _cleanText(String text) {
    // Remove HTML tags
    String cleaned = text.replaceAll(RegExp(r'<[^>]*>'), '');
    // Decode HTML entities
    cleaned = cleaned.replaceAll('&amp;', '&');
    cleaned = cleaned.replaceAll('&lt;', '<');
    cleaned = cleaned.replaceAll('&gt;', '>');
    cleaned = cleaned.replaceAll('&quot;', '"');
    cleaned = cleaned.replaceAll('&#39;', "'");
    // Remove extra whitespace
    cleaned = cleaned.replaceAll(RegExp(r'\s+'), ' ').trim();
    return cleaned;
  }

  /// Extract URLs from text
  List<String> extractUrls(String text) {
    final urlRegex = RegExp(
      r'(?:(?:https?|ftp):\/\/)?(?:www\.)?[a-zA-Z0-9-]+\.[a-zA-Z]{2,}(?:[\/\w\.-]*)*\/?(?:\?[^\s]*)?(?:\#[^\s]*)?',
      caseSensitive: false,
    );

    final matches = urlRegex.allMatches(text);
    final urls = <String>[];

    for (final match in matches) {
      var url = match.group(0)!;
      if (!url.startsWith('http')) {
        url = 'https://$url';
      }
      urls.add(url);
    }

    return urls;
  }

  @override
  void onClose() {
    _debounceTimer?.cancel();
    super.onClose();
  }
}
