// Lab tests, shared by the server and the dashboard: a catalog of common biomarkers (names labs print, units and
// the explicit conversions between them), the API shapes, and small pure helpers. Nothing here judges a result:
// a status only says where a number sits against a range, the lab's own whenever the report printed one.

// ---------- API shapes ----------

/** Where a result sits against a range. Never a verdict: "below the range", not "low" or "bad". */
export type LabStatus = 'below' | 'within' | 'above';

/** A result printed as "<0.5" or ">90": the true value is somewhere below or above the number. */
export type LabQualifier = '<' | '>';

/**
 * The range a result is read against. 'lab' is the reference range printed on the report. 'typical' is used only
 * when the report printed none: a typical adult range from the catalog, always labelled as such.
 */
export type LabRange = {
  low: number | null;
  high: number | null;
  text: string;
  kind: 'lab' | 'typical';
  note?: string;
  /**
   * Set only when the printed range holds more than one band ("Male: 13.0-17.0 Female: 12.0-15.0"): the band
   * low and high come from, picked by the sex in the profile, or null when none could be picked (and both are null).
   */
  band?: 'female' | 'male' | null;
};

/** One stored result, as printed, with where it sits against its own range. */
export type LabResult = {
  id: string;
  /** The day the sample was collected (YYYY-MM-DD). */
  collected: string;
  /** A catalog key, or 'other:<slug>' for a marker the catalog doesn't know. */
  biomarker: string;
  /** The marker's name as printed. */
  name: string;
  /** The result as printed: "5.4", "<0.5", "Negative". */
  valueText: string;
  /** The number in valueText, when there is one. */
  value: number | null;
  qualifier: LabQualifier | null;
  unit: string;
  range: LabRange | null;
  status: LabStatus | null;
  lab: string;
  panel: string;
  /** 'manual' (typed in), 'report' (read from an uploaded report, then checked and saved), or 'demo'. */
  source: string;
};

/** One biomarker: its latest result, every result oldest first, and the exact values that can be drawn together. */
export type LabMarker = {
  key: string;
  /** The catalog's name, or the latest printed name for a marker the catalog doesn't know. */
  name: string;
  group: string;
  latest: LabResult;
  history: LabResult[];
  /**
   * Exact values (no "<" or ">") in the latest result's unit, oldest first: the same unit, or converted with an
   * explicit factor from the catalog. A value in a unit that can't be converted is left out, never guessed.
   */
  points: { id: string; date: string; value: number }[];
  /** Results in a unit that can't be put on the same scale as the latest one. */
  otherUnits: number;
};

/** One collection: the results from one day, one lab and one panel. */
export type LabPanel = { collected: string; lab: string; panel: string; results: LabResult[] };

export type LabsData = {
  today: string;
  /** The demo results are showing (a local demo database, before any results of your own). */
  demo: boolean;
  count: number;
  markers: LabMarker[];
  /** Newest first. */
  panels: LabPanel[];
};

/** One row to add (POST /api/labs) or one row read from a report (POST /api/labs/extract), before it's saved. */
export type LabInput = {
  collected: string;
  name: string;
  valueText: string;
  unit?: string;
  /** The reference range as printed ("3.5-5.0", "<200", ">39"); the numbers are read from it unless given. */
  refText?: string;
  refLow?: number | null;
  refHigh?: number | null;
  lab?: string;
  panel?: string;
  /** A catalog key, when the person picked the marker; otherwise it's matched from the name. */
  biomarker?: string;
};

/**
 * A row Claude read from a report: a draft for the person to check. collected is null when the report showed no
 * date, or when the date read couldn't be used (not a real date, in the future, before 1900): then dateDropped is set.
 */
export type LabDraft = Omit<LabInput, 'collected' | 'refLow' | 'refHigh' | 'biomarker'> & { collected: string | null; biomarker: string | null; dateDropped?: true };

export type LabExtract = { rows: LabDraft[]; note: string | null; usedToday: number; limit: number };

// ---------- the catalog ----------

type Range = { low?: number; high?: number };
type Typical = Range & { note?: string };

type MarkerDef = {
  key: string;
  name: string;
  group: string;
  /** The unit the typical range is in, and the one other units convert through. */
  unit: string;
  /** Other spellings labs print, matched after normalising case, punctuation and filler words. */
  synonyms: string[];
  /** Other units, each as canonical = value × factor (+ offset). Only explicit, exact conversions. */
  units?: Record<string, number | [factor: number, offset: number]>;
  /**
   * A typical adult range in the canonical unit, used only when a result has no printed range. Per sex where it
   * differs by sex: with no sex chosen in the profile there's no fallback, rather than a guess.
   */
  typical?: Typical | { female: Typical; male: Typical; note?: string };
  /** Why there's no conversion or no typical range, for the reader of this file. */
  why?: string;
};

export const LAB_GROUPS = ['Lipids', 'Blood sugar', 'Vitamins and minerals', 'Thyroid', 'Hormones', 'Inflammation', 'Blood count', 'Liver', 'Kidney', 'Electrolytes', 'Other'];

const CHOL: MarkerDef['units'] = { 'mmol/L': 38.67 };

