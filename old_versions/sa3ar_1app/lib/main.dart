// Sa3ar: Egyptian Multi-Store Price Tracker (CN3071)
// Live prices: GPU/CPU/RAM (price-engine.com), gift cards and recharge
// (egyptgamestore.com, games2egypt.com, shop.carry1st.com). Fetched on every app
// open and every 15 minutes while open. See the Sources tab for fetch status.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'core.dart';
import 'live.dart';

export 'core.dart';
export 'live.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const Sa3arApp());
}

// ===========================================================================
// PART 4 | TECH LEAD (Ahmed): app state, live refresh, history, alerts
// ===========================================================================
class AppState extends ChangeNotifier {
  final bool live;
  AppState({this.live = true});

  List<Product> products = [];
  SearchEngine engine = SearchEngine(const []);
  bool loading = true, refreshing = false, demo = true;
  PayMethod method = PayMethod.card;
  final Map<String, double> targets = {};
  final Map<String, SourceStatus> status = {};
  DateTime? lastUpdated;
  void Function(String)? onAlert;
  final LiveRepository repo = LiveRepository();
  Map<String, List<double>> histories = {};
  final Set<String> _alerted = {};
  Timer? _timer;
  final List<Listing> _listings = [];
  final List<Listing> _extra = []; // results from on-demand Amazon EG / Noon EG searches
  bool searchingOnline = false;

  void initDemo() {
    products = buildCatalog();
    engine = SearchEngine(products);
    loading = false;
    demo = true;
    notifyListeners();
  }

  /// Runs every time the app opens: show cached prices at once, then fetch fresh ones.
  Future<void> init() async {
    final cached = await repo.loadCache();
    histories = await repo.loadHistories();
    await repo.loadImages();
    targets
      ..clear()
      ..addAll(await repo.loadTargets());
    lastUpdated = await repo.loadUpdated();
    if (cached.isNotEmpty) {
      _rebuild(cached);
      demo = false;
    } else {
      initDemo();
    }
    loading = false;
    notifyListeners();
    unawaited(refresh());
    _timer = Timer.periodic(const Duration(minutes: 15), (_) => refresh());
  }

  void _rebuild(List<Listing> ls) {
    _listings
      ..clear()
      ..addAll(ls);
    products = ProductMatcher.group([..._listings, ..._extra], histories);
    engine = SearchEngine(products);
  }

  /// Searches Amazon EG and Noon EG for whatever the user typed and adds the results.
  Future<int> searchOnline(String q) async {
    if (!live || searchingOnline) return 0;
    searchingOnline = true;
    notifyListeners();
    var n = 0;
    try {
      final r = await repo.searchOnline(q);
      n = r.length;
      _extra.addAll(r);
      _rebuild(List.of(_listings));
    } catch (e) {
      debugPrint('online search failed: $e');
    }
    searchingOnline = false;
    notifyListeners();
    return n;
  }

  /// Photo for a product: from its store listings, or looked up on Amazon EG / Noon EG.
  Future<String?> imageFor(Product p) async {
    for (final o in p.offers) {
      if (o.imageUrl != null) {
        p.imageUrl = o.imageUrl;
        return o.imageUrl;
      }
    }
    if (!live) return null;
    final u = await repo.imageFor(p.name);
    if (u != null) p.imageUrl = u;
    return u;
  }

  Future<void> refresh() async {
    if (refreshing || !live) return;
    refreshing = true;
    notifyListeners();
    try {
      final res = await repo.refresh((s) {
        status[s.name] = s;
        notifyListeners();
      });
      if (res.isNotEmpty) {
        _rebuild(res);
        _recordHistory();
        demo = false;
        lastUpdated = DateTime.now();
        await repo.saveHistories(histories);
        await repo.saveUpdated(lastUpdated!);
        _fireAlerts();
      }
    } catch (e) {
      debugPrint('refresh failed: $e');
    }
    refreshing = false;
    notifyListeners();
  }

  Future<void> refreshIfStale() async {
    final t = lastUpdated;
    if (t == null || DateTime.now().difference(t).inMinutes >= 10) await refresh();
  }

  void _recordHistory() {
    for (final p in products) {
      final prices = p.offers.where((o) => o.inStock).map((o) => o.base);
      if (prices.isEmpty) continue;
      final best = prices.reduce(math.min);
      final h = histories.putIfAbsent(p.id, () => []);
      if (h.isEmpty || h.last != best) h.add(best);
      if (h.length > 60) h.removeRange(0, h.length - 60);
      p.history
        ..clear()
        ..addAll(h);
    }
  }

