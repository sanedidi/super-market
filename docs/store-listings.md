# Тексты и анкеты для App Store Connect и Google Play Console

Всё, что нужно вставить при публикации трёх приложений: **Super Market** (покупатели), **SM Магазин** (магазины),
**SM Курьер** (курьеры). Тексты магазинов — на русском и узбекском (латиница), заметки для проверяющего Apple —
на английском с переводом. Длина каждого текста проверена скриптом, число символов указано рядом (пробелы и переводы
строк считаются).

Сборка, подпись и манифест конфиденциальности iOS — [release.md](release.md). Демо-доступ — раздел 7.

| Приложение | App Store (bundle id) | Google Play (package) | Версия в `pubspec.yaml` |
|---|---|---|---|
| Super Market | `uz.supermarket.smClient` | `uz.supermarket.sm_client` | 0.9.0 |
| SM Магазин | `uz.supermarket.smStore` | `uz.supermarket.sm_store` | 0.8.0 |
| SM Курьер | `uz.supermarket.smCourier` | `uz.supermarket.sm_courier` | 1.1.0 |

> **Языки.** Интерфейс всех трёх приложений сейчас только на русском (`locale: ru`; в Super Market настройка
> «Язык приложения» пока не переводит интерфейс). Поэтому в узбекских описаниях есть строка «Ilova interfeysi
> hozircha rus tilida». Узбекского языка нет в списке языков метаданных App Store Connect (на момент подготовки —
> проверьте при создании): в App Store основной язык — **Russian**, узбекские тексты — для Google Play (язык
> «Uzbek – uz», если он есть в списке Play Console; если нет — только ru-RU) и на будущее.

---

## 1. Общие ссылки и реквизиты

| Поле | Значение |
|---|---|
| Политика конфиденциальности (Privacy Policy URL) | https://super-market.uz/privacy (UZ: https://super-market.uz/privacy/uz) |
| Публичная оферта для покупателей | https://super-market.uz/offer |
| Оферта для магазинов | https://super-market.uz/offer/stores |
| Условия для курьеров | https://super-market.uz/courier-terms |
| Удаление аккаунта (Google Play → Data safety → Delete account URL) | https://super-market.uz/delete-account |
| Поддержка (Support URL) | https://t.me/super_market_support |
| Телефон поддержки | +998 50 576 47 23 |
| Маркетинговый сайт (Marketing URL / Website) | https://super-market.uz |
| Email для Google Play (обязателен) и App Review | `<email поддержки>` — в коде и на сайте email нет, заведите ящик (например, support@super-market.uz) |
| Разработчик (юр. лицо) | ЯТТ ANVAROV SHAHZODBEK XOJIMUROD O‘G‘LI |
| Бренд | Super Market |
| Copyright (App Store) | `© 2026 ANVAROV SHAHZODBEK XOJIMUROD O‘G‘LI` (Apple в примерах пишет без знака: `2026 ANVAROV SHAHZODBEK XOJIMUROD O‘G‘LI` — подходят оба) |

Проверьте до отправки:

- `/offer` и `/offer/stores` — страницы (`web/site/offer.html`, `offer-stores.html`) и маршруты nginx добавляются в
  этой же ветке параллельно; убедитесь, что после деплоя они открываются. Ссылка на оферту в приложении покупателя
  берётся из `OFFER_URL` (`/client/config`) — на проде должно быть `https://super-market.uz/offer`.
- Имя разработчика в App Store (Seller) берётся из аккаунта Apple Developer: у аккаунта физлица — ФИО владельца, у
  организации — юр. название из D-U-N-S. Вручную в карточке приложения его не поменять. В Google Play имя разработчика
  можно задать: «Super Market» или юр. название.

---

## 2. App Store — тексты, категории, возрастной рейтинг

Правила, которые учтены:

- Ключевые слова — через запятую без пробелов, без слов из названия и подзаголовка (Apple и так их учитывает),
  без названий конкурентов. Если поле App Store Connect покажет превышение (счётчик у кириллицы иногда строже) —
  уберите последнее слово.
- «Что нового» Apple не показывает для **первой** версии приложения — поле появится со второй. Текст ниже пригодится
  для Google Play (раздел 3) и следующей версии.
- **SM Магазин (iOS):** ни слова о покупке подписки, тарифах, ценах и о том, где платить (guideline 3.1.1 / 3.1.3).
  В приложении на iOS подписка только для просмотра (`subscriptionReadOnly` в `apps/store/lib/finance/balance_screen.dart`).
- Название в App Store должно быть уникальным среди всех приложений. «Super Market» почти наверняка занято, поэтому
  название с пояснением; на экране iPhone останется короткое имя из `CFBundleDisplayName` («Super Market», «SM Магазин»,
  «SM Курьер»).

### 2.1. Возрастной рейтинг (анкета Apple, все три приложения)

Анкета App Store Connect (новая, с 2025 года) → ожидаемые ответы:

| Раздел / вопрос | Super Market | SM Магазин | SM Курьер |
|---|---|---|---|
| Parental Controls (родительский контроль) | No | No | No |
| Age Assurance (проверка возраста в приложении) | No | No | No |
| Unrestricted Web Access (свободный доступ в интернет) | No — ссылки (Payme, Click, Telegram, политика) открываются во внешнем браузере | No | No |
| User-Generated Content (контент пользователей, видимый другим) | No — списки «Моей семьи» видят только приглашённые члены семьи | No | No |
| Messaging and Chat | No | No | No |
| Advertising (реклама) | **Yes** — блоки брендов с пометкой «Реклама» на главной | No | No |
| Profanity or Crude Humor | None | None | None |
| Horror/Fear Themes | None | None | None |
| Alcohol, Tobacco, or Drug Use or References | None (см. ⚠ ниже) | None | None |
| Medical or Treatment Information | None | None | None |
| Health or Wellness Topics | No | No | No |
| Mature or Suggestive Themes | None | None | None |
| Sexual Content or Nudity / Graphic Sexual Content | None | None | None |
| Cartoon / Realistic / Graphic Violence | None | None | None |
| Guns or Other Weapons | None | None | None |
| Simulated Gambling / Gambling | None / No | None / No | None / No |
| Contests | None (акции — это скидки, не конкурсы) | None | None |
| Loot Boxes | No | No | No |
| **Итог** | **4+** | **4+** | **4+** |

Повышать рейтинг вручную не нужно: рейтинг Apple — про содержимое, а возраст (16+ для покупателей, 18+ для курьеров
«по пути») ограничивают оферта, условия и проверка документа.

> ⚠ **Алкоголь и табак.** В коде нет фильтра таких товаров в витрине покупателя (поиск по `алкогол|табак|сигарет`
> ничего не находит). Apple (1.4.3) и Google запрещают приложениям **способствовать продаже табака и вейпов**, а
> продажа алкоголя потребовала бы ответа «Frequent» и рейтинга выше. Ответы выше верны, только если магазины не
> выставляют такие товары онлайн — убедитесь в этом до отправки (лучше — скрывать такие категории на сервере).

### 2.2. Super Market — App Store

**Категория:** основная — Food & Drink (Еда и напитки), дополнительная — Shopping (Покупки).

Название (≤30) — 28 симв.
```text
Super Market: продукты рядом
```
Запасной вариант, если занято — 23 симв.
```text
Super Market — доставка
```

Подзаголовок (≤30) — 28 симв.
```text
Доставка из магазинов у дома
```

Промотекст (≤170) — 161 симв.
```text
Продукты из магазинов вашего района: ищите товар сразу во всех, сравнивайте цены и следите за курьером на карте. Оплата картой Uzcard и Humo через Payme и Click.
```

Ключевые слова (≤100) — 99 симв.
```text
продуктовый,супермаркет,еда,бакалея,молоко,хлеб,овощи,фрукты,заказ,курьер,ташкент,насия,семья,payme
```

<a id="client-description-ru"></a>
Описание (≤4000) — 1488 симв.
```text
Super Market — продукты из магазинов вашего района с доставкой. Заказ собирает и привозит сам магазин.

ГЛАВНОЕ
• Магазины, которые привозят по вашему адресу, — списком и на карте
• Поиск сразу по всем магазинам рядом: где есть товар и сколько стоит
• Каталог магазина с категориями, акциями и скидками
• Понятные условия в корзине: минимальная сумма, цена доставки и сумма, от которой доставка бесплатная
• Доставка как можно скорее или ко времени
• Оплата картой Uzcard или Humo через Payme и Click, наличными курьеру — если магазин принимает
• Статус заказа обновляется сам, а пока заказ в пути, курьер виден на карте

ДЛЯ СЕМЬИ И НА КАЖДЫЙ ДЕНЬ
• «Моя семья»: общий список покупок, «Попросить купить» и напоминания
• Избранные товары и несколько адресов: дом, работа, родители
• «Мои долги»: если вы берёте в долг (насия) в магазине у дома, видно, где и сколько вы должны, и историю покупок. Не согласны с записью — нажмите «Это не я»
• «Хочу доставку»: отметьте магазин рядом, который пока не привозит, — он узнает, что его ждут

БЕЗ ЛИШНЕГО
• Магазины и товары можно смотреть без регистрации
• Вход по номеру телефона — код придёт по SMS или в Telegram
• Уведомления о заказе. Об акциях — только если вы сами их включите
• Удалить аккаунт можно в приложении: Профиль → Настройки → Удалить аккаунт

Super Market — платформа: товары продают и доставляют сами магазины. Список магазинов зависит от вашего адреса.

Вопросы и поддержка: Telegram @super_market_support, +998 50 576 47 23.
```

