# okf-roam

Roam-style navigation for [Open Knowledge Format][okf] bundles in Emacs.

The first usable slice indexes OKF concept documents and their Markdown links
in SQLite, then exposes:

- `M-x okf-roam-db-sync`
- `M-x okf-roam-validate`
- `M-x okf-roam-node-find`
- `M-x okf-roam-buffer-toggle`
- `M-x okf-roam-open-at-point`

`index.md` and `log.md` are treated as reserved navigation files rather than
concepts. Broken links remain in the index and appear in the side buffer.

## Setup

```elisp
(add-to-list 'load-path "/path/to/okf-roam")
(require 'okf-roam)

(setq okf-roam-directory "/path/to/your/okf-bundle")

(global-set-key (kbd "C-c n f") #'okf-roam-node-find)
(global-set-key (kbd "C-c n b") #'okf-roam-buffer-toggle)
(global-set-key (kbd "C-c n o") #'okf-roam-open-at-point)
```

Run `M-x okf-roam-db-sync` after changing the bundle. The SQLite index is
stored at `<bundle>/.okf-roam/okf-roam.db` by default.

For a quick local trial, point `okf-roam-directory` at `examples/basic`, sync,
then open the Review a Concept playbook and run
`M-x okf-roam-buffer-toggle`. Its intentionally broken Publishing Guide link
will appear in the side buffer.

The parser consumes the top-level OKF fields it needs without imposing a fixed
schema. Unknown producer-defined frontmatter is preserved in the database as
raw YAML and otherwise ignored.

## Development

```sh
make test
make check
```

[okf]: https://github.com/GoogleCloudPlatform/knowledge-catalog/blob/main/okf/SPEC.md
