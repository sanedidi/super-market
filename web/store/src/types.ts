// Типы ответов API (поля — json-теги структур Go). Деньги и количество — строки.
// Объявлены через type, чтобы подходить под RemoteSelect (Record<string, unknown>).

export type Network = { id: string; name: string; kind: 'chain' | 'single'; status: string; business_type?: 'store' | 'cafe' | 'restaurant' }

export type Me = {
  user_id: string
  employee_id: string
  network: Network
  is_owner: boolean
  permissions: string[]
  all_stores: boolean
  store_ids: string[] | null
  full_name?: string
  role_name?: string
  phone?: string
  must_change_password?: boolean
}

export type Store = {
  id: string
  name: string
  address: string
  phone: string
  lat: number | null
  lng: number | null
  status: string
  default_warehouse_id: string | null
  online_price_type_id: string | null
  created_at: string
  logo_url: string
  city: string
}

export type Warehouse = { id: string; store_id: string; name: string; is_active: boolean; is_default: boolean }

export type Product = {
  id: string
  network_id: string | null
  name: string
  description: string
  brand_id: string | null
  brand_name: string | null
  category_id: string
  category_name: string
  unit_id: string
  unit_short: string
  is_fractional: boolean
  color_id: string | null
  base_price: string
  images: string[] | null
  barcodes: string[] | null
  moderation_status: string
  rejection_reason: string
  is_active: boolean
  price?: string
  price_source?: string
  price_type_id?: string
  /** Группа вариаций (подтверждённая): «Чипсы Lay's», вес «150 г», вкус «Сыр». */
  variant_group_id?: string | null
  variant_group_name?: string | null
  variant_weight?: string
  variant_flavor?: string
}

/** Товар (вариант: вкус, цвет…) в группе вариаций магазина (GET /store/variant-groups/{id}). */
export type VariantItem = {
  product_id: string
  name: string
  flavor: string
  barcode: string
  image: string | null
  price: string
  price_source: 'store' | 'network' | 'base'
  /** «Своя цена»: цена веса её не перезаписывает. */
  own_price: boolean
  stock: string
}

export type VariantWeight = {
  weight: string
  /** Общая цена вкусов без своей цены; null — у них разные цены. */
  price: string | null
  stock: string
  items: VariantItem[]
}

export type VariantGroup = {
  id: string
  name: string
  brand_name: string | null
  store_id: string
  price_type_id: string
  stock: string
  /** Название переключателя «размера» (Вес, Объём…); "" — его нет: тогда все товары в одном weights[] с weight "". */
  weight_label: string
  /** Название переключателя «варианта» (Вкус, Цвет…); "" — его нет. */
  flavor_label: string
  weights: VariantWeight[]
}

export type DictItem = {
  id: string
  name: string
  is_active: boolean
  parent_id?: string | null
  sort?: number
  hex?: string
  short_name?: string
  is_fractional?: boolean
}

export type PriceType = { id: string; name: string; is_default: boolean; is_active: boolean }

export type PriceDocItem = {
  product_id: string
  product_name: string
  new_price: string
  previous_price: string | null
  current_price: string
}

export type PriceDocument = {
  id: string
  number: number
  price_type_id: string
  price_type_name: string
  store_id: string | null
  store_name: string | null
  status: string
  note: string
  created_by: string
  posted_at: string | null
  created_at: string
  items_count: number
  items?: PriceDocItem[]
}

export type StockDocType = 'income' | 'supplier_return' | 'transfer' | 'write_off' | 'posting' | 'inventory'

export type StockDocItem = {
  line: number
  product_id: string
  product_name: string
  unit_short: string
  qty: string
  price: string | null
  expected_qty: string | null
}

export type StockDocument = {
  id: string
  type: StockDocType
  type_title: string
  number: number
  status: string
  warehouse_id: string
  warehouse_name: string
  store_id: string
  to_warehouse_id: string | null
  to_warehouse_name: string | null
  counterparty_id: string | null
  counterparty_name: string | null
  currency: string
  rate: string | null
  reason: string
  note: string
  total: string
  created_by: string
  posted_at: string | null
  created_at: string
  items_count: number
  items?: StockDocItem[]
}

export type StockRow = {
  warehouse_id: string
  warehouse_name: string
  store_id: string
  product_id: string
  product_name: string
  unit_short: string
  qty: string
  // Себестоимость — только с правом inventory.manage или reports.view.
  avg_cost?: string
  total_cost?: string
  avg_cost_usd?: string
}

