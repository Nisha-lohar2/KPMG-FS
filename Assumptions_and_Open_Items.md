# WRICEF-ID 7 — Assumptions & Open Items for Lead Confirmation

Report: `ZPP_RM_PM_DEFICIT_REPORT.abap`
Source: `WRICEF-ID 7 Report for RM PM deficit based on FG Deficit.xlsx` (BRD / FS / Detailed FS tabs)

The FS is thorough in most places, but a few areas were either undefined, ambiguous, or
specified in a way (CDS view fields) that had to be translated into concrete table logic.
Everything below is an assumption made to keep the program complete and executable — please
confirm each with Mukesh Yadav before this goes for review/testing.

---

## 1. Undefined / missing in the FS

| # | Item | Assumption made |
|---|------|------------------|
| 1 | **In-transit stock** — named in the BRD deficit formula `(Unrestricted + Quality + In-Transit) - (Open SO + Open STO)`, but no table/CDS view is given anywhere in the FS. | Left as an unwired placeholder (`gv_in_transit_stock`), **not** added to the formula. FG stock currently = Unrestricted + Quality only. |
| 2 | **QE01 control-sample / quality-inspection paragraph** (FS, around the "Configuration Step" note — `TVARVC`, `ZQM_CONTROL_PLANT`, `ZQM_CONTROL_MTART`, `ZPP_QE01_CUST`). Reads unrelated to an RM/PM deficit report. | Excluded entirely from the program. Flagged as a likely copy-paste from a different FS (QM control sample WRICEF). |
| 3 | **Custom table `ZPP_PLAN_SLOC` structure** — FS only says "pass WERKS and LGORT" to it; the actual field list/key structure isn't shown. | Assumed the table has (at least) `WERKS` + `LGORT` as key fields, and that **any row present = that Plant/SLoc combination is excluded** from stock. |
| 4 | **"Order Start Date"** selection field — FS doesn't say which underlying date drives it. | Assumed Sales Order creation date (`VBAK-ERDAT`). Could instead be requested delivery date or similar. |
| 5 | **Authorization object** — FS only says "Plant as an authorization object", no object name given. | Used `M_MSEG_WMB` as a placeholder. Needs confirmation from Basis/Security on the correct object for this custom report. |

## 2. CDS-view logic translated to classic tables (needs validation)

The FS is written against S/4HANA CDS views (`I_SalesDocumentItem`, `I_PurchaseOrder`,
`I_ProductSupplyPlanning`, etc.). The report was built against the underlying classic
transparent tables instead, since no confirmation was given on whether CDS views/RAP
artifacts are expected to be consumed directly. Field-level mapping assumptions:

| # | FS says (CDS) | Implemented as (classic table) | Risk |
|---|---|---|---|
| 6 | `I_SalesDocumentItem` + `I_SalesDocument-OVERALLSDPROCESSSTATUS=B`, `OVERALLDELIVERYBLOCKSTATUS<>C` | `VBAP` + `VBAK-GBSTK <> 'C'` | Status field is an approximation, not an exact 1:1 mapping — the CDS overall-process-status has more granularity than `GBSTK`. |
| 7 | `I_DeliveryDocumentItem` filtered on item category A/B and `GOODSMOVEMENTSTATUS<>C` | `LIPS`, summed without an explicit status filter | Delivery items should be filtered before summing `LFIMG`; currently sums all matching lines. |
| 8 | `I_PurchaseOrderItem` filtered on `PURCHASEORDERCATEGORY=F`, `MATERIALTYPE=FERT`, `ISCOMPLETELYDELIVERED` blank | `EKPO` filtered only on `LOEKZ`/`ELIKZ` | Missing the explicit PO category / material type filter — could pull in POs that shouldn't qualify. |
| 9 | GR quantity via `I_DeliveryDocumentItem-GOODSMOVEMENTSTATUS=C` | `EKBE` where `VGABE = '1'` (goods receipt) | Reasonable equivalent, but not verified against the exact CDS-side filter. |
| 10 | Batch-managed vs. non-batch stock decided by `V_MBEW_MD-BWTTY` (valuation type) and `I_PRODUCTPLANT-ISBATCHMANAGEMENTREQUIRED` | Approximated: "if `MCHB` has rows, use `MCHB`, else use `MARD`" | This is a shortcut, not the FS's actual 3-condition logic (valuation-type check, then batch-management-required check, then plain `MARD`). Should be rebuilt against `MBEW`/`MARA-XCHPF` per the FS's Condition 1/2/3. |
| 11 | Material Category via `I_PRODUCTSALESDELIVERY-FOURTHSALESSPECPRODUCTGROUP` → `TVM4T-BEZEI` | `MVKE-MVGR4` → `TVM4T-BEZEI` | `MVGR4` on `MVKE` is the classic-table equivalent of that CDS field, but not explicitly confirmed. |
| 12 | Min/Max Stock Level via `I_ProductSupplyPlanning-REORDERTHRESHOLDQUANTITY` / `MAXIMUMSTOCKQUANTITY` | `MARC-MINBE` / `MARC-BSTMA` | Likely correct, but not confirmed — `MARC-EISBE` is another possible candidate for reorder point depending on MRP type in use. |

## 3. Logic filled in where the FS was silent

| # | Item | Assumption made |
|---|------|------------------|
| 13 | **BOM explosion method** — FS says *"for BOM Component, use Program RCS11001."* | Used function module `CS_BOM_EXPL_MAT_V2` (the standard FM behind that program) instead of calling the report directly, since a report can't cleanly be called as a sub-routine for data return. Functionally equivalent, but flagging the deviation from the literal instruction. |
| 14 | **Which FG lines get exploded** — FS says explode "based on the Deficit QTY of FG." | Assumed only FG lines with a **negative** deficit (actual shortage) are exploded; FG lines in surplus are dropped from output entirely rather than shown with blank RM/PM columns. |
| 15 | **PRT lookup** — FS passes `PLFH-OBJID` to `CRVE_A-OBJID` for `OBJTY=FH`. | Assumed only PRT category `FH` (equipment) is in scope; other PRT categories (material, document, miscellaneous) are not read. |
| 16 | **Routing plant/task-list type** — FS says `PLNTY = N and 2` for `MAPL`, but only `PLNTY = N` for `PLKO`. | Kept as literally written (MAPL checked for N/2, PLKO checked for N only) even though this looks like it could itself be a typo in the FS — worth double-checking with Mukesh. |

---

### Suggested next step
Send items **1, 2, 3, 4, 6–12** to Mukesh Yadav for functional confirmation — these affect
correctness, not just style. Items 13–16 are technical-design calls that can likely be
confirmed in a quick technical review instead of going back to functional.
