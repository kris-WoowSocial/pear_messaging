import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// TLS-pinned HTTP client for first-party `vant.chat` REST traffic.
///
/// The [HttpClient] is built on a [SecurityContext] whose trust store
/// contains ONLY the ISRG (Let's Encrypt) root CA certificates — so a
/// connection only validates when the presented chain resolves to a
/// pinned root (SPKI-pinning equivalent at the trust-anchor layer; the
/// leaf rotates every ~90 days so pinning the leaf would break the app).
///
/// Pinned roots:
///   - ISRG Root X1  — current vant.chat issuer anchor
///   - ISRG Root YR  — newer Let's Encrypt RSA root on the live chain
///   - ISRG Root X2  — backup pin (ECDSA root, alternate issuance path)
///
/// Use [PinnedHttpClient.newClient] anywhere vant.chat REST is called.
/// Third-party fetches (link previews, CDN) must keep the default trust
/// store — this context would reject them, so it is deliberately NOT
/// installed as a global HttpOverride.
class PinnedHttpClient {
  PinnedHttpClient._();

  /// Create a pinned [http.Client]. Callers own `close()`.
  static http.Client newClient() {
    final ctx = SecurityContext(withTrustedRoots: false);
    for (final der in _pinnedRoots) {
      ctx.setTrustedCertificatesBytes(base64Decode(der));
    }
    return IOClient(HttpClient(context: ctx));
  }

  // ISRG Root X1 (RSA, expires 2035) — primary pin.
  static const String _isrgX1 =
      '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'
      'm+kXQ99b21/+jh5Xos1AnX5iItreGCc=';

  // ISRG Root X2 (ECDSA P-384, expires 2040) — backup pin.
  static const String _isrgX2 =
      'MIICGzCCAaGgAwIBAgIQQdKd0XLq7qeAwSxs6S+HUjAKBggqhkjOPQQDAzBPMQswCQYDVQQGEwJV'
      'UzEpMCcGA1UEChMgSW50ZXJuZXQgU2VjdXJpdHkgUmVzZWFyY2ggR3JvdXAxFTATBgNVBAMTDElT'
      'UkcgUm9vdCBYMjAeFw0yMDA5MDQwMDAwMDBaFw00MDA5MTcxNjAwMDBaME8xCzAJBgNVBAYTAlVT'
      'MSkwJwYDVQQKEyBJbnRlcm5ldCBTZWN1cml0eSBSZXNlYXJjaCBHcm91cDEVMBMGA1UEAxMMSVNS'
      'RyBSb290IFgyMHYwEAYHKoZIzj0CAQYFK4EEACIDYgAEzZvVn4CDCuwJSvMWSj5cz3es3mcFDR0H'
      'ttwW+1qLFNvicWDEukWVEYmO6gbf9yoWHKS5xcUy4APgHoIYOIvXRdgKam7mAHf7AlF9ItgKbppb'
      'd9/w+kHsOdx1ymgHDB/qo0IwQDAOBgNVHQ8BAf8EBAMCAQYwDwYDVR0TAQH/BAUwAwEB/zAdBgNV'
      'HQ4EFgQUfEKWrt5LSDv6kviejM9ti6lyN5UwCgYIKoZIzj0EAwMDaAAwZQIwe3lORlCEwkSHRhtF'
      'cP9Ymd70/aTSVaYgLXTWNLxBo1BfASdWtL4ndQavEi51mI38AjEAi/V3bNTIZargCyzuFJ0nN6T5'
      'U6VR5CmD1/iQMVtCnwr1/q4AaOeMSQ+2b1tbFfLn';

  // ISRG Root YR (RSA, signed by X1, present on the live vant.chat chain).
  static const String _isrgYr =
      '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';

  static const List<String> _pinnedRoots = [_isrgX1, _isrgYr, _isrgX2];
}
