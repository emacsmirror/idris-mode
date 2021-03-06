# Changes

This file documents the user-interface changes in idris-mode, starting
with release 0.9.19.

## 1.0

+ Idris mode has been brought uptodate with Idris1
+ Basic navigation commands added

### Fixes

+ Fix regular expression when matching on `.ipkg` extensions
+ Prevent completion-error when identifier is at beginning of buffer
+ Internal code changes
+ Better development testing with travis

### UX

+ `C-u C-c C-l` flags the buffer as dirty
+ Add images back into the repl
+ Disable the Idris event log by default
+ When Idris returns no proof search, do not delete the metavas
+ Remove references to idris-event-buffer-name when idris-log-events is nil
+ Fix idris-simple-indent-backtab
+ Give operator chars "." syntax and improve idris-thing-at-point
+ Conditional semantic faces for light/dark backgrounds

### Documentation

+ General fix ups
+ Document a way of reducing excessive frames


## 2016 Feb 29

 * It is possible to customize what happens to the focus of the current
   window when the type checking is performed and type errors are detected,
   now the user can choose between two options: 1) the current window stays
   focused or 2) the focus goes to the `*idris-notes*` buffer.
   The  true or false value of the variable
   `idris-stay-in-current-window-on-compiler-error` controls this behaviour.

## 0.9.19

 * The variable `idris-packages` has been renamed to
   `idris-load-packages`. If you have this as a file variable, please
   rename it.
 * The faces `idris-quasiquotation-face` and
   `idris-antiquotation-face` have been added, for compiler-supported
   highlighting of quotations. They are, by default, without
   properties, but they can be customized if desired.
 * Active terms can now be right-clicked. The old "show term widgets"
   command is no longer necessary, and will be removed in an upcoming
   release.
 * The case split command can be run on a hole, causing it to be filled
   with a prototype for a case split expression. Case-splitting a pattern
   variable has the same effect as before.
 * There is support for the interactive elaborator, which may replace
   the interactive prover in a future release. To use this, set
   `idris-enable-elab-prover` to non-`nil`.
