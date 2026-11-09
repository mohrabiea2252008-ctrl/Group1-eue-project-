// PART 4 | TECH LEAD (Ahmed): live price fetching.
// Fetches prices from the web every time the app opens (and every 15 min while
// it is open), turns them into Listings, and caches them on the device.
//
// Two fetchers:
//   HttpFetcher       plain HTTP (fast, works for server-rendered pages)
//   WebFetchService   a hidden WebView that runs the page's JavaScript, so it
//                     works for single-page apps and many bot-protected sites
//
// IMPORTANT: the parsers are generic (JSON-LD, embedded JSON, product cards,
// price-node detection). Check the Sources tab in the app: it shows how many
// items each source returned and why one failed.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/widgets.dart' show Widget, SizedBox;
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as hp;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'core.dart';

// ---------------------------------------------------------------------------
// Fetchers
// ---------------------------------------------------------------------------
abstract class PageFetcher {
  Future<String?> get(String url);
}

class HttpFetcher implements PageFetcher {
  static const ua =
      'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Mobile Safari/537.36';

  @override
  Future<String?> get(String url) async {
    try {
      final r = await http.get(Uri.parse(url), headers: {
        'User-Agent': ua,
        'Accept': 'text/html,application/xhtml+xml',
        'Accept-Language': 'en,ar;q=0.8',
      }).timeout(const Duration(seconds: 20));
      if (r.statusCode != 200) return null;
      return utf8.decode(r.bodyBytes, allowMalformed: true);
    } catch (_) {
      return null;
    }
  }
}

/// Renders pages in a hidden WebView (runs JavaScript) and returns the final HTML.
class WebFetchService implements PageFetcher {
  WebFetchService._();
  static final WebFetchService instance = WebFetchService._();

  WebViewController? _controller;
  Completer<void>? _loaded;
  Future<void> _queue = Future<void>.value();

  void init() {
    if (_controller != null) return;
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(HttpFetcher.ua)
      ..setNavigationDelegate(NavigationDelegate(onPageFinished: (_) {
        if (!(_loaded?.isCompleted ?? true)) _loaded!.complete();
      }));
  }

  /// Put this (1x1 px, invisible) somewhere in the widget tree.
  Widget hostWidget() {
    init();
    return SizedBox(width: 1, height: 1, child: WebViewWidget(controller: _controller!));
  }

  @override
  Future<String?> get(String url) {
    final c = Completer<String?>();
    _queue = _queue.then((_) async {
      c.complete(await _load(url));
    });
    return c.future;
  }

  Future<String?> _load(String url) async {
    final ctl = _controller;
    if (ctl == null) return null;
    try {
      _loaded = Completer<void>();
      await ctl.loadRequest(Uri.parse(url));
      await _loaded!.future.timeout(const Duration(seconds: 30));
      await Future<void>.delayed(const Duration(seconds: 4)); // let JS render
      final r = await ctl.runJavaScriptReturningResult('document.documentElement.outerHTML');
      var s = r.toString();
      if (s.startsWith('"')) s = jsonDecode(s) as String; // Android returns a JSON string
      return s;
    } catch (e) {
      debugPrint('WebView fetch failed for $url: $e');
      return null;
    }
  }
}

// ---------------------------------------------------------------------------
// Extraction helpers
// ---------------------------------------------------------------------------
String latinDigits(String s) {
  const ar = '٠١٢٣٤٥٦٧٨٩';
  var out = s;
  for (var i = 0; i < 10; i++) {
    out = out.replaceAll(ar[i], '$i');
  }
  return out;
}

final RegExp _priceRe = RegExp(
    r'(?<![A-Za-z])(?:EGP|LE|E£)\s*([0-9][0-9,]*(?:\.[0-9]+)?)|([0-9][0-9,]*(?:\.[0-9]+)?)\s*(?:EGP|LE\b|E£|ج\.?\s?م|جنيه)',
    caseSensitive: false);

/// "EGP 4,590", "4590 EGP", "EGP 4590 00" -> 4590. Returns null if no price.
double? parsePrice(String text) {
  final m = _priceRe.firstMatch(latinDigits(text));
  if (m == null) return null;
  final v = double.tryParse((m[1] ?? m[2])!.replaceAll(',', ''));
  if (v == null || v < 5) return null;
  return v;
}

