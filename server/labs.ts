// Lab tests (/api/labs): a person's lab results as printed, each against the lab's own reference range.
// Placeholder from the shared scaffold; the lab tests builder fills it in.
import express from 'express';
import type { Db } from './db.ts';
import type { McflyClient } from './mcfly.ts';

export function labsRouter(_db: Db, _opts: { hosted: boolean; client?: () => McflyClient | null }) {
  return express.Router();
}