  void _fireAlerts() {
    for (final p in products) {
      final m = alertMessage(p);
      if (m != null && _alerted.add('${p.id}|${bestTotal(p)}')) onAlert?.call(m);
    }
  }

  String get statusLine {
    if (!live) return 'Demo data';
    if (demo) return 'Demo data - fetching live prices...';
    final t = lastUpdated;
    if (t == null) return 'Live prices';
    final m = DateTime.now().difference(t).inMinutes;
    return 'Live prices - updated ${m < 1 ? 'just now' : '$m min ago'}';
  }

  void setMethod(PayMethod m) {
    method = m;
    notifyListeners();
  }

  void setTarget(Product p, double t) {
    targets[p.id] = t;
    if (live) repo.saveTargets(targets);
    notifyListeners();
  }

  void removeTarget(Product p) {
    targets.remove(p.id);
    if (live) repo.saveTargets(targets);
    notifyListeners();
  }

  double? bestTotal(Product p) => PriceEngine.best(p, method)?.total(method);

  bool hit(Product p) {
    final t = targets[p.id];
    final b = bestTotal(p);
    return t != null && b != null && b <= t;
  }

  String? alertMessage(Product p) {
    if (!hit(p)) return null;
    return 'Price alert: ${p.name} is now ${egp(bestTotal(p)!)}, '
        'below your ${egp(targets[p.id]!)} target';
  }

  /// Demo helper: drops the cheapest verified seller's price to trigger alerts live.
  void simulateDrop(Product p) {
    final o = p.offers.firstWhere((o) => o.verified, orElse: () => p.offers.first);
    o.base -= math.max(10, (o.base * 0.05).roundToDouble());
    final b = bestTotal(p);
    if (b != null) p.history.add(b);
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

// ===========================================================================
// PART 3 | UI DEVELOPER (Afifi): Flutter screens and widgets
// Light dashboard look: mint gradient, white rounded cards, black pill buttons,
// donut chart for the price breakdown.
// Screens: Welcome/Login, Search, Compare & fees, Alerts (+ Sources for live data)
// ===========================================================================
const kBg = Color(0xFFE9F2E5);
const kBg2 = Color(0xFFF8FBF6);
const kInk = Color(0xFF1B2620);
const kMuted = Color(0xFF7C8A82);
const kSage = Color(0xFF9DBBA2);
const kSageDark = Color(0xFF4F7F5C);
const kSageSoft = Color(0xFFDDEBDF);
const kLav = Color(0xFFC9CBE8);
const kBeige = Color(0xFFE8DCB3);
const kMint = Color(0xFFBFDADA);
const kWarn = Color(0xFFE0736B);

const List<BoxShadow> kShadow = [BoxShadow(color: Color(0x14000000), blurRadius: 18, offset: Offset(0, 6))];

IconData catIcon(String c) {
  switch (c) {
    case 'GPU':
      return Icons.memory;
    case 'CPU':
      return Icons.developer_board;
    case 'RAM':
      return Icons.storage;
    case 'Gift cards':
      return Icons.card_giftcard;
    case 'Top-ups':
      return Icons.sports_esports;
    case 'Recharge':
      return Icons.phone_android;
    default:
      return Icons.shopping_bag;
  }
}

Color catColor(String c) {
  switch (c) {
    case 'GPU':
    case 'Top-ups':
      return kLav;
    case 'CPU':
      return kMint;
    case 'RAM':
    case 'Recharge':
      return kBeige;
    default:
      return kSage;
  }
}

class GradientBg extends StatelessWidget {
  final Widget child;
  const GradientBg({super.key, required this.child});
  @override
  Widget build(BuildContext context) => Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [kBg, kBg2]),
        ),
        child: child,
      );
}

class WhiteCard extends StatelessWidget {
  final Widget child;
  final Color color;
  final EdgeInsets padding;
  final EdgeInsets margin;
  final VoidCallback? onTap;
  const WhiteCard({
    super.key,
    required this.child,
    this.color = Colors.white,
    this.padding = const EdgeInsets.all(16),
    this.margin = EdgeInsets.zero,
    this.onTap,
  });
  @override
  Widget build(BuildContext context) => Container(
        margin: margin,
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(22), boxShadow: kShadow),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(22),
            onTap: onTap,
            child: Padding(padding: padding, child: child),
          ),
        ),
      );
}

class Badge2 extends StatelessWidget {
  final String text;
  final Color bg, fg;
  const Badge2(this.text, this.bg, this.fg, {super.key});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
        child: Text(text, style: TextStyle(color: fg, fontSize: 10, fontWeight: FontWeight.w700)),
      );
}