String _ws(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();

final RegExp _oos = RegExp(r'out of stock|sold out|نفذ|نفد|غير متوفر', caseSensitive: false);
final RegExp _oldClass = RegExp(r'(^|[\s_-])(old|was|before|compare|strike|regular|original)([\s_-]|$)', caseSensitive: false);

bool _isOld(dom.Element e) {
  dom.Element? n = e;
  for (var i = 0; i < 4 && n != null; i++) {
    final tag = n.localName ?? '';
    if (tag == 's' || tag == 'del' || tag == 'strike') return true;
    if (_oldClass.hasMatch(n.className)) return true;
    n = n.parent;
  }
  return false;
}


/// First usable <img> inside a card (handles lazy-loading attributes and srcset).
String? _imgOf(dom.Element? card, String pageUrl) {
  if (card == null) return null;
  for (final img in card.querySelectorAll('img')) {
    var src = img.attributes['src'] ?? img.attributes['data-src'] ?? img.attributes['data-lazy-src'] ?? '';
    if (src.isEmpty || src.startsWith('data:')) {
      final ss = img.attributes['srcset'] ?? img.attributes['data-srcset'] ?? '';
      if (ss.isNotEmpty) src = ss.split(',').first.trim().split(' ').first;
    }
    if (src.isEmpty || src.startsWith('data:') || src.endsWith('.svg')) continue;
    try {
      return Uri.parse(pageUrl).resolve(src).toString();
    } catch (_) {}
  }
  return null;
}

/// Image URL from a JSON object (schema.org "image", "imageUrl", Noon "image_key"...).
String? _jsonImage(Map<String, dynamic> m) {
  for (final k in ['image', 'imageUrl', 'image_url', 'thumbnail', 'thumbnailUrl', 'images']) {
    var v = m[k];
    if (v is List && v.isNotEmpty) v = v.first;
    if (v is Map) v = v['url'];
    if (v is String && v.startsWith('http')) return v;
  }
  final key = m['image_key'];
  if (key is String && key.isNotEmpty) return 'https://f.nooncdn.com/p/$key.jpg';
  return null;
}

int _linkCount(dom.Element e, RegExp re) =>
    e.querySelectorAll('a[href]').map((a) => a.attributes['href'] ?? '').where(re.hasMatch).toSet().length;

String _titleFor(dom.Element a, dom.Element card) {
  final cands = <String>[
    a.attributes['title'] ?? '',
    card.querySelector('img')?.attributes['alt'] ?? '',
    card.querySelector('h1,h2,h3,h4,h5')?.text ?? '',
    a.text,
  ];
  for (final c in cands) {
    final t = _ws(c.replaceAll(_priceRe, ''));
    if (t.length >= 4) return t;
  }
  return '';
}

/// Strategy 1: product cards found through product links (e.g. /Product/123/...).
List<Listing> extractCards(dom.Document doc,
    {required String pageUrl,
    required String feed,
    required String store,
    required RegExp productLink,
    String? fallback}) {
  final out = <Listing>[];
  final seen = <String>{};
  for (final a in doc.querySelectorAll('a[href]')) {
    final href = a.attributes['href'] ?? '';
    if (!productLink.hasMatch(href)) continue;
    final url = Uri.parse(pageUrl).resolve(href).toString();
    if (!seen.add(url)) continue;
    dom.Element card = a;
    for (var i = 0; i < 6; i++) {
      final p = card.parent;
      if (p == null || _linkCount(p, productLink) > 1) break;
      card = p;
    }
    final price = parsePrice(card.text);
    if (price == null) continue;
    final title = _titleFor(a, card);
    if (title.isEmpty) continue;
    final cat = Classifier.category(title) ?? fallback;
    if (cat == null) continue;
    out.add(Listing(
        feed: feed,
        store: store,
        title: title,
        url: url,
        category: cat,
        price: price,
        inStock: !_oos.hasMatch(card.text),
        imageUrl: _imgOf(card, pageUrl)));
  }
  return out;
}

/// Strategy 2 (works on unknown layouts): find every price on the page, then
/// walk up to the smallest block that holds exactly one price = one product card.
List<Listing> extractByPriceNodes(dom.Document doc,
    {required String pageUrl,
    required String feed,
    required String store,
    String? fallback,
    bool storeFromHost = false}) {
  final priceNodes = <dom.Element>{};
  for (final e in doc.querySelectorAll('*')) {
    if (e.children.length > 3) continue;
    final t = e.text;
    if (t.length > 40 || parsePrice(t) == null) continue;
    if (e.children.any((c) => parsePrice(c.text) != null)) continue;
    if (_isOld(e)) continue;
    priceNodes.add(e);
  }
  final out = <Listing>[];
  final seen = <String>{};
  final pageHost = Uri.parse(pageUrl).host;
  for (final p in priceNodes) {
    dom.Element card = p;
    for (var i = 0; i < 7; i++) {
      final par = card.parent;
      if (par == null) break;
      if (par.querySelectorAll('*').where(priceNodes.contains).length > 1) break;
      card = par;
    }
    final price = parsePrice(p.text)!;
    final cands = <String>[];
    for (final x in card.querySelectorAll('h1,h2,h3,h4,h5,a,img')) {
      cands.add(x.attributes['title'] ?? '');
      cands.add(x.attributes['alt'] ?? '');
      cands.add(x.text);
    }
    final cleaned = cands.map((c) => _ws(c.replaceAll(_priceRe, ''))).where((c) => c.length >= 8 && c.length <= 200).toList();
    String title = '';
    String? cat;
    for (final c in cleaned) {
      final k = Classifier.category(c);
      if (k != null) {
        title = c;
        cat = k;
        break;
      }
    }
    if (cat == null && fallback != null && cleaned.isNotEmpty) {
      title = cleaned.first;
      cat = fallback;
    }
    if (cat == null) continue;
    var url = pageUrl;
    dom.Element? n = p;
    for (var i = 0; i < 8 && n != null; i++) {
      final h = n.attributes['href'] ?? '';
      if (n.localName == 'a' && h.isNotEmpty && !h.startsWith('#')) {
        url = Uri.parse(pageUrl).resolve(h).toString();
        break;
      }
      n = n.parent;
    }
    if (url == pageUrl) {
      final a = card.querySelector('a[href]');
      final h = a?.attributes['href'] ?? '';
      if (h.isNotEmpty && !h.startsWith('#') && !h.startsWith('javascript')) url = Uri.parse(pageUrl).resolve(h).toString();
    }
    if (!seen.add('$title|$price|$url')) continue;
    final host = Uri.tryParse(url)?.host ?? '';
    final st = storeFromHost && host.isNotEmpty && host != pageHost ? host.replaceFirst('www.', '') : store;
    out.add(Listing(feed: feed, store: st, title: title, url: url, category: cat, price: price, inStock: !_oos.hasMatch(card.text), imageUrl: _imgOf(card, pageUrl)));
  }
  return out;
}

double? _num(dynamic v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v.replaceAll(',', '').trim());
  return null;
}

