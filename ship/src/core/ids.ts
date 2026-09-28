// Delivery and command ids (architecture: Delivery `<key>-<attempt>`, command `<delivery>/<name>-<n>`).
import type { CommandId, DeliveryId } from "../contracts/common";

export const KEY_RE = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;
const DELIVERY_SRC = "[A-Za-z0-9][A-Za-z0-9._-]*-[1-9][0-9]*";
const DELIVERY_RE = new RegExp(`^${DELIVERY_SRC}$`);
const COMMAND_ID_RE = new RegExp(`^(${DELIVERY_SRC})/([a-z][a-z_]*)-([1-9][0-9]*)$`);

export const isValidKey = (key: string): boolean => KEY_RE.test(key);

export const isDeliveryId = (id: string): boolean => DELIVERY_RE.test(id);

export const deliveryId = (key: string, attempt: number): DeliveryId => `${key}-${attempt}`;

export const commandId = (delivery: DeliveryId, suffix: string): CommandId => `${delivery}/${suffix}`;

/** The next `<name>-<n>` for a name, and the grown seq. The input seq is not changed. */
export const nextId = (
  seq: Record<string, number>,
  name: string,
): { suffix: string; seq: Record<string, number> } => {
  const n = (seq[name] ?? 0) + 1;
  return { suffix: `${name}-${n}`, seq: { ...seq, [name]: n } };
};

export const parseCommandId = (id: CommandId): { delivery: DeliveryId; name: string; n: number } | null => {
  const match = COMMAND_ID_RE.exec(id);
  if (!match) return null;
  const [, delivery, name, n] = match;
  return { delivery: delivery!, name: name!, n: Number(n) };
};