class Choice extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const Choice({super.key, required this.label, required this.selected, required this.onTap});
  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          margin: const EdgeInsets.only(right: 8),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
          decoration: BoxDecoration(
            color: selected ? kInk : Colors.white,
            borderRadius: BorderRadius.circular(22),
            boxShadow: kShadow,
          ),
          child: Text(label,
              style: TextStyle(color: selected ? Colors.white : kInk, fontWeight: FontWeight.w600, fontSize: 13)),
        ),
      );
}

class PayMethodChips extends StatelessWidget {
  final AppState state;
  const PayMethodChips(this.state, {super.key});
  @override
  Widget build(BuildContext context) => SizedBox(
        height: 46,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
          children: [
            for (final m in PayMethod.values)
              Choice(label: m.label, selected: state.method == m, onTap: () => state.setMethod(m)),
          ],
        ),
      );
}

class Sparkline extends CustomPainter {
  final List<double> v;
  Sparkline(this.v);
  @override
  void paint(Canvas canvas, Size size) {
    if (v.length < 2) return;
    final lo = v.reduce(math.min), hi = v.reduce(math.max);
    final span = (hi - lo) == 0 ? 1.0 : hi - lo;
    final path = Path();
    for (var i = 0; i < v.length; i++) {
      final x = size.width * i / (v.length - 1);
      final y = size.height - (v[i] - lo) / span * size.height * 0.8 - size.height * 0.1;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(
        path,
        Paint()
          ..color = kSageDark
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..strokeJoin = StrokeJoin.round);
  }

  @override
  bool shouldRepaint(covariant Sparkline old) => true;
}

class DonutPainter extends CustomPainter {
  final List<double> values;
  final List<Color> colors;
  DonutPainter(this.values, this.colors);
  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 16.0;
    final rect = Rect.fromLTWH(0, 0, size.width, size.height).deflate(stroke / 2);
    final total = values.fold<double>(0, (a, b) => a + b);
    final base = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = const Color(0xFFEEF3EC);
    canvas.drawArc(rect, 0, math.pi * 2, false, base);
    if (total <= 0) return;
    var start = -math.pi / 2;
    for (var i = 0; i < values.length; i++) {
      if (values[i] <= 0) continue;
      final sweep = math.pi * 2 * values[i] / total;
      canvas.drawArc(
          rect,
          start,
          math.max(0.02, sweep - 0.06),
          false,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = stroke
            ..strokeCap = StrokeCap.round
            ..color = colors[i % colors.length]);
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(covariant DonutPainter old) => true;
}

// ---------------------------------------------------------------------------
// App shell, Welcome / Login, navigation
// ---------------------------------------------------------------------------
class Sa3arApp extends StatefulWidget {
  final bool live;
  const Sa3arApp({super.key, this.live = true});
  @override
  State<Sa3arApp> createState() => _Sa3arAppState();
}

class _Sa3arAppState extends State<Sa3arApp> with WidgetsBindingObserver {
  late final AppState state = AppState(live: widget.live);
  final messengerKey = GlobalKey<ScaffoldMessengerState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    state.onAlert = (m) => messengerKey.currentState?.showSnackBar(SnackBar(content: Text(m)));
    if (widget.live) {
      WebFetchService.instance.init();
      state.init();
    } else {
      state.initDemo();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed && widget.live) state.refreshIfStale();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    state.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Sa3ar',
        debugShowCheckedModeBanner: false,
        scaffoldMessengerKey: messengerKey,
        theme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.light,
          colorScheme: ColorScheme.fromSeed(seedColor: kSage, brightness: Brightness.light),
          scaffoldBackgroundColor: kBg,
          appBarTheme: const AppBarTheme(
            backgroundColor: Colors.transparent,
            elevation: 0,
            scrolledUnderElevation: 0,
            foregroundColor: kInk,
          ),
          navigationBarTheme: const NavigationBarThemeData(backgroundColor: Colors.white, indicatorColor: kSage),
        ),
        home: Builder(
          builder: (ctx) => WelcomeScreen(
            onContinue: () => Navigator.of(ctx).pushReplacement(
              MaterialPageRoute(builder: (_) => Shell(state: state, live: widget.live)),
            ),
          ),
        ),
      );
}

/// Screen 1: Welcome / Login (phone sign-in is a demo; guest mode skips it).
class WelcomeScreen extends StatelessWidget {
  final VoidCallback onContinue;
  const WelcomeScreen({super.key, required this.onContinue});

