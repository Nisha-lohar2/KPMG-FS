# ZR_RMPM_DEFICIT_FG_REPORT_V2 — Change Document

**Date:** 28-Jul-2026
**Object:** `ZR_RMPM_DEFICIT_FG_REPORT_V2` (WRICEF-ID 7 — RM/PM deficit based on FG deficit)
**Scope of change:** FG Deficit ALV only. The BOM Component Details ALV is unchanged.

---

## 1. Summary of the request

Enhance the **FG Deficit** ALV output (radio button `P_FGDEF`) only:

1. Add columns: Unrestricted Stock, Quality Stock, Net Weight, Work Center, PRT.
2. Replace the generic "Quantity" column header currently shown for Open Sales Order Qty,
   Open STO Qty and FG Deficit/Surplus Qty with meaningful, unique headers.
3. Populate the new fields from existing report logic, without redundant database reads.
4. Leave the **BOM Component Details** ALV (`P_BOMCD`), the business logic, the calculations
   and the overall report flow untouched.

---

## 2. Decisions taken before coding

| # | Point | Decision |
|---|-------|----------|
| 1 | **Storage Location** was listed as an FG Deficit output column, but FG stock is aggregated across storage locations (`MATNR`/`WERKS`/`LGORT`-wise, then summed `MATNR`/`WERKS`-wise, minus `ZPP_PLAN_SLOC` exclusions), and the deficit formula works per Material/Plant. There is therefore no single storage location per FG row. | **Column dropped** from the FG Deficit ALV, per confirmation. Showing it would have required either changing the output granularity to Material/Plant/SLoc — which changes the business logic and risks double-counting the plant-level Open SO / Open STO / Deficit figures — or leaving the column permanently blank. |
| 2 | **Net Weight / Work Center / PRT** on the FG ALV — whose values? | Confirmed as the **Finished Good's own** master data and its own 1st routing (not any component's). Net Weight from `I_Product` for the FG material; Work Center and PRT from the FG's own routing. |

---

## 3. Root cause of the "Quantity" column headers

This was not a field-name or logic problem. `FORM SET_COL` set only the **medium** and **long**
column texts. Because `DISPLAY_ALV` calls `lo_cols->set_optimize( abap_true )`, SALV narrows
the columns and falls back to the **short** text — and none was supplied, so it used the short
description of the underlying data element. `FG_STOCK`, `TOT_SO`, `NET_STO` and `DEFICIT_FG`
are all typed `MENGE_D`, whose short text is the generic **"Quantity"** — hence four columns
rendering with the same header.

**Fix:** `SET_COL` now also sets a short text. Field names, data types and all business logic
are untouched — this affects displayed text only.

---

## 4. Structure changes

### 4.1 `ty_qty` — stock split carried alongside the existing total

```abap
TYPES: BEGIN OF ty_qty,
         matnr TYPE matnr,
         werks TYPE werks_d,
         menge TYPE menge_d,        "Unrestricted + Quality (total)  <-- unchanged meaning
         unres TYPE menge_d,        "NEW - Unrestricted only
         qual  TYPE menge_d,        "NEW - Quality only
       END OF ty_qty,
       tt_qty TYPE SORTED TABLE OF ty_qty WITH UNIQUE KEY matnr werks.
```

`MENGE` keeps exactly its previous meaning and value (Unrestricted + Quality). It is what the
FG deficit formula and the RM/PM component stock consume, so **both are unaffected**. The two
new fields carry the same figures split out.

### 4.2 `ty_fg` — five new FG-level attributes

```abap
fg_unres   TYPE menge_d,     "Unrestricted stock (FG)
fg_qual    TYPE menge_d,     "Quality stock (FG)
fg_netwt   TYPE ntgew,       "Net weight (FG)
fg_arbpl   TYPE arbpl,       "Work Center (FG routing)
fg_prt     TYPE equnr,       "PRT (FG routing)
```

### 4.3 `ty_out` — same five fields, inserted after `WERKS`

```abap
werks        TYPE werks_d,
fg_unres     TYPE menge_d,   "FG mode only
fg_qual      TYPE menge_d,   "FG mode only
fg_netwt     TYPE ntgew,     "FG mode only
fg_arbpl     TYPE arbpl,     "FG mode only
fg_prt       TYPE equnr,     "FG mode only
fg_stock     TYPE menge_d,
...
```

Two deliberate choices here:

- The new fields are **inserted, not appended**, so the FG Deficit ALV reads in a sensible
  order (Material … Plant, Unrestricted, Quality, Net Weight, Work Center, PRT, FG Stock,
  Open SO Qty, Open STO Qty, FG Def/Surplus Qty). Because no *existing* field was reordered
  and the new ones are hidden in BOM mode, the **BOM ALV's visible column order is unchanged**.
- `FG_NETWT` / `FG_ARBPL` / `FG_PRT` are **separate fields** from the existing component-level
  `NET_WEIGHT` / `ARBPL` / `EQUNR`. In BOM mode those describe the component and its FG routing
  and must not be disturbed, so they were not reused.

---

## 5. Data retrieval logic for the new fields

