*&---------------------------------------------------------------------*
*& Report ZR_RMPM_DEFICIT_FG_REPORT
*&---------------------------------------------------------------------*
*& WRICEF-ID 7 : Report for RM/PM deficit based on FG deficit
*& Module      : PP
*& Object Type : Report (ALV)
*& Source      : Functional Specification "WRICEF-ID 7 Report for RM PM
*&               deficit based on FG Deficit" (BRD / FS / Detailed FS)
*&
*& Business logic (from FS):
*&   1. For the plant(s) entered, derive the FG list from open sales
*&      order items, then calculate the FG deficit:
*&         Deficit/Surplus = Total Stock - ( Total Sales Order + Net STO )
*&      where Total Stock = Unrestricted + Quality stock.
*&   2. For each FG in deficit, explode the 1st level of the active BOM
*&      (one BOM at a time) with Required Qty = FG deficit, and derive
*&      the RM/PM requirement per component.
*&   3. Show component stock, component deficit, min/max levels, net
*&      weight, and the Work Center / PRT from the 1st routing.
*&
*& For every field the underlying source table/CDS view and filter are
*& taken verbatim from the "Detailed FS" sheet. Points the FS left
*& ambiguous are marked "FS-OPEN" inline for functional confirmation.
*&---------------------------------------------------------------------*
REPORT zr_rmpm_deficit_fg_report.

*&---------------------------------------------------------------------*
*& Constants
*&---------------------------------------------------------------------*
CONSTANTS:
  gc_lang            TYPE spras     VALUE 'E',
  gc_item_cat_tan    TYPE char4     VALUE 'TAN',
  gc_doc_cat_order   TYPE char1     VALUE 'C',
  gc_so_status_open  TYPE char1     VALUE 'B',   "OverallSDProcessStatus
  gc_delblock_c      TYPE char1     VALUE 'C',   "OverallDeliveryBlockStatus
  gc_gms_completed   TYPE char1     VALUE 'C',   "GoodsMovementStatus
  gc_po_cat_sto      TYPE char1     VALUE 'F',   "PurchaseOrderCategory (STO)
  gc_mtype_fert      TYPE mtart     VALUE 'FERT',
  gc_bom_usage       TYPE stlan     VALUE '1',
  gc_bom_application TYPE capid      VALUE 'PP01',
  gc_bom_status_act  TYPE char1     VALUE '1',   "BillOfMaterialStatus
  gc_prt_objty_fh    TYPE cr_objty  VALUE 'FH',
  gc_auth_object     TYPE xuobject  VALUE 'M_MATE_WRK', "FS-OPEN: object not named in FS
  gc_actvt_display   TYPE activ_auth VALUE '03'.