  @override
  Widget build(BuildContext context) => Scaffold(
        body: GradientBg(
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(children: [
                const Spacer(flex: 2),
                Container(
                  width: 84,
                  height: 84,
                  decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle, boxShadow: kShadow),
                  child: const Icon(Icons.sell_rounded, color: kSageDark, size: 40),
                ),
                const SizedBox(height: 16),
                const Text('Sa3ar', style: TextStyle(fontSize: 40, fontWeight: FontWeight.w800, color: kInk)),
                const SizedBox(height: 8),
                const Text('The real final price,\nacross every store.',
                    textAlign: TextAlign.center, style: TextStyle(fontSize: 16, color: kMuted, height: 1.4)),
                const Spacer(),
                WhiteCard(
                  child: Row(children: [
                    const CircleAvatar(radius: 22, backgroundColor: kLav, child: Icon(Icons.sports_esports, color: kInk)),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('PUBG 660 UC', style: TextStyle(fontWeight: FontWeight.w700, color: kInk)),
                        SizedBox(height: 2),
                        Text('Best overall: Carry1st', style: TextStyle(color: kMuted, fontSize: 12)),
                      ]),
                    ),
                    const Text('EGP 340', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: kInk)),
                  ]),
                ),
                const Spacer(flex: 2),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                        backgroundColor: kInk, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 16), shape: const StadiumBorder()),
                    onPressed: onContinue,
                    child: const Text('Continue with phone'),
                  ),
                ),
                TextButton(
                  onPressed: onContinue,
                  child: const Text('Browse as guest', style: TextStyle(color: kInk, fontWeight: FontWeight.w600)),
                ),
                const SizedBox(height: 12),
              ]),
            ),
          ),
        ),
      );
}

class Shell extends StatefulWidget {
  final AppState state;
  final bool live;
  const Shell({super.key, required this.state, this.live = true});
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int index = 0;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: GradientBg(
          child: SafeArea(
            child: Stack(fit: StackFit.expand, children: [
              IndexedStack(index: index, children: [
                HomeScreen(state: widget.state),
                AlertsScreen(state: widget.state),
                SourcesScreen(state: widget.state),
              ]),
              // Hidden browser used to read JavaScript-rendered store pages.
              if (widget.live)
                Positioned(
                  left: 0,
                  top: 0,
                  width: 1,
                  height: 1,
                  child: Opacity(opacity: 0.01, child: WebFetchService.instance.hostWidget()),
                ),
            ]),
          ),
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: index,
          onDestinationSelected: (i) => setState(() => index = i),
          destinations: const [
            NavigationDestination(icon: Icon(Icons.search), label: 'Search'),
            NavigationDestination(icon: Icon(Icons.notifications_none), label: 'Alerts'),
            NavigationDestination(icon: Icon(Icons.cloud_sync_outlined), label: 'Sources'),
          ],
        ),
      );
}

// ---------------------------------------------------------------------------
// Screen 2: Search
// ---------------------------------------------------------------------------

/// Product photo: uses the store's image, or looks one up on Amazon EG / Noon EG.
class ProductImage extends StatefulWidget {
  final AppState state;
  final Product product;
  final double size;
  final double radius;
  const ProductImage({super.key, required this.state, required this.product, this.size = 52, this.radius = 14});
  @override
  State<ProductImage> createState() => _ProductImageState();
}

class _ProductImageState extends State<ProductImage> {
  String? url;

  @override
  void initState() {
    super.initState();
    url = widget.product.imageUrl;
    if (url == null) _fetch();
  }

  Future<void> _fetch() async {
    final u = await widget.state.imageFor(widget.product);
    if (mounted && u != null) setState(() => url = u);
  }

  Widget _placeholder() => Container(
        width: widget.size,
        height: widget.size,
        color: catColor(widget.product.category),
        child: Icon(catIcon(widget.product.category), color: kInk, size: widget.size * 0.45),
      );

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(widget.radius),
        child: url == null
            ? _placeholder()
            : Container(
                width: widget.size,
                height: widget.size,
                color: Colors.white,
                child: Image.network(
                  url!,
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => _placeholder(),
                  loadingBuilder: (c, child, p) => p == null ? child : _placeholder(),
                ),
              ),
      );
}

class StatCard extends StatelessWidget {
  final IconData icon;
  final String label, value, tag;
  const StatCard({super.key, required this.icon, required this.label, required this.value, required this.tag});
  @override
  Widget build(BuildContext context) => WhiteCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            CircleAvatar(radius: 16, backgroundColor: kSageSoft, child: Icon(icon, size: 18, color: kSageDark)),
            const Spacer(),
            Badge2(tag, kSageSoft, kSageDark),
          ]),
          const SizedBox(height: 12),
          Text(value, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: kInk)),
          Text(label, style: const TextStyle(color: kMuted, fontSize: 12)),
        ]),
      );
}

