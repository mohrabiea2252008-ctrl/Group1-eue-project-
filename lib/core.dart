import 'dart:math' as math;

enum PayMethod { wallet, instapay, fawry, card }

extension PayMethodLabel on PayMethod {
  String get label {
    switch (this) {
      case PayMethod.wallet:
        return 'Vodafone Cash';
      case PayMethod.instapay:
        return 'InstaPay';
      case PayMethod.fawry:
        return 'Fawry';
      case PayMethod.card:
        return 'Card';
    }
  }
}

class Offer {
  final String store;
  final bool verified;
  double base;
  final double shipping;
  final String delivery;
  final int deliveryRank; // 0 = instant, higher = slower
  final Map<PayMethod, double> fees; // accepted methods -> gateway fee
  final Map<PayMethod, double> promos; // method -> bank/wallet cashback
  final String? title; // listing title from the store (live data)
  final String? url; // direct product page
  final bool inStock;

  Offer({
    required this.store,
    required this.base,
    required this.fees,
    this.verified = true,
    this.shipping = 0,
    this.delivery = 'Instant',
    this.deliveryRank = 0,
    this.promos = const {},
    this.title,
    this.url,
    this.inStock = true,
  });

  bool accepts(PayMethod m) => fees.containsKey(m);

  /// Final Total = Base + Gateway Fee + Shipping - Promo/Cashback
  double total(PayMethod m) =>
      base + (fees[m] ?? 0) + shipping - (promos[m] ?? 0);
}

class Product {
  final String id, name, category;
  final List<String> aliases;
  final List<Offer> offers;
  final List<double> history;
  Product({
    required this.id,
    required this.name,
    required this.category,
    required this.offers,
    required this.history,
    this.aliases = const [],
  });
}

Map<PayMethod, double> _free() =>
    {PayMethod.wallet: 0, PayMethod.instapay: 0, PayMethod.card: 0};

