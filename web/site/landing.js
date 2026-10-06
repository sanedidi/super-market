// Сайт super-market.uz: внешние ссылки, мобильное меню, тарифы из API, оглавление документов,
// масштаб макетов приложений на лендинге.
// Подключается на всех страницах сайта (лендинг и документы). Без зависимостей.
(function () {
  'use strict';

  // Все внешние ссылки сайта — здесь (элементы с data-link="<ключ>").
  // Пустая строка — ссылки пока нет: кнопка видна, но ведёт на «#» и помечена aria-disabled.
  var LINKS = {
    login: 'https://store.super-market.uz/',     // «Войти», «Войти в панель»
    register: 'https://store.super-market.uz/',  // «Подключить магазин», «Подключить сеть» (вход по номеру → мастер настройки)
    telegram: 'https://t.me/super_market_support', // поддержка в Telegram (то же, что SUPPORT_URL)
    support: 'tel:+998505764723',  // телефон поддержки в подвале
    offer: '',             // публичная оферта (то же, что OFFER_URL)
    clientAppStore: '',    // Super Market (покупатели) в App Store
    clientGooglePlay: '',  // Super Market (покупатели) в Google Play, пакет uz.supermarket.sm_client
    courierAppStore: '',   // «SM Курьер» в App Store
    courierGooglePlay: ''  // «SM Курьер» в Google Play
  };

  var TARIFFS_URL = '/api/v1/public/tariffs';

  var lang = (document.documentElement.lang || 'ru').toLowerCase().indexOf('uz') === 0 ? 'uz' : 'ru';
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

  function pluralRu(n, one, few, many) {
    var m10 = n % 10, m100 = n % 100;
    if (m10 === 1 && m100 !== 11) return one;
    if (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14)) return few;
    return many;
  }

  var T = {
    ru: {
      per: 'за магазин в месяц',
      best: 'Выгоднее',
      ctaOne: 'Подключить магазин',
      ctaMany: 'Подключить сеть',
      title: function (t) {
        if (t.max === null) return t.min === 1 ? 'Любое число магазинов' : t.min + ' и более магазинов';
        if (t.max === t.min) return t.min + ' ' + pluralRu(t.min, 'магазин', 'магазина', 'магазинов');
        return t.min + '–' + t.max + ' ' + pluralRu(t.max, 'магазин', 'магазина', 'магазинов');
      },
      stat: function (price, from) { return (from ? 'от ' : '') + price; },
      network: function (tiers, base) {
        var parts = tiers.map(function (t) {
          return 'от ' + t.min + ' ' + (t.min % 10 === 1 && t.min % 100 !== 11 ? 'магазина' : 'магазинов') + ' — ' + money(t);
        });
        var s = parts.join(', ') + ' за магазин в месяц вместо ' + money(base) + '.';
        return s.charAt(0).toUpperCase() + s.slice(1);
      },
      empty: 'Стоимость подключения подскажем в поддержке.',
      ask: 'Написать в Telegram'
    },
    uz: {
      per: 'oyiga bir do‘kon uchun',
      best: 'Foydaliroq',
      ctaOne: 'Do‘konni ulash',
      ctaMany: 'Tarmoqni ulash',
      title: function (t) {
        if (t.max === null) return t.min === 1 ? 'Istalgan sondagi do‘kon' : t.min + ' va undan ko‘p do‘kon';
        if (t.max === t.min) return t.min + ' ta do‘kon';
        return t.min + '–' + t.max + ' ta do‘kon';
      },
      stat: function (price, from) { return price + (from ? ' dan' : ''); },
      network: function (tiers, base) {
        return tiers.map(function (t) {
          return t.min + ' ta do‘kondan boshlab — bir do‘kon uchun oyiga ' + money(t);
        }).join(', ') + ' (' + money(base) + ' o‘rniga).';
      },
      empty: 'Ulanish narxini qo‘llab-quvvatlash xizmati aytib beradi.',
      ask: 'Telegram’da yozish'
    }
  }[lang];

  // "20.00" → «20 $», "12.50" → «12,50 $».
  function money(t) {
    var m = /^\s*(\d+)(?:[.,](\d+))?\s*$/.exec(t.priceStr);
    var whole = m ? m[1] : String(Math.round(t.price));
    var frac = m && m[2] && /[1-9]/.test(m[2]) ? ',' + m[2] : '';
    whole = whole.replace(/\B(?=(\d{3})+(?!\d))/g, ' ');
    var cur = !t.currency || t.currency === 'USD' ? '$' : t.currency;
    return whole + frac + ' ' + cur;
  }

  function normalize(data) {
    var items = data && Array.isArray(data.items) ? data.items : null;
    if (!items) return null;
    var out = [];
    for (var i = 0; i < items.length; i++) {
      var it = items[i] || {};
      var min = parseInt(it.min_stores, 10);
      var max = it.max_stores === null || it.max_stores === undefined ? null : parseInt(it.max_stores, 10);
      var priceStr = String(it.price_per_store == null ? '' : it.price_per_store);
      var price = parseFloat(priceStr.replace(',', '.'));
      if (!isFinite(min) || min < 1 || !isFinite(price) || price < 0) continue;
      if (max !== null && (!isFinite(max) || max < min)) max = null;
      out.push({ min: min, max: max, price: price, priceStr: priceStr, currency: String(it.currency || 'USD') });
    }
    out.sort(function (a, b) { return a.min - b.min; });
    return out;
  }

  function el(tag, cls, text) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text != null) e.textContent = text;
    return e;
  }

  function renderTariffs(items) {
    var box = document.getElementById('tariffs');
    if (!box) return;
    var featuresEl = box.querySelector('[data-tariff="features"]') || box.querySelector('.checks');
    var featuresHTML = featuresEl ? featuresEl.innerHTML : '';
    var statWrap = document.querySelector('[data-tariff="stat"]');
    var statEl = document.querySelector('[data-tariff="min-price"]');
    var networkEl = document.querySelector('[data-tariff="network"]');

    box.textContent = '';
    box.setAttribute('data-count', String(Math.min(items.length, 3)));

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

    var minPrice = Infinity, maxPrice = -Infinity, best = -1;
    items.forEach(function (t, i) {
      if (t.price < minPrice) { minPrice = t.price; best = i; }
      if (t.price > maxPrice) maxPrice = t.price;
    });
    var highlight = items.length > 1 && minPrice < maxPrice;

    items.forEach(function (t, i) {
      var isBest = highlight && i === best;
      var card = el('article', 'price-card' + (isBest ? ' price-card--best' : ''));
      var top = el('div', 'price-card__top');
      top.appendChild(el('h3', 'price-card__title', T.title(t)));
      if (isBest) top.appendChild(el('span', 'badge', T.best));
      card.appendChild(top);

      var price = el('p', 'price-card__price');
      price.appendChild(el('span', 'price-card__amount', money(t)));
      price.appendChild(el('span', 'price-card__per', T.per));
      card.appendChild(price);
      card.appendChild(document.createElement('hr'));

      var ul = el('ul', 'checks');
      ul.innerHTML = featuresHTML;
      card.appendChild(ul);

      var primary = isBest || items.length === 1;
      var cta = el('a', 'button button--lg price-card__cta ' + (primary ? 'button--primary' : 'button--secondary'),
        t.min > 1 ? T.ctaMany : T.ctaOne);
      cta.setAttribute('data-link', 'register');
      card.appendChild(cta);
      box.appendChild(card);
    });
    applyLinks(box);

    if (statWrap && statEl) {
      statWrap.hidden = false;
      var cheapest = items[best];
      statEl.textContent = T.stat(money(cheapest), minPrice < maxPrice);
    }

    if (networkEl) {
      var base = items[0];
      var tiers = items.filter(function (t) { return t.min > 1 && t.price < base.price; });
      networkEl.hidden = !tiers.length;
      if (tiers.length) networkEl.textContent = T.network(tiers, base);
    }
  }

  function loadTariffs() {
    if (!document.getElementById('tariffs') || !window.fetch) return;
    var ctrl = window.AbortController ? new AbortController() : null;
    var timer = ctrl ? setTimeout(function () { ctrl.abort(); }, 8000) : null;
    fetch(TARIFFS_URL, { headers: { Accept: 'application/json' }, credentials: 'omit', signal: ctrl ? ctrl.signal : undefined })
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
