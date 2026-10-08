// Сайт super-market.uz: внешние ссылки, мобильное меню, тарифы из API, оглавление документов,
// масштаб макетов приложений на лендинге.
// Подключается на всех страницах сайта (лендинг и документы). Без зависимостей.
(function () {
  'use strict';

  // Язык страницы — из <html lang>: «uz» (по умолчанию) или «ru». Узбекские страницы лежат на
  // адресах без суффикса (/, /privacy, /offer…), русские — с /ru (/ru, /privacy/ru, /offer/ru…).
  var lang = (document.documentElement.lang || 'uz').toLowerCase().indexOf('ru') === 0 ? 'ru' : 'uz';

  // Все внешние ссылки сайта — здесь (элементы с data-link="<ключ>").
  // Пустая строка — ссылки пока нет: кнопка видна, но ведёт на «#» и помечена aria-disabled.
  var LINKS = {
    login: 'https://store.super-market.uz/',     // «Войти», «Войти в панель»
    register: 'https://store.super-market.uz/',  // «Подключить магазин», «Подключить сеть» (вход по номеру → мастер настройки)
    telegram: 'https://t.me/super_market_support', // поддержка в Telegram (то же, что SUPPORT_URL)
    support: 'tel:+998505764723',  // телефон поддержки в подвале
    offer: lang === 'ru' ? '/offer/ru' : '/offer', // оферта для покупателей (OFFER_URL — узбекская); в подвале ссылки на оферты прямо в HTML
    clientAppStore: '',    // Super Market (покупатели) в App Store
    clientGooglePlay: '',  // Super Market (покупатели) в Google Play, пакет uz.supermarket.sm_client
    courierAppStore: '',   // «SM Курьер» в App Store
    courierGooglePlay: ''  // «SM Курьер» в Google Play
  };

  var TARIFFS_URL = '/api/v1/public/tariffs';

  var isIOS = /iPad|iPhone|iPod/.test(navigator.userAgent) ||
    (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);

  // ---------------------------------------------------------------- ссылки

  function linkFor(key) {
    // «SM Курьер» одной ссылкой: на iPhone — App Store, иначе — Google Play.
    if (key === 'courierApp') {
      return isIOS ? (LINKS.courierAppStore || LINKS.courierGooglePlay) : (LINKS.courierGooglePlay || LINKS.courierAppStore);
    }
    return LINKS[key];
  }

  function applyLinks(root) {
    var els = (root || document).querySelectorAll('[data-link]');
    for (var i = 0; i < els.length; i++) {
      var a = els[i];
      var key = a.getAttribute('data-link');
      if (!(key in LINKS) && key !== 'courierApp') continue;
      var url = linkFor(key);
      if (url) {
        a.setAttribute('href', url);
        a.removeAttribute('aria-disabled');
        if (/^https?:/.test(url) && url.indexOf(location.origin) !== 0 && key !== 'login' && key !== 'register') {
          a.setAttribute('target', '_blank');
          a.setAttribute('rel', 'noopener');
        }
      } else {
        a.setAttribute('href', '#');
        a.setAttribute('aria-disabled', 'true');
      }
    }
  }

  document.addEventListener('click', function (e) {
    var a = e.target.closest && e.target.closest('a[aria-disabled="true"]');
    if (a) e.preventDefault();
  });

  // ---------------------------------------------------------------- меню

  function initMenu() {
    var header = document.querySelector('.site-header');
    var btn = header && header.querySelector('.menu-toggle');
    var menu = document.getElementById('mobile-menu');
    if (!btn || !menu) return;
    var labels = lang === 'uz' ? ['Menyu', 'Menyuni yopish'] : ['Меню', 'Закрыть меню'];

    function set(open) {
      header.classList.toggle('menu-open', open);
      btn.setAttribute('aria-expanded', open ? 'true' : 'false');
      btn.setAttribute('aria-label', labels[open ? 1 : 0]);
    }
    btn.addEventListener('click', function () { set(!header.classList.contains('menu-open')); });
    menu.addEventListener('click', function (e) { if (e.target.closest('a')) set(false); });
    document.addEventListener('keydown', function (e) {
      if (e.key === 'Escape' && header.classList.contains('menu-open')) { set(false); btn.focus(); }
    });
    document.addEventListener('click', function (e) {
      if (header.classList.contains('menu-open') && !header.contains(e.target)) set(false);
    });
    if (window.matchMedia) {
      var mq = window.matchMedia('(min-width: 1200px)');
      var onChange = function () { if (mq.matches) set(false); };
      if (mq.addEventListener) mq.addEventListener('change', onChange); else if (mq.addListener) mq.addListener(onChange);
    }
  }

  // ---------------------------------------------------------------- тарифы

  // GET /api/v1/public/tariffs — открытые тарифы карточками: name, description (на языке
  // запроса), price_uzs за магазин в месяц, order_commission (%), min_stores, recommended,
  // features[{name, included}], limits[{key, value}]. Тарифы и их состав настраивает
  // супер-админ — здесь ничего не зашито.

  function pluralRu(n, one, few, many) {
    var m10 = n % 10, m100 = n % 100;
    if (m10 === 1 && m100 !== 11) return one;
    if (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14)) return few;
    return many;
  }

  var T = {
    ru: {
      cur: 'сум',
      per: 'за магазин в месяц',
      free: 'Бесплатно',
      commission: function (c) { return 'комиссия ' + c + '% с онлайн-заказа'; },
      noCommission: 'без комиссии с заказов',
      best: 'Рекомендуем',
      ctaOne: 'Подключить магазин',
      ctaMany: 'Подключить сеть',
      fromStores: function (n) { return 'для сетей от ' + n + ' ' + pluralRu(n, 'магазина', 'магазинов', 'магазинов'); },
      limits: {
        stores: function (v) { return v === null ? 'Магазинов — без лимита' : v + ' ' + pluralRu(v, 'магазин', 'магазина', 'магазинов'); },
        registers: function (v) { return v === null ? 'кассы без лимита' : v + ' ' + pluralRu(v, 'касса', 'кассы', 'касс'); },
        staff: function (v) { return v === null ? 'сотрудники без лимита' : v + ' ' + pluralRu(v, 'сотрудник', 'сотрудника', 'сотрудников'); }
      },
      base: 'Касса, склад и онлайн-заказы',
      stat: function (price) { return 'от ' + price; },
      statFree: 'Бесплатно',
      statFreeLabel: 'есть бесплатный тариф',
      lead: function (c) { return 'Начните бесплатно — с комиссией ' + c + '% с онлайн-заказа. На платных тарифах комиссии нет. Подключение бесплатное.'; },
      network: function (t) { return 'От ' + t.min + ' ' + pluralRu(t.min, 'магазина', 'магазинов', 'магазинов') + ' — тариф «' + t.name + '»: ' + money(t.price) + ' за магазин в месяц.'; },
      empty: 'Стоимость подключения подскажем в поддержке.',
      ask: 'Написать в Telegram'
    },
    uz: {
      cur: 'so‘m',
      per: 'oyiga bir do‘kon uchun',
      free: 'Bepul',
      commission: function (c) { return 'onlayn buyurtmadan ' + c + '% komissiya'; },
      noCommission: 'buyurtmalardan komissiyasiz',
      best: 'Tavsiya etamiz',
      ctaOne: 'Do‘konni ulash',
      ctaMany: 'Tarmoqni ulash',
      fromStores: function (n) { return n + ' ta va undan ko‘p do‘konli tarmoqlar uchun'; },
      limits: {
        stores: function (v) { return v === null ? 'Do‘konlar — cheklovsiz' : v + ' ta do‘kon'; },
        registers: function (v) { return v === null ? 'kassalar cheklovsiz' : v + ' ta kassa'; },
        staff: function (v) { return v === null ? 'xodimlar cheklovsiz' : v + ' ta xodim'; }
      },
      base: 'Kassa, ombor va onlayn buyurtmalar',
      stat: function (price) { return price + ' dan'; },
      statFree: 'Bepul',
      statFreeLabel: 'bepul tarif bor',
      lead: function (c) { return 'Bepul boshlang — onlayn buyurtmadan ' + c + '% komissiya bilan. Pullik tariflarda komissiya yo‘q. Ulanish bepul.'; },
      network: function (t) { return t.min + ' ta do‘kondan boshlab — «' + t.name + '» tarifi: bir do‘kon uchun oyiga ' + money(t.price) + '.'; },
      empty: 'Ulanish narxini qo‘llab-quvvatlash xizmati aytib beradi.',
      ask: 'Telegram’da yozish'
    }
  }[lang];

  // 149000 → «149 000 сум».
  function money(v) {
    var whole = String(Math.round(v)).replace(/\B(?=(\d{3})+(?!\d))/g, ' ');
    return whole + ' ' + T.cur;
  }

  function num(v) {
    var n = parseFloat(String(v == null ? '' : v).replace(',', '.'));
    return isFinite(n) ? n : NaN;
  }

  function normalize(data) {
    var items = data && Array.isArray(data.items) ? data.items : null;
    if (!items) return null;
    var out = [];
    for (var i = 0; i < items.length; i++) {
      var it = items[i] || {};
      var price = num(it.price_uzs);
      if (!it.name || !isFinite(price) || price < 0) continue;
      var limits = {};
      (it.limits || []).forEach(function (l) { if (l && l.key) limits[l.key] = l.value === null || l.value === undefined ? null : parseInt(l.value, 10); });
      out.push({
        name: String(it.name),
        description: String(it.description || ''),
        price: price,
        commission: num(it.order_commission) || 0,
        min: parseInt(it.min_stores, 10) || 1,
        recommended: !!it.recommended,
        sort: parseInt(it.sort, 10) || 0,
        features: (it.features || []).filter(function (f) { return f && f.included && f.name; }).map(function (f) { return String(f.name); }),
        limits: limits
      });
    }
    out.sort(function (a, b) { return a.sort - b.sort; });
    return out;
  }

  function el(tag, cls, text) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text != null) e.textContent = text;
    return e;
  }

  function check(text) {
    var li = el('li');
    li.innerHTML = '<svg aria-hidden="true"><use href="#i-check"/></svg>';
    li.appendChild(document.createTextNode(text));
    return li;
  }

  function limitsLine(t) {
    var parts = [];
    ['stores', 'registers', 'staff'].forEach(function (k) {
      if (k in t.limits) parts.push(T.limits[k](t.limits[k]));
    });
    if (!parts.length) return '';
    var s = parts.join(', ');
    return s.charAt(0).toUpperCase() + s.slice(1);
  }

  function renderTariffs(items) {
    var box = document.getElementById('tariffs');
    if (!box) return;
    var statWrap = document.querySelector('[data-tariff="stat"]');
    var statEl = document.querySelector('[data-tariff="min-price"]');
    var networkEl = document.querySelector('[data-tariff="network"]');
    var leadEl = document.querySelector('[data-tariff="lead"]');

    box.textContent = '';
    box.setAttribute('data-count', String(Math.min(items.length, 4)));

    if (!items.length) {
      var p = el('p', 'price-note', T.empty + ' ');
      var a = el('a', null, T.ask);
      a.setAttribute('data-link', 'telegram');
      p.appendChild(a);
      box.appendChild(p);
      applyLinks(box);
      if (statWrap) statWrap.hidden = true;
      if (networkEl) networkEl.hidden = true;
      return;
    }

    items.forEach(function (t) {
      var card = el('article', 'price-card' + (t.recommended ? ' price-card--best' : ''));
      var top = el('div', 'price-card__top');
      top.appendChild(el('h3', 'price-card__title', t.name));
      if (t.recommended) top.appendChild(el('span', 'badge', T.best));
      card.appendChild(top);

      var price = el('p', 'price-card__price');
      price.appendChild(el('span', 'price-card__amount', t.price > 0 ? money(t.price) : T.free));
      if (t.price > 0) price.appendChild(el('span', 'price-card__per', T.per));
      card.appendChild(price);
      var terms = [t.commission > 0 ? T.commission(t.commission) : T.noCommission];
      if (t.min > 1) terms.push(T.fromStores(t.min));
      card.appendChild(el('p', 'price-card__terms', terms.join(' · ')));
      if (t.description) card.appendChild(el('p', 'price-card__desc', t.description));
      card.appendChild(document.createElement('hr'));

      var ul = el('ul', 'checks');
      var lim = limitsLine(t);
      if (lim) ul.appendChild(check(lim));
      if (!t.features.length) ul.appendChild(check(T.base));
      t.features.forEach(function (f) { ul.appendChild(check(f)); });
      card.appendChild(ul);

      var cta = el('a', 'button button--lg price-card__cta ' + (t.recommended ? 'button--primary' : 'button--secondary'),
        t.min > 1 ? T.ctaMany : T.ctaOne);
      cta.setAttribute('data-link', 'register');
      card.appendChild(cta);
      box.appendChild(card);
    });
    applyLinks(box);

    var free = items.filter(function (t) { return t.price === 0; })[0];
    var paid = items.filter(function (t) { return t.price > 0; });
    if (statWrap && statEl) {
      statWrap.hidden = false;
      if (free) {
        statEl.textContent = T.statFree;
        var label = statWrap.querySelector('span');
        if (label) label.textContent = T.statFreeLabel;
      } else if (paid.length) {
        statEl.textContent = T.stat(money(Math.min.apply(null, paid.map(function (t) { return t.price; }))));
      }
    }
    if (leadEl && free && free.commission > 0) leadEl.textContent = T.lead(free.commission);

    if (networkEl) {
      var net = items.filter(function (t) { return t.min > 1; })[0];
      networkEl.hidden = !net;
      if (net) networkEl.textContent = T.network(net);
    }
  }

  function loadTariffs() {
    if (!document.getElementById('tariffs') || !window.fetch) return;
    var ctrl = window.AbortController ? new AbortController() : null;
    var timer = ctrl ? setTimeout(function () { ctrl.abort(); }, 8000) : null;
    fetch(TARIFFS_URL, { headers: { Accept: 'application/json', 'Accept-Language': lang }, credentials: 'omit', signal: ctrl ? ctrl.signal : undefined })
      .then(function (res) { if (!res.ok) throw new Error('HTTP ' + res.status); return res.json(); })
      .then(function (data) {
        var items = normalize(data);
        if (items) renderTariffs(items); // иначе остаются статичные карточки из HTML
      })
      .catch(function () { /* оставляем статичные карточки */ })
      .then(function () { if (timer) clearTimeout(timer); });
  }

  // ---------------------------------------------------------------- оглавление документов

  function initToc() {
    var links = document.querySelectorAll('.toc a[href^="#"]');
    if (!links.length) return;
    var items = [];
    for (var i = 0; i < links.length; i++) {
      var h = document.getElementById(decodeURIComponent(links[i].getAttribute('href').slice(1)));
      if (h) items.push({ a: links[i], h: h });
    }
    if (!items.length) return;
    var current = null, queued = false;
    function update() {
      queued = false;
      var header = document.querySelector('.site-header');
      var line = (header ? header.getBoundingClientRect().bottom : 0) + 40;
      var active = items[0];
      for (var j = 0; j < items.length; j++) {
        if (items[j].h.getBoundingClientRect().top <= line) active = items[j]; else break;
      }
      // Долистали до конца — подсвечиваем последний пункт.
      if (window.innerHeight + window.scrollY >= document.documentElement.scrollHeight - 2) active = items[items.length - 1];
      if (active === current) return;
      if (current) current.a.removeAttribute('aria-current');
      active.a.setAttribute('aria-current', 'true');
      current = active;
    }
    function queue() { if (!queued) { queued = true; requestAnimationFrame(update); } }
    window.addEventListener('scroll', queue, { passive: true });
    window.addEventListener('resize', queue);
    update();
  }

  // ---------------------------------------------------------------- макеты приложений (mockups.css)

  // Макет свёрстан в пикселях Figma (--mk-w) и масштабируется под ширину контейнера .mk.
  // CSS считает масштаб сам (container query units); здесь — то же для браузеров без tan()/atan2().
  function initMockups() {
    var boxes = document.querySelectorAll('.mk');
    if (!boxes.length || !('ResizeObserver' in window)) return;
    var ro = new ResizeObserver(function (entries) {
      for (var i = 0; i < entries.length; i++) {
        var box = entries[i].target;
        var w = parseFloat(getComputedStyle(box).getPropertyValue('--mk-w'));
        if (w > 0) box.style.setProperty('--mk-k', String(box.clientWidth / w));
      }
    });
    for (var i = 0; i < boxes.length; i++) ro.observe(boxes[i]);
  }

  applyLinks();
  initMenu();
  loadTariffs();
  initToc();
  initMockups();
})();