double? _offerPrice(dynamic o) {
  if (o is List) {
    for (final x in o) {
      final p = _offerPrice(x);
      if (p != null) return p;
    }
    return null;
  }
  if (o is Map) return _num(o['price']) ?? _num(o['lowPrice']);
  return null;
}

void _walk(dynamic n, void Function(Map<String, dynamic>) f) {
  if (n is Map) {
    f(Map<String, dynamic>.from(n));
    for (final v in n.values) {
      _walk(v, f);
    }
  } else if (n is List) {
    for (final v in n) {
      _walk(v, f);
    }
  }
}

/// Strategy 3: JSON-LD (schema.org Product/Offer) and embedded JSON (e.g. Next.js __NEXT_DATA__).
List<Listing> extractJson(dom.Document doc,
    {required String pageUrl, required String feed, required String store, String? fallback, String pageTitle = ''}) {
  final out = <Listing>[];
  final seen = <String>{};
  void add(String name, double price, String? url, bool inStock, [String? image]) {
    final n = _ws(name);
    if (n.length < 3 || price < 5) return;
    var title = n;
    if (pageTitle.isNotEmpty && !n.toLowerCase().contains(pageTitle.toLowerCase().split(' ').first)) title = '$pageTitle $n';
    final cat = Classifier.category(title) ?? fallback;
    if (cat == null) return;
    if (!seen.add('$title|$price')) return;
    out.add(Listing(feed: feed, store: store, title: title, url: url ?? pageUrl, category: cat, price: price, inStock: inStock, imageUrl: image));
  }

  for (final s in doc.querySelectorAll('script')) {
    final type = s.attributes['type'] ?? '';
    final id = s.attributes['id'] ?? '';
    if (!type.contains('json') && id != '__NEXT_DATA__') continue;
    dynamic j;
    try {
      j = jsonDecode(s.text);
    } catch (_) {
      continue;
    }
    _walk(j, (m) {
      final t = m['@type'];
      final isProduct = t == 'Product' || (t is List && t.contains('Product'));
      if (isProduct) {
        final p = _offerPrice(m['offers']);
        if (p != null) {
          final off = m['offers'];
          final av = (off is Map ? off['availability'] : null)?.toString() ?? '';
          add('${m['name'] ?? ''}', p, m['url']?.toString(), !av.contains('OutOfStock'), _jsonImage(m));
        }
        return;
      }
      final name = m['name'] ?? m['title'] ?? m['label'] ?? m['displayName'];
      final price = _num(m['price'] ?? m['sellingPrice'] ?? m['salePrice'] ?? m['amount']);
      if (name is String && price != null) add(name, price, null, m['inStock'] != false && m['available'] != false, _jsonImage(m));
    });
  }
  return out;
}