### 5.1 Unrestricted / Quality — zero additional database reads

`GET_TOTAL_STOCK` already reads `NSDM_V_MCHB` (`CLABS`, `CINSM`) and `NSDM_V_MARD`
(`LABST`, `INSME`) in bulk via `FOR ALL ENTRIES`, applying the `ZPP_PLAN_SLOC` exclusion. It
previously collapsed the two figures into a single total on the spot. It now passes them
through **separately from the same rows** — the `SELECT` statements themselves are byte-for-byte
unchanged.

A new `FORM ADD_STOCK_QTY` accumulates Unrestricted, Quality and the combined total per
Material/Plant. `FILL_FG_STOCK` then assigns all three from the one existing result table:

```abap
<fg>-fg_stock = ls_stock-menge.     "Unrestricted + Quality (unchanged)
<fg>-fg_unres = ls_stock-unres.     "same read, split out for the ALV
<fg>-fg_qual  = ls_stock-qual.
```

> **Note on `ADD_QTY`:** the original generic accumulator is also called by
> `FILL_TOTAL_SALES_ORDER` and `FILL_NET_TOTAL_STO`. It was therefore **left with its original
> 3-parameter signature** and a separate `ADD_STOCK_QTY` was added for the stock path, rather
> than changing a routine that two unrelated stages depend on.

### 5.2 Net Weight / Work Center / PRT — existing bulk routines reused

New `FORM FILL_FG_EXTRA_DATA` reuses the **existing** bulk forms `GET_NET_WEIGHT` and
`GET_WORKCENTER_PRT` — the very same routines the component stage uses — simply passing the
**FG keys** instead of component keys:

```abap
PERFORM get_net_weight     USING lt_keys CHANGING lt_weight.
PERFORM get_workcenter_prt USING lt_keys CHANGING lt_wc lt_prt.
```

No new database logic was written. The assignment loop that follows performs only in-memory
`READ TABLE ... WITH TABLE KEY` lookups with an `sy-subrc` check on each.

`FILL_FG_EXTRA_DATA` is called **only when `P_FGDEF = abap_true`**. In BOM Component Details
mode these columns are hidden, so fetching them there would be exactly the redundant read the
requirement rules out.

---

## 6. ALV field catalog modifications

### 6.1 `SET_COL` signature extended

```abap
FORM set_col USING io_cols  TYPE REF TO cl_salv_columns_table
                   iv_name  TYPE csequence
                   iv_short TYPE csequence     "NEW
                   iv_med   TYPE csequence
                   iv_long  TYPE csequence.
```

Passing `SPACE` as `IV_SHORT` skips `set_short_text( )` and preserves a column's previous
rendering — this is how all nine component columns are called, so the BOM ALV is untouched.

Length limits: short 10 (`SCRTEXT_S`), medium 20 (`SCRTEXT_M`), long 40 (`SCRTEXT_L`).

### 6.2 Renamed headers (display text only)

| Field | Before | Short (10) | Medium (20) | Long (40) |
|---|---|---|---|---|
| `TOT_SO` | "Quantity" | `OpenSOQty` | `Open Sales Order Qty` | `Open Sales Order Qty` |
| `NET_STO` | "Quantity" | `OpenSTOQty` | `Open STO Qty` | `Open STO Qty` |
| `DEFICIT_FG` | "Quantity" | `FGDef/Sur` | `FG Def/Surplus Qty` | `FG Deficit / Surplus Qty` |
| `FG_STOCK` | "Quantity" | `FG Stock` | `FG Stock` | `FG Stock (Unrestricted + Quality)` |

`FG_STOCK` was hit by the same fallback and is included so all four quantity columns are
distinguishable. The medium text for `DEFICIT_FG` is abbreviated because the requested
"FG Deficit / Surplus Qty" is 24 characters and `SCRTEXT_M` caps at 20; the full wording is
carried in the long text.

### 6.3 New column headers

| Field | Short (10) | Medium (20) | Long (40) |
|---|---|---|---|
| `FG_UNRES` | `Unrest.Stk` | `Unrestricted Stock` | `Unrestricted Stock` |
| `FG_QUAL` | `Qual.Stock` | `Quality Stock` | `Quality Stock` |
| `FG_NETWT` | `Net Weight` | `Net Weight` | `Net Weight` |
| `FG_ARBPL` | `Work Ctr.` | `Work Center` | `Work Center` |
| `FG_PRT` | `PRT` | `PRT` | `PRT` |

### 6.4 Mode-dependent column visibility

```abap
IF p_fgdef = abap_true.
  PERFORM hide_component_columns USING lo_cols.   "existing
ELSE.
  PERFORM hide_fg_only_columns   USING lo_cols.   "NEW
ENDIF.
```

New `FORM HIDE_FG_ONLY_COLUMNS` hides `FG_UNRES`, `FG_QUAL`, `FG_NETWT`, `FG_ARBPL`, `FG_PRT`
in BOM Component Details mode, so that ALV shows exactly the columns it did before.

---

## 7. FORM routines added / modified

