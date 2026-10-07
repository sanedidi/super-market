// «Удалить» в веб-панелях (Figma «Веб-панели · удаление»): подтверждение,
// а если запись уже используется — объяснение и «Отключить» вместо удаления.
import { App, Button, Popconfirm } from "antd";
import { useQueryClient } from "@tanstack/react-query";
import { ApiError, api } from "./api";
import { errorText } from "./hooks";
import { tr } from "./i18n";

export interface RemoveOptions {
  /** DELETE-путь записи. */
  path: string;
  /** Название для текстов: «Удалить «…»?». */
  name: string;
  /** Отключить вместо удаления (PATCH is_active=false и т.п.); нет — кнопки «Отключить» не будет. */
  deactivate?: () => Promise<unknown>;
  onDone?: () => void;
}

/** Удаление с обработкой «используется» (409 in_use). */
export function useRemove() {
  const { message, modal } = App.useApp();
  const qc = useQueryClient();
  return async (o: RemoveOptions) => {
    try {
      await api.del(o.path);
      message.success(tr("Удалено", "Oʻchirildi"));
      await qc.invalidateQueries();
      o.onDone?.();
    } catch (e) {
      if (e instanceof ApiError && e.status === 409) {
        const canOff = !!o.deactivate && e.details?.deactivate === true;
        const props = {
          title: tr(`«${o.name}» нельзя удалить`, `«${o.name}»ni oʻchirib boʻlmaydi`),
          content: e.message,
          width: 480,
        };
        if (canOff) {
          modal.confirm({
            ...props,
            okText: tr("Отключить", "Oʻchirib qoʻyish"),
            cancelText: tr("Закрыть", "Yopish"),
            onOk: async () => {
              try {
                await o.deactivate!();
                message.success(tr("Отключено", "Oʻchirib qoʻyildi"));
                await qc.invalidateQueries();
              } catch (err) {
                message.error(errorText(err));
              }
            },
          });
        } else {
          modal.info({ ...props, okText: tr("Понятно", "Tushunarli") });
        }
        return;
      }
      message.error(errorText(e));
    }
  };
}

/** Кнопка «Удалить» с подтверждением. */
export function DeleteButton(
  props: RemoveOptions & {
    size?: "small" | "middle";
    disabled?: boolean;
    title?: string;
  },
) {
  const remove = useRemove();
  // span гасит клики (и из всплывающего подтверждения), чтобы строка таблицы не открывалась.
  return (
    <span onClick={(e) => e.stopPropagation()}>
      <Popconfirm
        title={props.title ?? tr(`Удалить «${props.name}»?`, `«${props.name}» oʻchirilsinmi?`)}
        description={tr("Запись исчезнет из списков. Это нельзя отменить.", "Yozuv roʻyxatlardan yoʻqoladi. Buni bekor qilib boʻlmaydi.")}
        okText={tr("Удалить", "Oʻchirish")}
        cancelText={tr("Отмена", "Bekor qilish")}
        okButtonProps={{ danger: true }}
        onConfirm={() => remove(props)}
        disabled={props.disabled}
      >
        <Button size={props.size ?? "small"} danger disabled={props.disabled}>
          {tr("Удалить", "Oʻchirish")}
        </Button>
      </Popconfirm>
    </span>
  );
}
