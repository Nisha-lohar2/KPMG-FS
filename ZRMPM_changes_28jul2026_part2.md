# ZR_RMPM_DEFICIT_FG_REPORT_V2 — Change Document (Part 2)

**Date:** 28-Jul-2026
**Object:** `ZR_RMPM_DEFICIT_FG_REPORT_V2` (WRICEF-ID 7 — RM/PM deficit based on FG deficit)
**Predecessor:** `ZRMPM_changes_28jul2026.md` (Part 1 — FG Deficit columns + unique headers)
**Scope of change:** Both ALVs. FG Deficit gains Min/Max Stock; BOM Component Details loses five
columns and gains a stock breakup; negative-deficit rows are highlighted in both.

---

## 1. Summary of the request

| # | Requirement | Where implemented |
|---|-------------|-------------------|
| 1 | FG Deficit ALV: add **Minimum Stock** and **Maximum Stock** | `TY_FG`, `TY_OUT`, `FILL_FG_EXTRA_DATA`, `MOVE_FG_TO_OUT`, `DISPLAY_ALV` |
| 2 | BOM Component Details ALV: remove **Min Stock, Max Stock, Net Weight, Work Center, PRT** | `BUILD_AND_ENRICH_OUTPUT`, `DISPLAY_ALV` |
| 3 | BOM Component Details ALV: add **stock breakup** — FG Unrestricted/Quality and Component Unrestricted/Quality | `TY_OUT`, `BUILD_AND_ENRICH_OUTPUT`, `MOVE_FG_TO_OUT`, `DISPLAY_ALV` |
| 4 | Highlight rows in **red** where FG Deficit/Surplus < 0, in **both** ALVs | new `SET_ROW_COLORS`, `DISPLAY_ALV` |

---

## 2. Points to confirm

