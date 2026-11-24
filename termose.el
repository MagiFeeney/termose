;;; termose.el --- Terminal Composer: A Compositional Command-line Interface -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Magi Feeney

;; Author: Magi Feeney <matrixfeeney@gmail.com>
;; Version: 0.3.0
;; Package-Requires: ((emacs "28.1") (transient "0.4"))
;; Keywords: terminals, processes, convenience
;; URL: https://github.com/MagiFeeney/termose

;; This file is not part of GNU Emacs.  License: GPL-3.0-or-later.

;;; Commentary:

;; Termose composes a command in a small buffer, send it
;; to vterm / ghostel / eat / term / shell / eshell.
;;
;;   M-x termose        open the composer alone or from region
;;   M-x termose-menu   open the composer with a menu of options
;;
;; In the composer:
;;   \        pops up the option list (corfu, company or *Completions*)
;;   C-c C-c  send and run      C-c C-j  send without RET
;;   C-c C-o  menu              C-c C-k  cancel
;;   M-p/M-n  history (filtered by what you typed)   M-r  search history
;;
;; Notebook with org mode is supported. Store commands and retrieve with keywords.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'seq)
(require 'sh-script)
(require 'transient)

(declare-function vterm-send-string "ext:vterm" (string &optional paste-p))
(declare-function vterm-send-return "ext:vterm" ())
(declare-function ghostel-send-string "ext:ghostel" (string))
(declare-function ghostel-send-key "ext:ghostel" (key &optional modifiers))
(declare-function comint-send-input "comint" (&optional no-newline artificial))
(declare-function eshell-send-input "esh-mode" (&optional use-region queue-p no-newline))
(defvar savehist-additional-variables)
(defvar org-directory)
(declare-function company-complete "ext:company" ())
(declare-function org-element-map "org-element")
(declare-function org-element-parse-buffer "org-element")
(declare-function org-element-property "org-element")
(declare-function org-element-lineage "org-element")
(declare-function org-element-type "org-element")
(declare-function org-end-of-subtree "org")
(declare-function org-escape-code-in-string "org-src")
(declare-function denote-directory-files "ext:denote")
(declare-function org-roam-db-query "ext:org-roam-db")

;;;; User options

(defgroup termose nil
  "Compose terminal commands."
  :group 'terminals)

(defcustom termose-options
  '(("gpu"  "CUDA_VISIBLE_DEVICES=%s" :default "0" :match "[0-9,]+")
    ("uv"   "uv run" :at front)
    ("time" "time" :at front)
    ("srun" "srun --gres=gpu:%s" :at front :default "1" :match "[0-9]+")
    ("log"  "2>&1 | tee %s" :at end :default "run.log" :match "\\S-*[./]\\S-*")
    ("bg"   "&" :at end)
    ("tmux" "tmux new -d -s %s {qcmd}" :key "x"))
  "Options written as \\NAME in the composer.
Each entry is (NAME EXPANSION . PROPERTIES).  See the file commentary."
  :type '(repeat (cons (string :tag "Name")
                       (cons (choice (string :tag "Expansion") function)
                             (plist :tag "Properties"
                                    :options ((:default string) (:match regexp)
                                              (:at (choice (const front) (const end)))
                                              (:key string)))))))

(defcustom termose-templates
  '(("uv"
     ("run"  "uv run {{script:main.py}} {{_}}")
     ("add"  "uv add {{packages}}")
     ("sync" "uv sync"))
    ("slurm"
     ("interactive" "srun --partition={{partition|gpu|cpu}} --gres=gpu:{{gpus:1}} --time={{time:04:00:00}} --pty bash")
     ("batch"  "sbatch --job-name={{name:job}} --gres=gpu:{{gpus:1}} --wrap='{{_}}'")
     ("queue"  "squeue -u $USER")
     ("cancel" "scancel {{jobid}}"))
    ("loop"
     ("files"  "for f in {{glob:*}}; do {{_}} \"$f\"; done")
     ("range"  "for i in $(seq {{from:1}} {{to:10}}); do {{_}}; done")
     ("values" "for v in {{values:1 2 3}}; do {{_}}; done")
     ("lines"  "while IFS= read -r line; do {{_}}; done < {{file}}"))
    ("system"
     ("gpus"   "watch -n 1 nvidia-smi")
     ("disk"   "du -sh {{path:.}}/* | sort -h")
     ("port"   "lsof -i :{{port:8000}}")))
  "Template groups: (GROUP (NAME TEMPLATE . PROPERTIES) ...).
PROPERTIES may contain :key.  Group keys are uppercase letters."
  :type '(repeat (cons (string :tag "Group")
                       (repeat (cons (string :tag "Name")
                                     (cons (string :tag "Template")
                                           (plist :options ((:key string)))))))))

