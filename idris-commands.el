;;; idris-commands.el --- Commands for Emacs passed to Idris -*- lexical-binding: t -*-

;; Copyright (C) 2013 Hannes Mehnert

;; Author: Hannes Mehnert <hannes@mehnert.org> and David Raymond Christiansen <david@davidchristiansen.dk>

;; License:
;; Inspiration is taken from SLIME/DIME (http://common-lisp.net/project/slime/) (https://github.com/dylan-lang/dylan-mode)
;; Therefore license is GPL

;; This file is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;; This file is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING. If not, write to
;; the Free Software Foundation, Inc., 59 Temple Place - Suite 330,
;; Boston, MA 02111-1307, USA.

;;; Code:

(require 'idris-core)
(require 'idris-settings)
(require 'inferior-idris)
(require 'idris-repl)
(require 'idris-warnings)
(require 'idris-compat)
(require 'idris-info)
(require 'idris-tree-info)
(require 'idris-log)
(require 'idris-ipkg-mode)
(require 'idris-warnings-tree)
(require 'idris-hole-list)
(require 'idris-prover)
(require 'idris-common-utils)
(require 'idris-syntax)
(require 'idris-highlight-input)

(require 'cl-lib)
(require 'thingatpt)

(defvar-local idris-load-to-here nil
  "The maximum position to load.")

(defun idris-make-dirty ()
  "Mark an Idris buffer as dirty and remove the loaded region."
  (setq idris-buffer-dirty-p t)
  (when idris-loaded-region-overlay
    (delete-overlay idris-loaded-region-overlay))
  (setq idris-loaded-region-overlay nil))

(defun idris-make-clean ()
  (setq idris-buffer-dirty-p nil))

(defun idris-current-buffer-dirty-p ()
  "Check whether the current buffer's most recent version is loaded."
  (or idris-buffer-dirty-p
      (not (equal (current-buffer)
                  idris-currently-loaded-buffer))
      ;; for when we load the whole buffer
      (and (not idris-load-to-here) (not idris-loaded-region-overlay))
      ;; true when the place to load is outside the loaded region - extend region!
      (and idris-loaded-region-overlay
           idris-load-to-here
           (> (marker-position idris-load-to-here)
              (overlay-end idris-loaded-region-overlay)))))

(defun idris-position-loaded-p (pos)
  (and idris-loaded-region-overlay
       (member idris-loaded-region-overlay (overlays-at pos))
       t))

(defun idris-ensure-process-and-repl-buffer ()
  "Ensure that an Idris process is running and the Idris REPL buffer exists."
  (idris-run)
  (idris-repl-buffer))

(defun idris-switch-working-directory (new-working-directory)
  "Switch working directory to NEW-WORKING-DIRECTORY."
  (unless (string= idris-process-current-working-directory new-working-directory)
    (idris-ensure-process-and-repl-buffer)
    (let* ((path (if (> idris-protocol-version 1)
                     (prin1-to-string new-working-directory)
                   new-working-directory))
           (eval-result (idris-eval `(:interpret ,(concat ":cd " path))))
           (result-msg (or (car-safe eval-result) "")))
      ;; Check if the message from Idris contains the new directory path.
      ;; Before check drop the last character (slash) in the path
      ;; as the message does not include it.
      (if (string-match-p (file-truename (substring new-working-directory 0 -1))
                          result-msg)
          (progn
            (message result-msg)
            (setq idris-process-current-working-directory new-working-directory))
        (error "Failed to switch the working directory %s" eval-result)))))

(define-obsolete-function-alias 'idris-list-holes-on-load 'idris-list-holes "2022-12-15"
  "Use the user's settings from customize to determine whether to list the holes.")

(defun idris-possibly-make-dirty (_beginning _end _length)
  "Make the buffer dirty."
  (idris-make-dirty))
  ;; If there is a load-to-here marker and a currently loaded region, only
  ;; make the buffer dirty when the change overlaps the loaded region.
  ;; (if (and idris-load-to-here idris-loaded-region-overlay)
  ;;     (when (member idris-loaded-region-overlay
  ;;                   (overlays-in beginning end))
  ;;       (idris-make-dirty))
  ;;   ;; Otherwise just make it dirty.
  ;; (idris-make-dirty)))

(defun idris-update-loaded-region (fc)
  (if fc
      (let* ((end (assoc :end fc))
             (line (cadr end))
             (col (cl-caddr end)))
        (when (overlayp idris-loaded-region-overlay)
          (delete-overlay idris-loaded-region-overlay))
        (with-current-buffer idris-currently-loaded-buffer
          (setq idris-loaded-region-overlay
                (make-overlay (point-min)
                              (save-excursion (goto-char (point-min))
                                              (forward-line (1- line))
                                              (move-to-column (1- col))
                                              (point))
                              (current-buffer)))
          (overlay-put idris-loaded-region-overlay 'face 'idris-loaded-region-face)))

    ;; HACK: Some versions of Idris don't properly return a span for
    ;; some modules, returning () instead. Remove this (and the
    ;; surrounding (if fc)) after Idris 0.9.17, which contains a fix.
    (idris-update-loaded-region
     `((:filename ,(cdr (idris-filename-to-load)))
       (:start 1 1)
       ,`(:end ,(idris-get-line-num (point-max)) 1)))))

(defun idris-load-to (&optional pos)
  (when (not pos) (setq pos (point)))
  (setq idris-load-to-here (copy-marker pos t))
  (setq overlay-arrow-position (copy-marker (save-excursion
                                              (goto-char pos)
                                              (line-beginning-position))
                                            nil)))

(defun idris-no-load-to ()
  (setq idris-load-to-here nil)
  (setq overlay-arrow-position nil))

(defun idris-load-forward-line (&optional nlines)
  (interactive)
  (when idris-load-to-here
    (save-excursion
      (goto-char idris-load-to-here)
      (forward-line nlines)
      (idris-make-dirty)
      (idris-load-to (point)))))

(defun idris-load-backward-line ()
  (interactive)
  (idris-load-forward-line -1))

(defun idris-filename-to-load ()
  "Compute the working directory and filename to load in Idris.
Returning these as a cons."
  (let* ((ipkg-file (car-safe (idris-find-file-upwards "ipkg")))
         (file-name (buffer-file-name))
         (work-dir (directory-file-name (idris-file-name-parent-directory (or ipkg-file file-name))))
         (source-dir (or (idris-ipkg-find-src-dir) work-dir)))
    ;; TODO: Update once https://github.com/idris-lang/Idris2/issues/3310 is resolved
    (if (> idris-protocol-version 1)
        (cons work-dir (file-relative-name file-name work-dir))
      (cons source-dir (file-relative-name file-name source-dir)))))

(defun idris-load-file (&optional set-line)
  "Pass the current buffer's file to the inferior Idris process.
A prefix argument SET-LINE forces loading but only up to the current line."
  (interactive "p")
  (save-buffer)
  (idris-ensure-process-and-repl-buffer)
  (when (and set-line (= set-line 4))
    (idris-load-to (point))
    (idris-make-dirty))
  (when (and set-line (= set-line 16)) (idris-no-load-to))
  (if (buffer-file-name)
      (when (idris-current-buffer-dirty-p)
        (when idris-prover-currently-proving
          (if (y-or-n-p (format "%s is open in the prover. Abandon and load? "
                                idris-prover-currently-proving))
              (idris-prover-abandon)
            (signal 'quit nil)))
        ;; Remove warning overlays
        (idris-warning-reset-all)
        ;; Clear the contents of the compiler notes buffer, if it exists
        (when (get-buffer idris-notes-buffer-name)
          (with-current-buffer idris-notes-buffer-name
            (let ((inhibit-read-only t)) (erase-buffer))))
        ;; Actually do the loading
        (let* ((dir-and-fn (idris-filename-to-load))
               (fn (cdr dir-and-fn))
               (srcdir (car dir-and-fn))
               (idris-semantic-source-highlighting (idris-buffer-semantic-source-highlighting)))
          (setq idris-currently-loaded-buffer nil)
          (idris-switch-working-directory srcdir)
          (idris-delete-ibc t) ;; delete the ibc to avoid interfering with partial loads
          (idris-toggle-semantic-source-highlighting)
          (idris-eval-async
           (if idris-load-to-here
               `(:load-file ,fn ,(idris-get-line-num idris-load-to-here))
             `(:load-file ,fn))
           (lambda (result)
             (pcase result
               (`(:highlight-source ,hs)
                (idris-highlight-source-file hs))
               (_ (idris-make-clean)
                  (idris-update-options-cache)
                  (setq idris-currently-loaded-buffer (current-buffer))
                  (when (member 'warnings-tree idris-warnings-printing)
                    (idris-list-compiler-notes))
                  (run-hooks 'idris-load-file-success-hook)
                  (idris-update-loaded-region result))))
           (lambda (_condition)
             (when (member 'warnings-tree idris-warnings-printing)
               (idris-list-compiler-notes))))))
    (error "Cannot find file for current buffer")))

(defun idris-view-compiler-log ()
  "Jump to the log buffer, if it is open."
  (interactive)
  (let ((buffer (get-buffer idris-log-buffer-name)))
    (if buffer
        (pop-to-buffer buffer)
      (message "No Idris compiler log is currently open"))))

(defun idris-next-error ()
  "Jump to the next error overlay in the buffer."
  (interactive)
  (let ((warnings-forward (sort (cl-remove-if-not #'(lambda (w) (> (overlay-start w) (point))) idris-warnings)
                                #'(lambda (w1 w2) (<= (overlay-start w1) (overlay-start w2))))))
    (if warnings-forward
        (goto-char (overlay-start (car warnings-forward)))
      (error "No warnings or errors until end of buffer"))))

(defun idris-previous-error ()
  "Jump to the previous error overlay in the buffer."
  (interactive)
  (let ((warnings-backward (sort (cl-remove-if-not #'(lambda (w) (< (overlay-end w) (point))) idris-warnings)
                                 #'(lambda (w1 w2) (>= (overlay-end w1) (overlay-end w2))))))
    (if warnings-backward
        (goto-char (overlay-end (car warnings-backward)))
      (error "No warnings or errors until beginning of buffer"))))

(defun idris-load-file-sync ()
  "Pass the current buffer's file synchronously to the inferior Idris process.
This sets the load position to point, if there is one."
  (save-buffer)
  (idris-ensure-process-and-repl-buffer)
  (if (buffer-file-name)
      (unless (idris-position-loaded-p (point))
        (idris-warning-reset-all)
        (when (and idris-load-to-here
                   (< (marker-position idris-load-to-here) (point)))
          (idris-load-to (point)))
        (let* ((dir-and-fn (idris-filename-to-load))
               (fn (cdr dir-and-fn))
               (srcdir (car dir-and-fn)))
          (setq idris-currently-loaded-buffer nil)
          (idris-switch-working-directory srcdir)
          (let ((result
                 (idris-eval
                  (if idris-load-to-here
                      `(:load-file ,fn ,(idris-get-line-num idris-load-to-here))
                    `(:load-file ,fn)))))
            (idris-update-options-cache)
            (setq idris-currently-loaded-buffer (current-buffer))
            (idris-make-clean)
            (idris-update-loaded-region (car result)))))
    (error "Cannot find file for current buffer")))



(defun idris-info-for-name (command name)
  "Pass to Idris compiler COMMAND with NAME as argument and display the result."
  (let* ((ty (idris-eval (list command name)))
         (result (car ty))
         (formatting (cdr ty)))
    (idris-show-info (format "%s" result) formatting)))


(defun idris-type-at-point (thing)
  "Display the type of the THING at point, considered as a global variable."
  (interactive "P")
  (let ((name (if thing (read-string "Check: ")
                (idris-name-at-point))))
    (when (idris-current-buffer-dirty-p)
      (idris-load-file-sync))
    (when name
      (idris-info-for-name :type-of name))))

(defun idris--print-definition-of-name (name)
  "Fetch from the Idris compiler and display the definition of the NAME."
  (if (>=-protocol-version 2 1)
      (idris-info-for-name :interpret (concat ":printdef " name))
    (idris-info-for-name :print-definition name)))

(defun idris-print-definition-of-name-at-point (name)
  "Display the definition of the function or type of the NAME at point.

Idris 2 as of 05/01/2023 does not yet fully support
printing definition of a type at point."
  (interactive "P")
  (let ((name* (if name
                   (read-string "Print definition: ")
                 (idris-name-at-point))))
    (when name*
      (idris--print-definition-of-name name*))))

(define-obsolete-function-alias 'idris-print-definition-of-name 'idris-print-definition-of-name-at-point "2023-01-05")

(defun idris-who-calls-name (name)
  "Show the callers of NAME in a tree."
  (let* ((callers (idris-eval `(:who-calls ,name)))
         (roots (mapcar #'(lambda (c) (idris-caller-tree c :who-calls))
                        (car callers))))
    (if (not (null roots))
        (idris-tree-info-show-multiple roots "Callers")
      (message "The name %s was not found." name))
    nil))

(defun idris-who-calls-name-at-point (thing)
  (interactive "P")
  (let ((name (if thing (read-string "Who calls: ")
                (idris-name-at-point))))
    (when name
      (idris-who-calls-name name))))

(defun idris-name-calls-who (name)
  "Show the callees of NAME in a tree."
  (let* ((callees (idris-eval `(:calls-who ,name)))
         (roots (mapcar #'(lambda (c) (idris-caller-tree c :calls-who)) (car callees))))
    (if (not (null roots))
        (idris-tree-info-show-multiple roots "Callees")
      (message "The name %s was not found." name))
    nil))

(defun idris-name-calls-who-at-point (thing)
  (interactive "P")
  (let ((name (if thing (read-string "Calls who: ")
                (idris-name-at-point))))
    (when name
      (idris-name-calls-who name))))

(defun idris-browse-namespace (namespace)
  "Show the contents of NAMESPACE in a tree info buffer."
  (interactive
   ;; Compute a default namespace for the prompt based on the text
   ;; annotations at point when called interactively. Overlays are
   ;; preferred over text properties.
   (let ((default
           (or (cl-some #'(lambda (o) (overlay-get o 'idris-namespace))
                        (overlays-at (point)))
               (get-text-property (point) 'idris-namespace))))
     (list (read-string "Browse namespace: " default))))
  (idris-tree-info-show (idris-namespace-tree namespace)
                        "Browse Namespace"))

(defun idris-caller-tree (caller cmd)
  "Display a tree from an IDE CALLER list.
Using CMD lazily retrieve a few levels at a time from Idris compiler."
  (pcase caller
    (`((,name ,highlight) ,children)
     (make-idris-tree
      :item name
      :highlighting highlight
      :collapsed-p t
      :kids (lambda ()
              (cl-mapcan #'(lambda (child)
                             (let ((child-name (caar (idris-eval `(,cmd ,(car child))))))
                               (if child-name
                                   (list (idris-caller-tree child-name cmd))
                                 nil)))
                         children))
      :preserve-properties '(idris-tt-tree)))
    (_ (error "Failed to make tree from %s" caller))))

(defun idris-namespace-tree (namespace &optional recursive)
  "Create a tree of the contents of NAMESPACE.
Lazily retrieve children when RECURSIVE is non-nil."
  (cl-flet*
      ;; Show names as childless trees with decorated roots
      ((name-tree (n) (make-idris-tree :item (car n)
                                       :highlighting (cadr n)
                                       :kids nil
                                       :preserve-properties '(idris-tt-tree)))
       ;; The children of a tree are the namespaces followed by the names.
       (get-children (sub-namespaces names)
                     (append (mapcar #'(lambda (ns)
                                         (idris-namespace-tree ns t))
                                     sub-namespaces)
                             (mapcar #'name-tree names))))
    (let ((highlight `((0 ,(length namespace)
                          ((:decor :namespace)
                           (:namespace ,namespace))))))
      (if recursive
          ;; In the recursive case, generate a collapsed tree and lazily
          ;; get the contents as expansion is requested
          (make-idris-tree
           :item namespace
           :highlighting highlight
           :collapsed-p t
           :kids (lambda ()
                   (pcase (idris-eval `(:browse-namespace ,namespace))
                     (`((,sub-namespaces ,names . ,_))
                      (get-children sub-namespaces names))
                     (_ nil)))
           :preserve-properties '(idris-tt-term))
        ;; In the non-recursive case, generate an expanded tree with the
        ;; first level available, but only if the namespace actually makes
        ;; sense
        (pcase (idris-eval `(:browse-namespace ,namespace))
          (`((,sub-namespaces ,names . ,_))
           (make-idris-tree
            :item namespace
            :highlighting highlight
            :collapsed-p nil
            :kids (get-children sub-namespaces names)
            :preserve-properties '(idris-tt-term)))
          (_ (error "Invalid namespace %s" namespace)))))))

(defun idris-newline-and-indent ()
  "Indent a new line like the current one by default."
  (interactive)
  (let ((indent ""))
    (save-excursion
      (move-beginning-of-line nil)
      (when (looking-at (if (idris-lidr-p) "^\\(>\\s-*\\)" "\\(\\s-*\\)"))
        (setq indent (match-string 1))))
    (insert "\n" indent)))

(defun idris-delete-forward-char (n &optional killflag)
  "Delete the following N characters (previous if N is negative).
If the current buffer is in `idris-mode' and the file being
edited is a literate Idris file, deleting the end of a line will
take into account bird tracks.  If Transient Mark mode is
enabled, the mark is active, and N is 1, delete the text in the
region and deactivate the mark instead.
To disable this, set variable `delete-active-region' to nil.

Optional second arg KILLFLAG non-nil means to kill (save in kill
ring) instead of delete.  Interactively, N is the prefix arg, and
KILLFLAG is set if N was explicitly specified."
  (interactive "p\nP")
  (unless (integerp n)
    (signal 'wrong-type-argument (list 'integerp n)))
  (cond
   ;; Under the circumstances that `delete-forward-char' does something
   ;; special, delegate to it. This was discovered by reading the source to
   ;; it.
   ((and (use-region-p)
         delete-active-region
         (= n 1))
    (call-interactively 'delete-forward-char n killflag))
   ;; If in idris-mode and editing an LIDR file and at the end of a line,
   ;; then delete the newline and a leading >, if it exists
   ((and (eq major-mode 'idris-mode)
         (idris-lidr-p)
         (= n 1)
         (eolp))
    (delete-char 1 killflag)
    (when (and (not (eolp)) (equal (following-char) ?\>))
      (delete-char 1 killflag)
      (when (and (not (eolp)) (equal (following-char) ?\ ))
        (delete-char 1 killflag))))
   ;; Nothing special to do - delegate to `delete-char', just as
   ;; `delete-forward-char' does
   (t (delete-char 1 killflag))))


(defun idris-apropos (what)
  "Look up WHAT in names, type signatures, and docstrings."
  (interactive "sSearch Idris docs for: ")
  (idris-info-for-name :apropos what))

(defun idris-type-search (what)
  "Search the Idris libraries for WHAT by fuzzy type matching."
  (interactive "sSearch for type: ")
  (idris-info-for-name :interpret (concat ":search " what)))

(defun idris-docs-at-point (thing)
  "Display the internal documentation for the THING (name at point).
Considered as a global variable"
  (interactive "P")
  (let ((name (if thing (read-string "Docs: ")
                (idris-name-at-point))))
    (when name
      (idris-info-for-name :docs-for name))))

(defun idris-eldoc-lookup ()
  "Return Eldoc string associated with the thing at point."
  (get-char-property (point) 'idris-eldoc))

(defun idris-pretty-print ()
  "Get a term or definition pretty-printed by Idris.
Useful for writing papers or slides."
  (interactive)
  (let ((what (read-string "What should be pretty-printed? "))
        (fmt (completing-read "What format? " '("html", "latex") nil t nil nil "latex"))
        (width (read-string "How wide? " nil nil "80")))
    (if (<= (string-to-number width) 0)
        (error "Width must be positive")
      (if (< (length what) 1)
          (error "Nothing to pretty-print")
        (let ((text (idris-eval `(:interpret ,(concat ":pprint " fmt " " width " " what)))))
          (with-idris-info-buffer
            (insert (car text))
            (goto-char (point-min))
            (re-search-forward (if (string= fmt "latex")
                                   "% START CODE\n"
                                 "<!-- START CODE -->"))
            (push-mark nil t)
            (re-search-forward (if (string= fmt "latex")
                                   "% END CODE\n"
                                 "<!-- END CODE -->"))
            (goto-char (match-beginning 0))
            (copy-region-as-kill (mark) (point))
            (message "Code copied to kill ring")))))))


(defun idris-case-split ()
  "Case split the pattern variable at point."
  (interactive)
  (let ((what (idris-thing-at-point)))
    (when (car what)
      (idris-load-file-sync)
      (let ((result (car (idris-eval `(:case-split ,(cdr what) ,(car what)))))
            (initial-position (point)))
        (if (<= (length result) 2)
            (message "Can't case split %s" (car what))
          (delete-region (line-beginning-position) (line-end-position))
          (if (> idris-protocol-version 1)
              (insert (substring result 0 (length result)))
            (insert (substring result 0 (1- (length result)))))
          (goto-char initial-position))))))

(defun idris-make-cases-from-hole ()
  "Make a case expression from the metavariable at point."
  (interactive)
  (let ((what (idris-thing-at-point)))
    (when (car what)
      (idris-load-file-sync)
      (let ((result (car (idris-eval `(:make-case ,(cdr what) ,(car what))))))
        (if (<= (length result) 2)
            (message "Can't make cases from %s" (car what))
          (delete-region (line-beginning-position) (line-end-position))
          (if (> idris-protocol-version 1)
              (insert (substring result 0 (length result)))
            (insert (substring result 0 (1- (length result)))))
          (search-backward "_ of\n"))))))

(defun idris-case-dwim ()
  "If point is on a hole name, make it into a case expression.
Otherwise, case split as a pattern variable."
  (interactive)
  (cond
   ((looking-at-p "\\?[a-zA-Z_]+") ;; point at "?" in ?hole_rs1
    (forward-char) ;; move from "?" for idris-make-cases-from-hole to work correctly
    (idris-make-cases-from-hole))
   ((or (and (char-equal (char-before) ??) ;; point at "h" in ?hole_rs1
             (looking-at-p "[a-zA-Z_]+"))
        (looking-back "\\?[a-zA-Z0-9_]+" nil)) ;; point somewhere afte "?h" in ?hole_rs1
    (idris-make-cases-from-hole))
   (t (idris-case-split))))

(defun idris-add-clause (proof)
  "Add clauses to the declaration at point."
  (interactive "P")
  (let ((what (idris-thing-at-point))
        (command (if proof :add-proof-clause :add-clause)))
    (when (car what)
      (idris-load-file-sync)
      (let ((result (string-trim-left (car (idris-eval `(,command ,(cdr what) ,(car what))))))
            final-point
            (prefix (save-excursion        ; prefix is the indentation to insert for the clause
                      (goto-char (point-min))
                      (forward-line (1- (cdr what)))
                      (goto-char (line-beginning-position))
                      (re-search-forward "\\(^>?\\s-*\\)" nil t)
                      (or (match-string 1) ""))))
        ;; Go forward until we get to a line with equal or less indentation to
        ;; the type declaration, or the end of the buffer, and insert the
        ;; result
        (goto-char (line-beginning-position))
        (forward-line)
        (while (and (not (eobp))
                    (progn (goto-char (line-beginning-position))
                           ;; this will be true if we're looking at the prefix
                           ;; with extra whitespace
                           (looking-at-p (concat prefix "\\s-+"))))
          (forward-line))
        (insert prefix)
        (setq final-point (point)) ;; Save the location of the start of the clause
        (insert result)
        (newline)
        (goto-char final-point))))) ;; Put the cursor on the start of the inserted clause

(defun idris-add-missing ()
  "Add missing cases."
  (interactive)
  (let ((what (idris-thing-at-point)))
    (when (car what)
      (idris-load-file-sync)
      (let ((result (car (idris-eval `(:add-missing ,(cdr what) ,(car what))))))
        (forward-line 1)
        (insert result)))))

(defun idris-make-with-block ()
  "Add with block."
  (interactive)
  (let ((what (idris-thing-at-point)))
    (when (car what)
      (idris-load-file-sync)
      (let ((result (car (idris-eval `(:make-with ,(cdr what) ,(car what))))))
        (beginning-of-line)
        (kill-line)
        (insert result)))))

(defun idris-make-lemma ()
  "Extract lemma from hole."
  (interactive)
  (let ((what (idris-thing-at-point)))
    (when (car what)
      (idris-load-file-sync)
      (let* ((result (car (idris-eval `(:make-lemma ,(cdr what) ,(car what)))))
             (lemma-type (car result)))
        ;; There are two cases here: either a ?hole, or the {name} of a provisional defn.
        (cond ((equal lemma-type :metavariable-lemma)
               (let ((lem-app (cadr (assoc :replace-metavariable (cdr result))))
                     (type-decl (cadr (assoc :definition-type (cdr result)))))
                 ;; replace the hole
                 ;; assume point is on the hole right now!
                 (while (not (looking-at "\\?[a-zA-Z0-9?_]+"))
                   (backward-char 1))
                 ;; now we're on the ? - we just matched the metavar
                 (replace-match lem-app)

                 ;; now we add the type signature - search upwards for the current
                 ;; signature, then insert before it
                 (re-search-backward (if (idris-lidr-p)
                                         "^\\(>\\s-*\\)\\(([^)]+)\\|[a-zA-Z_0-9]+\\)\\s-*:"
                                       "^\\(\\s-*\\)\\(([^)]+)\\|[a-zA-Z_0-9]+\\)\\s-*:"))
                 (let ((indentation (match-string 1))
                       end-point)
                   (beginning-of-line)

                   ;; make sure we are above the documentation string
                   (forward-line -1)
                   (while (and (not (looking-at-p "^\\s-*$"))
                               (not (equal (point) (point-min)))
                               (or (looking-at-p "^|||") (looking-at-p "^--")))
                     (forward-line -1))

                   ;; if we reached beginning of file
                   ;; add new line between the type signature and the lemma
                   (if (equal (point) (point-min))
                       (progn
                         (newline 1)
                         (forward-line -1))
                     ;; otherwise find first non empty line
                     (forward-line -1)
                     (when (looking-at-p "^.*\\S-.*$")
                       (forward-line 1)
                       (newline 1)))

                   (insert indentation)
                   (setq end-point (point))
                   (insert type-decl)
                   (newline 1)
                   ;; make sure point ends up ready to start a new pattern match
                   (goto-char end-point))))
              ((equal lemma-type :provisional-definition-lemma)
               (let ((clause (cadr (assoc :definition-clause (cdr result)))))
                 ;; Insert the definition just after the current definition
                 ;; This can either be before the next type definition or at the end of
                 ;; the buffer, if there is no next type definition
                 (let ((next-defn-point
                        (re-search-forward (if (idris-lidr-p)
                                               "^\\(>\\s-*\\)\\(([^)]+)\\|\\w+\\)\\s-*:"
                                             "^\\(\\s-*\\)\\(([^)]+)\\|\\w+\\)\\s-*:")
                                           nil t)))
                   (if next-defn-point ;; if we found a definition
                       (let ((indentation (match-string 1)) end-point)
                         (goto-char next-defn-point)
                         (beginning-of-line)
                         (insert indentation)
                         (setq end-point (point))
                         (insert clause)
                         (newline 2)
                         ;; make sure point is at new defn
                         (goto-char end-point))
                     ;; otherwise it goes at the end of the buffer
                     (let ((end (point-max)))
                       (goto-char end)
                       (insert clause)
                       (newline)
                       ;; make sure point is at new defn
                       (goto-char end)))))))))))

(defun idris-compile-and-execute ()
  "Execute the program in the current buffer."
  (interactive)
  (idris-load-file-sync)
  (if (>=-protocol-version 2 1)
      (let ((name (read-string "MExpression to compile & execute (default main): "
                               nil nil "main")))
        (idris-repl-eval-string (format ":exec %s" name) 0))
    (idris-eval '(:interpret ":exec"))))

(defun idris-replace-hole-with (expr)
  "Replace the hole under the cursor by some EXPR."
  (save-excursion
    (let ((start (progn (search-backward "?") (point)))
          (end (progn (forward-char) (search-forward-regexp "[^a-zA-Z0-9_']")
                      (backward-char) (point))))
      (delete-region start end))
    (insert expr)))

(defvar-local proof-region-start nil
  "The start position of the last proof region.")
(defvar-local proof-region-end nil
  "The end position of the last proof region.")

(defun idris-proof-search (&optional arg)
  "Invoke the proof search.
A plain prefix ARG causes the command to prompt for hints and recursion
 depth, while a numeric prefix argument sets the recursion depth directly."
  (interactive "P")
  (let ((hints (if (consp arg)
                   (split-string (read-string "Hints: ") "[^a-zA-Z0-9']")
                 '()))
        (depth (cond ((consp arg)
                      (let ((input (string-to-number (read-string "Search depth: "))))
                        (if (= input 0)
                            nil
                          (list input))))
                     ((numberp arg)
                      (list arg))
                     (t nil)))
        (what (idris-thing-at-point)))
    (when (car what)
      (idris-load-file-sync)

      (let ((result (car (if (> idris-protocol-version 1)
                             (idris-eval `(:proof-search ,(cdr what) ,(car what)))
                           (idris-eval `(:proof-search ,(cdr what) ,(car what) ,hints ,@depth))
                           ))))
        (if (string= result "")
            (error "Nothing found")
          (idris-replace-hole-with result))))))

(defun idris-proof-search-next ()
  "Replace the previous proof search result with the next one, if it exists.
Idris 2 only."
  (interactive)
  (if (not proof-region-start)
      (error "You must proof search first before looking for subsequent proof results")
    (let ((result (car (idris-eval `:proof-search-next))))
      (if (string= result "No more results")
          (message "No more results")
        (save-excursion
          (goto-char proof-region-start)
          (delete-region proof-region-start proof-region-end)
          (setq proof-region-start (point))
          (insert result)
          (setq proof-region-end (point)))))))

(defvar-local def-region-start nil)
(defvar-local def-region-end nil)

(defun idris-generate-def ()
  "Generate definition."
  (interactive)
  (let ((what (idris-thing-at-point)))
    (when (car what)
      (idris-load-file-sync)
      (let ((result (car (idris-eval `(:generate-def ,(cdr what) ,(car what)))))
            final-point
            (prefix (save-excursion
                      (goto-char (point-min))
                      (forward-line (1- (cdr what)))
                      (goto-char (line-beginning-position))
                      (re-search-forward "\\(^>?\\s-*\\)" nil t)
                      (or (match-string 1) ""))))
        (if (string= result "")
            (error "Nothing found")
          (goto-char (line-beginning-position))
          (forward-line)
          (while (and (not (eobp))
                      (progn (goto-char (line-beginning-position))
                             (looking-at-p (concat prefix "\\s-+"))))
            (forward-line))
          (insert prefix)
          (setq final-point (point))
          (setq def-region-start (point))
          (insert result)
          (setq def-region-end (point))
          (newline)
          (goto-char final-point)
;          (save-excursion
;            (forward-line 1)
;            (setq def-region-start (point))
;            (insert result)
;            (setq def-region-end (point)))
          )))))

(defun idris-generate-def-next ()
  "Replace the previous generated definition with next definition, if it exists.
Idris 2 only."
  (interactive)
  (if (not def-region-start)
      (error "You must program search first before looking for subsequent program results")
    (let ((result (car (idris-eval `:generate-def-next))))
      (if (string= result "No more results")
          (message "No more results")
        (save-excursion
          (goto-char def-region-start)
          (delete-region def-region-start def-region-end)
          (setq def-region-start (point))
          (insert result)
          (setq def-region-end (point)))))))

(defun idris-intro ()
  "Introduce the unambiguous constructor to use in this hole."
  (interactive)
  (let ((what (idris-thing-at-point)))
    (unless (car what)
      (error "Could not find a hole at point to refine by"))
    (idris-load-file-sync)
    (let ((results (car (idris-eval `(:intro ,(cdr what) ,(car what))))))
      (pcase results
        (`(,result) (idris-replace-hole-with result))
        (_ (idris-replace-hole-with (ido-completing-read "I'm hesitating between: " results)))))))

(defun idris-refine (name)
  "Refine by some NAME, without recursive proof search."
  (interactive "MRefine by: ")
  (let ((what (idris-thing-at-point)))
    (unless (car what)
      (error "Could not find a hole at point to refine by"))
    (idris-load-file-sync)
    (let ((result (car (idris-eval `(:refine ,(cdr what) ,(car what) ,name)))))
      (idris-replace-hole-with result))))

(defun idris-identifier-backwards-from-point ()
  (let (identifier-start
        (identifier-end (point))
        (failure (list nil nil nil)))
    (save-excursion
      (while (and (> (point) (point-min)) (idris-is-ident-char-p (char-before)))
        (backward-char)
        (setq identifier-start (point)))
      (if identifier-start
          (list (buffer-substring-no-properties identifier-start identifier-end)
                identifier-start
                identifier-end)
        failure))))

(defun idris-complete-symbol-at-point ()
  "Attempt to complete the symbol at point as a global variable.

This function does not attempt to load the buffer if it's not
already loaded, as a buffer awaiting completion is probably not
type-correct, so loading will fail."
  (if (not idris-process)
      nil
    (when idris-completion-via-compiler
      (cl-destructuring-bind (identifier start end) (idris-identifier-backwards-from-point)
        (when identifier
          (let ((result (car (idris-eval `(:repl-completions ,identifier)))))
            (cl-destructuring-bind (completions _partial) result
              (if (null completions)
                  nil
                (list start end completions
                      :exclusive 'no)))))))))

(defun idris-complete-keyword-at-point ()
  "Attempt to complete the symbol at point as an Idris keyword."
  (pcase-let* ((all-idris-keywords
                (append idris-keywords idris-definition-keywords))
               (`(,identifier ,start ,end)
                (idris-identifier-backwards-from-point)))
    (when identifier
      (let ((candidates (cl-remove-if-not
                         (apply-partially #'string-prefix-p identifier)
                         all-idris-keywords)))
        (if (null candidates)
            nil
          (list start end candidates
                :exclusive 'no))))))

(defun idris-list-holes ()
  "Get a list of currently open holes."
  (interactive)
  (when (idris-current-buffer-dirty-p)
    (idris-load-file-sync))
  (idris-hole-list-show (car (idris-eval '(:metavariables 80)))))

(defun idris-list-compiler-notes ()
  "Show the compiler notes in tree view."
  (interactive)
  (with-temp-message "Preparing compiler note tree..."
    (idris-compiler-notes-list-show (reverse idris-raw-warnings))))

(defun idris-kill-buffers ()
  (idris-warning-reset-all)
  (setq idris-currently-loaded-buffer nil)
  ;; not killing :events since it it tremendously useful for debuging
  (let ((bufs (list :connection :repl :proof-obligations :proof-shell :proof-script :log :info :notes :holes :tree-viewer)))
    (dolist (b bufs) (idris-kill-buffer b))))

(defun idris-remove-event-hooks ()
  "Remove Idris event hooks set after connection with Idris established."
  (dolist (h idris-event-hooks) (remove-hook 'idris-event-hooks h)))

(define-obsolete-function-alias 'idris-pop-to-repl 'idris-switch-to-repl "2022-12-28")

(defun idris-switch-to-last-idris-buffer ()
  "Switch to the last Idris buffer.
The default keybinding for this command is
the same as for command `idris-switch-to-repl',
so it is convenient to jump between Idris code and REPL.

Inspired by `cider-switch-to-last-clojure-buffer'
https://github.com/clojure-emacs/cider"
  (interactive)
  (if (derived-mode-p 'idris-repl-mode)
      (let ((idris-buffer (seq-find
                           (lambda (b) (eq 'idris-mode (buffer-local-value 'major-mode b)))
                           (buffer-list))))
        (if idris-buffer
            (pop-to-buffer idris-buffer `(display-buffer-reuse-window))
          (user-error "No Idris buffer found")))
    (user-error "Not in a Idris REPL buffer")))

(defun idris-run ()
  "Run an inferior Idris process."
  (interactive)
  (let ((command-line-flags (idris-compute-flags)))
    ;; Kill the running Idris if the command-line flags need updating
    (when (and (get-buffer-process (get-buffer idris-connection-buffer-name))
               (not (equal command-line-flags idris-current-flags)))
      (message "Idris command line arguments changed, restarting Idris")
      (idris-quit)
      (sit-for 0.01)) ; allows the sentinel to run and reset idris-process
    ;; Start Idris if necessary
    (when (not idris-process)
      (setq idris-process
            (get-buffer-process
             (apply #'make-comint-in-buffer
                    "idris"
                    idris-process-buffer-name
                    idris-interpreter-path
                    nil
                    "--ide-mode-socket"
                    command-line-flags)))
      (with-current-buffer idris-process-buffer-name
        (add-hook 'comint-preoutput-filter-functions
                  'idris-process-filter
                  nil
                  t)
        (add-hook 'comint-output-filter-functions
                  'idris-show-process-buffer
                  nil
                  t))
      (set-process-sentinel idris-process 'idris-sentinel)
      (setq idris-current-flags command-line-flags)
      (accept-process-output idris-process 3))))

(defun idris-quit ()
  "Quit the Idris process, cleaning up the state synchronized with Emacs."
  (interactive)
  (setq idris-prover-currently-proving nil)
  (let* ((pbuf (get-buffer idris-process-buffer-name))
         (cbuf (get-buffer idris-connection-buffer-name)))
    (when cbuf
      (when (get-buffer-process cbuf)
        (with-current-buffer cbuf (delete-process nil))) ; delete connection without asking
      (kill-buffer cbuf))
    (when pbuf
      (when (get-buffer-process pbuf)
        (with-current-buffer pbuf (delete-process nil))) ; delete process without asking
      (kill-buffer pbuf)
      (unless (get-buffer idris-process-buffer-name) (idris-kill-buffers))
      (setq idris-rex-continuations '())
      (when idris-loaded-region-overlay
        (delete-overlay idris-loaded-region-overlay)
        (setq idris-loaded-region-overlay nil)))
    (idris-prover-end)
    (idris-kill-buffers)
    (idris-remove-event-hooks)
    (setq idris-process-current-working-directory nil)
    (setq idris-protocol-version 0
          idris-protocol-version-minor 0)))

(defun idris-delete-ibc (no-confirmation)
  "Delete the IBC file for the current buffer.
When NO-CONFIRMATION argument is set to t the deletion will be
performed silently without confirmation from the user."
  (interactive "P")
  (unless (> idris-protocol-version 1)
    (let* ((fname (buffer-file-name))
           (ibc (concat (file-name-sans-extension fname) ".ibc")))
      (if (not (member (file-name-extension fname)
                       '("idr" "lidr" "org" "markdown" "md")))
          (error "The current file is not an Idris file")
        (when (or no-confirmation (y-or-n-p (concat "Really delete " ibc "?")))
          (when (file-exists-p ibc)
            (delete-file ibc)
            (message "%s deleted" ibc)))))))

(defun idris--active-term-beginning (term pos)
  "Find the beginning of active term TERM that occurs at POS.

It is an error if POS is not in the specified term. TERM should
be Idris's own serialization of the term in question."
  (unless (equal (get-char-property pos 'idris-tt-term) term)
    (error "Term not present at %s" pos))
  (save-excursion
    ;; Find the beginning of the active term
    (goto-char pos)
    (while (equal (get-char-property (point) 'idris-tt-term)
                  term)
      (backward-char 1))
    (forward-char 1)
    (point)))

(defun idris-make-term-menu (_term)
  "Make a menu for the widget for some term."
  (let ((menu (make-sparse-keymap)))
    (define-key menu [idris-term-menu-normalize]
      `(menu-item "Normalize"
                  (lambda () (interactive))))
    (define-key-after menu [idris-term-menu-show-implicits]
      `(menu-item "Show implicits"
                  (lambda () (interactive))))
    (define-key-after menu [idris-term-menu-hide-implicits]
      `(menu-item "Hide implicits"
                  (lambda () (interactive))))
    (define-key-after menu [idris-term-menu-core]
      `(menu-item "Show core"
                  (lambda () (interactive))))
    menu))

(defun idris-insert-term-widget (term)
  "Make a widget for interacting with the TERM."
  (let ((inhibit-read-only t)
        (start-pos (copy-marker (point)))
        (end-pos (copy-marker (idris-find-term-end (point) 1)))
        (buffer (current-buffer)))
    (insert-before-markers
     (propertize
      "▶"
      'face 'idris-active-term-face
      'mouse-face 'highlight
      'idris-term-widget term
      'help-echo "<mouse-3>: term menu"
      'keymap (let ((map (make-sparse-keymap)))
                (define-key map [mouse-3]
                  (lambda () (interactive)
                    (let ((selection
                           (x-popup-menu t (idris-make-term-menu term))))
                      (cond ((equal selection
                                    '(idris-term-menu-normalize))
                             (idris-normalize-term start-pos buffer)
                             (idris-remove-term-widgets))
                            ((equal selection
                                    '(idris-term-menu-show-implicits))
                             (idris-show-term-implicits start-pos buffer)
                             (idris-remove-term-widgets))
                            ((equal selection
                                    '(idris-term-menu-hide-implicits))
                             (idris-hide-term-implicits start-pos buffer)
                             (idris-remove-term-widgets))
                            ((equal selection
                                    '(idris-term-menu-core))
                             (idris-show-core-term start-pos buffer)
                             (idris-remove-term-widgets))))))
                map)))
    (let ((term-overlay (make-overlay start-pos end-pos)))
      ;; TODO: delete the markers now that they're not useful
      (overlay-put term-overlay 'idris-term-widget term)
      (overlay-put term-overlay 'face 'idris-active-term-face))))

(defun idris-add-term-widgets ()
  "Add interaction widgets to annotated terms."
  (interactive)
  (save-excursion
    (goto-char (point-min))
    (let (term)
      (while (setq term (idris-search-property 'idris-tt-term))
        (idris-insert-term-widget term)))))

(defun idris-remove-term-widgets (&optional buffer)
  "Remove interaction widgets from annotated terms in BUFFER."
  (interactive)
  (with-current-buffer (or buffer (current-buffer))
    (save-excursion
      (let ((inhibit-read-only t))
        (mapc (lambda (overlay)
                (when (overlay-get overlay 'idris-term-widget)
                  (delete-overlay overlay)))
              (overlays-in (point-min) (point-max)))
        (goto-char (point-min))
        (while (idris-search-property 'idris-term-widget)
          (delete-char 1))))))

(defun idris-show-term-implicits (position &optional buffer)
  "Replace the term at POSITION in BUFFER with a fully-explicit version."
  (interactive "d")
  (idris-active-term-command position :show-term-implicits buffer))

(defun idris-hide-term-implicits (position &optional buffer)
  "Replace the term at POSITION in BUFFER with a fully-implicit version."
  (interactive "d")
  (idris-active-term-command position :hide-term-implicits buffer))

(defun idris-normalize-term (position &optional buffer)
  "Replace the term at POSITION in BUFFER with a normalized version."
  (interactive "d")
  (idris-active-term-command position :normalise-term buffer))

(defun idris-show-core-term (position &optional buffer)
  "Replace the term at POSITION in BUFFER with the corresponding core term."
  (interactive "d")
  (idris-active-term-command position :elaborate-term buffer))

(defun idris-active-term-command (position cmd &optional buffer)
  "For the term at POSITION in BUFFER, run the live term command (CMD)."
  (unless (member cmd '(:show-term-implicits
                        :hide-term-implicits
                        :normalise-term
                        :elaborate-term))
    (error "Invalid term command %s" cmd))
  (with-current-buffer (or buffer (current-buffer))
    (let ((term (plist-get (text-properties-at position) 'idris-tt-term)))
      (if (null term)
          (error "No term here")
        (let* ((res (car (idris-eval (list cmd term))))
               (new-term (car res))
               (spans (cadr res))
               (col (save-excursion (goto-char (idris-find-term-end position -1))
                                    (current-column)))
               (rendered
                (with-temp-buffer
                  (idris-propertize-spans (idris-repl-semantic-text-props spans)
                    (insert new-term))
                  ;; Indent the new term properly, if it's annotated
                  (let ((new-tt-term (plist-get (text-properties-at (point-min)) 'idris-tt-term)))
                    (when new-tt-term
                      (goto-char (point-min))
                      (when (= (forward-line 1) 0)
                        (indent-rigidly (point) (point-max) col))
                      (put-text-property (point-min) (point-max) 'idris-tt-term new-tt-term)))
                  (buffer-string))))
          (idris-replace-term-at position rendered))))))

(defun idris-find-term-end (pos step)
  "Find an end of the term at POS, moving STEP positions in each iteration.
Return the position found."
  (unless (or (= step 1) (= step -1))
    (error "Valid values for STEP are 1 or -1"))
  ;; Can't use previous-single-property-change-position because it breaks if
  ;; point is at the beginning of the term (likewise for next/end).
  (let ((term (plist-get (text-properties-at pos) 'idris-tt-term)))
    (when (null term)
      (error "No term at %s" pos))
    (save-excursion
      (goto-char pos)
      (while (and (string= term
                           (plist-get (text-properties-at (point))
                                      'idris-tt-term))
                  (not (eobp))
                  (not (bobp)))
        (forward-char step))
      (if (= step -1)
          (1+ (point))
        (point)))))

(defun idris-replace-term-at (position new-term)
  "Replace the term at POSITION with the new rendered term NEW-TERM.
The idris-tt-term text property is used to determined the extent
of the term to replace."
  (when (null (plist-get (text-properties-at position) 'idris-tt-term))
    (error "No term here"))
  (let ((start (idris-find-term-end position -1))
        (end (idris-find-term-end position 1))
        (inhibit-read-only t))
    (save-excursion
      (delete-region start end)
      (goto-char start)
      (insert new-term))))

(defun idris-prove-hole (name &optional elab)
  "Launch the prover on the hole NAME, using Elab mode if ELAB is non-nil."
  (idris-eval-async `(:interpret ,(concat (if elab ":elab " ":p ") name))
                    (lambda (_) t))
  ;; The timer is necessary because of the async nature of starting the prover
  (run-with-timer 0.25 nil
                  #'(lambda ()
                      (let ((buffer (get-buffer idris-prover-script-buffer-name)))
                        (when buffer
                          (let ((window (get-buffer-window buffer)))
                            (when window
                              (select-window window))))))))

(defun idris-fill-paragraph (justify)
  "In literate Idris files, allow filling non-code paragraphs."
  (if (and (idris-lidr-p) (not (save-excursion (move-beginning-of-line nil)
                                               (looking-at-p ">\\s-"))))
      (fill-paragraph justify)
    (save-excursion
      (if (nth 4 (syntax-ppss))
          (fill-comment-paragraph justify) ;; if inside comment, use normal Emacs comment filling
        (if (save-excursion (move-beginning-of-line nil)
                            (looking-at "\\s-*|||\s-*")) ;; if inside documentation, fill with special prefix
            (let ((fill-prefix (substring-no-properties (match-string 0)))
                  (paragraph-start "\\s-*|||\\s-*$\\|\\s-*$\\|\\s-*@" )
                  (paragraph-separate "\\s-*|||\\s-*$\\|\\s-*$"))
              (fill-paragraph))
          ;; Otherwise do nothing
          "")))))


(defun idris-set-idris-load-packages ()
  "Interactively set the `idris-load-packages' variable."
  (interactive)
  (let* ((idris-libdir (replace-regexp-in-string
                        "[\r\n]*\\'" ""   ; remove trailing newline junk
                        (shell-command-to-string (concat idris-interpreter-path " --libdir"))))
         (idris-libs (cl-remove-if #'(lambda (x) (string= (substring x 0 1) "."))
                                   (directory-files idris-libdir)))
         (packages '())
         (prompt "Package to use (blank when done): ")
         (this-package (completing-read prompt (cons "" idris-libs))))
    (while (not (string= this-package ""))
      (push this-package packages)
      (setq this-package (completing-read prompt (cl-remove-if #'(lambda (x) (member x packages))
                                                               idris-libs))))
    (when (y-or-n-p (format "Use the packages %s for this session?"
                            (cl-reduce #'(lambda (x y) (concat x ", " y)) packages)))
      (setq idris-load-packages packages)
      (when (y-or-n-p "Save package list for future sessions? ")
        (add-file-local-variable 'idris-load-packages packages)))))

(defun idris-open-package-file ()
  "Provide easy access to package files."
  (interactive)
  (let ((files (idris-find-file-upwards "ipkg")))
    (cond ((= (length files) 0)
           (error "No .ipkg file found"))
          ((= (length files) 1)
           (find-file (car files)))
          (t (find-file (completing-read "Package file: " files nil t))))))

(defun idris-start-project ()
  "Interactively create a new Idris project, complete with ipkg file."
  (interactive)
  (let* ((project-name (read-string "Project name: "))
         (default-filename (downcase (replace-regexp-in-string "[^a-zA-Z]" "" project-name)))
         (create-in (read-directory-name "Create in: " nil default-filename))
         (default-ipkg-name (concat default-filename ".ipkg"))
         (ipkg-file (read-string
                     (format "Package file name (%s): " default-ipkg-name)
                     nil nil default-ipkg-name))
         (src-dir (read-string "Source directory (src): " nil nil "src"))
         (module-name-suggestion (replace-regexp-in-string "[^a-zA-Z]+" "." (capitalize project-name)))
         (first-mod (read-string
                     (format "First module name (%s): " module-name-suggestion)
                     nil nil module-name-suggestion)))
    (when (file-exists-p create-in) (error "%s already exists" create-in))
    (when (string= src-dir "") (setq src-dir nil))
    (make-directory create-in t)
    (when src-dir (make-directory (concat (file-name-as-directory create-in) src-dir) t))
    (find-file (concat (file-name-as-directory create-in) ipkg-file))
    (insert "package " (replace-regexp-in-string ".ipkg$" "" ipkg-file))
    (newline 2)
    (insert "-- " project-name)
    (newline)
    (let ((name (user-full-name)))
      (unless (string= name "unknown")
        (insert "-- by " name)
        (newline)))
    (newline)
    (insert "opts = \"\"")
    (newline)
    (when src-dir (insert "sourcedir = \"" src-dir "\"") (newline))
    (insert "modules = ")
    (insert first-mod)
    (newline)
    (save-buffer)
    (let* ((mod-path (reverse (split-string first-mod "\\.+")))
           (mod-dir (mapconcat #'file-name-as-directory
                               (cons create-in (cons src-dir (reverse (cdr mod-path))))
                               ""))
           (filename (concat mod-dir (car mod-path) ".idr")))
      (make-directory mod-dir t)
      (pop-to-buffer (find-file-noselect filename))
      (insert "module " first-mod)
      (newline)
      (save-buffer))))

;;; Pretty-printer stuff

(defun idris-set-current-pretty-print-width ()
  "Send the current pretty-printer width to Idris, if there is a process."
  (let ((command (format ":consolewidth %s"
                         (or idris-pretty-printer-width
                             "infinite"))))
    (when (and idris-process
               (not idris-prover-currently-proving))
      (idris-eval `(:interpret ,command) t))))

;;; Computing a menu with these commands
(defun idris-context-menu-items (plist)
  "Compute a contextual menu based on the Idris semantic decorations in PLIST."
  (let ((ref (or (plist-get plist 'idris-name-key) (plist-get plist 'idris-ref)))
        (ref-style (plist-get plist 'idris-ref-style))
        (namespace (plist-get plist 'idris-namespace))
        (source-file (plist-get plist 'idris-source-file))
        (tt-term (plist-get plist 'idris-tt-term)))
    (append
     (when ref
       (append (list (list "Get type"
                           (lambda ()
                             (interactive)
                             (idris-info-for-name :type-of ref))))
               (cond ((member ref-style
                              '(:type :data :function))
                      (list
                       (list "Get docs"
                             (lambda ()
                               (interactive)
                               (idris-info-for-name :docs-for ref)))
                       (list "Get definition"
                             (lambda ()
                               (interactive)
                               (idris--print-definition-of-name ref)))
                       (list "Who calls?"
                             (lambda ()
                               (interactive)
                               (idris-who-calls-name ref)))
                       (list "Calls who?"
                             (lambda ()
                               (interactive)
                               (idris-name-calls-who ref)))))
                     ((equal ref-style :metavar)
                      (cons (list "Launch prover"
                                  (lambda ()
                                    (interactive)
                                    (idris-prove-hole ref)))
                            (when idris-enable-elab-prover
                              (list (list "Launch interactive elaborator"
                                          (lambda ()
                                            (interactive)
                                            (idris-prove-hole ref t))))))))))
     (when namespace
       (list (list (concat "Browse " namespace)
                   (lambda ()
                     (interactive)
                     (idris-browse-namespace namespace)))))
     (when (and namespace source-file)
       (list (list (concat "Edit " source-file)
                   (lambda ()
                     (interactive)
                     (find-file source-file)))))
     (when tt-term
       (list (list "Normalize term"
                   (let ((pos (point)))
                     (lambda ()
                       (interactive)
                       (save-excursion
                         (idris-normalize-term
                          (idris--active-term-beginning tt-term pos))))))
             (list "Show term implicits"
                   (let ((pos (point)))
                     (lambda ()
                       (interactive)
                       (save-excursion
                         (idris-show-term-implicits
                          (idris--active-term-beginning tt-term pos))))))
             (list "Hide term implicits"
                   (let ((pos (point)))
                     (lambda ()
                       (interactive)
                       (save-excursion
                         (idris-hide-term-implicits
                          (idris--active-term-beginning tt-term pos))))))
             (list "Show core"
                   (let ((pos (point)))
                     (lambda ()
                       (interactive)
                       (save-excursion
                         (idris-show-core-term
                          (idris--active-term-beginning tt-term pos)))))))))))

(provide 'idris-commands)
;;; idris-commands.el ends here