class HomeScreen extends StatefulWidget {
  final AppState state;
  const HomeScreen({super.key, required this.state});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String query = '';
  String category = 'All';

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: widget.state,
        builder: (context, _) {
          final st = widget.state;
          if (st.loading) return const Center(child: CircularProgressIndicator());
          final catSet = <String>{for (final p in st.products) p.category}.toList()..sort();
          final cats = ['All', ...catSet];
          if (!cats.contains(category)) category = 'All';
          var results = st.engine.search(query);
          if (category != 'All') {
            results = results.where((p) => p.category == category).toList();
          }
          final stores = <String>{for (final p in st.products) for (final o in p.offers) o.store}.length;
          final offers = st.products.fold<int>(0, (a, p) => a + p.offers.length);
          return RefreshIndicator(
            onRefresh: st.live ? st.refresh : () async {},
            child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverToBoxAdapter(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    if (st.refreshing) const LinearProgressIndicator(minHeight: 2),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
                      child: Row(children: [
                        const Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text('Hello, Shopper', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: kInk)),
                            SizedBox(height: 2),
                            Text('Explore live prices across Egyptian stores', style: TextStyle(color: kMuted, fontSize: 13)),
                          ]),
                        ),
                        Container(
                          width: 44,
                          height: 44,
                          decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle, boxShadow: kShadow),
                          child: const Icon(Icons.sell_rounded, color: kSageDark),
                        ),
                      ]),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                      child: Container(
                        height: 54,
                        padding: const EdgeInsets.only(left: 20, right: 6),
                        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(30), boxShadow: kShadow),
                        child: Row(children: [
                          Expanded(
                            child: TextField(
                              onChanged: (v) => setState(() => query = v),
                              decoration: const InputDecoration(
                                border: InputBorder.none,
                                hintText: 'Search RTX 4060, Ryzen, DDR5, Nitro...',
                                hintStyle: TextStyle(color: kMuted, fontSize: 14),
                              ),
                            ),
                          ),
                          Container(
                            width: 42,
                            height: 42,
                            decoration: const BoxDecoration(color: kInk, shape: BoxShape.circle),
                            child: const Icon(Icons.search, color: Colors.white, size: 20),
                          ),
                        ]),
                      ),
                    ),
                    SizedBox(
                      height: 46,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
                        children: [
                          for (final c in cats) Choice(label: c, selected: category == c, onTap: () => setState(() => category = c)),
                        ],
                      ),
                    ),
                    const Padding(
                      padding: EdgeInsets.fromLTRB(20, 6, 20, 0),
                      child: Text('Pay with', style: TextStyle(color: kMuted, fontSize: 12)),
                    ),
                    PayMethodChips(st),
                    if (query.trim().length >= 3)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                        child: WhiteCard(
                          color: kSageSoft,
                          child: Row(children: [
                            const Icon(Icons.travel_explore, color: kSageDark),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text('Search Amazon EG and Noon EG for "${query.trim()}"',
                                  style: const TextStyle(fontWeight: FontWeight.w600, color: kInk, fontSize: 13)),
                            ),
                            const SizedBox(width: 8),
                            st.searchingOnline
                                ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                                : FilledButton(
                                    style: FilledButton.styleFrom(backgroundColor: kInk, foregroundColor: Colors.white, shape: const StadiumBorder()),
                                    onPressed: st.live
                                        ? () async {
                                            final n = await st.searchOnline(query.trim());
                                            if (!context.mounted) return;
                                            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                                                content: Text(n == 0
                                                    ? 'No results from Amazon EG or Noon EG (they may be blocking the app)'
                                                    : 'Added $n results from Amazon EG and Noon EG')));
                                          }
                                        : null,
                                    child: const Text('Search'),
                                  ),
                          ]),
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                      child: Row(children: [
                        Expanded(child: StatCard(icon: Icons.inventory_2_outlined, label: 'Products tracked', value: '${st.products.length}', tag: st.demo ? 'demo' : 'live')),
                        const SizedBox(width: 12),
                        Expanded(child: StatCard(icon: Icons.store_mall_directory_outlined, label: 'Stores compared', value: '$stores', tag: '$offers offers')),
                      ]),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
                      child: Row(children: [
                        const Text('Best deals', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: kInk)),
                        const Spacer(),
                        Text('${results.length} products', style: const TextStyle(color: kMuted, fontSize: 12)),
                      ]),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
                      child: Text(st.statusLine, style: const TextStyle(color: kMuted, fontSize: 11)),
                    ),
                  ]),
                ),
                if (results.isEmpty)
                  const SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.all(40),
                      child: Center(child: Text('No results', style: TextStyle(color: kMuted))),
                    ),
                  )
                else
                  SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (context, i) => ProductTile(state: st, product: results[i]),
                      childCount: results.length,
                    ),
                  ),
                const SliverToBoxAdapter(child: SizedBox(height: 24)),
              ],
            ),
          );
        },
      );
}

