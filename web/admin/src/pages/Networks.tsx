import { useState } from 'react'
import { Button, Form, Input, Popconfirm, Select, Space, Typography } from 'antd'
import { CrudPage, StatusTag, api, dateTime, useAction } from '@sm/shared'

interface Network {
  id: string
  name: string
  kind: 'chain' | 'single'
  status: 'active' | 'blocked'
  owner_name: string
  owner_phone: string
  stores_count: number
  created_at: string
}

export function Networks() {
  const [q, setQ] = useState('')
  const setStatus = useAction((v: { id: string; status: string }) => api.patch(`/admin/networks/${v.id}`, { status: v.status }), {
    success: 'Статус изменён',
  })
  return (
    <CrudPage<Network>
      title="Сети и магазины"
      path="/admin/networks"
      params={{ q, limit: 200 }}
      createLabel="Подключить сеть"
      toolbar={<Input.Search placeholder="Название или телефон" allowClear onSearch={setQ} style={{ width: 260 }} />}
      columns={[
        { title: 'Название', dataIndex: 'name' },
        { title: 'Тип', dataIndex: 'kind', render: (k) => (k === 'chain' ? 'Сеть' : 'Одиночный магазин') },
        { title: 'Магазинов', dataIndex: 'stores_count' },
        {
          title: 'Владелец',
          render: (_, n) => (
            <>
              {n.owner_name}
              <br />
              <Typography.Text type="secondary">{n.owner_phone}</Typography.Text>
            </>
          ),
        },
        { title: 'Статус', dataIndex: 'status', render: (s) => <StatusTag status={s} /> },
        { title: 'Подключена', dataIndex: 'created_at', render: dateTime },
        {
          key: 'block',
          render: (_, n) => (
            <Popconfirm
              title={n.status === 'active' ? 'Заблокировать сеть? Сотрудники сразу потеряют доступ.' : 'Разблокировать сеть?'}
              onConfirm={() => setStatus.mutate({ id: n.id, status: n.status === 'active' ? 'blocked' : 'active' })}
            >
              <Button size="small" danger={n.status === 'active'}>
                {n.status === 'active' ? 'Заблокировать' : 'Разблокировать'}
              </Button>
            </Popconfirm>
          ),
        },
      ]}
      toForm={(n) => ({ name: n.name })}
      toBody={(v, editing) => (editing ? { name: v.name } : v)}
      form={(editing) => (
        <>
          <Form.Item name="name" label="Название" rules={[{ required: true }]}>
            <Input />
          </Form.Item>
          {!editing && (
            <Space direction="vertical" style={{ width: '100%' }}>
              <Form.Item name="kind" label="Тип" initialValue="chain" rules={[{ required: true }]}>
                <Select
                  options={[
                    { value: 'chain', label: 'Сеть магазинов' },
                    { value: 'single', label: 'Одиночный магазин' },
                  ]}
                />
              </Form.Item>
              <Form.Item name="owner_name" label="Имя владельца" rules={[{ required: true }]}>
                <Input />
              </Form.Item>
              <Form.Item
                name="owner_phone"
                label="Телефон владельца"
                rules={[{ required: true }]}
                extra="Владелец входит в панель магазина по этому номеру через Telegram-бота."
              >
                <Input placeholder="+998 90 123 45 67" />
              </Form.Item>
            </Space>
          )}
        </>
      )}
    />
  )
}