| # | Point | Decision taken |
|---|-------|----------------|
| 1 | **"Full SAP ECC compatibility"** was requested, but this report is built entirely on S/4HANA CDS views (`I_SalesDocumentItem`, `I_Product`, `I_ProductPlant`, `I_ProductSupplyPlanning`, `I_BillOfMaterial*`, `I_DeliveryDocumentItem`, `I_PurchaseOrder*`) and S/4 stock views (`NSDM_V_MCHB`, `NSDM_V_MARD`, `V_MBEW_MD`). **None of these exist in ECC.** | The report **is not ECC-executable today**, and making it so would mean re-platforming the whole data layer onto classic tables (`VBAP`/`VBAK`, `MARA`/`MARC`, `MCHB`/`MARD`, `EKKO`/`EKPO`, `MAST`/`STPO`) — a rewrite, and one that directly contradicts *"do not modify the existing business calculations or report flow"*. **No CDS view was changed.** All code added in this round is release-neutral (see #2). Flagging for a decision: either drop the ECC requirement, or raise the re-platforming as its own work item. |
| 2 | Row-colouring technique — `INFO_FNAME` was suggested. | `INFO_FNAME` belongs to the classic `REUSE_ALV_GRID_DISPLAY` layout; this report uses `CL_SALV_TABLE`. Used the SALV equivalent: an `LVC_T_SCOL` colour column registered via `SET_COLOR_COLUMN`. This is the same DDIC structure the classic grid consumes, so it is release-neutral and works in ECC as well as S/4. |
| 3 | **Storage Location** appears again in the requested FG output list. | Unchanged from Part 1 §2: **still dropped.** FG stock is aggregated across storage locations and the deficit formula works per Material/Plant, so there is no single storage location per FG row. Showing it would require changing output granularity (and risking double-counted Open SO / Open STO figures) or leaving the column permanently blank. |
| 4 | Removing Min/Max, Net Weight, Work Center and PRT from the BOM ALV leaves their retrieval doing no work. | The three bulk retrievals were **commented out**, not left running — otherwise the removal would have kept four redundant database round trips per execution. Fields kept in `TY_OUT` and their `SET_COL` headers retained, so re-enabling is a small, local change. |

---

## 3. Structure changes

### 3.1 `TY_FG` — two new FG-level fields

```abap
fg_min     TYPE menge_d,     "Minimum stock level (FG)
fg_max     TYPE menge_d,     "Maximum stock level (FG)
```

### 3.2 `TY_OUT` — four new display fields plus the colour column

```abap
fg_min       TYPE menge_d,   "FG mode only
fg_max       TYPE menge_d,   "FG mode only
rmpm_unres   TYPE menge_d,   "BOM mode only (component split)
rmpm_qual    TYPE menge_d,   "BOM mode only (component split)
t_color      TYPE lvc_t_scol, "row colour (not a visible column)
```

`FG_UNRES` / `FG_QUAL` already existed from Part 1 — they are **not** new fields, but they are
now shown in *both* modes rather than FG mode only.

### 3.3 New constants

```abap
gc_color_negative TYPE i VALUE 6,   "COL_NEGATIVE
gc_color_intensiv TYPE i VALUE 1,
gc_color_not_inv  TYPE i VALUE 0,
```

Typed `I` rather than `LVC_COL` / `LVC_INT` / `LVC_INV` on purpose: the underlying domains of
those data elements differ across releases, and a numeric literal converts cleanly into all of
them on assignment.

---

## 4. Data retrieval for the new fields

**No new SELECT statement was written.** Every new value comes from a bulk form that already
existed:

| New field | Source | Extra DB cost |
|-----------|--------|---------------|
| `FG_MIN`, `FG_MAX` | `GET_MIN_MAX_STOCK` (`I_ProductSupplyPlanning`) called with **FG keys** instead of component keys, from `FILL_FG_EXTRA_DATA` | One bulk read, FG mode only — and it *replaces* the component-key call that requirement 2 removed |
| `FG_UNRES`, `FG_QUAL` | `FILL_FG_STOCK` → `GET_TOTAL_STOCK`, which already returns `UNRES` / `QUAL` / `MENGE` per key in `TY_QTY` | **Zero** |
| `RMPM_UNRES`, `RMPM_QUAL` | The *same* `GET_TOTAL_STOCK` call already made for component stock — all three figures come off one `TY_QTY` row | **Zero** |

`FILL_FG_EXTRA_DATA` runs only in FG Deficit mode, so Min/Max, Net Weight and Work Center/PRT
are never fetched in BOM mode where they are not displayed.

Net database effect of this round: **fewer reads than before.** BOM mode drops three bulk
retrievals (`GET_MIN_MAX_STOCK`, `GET_NET_WEIGHT`, `GET_WORKCENTER_PRT`); FG mode adds one
(`GET_MIN_MAX_STOCK`).

---

## 5. Column visibility per mode

| Column | FG Deficit | BOM Component Details |
|---|---|---|
| `MATNR`, `MAKTX`, `MATKL`, `MATCAT`, `WERKS` | shown | shown |
| `FG_UNRES`, `FG_QUAL` | shown | **shown** (new — FG half of the breakup) |
| `FG_MIN`, `FG_MAX` | **shown** (new) | hidden |
| `FG_NETWT`, `FG_ARBPL`, `FG_PRT` | shown | hidden |
| `FG_STOCK`, `TOT_SO`, `NET_STO`, `DEFICIT_FG` | shown | shown |
| `IDNRK`, `QTY_BOM`, `RMPM_STOCK`, `RMPM_DEFICIT` | hidden | shown |
| `RMPM_UNRES`, `RMPM_QUAL` | hidden | **shown** (new — component half) |
| `MIN_STOCK`, `MAX_STOCK`, `NET_WEIGHT`, `ARBPL`, `EQUNR` | hidden | **hidden** (removed per req. 2) |
| `T_COLOR` | never rendered — consumed by `SET_COLOR_COLUMN` | same |

### Headers

`FG_UNRES` / `FG_QUAL` carry **mode-dependent** headers so the two stock blocks can never be
confused when they sit side by side in BOM mode:

| Field | FG Deficit mode | BOM Component Details mode |
|---|---|---|
| `FG_UNRES` | Unrestricted Stock | **FG** Unrestricted Stock |
| `FG_QUAL` | Quality Stock | **FG** Quality Stock |
| `RMPM_UNRES` | — | BOM Component Unrestricted Stock |
| `RMPM_QUAL` | — | BOM Component Quality Stock |

All new columns supply a **short** text as well as medium and long — the same fix Part 1 applied,
without which `SET_OPTIMIZE` makes SALV fall back to `MENGE_D`'s generic "Quantity". Verified all
texts are within the SCRTEXT_S/M/L limits of 10 / 20 / 40 characters.

---

## 6. Row highlighting

New `FORM SET_ROW_COLORS`, called from `START-OF-SELECTION` after the output table is built and
before `DISPLAY_ALV`, so it covers **both** modes:

```abap
FORM set_row_colors.

  DATA ls_scol TYPE lvc_s_scol.

  CLEAR ls_scol-fname.                       "blank = entire row
  ls_scol-color-col = gc_color_negative.     "6 = red
  ls_scol-color-int = gc_color_intensiv.
  ls_scol-color-inv = gc_color_not_inv.

  LOOP AT gt_out ASSIGNING FIELD-SYMBOL(<out>) WHERE deficit_fg < 0.
    APPEND ls_scol TO <out>-t_color.
  ENDLOOP.

ENDFORM.
```

and in `DISPLAY_ALV`, after `SET_OPTIMIZE`:

```abap
lo_cols->set_color_column( 'T_COLOR' ).
```

Notes:

- An **empty `FNAME`** colours the entire row rather than a single cell.
- Rows with a zero or positive Deficit/Surplus get **no** `T_COLOR` entry and therefore keep
  standard ALV formatting.
- `DEFICIT_FG` is an FG-level field carried on *every* output row in either mode, so in BOM mode
  all component rows belonging to a deficit FG are highlighted too.
- One in-memory pass over an already-built table; no database access, no per-cell work.
- SALV consumes the registered colour column and does not render it, so no explicit hide is needed.

---

## 7. FORM routines modified

| FORM | Change |
|------|--------|
| *(declarations)* | `TY_FG` +2 fields; `TY_OUT` +5 fields; +3 colour constants |
| `START-OF-SELECTION` | added `PERFORM set_row_colors` before `display_alv` |
| `FILL_FG_EXTRA_DATA` | added `GET_MIN_MAX_STOCK` call with FG keys + in-memory assignment of `FG_MIN` / `FG_MAX` |
| `BUILD_AND_ENRICH_OUTPUT` | added `RMPM_UNRES` / `RMPM_QUAL` from the existing stock read; commented out the Min/Max, Net Weight and Work Center/PRT retrievals and assignments; dropped the now-unused `LT_FG_KEYS` build |
| `MOVE_FG_TO_OUT` | copies `FG_MIN` / `FG_MAX`; comments clarify that `FG_UNRES` / `FG_QUAL` now feed both modes |
| `DISPLAY_ALV` | `SET_COLOR_COLUMN`; mode-dependent `FG_UNRES` / `FG_QUAL` headers; `SET_COL` for `FG_MIN`, `FG_MAX`, `RMPM_UNRES`, `RMPM_QUAL`; per-mode hide lists moved inline |
| `SET_ROW_COLORS` | **new** |
| `HIDE_COLS` | **new** — replaces `HIDE_FG_ONLY_COLUMNS` and `HIDE_COMPONENT_COLUMNS`, which did identical work on different lists |
| `HIDE_FG_ONLY_COLUMNS`, `HIDE_COMPONENT_COLUMNS` | **removed** (superseded by `HIDE_COLS`) |

Untouched: `BUILD_FG_CANDIDATES`, `FILL_FG_MASTER_DATA`, `FILL_FG_STOCK`, `GET_TOTAL_STOCK`,
`ADD_QTY`, `ADD_STOCK_QTY`, `FILL_TOTAL_SALES_ORDER`, `FILL_NET_TOTAL_STO`, `CALC_FG_DEFICIT`,
`EXPLODE_DEFICIT_BOMS`, `GET_ACTIVE_BOM_ALT`, `EXPLODE_SINGLE_BOM`, `BUILD_FG_OUTPUT`,
`GET_MIN_MAX_STOCK`, `GET_NET_WEIGHT`, `GET_WORKCENTER_PRT`, `SET_COL`, `CHECK_AUTHORIZATION`,
`LOAD_SLOC_EXCLUSIONS`.

No deficit formula, no stock rule, no BOM-explosion behaviour and no selection-screen field was
altered.

---

## 8. Technical requirements — compliance

| Requirement | Status |
|---|---|
| No `SELECT` inside a loop | **Verified** — automated scan of the whole program tracking `LOOP AT`/`ENDLOOP` depth found zero `SELECT` statements at depth > 0 |
| Bulk retrieval only | **Yes** — no new SELECT written at all; all new values reuse existing `FOR ALL ENTRIES` bulk forms |
| Reuse existing structures / tables / logic | **Yes** — `GET_MIN_MAX_STOCK` and `GET_TOTAL_STOCK` reused unchanged; `TY_QTY` already carried the Unrestricted/Quality split |
| Avoid redundant database reads | **Yes** — and net reads *decreased*: BOM mode drops three bulk retrievals, FG mode adds one |
| `sy-subrc` checked | **Yes** — after every new `READ TABLE`. `LOOP AT ... WHERE` and `APPEND` do not require it |
| Business calculations unchanged | **Yes** — `MENGE` still means Unrestricted + Quality, so the deficit formula and RM/PM stock are untouched |
| Clean Core | **Yes** — no modification, no access to non-released internals; one duplicated FORM pair collapsed into `HIDE_COLS` |
| ECC compatibility | **Partial — see §2 #1.** New code is release-neutral, but the report's existing CDS-based data layer is S/4-only and was not changed |

---

## 9. Verification performed

Static checks only — no SAP system was available:

- `FORM` / `ENDFORM` balance: 25 / 25.
- Every `PERFORM` target resolves to a defined `FORM`; no orphaned forms; no references left to
  the two removed hide routines.
- `LOOP AT` / `ENDLOOP` balance: 36 / 36; no `SELECT` at loop depth > 0.
- All commented-out variables (`LT_MINMAX`, `LT_WEIGHT`, `LT_WC`, `LT_PRT`, `LT_FG_KEYS`,
  `LS_MM`, `LS_W`, `LS_WC`, `LS_PRT`) confirmed to have zero live references remaining in
  `BUILD_AND_ENRICH_OUTPUT`.
- All new fields confirmed declared, populated and referenced consistently.
- All ALV header texts confirmed within the 10 / 20 / 40 character limits.

**Still required before transport: SE38 syntax check and ATC run.** In particular, confirm on
the target release that `CL_SALV_COLUMNS_TABLE->SET_COLOR_COLUMN` behaves as expected with the
`LVC_T_SCOL` column, and that `I_ProductSupplyPlanning` returns Min/Max at FG level for the
plants in scope.
