// «Удалить» в веб-панелях (Figma «Веб-панели · удаление»): подтверждение,
// а если запись уже используется — объяснение и «Отключить» вместо удаления.
import { App, Button, Popconfirm } from "antd";
import { useQueryClient } from "@tanstack/react-query";
import { ApiError, api } from "./api";
import { errorText } from "./hooks";

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
      message.success("Удалено");
      await qc.invalidateQueries();
      o.onDone?.();
    } catch (e) {
      if (e instanceof ApiError && e.status === 409) {
        const canOff = !!o.deactivate && e.details?.deactivate === true;
        const props = {
          title: `«${o.name}» нельзя удалить`,
          content: e.message,
          width: 480,
        };
        if (canOff) {
          modal.confirm({
            ...props,
            okText: "Отключить",
            cancelText: "Закрыть",
            onOk: async () => {
              try {
                await o.deactivate!();
                message.success("Отключено");
                await qc.invalidateQueries();
              } catch (err) {
                message.error(errorText(err));
              }
            },
          });
        } else {
          modal.info({ ...props, okText: "Понятно" });
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
        title={props.title ?? `Удалить «${props.name}»?`}
        description="Запись исчезнет из списков. Это нельзя отменить."
        okText="Удалить"
        cancelText="Отмена"
        okButtonProps={{ danger: true }}
        onConfirm={() => remove(props)}
        disabled={props.disabled}
      >
        <Button size={props.size ?? "small"} danger disabled={props.disabled}>
          Удалить
        </Button>
      </Popconfirm>
    </span>
  );
}
