// lib/main.dart
//
// Flutter app demonstrating two-layer consent flow:
// 1) OneTrust consent (first layer). If denied -> treat as denied, do NOT show ATT.
// 2) If OneTrust granted -> on iOS show ATT; only if ATT authorized treat as full consent.
// 3) On Android, OneTrust grant => considered consent granted (no ATT).
//
// Assumptions:
// - Native MethodChannel handlers exist for:
//     'applyPrivacyAndInit'  -> disable ad-ids and init native AppsFlyer in privacy mode
//     'revokePrivacyAndInit' -> re-enable ad-ids and init native AppsFlyer normally
// - The Dart-side AppsFlyer plugin initialisation / event buffering is used as in previous examples.
// - Add `app_tracking_transparency` to pubspec for ATT on iOS.
//
// Add to pubspec.yaml:
//   app_tracking_transparency: ^2.0.3    # or latest
//   appsflyer_sdk: ^6.6.0
//   shared_preferences: ^2.0.15
//

import 'dart:io' show Platform;
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:appsflyer_sdk/appsflyer_sdk.dart';
import 'package:app_tracking_transparency/app_tracking_transparency.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// MethodChannel to call native privacy/init methods (must match native).
const MethodChannel _afChannel = MethodChannel('com.example.app/appsflyer_privacy');

/// AppsFlyer config — replace with your real values.
final AppsFlyerOptions _afOptions = AppsFlyerOptions(
  afDevKey: 'REPLACE_WITH_YOUR_DEV_KEY', // <-- REPLACE
  appId: 'REPLACE_WITH_YOUR_APP_ID',     // <-- iOS app id / bundle id when required
  showDebug: true,
);