export const BIOMARKERS: MarkerDef[] = [
  // Lipids. Cholesterol: 1 mmol/L = 38.67 mg/dL; triglycerides: 1 mmol/L = 88.57 mg/dL.
  {
    key: 'total_cholesterol',
    name: 'Total cholesterol',
    group: 'Lipids',
    unit: 'mg/dL',
    units: CHOL,
    synonyms: ['Total cholesterol', 'Cholesterol', 'Cholesterol, Total', 'Cholesterol Total', 'TC', 'T. Cholesterol'],
    typical: { high: 199 },
  },
  {
    key: 'ldl',
    name: 'LDL cholesterol',
    group: 'Lipids',
    unit: 'mg/dL',
    units: CHOL,
    synonyms: ['LDL', 'LDL-C', 'LDL Cholesterol', 'LDL-Cholesterol', 'LDL Chol Calc (NIH)', 'LDL Cholesterol Calc', 'LDL Calculated', 'LDL Chol', 'LDL Direct', 'Low density lipoprotein', 'Low-density lipoprotein cholesterol'],
    typical: { high: 99 },
  },
  {
    key: 'hdl',
    name: 'HDL cholesterol',
    group: 'Lipids',
    unit: 'mg/dL',
    units: CHOL,
    synonyms: ['HDL', 'HDL-C', 'HDL Cholesterol', 'HDL-Cholesterol', 'HDL Chol', 'High density lipoprotein', 'High-density lipoprotein cholesterol'],
    typical: { low: 40 },
  },
  {
    key: 'triglycerides',
    name: 'Triglycerides',
    group: 'Lipids',
    unit: 'mg/dL',
    units: { 'mmol/L': 88.57 },
    synonyms: ['Triglycerides', 'Triglyceride', 'TG', 'Trig', 'Trigs'],
    typical: { high: 149 },
  },
  {
    key: 'non_hdl',
    name: 'Non-HDL cholesterol',
    group: 'Lipids',
    unit: 'mg/dL',
    units: CHOL,
    synonyms: ['Non-HDL cholesterol', 'Non HDL Cholesterol', 'Non-HDL-C', 'Non-HDL', 'Non HDL Chol'],
    typical: { high: 129 },
  },
  {
    key: 'apob',
    name: 'Apolipoprotein B',
    group: 'Lipids',
    unit: 'mg/dL',
    units: { 'g/L': 100 },
    synonyms: ['ApoB', 'Apo B', 'Apolipoprotein B', 'Apolipoprotein B-100', 'Apo B-100', 'Apolipoprotein B100'],
    typical: { high: 89 },
  },
  {
    key: 'lpa',
    name: 'Lipoprotein(a)',
    group: 'Lipids',
    unit: 'nmol/L',
    synonyms: ['Lp(a)', 'Lipoprotein(a)', 'Lipoprotein (a)', 'Lipoprotein a', 'LPA', 'Lp a'],
    typical: { high: 74 },
    why: 'mg/dL and nmol/L measure different things for Lp(a) (particle mass vs count), so no factor joins them.',
  },
  // Blood sugar. Glucose: 1 mmol/L = 18.016 mg/dL. HbA1c: % = 0.09148 × mmol/mol + 2.152 (the IFCC/NGSP master equation).
  {
    key: 'hba1c',
    name: 'HbA1c',
    group: 'Blood sugar',
    unit: '%',
    units: { 'mmol/mol': [0.09148, 2.152] },
    synonyms: ['HbA1c', 'Hb A1c', 'A1c', 'Hemoglobin A1c', 'Hemoglobin A1C', 'Haemoglobin A1c', 'HgbA1c', 'Hgb A1c', 'Glycated hemoglobin', 'Glycohemoglobin', 'Glycosylated hemoglobin', 'Glycated haemoglobin'],
    typical: { high: 5.6 },
  },
  {
    key: 'glucose',
    name: 'Glucose',
    group: 'Blood sugar',
    unit: 'mg/dL',
    units: { 'mmol/L': 18.016 },
    synonyms: ['Glucose', 'Fasting glucose', 'Glucose, Fasting', 'Glucose Fasting', 'Fasting blood glucose', 'Fasting plasma glucose', 'FBG', 'FPG', 'Blood glucose', 'Glucose, Serum'],
    typical: { low: 70, high: 99, note: 'fasting' },
  },
  {
    key: 'insulin',
    name: 'Insulin',
    group: 'Blood sugar',
    unit: 'uIU/mL',
    // 1 µIU/mL = 6 pmol/L (the conventional factor for insulin).
    units: { 'pmol/L': 1 / 6 },
    synonyms: ['Insulin', 'Fasting insulin', 'Insulin, Fasting', 'Insulin Fasting', 'Insulin, Serum'],
    typical: { low: 2.6, high: 24.9, note: 'fasting' },
  },
  // Vitamins and minerals.
  {
    key: 'vitamin_d',
    name: 'Vitamin D (25-OH)',
    group: 'Vitamins and minerals',
    unit: 'ng/mL',
    // 1 ng/mL = 2.496 nmol/L.
    units: { 'nmol/L': 1 / 2.496 },
    synonyms: [
      'Vitamin D',
      '25-OH Vitamin D',
      'Vitamin D, 25-Hydroxy',
      'Vitamin D, 25-Hydroxy, Total',
      '25(OH)D',
      '25-Hydroxyvitamin D',
      '25-Hydroxy Vitamin D',
      '25 Hydroxy Vitamin D',
      'Vitamin D 25-OH',
      'Vitamin D, 25-OH, Total',
      'Vitamin D3 (25-OH)',
      '25 OH Vit D',
      '25-OH-D',
      'Calcidiol',
    ],
    typical: { low: 30, high: 100 },
  },
  {
    key: 'b12',
    name: 'Vitamin B12',
    group: 'Vitamins and minerals',
    unit: 'pg/mL',
    // 1 pg/mL = 0.738 pmol/L.
    units: { 'pmol/L': 1 / 0.738 },
    synonyms: ['Vitamin B12', 'Vitamin B-12', 'B12', 'B-12', 'Cobalamin', 'Cyanocobalamin', 'Vit B12'],
    typical: { low: 232, high: 1245 },
  },
  {
    key: 'folate',
    name: 'Folate',
    group: 'Vitamins and minerals',
    unit: 'ng/mL',
    // 1 ng/mL = 2.266 nmol/L.
    units: { 'nmol/L': 1 / 2.266 },
    synonyms: ['Folate', 'Folic acid', 'Serum folate', 'Folate, Serum'],
    typical: { low: 3 },
  },
  {
    key: 'ferritin',
    name: 'Ferritin',
    group: 'Vitamins and minerals',
    unit: 'ng/mL',
    synonyms: ['Ferritin', 'Serum ferritin', 'Ferritin, Serum'],
    typical: { female: { low: 15, high: 150 }, male: { low: 30, high: 400 } },
  },
  {
    key: 'iron',
    name: 'Iron',
    group: 'Vitamins and minerals',
    unit: 'ug/dL',
    // 1 µmol/L = 5.585 µg/dL.
    units: { 'umol/L': 5.585 },
    synonyms: ['Iron', 'Iron, Total', 'Iron Total', 'Serum iron', 'Iron, Serum', 'Fe'],
    typical: { female: { low: 27, high: 159 }, male: { low: 38, high: 169 } },
  },
  {
    key: 'magnesium',
    name: 'Magnesium',
    group: 'Vitamins and minerals',
    unit: 'mg/dL',
    // 1 mmol/L = 2.431 mg/dL; magnesium is divalent, so 1 mEq/L = 0.5 mmol/L.
    units: { 'mmol/L': 2.431, 'mEq/L': 1.2155 },
    // RBC magnesium is a different test with its own range, so it isn't matched here.
    synonyms: ['Magnesium', 'Mg', 'Serum magnesium', 'Magnesium, Serum'],
    typical: { low: 1.6, high: 2.3 },
  },
  // Thyroid.
  {
    key: 'tsh',
    name: 'TSH',
    group: 'Thyroid',
    unit: 'mIU/L',
    synonyms: ['TSH', 'Thyroid stimulating hormone', 'Thyroid-stimulating hormone', 'Thyrotropin', 'TSH, 3rd generation', 'TSH 3rd Generation', 'TSH, Ultrasensitive', 'TSH Ultrasensitive', 'TSH, High Sensitivity'],
    typical: { low: 0.45, high: 4.5 },
  },
  {
    key: 'free_t4',
    name: 'Free T4',
    group: 'Thyroid',
    unit: 'ng/dL',
    // 1 ng/dL = 12.87 pmol/L.
    units: { 'pmol/L': 1 / 12.87 },
    synonyms: ['Free T4', 'T4, Free', 'T4 Free', 'FT4', 'Free thyroxine', 'Thyroxine, Free', 'T4, Free (Direct)', 'Free T4 (Direct)', 'Thyroxine (T4) Free, Direct', 'Free T4, Direct'],
    typical: { low: 0.82, high: 1.77 },
  },
  {
    key: 'free_t3',
    name: 'Free T3',
    group: 'Thyroid',
    unit: 'pg/mL',
    // 1 pg/mL = 1.536 pmol/L.
    units: { 'pmol/L': 1 / 1.536 },
    synonyms: ['Free T3', 'T3, Free', 'T3 Free', 'FT3', 'Free triiodothyronine', 'Triiodothyronine, Free', 'Triiodothyronine (T3), Free', 'Free T3, Serum'],
    typical: { low: 2.0, high: 4.4 },
  },
  // Hormones.
  {
    key: 'testosterone',
    name: 'Testosterone (total)',
    group: 'Hormones',
    unit: 'ng/dL',
    // 1 nmol/L = 28.84 ng/dL.
    units: { 'nmol/L': 28.84 },
    synonyms: ['Testosterone', 'Testosterone, Total', 'Testosterone Total', 'Total testosterone', 'Testosterone, Serum', 'Testosterone, Total, LC/MS', 'Testosterone, Total, MS', 'Testosterone, Total, Immunoassay'],
    typical: { female: { low: 8, high: 48 }, male: { low: 264, high: 916 } },
  },
  {
    key: 'estradiol',
    name: 'Estradiol',
    group: 'Hormones',
    unit: 'pg/mL',
    // 1 pg/mL = 3.671 pmol/L.
    units: { 'pmol/L': 1 / 3.671 },
    synonyms: ['Estradiol', 'Oestradiol', 'E2', 'Estradiol, Serum', 'Estradiol, Sensitive', 'Estradiol, Ultrasensitive', 'Estradiol (E2)'],
    why: 'It moves through the menstrual cycle and with age, so one typical range would mislead. Only the printed range is used.',
  },
  {
    key: 'cortisol_am',
    name: 'Cortisol (morning)',
    group: 'Hormones',
    unit: 'ug/dL',
    // 1 µg/dL = 27.59 nmol/L.
    units: { 'nmol/L': 1 / 27.59 },
    // A bare "Cortisol" could be an afternoon draw, so it isn't matched here: it stays as its own marker.
    synonyms: ['Cortisol, AM', 'Cortisol AM', 'AM Cortisol', 'Morning cortisol', 'Cortisol - AM', 'Cortisol, A.M.', 'Cortisol (morning)', 'Cortisol, Morning'],
    typical: { low: 6.2, high: 19.4, note: 'morning' },
  },
  // Inflammation. 1 mg/dL = 10 mg/L.
  {
    key: 'hs_crp',
    name: 'hs-CRP',
    group: 'Inflammation',
    unit: 'mg/L',
    units: { 'mg/dL': 10 },
    // Standard CRP has a different range and purpose, so plain "CRP" isn't matched here.
    synonyms: ['hs-CRP', 'hsCRP', 'hs CRP', 'High sensitivity CRP', 'High-sensitivity CRP', 'CRP, High Sensitivity', 'C-Reactive Protein, High Sensitivity', 'High-sensitivity C-reactive protein', 'C-Reactive Protein, Cardiac', 'Cardio CRP', 'CRP, hs'],
    typical: { high: 3 },
  },
  // Blood count. Counts per µL in thousands (= 10^9/L) or millions (= 10^12/L).
  {
    key: 'hemoglobin',
    name: 'Hemoglobin',
    group: 'Blood count',
    unit: 'g/dL',
    units: { 'g/L': 0.1 },
    synonyms: ['Hemoglobin', 'Haemoglobin', 'Hgb', 'Hb'],
    typical: { female: { low: 12, high: 15.5 }, male: { low: 13.5, high: 17.5 } },
  },
  {
    key: 'hematocrit',
    name: 'Hematocrit',
    group: 'Blood count',
    unit: '%',
    units: { 'L/L': 100 },
    synonyms: ['Hematocrit', 'Haematocrit', 'Hct', 'PCV', 'Packed cell volume'],
    typical: { female: { low: 34.9, high: 44.5 }, male: { low: 38.8, high: 50 } },
  },
  {
    key: 'wbc',
    name: 'White blood cells',
    group: 'Blood count',
    unit: '10^3/uL',
    synonyms: ['WBC', 'WBC Count', 'White blood cells', 'White blood cell count', 'White Blood Cell (WBC) Count', 'Leukocytes', 'Leukocyte count', 'Total WBC'],
    typical: { low: 3.4, high: 10.8 },
  },
  {
    key: 'rbc',
    name: 'Red blood cells',
    group: 'Blood count',
    unit: '10^6/uL',
    synonyms: ['RBC', 'RBC Count', 'Red blood cells', 'Red blood cell count', 'Red Blood Cell (RBC) Count', 'Erythrocytes', 'Erythrocyte count'],
    typical: { female: { low: 3.77, high: 5.28 }, male: { low: 4.14, high: 5.8 } },
  },
  {
    key: 'platelets',
    name: 'Platelets',
    group: 'Blood count',
    unit: '10^3/uL',
    synonyms: ['Platelets', 'Platelet count', 'Platelet Count', 'PLT', 'Thrombocytes'],
    typical: { low: 150, high: 450 },
  },
  // Liver.
  {
    key: 'alt',
    name: 'ALT',
    group: 'Liver',
    unit: 'U/L',
    synonyms: ['ALT', 'ALT (SGPT)', 'SGPT', 'Alanine aminotransferase', 'Alanine transaminase', 'ALAT', 'GPT'],
    typical: { low: 7, high: 55 },
  },
  {
    key: 'ast',
    name: 'AST',
    group: 'Liver',
    unit: 'U/L',
    synonyms: ['AST', 'AST (SGOT)', 'SGOT', 'Aspartate aminotransferase', 'Aspartate transaminase', 'ASAT', 'GOT'],
    typical: { low: 8, high: 48 },
  },
  // Kidney.
  {
    key: 'creatinine',
    name: 'Creatinine',
    group: 'Kidney',
    unit: 'mg/dL',
    // 1 mg/dL = 88.42 µmol/L.
    units: { 'umol/L': 1 / 88.42 },
    synonyms: ['Creatinine', 'Serum creatinine', 'Creatinine, Serum', 'Creat', 'CREA'],
    typical: { female: { low: 0.59, high: 1.04 }, male: { low: 0.74, high: 1.35 } },
  },
  {
    key: 'egfr',
    name: 'eGFR',
    group: 'Kidney',
    unit: 'mL/min/1.73m2',
    synonyms: ['eGFR', 'GFR, Estimated', 'Estimated GFR', 'eGFR (CKD-EPI)', 'eGFR CKD-EPI', 'Estimated glomerular filtration rate', 'Glomerular filtration rate, estimated', 'eGFR If NonAfricn Am', 'eGFR Non-Afr. American'],
    typical: { low: 60 },
  },
  {
    key: 'bun',
    name: 'Urea nitrogen (BUN)',
    group: 'Kidney',
    unit: 'mg/dL',
    // 1 mmol/L of urea nitrogen = 2.801 mg/dL.
    units: { 'mmol/L': 2.801 },
    synonyms: ['BUN', 'Blood urea nitrogen', 'Urea nitrogen', 'Urea Nitrogen (BUN)', 'Urea Nitrogen, Blood'],
    typical: { low: 6, high: 24 },
  },
  {
    key: 'uric_acid',
    name: 'Uric acid',
    group: 'Kidney',
    unit: 'mg/dL',
    // 1 mg/dL = 59.48 µmol/L.
    units: { 'umol/L': 1 / 59.48 },
    synonyms: ['Uric acid', 'Urate', 'Uric Acid, Serum', 'Serum uric acid'],
    typical: { female: { low: 2.4, high: 6 }, male: { low: 3.4, high: 7 } },
  },
  // Electrolytes. Sodium and potassium are monovalent (mEq/L = mmol/L); calcium is divalent.
  {
    key: 'sodium',
    name: 'Sodium',
    group: 'Electrolytes',
    unit: 'mmol/L',
    units: { 'mEq/L': 1 },
    synonyms: ['Sodium', 'Na', 'Serum sodium', 'Sodium, Serum'],
    typical: { low: 135, high: 145 },
  },
  {
    key: 'potassium',
    name: 'Potassium',
    group: 'Electrolytes',
    unit: 'mmol/L',
    units: { 'mEq/L': 1 },
    synonyms: ['Potassium', 'K', 'Serum potassium', 'Potassium, Serum'],
    typical: { low: 3.5, high: 5.1 },
  },
  {
    key: 'calcium',
    name: 'Calcium',
    group: 'Electrolytes',
    unit: 'mg/dL',
    // 1 mmol/L = 4.008 mg/dL; 1 mEq/L = 0.5 mmol/L.
    units: { 'mmol/L': 4.008, 'mEq/L': 2.004 },
    synonyms: ['Calcium', 'Ca', 'Calcium, Total', 'Total calcium', 'Calcium, Serum'],
    typical: { low: 8.6, high: 10.3 },
  },
];