List<Product> buildCatalog() => [
      Product(
        id: 'pubg',
        name: 'PUBG 660 UC',
        category: 'Top-ups',
        aliases: ['pubg mobile uc', 'uc 660', 'ببجي'],
        history: [365, 362, 360, 355, 352, 350, 348, 345, 340],
        offers: [
          Offer(
              store: 'Carry1st Shop',
              base: 325,
              delivery: 'Instant top-up',
              fees: {PayMethod.wallet: 0, PayMethod.instapay: 0, PayMethod.fawry: 5, PayMethod.card: 15}),
          Offer(
              store: 'Third-party store',
              base: 325,
              verified: false,
              delivery: 'Manual SMS code',
              deliveryRank: 2,
              fees: {PayMethod.card: 15, PayMethod.fawry: 10}),
          Offer(
              store: 'EGPStore',
              base: 322,
              shipping: 5,
              delivery: 'Instant code',
              fees: {PayMethod.card: 15, PayMethod.instapay: 0}),
          Offer(
              store: 'Games World',
              base: 330,
              delivery: '1-3 business days',
              deliveryRank: 3,
              fees: {PayMethod.card: 15}),
        ],
      ),
      Product(
        id: 'ff',
        name: 'Free Fire Diamonds',
        category: 'Top-ups',
        aliases: ['ff diamonds', 'free fire', 'فري فاير'],
        history: [210, 208, 205, 205, 200, 199, 199, 195],
        offers: [
          Offer(
              store: 'Carry1st Shop',
              base: 195,
              delivery: 'Instant top-up',
              fees: {..._free(), PayMethod.fawry: 5}),
          Offer(
              store: 'Local key portal',
              base: 190,
              verified: false,
              delivery: 'Code by SMS',
              deliveryRank: 2,
              fees: {PayMethod.card: 12}),
        ],
      ),
      Product(
        id: 'steam',
        name: 'Steam Wallet Card',
        category: 'Gift cards',
        aliases: ['steam gift card', 'steam card', 'ستيم'],
        history: [1120, 1110, 1100, 1090, 1075, 1060, 1050],
        offers: [
          Offer(
              store: 'EGPStore',
              base: 1050,
              delivery: 'Instant code',
              fees: {..._free(), PayMethod.wallet: 2}),
          Offer(
              store: 'Carry1st Shop',
              base: 1090,
              delivery: 'Instant code',
              fees: {..._free(), PayMethod.fawry: 8}),
          Offer(
              store: 'Marketplace keys',
              base: 1020,
              verified: false,
              delivery: 'Code by email',
              deliveryRank: 1,
              fees: {PayMethod.card: 25}),
        ],
      ),
      Product(
        id: 'ps5',
        name: 'PlayStation 5 Slim',
        category: 'Gaming',
        aliases: ['ps5', 'playstation', 'sony console', 'بلايستيشن'],
        history: [29500, 29200, 29000, 28800, 28500, 28500],
        offers: [
          Offer(
              store: 'Amazon EG',
              base: 28500,
              delivery: 'Next-day delivery',
              deliveryRank: 1,
              fees: {PayMethod.card: 0},
              promos: {PayMethod.card: 500}),
          Offer(
              store: 'Games World Egypt',
              base: 27900,
              shipping: 100,
              delivery: '1-3 business days',
              deliveryRank: 3,
              fees: {PayMethod.instapay: 0, PayMethod.card: 0}),
        ],
      ),
      Product(
        id: 'rtx',
        name: 'RTX 4060 Graphics Card',
        category: 'PC & Tech',
        aliases: ['gpu', 'graphics card', 'nvidia', 'كارت شاشة'],
        history: [16400, 16200, 16000, 15900, 15800, 15700],
        offers: [
          Offer(
              store: 'El Badr Group',
              base: 15800,
              shipping: 80,
              delivery: '1-3 business days',
              deliveryRank: 3,
              fees: {PayMethod.instapay: 0, PayMethod.card: 0}),
          Offer(
              store: 'Sigma Computer',
              base: 15500,
              shipping: 100,
              delivery: '1-3 business days',
              deliveryRank: 3,
              fees: {PayMethod.instapay: 0, PayMethod.card: 0}),
          Offer(
              store: 'Maximum Hardware',
              base: 16000,
              delivery: '1-2 business days',
              deliveryRank: 2,
              fees: {PayMethod.card: 0}),
        ],
      ),
      Product(
        id: 'kb',
        name: 'Mechanical Keyboard',
        category: 'PC & Tech',
        aliases: ['keyboard', 'gaming keyboard', 'كيبورد'],
        history: [1650, 1600, 1600, 1550, 1500],
        offers: [
          Offer(
              store: 'Sigma Computer',
              base: 1500,
              shipping: 60,
              delivery: '1-3 business days',
              deliveryRank: 3,
              fees: {PayMethod.instapay: 0, PayMethod.card: 0}),
          Offer(
              store: 'Noon EG',
              base: 1550,
              delivery: 'Express delivery',
              deliveryRank: 1,
              fees: {PayMethod.card: 0, PayMethod.fawry: 10}),
        ],
      ),
      Product(
        id: 'laptop',
        name: 'Lenovo IdeaPad Laptop',
        category: 'Electronics',
        aliases: ['laptop', 'notebook', 'لابتوب'],
        history: [21500, 21200, 21000, 20800, 20500],
        offers: [
          Offer(
              store: 'Amazon EG',
              base: 20500,
              delivery: 'Next-day delivery',
              deliveryRank: 1,
              fees: {PayMethod.card: 0},
              promos: {PayMethod.card: 300}),
          Offer(
              store: 'B.TECH',
              base: 20400,
              delivery: '1-3 business days',
              deliveryRank: 3,
              fees: {PayMethod.card: 0, PayMethod.instapay: 0}),
          Offer(
              store: 'Noon EG',
              base: 20700,
              delivery: 'Express delivery',
              deliveryRank: 1,
              fees: {PayMethod.card: 0, PayMethod.fawry: 10}),
        ],
      ),
    ];

