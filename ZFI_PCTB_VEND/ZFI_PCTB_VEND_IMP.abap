*&---------------------------------------------------------------------*
*& Include          ZFI_PCTB_VEND_IMP
*&---------------------------------------------------------------------*
*& Implementation - Vendor Trial Balance (Profit Center wise)
*&---------------------------------------------------------------------*

*&---------------------------------------------------------------------*
*&      Form  AUTHORIZATION_CHECK
*&---------------------------------------------------------------------*
FORM authorization_check.

  LOOP AT s_bukrs INTO DATA(ls_bukrs).
    AUTHORITY-CHECK OBJECT 'ZTB_PC1'
      ID 'BUKRS' FIELD ls_bukrs-low
      ID 'ACTVT' FIELD '03'.

    IF sy-subrc <> 0.
      MESSAGE |You do not have authorization for company code { ls_bukrs-low }|
              TYPE 'E'.
    ENDIF.
  ENDLOOP.

ENDFORM.

*&---------------------------------------------------------------------*
*&      Form  GET_DATA
*&---------------------------------------------------------------------*
FORM get_data.

  PERFORM get_vendor_names.
  PERFORM get_profit_center_regio.
  PERFORM get_line_items.
  PERFORM get_open_items.
  PERFORM get_gl_items.

ENDFORM.

*&---------------------------------------------------------------------*
*&      Form  GET_VENDOR_NAMES
*&---------------------------------------------------------------------*
*&  Reads the vendor names and - when no supplier was entered - fills
*&  S_LIFNR so that the submitted standard report is restricted the
*&  same way as before.
*&---------------------------------------------------------------------*
FORM get_vendor_names.

  SELECT lifnr, name1
    FROM lfa1
    WHERE lifnr IN @s_lifnr
    INTO TABLE @gt_vendor_name.

  IF gt_vendor_name IS INITIAL.
    MESSAGE 'No supplier found for the given selection' TYPE 'S' DISPLAY LIKE 'E'.
    LEAVE LIST-PROCESSING.
  ENDIF.

  IF s_lifnr[] IS INITIAL.
    s_lifnr[] = VALUE #( FOR ls_vendor IN gt_vendor_name
                         ( sign = 'I' option = 'EQ' low = ls_vendor-lifnr ) ).
  ENDIF.

ENDFORM.

*&---------------------------------------------------------------------*
*&      Form  GET_PROFIT_CENTER_REGIO
*&---------------------------------------------------------------------*
*&  FS 329: the state is the region of the profit center master (CEPC).
*&  When a state is entered the resulting profit centers are turned into
*&  a range so that the restriction is pushed down to the database in
*&  the FAGLFLEXA select instead of being filtered afterwards.
*&---------------------------------------------------------------------*
FORM get_profit_center_regio.

  DATA(lv_keydate) = VALUE budat( s_pdate[ 1 ]-high OPTIONAL ).

  SELECT prctr, datbi, regio
    FROM cepc
    WHERE prctr IN @s_prctr
      AND regio IN @s_regio
      AND datbi >= @lv_keydate
      AND datab <= @lv_keydate
    ORDER BY prctr ASCENDING, datbi DESCENDING
    INTO TABLE @DATA(lt_cepc).

  " CEPC is key-dependent on the controlling area as well - the report has
  " no controlling area selection, so the latest valid entry wins.
  DELETE ADJACENT DUPLICATES FROM lt_cepc COMPARING prctr.
  gt_regio = CORRESPONDING #( lt_cepc ).

  IF s_regio[] IS NOT INITIAL.
    IF gt_regio IS INITIAL.
      MESSAGE 'No profit center found for the selected State (Region)'
              TYPE 'S' DISPLAY LIKE 'E'.
      LEAVE LIST-PROCESSING.
    ENDIF.

    gr_prctr = VALUE #( FOR ls_regio IN gt_regio
                        ( sign = 'I' option = 'EQ' low = ls_regio-prctr ) ).
  ENDIF.

ENDFORM.