// ---------- names ----------

/** Lower case, accents and punctuation gone: "Vitamin D, 25-Hydroxy" → "vitamin d 25 hydroxy". */
export function normalizeName(s: string) {
  return s
    .replace(/[µμ]/g, 'u')
    .normalize('NFKD')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, ' ')
    .trim();
}

/** Words that don't change which marker it is ("Glucose, Serum", "Iron, Total") and spellings to unify. */
const FILLER = new Set(['serum', 'plasma', 'blood', 'whole', 'level', 'levels', 'test', 'result', 'total', 'calc', 'calculated', 'measured']);
const SPELLING: Record<string, string> = { chol: 'cholesterol', vit: 'vitamin', haemoglobin: 'hemoglobin', haematocrit: 'hematocrit', oestradiol: 'estradiol' };

function loose(norm: string) {
  return norm
    .split(' ')
    .map((w) => SPELLING[w] ?? w)
    .filter((w) => w && !FILLER.has(w))
    .join(' ');
}

const BY_KEY = new Map(BIOMARKERS.map((b) => [b.key, b]));
/** Exact normalised names first, then the looser form; a name that could mean two markers would be a catalog bug. */
const BY_NAME = new Map<string, string>();
const BY_LOOSE = new Map<string, string>();
for (const b of BIOMARKERS) {
  for (const s of [b.name, ...b.synonyms]) {
    const n = normalizeName(s);
    for (const [map, k] of [
      [BY_NAME, n],
      [BY_LOOSE, loose(n)],
    ] as const) {
      const had = map.get(k);
      if (had && had !== b.key) throw new Error(`Lab catalog: "${s}" matches both ${had} and ${b.key}`);
      if (k) map.set(k, b.key);
    }
  }
}