List<Listing> smartExtract(dom.Document d,
    {required String pageUrl,
    required String feed,
    required String store,
    RegExp? productLink,
    String? fallback,
    bool storeFromHost = false}) {
  if (productLink != null) {
    final r = extractCards(d, pageUrl: pageUrl, feed: feed, store: store, productLink: productLink, fallback: fallback);
    if (r.isNotEmpty) return r;
  }
  final j = extractJson(d, pageUrl: pageUrl, feed: feed, store: store, fallback: fallback);
  if (j.isNotEmpty) return j;
  return extractByPriceNodes(d, pageUrl: pageUrl, feed: feed, store: store, fallback: fallback, storeFromHost: storeFromHost);
}

List<String> discover(dom.Document d, String pageUrl, RegExp match, {int max = 10, RegExp? exclude}) {
  final out = <String>{};
  final base = Uri.parse(pageUrl);
  for (final a in d.querySelectorAll('a[href]')) {
    final href = a.attributes['href'] ?? '';
    if (href.isEmpty || href.startsWith('#') || href.startsWith('javascript')) continue;
    Uri u;
    try {
      u = base.resolve(href);
    } catch (_) {
      continue;
    }
    if (u.host != base.host) continue;
    if (exclude != null && exclude.hasMatch(u.path)) continue;
    if (match.hasMatch('${u.path} ${_ws(a.text)}')) out.add(u.toString().split('#').first);
  }
  return out.take(max).toList();
}

// ---------------------------------------------------------------------------
// Sources
// ---------------------------------------------------------------------------
class SourceStatus {
  final String name;
  String state = 'idle'; // running | ok | no data | error
  int count = 0;
  String? error;
  DateTime? updated;
  String note = '';
  SourceStatus(this.name);
}

class Ctx {
  final PageFetcher http;
  final PageFetcher web;
  String head = '';
  Ctx(this.http, this.web);

  Future<dom.Document?> doc(String url, {bool js = false}) async {
    String? body;
    if (!js) body = await http.get(url);
    if (body == null || body.length < 1500) body = await web.get(url) ?? body;
    if (body == null) return null;
    head = _ws(body.length > 300 ? body.substring(0, 300) : body);
    return hp.parse(body);
  }

