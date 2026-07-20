*&---------------------------------------------------------------------*
*& Include          ZFI_PCTB_VEND_SS
*&---------------------------------------------------------------------*
*& Selection screen
*&
*& FS Object ID 329: existing fields stay unchanged, S_GSBER ("Plant")
*& and S_REGIO ("State") are inserted between profit center and
*& document date as per the proposed screen layout.
*&
*& Selection texts to be maintained (SE38 -> Goto -> Text elements):
*&   S_BUKRS  Company Code
*&   S_LIFNR  Supplier
*&   S_PRCTR  Profit Center
*&   S_GSBER  Plant (Business Area)
*&   S_REGIO  State (Region)
*&   S_PDATE  Document Date
*&   TEXT-001 Selection Criteria
*&---------------------------------------------------------------------*

SELECTION-SCREEN BEGIN OF BLOCK blck WITH FRAME TITLE text-001.
SELECT-OPTIONS: s_bukrs FOR ekko-bukrs OBLIGATORY NO INTERVALS NO-EXTENSION,
                s_lifnr FOR ekko-lifnr,
                s_prctr FOR faglflexa-prctr,
                s_gsber FOR faglflexa-rbusa,
                s_regio FOR cepc-regio,
                s_pdate FOR ekko-bedat OBLIGATORY NO-EXTENSION.
SELECTION-SCREEN END OF BLOCK blck.