/// Where real store data plugs in (scraper mesh / official APIs).
abstract class PriceSource {
  Future<List<Product>> load();
}

class MockPriceSource implements PriceSource {
  @override
  Future<List<Product>> load() async {
    await Future<void>.delayed(const Duration(milliseconds: 400));
    return buildCatalog();
  }
}

/// Typo-tolerant, multilingual (English + Arabic aliases) product search.
class SearchEngine {
  final List<Product> catalog;
  SearchEngine(this.catalog);

  static final RegExp _junk = RegExp(r'[^a-z0-9\u0600-\u06FF\s]');

  static List<String> tokens(String s) => s
      .toLowerCase()
      .replaceAll(_junk, ' ')
      .split(RegExp(r'\s+'))
      .where((t) => t.isNotEmpty)
      .toList();

  static int _lev(String a, String b) {
    var prev = List<int>.generate(b.length + 1, (i) => i);
    for (var i = 1; i <= a.length; i++) {
      final cur = List<int>.filled(b.length + 1, 0);
      cur[0] = i;
      for (var j = 1; j <= b.length; j++) {
        final cost = a[i - 1] == b[j - 1] ? 0 : 1;
        cur[j] = math.min(math.min(cur[j - 1] + 1, prev[j] + 1), prev[j - 1] + cost);
      }
      prev = cur;
    }
    return prev[b.length];
  }

  static double _match(String q, String t) {
    if (q == t) return 1;
    if (t.startsWith(q)) return 0.85;
    if (q.length >= 3 && t.contains(q)) return 0.6;
    if (q.length >= 4 && _lev(q, t) <= (q.length >= 8 ? 2 : 1)) return 0.7;
    return 0;
  }

  List<Product> search(String query) {
    final qs = tokens(query);
    if (qs.isEmpty) return List.of(catalog);
    final scored = <MapEntry<Product, double>>[];
    for (final p in catalog) {
      final pts = tokens('${p.name} ${p.category} ${p.aliases.join(' ')}');
      var total = 0.0;
      var ok = true;
      for (final q in qs) {
        var best = 0.0;
        for (final t in pts) {
          best = math.max(best, _match(q, t));
        }
        if (best == 0) {
          ok = false;
          break;
        }
        total += best;
      }
      if (ok) scored.add(MapEntry(p, total / qs.length));
    }
    scored.sort((a, b) => b.value.compareTo(a.value));
    return scored.map((e) => e.key).toList();
  }
}

/// Ranks stores by FINAL price; ties go to verified sellers, then faster delivery.
class PriceEngine {
  static List<Offer> rank(Product p, PayMethod m) {
    final list = p.offers.where((o) => o.accepts(m)).toList();
    list.sort((a, b) {
      if (a.inStock != b.inStock) return a.inStock ? -1 : 1;
      final c = a.total(m).compareTo(b.total(m));
      if (c != 0) return c;
      if (a.verified != b.verified) return a.verified ? -1 : 1;
      return a.deliveryRank.compareTo(b.deliveryRank);
    });
    return list;
  }

  static Offer? best(Product p, PayMethod m) {
    final r = rank(p, m);
    return r.isEmpty ? null : r.first;
  }
}

String egp(double v) => 'EGP ${v.toStringAsFixed(v == v.roundToDouble() ? 0 : 1)}';

// ===========================================================================
// LIVE LISTINGS, CLASSIFICATION AND PRODUCT MATCHING
// ===========================================================================
class Listing {
  final String feed, store, title, url, category;
  final double price;
  final bool inStock;
  const Listing({
    required this.feed,
    required this.store,
    required this.title,
    required this.url,
    required this.category,
    required this.price,
    this.inStock = true,
  });