export type Movement = {
  product_id: string
  product_name: string
  qty: string
  unit_cost?: string
  doc_type: string
  doc_kind: string
  doc_id: string
  doc_number: number | null
  created_at: string
  balance_after: string | null
}

export type CounterpartyType = { id: string; name: string; is_active: boolean }

export type Counterparty = {
  id: string
  type_id: string | null
  type_name: string | null
  name: string
  phone: string
  inn: string
  note: string
  is_active: boolean
  balance: string
}

export type Reason = { id: string; name: string; kind: 'income' | 'expense'; is_active: boolean }

export type Cashbox = {
  id: string
  store_id: string | null
  store_name: string | null
  name: string
  currency: string
  is_main: boolean
  is_active: boolean
  balance: string
}

export type PaymentMethod = {
  id: string
  name: string
  cashbox_id: string
  cashbox_name: string
  store_id: string | null
  is_active: boolean
}

export type CashOperation = {
  id: string
  number: number
  kind: 'income' | 'expense'
  cashbox_id: string
  cashbox_name: string
  currency: string
  amount: string
  amount_uzs: string
  rate: string | null
  counterparty_id: string | null
  counterparty_name: string | null
  reason_id: string | null
  reason_name: string | null
  note: string
  created_by: string
  created_at: string
}

export type CashTransfer = {
  id: string
  number: number
  kind: string
  from_id: string
  from_name: string
  from_currency: string
  to_id: string
  to_name: string
  to_currency: string
  amount_from: string
  amount_to: string
  rate: string | null
  note: string
  created_by: string
  created_at: string
}

export type Entry = { amount: string; doc_type: string; doc_id: string; created_at: string }

export type Rate = { rate: string; created_at: string }

export type SaleItem = {
  line: number
  product_id: string
  product_name: string
  qty: string
  price: string
  discount: string
  total: string
  returned_qty: string
}

export type Sale = {
  id: string
  number: number
  store_id: string
  store_name: string
  warehouse_id: string
  subtotal: string
  discount: string
  total: string
  customer_phone: string
  note: string
  cashier: string
  sold_at: string
  fiscal_status: string
  fiscal_number: string
  fiscal_sign: string
  created_at: string
  items?: SaleItem[]
  payments?: { payment_method_id: string; name: string; amount: string }[]
}

export type CustomerReturn = {
  id: string
  number: number
  sale_id: string
  sale_number: number
  store_id: string
  total: string
  payment_method: string
  reason: string
  created_by: string
  fiscal_status: string
  created_at: string
  items?: { sale_line: number; product_name: string; qty: string; total: string }[]
}

export type SalesSummary = {
  sales_count: number
  subtotal: string
  discount: string
  revenue: string
  returns_count: number
  returns: string
  net: string
}

export type StockSummary = { positions: number; products: number; cost_value?: string }

export type FiscalSummary = { pending_sales: number; pending_returns: number; oldest_pending_at: string | null }

export type OrderItem = {
  line: number
  product_id: string
  product_name: string
  unit_short: string
  qty: string
  price: string
  total: string
  picked_warehouse_id: string | null
  from_other_warehouse: boolean
  /** Цена до скидки по акции; null — скидки не было. */
  old_price: string | null
}

export type Order = {
  id: string
  number: number
  store_id: string
  store_name: string
  warehouse_id: string
  status: string
  status_title: string
  subtotal: string
  discount: string
  delivery_fee: string
  total: string
  address: string
  entrance: string
  floor: string
  apartment: string
  address_comment: string
  lat: number
  lng: number
  distance_m: number
  customer_phone: string
  comment: string
  payment_provider: string
  payment_status: string | null
  paid_at: string | null
  accepted_at: string | null
  delivered_at: string | null
  delivery_from: string | null
  delivery_to: string | null
  courier_id: string | null
  courier_name: string | null
  eta_at: string | null
  /** staff — штатный курьер, crowd — курьер «по пути». */
  delivery_mode?: 'staff' | 'crowd'
  crowd_courier_id?: string | null
  crowd_courier_phone?: string | null
  crowd_pickup_until?: string | null
  /** Заказ сейчас предлагается курьерам «по пути». */
  crowd_open?: boolean
  cancel_reason: string
  fiscal_status: string
  created_at: string
  items?: OrderItem[]
  history?: { status: string; actor: string; note: string; created_at: string }[]
}