| FORM | Change |
|---|---|
| `ADD_STOCK_QTY` | **New.** Accumulates Unrestricted / Quality / total per Material/Plant. |
| `FILL_FG_EXTRA_DATA` | **New.** FG-level Net Weight / Work Center / PRT via the existing bulk routines. FG mode only. |
| `HIDE_FG_ONLY_COLUMNS` | **New.** Hides the FG-only columns in BOM mode. |
| `GET_TOTAL_STOCK` | Modified — passes `CLABS`/`CINSM` and `LABST`/`INSME` separately to `ADD_STOCK_QTY`. **`SELECT` statements unchanged.** |
| `FILL_FG_STOCK` | Modified — also assigns `FG_UNRES` / `FG_QUAL` from the same result table. |
| `MOVE_FG_TO_OUT` | Modified — copies the five new FG fields to the output row. |
| `DISPLAY_ALV` | Modified — new/renamed headers, plus the `ELSE` branch hiding FG-only columns. |
| `SET_COL` | Modified — extended with a short-text parameter. |
| `ADD_QTY` | **Unchanged** (see note in §5.1). |
| Main flow (`START-OF-SELECTION`) | One line added: `PERFORM fill_fg_extra_data.` inside the existing FG-mode `ELSE` branch. |

**Not touched:** `BUILD_FG_CANDIDATES`, `FILL_FG_MASTER_DATA`, `FILL_TOTAL_SALES_ORDER`,
`FILL_NET_TOTAL_STO`, `CALC_FG_DEFICIT`, `EXPLODE_DEFICIT_BOMS`, `GET_ACTIVE_BOM_ALT`,
`EXPLODE_SINGLE_BOM`, `BUILD_AND_ENRICH_OUTPUT`, `BUILD_FG_OUTPUT`, `GET_MIN_MAX_STOCK`,
`GET_NET_WEIGHT`, `GET_WORKCENTER_PRT`, `HIDE_COMPONENT_COLUMNS`, `CHECK_AUTHORIZATION`,
`LOAD_SLOC_EXCLUSIONS`.

---

## 8. Resulting FG Deficit ALV columns

Material · Material Description · Material Group · Material Category · Plant ·
**Unrestricted Stock** · **Quality Stock** · **Net Weight** · **Work Center** · **PRT** ·
FG Stock · Open Sales Order Qty · Open STO Qty · FG Deficit / Surplus Qty

(Storage Location omitted — see §2.)

---

## 9. Technical compliance

| Requirement | How it is met |
|---|---|
| No `SELECT` inside a loop | No `SELECT` was added at all. Every new value comes from an existing bulk `FOR ALL ENTRIES` routine; the assignment loops perform in-memory `READ TABLE` only. |
| No redundant database reads | Unrestricted/Quality reuse the *same rows* already read for the total. Net Weight / WC / PRT reuse the existing bulk forms and are fetched only in the mode that displays them. |
| `sy-subrc` checked | Every new `READ TABLE` in `FILL_FG_STOCK` and `FILL_FG_EXTRA_DATA` is followed by an `IF sy-subrc = 0.` guard. |
| Reuse existing structures / tables / logic | `tt_key`, `tt_qty`, `tt_weight`, `tt_wc`, `tt_prt`, `GET_NET_WEIGHT`, `GET_WORKCENTER_PRT`, `MOVE_FG_TO_OUT` and `SET_COL` all reused. |
| Values correspond to the correct FG | All lookups key on `MATNR` + `WERKS` of the FG row via `WITH TABLE KEY` on sorted/unique tables. |
| Clean Core | Inline declarations, `VALUE #( )` constructors, no new global state, no modification of SAP standard objects. |
| BOM ALV unaffected | New fields hidden in BOM mode; component headers keep `SPACE` short text; `ADD_QTY` and all component-stage routines unchanged. |

---

## 10. Verification performed

Static checks only — no SAP system was available in this environment:

- `FORM` / `ENDFORM` balance: 25 / 25.
- Every `PERFORM` target resolves to a defined `FORM` (no dangling calls).
- All 23 `SET_COL` calls parsed and confirmed to pass exactly 4 arguments after `lo_cols`.
- Each of the five new fields traced end-to-end: type declaration → population → `MOVE_FG_TO_OUT`
  → field catalog.
- All short texts confirmed ≤ 10 characters, medium ≤ 20, long ≤ 40.

> One defect was found and fixed during development: the first version of this change altered
> `ADD_QTY`'s signature to four parameters, which silently broke its two other callers
> (`FILL_TOTAL_SALES_ORDER`, `FILL_NET_TOTAL_STO`). Resolved by leaving `ADD_QTY` alone and
> adding the separate `ADD_STOCK_QTY`.

### Still to be done before transport

- **SE38 syntax check and ATC run** — not possible in this environment.
- Confirm the short texts render as intended in your system's ALV (particularly
  `FG Def/Surplus Qty` vs. the full `FG Deficit / Surplus Qty` in a wide layout).
- Functional verification that Unrestricted + Quality on the FG rows sums exactly to the
  existing FG Stock column.
- The open items in `Assumptions_and_Open_Items.md` are **unaffected** by this change and still
  need functional sign-off.
