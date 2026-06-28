import 'package:flutter/widgets.dart';

/// Strong right-to-left scripts: Hebrew (0590–05FF), Arabic + Supplement +
/// Extended-A (0600–06FF, 0750–077F, 08A0–08FF), Syriac (0700–074F), Thaana
/// (0780–07BF), and the Arabic presentation forms (FB1D–FDFF, FE70–FEFF).
final RegExp _rtlChar = RegExp(
  '[֐-׿؀-ۿ܀-ݏݐ-ݿހ-޿'
  'ࢠ-ࣿיִ-﷿ﹰ-﻿]',
);

/// Strong left-to-right letters we care about: Latin (incl. accents), Cyrillic,
/// CJK, Kana, and Hangul. Used only to break ties for mixed strings.
final RegExp _ltrChar = RegExp(
  '[A-Za-zÀ-ɏЀ-ӿ一-鿿぀-ヿ가-힯]',
);

/// Whether [text] should be laid out right-to-left.
///
/// Content-based (not language-code based) on purpose: the source language is
/// often auto-detected ("Any"), and conversation/quick modes show two languages
/// at once — so each block must decide its own direction from what it contains.
/// A block is RTL when it has RTL characters and they are at least as numerous
/// as the LTR letters (so a stray Latin word inside an Arabic sentence, or a
/// lone Arabic name inside an English sentence, resolves to the dominant side).
bool isRtlText(String text) {
  final rtl = _rtlChar.allMatches(text).length;
  if (rtl == 0) return false;
  return rtl >= _ltrChar.allMatches(text).length;
}

/// The [TextDirection] a block of [text] should render with.
TextDirection directionOf(String text) =>
    isRtlText(text) ? TextDirection.rtl : TextDirection.ltr;
