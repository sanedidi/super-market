// «Каталог → Главная приложения»: шаблон для всех сетей или витрина одной сети.
import { useState } from 'react'
import { App, Button, Drawer, Space } from 'antd'
import { BarChartOutlined, GlobalOutlined, RollbackOutlined } from '@ant-design/icons'
import { useQueryClient } from '@tanstack/react-query'
import { HomeEditor, HomeStatsPanel, api, errorText } from '@sm/shared'
import { SearchSelect } from '../components'
import { useUrlState } from '../hooks'

export function AppHome() {
  const [network, setNetwork] = useUrlState('network')
  const { message, modal } = App.useApp()
  const qc = useQueryClient()
  const [reload, setReload] = useState(0)
  const [stats, setStats] = useState(false)
  const params = { network_id: network }
  return (
    <>
    <Drawer open={stats} onClose={() => setStats(false)} width={980} title={null}>
      <HomeStatsPanel path="/admin/home/stats" params={{ network_id: network }} subtitle={network ? 'одна сеть' : 'все сети'} />
    </Drawer>
    <HomeEditor
      key={`${network ?? 'platform'}-${reload}`}
      title="Главная приложения"
      subtitle={
        network
          ? 'Своя витрина сети: её видят покупатели только этой сети. Изменения появятся после «Опубликовать».'
          : 'Блоки, которые видят покупатели на главной. Изменения появятся у всех после «Опубликовать».'
      }
      base="/admin/home"
      params={params}
      storesPath="/admin/home/stores"
      previewPath="/admin/home/preview"
      paths={{ products: '/admin/products', categories: '/admin/catalog/categories', banners: '/admin/banners' }}
      canPin={!network}
      scope={
        <Space>
        <Button size="large" icon={<BarChartOutlined />} onClick={() => setStats(true)}>
          Статистика
        </Button>
        <SearchSelect
          path="/admin/networks"
          size="large"
          value={network}
          onChange={(v) => setNetwork(v as string | undefined)}
          allowClear
          placeholder={
            <span>
              <GlobalOutlined /> Для всех сетей
            </span>
          }
          style={{ width: 240 }}
        />
        </Space>
      }
      extraActions={(l) =>
        l.network_id && l.version > 0 ? (
          <div className="smh-reset">
            У сети «{l.network_name}» своя витрина (версия {l.version}).
            <Button
              size="small"
              icon={<RollbackOutlined />}
              onClick={() =>
                modal.confirm({
                  title: 'Вернуть общий шаблон?',
                  content: 'Своя витрина сети и её версии удалятся, магазины сети увидят шаблон платформы.',
                  okText: 'Вернуть шаблон',
                  okButtonProps: { danger: true },
                  cancelText: 'Отмена',
                  onOk: async () => {
                    try {
                      await api.del(`/admin/home?network_id=${l.network_id}`)
                      await qc.invalidateQueries({ queryKey: ['/admin/home'] })
                      setReload((n) => n + 1)
                      message.success('Сеть снова видит общий шаблон')
                    } catch (e) {
                      message.error(errorText(e))
                    }
                  },
                })
              }
            >
              Вернуть общий шаблон
            </Button>
          </div>
        ) : null
      }
    />
    </>
  )
}