  Map<String, dynamic> toJson() => {
        'feed': feed,
        'store': store,
        'title': title,
        'url': url,
        'category': category,
        'price': price,
        'inStock': inStock,
      };

  factory Listing.fromJson(Map<String, dynamic> j) => Listing(
        feed: j['feed'] as String,
        store: j['store'] as String,
        title: j['title'] as String,
        url: j['url'] as String,
        category: j['category'] as String,
        price: (j['price'] as num).toDouble(),
        inStock: j['inStock'] as bool? ?? true,
      );
}

/// Decides what a listing is (GPU, CPU, RAM, Gift cards, Top-ups, Recharge)
/// and builds a model key so the same product from different stores is merged.
class Classifier {
  static final _gpu = RegExp(r'\b(rtx|gtx|rx|arc)\s?-?(\d{3,4})\s?(ti\s?super|ti|super|xtx|xt|gre)?\b', caseSensitive: false);
  static final _ryzen = RegExp(r'ryzen\s?([3579])\s?-?(\d{4,5}[a-z0-9]*)', caseSensitive: false);
  static final _core = RegExp(r'core\s?(i[3579])\s?-?\s?(\d{4,5}[a-z]*)', caseSensitive: false);
  static final _ultra = RegExp(r'ultra\s?([3579])\s?-?(\d{3}[a-z]*)', caseSensitive: false);
  static final _ddr = RegExp(r'ddr\s?([345])', caseSensitive: false);
  static final _kit = RegExp(r'(\d)\s?x\s?(\d{1,3})\s?gb', caseSensitive: false);
  static final _gb = RegExp(r'(\d{1,3})\s?gb', caseSensitive: false);
  static final _notPart = RegExp(r'laptop|notebook|لابتوب|prebuilt|desktop|gaming pc|all.in.one|monitor|\bcase\b|ssd|nvme');
  static final _recharge = RegExp(
      r'recharge|mobile credit|vodafone|orange|etisalat|\bwe\b|telecom|كارت شحن|شحن رصيد|فودافون|اورانج|أورانج|اتصالات');
  static final _topup = RegExp(
      r'pubg|\buc\b|free fire|diamonds?|mobile legends|call of duty|codm|cod points|valorant|genshin|top.?up|royale pass|robux|coins');
  static final _gift = RegExp(
      r'gift ?card|steam|playstation|psn|xbox|google play|itunes|apple|netflix|spotify|discord|nitro|razer|roblox|fortnite|amazon|nintendo|eshop|بطاقة|هدايا|voucher');

  static String? category(String title) {
    final t = title.toLowerCase();
    if (!_notPart.hasMatch(t)) {
      if (_gpu.hasMatch(t) || t.contains('graphics card') || t.contains('كارت شاشة')) return 'GPU';
      if (_ryzen.hasMatch(t) || _core.hasMatch(t) || _ultra.hasMatch(t)) return 'CPU';
      if (_ddr.hasMatch(t) && _gb.hasMatch(t)) return 'RAM';
    }
    if (_recharge.hasMatch(t)) return 'Recharge';
    if (_topup.hasMatch(t)) return 'Top-ups';
    if (_gift.hasMatch(t)) return 'Gift cards';
    return null;
  }