  /// Fetch with plain HTTP first; if the parser finds nothing (blocked / JS app) retry in the WebView.
  Future<List<Listing>> scrape(String url, List<Listing> Function(dom.Document) parse, {bool js = false}) async {
    if (!js) {
      final body = await http.get(url);
      if (body != null) {
        head = _ws(body.length > 300 ? body.substring(0, 300) : body);
        final r = parse(hp.parse(body));
        if (r.isNotEmpty) return r;
      }
    }
    final b = await web.get(url);
    if (b == null) return [];
    head = _ws(b.length > 300 ? b.substring(0, 300) : b);
    return parse(hp.parse(b));
  }
}

Future<List<R>> _pooled<T, R>(List<T> items, int size, Future<R> Function(T) f) async {
  final out = <R>[];
  for (var i = 0; i < items.length; i += size) {
    out.addAll(await Future.wait(items.skip(i).take(size).map(f)));
  }
  return out;
}

abstract class LiveSource {
  String get name;
  Future<List<Listing>> fetch(Ctx c);
}

/// Games2Egypt: gift cards, Discord, PSN, Steam... (server-rendered, may need the WebView if blocked).
class Games2EgyptSource extends LiveSource {
  @override
  String get name => 'Games2Egypt';
  static final prod = RegExp(r'/Product/\d+/', caseSensitive: false);
  static const seeds = <String>['https://www.games2egypt.com/Brand/5302/discord'];

  @override
  Future<List<Listing>> fetch(Ctx c) async {
    const home = 'https://www.games2egypt.com/';
    final pages = <String>{...seeds};
    final hd = await c.doc(home);
    if (hd != null) {
      pages.addAll(discover(
          hd,
          home,
          RegExp(r'/(Category|Brand)/\d+/.*(gift|card|digital|psn|steam|xbox|google|itunes|razer|roblox|recharge|topup|top-up)|بطاق|شحن',
              caseSensitive: false),
          max: 12));
    }
    final res = await _pooled<String, List<Listing>>(
        pages.toList(),
        3,
        (p) => c.scrape(p,
            (d) => smartExtract(d, pageUrl: p, feed: name, store: 'Games2Egypt', productLink: prod, fallback: 'Gift cards')));
    return res.expand((e) => e).toList();
  }
}

/// Egypt Game Store: a JavaScript app, so everything goes through the WebView.
class EgyptGameStoreSource extends LiveSource {
  @override
  String get name => 'Egypt Game Store';
  static final prod = RegExp(r'/card/\d+/', caseSensitive: false);
  static const seeds = <String>['https://egyptgamestore.com/', 'https://egyptgamestore.com/card'];

  @override
  Future<List<Listing>> fetch(Ctx c) async {
    final pages = <String>{...seeds};
    final hd = await c.doc(seeds.first, js: true);
    if (hd != null) {
      pages.addAll(discover(hd, seeds.first, RegExp(r'card|categor|gift|recharge|topup|top-up|shop|بطاق|شحن', caseSensitive: false),
          exclude: prod, max: 8));
    }
    final out = <Listing>[];
    for (final p in pages) {
      out.addAll(await c.scrape(
          p, (d) => smartExtract(d, pageUrl: p, feed: name, store: 'Egypt Game Store', productLink: prod, fallback: 'Gift cards'),
          js: true));
    }
    return out;
  }
}

/// Carry1st Egypt: listing pages give product links; each product page gives the denominations/prices.
class Carry1stSource extends LiveSource {
  @override
  String get name => 'Carry1st';
  static final prod = RegExp(r'/product/[^/?#]+');
  static const base = 'https://shop.carry1st.com/ar/EG';
  static const seeds = <String>[
    '$base',
    '$base/products/type/most-popular-today',
    '$base/products/type/Direct_Game_Top_Up',
    '$base/products/type/game-top-up',
    '$base/products/type/lifestyle-entertainment',
    '$base/products/type/prepaid',
  ];