(defcustom termose-prefix "\\"
  "String that starts an option token."
  :type 'string)

(defcustom termose-auto-popup t
  "Non-nil means typing `termose-prefix' pops up the option list."
  :type 'boolean)

(defcustom termose-backends
  '((vterm-mode   . termose--send-vterm)
    (ghostel-mode . termose--send-ghostel)
    (eat-mode     . termose--send-raw)
    (term-mode    . termose--send-raw)
    (eshell-mode  . termose--send-eshell)
    (comint-mode  . termose--send-comint))
  "Terminal modes and how to send to them.
Each FUNCTION gets BUFFER, STRING and EXECUTE."
  :type '(alist :key-type symbol :value-type function))

(defcustom termose-new-terminal '(vterm ghostel eat ansi-term shell)
  "Commands tried, in order, to make a terminal when none exists.
In a remote (TRAMP) directory, `termose-local-only-terminals' are skipped."
  :type '(repeat function))

(defcustom termose-local-only-terminals '(ansi-term term)
  "Terminal commands that always start a local shell, even under TRAMP."
  :type '(repeat function))

(defcustom termose-display-action
  '((display-buffer-reuse-window display-buffer-at-bottom) (window-height . 6))
  "How the composer window is shown."
  :type 'sexp)

(defface termose-option '((t :inherit font-lock-builtin-face :weight bold))
  "Face for known option tokens.")
(defface termose-preview '((t :inherit shadow :slant italic))
  "Face for the expanded-command preview.")

;;;; State

(defvar termose-history nil "Sent commands, newest first, as typed.")
(put 'termose-history 'history-length 300)
(defvar termose--target nil "Buffer commands go to.")
(defvar termose--origin nil "Window the composer was opened from.")
(defvar termose--origin-host nil "TRAMP host of the buffer the composer was opened from.")
(defvar termose--group nil "Template group shown by the template menu.")
(defvar-local termose--overlay nil)
(defvar-local termose--hist-pos -1)
(defvar-local termose--draft "")
(defconst termose--buffer "*termose*")

;;;; Options and parsing

(defun termose--opt (name) (assoc name termose-options))
(defun termose--prop (opt key) (plist-get (cddr opt) key))

(defun termose--nargs (opt)
  (let ((e (cadr opt)))
    (if (functionp e)
        (car (func-arity e))
      (1- (length (split-string (replace-regexp-in-string "%%" "" e) "%s"))))))

(defun termose--defaults (opt)
  (let ((d (termose--prop opt :default))) (if (listp d) d (list d))))

(defun termose--word-end (s i)
  "End of the shell word starting at I in S."
  (let ((n (length s)) q)
    (while (and (< i n) (or q (not (memq (aref s i) '(?\s ?\t ?\n ?\; ?| ?& ?\( ?\))))))
      (let ((c (aref s i)))
        (cond ((and (eq c ?\\) (not (eq q ?'))) (cl-incf i))
              ((eq c q) (setq q nil))
              ((and (not q) (memq c '(?' ?\")) (setq q c)))))
      (cl-incf i))
    (min i n)))

(defun termose--skip-blanks (s i)
  (while (and (< i (length s)) (memq (aref s i) '(?\s ?\t))) (cl-incf i))
  i)

(defun termose--token-at (s i)
  "If an option token starts at I in S, return (OPT . NAME-END)."
  (let ((p termose-prefix) (case-fold-search nil))
    (when (and (or (= i 0) (memq (aref s (1- i)) '(?\s ?\t ?\n ?\; ?| ?& ?\()))
               (string-prefix-p p (substring s i))
               (eq (string-match "[[:alpha:]_][[:alnum:]_-]*" s (+ i (length p)))
                   (+ i (length p))))
      (let ((opt (termose--opt (match-string 0 s))) (e (match-end 0)))
        (when (and opt (or (= e (length s)) (memq (aref s e) '(?\s ?\t ?\n ?= ?\; ?| ?& ?\)))))
          (cons opt e))))))

(defun termose--args (s j opt ask)
  "Read OPT's args from S at J.  Return (ARGS . END)."
  (let ((n (termose--nargs opt)) (defs (termose--defaults opt))
        (re (termose--prop opt :match)) args)
    (when (and (> n 0) (< j (length s)) (eq (aref s j) ?=))
      (let ((e (termose--word-end s (1+ j))))
        (push (substring s (1+ j) e) args)
        (setq j e)))
    (while (< (length args) n)
      (let* ((k (length args))
             (p (termose--skip-blanks s j))
             (e (termose--word-end s p))
             (w (substring s p e)))
        (if (and (> e p) (not (termose--token-at s p))
                 (or (null re) (string-prefix-p "$" w)
                     (string-match-p (concat "\\`\\(?:" re "\\)\\'") w)))
            (progn (push w args) (setq j e))
          (push (or (nth k defs)
                    (if ask (read-string (format "%s%s arg %d: " termose-prefix (car opt) (1+ k)))
                      "<?>"))
                args))))
    (cons (nreverse args) j)))

