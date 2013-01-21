;;; flycheck.el --- Flymake done right

;; Copyright (c) 2012, 2013 Sebastian Wiesner <lunaryorn@gmail.com>
;;
;; Author: Sebastian Wiesner <lunaryorn@gmail.com>
;; URL: https://github.com/lunaryorn/flycheck
;; Version: 0.5
;; Keywords: convenience languages tools
;; Package-Requires: ((s "1.3.0") (dash "1.0.3"))

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; On-the-fly syntax checking for GNU Emacs (aka "flymake done right")

;; Provide `flycheck-mode' which enables on-the-fly syntax checking for a large
;; number of different modes and languages (see `flycheck-checkers' for a
;; complete list).
;;
;; Support for new modes and languages can be added by declaring a new syntax
;; checker.

;;; Code:

(eval-when-compile
  (require 'cl)                         ; For defstruct
  (require 'compile)                    ; Compilation Mode
  (require 'sh-script))

(require 's)
(require 'dash)


;;;; Compatibility
(eval-and-compile
  (unless (and (fboundp 'defvar-local)
               (eq (car (symbol-function 'defvar-local)) 'macro))
    (defmacro defvar-local (var val &optional docstring)
      "Define VAR as a buffer-local variable with default value VAL.
Like `defvar' but additionally marks the variable as being automatically
buffer-local wherever it is set."
      (declare (debug defvar) (doc-string 3))
      ;; Can't use backquote here, it's too early in the bootstrap.
      (list 'progn (list 'defvar var val docstring)
            (list 'make-variable-buffer-local (list 'quote var))))))

(eval-and-compile
  (unless (fboundp 'user-error)
    ;; Provide `user-error' for Emacs 24.2
    (defalias 'user-error 'error)
    ;; And make the debugger ignore our Flycheck user errors in Emacs 24.2
    (add-to-list 'debug-ignored-errors "\\`No more Flycheck errors\\'")
    (add-to-list 'debug-ignored-errors "\\`Flycheck mode disabled\\'")
    (add-to-list 'debug-ignored-errors
                 "\\`Configured syntax checker .* cannot be used\\'")))


;;;; Customization
(defgroup flycheck nil
  "Check syntax on-the-fly."
  :prefix "flycheck-"
  :group 'tools)

(defgroup flycheck-config-files nil
  "Configuration files for on-the-fly syntax checking."
  :prefix "flycheck-"
  :group 'flycheck)

(defcustom flycheck-checkers
  '(bash
    coffee-coffeelint
    css-csslint
    emacs-lisp
    haml
    html-tidy
    javascript-jshint
    json-jsonlint
    lua
    perl
    php
    python-flake8
    python-pylint
    python-pyflakes
    ruby
    sass
    sh
    tex-chktex
    tex-lacheck
    xml-xmlstarlet
    zsh)
  "Flycheck checkers.

A list of flycheck checkers to try for the current buffer.

If `flycheck-checker' is nil a checker is automatically selected
from these checkers on every syntax checker.

Syntax checkers are declared with `flycheck-declare-checker'."
  :group 'flycheck
  :type '(repeat (symbol :tag "Checker")))

(defvar-local flycheck-checker nil
  "Checker to use for the current buffer.

If unset automatically select a suitable checker from
`flycheck-checkers' on every syntax check.

If set to a checker only use this checker.  If set, checkers are
never selected automatically from `flycheck-checkers'.  If the
checker is unusable in the current buffer an error is signaled.

A checker is a symbol that is declared as checker with
`flycheck-declare-checker'.

Use the command `flycheck-select-checker' to select a checker for
the current buffer, or set this variable as file local variable
to always use a specific checker for a file.")
(put 'flycheck-checker 'safe-local-variable 'flycheck-registered-checker-p)

(defface flycheck-error-face
  '((t :inherit error))
  "Face for flycheck errors."
  :group 'flycheck)

(defface flycheck-warning-face
  '((t :inherit warning))
  "Face for flycheck warnings."
  :group 'flycheck)

(make-obsolete-variable 'flycheck-ignore-columns
                        "Use `flycheck-highlighting-mode' instead."
                        "0.6")

(defcustom flycheck-highlighting-mode 'columns
  "The highlighting mode.

Controls how Flycheck highlights errors in buffers.  May either
be columns, lines or nil.

If columns highlight specific columns if errors are specific to a
column.  If lines always highlight the whole line regardless of
whether the error is specific to a column.  If nil do no
highlight errors at all, but only show fringe icons.

Note that this does not affect error navigation.  When navigating
errors with `next-error' and `previous-error' Flycheck always
jumps to the error column regardless of the highlighting mode."
  :group 'flycheck
  :type '(choice (const :tag "Highlight columns only" columns)
                 (const :tag "Highlight whole lines" lines)
                 (const :tag "Do not highlight errors" nil))
  :package-version '(flycheck . "0.6"))

(defcustom flycheck-mode-hook nil
  "Hooks to run after `flycheck-mode'."
  :group 'flycheck
  :type 'hook)

(defcustom flycheck-after-syntax-check-hook nil
  "Hooks to run after each syntax check.

This hook is run after the syntax check process finished, all
error messages were parsed and properly reported (including
overlay setup)."
  :group 'flycheck
  :type 'hook)


;;;; Minor mode definition
;;;###autoload
(defconst flycheck-mode-line-lighter " FlyC"
  "The standard lighter for flycheck mode.")

(defvar-local flycheck-mode-line nil
  "The mode line lighter of variable `flycheck-mode'.")

(defun flycheck-report-status (status)
  "Report flycheck STATUS."
  (let ((mode-line flycheck-mode-line-lighter))
    (setq mode-line (concat mode-line status))
    (setq flycheck-mode-line mode-line)
    (force-mode-line-update)))

(defvar flycheck-mode-map
  (let ((map (make-sparse-keymap))
        (pmap (make-sparse-keymap)))
    (define-key pmap "c" 'flycheck-buffer)
    (define-key pmap "C" 'flycheck-clear)
    (define-key pmap (kbd "C-c") 'flycheck-compile)
    (define-key pmap "s" 'flycheck-select-checker)
    (define-key pmap "?" 'flycheck-describe-checker)
    (define-key map (kbd "C-c !") pmap)
    map)
  "Keymap of `flycheck-mode'.")

(easy-menu-change
 '("Tools") "Syntax Checking"
 '(["Check current buffer" flycheck-buffer t]
   ["Clear errors in buffer" flycheck-clear t]
   ["Compile current buffer" flycheck-compile t]
   "---"
   ["Select checker" flycheck-select-checker t]
   "---"
   ["Describe checker" flycheck-describe-checker t])
  "Spell Checking")

(easy-menu-change '("Tools") "--" nil "Spell Checking")

(defun flycheck-teardown ()
  "Teardown flyheck.

Completely clear the whole flycheck state.  Remove overlays, kill
running checks, and empty all variables used by flycheck."
  (flycheck-clear)
  (flycheck-stop-checker)
  (flycheck-cancel-error-display-timer)
  (flycheck-post-syntax-check-cleanup)
  (flycheck-clear-checker))

(defvar-local flycheck-previous-next-error-function nil
  "Remember the previous `next-error-function'.")

(defun flycheck-tramp-file-p (filename)
  "Determine if FILENAME is opened with Tramp."
  (and (fboundp 'tramp-tramp-file-p)
       (tramp-tramp-file-p filename)))

(defun flycheck-may-enable-mode ()
  "Determine whether Flycheck mode may be enabled.

Flycheck mode is not enabled under any of the following
conditions:

- The buffer file is loaded with Tramp.

Return t if Flycheck mode may be enabled, and nil otherwise."
  (not (flycheck-tramp-file-p (buffer-file-name))))

;;;###autoload
(define-minor-mode flycheck-mode
  "Minor mode for on-the-fly syntax checking.

When called interactively, toggle `flycheck-mode'.  With prefix
ARG, enable `flycheck-mode' if ARG is positive, otherwise disable
it.

When called from Lisp, enable `flycheck-mode' if ARG is omitted,
nil or positive.  If ARG is `toggle', toggle `flycheck-mode'.
Otherwise behave as if called interactively.

In `flycheck-mode' the buffer is automatically syntax-checked
using the first suitable checker from `flycheck-checkers'.  Use
`flycheck-select-checker` to select a checker for the current
buffer manually.

\\{flycheck-mode-map}"
  :init-value nil
  :keymap flycheck-mode-map
  :lighter flycheck-mode-line
  :group 'flycheck
  :require 'flycheck
  (cond
   (flycheck-mode
    (cond
     ((flycheck-may-enable-mode)
      ;; Start flycheck mode
      (flycheck-report-status "")

      (add-hook 'after-save-hook 'flycheck-buffer-safe nil t)
      (add-hook 'after-change-functions 'flycheck-handle-change nil t)
      (add-hook 'post-command-hook 'flycheck-show-error-at-point-soon nil t)

      (setq flycheck-previous-next-error-function next-error-function)
      (setq next-error-function 'flycheck-next-error)

      (flycheck-buffer-safe))
     (t
      (flycheck-mode -1)
      (user-error "Cannot use Flycheck mode in buffer %s" (buffer-name)))))
   (t
    (remove-hook 'after-save-hook 'flycheck-buffer-safe t)
    (remove-hook 'after-change-functions 'flycheck-handle-change t)
    (remove-hook 'post-command-hook 'flycheck-show-error-at-point-soon t)

    (setq next-error-function flycheck-previous-next-error-function)

    (flycheck-teardown))))

(defun flycheck-handle-change (beg end len)
  "Handle a buffer change between BEG and END with LEN.

BEG and END mark the beginning and end of the change text.  LEN is ignored.

Start a syntax check if a new line has been inserted into the buffer."
  (let ((new-text (buffer-substring beg end)))
    (when (and flycheck-mode (s-contains? "\n" new-text))
      (flycheck-buffer-safe))))

(defun flycheck-clear ()
  "Clear all errors in the current buffer."
  (interactive)
  (flycheck-remove-overlays)
  (flycheck-clear-errors))

(defun flycheck-buffer ()
  "Check syntax in the current buffer."
  (interactive)
  (flycheck-clear)
  (if flycheck-mode
      (when (not (flycheck-running-p))
        (condition-case err
            (let ((checker (flycheck-get-checker-for-buffer)))
              (when checker (flycheck-start-checker checker)))
          (error
           (flycheck-report-status "!")
           (signal (car err) (cdr err)))))
    (user-error "Flycheck mode disabled")))

(defun flycheck-compile-name (mode-name)
  "Get a name for a compilation buffer."
  (format "*Flycheck %s*" (buffer-file-name)))

(defun flycheck-compile ()
  "Run syntax checker as compiler."
  (interactive)
  (unless (buffer-file-name)
    (user-error "Cannot compile buffers without backing file."))
  (let ((checker (flycheck-get-checker-for-buffer)))
    (if checker
        (let* ((command (flycheck-checker-shell-command checker))
               (buffer (compilation-start command nil
                                          #'flycheck-compile-name)))
          (with-current-buffer buffer
            (set (make-local-variable 'compilation-error-regexp-alist)
                 (flycheck-checker-compilation-error-regexp-alist checker))))
      (user-error "No suitable checker available."))))

(defun flycheck-may-check-buffer ()
  "Determine whether the buffer may be checked.

A buffer may not be checked under the following conditions:

- The buffer is read only (see `buffer-read-only').

Return t if the buffer may be checked and nil otherwise."
  (not buffer-read-only))

(defun flycheck-buffer-safe ()
  "Safely check syntax in the current buffer.

Like `flycheck-buffer', but do not check buffers that need not be
checked (i.e. read-only buffers) and demote all errors to messages.

Use when checking buffers automatically."
  (if (flycheck-may-check-buffer)
      (with-demoted-errors
        (flycheck-buffer))
    (message "Cannot perform a syntax check in buffer %s."
             (buffer-name))))

;;;###autoload
(defun flycheck-mode-on ()
  "Unconditionally enable variable `flycheck-mode'."
  (flycheck-mode 1))
(make-obsolete 'flycheck-mode-on 'flycheck-mode "0.5")

;;;###autoload
(defun flycheck-mode-off ()
  "Unconditionally disable variable `flycheck-mode'."
  (flycheck-mode -1))
(make-obsolete 'flycheck-mode-off "Use (flycheck-mode -1)." "0.5")


;;;; Utility functions
(defun flycheck-temp-file-system (filename prefix)
  "Create a copy of FILENAME with PREFIX in temp directory.

Return the path of the file."
  ;; HACK: Prevent re-compression to work around a supposed bug in Emacs.
  ;; `make-temp-file' calls `write-region' to set the contents of the new
  ;; temporary file, which in turn calls `jka-compr-write-region' for compressed
  ;; files. If `jka-compr-really-do-compress' is non-nil this function uses END
  ;; even though START is a string, hence breaking the `write-region' API that
  ;; we rely on.  Report upstream!
  (let ((jka-compr-really-do-compress nil)
        (extension (when filename (file-name-extension filename))))
    (make-temp-file prefix nil
                    (when extension (concat "." extension)))))

(defun flycheck-temp-file-inplace (filename prefix)
  "Create an in-place copy of FILENAME with PREFIX added.

If FILENAME is nil, fall back to `flycheck-temp-file-system'.

Return the path of the file."
  (if filename
      (let* ((directory (file-name-directory filename))
             (name (file-name-nondirectory filename)))
        (expand-file-name (format "%s-%s" prefix name) directory))
    ;; With no filename, fall back to a copy in the system directory.
    (flycheck-temp-file-system filename prefix)))

(defun flycheck-find-file-in-tree (filename directory)
  "Find FILENAME in DIRECTORY and all of its ancestors.

Start looking for a file named FILENAME in DIRECTORY and traverse
upwards through all of its ancestors up to the file system root
until the file is found or the root is reached.

Return the absolute path of the file, or nil if the file was not
found in DIRECTORY or any of its ancestors."
  (let ((full-path (expand-file-name filename directory)))
    (cond ((string= directory "/") (when (file-exists-p full-path) full-path))
          ((file-exists-p full-path) full-path)
          ((let ((parent-directory (file-name-directory
                                    (directory-file-name
                                     (file-name-directory full-path)))))
             (flycheck-find-file-in-tree filename parent-directory))))))

(defun flycheck-find-file-for-buffer (filename)
  "Find FILENAME for the current buffer.

First try to find the file in the buffer's directory and any of
its ancestors (see `flycheck-find-file-in-tree').  If that fails
or if the buffer has no `buffer-file-name' try to find the file
in the home directory.  If the file is not found anywhere return
nil."
  (let ((directory (when (buffer-file-name)
                     (file-name-directory (buffer-file-name)))))
    (or (when directory (flycheck-find-file-in-tree filename directory))
        (let ((home-path (expand-file-name filename)))
          (when (file-exists-p home-path) home-path)))))

(defun flycheck-canonical-file-name (filename)
  "Turn FILENAME into canonical form.

Return FILENAME expanded and fully resolved, in a canonical form
without double slashes and without trailing slash, i.e. in a form
suitable for comparison of file names."
  (directory-file-name (file-truename filename)))

(defun flycheck-same-files-p (file1 file2)
  "Determine whether two files FILE1 and FILE2 are the same."
  (string= (flycheck-canonical-file-name file1)
           (flycheck-canonical-file-name file2)))

(defun flycheck-save-buffer-to-file (file-name)
  "Save the contents of the current buffer to FILE-NAME."
  (make-directory (file-name-directory file-name) t)
  (write-region nil nil file-name nil 0))

(defun flycheck-temp-buffer-copy (temp-file-fn)
  "Copy current buffer to temp file returned by TEMP-FILE-FN.

Return the name of the temporary file."
  (let ((temp-file (funcall temp-file-fn (buffer-file-name) "flycheck")))
    (flycheck-save-buffer-to-file temp-file)
    temp-file))


;;;; Minibuffer tools
(defvar read-flycheck-checker-history nil
  "History of `read-flycheck-checker'.")

(defun read-flycheck-checker (prompt)
  "Read a flycheck checker from minibuffer with PROMPT.

Return the checker as symbol, or nil if no checker was
chosen."
  (let* ((checkers (-map #'symbol-name flycheck-checkers))
         (input (completing-read prompt obarray
                                 #'flycheck-valid-checker-p t
                                 nil 'read-flycheck-checker-history)))
    (if (string= input "") nil (intern input))))


;;;; Checker declarations
;;;###autoload
(defmacro flycheck-declare-checker (symbol docstring &rest properties)
  "Declare SYMBOL as syntax checker with DOCSTRING and PROPERTIES.

DOCSTRING provides documentation for the new checker.  Use
`flycheck-checker-documentation' to access the documentation
string of a checker, and `flycheck-describe-checker' to get help
about a checker.

The following PROPERTIES are understood:

:command A list with the executable (in `car') and the
arguments (in `cdr') of the syntax checker.  The executable is
checked for existence with `executable-find' before executing the
checker.  The arguments are substituted with
`flycheck-substitute-argument' before execution, see the
documentation of this function for a list of special tags allowed
in arguments.

:error-patterns A list of error patterns to parse the output of
the checker.  Each pattern is a list (REGEXP LEVEL).  REGEXP is a
regular expression that matches an error.  This regular
expression may contain match groups extracting specific
information about the error.  The 1st group is the file name, the
2nd group the line number, the 3rd group the column number and
the 4th group the error message.  A group is ignored if it did
not match or the match returned an empty string.  LEVEL is either
warning or error and determines the severity of the error message
parsed with the pattern.

:modes A major mode symbol or a list thereof.  If present the
checker is only used in these modes.

:predicate An Emacs Lisp form.  If present the checker is only
used if the form evaluates to a non-nil result in the buffer to
check.

Either :modes or :predicate must be present.  If both are
present, both must match for the checker to be used."
  (declare (indent 1)
           (doc-string 2))
  `(progn
     ;; Un-declare any previous checker for this mode
     (put (quote ,symbol) :flycheck-checker nil)
     (put (quote ,symbol) :flycheck-command nil)
     (put (quote ,symbol) :flycheck-error-patterns nil)
     (put (quote ,symbol) :flycheck-modes nil)
     (put (quote ,symbol) :flycheck-predicate nil)
     (put (quote ,symbol) :flycheck-documentation nil)
     ;; Store the checker properties
     (put (quote ,symbol) :flycheck-command ,(plist-get properties :command))
     (put (quote ,symbol) :flycheck-error-patterns
          ,(plist-get properties :error-patterns))
     (put (quote ,symbol) :flycheck-modes ,(plist-get properties :modes))
     (put (quote ,symbol) :flycheck-predicate
          ,(plist-get properties :predicate))
     (put (quote ,symbol) :flycheck-documentation ,docstring)
     ;; Verify the checker and declare it valid if succeeded
     (flycheck-verify-checker (quote ,symbol))
     (put (quote ,symbol) :flycheck-checker t)))

;;;###autoload
(defmacro flycheck-def-config-file-var (symbol checker &optional file-name)
  "Define SYMBOL as config file variable for CHECKER, with default FILE-NAME.

SYMBOL is declared as customizable variable (see `defcustom`)
providing a configuration file for CHECKER.  The CHECKER argument
is used for documentation purposes only.  If given use FILE-NAME
as initial value.

Use this together with the config tag in checker arguments."
  (declare (indent 3))
  `(progn
     (put (quote ,checker) :flycheck-config-file-var (quote ,symbol))
     (defcustom ,symbol ,file-name
       ,(format "Configuration file for `%s'.

When set to a plain file name without any slash search for this
file name in the directory of the buffer being check, any
ancestors thereof or the home directory.  If buffer being checked
has no backing file, search in the home directory only.  If the
file is found pass it to the checker as configuration file.
Otherwise invoke the checker without a configuration file.

When set to a file path containing a slash expand the file name
with `expand-file-name` and pass this file to checker, if it
exists.  Otherwise invoke the checker without a configuration
file.

Use this variable as file-local variable if you need a specific
configuration file a buffer." checker)
       :type '(choice (const :tag "No configuration file" nil)
                      (string :tag "File name or path"))
       :group 'flycheck-config-files)
     (put (quote ,symbol) 'safe-local-variable #'stringp)
     (make-variable-buffer-local (quote ,symbol))))

(defun flycheck-error-pattern-p (pattern)
  "Check whether PATTERN is a valid error pattern."
  (and
   (listp pattern)                      ; A pattern must be a list...
   (= (length pattern) 2)               ; ...of length 2...
   (stringp (car pattern))              ; ...whose 1st element is a string
   (symbolp (cadr pattern))             ; ...and whose 2nd element is a symbol
   ))

(defun flycheck-error-patterns-list-p (patterns)
  "Check whether PATTERNS is a list of valid error patterns."
  (-all? 'flycheck-error-pattern-p patterns))

(defun flycheck-verify-checker (checker)
  "Verify CHECKER.

Ensure that all required properties are present, and signal an
error if not."
  (let ((command (get checker :flycheck-command))
        (patterns (get checker :flycheck-error-patterns))
        (modes (get checker :flycheck-modes))
        (predicate (get checker :flycheck-predicate))
        (doc (get checker :flycheck-documentation)))
    (unless (and doc (stringp doc))
      (error "Checker %s lacks documentation" checker))
    (unless command
      (error "Checker %s lacks :command" checker))
    (unless (stringp (car command))
      (error "Checker %s lacks executable in :command" checker))
    (unless (and patterns (flycheck-error-patterns-list-p patterns))
      (error "Checker %s lacks valid :error-patterns" checker))
    (unless (or modes predicate)
      (error "Checker %s lacks :modes and :predicate" checker))))


;;;; Checker API
(defun flycheck-registered-checker-p (checker)
  "Determine whether CHECKER is registered.

A checker is registered if it is contained in `flycheck-checkers'."
  (memq checker flycheck-checkers))

(defun flycheck-valid-checker-p (checker)
  "Check whether a CHECKER is valid.

A valid checker is a symbol declared as checker with
`flycheck-declare-checker'."
  (get checker :flycheck-checker))

(defun flycheck-checker-modes (checker)
  "Get the modes of CHECKER."
  (let ((modes (get checker :flycheck-modes)))
    (if (and modes (symbolp modes))
        (list modes)
      modes)))

(defun flycheck-checker-predicate (checker)
  "Get the predicate of CHECKER."
  (get checker :flycheck-predicate))

(defun flycheck-checker-command (checker)
  "Get the raw command of CHECKER.

The command list returned by this function is not substituted,
and hence still contains special tags and symbols.  Use
`flycheck-checker-substituted-command' to get an executable
command list with no special tags and symbols."
  (get checker :flycheck-command))

(defun flycheck-checker-executable (checker)
  "Get the executable of CHECKER.

The executable is the `car' of the checker command as returned by
`flycheck-checker-command'."
  (car (flycheck-checker-command checker)))

(defun flycheck-checker-error-patterns (checker)
  "Get the error patterns of CHECKER."
  (get checker :flycheck-error-patterns))

(defun flycheck-checker-pattern-to-error-regexp (pattern)
  "Convert PATTERN into an error regexp for compile.el.

Return a list representing PATTERN, suitable as element in
`compilation-error-regexp-alist'."
  (let* ((regexp (car pattern))
         (level (cadr pattern))
         (level-no (cond
                    ((eq level 'error) 2)
                    ((eq level 'warning) 1))))
    (list regexp 1 2 3 level-no)))

(defun flycheck-checker-compilation-error-regexp-alist (checker)
  "Convert error patterns of CHECKER for use with compile.el.

Return an alist of all error patterns of CHECKER, suitable for
use with `compilation-error-regexp-alist'."
  (-map #'flycheck-checker-pattern-to-error-regexp
        (flycheck-checker-error-patterns checker)))

(defun flycheck-checker-documentation (checker)
  "Get the documentation of CHECKER."
  (documentation-property checker :flycheck-documentation))

(defun flycheck-checker-config-file-var (checker)
  "Get the associated configuration file variable of CHECKER.

Return nil if CHECKER has no associated configuration file
variable."
  (get checker :flycheck-config-file-var))

(defun flycheck-check-modes (checker)
  "Check the allowed modes of CHECKER.

Check the current `major-mode' against the modes allowed for
CHECKER.  Return t if the modes match or nil otherwise."
  (let ((modes (flycheck-checker-modes checker)))
    (or (not modes) (memq major-mode modes))))

(defun flycheck-check-predicate (checker)
  "Check the predicate of CHECKER.

Check the predicate of CHECKER, and return t if the checker has
no predicate or the result of the predicate evaluation."
  (let ((predicate (flycheck-checker-predicate checker)))
    (or (not predicate) (eval predicate))))

(defun flycheck-check-executable (checker)
  "Check the executable of the CHECKER."
  (when (executable-find (flycheck-checker-executable checker)) t))

(defun flycheck-may-use-checker (checker)
  "Determine whether a CHECKER may be used.

Return t if CHECKER may be used for the current buffer and nil
otherwise."
  (unless (flycheck-valid-checker-p checker)
    (error "%s is no declared flycheck syntax checker (see `flycheck-declare-checker')"
           checker))
  (and (flycheck-check-modes checker)
       (flycheck-check-predicate checker)
       (flycheck-check-executable checker)))

(defvar-local flycheck-substituted-files nil
  "A list of all files created for argument substitution.")

(defun flycheck-clean-substituted-files ()
  "Remove all substituted files."
  (--each flycheck-substituted-files (ignore-errors (delete-file it)))
  (setq flycheck-substituted-files nil))

(defun flycheck-get-source-file (temp-fn)
  "Get the source file to check using TEMP-FN.

Make a temporary copy of the buffer, remember it in
`flycheck-substituted-files' and return the file path."
  (let ((temp-file (flycheck-temp-buffer-copy temp-fn)))
    (add-to-list #'flycheck-substituted-files temp-file)
    temp-file))

(defun flycheck-find-config-file (file-name)
  "Find the configuration file FILE-NAME.

If FILE-NAME contains a slash, return FILE-NAME expanded with
`expand-file-name'.

If FILE-NAME does not contain a slash, search the file with
`flycheck-find-file-name' and return the result."
  (when file-name
    (if (s-contains? "/" file-name)
        (let ((file-name (expand-file-name file-name)))
          (when (file-exists-p file-name) file-name))
      (flycheck-find-file-for-buffer file-name))))

(defun flycheck-substitute-argument (arg)
  "Substitute ARG with file to check is possible.

If ARG is source or source-inplace, create a temporary file
to checker and return its path, otherwise return ARG unchanged.

If ARG is a list whose `car' is config, search the configuration
file and return a list of options that specify this configuration
file, or nil of the config file was not found."
  (cond
   ((eq arg 'source)
    (flycheck-get-source-file #'flycheck-temp-file-system))
   ((eq arg 'source-inplace)
    (flycheck-get-source-file #'flycheck-temp-file-inplace))
   ((and (listp arg) (eq (car arg) 'config))
    (let ((option-name (nth 1 arg))
           (file-name  (flycheck-find-config-file (symbol-value (nth 2 arg)))))
      (when file-name
        (list option-name file-name))))
   (t arg)))

(defun flycheck-checker-substituted-command (checker)
  "Get the substituted command of a CHECKER.

Substitute each argument in the command of CHECKER using
`flycheck-substitute-argument'.  This replaces any special
symbols in the command."
  (-flatten (-keep #'flycheck-substitute-argument
                   (flycheck-checker-command checker))))

(defun flycheck-substitute-shell-argument (arg)
  "Substitute ARG for use in a shell command..

If ARG is source or source-inplace, return the buffer file name.

If ARG is a list whose `car' is config, search the configuration
file and return a list of options that specify this configuration
file, or nil of the config file was not found.

ARG is always quoted for use in a shell command (see
`shell-quote-argument')."
  (cond
   ((memq arg '(source source-inplace))
    (shell-quote-argument (buffer-file-name)))
   ((and (listp arg) (eq (car arg) 'config))
    (let ((option-name (nth 1 arg))
          (file-name (flycheck-find-config-file (symbol-value (nth 2 arg)))))
      (if file-name
          (concat option-name " " (shell-quote-argument file-name))
        "")))
   (t (shell-quote-argument arg))))

(defun flycheck-checker-shell-command (checker)
  "Get a shell command for CHECKER.

Return the command of CHECKER as single string, suitable for
shell execution."
  (s-join " " (-map #'flycheck-substitute-shell-argument
                    (flycheck-checker-command checker))))


;;;; Checker selection
(defvar-local flycheck-last-checker nil
  "The last checker used for the current buffer.")

(defun flycheck-clear-checker ()
  "Clear configured and remembered checkers in the current buffer."
  (setq flycheck-checker nil)
  (setq flycheck-last-checker nil))

(defun flycheck-try-last-checker-for-buffer ()
  "Try the last checker for the current buffer.

Return the checker if it may be used, or nil otherwise."
  ;; We should not use the last checker if it was removed from the list of
  ;; allowed checkers in the meantime
  (when (and (flycheck-registered-checker-p flycheck-last-checker)
             (flycheck-may-use-checker flycheck-last-checker))
    flycheck-last-checker))

(defun flycheck-get-new-checker-for-buffer ()
  "Find a new checker for the current buffer.

If a checker is found set `flycheck-last-checker' to re-use this
checker for the next check.

Return the checker if there is any, or nil otherwise."
  (let ((checker (-first #'flycheck-may-use-checker flycheck-checkers)))
    (when checker
      (setq flycheck-last-checker checker))))

(defun flycheck-get-checker-for-buffer ()
  "Find the checker for the current buffer.

Return checker if there is a checker for the current buffer, or
nil otherwise."
  (if flycheck-checker
      ;; If a checker was configured, try to use it!
      (if (flycheck-may-use-checker flycheck-checker)
          flycheck-checker
        (user-error "Configured syntax checker %s cannot be used"
                    flycheck-checker))
    (or (flycheck-try-last-checker-for-buffer)
        (flycheck-get-new-checker-for-buffer))))

(defun flycheck-select-checker (checker)
  "Select CHECKER for the current buffer.

CHECKER is a checker symbol (see `flycheck-checkers') or nil.  If
nil deselect the current checker (if any) and use automatic
checker selection via `flycheck-checkers'.

If called interactively prompt for CHECKER.  If no checker is
entered deselect the current checker.  With prefix arg
immediately deselect the current checker without any prompt.

Set `flycheck-checker' to CHECKER and automatically start a new
syntax check if the checker changed."
  (interactive
   (if current-prefix-arg
       (list nil)
     (list (read-flycheck-checker "Checker: "))))
  (when (not (eq checker flycheck-checker))
    (setq flycheck-checker checker)
    (flycheck-buffer)))


;;;; Checker help
(defun flycheck-describe-checker (checker)
  "Display the documentation of CHECKER.

CHECKER is a checker symbol.

Pop up a help buffer with the documentation of CHECKER."
  (interactive
   (list (read-flycheck-checker "Describe checker: ")))
  (if (null checker)
      (message "You didn't specify a Flycheck syntax checker.")
    (help-setup-xref (list #'flycheck-describe-checker checker)
                     (called-interactively-p 'interactive))
    (save-excursion
      (with-help-window (help-buffer)
        ;; TODO: Find and output declaring file
        (princ (format "%s is a Flycheck syntax checker.\n\n" checker))
        (let ((executable (flycheck-checker-executable checker))
              (modes (flycheck-checker-modes checker))
              (predicate (flycheck-checker-predicate checker))
              (config-file-var (flycheck-checker-config-file-var checker)))
          (princ (format "  This checker executes \"%s\"" executable))
          (if config-file-var
            (princ (format ", using a configuration file from `%s'.\n"
                           config-file-var))
            (princ ".\n"))
          (cond
           ((and modes predicate)
            (princ (format "  It checks syntax in the major mode(s) %s if the predicate %s is fulfilled. "
                           (s-join ", " (--map (format "`%s'" it) modes))
                           predicate)))
           (modes
            (princ (format "  It checks syntax in the major mode(s) %s. "
                           (s-join ", " (--map (format "`%s'" it) modes)))))
           (predicate
            (princ (format "  It checks syntax if the predicate %s is fulfilled. "
                           (prin1-to-string predicate)))))
          (with-current-buffer (help-buffer)
            (save-excursion
              (goto-char (point-min))
              (forward-paragraph)
              (fill-region-as-paragraph (point) (point-max)))))
        (princ (format "\n\nDocumentation:\n%s"
                       (flycheck-checker-documentation checker)))))))


;; Checker error API
(defstruct (flycheck-error
            (:constructor flycheck-make-error))
  buffer file-name line-no col-no text level)

(defmacro flycheck-error-with-buffer (err &rest forms)
  "Switch to the buffer of ERR and evaluate FORMS.

If the buffer of ERR is not live, FORMS are not evaluated."
  (declare (indent 1))
  `(when (buffer-live-p (flycheck-error-buffer ,err))
    (with-current-buffer (flycheck-error-buffer ,err)
      ,@forms)))

(defun flycheck-error-region (err &optional ignore-column)
  "Get the region of ERR.

ERR is a flycheck error whose region to get.  If IGNORE-COLUMN is
given and t ignore the column number of ERR when determining the
region.  Hence the region will always extend over the whole line.

Return a cons cell (BEG . END).  BEG is the beginning of the
error region and END its end.  If ERR has a column number and
IGNORE-COLUMN is omitted or nil BEG and END mark a region that
marks that column only.  Otherwise BEG is the position of the
first non-whitespace character on the ERR line and END its end."
  (save-excursion
    (goto-char (point-min))
    (forward-line (- (flycheck-error-line-no err) 1))
    (back-to-indentation)
    (let* ((col (if ignore-column nil (flycheck-error-col-no err)))
           (beg (point))
           (end (line-end-position)))
      (cond
       ((= beg end)
        (forward-line -1)
        (setq beg (line-end-position)))
       (col
        (setq end (min (+ (line-beginning-position) col)
                       (+ (line-end-position) 1)))
        (setq beg (- end 1))))
      `(,beg . ,end))))

(defun flycheck-error-pos (err)
  "Get the buffer position of ERR.

If ERR has a column return exactly that column.  Otherwise return
the beginning of the line of ERR."
  (car (flycheck-error-region err)))


;;;; Error parsing
(defun flycheck-match-string-non-empty (group match &optional trim-first)
  "Get a non-empty string from a GROUP in MATCH.

If the string returned by GROUP is empty, return nil instead.

If TRIM-FIRST is t trim leading and trailing white space in the matched
string."
  (let ((matched-string (nth group match)))
    (save-match-data
      (when matched-string
        (when trim-first
          (setq matched-string (s-trim matched-string)))
        (when (not (s-blank? matched-string))
          matched-string)))))

(defun flycheck-match-int (group match)
  "Get an integer from a GROUP in MATCH.

Return nil if the group did not match a number."
  (let ((matched-string (flycheck-match-string-non-empty group match t)))
    (when matched-string
      (string-to-number matched-string))))

(defun flycheck-get-regexp (patterns)
  "Create a single regular expression from PATTERNS."
  (s-join "\\|" (--map (format "\\(?:%s\\)" (car it)) patterns)))

(defun flycheck-split-output (output patterns)
  "Split OUTPUT from BUFFER with PATTERNS.

Return a list of strings where each string is an unparsed error."
  (let ((regexp (flycheck-get-regexp patterns))
        (errors nil)
        (last-match 0))
    (while (string-match regexp output last-match)
      (!cons (match-string 0 output) errors)
      (setq last-match (match-end 0)))
    errors))

(defun flycheck-try-parse-error-with-pattern (err pattern)
  "Try to parse a single ERR with a PATTERN.

Return the parsed error if PATTERN matched ERR, or nil
otherwise."
  (let* ((regexp (car pattern))
         (level (cadr pattern))
         (match (s-match regexp err)))
    (when match
      (flycheck-make-error
       :file-name (flycheck-match-string-non-empty 1 match)
       :line-no (flycheck-match-int 2 match)
       :col-no (flycheck-match-int 3 match)
       :text (flycheck-match-string-non-empty 4 match t)
       :level level))))

(defun flycheck-parse-error (err patterns)
  "Parse a single ERR with error PATTERNS.

Apply each pattern in PATTERNS to ERR, in the given order, and
return the first parsed error."
  ;; Try to parse patterns in the order of declaration to make sure that the
  ;; first match wins.
  (car (--keep (flycheck-try-parse-error-with-pattern err it) patterns)))

(defun flycheck-parse-errors (errors patterns)
  "Parse ERRORS with PATTERNS.

ERRORS is a list of strings where each string is an unparsed
error message, typically from `flycheck-split-output'.  PATTERNS
is a list of error patterns to parse ERRORS with.

Return a list of parsed errors."
  (--map (flycheck-parse-error it patterns) errors))

(defun flycheck-parse-output (output buffer patterns)
  "Parse OUTPUT from BUFFER with PATTERNS.

PATTERNS is a list of flycheck error patterns.

First split OUTPUT with PATTERNS to obtain a list of unparsed
errors.  Then parse each error with PATTERNS to create a
structured representation of the error.  This ensures that the
first pattern wins.

Return a list of parsed errors and warnings (as `flycheck-error'
objects)."
  (let* ((chunks (flycheck-split-output output patterns))
         (errors (flycheck-parse-errors chunks patterns)))
    (--each errors (setf (flycheck-error-buffer it) buffer))
    errors))

(defun flycheck-relevant-error-p (err)
  "Determine whether ERR is relevant for the current buffer.

Return t if ERR may be shown for the current buffer, or nil
otherwise."
  (flycheck-error-with-buffer err
    (let ((file-name (flycheck-error-file-name err)))
      (and
       (or (not file-name) (flycheck-same-files-p file-name (buffer-file-name)))
       (not (s-blank? (flycheck-error-text err)))
       (flycheck-error-line-no err)))))

(defun flycheck-back-substitute-filename (err)
  "Reverse substitute the file name in ERR.

Substitute the file name of ERR with the function `buffer-file-name' of
the corresponding buffer if it matches and file in
`flycheck-substituted-files'."
  (flycheck-error-with-buffer err
    (let ((file-name (flycheck-error-file-name err)))
      (when file-name
        (--each
          flycheck-substituted-files
          (when (flycheck-same-files-p file-name it)
            (setf (flycheck-error-file-name err) (buffer-file-name)))))
      err)))

(defun flycheck-sanitize-error (err)
  "Sanitize ERR.

Clean up the error file name and the error message."
  (flycheck-error-with-buffer err
    (let ((filename (flycheck-error-file-name err))
          (text (flycheck-error-text err)))
      (when text
        (setf (flycheck-error-text err) (s-collapse-whitespace (s-trim text))))
      (when filename
        ;; If the error has a file name, expand it relative to the default
        ;; directory of its buffer and back substitute the file name
        (setf (flycheck-error-file-name err) (expand-file-name filename))
        (flycheck-back-substitute-filename err))))
  err)

(defun flycheck-sanitize-errors (errors)
  "Sanitize ERRORS.

Remove all errors that do not belong to the current file."
  (-filter 'flycheck-relevant-error-p (-map 'flycheck-sanitize-error errors)))

(defun flycheck-error-<= (err1 err2)
  "Determine whether ERR1 goes before ERR2.

Compare by line numbers and then by column numbers."
  (let ((line1 (flycheck-error-line-no err1))
        (line2 (flycheck-error-line-no err2)))
    (if (= line1 line2)
        (let ((col1 (flycheck-error-col-no err1))
              (col2 (flycheck-error-col-no err2)))
          (or (not col1)                ; Sort errors for the whole line first
              (and col2 (<= col1 col2))))
      (< line1 line2))))

(defun flycheck-sort-errors (errors)
  "Sort ERRORS by line and column numbers.

ERRORS is modified by side effects."
  (sort errors 'flycheck-error-<=))


;;;; Error analysis and reporting
(defun flycheck-count-errors (errors)
  "Count the number of warnings and errors in ERRORS.

Return a cons cell whose `car' is the number of errors and whose
`car' is the number of warnings."
  (let* ((groups (-group-by 'flycheck-error-level errors))
         (errors (cdr (assq 'error groups)))
         (warnings (cdr (assq 'warning groups))))
    `(,(length errors) . ,(length warnings))))

(defun flycheck-report-errors (errors)
  "Report ERRORS in the current buffer.

Add overlays and report a proper flycheck status."
  (flycheck-add-overlays errors)
  (if errors
      (let ((no-err-warnings (flycheck-count-errors errors)))
        (flycheck-report-status
         (format ":%s/%s" (car no-err-warnings) (cdr no-err-warnings))))
    (flycheck-report-status "")))

(defvar-local flycheck-current-errors nil
  "A list of all errors and warnings in the current buffer.")

(defun flycheck-clear-errors ()
  "Remove all error information from the current buffer."
  (setq flycheck-current-errors nil)
  (flycheck-report-status ""))


;;;; Error overlay management
(when (fboundp 'define-fringe-bitmap)
  (define-fringe-bitmap 'flycheck-fringe-exclamation-mark
    [24 60 60 24 24 0 0 24 24] nil nil 'center))

(defconst flycheck-fringe-exclamation-mark
  (if (get 'exclamation-mark 'fringe)
      'exclamation-mark
    'flycheck-fringe-exclamation-mark)
    "The symbol to use as exclamation mark bitmap.

Defaults to the built-in exclamation mark if available or to the
flycheck exclamation mark otherwise.")

(defconst flycheck-error-overlay nil
  "Overlay category for flycheck errors.")
(put 'flycheck-error-overlay 'flycheck-overlay t)
(put 'flycheck-error-overlay 'face 'flycheck-error-face)
(put 'flycheck-error-overlay 'priority 100)
(put 'flycheck-error-overlay 'help-echo "Unknown error.")
(put 'flycheck-error-overlay 'flycheck-fringe-bitmap
     flycheck-fringe-exclamation-mark)

(defconst flycheck-warning-overlay nil
  "Overlay category for flycheck warning.")
(put 'flycheck-warning-overlay 'flycheck-overlay t)
(put 'flycheck-warning-overlay 'face 'flycheck-warning-face)
(put 'flycheck-warning-overlay 'priority 100)
(put 'flycheck-warning-overlay 'help-echo "Unknown warning.")
(put 'flycheck-warning-overlay 'flycheck-fringe-bitmap 'question-mark)

(defconst flycheck-overlay-categories-alist
  '((warning . flycheck-warning-overlay)
    (error . flycheck-error-overlay))
  "Overlay categories for error levels.")

(defun flycheck-add-overlay (err)
  "Add overlay for ERR."
  (flycheck-error-with-buffer err
    (save-excursion
      (goto-char (point-min))
      (forward-line (- (flycheck-error-line-no err) 1))
      (let* ((mode flycheck-highlighting-mode)
             (level (flycheck-error-level err))
             (region (flycheck-error-region err (not (eq mode 'columns))))
             (category (cdr (assq level flycheck-overlay-categories-alist)))
             (text (flycheck-error-text err))
             (overlay (make-overlay (car region) (cdr region)
                                    (flycheck-error-buffer err)))
             (fringe-icon `(left-fringe ,(get category 'flycheck-fringe-bitmap)
                                        ,(get category 'face))))
        ;; TODO: Consider hooks to re-check if overlay contents change
        (overlay-put overlay 'category category)
        (unless mode
          ;; Erase the highlighting from the overlay if requested by the user
          (overlay-put overlay 'face nil))
        (overlay-put overlay 'flycheck-error err)
        (overlay-put overlay 'before-string
                     (propertize "!" 'display fringe-icon))
        (unless (s-blank? text)
          (overlay-put overlay 'help-echo text))))))

(defun flycheck-add-overlays (errors)
  "Add overlays for ERRORS."
  ;; Add overlays from last to first to make sure that for each region the first
  ;; error emitted by the checker is on top
  (mapc #'flycheck-add-overlay (reverse errors)))

(defun flycheck-overlays-at (pos)
  "Return a list of all flycheck overlays at POS."
  (--filter (overlay-get it 'flycheck-overlay) (overlays-at pos)))

(defun flycheck-overlay-errors-at (pos)
  "Return a list of all flycheck errors overlayed at POS."
  (--map (overlay-get it 'flycheck-error) (flycheck-overlays-at pos)))

(defun flycheck-overlay-messages-at (pos)
  "Return a list of all flycheck messages overlayed at POS."
  (--map (overlay-get it 'help-echo) (flycheck-overlays-at pos)))

(defun flycheck-remove-overlays ()
  "Remove all flycheck overlays in the current buffer."
  (remove-overlays (point-min) (point-max) 'flycheck-overlay t))


;;;; Error navigation
(defun flycheck-next-error (no-errors reset)
  "Advance NO-ERRORS, optionally RESET before.

NO-ERRORS is a number specifying how many errors to move forward.
IF RESET is t, move to beginning of buffer first."
  (when reset
    (goto-char (point-min)))
  ;; TODO: Horribly inefficient, possibly improve by considering less errors.
  (let* ((err-positions (-map 'flycheck-error-pos flycheck-current-errors))
         ;; Remove the current point for the errors because we don't want to
         ;; navigate to the current error again
         (navigatable-errors (--remove (= (point) it) err-positions))
         (splitted (--split-with (>= (point) it) navigatable-errors))
         (pos-before (nreverse (car splitted)))
         (pos-after (cadr splitted))
         (positions (if (< no-errors 0) pos-before pos-after))
         (pos (nth (- (abs no-errors) 1) positions)))
    (if pos
        (goto-char pos)
      (user-error "No more Flycheck errors"))))


;;;; Error message echoing
(defun flycheck-may-show-message ()
  "Determine whether the minibuffer is free to show a message.

Return t if the minibuffer is free to show message or nil otherwise.

The minibuffer is considered free if the minibuffer is not active
and the cursor is not in the minibuffer."
  (and (not (active-minibuffer-window)) (not cursor-in-echo-area)))

(defvar-local flycheck-error-display-timer nil
  "Timer to automatically show the error at point in minibuffer.")

(defun flycheck-cancel-error-display-timer ()
  "Cancel the error display timer for the current buffer."
  (when flycheck-error-display-timer
    (cancel-timer flycheck-error-display-timer)
    (setq flycheck-error-display-timer nil)))

(defun flycheck-show-error-at-point ()
  "Show the first error message at point in minibuffer."
  (interactive)
  (flycheck-cancel-error-display-timer)
  (when flycheck-mode
    (if (flycheck-may-show-message)
        (let ((message (car (flycheck-overlay-messages-at (point)))))
          (if message
              (message "%s" message)
            (message nil)))
      ;; Try again if the minibuffer is busy at the moment
      (flycheck-show-error-at-point-soon))))

(defun flycheck-show-error-at-point-soon ()
  "Show the first error message at point in minibuffer asap.

Show the error message at point in minibuffer after a short delay."
  (flycheck-cancel-error-display-timer)
  (when (flycheck-overlays-at (point))
    (setq flycheck-error-display-timer
          (run-at-time 0.9 nil 'flycheck-show-error-at-point))))


;;;; Checker process management
(defvar-local flycheck-current-process nil
  "The current syntax checking process.")

(defun flycheck-running-p ()
  "Determine whether a syntax check is running."
  (when (and flycheck-current-process
             (memq (process-status flycheck-current-process) '(exit signal)))
    (flycheck-post-syntax-check-cleanup)
    (setq flycheck-current-process nil))
  (when flycheck-current-process t))

(defun flycheck-post-syntax-check-cleanup (&optional process)
  "Cleanup after a syntax check PROCESS."
  (unwind-protect
      (let ((process (or process flycheck-current-process)))
        (when process
          (setq flycheck-current-process nil)
          (delete-process process)))
    (flycheck-clean-substituted-files)))

(defun flycheck-receive-checker-output (process output)
  "Receive a syntax checking PROCESS OUTPUT."
  (let ((pending-output (process-get process :flycheck-pending-output)))
    (process-put process :flycheck-pending-output
                 (cons output pending-output))))

(defun flycheck-get-output (process)
  "Get the complete output of PROCESS."
  (with-demoted-errors
    (let ((pending-output (process-get process :flycheck-pending-output)))
      (apply #'concat (nreverse pending-output)))))

(defun flycheck-finish-syntax-check (checker exit-status output)
  "Finish a syntax check with CHECKER.

CHECKER is the checker used during this check.  EXIT-STATUS is
the integral exit code of the syntax checker and OUTPUT its
output a string.

Parse the output and report an appropriate error status."
  (flycheck-report-status "")
  (let* ((error-patterns (flycheck-checker-error-patterns checker))
         (parsed-errors (flycheck-parse-output output (current-buffer)
                                               error-patterns))
         (errors (flycheck-sort-errors
                  (flycheck-sanitize-errors parsed-errors))))
    (when flycheck-mode
      (setq flycheck-current-errors errors)
      (flycheck-report-errors errors)
      (when (and (/= exit-status 0) (not errors))
        ;; Report possibly flawed checker definition
        (message "Checker %s returned non-zero exit code %s, but no errors from\
output: %s\nChecker definition probably flawed."
                 checker exit-status output)
        (flycheck-report-status "?"))
      (when (eq (current-buffer) (window-buffer))
        (flycheck-show-error-at-point))
      (run-hooks 'flycheck-after-syntax-check-hook))))

(defun flycheck-handle-signal (process event)
  "Handle a syntax checking PROCESS EVENT."
  (when (memq (process-status process) '(signal exit))
    (with-current-buffer (process-buffer process)
      (unwind-protect
          (condition-case-unless-debug err
              (when (buffer-live-p (process-buffer process))
                (flycheck-finish-syntax-check
                 (process-get process :flycheck-checker)
                 (process-exit-status process)
                 (flycheck-get-output process)))
            (error
             (flycheck-report-status "!")
             (signal (car err) (cdr err))))
        (flycheck-post-syntax-check-cleanup process)))))

(defun flycheck-start-checker (checker)
  "Start a syntax CHECKER."
  (condition-case err
      (let* ((command (flycheck-checker-substituted-command checker))
             (program (car command))
             (args (cdr command))
             (process (apply 'start-file-process
                             "flycheck" (current-buffer)
                             program args)))
        (setq flycheck-current-process process)
        (set-process-filter process 'flycheck-receive-checker-output)
        (set-process-sentinel process 'flycheck-handle-signal)
        (set-process-query-on-exit-flag process nil)
        (flycheck-report-status "*")
        (process-put process :flycheck-checker checker))
      (error
       (flycheck-report-status "!")
       (flycheck-post-syntax-check-cleanup)
       (signal (car err) (cdr err)))))

(defun flycheck-stop-checker ()
  "Stop any syntax checker for the current buffer."
  (when (flycheck-running-p)
    (interrupt-process flycheck-current-process)))


;;;; Built-in checkers
(flycheck-declare-checker bash
  "A Bash syntax checker using the bash executable.

See URL `http://www.gnu.org/software/bash/'."
  :command '("bash" "--norc" "-n" source)
  :error-patterns '(("^\\(?1:.+\\): line \\(?2:[0-9]+\\): \\(?4:.*\\)$" error))
  :modes 'sh-mode
  :predicate '(eq sh-shell 'bash))

(flycheck-def-config-file-var flycheck-coffeelintrc coffee-coffeelint
                              ".coffeelint.json")

(flycheck-declare-checker coffee-coffeelint
  "A CoffeeScript syntax and style checker using coffeelint.

See URL `http://www.coffeelint.org/'."
  :command '("coffeelint" (config "--file" flycheck-coffeelintrc) "--csv" source)
  :error-patterns
  '(("SyntaxError: \\(?4:.*\\) on line \\(?2:[0-9]+\\)" error)
    ("\\(?1:.+\\),\\(?2:[0-9]+\\),error,\\(?4:.+\\)" error)
    ("\\(?1:.+\\),\\(?2:[0-9]+\\),warn,\\(?4:.+\\)" warning))
  :modes 'coffee-mode)

(flycheck-declare-checker css-csslint
  "A CSS syntax and style checker using csslint.

See URL `https://github.com/stubbornella/csslint'."
  :command '("csslint" "--format=compact" source)
  :error-patterns
  '(("^\\(?1:.*\\): line \\(?2:[0-9]+\\), col \\(?3:[0-9]+\\), Error - \\(?4:.+\\)$"
     error)
    ("^\\(?1:.*\\): line \\(?2:[0-9]+\\), col \\(?3:[0-9]+\\), Warning - \\(?4:.+\\)$"
     warning))
  :modes 'css-mode)

(defconst flycheck-emacs-lisp-check-form
  '(progn
     ;; Initialize packages to at least try to load dependencies
     (package-initialize)

     (setq byte-compiled-files nil)
     (defun byte-compile-dest-file (source)
       (let ((temp-file (expand-file-name (make-temp-file source)
                                          temporary-file-directory)))
         (add-to-list 'byte-compiled-files temp-file)
         temp-file))

     (setq byte-compile-dest-file-function 'byte-compile-dest-file)
     (mapc 'byte-compile-file command-line-args-left)
     (mapc 'delete-file byte-compiled-files)))

(flycheck-declare-checker emacs-lisp
  "An Emacs Lisp syntax checker.

This checker simply attempts to byte compile the contents of the
buffer using the currently running Emacs executable."
  :command `(,(concat invocation-directory invocation-name)
             "--no-site-file" "--no-site-lisp" "--batch" "--eval"
             ,(prin1-to-string flycheck-emacs-lisp-check-form) source-inplace)
  :error-patterns
  '(("^\\(?1:.*\\):\\(?2:[0-9]+\\):\\(?3:[0-9]+\\):Warning:\\(?4:.*\\(?:\n    .*\\)*\\)$"
     warning)
    ("^\\(?1:.*\\):\\(?2:[0-9]+\\):\\(?3:[0-9]+\\):Error:\\(?4:.*\\(?:\n    .*\\)*\\)$"
     error))
  :modes '(emacs-lisp-mode lisp-interaction-mode)
  ;; Ensure that we only check buffers with a backing file.  For buffers without
  ;; a backing file we cannot guarantee that file names in error messages are
  ;; properly resolved, because `byte-compile-file' emits file names *relative
  ;; to the directory of the checked file* instead of the working directory.
  ;; Hence our backwards-substitution will fail, because the checker process has
  ;; a different base directory to resolve relative file names than the flycheck
  ;; code working on the buffer to check.
  :predicate '(and (buffer-file-name)
                   ;; Do not check buffers which should not be byte-compiled.
                   ;; The checker process will refuse to compile these anyway
                   (not (and (boundp 'no-byte-compile) no-byte-compile))
                   ;; Do not check temporary buffers of `byte-compile-file' or
                   ;; autoload buffers created during package installation.
                   ;; Checking these interferes with package installation, see
                   ;; https://github.com/lunaryorn/flycheck/issues/45 and
                   ;; https://github.com/bbatsov/prelude/issues/248
                   (not (string= (buffer-name) " *Compiler Input*"))
                   (not (s-ends-with? "-autoloads.el" (buffer-name)))))

(flycheck-declare-checker haml
  "A Haml syntax checker using the Haml compiler.

See URL `http://haml.info'."
  :command '("haml" "-c" source)
  :error-patterns
  '(("^Syntax error on line \\(?2:[0-9]+\\): \\(?4:.*\\)$" error))
  :modes 'haml-mode)

(flycheck-def-config-file-var flycheck-tidyrc html-tidy ".tidyrc")

(flycheck-declare-checker html-tidy
  "A HTML syntax and style checker using Tidy.

See URL `https://github.com/w3c/tidy-html5'."
  :command '("tidy" (config "-config" flycheck-tidyrc) "-e" "-q" source)
  :error-patterns
  '(("^line \\(?2:[0-9]+\\) column \\(?3:[0-9]+\\) - Error: \\(?4:.*\\)$" error)
    ("^line \\(?2:[0-9]+\\) column \\(?3:[0-9]+\\) - Warning: \\(?4:.*\\)$"
     warning))
  :modes '(html-mode nxhtml-mode))

(flycheck-def-config-file-var flycheck-jshintrc javascript-jshint ".jshintrc")

(flycheck-declare-checker javascript-jshint
  "A JavaScript syntax and style checker using jshint.

See URL `http://www.jshint.com'."
  :command '("jshint" (config "--config" flycheck-jshintrc) source)
  :error-patterns
  '(("^\\(?1:.*\\): line \\(?2:[0-9]+\\), col \\(?3:[0-9]+\\), \\(?4:.+\\)$"
     error))
  :modes '(js-mode js2-mode js3-mode))

(flycheck-declare-checker json-jsonlint
  "A JSON syntax and style checker using jsonlint.

See URL `https://github.com/zaach/jsonlint'."
  :command '("jsonlint" "-c" "-q" source)
  :error-patterns
  '(("^\\(?1:.+\\)\: line \\(?2:[0-9]+\\), col \\(?3:[0-9]+\\), \\(?4:.+\\)$"
     error))
  :predicate '(or
               (eq major-mode 'json-mode)
               (and buffer-file-name
                    (string= "json" (file-name-extension buffer-file-name)))))

(flycheck-declare-checker lua
  "A Lua syntax checker using the Lua compiler.

See URL `http://www.lua.org/'."
  :command '("luac" "-p" source)
  :error-patterns
  '(("^.*?: \\(?1:.*?\\):\\(?2:[0-9]+\\): \\(?4:.*\\)$" error))
  :modes 'lua-mode)

(flycheck-declare-checker perl
  "A Perl syntax checker using the Perl interpreter.

See URL `http://www.perl.org'."
  :command '("perl" "-w" "-c" source)
  :error-patterns
  '(("^\\(?4:.*?\\) at \\(?1:.*?\\) line \\(?2:[0-9]+\\)\\.$" error)
    ("^\\(?4:.*?\\) at \\(?1:.*?\\) line \\(?2:[0-9]+\\), .*$" error))
  :modes '(perl-mode cperl-mode))

(flycheck-declare-checker php
  "A PHP syntax checker using the PHP command line.

See URL `http://php.net/manual/en/features.commandline.php'."
  :command '("php" "-l" "-d" "error_reporting=E_ALL" "-d" "display_errors=1"
             "-d" "log_errors=0" source)
  :error-patterns
  '(("\\(?:Parse\\|Fatal\\|syntax\\) error[:,] \\(?4:.*\\) in \\(?1:.*\\) on line \\(?2:[0-9]+\\)"
    error))
  :modes '(php-mode php+-mode))

(flycheck-def-config-file-var flycheck-flake8rc python-flake8 ".flake8rc")

(flycheck-declare-checker python-flake8
  "A Python syntax and style checker using the flake8 utility.

See URL `http://pypi.python.org/pypi/flake8'."
  :command '("flake8" (config "--config" flycheck-flake8rc) source-inplace)
  :error-patterns
  '(("^\\(?1:.*?\\):\\(?2:[0-9]+\\):\\(?:\\(?3:[0-9]+\\):\\)? \\(?4:E[0-9]+.*\\)$"
     error)
    ("^\\(?1:.*?\\):\\(?2:[0-9]+\\):\\(?:\\(?3:[0-9]+\\):\\)? \\(?4:W[0-9]+.*\\)$"
     warning)
    ("^\\(?1:.*\\):\\(?2:[0-9]+\\): \\(?4:.*\\)$" error))
  :modes 'python-mode)

(flycheck-declare-checker python-pylint
  "A Python syntax and style checker using the pylint utility.

See URL `http://pypi.python.org/pypi/pylint'."
  :command '("epylint" source-inplace)
  :error-patterns
  '(("^\\(?1:.*\\):\\(?2:[0-9]+\\): Warning (W.*): \\(?4:.*\\)$" warning)
    ("^\\(?1:.*\\):\\(?2:[0-9]+\\): Error (E.*): \\(?4:.*\\)$" error)
    ("^\\(?1:.*\\):\\(?2:[0-9]+\\): \\[F\\] \\(?4:.*\\)$" error))
  :modes 'python-mode)

(flycheck-declare-checker python-pyflakes
  "A Python syntax and style checker using the pyflakes utility.

See URL `http://pypi.python.org/pypi/pyflakes'."
  :command '("pyflakes" source-inplace)
  :error-patterns '(("^\\(?1:.*\\):\\(?2:[0-9]+\\): \\(?4:.*\\)$" error))
  :modes 'python-mode)

(flycheck-declare-checker ruby
  "A Ruby syntax checker using the Ruby interpreter."
  :command '("ruby" "-w" "-c" source)
  :error-patterns '(("^\\(?1:.*\\):\\(?2:[0-9]+\\): \\(?4:.*\\)$" error))
  :modes 'ruby-mode)

(flycheck-declare-checker sass
  "A Sass syntax checker using the Sass compiler.

See URL `http://sass-lang.com'."
  :command '("sass" "-c" source)
  :error-patterns
  '(("^Syntax error on line \\(?2:[0-9]+\\): \\(?4:.*\\)$" error)
    ("^WARNING on line \\(?2:[0-9]+\\) of \\(?1:.*\\):\r?\n\\(?4:.*\\)$"
     warning)
    ("^Syntax error: \\(?4:.*\\)\r?\n        on line \\(?2:[0-9]+\\) of \\(?1:.*\\)$"
     error))
  :modes 'sass-mode)

(flycheck-declare-checker sh
  "A POSIX Shell syntax checker using the dash executable.

See URL `http://gondor.apana.org.au/~herbert/dash/'."
  :command '("dash" "-n" source)
  :error-patterns '(("^\\(?1:.+\\): \\(?2:[0-9]+\\): \\1: \\(?4:.*\\)$" error))
  :modes 'sh-mode
  :predicate '(eq sh-shell 'sh))

(flycheck-def-config-file-var flycheck-chktexrc tex-chktex ".chktexrc")

(flycheck-declare-checker tex-chktex
  "A TeX and LaTeX syntax and style checker using chktex.

See URL `http://baruch.ev-en.org/proj/chktex/'."
  :command '("chktex" (config "-l" flycheck-chktexrc) "-v0" "-q" "-I"
             source-inplace)
  :error-patterns
  '(("^\\(?1:.*\\):\\(?2:[0-9]+\\):\\(?3:[0-9]+\\):\\(?4:[0-9]+:.*\\)$"
     warning))
  :modes '(latex-mode plain-tex-mode))

(flycheck-declare-checker tex-lacheck
  "A LaTeX syntax and style checker using lacheck.

See URL `http://www.ctan.org/pkg/lacheck'."
  :command '("lacheck" source-inplace)
  :error-patterns
  '(("^\"\\(?1:.*\\)\", line \\(?2:[0-9]+\\): \\(?4:.*\\)$" warning))
  :modes 'latex-mode)

(flycheck-declare-checker xml-xmlstarlet
  "A XML validator using the xmlstarlet utility.

See URL `http://xmlstar.sourceforge.net/'."
  :command '("xmlstarlet" "val" "-e" "-q" source)
  :error-patterns
  '(("^\\(?1:.*\\):\\(?2:[0-9]+\\)\\.\\(?3:[0-9]+\\): \\(?4:.*\\)$" error))
  :modes '(xml-mode nxml-mode))

(flycheck-declare-checker zsh
  "A Zsh syntax checker using the zsh executable.

See URL `http://www.zsh.org/'."
  :command '("zsh" "-n" "-d" "-f" source)
  :error-patterns '(("^\\(?1:.*\\):\\(?2:[0-9]+\\): \\(?4:.*\\)$" error))
  :modes 'sh-mode
  :predicate '(eq sh-shell 'zsh))

(provide 'flycheck)

;;; flycheck.el ends here