/** The catalog entry for a key, if it's one. */
export const biomarker = (key: string) => BY_KEY.get(key);

/**
 * The catalog key for a printed name, or null when the catalog doesn't know it. Exact after normalising, never a
 * partial match: "Free testosterone" must not become total testosterone, nor "Non-HDL" HDL.
 */
export function matchBiomarker(name: string): string | null {
  const n = normalizeName(name);
  if (!n) return null;
  return BY_NAME.get(n) ?? BY_LOOSE.get(loose(n)) ?? null;
}

/**
 * The sample a result is from when it isn't blood, read from its panel ("Urinalysis", "Microscopic exam") or its
 * name ("Glucose, Urine"). The catalog's markers are all blood tests, so these never become one of them.
 */
const SPECIMENS: { specimen: string; panel: RegExp; name: RegExp; words: Set<string> }[] = [
  {
    specimen: 'urine',
    // "U/A" and "U.A." normalise to "u a".
    panel: /\b(urine|urinalysis|urinary|ua|u a|microscopic|microscopy|dipstick)\b/,
    name: /\b(urine|urinalysis|urinary)\b/,
    words: new Set(['urine', 'urinalysis', 'urinary', 'ua']),
  },
  { specimen: 'stool', panel: /\b(stool|fecal|faecal|feces|faeces)\b/, name: /\b(stool|fecal|faecal|feces|faeces)\b/, words: new Set(['stool', 'fecal', 'faecal', 'feces', 'faeces']) },
];