  /// Same model from different brands/stores -> same key (e.g. "RTX 4060 TI").
  static String? modelKey(String cat, String title) {
    final t = title.toLowerCase();
    if (cat == 'GPU') {
      final m = _gpu.firstMatch(t);
      if (m == null) return null;
      final suffix = m[3] == null ? '' : ' ${m[3]!.replaceAll(RegExp(r'\s+'), ' ')}';
      return '${m[1]} ${m[2]}$suffix'.toUpperCase();
    }
    if (cat == 'CPU') {
      var m = _ryzen.firstMatch(t);
      if (m != null) return 'RYZEN ${m[1]} ${m[2]}'.toUpperCase();
      m = _core.firstMatch(t);
      if (m != null) return 'CORE ${m[1]} ${m[2]}'.toUpperCase();
      m = _ultra.firstMatch(t);
      if (m != null) return 'CORE ULTRA ${m[1]} ${m[2]}'.toUpperCase();
      return null;
    }
    if (cat == 'RAM') {
      final d = _ddr.firstMatch(t);
      if (d == null) return null;
      var gb = 0;
      final k = _kit.firstMatch(t);
      if (k != null) {
        gb = int.parse(k[1]!) * int.parse(k[2]!);
      } else {
        final g = _gb.firstMatch(t);
        if (g == null) return null;
        gb = int.parse(g[1]!);
      }
      return 'DDR${d[1]} ${gb}GB';
    }
    return null;
  }

  static List<String> normTokens(String s) {
    const stop = {'gift', 'card', 'cards', 'digital', 'code', 'voucher', 'the', 'of', 'for'};
    final t = s
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9\u0600-\u06FF\s]'), ' ')
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty && !stop.contains(w))
        .toSet()
        .toList();
    t.sort();
    return t;
  }
}

class StoreProfile {
  static const verifiedStores = {'Games2Egypt', 'Egypt Game Store', 'Carry1st', 'sigma-computer.com', 'amazon.eg', 'noon.com', 'btech.com'};
  static bool isVerified(String store) => verifiedStores.contains(store);

  /// TODO(Ahmed): replace with real gateway fees per store once confirmed.
  static Map<PayMethod, double> fees() =>
      {PayMethod.wallet: 0, PayMethod.instapay: 0, PayMethod.fawry: 0, PayMethod.card: 0};
}

double _jaccard(Set<String> a, Set<String> b) {
  if (a.isEmpty || b.isEmpty) return 0;
  final inter = a.intersection(b).length;
  return inter / (a.length + b.length - inter);
}

/// Product matching: merges listings of the same item across stores.
class ProductMatcher {
  static Offer _toOffer(Listing l) {
    final hw = const {'GPU', 'CPU', 'RAM'}.contains(l.category);
    return Offer(
      store: l.store,
      base: l.price,
      title: l.title,
      url: l.url,
      inStock: l.inStock,
      verified: StoreProfile.isVerified(l.store),
      delivery: hw ? 'Standard delivery' : 'Instant code',
      deliveryRank: hw ? 3 : 0,
      fees: StoreProfile.fees(),
    );
  }

  static List<Product> group(List<Listing> ls, Map<String, List<double>> histories) {
    final groups = <String, List<Listing>>{};
    final names = <String, String>{};
    final tokenSets = <String, Set<String>>{};
    for (final l in ls) {
      final mk = Classifier.modelKey(l.category, l.title);
      String id;
      if (mk != null) {
        id = '${l.category}|$mk';
        names[id] = mk;
      } else {
        final toks = Classifier.normTokens(l.title).toSet();
        id = '${l.category}|${(toks.toList()..sort()).join(' ')}';
        for (final e in tokenSets.entries) {
          if (e.key.startsWith('${l.category}|') && _jaccard(e.value, toks) >= 0.8) {
            id = e.key;
            break;
          }
        }
        tokenSets.putIfAbsent(id, () => toks);
      }
      groups.putIfAbsent(id, () => []).add(l);
    }
    final out = <Product>[];
    groups.forEach((id, items) {
      final titles = items.map((e) => e.title).toList()..sort((a, b) => a.length.compareTo(b.length));
      out.add(Product(
        id: id,
        name: names[id] ?? titles.first,
        category: items.first.category,
        offers: items.map(_toOffer).toList(),
        aliases: titles.toSet().take(12).toList(),
        history: List<double>.from(histories[id] ?? const <double>[]),
      ));
    });
    out.sort((a, b) {
      final c = a.category.compareTo(b.category);
      return c != 0 ? c : a.name.compareTo(b.name);
    });
    return out;
  }
}