  @override
  Future<List<Listing>> fetch(Ctx c) async {
    final urls = <String>{};
    for (final s in seeds) {
      final d = await c.doc(s);
      if (d == null) continue;
      for (final a in d.querySelectorAll('a[href]')) {
        final h = a.attributes['href'] ?? '';
        if (prod.hasMatch(h)) urls.add(Uri.parse(s).resolve(h).toString());
      }
    }
    final list = urls.take(40).toList();
    final res = await _pooled<String, List<Listing>>(list, 4, (u) async {
      final d = await c.doc(u);
      if (d == null) return <Listing>[];
      final title = _ws(d.querySelector('h1')?.text ?? '');
      var r = extractJson(d, pageUrl: u, feed: name, store: 'Carry1st', fallback: 'Top-ups', pageTitle: title);
      if (r.isEmpty) r = extractByPriceNodes(d, pageUrl: u, feed: name, store: 'Carry1st', fallback: 'Top-ups');
      final og = d.querySelector('meta[property="og:image"]')?.attributes['content'];
      if (og != null && og.isNotEmpty) {
        r = r
            .map((x) => x.imageUrl != null ? x : Listing(feed: x.feed, store: x.store, title: x.title, url: x.url, category: x.category, price: x.price, inStock: x.inStock, imageUrl: og))
            .toList();
      }
      return r;
    });
    return res.expand((e) => e).toList();
  }
}

/// price-engine.com electronics: GPUs, CPUs and RAM. Add real category URLs to [extraSeeds].
class PriceEngineSource extends LiveSource {
  @override
  String get name => 'Price Engine';
  static const home = 'https://price-engine.com/?dept=electronics';
  // Paste the GPU / CPU / RAM listing URLs from price-engine.com here (more pages = more products).
  static const extraSeeds = <String>[];

  @override
  Future<List<Listing>> fetch(Ctx c) async {
    final pages = <String>{home, ...extraSeeds};
    final hd = await c.doc(home);
    if (hd != null) {
      pages.addAll(discover(
          hd, home, RegExp(r'gpu|graphic|video|vga|cpu|processor|ram|memory|rtx|radeon|ryzen|intel|ddr|geforce', caseSensitive: false),
          max: 10));
    }
    final out = <Listing>[];
    for (final p in pages) {
      out.addAll(await c.scrape(p, (d) => smartExtract(d, pageUrl: p, feed: name, store: 'Price Engine', storeFromHost: true)));
    }
    return out;
  }
}


// ---------------------------------------------------------------------------
// Amazon Egypt and Noon Egypt (search pages) + product images
// ---------------------------------------------------------------------------
/// Amazon.eg search results page: title, price, photo and /dp/ link for each result.
List<Listing> parseAmazon(dom.Document d, String pageUrl, {String? fallback}) {
  final out = <Listing>[];
  final seen = <String>{};
  for (final r in d.querySelectorAll('div[data-component-type="s-search-result"]')) {
    final asin = r.attributes['data-asin'] ?? '';
    if (asin.isEmpty || !seen.add(asin)) continue;
    final title = _ws(r.querySelector('h2')?.text ?? '');
    if (title.length < 4) continue;
    final price = parsePrice(r.querySelector('span.a-price span.a-offscreen')?.text ?? r.querySelector('span.a-price')?.text ?? '');
    if (price == null) continue;
    out.add(Listing(
      feed: 'Amazon EG',
      store: 'Amazon EG',
      title: title,
      url: 'https://www.amazon.eg/dp/$asin',
      category: Classifier.category(title) ?? fallback ?? 'Electronics',
      price: price,
      imageUrl: r.querySelector('img.s-image')?.attributes['src'],
    ));
  }
  if (out.isEmpty && d.querySelectorAll('div[data-component-type="s-search-result"]').isEmpty) return [];
  return out;
}