late final AppsFlyerSdk _afSdk;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Create the AppsFlyer plugin instance but DO NOT call init/start here.
  _afSdk = AppsFlyerSdk(_afOptions);
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({Key? key}) : super(key: key);
  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  // Consent states:
  // _oneTrustConsent: result from OneTrust UI (true = granted, false = denied)
  // _finalConsent: effective "send identifiers & events" permission after ATT step
  bool _oneTrustConsent = false;
  bool _finalConsent = false;

  // plugin initialization flag: we only call plugin init when _finalConsent == true
  bool _afPluginInitialized = false;

  final List<Map<String, dynamic>> _eventBuffer = [];
  SharedPreferences? _prefs;

  @override
  void initState() {
    super.initState();
    _loadStoredConsentAndApply();
  }

  /// Load stored consent decision (if any) and apply appropriate flow.
  Future<void> _loadStoredConsentAndApply() async {
    _prefs = await SharedPreferences.getInstance();
    final storedOneTrust = _prefs?.getBool('one_trust_consent') ?? false;
    final storedFinal = _prefs?.getBool('final_consent') ?? false;

    setState(() {
      _oneTrustConsent = storedOneTrust;
      _finalConsent = storedFinal;
    });

    if (_oneTrustConsent) {
      // If OneTrust previously granted, we must re-run the ATT step (iOS) or
      // treat as granted on Android.
      await _evaluateAttIfNeededAndApply();
    } else {
      // If OneTrust previously denied (or default), ensure privacy-mode init
      // executed so native SDKs do not collect ad-ids.
      await _applyPrivacyAndInitNative();
    }
  }

  /// PUBLIC: invoked by your OneTrust UI when the user chooses an option.
  /// This is the main entry point for the two-layer flow.
  Future<void> handleOneTrustDecision(bool granted) async {
    // Persist OneTrust decision immediately.
    await _prefs?.setBool('one_trust_consent', granted);
    setState(() => _oneTrustConsent = granted);

    if (!granted) {
      // 1) OneTrust denied -> treat as denied; DO NOT show ATT prompt.
      // Apply privacy-mode init so SDK does not collect identifiers.
      await _applyPrivacyAndInitNative();
      // effective final consent remains false
      await _prefs?.setBool('final_consent', false);
      setState(() => _finalConsent = false);
      // Do not init plugin-level analytics; continue buffering.
      _afPluginInitialized = false;
      return;
    }

    // 2) OneTrust granted -> proceed to ATT (iOS) or treat as granted (Android)
    await _evaluateAttIfNeededAndApply();
  }

  /// If platform is iOS, request ATT and set final consent only if ATT authorized.
  /// On Android, consider OneTrust = final consent granted (no ATT).
  Future<void> _evaluateAttIfNeededAndApply() async {
    if (Platform.isIOS) {
      // Request App Tracking Transparency authorization. The plugin shows system dialog.
      try {
        final status = await AppTrackingTransparency.requestTrackingAuthorization();
        final bool attAuthorized = status == TrackingStatus.authorized;

        // Save final result and apply the corresponding flow.
        await _prefs?.setBool('final_consent', attAuthorized);
        setState(() => _finalConsent = attAuthorized);

        if (attAuthorized) {
          // ATT authorized -> revoke native privacy, init normal flows
          await _revokePrivacyAndInitNative();
          // initialize plugin-level AppsFlyer and flush buffered events
          await _initAppsFlyerPluginAndFlush();
        } else {
          // ATT denied/restricted -> treat as denied: apply privacy-mode init (no IDs)
          await _applyPrivacyAndInitNative();
          _afPluginInitialized = false;
        }
      } on PlatformException catch (e) {
        // If the ATT plugin call fails unexpectedly, fallback to privacy-mode init
        debugPrint('ATT request failed: ${e.message} — falling back to privacy-mode');
        await _applyPrivacyAndInitNative();
        setState(() => _finalConsent = false);
        await _prefs?.setBool('final_consent', false);
      }
    } else {
      // Android (or other): treat OneTrust = final consent granted (no ATT).
      await _prefs?.setBool('final_consent', true);
      setState(() => _finalConsent = true);

      // Revoke native privacy (re-enable ad-id collection) and init normally
      await _revokePrivacyAndInitNative();
      await _initAppsFlyerPluginAndFlush();
    }
  }

  /// Initialize the AppsFlyer plugin (Dart side) and flush buffered events.
  /// Only call this when final consent is true.
  Future<void> _initAppsFlyerPluginAndFlush() async {
    if (_afPluginInitialized) return;
    try {
      await _afSdk.initSdk(
        registerConversionDataCallback: true,
        registerOnAppOpenAttributionCallback: true,
      );
      _afPluginInitialized = true;
      await _flushBufferedEvents();
      debugPrint('AppsFlyer plugin initialized (Dart).');
    } catch (e) {
      debugPrint('AppsFlyer plugin init error: $e');
    }
  }

  /// Flush buffered events. Only send if final consent & plugin initialized.
  Future<void> _flushBufferedEvents() async {
    if (!_finalConsent || !_afPluginInitialized) return;
    final copy = List<Map<String, dynamic>>.from(_eventBuffer);
    for (final ev in copy) {
      try {
        await _afSdk.logEvent(ev['name'] as String, ev['params'] as Map<String, dynamic>);
        _eventBuffer.remove(ev);
      } catch (e) {
        debugPrint('Flush error: $e');
        break; // stop on first failure
      }
    }
  }

  /// Buffer events when consent is not granted; strip obvious PII first.
  Future<void> trackEvent(String name, Map<String, dynamic> params) async {
    if (_finalConsent && _afPluginInitialized) {
      await _afSdk.logEvent(name, params);
      debugPrint('Event sent: $name');
    } else {
      final safe = _stripPii(params);
      _eventBuffer.add({'name': name, 'params': safe, 'ts': DateTime.now().toIso8601String()});
      debugPrint('Event buffered (PII stripped): $name -> $safe');
    }
  }

  /// Remove common PII keys before buffering.
  Map<String, dynamic> _stripPii(Map<String, dynamic> params) {
    final safe = Map<String, dynamic>.from(params);
    final piiKeys = ['email', 'phone', 'user_id', 'customer_id'];
    safe.removeWhere((k, _) => piiKeys.contains(k.toLowerCase()));
    return safe;
  }

  /// DART -> native: disable ad-id collection and start native SDK in privacy-mode.
  /// Native must start SDK without anonymizing (so referrer/SKAdNetwork capture still happens).
  Future<void> _applyPrivacyAndInitNative() async {
    try {
      await _afChannel.invokeMethod('applyPrivacyAndInit');
      debugPrint('Native applyPrivacyAndInit invoked');
    } on PlatformException catch (e) {
      debugPrint('applyPrivacyAndInit failed: ${e.message}');
    }
  }

  /// DART -> native: re-enable ad-id collection and start native SDK normally.
  Future<void> _revokePrivacyAndInitNative() async {
    try {
      await _afChannel.invokeMethod('revokePrivacyAndInit');
      debugPrint('Native revokePrivacyAndInit invoked');
    } on PlatformException catch (e) {
      debugPrint('revokePrivacyAndInit failed: ${e.message}');
    }
  }

  /// UI helper: clear stored consent for testing.
  Future<void> _clearStored() async {
    await _prefs?.remove('one_trust_consent');
    await _prefs?.remove('final_consent');
    setState(() {
      _oneTrustConsent = false;
      _finalConsent = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    // Minimal UI to simulate OneTrust choices and show current state.
    // Replace with real OneTrust integration UI or SDK call.
    return MaterialApp(
      title: 'AF Consent (OneTrust + ATT) Demo',
      home: Scaffold(
        appBar: AppBar(title: const Text('OneTrust + ATT Consent Flow')),
        body: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('OneTrust consent: ${_oneTrustConsent ? 'GRANTED' : 'DENIED'}'),
              const SizedBox(height: 6),
              Text('Final consent (after ATT if iOS): ${_finalConsent ? 'GRANTED' : 'DENIED'}'),
              const SizedBox(height: 16),
              const Text('Simulate OneTrust decision:'),
              const SizedBox(height: 8),
              Row(
                children: [
                  ElevatedButton(
                      onPressed: () async {
                        // Simulate OneTrust GRANT: start second-layer evaluation (ATT on iOS)
                        await handleOneTrustDecision(true);
                      },
                      child: const Text('OneTrust: Grant')),
                  const SizedBox(width: 12),
                  ElevatedButton(
                      onPressed: () async {
                        // Simulate OneTrust DENY: directly apply privacy-mode init
                        await handleOneTrustDecision(false);
                      },
                      child: const Text('OneTrust: Deny')),
                ],
              ),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: () => trackEvent('purchase', {'value': 9.99, 'currency': 'GBP', 'email': 'a@b.com'}),
                child: const Text('Track purchase (contains PII)'),
              ),
              const SizedBox(height: 8),
              ElevatedButton(
                onPressed: () => trackEvent('view_item', {'item_id': 'sku-123', 'category': 'glasses'}),
                child: const Text('Track view_item (no PII)'),
              ),
              const SizedBox(height: 16),
              Text('Buffered events: ${_eventBuffer.length}'),
              const SizedBox(height: 8),
              Expanded(child: SingleChildScrollView(child: Text(_eventBuffer.toString()))),
              const SizedBox(height: 12),
              Row(
                children: [
                  ElevatedButton(onPressed: _clearStored, child: const Text('Clear stored consent (debug)')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
