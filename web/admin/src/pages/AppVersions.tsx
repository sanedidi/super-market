// Версии приложений (Figma «Супер-админ · Версии приложений», ВП1–ВП2):
// выложили новую версию в App Store / Google Play — вписываем её сюда, и у кого
// версия старее, приложение при запуске покажет шторку «Есть обновление»
// (Figma «Обновление приложения», ОБ1) с «Что нового» и ссылкой на стор.
import { useState } from 'react'
import dayjs from 'dayjs'
import { Alert, Button, Form, Input, Modal, Space, Table, Tag, Typography } from 'antd'
import { EditOutlined } from '@ant-design/icons'
import { FormTranslate, LoadError, api, useAction, useList } from '@sm/shared'

interface AppVersion {
  app: 'client' | 'store' | 'courier' | 'agent'
  platform: 'ios' | 'android'
  latest: string
  store_url: string
  notes_ru: string
  notes_uz: string
  updated_at: string | null
}

const APPS: Record<AppVersion['app'], { title: string; who: string }> = {
  client: { title: 'Super Market', who: 'покупатель' },
  store: { title: 'SM Магазин', who: 'магазин' },
  courier: { title: 'SM Курьер', who: 'курьер' },
  agent: { title: 'SM Агент', who: 'агент' },
}

const PLATFORM: Record<AppVersion['platform'], string> = { ios: 'iOS', android: 'Android' }

/** Первая строка «Что нового» без маркера. */
function firstNote(v: AppVersion): string {
  const l = v.notes_ru.split('\n').map((s) => s.replace(/^[\s•*-]+/, '').trim()).filter(Boolean)
  if (!l.length) return '—'
  return l.length > 1 ? `${l[0]} (+${l.length - 1})` : l[0]
}

export function AppVersions() {
  const list = useList<AppVersion>('/admin/app-versions')
  const [edit, setEdit] = useState<AppVersion | null>(null)
  return (
    <Space direction="vertical" size={16} style={{ width: '100%' }}>
      <Typography.Title level={3} style={{ margin: 0 }}>
        Версии приложений
      </Typography.Title>
      <Alert
        type="info"
        showIcon
        message="Выложили новую версию в стор — впишите её в «Последняя». У кого версия старее, при запуске появится шторка «Есть обновление» с «Что нового» и кнопкой «Обновить». Пустая версия или ссылка — шторка не показывается."
      />
      {list.error ? (
        <LoadError error={list.error} retry={() => list.refetch()} />
      ) : (
        <Table<AppVersion>
          rowKey={(v) => `${v.app}/${v.platform}`}
          loading={list.isLoading}
          dataSource={list.data}
          pagination={false}
          columns={[
            {
              title: 'Приложение',
              render: (_, v) => (
                <div>
                  <Typography.Text strong>{APPS[v.app].title}</Typography.Text>
                  <div style={{ fontSize: 12, color: '#667085' }}>{APPS[v.app].who}</div>
                </div>
              ),
            },
            {
              title: 'Платформа',
              dataIndex: 'platform',
              render: (p: AppVersion['platform']) => (
                <Tag bordered={false} color={p === 'android' ? 'green' : undefined}>
                  {PLATFORM[p]}
                </Tag>
              ),
            },
            { title: 'Последняя', dataIndex: 'latest', render: (v: string) => v || <Typography.Text type="secondary">не задана</Typography.Text> },
            { title: 'Что нового', render: (_, v) => <Typography.Text ellipsis style={{ maxWidth: 360 }}>{firstNote(v)}</Typography.Text> },
            {
              title: 'Изменена',
              dataIndex: 'updated_at',
              render: (v: string | null) => (v ? dayjs(v).format('DD.MM.YYYY HH:mm') : '—'),
            },
            {
              key: 'edit',
              align: 'right',
              render: (_, v) => (
                <Button icon={<EditOutlined />} onClick={() => setEdit(v)}>
                  Изменить
                </Button>
              ),
            },
          ]}
        />
      )}
      {edit && <EditVersion v={edit} onClose={() => setEdit(null)} />}
    </Space>
  )
}

function EditVersion({ v, onClose }: { v: AppVersion; onClose: () => void }) {
  const [form] = Form.useForm<Pick<AppVersion, 'latest' | 'store_url' | 'notes_ru' | 'notes_uz'>>()
  const save = useAction((body: Pick<AppVersion, 'latest' | 'store_url' | 'notes_ru' | 'notes_uz'>) => api.put(`/admin/app-versions/${v.app}/${v.platform}`, body), {
    success: 'Версия сохранена',
    invalidate: [['/admin/app-versions']],
  })
  const store = v.platform === 'ios' ? 'App Store' : 'Google Play'
  return (
    <Modal
      open
      title={`${APPS[v.app].title} · ${PLATFORM[v.platform]}`}
      okText="Сохранить"
      cancelText="Отмена"
      confirmLoading={save.isPending}
      onCancel={onClose}
      onOk={() => form.validateFields().then((b) => save.mutateAsync(b).then(onClose)).catch(() => undefined)}
      width={560}
    >
      <Form form={form} layout="vertical" initialValues={v} requiredMark={false}>
        <Form.Item
          name="latest"
          label="Последняя версия"
          extra={`Та, что сейчас в ${store}. Пусто — шторка не показывается.`}
          rules={[{ pattern: /^\d{1,4}(\.\d{1,4}){0,3}$/, message: 'Версия вида 0.9.2' }]}
        >
          <Input placeholder="0.9.2" style={{ maxWidth: 200 }} />
        </Form.Item>
        <Form.Item
          name="store_url"
          label={`Ссылка на ${store}`}
          rules={[{ pattern: /^https:\/\//, message: 'Ссылка начинается с https://' }]}
        >
          <Input placeholder={v.platform === 'ios' ? 'https://apps.apple.com/app/…' : 'https://play.google.com/store/apps/details?id=…'} />
        </Form.Item>
        <Form.Item name="notes_ru" label="Что нового — по-русски, по строке на пункт">
          <Input.TextArea autoSize={{ minRows: 3, maxRows: 8 }} maxLength={2000} placeholder={'Приход вручную: сканер, поиск, новый товар по фото\nИсправлены ошибки'} />
        </Form.Item>
        <Form.Item
          name="notes_uz"
          label={
            <Space size={4}>
              Yangiliklar — oʻzbekcha
              <FormTranslate form={form} from="notes_ru" into="notes_uz" to="uz" />
            </Space>
          }
        >
          <Input.TextArea autoSize={{ minRows: 3, maxRows: 8 }} maxLength={2000} />
        </Form.Item>
      </Form>
    </Modal>
  )
}
