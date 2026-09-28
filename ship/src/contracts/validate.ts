// One ajv instance for the Runner and adapters (the core never imports this). ajv caches each compiled schema.
import Ajv, { type ErrorObject, type SchemaObject } from "ajv";

const ajv = new Ajv();

// ajv's own text omits the params, e.g. which additional property was found.
const describe = ({ instancePath, message, params }: ErrorObject): string =>
  `${instancePath || "/"} ${message ?? "is invalid"} ${JSON.stringify(params)}`;

/** `null` when `data` fits `schema`, else what is wrong, naming the offending field. */
export const check = (schema: SchemaObject, data: unknown): string | null =>
  ajv.validate(schema, data) ? null : (ajv.errors ?? []).map(describe).join("; ");