*&---------------------------------------------------------------------*
*&      Form  GET_LINE_ITEMS
*&---------------------------------------------------------------------*
*&  Runs the standard vendor line item report for the selected period
*&  and picks up its ALV result via the SALV runtime info.
*&---------------------------------------------------------------------*
FORM get_line_items.

  cl_salv_bs_runtime_info=>set( display  = abap_false
                                metadata = abap_false
                                data     = abap_true ).

  SUBMIT rfitemap WITH so_kunnr IN s_lifnr
                  WITH kd_lifnr IN s_lifnr
                  WITH kd_bukrs IN s_bukrs
                  WITH so_budat IN s_pdate
                  WITH x_aisel  EQ abap_true
                  WITH x_opsel  EQ abap_false
                  WITH pa_vari  EQ '/1SAP'
                  AND RETURN.

  TRY.
      cl_salv_bs_runtime_info=>get_data_ref( IMPORTING r_data = go_data ).
      ASSIGN go_data->* TO <lt_data>.

      IF <lt_data> IS ASSIGNED.
        " <lt_data> is generically typed, so the mapping is done per row.
        LOOP AT <lt_data> ASSIGNING FIELD-SYMBOL(<ls_data>).
          DATA ls_line TYPE ty_report.
          CLEAR ls_line.
          MOVE-CORRESPONDING <ls_data> TO ls_line.
          APPEND ls_line TO gt_report.
        ENDLOOP.
      ENDIF.

    CATCH cx_salv_bs_sc_runtime_info.
      cl_salv_bs_runtime_info=>clear_all( ).
      MESSAGE 'Unable to retrieve the vendor line items' TYPE 'S' DISPLAY LIKE 'E'.
      LEAVE LIST-PROCESSING.
  ENDTRY.

  cl_salv_bs_runtime_info=>clear_all( ).

ENDFORM.

*&---------------------------------------------------------------------*
*&      Form  GET_OPEN_ITEMS
*&---------------------------------------------------------------------*
*&  Opening balance = open items one day before the period start,
*&  closing balance = open items at the period end.
*&---------------------------------------------------------------------*
FORM get_open_items.

  " Computed once - not inside the vendor loop.
  DATA(ls_pdate)      = VALUE #( s_pdate[ 1 ] OPTIONAL ).
  DATA(lv_open_date)  = CONV budat( ls_pdate-low - 1 ).
  DATA(lv_close_date) = CONV budat( ls_pdate-high ).

  SELECT lifnr, bukrs
    FROM lfb1
    WHERE lifnr IN @s_lifnr
      AND bukrs IN @s_bukrs
    INTO TABLE @DATA(lt_vendor).

  LOOP AT lt_vendor INTO DATA(ls_vendor).

    DATA(lt_items) = VALUE tt_bapi_itm( ).
    CALL FUNCTION 'BAPI_AP_ACC_GETOPENITEMS'
      EXPORTING
        companycode = ls_vendor-bukrs
        vendor      = ls_vendor-lifnr
        keydate     = lv_open_date
      TABLES
        lineitems   = lt_items.
    APPEND LINES OF lt_items TO gt_opening_b.

    CLEAR lt_items.
    CALL FUNCTION 'BAPI_AP_ACC_GETOPENITEMS'
      EXPORTING
        companycode = ls_vendor-bukrs
        vendor      = ls_vendor-lifnr
        keydate     = lv_close_date
      TABLES
        lineitems   = lt_items.
    APPEND LINES OF lt_items TO gt_closing_b.

  ENDLOOP.

ENDFORM.

*&---------------------------------------------------------------------*
*&      Form  GET_GL_ITEMS
*&---------------------------------------------------------------------*
*&  Opening, closing and period items are read from FAGLFLEXA with a
*&  single database access over the union of all document keys.
*&---------------------------------------------------------------------*
FORM get_gl_items.

  DATA lt_key TYPE tt_doc_key.

  PERFORM add_bapi_keys USING gt_opening_b CHANGING lt_key.
  PERFORM add_bapi_keys USING gt_closing_b CHANGING lt_key.

  LOOP AT gt_report INTO DATA(ls_report).
    INSERT VALUE #( rbukrs = ls_report-bukrs
                    ryear  = ls_report-gjahr
                    docnr  = ls_report-belnr
                    buzei  = ls_report-buzei ) INTO TABLE lt_key.
  ENDLOOP.

  IF lt_key IS INITIAL.
    RETURN.
  ENDIF.

  SELECT rbukrs, ryear, docnr, buzei, prctr, rbusa, drcrk, hsl
    FROM faglflexa
    FOR ALL ENTRIES IN @lt_key
    WHERE rldnr  = @gc_ledger
      AND rbukrs = @lt_key-rbukrs
      AND ryear  = @lt_key-ryear
      AND docnr  = @lt_key-docnr
      AND buzei  = @lt_key-buzei
      AND prctr  IN @s_prctr
      AND prctr  IN @gr_prctr
      AND rbusa  IN @s_gsber
    INTO TABLE @gt_gl.

