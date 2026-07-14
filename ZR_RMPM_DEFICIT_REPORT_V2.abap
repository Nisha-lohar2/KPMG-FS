*&---------------------------------------------------------------------*
*& Report  ZR_RMPM_DEFICIT_REPORT
*&---------------------------------------------------------------------*
*& WRICEF-ID 7 — Report for BOM explosion based on FG deficit
*& Module      : PP
*& Object Type : Report
*& Source      : Functional Specification, "Detailed FS" sheet, v1
*& Owner       : Mukesh Yadav (Functional)
*&
*& Rebuilt against the field-level source mapping in the Detailed FS
*& sheet. This supersedes the earlier draft, which used MARA/MTART and
*& MAST/STKO as placeholders before the field-level FS was available.
*& Table/CDS view names below are taken verbatim from that sheet.
*&
*& FIX (prior revision): STAGE_F_BOM_EXPLOSION's CHANGING parameter was
*& declared as an inline anonymous table type
*&   "pc_bom_comp TYPE STANDARD TABLE OF ty_bom_comp"
*& which is not valid in a FORM interface (only valid in TYPES/DATA
*& statements). That caused the syntax check to miscount the FORM's
*& formal parameters against the PERFORM call ("formal parameters: 4,
*& actual parameters: 2"). Fixed by declaring a named table type
*& TT_BOM_COMP and using that in the FORM signature instead. Same
*& fix applied to STAGE_G_PROCESS_COMPONENTS's PT_BOM parameter for
*& consistency/stricter typing.
*&
*& OPTIMIZATION (this revision): three routines re-read the database
*& inside a LOOP, one row / one round trip at a time ("SELECT-in-LOOP"),
*& which does not scale once selection returns more than a handful of
*& sales orders or STO items:
*&   - GET_STOCK issued two round trips (unrestricted, then quality)
*&     for every single FG and every single BOM component. Merged into
*&     one SELECT per stock source (CLABS+CINSM / LABST+INSME summed
*&     in the SQL itself) — this routine is the hottest path in the
*&     whole report, called once per FG plus once per BOM component.
*&   - GET_TOTAL_SO_QTY (Stage C) issued one SELECT SINGLE against
*&     I_SalesDocument and one SELECT SUM against I_DeliveryDocumentItem
*&     per open SO line of the FG being processed. Replaced with two
*&     bulk selects (FOR ALL ENTRIES) per FG — SO validity and
*&     delivered qty are now looked up in memory instead.
*&   - GET_NET_TOTAL_STO_QTY (Stage D) issued one SELECT SUM against
*&     I_DeliveryDocumentItem per open STO PO item. Replaced with a
*&     single grouped bulk select (FOR ALL ENTRIES ... GROUP BY) for
*&     all PO items of the FG at once.
*& Behaviour/output is unchanged — same filters, same formulas, only
*& the number of DB round trips is reduced.
*&
*& NEW (this revision): wired up the "Order Start Date" selection
*& field (S_ERDAT), which was declared on the selection screen but
*& never referenced anywhere in Stage A — every run silently ignored
*& it regardless of what the user entered. See open item 5 below for
*& the assumption made on which date field it filters.
*&
*& OPEN ITEMS — confirm with Mukesh Yadav before this goes to test:
*&   1) BRD text includes "In transit stock" in the deficit formula,
*&      but the Detailed FS's own formula step ("Total stock -
*&      (Total SO qty + Net STO)") does not use it, and no source
*&      table is given anywhere in the sheet for in-transit stock.
*&      NOT implemented below — see STAGE E.
*&   2) FG candidate list is driven entirely from open Sales Order
*&      items (I_SalesDocumentItem, ITEMCATEGORY=TAN, DOCCATEGORY=C).
*&      An FG with a deficit driven only by STO and zero open sales
*&      orders in the plant will NOT appear on this report. Confirm
*&      this is intended — see STAGE A.
*&   3) BOM alternative: FS says take BillOfMaterial/Variant combos
*&      from I_BillOfMaterialItemTp, filtered active via
*&      I_BillOfMaterial (not archived, status = 1), but does not
*&      state a tie-breaker if more than one active alternative
*&      remains. Implemented as lowest BillOfMaterialVariant — see
*&      STAGE F, confirm the tie-break rule.
*&   4) Net Total STO delivery-status filter: FS text says
*&      "GOODSMOVEMENTSTATUS=C and OVERALL STATUS=A and B" in the same
*&      sentence. Implemented as GoodsMovementStatus = 'C' AND
*&      SdProcessStatus IN ('A','B') — that combination is unusual (A
*&      commonly means "not yet processed"). Confirm the intended
*&      status codes and the exact field name with Mukesh — see
*&      STAGE D.
*&   5) Order Start Date: FS selection-screen table names the field
*&      "Order date from/to" but never states the underlying source.
*&      Wired to I_SalesDocumentItem-CreationDate (item-level creation
*&      date) as the closest CDS equivalent of the classic VBAP-ERDAT
*&      field. Confirm this is the field the business means, and not
*&      e.g. a requested-delivery-date — see STAGE A.
*&   6) Total Sales Order (Stage C): the Detailed FS's own text for
*&      this step reads "...to I_DELIVERYDOCUMENTITEM- REFERENCESD-
*&      DOCUMENT and REFERENCESDDOCUMENTITEM for
*&      I_DELIVERYDOCUMENTITEM=A and B and GOODSMOVEMENTSTATUS is not
*&      equal to C..." — the "=A and B" clause does not name a field
*&      (likely a delivery item category filter), so it cannot be
*&      implemented as written. GET_TOTAL_SO_QTY currently filters
*&      only on GoodsMovementStatus <> 'C', i.e. the part of the
*&      sentence that IS unambiguous. Confirm what "=A and B" was
*&      meant to filter — see STAGE C.
*&   7) Net Total STO (Stage D): Detailed FS text says to take
*&      "PURCHASEORDER and PURCHASEORDERITEM, MANUFACTURERMATERIAL,
*&      ORDERQUANTITY" from I_PurchaseOrderItem — i.e. it names
*&      MANUFACTURERMATERIAL as the field carrying the material. The
*&      report instead filters/matches on I_PurchaseOrderItem-Material
*&      (the FG being processed), since ManufacturerMaterial is
*&      normally populated for external-vendor cross-references, not
*&      intra-company STOs, and matching on it would silently drop
*&      valid STO lines. Confirm which field should actually drive the
*&      match — see STAGE D.
*&   8) I_PurchaseOrderHistory is listed in the FS's "Selection
*&      Parameters" table (#9) as a source object, but the field-level
*&      Detailed FS steps for Net Total STO explicitly route delivered
*&      quantity through I_DeliveryDocumentItem instead. Implemented
*&      per the field-level steps (I_DeliveryDocumentItem); the
*&      listed-but-unused I_PurchaseOrderHistory reference is flagged
*&      here in case it was meant to replace/supplement that source.
*&---------------------------------------------------------------------*
REPORT zr_rmpm_deficit_report.

