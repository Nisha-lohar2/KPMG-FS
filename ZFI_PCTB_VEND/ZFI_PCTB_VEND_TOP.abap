*&---------------------------------------------------------------------*
*& Include          ZFI_PCTB_VEND_TOP
*&---------------------------------------------------------------------*
*& Global declarations - Vendor Trial Balance (Profit Center wise)
*&
*& FS Object ID 329 - FI Vendor Trial Balance
*&   Added : GSBER (Business Area / "Plant") and
*&           REGIO (Region from CEPC / "State")
*&---------------------------------------------------------------------*

TABLES: ekko, faglflexa, cepc.

TYPES: BEGIN OF ty_vendor_n,
         lifnr TYPE lfa1-lifnr,
         name1 TYPE lfa1-name1,
       END OF ty_vendor_n,

       BEGIN OF ty_vendor,
         lifnr TYPE lfb1-lifnr,
         bukrs TYPE lfb1-bukrs,
       END OF ty_vendor,

       BEGIN OF ty_report,
         bukrs TYPE bukrs,
         lifnr TYPE lifnr,
         belnr TYPE belnr_d,
         gjahr TYPE gjahr,
         buzei TYPE buzei,
       END OF ty_report,

       "! Profit center -> region, read from profit center master (CEPC)
       BEGIN OF ty_prctr_regio,
         prctr TYPE cepc-prctr,
         regio TYPE cepc-regio,
       END OF ty_prctr_regio,

       "! Document key used to read the G/L line items in one go
       BEGIN OF ty_doc_key,
         rbukrs TYPE faglflexa-rbukrs,
         ryear  TYPE faglflexa-ryear,
         docnr  TYPE faglflexa-docnr,
         buzei  TYPE faglflexa-buzei,
       END OF ty_doc_key,

       "! Component order must match the SELECT list in GET_GL_ITEMS
       BEGIN OF ty_data,
         rbukrs TYPE faglflexa-rbukrs,
         ryear  TYPE faglflexa-ryear,
         docnr  TYPE faglflexa-docnr,
         buzei  TYPE faglflexa-buzei,
         prctr  TYPE faglflexa-prctr,
         gsber  TYPE faglflexa-rbusa,
         drcrk  TYPE faglflexa-drcrk,
         hsl    TYPE faglflexa-hsl,
       END OF ty_data,

       "! One aggregation input line (vendor / profit center / business area)
       BEGIN OF ty_assign,
         lifnr TYPE lfa1-lifnr,
         name1 TYPE lfa1-name1,
         prctr TYPE faglflexa-prctr,
         gsber TYPE faglflexa-rbusa,
         regio TYPE cepc-regio,
         hsl   TYPE faglflexa-hsl,
       END OF ty_assign,

       BEGIN OF ty_final,
         lifnr         TYPE lfa1-lifnr,
         name1         TYPE lfa1-name1,
         prctr         TYPE faglflexa-prctr,
         gsber         TYPE faglflexa-rbusa,
         regio         TYPE cepc-regio,
         open_balance  TYPE faglflexa-hsl,
         debit         TYPE faglflexa-hsl,
         credit        TYPE faglflexa-hsl,
         close_balance TYPE faglflexa-hsl,
       END OF ty_final.

TYPES: tt_vendor_n TYPE HASHED TABLE OF ty_vendor_n
                        WITH UNIQUE KEY lifnr,
       tt_regio    TYPE HASHED TABLE OF ty_prctr_regio
                        WITH UNIQUE KEY prctr,
       tt_doc_key  TYPE SORTED TABLE OF ty_doc_key
                        WITH UNIQUE KEY rbukrs ryear docnr buzei,
       "! Non-unique: with document splitting one line item can carry
       "! several profit center / business area assignments.
       tt_data     TYPE SORTED TABLE OF ty_data
                        WITH NON-UNIQUE KEY rbukrs ryear docnr buzei,
       tt_balance  TYPE HASHED TABLE OF ty_final
                        WITH UNIQUE KEY lifnr prctr gsber,
       tt_final    TYPE STANDARD TABLE OF ty_final WITH EMPTY KEY,
       tt_bapi_itm TYPE STANDARD TABLE OF bapi3008_2 WITH EMPTY KEY,
       tt_prctr_r  TYPE RANGE OF faglflexa-prctr.

DATA: go_data TYPE REF TO data.
FIELD-SYMBOLS: <lt_data> TYPE table.

DATA: gt_vendor_name TYPE tt_vendor_n,     " LFA1 vendor names
      gt_regio       TYPE tt_regio,        " CEPC profit center -> region
      gr_prctr       TYPE tt_prctr_r,      " region driven profit center filter
      gt_report      TYPE STANDARD TABLE OF ty_report WITH EMPTY KEY,
      gt_gl          TYPE tt_data,         " FAGLFLEXA line items
      gt_opening_b   TYPE tt_bapi_itm,     " open items at period start - 1
      gt_closing_b   TYPE tt_bapi_itm,     " open items at period end
      gt_balance     TYPE tt_balance,      " aggregation buffer
      gt_final       TYPE tt_final.        " ALV output

DATA: gt_fieldcat TYPE slis_t_fieldcat_alv,
      gs_layout   TYPE slis_layout_alv.

"! Result columns addressed dynamically by the aggregation routines
CONSTANTS: BEGIN OF gc_col,
             open  TYPE fieldname VALUE 'OPEN_BALANCE',
             close TYPE fieldname VALUE 'CLOSE_BALANCE',
             debit TYPE fieldname VALUE 'DEBIT',
             credi TYPE fieldname VALUE 'CREDIT',
           END OF gc_col.

CONSTANTS: gc_ledger TYPE faglflexa-rldnr VALUE '0L',
           gc_debit  TYPE faglflexa-drcrk VALUE 'S',
           gc_credit TYPE faglflexa-drcrk VALUE 'H'.
