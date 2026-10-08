// Переводы данных на узбекский: сколько категорий, единиц, цветов и товаров
// ещё без перевода, и массовый перевод недостающего через ИИ-сервис.
import { useRef, useState } from 'react'
import { Link } from 'react-router-dom'
import { Alert, App, Button, Card, Flex, Progress, Space, Table, Tag, Typography } from 'antd'
import { PauseCircleOutlined, ReloadOutlined, TranslationOutlined } from '@ant-design/icons'
import { LoadError, PageTitle, api, errorText, useItem } from '@sm/shared'

type Entity = 'categories' | 'units' | 'colors' | 'products'

interface StatRow {
  entity: Entity
  total: number
  missing: number
}

interface Run {
  entity: Entity
  translated: number
  remaining: number | null
}

const TITLES: Record<Entity, string> = {
  categories: 'Категории',
  units: 'Единицы измерения',
  colors: 'Цвета',
  products: 'Товары',
}

const BATCH = 50

export function Translations() {
  const { message } = App.useApp()
  const stats = useItem<{ items: StatRow[] | null }>('/admin/i18n/stats')
  const [run, setRun] = useState<Run | null>(null)
  const [stopping, setStopping] = useState(false)
  const stop = useRef(false)
  const rows = stats.data?.items ?? []

  // Переводим пачками по 50, пока не останется ничего, не будет ошибки или нажмут «Остановить».
  const translate = async (entity: Entity) => {
    stop.current = false
    setStopping(false)
    let done = 0
    setRun({ entity, translated: 0, remaining: null })
    try {
      for (;;) {
        const r = await api.post<{ translated: number; remaining: number }>('/admin/i18n/translate-missing', { entity, limit: BATCH })
        done += r.translated
        setRun({ entity, translated: done, remaining: r.remaining })
        if (r.remaining <= 0) {
          message.success(`${TITLES[entity]}: переведено ${done}, всё готово`)
          break
        }
        // Ничего не перевелось — дальше крутить бессмысленно (ИИ не ответил или тексты не переводятся).
        if (r.translated === 0) {
          message.warning(`${TITLES[entity]}: перевод остановлен — сервис ничего не перевёл, осталось ${r.remaining}`)
          break
        }
        if (stop.current) {
          message.info(`${TITLES[entity]}: остановлено, переведено ${done}, осталось ${r.remaining}`)
          break
        }
      }
    } catch (e) {
      message.error(errorText(e))
    } finally {
      setRun(null)
      setStopping(false)
      void stats.refetch()
    }
  }

  return (
    <>
      <PageTitle
        title="Переводы"
        extra={
          <Button icon={<ReloadOutlined spin={stats.isFetching} />} disabled={!!run} onClick={() => stats.refetch()}>
            Обновить
          </Button>
        }
      >
        <Typography.Text type="secondary">
          Узбекские названия справочников и товаров. Пустой перевод — в приложении и панели магазина показывается русский текст.
        </Typography.Text>
      </PageTitle>
      <Alert
        type="info"
        showIcon
        style={{ marginBottom: 16 }}
        message={
          <>
            Переводит ИИ-сервис платформы (раздел <Link to="/ai">«ИИ-сервис»</Link>), пачками по {BATCH} записей. Расход виден там же, на вкладке
            «Расход». Перевод любой записи можно поправить вручную в её карточке.
          </>
        }
      />
      <LoadError error={stats.error} retry={() => stats.refetch()} />
      <Card styles={{ body: { padding: 0 } }}>
        <Table<StatRow>
          rowKey="entity"
          loading={stats.isLoading}
          dataSource={rows}
          pagination={false}
          scroll={{ x: true }}
          columns={[
            { title: 'Справочник', dataIndex: 'entity', render: (v: Entity) => <b>{TITLES[v] ?? v}</b> },
            { title: 'Всего', dataIndex: 'total', align: 'right' },
            {
              title: 'Без перевода',
              dataIndex: 'missing',
              align: 'right',
              render: (v: number) => (v > 0 ? <Tag color="orange">{v}</Tag> : <Tag color="green">все переведены</Tag>),
            },
            {
              title: 'Готово',
              key: 'pct',
              width: 220,
              render: (_, r) => (
                <Progress percent={r.total > 0 ? Math.floor(((r.total - r.missing) / r.total) * 100) : 100} size="small" status={r.missing === 0 ? 'success' : 'normal'} />
              ),
            },
            {
              key: 'act',
              align: 'right',
              width: 320,
              render: (_, r) => {
                if (run?.entity === r.entity)
                  return (
                    <Flex gap={12} align="center" justify="flex-end" wrap>
                      <Typography.Text type="secondary" style={{ fontSize: 13 }}>
                        Переведено {run.translated}
                        {run.remaining !== null && ` · осталось ${run.remaining}`}
                      </Typography.Text>
                      <Button
                        size="small"
                        icon={<PauseCircleOutlined />}
                        loading={stopping}
                        onClick={() => {
                          stop.current = true
                          setStopping(true)
                        }}
                      >
                        Остановить
                      </Button>
                    </Flex>
                  )
                return (
                  r.missing > 0 && (
                    <Button size="small" type="primary" icon={<TranslationOutlined />} disabled={!!run} onClick={() => translate(r.entity)}>
                      Перевести недостающее
                    </Button>
                  )
                )
              },
            },
          ]}
        />
      </Card>
      {run && (
        <Space style={{ marginTop: 12 }}>
          <Typography.Text type="secondary" style={{ fontSize: 13 }}>
            «Остановить» сработает после текущей пачки — её перевод сохранится.
          </Typography.Text>
        </Space>
      )}
    </>
  )
}
