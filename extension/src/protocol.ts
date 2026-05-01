/**
 * Zod schemas and inferred types for all daemon messages.
 *
 * Single source of truth — TypeScript types are derived from schemas via z.infer.
 * All external data is parsed through these schemas at the boundary.
 */

import { z } from "zod";

// --- Daemon response schemas ---

const LocalResponseSchema = z.object({
  status: z.literal("LOCAL"),
});

const RemoteResponseSchema = z.object({
  status: z.literal("REMOTE"),
  tenant: z.string(),
});

const FallbackResponseSchema = z.object({
  status: z.literal("FALLBACK"),
});

const OkResponseSchema = z.object({
  status: z.literal("OK"),
  detail: z.string().optional(),
});

const MatchResponseSchema = z.object({
  status: z.literal("MATCH"),
  tenant: z.string(),
  rule_index: z.union([z.string(), z.number()]),
});

const NoMatchResponseSchema = z.object({
  status: z.literal("NOMATCH"),
  default: z.string(),
});

const ConfigResponseSchema = z.object({
  status: z.literal("CONFIG"),
  data: z.unknown(),
});

const StatusResponseSchema = z.object({
  status: z.literal("STATUS"),
  data: z.unknown(),
});

const ErrorResponseSchema = z.object({
  status: z.literal("ERR"),
  message: z.string(),
});

export const DaemonResponseSchema = z.discriminatedUnion("status", [
  LocalResponseSchema,
  RemoteResponseSchema,
  FallbackResponseSchema,
  OkResponseSchema,
  MatchResponseSchema,
  NoMatchResponseSchema,
  ConfigResponseSchema,
  StatusResponseSchema,
  ErrorResponseSchema,
]);

export type DaemonResponse = z.infer<typeof DaemonResponseSchema>;

// --- Config schemas (parsed from CONFIG response) ---

const TenantSchema = z.object({
  name: z.string(),
  browser_cmd: z.string(),
  socket: z.string(),
  badge_label: z.string().nullable().optional(),
  badge_color: z.string().nullable().optional(),
});

const RuleSchema = z.object({
  pattern: z.string(),
  tenant: z.string(),
  enabled: z.boolean().nullable().optional(),
  comment: z.string().nullable().optional(),
});

const DefaultsSchema = z.object({
  unmatched: z.string().default("local"),
  notifications: z.boolean().default(true),
  notification_timeout_ms: z.number().default(3000),
  cooldown_secs: z.number().default(5),
});

export const ConfigSchema = z.object({
  tenants: z.record(z.string(), TenantSchema),
  rules: z.array(RuleSchema),
  defaults: DefaultsSchema.optional(),
});

export type Config = z.infer<typeof ConfigSchema>;
export type Tenant = z.infer<typeof TenantSchema>;

// --- Command types (extension → native host) ---

export type OpenCommand = { readonly cmd: "open"; readonly url: string };
export type OpenOnCommand = {
  readonly cmd: "open-on";
  readonly tenant: string;
  readonly url: string;
};
export type AddRuleCommand = {
  readonly cmd: "add-rule";
  readonly rule: { readonly pattern: string; readonly tenant: string };
};
export type SetConfigCommand = {
  readonly cmd: "set-config";
  readonly config: Config;
};
export type TestCommand = { readonly cmd: "test"; readonly url: string };
export type GetConfigCommand = { readonly cmd: "get-config" };
export type StatusCommand = { readonly cmd: "status" };

export type DaemonCommand =
  | OpenCommand
  | OpenOnCommand
  | AddRuleCommand
  | SetConfigCommand
  | TestCommand
  | GetConfigCommand
  | StatusCommand;

// --- Parse helper ---

export function parseDaemonResponse(raw: unknown): DaemonResponse {
  return DaemonResponseSchema.parse(raw);
}