*----------------------------------------------------------------------*
* Custom table ZPP_PLAN_SLOC (WERKS, LGORT) — assumed to already exist
* per Section 7 of the earlier technical spec / "Assumption" row of BRD
* ("Few of the SLoc stock should not be considered").
*----------------------------------------------------------------------*

*----------------------------------------------------------------------*
* 1. Type declarations
*----------------------------------------------------------------------*
TYPES: BEGIN OF ty_fg_deficit,
         matnr        TYPE matnr,        "FG material (Product)
         werks        TYPE werks_d,
         maktx        TYPE maktx,
         matkl        TYPE matkl,        "Material Group (ProductGroup)
         mvgr4_txt    TYPE bezei20,      "Material Category
         fg_stock     TYPE menge_d,      "Total Stock (Unrestr. + Quality)
         tot_so_qty   TYPE menge_d,
         net_sto_qty  TYPE menge_d,
         deficit_fg   TYPE menge_d,      "negative = shortage
       END OF ty_fg_deficit.

TYPES: BEGIN OF ty_bom_comp,
         matnr        TYPE matnr,        "FG (link back to header)
         werks        TYPE werks_d,
         idnrk        TYPE idnrk,        "component material
         menge        TYPE menge_d,      "MNGKO from BOM explosion
       END OF ty_bom_comp.

TYPES: tt_bom_comp TYPE STANDARD TABLE OF ty_bom_comp WITH EMPTY KEY.

TYPES: BEGIN OF ty_alv_out.
         INCLUDE TYPE ty_fg_deficit AS fg.
TYPES:   idnrk        TYPE idnrk,        "BOM Component
         qty_bom      TYPE menge_d,      "QTY as per BOM
         rmpm_stock   TYPE menge_d,      "component Stock
         rmpm_deficit TYPE menge_d,      "component Deficit
         min_stock    TYPE menge_d,
         max_stock    TYPE menge_d,
         net_weight   TYPE ntgew,
         arbpl        TYPE arbpl,        "Work Center
         equnr        TYPE equnr,        "PRT
       END OF ty_alv_out.

TYPES: BEGIN OF ty_so_item,
         salesdocument     TYPE vbeln,
         salesdocumentitem TYPE posnr,
         matnr             TYPE matnr,
         werks             TYPE werks_d,
         orderquantity     TYPE menge_d,
       END OF ty_so_item,
       tt_so_item TYPE STANDARD TABLE OF ty_so_item WITH EMPTY KEY.

TYPES: BEGIN OF ty_stock_line,
         lgort TYPE lgort_d,
         qty   TYPE menge_d,
       END OF ty_stock_line,
       tt_stock_line TYPE STANDARD TABLE OF ty_stock_line WITH EMPTY KEY.

TYPES: BEGIN OF ty_sloc_excl,
         werks TYPE werks_d,
         lgort TYPE lgort_d,
       END OF ty_sloc_excl.

DATA: gt_fg_candidates TYPE STANDARD TABLE OF ty_fg_deficit WITH EMPTY KEY,
      gt_bom_comp      TYPE tt_bom_comp,
      gt_alv_out       TYPE STANDARD TABLE OF ty_alv_out    WITH EMPTY KEY,
      gt_so_items_raw  TYPE tt_so_item,
      gt_sloc_excl     TYPE SORTED TABLE OF ty_sloc_excl
                          WITH NON-UNIQUE KEY werks lgort.

*----------------------------------------------------------------------*
* 2. Selection screen — Plant mandatory, Order Date + Material optional
*    (all as ranges, per BRD "Selection Screen" table: From/To on each)
*----------------------------------------------------------------------*
TABLES: t001w, mara.

SELECTION-SCREEN BEGIN OF BLOCK b1 WITH FRAME TITLE TEXT-001.
SELECT-OPTIONS: s_werks FOR t001w-werks OBLIGATORY,
                s_erdat FOR sy-datum,
                s_matnr FOR mara-matnr.
SELECTION-SCREEN END OF BLOCK b1.