export function specimenOf(name: string, panel = ''): string | null {
  const [n, p] = [normalizeName(name), normalizeName(panel)];
  return SPECIMENS.find((s) => s.panel.test(p) || s.name.test(n))?.specimen ?? null;
}

const slug = (norm: string) => norm.replace(/ /g, '-').slice(0, 60) || 'unnamed';

/**
 * The key a result is stored under: the catalog's, or 'other:<slug>' so a marker the catalog doesn't know still
 * joins up. A result from urine or stool is 'other:<specimen>-<name>' whatever its name: a urinalysis "Glucose"
 * must never join blood glucose, and "Glucose" on a urinalysis joins "Glucose, Urine" from another lab.
 */
export function markerKey(name: string, panel = ''): string {
  const specimen = specimenOf(name, panel);
  if (specimen) {
    const words = SPECIMENS.find((s) => s.specimen === specimen)!.words;
    const rest = normalizeName(name)
      .split(' ')
      .filter((w) => w && !words.has(w))
      .join(' ');
    return `other:${specimen}-${slug(rest)}`;
  }
  return matchBiomarker(name) ?? `other:${slug(normalizeName(name))}`;
}

export const isOther = (key: string) => key.startsWith('other:');

/** The marker's name: the catalog's, or the printed one, with the sample when it isn't blood ("Glucose (urine)"). */
export function markerName(key: string, printed: string) {
  const def = BY_KEY.get(key);
  if (def) return def.name;
  const specimen = SPECIMENS.find((s) => key.startsWith(`other:${s.specimen}-`));
  return specimen && !specimen.name.test(normalizeName(printed)) ? `${printed} (${specimen.specimen})` : printed;
}

export function markerGroup(key: string) {
  return BY_KEY.get(key)?.group ?? 'Other';
}

