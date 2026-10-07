// Загрузка фото в хранилище (MinIO): карточки с превью, удаление, просмотр.
// Для Form.Item: value — ссылка (single) или массив ссылок.
import { useRef, useState } from 'react'
import { App, Image, Upload } from 'antd'
import type { UploadFile, UploadProps } from 'antd'
import { LoadingOutlined, PlusOutlined } from '@ant-design/icons'
import { api, ApiError } from './api'
import { tr } from './i18n'

const ACCEPT = 'image/jpeg,image/png,image/webp,image/gif'
const MAX_MB = 8

interface BaseProps {
  /** Сколько фото можно загрузить (для списка). */
  max?: number
  hint?: string
  disabled?: boolean
}

type Props =
  | (BaseProps & { multiple: true; value?: string[] | null; onChange?: (v: string[]) => void })
  | (BaseProps & { multiple?: false; value?: string | null; onChange?: (v: string) => void })

export function ImageUpload(props: Props) {
  const { message } = App.useApp()
  const [busy, setBusy] = useState(0)
  const [preview, setPreview] = useState<string | null>(null)
  const urls = props.multiple ? (props.value ?? []) : props.value ? [props.value] : []
  const max = props.multiple ? (props.max ?? 10) : 1

  const emit = (next: string[]) => {
    if (props.multiple) props.onChange?.(next)
    else props.onChange?.(next[0] ?? '')
  }

  const files: UploadFile[] = urls.map((u, i) => ({ uid: `${i}-${u}`, name: u.split('/').pop() ?? 'photo', status: 'done', url: u }))
  if (busy > 0) for (let i = 0; i < busy; i++) files.push({ uid: `busy-${i}`, name: '…', status: 'uploading', percent: 50 })

  // Текущий список ссылок — общий для параллельных загрузок нескольких файлов.
  const current = useRef(urls)
  current.current = urls

  const customRequest: UploadProps['customRequest'] = async ({ file, onSuccess, onError }) => {
    const f = file as File
    setBusy((n) => n + 1)
    try {
      const url = await api.upload(f, f.name)
      current.current = props.multiple ? [...current.current, url].slice(0, max) : [url]
      emit(current.current)
      onSuccess?.(url)
    } catch (e) {
      message.error(e instanceof ApiError ? e.message : tr('Не удалось загрузить фото', 'Rasmni yuklab boʻlmadi'))
      onError?.(e as Error)
    } finally {
      setBusy((n) => n - 1)
    }
  }

  return (
    <>
      <Upload
        listType="picture-card"
        accept={ACCEPT}
        multiple={!!props.multiple}
        fileList={files}
        disabled={props.disabled}
        customRequest={customRequest}
        beforeUpload={(f) => {
          if (!ACCEPT.split(',').includes(f.type)) {
            message.error(tr('Нужна картинка JPG, PNG, WEBP или GIF', 'JPG, PNG, WEBP yoki GIF rasm kerak'))
            return Upload.LIST_IGNORE
          }
          if (f.size > MAX_MB * 1024 * 1024) {
            message.error(tr(`Фото больше ${MAX_MB} МБ`, `Rasm ${MAX_MB} MB dan katta`))
            return Upload.LIST_IGNORE
          }
          return true
        }}
        onRemove={(f) => {
          if (f.url) emit(urls.filter((u) => u !== f.url))
          return false
        }}
        onPreview={(f) => setPreview(f.url ?? null)}
        showUploadList={{ showPreviewIcon: true, showRemoveIcon: !props.disabled }}
      >
        {files.length >= max ? null : (
          <div className="sm-upload-btn">
            {busy > 0 ? <LoadingOutlined /> : <PlusOutlined />}
            <div>{props.hint ?? tr('Фото', 'Rasm')}</div>
          </div>
        )}
      </Upload>
      {preview && (
        <Image
          style={{ display: 'none' }}
          src={preview}
          preview={{ visible: true, src: preview, onVisibleChange: (v) => !v && setPreview(null) }}
        />
      )}
    </>
  )
}