*----------------------------------------------------------------------*
* 3. Main processing
*----------------------------------------------------------------------*
START-OF-SELECTION.

  PERFORM authority_check_plant.
  PERFORM load_sloc_exclusions.

  PERFORM stage_a_build_fg_candidates.

  LOOP AT gt_fg_candidates ASSIGNING FIELD-SYMBOL(<fg>).

    " Stage B — FG stock (Unrestricted + Quality), reusable routine
    PERFORM get_stock USING <fg>-matnr <fg>-werks CHANGING <fg>-fg_stock.

    " Stage C — Total Sales Order qty
    PERFORM get_total_so_qty USING <fg>-matnr <fg>-werks CHANGING <fg>-tot_so_qty.

    " Stage D — Net Total STO qty
    PERFORM get_net_total_sto_qty USING <fg>-matnr <fg>-werks CHANGING <fg>-net_sto_qty.

    " Stage E — Deficit/Surplus = Total stock - (Total SO qty + Net STO)
    " NOTE: in-transit stock deliberately omitted — see header, open item 1.
    <fg>-deficit_fg = <fg>-fg_stock - ( <fg>-tot_so_qty + <fg>-net_sto_qty ).

    IF <fg>-deficit_fg < 0.

      " Stage F — BOM explosion (deficit FGs only, 1st active alternative)
      CLEAR gt_bom_comp.
      PERFORM stage_f_bom_explosion USING <fg> CHANGING gt_bom_comp.

      " Stage G — per BOM component
      PERFORM stage_g_process_components USING <fg> gt_bom_comp.

    ENDIF.

  ENDLOOP.

  PERFORM display_alv.

*&---------------------------------------------------------------------*
*&      Form  AUTHORITY_CHECK_PLANT
*&---------------------------------------------------------------------*
* BRD: "Plant as an authorization object". Placeholder object below —
* confirm the correct authorization object with Basis/Security.
*&---------------------------------------------------------------------*
FORM authority_check_plant.

  LOOP AT s_werks.
    AUTHORITY-CHECK OBJECT 'M_MSEG_WWA'
      ID 'WERKS' FIELD s_werks-low
      ID 'ACTVT' FIELD '03'.
    IF sy-subrc <> 0.
      MESSAGE e172(00) WITH s_werks-low. "No authorization for plant &1
    ENDIF.
  ENDLOOP.

ENDFORM.

*&---------------------------------------------------------------------*
*&      Form  LOAD_SLOC_EXCLUSIONS
*&---------------------------------------------------------------------*
FORM load_sloc_exclusions.

  SELECT werks, lgort
    FROM zpp_plan_sloc
    INTO TABLE @gt_sloc_excl.

ENDFORM.

*&---------------------------------------------------------------------*
*&      Form  STAGE_A_BUILD_FG_CANDIDATES
*&---------------------------------------------------------------------*
* Detailed FS, "Material" row:
*   Pass selection screen plant to I_SalesDocumentItem-PLANT for
*   SALESDOCUMENTITEMCATEGORY = 'TAN' and SDDOCUMENTCATEGORY = 'C',
*   take PRODUCT. Also filtered by SalesDocumentRjcnReason = '' up
*   front since Stage C re-reads the same base condition anyway.
* S_ERDAT (BRD "Order Start date") applied against Creationdate — see
* header, open item 5, the FS never names the underlying date field.
*&---------------------------------------------------------------------*
FORM stage_a_build_fg_candidates.

  SELECT sdi~salesdocument, sdi~salesdocumentitem,
         sdi~product AS matnr, sdi~plant AS werks,
         sdi~orderquantity
    FROM i_salesdocumentitem AS sdi
    INTO TABLE @gt_so_items_raw
    WHERE sdi~plant                     IN @s_werks
      AND sdi~product                   IN @s_matnr
      AND sdi~creationdate              IN @s_erdat
      AND sdi~salesdocumentitemcategory  = 'TAN'
      AND sdi~sddocumentcategory         = 'C'
      AND sdi~salesdocumentrjcnreason    = ''.

  " Distinct Product/Plant -> FG candidate list
  DATA(lt_distinct) = gt_so_items_raw.
  SORT lt_distinct BY matnr werks.
  DELETE ADJACENT DUPLICATES FROM lt_distinct COMPARING matnr werks.

  LOOP AT lt_distinct INTO DATA(ls_distinct).
    APPEND INITIAL LINE TO gt_fg_candidates ASSIGNING FIELD-SYMBOL(<fs_fg>).
    <fs_fg>-matnr = ls_distinct-matnr.
    <fs_fg>-werks = ls_distinct-werks.

    PERFORM get_material_description USING <fs_fg>-matnr CHANGING <fs_fg>-maktx.
    PERFORM get_material_group       USING <fs_fg>-matnr CHANGING <fs_fg>-matkl.
    PERFORM get_material_category    USING <fs_fg>-matnr CHANGING <fs_fg>-mvgr4_txt.
  ENDLOOP.

ENDFORM.

*&---------------------------------------------------------------------*
*&      Form  GET_MATERIAL_DESCRIPTION
*&---------------------------------------------------------------------*
* Detailed FS: I_SalesDocumentItem-Product -> I_ProductText-Product,
* take PRODUCTNAME for LANGUAGE = 'E'.
*&---------------------------------------------------------------------*
FORM get_material_description USING    pu_matnr TYPE matnr
                               CHANGING pc_maktx TYPE maktx.

  CLEAR pc_maktx.

  SELECT SINGLE productname
    FROM i_producttext
    INTO @pc_maktx
    WHERE product  = @pu_matnr
      AND language = 'E'.

ENDFORM.

*&---------------------------------------------------------------------*
*&      Form  GET_MATERIAL_GROUP
*&---------------------------------------------------------------------*
* Detailed FS: I_SalesDocumentItem-Product -> I_Product-Product,
* take PRODUCTGROUP.
*&---------------------------------------------------------------------*
FORM get_material_group USING    pu_matnr TYPE matnr
                         CHANGING pc_matkl TYPE matkl.

  CLEAR pc_matkl.

  SELECT SINGLE productgroup
    FROM i_product
    INTO @pc_matkl
    WHERE product = @pu_matnr.