*&---------------------------------------------------------------------*
*& Types
*&---------------------------------------------------------------------*
* Generic (Material, Plant) key + quantity tables, reused for FG and
* for RM/PM component level (IDNRK shares MATNR's domain).
TYPES: BEGIN OF ty_key,
         matnr TYPE matnr,
         werks TYPE werks_d,
       END OF ty_key,
       tt_key TYPE SORTED TABLE OF ty_key WITH UNIQUE KEY matnr werks.

TYPES: BEGIN OF ty_qty,
         matnr TYPE matnr,
         werks TYPE werks_d,
         menge TYPE menge_d,
       END OF ty_qty,
       tt_qty TYPE SORTED TABLE OF ty_qty WITH UNIQUE KEY matnr werks.

TYPES: BEGIN OF ty_minmax,
         matnr     TYPE matnr,
         werks     TYPE werks_d,
         min_stock TYPE menge_d,
         max_stock TYPE menge_d,
       END OF ty_minmax,
       tt_minmax TYPE SORTED TABLE OF ty_minmax WITH UNIQUE KEY matnr werks.

TYPES: BEGIN OF ty_weight,
         matnr      TYPE matnr,
         net_weight TYPE ntgew,
       END OF ty_weight,
       tt_weight TYPE SORTED TABLE OF ty_weight WITH UNIQUE KEY matnr.

TYPES: BEGIN OF ty_wc,
         matnr TYPE matnr,
         werks TYPE werks_d,
         arbpl TYPE arbpl,
       END OF ty_wc,
       tt_wc TYPE SORTED TABLE OF ty_wc WITH UNIQUE KEY matnr werks.

TYPES: BEGIN OF ty_prt,
         matnr TYPE matnr,
         werks TYPE werks_d,
         equnr TYPE equnr,
       END OF ty_prt,
       tt_prt TYPE SORTED TABLE OF ty_prt WITH UNIQUE KEY matnr werks.

TYPES: BEGIN OF ty_bom_alt,
         matnr TYPE matnr,
         werks TYPE werks_d,
         stlal TYPE stlal,
       END OF ty_bom_alt,
       tt_bom_alt TYPE SORTED TABLE OF ty_bom_alt WITH UNIQUE KEY matnr werks.

* Raw open sales-order item (kept for the Total Sales Order step)
TYPES: BEGIN OF ty_so_item,
         salesdocument     TYPE vbeln_va,
         salesdocumentitem TYPE posnr_va,
         matnr             TYPE matnr,
         werks             TYPE werks_d,
         orderquantity     TYPE menge_d,
       END OF ty_so_item,
       tt_so_item TYPE STANDARD TABLE OF ty_so_item WITH EMPTY KEY.

* FG-level result
TYPES: BEGIN OF ty_fg,
         matnr      TYPE matnr,
         werks      TYPE werks_d,
         maktx      TYPE maktx,
         matkl      TYPE matkl,
         matcat     TYPE bezei20,
         fg_stock   TYPE menge_d,
         tot_so     TYPE menge_d,
         net_sto    TYPE menge_d,
         deficit_fg TYPE menge_d,     "negative = shortage
       END OF ty_fg,
       tt_fg TYPE STANDARD TABLE OF ty_fg WITH EMPTY KEY.

* One exploded BOM component (before enrichment)
TYPES: BEGIN OF ty_comp,
         fg      TYPE ty_fg,
         idnrk   TYPE idnrk,
         qty_bom TYPE menge_d,        "MNGKO from explosion
       END OF ty_comp,
       tt_comp TYPE STANDARD TABLE OF ty_comp WITH EMPTY KEY.

* Final ALV row (BRD "ALV generation format" order)
TYPES: BEGIN OF ty_out,
         matnr        TYPE matnr,
         maktx        TYPE maktx,
         matkl        TYPE matkl,
         matcat       TYPE bezei20,
         werks        TYPE werks_d,
         fg_stock     TYPE menge_d,
         tot_so       TYPE menge_d,
         net_sto      TYPE menge_d,
         deficit_fg   TYPE menge_d,
         idnrk        TYPE idnrk,
         qty_bom      TYPE menge_d,
         rmpm_stock   TYPE menge_d,
         rmpm_deficit TYPE menge_d,
         min_stock    TYPE menge_d,
         max_stock    TYPE menge_d,
         net_weight   TYPE ntgew,
         arbpl        TYPE arbpl,
         equnr        TYPE equnr,
       END OF ty_out,
       tt_out TYPE STANDARD TABLE OF ty_out WITH EMPTY KEY.

TYPES: BEGIN OF ty_sloc,
         werks TYPE werks_d,
         lgort TYPE lgort_d,
       END OF ty_sloc.

*&---------------------------------------------------------------------*
*& Global data
*&---------------------------------------------------------------------*
DATA: gt_fg      TYPE tt_fg,
      gt_so_raw  TYPE tt_so_item,
      gt_comp    TYPE tt_comp,
      gt_out     TYPE tt_out,
      gt_sloc    TYPE SORTED TABLE OF ty_sloc WITH NON-UNIQUE KEY werks lgort.

DATA: gv_werks_d TYPE werks_d,
      gv_matnr_d TYPE matnr.

*&---------------------------------------------------------------------*
*& Selection screen (BRD "Selection Screen": Plant mandatory,
*& Order Start date + Material optional, all From/To ranges)
*&---------------------------------------------------------------------*
SELECTION-SCREEN BEGIN OF BLOCK b1 WITH FRAME TITLE TEXT-001.  "001 = Selection Screen
SELECT-OPTIONS: s_werks FOR gv_werks_d OBLIGATORY,
                s_erdat FOR sy-datum,          "Order Start date (FS-OPEN, see stage A)
                s_matnr FOR gv_matnr_d.
SELECTION-SCREEN END OF BLOCK b1.

*&---------------------------------------------------------------------*
*& Main flow
*&---------------------------------------------------------------------*
START-OF-SELECTION.

  PERFORM check_authorization.
  PERFORM load_sloc_exclusions.

  PERFORM build_fg_candidates.       "Stage A
  IF gt_fg IS INITIAL.
    MESSAGE 'No FG found for the selection' TYPE 'S' DISPLAY LIKE 'W'.
    RETURN.
  ENDIF.

  PERFORM fill_fg_master_data.       "Description / Group / Category
  PERFORM fill_fg_stock.             "Total Stock
  PERFORM fill_total_sales_order.    "Total Sales Order
  PERFORM fill_net_total_sto.        "Net Total STO
  PERFORM calc_fg_deficit.           "Deficit/Surplus

  PERFORM explode_deficit_boms.      "Stage F (deficit FGs only)
  PERFORM build_and_enrich_output.   "Stage G

  PERFORM display_alv.

*&---------------------------------------------------------------------*
*&      Form  CHECK_AUTHORIZATION
*&---------------------------------------------------------------------*
* BRD: "Plant as an authorization object". FS-OPEN: the object name is
* not given; M_MATE_WRK (plant view, ACTVT 03) is used as a placeholder
* pending confirmation from Basis/Security.
*&---------------------------------------------------------------------*
FORM check_authorization.

  LOOP AT s_werks INTO DATA(ls_werks).
    AUTHORITY-CHECK OBJECT gc_auth_object
      ID 'WERKS' FIELD ls_werks-low
      ID 'ACTVT' FIELD gc_actvt_display.
    IF sy-subrc <> 0.
      MESSAGE e172(00) WITH ls_werks-low.  "No authorization for &1
    ENDIF.
  ENDLOOP.

ENDFORM.

*&---------------------------------------------------------------------*
*&      Form  LOAD_SLOC_EXCLUSIONS
*&---------------------------------------------------------------------*
* Detailed FS stock steps: storage locations present in ZPP_PLAN_SLOC
* must NOT be considered for stock. Loaded once here.
*&---------------------------------------------------------------------*
FORM load_sloc_exclusions.

  SELECT werks, lgort
    FROM zpp_plan_sloc
    INTO TABLE @gt_sloc.
  IF sy-subrc <> 0.
    CLEAR gt_sloc.
  ENDIF.

ENDFORM.

*&---------------------------------------------------------------------*
*&      Form  BUILD_FG_CANDIDATES
*&---------------------------------------------------------------------*
* Detailed FS "Material": pass plant to I_SalesDocumentItem-Plant for
* SalesDocumentItemCategory = 'TAN' and SDDocumentCategory = 'C' and
* take Product. SalesDocumentRjcnReason = space (needed by the Total
* Sales Order step) is applied here already.
* FS-OPEN: the FS does not name the source of "Order Start date"; it is
* applied against I_SalesDocumentItem-CreationDate.
*&---------------------------------------------------------------------*
FORM build_fg_candidates.

  SELECT salesdocument,
         salesdocumentitem,
         product  AS matnr,
         plant    AS werks,
         orderquantity
    FROM i_salesdocumentitem
    INTO TABLE @gt_so_raw
    WHERE plant                    IN @s_werks
      AND product                  IN @s_matnr
      AND creationdate             IN @s_erdat
      AND salesdocumentitemcategory = @gc_item_cat_tan
      AND sddocumentcategory        = @gc_doc_cat_order
      AND salesdocumentrjcnreason   = @space.
  IF sy-subrc <> 0.
    RETURN.
  ENDIF.

  " Distinct Product/Plant -> FG candidate list
  DATA(lt_dist) = gt_so_raw.
  SORT lt_dist BY matnr werks.
  DELETE ADJACENT DUPLICATES FROM lt_dist COMPARING matnr werks.

  LOOP AT lt_dist INTO DATA(ls_dist).
    APPEND VALUE #( matnr = ls_dist-matnr
                    werks = ls_dist-werks ) TO gt_fg.
  ENDLOOP.

ENDFORM.

