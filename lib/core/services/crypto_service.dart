import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'dart:async';
import 'api_service.dart';

/// Supported cryptocurrencies
enum CryptoCoin {
  btc,
  eth,
  usdtTrc20;

  String get label {
    switch (this) {
      case CryptoCoin.btc:
        return 'Bitcoin (BTC)';
      case CryptoCoin.eth:
        return 'Ethereum (ETH)';
      case CryptoCoin.usdtTrc20:
        return 'USDT (TRC20)';
    }
  }

  String get symbol {
    switch (this) {
      case CryptoCoin.btc:
        return 'BTC';
      case CryptoCoin.eth:
        return 'ETH';
      case CryptoCoin.usdtTrc20:
        return 'USDT';
    }
  }

  IconData get icon {
    switch (this) {
      case CryptoCoin.btc:
        return Icons.currency_bitcoin;
      case CryptoCoin.eth:
        return Icons.toll;
      case CryptoCoin.usdtTrc20:
        return Icons.account_balance_wallet;
    }
  }

  Color get color {
    switch (this) {
      case CryptoCoin.btc:
        return Colors.orange;
      case CryptoCoin.eth:
        return Colors.blue;
      case CryptoCoin.usdtTrc20:
        return Colors.green;
    }
  }
}

class CryptoService extends GetxService {
  final RxBool isAvailable = false.obs;
  final RxBool isLoading = false.obs;
  final Rx<CryptoCoin> selectedCoin = CryptoCoin.usdtTrc20.obs;
  final RxString currentAddress = ''.obs;
  final RxDouble amount = 0.0.obs;
  final RxInt amountSmallestUnit = 0.obs;
  final RxString expiry = ''.obs;
  final RxString paymentStatus =
      'none'.obs; // none, pending, confirmed, expired, not_found
  final RxInt confirmations = 0.obs;
  final RxString txHash = ''.obs;
  final RxString contractAddress = ''.obs;
  final RxString expiryDate = ''.obs;
  final RxString currency = ''.obs;

  Timer? _pollingTimer;
  static const Duration _pollingInterval = Duration(seconds: 15);

  Future<CryptoService> init() async {
    isAvailable.value = true;
    debugPrint('✅ Multi-Coin Crypto Service initialized');
    return this;
  }

  /// Get pricing for a specific coin and plan
  Map<String, dynamic> getPricing(CryptoCoin coin, String planId) {
    // Pricing in USD equivalent
    // 6 months: $70 USD
    // 1 year: $100 USD
    switch (coin) {
      case CryptoCoin.btc:
        // ~70 USDT = 0.000875 BTC for 6 months, 100 USDT = 0.00125 BTC for 1 year
        return {
          '6_months': {
            'amount': 0.000875,
            'smallestUnit': 87500,
            'symbol': 'BTC'
          },
          '1_year': {
            'amount': 0.00125,
            'smallestUnit': 125000,
            'symbol': 'BTC'
          },
        };
      case CryptoCoin.eth:
        // ~70 USDT = 0.026 ETH for 6 months, 100 USDT = 0.038 ETH for 1 year
        return {
          '6_months': {
            'amount': 0.026,
            'smallestUnit': 26000000000000000,
            'symbol': 'ETH'
          },
          '1_year': {
            'amount': 0.038,
            'smallestUnit': 38000000000000000,
            'symbol': 'ETH'
          },
        };
      case CryptoCoin.usdtTrc20:
        // 70 USDT for 6 months, 100 USDT for 1 year
        return {
          '6_months': {
            'amount': 70.0,
            'smallestUnit': 70000000,
            'symbol': 'USDT'
          },
          '1_year': {
            'amount': 100.0,
            'smallestUnit': 100000000,
            'symbol': 'USDT'
          },
        };
    }
  }

  /// Generate a unique payment address for selected coin
  Future<Map<String, dynamic>> generateAddress({
    required String deviceId,
    required String planId,
    required String countryCode,
    CryptoCoin? coin,
  }) async {
    try {
      isLoading.value = true;
      final selectedCrypto = coin ?? selectedCoin.value;
      selectedCoin.value = selectedCrypto;

      final data = await ApiService.to.generateCryptoAddress(
        deviceId: deviceId,
        planId: planId,
        countryCode: countryCode,
        coin: selectedCrypto.name,
      );
      debugPrint(
          '✅ ${selectedCrypto.label} address generated: ${data['address']}');

      currentAddress.value = data['address'];
      amount.value = ((data['amount'] ??
              data['amountUSDT'] ??
              data['amountBTC'] ??
              data['amountETH'] ??
              0) as num)
          .toDouble();
      amountSmallestUnit.value = (data['amountSmallestUnit'] ??
          data['amountSatoshi'] ??
          data['amountWei'] ??
          0) as int;
      expiry.value = data['expiry'];
      contractAddress.value = data['contractAddress'] ?? '';
      currency.value = data['currency'] ?? selectedCrypto.symbol;
      paymentStatus.value = 'pending';

      return data;
    } catch (e) {
      debugPrint('❌ Error generating crypto address: $e');
      rethrow;
    } finally {
      isLoading.value = false;
    }
  }