ENDFORM.

*&---------------------------------------------------------------------*
*&      Form  GET_MATERIAL_CATEGORY
*&---------------------------------------------------------------------*
* Detailed FS: I_SalesDocumentItem-Product -> I_ProductSalesDelivery-
* Product where FOURTHSALESSPECPRODUCTGROUP is not blank, take that
* value. Pass to TVM4T-MVGR4 for SPRAS = 'E', take BEZEI.
*&---------------------------------------------------------------------*
FORM get_material_category USING    pu_matnr TYPE matnr
                            CHANGING pc_text  TYPE bezei20.

  DATA: lv_mvgr4 TYPE mvgr4.

  CLEAR: pc_text, lv_mvgr4.

  SELECT SINGLE fourthsalesspecproductgroup
    FROM i_productsalesdelivery
    INTO @lv_mvgr4
    WHERE product                      = @pu_matnr
      AND fourthsalesspecproductgroup <> ''.

  IF sy-subrc = 0 AND lv_mvgr4 IS NOT INITIAL.
    SELECT SINGLE bezei
      FROM tvm4t
      INTO @pc_text
      WHERE spras = 'E'
        AND mvgr4 = @lv_mvgr4.
  ENDIF.

ENDFORM.

*&---------------------------------------------------------------------*
*&      Form  CHECK_BATCH_MANAGED
*&---------------------------------------------------------------------*
* Detailed FS "Unrestricted Stock" / "Quality Stock" — 3 conditions:
*   1) V_MBEW_MD-BWTTY <> '' for Product/Plant  -> batch-managed
*   2) V_MBEW_MD-BWTTY = '' AND
*      I_ProductPlant-IsBatchManagementRequired <> '' -> batch-managed
*   3) V_MBEW_MD-BWTTY = '' AND
*      I_ProductPlant-IsBatchManagementRequired = '' -> not batch-managed
*&---------------------------------------------------------------------*
FORM check_batch_managed USING    pu_matnr    TYPE matnr
                                   pu_werks    TYPE werks_d
                          CHANGING pc_is_batch TYPE abap_bool.

  DATA: lv_bwtty     TYPE bwtty,
        lv_batchflag TYPE abap_boolean. "I_ProductPlant-IsBatchManagementRequired

  CLEAR pc_is_batch.

  SELECT SINGLE bwtty
    FROM v_mbew_md
    INTO @lv_bwtty
    WHERE matnr = @pu_matnr
      AND bwkey = @pu_werks.

  IF sy-subrc = 0 AND lv_bwtty IS NOT INITIAL.
    pc_is_batch = abap_true.       "Condition 1
    RETURN.
  ENDIF.

  SELECT SINGLE isbatchmanagementrequired
    FROM i_productplant
    INTO @lv_batchflag
    WHERE product = @pu_matnr
      AND plant   = @pu_werks.

  IF sy-subrc = 0 AND lv_batchflag IS NOT INITIAL.
    pc_is_batch = abap_true.       "Condition 2
  ELSE.
    pc_is_batch = abap_false.      "Condition 3
  ENDIF.

ENDFORM.

*&---------------------------------------------------------------------*
*&      Form  GET_STOCK
*&---------------------------------------------------------------------*
* Stage B — reusable routine (Total Stock = Unrestricted + Quality).
* Called for the FG and again for every RM/PM component (Stage G), so
* this is the hottest path in the report — kept to a single round trip
* per call: unrestricted and quality quantities are summed in the SQL
* itself (CLABS+CINSM / LABST+INSME) instead of two separate SELECTs.
*&---------------------------------------------------------------------*
FORM get_stock USING    pu_matnr TYPE matnr
                         pu_werks TYPE werks_d
                CHANGING pc_stock TYPE menge_d.

  DATA: lv_is_batch TYPE abap_bool,
        lt_lines    TYPE tt_stock_line.

  CLEAR pc_stock.

  PERFORM check_batch_managed USING pu_matnr pu_werks CHANGING lv_is_batch.

  IF lv_is_batch = abap_true.
    " Batch-managed: NSDM_V_MCHB, CLABS (unrestricted) + CINSM (quality)
    SELECT lgort, ( clabs + cinsm ) AS qty
      FROM nsdm_v_mchb
      INTO TABLE @lt_lines
      WHERE matnr = @pu_matnr
        AND werks = @pu_werks
        AND ( clabs <> 0 OR cinsm <> 0 ).
  ELSE.
    " Not batch-managed: NSDM_V_MARD, LABST (unrestricted) + INSME (quality)
    SELECT lgort, ( labst + insme ) AS qty
      FROM nsdm_v_mard
      INTO TABLE @lt_lines
      WHERE matnr = @pu_matnr
        AND werks = @pu_werks
        AND ( labst <> 0 OR insme <> 0 ).
  ENDIF.

  " Exclude storage locations listed in ZPP_PLAN_SLOC, sum the rest
  LOOP AT lt_lines INTO DATA(ls_line).
    READ TABLE gt_sloc_excl TRANSPORTING NO FIELDS
      WITH KEY werks = pu_werks
               lgort = ls_line-lgort
      BINARY SEARCH.
    IF sy-subrc <> 0.
      pc_stock = pc_stock + ls_line-qty.
    ENDIF.
  ENDLOOP.

ENDFORM.