*&---------------------------------------------------------------------*
*&      Form  FILL_FG_MASTER_DATA
*&---------------------------------------------------------------------*
* Description : I_ProductText-ProductName for Language = 'E'
* Group       : I_Product-ProductGroup
* Category    : I_ProductSalesDelivery-FourthSalesSpecProductGroup
*               (not blank) -> TVM4T-BEZEI for Spras = 'E'
*&---------------------------------------------------------------------*
FORM fill_fg_master_data.

  DATA(lt_matnr) = VALUE tt_key( ).
  LOOP AT gt_fg INTO DATA(ls_fg).
    INSERT VALUE #( matnr = ls_fg-matnr ) INTO TABLE lt_matnr.
  ENDLOOP.
  IF lt_matnr IS INITIAL.
    RETURN.
  ENDIF.

  SELECT product AS matnr, productname AS maktx
    FROM i_producttext
    FOR ALL ENTRIES IN @lt_matnr
    WHERE product  = @lt_matnr-matnr
      AND language = @gc_lang
    INTO TABLE @DATA(lt_text).

  SELECT product AS matnr, productgroup AS matkl
    FROM i_product
    FOR ALL ENTRIES IN @lt_matnr
    WHERE product = @lt_matnr-matnr
    INTO TABLE @DATA(lt_group).

  SELECT DISTINCT product AS matnr,
                  fourthsalesspecproductgroup AS mvgr4
    FROM i_productsalesdelivery
    FOR ALL ENTRIES IN @lt_matnr
    WHERE product                     = @lt_matnr-matnr
      AND fourthsalesspecproductgroup <> @space
    INTO TABLE @DATA(lt_mvgr4).

  IF lt_mvgr4 IS NOT INITIAL.
    DATA(lt_mvgr4_key) = lt_mvgr4.
    SORT lt_mvgr4_key BY mvgr4.
    DELETE ADJACENT DUPLICATES FROM lt_mvgr4_key COMPARING mvgr4.

    SELECT mvgr4, bezei
      FROM tvm4t
      FOR ALL ENTRIES IN @lt_mvgr4_key
      WHERE spras = @gc_lang
        AND mvgr4 = @lt_mvgr4_key-mvgr4
      INTO TABLE @DATA(lt_cat_text).
  ENDIF.

  SORT lt_text  BY matnr.
  SORT lt_group BY matnr.
  SORT lt_mvgr4 BY matnr.
  SORT lt_cat_text BY mvgr4.

  LOOP AT gt_fg ASSIGNING FIELD-SYMBOL(<fg>).

    READ TABLE lt_text INTO DATA(ls_text)
      WITH KEY matnr = <fg>-matnr BINARY SEARCH.
    IF sy-subrc = 0.
      <fg>-maktx = ls_text-maktx.
    ENDIF.

    READ TABLE lt_group INTO DATA(ls_group)
      WITH KEY matnr = <fg>-matnr BINARY SEARCH.
    IF sy-subrc = 0.
      <fg>-matkl = ls_group-matkl.
    ENDIF.

    READ TABLE lt_mvgr4 INTO DATA(ls_mvgr4)
      WITH KEY matnr = <fg>-matnr BINARY SEARCH.
    IF sy-subrc = 0.
      READ TABLE lt_cat_text INTO DATA(ls_cat)
        WITH KEY mvgr4 = ls_mvgr4-mvgr4 BINARY SEARCH.
      IF sy-subrc = 0.
        <fg>-matcat = ls_cat-bezei.
      ENDIF.
    ENDIF.

  ENDLOOP.

ENDFORM.

*&---------------------------------------------------------------------*
*&      Form  FILL_FG_STOCK
*&---------------------------------------------------------------------*
* Total Stock (Unrestricted + Quality) for every FG candidate.
*&---------------------------------------------------------------------*
FORM fill_fg_stock.

  DATA lt_stock TYPE tt_qty.

  DATA(lt_keys) = VALUE tt_key( ).
  LOOP AT gt_fg INTO DATA(ls_fg).
    INSERT VALUE #( matnr = ls_fg-matnr werks = ls_fg-werks ) INTO TABLE lt_keys.
  ENDLOOP.

  PERFORM get_total_stock USING lt_keys CHANGING lt_stock.

  LOOP AT gt_fg ASSIGNING FIELD-SYMBOL(<fg>).
    READ TABLE lt_stock INTO DATA(ls_stock)
      WITH TABLE KEY matnr = <fg>-matnr werks = <fg>-werks.
    IF sy-subrc = 0.
      <fg>-fg_stock = ls_stock-menge.
    ENDIF.
  ENDLOOP.

ENDFORM.

*&---------------------------------------------------------------------*
*&      Form  GET_TOTAL_STOCK
*&---------------------------------------------------------------------*
* Detailed FS "Unrestricted Stock" + "Quality Stock", 3 conditions:
*   C1: V_MBEW_MD-BWTTY <> ''                         -> NSDM_V_MCHB
*   C2: BWTTY = '' AND I_ProductPlant
*         -IsBatchManagementRequired <> ''            -> NSDM_V_MCHB
*   C3: BWTTY = '' AND IsBatchManagementRequired = '' -> NSDM_V_MARD
* Unrestricted = CLABS/LABST, Quality = CINSM/INSME. Storage locations
* present in ZPP_PLAN_SLOC are excluded. Result = Unrestricted+Quality
* summed per Material/Plant. Reused for FG and RM/PM component level.
*&---------------------------------------------------------------------*
FORM get_total_stock USING    it_keys TYPE tt_key
                     CHANGING  ct_qty  TYPE tt_qty.

  CLEAR ct_qty.
  IF it_keys IS INITIAL.
    RETURN.
  ENDIF.

  " ---- Classify batch-managed vs. non-batch ------------------------
  SELECT matnr, bwkey AS werks, bwtty
    FROM v_mbew_md
    FOR ALL ENTRIES IN @it_keys
    WHERE matnr = @it_keys-matnr
      AND bwkey = @it_keys-werks
    INTO TABLE @DATA(lt_mbew).

  SELECT product AS matnr, plant AS werks, isbatchmanagementrequired AS flag
    FROM i_productplant
    FOR ALL ENTRIES IN @it_keys
    WHERE product = @it_keys-matnr
      AND plant   = @it_keys-werks
    INTO TABLE @DATA(lt_pplant).

  SORT lt_pplant BY matnr werks.

  DATA: lt_batch    TYPE tt_key,
        lt_nonbatch TYPE tt_key.

  LOOP AT it_keys INTO DATA(ls_key).
    " C1: any valuation type (BWTTY) populated -> batch path (NSDM_V_MCHB)
    DATA(lv_batch) = abap_false.
    LOOP AT lt_mbew INTO DATA(ls_mbew)
         WHERE matnr = ls_key-matnr AND werks = ls_key-werks
           AND bwtty <> space.
      lv_batch = abap_true.
      EXIT.
    ENDLOOP.

    IF lv_batch = abap_false.
      " C2 / C3: decide via IsBatchManagementRequired
      READ TABLE lt_pplant INTO DATA(ls_pp)
        WITH KEY matnr = ls_key-matnr werks = ls_key-werks BINARY SEARCH.
      IF sy-subrc = 0 AND ls_pp-flag <> space.
        lv_batch = abap_true.
      ENDIF.
    ENDIF.

    IF lv_batch = abap_true.
      INSERT ls_key INTO TABLE lt_batch.
    ELSE.
      INSERT ls_key INTO TABLE lt_nonbatch.
    ENDIF.
  ENDLOOP.

  " ---- Batch-managed stock: NSDM_V_MCHB ----------------------------
  IF lt_batch IS NOT INITIAL.
    SELECT matnr, werks, lgort, clabs, cinsm
      FROM nsdm_v_mchb
      FOR ALL ENTRIES IN @lt_batch
      WHERE matnr = @lt_batch-matnr
        AND werks = @lt_batch-werks
        AND ( clabs <> 0 OR cinsm <> 0 )
      INTO TABLE @DATA(lt_mchb).

    LOOP AT lt_mchb INTO DATA(ls_mchb).
      READ TABLE gt_sloc TRANSPORTING NO FIELDS
        WITH KEY werks = ls_mchb-werks lgort = ls_mchb-lgort.
      IF sy-subrc = 0.
        CONTINUE.                       "excluded storage location
      ENDIF.
      DATA(lv_qty_mchb) = CONV menge_d( ls_mchb-clabs + ls_mchb-cinsm ).
      PERFORM add_qty USING ls_mchb-matnr ls_mchb-werks lv_qty_mchb
                      CHANGING ct_qty.
    ENDLOOP.
  ENDIF.

  " ---- Non-batch stock: NSDM_V_MARD --------------------------------
  IF lt_nonbatch IS NOT INITIAL.
    SELECT matnr, werks, lgort, labst, insme
      FROM nsdm_v_mard
      FOR ALL ENTRIES IN @lt_nonbatch
      WHERE matnr = @lt_nonbatch-matnr
        AND werks = @lt_nonbatch-werks
        AND ( labst <> 0 OR insme <> 0 )
      INTO TABLE @DATA(lt_mard).

    LOOP AT lt_mard INTO DATA(ls_mard).
      READ TABLE gt_sloc TRANSPORTING NO FIELDS
        WITH KEY werks = ls_mard-werks lgort = ls_mard-lgort.
      IF sy-subrc = 0.
        CONTINUE.
      ENDIF.
      DATA(lv_qty_mard) = CONV menge_d( ls_mard-labst + ls_mard-insme ).
      PERFORM add_qty USING ls_mard-matnr ls_mard-werks lv_qty_mard
                      CHANGING ct_qty.
    ENDLOOP.
  ENDIF.