(defun termose--scan (s &optional ask)
  "Return option tokens in S as (OPT BEG END ARGS), skipping quoted text."
  (let ((i 0) (n (length s)) q toks)
    (while (< i n)
      (let ((c (aref s i)) tok)
        (cond
         (q (cond ((and (eq c ?\\) (eq q ?\")) (cl-incf i)) ((eq c q) (setq q nil)))
            (cl-incf i))
         ((setq tok (termose--token-at s i))
          (pcase-let ((`(,args . ,end) (termose--args s (cdr tok) (car tok) ask)))
            (push (list (car tok) i end args) toks)
            (setq i end)))
         ((eq c ?\\) (cl-incf i 2))
         (t (when (memq c '(?' ?\")) (setq q c)) (cl-incf i)))))
    (nreverse toks)))

(defun termose--render (opt args)
  (let ((e (cadr opt)))
    (if (functionp e) (apply e args) (apply #'format e args))))

(defun termose--place (opt text)
  (cond ((string-match-p "{q?cmd}" text) 'wrap)
        ((termose--prop opt :at))
        ((string-match-p "\\`[A-Za-z_][A-Za-z0-9_]*=" text) 'front)
        (t 'here)))

;;;; Scoping: which command an option belongs to

(defun termose--match-close (s i)
  "Index after the bracket matching the one at I in S (quote-aware)."
  (let* ((open (aref s i)) (close (if (eq open ?\() ?\) ?})) (depth 0) (n (length s)) q)
    (catch 'done
      (while (< i n)
        (let ((c (aref s i)))
          (cond (q (cond ((and (eq c ?\\) (not (eq q ?'))) (cl-incf i))
                         ((eq c q) (setq q nil))))
                ((eq c ?\\) (cl-incf i))
                ((memq c '(?' ?\" ?`)) (setq q c))
                ((eq c open) (cl-incf depth))
                ((eq c close) (when (= (cl-decf depth) 0) (throw 'done (1+ i))))))
        (cl-incf i))
      n)))

(defun termose--lex-word-end (s i)
  "End of the shell word at I in S: quotes, $(..), ${..} and redirects stay whole."
  (let ((n (length s)) q done)
    (while (and (< i n) (not done))
      (let ((c (aref s i))
            (prev (and (> i 0) (aref s (1- i))))
            (next (and (< (1+ i) n) (aref s (1+ i)))))
        (cond
         (q (cond ((and (eq c ?\\) (not (eq q ?'))) (cl-incf i 2))
                  ((eq c q) (setq q nil) (cl-incf i))
                  (t (cl-incf i))))
         ((eq c ?\\) (cl-incf i 2))
         ((memq c '(?' ?\" ?`)) (setq q c) (cl-incf i))
         ((and (memq c '(?$ ?< ?>)) (eq next ?\()) (setq i (termose--match-close s (1+ i))))
         ((and (eq c ?$) (eq next ?{)) (setq i (termose--match-close s (1+ i))))
         ((memq c '(?\s ?\t ?\n ?\; ?\( ?\))) (setq done t))
         ((eq c ?&) (if (or (memq prev '(?< ?>)) (eq next ?>)) (cl-incf i) (setq done t)))
         ((eq c ?|) (if (eq prev ?>) (cl-incf i) (setq done t)))
         (t (cl-incf i)))))
    (min i n)))

(defun termose--lex (s toks)
  "Split S into items (TYPE TEXT BEG END).  TYPE is word, op or opt.
TOKS are option tokens; one starting an item becomes an opt item."
  (let ((i 0) (n (length s)) items)
    (while (< i n)
      (let ((c (aref s i))
            (next (and (< (1+ i) n) (aref s (1+ i)))))
        (while (and toks (< (nth 1 (car toks)) i)) (pop toks))
        (cond
         ((and toks (= i (nth 1 (car toks))))
          (let ((tk (pop toks)))
            (push (list 'opt tk i (nth 2 tk)) items)
            (setq i (nth 2 tk))))
         ((memq c '(?\s ?\t)) (cl-incf i))
         ((and (eq c ?\\) (eq next ?\n)) (cl-incf i 2))
         ((eq c ?#) (while (and (< i n) (not (eq (aref s i) ?\n))) (cl-incf i)))
         ((eq c ?\n) (push (list 'op "\n" i (1+ i)) items) (cl-incf i))
         ((and (eq c ?&) (eq next ?>))
          (let ((e (termose--lex-word-end s i))) (push (list 'word (substring s i e) i e) items) (setq i e)))
         ((memq c '(?\; ?& ?| ?\( ?\)))
          (let* ((len (if (or (and (eq c ?\;) (eq next ?\;)) (and (eq c ?&) (eq next ?&))
                              (and (eq c ?|) (memq next '(?| ?&))))
                          2 1))
                 (op (substring s i (+ i len))))
            (push (list 'op (pcase op (";;" ";") ("|&" "|") (_ op)) i (+ i len)) items)
            (cl-incf i len)))
         (t (let ((e (max (1+ i) (termose--lex-word-end s i))))
              (push (list 'word (substring s i e) i e) items)
              (setq i e))))))
    (nreverse items)))

(cl-defstruct (termose--cmd (:constructor termose--cmd-make) (:copier nil))
  beg end env front compound chain)
(cl-defstruct (termose--chain (:constructor termose--chain-make) (:copier nil))
  beg end suffix wraps)

(defconst termose--closers
  '(("done" "for" "select" "while" "until") ("fi" "if") ("esac" "case") ("}" "{") (")" "(")))

(defun termose--env-p (text) (string-match-p "\\`[A-Za-z_][A-Za-z0-9_]*=" text))

(defun termose--parse (s toks)
  "Find the commands and chains of S and attach option tokens TOKS to them.
TOKS are (OPT BEG END ARGS TEXT PLACE).  Return (CMDS . CHAINS)."
  (let (cmds chains chain cmd (at-cmd t) header pending stack last-cmd seen)
    (cl-labels
        ((touch (end) (when chain (setf (termose--chain-end chain)
                                        (max end (termose--chain-end chain)))))
         (new-chain (beg) (unless chain
                            (setq chain (termose--chain-make :beg beg :end beg))
                            (push chain chains)))
         (attach (tk c)
           (let ((ch (termose--cmd-chain c)) (text (nth 4 tk)))
             (pcase (nth 5 tk)
               ('front (if (termose--env-p text)
                           (setf (termose--cmd-env c) (append (termose--cmd-env c) (list text)))
                         (setf (termose--cmd-front c) (append (termose--cmd-front c) (list text)))))
               ('end (setf (termose--chain-suffix ch) (append (termose--chain-suffix ch) (list text))))
               ('wrap (setf (termose--chain-wraps ch) (append (termose--chain-wraps ch) (list text)))))))
         (start-cmd (beg end compound)
           (new-chain beg)
           (setq cmd (termose--cmd-make :beg beg :end end :compound compound :chain chain)
                 at-cmd nil last-cmd cmd)
           (push cmd cmds)
           (touch end)
           (dolist (tk (nreverse pending)) (attach tk cmd))
           (setq pending nil))
         (close-chain () (setq chain nil cmd nil at-cmd t))
         (open (kw beg end)
           (start-cmd beg end t)
           (push (list kw cmd chain) stack)
           (setq chain nil cmd nil at-cmd t
                 header (cond ((member kw '("for" "select")) 'for)
                              ((equal kw "case") 1))))
         (close (closer end)
           (let ((frame (car stack)))
             (when (and frame (member (car frame) (cdr (assoc closer termose--closers))))
               (pop stack)
               (setq cmd (nth 1 frame) chain (nth 2 frame) at-cmd nil header nil)
               (setf (termose--cmd-end cmd) end)
               (touch end)
               t))))
      (pcase-dolist (`(,type ,x ,beg ,end) (termose--lex s toks))
        (cond
         ((eq type 'opt)
          (push x seen)
          (unless (eq (nth 5 x) 'here)
            (cond ((integerp header) (attach x (nth 1 (car stack))))
                  ((or header at-cmd (null cmd)) (unless header (new-chain beg)) (push x pending))
                  (t (attach x cmd))))
          (touch end))
         ((integerp header)             ; inside case … esac: opaque
          (cond ((equal x "case") (cl-incf header))
                ((and (equal x "esac") (= (cl-decf header) 0)) (close "esac" end))))
         ((eq header 'for)
          (when (equal x "do") (setq header nil at-cmd t)))
         ((eq type 'op)
          (cond ((member x '(";" "&" "\n")) (close-chain))
                ((member x '("&&" "||" "|")) (touch end) (setq cmd nil at-cmd t))
                ((equal x "(") (if at-cmd (open "(" beg end) (touch end)))
                ((equal x ")") (unless (close ")" end) (touch end)))))
         (at-cmd
          (cond ((member x '("for" "select" "while" "until" "if" "case" "{")) (open x beg end))
                ((member x '("do" "then" "else" "elif" "!")) (close-chain))
                ((member x '("done" "fi" "esac" "}")) (close x end))
                (t (start-cmd beg end nil))))
         (cmd (setf (termose--cmd-end cmd) end) (touch end))))
      ;; Unclosed blocks (still typing): close them at the end of the text.
      (while stack
        (let ((frame (pop stack)))
          (setq cmd (nth 1 frame) chain (nth 2 frame))
          (setf (termose--cmd-end cmd) (length s))
          (touch (length s))))
      ;; Options with no command after them go to the last command;
      ;; options hidden inside a word, e.g. $(… \gpu …), to the command around them.
      (when last-cmd (dolist (tk (nreverse pending)) (attach tk last-cmd)))
      (dolist (tk toks)
        (unless (or (memq tk seen) (eq (nth 5 tk) 'here))
          (let ((c (or (car (sort (seq-filter (lambda (c) (<= (termose--cmd-beg c) (nth 1 tk)
                                                              (termose--cmd-end c)))
                                              cmds)
                                  (lambda (a b) (< (- (termose--cmd-end a) (termose--cmd-beg a))
                                                   (- (termose--cmd-end b) (termose--cmd-beg b))))))
                       last-cmd)))
            (when c (attach tk c)))))
      (cons cmds chains))))

(defun termose--quote (s)
  (concat "'" (replace-regexp-in-string "'" "'\\''" s t t) "'"))

(defun termose--cmd-fn (c)
  (let ((env (termose--cmd-env c)) (front (termose--cmd-front c)))
    (if (termose--cmd-compound c)
        (lambda (inner)
          (let ((x (string-trim inner)))
            (when front (setq x (concat (string-join front " ") " bash -c " (termose--quote x))))
            (when env (setq x (format "(export %s; %s)" (string-join env " ") x)))
            x))
      (lambda (inner) (string-join (append env front (list (string-trim inner))) " ")))))

(defun termose--chain-fn (ch)
  (let ((suffix (termose--chain-suffix ch)) (wraps (termose--chain-wraps ch)))
    (lambda (inner)
      (let ((x (string-trim inner)))
        (dolist (sfx suffix) (setq x (concat x " " sfx)))
        (dolist (w wraps x)
          (setq x (replace-regexp-in-string
                   "{qcmd}" (termose--quote x)
                   (replace-regexp-in-string "{cmd}" x w t t) t t)))))))

(defun termose--render-regions (s beg end regions)
  "Render S from BEG to END, replacing REGIONS (BEG END FN-OR-STRING RANK)."
  (let ((pos beg) (out ""))
    (while regions
      (let* ((r (pop regions)) (rb (nth 0 r)) (re (nth 1 r)) (f (nth 2 r)) children)
        (while (and regions (< (nth 0 (car regions)) re))
          (push (pop regions) children))
        (setq out (concat out (substring s pos rb)))
        (let* ((inner (termose--render-regions s rb re (nreverse children)))
               (text (if (functionp f) (funcall f inner) f)))
          (setq out (concat out text))
          (setq pos re)
          ;; A removed option leaves no double space behind.
          (when (and (equal f "") (or (string-empty-p out) (memq (aref out (1- (length out))) '(?\s ?\t))))
            (setq pos (min end (termose--skip-blanks s pos)))
            (when (or (= pos end) (memq (aref s pos) '(?\; ?\) ?\n)))
              (setq out (string-trim-right out))))
          ;; "cmd &" already ends the command: drop a following ";" (bash rejects "&;").
          (when (and (functionp f) (string-match-p "[^&]&\\'" text))
            (let ((q (min end (termose--skip-blanks s pos))))
              (when (and (< q end) (eq (aref s q) ?\;)
                         (not (and (< (1+ q) end) (eq (aref s (1+ q)) ?\;))))
                (setq pos (1+ q))))))))
    (concat out (substring s pos end))))

(defun termose-expand (string &optional ask)
  "Return STRING with its option tokens expanded.
Prefixes go in front of the command they are written in; suffixes and
wrappers apply to the `a && b | c' chain they are in; after done/fi/}
an option applies to the whole loop or block.
With ASK, prompt for missing arguments that have no default."
  (let* ((toks (mapcar (lambda (tk)
                         (let ((text (termose--render (car tk) (nth 3 tk))))
                           (append tk (list text (termose--place (car tk) text)))))
                       (termose--scan string ask)))
         (parsed (termose--parse string toks))
         (regions
          (append
           (mapcar (lambda (tk) (list (nth 1 tk) (nth 2 tk)
                                      (if (eq (nth 5 tk) 'here) (nth 4 tk) "") 2))
                   toks)
           (cl-loop for c in (car parsed)
                    when (or (termose--cmd-env c) (termose--cmd-front c))
                    collect (list (termose--cmd-beg c) (termose--cmd-end c) (termose--cmd-fn c) 1))
           (cl-loop for ch in (cdr parsed)
                    when (or (termose--chain-suffix ch) (termose--chain-wraps ch))
                    collect (list (termose--chain-beg ch) (termose--chain-end ch)
                                  (termose--chain-fn ch) 0)))))
    (setq regions (sort regions (lambda (a b)
                                  (cond ((/= (nth 0 a) (nth 0 b)) (< (nth 0 a) (nth 0 b)))
                                        ((/= (nth 1 a) (nth 1 b)) (> (nth 1 a) (nth 1 b)))
                                        (t (< (nth 3 a) (nth 3 b)))))))
    (if (and toks (null (car parsed)))
        ;; Only options, no command yet.
        (string-join (mapcar (lambda (tk) (nth 4 tk)) toks) " ")
      (string-trim (termose--render-regions string 0 (length string) regions)))))

;;;; Templates

(defun termose-fill (template)
  "Prompt for TEMPLATE's fields.  Return (TEXT . POINT-OFFSET)."
  (let ((pos 0) (out "") vals cursor)
    (while (string-match "{{\\([^}]*\\)}}" template pos)
      (let* ((spec (match-string 1 template))
             (mb (match-beginning 0))
             (me (match-end 0))
             (parts (split-string spec "|"))
             (name (car (split-string (car parts) ":")))
             (def (if (cdr parts) (cadr parts)
                    (and (string-match ":\\(.*\\)" spec) (match-string 1 spec)))))
        (setq out (concat out (substring template pos mb)))
        (if (equal spec "_")
            (setq cursor (length out))
          (unless (assoc name vals)
            (push (cons name
                        (if (cdr parts)
                            (completing-read (format "%s: " name) (cdr parts) nil nil nil nil def)
                          (read-string (format (if def "%s (%s): " "%s: ") name def) nil nil def)))
                  vals))
          (setq out (concat out (cdr (assoc name vals)))))
        (setq pos me)))
    (cons (concat out (substring template pos)) cursor)))

(defun termose-insert-template (template)
  "Fill TEMPLATE and insert it at point in the composer."
  (with-current-buffer (termose--composer)
    (let ((filled (termose-fill template)))
      ;; Insert at point, so templates nest: a loop first, then a command in it.
      (unless (or (bobp) (memq (char-before) '(?\s ?\t ?\n))) (insert " "))
      (let* ((start (point))
             (_ (insert (car filled)))
             (cursor (copy-marker (if (cdr filled) (+ start (cdr filled)) (point)))))
        (cond ((and (memq (char-before) '(?\s ?\t)) (memq (char-after) '(?\s ?\t)))
               (delete-char 1))
              ((and (memq (char-before) '(?\s ?\t)) (memq (char-after) '(?\; ?\))))
               (delete-char -1)))
        (unless (or (eobp) (memq (char-after) '(?\s ?\t ?\n ?\; ?\" ?\')))
          (insert " ") (backward-char))
        (goto-char cursor)
        (set-marker cursor nil)
        (dolist (w (get-buffer-window-list (current-buffer)))
          (set-window-point w (point)))))))

;;;; Completion popup

(defun termose--annotate (name)
  (let ((opt (termose--opt name)))
    (when opt
      (concat (make-string (max 1 (- 7 (length name))) ?\s)
              (if (stringp (cadr opt)) (cadr opt) "λ")))))

(defun termose-completion-at-point ()
  "Complete option names after `termose-prefix'."
  (let* ((end (point))
         (beg (save-excursion (skip-chars-backward "[:alnum:]_-" (line-beginning-position)) (point)))
         (pb (- beg (length termose-prefix))))
    (when (and (>= pb (line-beginning-position))
               (equal termose-prefix (buffer-substring-no-properties pb beg))
               (or (= pb (line-beginning-position)) (memq (char-before pb) '(?\s ?\t))))
      (list beg end (mapcar #'car termose-options)
            :exclusive 'no
            :annotation-function #'termose--annotate
            :company-kind (lambda (_) 'keyword)
            :exit-function (lambda (_ status)
                             (when (and (eq status 'finished)
                                        (not (memq (char-after) '(?\s ?\t))))
                               (insert " ")))))))

(defun termose--maybe-popup ()
  (when (and termose-auto-popup
             (memq this-command '(self-insert-command org-self-insert-command))
             (let ((b (- (point) (length termose-prefix))))
               (and (>= b (line-beginning-position))
                    (equal termose-prefix (buffer-substring-no-properties b (point)))
                    (or (= b (line-beginning-position)) (memq (char-before b) '(?\s ?\t))))))
    (if (bound-and-true-p company-mode) (company-complete) (completion-at-point))))

;;;; Targets and sending

(defun termose--terminal-p (buf)
  (and (buffer-live-p buf)
       (with-current-buffer buf
         (and (apply #'derived-mode-p (mapcar #'car termose-backends))
              (or (derived-mode-p 'eshell-mode) (get-buffer-process buf))))))

(defun termose--host (buf)
  "TRAMP prefix of BUF's directory, or nil when local."
  (with-current-buffer buf (file-remote-p default-directory)))

(defun termose--guess-target ()
  (if (termose--terminal-p termose--target) termose--target
    (seq-find #'termose--terminal-p (buffer-list))))

(defun termose--target-label ()
  "Where the next command goes, with a warning on a host mismatch."
  (let* ((tgt (termose--guess-target))
         (host (if tgt (termose--host tgt) termose--origin-host)))
    (concat (if tgt (buffer-name tgt) "new terminal")
            (if host (format " @%s" (file-remote-p host 'host)) "")
            (when (and tgt termose--origin-host (not (equal host termose--origin-host)))
              (propertize (format "  ⚠ file is on %s" (file-remote-p termose--origin-host 'host))
                          'face 'warning)))))

(defun termose--new-terminal ()
  "Start a terminal in `default-directory', remote or local."
  (let* ((remote (file-remote-p default-directory))
         (cmd (seq-find (lambda (c) (and (fboundp c)
                                         (not (and remote (memq c termose-local-only-terminals)))))
                        termose-new-terminal))
         buf)
    (unless cmd (user-error "No usable terminal in `termose-new-terminal'"))
    (save-window-excursion
      (pcase cmd
        ('ansi-term (ansi-term (or (getenv "SHELL") "/bin/sh")))
        ((or 'vterm 'shell) (funcall cmd (generate-new-buffer-name (format "*%s*" cmd))))
        (_ (funcall cmd)))
      (setq buf (current-buffer)))
    (when (get-buffer-process buf) (accept-process-output (get-buffer-process buf) 0.3))
    buf))

(defun termose-set-target ()
  "Choose the terminal buffer that receives commands."
  (interactive)
  (let* ((names (mapcar #'buffer-name (seq-filter #'termose--terminal-p (buffer-list))))
         (pick (completing-read "Send to: " (append names '("[new terminal]")) nil t)))
    (setq termose--target (if (member pick names) (get-buffer pick)
                            (with-current-buffer (termose--composer) (termose--new-terminal))))))

(defun termose--send-vterm (buf str exec)
  (with-current-buffer buf (vterm-send-string str t) (when exec (vterm-send-return))))

(defun termose--send-ghostel (buf str exec)
  (with-current-buffer buf (ghostel-send-string str) (when exec (ghostel-send-key "return"))))

(defun termose--send-comint (buf str exec)
  (with-current-buffer buf
    (goto-char (point-max)) (insert str) (when exec (comint-send-input))))

(defun termose--send-eshell (buf str exec)
  (with-current-buffer buf
    (goto-char (point-max)) (insert str) (when exec (eshell-send-input))))

(defun termose--send-raw (buf str exec)
  (process-send-string (get-buffer-process buf) (concat str (if exec "\r" ""))))

(defun termose-send-string (string &optional buffer execute)
  "Send STRING to BUFFER (default: the target), pressing RET if EXECUTE."
  (let* ((buf (or buffer (termose--guess-target) (termose--new-terminal)))
         (fn (with-current-buffer buf
               (cdr (seq-find (lambda (b) (derived-mode-p (car b))) termose-backends)))))
    (setq termose--target buf)
    (funcall (or fn #'termose--send-raw) buf string execute)
    (dolist (w (get-buffer-window-list buf nil t))
      (with-current-buffer buf (set-window-point w (point))))
    buf))

;;;; Composer

(defun termose--composer () (get-buffer-create termose--buffer))
(defun termose--text () (string-trim (with-current-buffer (termose--composer) (buffer-string))))

(defun termose-send (&optional no-execute)
  "Expand the composer text and send it.  With NO-EXECUTE, don't press RET."
  (interactive "P")
  (let ((raw (termose--text)))
    (when (string-empty-p raw) (user-error "Nothing to send"))
    (let* ((cmd (termose-expand raw t))
           (win (get-buffer-window termose--buffer))
           ;; Pick/create the target here, in the composer's (maybe remote) directory.
           (target (with-current-buffer (termose--composer)
                     (or (termose--guess-target) (termose--new-terminal)))))
      (setq termose-history (cons raw (delete raw termose-history)))
      (when win (quit-window nil win))
      (when (window-live-p termose--origin) (select-window termose--origin))
      (let ((buf (termose-send-string cmd target (not no-execute))))
        (unless (get-buffer-window buf 'visible) (display-buffer buf))
        (message "→ %s: %s" (buffer-name buf) cmd)))))

(defun termose-send-no-execute ()
  "Send the composer text without pressing RET."
  (interactive)
  (termose-send t))

(defun termose-cancel ()
  "Close the composer."
  (interactive)
  (let ((win (get-buffer-window termose--buffer)))
    (when win (quit-window nil win))
    (when (window-live-p termose--origin) (select-window termose--origin))))

(defun termose--hist-matches ()
  "History entries starting with the text typed before browsing."
  (seq-filter (lambda (h) (string-prefix-p termose--draft h)) termose-history))

(defun termose--hist-show (text)
  (erase-buffer)
  (insert text))

(defun termose-history-prev (&optional n)
  "Show the previous history entry starting with what you typed.
Typing nothing browses all of history; M-n past the newest entry
gives your text back."
  (interactive "p")
  (when (< termose--hist-pos 0) (setq termose--draft (termose--text)))
  (let* ((items (termose--hist-matches))
         (i (max -1 (min (1- (length items)) (+ termose--hist-pos n)))))
    (unless items (user-error "No history%s"
                              (if (string-empty-p termose--draft) ""
                                (format " starting with %S" termose--draft))))
    (setq termose--hist-pos i)
    (termose--hist-show (if (< i 0) termose--draft (nth i items)))
    (message "History %d/%d" (1+ i) (length items))))

(defun termose-history-next (&optional n)
  "Show the next (newer) history entry."
  (interactive "p")
  (termose-history-prev (- n)))

(defun termose-history-search ()
  "Pick a command from history with completion."
  (interactive)
  (unless termose-history (user-error "No history"))
  (let ((pick (completing-read
               "History: "
               (lambda (str pred action)
                 (if (eq action 'metadata)
                     '(metadata (display-sort-function . identity))
                   (complete-with-action action termose-history str pred))))))
    (termose--hist-show pick)
    (setq termose--hist-pos -1)))

(with-eval-after-load 'savehist
  (add-to-list 'savehist-additional-variables 'termose-history))

(defun termose--update (&rest _)
  "Refresh the preview line."
  (unless (memq this-command '(termose-history-prev termose-history-next))
    (setq termose--hist-pos -1))
  (let* ((raw (string-trim (buffer-string)))
         (exp (condition-case e (termose-expand raw) (error (error-message-string e))))
         (s (if (equal exp raw) ""
              (concat "\n" (propertize (concat "⇒ " exp) 'face 'termose-preview)))))
    (unless termose--overlay
      (setq termose--overlay (make-overlay (point-max) (point-max) nil t)))
    (move-overlay termose--overlay (point-max) (point-max))
    (unless (string-empty-p s) (put-text-property 0 1 'cursor t s))
    (overlay-put termose--overlay 'after-string s)))

(defun termose--header ()
  (progn
    (concat (propertize (concat " → " (termose--target-label) " ") 'face 'mode-line-buffer-id)
            (substitute-command-keys
             "  \\<termose-mode-map>\\[termose-send] run  \\[termose-send-no-execute] insert  \\[termose-menu] menu  \\[termose-notebook] notebook  \\[termose-cancel] cancel  ")
            termose-prefix " options")))

(defun termose--fontify (limit)
  (let (found)
    (while (and (not found)
                (re-search-forward (concat (regexp-quote termose-prefix)
                                           "\\([[:alpha:]_][[:alnum:]_-]*\\)")
                                   limit t))
      (when (save-match-data
              (termose--token-at (buffer-substring-no-properties
                                  (line-beginning-position) (line-end-position))
                                 (- (match-beginning 0) (line-beginning-position))))
        (setq found t)))
    found))

(defvar termose-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "C-c C-c") #'termose-send)
    (define-key m (kbd "C-c C-j") #'termose-send-no-execute)
    (define-key m (kbd "C-c C-o") #'termose-menu)
    (define-key m (kbd "C-c C-k") #'termose-cancel)
    (define-key m (kbd "C-c C-n") #'termose-notebook)
    (define-key m (kbd "C-c C-a") #'termose-notebook-add)
    (define-key m (kbd "M-p") #'termose-history-prev)
    (define-key m (kbd "M-n") #'termose-history-next)
    (define-key m (kbd "M-r") #'termose-history-search)
    m))

(define-derived-mode termose-mode sh-mode "Termose"
  "Major mode of the termose composer.
Opening it never shows the menu; press \\[termose-menu] when you want it.
\\{termose-mode-map}"
  (setq-local header-line-format '(:eval (termose--header)))
  (setq-local tab-always-indent 'complete)
  (setq-local show-paren-data-function #'show-paren--default)
  (add-hook 'completion-at-point-functions #'termose-completion-at-point nil t)
  (add-hook 'after-change-functions #'termose--update nil t)
  (add-hook 'post-command-hook #'termose--maybe-popup nil t)
  (font-lock-add-keywords nil '((termose--fontify (0 'termose-option prepend)))))

;;;###autoload
(defun termose (&optional initial)
  "Open the composer, prefilled with INITIAL.
Interactively the region, or with \\[universal-argument] the last kill,
prefills it.  Opened from a terminal, that terminal is the target."
  (interactive
   (list (cond ((use-region-p)
                (prog1 (buffer-substring-no-properties (region-beginning) (region-end))
                  (deactivate-mark)))
               (current-prefix-arg (current-kill 0 t)))))
  (unless (eq (current-buffer) (get-buffer termose--buffer))
    (let ((host (file-remote-p default-directory)))
      (setq termose--origin-host host)
      (if (termose--terminal-p (current-buffer))
          (setq termose--target (current-buffer))
        ;; From a remote file, prefer a terminal on the same host.
        (when-let* ((same (and host (seq-find (lambda (b) (and (termose--terminal-p b)
                                                              (equal (termose--host b) host)))
                                             (buffer-list)))))
          (unless (equal (and (termose--terminal-p termose--target) (termose--host termose--target)) host)
            (setq termose--target same)))))
    (setq termose--origin (selected-window))
    (let ((dir default-directory))
      (with-current-buffer (termose--composer) (setq default-directory dir)))
    (with-current-buffer (termose--composer)
      (unless (derived-mode-p 'termose-mode)
        (let ((inhibit-message t) (sh-mode-hook nil) (prog-mode-hook nil))
          (termose-mode)))
      (erase-buffer)
      (setq termose--hist-pos -1 termose--draft "")
      (when initial (insert (string-trim initial)))
      (termose--update))
    (select-window (display-buffer (termose--composer) termose-display-action))))

;;;; Notebook

(defcustom termose-notebook-files nil
  "Your command notebook: a list of Org files, or a function returning one.
nil means commands.org inside `org-directory'.
With one file, its top-level headings are the sections.  With several
\(e.g. every Denote or Org-roam note tagged `termose-notebook-tag'), each
note is a section, named by its #+title.  Ready-made functions:
`termose-notebook-denote-files', `termose-notebook-roam-files'."
  :type '(choice (const :tag "commands.org in `org-directory'" nil)
                 (repeat file) function))

(defcustom termose-notebook-tag "commands"
  "Denote keyword / Org-roam tag marking notes that hold commands."
  :type 'string)

(defcustom termose-notebook-languages '("bash" "sh" "shell" "zsh")
  "Src block languages that count as commands."
  :type '(repeat string))

(defun termose-notebook-denote-files ()
  "Denote notes (.org) whose keywords include `termose-notebook-tag'."
  (require 'denote)
  (seq-filter (lambda (f) (string-suffix-p ".org" f))
              (denote-directory-files
               (format "__\\(?:[[:alnum:]]+_\\)*%s\\(?:[_.@=]\\|\\'\\)"
                       (regexp-quote termose-notebook-tag)))))

(defun termose-notebook-roam-files ()
  "Org-roam files with a node tagged `termose-notebook-tag'."
  (require 'org-roam)
  (delete-dups
   (mapcar #'car (org-roam-db-query
                  [:select [nodes:file] :from tags
                   :inner-join nodes :on (= tags:node-id nodes:id)
                   :where (= tags:tag $s1)]
                  termose-notebook-tag))))

(defun termose-notebook--files ()
  (mapcar #'expand-file-name
          (cond ((functionp termose-notebook-files) (funcall termose-notebook-files))
                (termose-notebook-files)
                (t (require 'org)
                   (list (expand-file-name "commands.org" org-directory))))))

(defun termose-notebook--title (file)
  "FILE's #+title, else its name without Denote id and keywords."
  (with-temp-buffer
    (insert-file-contents file nil 0 4000)
    (let ((case-fold-search t))
      (if (re-search-forward "^#\\+title:[ \t]*\\(.+?\\)[ \t]*$" nil t)
          (match-string 1)
        (let ((base (file-name-base file)))
          (replace-regexp-in-string
           "-" " " (replace-regexp-in-string "\\`[0-9T]+--\\|\\(__\\|==\\|@@\\).*\\'" "" base)))))))

(defun termose-notebook--file-text (file)
  (let ((buf (find-buffer-visiting file)))
    (if buf
        (with-current-buffer buf (save-restriction (widen) (buffer-string)))
      (with-temp-buffer (insert-file-contents file) (buffer-string)))))

(defun termose-notebook--entries ()
  "Return notebook entries as (DESCRIPTION COMMAND FILE POS SECTION)."
  (require 'org-element)
  (let* ((files (seq-filter #'file-readable-p (termose-notebook--files)))
         (multi (cdr files)))
    (cl-loop
     for file in files
     for title = (and multi (termose-notebook--title file))
     append
     (with-temp-buffer
       (insert (termose-notebook--file-text file))
       (delay-mode-hooks (org-mode))
       (org-element-map (org-element-parse-buffer) 'src-block
         (lambda (b)
           (when (member (org-element-property :language b) termose-notebook-languages)
             (let* ((path (nreverse
                           (cl-loop for e in (org-element-lineage b)
                                    when (eq (org-element-type e) 'headline)
                                    collect (org-element-property :raw-value e))))
                    (path (if title (cons title path) path)))
               (list (if path (string-join path " / ") (file-name-base file))
                     (string-trim (org-element-property :value b))
                     file
                     (org-element-property :begin b)
                     (or (car path) (file-name-base file)))))))))))

(defun termose-notebook--table ()
  "Return (CANDIDATES . HASH) for completion."
  (let ((hash (make-hash-table :test #'equal)) cands)
    (dolist (e (termose-notebook--entries))
      (let* ((preview (truncate-string-to-width
                       (replace-regexp-in-string "\n" " ⏎ " (nth 1 e)) 70 nil nil "…"))
             (key (concat (car e) (make-string (max 2 (- 40 (string-width (car e)))) ?\s)
                          (propertize preview 'face 'completions-annotations))))
        (while (gethash key hash) (setq key (concat key " ")))
        (puthash key e hash)
        (push key cands)))
    (cons (nreverse cands) hash)))

;;;###autoload
(defun termose-notebook (&optional visit)
  "Search the notebook and insert a command into the composer.
Matches descriptions and command text.  With prefix argument VISIT,
jump to the entry in its Org file instead."
  (interactive "P")
  (pcase-let ((`(,cands . ,hash) (termose-notebook--table)))
    (unless cands
      (user-error "No commands in %s yet; save one with C-c C-a"
                  (mapconcat #'abbreviate-file-name (termose-notebook--files) ", ")))
    (let* ((pick (completing-read
                  (if visit "Visit command: " "Command: ")
                  (lambda (str pred action)
                    (if (eq action 'metadata)
                        `(metadata
                          (category . termose-notebook)
                          (display-sort-function . identity)
                          (group-function
                           . ,(lambda (c transform)
                                (let ((e (gethash c hash)))
                                  (if (not transform) (nth 4 e)
                                    (if (string-prefix-p (concat (nth 4 e) " / ") c)
                                        (substring c (+ 3 (length (nth 4 e))))
                                      c))))))
                      (complete-with-action action cands str pred)))
                  nil t))
           (e (gethash pick hash)))
      (if visit
          (progn (find-file (nth 2 e)) (widen) (goto-char (nth 3 e))
                 (when (fboundp 'org-reveal) (org-reveal)))
        (unless (get-buffer-window termose--buffer) (termose))
        (termose-insert-template (nth 1 e))))))

(defun termose-notebook--pick-file (prompt)
  "Return a notebook file; ask by title when there are several."
  (let ((files (termose-notebook--files)))
    (if (cdr files)
        (let ((alist (mapcar (lambda (f) (cons (termose-notebook--title f) f))
                             (seq-filter #'file-readable-p files))))
          (cdr (assoc (completing-read prompt alist nil t) alist)))
      (or (car files) (user-error "`termose-notebook-files' is empty")))))

(defun termose-notebook-add (command)
  "Save COMMAND (the composer text, else the last sent) to the notebook.
With one file you pick or create a section; with several notes you
pick the note (create new notes with Denote/Org-roam as usual)."
  (interactive
   (list (let ((txt (termose--text)))
           (if (string-empty-p txt)
               (or (car termose-history) (user-error "Nothing to save"))
             txt))))
  (require 'org)
  (let* ((multi (cdr (termose-notebook--files)))
         (file (termose-notebook--pick-file "Save to note: "))
         (section (unless multi
                    (completing-read "Section: " (delete-dups (mapcar (lambda (e) (nth 4 e))
                                                                       (termose-notebook--entries))))))
         (desc (read-string "Description (how you'd search for it): "))
         (stars (if multi "*" "**")))
    (make-directory (file-name-directory file) t)
    (with-current-buffer (find-file-noselect file)
      (save-excursion
        (save-restriction
          (widen)
          (goto-char (point-min))
          (cond ((null section) (goto-char (point-max)))
                ((re-search-forward (format "^\\* +%s\\(?:[ \t]+:.*:\\)?[ \t]*$" (regexp-quote section)) nil t)
                 (org-end-of-subtree t t))
                (t (goto-char (point-max))
                   (unless (bolp) (insert "\n"))
                   (insert "\n* " section "\n")))
          (unless (bolp) (insert "\n"))
          (unless (save-excursion (forward-line -1) (looking-at-p "[ \t]*$")) (insert "\n"))
          (insert stars " " desc "\n#+begin_src " (car termose-notebook-languages) "\n"
                  (org-escape-code-in-string command) "\n#+end_src\n")
          (unless (eobp) (insert "\n"))))
      (save-buffer))
    (message "Saved to %s → %s" (file-name-nondirectory file)
             (if section (concat section " / " desc) desc))))

(defun termose-notebook-open ()
  "Open the notebook (asks which note when there are several)."
  (interactive)
  (find-file (termose-notebook--pick-file "Open note: ")))

;;;; Menu

(defun termose--keys (names used &optional upcase)
  "Assign a free key to each of NAMES (list of (NAME . EXPLICIT-KEY)).
USED holds keys already taken."
  (mapcar (lambda (it)
            (let ((k (or (cdr it)
                         (seq-find (lambda (k) (not (member k used)))
                                   (append (mapcar #'string
                                                   (seq-filter (lambda (c) (string-match-p "[[:alnum:]]" (string c)))
                                                               (funcall (if upcase #'upcase #'downcase) (car it))))
                                           (split-string (funcall (if upcase #'upcase #'identity)
                                                                  "abcdefghijklmnopqrstuvwxyz123456789")
                                                         "" t))))))
              (push k used)
              (cons (car it) k)))
          names))

(defun termose--tokens ()
  (with-current-buffer (termose--composer) (termose--scan (buffer-string))))

(defun termose--scope-at (s p)
  "Return (CMD-BEG . CHAIN-END) for the command at index P of S, or nil.
Blanks right before or after a command count as that command."
  (let* ((cmds (car (termose--parse s nil)))
         (p2 (min (length s) (termose--skip-blanks s p)))
         (size (lambda (c) (- (termose--cmd-end c) (termose--cmd-beg c))))
         (around (lambda (q) (sort (seq-filter (lambda (c) (<= (termose--cmd-beg c) q (termose--cmd-end c)))
                                               cmds)
                                   (lambda (a b) (< (funcall size a) (funcall size b))))))
         (pb (let ((q p)) (while (and (> q 0) (memq (aref s (1- q)) '(?\s ?\t))) (cl-decf q)) q))
         (smallest (lambda (cs) (car (sort cs (lambda (a b) (< (funcall size a) (funcall size b)))))))
         (c (or (funcall smallest (seq-filter (lambda (c) (= (termose--cmd-beg c) p2)) cmds)) ; before one
                (funcall smallest (seq-filter (lambda (c) (= (termose--cmd-end c) pb)) cmds)) ; after one
                (car (funcall around p))
                (car (sort (seq-filter (lambda (c) (<= (termose--cmd-beg c) p)) cmds)
                           (lambda (a b) (> (termose--cmd-beg a) (termose--cmd-beg b))))))))
    (when c (cons (termose--cmd-beg c) (termose--chain-end (termose--cmd-chain c))))))

(defun termose--nearest-token (opt p)
  "OPT's token in the composer closest to index P, or nil."
  (car (sort (seq-filter (lambda (tk) (eq (car tk) opt)) (termose--tokens))
             (lambda (a b) (< (min (abs (- (nth 1 a) p)) (abs (- (nth 2 a) p)))
                              (min (abs (- (nth 1 b) p)) (abs (- (nth 2 b) p))))))))

(defun termose-toggle (name)
  "Add option NAME to the command at point, or remove the nearest one.
Prefixes go in front of that command, suffixes and wrappers after its
chain; with point after done/fi/}, the whole loop or block."
  (with-current-buffer (termose--composer)
    (let* ((opt (termose--opt name))
           (p (1- (point)))
           (tok (termose--nearest-token opt p)))
      (if tok
          (let ((beg (1+ (nth 1 tok))) (end (1+ (nth 2 tok))))
            (delete-region beg (save-excursion (goto-char end) (skip-chars-forward " \t") (point)))
            (goto-char beg)
            (when (and (or (eolp) (memq (char-after) '(?\; ?\)))) (memq (char-before) '(?\s ?\t)))
              (delete-char -1)))
        (let* ((defs (termose--defaults opt))
               (args (cl-loop for k below (termose--nargs opt)
                              collect (read-string (format "%s%s arg %d: " termose-prefix name (1+ k))
                                                   nil nil (nth k defs))))
               (token (string-join (cons (concat termose-prefix name) args) " "))
               (text (termose--render opt args))
               (place (termose--place opt text))
               (scope (termose--scope-at (buffer-string) p)))
          (cond
           ((eq place 'here)
            (unless (or (bobp) (memq (char-before) '(?\s ?\t ?\n))) (insert " "))
            (insert token " "))
           ((eq place 'front)
            (goto-char (if scope (1+ (car scope)) (point-min)))
            (insert token " "))
           (t
            (goto-char (if scope (1+ (cdr scope)) (point-max)))
            (unless (or (bobp) (memq (char-before) '(?\s ?\t ?\n))) (insert " "))
            (insert token))))))))

(defun termose--option-suffixes (_)
  (transient-parse-suffixes
   'termose-menu
   (cl-loop for (name . key) in (termose--keys (mapcar (lambda (o) (cons (car o) (termose--prop o :key)))
                                                       termose-options)
                                               nil)
            for cmd = (intern (concat "termose-option/" name))
            do (let ((name name))
                 (defalias cmd (lambda () (interactive) (termose-toggle name))
                   (format "Toggle the %s option." name)))
            collect (let ((name name))
                      (list key cmd :transient t
                            :description (lambda () (termose--option-desc name)))))))

(defun termose--option-desc (name)
  (let* ((opt (termose--opt name))
         (tok (termose--nearest-token opt (with-current-buffer (termose--composer) (1- (point))))))
    (concat (propertize (concat termose-prefix name) 'face (if tok 'transient-value 'transient-heading))
            (propertize " " 'display '(space :align-to 18))
            (if tok
                (propertize (termose--render opt (nth 3 tok)) 'face 'transient-value)
              (propertize (if (stringp (cadr opt)) (cadr opt) "λ") 'face 'transient-inactive-value)))))

(defun termose--group-suffixes (_)
  (transient-parse-suffixes
   'termose-menu
   (cl-loop for (group . key) in (termose--keys (mapcar (lambda (g) (list (car g))) termose-templates)
                                                (mapcar #'cdr (termose--keys
                                                               (mapcar (lambda (o) (cons (car o) (termose--prop o :key)))
                                                                       termose-options)
                                                               nil))
                                                t)
            for cmd = (intern (concat "termose-templates/" group))
            do (let ((group group))
                 (defalias cmd (lambda () (interactive)
                                 (setq termose--group group)
                                 (transient-setup 'termose-template-menu))
                   (format "Pick a %s template." group)))
            collect (list key (concat group "…") cmd))))

(defun termose--template-suffixes (_)
  (let ((items (cdr (assoc termose--group termose-templates))))
    (transient-parse-suffixes
     'termose-template-menu
     (cl-loop for (name . key) in (termose--keys (mapcar (lambda (it) (cons (car it) (plist-get (cddr it) :key)))
                                                         items)
                                                 nil)
              for tpl = (cadr (assoc name items))
              for cmd = (intern (format "termose-template/%s/%s" termose--group name))
              do (let ((tpl tpl))
                   (defalias cmd (lambda () (interactive) (termose-insert-template tpl))
                     (format "Insert template: %s" tpl)))
              collect (list key cmd
                            :description (concat name (propertize " " 'display '(space :align-to 20))
                                                 (propertize (truncate-string-to-width
                                                              (replace-regexp-in-string "\n" " ⏎ " tpl) 60 nil nil "…")
                                                             'face 'transient-inactive-value)))))))

(transient-define-prefix termose-template-menu ()
  "Pick a template."
  [:description (lambda () (concat termose--group " templates"))
   :class transient-column
   :setup-children termose--template-suffixes])

(transient-define-prefix termose-dispatch ()
  "The termose menu: options, templates, notebook and send actions.
Change its keys with `transient-suffix-put', e.g.
  (transient-suffix-put 'termose-dispatch 'termose-send :key \"r\")"
  [:description (lambda ()
                  (concat "termose → " (termose--target-label)))
   ["Options" :class transient-column :setup-children termose--option-suffixes]
   ["Templates" :class transient-column :setup-children termose--group-suffixes]]
  [["Send"
    ("RET" "run" termose-send)
    ("C-j" "insert, don't run" termose-send-no-execute)]
   ["Notebook"
    ("/" "search commands" termose-notebook)
    ("C-a" "save this command" termose-notebook-add)
    ("C-o" "open notebook" termose-notebook-open)]
   ["Composer"
    ("C-t" "target terminal" termose-set-target :transient t)
    ("C-k" "cancel" termose-cancel)]])

;;;###autoload
(defun termose-menu ()
  "Open the composer and show the menu of options and templates."
  (interactive)
  (unless (eq (current-buffer) (get-buffer termose--buffer))
    (call-interactively #'termose))
  (transient-setup 'termose-dispatch))

(provide 'termose)
;;; termose.el ends here
