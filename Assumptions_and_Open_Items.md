# WRICEF-ID 7 — Assumptions & Open Items for Lead Confirmation

Report: `ZR_RMPM_DEFICIT_REPORT_V2.abap`
Source: `WRICEF-ID 7 Report for RM PM deficit based on FG Deficit.xlsx` (BRD / FS / Detailed FS tabs)

This supersedes the previous version of this document, which was written against an earlier
draft that used classic tables (MARA/MTART, MAST/STKO, EKPO, VBAK-GBSTK, MCHB/MARD) as
placeholders before the field-level "Detailed FS" sheet was available. The report has since
been rebuilt directly against that sheet, using the CDS view and field names it specifies
verbatim (I_SalesDocumentItem, I_PurchaseOrderItem, NSDM_V_MCHB, V_MBEW_MD, etc.), so most of
the earlier "CDS-to-classic-table mapping risk" items no longer apply.

What follows is what's left: places where the Detailed FS is undefined, ambiguous, or
internally inconsistent, plus the concrete assumption made to keep the program complete and
executable. Everything below should be confirmed with Mukesh Yadav (Functional) before this
goes to test.

---

## 1. Undefined in the FS

| # | Item | Assumption made |
|---|------|------------------|
| 1 | **In-transit stock** — named in the BRD deficit formula `(Unrestricted + Quality + In-Transit) - (Open SO + Open STO)`, but the Detailed FS's own worked formula ("Total stock - (Total SO qty + Net STO)", cell A68/B68) drops it, and no table/CDS view is given anywhere in the sheet for it. | **Not implemented.** FG stock = Unrestricted + Quality only, matching the Detailed FS's literal formula over the BRD's prose. See `STAGE_A`/Stage E in the report. |
| 2 | **"Order Start date"** selection field (BRD row 17 / Detailed FS row 16) — named on the selection screen but no source table/field is given anywhere in either sheet. | Wired to `I_SalesDocumentItem-CreationDate` (closest CDS equivalent of classic VBAP-ERDAT). Previously this field was declared on the selection screen but never actually used in any filter — that gap is now closed, but the underlying field choice itself needs confirmation. |
| 3 | **Authorization object** — FS only says "Plant as an authorization object" (Detailed FS row 15), no object name given. | Used `M_MSEG_WWA` as a placeholder in `AUTHORITY_CHECK_PLANT`. Needs confirmation from Basis/Security on the correct object for this custom report. |
| 4 | **Custom table `ZPP_PLAN_SLOC` structure** — FS only says "pass WERKS and LGORT" to it (Detailed FS rows 44/88 etc.); the actual field list/key structure isn't shown. | Assumed the table has (at least) `WERKS` + `LGORT` as key fields, and that **any row present = that Plant/SLoc combination is excluded** from stock. |

## 2. Ambiguous / internally inconsistent in the FS