ENDFORM.

*&---------------------------------------------------------------------*
*&      Form  ADD_QTY  (accumulate qty per Material/Plant)
*&---------------------------------------------------------------------*
FORM add_qty USING    iv_matnr TYPE matnr
                      iv_werks TYPE werks_d
                      iv_qty   TYPE menge_d
             CHANGING ct_qty   TYPE tt_qty.

  READ TABLE ct_qty ASSIGNING FIELD-SYMBOL(<q>)
    WITH TABLE KEY matnr = iv_matnr werks = iv_werks.
  IF sy-subrc = 0.
    <q>-menge = <q>-menge + iv_qty.
  ELSE.
    INSERT VALUE #( matnr = iv_matnr werks = iv_werks menge = iv_qty )
      INTO TABLE ct_qty.
  ENDIF.

ENDFORM.

*&---------------------------------------------------------------------*
*&      Form  FILL_TOTAL_SALES_ORDER
*&---------------------------------------------------------------------*
* Detailed FS "Total Sales Order":
*   Open SO items (from stage A) whose SalesDocument has
*   OverallSDProcessStatus = 'B' and OverallDeliveryBlockStatus <> 'C'.
*   Open qty = OrderQuantity - delivered (I_DeliveryDocumentItem
*   ActualDeliveryQuantity where GoodsMovementStatus <> 'C'), summed
*   per Material/Plant.
* FS-OPEN: FS text "...for I_DeliveryDocumentItem = A and B..." does not
* name a field, so only the GoodsMovementStatus <> 'C' filter is applied.
*&---------------------------------------------------------------------*
FORM fill_total_sales_order.

  IF gt_so_raw IS INITIAL.
    RETURN.
  ENDIF.

  " Valid sales documents
  DATA lt_doc TYPE STANDARD TABLE OF vbeln_va WITH EMPTY KEY.
  LOOP AT gt_so_raw INTO DATA(ls_so).
    APPEND ls_so-salesdocument TO lt_doc.
  ENDLOOP.
  SORT lt_doc.
  DELETE ADJACENT DUPLICATES FROM lt_doc.

  SELECT salesdocument
    FROM i_salesdocument
    FOR ALL ENTRIES IN @lt_doc
    WHERE salesdocument              = @lt_doc-table_line
      AND overallsdprocessstatus     = @gc_so_status_open
      AND overalldeliveryblockstatus <> @gc_delblock_c
    INTO TABLE @DATA(lt_valid).
  SORT lt_valid BY salesdocument.

  " Delivered qty per SO item. FOR ALL ENTRIES cannot be combined with
  " GROUP BY, so raw delivery rows are fetched and summed via COLLECT.
  TYPES: BEGIN OF ty_deliv,
           salesdocument     TYPE vbeln_va,
           salesdocumentitem TYPE posnr_va,
           menge             TYPE menge_d,
         END OF ty_deliv.
  DATA: lt_deliv_raw TYPE STANDARD TABLE OF ty_deliv WITH EMPTY KEY,
        lt_deliv     TYPE SORTED TABLE OF ty_deliv
                          WITH UNIQUE KEY salesdocument salesdocumentitem.

  SELECT referencesddocument     AS salesdocument,
         referencesddocumentitem AS salesdocumentitem,
         actualdeliveryquantity  AS menge
    FROM i_deliverydocumentitem
    FOR ALL ENTRIES IN @gt_so_raw
    WHERE referencesddocument     = @gt_so_raw-salesdocument
      AND referencesddocumentitem = @gt_so_raw-salesdocumentitem
      AND goodsmovementstatus    <> @gc_gms_completed
    INTO TABLE @lt_deliv_raw.

  LOOP AT lt_deliv_raw INTO DATA(ls_deliv_raw).
    COLLECT ls_deliv_raw INTO lt_deliv.
  ENDLOOP.

  DATA(lt_so_qty) = VALUE tt_qty( ).

  LOOP AT gt_so_raw INTO ls_so.
    READ TABLE lt_valid TRANSPORTING NO FIELDS
      WITH KEY salesdocument = ls_so-salesdocument BINARY SEARCH.
    IF sy-subrc <> 0.
      CONTINUE.
    ENDIF.

    DATA(lv_deliv) = VALUE menge_d( ).
    READ TABLE lt_deliv INTO DATA(ls_deliv)
      WITH KEY salesdocument     = ls_so-salesdocument
               salesdocumentitem = ls_so-salesdocumentitem BINARY SEARCH.
    IF sy-subrc = 0.
      lv_deliv = ls_deliv-menge.
    ENDIF.

    DATA(lv_open_so) = CONV menge_d( ls_so-orderquantity - lv_deliv ).
    PERFORM add_qty USING ls_so-matnr ls_so-werks lv_open_so
                    CHANGING lt_so_qty.
  ENDLOOP.

  LOOP AT gt_fg ASSIGNING FIELD-SYMBOL(<fg>).
    READ TABLE lt_so_qty INTO DATA(ls_sum)
      WITH TABLE KEY matnr = <fg>-matnr werks = <fg>-werks.
    IF sy-subrc = 0.
      <fg>-tot_so = ls_sum-menge.
    ENDIF.
  ENDLOOP.

ENDFORM.

