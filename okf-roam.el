;;; okf-roam.el --- Roam-style navigation for OKF bundles -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: Zachary Bodtorf
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: files, hypermedia, tools
;; URL: https://github.com/zacharybodtorf/okf-roam

;;; Commentary:

;; okf-roam indexes Open Knowledge Format (OKF) concept documents in SQLite
;; and provides commands for finding concepts, opening links, and inspecting
;; backlinks.  It intentionally has no dependencies outside Emacs.

;;; Code:

(require 'cl-lib)
(require 'button)
(require 'json)
(require 'seq)
(require 'sqlite)
(require 'subr-x)

(defvar markdown-command)
(defvar markdown-xhtml-body-preamble)
(declare-function markdown-standalone "markdown-mode"
                  (&optional output-buffer-name title))

(defgroup okf-roam nil
  "Roam-style navigation for Open Knowledge Format bundles."
  :group 'files
  :prefix "okf-roam-")

(defcustom okf-roam-directory nil
  "Root directory of the active OKF bundle."
  :type '(choice (const :tag "Not configured" nil) directory))

(defcustom okf-roam-database-file nil
  "SQLite database used by okf-roam.
When nil, use `.okf-roam/okf-roam.db' inside `okf-roam-directory'."
  :type '(choice (const :tag "Inside bundle" nil) file))

(defcustom okf-roam-pandoc-command "pandoc"
  "Pandoc executable used by `okf-roam-preview'."
  :type 'string)

(defconst okf-roam--reserved-files '("index.md" "log.md"))
(defconst okf-roam--buffer-name "*okf-roam*")

(cl-defstruct okf-roam-concept
  id file type title description tags frontmatter body)

(defun okf-roam--root ()
  "Return the normalized active bundle root."
  (unless okf-roam-directory
    (user-error "Set `okf-roam-directory' to an OKF bundle first"))
  (file-name-as-directory (expand-file-name okf-roam-directory)))

(defun okf-roam--db-file ()
  "Return the database file for the active bundle."
  (expand-file-name
   (or okf-roam-database-file
       (expand-file-name ".okf-roam/okf-roam.db" (okf-roam--root)))))

(defun okf-roam--concept-file-p (file)
  "Return non-nil when FILE is an OKF concept document."
  (and (string-equal (file-name-extension file) "md")
       (not (member (file-name-nondirectory file)
                    okf-roam--reserved-files))))

(defun okf-roam--concept-files ()
  "Return all concept files below the active bundle root."
  (seq-filter
   #'okf-roam--concept-file-p
   (directory-files-recursively (okf-roam--root) "\\.md\\'")))

(defun okf-roam--concept-id (file)
  "Return the bundle-relative concept ID for FILE."
  (file-name-sans-extension
   (file-relative-name (expand-file-name file) (okf-roam--root))))

(defun okf-roam--strip-yaml-comment (value)
  "Strip a trailing YAML comment from scalar VALUE."
  (if (string-match "\\(?:^\\|[[:space:]]\\)#[[:space:]].*\\'" value)
      (string-trim-right (substring value 0 (match-beginning 0)))
    value))

(defun okf-roam--yaml-scalar (value)
  "Parse a simple top-level YAML scalar VALUE."
  (let ((trimmed (string-trim (okf-roam--strip-yaml-comment value))))
    (if (and (> (length trimmed) 1)
             (memq (aref trimmed 0) '(?\" ?'))
             (= (aref trimmed 0) (aref trimmed (1- (length trimmed)))))
        (substring trimmed 1 -1)
      trimmed)))

(defun okf-roam--yaml-list (value)
  "Parse an inline YAML list VALUE."
  (let ((trimmed (string-trim value)))
    (if (and (string-prefix-p "[" trimmed)
             (string-suffix-p "]" trimmed))
        (mapcar #'okf-roam--yaml-scalar
                (split-string (substring trimmed 1 -1) "," t "[[:space:]]*"))
      nil)))

(defun okf-roam--parse-frontmatter (text)
  "Parse the top-level fields needed from YAML frontmatter TEXT.
Unknown or nested producer fields are left in the raw frontmatter."
  (let ((lines (split-string text "\n"))
        result current-key)
    (dolist (line lines)
      (cond
       ((string-match "\\`\\([[:alnum:]_-]+\\):[[:space:]]*\\(.*\\)\\'" line)
        (setq current-key (match-string 1 line))
        (let ((value (match-string 2 line)))
          (unless (string-empty-p value)
            (push (cons current-key
                        (or (okf-roam--yaml-list value)
                            (okf-roam--yaml-scalar value)))
                  result))))
       ((and current-key
             (string-match "\\`[[:space:]]+-[[:space:]]+\\(.+\\)\\'" line))
        (let ((existing (assoc current-key result))
              (value (okf-roam--yaml-scalar (match-string 1 line))))
          (if existing
              (setcdr existing
                      (append (if (listp (cdr existing))
                                  (cdr existing)
                                (list (cdr existing)))
                              (list value)))
            (push (cons current-key (list value)) result))))))
    (nreverse result)))

(defun okf-roam--split-document (text)
  "Split OKF document TEXT into frontmatter and body."
  (unless (string-match "\\`---[ \t]*\n" text)
    (error "Missing YAML frontmatter"))
  (let ((start (match-end 0)))
    (unless (string-match "^---[ \t]*$" text start)
      (error "Unclosed YAML frontmatter"))
    (list (substring text start (match-beginning 0))
          (string-trim-left (substring text (match-end 0))))))

(defun okf-roam--read-concept (file)
  "Read and validate the OKF concept in FILE."
  (let* ((parts (okf-roam--split-document
                 (with-temp-buffer
                   (insert-file-contents file)
                   (buffer-string))))
         (frontmatter (car parts))
         (body (cadr parts))
         (metadata (okf-roam--parse-frontmatter frontmatter))
         (type (alist-get "type" metadata nil nil #'string-equal))
         (id (okf-roam--concept-id file))
         (title (alist-get "title" metadata nil nil #'string-equal))
         (tags (alist-get "tags" metadata nil nil #'string-equal)))
    (unless (and (stringp type) (not (string-empty-p type)))
      (error "Missing non-empty `type' field"))
    (make-okf-roam-concept
     :id id
     :file (expand-file-name file)
     :type type
     :title (if (and (stringp title) (not (string-empty-p title)))
                title
              (string-replace "_" " " (file-name-nondirectory id)))
     :description (alist-get "description" metadata nil nil #'string-equal)
     :tags (cond ((listp tags) tags)
                 ((stringp tags) (list tags))
                 (t nil))
     :frontmatter frontmatter
     :body body)))

(defconst okf-roam--markdown-link-regexp
  "\\[\\([^]\n]+\\)\\](\\([^)[:space:]\n]+\\)\\(?:[[:space:]]+\"[^\"]*\"\\)?)")

(defun okf-roam--external-target-p (target)
  "Return non-nil when TARGET is not an OKF concept link."
  (or (string-prefix-p "#" target)
      (string-match-p "\\`[[:alpha:]][[:alnum:]+.-]*:" target)))

(defun okf-roam--target-path (source-file target)
  "Resolve TARGET from SOURCE-FILE to an absolute file path."
  (let* ((without-fragment (car (split-string target "[?#]")))
         (root (okf-roam--root)))
    (if (string-prefix-p "/" without-fragment)
        (expand-file-name (string-remove-prefix "/" without-fragment) root)
      (expand-file-name without-fragment
                        (file-name-directory source-file)))))

(defun okf-roam--target-id (source-file target)
  "Resolve an internal TARGET from SOURCE-FILE to a concept ID."
  (file-name-sans-extension
   (file-relative-name (okf-roam--target-path source-file target)
                       (okf-roam--root))))

(defun okf-roam--inside-root-p (file)
  "Return non-nil when FILE is inside the active bundle root."
  (file-in-directory-p (expand-file-name file) (okf-roam--root)))

(defun okf-roam--link-context (body start)
  "Return the trimmed line in BODY containing START."
  (let ((line-start (or (string-match-p "[^\n]*\\'" (substring body 0 start)) 0))
        (line-end (or (string-match "\n" body start) (length body))))
    (string-trim (substring body line-start line-end))))

(defun okf-roam--concept-links (concept)
  "Extract internal markdown links from CONCEPT."
  (let ((body (okf-roam-concept-body concept))
        links
        (position 0))
    (while (string-match okf-roam--markdown-link-regexp body position)
      (let ((label (match-string 1 body))
            (target (match-string 2 body))
            (start (match-beginning 0))
            (end (match-end 0)))
        (unless (okf-roam--external-target-p target)
          (let ((path (okf-roam--target-path
                       (okf-roam-concept-file concept) target)))
            (push (list (okf-roam-concept-id concept)
                        (okf-roam--target-id
                         (okf-roam-concept-file concept) target)
                        label target
                        (okf-roam--link-context body start)
                        (if (and (okf-roam--inside-root-p path)
                                 (file-exists-p path))
                            1
                          0))
                  links)))
        (setq position end)))
    (nreverse links)))

(defun okf-roam--open-db ()
  "Open and initialize the active okf-roam database."
  (let ((file (okf-roam--db-file)))
    (make-directory (file-name-directory file) t)
    (let ((db (sqlite-open file)))
      (sqlite-execute
       db
       "CREATE TABLE IF NOT EXISTS concepts (
          id TEXT PRIMARY KEY,
          file TEXT NOT NULL,
          type TEXT NOT NULL,
          title TEXT NOT NULL,
          description TEXT,
          tags TEXT NOT NULL,
          frontmatter TEXT NOT NULL,
          body TEXT NOT NULL
        )")
      (sqlite-execute
       db
       "CREATE TABLE IF NOT EXISTS links (
          source TEXT NOT NULL,
          dest TEXT NOT NULL,
          label TEXT NOT NULL,
          raw_target TEXT NOT NULL,
          context TEXT NOT NULL,
          exists_in_bundle INTEGER NOT NULL
        )")
      (sqlite-execute
       db "CREATE INDEX IF NOT EXISTS links_source_idx ON links(source)")
      (sqlite-execute
       db "CREATE INDEX IF NOT EXISTS links_dest_idx ON links(dest)")
      db)))

(defun okf-roam--with-db (function)
  "Call FUNCTION with an open database and always close it."
  (let ((db (okf-roam--open-db)))
    (unwind-protect
        (funcall function db)
      (sqlite-close db))))

;;;###autoload
(defun okf-roam-db-sync ()
  "Rebuild the SQLite index for the active OKF bundle."
  (interactive)
  (let (concepts errors)
    (dolist (file (okf-roam--concept-files))
      (condition-case err
          (push (okf-roam--read-concept file) concepts)
        (error
         (push (format "%s: %s"
                       (file-relative-name file (okf-roam--root))
                       (error-message-string err))
               errors))))
    (setq concepts (nreverse concepts))
    (setq errors (nreverse errors))
    (okf-roam--with-db
     (lambda (db)
       (sqlite-execute db "BEGIN")
       (condition-case err
           (progn
             (sqlite-execute db "DELETE FROM links")
             (sqlite-execute db "DELETE FROM concepts")
             (dolist (concept concepts)
               (sqlite-execute
                db
                "INSERT INTO concepts
                 (id, file, type, title, description, tags, frontmatter, body)
                 VALUES (?, ?, ?, ?, ?, ?, ?, ?)"
                (vector
                 (okf-roam-concept-id concept)
                 (okf-roam-concept-file concept)
                 (okf-roam-concept-type concept)
                 (okf-roam-concept-title concept)
                 (or (okf-roam-concept-description concept) "")
                 (json-serialize (vconcat (okf-roam-concept-tags concept)))
                 (okf-roam-concept-frontmatter concept)
                 (okf-roam-concept-body concept)))
               (dolist (link (okf-roam--concept-links concept))
                 (sqlite-execute
                  db
                  "INSERT INTO links
                   (source, dest, label, raw_target, context, exists_in_bundle)
                   VALUES (?, ?, ?, ?, ?, ?)"
                  (vconcat link))))
             (sqlite-execute db "COMMIT"))
         (error
          (sqlite-execute db "ROLLBACK")
          (signal (car err) (cdr err))))))
    (when errors
      (with-current-buffer (get-buffer-create "*okf-roam errors*")
        (erase-buffer)
        (insert (string-join errors "\n"))
        (special-mode)
        (display-buffer (current-buffer))))
    (message "Indexed %d concepts; skipped %d invalid files"
             (length concepts) (length errors))
    (list :concepts (length concepts) :errors errors)))

;;;###autoload
(defun okf-roam-validate ()
  "Validate concept frontmatter in the active OKF bundle."
  (interactive)
  (let (errors)
    (dolist (file (okf-roam--concept-files))
      (condition-case err
          (okf-roam--read-concept file)
        (error
         (push (format "%s: %s"
                       (file-relative-name file (okf-roam--root))
                       (error-message-string err))
               errors))))
    (setq errors (nreverse errors))
    (if errors
        (progn
          (when (called-interactively-p 'interactive)
            (with-current-buffer (get-buffer-create "*okf-roam errors*")
              (erase-buffer)
              (insert (string-join errors "\n"))
              (special-mode)
              (display-buffer (current-buffer))))
          errors)
      (when (called-interactively-p 'interactive)
        (message "OKF bundle is valid"))
      nil)))

(defun okf-roam--select (query &optional values)
  "Run database QUERY with optional VALUES and return rows."
  (okf-roam--with-db
   (lambda (db)
     (sqlite-select db query values))))

(defun okf-roam--open-id (id)
  "Open concept ID."
  (let ((row (car (okf-roam--select
                   "SELECT file FROM concepts WHERE id = ?" (vector id)))))
    (unless row
      (user-error "Concept is not indexed: %s" id))
    (find-file (seq-elt row 0))))

;;;###autoload
(defun okf-roam-node-find ()
  "Find and open an indexed OKF concept."
  (interactive)
  (let* ((rows (okf-roam--select
                "SELECT id, type, title FROM concepts ORDER BY title"))
         (choices
          (mapcar
           (lambda (row)
             (cons (format "%-18s %s  (%s)"
                           (seq-elt row 1) (seq-elt row 2) (seq-elt row 0))
                   (seq-elt row 0)))
           rows))
         (choice (completing-read "OKF concept: " choices nil t)))
    (okf-roam--open-id (cdr (assoc choice choices)))))

(defun okf-roam--button-action (button)
  "Open the concept associated with BUTTON."
  (okf-roam--open-id (button-get button 'okf-roam-id)))

(defun okf-roam--insert-link-row (row id-index label-index)
  "Insert a concept button from ROW using ID-INDEX and LABEL-INDEX."
  (let ((id (seq-elt row id-index))
        (label (seq-elt row label-index)))
    (insert "  ")
    (insert-text-button
     (if (string-empty-p label) id label)
     'follow-link t
     'help-echo id
     'okf-roam-id id
     'action #'okf-roam--button-action)
    (insert (format "  (%s)\n" id))))

(defun okf-roam--insert-section (heading rows id-index label-index)
  "Insert HEADING and linked ROWS into the roam buffer.
ID-INDEX and LABEL-INDEX identify the relevant fields in each row."
  (insert (propertize heading 'face 'bold) "\n")
  (if rows
      (dolist (row rows)
        (okf-roam--insert-link-row row id-index label-index))
    (insert "  None\n"))
  (insert "\n"))

(defun okf-roam--render-buffer (id)
  "Render the roam side buffer for concept ID."
  (let* ((concept (car (okf-roam--select
                        "SELECT type, title, description, tags
                         FROM concepts WHERE id = ?"
                        (vector id))))
         (forward (okf-roam--select
                   "SELECT l.dest, COALESCE(c.title, l.label)
                    FROM links l
                    LEFT JOIN concepts c ON c.id = l.dest
                    WHERE l.source = ? AND l.exists_in_bundle = 1
                    ORDER BY 2"
                   (vector id)))
         (backlinks (okf-roam--select
                     "SELECT l.source, c.title
                      FROM links l
                      JOIN concepts c ON c.id = l.source
                      WHERE l.dest = ?
                      ORDER BY c.title"
                     (vector id)))
         (broken (okf-roam--select
                  "SELECT dest, label, raw_target
                   FROM links
                   WHERE source = ? AND exists_in_bundle = 0
                   ORDER BY label"
                  (vector id))))
    (unless concept
      (user-error "Concept is not indexed: %s" id))
    (with-current-buffer (get-buffer-create okf-roam--buffer-name)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize (seq-elt concept 1)
                            'face '(:height 1.3 :weight bold))
                "\n")
        (insert (format "%s  |  %s\n\n" (seq-elt concept 0) id))
        (unless (string-empty-p (seq-elt concept 2))
          (insert (seq-elt concept 2) "\n\n"))
        (okf-roam--insert-section "Forward links" forward 0 1)
        (okf-roam--insert-section "Backlinks" backlinks 0 1)
        (insert (propertize "Broken links" 'face 'bold) "\n")
        (if broken
            (dolist (row broken)
              (insert (format "  %s  (%s)\n"
                              (seq-elt row 1) (seq-elt row 2))))
          (insert "  None\n"))
        (goto-char (point-min))
        (special-mode))
      (current-buffer))))

(defun okf-roam--current-id ()
  "Return the current buffer's concept ID."
  (unless buffer-file-name
    (user-error "Current buffer is not visiting a file"))
  (let ((root (okf-roam--root))
        (file (expand-file-name buffer-file-name)))
    (unless (file-in-directory-p file root)
      (user-error "Current file is outside `okf-roam-directory'"))
    (unless (okf-roam--concept-file-p file)
      (user-error "Current file is not an OKF concept"))
    (okf-roam--concept-id file)))

(defun okf-roam--html-escape (text)
  "Escape TEXT for inclusion in HTML."
  (let ((escaped (string-replace "&" "&amp;" text)))
    (setq escaped (string-replace "<" "&lt;" escaped))
    (setq escaped (string-replace ">" "&gt;" escaped))
    (string-replace "\"" "&quot;" escaped)))

(defun okf-roam--preview-preamble (concept)
  "Return an HTML heading block for CONCEPT."
  (let ((title (okf-roam--html-escape (okf-roam-concept-title concept)))
        (type (okf-roam--html-escape (okf-roam-concept-type concept)))
        (description (okf-roam-concept-description concept)))
    (concat
     "<header class=\"okf-roam-concept-header\">"
     "<p><strong>" type "</strong></p>"
     "<h1>" title "</h1>"
     (if (and (stringp description) (not (string-empty-p description)))
         (format "<p>%s</p>" (okf-roam--html-escape description))
       "")
     "</header>")))

(defun okf-roam--compile-pandoc (begin end output-buffer)
  "Compile Markdown from BEGIN to END into OUTPUT-BUFFER with Pandoc."
  (unless (executable-find okf-roam-pandoc-command)
    (user-error "Pandoc executable not found: %s" okf-roam-pandoc-command))
  (let ((error-file (make-temp-file "okf-roam-pandoc-")))
    (unwind-protect
        (let ((status
               (call-process-region
                begin end okf-roam-pandoc-command nil
                (list output-buffer error-file) nil
                "--from=markdown"
                "--to=html"
                "--mathjax"
                "--syntax-highlighting=pygments")))
          (unless (eq status 0)
            (error "Pandoc failed: %s"
                   (string-trim
                    (with-temp-buffer
                      (insert-file-contents error-file)
                      (buffer-string)))))
          status)
      (delete-file error-file))))

;;;###autoload
(defun okf-roam-preview ()
  "Preview the current OKF concept as HTML in a browser.
Use frontmatter metadata for the document heading and Pandoc for Markdown
conversion.  This requires the `markdown-mode' package and Pandoc."
  (interactive)
  (unless buffer-file-name
    (user-error "Current buffer is not visiting a file"))
  (unless (require 'markdown-mode nil t)
    (user-error "Install the `markdown-mode' package to use previews"))
  (let* ((concept (okf-roam--read-concept buffer-file-name))
         (markdown-command #'okf-roam--compile-pandoc)
         (markdown-xhtml-body-preamble
          (okf-roam--preview-preamble concept)))
    (browse-url-of-buffer
     (markdown-standalone "*okf-roam preview*"
                          (okf-roam-concept-title concept)))))

;;;###autoload
(defun okf-roam-buffer-toggle ()
  "Toggle the roam side buffer for the current concept."
  (interactive)
  (let ((window (get-buffer-window okf-roam--buffer-name)))
    (if window
        (delete-window window)
      (display-buffer-in-side-window
       (okf-roam--render-buffer (okf-roam--current-id))
       '((side . right) (slot . 0) (window-width . 0.35))))))

(defun okf-roam--link-at-point ()
  "Return the markdown link target at point, or nil."
  (let ((position (point))
        target)
    (save-excursion
      (beginning-of-line)
      (while (and (not target)
                  (re-search-forward okf-roam--markdown-link-regexp
                                     (line-end-position) t))
        (when (and (<= (match-beginning 0) position)
                   (>= (match-end 0) position))
          (setq target (match-string-no-properties 2)))))
    target))

;;;###autoload
(defun okf-roam-open-at-point ()
  "Open the internal markdown link at point."
  (interactive)
  (let ((target (okf-roam--link-at-point)))
    (unless target
      (user-error "No markdown link at point"))
    (if (okf-roam--external-target-p target)
        (browse-url target)
      (let ((path (okf-roam--target-path buffer-file-name target)))
        (unless (okf-roam--inside-root-p path)
          (user-error "Link target is outside the OKF bundle"))
        (find-file path)))))

(provide 'okf-roam)

;;; okf-roam.el ends here
