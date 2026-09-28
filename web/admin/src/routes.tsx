import { Navigate, Route, Routes } from 'react-router-dom'
import { Shell, type MenuItem } from '@sm/shared'
import { ShopOutlined } from '@ant-design/icons'

const menu: MenuItem[] = [{ key: '/networks', icon: <ShopOutlined />, label: 'Сети' }]

export function AdminRoutes() {
  return (
    <Routes>
      <Route element={<Shell title="Супер-админ" menu={menu} />}>
        <Route index element={<Navigate to="/networks" replace />} />
        <Route path="networks" element={<div>Сети</div>} />
      </Route>
    </Routes>
  )
}