*&---------------------------------------------------------------------*
*&      Form  FILL_NET_TOTAL_STO
*&---------------------------------------------------------------------*
* Detailed FS "Net Total STO":
*   I_PurchaseOrder-SupplyingPlant IN plant, PurchaseOrderType in the
*   STO type list, PurchasingDocumentDeletionCode = ''. Items with
*   PurchaseOrderCategory 'F', MaterialType 'FERT',
*   PurchasingDocumentDeletionCode '', IsCompletelyDelivered ''.
*   Net = OrderQuantity - delivered (I_DeliveryDocumentItem
*   ActualDeliveryQuantity, GoodsMovementStatus = 'C'), per Material/
*   SupplyingPlant.
* FS-OPEN: (a) FS names ManufacturerMaterial as the field to take, but
* the FG match is done on Material (Product); (b) "OVERALL STATUS = A
* and B" alongside GoodsMovementStatus = 'C' is contradictory and is
* not applied.
*&---------------------------------------------------------------------*
FORM fill_net_total_sto.

  DATA(lt_keys) = VALUE tt_key( ).
  LOOP AT gt_fg INTO DATA(ls_fg).
    INSERT VALUE #( matnr = ls_fg-matnr werks = ls_fg-werks ) INTO TABLE lt_keys.
  ENDLOOP.
  IF lt_keys IS INITIAL.
    RETURN.
  ENDIF.

  " STO order types (ZUB, UB, ZSTR, ZOST, ZBST, ZUB1..ZUB8)
  DATA lt_potype TYPE RANGE OF ekko-bsart.
  lt_potype = VALUE #(
    ( sign = 'I' option = 'EQ' low = 'ZUB'  )
    ( sign = 'I' option = 'EQ' low = 'UB'   )
    ( sign = 'I' option = 'EQ' low = 'ZSTR' )
    ( sign = 'I' option = 'EQ' low = 'ZOST' )
    ( sign = 'I' option = 'EQ' low = 'ZBST' )
    ( sign = 'I' option = 'BT' low = 'ZUB1' high = 'ZUB8' ) ).

  SELECT poi~purchaseorder,
         poi~purchaseorderitem,
         poi~material     AS matnr,
         po~supplyingplant AS werks,
         poi~orderquantity
    FROM i_purchaseorderitem AS poi
    INNER JOIN i_purchaseorder AS po
      ON po~purchaseorder = poi~purchaseorder
    FOR ALL ENTRIES IN @lt_keys
    WHERE poi~material                    = @lt_keys-matnr
      AND po~supplyingplant               = @lt_keys-werks
      AND po~purchaseordertype            IN @lt_potype
      AND po~purchasingdocumentdeletioncode = @space
      AND poi~purchaseordercategory       = @gc_po_cat_sto
      AND poi~materialtype                = @gc_mtype_fert
      AND poi~purchasingdocumentdeletioncode = @space
      AND poi~iscompletelydelivered       = @space
    INTO TABLE @DATA(lt_po).
  IF sy-subrc <> 0.
    RETURN.
  ENDIF.

  " Delivered (GR-completed) qty per PO item. FOR ALL ENTRIES cannot be
  " combined with GROUP BY, so raw rows are fetched and summed via COLLECT.
  TYPES: BEGIN OF ty_grd,
           purchaseorder     TYPE ebeln,
           purchaseorderitem TYPE ebelp,
           menge             TYPE menge_d,
         END OF ty_grd.
  DATA: lt_grd_raw TYPE STANDARD TABLE OF ty_grd WITH EMPTY KEY,
        lt_grd     TYPE SORTED TABLE OF ty_grd
                        WITH UNIQUE KEY purchaseorder purchaseorderitem.

  SELECT purchaseorder,
         purchaseorderitem,
         actualdeliveryquantity AS menge
    FROM i_deliverydocumentitem
    FOR ALL ENTRIES IN @lt_po
    WHERE purchaseorder       = @lt_po-purchaseorder
      AND purchaseorderitem   = @lt_po-purchaseorderitem
      AND goodsmovementstatus = @gc_gms_completed
    INTO TABLE @lt_grd_raw.

  LOOP AT lt_grd_raw INTO DATA(ls_grd_raw).
    COLLECT ls_grd_raw INTO lt_grd.
  ENDLOOP.

  DATA(lt_sto_qty) = VALUE tt_qty( ).

  LOOP AT lt_po INTO DATA(ls_po).
    DATA(lv_deliv) = VALUE menge_d( ).
    READ TABLE lt_grd INTO DATA(ls_grd)
      WITH KEY purchaseorder     = ls_po-purchaseorder
               purchaseorderitem = ls_po-purchaseorderitem BINARY SEARCH.
    IF sy-subrc = 0.
      lv_deliv = ls_grd-menge.
    ENDIF.

    DATA(lv_net_sto) = CONV menge_d( ls_po-orderquantity - lv_deliv ).
    PERFORM add_qty USING ls_po-matnr ls_po-werks lv_net_sto
                    CHANGING lt_sto_qty.
  ENDLOOP.

  LOOP AT gt_fg ASSIGNING FIELD-SYMBOL(<fg>).
    READ TABLE lt_sto_qty INTO DATA(ls_sum)
      WITH TABLE KEY matnr = <fg>-matnr werks = <fg>-werks.
    IF sy-subrc = 0.
      <fg>-net_sto = ls_sum-menge.
    ENDIF.
  ENDLOOP.

ENDFORM.

*&---------------------------------------------------------------------*
*&      Form  CALC_FG_DEFICIT
*&---------------------------------------------------------------------*
* Detailed FS "Deficit/Surplus" = Total Stock - ( Total SO + Net STO ).
* Negative result = deficit (shortage).
*&---------------------------------------------------------------------*
FORM calc_fg_deficit.

  LOOP AT gt_fg ASSIGNING FIELD-SYMBOL(<fg>).
    <fg>-deficit_fg = <fg>-fg_stock - ( <fg>-tot_so + <fg>-net_sto ).
  ENDLOOP.

ENDFORM.