«Что нового» (для следующих версий и Google Play) (≤4000) — 152 симв.
```text
Первый выпуск Super Market: магазины рядом с доставкой, поиск по всем магазинам, оплата через Payme и Click, курьер на карте, «Моя семья» и «Мои долги».
```

**Узбекский (латиница)** — для Google Play и на будущее:

Nomi (≤30) — 29 симв.
```text
Super Market: yaqin do‘konlar
```

Qisqa sarlavha / subtitle (≤30) — 30 симв.
```text
Do‘kondan uyga yetkazib berish
```

Promo matn (≤170) — 165 симв.
```text
Mahallangizdagi do‘konlardan mahsulotlar: barcha do‘konlardan birdaniga qidiring, narxlarni solishtiring va kuryerni xaritada kuzating. Payme va Click orqali to‘lov.
```

Kalit so‘zlar (≤100) — 93 симв.
```text
oziq-ovqat,supermarket,non,sut,sabzavot,meva,buyurtma,kuryer,toshkent,nasiya,oila,dokon,payme
```

<a id="client-description-uz"></a>
Tavsif (≤4000) — 1732 симв.
```text
Super Market — mahallangizdagi do‘konlardan mahsulotlarni yetkazib berish. Buyurtmani do‘konning o‘zi yig‘adi va olib keladi.

ASOSIY IMKONIYATLAR
• Manzilingizga yetkazib beradigan do‘konlar — ro‘yxatda va xaritada
• Yaqin atrofdagi barcha do‘konlardan birdaniga qidirish: mahsulot qayerda bor va necha pul
• Do‘kon katalogi: bo‘limlar, aksiyalar va chegirmalar
• Savatda shartlar aniq: minimal summa, yetkazib berish narxi va qaysi summadan bepul
• Imkon qadar tez yoki belgilangan vaqtga yetkazib berish
• Payme va Click orqali Uzcard yoki Humo kartasi bilan to‘lov, do‘kon qabul qilsa — kuryerga naqd pul
• Buyurtma holati o‘zi yangilanadi, yo‘ldagi kuryer xaritada ko‘rinadi

OILA UCHUN VA HAR KUNI
• «Моя семья» (Mening oilam): umumiy xaridlar ro‘yxati, «Sotib olishni so‘rash» va eslatmalar
• Sevimli mahsulotlar va bir nechta manzil: uy, ish, ota-ona
• «Мои долги» (Qarzlarim): uy yonidagi do‘kondan nasiyaga olsangiz, qayerda va qancha qarzingiz borligi hamda xaridlar tarixi ko‘rinadi. Yozuvga rozi bo‘lmasangiz — «Это не я» (Bu men emasman) tugmasini bosing
• «Хочу доставку» (Yetkazib berishni xohlayman): hozircha yetkazmaydigan yaqin do‘konni belgilang — u sizni kutayotganini bilib oladi

ORTIQCHASIZ
• Do‘kon va mahsulotlarni ro‘yxatdan o‘tmasdan ko‘rish mumkin
• Telefon raqami orqali kirish — kod SMS yoki Telegram’ga keladi
• Buyurtma haqida bildirishnomalar. Aksiyalar haqida — faqat o‘zingiz yoqsangiz
• Akkauntni ilovada o‘chirish mumkin: Профиль → Настройки → Удалить аккаунт

Ilova interfeysi hozircha rus tilida.

Super Market — platforma: mahsulotlarni do‘konlarning o‘zi sotadi va yetkazadi. Do‘konlar ro‘yxati manzilingizga bog‘liq.

Savollar va yordam: Telegram @super_market_support, +998 50 576 47 23.
```

Yangiliklar / What's New (≤4000) — 178 симв.
```text
Super Market’ning birinchi versiyasi: yetkazib beradigan yaqin do‘konlar, barcha do‘konlardan qidirish, Payme va Click orqali to‘lov, kuryer xaritada, «Моя семья» va «Мои долги».
```

### 2.3. SM Магазин — App Store

**Категория:** основная — Business (Бизнес), дополнительная — Productivity (Производительность).

> В iOS-текстах нет подписки, тарифов, цен и ссылок на оплату (3.1.1). Не добавляйте их и в скриншоты: на iOS-скриншоте
> «Финансы» не должно быть карточки подписки с ценой (см. раздел 8).

Название (≤30) — 25 симв.
```text
SM Магазин — Super Market
```

Подзаголовок (≤30) — 23 симв.
```text
Заказы, склад и финансы
```

Промотекст (≤170) — 145 симв.
```text
Принимайте онлайн-заказы, делайте приход по фото накладной и следите за выручкой с телефона. Для владельцев и сотрудников магазинов Super Market.
```

Ключевые слова (≤100) — 98 симв.
```text
учёт,накладная,приход,остатки,продавец,торговля,бизнес,выручка,насия,долги,курьер,сотрудники,касса
```

<a id="store-description-ru-ios"></a>
Описание (≤4000) — 1460 симв.
```text
SM Магазин — приложение для владельцев и сотрудников продуктовых магазинов, подключённых к Super Market. Онлайн-заказы, склад и деньги магазина — в телефоне.

ЗАКАЗЫ
• Новые заказы из приложения Super Market — с уведомлением
• Принять, собрать и передать своему курьеру или курьеру «по пути»
• Выдача заказа курьеру «по пути» по коду

СКЛАД
• Приход по фото накладной: сфотографируйте накладную поставщика — ИИ распознает строки и сопоставит их с каталогом, останется проверить и провести
• Начало работы по фото полок и сканеру штрихкодов
• Остатки, возврат поставщику, долги поставщикам и акт сверки

ДЕНЬГИ И КОНТРОЛЬ
• Итоги дня: выручка, прибыль и что требует внимания
• Кассы и сдача кассы, контроль кассиров: недостачи, возвраты, скидки
• Баланс онлайн-заказов и заявки на вывод денег магазину
• Долги покупателей (насия): кто должен, лимиты, напоминания, приём оплаты

КОМАНДА
• Сотрудники и роли с правами
• Курьеры «по пути»: проверка документа в магазине и бонусы магазину
• Реклама брендов: доля магазина с показов, можно скрыть бренд

НАСТРОЙКА И БЕЗОПАСНОСТЬ
• Первая настройка: точка магазина на карте, часы работы, доставка
• Вход по номеру сотрудника и коду из Telegram, дальше — свой код из 4 цифр или Face ID
• Каждый сотрудник видит только то, что разрешает его роль

Аккаунт сотрудника заводит владелец сети в панели магазина. Удалить аккаунт: Ещё → Удалить аккаунт.

Вопросы и поддержка: Telegram @super_market_support, +998 50 576 47 23.
```

«Что нового» (≤4000) — 149 симв.
```text
Первый выпуск SM Магазин: заказы, приход по фото накладной, склад, итоги дня, кассы, долги покупателей и поставщиков, сотрудники и курьеры «по пути».
```

**Узбекский (латиница):**

Nomi (≤30) — 25 симв.
```text
SM Магазин — Super Market
```

Qisqa sarlavha / subtitle (≤30) — 25 симв.
```text
Buyurtma, ombor va moliya
```

Promo matn (≤170) — 157 симв.
```text
Onlayn buyurtmalarni qabul qiling, yuk xati surati bo‘yicha kirim qiling va tushumni telefondan kuzating. Super Market do‘konlari egalari va xodimlari uchun.
```

Kalit so‘zlar (≤100) — 96 симв.
```text
hisob,yuk xati,kirim,qoldiq,sotuvchi,savdo,biznes,tushum,nasiya,qarz,kuryer,xodimlar,kassa,dokon
```

<a id="store-description-uz-ios"></a>
Tavsif (≤4000) — 1693 симв.
```text
SM Магазин — Super Market’ga ulangan oziq-ovqat do‘konlari egalari va xodimlari uchun ilova. Onlayn buyurtmalar, ombor va do‘kon pullari — telefoningizda.

BUYURTMALAR
• Super Market ilovasidan yangi buyurtmalar — bildirishnoma bilan
• Qabul qilish, yig‘ish va o‘z kuryeringizga yoki «yo‘l-yo‘lakay» kuryerga topshirish
• «Yo‘l-yo‘lakay» kuryerga buyurtmani kod bo‘yicha berish

OMBOR
• Yuk xati surati bo‘yicha kirim: yetkazib beruvchining yuk xatini suratga oling — sun’iy intellekt qatorlarni o‘qiydi va katalog bilan solishtiradi, tekshirib o‘tkazish qoladi
• Javon surati va shtrix-kod skaneri bilan ishni boshlash
• Qoldiqlar, yetkazib beruvchiga qaytarish, yetkazib beruvchilarga qarzlar va solishtirma dalolatnoma

PUL VA NAZORAT
• Kun yakuni: tushum, foyda va e’tibor talab qiladigan narsalar
• Kassalar va kassani topshirish, kassirlar nazorati: kamomad, qaytarishlar, chegirmalar
• Onlayn buyurtmalar balansi va do‘konga pul yechish arizalari
• Xaridorlar qarzi (nasiya): kim qarzdor, limitlar, eslatmalar, to‘lovni qabul qilish

JAMOA
• Xodimlar va huquqli rollar
• «Yo‘l-yo‘lakay» kuryerlar: do‘konda hujjatni tekshirish va do‘konga bonuslar
• Brendlar reklamasi: ko‘rsatishlardan do‘kon ulushi, brendni yashirish mumkin

SOZLASH VA XAVFSIZLIK
• Dastlabki sozlash: do‘kon xaritadagi nuqtasi, ish vaqti, yetkazib berish
• Xodim raqami va Telegram’dagi kod orqali kirish, keyin — 4 raqamli o‘z kodingiz yoki Face ID
• Har bir xodim faqat roli ruxsat bergan narsani ko‘radi

Xodim akkauntini tarmoq egasi do‘kon panelida ochadi. Akkauntni o‘chirish: Ещё → Удалить аккаунт.

Ilova interfeysi hozircha rus tilida.

Savollar va yordam: Telegram @super_market_support, +998 50 576 47 23.
```

