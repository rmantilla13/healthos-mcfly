// One metric for a detail sheet (/api/metric): its history over a range and a plain sentence about it.
// Placeholder from the shared scaffold; the detail-sheets builder fills it in.
import express from 'express';
import type { Db } from './db.ts';

export function metricRouter(_db: Db, _hosted: boolean) {
  return express.Router();
}
