# Termose: Terminal Composer

Termose is a compositional command-line interface. It aims to reduce the mental effort required to recall or repeatedly enter specific commands. You can combine frequently used components and edit them however you like. Shortcuts, templates, and command notebooks are easy to access. You make the choices, so your memory is no longer the bottleneck.

## Installation

```elisp
(use-package termose
  :ensure t
  :vc (:url "https://github.com/MagiFeeney/termose/" :rev :newest)
  :commands (termose termose-menu termose-notebook termose-notebook-add)
  :bind (("C-c t" . termose)
         ("C-c m" . termose-menu)
         ("C-c n" . termose-notebook))
  :custom
  ;; Notebook (default: commands.org in your `org-directory'):
  ;; (termose-notebook-files '("~/path/to/commands.org"))
  ;; (termose-notebook-files #'termose-notebook-denote-files)
  ;; (termose-notebook-files #'termose-notebook-roam-files)
  ;; (termose-notebook-tag "commands")

  ;; options: (NAME EXPANSION [:default D] [:match REGEXP] [:at front|end] [:key K])
  ;; (termose-options
  ;;  '(("gpu"  "CUDA_VISIBLE_DEVICES=%s" :default "0" :match "[0-9,]+")
  ;;    ("uv"   "uv run" :at front)
  ;;    ("log"  "2>&1 | tee %s" :at end :default "run.log" :match "\\S-*[./]\\S-*")
  ;;    ("bg"   "&" :at end)
  ;;    ("tmux" "tmux new -d -s %s {qcmd}" :key "x")))

  ;; menu keys: (Uppercase = group): {{name}} {{name:default}} {{name|a|b}} {{_}}
  ;; (termose-templates
  ;;  '(("uv"    ("run"  "uv run {{script:main.py}} {{_}}")
  ;;             ("sync" "uv sync"))
  ;;    ("slurm" ("interactive" "srun --partition={{partition|gpu|cpu}} --gres=gpu:{{gpus:1}} --time={{time:04:00:00}} --pty bash")
  ;;             ("queue" "squeue -u $USER"))))

  ;; Optional
  ;; (termose-prefix "\\")        ; what starts an option: \gpu
  ;; (termose-auto-popup t)       ; typing \ pops up the option list
  ;; (termose-display-action '((display-buffer-at-bottom) (window-height . 6))))
```

## Persistent Termose History

``` elisp
(use-package savehist
  :init (savehist-mode 1)
  :config (add-to-list 'savehist-additional-variables 'termose-history))
```

## Concepts

- **Options**: shorthands typed in a command, starting with `\`. \
  `python train.py \gpu 0,1 \log` runs
  `CUDA_VISIBLE_DEVICES=0,1 python train.py 2>&1 | tee run.log`.
- **Templates**: template commands that are ready to use.
- **Notebook**: an extended memory with keyword retrieval, powered by org mode.

## Keybindings

| Key                | Action                                    |
|--------------------|-------------------------------------------|
| `C-c C-c`          | run                                       |
| `C-c C-j`          | send without pressing RET                 |
| `\`                | pop up the options                        |
| `C-c C-o`          | menu: options, templates, notebook        |
| `C-c C-n`          | search the notebook                       |
| `C-c C-a`          | save the current command to the notebook  |
| `M-p` / `M-n`      | history, filtered by what you typed       |
| `M-r`              | search history                            |
| `C-c C-k`          | cancel                                    |

Customize your preferred keybindings by overriding `termose-mode-map`.