*&---------------------------------------------------------------------*
*&      Form  EXPLODE_DEFICIT_BOMS
*&---------------------------------------------------------------------*
* BRD: explode the 1st level of the active BOM, one BOM at a time, for
* FGs in deficit. The active alternative is resolved in bulk; the level-1
* explosion itself is per FG via CS_BOM_EXPL_MAT_V2 (RCS11001's FM), as
* the FS requires per-material explosion. The loop below issues no SELECT.
*&---------------------------------------------------------------------*
FORM explode_deficit_boms.

  DATA lt_alt TYPE tt_bom_alt.

  DATA(lt_def_keys) = VALUE tt_key( ).
  LOOP AT gt_fg INTO DATA(ls_fg) WHERE deficit_fg < 0.
    INSERT VALUE #( matnr = ls_fg-matnr werks = ls_fg-werks ) INTO TABLE lt_def_keys.
  ENDLOOP.
  IF lt_def_keys IS INITIAL.
    RETURN.
  ENDIF.

  PERFORM get_active_bom_alt USING lt_def_keys CHANGING lt_alt.

  LOOP AT gt_fg INTO ls_fg WHERE deficit_fg < 0.
    READ TABLE lt_alt INTO DATA(ls_alt)
      WITH TABLE KEY matnr = ls_fg-matnr werks = ls_fg-werks.
    IF sy-subrc <> 0.
      CONTINUE.                          "no active BOM -> nothing to explode
    ENDIF.
    PERFORM explode_single_bom USING ls_fg ls_alt-stlal.
  ENDLOOP.

ENDFORM.

*&---------------------------------------------------------------------*
*&      Form  GET_ACTIVE_BOM_ALT
*&---------------------------------------------------------------------*
* Detailed FS "Alternative": distinct BillOfMaterial / Variant from
* I_BillOfMaterialItemTP for Product/Plant, kept only if active via
* I_BillOfMaterial (BOMIsArchivedForDeletion = '', BillOfMaterialStatus
* = '1'). FS-OPEN: no tie-break is stated when several remain; the
* lowest BillOfMaterialVariant is used.
*&---------------------------------------------------------------------*
FORM get_active_bom_alt USING    it_keys TYPE tt_key
                        CHANGING ct_alt  TYPE tt_bom_alt.

  CLEAR ct_alt.
  IF it_keys IS INITIAL.
    RETURN.
  ENDIF.

  SELECT DISTINCT material AS matnr,
                  plant    AS werks,
                  billofmaterial,
                  billofmaterialvariant
    FROM i_billofmaterialitemtp
    FOR ALL ENTRIES IN @it_keys
    WHERE material = @it_keys-matnr
      AND plant    = @it_keys-werks
    INTO TABLE @DATA(lt_item).
  IF sy-subrc <> 0.
    RETURN.
  ENDIF.

  DATA(lt_hdr_key) = lt_item.
  SORT lt_hdr_key BY billofmaterial billofmaterialvariant.
  DELETE ADJACENT DUPLICATES FROM lt_hdr_key
    COMPARING billofmaterial billofmaterialvariant.

  SELECT billofmaterial, billofmaterialvariant
    FROM i_billofmaterial
    FOR ALL ENTRIES IN @lt_hdr_key
    WHERE billofmaterial           = @lt_hdr_key-billofmaterial
      AND billofmaterialvariant    = @lt_hdr_key-billofmaterialvariant
      AND bomisarchivedfordeletion = @space
      AND billofmaterialstatus     = @gc_bom_status_act
    INTO TABLE @DATA(lt_active).
  IF sy-subrc <> 0.
    RETURN.
  ENDIF.
  SORT lt_active BY billofmaterial billofmaterialvariant.

  " Keep active item combos, pick lowest variant per Material/Plant
  DATA lt_pick TYPE STANDARD TABLE OF ty_bom_alt WITH EMPTY KEY.

  LOOP AT lt_item INTO DATA(ls_item).
    READ TABLE lt_active TRANSPORTING NO FIELDS
      WITH KEY billofmaterial        = ls_item-billofmaterial
               billofmaterialvariant = ls_item-billofmaterialvariant BINARY SEARCH.
    IF sy-subrc = 0.
      APPEND VALUE #( matnr = ls_item-matnr
                      werks = ls_item-werks
                      stlal = ls_item-billofmaterialvariant ) TO lt_pick.
    ENDIF.
  ENDLOOP.

  SORT lt_pick BY matnr werks stlal ASCENDING.
  DELETE ADJACENT DUPLICATES FROM lt_pick COMPARING matnr werks.

  LOOP AT lt_pick INTO DATA(ls_pick).
    INSERT ls_pick INTO TABLE ct_alt.
  ENDLOOP.

ENDFORM.

*&---------------------------------------------------------------------*
*&      Form  EXPLODE_SINGLE_BOM
*&---------------------------------------------------------------------*
* Level-1 explosion of one FG BOM via CS_BOM_EXPL_MAT_V2.
*   Application = PP01, BOM Usage = 1, Valid On = system date,
*   Required Qty = FG deficit qty (absolute). QTY as per BOM = MNGKO.
*&---------------------------------------------------------------------*
FORM explode_single_bom USING iu_fg    TYPE ty_fg
                              iu_stlal TYPE stlal.

  DATA: lt_stb    TYPE STANDARD TABLE OF stpox,
        lt_matcat TYPE STANDARD TABLE OF cscmat.

  DATA(lv_req_qty) = CONV menge_d( abs( iu_fg-deficit_fg ) ).   "Required Qty

  CALL FUNCTION 'CS_BOM_EXPL_MAT_V2'
    EXPORTING
      capid                 = gc_bom_application
      datuv                 = sy-datum
      mehrs                 = space              "single (level-1) explosion
      mtnrv                 = iu_fg-matnr
      werks                 = iu_fg-werks
      stlan                 = gc_bom_usage
      stlal                 = iu_stlal
      emeng                 = lv_req_qty     "Required quantity (scales MNGKO)
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

  LOOP AT lt_stb INTO DATA(ls_stb) WHERE idnrk IS NOT INITIAL.
    APPEND VALUE #( fg      = iu_fg
                    idnrk   = ls_stb-idnrk
                    qty_bom = ls_stb-mngko ) TO gt_comp.
  ENDLOOP.

ENDFORM.

*&---------------------------------------------------------------------*
*&      Form  BUILD_AND_ENRICH_OUTPUT
*&---------------------------------------------------------------------*
* Stage G: for every exploded component, add RM/PM stock, RM/PM deficit
* (Requirement Qty - Total Stock), Min/Max levels, Net Weight, and the
* FG routing's Work Center / PRT. All lookups are bulked; the assembly
* loop performs only in-memory reads.
*&---------------------------------------------------------------------*
FORM build_and_enrich_output.

  DATA: lt_stock  TYPE tt_qty,
        lt_minmax TYPE tt_minmax,
        lt_weight TYPE tt_weight,
        lt_wc     TYPE tt_wc,
        lt_prt    TYPE tt_prt.

  IF gt_comp IS INITIAL.
    RETURN.
  ENDIF.

  " Distinct component keys (Material=IDNRK, Plant=FG plant)
  DATA(lt_comp_keys) = VALUE tt_key( ).
  LOOP AT gt_comp INTO DATA(ls_comp).
    INSERT VALUE #( matnr = ls_comp-idnrk werks = ls_comp-fg-werks )
      INTO TABLE lt_comp_keys.
  ENDLOOP.

  " Distinct FG keys (for Work Center / PRT)
  DATA(lt_fg_keys) = VALUE tt_key( ).
  LOOP AT gt_comp INTO ls_comp.
    INSERT VALUE #( matnr = ls_comp-fg-matnr werks = ls_comp-fg-werks )
      INTO TABLE lt_fg_keys.
  ENDLOOP.

  PERFORM get_total_stock    USING lt_comp_keys CHANGING lt_stock.
  PERFORM get_min_max_stock  USING lt_comp_keys CHANGING lt_minmax.
  PERFORM get_net_weight     USING lt_comp_keys CHANGING lt_weight.
  PERFORM get_workcenter_prt USING lt_fg_keys   CHANGING lt_wc lt_prt.

  LOOP AT gt_comp INTO ls_comp.

    APPEND INITIAL LINE TO gt_out ASSIGNING FIELD-SYMBOL(<out>).
    <out>-matnr      = ls_comp-fg-matnr.
    <out>-maktx      = ls_comp-fg-maktx.
    <out>-matkl      = ls_comp-fg-matkl.
    <out>-matcat     = ls_comp-fg-matcat.
    <out>-werks      = ls_comp-fg-werks.
    <out>-fg_stock   = ls_comp-fg-fg_stock.
    <out>-tot_so     = ls_comp-fg-tot_so.
    <out>-net_sto    = ls_comp-fg-net_sto.
    <out>-deficit_fg = ls_comp-fg-deficit_fg.
    <out>-idnrk      = ls_comp-idnrk.
    <out>-qty_bom    = ls_comp-qty_bom.

    READ TABLE lt_stock INTO DATA(ls_stock)
      WITH TABLE KEY matnr = ls_comp-idnrk werks = ls_comp-fg-werks.
    IF sy-subrc = 0.
      <out>-rmpm_stock = ls_stock-menge.
    ENDIF.

    " RM/PM Deficit = Requirement Qty (QTY as per BOM) - Total Stock
    <out>-rmpm_deficit = ls_comp-qty_bom - <out>-rmpm_stock.

    READ TABLE lt_minmax INTO DATA(ls_mm)
      WITH TABLE KEY matnr = ls_comp-idnrk werks = ls_comp-fg-werks.
    IF sy-subrc = 0.
      <out>-min_stock = ls_mm-min_stock.
      <out>-max_stock = ls_mm-max_stock.
    ENDIF.

    READ TABLE lt_weight INTO DATA(ls_w)
      WITH TABLE KEY matnr = ls_comp-idnrk.
    IF sy-subrc = 0.
      <out>-net_weight = ls_w-net_weight.
    ENDIF.

    READ TABLE lt_wc INTO DATA(ls_wc)
      WITH TABLE KEY matnr = ls_comp-fg-matnr werks = ls_comp-fg-werks.
    IF sy-subrc = 0.
      <out>-arbpl = ls_wc-arbpl.
    ENDIF.

    READ TABLE lt_prt INTO DATA(ls_prt)
      WITH TABLE KEY matnr = ls_comp-fg-matnr werks = ls_comp-fg-werks.
    IF sy-subrc = 0.
      <out>-equnr = ls_prt-equnr.
    ENDIF.

  ENDLOOP.