  /// Check payment status for a device
  Future<Map<String, dynamic>> checkPaymentStatus(String deviceId,
      {CryptoCoin? coin}) async {
    try {
      final selectedCrypto = coin ?? selectedCoin.value;

      final data = await ApiService.to
          .checkCryptoPayment(deviceId, coin: selectedCrypto.name);

      paymentStatus.value = data['status'];
      confirmations.value = data['confirmations'] ?? 0;
      txHash.value = data['txHash'] ?? '';
      currency.value = data['currency'] ?? selectedCrypto.symbol;

      if (data['expiryDate'] != null) {
        expiryDate.value = data['expiryDate'];
      }

      debugPrint(
          '✅ Payment status: ${data['status']}, confirmations: ${data['confirmations']}');
      return data;
    } catch (e) {
      debugPrint('❌ Error checking payment status: $e');
      rethrow;
    }
  }

  /// Start polling for payment confirmation
  void startPolling(String deviceId, {CryptoCoin? coin}) {
    stopPolling(); // Stop any existing timer
    final selectedCrypto = coin ?? selectedCoin.value;

    debugPrint('🔄 Starting ${selectedCrypto.label} payment polling');

    _pollingTimer = Timer.periodic(_pollingInterval, (timer) async {
      try {
        final status = await checkPaymentStatus(deviceId, coin: selectedCrypto);

        if (status['status'] == 'active' || status['status'] == 'confirmed') {
          debugPrint('✅ Payment confirmed via polling!');
          stopPolling();
        } else if (status['status'] == 'expired') {
          debugPrint('⏰ Payment address expired');
          stopPolling();
        }
      } catch (e) {
        debugPrint('⚠️ Polling error: $e');
      }
    });
  }

  /// Stop polling for payment confirmation
  void stopPolling() {
    if (_pollingTimer != null) {
      _pollingTimer!.cancel();
      _pollingTimer = null;
      debugPrint('⏹️ Stopped crypto payment polling');
    }
  }

  /// Format amount for display based on coin
  String formatAmount(double amount, CryptoCoin coin) {
    switch (coin) {
      case CryptoCoin.btc:
        return amount.toStringAsFixed(8);
      case CryptoCoin.eth:
        return amount.toStringAsFixed(6);
      case CryptoCoin.usdtTrc20:
        return amount.toStringAsFixed(6);
    }
  }

  /// Format smallest unit to display amount
  String smallestUnitToDisplay(int smallestUnit, CryptoCoin coin) {
    switch (coin) {
      case CryptoCoin.btc:
        return (smallestUnit / 100000000).toStringAsFixed(8);
      case CryptoCoin.eth:
        return (smallestUnit / 1000000000000000000).toStringAsFixed(6);
      case CryptoCoin.usdtTrc20:
        return (smallestUnit / 1000000).toStringAsFixed(6);
    }
  }

  /// Get required confirmations for each coin
  int getRequiredConfirmations(CryptoCoin coin) {
    switch (coin) {
      case CryptoCoin.btc:
        return 3;
      case CryptoCoin.eth:
        return 12;
      case CryptoCoin.usdtTrc20:
        return 19;
    }
  }

  /// Generate payment URI based on coin
  String generatePaymentURI(String address, double amount, CryptoCoin coin,
      {String? contractAddress}) {
    switch (coin) {
      case CryptoCoin.btc:
        return 'bitcoin:$address?amount=$amount';
      case CryptoCoin.eth:
        return 'ethereum:$address?value=${(amount * 1000000000000000000).toInt()}';
      case CryptoCoin.usdtTrc20:
        return 'tron:$address?amount=$amount&contract=${contractAddress ?? 'TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t'}';
    }
  }

  /// Check if address has expired
  bool isAddressExpired() {
    if (expiry.value.isEmpty) return false;

    final expiryTime = DateTime.parse(expiry.value);
    return DateTime.now().isAfter(expiryTime);
  }

  /// Get time remaining until expiry
  String getTimeRemaining() {
    if (expiry.value.isEmpty) return '';

    final expiryTime = DateTime.parse(expiry.value);
    final remaining = expiryTime.difference(DateTime.now());

    if (remaining.isNegative) return 'Expired';

    final minutes = remaining.inMinutes;
    final seconds = remaining.inSeconds % 60;

    if (minutes > 0) {
      return '${minutes}m ${seconds}s';
    } else {
      return '${seconds}s';
    }
  }

  /// Get coin info for display
  String getCoinInfo(CryptoCoin coin) {
    switch (coin) {
      case CryptoCoin.btc:
        return 'Send BTC to the address above. 3 confirmations required.';
      case CryptoCoin.eth:
        return 'Send ETH to the address above. 12 confirmations required.';
      case CryptoCoin.usdtTrc20:
        return 'Send USDT-TRC20 to the address above. 19 confirmations required.';
    }
  }

  /// Get coin by name
  CryptoCoin? getCoinByName(String name) {
    try {
      return CryptoCoin.values.firstWhere((c) => c.name == name);
    } catch (e) {
      return null;
    }
  }

  @override
  void onClose() {
    stopPolling();
    super.onClose();
  }
}
