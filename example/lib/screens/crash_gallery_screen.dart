import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:sankofa_flutter/sankofa_flutter.dart';

import '../sankofa_runtime.dart';

/// Sankofa Catch crash gallery — one realistic Flutter crash class per
/// button.  Every event lands in the dashboard's Catch → Issues list
/// with the live Switch + Config snapshot attached (auto-discovered
/// from the Module Registry by `Sankofa.instance.init` in Phase A).
///
/// The gallery is organised into three sections mirroring the Web +
/// Node examples:
///
///   1. Dart runtime errors — uncaught throws, null checks, type casts
///   2. Async / isolate errors — missing await, Future rejections
///   3. Manual captures — `captureException` + `captureMessage` with
///      fingerprints, tags, extra context, and breadcrumbs
///
/// 🚀 Two API patterns are shown side-by-side so you can pick whichever
/// fits your codebase:
///
///   - **Static helpers (Crashlytics-style)** — call from anywhere with
///     no instance plumbing.  The 90% case:
///
///         Sankofa.log('user clicked checkout');
///         Sankofa.setUser(const CatchUserContext(id: 'u1'));
///         Sankofa.captureException(err, stackTrace);
///
///   - **Instance API (Sentry-style)** — for advanced use where you
///     want a custom transport, sample rate, or shutdown lifecycle:
///
///         final c = SankofaCatch.instance;
///         c?.captureException(err, st, CatchCaptureOptions(...));
///
/// Both reach the same singleton — pick by ergonomic preference.
///
/// Uncaught errors ride the `FlutterError.onError` +
/// `PlatformDispatcher.instance.onError` hooks the SDK installs — no
/// try/catch needed for those scenarios.  This file's manual capture
/// scenarios exist BECAUSE the gallery is testing the handled path,
/// not because production apps need to write code like this.
class CrashGalleryScreen extends StatefulWidget {
  const CrashGalleryScreen({super.key});

  @override
  State<CrashGalleryScreen> createState() => _CrashGalleryScreenState();
}

class _CrashGalleryScreenState extends State<CrashGalleryScreen> {
  String _status = 'Waiting for a crash…';

  @override
  void initState() {
    super.initState();
    Sankofa.instance.screen('CrashGalleryScreen');
    // Sticky user + tag context — every event below inherits these,
    // matching the Node / Web example conventions so dashboards look
    // consistent across SDKs.
    //
    // 🚀 Phase A: using the static-helper API (`Sankofa.setUser`,
    // `Sankofa.setTags`) instead of `sankofaCatch().setUser(...)` —
    // works from anywhere in the app with no instance plumbing.
    Sankofa.setUser(const CatchUserContext(
      id: 'usr_demo_42',
      email: 'demo@sankofa.dev',
      username: 'demo',
    ));
    Sankofa.setTags({
      'surface': 'crash-gallery',
      'platform': defaultTargetPlatform.name,
    });
    Sankofa.setExtra('gallery_version', 1);
  }

  // ── Scenarios ─────────────────────────────────────────────────

