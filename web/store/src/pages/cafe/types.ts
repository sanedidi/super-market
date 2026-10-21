// Типы API кафе (/store/cafe/*), бэкенд — internal/cafe.

export type Kind = 'goods' | 'dish' | 'prep'

export type Workshop = {
  id: string
  name: string
  name_ru: string
  name_uz: string
  sort: number
  is_default: boolean
  is_active: boolean
  group_count: number
  dish_count: number
  icon: WorkshopIcon
  cook_minutes: number
  ticket_print: 'always' | 'offline' | 'never'
  group_ids: string[]
  group_names: string[]
}

export type WorkshopIcon = 'fire' | 'bakery' | 'bar' | 'soup' | 'grill' | 'salad' | 'pizza' | 'cafe'

export type MenuGroup = {
  id: string
  name: string
  name_ru: string
  name_uz: string
  color: string
  sort: number
  workshop_id: string | null
  workshop_name: string | null
  dish_count: number
}

export type RecipeLine = {
  line: number
  ingredient_id: string
  name: string
  kind: Kind
  unit_short: string
  qty: string
  unit_cost: string
  cost: string
  has_cost: boolean
  not_tracked: boolean
}

export type UsedIn = { id: string; name: string; kind: Kind; qty: string; unit_short: string; is_active: boolean }

export type Dish = {
  id: string
  kind: Kind
  name: string
  name_ru: string
  name_uz: string
  description: string
  menu_code: number | null
  menu_group_id: string | null
  menu_group_name: string | null
  workshop_id: string | null
  kitchen_workshop_id: string | null
  kitchen_workshop_name: string | null
  unit_id: string
  unit_short: string
  is_fractional: boolean
  price: string
  yield_qty: string
  cook_minutes: number | null
  shelf_hours: number | null
  ikpu: string
  package_code: string
  vat_rate: string
  images: string[]
  is_active: boolean
  store_ids: string[]
  modifier_group_ids: string[]
  cost: string
  cost_complete: boolean
  markup: string
  food_cost: string | null
  has_recipe: boolean
  portion: string
  stop_store_ids: string[]
  stock?: string
  recipe?: RecipeLine[]
  used_in?: UsedIn[]
}

export type ModifierAction = 'none' | 'add' | 'remove' | 'factor'

export type ModifierOption = {
  id: string
  name: string
  name_ru: string
  name_uz: string
  price: string
  action: ModifierAction
  product_id: string | null
  product_name: string | null
  qty: string | null
  factor: string | null
  sort: number
}

export type ModifierGroup = {
  id: string
  name: string
  name_ru: string
  name_uz: string
  min_select: number
  max_select: number
  required: boolean
  sort: number
  dish_count: number
  options: ModifierOption[]
}

export type Ingredient = { id: string; name: string; kind: Kind; unit_short: string; barcode: string | null; cost: string | null }

export type StopItem = { product_id: string; name: string; menu_group_name: string | null; image: string | null; since: string; by: string | null }

export type StockItem = {
  product_id: string
  name: string
  kind: Kind
  unit_short: string
  qty: string
  cost: string | null
  value: string
  per_day: string
  days_left: string | null
  dish_count: number
  status: 'ok' | 'low' | 'minus' | 'none'
}

export type StockSummary = {
  warehouse_id: string
  value: string
  low: number
  minus: number
  spoil_week: string
  spoil_share: string | null
  items: StockItem[]
}

export type Production = {
  id: string
  number: number
  store_id: string
  warehouse_id: string
  product_id: string
  product_name: string
  unit_short: string
  qty: string
  cost: string
  unit_cost: string
  expires_at: string | null
  note: string
  created_by: string
  created_at: string
  cook: string | null
  produced_at: string
}

export type ProductionPreview = {
  warehouse_id: string
  warehouse_name: string
  qty: string
  cost: string
  expires_at: string | null
  lines: { ingredient_id: string; name: string; unit_short: string; qty: string; stock: string; enough: boolean; short: string }[]
  not_tracked: string[]
}