/** Sort order: the catalog's, then markers it doesn't know by name. */
export function markerOrder(key: string) {
  const i = BIOMARKERS.findIndex((b) => b.key === key);
  return i < 0 ? BIOMARKERS.length : i;
}

// ---------- units ----------

/**
 * One spelling per unit: "µg/dL", "mcg/dL" and "ug/dl" are the same; "K/uL", "x10E3/uL" and "10^9/L" are the same
 * count. Mathematically identical units only; mEq/L vs mmol/L depends on the ion, so that's per marker.
 */
export function unitKey(u: string): string {
  let k = u
    .trim()
    .replace(/[µμ]/g, 'u')
    .toLowerCase()
    .replace(/\s+/g, '')
    .replace(/mcg/g, 'ug')
    .replace(/²/g, '2')
    .replace(/\^2/g, '2')
    .replace(/³/g, '3');
  k = k.replace(/^x/, '').replace(/10[e*]/g, '10^').replace(/10\((\d+)\)/g, '10^$1');
  const SAME: Record<string, string> = {
    'k/ul': '10^3/ul',
    'thou/ul': '10^3/ul',
    '10^3/mm3': '10^3/ul',
    '10^9/l': '10^3/ul',
    'm/ul': '10^6/ul',
    'mil/ul': '10^6/ul',
    '10^6/mm3': '10^6/ul',
    '10^12/l': '10^6/ul',
    'uiu/ml': 'miu/l',
    'uu/ml': 'miu/l',
    'mu/l': 'miu/l',
    'ug/l': 'ng/ml',
    'ng/l': 'pg/ml',
    'iu/l': 'u/l',
    'ml/min/1.73m2': 'ml/min/1.73m2',
    'ml/min/1.73': 'ml/min/1.73m2',
  };
  return SAME[k] ?? k;
}

function toCanonical(def: MarkerDef, unit: string): [number, number] | null {
  const k = unitKey(unit);
  if (k === unitKey(def.unit)) return [1, 0];
  for (const [u, f] of Object.entries(def.units ?? {})) if (unitKey(u) === k) return typeof f === 'number' ? [f, 0] : f;
  return null;
}

/**
 * A value from one unit in another, for one marker (mg/dL → mmol/L differs for glucose and cholesterol). The same
 * unit, however it's spelled, comes back unchanged; null when the catalog has no explicit conversion.
 */
export function convert(value: number, from: string, to: string, key: string): number | null {
  if (unitKey(from) === unitKey(to)) return value;
  const def = BY_KEY.get(key);
  if (!def) return null;
  const f = toCanonical(def, from);
  const t = toCanonical(def, to);
  if (!f || !t) return null;
  return (value * f[0] + f[1] - t[1]) / t[0];
}

/** The units a marker is printed in, for suggestions while typing. */
export function markerUnits(key: string): string[] {
  const def = BY_KEY.get(key);
  return def ? [def.unit, ...Object.keys(def.units ?? {})] : [];
}

// ---------- values and ranges ----------

/**
 * One number as labs print it, the same grammar for a result and for its range: "250,000" (thousands), "5,4" (a
 * decimal comma), "-2.0", ".5". A sign straight after a letter is a hyphen ("Adult-13-17"), not a minus. A result is
 * read in its range's comma style: "2,350" beside "0,270-4,200" is 2.35, not 2350.
 */
const NUM = String.raw`(?:(?<![A-Za-z\d.,])[-+])?(?:[1-9]\d{0,2}(?:,\d{3})+(?:\.\d+)?|\d+(?:[.,]\d+)?|\.\d+)`;
const THOUSANDS = /^[-+]?[1-9]\d{0,2}(,\d{3})+(\.\d+)?$/;
/** A comma that can only be a decimal one ("0,450", "5,4"), not thousands ("4,500"). */
const isDecimalComma = (raw: string) => raw.includes(',') && !THOUSANDS.test(raw);

/** "250,000" → 250000; "5,4" → 5.4, or with decimalComma, "4,500" → 4.5. */
function readNumber(raw: string, decimalComma = false): number {
  return !decimalComma && THOUSANDS.test(raw) ? Number(raw.replace(/,/g, '')) : Number(raw.replace(',', '.'));
}

/** Minus signs, dashes and "≤ ≥" as plain characters. */
const plain = (s: string) => s.replace(/−/g, '-').replace(/≤/g, '<=').replace(/≥/g, '>=');

/**
 * "5.4", "<0.5", "> 90", "1,234", "5,4", "250 H" → a number and its qualifier; "Negative" → no number. With
 * decimalComma (its range has one: rangeDecimalComma), "2,350" is 2.35.
 */
export function parseResultValue(text: string, decimalComma = false): { value: number | null; qualifier: LabQualifier | null } {
  let t = plain(text.trim());
  // A flag printed after the number ("250 H", "3.1 (L)", "7.2*") isn't part of it.
  t = t.replace(/\s*(\(\s*(h|l|hh|ll|high|low|a|abn|abnormal)\s*\)|\b(h|l|hh|ll|high|low|a|abn|abnormal)\b|\*+)\s*$/i, '').trim();
  const m = new RegExp(String.raw`^(<=?|>=?|less than|greater than)?\s*(${NUM})$`, 'i').exec(t);
  if (!m) return { value: null, qualifier: null };
  const num = readNumber(m[2], decimalComma);
  if (!Number.isFinite(num)) return { value: null, qualifier: null };
  const q = m[1]?.toLowerCase();
  const qualifier = !q ? null : q.startsWith('<') || q === 'less than' ? '<' : '>';
  return { value: num, qualifier };
}

export type Bounds = { low: number | null; high: number | null; lowOpen: boolean; highOpen: boolean };