Yangiliklar / What's New (≤4000) — 193 симв.
```text
SM Магазин’ning birinchi versiyasi: buyurtmalar, yuk xati surati bo‘yicha kirim, ombor, kun yakuni, kassalar, xaridorlar va yetkazib beruvchilar qarzlari, xodimlar va «yo‘l-yo‘lakay» kuryerlar.
```

### 2.4. SM Курьер — App Store

**Категория:** основная — Business (Бизнес), дополнительная — Productivity (Производительность).

Название (≤30) — 24 симв.
```text
SM Курьер — Super Market
```

Подзаголовок (≤30) — 25 симв.
```text
Зарабатывайте на доставке
```

Промотекст (≤170) — 155 симв.
```text
Идёте домой или на работу? Включите «Ищу заказы» — лента покажет заказы из магазинов рядом и по пути. Вознаграждение сразу на баланс, выплата раз в неделю.
```

Ключевые слова (≤100) — 98 симв.
```text
подработка,работа,доставка,заработок,по пути,ташкент,пешком,велосипед,самокат,смена,заказы,магазин
```

<a id="courier-description-ru"></a>
Описание (≤4000) — 1490 симв.
```text
SM Курьер — приложение для доставки заказов из магазинов Super Market. В нём два режима.

КУРЬЕР «ПО ПУТИ» — для всех от 18 лет
• Вход по номеру телефона и коду из SMS — аккаунт создастся сам
• Подтвердите личность в любом магазине-партнёре: продавец сверит паспорт или ID-карту, копию мы не храним
• Включите «Ищу заказы» и укажите, куда идёте, — лента покажет собранные заказы рядом и по пути и сколько вы за них получите
• Заберите заказ в магазине по коду и передайте покупателю — вознаграждение сразу на баланс
• Уровни: чем больше доставок вовремя, тем дороже заказы и больше заказов одновременно
• Заработок и история начислений, выплата раз в неделю

КУРЬЕР МАГАЗИНА — для сотрудников
• Вход по логину и паролю, которые выдаёт магазин
• Смена и транспорт: пешком, велосипед, самокат, авто
• Заказы «Забрать в магазине» и «Везу», новые — с вибрацией
• Карточка заказа: адрес, звонок покупателю и магазину, маршрут в Яндекс Картах, сколько взять наличными
• История за сегодня, вчера и неделю с суммой наличных для кассы

ГЕОПОЗИЦИЯ — ТОЛЬКО ПОКА ВЫ РАБОТАЕТЕ
Приложение получает геопозицию, только пока включено «Ищу заказы», есть активный заказ или идёт смена. В это время на Android видно уведомление, на iPhone — системный индикатор геолокации. Хранится только последняя точка, без истории перемещений. Выключите поиск или завершите смену — передача прекратится.

Удалить аккаунт: Профиль → Удалить аккаунт.

Вопросы и поддержка: Telegram @super_market_support, +998 50 576 47 23.
```

«Что нового» (≤4000) — 149 симв.
```text
Первый выпуск SM Курьер: заказы по пути с вознаграждением, уровни и заработок для курьеров «по пути», смена, заказы и маршрут для курьеров магазинов.
```

**Узбекский (латиница):**

Nomi (≤30) — 24 симв.
```text
SM Курьер — Super Market
```

Qisqa sarlavha / subtitle (≤30) — 29 симв.
```text
Yetkazib berib daromad qiling
```

Promo matn (≤170) — 165 симв.
```text
Uyga yoki ishga ketyapsizmi? «Ищу заказы»ni yoqing — lenta yaqin va yo‘lingizdagi do‘konlar buyurtmalarini ko‘rsatadi. Haq darhol balansga, to‘lov haftada bir marta.
```

Kalit so‘zlar (≤100) — 99 симв.
```text
kuryer,ish,qoshimcha daromad,yetkazish,yol-yolakay,toshkent,piyoda,velosiped,samokat,smena,buyurtma
```

<a id="courier-description-uz"></a>
Tavsif (≤4000) — 1713 симв.
```text
SM Курьер — Super Market do‘konlaridan buyurtmalarni yetkazib berish uchun ilova. Unda ikki rejim bor.

«YO‘L-YO‘LAKAY» KURYER — 18 yoshdan hamma uchun
• Telefon raqami va SMS’dagi kod orqali kirish — akkaunt o‘zi ochiladi
• Istalgan hamkor do‘konda shaxsingizni tasdiqlang: sotuvchi pasport yoki ID-kartani tekshiradi, nusxasini saqlamaymiz
• «Ищу заказы» (Buyurtma qidiryapman)ni yoqing va qayerga ketayotganingizni belgilang — lenta yaqin va yo‘lingizdagi yig‘ilgan buyurtmalarni va har biri uchun haqni ko‘rsatadi
• Buyurtmani do‘kondan kod bo‘yicha oling va xaridorga topshiring — haq darhol balansga tushadi
• Darajalar: o‘z vaqtida yetkazishlar qancha ko‘p bo‘lsa, buyurtmalar shuncha qimmat va bir vaqtda ko‘proq buyurtma
• Daromad va hisob-kitoblar tarixi, to‘lov haftada bir marta

DO‘KON KURYERI — xodimlar uchun
• Do‘kon beradigan login va parol bilan kirish
• Smena va transport: piyoda, velosiped, samokat, avto
• «Забрать в магазине» va «Везу» buyurtmalari, yangilari — tebranish bilan
• Buyurtma kartochkasi: manzil, xaridor va do‘konga qo‘ng‘iroq, Yandex Xaritalarda yo‘nalish, qancha naqd pul olish kerak
• Bugun, kecha va hafta tarixi, kassaga topshiriladigan naqd pul summasi bilan

GEOJOYLASHUV — FAQAT ISHLAYOTGANINGIZDA
Ilova geojoylashuvni faqat «Ищу заказы» yoqilganda, faol buyurtma bo‘lganda yoki smena davomida oladi. Bu vaqtda Android’da bildirishnoma, iPhone’da tizim geojoylashuv belgisi ko‘rinadi. Faqat oxirgi nuqta saqlanadi, harakatlar tarixi saqlanmaydi. Qidiruvni o‘chiring yoki smenani tugating — uzatish to‘xtaydi.

Akkauntni o‘chirish: Профиль → Удалить аккаунт.

Ilova interfeysi hozircha rus tilida.

Savollar va yordam: Telegram @super_market_support, +998 50 576 47 23.
```

Yangiliklar / What's New (≤4000) — 164 симв.
```text
SM Курьер’ning birinchi versiyasi: «yo‘l-yo‘lakay» kuryerlar uchun haqli buyurtmalar, darajalar va daromad; do‘kon kuryerlari uchun smena, buyurtmalar va yo‘nalish.
```

---

## 3. Google Play — тексты магазина

Общее для всех трёх: **Приложение**, **Бесплатное**, язык по умолчанию — **русский (ru-RU)**. Контакты в «Настройки
магазина»: email `<email поддержки>` (обязателен), телефон +998505764723, сайт https://super-market.uz.
Теги — до 5 из списка Play Console (названия в консоли могут отличаться, выбирайте ближайшие).

Заметки о выпуске Play пишутся в форме выпуска в таком виде (текст — из «Что нового» раздела 2):

```text
<ru-RU>
Первый выпуск …
</ru-RU>
<uz>
… birinchi versiyasi …
</uz>
```

### 3.1. Super Market — Google Play

- **Категория:** Еда и напитки (Food & Drink).
- **Теги:** Доставка продуктов / Grocery delivery, Продукты / Groceries, Покупки / Shopping, Доставка еды / Food delivery, Супермаркет.

Название (≤30) — 28 симв.
```text
Super Market: продукты рядом
```

Краткое описание (≤80) — 75 симв.
```text
Продукты из магазинов у дома: поиск по всем, Payme и Click, курьер на карте
```