ENDFORM.

*&---------------------------------------------------------------------*
*&      Form  ADD_BAPI_KEYS
*&---------------------------------------------------------------------*
FORM add_bapi_keys USING    it_items TYPE tt_bapi_itm
                   CHANGING ct_key   TYPE tt_doc_key.

  LOOP AT it_items INTO DATA(ls_item).
    INSERT VALUE #( rbukrs = ls_item-comp_code
                    ryear  = ls_item-fisc_year
                    docnr  = ls_item-doc_no
                    buzei  = ls_item-item_num ) INTO TABLE ct_key.
  ENDLOOP.

ENDFORM.

*&---------------------------------------------------------------------*
*&      Form  FILL_DATA
*&---------------------------------------------------------------------*
*&  Aggregates all four amount columns into one result table keyed by
*&  vendor / profit center / business area.
*&---------------------------------------------------------------------*
FORM fill_data.

  PERFORM aggregate_open_items USING gt_opening_b gc_col-open.
  PERFORM aggregate_open_items USING gt_closing_b gc_col-close.
  PERFORM aggregate_period_items.

  gt_final = gt_balance.
  SORT gt_final BY lifnr prctr gsber.

ENDFORM.

*&---------------------------------------------------------------------*
*&      Form  AGGREGATE_OPEN_ITEMS
*&---------------------------------------------------------------------*
FORM aggregate_open_items USING it_items TYPE tt_bapi_itm
                                iv_field TYPE fieldname.

  LOOP AT it_items INTO DATA(ls_item).
    LOOP AT gt_gl INTO DATA(ls_gl)
         WHERE rbukrs = ls_item-comp_code
           AND ryear  = ls_item-fisc_year
           AND docnr  = ls_item-doc_no
           AND buzei  = ls_item-item_num.

      PERFORM add_amount USING iv_field ls_item-vendor ls_gl.
    ENDLOOP.
  ENDLOOP.

ENDFORM.

*&---------------------------------------------------------------------*
*&      Form  AGGREGATE_PERIOD_ITEMS
*&---------------------------------------------------------------------*
*&  Debit / credit turnover of the selected period, split by DRCRK.
*&---------------------------------------------------------------------*
FORM aggregate_period_items.

  LOOP AT gt_report INTO DATA(ls_report).
    LOOP AT gt_gl INTO DATA(ls_gl)
         WHERE rbukrs = ls_report-bukrs
           AND ryear  = ls_report-gjahr
           AND docnr  = ls_report-belnr
           AND buzei  = ls_report-buzei.

      CASE ls_gl-drcrk.
        WHEN gc_credit.
          PERFORM add_amount USING gc_col-credi ls_report-lifnr ls_gl.
        WHEN gc_debit.
          PERFORM add_amount USING gc_col-debit ls_report-lifnr ls_gl.
      ENDCASE.
    ENDLOOP.
  ENDLOOP.

ENDFORM.