/** Each range in normalised text: "a-b" pairs and one-sided "<b", ">=a". A pair printed the wrong way round is null. */
const RANGE = new RegExp(String.raw`(${NUM})\s*-\s*(${NUM})|(<=?|>=?)\s*(${NUM})`, 'g');

function rangesIn(t: string): (Bounds | null)[] {
  return [...t.matchAll(RANGE)].map((m): Bounds | null => {
    if (m[1] !== undefined) {
      // One style per range: if either bound has a decimal comma ("0,450-4,500"), so has the other.
      const comma = [m[1], m[2]].some(isDecimalComma);
      const [low, high] = [readNumber(m[1], comma), readNumber(m[2], comma)];
      return Number.isFinite(low) && Number.isFinite(high) && low <= high ? { low, high, lowOpen: false, highOpen: false } : null;
    }
    const v = readNumber(m[4]);
    if (!Number.isFinite(v)) return null;
    return m[3].startsWith('<') ? { low: null, high: v, lowOpen: false, highOpen: m[3] === '<' } : { low: v, high: null, lowOpen: m[3] === '>', highOpen: false };
  });
}

const rangeTextOf = (text: string) =>
  plain(text)
    .replace(/[–—]/g, '-')
    .replace(/([<>])\s*or\s*=/gi, '$1=')
    .replace(/\bto\b/gi, '-');

/** A band's label: "Male", "Women", "M:", "(F)". */
const SEX_LABEL = /\b(females?|wom[ae]n|males?|m[ae]n)\b|\b([fm])\s*[:=]|\(\s*([fm])\s*\)/gi;

/** How many ranges the printed text holds: 0 ("Negative"), 1, or more (bands by sex or age, "Optimal <100, Borderline 100-129"). */
export function rangeCount(text: string) {
  return rangesIn(rangeTextOf(text)).length;
}

/** Whether a printed range writes its numbers with a decimal comma ("0,270 - 4,200"), so its result is read that way too. */
export function rangeDecimalComma(text: string) {
  return [...rangeTextOf(text).matchAll(RANGE)].some((m) => [m[1], m[2], m[4]].some((s) => s !== undefined && isDecimalComma(s)));
}

/**
 * The numbers in a printed reference range: "3.5-5.0", "3.5 – 5.0 mmol/L", "<200", "> OR = 40", "Desirable: <100",
 * "150,000-450,000", "-2.0-2.0". "<200" is open (200 itself is outside); "<=200" isn't. Null when it holds no range
 * ("Negative", "See note").
 *
 * Text with more than one range is never read as its first one. Bands labelled by sex, each label before its one
 * range ("Male: 13.0-17.0 Female: 12.0-15.0"), give the band for the sex passed in; anything else (no sex chosen,
 * age bands, categories, a label after its range) is null, so the range shows as printed with no status.
 */
export function parseRange(text: string, sex: Sex = null): Bounds | null {
  const t = rangeTextOf(text);
  const all = rangesIn(t);
  if (all.length <= 1) return all[0] ?? null;
  if (sex !== 'female' && sex !== 'male') return null;
  const labels = [...t.matchAll(SEX_LABEL)];
  if (!labels.length || rangesIn(t.slice(0, labels[0].index)).length) return null;
  const bands = labels.map((l, i) => ({
    sex: /^(f|wom)/i.test(l[1] ?? l[2] ?? l[3]) ? 'female' : 'male',
    ranges: rangesIn(t.slice(l.index + l[0].length, labels[i + 1]?.index ?? t.length)),
  }));
  if (bands.some((b) => b.ranges.length !== 1)) return null;
  const mine = bands.filter((b) => b.sex === sex);
  return mine.length === 1 ? mine[0].ranges[0] : null;
}

/**
 * Where an exact value sits against a range. Bounds count as inside unless the range was printed open ("<200").
 * Null when there's no value or no range.
 */
export function statusOf(value: number | null, low: number | null, high: number | null, open: { low?: boolean; high?: boolean } = {}): LabStatus | null {
  if (value === null || !Number.isFinite(value) || (low === null && high === null)) return null;
  if (low !== null && (open.low ? value <= low : value < low)) return 'below';
  if (high !== null && (open.high ? value >= high : value > high)) return 'above';
  return 'within';
}

/**
 * The same for a result as printed. "<0.5" is anywhere under 0.5, so it's within a "<3" range and below a "1-3"
 * range only when 0.5 is at or under the bottom; otherwise it can't be placed and the status is null.
 */
export function resultStatus(r: { value: number | null; qualifier: LabQualifier | null }, b: Bounds | null): LabStatus | null {
  if (!b || r.value === null) return null;
  if (!r.qualifier) return statusOf(r.value, b.low, b.high, { low: b.lowOpen, high: b.highOpen });
  const v = r.value;
  if (r.qualifier === '<') {
    if (b.low !== null && b.low > 0 && v <= b.low) return 'below';
    // A lower bound of 0 is no bound for a concentration: "<0.3" against "0.00-3.00" is within it.
    if ((b.low === null || b.low <= 0) && b.high !== null && v <= b.high) return 'within';
    return null;
  }
  if (b.high !== null && v >= b.high) return 'above';
  if (b.high === null && b.low !== null && v >= b.low) return 'within';
  return null;
}

export type Sex = 'female' | 'male' | 'unspecified' | null;

/**
 * The catalog's typical adult range for a marker, only in its own unit (a range isn't converted to judge a result
 * in another unit), and only for the sex chosen in the profile where the range differs by sex.
 */