export type WorkingHours = { weekday: number; opens: string; closes: string }
export type DeliveryRule = { type: 'fixed' | 'distance' | 'zone' | 'free_from'; params: Record<string, string | number>; sort: number }
export type DeliverySettings = {
  accepts_online: boolean
  min_order_amount: string
  delivery_radius_m: number
  working_hours: WorkingHours[] | null
  rules: DeliveryRule[] | null
  eta_min: number | null
  eta_max: number | null
  slots: SlotSettings
}

export type SlotSettings = {
  enabled: boolean
  slot_minutes: number
  days_ahead: number
  lead_minutes: number
  capacity: number
}

export type PromotionItem = { product_id: string; product_name: string; price: string; regular_price: string }
export type Promotion = {
  id: string
  name: string
  starts_at: string
  ends_at: string
  store_ids: string[] | null
  is_active: boolean
  status: 'scheduled' | 'running' | 'ended' | 'disabled'
  item_count: number
  created_at: string
  items?: PromotionItem[]
}
export type Zone = { id: string; name: string; price: string; is_active: boolean; polygon: [number, number][] }

export type Role = { id: string; name: string; permissions: string[] | null; is_owner: boolean }
export type Permission = { code: string; title: string }
export type Employee = {
  id: string
  phone: string
  full_name: string
  role_id: string
  role_name: string
  is_owner: boolean
  status: string
  all_stores: boolean
  store_ids: string[] | null
  /** Логин для панели и «SM Магазин» ('' — входа нет). */
  login: string
  temp_password: boolean
  last_login_at: string | null
}

export type Balance = { available: string; pending: string; next_payout_at: string | null }
export type BalanceEntry = {
  id: number
  kind: string
  status: string
  amount: string
  store_id: string | null
  order_id: string | null
  order_number: number | null
  note: string
  created_at: string
}
export type Payout = {
  id: string
  number: number
  amount: string
  status: string
  requisites: string
  note: string
  admin_note: string
  processed_at: string | null
  created_at: string
}
export type Billing = {
  network_id: string
  network_name: string
  stores_count: number
  plan_key: string
  plan_name: string
  effective_plan_key: string
  trial_until: string | null
  custom_price_uzs: string | null
  price_per_store: string
  monthly_uzs: string
  billing_from: string
  balance_available: string
  balance_pending: string
  unpaid_uzs: string
  overdue: boolean
}
export type Invoice = {
  id: string
  period: string
  stores_count: number
  price_per_store: string
  currency: 'UZS' | 'USD'
  amount_usd: string | null
  rate: string | null
  amount_uzs: string
  plan_key: string | null
  plan_name: string
  status: string
  due_date: string
  overdue: boolean
  paid_via: string | null
  paid_at: string | null
  note: string
  created_at: string
  showcase_plan?: string | null
  showcase_uzs?: string
  ad_share_uzs?: string
}

export type CashboxFlow = {
  id: string
  name: string
  currency: string
  store_id: string | null
  opening: string
  income: string
  expense: string
  closing: string
}
export type CashFlow = {
  from: string
  to: string
  cashboxes: CashboxFlow[]
  lines: { currency: string; category: string; title: string; income: string; expense: string }[]
}
export type ReasonAmount = { reason_id: string; name: string; amount: string }
export type ProfitLoss = {
  from: string
  to: string
  revenue: { pos_sales: string; customer_returns: string; online_orders: string; delivery_fees: string; total: string }
  cost_of_goods: { pos: string; returns: string; online: string; total: string }
  gross_profit: string
  stock_adjustments: { write_offs: string; inventory_shortage: string; inventory_surplus: string; total: string }
  other_income: ReasonAmount[] | null
  expenses: ReasonAmount[] | null
  platform_subscription: string
  net_profit: string
  sales_count: number
  orders_count: number
}

export type Courier = {
  employee_id: string
  full_name: string
  phone: string
  vehicle: 'foot' | 'bike' | 'scooter' | 'car'
  on_shift: boolean
  lat: number | null
  lng: number | null
  located_at: string | null
  active_orders: number
  /** Логин приложения курьера; null — входа нет. */
  login: string | null
  last_login_at: string | null
}