*&---------------------------------------------------------------------*
*&      Form  GET_TOTAL_SO_QTY
*&---------------------------------------------------------------------*
* Stage C — Total Sales Order, per Detailed FS "Total Sales Order" row.
* Reuses the raw SO item set gathered in Stage A (same base filter).
* Bulk-fetches SO validity and delivered qty in two round trips per FG
* instead of one SELECT SINGLE + one SELECT SUM per open SO line
* (previous revision issued up to 2N DB calls for N open SO lines).
* See header, open item 6, on the "=A and B" clause that could not be
* implemented because the FS text does not name a field.
*&---------------------------------------------------------------------*
FORM get_total_so_qty USING    pu_matnr TYPE matnr
                                pu_werks TYPE werks_d
                       CHANGING pc_qty   TYPE menge_d.

  TYPES: BEGIN OF ty_deliv_sum,
           salesdocument     TYPE vbeln,
           salesdocumentitem TYPE posnr,
           qty               TYPE menge_d,
         END OF ty_deliv_sum.

  DATA: lt_so_lines  TYPE tt_so_item,
        lt_docnrs    TYPE STANDARD TABLE OF vbeln WITH EMPTY KEY,
        lt_valid_so  TYPE SORTED TABLE OF vbeln WITH UNIQUE KEY table_line,
        lt_deliv_sum TYPE SORTED TABLE OF ty_deliv_sum
                         WITH UNIQUE KEY salesdocument salesdocumentitem,
        lv_delivered TYPE menge_d.

  CLEAR pc_qty.

  lt_so_lines = VALUE #( FOR ls IN gt_so_items_raw
                          WHERE ( matnr = pu_matnr AND werks = pu_werks )
                          ( ls ) ).

  IF lt_so_lines IS INITIAL.
    RETURN.
  ENDIF.

  " Only consider SOs with OverallSDProcessStatus = 'B' and
  " OverallDeliveryBlockStatus <> 'C' — one bulk lookup for all SOs of
  " this FG instead of a SELECT SINGLE per SO line.
  lt_docnrs = VALUE #( FOR ls_so IN lt_so_lines ( ls_so-salesdocument ) ).
  SORT lt_docnrs.
  DELETE ADJACENT DUPLICATES FROM lt_docnrs.

  SELECT salesdocument
    FROM i_salesdocument
    INTO TABLE @lt_valid_so
    FOR ALL ENTRIES IN @lt_docnrs
    WHERE salesdocument              = @lt_docnrs-table_line
      AND overallsdprocessstatus     = 'B'
      AND overalldeliveryblockstatus <> 'C'.

  " Delivered qty for all SO lines of this FG in one grouped bulk select.
  SELECT referencesddocument     AS salesdocument,
         referencesddocumentitem AS salesdocumentitem,
         SUM( actualdeliveryquantity ) AS qty
    FROM i_deliverydocumentitem
    INTO TABLE @lt_deliv_sum
    FOR ALL ENTRIES IN @lt_so_lines
    WHERE referencesddocument     = @lt_so_lines-salesdocument
      AND referencesddocumentitem = @lt_so_lines-salesdocumentitem
      AND goodsmovementstatus    <> 'C'
    GROUP BY referencesddocument, referencesddocumentitem.

  LOOP AT lt_so_lines INTO DATA(ls_so).
    READ TABLE lt_valid_so TRANSPORTING NO FIELDS
      WITH KEY table_line = ls_so-salesdocument
      BINARY SEARCH.
    IF sy-subrc <> 0.
      CONTINUE.
    ENDIF.

    CLEAR lv_delivered.
    READ TABLE lt_deliv_sum INTO DATA(ls_deliv)
      WITH KEY salesdocument     = ls_so-salesdocument
               salesdocumentitem = ls_so-salesdocumentitem
      BINARY SEARCH.
    IF sy-subrc = 0.
      lv_delivered = ls_deliv-qty.
    ENDIF.

    pc_qty = pc_qty + ( ls_so-orderquantity - lv_delivered ).
  ENDLOOP.

ENDFORM.