class ProductTile extends StatelessWidget {
  final AppState state;
  final Product product;
  const ProductTile({super.key, required this.state, required this.product});

  @override
  Widget build(BuildContext context) {
    final best = PriceEngine.best(product, state.method);
    return WhiteCard(
      margin: const EdgeInsets.fromLTRB(16, 6, 16, 6),
      onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ProductScreen(state: state, product: product))),
      child: Row(children: [
        ProductImage(state: state, product: product, size: 52),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(product.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15, color: kInk)),
            const SizedBox(height: 2),
            Text('${product.category} · ${product.offers.length} stores', style: const TextStyle(color: kMuted, fontSize: 12)),
          ]),
        ),
        const SizedBox(width: 8),
        if (best == null)
          Text('Not available\nwith ${state.method.label}', textAlign: TextAlign.end, style: const TextStyle(color: kMuted, fontSize: 11))
        else
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(egp(best.total(state.method)), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: kInk)),
            SizedBox(width: 90, child: Text(best.store, textAlign: TextAlign.end, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: kMuted, fontSize: 11))),
          ]),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Screen 3: Compare & fees
// ---------------------------------------------------------------------------
class ProductScreen extends StatelessWidget {
  final AppState state;
  final Product product;
  const ProductScreen({super.key, required this.state, required this.product});

  Widget _legend(Color c, String l, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(children: [
          Container(width: 10, height: 10, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
          const SizedBox(width: 8),
          Expanded(child: Text(l, style: const TextStyle(color: kMuted, fontSize: 12))),
          Text(v, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: kInk)),
        ]),
      );

  Widget _breakdown(Offer best, PayMethod m) {
    final fee = best.fees[m] ?? 0;
    final promo = best.promos[m] ?? 0;
    return WhiteCard(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text('Price breakdown', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: kInk)),
          const Spacer(),
          Badge2(best.store, kSageSoft, kSageDark),
        ]),
        const SizedBox(height: 14),
        Row(children: [
          SizedBox(
            width: 130,
            height: 130,
            child: Stack(alignment: Alignment.center, children: [
              CustomPaint(size: const Size(130, 130), painter: DonutPainter([best.base, fee, best.shipping], const [kSage, kLav, kBeige])),
              Column(mainAxisSize: MainAxisSize.min, children: [
                Text(egp(best.total(m)), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: kInk)),
                const Text('Final total', style: TextStyle(color: kMuted, fontSize: 10)),
              ]),
            ]),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(children: [
              _legend(kSage, 'Base price', egp(best.base)),
              _legend(kLav, '${m.label} fee', egp(fee)),
              _legend(kBeige, 'Shipping', egp(best.shipping)),
              _legend(kMint, 'Promo', '- ${egp(promo)}'),
            ]),
          ),
        ]),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: state,
        builder: (context, _) {
          final m = state.method;
          final ranked = PriceEngine.rank(product, m);
          final best = ranked.isEmpty ? null : ranked.first;
          final sticker = ranked.isEmpty ? null : ranked.map((o) => o.base).reduce(math.min);
          final tie = ranked.length > 1 && (ranked[0].total(m) - ranked[1].total(m)).abs() < 0.01;
          return Scaffold(
            appBar: AppBar(
              title: Text(product.name, style: const TextStyle(fontWeight: FontWeight.w700)),
              actions: [
                IconButton(
                  icon: Icon(state.targets.containsKey(product.id) ? Icons.notifications_active : Icons.notifications_none),
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => SetAlertScreen(state: state, product: product))),
                ),
              ],
            ),
            body: GradientBg(
              child: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 4, 20, 0),
                  child: Text('Pay with', style: TextStyle(color: kMuted, fontSize: 12)),
                ),
                PayMethodChips(state),
                WhiteCard(
                  margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: Center(child: ProductImage(state: state, product: product, size: 150, radius: 18)),
                ),
                if (best != null) _breakdown(best, m),
                if (best != null && sticker != null && sticker < best.total(m) - 0.01)
                  WhiteCard(
                    color: kBeige,
                    margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    child: Text('Lowest sticker price: ${egp(sticker)}. Real best price after fees: ${egp(best.total(m))}.',
                        style: const TextStyle(color: kInk, fontWeight: FontWeight.w700)),
                  ),
                if (best != null)
                  WhiteCard(
                    color: kSageSoft,
                    margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    child: Text(
                        tie ? 'Same total. ${best.store} wins on trust and delivery speed.' : '${best.store} has the lowest final price.',
                        style: const TextStyle(color: kInk, fontWeight: FontWeight.w700)),
                  ),
                WhiteCard(
                  margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Price history ${state.demo ? '(demo data)' : '(recorded by the app)'}', style: const TextStyle(color: kMuted, fontSize: 12)),
                    const SizedBox(height: 12),
                    SizedBox(height: 80, width: double.infinity, child: CustomPaint(painter: Sparkline(product.history))),
                  ]),
                ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 16, 20, 0),
                  child: Text('Stores ranked by final price', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: kInk)),
                ),
                if (ranked.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text('No store accepts ${m.label} for this item.', style: const TextStyle(color: kMuted)),
                  ),
                for (final o in ranked) OfferCard(offer: o, method: m, isBest: o == best),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(backgroundColor: kInk, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 14), shape: const StadiumBorder()),
                    icon: const Icon(Icons.trending_down),
                    label: const Text('Simulate price drop (demo)'),
                    onPressed: () {
                      state.simulateDrop(product);
                      final msg = state.alertMessage(product);
                      if (msg != null) {
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
                      }
                    },
                  ),
                ),
              ]),
            ),
          );
        },
      );
}