*&---------------------------------------------------------------------*
*&      Form  ADD_AMOUNT
*&---------------------------------------------------------------------*
*&  Adds one G/L line item amount to the requested column of the
*&  vendor / profit center / business area result row.
*&---------------------------------------------------------------------*
FORM add_amount USING iv_field  TYPE fieldname
                      iv_lifnr  TYPE lifnr
                      is_gl     TYPE ty_data.

  READ TABLE gt_balance ASSIGNING FIELD-SYMBOL(<ls_bal>)
       WITH TABLE KEY lifnr = iv_lifnr
                      prctr = is_gl-prctr
                      gsber = is_gl-gsber.

  IF sy-subrc <> 0.
    DATA ls_new TYPE ty_final.
    CLEAR ls_new.
    ls_new-lifnr = iv_lifnr.
    ls_new-prctr = is_gl-prctr.
    ls_new-gsber = is_gl-gsber.

    READ TABLE gt_vendor_name INTO DATA(ls_name)
         WITH TABLE KEY lifnr = iv_lifnr.
    IF sy-subrc = 0.
      ls_new-name1 = ls_name-name1.
    ENDIF.

    " Region is optional - it is user maintained in the profit center master.
    READ TABLE gt_regio INTO DATA(ls_regio)
         WITH TABLE KEY prctr = is_gl-prctr.
    IF sy-subrc = 0.
      ls_new-regio = ls_regio-regio.
    ENDIF.

    INSERT ls_new INTO TABLE gt_balance ASSIGNING <ls_bal>.
  ENDIF.

  ASSIGN COMPONENT iv_field OF STRUCTURE <ls_bal> TO FIELD-SYMBOL(<lv_amount>).
  IF <lv_amount> IS ASSIGNED.
    <lv_amount> = <lv_amount> + is_gl-hsl.
  ENDIF.

ENDFORM.

*&---------------------------------------------------------------------*
*&      Form  FCAT
*&---------------------------------------------------------------------*
FORM fcat.

  gt_fieldcat = VALUE #(
    ( fieldname = 'LIFNR'         seltext_m = 'Vendor Code'       outputlen = 10 )
    ( fieldname = 'NAME1'         seltext_m = 'Vendor Name'       outputlen = 35 )
    ( fieldname = 'PRCTR'         seltext_m = 'Profit Center'     outputlen = 10 )
    ( fieldname = 'GSBER'         seltext_m = 'Plant (Bus. Area)' outputlen = 10 )
    ( fieldname = 'REGIO'         seltext_m = 'State (Region)'    outputlen = 10 )
    ( fieldname = 'OPEN_BALANCE'  seltext_m = 'Opening Balance'   do_sum = abap_true )
    ( fieldname = 'DEBIT'         seltext_m = 'Debit'             do_sum = abap_true )
    ( fieldname = 'CREDIT'        seltext_m = 'Credit'            do_sum = abap_true )
    ( fieldname = 'CLOSE_BALANCE' seltext_m = 'Closing Balance'   do_sum = abap_true ) ).

ENDFORM.

*&---------------------------------------------------------------------*
*&      Form  DISPLAY
*&---------------------------------------------------------------------*
FORM display.

  IF gt_final IS INITIAL.
    MESSAGE 'No data found for the given selection' TYPE 'S' DISPLAY LIKE 'E'.
    LEAVE LIST-PROCESSING.
  ENDIF.

  gs_layout-colwidth_optimize = abap_true.
  gs_layout-zebra             = abap_true.

  CALL FUNCTION 'REUSE_ALV_GRID_DISPLAY'
    EXPORTING
      i_callback_program     = sy-repid
      i_callback_top_of_page = 'TOP_OFF_PAGE'
      is_layout              = gs_layout
      i_save                 = 'A'
      it_fieldcat            = gt_fieldcat
    TABLES
      t_outtab               = gt_final
    EXCEPTIONS
      program_error          = 1
      OTHERS                 = 2.

  IF sy-subrc <> 0.
    MESSAGE ID sy-msgid TYPE sy-msgty NUMBER sy-msgno
            WITH sy-msgv1 sy-msgv2 sy-msgv3 sy-msgv4.
  ENDIF.

ENDFORM.

*&---------------------------------------------------------------------*
*&      Form  TOP_OFF_PAGE
*&---------------------------------------------------------------------*
FORM top_off_page.

  DATA(ls_pdate) = VALUE #( s_pdate[ 1 ] OPTIONAL ).

  DATA(lt_comment) = VALUE slis_t_listheader(
    ( typ = 'H' info = 'Vendor-PC - TB' )
    ( typ = 'S' info = |Vendor TB based on PC for the period: | &&
                       |{ ls_pdate-low DATE = USER } To { ls_pdate-high DATE = USER }| ) ).

  CALL FUNCTION 'REUSE_ALV_COMMENTARY_WRITE'
    EXPORTING
      it_list_commentary = lt_comment.

ENDFORM.
