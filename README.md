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

For a quick local trial, point `okf-roam-directory` at `examples/data-team`,
sync, then open Weekly Active Users and run `M-x okf-roam-buffer-toggle`. The
sample follows the table, metric, join-path, and runbook use cases described in
Google Cloud's [OKF introduction][okf-introduction]. Open the Investigate a
Metric Change playbook to see an intentionally broken Metric Incident Log link.

The parser consumes the top-level OKF fields it needs without imposing a fixed
schema. Unknown producer-defined frontmatter is preserved in the database as
raw YAML and otherwise ignored.

## Development

```sh
make test
make check
```

[okf]: https://github.com/GoogleCloudPlatform/knowledge-catalog/blob/main/okf/SPEC.md
[okf-introduction]: https://cloud.google.com/blog/products/data-analytics/how-the-open-knowledge-format-can-improve-data-sharing/