export type CrowdCourierCard = {
  user_id: string
  code: string
  status: 'unverified' | 'active' | 'blocked'
  phone: string
  full_name: string
  level: string
  delivered: number
  verified_at: string | null
  verified_store: string | null
}

export type StoreCrowdBonus = {
  courier_id: string
  name: string
  code: string
  store_name: string
  verified_at: string
  deliveries: number
  credited: string
  pending: string
}

export type StoreCrowdBonuses = {
  credited_month: string
  pending: string
  verified: number
  per_delivery: string
  max_deliveries: number
  items: StoreCrowdBonus[] | null
}

// ABC/XYZ-анализ (/store/reports/abc-xyz). Доли — проценты числом.
export type AbcLetter = 'A' | 'B' | 'C'
export type XyzLetter = 'X' | 'Y' | 'Z'
export type AbcBy = 'revenue' | 'profit' | 'qty'
export type AbcItem = {
  product_id: string
  name: string
  category: string
  unit: string
  image: string | null
  abc: AbcLetter
  /** null — продаж меньше 4 недель, XYZ ещё не считается. */
  xyz: XyzLetter | null
  revenue: string
  profit: string
  qty: string
  share: number
  cum_share: number
  /** Коэффициент вариации продаж по неделям, %. */
  variation: number | null
  stock: string
  /** На сколько дней хватит остатка при спросе за последние 14 дней; 0 — нет в наличии. */
  days_cover: number | null
}
export type AbcNoSaleItem = {
  product_id: string
  name: string
  category: string
  unit: string
  image: string | null
  stock: string
  stock_value: string
}
export type AbcXyz = {
  from: string
  to: string
  by: AbcBy
  analysis_from: string
  weeks: number
  xyz_available: boolean
  xyz_days_left: number
  min_weeks: number
  totals: { revenue: string; profit: string; qty: string; products: number }
  groups: Record<AbcLetter, { count: number; share: number; revenue: string; profit: string }>
  matrix: { cell: string; count: number; share: number; revenue: string }[]
  no_sales: { count: number; stock_value: string }
  items: AbcItem[]
  no_sale_items: AbcNoSaleItem[]
}

/** /store/reports/sales-series — точка по часу или дню. */
export type SeriesPoint = {
  at: string
  revenue: string
  pos: string
  online: string
  profit: string
  checks: number
  orders: number
}
export type SeriesTotals = {
  revenue: string
  pos: string
  online: string
  profit: string
  margin_pct: number | null
  checks: number
  orders: number
  avg_check: string
}
export type SalesSeries = {
  from: string
  to: string
  bucket: 'hour' | 'day' | 'weekday_hour'
  points: SeriesPoint[]
  totals: SeriesTotals
  compare?: 'prev' | 'week'
  prev_from?: string
  prev_to?: string
  prev?: SeriesPoint[]
  prev_totals?: SeriesTotals
  change_pct?: number | null
  heatmap?: { weekday: number; hour: number; checks: number; revenue: string }[]
}

/** /store/reports/sales-breakdown */
export type BreakdownItem = {
  key: string
  name: string
  value: string
  qty?: string
  unit?: string | null
  image?: string | null
  share: number
  prev_value?: string
  change_pct?: number | null
}
export type SalesBreakdown = {
  by: 'category' | 'product' | 'payment'
  from: string
  to: string
  total: string
  items: BreakdownItem[]
  other: { count: number; value: string; share: number; prev_value?: string } | null
  prev_total?: string
  change_pct?: number | null
}

// ---------------------------------------------------------------- тарифы

export type PlanFeature = { key: string; group: string; name: string; hint: string; included: boolean }
export type PlanLimit = { key: string; group: string; name: string; hint: string; value: number | null; used?: number }

/** Карточка тарифа на языке панели (GET /store/plan). */
export type PlanView = {
  key: string
  name: string
  description: string
  price_uzs: string
  currency: string
  min_stores: number
  order_commission: string
  recommended: boolean
  sort: number
  features: PlanFeature[]
  limits: PlanLimit[]
}

/** «Мой тариф»: выбранный, действующий (пробный), карточки для смены. */
export type MyPlan = {
  chosen: { key: string; name: string; name_uz: string; price_uzs: string; order_commission: string }
  effective: { key: string; name: string; name_uz: string }
  trial_plan: string
  trial_until: string | null
  in_trial: boolean
  custom_price_uzs: string | null
  current: PlanView
  plans: PlanView[]
  stores_count: number
  can_change: boolean
}
