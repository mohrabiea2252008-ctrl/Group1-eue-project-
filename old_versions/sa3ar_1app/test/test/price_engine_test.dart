// PART 5 | QA LEAD (Jo): automated checks. Run with:  flutter test
import 'package:flutter_application_2/core.dart';
import 'package:flutter_application_2/live.dart';
import 'package:flutter_application_2/main.dart' show AppState, Sa3arApp;
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as hp;

Product byId(String id) => buildCatalog().firstWhere((p) => p.id == id);

void main() {
  test('final price formula = base + fee + shipping - promo', () {
    final amazon = byId('ps5').offers.firstWhere((o) => o.store == 'Amazon EG');
    expect(amazon.total(PayMethod.card), 28000);
  });

  test('tie goes to the verified seller (PUBG, card)', () {
    final ranked = PriceEngine.rank(byId('pubg'), PayMethod.card);
    expect(ranked[0].total(PayMethod.card), ranked[1].total(PayMethod.card));
    expect(ranked.first.store, 'Carry1st Shop');
  });

  test('stores that do not accept a payment method are filtered out', () {
    expect(PriceEngine.rank(byId('pubg'), PayMethod.wallet).length, 1);
  });

  test('search tolerates typos and Arabic aliases', () {
    final engine = SearchEngine(buildCatalog());
    expect(engine.search('plastation').first.id, 'ps5');
    expect(engine.search('ببجي').map((p) => p.id), contains('pubg'));
  });

  test('alert triggers only at or below the target', () {
    final s = AppState(live: false)..products = buildCatalog();
    final p = s.products.firstWhere((e) => e.id == 'pubg');
    s.setTarget(p, 345);
    expect(s.hit(p), isTrue);
    s.setTarget(p, 300);
    expect(s.hit(p), isFalse);
  });

  test('prices are parsed from Egyptian formats', () {
    expect(parsePrice('EGP 4,590'), 4590);
    expect(parsePrice('5,899 EGP'), 5899);
    expect(parsePrice('EGP 4590 00'), 4590);
    expect(parsePrice('no price here'), isNull);
  });

  test('classifier sorts GPU / CPU / RAM / gift cards / recharge', () {
    expect(Classifier.category('ASUS Dual GeForce RTX 4060 Ti 8GB'), 'GPU');
    expect(Classifier.category('AMD Ryzen 5 5600X Processor'), 'CPU');
    expect(Classifier.category('Corsair Vengeance 2x16GB DDR5 6000MHz'), 'RAM');
    expect(Classifier.category('Lenovo Legion Laptop RTX 4060'), isNull);
    expect(Classifier.category('Discord Nitro 1 Month'), 'Gift cards');
    expect(Classifier.category('Vodafone Recharge Card 50 EGP'), 'Recharge');
  });

  test('same GPU model from two stores becomes one product with two offers', () {
    final ls = [
      const Listing(feed: 'a', store: 'Sigma', title: 'MSI RTX 4060 Ti Ventus', url: 'u1', category: 'GPU', price: 20000),
      const Listing(feed: 'b', store: 'Badr', title: 'Gigabyte GeForce RTX 4060 Ti Eagle', url: 'u2', category: 'GPU', price: 19500),
    ];
    final ps = ProductMatcher.group(ls, {});
    expect(ps.length, 1);
    expect(ps.first.offers.length, 2);
  });

  test('product cards are extracted from HTML', () {
    final doc = hp.parse('<div><div class="c"><a href="/Product/1/x">Discord Nitro 1 Month</a>'
        '<span>EGP 299</span></div><div class="c"><a href="/Product/2/y">Steam Gift Card</a><span>EGP 1,050</span></div></div>');
    final r = extractCards(doc,
        pageUrl: 'https://www.games2egypt.com/',
        feed: 'f',
        store: 'Games2Egypt',
        productLink: RegExp(r'/Product/\d+/'));
    expect(r.map((l) => l.price), [299, 1050]);
  });


  test('Amazon EG results give title, price, link and photo', () {
    final doc = hp.parse('<div data-component-type="s-search-result" data-asin="B0TEST1234"><h2><a href="/dp/B0TEST1234"><span>MSI GeForce RTX 4060 Ventus 8GB</span></a></h2>'
        '<img class="s-image" src="https://m.media-amazon.com/images/I/test.jpg"/><span class="a-price"><span class="a-offscreen">EGP 15,999.00</span></span></div>');
    final r = parseAmazon(doc, 'https://www.amazon.eg/s?k=rtx');
    expect(r.length, 1);
    expect(r.first.price, 15999);
    expect(r.first.url, 'https://www.amazon.eg/dp/B0TEST1234');
    expect(r.first.imageUrl, 'https://m.media-amazon.com/images/I/test.jpg');
    expect(r.first.category, 'GPU');
  });

  test('Noon EG results are read from the page data, with photo', () {
    final doc = hp.parse('<script id="__NEXT_DATA__" type="application/json">{"props":{"hits":[{"name":"Corsair Vengeance 32GB DDR5 6000MHz","sku":"N123","price":9000,"sale_price":8500,"image_key":"pnsku/N123/v1","url":"corsair-vengeance"}]}}</script>');
    final r = parseNoon(doc, 'https://www.noon.com/egypt-en/search/?q=ram');
    expect(r.length, 1);
    expect(r.first.price, 8500);
    expect(r.first.imageUrl, 'https://f.nooncdn.com/p/pnsku/N123/v1.jpg');
    expect(r.first.category, 'RAM');
  });

  test('product cards keep their photo', () {
    final doc = hp.parse('<div><div><a href="/Product/1/x">Discord Nitro 1 Month</a><img src="/img/nitro.png"/><span>EGP 299</span></div>'
        '<div><a href="/Product/2/y">Steam Gift Card</a><span>EGP 1,050</span></div></div>');
    final r = extractCards(doc, pageUrl: 'https://www.games2egypt.com/', feed: 'f', store: 'Games2Egypt', productLink: RegExp(r'/Product/\d+/'));
    expect(r.first.imageUrl, 'https://www.games2egypt.com/img/nitro.png');
    expect(r.last.imageUrl, isNull);
  });

  testWidgets('welcome screen leads to the search screen (demo mode)', (tester) async {
    await tester.pumpWidget(const Sa3arApp(live: false));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Browse as guest'));
    await tester.pumpAndSettle();
    expect(find.text('Hello, Shopper'), findsOneWidget);
  });
}