class OfferCard extends StatelessWidget {
  final Offer offer;
  final PayMethod method;
  final bool isBest;
  const OfferCard({super.key, required this.offer, required this.method, required this.isBest});

  Widget _row(String label, double value) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(label, style: const TextStyle(color: kMuted)),
          Text(value < 0 ? '- ${egp(-value)}' : egp(value), style: const TextStyle(color: kInk, fontWeight: FontWeight.w600)),
        ]),
      );

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        decoration: BoxDecoration(color: isBest ? kSageSoft : Colors.white, borderRadius: BorderRadius.circular(22), boxShadow: kShadow),
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            shape: const Border(),
            collapsedShape: const Border(),
            title: Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
              Text(offer.store, style: const TextStyle(fontWeight: FontWeight.w700, color: kInk)),
              offer.verified ? const Badge2('VERIFIED', kSageDark, Colors.white) : const Badge2('MARKETPLACE', kBeige, kInk),
              if (isBest) const Badge2('BEST', kInk, Colors.white),
              if (!offer.inStock) const Badge2('OUT OF STOCK', kWarn, Colors.white),
            ]),
            subtitle: Text(offer.title ?? offer.delivery, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: kMuted)),
            trailing: Text(egp(offer.total(method)), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: kInk)),
            children: [
              _row('Base price', offer.base),
              _row('${method.label} fee', offer.fees[method] ?? 0),
              _row('Shipping', offer.shipping),
              _row('Promo / cashback', -(offer.promos[method] ?? 0)),
              if (offer.url != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      icon: const Icon(Icons.open_in_new, size: 18),
                      label: const Text('Open store page'),
                      onPressed: () => launchUrl(Uri.parse(offer.url!), mode: LaunchMode.externalApplication),
                    ),
                  ),
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      );
}

// ---------------------------------------------------------------------------
// Screen 4: Alerts (set an alert + list of alerts)
// ---------------------------------------------------------------------------
class SetAlertScreen extends StatefulWidget {
  final AppState state;
  final Product product;
  const SetAlertScreen({super.key, required this.state, required this.product});
  @override
  State<SetAlertScreen> createState() => _SetAlertScreenState();
}

class _SetAlertScreenState extends State<SetAlertScreen> {
  late final TextEditingController ctrl =
      TextEditingController(text: widget.state.targets[widget.product.id]?.toStringAsFixed(0) ?? '');
  bool push = true;