*&---------------------------------------------------------------------*
*&      Form  GET_NET_TOTAL_STO_QTY
*&---------------------------------------------------------------------*
* Stage D — Net Total STO, per Detailed FS "Net Total STO" row.
* Aggregate-level: SUM(OrderQuantity) - SUM(ActualDeliveryQuantity),
* both grouped by material — see header, open item 4 on the status
* filter combination, and open item 7 on the Material vs.
* ManufacturerMaterial field used to match the FG.
* Delivered qty for all open STO PO items is bulk-fetched in one
* grouped select instead of one SELECT SUM per PO item inside a LOOP.
*&---------------------------------------------------------------------*
FORM get_net_total_sto_qty USING    pu_matnr TYPE matnr
                                     pu_werks TYPE werks_d
                            CHANGING pc_qty   TYPE menge_d.

  TYPES: BEGIN OF ty_po_item,
           purchaseorder     TYPE ebeln,
           purchaseorderitem TYPE ebelp,
           orderquantity     TYPE menge_d,
         END OF ty_po_item.

  TYPES: BEGIN OF ty_po_deliv,
           purchaseorder     TYPE ebeln,
           purchaseorderitem TYPE ebelp,
           qty               TYPE menge_d,
         END OF ty_po_deliv.

  DATA: lt_po_items    TYPE STANDARD TABLE OF ty_po_item WITH EMPTY KEY,
        lt_po_deliv    TYPE STANDARD TABLE OF ty_po_deliv WITH EMPTY KEY,
        lv_ordered_sum TYPE menge_d,
        lv_deliv_sum   TYPE menge_d.

  CLEAR pc_qty.

  SELECT poi~purchaseorder, poi~purchaseorderitem, poi~orderquantity
    FROM i_purchaseorderitem AS poi
    INNER JOIN i_purchaseorder AS po
      ON po~purchaseorder = poi~purchaseorder
    INTO TABLE @lt_po_items
    WHERE po~supplyingplant                = @pu_werks
      AND po~purchaseordertype              IN ( 'ZUB', 'UB', 'ZSTR', 'ZOST', 'ZBST',
                                                   'ZUB1', 'ZUB2', 'ZUB3', 'ZUB4',
                                                   'ZUB5', 'ZUB6', 'ZUB7', 'ZUB8' )
      AND po~purchasingdocumentdeletioncode = ''
      AND poi~material                      = @pu_matnr
      AND poi~purchaseordercategory         = 'F'
      AND poi~materialtype                  = 'FERT'
      AND poi~iscompletelydelivered         = ''.

  IF lt_po_items IS INITIAL.
    RETURN.
  ENDIF.

  SELECT purchaseorder, purchaseorderitem,
         SUM( actualdeliveryquantity ) AS qty
    FROM i_deliverydocumentitem
    INTO TABLE @lt_po_deliv
    FOR ALL ENTRIES IN @lt_po_items
    WHERE purchaseorder     = @lt_po_items-purchaseorder
      AND purchaseorderitem = @lt_po_items-purchaseorderitem
      AND goodsmovementstatus = 'C'
      AND sdprocessstatus     IN ( 'A', 'B' )
    GROUP BY purchaseorder, purchaseorderitem.

  SORT lt_po_deliv BY purchaseorder purchaseorderitem.

  LOOP AT lt_po_items INTO DATA(ls_po).
    lv_ordered_sum = lv_ordered_sum + ls_po-orderquantity.

    READ TABLE lt_po_deliv INTO DATA(ls_deliv)
      WITH KEY purchaseorder     = ls_po-purchaseorder
               purchaseorderitem = ls_po-purchaseorderitem
      BINARY SEARCH.
    IF sy-subrc = 0.
      lv_deliv_sum = lv_deliv_sum + ls_deliv-qty.
    ENDIF.
  ENDLOOP.

  pc_qty = lv_ordered_sum - lv_deliv_sum.

ENDFORM.