| # | Item | Assumption made |
|---|------|------------------|
| 5 | **BOM alternative tie-break** — Detailed FS row 73 says take BillOfMaterial/Variant combos from `I_BillOfMaterialItemTp`, filtered active via `I_BillOfMaterial` (not archived, status = 1), but states no tie-breaker if more than one active alternative remains. | Implemented as **lowest `BillOfMaterialVariant`** wins. Same rule reused for "1st routing" in the Work Center/PRT lookup (Detailed FS rows 128/129, which also don't state a tie-breaker). Confirm the intended rule. |
| 6 | **Net Total STO delivery-status filter** (Detailed FS row 67, B67) — the FS text reads "...for GOODSMOVEMENTSTATUS=C and OVERALL STATUS= A and B..." in one sentence, naming two conditions on what looks like the same field with contradictory values (`C` and `A`/`B` at once). | Implemented as `GoodsMovementStatus = 'C' AND SdProcessStatus IN ('A','B')`, i.e. read as **two different fields**, one for the goods-movement status and one for the SD process status. The combination is still unusual (status `A` commonly means "not yet processed"). Confirm the intended fields/codes — see `GET_NET_TOTAL_STO_QTY`. |
| 7 | **Total Sales Order delivery-item filter** (Detailed FS row 66, B66) — the FS text reads "...to I_DELIVERYDOCUMENTITEM- REFERENCESDDOCUMENT and REFERENCESDDOCUMENTITEM for **I_DELIVERYDOCUMENTITEM=A and B** and GOODSMOVEMENTSTATUS is not equal to C..." — the "=A and B" clause does not name a field at all. | **Not implemented** — only the unambiguous part of the sentence (`GoodsMovementStatus <> 'C'`) is filtered in `GET_TOTAL_SO_QTY`. If this was meant to be a delivery item category filter, confirm the field name and values. |
| 8 | **Net Total STO material match** (Detailed FS row 65) — FS text says to take "PURCHASEORDER and PURCHASEORDERITEM, **MANUFACTURERMATERIAL**, ORDERQUANTITY" from `I_PurchaseOrderItem`, naming `ManufacturerMaterial` as the field carrying the material. | Matched on `I_PurchaseOrderItem-Material` instead, since `ManufacturerMaterial` is normally populated for external-vendor cross-references, not intra-company STOs — matching on it would likely drop valid STO lines. Confirm which field should actually drive the match — see `GET_NET_TOTAL_STO_QTY`. |
| 9 | **`I_PurchaseOrderHistory`** is listed in the FS's "Selection Parameters" table (FS tab, row 61, item #9) as a source object, but the field-level Detailed FS steps for Net Total STO explicitly route delivered quantity through `I_DeliveryDocumentItem` instead, and never reference `I_PurchaseOrderHistory`. | Implemented per the field-level steps (`I_DeliveryDocumentItem`). Flagging in case `I_PurchaseOrderHistory` was intended to replace or supplement that source for GR tracking. |

## 3. Confirmed non-functional content in the FS

| # | Item | Note |
|---|------|------|
| 10 | **QE01 control-sample / quality-inspection paragraph** appears on *both* the "FS" tab (row 27) and the "Detailed FS" tab (row 27 area) — `TVARVC`, `ZQM_CONTROL_PLANT`, `ZQM_CONTROL_MTART`, `ZPP_QE01_CUST`. Reads unrelated to an RM/PM deficit report (it's about a QE01 control-sample indicator). | Excluded entirely from the program. Confirmed present in both tabs, reinforcing that this looks like a copy-paste from a different FS (a QM control-sample WRICEF), not something belonging in this report. |

## 4. Technical-design decisions (not functional gaps, but worth a quick technical sign-off)

| # | Item | Decision made |
|---|------|------------------|
| 11 | **BOM explosion method** — FS says *"for BOM Component, use Program RCS11001."* | Used function module `CS_BOM_EXPL_MAT_V2` (the standard FM behind that program) instead of calling the report directly, since a report can't cleanly be called as a sub-routine for data return. |
| 12 | **Which FG lines get exploded** — FS says explode "based on the Deficit QTY of FG." | Only FG lines with a **negative** deficit (actual shortage) are exploded; FG lines in surplus are dropped from the output entirely rather than shown with blank RM/PM columns. |
| 13 | **PRT lookup** — FS passes `PLFH-OBJID` to `CRVE_A-OBJID` for `OBJTY=FH`. | Only PRT category `FH` (equipment) is in scope; other PRT categories (material, document, miscellaneous) are not read — this is exactly what the FS specifies, just calling it out. |
| 14 | **Routing plant/task-list type** — FS says `PLNTY = N and 2` for `MAPL` (Work Center), but only `PLNTY = N` for the same lookup on the PRT side. | Kept as literally written even though this asymmetry looks like it could itself be a typo in the FS — worth double-checking with Mukesh. |

---

## 5. Performance notes (code quality, not functional)

The following were tightened up in this revision; behavior/output is unchanged, only the number
of database round trips:

- **`GET_STOCK`** — was issuing two SELECTs (unrestricted, then quality) per call. This routine
  runs once per FG *and* once per BOM component, making it the hottest path in the report.
  Reduced to one SELECT per stock source by summing the two quantity columns in the SQL itself.
- **`GET_TOTAL_SO_QTY`** (Stage C) — was issuing one `SELECT SINGLE` (SO validity) and one
  `SELECT SUM` (delivered qty) *per open SO line*, i.e. up to 2N round trips for N lines.
  Replaced with two bulk `FOR ALL ENTRIES` selects per FG.
- **`GET_NET_TOTAL_STO_QTY`** (Stage D) — was issuing one `SELECT SUM` per open STO PO item
  inside a loop. Replaced with a single grouped bulk select for all PO items of the FG at once.

A further round of optimization is possible (batching Stage B/C/D across *all* FG candidates in
one shot before the main loop, and batching Stage G's per-component lookups the same way), but
that would restructure the report's overall flow rather than just tightening individual
routines — worth doing as a deliberate follow-up once the functional open items above are
signed off, not bundled into this pass.

---

### Suggested next step
Send items **1–9** to Mukesh Yadav for functional confirmation — these affect correctness, not
just style. Item 10 is a heads-up that the QE01 paragraph should probably be removed from the FS
document itself. Items 11–14 are technical-design calls that can likely be confirmed in a quick
technical review instead of going back to functional.