  @override
  void dispose() {
    ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final st = widget.state;
    final p = widget.product;
    final best = st.bestTotal(p);
    return Scaffold(
      appBar: AppBar(title: const Text('Price alert', style: TextStyle(fontWeight: FontWeight.w700))),
      body: GradientBg(
        child: ListView(padding: const EdgeInsets.all(16), children: [
          WhiteCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(p.name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: kInk)),
              const SizedBox(height: 4),
              const Text('Current best price', style: TextStyle(color: kMuted, fontSize: 12)),
              Text(best == null ? 'n/a' : egp(best), style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w800, color: kInk)),
            ]),
          ),
          const SizedBox(height: 12),
          WhiteCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Target price', style: TextStyle(fontWeight: FontWeight.w700, color: kInk)),
              const SizedBox(height: 8),
              TextField(
                controller: ctrl,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  prefixText: 'EGP ',
                  filled: true,
                  fillColor: kBg2,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                ),
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Push notification'),
                subtitle: const Text('Free'),
                value: push,
                onChanged: (v) => setState(() => push = v),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Row(children: [Text('WhatsApp alert'), SizedBox(width: 8), Badge2('PREMIUM', kBeige, kInk)]),
                value: false,
                onChanged: null,
              ),
            ]),
          ),
          const SizedBox(height: 16),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: kInk, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 16), shape: const StadiumBorder()),
            onPressed: () {
              final t = double.tryParse(ctrl.text);
              if (t == null) return;
              st.setTarget(p, t);
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Alert saved')));
              Navigator.of(context).pop();
            },
            child: const Text('Save alert'),
          ),
          if (st.targets.containsKey(p.id))
            TextButton(
              onPressed: () {
                st.removeTarget(p);
                Navigator.of(context).pop();
              },
              child: const Text('Remove alert', style: TextStyle(color: kWarn)),
            ),
        ]),
      ),
    );
  }
}

class AlertsScreen extends StatelessWidget {
  final AppState state;
  const AlertsScreen({super.key, required this.state});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: state,
        builder: (context, _) {
          final watched = state.products.where((p) => state.targets.containsKey(p.id)).toList();
          return ListView(padding: const EdgeInsets.fromLTRB(0, 16, 0, 24), children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text('Your alerts', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: kInk)),
            ),
            if (watched.isEmpty)
              const WhiteCard(
                margin: EdgeInsets.symmetric(horizontal: 16),
                child: Text('No alerts yet. Open a product and tap the bell.', style: TextStyle(color: kMuted)),
              ),
            for (final p in watched)
              WhiteCard(
                margin: const EdgeInsets.fromLTRB(16, 6, 16, 6),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ProductScreen(state: state, product: p))),
                child: Row(children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(p.name, style: const TextStyle(fontWeight: FontWeight.w700, color: kInk)),
                      const SizedBox(height: 2),
                      Text('Target ${egp(state.targets[p.id]!)} · now ${state.bestTotal(p) == null ? 'n/a' : egp(state.bestTotal(p)!)}',
                          style: const TextStyle(color: kMuted, fontSize: 12)),
                    ]),
                  ),
                  state.hit(p) ? const Badge2('TRIGGERED', kSageDark, Colors.white) : const Badge2('WATCHING', kBeige, kInk),
                ]),
              ),
          ]);
        },
      );
}

// ---------------------------------------------------------------------------
// Sources: shows which live feeds worked
// ---------------------------------------------------------------------------
class SourcesScreen extends StatelessWidget {
  final AppState state;
  const SourcesScreen({super.key, required this.state});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: state,
        builder: (context, _) => ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 24), children: [
          const Text('Live sources', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: kInk)),
          const SizedBox(height: 4),
          Text(state.statusLine, style: const TextStyle(color: kMuted)),
          const SizedBox(height: 12),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: kInk, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 14), shape: const StadiumBorder()),
            icon: const Icon(Icons.refresh),
            label: Text(state.refreshing ? 'Refreshing...' : 'Refresh now'),
            onPressed: state.live && !state.refreshing ? state.refresh : null,
          ),
          const SizedBox(height: 12),
          if (state.status.isEmpty) const Text('No fetch has run yet.', style: TextStyle(color: kMuted)),
          for (final s in state.status.values)
            WhiteCard(
              margin: const EdgeInsets.only(bottom: 10),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(
                  s.state == 'ok' ? Icons.check_circle : (s.state == 'running' ? Icons.hourglass_top : Icons.error_outline),
                  color: s.state == 'ok' ? kSageDark : (s.state == 'running' ? kMuted : kWarn),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(s.name, style: const TextStyle(fontWeight: FontWeight.w700, color: kInk)),
                    Text(
                      '${s.state} | ${s.count} items'
                      '${s.error != null ? '\n${s.error}' : ''}'
                      '${s.note.isNotEmpty ? '\n${s.note}' : ''}',
                      style: const TextStyle(color: kMuted, fontSize: 12),
                    ),
                  ]),
                ),
              ]),
            ),
        ]),
      );
}
