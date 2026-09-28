// One ajv instance for the Runner and adapters (the core never imports this). ajv caches each compiled schema.
import Ajv, { type SchemaObject } from "ajv";

const ajv = new Ajv();

/** `null` when `data` fits `schema`, else ajv's error text. */
export const check = (schema: SchemaObject, data: unknown): string | null =>
  ajv.validate(schema, data) ? null : ajv.errorsText();
