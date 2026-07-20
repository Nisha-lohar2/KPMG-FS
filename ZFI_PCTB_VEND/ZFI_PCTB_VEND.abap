*&---------------------------------------------------------------------*
*& Report ZFI_PCTB_VEND
*&---------------------------------------------------------------------*
*& Vendor Trial Balance - Profit Center / Plant (Business Area) /
*& State (Region) wise.
*&
*& FS Object ID 329 - FI Vendor Trial Balance (Astral Limited, UDAY)
*&---------------------------------------------------------------------*
REPORT zfi_pctb_vend.

INCLUDE zfi_pctb_vend_top.
INCLUDE zfi_pctb_vend_ss.
INCLUDE zfi_pctb_vend_imp.

START-OF-SELECTION.

  PERFORM authorization_check.
  PERFORM get_data.
  PERFORM fill_data.
  PERFORM fcat.
  PERFORM display.