ENDFORM.

*&---------------------------------------------------------------------*
*&      Form  GET_MIN_MAX_STOCK
*&---------------------------------------------------------------------*
* Detailed FS "Min/Max Stock Level": I_ProductSupplyPlanning
* ReorderThresholdQuantity / MaximumStockQuantity per Product/Plant.
*&---------------------------------------------------------------------*
FORM get_min_max_stock USING    it_keys   TYPE tt_key
                       CHANGING ct_minmax TYPE tt_minmax.

  CLEAR ct_minmax.
  IF it_keys IS INITIAL.
    RETURN.
  ENDIF.

  " I_ProductSupplyPlanning can hold several MRP-area rows per Product/
  " Plant; insert one per key (duplicates set sy-subrc, no short dump).
  SELECT product AS matnr,
         plant   AS werks,
         reorderthresholdquantity AS min_stock,
         maximumstockquantity     AS max_stock
    FROM i_productsupplyplanning
    FOR ALL ENTRIES IN @it_keys
    WHERE product = @it_keys-matnr
      AND plant   = @it_keys-werks
    INTO TABLE @DATA(lt_supply).

  LOOP AT lt_supply INTO DATA(ls_supply).
    INSERT VALUE #( matnr     = ls_supply-matnr
                    werks     = ls_supply-werks
                    min_stock = ls_supply-min_stock
                    max_stock = ls_supply-max_stock ) INTO TABLE ct_minmax.
  ENDLOOP.

ENDFORM.

*&---------------------------------------------------------------------*
*&      Form  GET_NET_WEIGHT
*&---------------------------------------------------------------------*
* Detailed FS "Net Weight": I_Product-NetWeight (not plant-specific).
*&---------------------------------------------------------------------*
FORM get_net_weight USING    it_keys   TYPE tt_key
                    CHANGING ct_weight TYPE tt_weight.

  CLEAR ct_weight.
  IF it_keys IS INITIAL.
    RETURN.
  ENDIF.

  DATA(lt_matnr) = VALUE tt_key( ).
  LOOP AT it_keys INTO DATA(ls_key).
    INSERT VALUE #( matnr = ls_key-matnr ) INTO TABLE lt_matnr.
  ENDLOOP.

  SELECT product AS matnr, netweight AS net_weight
    FROM i_product
    FOR ALL ENTRIES IN @lt_matnr
    WHERE product = @lt_matnr-matnr
    INTO TABLE @ct_weight.

ENDFORM.