/// Noon.com Egypt search page: reads the product list embedded in __NEXT_DATA__.
List<Listing> parseNoon(dom.Document d, String pageUrl, {String? fallback}) {
  final out = <Listing>[];
  final seen = <String>{};
  for (final sc in d.querySelectorAll('script')) {
    if (sc.attributes['id'] != '__NEXT_DATA__') continue;
    dynamic j;
    try {
      j = jsonDecode(sc.text);
    } catch (_) {
      continue;
    }
    _walk(j, (m) {
      final name = m['name'];
      final sku = m['sku']?.toString();
      final price = _num(m['sale_price']) ?? _num(m['price']);
      if (name is String && sku != null && price != null && price >= 5 && seen.add(sku)) {
        final slug = m['url']?.toString();
        out.add(Listing(
          feed: 'Noon EG',
          store: 'Noon EG',
          title: _ws(name),
          url: slug != null && slug.isNotEmpty
              ? 'https://www.noon.com/egypt-en/$slug/$sku/p/'
              : 'https://www.noon.com/egypt-en/search/?q=${Uri.encodeQueryComponent(name)}',
          category: Classifier.category(name) ?? fallback ?? 'Electronics',
          price: price,
          imageUrl: _jsonImage(m),
        ));
      }
    });
  }
  if (out.isEmpty) return extractByPriceNodes(d, pageUrl: pageUrl, feed: 'Noon EG', store: 'Noon EG', fallback: fallback ?? 'Electronics');
  return out;
}

class AmazonEgyptSource extends LiveSource {
  @override
  String get name => 'Amazon EG';
  static const queries = ['rtx graphics card', 'ryzen processor', 'ddr5 ram', 'gift card', 'playstation controller'];

  @override
  Future<List<Listing>> fetch(Ctx c) async {
    final out = <Listing>[];
    for (final q in queries) {
      final url = 'https://www.amazon.eg/s?k=${Uri.encodeQueryComponent(q)}';
      out.addAll((await c.scrape(url, (d) => parseAmazon(d, url))).take(20));
    }
    return out;
  }
}

class NoonEgyptSource extends LiveSource {
  @override
  String get name => 'Noon EG';
  static const queries = ['rtx graphics card', 'ryzen processor', 'ddr5 ram', 'gift card', 'playstation controller'];

  @override
  Future<List<Listing>> fetch(Ctx c) async {
    final out = <Listing>[];
    for (final q in queries) {
      final url = 'https://www.noon.com/egypt-en/search/?q=${Uri.encodeQueryComponent(q)}';
      out.addAll((await c.scrape(url, (d) => parseNoon(d, url))).take(20));
    }
    return out;
  }
}

// ---------------------------------------------------------------------------
// Repository: refresh, cache, history, alert targets
// ---------------------------------------------------------------------------
class LiveRepository {
  final List<LiveSource> sources = [Games2EgyptSource(), EgyptGameStoreSource(), Carry1stSource(), PriceEngineSource(), AmazonEgyptSource(), NoonEgyptSource()];

