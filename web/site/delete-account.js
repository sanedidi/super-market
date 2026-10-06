// Удаление аккаунта с сайта: номер → код → результат.
// API (тот же домен, /api/ проксируется на backend):
//   POST /api/v1/public/account-deletion/request {phone}       → {sent, expires_in, resend_in, channel}
//   POST /api/v1/public/account-deletion/confirm {phone, code} → {deleted: [...], requested: [...]}
// Ошибки: {"error": {"code", "message", "details"}}.
(function () {
  'use strict';

  var API = '/api/v1/public/account-deletion/';
  var $ = function (id) { return document.getElementById(id); };

  var steps = { phone: $('step-phone'), code: $('step-code'), done: $('step-done') };
  var about = $('about');

  var phoneForm = $('delete-form');
  var phoneInput = $('phone');
  var phoneBox = $('phone-box');
  var phoneError = $('phone-error');
  var sendBtn = $('send-btn');

  var codeForm = $('code-form');
  var codeInput = $('code');
  var otp = $('otp');
  var boxes = otp.querySelectorAll('.otp__box');
  var codeError = $('code-error');
  var codeSent = $('code-sent');
  var confirmBtn = $('confirm-btn');
  var restartBtn = $('restart-btn');
  var blocked = $('blocked');
  var blockedText = $('blocked-text');
  var resend = $('resend');

  var state = { digits: '', timer: null };

  // ---------------------------------------------------------------- утилиты

  function onlyDigits(s) { return (s || '').replace(/\D/g, ''); }

  // 9 цифр после +998 (если вставили номер целиком — отрезаем код страны).
  function nationalDigits(raw) {
    var d = onlyDigits(raw);
    if (d.length > 9 && d.indexOf('998') === 0) d = d.slice(3);
    return d.slice(0, 9);
  }

  function formatNational(d) {
    var parts = [d.slice(0, 2), d.slice(2, 5), d.slice(5, 7), d.slice(7, 9)];
    return parts.filter(Boolean).join(' ');
  }

  function maskedPhone(d) {
    // Неразрывные пробелы: номер не переносится по строкам.
    return ['+998', d.slice(0, 2), d.slice(2, 5), '••', d.slice(7, 9)].join('\u00a0');
  }

  function plural(n, one, few, many) {
    var m10 = n % 10, m100 = n % 100;
    if (m10 === 1 && m100 !== 11) return one;
    if (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14)) return few;
    return many;
  }

  function mmss(sec) {
    var m = Math.floor(sec / 60), s = sec % 60;
    return m + ':' + (s < 10 ? '0' : '') + s;
  }

  function sum(v) {
    var n = Math.round(parseFloat(v));
    if (!isFinite(n)) return String(v);
    return String(n).replace(/\B(?=(\d{3})+(?!\d))/g, ' ');
  }

  function capitalize(s) { return s ? s.charAt(0).toUpperCase() + s.slice(1) : s; }

  function busy(btn, on) {
    btn.disabled = on;
    btn.setAttribute('aria-busy', on ? 'true' : 'false');
  }

  function show(name) {
    Object.keys(steps).forEach(function (k) { steps[k].hidden = k !== name; });
    about.hidden = name !== 'phone';
    // Шаги «1. Номер · 2. Код · 3. Готово» и боковая карточка «Что произойдёт» (только на шаге 1) — через CSS.
    document.documentElement.setAttribute('data-step', name);
    var chips = document.querySelectorAll('.flow-steps [data-for]');
    for (var i = 0; i < chips.length; i++) {
      if (chips[i].getAttribute('data-for') === name) chips[i].setAttribute('aria-current', 'step');
      else chips[i].removeAttribute('aria-current');
    }
    var h = steps[name].querySelector('h1');
    window.scrollTo(0, 0);
    if (h) h.focus({ preventScroll: true });
  }

  // Ошибка API → {status, code, message, details}.
  function post(path, body) {
    return fetch(API + path, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Accept': 'application/json' },
      credentials: 'omit',
      body: JSON.stringify(body)
    }).then(function (res) {
      return res.json().catch(function () { return {}; }).then(function (data) {
        if (res.ok) return data;
        var e = (data && data.error) || {};
        throw { status: res.status, code: e.code || '', message: e.message || '', details: e.details || {} };
      });
    }, function () {
      throw { status: 0, code: 'network', message: '', details: {} };
    });
  }

  function commonError(err) {
    if (err.status === 0) return 'Нет связи с сервером. Проверьте интернет и попробуйте ещё раз.';
    if (err.status >= 500 && err.code !== 'telegram_unavailable') return 'Что-то пошло не так на сервере. Попробуйте ещё раз через несколько минут.';
    return capitalize(err.message) || 'Не получилось. Попробуйте ещё раз.';
  }

  // ---------------------------------------------------------------- шаг 1

  function setPhoneError(msg, html) {
    if (html) phoneError.innerHTML = html; else phoneError.textContent = msg || '';
    if (msg || html) {
      phoneBox.setAttribute('data-invalid', '');
      phoneInput.setAttribute('aria-invalid', 'true');
    } else {
      phoneBox.removeAttribute('data-invalid');
      phoneInput.removeAttribute('aria-invalid');
    }
  }

  // Форматируем «90 123 45 67», сохраняя позицию курсора по числу цифр слева.
  phoneInput.addEventListener('input', function () {
    var pos = phoneInput.selectionStart || 0;
    var before = onlyDigits(phoneInput.value.slice(0, pos)).length;
    var raw = phoneInput.value;
    var d = nationalDigits(raw);
    // Вставка «+998…»: код страны отрезан, курсор — в конец.
    if (onlyDigits(raw).length > 9) before = d.length;
    var out = formatNational(d);
    phoneInput.value = out;
    var i = 0, seen = 0;
    while (i < out.length && seen < before) { if (/\d/.test(out[i])) seen++; i++; }
    try { phoneInput.setSelectionRange(i, i); } catch (e) { /* type=tel в старых браузерах */ }
    if (phoneError.textContent) setPhoneError('');
  });

  phoneBox.addEventListener('click', function (e) { if (e.target !== phoneInput) phoneInput.focus(); });

  function requestCode(digits) {
    return post('request', { phone: '+998' + digits });
  }

  phoneForm.addEventListener('submit', function (e) {
    e.preventDefault();
    var d = nationalDigits(phoneInput.value);
    if (d.length !== 9) {
      setPhoneError('Введите 9 цифр номера после +998.');
      phoneInput.focus();
      return;
    }
    setPhoneError('');
    busy(sendBtn, true);
    requestCode(d).then(function (res) {
      state.digits = d;
      openCodeStep(res.channel, res.expires_in, res.resend_in);
    }, function (err) {
      if (err.code === 'account_not_found') {
        setPhoneError('Аккаунт с этим номером не найден.');
      } else if (err.code === 'too_many_requests') {
        // Код уже отправлен недавно — им можно воспользоваться.
        var wait = parseInt(err.details.retry_after, 10) || 60;
        state.digits = d;
        setPhoneError(null,
          'Код уже отправлен на этот номер. Новый можно запросить через ' + mmss(wait) +
          '. <button type="button" class="linkbtn" id="have-code" style="margin:0">У меня есть код →</button>');
        $('have-code').addEventListener('click', function () { openCodeStep('', 0, wait); });
      } else if (err.code === 'telegram_not_linked') {
        var url = err.details.bot_url;
        var safe = typeof url === 'string' && /^https:\/\/t\.me\//.test(url);
        setPhoneError(null,
          'Код можно получить только через Telegram. Откройте ' +
          (safe ? '<a href="' + url.replace(/"/g, '&quot;') + '" target="_blank" rel="noopener">бот Super Market</a>' : 'бот Super Market') +
          ', поделитесь номером и нажмите «Получить код» ещё раз.');
      } else if (err.code === 'validation') {
        setPhoneError('Проверьте номер: 9 цифр после +998.');
      } else {
        setPhoneError(commonError(err));
      }
      phoneInput.focus();
    }).then(function () { busy(sendBtn, false); });
  });

  // ---------------------------------------------------------------- шаг 2

  function sentText(channel, expiresIn) {
    var minutes = Math.round((expiresIn || 0) / 60);
    var ttl = minutes > 0 ? ' Код действует ' + minutes + ' ' + plural(minutes, 'минуту', 'минуты', 'минут') + '.' : '';
    if (channel === 'sms') return 'Отправили SMS на ' + maskedPhone(state.digits) + '.' + ttl;
    if (channel === 'telegram') return 'Отправили код в Telegram-бот Super Market.' + ttl;
    return 'Код отправлен на ' + maskedPhone(state.digits) + ' — в Telegram-бот Super Market или по SMS.';
  }

  function openCodeStep(channel, expiresIn, resendIn) {
    codeSent.textContent = sentText(channel, expiresIn);
    codeInput.value = '';
    setCodeError('');
    setBlocked(null);
    renderBoxes();
    startResend(resendIn || 60);
    show('code');
    // На телефоне сразу открываем цифровую клавиатуру.
    setTimeout(function () { codeInput.focus(); }, 50);
  }

  function renderBoxes() {
    var v = codeInput.value;
    var focused = document.activeElement === codeInput;
    for (var i = 0; i < boxes.length; i++) {
      boxes[i].textContent = v[i] || '';
      boxes[i].classList.toggle('is-active', focused && i === Math.min(v.length, boxes.length - 1));
    }
  }

  function setCodeError(msg) {
    codeError.textContent = msg || '';
    if (msg) { otp.setAttribute('data-invalid', ''); codeInput.setAttribute('aria-invalid', 'true'); }
    else { otp.removeAttribute('data-invalid'); codeInput.removeAttribute('aria-invalid'); }
  }

  function setBlocked(msg) {
    blocked.hidden = !msg;
    blockedText.textContent = msg || '';
    confirmBtn.hidden = !!msg;
    restartBtn.hidden = !msg;
    codeInput.disabled = !!msg;
    $('warn').hidden = !!msg;
    resend.hidden = !!msg;
  }

  codeInput.addEventListener('input', function () {
    var v = onlyDigits(codeInput.value).slice(0, 6);
    if (v !== codeInput.value) codeInput.value = v;
    if (codeError.textContent) setCodeError('');
    renderBoxes();
  });
  codeInput.addEventListener('focus', renderBoxes);
  codeInput.addEventListener('blur', renderBoxes);
  // Курсор всегда в конце — ввод идёт по ячейкам слева направо.
  codeInput.addEventListener('keyup', function () {
    var n = codeInput.value.length;
    try { codeInput.setSelectionRange(n, n); } catch (e) { /* ignore */ }
  });

  function startResend(sec) {
    clearInterval(state.timer);
    var left = Math.max(1, sec | 0);
    var tick = function () {
      if (left <= 0) {
        clearInterval(state.timer);
        resend.innerHTML = '<button type="button" id="resend-btn">Отправить код ещё раз</button>';
        $('resend-btn').addEventListener('click', doResend);
        return;
      }
      resend.textContent = 'Отправить код ещё раз через ' + mmss(left);
      left--;
    };
    // aria-live не читает каждую секунду: отключаем на время отсчёта.
    resend.setAttribute('aria-live', 'off');
    tick();
    state.timer = setInterval(function () {
      if (left <= 0) resend.setAttribute('aria-live', 'polite');
      tick();
    }, 1000);
  }

  function doResend() {
    var btn = $('resend-btn');
    if (btn) btn.disabled = true;
    requestCode(state.digits).then(function (res) {
      codeSent.textContent = sentText(res.channel, res.expires_in);
      codeInput.value = '';
      setCodeError('');
      setBlocked(null);
      renderBoxes();
      startResend(res.resend_in);
      resend.setAttribute('aria-live', 'polite');
      codeInput.focus();
    }, function (err) {
      if (err.code === 'too_many_requests') {
        startResend(parseInt(err.details.retry_after, 10) || 60);
      } else {
        if (btn) btn.disabled = false;
        setCodeError(commonError(err));
      }
    });
  }

  $('change-phone').addEventListener('click', backToPhone);
  restartBtn.addEventListener('click', backToPhone);

  function backToPhone() {
    clearInterval(state.timer);
    setPhoneError('');
    phoneInput.value = formatNational(state.digits);
    show('phone');
    phoneInput.focus();
  }

  codeForm.addEventListener('submit', function (e) {
    e.preventDefault();
    var code = codeInput.value;
    if (code.length !== 6) {
      setCodeError('Введите 6 цифр кода.');
      codeInput.focus();
      return;
    }
    busy(confirmBtn, true);
    post('confirm', { phone: '+998' + state.digits, code: code }).then(function (res) {
      clearInterval(state.timer);
      showResult(res);
    }, function (err) {
      var d = err.details || {};
      if (err.code === 'active_order') {
        setBlocked(d.account === 'crowd'
          ? 'Сначала завершите заказ № ' + d.order_number + ' в приложении Super Market Курьер: доставьте или отмените его.'
          : 'Сначала дождитесь завершения заказа № ' + d.order_number + ' в приложении Super Market.');
      } else if (err.code === 'unpaid_balance') {
        setBlocked('Сначала получите выплату: на балансе курьера «по пути» ' + sum(d.balance) +
          ' сум. Выплаты — по понедельникам, после этого аккаунт можно удалить.');
      } else if (err.code === 'account_not_found') {
        setBlocked('Аккаунт с этим номером не найден.');
      } else if (err.code === 'validation') {
        codeInput.value = '';
        renderBoxes();
        setCodeError('Код неверный или устарел. После 5 ошибок запросите новый код.');
        codeInput.focus();
      } else {
        setCodeError(commonError(err));
      }
    }).then(function () { busy(confirmBtn, false); });
  });

  // ---------------------------------------------------------------- шаг 3

  var ICON_OK = '<svg class="ico ico--ok" viewBox="0 0 20 20" aria-hidden="true"><circle cx="10" cy="10" r="10" fill="currentColor"/><path d="M6 10.2l2.6 2.6L14 7.4" fill="none" stroke="#fff" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>';
  var ICON_WAIT = '<svg class="ico ico--wait" viewBox="0 0 20 20" aria-hidden="true"><circle cx="10" cy="10" r="8.25" fill="none" stroke="currentColor" stroke-width="1.75"/><path d="M10 5.5V10l3 2" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"/></svg>';
  var REQUEST_NOTE = 'владелец сети или поддержка закроют доступ в течение 30 дней';

  var DELETED = {
    client: 'Super Market — аккаунт удалён',
    crowd: 'Курьер «по пути» — аккаунт удалён'
  };
  var REQUESTED = {
    store: 'SM Магазин — запрос отправлен',
    courier: 'SM Курьер — запрос отправлен'
  };

  function item(icon, title, sub) {
    var li = document.createElement('li');
    li.innerHTML = icon;
    var span = document.createElement('span');
    span.textContent = title;
    if (sub) {
      var s = document.createElement('span');
      s.className = 'sub';
      s.textContent = sub;
      span.appendChild(s);
    }
    li.appendChild(span);
    return li;
  }

  function showResult(res) {
    var deleted = (res && res.deleted) || [];
    var requested = (res && res.requested) || [];
    var list = $('done-list');
    list.innerHTML = '';
    ['client', 'crowd'].forEach(function (k) {
      if (deleted.indexOf(k) >= 0) list.appendChild(item(ICON_OK, DELETED[k]));
    });
    deleted.forEach(function (k) {
      if (!DELETED[k]) list.appendChild(item(ICON_OK, k + ' — аккаунт удалён'));
    });
    requested.forEach(function (k) {
      list.appendChild(item(ICON_WAIT, REQUESTED[k] || (k + ' — запрос отправлен'), REQUEST_NOTE));
    });
    var phone = maskedPhone(state.digits);
    var text;
    if (deleted.length) text = 'Мы вышли из аккаунта на всех устройствах. Что сделано с номером ' + phone + ':';
    else if (requested.length) text = 'Что сделано с номером ' + phone + ':';
    else text = 'Активных аккаунтов с номером ' + phone + ' не осталось.';
    $('done-text').textContent = text;
    list.parentNode.hidden = !list.children.length;
    show('done');
  }
})();