*&---------------------------------------------------------------------*
*&      Form  STAGE_F_BOM_EXPLOSION
*&---------------------------------------------------------------------*
* Stage F — BOM alternative from I_BillOfMaterialItemTp /
* I_BillOfMaterial (active, not archived), then CS_BOM_EXPL_MAT_V2
* (RCS11001's underlying FM), explosion level 1 only.
*&---------------------------------------------------------------------*
FORM stage_f_bom_explosion USING    pu_fg       TYPE ty_fg_deficit
                            CHANGING pc_bom_comp TYPE tt_bom_comp.

  DATA: lv_stlal  TYPE stlal,
        lt_stb    TYPE STANDARD TABLE OF stpox,
        lt_matcat TYPE STANDARD TABLE OF cscmat.

  PERFORM get_active_bom_alternative USING pu_fg-matnr pu_fg-werks
                                     CHANGING lv_stlal.

  IF lv_stlal IS INITIAL.
    RETURN.  "no active, non-archived BOM found — nothing to explode
  ENDIF.

  CALL FUNCTION 'CS_BOM_EXPL_MAT_V2'
    EXPORTING
      capid                 = 'PP01'
      bmeng                 = abs( pu_fg-deficit_fg )   "Required Qty = Deficit Qty
      datuv                 = sy-datum                  "Valid On = System Date
      mehrs                 = 'X'
      mtnrv                 = pu_fg-matnr
      stlal                 = lv_stlal
      stlan                 = '1'                        "BOM Usage = 1
      werks                 = pu_fg-werks
    TABLES
      stb                   = lt_stb
      matcat                = lt_matcat
    EXCEPTIONS
      alt_not_found         = 1
      call_invalid          = 2
      material_not_found    = 3
      missing_authorization = 4
      no_bom_found          = 5
      no_plant_data         = 6
      no_suitable_bom_found = 7
      conversion_error      = 8
      OTHERS                = 9.

  IF sy-subrc <> 0.
    RETURN.
  ENDIF.

  LOOP AT lt_stb INTO DATA(ls_stb) WHERE dumps <> 'X'.
    APPEND INITIAL LINE TO pc_bom_comp ASSIGNING FIELD-SYMBOL(<fs_comp>).
    <fs_comp>-matnr = pu_fg-matnr.
    <fs_comp>-werks = pu_fg-werks.
    <fs_comp>-idnrk = ls_stb-idnrk.
    <fs_comp>-menge = ls_stb-mngko.   "QTY as per BOM
  ENDLOOP.

ENDFORM.

*&---------------------------------------------------------------------*
*&      Form  GET_ACTIVE_BOM_ALTERNATIVE
*&---------------------------------------------------------------------*
* Detailed FS "Alternative" row:
*   I_BillOfMaterialItemTp-Product/Plant -> distinct BillOfMaterial +
*   BillOfMaterialVariant. Filter via I_BillOfMaterial where
*   BOMIsArchivedForDeletion = '' and BillOfMaterialStatus = '1'.
* No tie-breaker stated if multiple remain — see header, open item 3.
*&---------------------------------------------------------------------*
FORM get_active_bom_alternative USING    pu_matnr TYPE matnr
                                          pu_werks TYPE werks_d
                                 CHANGING pc_stlal TYPE stlal.

  TYPES: BEGIN OF ty_bom_hdr,
           billofmaterial        TYPE cs_stlnr,
           billofmaterialvariant TYPE stlal,
         END OF ty_bom_hdr.

  DATA: lt_bom_items TYPE STANDARD TABLE OF ty_bom_hdr WITH EMPTY KEY,
        lt_bom_active TYPE STANDARD TABLE OF ty_bom_hdr WITH EMPTY KEY.

  CLEAR pc_stlal.

  SELECT DISTINCT billofmaterial, billofmaterialvariant
    FROM i_billofmaterialitemtp
    INTO TABLE @lt_bom_items
    WHERE material = @pu_matnr
      AND plant   = @pu_werks.

  IF lt_bom_items IS INITIAL.
    RETURN.
  ENDIF.

  SELECT bom~billofmaterial, bom~billofmaterialvariant
    FROM i_billofmaterial AS bom
        INTO TABLE @lt_bom_active
    FOR ALL ENTRIES IN @lt_bom_items
    WHERE bom~billofmaterial        = @lt_bom_items-billofmaterial
      AND bom~billofmaterialvariant = @lt_bom_items-billofmaterialvariant
      AND bom~bomisarchivedfordeletion = ''
      AND bom~billofmaterialstatus     = '1'.

  IF lt_bom_active IS INITIAL.
    RETURN.
  ENDIF.

  " ASSUMPTION (open item 3): lowest variant wins when several active
  " alternatives exist. Confirm with Mukesh.
  SORT lt_bom_active BY billofmaterialvariant ASCENDING.
  pc_stlal = lt_bom_active[ 1 ]-billofmaterialvariant.

ENDFORM.

*&---------------------------------------------------------------------*
*&      Form  STAGE_G_PROCESS_COMPONENTS
*&---------------------------------------------------------------------*
* Stage G — per BOM component: reuse stock routine, Min/Max stock,
* Net Weight, Work Center/PRT, carry FG header fields onto the row.
*&---------------------------------------------------------------------*
FORM stage_g_process_components USING pu_fg  TYPE ty_fg_deficit
                                       pt_bom TYPE tt_bom_comp.

  FIELD-SYMBOLS: <ls_comp> TYPE ty_bom_comp.

  LOOP AT pt_bom ASSIGNING <ls_comp>.

    APPEND INITIAL LINE TO gt_alv_out ASSIGNING FIELD-SYMBOL(<alv>).

    <alv>-fg      = pu_fg.
    <alv>-idnrk   = <ls_comp>-idnrk.
    <alv>-qty_bom = <ls_comp>-menge.

    " Stock = Unrestricted + Quality (reuse Stage B routine)
    PERFORM get_stock USING <ls_comp>-idnrk pu_fg-werks
                       CHANGING <alv>-rmpm_stock.

    " Deficit = Requirement Qty - Total Stock
    <alv>-rmpm_deficit = <ls_comp>-menge - <alv>-rmpm_stock.

    " Min/Max Stock Level — I_ProductSupplyPlanning
    SELECT SINGLE reorderthresholdquantity, maximumstockquantity
      FROM i_productsupplyplanning
      INTO ( @<alv>-min_stock, @<alv>-max_stock )
      WHERE product = @<ls_comp>-idnrk
        AND plant   = @pu_fg-werks.

    " Net Weight — I_Product-NetWeight
    SELECT SINGLE netweight
      FROM i_product
      INTO @<alv>-net_weight
      WHERE product = @<ls_comp>-idnrk.

    " Work Center / PRT (1st routing only) — Stage H
    PERFORM get_workcenter_prt USING <ls_comp>-idnrk pu_fg-werks
                                CHANGING <alv>-arbpl <alv>-equnr.

  ENDLOOP.

ENDFORM.

*&---------------------------------------------------------------------*
*&      Form  GET_WORKCENTER_PRT
*&---------------------------------------------------------------------*
* Stage H, per Detailed FS "Work Center" / "PRT" rows — table names
* unchanged from the original spec:
*   Work Center: MAPL(PLNTY=N/2) -> PLNNR,PLNAL
*                -> PLKO(PLNTY=N/2, LOEKZ='') validity check
*                -> PLAS(PLNNR,PLNAL) -> PLNNR,ZAEHL
*                -> PLPO(PLNNR,ZAEHL) -> ARBID
*                -> CRHD(OBJID=ARBID) -> ARBPL
*   PRT:         MAPL(PLNTY=N) -> PLNNR,PLNAL
*                -> PLKO(PLNTY=N, LOEKZ='')
*                -> PLFH(PLNNR,PLNAL, LOEKZ='') -> OBJID
*                -> CRVE_A(OBJID, OBJTY='FH') -> EQUNR
*&---------------------------------------------------------------------*
FORM get_workcenter_prt USING    pu_matnr TYPE matnr
                                  pu_werks TYPE werks_d
                         CHANGING pc_arbpl TYPE arbpl
                                  pc_equnr TYPE equnr.

  DATA: lv_plnnr_wc TYPE plnnr, lv_plnal_wc TYPE plnal,
        lv_plnnr_prt TYPE plnnr, lv_plnal_prt TYPE plnal,
        lv_zaehl TYPE CIM_COUNT, "plnfl_zaehl,
        lv_arbid TYPE arbid,
        lv_objid TYPE cr_objid.

  CLEAR: pc_arbpl, pc_equnr.

  " ---- Work Center chain: PLNTY IN (N,2) ----
  SELECT mapl~plnnr, mapl~plnal
    FROM mapl
    INNER JOIN plko
      ON plko~plnty = mapl~plnty
     AND plko~plnnr = mapl~plnnr
     AND plko~loekz = ''
    INTO (@lv_plnnr_wc, @lv_plnal_wc) UP TO 1 ROWS
    WHERE mapl~matnr = @pu_matnr
      AND mapl~werks = @pu_werks
      AND mapl~plnty IN ( 'N', '2' )
    ORDER BY mapl~plnnr ASCENDING.  ENDSELECT. "1st routing — see open item 3, same rule applies here

  IF sy-subrc = 0.
    SELECT zaehl
      FROM plas
      INTO @lv_zaehl UP TO 1 ROWS
      WHERE plnnr = @lv_plnnr_wc
        AND plnal = @lv_plnal_wc
      ORDER BY zaehl ASCENDING. ENDSELECT.

    IF sy-subrc = 0.
      SELECT SINGLE arbid
        FROM plpo
        INTO @lv_arbid
        WHERE plnnr = @lv_plnnr_wc
          AND zaehl = @lv_zaehl.

      IF sy-subrc = 0 AND lv_arbid IS NOT INITIAL.
        SELECT SINGLE arbpl
          FROM crhd
          INTO @pc_arbpl
          WHERE objid = @lv_arbid.
      ENDIF.
    ENDIF.
  ENDIF.

  " ---- PRT chain: PLNTY = N only ----
  SELECT mapl~plnnr, mapl~plnal
    FROM mapl
    INNER JOIN plko
      ON plko~plnty = mapl~plnty
     AND plko~plnnr = mapl~plnnr
     AND plko~loekz = ''
    INTO (@lv_plnnr_prt, @lv_plnal_prt) UP TO 1 ROWS
    WHERE mapl~matnr = @pu_matnr
      AND mapl~werks = @pu_werks
      AND mapl~plnty = 'N'
    ORDER BY mapl~plnnr ASCENDING.    ENDSELECT.

  IF sy-subrc = 0.
    SELECT SINGLE objid
      FROM plfh
      INTO @lv_objid
      WHERE plnnr = @lv_plnnr_prt
        AND plnal = @lv_plnal_prt
        AND loekz = ''.

    IF sy-subrc = 0 AND lv_objid IS NOT INITIAL.
      SELECT SINGLE equnr
        FROM crve_a
        INTO @pc_equnr
        WHERE objid = @lv_objid
          AND objty = 'FH'.
    ENDIF.
  ENDIF.

ENDFORM.

*&---------------------------------------------------------------------*
*&      Form  DISPLAY_ALV
*&---------------------------------------------------------------------*
* ALV column order per BRD "ALV generation format" row.
*&---------------------------------------------------------------------*
FORM display_alv.

  DATA: lo_alv    TYPE REF TO cl_salv_table,
        lo_cols   TYPE REF TO cl_salv_columns_table,
        lo_column TYPE REF TO cl_salv_column_table.

  IF gt_alv_out IS INITIAL.
    MESSAGE 'No FG deficits found for the selection.' TYPE 'S' DISPLAY LIKE 'W'.
    RETURN.
  ENDIF.

  TRY.
      cl_salv_table=>factory(
        IMPORTING r_salv_table = lo_alv
        CHANGING  t_table      = gt_alv_out ).
    CATCH cx_salv_msg INTO DATA(lx_msg).
      MESSAGE lx_msg->get_text( ) TYPE 'E'.
      RETURN.
  ENDTRY.

  lo_alv->get_functions( )->set_all( abap_true ).
  lo_cols = lo_alv->get_columns( ).
  lo_cols->set_optimize( abap_true ).

  TRY.
      lo_column ?= lo_cols->get_column( 'MATNR' ).
      lo_column->set_medium_text( 'Material' ).

      lo_column ?= lo_cols->get_column( 'MAKTX' ).
      lo_column->set_medium_text( 'Material Description' ).

      lo_column ?= lo_cols->get_column( 'MATKL' ).
      lo_column->set_medium_text( 'Material Group' ).

      lo_column ?= lo_cols->get_column( 'MVGR4_TXT' ).
      lo_column->set_medium_text( 'Material Category' ).

      lo_column ?= lo_cols->get_column( 'WERKS' ).
      lo_column->set_medium_text( 'Plant' ).

      lo_column ?= lo_cols->get_column( 'FG_STOCK' ).
      lo_column->set_medium_text( 'FG Stock' ).

      lo_column ?= lo_cols->get_column( 'TOT_SO_QTY' ).
      lo_column->set_medium_text( 'Total Sales Order' ).

      lo_column ?= lo_cols->get_column( 'NET_STO_QTY' ).
      lo_column->set_medium_text( 'Net Total STO' ).

      lo_column ?= lo_cols->get_column( 'DEFICIT_FG' ).
      lo_column->set_medium_text( 'Deficit/Surplus FG' ).

      lo_column ?= lo_cols->get_column( 'IDNRK' ).
      lo_column->set_medium_text( 'BOM Component' ).

      lo_column ?= lo_cols->get_column( 'QTY_BOM' ).
      lo_column->set_medium_text( 'QTY as per BOM' ).

      lo_column ?= lo_cols->get_column( 'RMPM_STOCK' ).
      lo_column->set_medium_text( 'RM/PM Stock' ).

      lo_column ?= lo_cols->get_column( 'RMPM_DEFICIT' ).
      lo_column->set_medium_text( 'RM/PM Deficit' ).

      lo_column ?= lo_cols->get_column( 'MIN_STOCK' ).
      lo_column->set_medium_text( 'Min Stock Level' ).

      lo_column ?= lo_cols->get_column( 'MAX_STOCK' ).
      lo_column->set_medium_text( 'Max Stock Level' ).

      lo_column ?= lo_cols->get_column( 'NET_WEIGHT' ).
      lo_column->set_medium_text( 'Net Weight' ).

      lo_column ?= lo_cols->get_column( 'ARBPL' ).
      lo_column->set_medium_text( 'Work Center' ).

      lo_column ?= lo_cols->get_column( 'EQUNR' ).
      lo_column->set_medium_text( 'PRT' ).
    CATCH cx_salv_not_found.
      "column not present — ignore
  ENDTRY.

  lo_alv->display( ).

ENDFORM.