  Future<Map<String, List<Listing>>> _cacheMap() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString('listings_v1');
      if (raw == null) return {};
      final m = jsonDecode(raw) as Map<String, dynamic>;
      return {
        for (final e in m.entries)
          e.key: [for (final j in e.value as List) Listing.fromJson(Map<String, dynamic>.from(j as Map))]
      };
    } catch (_) {
      return {};
    }
  }

  // ---- on-demand search and product images (Amazon EG + Noon EG) ----
  Future<List<Listing>> searchOnline(String q) async {
    final ctx = Ctx(HttpFetcher(), WebFetchService.instance);
    final e = Uri.encodeQueryComponent(q);
    final urlA = 'https://www.amazon.eg/s?k=$e';
    final urlN = 'https://www.noon.com/egypt-en/search/?q=$e';
    final res = await Future.wait([
      ctx.scrape(urlA, (d) => parseAmazon(d, urlA)).catchError((_) => <Listing>[]),
      ctx.scrape(urlN, (d) => parseNoon(d, urlN)).catchError((_) => <Listing>[]),
    ]);
    return [...res[0].take(15), ...res[1].take(15)];
  }

  final Map<String, String?> _imgCache = {};
  Future<void> _imgQueue = Future<void>.value();
  int _imgLookups = 0;

  Future<void> loadImages() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString('images_v1');
      if (raw == null) return;
      (jsonDecode(raw) as Map<String, dynamic>).forEach((k, v) => _imgCache[k] = v as String?);
    } catch (_) {}
  }

  /// Looks up a photo for a product by searching Amazon EG / Noon EG.
  /// Only accepts a result whose title shares at least half the words of the query.
  Future<String?> imageFor(String query) {
    final key = query.toLowerCase().trim();
    if (_imgCache.containsKey(key)) return Future.value(_imgCache[key]);
    if (_imgLookups >= 60) return Future.value(null);
    final c = Completer<String?>();
    _imgQueue = _imgQueue.then((_) async {
      if (_imgCache.containsKey(key)) {
        c.complete(_imgCache[key]);
        return;
      }
      _imgLookups++;
      String? url;
      try {
        final want = Classifier.normTokens(query).toSet();
        for (final l in await searchOnline(query)) {
          if (l.imageUrl == null || want.isEmpty) continue;
          final have = Classifier.normTokens(l.title).toSet();
          if (want.intersection(have).length / want.length >= 0.5) {
            url = l.imageUrl;
            break;
          }
        }
      } catch (_) {}
      _imgCache[key] = url;
      try {
        final found = {for (final e in _imgCache.entries) if (e.value != null) e.key: e.value};
        (await SharedPreferences.getInstance()).setString('images_v1', jsonEncode(found));
      } catch (_) {}
      c.complete(url);
      await Future<void>.delayed(const Duration(milliseconds: 600));
    });
    return c.future;
  }

  Future<List<Listing>> loadCache() async => (await _cacheMap()).values.expand((e) => e).toList();

  List<Listing> _dedupe(List<Listing> ls) {
    final seen = <String>{};
    return ls.where((l) => l.price >= 5 && seen.add('${l.store}|${l.title}|${l.url}')).toList();
  }

  Future<List<Listing>> refresh(void Function(SourceStatus) onStatus) async {
    final cache = await _cacheMap();
    final fresh = <String, List<Listing>>{};
    await Future.wait(sources.map((s) async {
      final st = SourceStatus(s.name)..state = 'running';
      onStatus(st);
      final ctx = Ctx(HttpFetcher(), WebFetchService.instance);
      try {
        final r = _dedupe(await s.fetch(ctx).timeout(const Duration(minutes: 4)));
        if (r.isEmpty) {
          st
            ..state = 'no data'
            ..count = (cache[s.name] ?? []).length
            ..note = 'Parser found 0 items (showing cached prices). First bytes seen: ${ctx.head}';
          fresh[s.name] = cache[s.name] ?? [];
        } else {
          st
            ..state = 'ok'
            ..count = r.length
            ..updated = DateTime.now();
          fresh[s.name] = r;
        }
      } catch (e) {
        st
          ..state = 'error'
          ..error = '$e'
          ..count = (cache[s.name] ?? []).length;
        fresh[s.name] = cache[s.name] ?? [];
      }
      onStatus(st);
    }));
    final p = await SharedPreferences.getInstance();
    await p.setString('listings_v1', jsonEncode({for (final e in fresh.entries) e.key: e.value.map((l) => l.toJson()).toList()}));
    return fresh.values.expand((e) => e).toList();
  }

  Future<Map<String, List<double>>> loadHistories() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString('history_v1');
      if (raw == null) return {};
      final m = jsonDecode(raw) as Map<String, dynamic>;
      return {for (final e in m.entries) e.key: [for (final v in e.value as List) (v as num).toDouble()]};
    } catch (_) {
      return {};
    }
  }

  Future<void> saveHistories(Map<String, List<double>> h) async =>
      (await SharedPreferences.getInstance()).setString('history_v1', jsonEncode(h));

  Future<Map<String, double>> loadTargets() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString('targets_v1');
      if (raw == null) return {};
      return (jsonDecode(raw) as Map<String, dynamic>).map((k, v) => MapEntry(k, (v as num).toDouble()));
    } catch (_) {
      return {};
    }
  }

  Future<void> saveTargets(Map<String, double> t) async =>
      (await SharedPreferences.getInstance()).setString('targets_v1', jsonEncode(t));

  Future<DateTime?> loadUpdated() async {
    final raw = (await SharedPreferences.getInstance()).getString('updated_v1');
    return raw == null ? null : DateTime.tryParse(raw);
  }

  Future<void> saveUpdated(DateTime t) async => (await SharedPreferences.getInstance()).setString('updated_v1', t.toIso8601String());
}
