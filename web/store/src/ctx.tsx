// Контекст панели: кто вошёл (сеть, права) и выбранный магазин.
import { createContext, useContext, useEffect, useMemo, useState, type ReactNode } from 'react'
import { useItem, useList } from '@sm/shared'
import type { Me, MyPlan, Store } from './types'

interface StoreCtx {
  me: Me | undefined
  stores: Store[]
  storesLoading: boolean
  /** Выбранный магазин ('' — магазинов ещё нет). */
  storeId: string
  store: Store | undefined
  setStoreId: (id: string) => void
  can: (perm: string) => boolean
  /** Тариф сети («Tarif»); undefined, пока грузится. */
  plan: MyPlan | undefined
  /** Тариф ещё грузится (страницы с функцией тарифа ждут его, чтобы не мигать). */
  planLoading: boolean
  /** Функция входит в действующий тариф. Пока тариф грузится — да (без мигания замков). */
  has: (feature: string) => boolean
}

const Ctx = createContext<StoreCtx>({
  me: undefined,
  stores: [],
  storesLoading: false,
  storeId: '',
  store: undefined,
  setStoreId: () => {},
  can: () => false,
  plan: undefined,
  planLoading: false,
  has: () => true,
})

const KEY = 'sm_store_selected'

function readSaved(): string {
  try {
    return localStorage.getItem(KEY) ?? ''
  } catch {
    return ''
  }
}

function save(id: string) {
  try {
    localStorage.setItem(KEY, id)
  } catch {
    // приватный режим — выбор живёт до перезагрузки
  }
}

export function StoreProvider({ children }: { children: ReactNode }) {
  const me = useItem<Me>('/store/me')
  const stores = useList<Store>('/store/stores')
  const plan = useItem<MyPlan>(me.data ? '/store/plan' : null)
  const [picked, setPicked] = useState(readSaved)
  const list = useMemo(() => stores.data ?? [], [stores.data])

  // Сохранённый магазин мог пропасть — берём первый доступный.
  const storeId = list.some((s) => s.id === picked) ? picked : (list[0]?.id ?? '')
  useEffect(() => {
    if (storeId && storeId !== picked) setPicked(storeId)
  }, [storeId, picked])

  const value: StoreCtx = {
    me: me.data,
    stores: list,
    storesLoading: stores.isLoading,
    storeId,
    store: list.find((s) => s.id === storeId),
    setStoreId: (id) => {
      save(id)
      setPicked(id)
    },
    can: (perm) => !!me.data && (me.data.is_owner || me.data.permissions.includes(perm)),
    plan: plan.data,
    planLoading: plan.isLoading,
    has: (f) => !plan.data || plan.data.current.features.some((x) => x.key === f && x.included),
  }
  return <Ctx.Provider value={value}>{children}</Ctx.Provider>
}

export function useStore() {
  return useContext(Ctx)
}