*&---------------------------------------------------------------------*
*&      Form  GET_WORKCENTER_PRT
*&---------------------------------------------------------------------*
* Detailed FS "Work Center" / "PRT" — resolved from the FG routing.
* BRD: "If multiple routing exist ... fetch from 1st Routing Only".
*   Work Center: MAPL(PLNTY N/2) -> PLKO(LOEKZ='') -> PLAS -> PLPO
*                -> ARBID -> CRHD-ARBPL
*   PRT        : MAPL(PLNTY N)   -> PLKO(LOEKZ='') -> PLFH(LOEKZ='')
*                -> OBJID -> CRVE_A(OBJTY='FH')-EQUNR
* 1st routing / 1st line resolved via SORT + DELETE ADJACENT DUPLICATES.
*&---------------------------------------------------------------------*
FORM get_workcenter_prt USING    it_keys TYPE tt_key
                        CHANGING ct_wc   TYPE tt_wc
                                 ct_prt  TYPE tt_prt.

  CLEAR: ct_wc, ct_prt.
  IF it_keys IS INITIAL.
    RETURN.
  ENDIF.

  " ===== Work Center chain (PLNTY N/2) ==============================
  SELECT mapl~matnr, mapl~werks, mapl~plnnr, mapl~plnal
    FROM mapl
    INNER JOIN plko
      ON  plko~plnty = mapl~plnty
      AND plko~plnnr = mapl~plnnr
      AND plko~plnal = mapl~plnal
      AND plko~loekz = @space
    FOR ALL ENTRIES IN @it_keys
    WHERE mapl~matnr = @it_keys-matnr
      AND mapl~werks = @it_keys-werks
      AND mapl~plnty IN ( 'N', '2' )
    INTO TABLE @DATA(lt_route).

  SORT lt_route BY matnr werks plnnr plnal ASCENDING.
  DATA(lt_route1) = lt_route.
  DELETE ADJACENT DUPLICATES FROM lt_route1 COMPARING matnr werks.

  IF lt_route1 IS NOT INITIAL.
    SELECT plnnr, plnal, zaehl
      FROM plas
      FOR ALL ENTRIES IN @lt_route1
      WHERE plnnr = @lt_route1-plnnr
        AND plnal = @lt_route1-plnal
      INTO TABLE @DATA(lt_plas).
    SORT lt_plas BY plnnr plnal zaehl ASCENDING.
    DATA(lt_plas1) = lt_plas.
    DELETE ADJACENT DUPLICATES FROM lt_plas1 COMPARING plnnr plnal.

    IF lt_plas1 IS NOT INITIAL.
      SELECT plnnr, zaehl, arbid
        FROM plpo
        FOR ALL ENTRIES IN @lt_plas1
        WHERE plnnr = @lt_plas1-plnnr
          AND zaehl = @lt_plas1-zaehl
        INTO TABLE @DATA(lt_plpo).
      SORT lt_plpo BY plnnr zaehl.

      IF lt_plpo IS NOT INITIAL.
        SELECT objid, arbpl
          FROM crhd
          FOR ALL ENTRIES IN @lt_plpo
          WHERE objid = @lt_plpo-arbid
          INTO TABLE @DATA(lt_crhd).
        SORT lt_crhd BY objid.
      ENDIF.
    ENDIF.
  ENDIF.

  LOOP AT lt_route1 INTO DATA(ls_r1).
    READ TABLE lt_plas1 INTO DATA(ls_plas1)
      WITH KEY plnnr = ls_r1-plnnr plnal = ls_r1-plnal BINARY SEARCH.
    CHECK sy-subrc = 0.
    READ TABLE lt_plpo INTO DATA(ls_plpo)
      WITH KEY plnnr = ls_plas1-plnnr zaehl = ls_plas1-zaehl BINARY SEARCH.
    CHECK sy-subrc = 0.
    READ TABLE lt_crhd INTO DATA(ls_crhd)
      WITH KEY objid = ls_plpo-arbid BINARY SEARCH.
    CHECK sy-subrc = 0.
    INSERT VALUE #( matnr = ls_r1-matnr werks = ls_r1-werks arbpl = ls_crhd-arbpl )
      INTO TABLE ct_wc.
  ENDLOOP.

  " ===== PRT chain (PLNTY N) ========================================
  SELECT mapl~matnr, mapl~werks, mapl~plnnr, mapl~plnal
    FROM mapl
    INNER JOIN plko
      ON  plko~plnty = mapl~plnty
      AND plko~plnnr = mapl~plnnr
      AND plko~plnal = mapl~plnal
      AND plko~loekz = @space
    FOR ALL ENTRIES IN @it_keys
    WHERE mapl~matnr = @it_keys-matnr
      AND mapl~werks = @it_keys-werks
      AND mapl~plnty = 'N'
    INTO TABLE @DATA(lt_prt_route).

  SORT lt_prt_route BY matnr werks plnnr plnal ASCENDING.
  DATA(lt_prt_route1) = lt_prt_route.
  DELETE ADJACENT DUPLICATES FROM lt_prt_route1 COMPARING matnr werks.

  IF lt_prt_route1 IS NOT INITIAL.
    SELECT plnnr, plnal, objid
      FROM plfh
      FOR ALL ENTRIES IN @lt_prt_route1
      WHERE plnnr = @lt_prt_route1-plnnr
        AND plnal = @lt_prt_route1-plnal
        AND loekz = @space
      INTO TABLE @DATA(lt_plfh).
    SORT lt_plfh BY plnnr plnal.

    IF lt_plfh IS NOT INITIAL.
      SELECT objid, equnr
        FROM crve_a
        FOR ALL ENTRIES IN @lt_plfh
        WHERE objid = @lt_plfh-objid
          AND objty = @gc_prt_objty_fh
        INTO TABLE @DATA(lt_crve).
      SORT lt_crve BY objid.
    ENDIF.
  ENDIF.

  LOOP AT lt_prt_route1 INTO DATA(ls_pr1).
    READ TABLE lt_plfh INTO DATA(ls_plfh)
      WITH KEY plnnr = ls_pr1-plnnr plnal = ls_pr1-plnal BINARY SEARCH.
    CHECK sy-subrc = 0.
    READ TABLE lt_crve INTO DATA(ls_crve)
      WITH KEY objid = ls_plfh-objid BINARY SEARCH.
    CHECK sy-subrc = 0.
    INSERT VALUE #( matnr = ls_pr1-matnr werks = ls_pr1-werks equnr = ls_crve-equnr )
      INTO TABLE ct_prt.
  ENDLOOP.

ENDFORM.

*&---------------------------------------------------------------------*
*&      Form  DISPLAY_ALV
*&---------------------------------------------------------------------*
* ALV output in BRD "ALV generation format" column order.
*&---------------------------------------------------------------------*
FORM display_alv.

  IF gt_out IS INITIAL.
    MESSAGE 'No FG deficit / BOM component to display' TYPE 'S' DISPLAY LIKE 'W'.
    RETURN.
  ENDIF.

  TRY.
      cl_salv_table=>factory(
        IMPORTING r_salv_table = DATA(lo_alv)
        CHANGING  t_table      = gt_out ).
    CATCH cx_salv_msg INTO DATA(lx_msg).
      MESSAGE lx_msg->get_text( ) TYPE 'E'.
      RETURN.
  ENDTRY.

  lo_alv->get_functions( )->set_all( abap_true ).
  DATA(lo_cols) = lo_alv->get_columns( ).
  lo_cols->set_optimize( abap_true ).

  PERFORM set_col USING lo_cols 'MATNR'        'Material'.
  PERFORM set_col USING lo_cols 'MAKTX'        'Material Description'.
  PERFORM set_col USING lo_cols 'MATKL'        'Material Group'.
  PERFORM set_col USING lo_cols 'MATCAT'       'Material Category'.
  PERFORM set_col USING lo_cols 'WERKS'        'Plant'.
  PERFORM set_col USING lo_cols 'FG_STOCK'     'FG Stock'.
  PERFORM set_col USING lo_cols 'TOT_SO'       'Total Sales Order'.
  PERFORM set_col USING lo_cols 'NET_STO'      'Net Total STO'.
  PERFORM set_col USING lo_cols 'DEFICIT_FG'   'Deficit/Surplus FG'.
  PERFORM set_col USING lo_cols 'IDNRK'        'BOM Component'.
  PERFORM set_col USING lo_cols 'QTY_BOM'      'QTY as per BOM'.
  PERFORM set_col USING lo_cols 'RMPM_STOCK'   'RM/PM Stock'.
  PERFORM set_col USING lo_cols 'RMPM_DEFICIT' 'RM/PM Deficit'.
  PERFORM set_col USING lo_cols 'MIN_STOCK'    'Min Stock Level'.
  PERFORM set_col USING lo_cols 'MAX_STOCK'    'Max Stock Level'.
  PERFORM set_col USING lo_cols 'NET_WEIGHT'   'Net Weight'.
  PERFORM set_col USING lo_cols 'ARBPL'        'Work Center'.
  PERFORM set_col USING lo_cols 'EQUNR'        'PRT'.

  lo_alv->display( ).

ENDFORM.

*&---------------------------------------------------------------------*
*&      Form  SET_COL  (set ALV column header)
*&---------------------------------------------------------------------*
FORM set_col USING io_cols TYPE REF TO cl_salv_columns_table
                   iv_name TYPE csequence
                   iv_text TYPE csequence.

  TRY.
      DATA(lo_col) = CAST cl_salv_column_table(
                       io_cols->get_column( CONV lvc_fname( iv_name ) ) ).
      lo_col->set_medium_text( CONV #( iv_text ) ).
      lo_col->set_long_text( CONV #( iv_text ) ).
    CATCH cx_salv_not_found.
      "column not present - ignore
  ENDTRY.

ENDFORM.