Полное описание (≤4000): **тот же текст, что «Описание» в 2.2** ([RU](#client-description-ru)).

UZ — Nomi (≤30) — 29 симв.
```text
Super Market: yaqin do‘konlar
```

UZ — Qisqa tavsif (≤80) — 70 симв.
```text
Yaqin do‘konlardan mahsulotlar: qidiruv, Payme, Click, kuryer xaritada
```

UZ — To‘liq tavsif (≤4000): **тот же текст, что «Tavsif» в 2.2** ([UZ](#client-description-uz)).

### 3.2. SM Магазин — Google Play

- **Категория:** Бизнес (Business).
- **Теги:** Управление бизнесом / Business management, Розничная торговля / Retail, Учёт и склад / Inventory, POS, Продуктивность.

Название (≤30) — 25 симв.
```text
SM Магазин — Super Market
```

Краткое описание (≤80) — 71 симв.
```text
Заказы, приход по фото накладной, склад и финансы магазина Super Market
```

Полное описание (≤4000) — 1519 симв.

Текст как в iOS, плюс строка о подписке в «Деньги и контроль» (на Android счёт за подписку можно оплатить с
баланса магазина) и «отпечаток пальца» вместо Face ID:
```text
SM Магазин — приложение для владельцев и сотрудников продуктовых магазинов, подключённых к Super Market. Онлайн-заказы, склад и деньги магазина — в телефоне.

ЗАКАЗЫ
• Новые заказы из приложения Super Market — с уведомлением
• Принять, собрать и передать своему курьеру или курьеру «по пути»
• Выдача заказа курьеру «по пути» по коду

СКЛАД
• Приход по фото накладной: сфотографируйте накладную поставщика — ИИ распознает строки и сопоставит их с каталогом, останется проверить и провести
• Начало работы по фото полок и сканеру штрихкодов
• Остатки, возврат поставщику, долги поставщикам и акт сверки

ДЕНЬГИ И КОНТРОЛЬ
• Итоги дня: выручка, прибыль и что требует внимания
• Кассы и сдача кассы, контроль кассиров: недостачи, возвраты, скидки
• Баланс онлайн-заказов и заявки на вывод денег магазину
• Подписка: тариф, счета и оплата счёта с баланса
• Долги покупателей (насия): кто должен, лимиты, напоминания, приём оплаты

КОМАНДА
• Сотрудники и роли с правами
• Курьеры «по пути»: проверка документа в магазине и бонусы магазину
• Реклама брендов: доля магазина с показов, можно скрыть бренд

НАСТРОЙКА И БЕЗОПАСНОСТЬ
• Первая настройка: точка магазина на карте, часы работы, доставка
• Вход по номеру сотрудника и коду из Telegram, дальше — свой код из 4 цифр или отпечаток пальца
• Каждый сотрудник видит только то, что разрешает его роль

Аккаунт сотрудника заводит владелец сети в панели магазина. Удалить аккаунт: Ещё → Удалить аккаунт.

Вопросы и поддержка: Telegram @super_market_support, +998 50 576 47 23.
```

UZ — Nomi (≤30) — 25 симв.
```text
SM Магазин — Super Market
```

UZ — Qisqa tavsif (≤80) — 69 симв.
```text
Buyurtmalar, yuk xati surati bo‘yicha kirim, ombor va do‘kon moliyasi
```

UZ — To‘liq tavsif (≤4000): **текст «Tavsif» из 2.3** ([UZ](#store-description-uz-ios)); в блоке «PUL VA NAZORAT»
после строки о балансе можно добавить `• Obuna: tarif, hisob-fakturalar va balansdan to‘lash`, а «Face ID» заменить
на «barmoq izi».

### 3.3. SM Курьер — Google Play

- **Категория:** Бизнес (Business). Альтернатива — Карты и навигация, но приложение не навигатор (маршрут
  открывается в Яндекс Картах).
- **Теги:** Доставка / Delivery, Работа / Jobs, Подработка / Gig work, Бизнес.

Название (≤30) — 24 симв.
```text
SM Курьер — Super Market
```

Краткое описание (≤80) — 80 симв.
```text
Заказы из магазинов по пути: зарабатывайте на доставке. И для курьеров магазинов
```

Полное описание (≤4000): **тот же текст, что «Описание» в 2.4** ([RU](#courier-description-ru)).

UZ — Nomi (≤30) — 24 симв.
```text
SM Курьер — Super Market
```

UZ — Qisqa tavsif (≤80) — 63 симв.
```text
Do‘kon buyurtmalarini yo‘l-yo‘lakay yetkazing va daromad qiling
```

UZ — To‘liq tavsif (≤4000): **тот же текст, что «Tavsif» в 2.4** ([UZ](#courier-description-uz)).

---

## 4. App Store — «Конфиденциальность приложения» (App Privacy)

Для всех трёх: **Do you or your third-party partners collect data from this app? — Yes.**
**Tracking (отслеживание) — No** для каждого типа данных; `NSPrivacyTracking = false`, доменов отслеживания нет.
SDK аналитики и сбоев в проектах нет: в `pubspec.yaml` только `firebase_core` + `firebase_messaging` (push,
Super Market и SM Магазин), `yandex_mapkit` (карта, Super Market), `flutter_map` с тайлами OpenStreetMap (SM Магазин),
`geolocator`, `image_picker`, `mobile_scanner`, `local_auth`. Crashlytics, Firebase Analytics, AppMetrica и
рекламных SDK нет → **Crash Data, Performance Data, Other Diagnostic Data — не собираются.**

Как читать таблицы: «Связаны с пользователем» = Linked to you; «Цели» — Purposes в анкете
(App Functionality = функциональность приложения: вход, заказы, безопасность, предотвращение мошенничества).
Все строки таблиц ниже объявлены в `PrivacyInfo.xcprivacy` (`apps/client/ios/Runner/PrivacyInfo.xcprivacy`,
`apps/<app>/branding/ios/PrivacyInfo.xcprivacy`, см. release.md) с теми же флагами и целями — анкета и Privacy
Report из Xcode должны совпадать. Меняете сбор данных — правьте таблицу, манифест и политику вместе.

### 4.1. Super Market

| Категория → тип (App Store Connect) | Что именно | Связаны с пользователем | Для отслеживания | Цели |
|---|---|---|---|---|
| Contact Info → Name | имя, фамилия | Да | Нет | App Functionality |
| Contact Info → Phone Number | телефон для входа и заказа | Да | Нет | App Functionality |
| Contact Info → Physical Address | адреса доставки | Да | Нет | App Functionality |
| Location → Precise Location | точка адреса на карте, «Хочу доставку» | Да | Нет | App Functionality |
| Identifiers → User ID | ID аккаунта | Да | Нет | App Functionality |
| Purchases → Purchase History | заказы | Да | Нет | App Functionality; **Developer’s Advertising or Marketing** — пуш об акциях учитывает историю заказов (только с согласия, политика §4) |
| Identifiers → Device ID | push-токен Firebase | Да | Нет | App Functionality |
| Financial Info → Other Financial Info | долги (насия) в магазинах | Да | Нет | App Functionality |
| User Content → Other User Content | комментарии к заказу, списки «Моей семьи», «Это не я» | Да | Нет | App Functionality |
| Usage Data → Advertising Data | факт показа рекламы бренда (1 раз в день на пользователя, `ad_views`) — для расчёта с рекламодателем | Да | Нет | Third-Party Advertising |
| Usage Data → Product Interaction | обезличенные показы и нажатия блоков главной | Нет | Нет | Analytics |
| Other Data → Other Data Types | дата рождения и пол (по желанию) | Да | Нет | App Functionality |

Не собираются: Email, Contacts, Health, Fitness, Payment Info (карту вводят на страницах Payme/Click), Credit Info,
Photos, Audio, Browsing/Search History, Sensitive Info, Diagnostics.

⚠ Яндекс MapKit — сторонний SDK. После сборки откройте Xcode → Organizer → архив → **Generate Privacy Report**: если в
отчёте есть типы данных из манифеста Yandex MapKit (например, Device ID или Product Interaction), добавьте их в анкету.

### 4.2. SM Магазин

| Категория → тип | Что именно | Связаны | Отслеживание | Цели |
|---|---|---|---|---|
| Contact Info → Name | ФИО сотрудника; имена должников и курьеров, которых вносят сотрудники | Да | Нет | App Functionality |
| Contact Info → Phone Number | телефон сотрудника; телефоны должников | Да | Нет | App Functionality |
| Location → Precise Location | точка магазина на карте (по кнопке «я здесь») | Да | Нет | App Functionality |
| User Content → Photos or Videos | фото накладных, полок, товаров | Да | Нет | App Functionality |
| Identifiers → User ID | ID сотрудника | Да | Нет | App Functionality |
| Identifiers → Device ID | push-токен Firebase | Да | Нет | App Functionality |
| Financial Info → Payment Info | реквизиты для вывода денег (счёт, МФО или карта) | Да | Нет | App Functionality |
| Financial Info → Other Financial Info | выручка, кассы, баланс, долги покупателей и поставщикам | Да | Нет | App Functionality |
| Other Data → Other Data Types | данные проверки курьера «по пути»: ФИО, дата рождения, тип документа (номер — только хеш) | Да | Нет | App Functionality |

Face ID / отпечаток проверяются только на устройстве (`local_auth`) — **не** сбор данных. Тайлы OpenStreetMap и поиск
адреса Nominatim получают только запрос карты и строку поиска.

Реквизиты для вывода денег описаны в политике конфиденциальности (раздел 3.3).

### 4.3. SM Курьер

| Категория → тип | Что именно | Связаны | Отслеживание | Цели |
|---|---|---|---|---|
| Contact Info → Name | имя курьера | Да | Нет | App Functionality |
| Contact Info → Phone Number | телефон | Да | Нет | App Functionality |
| Location → Precise Location | точка во время «Ищу заказы», активного заказа или смены (на сервере только последняя) | Да | Нет | App Functionality |
| Identifiers → User ID | ID курьера, код KR-… | Да | Нет | App Functionality |
| Financial Info → Other Financial Info | начисления, удержания, выплаты (курьер «по пути») | Да | Нет | App Functionality |
| User Content → Customer Support | сообщение о проблеме с заказом | Да | Нет | App Functionality |

Push (Firebase) в приложении курьера нет. Точки «Дом»/«Работа» хранятся только на телефоне — не сбор.

---

## 5. Google Play — «Безопасность данных» (Data safety)

Общие ответы для всех трёх:

| Вопрос | Ответ |
|---|---|
| Собирает ли приложение или передаёт какие-либо из обязательных типов данных? | **Да** |
| Все ли данные шифруются при передаче? | **Да** (только HTTPS, cleartext в release запрещён) |
| Можно ли запросить удаление данных? | **Да**, в приложении и по ссылке https://super-market.uz/delete-account |
| Данные обрабатываются эфемерно? | Нет (для всех типов ниже) |
| Независимая проверка безопасности (MASA) | Нет |

**«Передача» (sharing) — нигде «Нет».** По определению Google не считается передачей: (1) передача **поставщикам
услуг**, которые обрабатывают данные по нашему поручению — Firebase Cloud Messaging, Яндекс MapKit, Eskiz (SMS),
Telegram (коды), Payme/Click, OpenAI/Anthropic (распознавание фото), OpenStreetMap/Nominatim; (2) передача, которую
начал сам пользователь и которую он ожидает: покупатель оформил заказ — магазин и курьер получают имя, телефон и
адрес; курьер вышел на смену — покупатель видит его точку (это раскрыто на экране перед запросом разрешения и в
политике); (3) передача по закону. Если хотите перестраховаться, отметить «Передаётся» не нарушение — но тогда
отметка появится в карточке.

**Аккаунты** (вопрос о создании аккаунта в форме): Super Market — да, номер телефона + одноразовый код;
SM Магазин — аккаунты создаются вне приложения (владелец сети в панели / регистрация магазина на сайте);
SM Курьер — курьер «по пути» создаёт аккаунт в приложении (телефон + код), штатному курьеру логин и пароль выдаёт
магазин. Ссылка на удаление для всех — https://super-market.uz/delete-account.

### 5.1. Super Market

| Тип данных (Play Console) | Собирается | Передаётся | Обязательно / по желанию | Цели |
|---|---|---|---|---|
| Местоположение → Приблизительное | Да | Нет | По желанию | Функции приложения |
| Местоположение → Точное | Да | Нет | По желанию (адрес можно выбрать на карте вручную) | Функции приложения |
| Личная информация → Имя | Да | Нет | Обязательно* | Функции приложения, Управление аккаунтом |
| Личная информация → Номер телефона | Да | Нет | Обязательно* | Функции приложения, Управление аккаунтом, Безопасность и предотвращение мошенничества |
| Личная информация → Адрес | Да | Нет | Обязательно* | Функции приложения |
| Личная информация → Идентификаторы пользователя | Да | Нет | Обязательно* | Функции приложения, Управление аккаунтом |
| Личная информация → Другое (дата рождения, пол) | Да | Нет | По желанию | Функции приложения |
| Финансовая информация → История покупок | Да | Нет | Обязательно* | Функции приложения, Реклама или маркетинг (акции — только с согласия), Безопасность и соблюдение закона (учёт) |
| Финансовая информация → Другое (долги «насия») | Да | Нет | По желанию | Функции приложения |
| Действия в приложении → Взаимодействие с приложением (показы рекламы брендов, нажатия блоков, избранное) | Да | Нет | Обязательно | Функции приложения, Аналитика, Реклама или маркетинг |
| Действия в приложении → Другой контент, созданный пользователем (комментарии, списки семьи, «Это не я») | Да | Нет | По желанию | Функции приложения |
| Идентификаторы устройства или другие (push-токен FCM) | Да | Нет | По желанию | Функции приложения, Связь с разработчиком |

\* Обязательно для заказа; смотреть магазины можно без входа.
Не собираются: эл. почта, платёжные данные (карту вводят у Payme/Click), фото, файлы, контакты, сообщения, здоровье,
аудио, календарь, история браузера, установленные приложения, сбои и диагностика.

### 5.2. SM Магазин

| Тип данных | Собирается | Передаётся | Обязательно / по желанию | Цели |
|---|---|---|---|---|
| Местоположение → Приблизительное, Точное | Да | Нет | По желанию (точку можно поставить на карте вручную) | Функции приложения |
| Личная информация → Имя, Номер телефона | Да | Нет | Обязательно | Функции приложения, Управление аккаунтом, Безопасность и предотвращение мошенничества |
| Личная информация → Идентификаторы пользователя | Да | Нет | Обязательно | Функции приложения, Управление аккаунтом |
| Личная информация → Другое (проверка курьера: ФИО, дата рождения, тип документа; номер — хеш) | Да | Нет | По желанию | Функции приложения, Безопасность и предотвращение мошенничества |
| Фото и видео → Фото (накладные, полки, товары) | Да | Нет (ИИ-сервис — поставщик услуг) | По желанию | Функции приложения |
| Финансовая информация → Платёжная информация (реквизиты для вывода) | Да | Нет | По желанию | Функции приложения |
| Финансовая информация → Другое (выручка, баланс, долги) | Да | Нет | Обязательно | Функции приложения |
| Действия в приложении → Другие действия (журнал: продажи, документы, история заказов) | Да | Нет | Обязательно | Функции приложения, Безопасность и предотвращение мошенничества |
| Идентификаторы устройства (push-токен FCM) | Да | Нет | По желанию | Функции приложения |

Отпечаток пальца/лицо проверяются на устройстве — не указывать.

### 5.3. SM Курьер

| Тип данных | Собирается | Передаётся | Обязательно / по желанию | Цели |
|---|---|---|---|---|
| Местоположение → Приблизительное, Точное | Да | Нет | Обязательно (без него нет ленты и смены) | Функции приложения |
| Личная информация → Имя, Номер телефона | Да | Нет | Обязательно | Функции приложения, Управление аккаунтом, Безопасность и предотвращение мошенничества |
| Личная информация → Идентификаторы пользователя | Да | Нет | Обязательно | Функции приложения, Управление аккаунтом |
| Финансовая информация → Другое (начисления, выплаты) | Да | Нет | По желанию (только курьер «по пути») | Функции приложения |
| Действия в приложении → Другие действия (принятые и доставленные заказы, коды выдачи) | Да | Нет | Обязательно | Функции приложения, Безопасность и предотвращение мошенничества |
| Действия в приложении → Другой контент пользователя (сообщение о проблеме) | Да | Нет | По желанию | Функции приложения |

Push-токенов нет (Firebase в приложении курьера не подключён).

---

## 6. Google Play — остальные разделы «Содержание приложения» (App content)

### 6.1. Сводка ответов

| Раздел | Super Market | SM Магазин | SM Курьер |
|---|---|---|---|
| Политика конфиденциальности | https://super-market.uz/privacy | то же | то же |
| Доступ к приложению (App access) | Часть функций требует входа → инструкции (раздел 7.2) | Все функции требуют входа → инструкции | Все функции требуют входа → инструкции (2 аккаунта) |
| Реклама (Ads) | **Да** — блоки брендов с пометкой «Реклама» на главной (прямые продажи, без рекламных SDK) | Нет | Нет |
| Рейтинг контента (IARC) | см. 6.2 | см. 6.2 | см. 6.2 |
| Целевая аудитория | **16–17 и 18+** (политика, раздел 14: не для лиц младше 16) | **18+** | **18+** (курьер «по пути» — с 18 лет по документу) |
| Привлекает детей? | Нет | Нет | Нет |
| Новостное приложение | Нет | Нет | Нет |
| COVID-19 (если раздел есть) | Не приложение для отслеживания контактов/статуса | то же | то же |
| Безопасность данных | раздел 5.1 | 5.2 | 5.3 |
| Государственное приложение | Нет | Нет | Нет |
| Финансовые функции | «Нет финансовых функций» (см. 6.3) | «Нет финансовых функций» | «Нет финансовых функций» |
| Здоровье | Нет функций здоровья | Нет | Нет |
| Рекламный идентификатор (Advertising ID) | **Нет** — `AD_ID` не нужен (нет Firebase Analytics и рекламных SDK). Проверьте объединённый манифест AAB: разрешения `com.google.android.gms.permission.AD_ID` быть не должно | Нет | Нет |
| Разрешения фоновых служб (FGS) | не используется | не используется | **FOREGROUND_SERVICE_LOCATION** — см. 6.4 |
| Местоположение в фоне | `ACCESS_BACKGROUND_LOCATION` нет — декларация не нужна | то же | то же (только «во время использования», см. 6.4) |
| Фото и видео (READ_MEDIA_*) | не используется | не нужна: `image_picker` открывает системный выбор фото, разрешений READ_MEDIA_* в манифесте нет | не используется |

### 6.2. Рейтинг контента (анкета IARC)

Email для сертификата — `<email поддержки>`. Категория: **«Все остальные типы приложений» (All Other App Types)**.

| Вопрос | Super Market | SM Магазин | SM Курьер |
|---|---|---|---|
| Насилие, страх, сексуальный контент, нецензурная лексика, грубый юмор | Нет | Нет | Нет |
| Наркотики, алкоголь, табак (упоминание, продажа) | Нет (⚠ см. 2.1 — только если такие товары не продаются онлайн) | Нет | Нет |
| Азартные игры, имитация азартных игр | Нет | Нет | Нет |
| Пользователи могут общаться или обмениваться контентом (Users Interact) | **Да** — «Моя семья»: общие списки и просьбы «Попросить купить» между приглашёнными членами семьи | Нет | Нет |
| Передаёт личные данные пользователя третьим лицам (Shares Info) | **Да** — имя, телефон и адрес получает магазин и курьер заказа | Нет | **Да** — имя, телефон и транспорт курьера видит покупатель |
| Передаёт текущее местоположение пользователя другим пользователям (Shares Location) | Нет | Нет | **Да** — покупатель видит курьера на карте |
| Покупка цифровых товаров (Digital Purchases) | Нет — только физические товары | Нет | Нет |
| Неограниченный доступ в интернет (Unrestricted Internet) | Нет | Нет | Нет |
| **Ожидаемый итог** | IARC 3+, PEGI 3, ESRB Everyone; пометки «Взаимодействие пользователей», «Передача данных» | 3+ / PEGI 3 / Everyone | 3+ / PEGI 3 / Everyone; «Передача данных», «Передача местоположения» |

### 6.3. Финансовые функции — почему «нет»

Отвечайте **«Моё приложение не предоставляет финансовых функций»** во всех трёх:

- оплата картой идёт на страницах Payme и Click (лицензированные платёжные системы); приложение карту не принимает и
  деньги не переводит — это оплата физических товаров;
- **«Мои долги» / «Долги покупателей» (насия)** — журнал магазина о товарах, отпущенных в долг по договорённости с
  покупателем. Кредит выдаёт не приложение и не Super Market, процентов, кредитных лимитов от платформы, займов и
  «купи сейчас — плати потом» с рассрочкой нет. Это учёт, а не кредитование;
- вывод баланса магазина и выплаты курьерам — расчёты платформы с продавцами и исполнителями за проданные товары и
  доставку, а не банковская услуга для пользователя.

Если Google всё же запросит уточнение — выберите «Другое» и вставьте:

```text
The app does not lend money or provide credit. "Nasiya" is a store's ledger of goods a local shop sold to its regular customer on deferred payment by their own agreement; the app only shows the record to the customer. Card payments for physical goods are processed on Payme and Click pages; the app does not store card data or transfer money.
```

### 6.4. Декларация фоновой службы для SM Курьер (FOREGROUND_SERVICE_LOCATION)

Что в коде:

- разрешения (`apps/courier/branding/apply.sh`): `ACCESS_FINE_LOCATION`, `ACCESS_COARSE_LOCATION`, `FOREGROUND_SERVICE`,
  `FOREGROUND_SERVICE_LOCATION`, `WAKE_LOCK`, `VIBRATE`, `POST_NOTIFICATIONS`; **`ACCESS_BACKGROUND_LOCATION` нет**;
- служба запускается через `geolocator` (`ForegroundNotificationConfig`):
  - курьер магазина — после нажатия **«Выйти на смену»**, уведомление **«Вы на смене»** / «Покупатели видят, где их
    заказ» (`apps/courier/lib/state.dart`); точка каждые ~10 с;
  - курьер «по пути» — пока включено **«Ищу заказы»** или есть принятый заказ, уведомление **«Ищу заказы по пути»** /
    «Super Market подбирает заказы рядом с вами» (`apps/courier/lib/crowd/crowd_state.dart`); точка каждые 10–15 с;
- перед системным запросом — свой экран «Разрешите доступ к геопозиции» с кнопками «Продолжить» / «Не сейчас»
  (`apps/courier/lib/ui/location_disclosure.dart`);
- служба останавливается при «Завершить смену» / выключении «Ищу заказы» без активных заказов, при выходе из аккаунта.

В Play Console: Содержание приложения → **Разрешения фоновых служб** → тип **Location** → вариант использования
**«Передача местоположения, инициированная пользователем» (User-initiated location sharing)**.

Описание (на английском, его читает команда проверки) (≤4000) — 1240 симв.
```text
SM Courier is used by delivery couriers of local grocery stores. The courier starts the foreground service himself: a store courier taps "Выйти на смену" (Start shift); a crowd courier turns on "Ищу заказы" (Looking for orders) or accepts an order. Before the first start the app shows its own screen explaining why location is needed, then the system permission dialog (foreground "while using the app" only; ACCESS_BACKGROUND_LOCATION is not requested).

While the service runs, a persistent notification is shown: "Вы на смене — Покупатели видят, где их заказ" for store couriers, "Ищу заказы по пути — Super Market подбирает заказы рядом с вами" for crowd couriers. The app sends the courier's location to our server every 10-15 seconds so that the customer sees the courier on the map and the arrival time, and so that orders near the courier's route can be offered. The service must keep working while the courier uses the navigation app (Yandex Maps), talks on the phone or locks the screen, so a foreground service is required.

Location sharing stops as soon as the courier ends the shift or turns off "Ищу заказы" and has no active order; the notification disappears. Only the last point is stored on the server, no route history.
```

Перевод для владельца: курьер сам запускает службу («Выйти на смену» / «Ищу заказы» / принял заказ); перед запросом —
экран-объяснение, разрешение только «во время использования»; пока служба работает — постоянное уведомление, точка
раз в 10–15 с для карты покупателя и подбора заказов; служба нужна, чтобы передача шла, пока курьер в Яндекс Картах,
говорит по телефону или выключил экран; останавливается сразу после конца смены / выключения поиска.

**Видео (20–30 с, ссылка YouTube «доступ по ссылке» или Google Drive с открытым доступом).** Снимайте запись экрана
Android-телефона:

| Секунды | Что показать |
|---|---|
| 0–4 | Открыть SM Курьер (вход как «Сотрудник магазина», логин `review`), экран «Вы не на смене» |
| 4–10 | Нажать **«Выйти на смену»** → экран «Разрешите доступ к геопозиции» → «Продолжить» → системный диалог → **«При использовании приложения»** |
| 10–15 | Статус «На смене»; опустить шторку — уведомление **«Вы на смене»** |
| 15–21 | Открыть заказ → «Маршрут» (откроются Яндекс Карты) или нажать «Домой» — уведомление остаётся в шторке |
| 21–25 | (по желанию) Второй телефон с Super Market: курьер на карте заказа |
| 25–30 | Вернуться в SM Курьер → **«Завершить смену»** → уведомление исчезло |

Можно добавить второе видео или продолжение: режим «Курьер по пути» → «Ищу заказы» → уведомление «Ищу заказы по
пути» → выключить «Ищу заказы» → уведомление исчезло.

### 6.5. Разрешения на местоположение (все три)

Только передний план: `ACCESS_FINE_LOCATION` / `ACCESS_COARSE_LOCATION`. Super Market — показать магазины рядом и
поставить точку адреса, SM Магазин — поставить точку магазина, SM Курьер — смена и «Ищу заказы» (через службу из 6.4).
Отдельная декларация «Location permissions» в Play Console нужна только для `ACCESS_BACKGROUND_LOCATION` — её нет.

---

## 7. Заметки для проверки и доступ к приложениям

### 7.0. Подготовка (до отправки, делает владелец)

1. На проде должны быть демо-данные и демо-доступ: GitHub → Actions → **demo-data** → `seed` (если ещё не было), затем
   **`review`**. В `PROD_ENV` должен быть `REVIEW_LOGIN=+998900000077:343549`. Команда в конце печатает блок
   «Демо-доступ для проверки приложений» — возьмите оттуда **пароль курьера магазина** и вставьте вместо
   `<пароль из demo review>` ниже (пароль постоянный, повторный запуск его не меняет).
2. `review` добавляет покупателю адрес **«Дом»** (Чиланзар, 9-й квартал, 20) рядом с **Baraka Market — Чиланзар**
   (Ташкент, 41.2856, 69.2044), делает номер сотрудником Baraka Market со всеми правами, курьером «по пути» с
   подтверждённой личностью, и заводит штатного курьера `review` («Курьер для проверки»).
3. Заказов демо-команда не создаёт. Чтобы проверяющий курьерского приложения увидел заказ: оформите в Super Market
   (с демо-номера) заказ в Baraka Market наличными, примите и соберите его в SM Магазин, в панели магазина
   (store.super-market.uz) назначьте курьера «Курьер для проверки». Для режима «по пути» — второй заказ, предложенный
   курьерам «по пути». Обновите перед каждой отправкой.
4. Приход по фото накладной работает, только если супер-админ настроил «ИИ-сервис» — проверьте.
5. Номер `+998 90 000 00 77` — служебный: код не отправляется, всегда подходит `343549`.

### 7.1. App Store — App Review Information

Для всех трёх: **Sign-in required — Yes**. Контакт: имя, фамилия, телефон `+998 50 576 47 23`, email `<email поддержки>`.
Поле «User name» — `900000077` (поле номера в приложениях уже содержит +998), «Password» — `343549`.
В SM Курьер логин/пароль штатного курьера — в заметках.

Во всех трёх приложениях поле номера устроено одинаково: «+998» стоит перед полем, вводятся 9 цифр
(`90 000 00 77`; вставка полного номера с +998 тоже работает).

#### Super Market — Notes (≤4000) — 2292 симв.
```text
Super Market is a marketplace of local grocery stores in Uzbekistan: customers order groceries from stores near their address, and the store itself picks and delivers the order.

DEMO ACCOUNT
On first launch you can tap "Продолжить без входа" (continue without login) and browse stores and products as a guest. To log in: Профиль (Profile) > log in. The phone field already shows the +998 country code, enter 9 digits: 90 000 00 77. Tick the consent checkbox (public offer and privacy policy) and tap "Получить код". Code: 343549 (no SMS or Telegram message is sent for this demo number; always enter this code).

LOCATION OF DEMO DATA
The demo store is "Baraka Market" in Tashkent (Chilanzar district). After login the saved address "Дом" (Chilanzar, Tashkent) is used, so the home screen shows the store. As a guest, on the "Куда доставить?" map choose a point in Tashkent, Chilanzar (about 41.2856, 69.2044) and tap "Показать магазины рядом". On a simulator you can also set this custom location.

TEST ORDER
Add products from Baraka Market to the cart and check out. Choose "Наличными курьеру" (cash to courier) if you do not want to pay; card payment opens the Payme or Click payment page (licensed payment providers in Uzbekistan). All purchases are physical goods delivered outside the app (guideline 3.1.3(e)); there are no digital goods or subscriptions in this app.

ACCOUNT DELETION
Профиль > Настройки > Удалить аккаунт. The account is deleted immediately (if an order is in progress, the app asks to wait for it). Web form for users without the app: https://super-market.uz/delete-account

LOGIN METHOD
The account is the user's phone number confirmed with a one-time code sent by SMS or by our Telegram bot. There is no third-party or social login (Telegram only delivers the code), so Sign in with Apple is not required (guideline 4.8).

NOTIFICATIONS AND ADS
Push notifications are used for order status. Promotional notifications are off by default; the app asks once after the first order and they can be turned off in Профиль > Настройки > Уведомления (guideline 4.5.4). Blocks of brands on the home screen are marked "Реклама" (ad); they are sold directly to brands, chosen by store and city, not by user profile. No ad SDKs, no tracking.

The app interface is in Russian.
```

Перевод для владельца: магазины рядом и заказ; гостевой просмотр «Продолжить без входа»; вход — Профиль → номер
9 цифр `90 000 00 77`, флажок согласия, код `343549` (не приходит, вводить всегда этот); демо-магазин Baraka Market в
Ташкенте (Чиланзар), после входа выбран адрес «Дом», гостю — выбрать точку в Чиланзаре; тестовый заказ — наличными,
оплата картой — страницы Payme/Click, только физические товары (3.1.3(e)); удаление — Профиль → Настройки → Удалить
аккаунт, веб-форма; вход по номеру и коду, сторонних входов нет, Sign in with Apple не нужен (4.8); push об акциях
выключены по умолчанию (4.5.4); реклама брендов помечена, без SDK и отслеживания.

#### SM Магазин — Notes (≤4000) — 2140 симв.
```text
SM Магазин is a business app for owners and staff of grocery stores connected to the Super Market platform: online orders, stock, receiving goods by a photo of the supplier's invoice, cash desks, debts and staff.

DEMO ACCOUNT
The phone field already shows +998, enter 9 digits: 90 000 00 77. Code: 343549 (no message is sent for this demo number; always enter this code). After login the app asks you to create a local 4-digit passcode (any digits, it protects the app on this phone); Face ID is optional. The demo account is an employee with all permissions in the demo network "Baraka Market" (Tashkent, Chilanzar).

WHAT TO CHECK
Главная (summary), Заказы (orders from the customer app), Склад (stock; "Приход" — take a photo of an invoice, it is recognized by an AI service), Финансы (cash desks, profit, balance), Ещё (customer and supplier debts, staff, crowd couriers, brand ads, passcode and Face ID, privacy policy, account deletion). Camera and photos are used only for invoices, shelves and products; location only to put the store on the map.

ACCOUNTS AND DELETION
Staff accounts are created by the store owner in the web panel; the app has no sign-up. Account deletion: Ещё > Удалить аккаунт sends a deletion request (for a network owner it means closing the network); it is processed within 30 days, the user sees the confirmation. Web form: https://super-market.uz/delete-account

PAYMENTS
The app does not sell anything to its users and has no in-app purchases. The Super Market platform service is sold to businesses (stores and store networks) under a B2B agreement and invoiced outside the app (guideline 3.1.3(c), enterprise services). On iOS the subscription screen is informational only (status and paid-until date): there are no payment buttons, links or calls to action. The "Баланс" screen shows the store's revenue from customers' online orders for physical goods (3.1.3(e)) and lets the store request a payout to its bank account.

LOGIN METHOD
Phone number and a one-time code from our Telegram bot. No third-party or social login, so Sign in with Apple is not required (4.8).

The app interface is in Russian.
```

Перевод для владельца: приложение для магазинов; вход `90 000 00 77` + `343549`, потом придумать любой код из
4 цифр, Face ID по желанию; демо-сотрудник со всеми правами в Baraka Market; что смотреть по вкладкам; камера/фото
только для накладных и товаров, геопозиция — точка магазина; аккаунты создаёт владелец, регистрации в приложении нет;
удаление — Ещё → Удалить аккаунт (запрос, до 30 дней); **оплата:** в приложении ничего не продаётся, сервис платформы
продаётся бизнесу по договору и счёту вне приложения — **3.1.3(c) Enterprise Services**; на iOS подписка только для
просмотра, без кнопок оплаты и ссылок; баланс — выручка магазина за физические товары (3.1.3(e)); вход по коду из
Telegram, сторонних входов нет (4.8).

> Почему 3.1.3(c): правило разрешает не использовать встроенные покупки, если сервис продаётся организациям, а не
> частным лицам. Магазины платят за платформу (панель, кассу, витрину) как бизнес. 3.1.3(f) (бесплатное приложение-
> компаньон к платному веб-сервису) тоже подходит по смыслу, но требует, чтобы в приложении вообще не было покупок и
> призывов к ним — у нас так и есть на iOS. Ссылаемся на (c), а описание экрана подписки закрывает (f).
> На iOS цен подписки нет: карточка (`SubscriptionInfoCard`) показывает только тариф, «Магазинов: N», «Оплачено до» и
> статус, сводка во вкладке «Финансы» — «Подписка · магазинов N». Цена в $ и оплата счетов — только на Android.

#### SM Курьер — Notes (≤4000) — 2566 симв.
```text
SM Курьер is the app for couriers who deliver orders of local grocery stores connected to Super Market. It has two modes, chosen on the login screen.

1) "Курьер по пути" (crowd courier, default tab)
The phone field already shows +998, enter 9 digits: 90 000 00 77. Tick the checkbox (courier terms and privacy policy). Code: 343549 (no SMS is sent for this demo number; always enter this code). The identity of this demo courier is already verified. Turn on "Ищу заказы" (looking for orders): the app shows its own explanation screen, then asks for location "while using the app". The feed shows ready orders of stores near you and on your way. Demo stores are in Tashkent (Chilanzar, about 41.2856, 69.2044): outside Uzbekistan the feed can be empty; on a simulator set this custom location. Tabs: Лента (feed), Заработок (earnings), Профиль (level, transport, terms, privacy policy, account deletion).
Account deletion: Профиль > Удалить аккаунт — deleted immediately (the app asks to finish active orders first).

2) "Сотрудник магазина" (store courier)
Switch to "Сотрудник магазина". Login: review, password: <пароль из demo review>. Tap "Выйти на смену" (start shift) to see orders assigned by the store, the order card with the route (opens Yandex Maps) and call buttons, and "Забрал" / "Доставил". History tab shows deliveries and cash to hand over. Store courier accounts are created by the store, so Профиль > Удалить аккаунт sends a deletion request, processed within 30 days. Web form: https://super-market.uz/delete-account

LOCATION
Location is used only while the courier works: during a shift, while "Ищу заказы" is on, or while the courier has an active order. It is sent every 10-15 seconds so the customer sees the courier on the map with arrival time, and so orders on the courier's way can be offered. The app requests "While Using the App" permission only. Because couriers switch to Yandex Maps or lock the phone during delivery, the app uses the "location" background mode to continue updates that the courier started; iOS shows the blue location indicator all the time. Updates stop when the shift ends or "Ищу заказы" is turned off with no active orders. Only the last point is stored, no route history.

PAYMENTS
No in-app purchases. Crowd couriers receive a fee for each delivery to their balance, paid out weekly outside the app.

LOGIN METHOD
Phone number with a one-time SMS code, or login and password issued by the store. No third-party or social login, so Sign in with Apple is not required (4.8).

The app interface is in Russian.
```

Перевод для владельца: два режима на экране входа. «Курьер по пути»: `90 000 00 77`, флажок условий, код `343549`,
личность уже подтверждена, «Ищу заказы» → экран-объяснение → разрешение «при использовании»; демо-магазины в
Ташкенте — вне Узбекистана лента может быть пустой, в симуляторе задать точку; удаление — Профиль → Удалить аккаунт
(сразу). «Сотрудник магазина»: логин `review`, пароль из `demo review`, «Выйти на смену», заказы, маршрут, звонки;
удаление — запрос, до 30 дней. Геопозиция только во время работы, раз в 10–15 с, разрешение только «при
использовании», фоновый режим location продолжает начатую курьером передачу с синим индикатором, хранится только
последняя точка. Покупок нет. Вход по коду или логину, Sign in with Apple не нужен.

### 7.2. Google Play — «Доступ к приложению» (App access)

Выберите «Все или некоторые функции приложения недоступны без входа» и добавьте инструкции. Тексты на английском
(можно продублировать русским в поле «Другая информация»).

**Super Market** — одна инструкция:

- Название: `Demo customer`
- Имя пользователя: `900000077`
- Пароль: `343549`
- Другая информация — 366 симв.
```text
Login: Профиль > log in. The +998 prefix is already in the phone field, enter 900000077. Tick the consent checkbox. Code 343549 (no SMS is sent for this number). Demo store Baraka Market is in Tashkent (Chilanzar); the saved address "Дом" is selected after login. Guests can browse via "Продолжить без входа". Account deletion: Профиль > Настройки > Удалить аккаунт.
```

**SM Магазин** — одна инструкция:

- Название: `Demo store employee`
- Имя пользователя: `900000077`
- Пароль: `343549`
- Другая информация — 284 симв.
```text
The +998 prefix is already in the phone field, enter 900000077, code 343549 (no message is sent for this number). Then create any 4-digit app passcode. The demo employee has all permissions in the demo network Baraka Market (Tashkent). Account deletion request: Ещё > Удалить аккаунт.
```

**SM Курьер** — две инструкции:

- `Crowd courier`: имя пользователя `900000077`, пароль `343549`, другая информация — 387 симв.
```text
Login tab "Курьер по пути" (default). The +998 prefix is in the field, enter 900000077, tick the terms checkbox, code 343549 (no SMS is sent). Identity is already verified. Turn on "Ищу заказы" and allow location while using the app; a notification "Ищу заказы по пути" is shown while it is on. Demo stores are in Tashkent (41.2856, 69.2044). Account deletion: Профиль > Удалить аккаунт.
```
- `Store courier`: имя пользователя `review`, пароль `<пароль из demo review>`, другая информация — 217 симв.
```text
Login tab "Сотрудник магазина". Tap "Выйти на смену": the foreground service notification "Вы на смене" is shown during the shift; tap "Завершить смену" to stop it. Account deletion request: Профиль > Удалить аккаунт.
```

---

## 8. Скриншоты и графика

### 8.1. Размеры

| Магазин | Что | Размер | Сколько |
|---|---|---|---|
| App Store | iPhone 6,9" (портрет) | **1320×2868** (или 1290×2796) PNG/JPG без прозрачности | 1–10, рекомендуем 6. Приложения только для iPhone (`TARGETED_DEVICE_FAMILY = 1`) — скриншоты iPad **не нужны**; меньшие iPhone App Store масштабирует сам |
| App Store | Иконка 1024×1024 | уже в сборке (`AppIcon.appiconset`) | — |
| Google Play | Скриншоты телефона | 9:16, например **1080×1920**; каждая сторона 320–3840 px, длинная сторона не больше двух коротких (1080×2400 **не подойдёт**) | 2–8, для рекомендаций — минимум 4 шириной от 1080 px |
| Google Play | Значок | **512×512** PNG 32-бит, до 1 МБ | 1 |
| Google Play | Баннер (Feature graphic) | **1024×500** JPG или PNG 24-бит без прозрачности | 1 |

Снимайте на демо-данных (Baraka Market, демо-товары) — без реальных телефонов, имён и адресов покупателей. Статус-бар
чистый (полный заряд, время 9:41). Подписи ниже — заголовок над экраном; ≤30 символов.

Баннер Google Play (идея): логотип + одна фраза на красном фоне `#E11D2A` — Super Market: «Продукты из магазинов у
дома»; SM Магазин: «Магазин в телефоне»; SM Курьер: «Доставляйте по пути». UZ: «Uy yonidagi do‘kon mahsulotlari»,
«Do‘kon telefoningizda», «Yo‘l-yo‘lakay yetkazing».

### 8.2. Super Market

| № | Экран | Подпись RU | Подпись UZ |
|---|---|---|---|
| 1 | Главная: магазины, которые доставляют по адресу «Дом» | Магазины у дома привезут сами | Uy yonidagi do‘konlardan |
| 2 | Поиск по всем магазинам (например, «молоко»): цены в разных магазинах | Ищите товар сразу везде | Barcha do‘konlardan qidiring |
| 3 | Витрина Baraka Market: категории и акции | Акции и скидки магазинов | Do‘konlar aksiyalari |
| 4 | Корзина и выбор оплаты Payme / Click | Оплата через Payme и Click | Payme va Click orqali to‘lov |
| 5 | Заказ в пути: курьер на карте и время прибытия | Курьер на карте | Kuryer xaritada |
| 6 | «Моя семья» — общий список покупок | Общий список для семьи | Oila uchun umumiy ro‘yxat |

### 8.3. SM Магазин

| № | Экран | Подпись RU | Подпись UZ |
|---|---|---|---|
| 1 | Главная: выручка за сегодня, быстрые действия | Выручка и итоги дня | Kunlik tushum va natijalar |
| 2 | Заказы: новые заказы | Онлайн-заказы в телефоне | Onlayn buyurtmalar telefonda |
| 3 | Приход: распознанная накладная, строки сопоставлены | Приход по фото накладной | Yuk xati surati bo‘yicha kirim |
| 4 | Склад: остатки | Остатки всегда под рукой | Qoldiqlar doim qo‘l ostida |
| 5 | Финансы: кассы и прибыль (**на iOS — без карточки подписки и цены**) | Кассы и прибыль | Kassalar va foyda |
| 6 | Долги покупателей (насия) | Насия под контролем | Nasiya nazorat ostida |

### 8.4. SM Курьер

| № | Экран | Подпись RU | Подпись UZ |
|---|---|---|---|
| 1 | Лента «По пути» с заказами и вознаграждением | Заказы по пути | Yo‘l-yo‘lakay buyurtmalar |
| 2 | Карточка заказа «по пути»: магазин, покупатель, вознаграждение | Заработок за каждую доставку | Har bir yetkazish uchun haq |
| 3 | «Заработок»: к выплате, движения | Выплата каждую неделю | Har hafta to‘lov |
| 4 | Профиль: уровень и прогресс | Больше доставок — выше уровень | Yetkazing va darajani oshiring |
| 5 | Курьер магазина: «На смене», заказы «Везу» | Курьер магазина: смена | Do‘kon kuryeri: smena |
| 6 | Карточка заказа штатного курьера: маршрут, звонки, наличные | Маршрут и звонок сразу | Yo‘nalish va qo‘ng‘iroq |

---

## 9. Порядок отправки (чек-лист)

### 9.1. Перед обоими магазинами

- [ ] Открываются https://super-market.uz/privacy, /privacy/uz, /delete-account, /courier-terms, **/offer, /offer/stores**.
- [ ] Заведён email поддержки (нужен Google Play и App Review).
- [ ] Прод: `demo seed` → `demo review`, пароль курьера `review` записан; тестовые заказы для курьера (7.0, п. 3).
- [ ] ИИ-сервис настроен (приход по фото); Payme/Click работают или включены наличные у Baraka Market.
- [ ] В витрине нет табака/вейпов и алкоголя (2.1).
- [ ] Скриншоты сняты (раздел 8), на iOS-скриншотах SM Магазин нет подписки и цен.

### 9.2. App Store Connect (для каждого из трёх)

1. [ ] Apple Developer → Identifiers: bundle id (`uz.supermarket.smClient` / `smStore` / `smCourier`) с Push
       Notifications для покупателя и магазина.
2. [ ] App Store Connect → Мои приложения → «+» → Новое приложение: платформа iOS, имя (2.x), основной язык
       **Russian**, bundle id, SKU (например, `sm-client`, `sm-store`, `sm-courier`).
3. [ ] Загрузить сборку (Xcode 26, release.md) → TestFlight → проверить на iPhone (вход демо-номером, push у покупателя
       и магазина, геопозиция курьера в фоне).
4. [ ] Xcode → Organizer → Generate Privacy Report — сверить с разделом 4.
5. [ ] App Information: подзаголовок, категории (2.x), Content Rights — «содержит сторонний контент, права есть»
       (фото и данные товаров магазинов, карты), возрастной рейтинг (2.1).
6. [ ] Pricing and Availability: бесплатно; страны — **Узбекистан** (сервис работает только там; проверяющий из США
       всё равно получит сборку). Если выберете страны ЕС — понадобится статус трейдера по DSA.
7. [ ] App Privacy: Privacy Policy URL + типы данных (раздел 4).
8. [ ] Страница версии: скриншоты 6,9", промотекст, описание, ключевые слова, Support URL, Marketing URL, Copyright,
       сборка; App Review Information — вход и заметки (7.1); выпуск — «вручную после одобрения».
9. [ ] Экспортное шифрование: в Info.plist уже `ITSAppUsesNonExemptEncryption = false` — вопрос не появится.
10. [ ] Add for Review → Submit. Ответы проверяющему — в Resolution Center.
11. [ ] После одобрения — выпустить, вставить ссылки App Store в `LINKS` на сайте (`web/site/landing.js`).

### 9.3. Google Play Console (для каждого из трёх)

1. [ ] Создать приложение: название (3.x), язык по умолчанию **русский (ru-RU)**, «Приложение», «Бесплатное»,
       подтвердить правила.
2. [ ] Play App Signing — оставить включённым (release.md).
3. [ ] Содержание приложения: политика конфиденциальности → доступ к приложению (7.2) → реклама (6.1) → рейтинг
       контента (6.2) → целевая аудитория (6.1) → новости → безопасность данных (5.x) → государственное →
       финансовые функции (6.3) → здоровье → рекламный идентификатор → **для курьера: разрешения фоновых служб + видео (6.4)**.
4. [ ] Настройки магазина: категория, теги, контакты (3.x).
5. [ ] Основная страница: название, краткое и полное описание (ru-RU; uz — если язык доступен), значок 512, баннер
       1024×500, скриншоты.
6. [ ] Тестирование → Внутреннее: загрузить AAB (`client-aab` / `store-aab` / `courier-aab` из workflow `release`),
       проверить на телефоне.
7. [ ] Если аккаунт разработчика **личный** и создан после 13.11.2023: закрытое тестирование минимум с **12
       тестировщиками 14 дней подряд**, потом «Заявка на доступ к рабочей версии». У аккаунта организации этого шага нет.
8. [ ] Рабочая версия → страны: **Узбекистан** → создать выпуск → тот же AAB → заметки о выпуске (формат в разделе 3)
       → отправить на проверку.
9. [ ] После публикации — ссылки Google Play в `LINKS` на сайте.