export function typicalRange(key: string, unit: string, sex: Sex): LabRange | null {
  const def = BY_KEY.get(key);
  if (!def?.typical || unitKey(unit) !== unitKey(def.unit)) return null;
  const t = def.typical;
  const r: Typical | undefined = 'female' in t ? (sex === 'female' || sex === 'male' ? { ...t[sex], note: t[sex].note ?? t.note } : undefined) : t;
  if (!r) return null;
  const low = r.low ?? null;
  const high = r.high ?? null;
  return { low, high, text: rangeText(low, high), kind: 'typical', ...(r.note ? { note: r.note } : {}) };
}

/** A range written out: "3.5–5.0", "≤ 199", "≥ 40". */
export function rangeText(low: number | null, high: number | null) {
  if (low !== null && high !== null) return `${low}–${high}`;
  if (high !== null) return `≤ ${high}`;
  if (low !== null) return `≥ ${low}`;
  return '';
}

export const STATUS_WORDS: Record<LabStatus, string> = { below: 'Below range', within: 'Within range', above: 'Above range' };

// ---------- words for the dashboard ----------

/** The status in words. A typical range says so, so it's never mistaken for the lab's own. */
export function statusLabel(r: LabResult): string {
  if (r.status) {
    const where = { below: 'Below', within: 'Within', above: 'Above' }[r.status];
    return `${where} ${r.range?.kind === 'typical' ? 'typical range' : 'range'}`;
  }
  if (!r.range) return 'No range printed';
  if (r.value === null) return 'Compare with range';
  // A printed range with no numbers in it ("See note"), not several bands.
  if (r.range.low === null && r.range.high === null && r.range.band === undefined) return 'Compare with range';
  return 'Can’t be placed';
}

/** Why there's no status, or which range a status is against when it isn't simply the printed one. */
export function statusHint(r: LabResult): string | undefined {
  const range = r.range;
  if (r.status && range?.kind === 'typical') return `The report printed no range, so this uses a typical adult range${range.note ? ` (${range.note})` : ''}.`;
  if (r.status && range?.band) return `The report printed more than one range. This uses the one for ${range.band === 'female' ? 'women' : 'men'}, from the sex in your profile.`;
  if (r.status) return undefined;
  if (!range) return "The report printed no range, and there's no typical range to use for this marker.";
  if (r.value === null) return 'The result is a word, not a number: compare it with the printed range.';
  if (range.band === null) {
    return "The printed range has more than one band (by sex or age), so this result isn't placed against any one of them. If your profile has no sex chosen and the bands are for women and men, choosing one may place it.";
  }
  if (range.low === null && range.high === null) return 'The printed range has no numbers to place this against: compare the result with the range as printed.';
  return `Printed as ${r.valueText}, which could fall on either side of the range.`;
}

/** The range text as printed, with a note when it's the typical one or one band of several. */
export function rangeLabel(r: LabResult) {
  if (!r.range) return '—';
  if (r.range.kind === 'typical') return `${r.range.text} (typical adult${r.range.note ? `, ${r.range.note}` : ''})`;
  return r.range.band ? `${r.range.text} (${r.range.band} range used)` : r.range.text;
}

/**
 * Why some of a marker's results aren't on its chart, one sentence per reason, counted from the results themselves:
 * printed with "<" or ">", printed as a word, or in a unit that can't be converted to the latest one's.
 */
export function undrawnReasons(m: Pick<LabMarker, 'history' | 'points' | 'latest'>): string[] {
  const drawn = new Set(m.points.map((p) => p.id));
  const rest = m.history.filter((h) => !drawn.has(h.id));
  const words = rest.filter((h) => h.value === null).length;
  const bounded = rest.filter((h) => h.value !== null && h.qualifier).length;
  const units = rest.length - words - bounded;
  const are = (n: number) => (n === 1 ? 'One result is' : `${n} results are`);
  const notDrawn = (n: number) => (n === 1 ? "it isn't drawn" : "they aren't drawn");
  const out: string[] = [];
  if (bounded) out.push(`${are(bounded)} printed with < or >, so ${bounded === 1 ? 'it has' : 'they have'} no exact value to draw.`);
  if (words) out.push(`${are(words)} ${words === 1 ? 'a word, not a number' : 'words, not numbers'}, so ${notDrawn(words)}.`);
  if (units) out.push(`${are(units)} in a unit that can't be put on the same scale as the latest result${m.latest.unit ? ` (${m.latest.unit})` : ''}, so ${notDrawn(units)}.`);
  return out;
}

/**
 * Rows read from a report as collections to check: one per date and lab (a lab left blank joins the date's only
 * named lab). Rows without a date are kept apart from rows whose date read couldn't be used, so each says why.
 */
export function draftGroups(rows: LabDraft[]): { collected: string; lab: string; dateDropped: boolean; rows: LabDraft[] }[] {
  const byDate = new Map<string, LabDraft[]>();
  for (const r of rows) {
    const k = r.collected ?? (r.dateDropped ? '\u0000dropped' : '');
    byDate.set(k, [...(byDate.get(k) ?? []), r]);
  }
  const out: ReturnType<typeof draftGroups> = [];
  for (const rs of byDate.values()) {
    const labs = [...new Set(rs.map((r) => r.lab ?? '').filter(Boolean))];
    const base = { collected: rs[0].collected ?? '', dateDropped: rs[0].collected === null && Boolean(rs[0].dateDropped) };
    if (labs.length <= 1) {
      out.push({ ...base, lab: labs[0] ?? '', rows: rs });
      continue;
    }
    for (const lab of [...labs, '']) {
      const mine = rs.filter((r) => (r.lab ?? '') === lab);
      if (mine.length) out.push({ ...base, lab, rows: mine });
    }
  }
  return out;
}