  List<_Scenario> get _scenarios => [
        // ── Uncaught Dart errors (SDK catches via FlutterError.onError /
        //    PlatformDispatcher.instance.onError). No try/catch here. ──
        _Scenario(
          id: 'null-check',
          title: 'Null check operator used on null',
          detail: "`x!` where x is null — the most common Flutter crash",
          run: () {
            final String? maybeToken = null;
            // ignore: null_check_always_fails
            final token = maybeToken!;
            debugPrint('never reached: $token');
          },
        ),
        _Scenario(
          id: 'late-init',
          title: 'LateInitializationError',
          detail: 'accessing a `late` field before assignment',
          run: () {
            final holder = _LateHolder();
            debugPrint(holder.apiBase);
          },
        ),
        _Scenario(
          id: 'type-error',
          title: 'TypeError: cast failed',
          detail: '`as String` on a dynamic int',
          run: () {
            final dynamic value = 42;
            final name = value as String;
            debugPrint('never reached: $name');
          },
        ),
        _Scenario(
          id: 'range-error',
          title: 'RangeError: index out of range',
          detail: 'list[99] on a 3-element list',
          run: () {
            final items = <String>['a', 'b', 'c'];
            debugPrint(items[99]);
          },
        ),
        _Scenario(
          id: 'format-exception',
          title: 'FormatException: int.parse',
          detail: 'parsing a non-numeric query param',
          run: () {
            final raw = "tomorrow";
            final n = int.parse(raw);
            debugPrint('never reached: $n');
          },
        ),
        _Scenario(
          id: 'stack-overflow',
          title: 'StackOverflowError',
          detail: 'infinite recursion',
          run: () {
            int recurse(int n) => recurse(n + 1);
            recurse(0);
          },
        ),
        _Scenario(
          id: 'assertion-error',
          title: 'AssertionError',
          detail: "assert(false, '...')",
          run: () {
            assert(false, 'invariant violated: cart cannot be empty at checkout');
          },
        ),

        // ── Async / isolate errors ──
        _Scenario(
          id: 'async-throw',
          title: 'Async Future: unhandled error',
          detail: 'future not awaited, error bubbles to PlatformDispatcher',
          run: () {
            // Intentionally not awaited — caught by
            // PlatformDispatcher.instance.onError.
            unawaited(_simulateApiCall());
          },
        ),
        _Scenario(
          id: 'timer-throw',
          title: 'Error inside a Timer callback',
          detail: 'no surrounding try/catch in the callback',
          run: () {
            Timer(const Duration(milliseconds: 100), () {
              throw StateError('background sync hit an invariant violation');
            });
          },
        ),
        _Scenario(
          id: 'widget-build-throw',
          title: 'Throw in widget build()',
          detail: 'rendering error surfaced via FlutterError.onError',
          run: () {
            // Show a route whose build() throws — mirrors a real
            // "red screen of death" scenario.
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const _BuggyScreen()),
            );
          },
        ),

        // ── Manual captures with rich context ──
        _Scenario(
          id: 'crashlytics-style-log',
          title: 'Crashlytics-style log() + manual capture',
          detail: 'shows the new Sankofa.log() ring-buffer + Sankofa.captureException statics',
          run: () {
            // 🚀 Phase A: pure static-helper API.  No `sankofaCatch()`
            // factory, no `instance` lookup — these calls work from
            // anywhere in the app and route to the same singleton the
            // SDK auto-constructed during `Sankofa.instance.init`.
            Sankofa.log('user opened payment flow', category: 'navigation');
            Sankofa.log('cart total: 49.00 USD', category: 'commerce');
            Sankofa.log('tapped pay button', category: 'user-action');
            try {
              throw StateError('payment gateway returned no token');
            } catch (e, st) {
              // The three Sankofa.log() lines above ride along on this
              // event's breadcrumb trail — Crashlytics-equivalent
              // behaviour with one method.
              Sankofa.captureException(e, st);
            }
          },
        ),
        _Scenario(
          id: 'json-parse',
          title: 'SyntaxError: JSON on HTML',
          detail: 'upstream returned HTML where JSON was expected — captured manually',
          run: () {
            const rawBody = '<!DOCTYPE html><html>502 Bad Gateway</html>';
            sankofaCatch().addBreadcrumb(CatchBreadcrumb(
              type: 'http',
              category: 'parse',
              message: 'parsing /api/orders response',
              level: CatchLevel.debug,
              data: {
                'content_type': 'text/html; charset=utf-8',
                'bytes': rawBody.length,
              },
            ));
            try {
              jsonDecode(rawBody);
            } catch (e, st) {
              sankofaCatch().captureException(
                e,
                st,
                const CatchCaptureOptions(
                  level: CatchLevel.error,
                  tags: {'subsystem': 'http-client'},
                  fingerprint: ['http', 'json-parse', 'html-body'],
                  extra: {
                    'content_type': 'text/html; charset=utf-8',
                    'expected': 'application/json',
                  },
                ),
              );
            }
          },
        ),
        _Scenario(
          id: 'custom-error',
          title: 'Custom business error (handled)',
          detail: 'PaymentDeclinedError captured with fingerprint + tags',
          run: () {
            try {
              throw PaymentDeclinedError(
                orderId: 'ord_8x92Lq',
                amountCents: 4900,
                currency: 'USD',
                gateway: 'stripe',
                gatewayCode: 'card_declined',
              );
            } catch (e, st) {
              sankofaCatch().captureException(
                e,
                st,
                const CatchCaptureOptions(
                  level: CatchLevel.warning,
                  fingerprint: ['payment', 'declined', 'stripe'],
                  tags: {'gateway': 'stripe', 'code': 'card_declined'},
                  extra: {'order_id': 'ord_8x92Lq', 'retriable': false},
                ),
              );
            }
          },
        ),
        _Scenario(
          id: 'breadcrumb-trail',
          title: 'Manual breadcrumb trail',
          detail: 'simulated user flow → handled error with rich context',
          run: () {
            final catcher = sankofaCatch();
            catcher.addBreadcrumb(CatchBreadcrumb(
              type: 'ui.click',
              category: 'button',
              message: 'tap #add-to-cart',
              level: CatchLevel.info,
              data: {'sku': 'SKU-A7281', 'variant': 'large'},
            ));
            catcher.addBreadcrumb(CatchBreadcrumb(
              type: 'http',
              category: 'fetch',
              message: 'POST /api/cart',
              level: CatchLevel.info,
              data: {'status': 500, 'duration_ms': 812},
            ));
            catcher.addBreadcrumb(CatchBreadcrumb(
              type: 'ui.transition',
              category: 'router',
              message: 'navigate /checkout → /cart',
              level: CatchLevel.info,
            ));
            try {
              throw StateError('AddToCart failed: upstream returned 500');
            } catch (e, st) {
              catcher.captureException(
                e,
                st,
                const CatchCaptureOptions(
                  level: CatchLevel.error,
                  tags: {'flow': 'add-to-cart', 'retriable': 'true'},
                ),
              );
            }
          },
        ),
        _Scenario(
          id: 'log-warning',
          title: 'captureMessage (no exception)',
          detail: 'warning-level signal with extra context',
          run: () {
            sankofaCatch().captureMessage(
              'user tried to open checkout with empty cart',
              const CatchCaptureOptions(
                level: CatchLevel.warning,
                tags: {'surface': 'checkout', 'issue': 'empty-cart'},
                extra: {'items_in_cart': 0, 'user_segment': 'trial'},
              ),
            );
          },
        ),
        _Scenario(
          id: 'flush-now',
          title: 'flush() — force-send pending',
          detail: 'useful before shutdown so the last event isn\'t lost',
          run: () async {
            await sankofaCatch().flush();
          },
        ),

        // ── Phase B: withScope + beforeSend ──
        // Demonstrate the Sentry-style temporary-scope overlay.  Tags
        // and extras set inside the closure ride on ONLY the capture
        // inside the closure; the global scope (set above via
        // Sankofa.setTags) is untouched.
        _Scenario(
          id: 'phase-b-with-scope',
          title: 'withScope — temporary scope overlay',
          detail: 'tags + level + extras attached to ONE capture only',
          run: () {
            Sankofa.withScope((scope) {
              scope.setTag('checkout_step', 'payment');
              scope.setTag('payment_method', 'stripe');
              scope.setExtra('cart_id', 'cart_8x92Lq');
              scope.setExtra('cart_value_cents', 4900);
              scope.setLevel(CatchLevel.warning);
              scope.setFingerprint(['checkout', 'payment', 'manual']);
              try {
                throw StateError('payment gateway timeout — retried 3x');
              } catch (e, st) {
                // Only this event carries the scope's extras + level.
                Sankofa.captureException(e, st);
              }
            });
            // Subsequent captures lose the scope.
            Sankofa.captureMessage('post-scope event — no checkout_step tag');
          },
        ),
        _Scenario(
          id: 'phase-b-with-scope-nested',
          title: 'withScope — nested scopes',
          detail: 'inner scope inherits + extends the outer scope at capture time',
          run: () {
            Sankofa.withScope((outer) {
              outer.setTag('feature', 'billing');
              outer.setExtra('checkout_session', 'sess_12345');
              Sankofa.withScope((inner) {
                inner.setTag('substep', 'card-validation');
                inner.setExtra('attempt', 2);
                try {
                  throw ArgumentError('invalid card number checksum');
                } catch (e, st) {
                  // This event carries BOTH feature=billing (outer) AND
                  // substep=card-validation (inner).
                  Sankofa.captureException(e, st);
                }
              });
              // After inner scope pops, only outer's tags apply here.
              Sankofa.captureMessage('still in outer scope');
            });
          },
        ),
        _Scenario(
          id: 'phase-b-before-send-info',
          title: 'beforeSend — see SankofaProvider.dart',
          detail: 'beforeSend is wired at init time; see how the example uses it for PII scrubbing',
          run: () {
            // beforeSend is configured at `Sankofa.instance.init(beforeSend: ...)`
            // — see lib/sankofa_runtime.dart in this example.  This
            // scenario just fires an event that the configured hook
            // can choose to scrub or drop.
            Sankofa.captureMessage(
              'sensitive event with email — beforeSend should scrub it',
              const CatchCaptureOptions(
                level: CatchLevel.info,
                extra: {
                  'user_email': 'ada@example.com',
                  'note': 'beforeSend hook can strip user_email here',
                },
              ),
            );
          },
        ),
      ];

  Future<void> _simulateApiCall() async {
    await Future<void>.delayed(const Duration(milliseconds: 40));
    throw HttpException('partner API returned 503 — circuit broken');
  }

  void _run(_Scenario scenario) {
    setState(() => _status = '🚀 Triggering "${scenario.title}"…');
    try {
      final result = scenario.run();
      if (result is Future) {
        result.then(
          (_) => setState(() =>
              _status = '✅ "${scenario.title}" dispatched — see dashboard'),
          onError: (_) => setState(() =>
              _status = '✅ "${scenario.title}" dispatched via rejection'),
        );
      } else {
        setState(() => _status =
            '✅ "${scenario.title}" fired — see dashboard');
      }
    } catch (e) {
      // Sync throws are caught by FlutterError.onError via the SDK.
      // We deliberately don't manually capture here — that would
      // produce a duplicate event.
      setState(() => _status = '💥 "${scenario.title}" threw: $e');
    }
  }

  // ── UI ─────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('🦋 Catch crash gallery'),
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: _scenarios.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (context, i) {
                final s = _scenarios[i];
                return _CrashCard(scenario: s, onTap: () => _run(s));
              },
            ),
          ),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              border: Border(
                top: BorderSide(color: Theme.of(context).dividerColor),
              ),
            ),
            child: Text(
              _status,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

class _Scenario {
  _Scenario({
    required this.id,
    required this.title,
    required this.detail,
    required this.run,
  });
  final String id;
  final String title;
  final String detail;
  final dynamic Function() run;
}

class _CrashCard extends StatelessWidget {
  const _CrashCard({required this.scenario, required this.onTap});
  final _Scenario scenario;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      color: Colors.red.shade50.withOpacity(0.6),
      shape: RoundedRectangleBorder(
        side: BorderSide(color: Colors.red.shade100),
        borderRadius: BorderRadius.circular(10),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                scenario.title,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: Colors.red.shade900,
                    ),
              ),
              const SizedBox(height: 4),
              Text(
                scenario.detail,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Colors.red.shade900.withOpacity(0.7),
                      fontFamily: 'monospace',
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Error types used by the scenarios ────────────────────────────────

class _LateHolder {
  late final String apiBase;
}

class _BuggyScreen extends StatelessWidget {
  const _BuggyScreen();
  @override
  Widget build(BuildContext context) {
    throw FlutterError(
      'BuggyScreen.build() threw — simulated widget-level render failure',
    );
  }
}

class HttpException implements Exception {
  HttpException(this.message);
  final String message;
  @override
  String toString() => 'HttpException: $message';
}

class PaymentDeclinedError implements Exception {
  PaymentDeclinedError({
    required this.orderId,
    required this.amountCents,
    required this.currency,
    required this.gateway,
    required this.gatewayCode,
  });
  final String orderId;
  final int amountCents;
  final String currency;
  final String gateway;
  final String gatewayCode;

  @override
  String toString() =>
      'PaymentDeclinedError: declined by $gateway ($gatewayCode) for order $orderId';
}
