;;; okf-roam-test.el --- Tests for okf-roam -*- lexical-binding: t; -*-

(require 'ert)
(require 'okf-roam)

(defmacro okf-roam-test--with-bundle (&rest body)
  "Run BODY with a temporary OKF bundle."
  (declare (indent 0) (debug t))
  `(let* ((root (make-temp-file "okf-roam-test-" t))
          (okf-roam-directory root)
          (okf-roam-database-file (expand-file-name "test.db" root)))
     (unwind-protect
         (progn ,@body)
       (delete-directory root t))))

(defun okf-roam-test--write (root path contents)
  "Write CONTENTS to PATH below ROOT."
  (let ((file (expand-file-name path root)))
    (make-directory (file-name-directory file) t)
    (with-temp-file file
      (insert contents))
    file))

(ert-deftest okf-roam-parses-core-frontmatter ()
  (okf-roam-test--with-bundle
    (let* ((file (okf-roam-test--write
                  root "concepts/topic.md"
                  "---\ntype: Concept\ntitle: Example Topic\ntags:\n  - example\n  - knowledge\nowner:\n  team: documentation\n---\n\nBody.\n"))
           (concept (okf-roam--read-concept file)))
      (should (equal (okf-roam-concept-id concept) "concepts/topic"))
      (should (equal (okf-roam-concept-type concept) "Concept"))
      (should (equal (okf-roam-concept-title concept) "Example Topic"))
      (should (equal (okf-roam-concept-tags concept)
                     '("example" "knowledge"))))))

(ert-deftest okf-roam-sync-indexes-links-and-skips-reserved-files ()
  (okf-roam-test--with-bundle
    (okf-roam-test--write root "index.md" "# Bundle\n")
    (okf-roam-test--write
     root "references/spec.md"
     "---\ntype: Reference\ntitle: Specification\n---\n")
    (okf-roam-test--write
     root "concepts/topic.md"
     "---\ntype: Concept\ntitle: Topic\ntags: [example, knowledge]\n---\nSee [spec](/references/spec.md), [local](../references/spec.md), and [missing](/playbooks/missing.md).\n")
    (let ((result (okf-roam-db-sync)))
      (should (= (plist-get result :concepts) 2))
      (should-not (plist-get result :errors)))
    (should (= (caar (okf-roam--select "SELECT COUNT(*) FROM concepts")) 2))
    (should (= (caar (okf-roam--select "SELECT COUNT(*) FROM links")) 3))
    (should (= (caar (okf-roam--select
                      "SELECT COUNT(*) FROM links WHERE exists_in_bundle = 0"))
               1))
    (should (equal
             (mapcar #'car
                     (okf-roam--select
                      "SELECT dest FROM links ORDER BY raw_target"))
             '("references/spec" "playbooks/missing" "references/spec")))))

(ert-deftest okf-roam-renders-backlinks-and-broken-links ()
  (okf-roam-test--with-bundle
    (okf-roam-test--write
     root "references/spec.md"
     "---\ntype: Reference\ntitle: Specification\n---\n")
    (okf-roam-test--write
     root "concepts/topic.md"
     "---\ntype: Concept\ntitle: Topic\n---\nSee [spec](/references/spec.md) and [missing](/playbooks/missing.md).\n")
    (okf-roam-db-sync)
    (with-current-buffer (okf-roam--render-buffer "concepts/topic")
      (should (string-match-p "Forward links" (buffer-string)))
      (should (string-match-p "Specification" (buffer-string)))
      (should (string-match-p "Broken links" (buffer-string)))
      (should (string-match-p "missing" (buffer-string))))
    (with-current-buffer (okf-roam--render-buffer "references/spec")
      (should (string-match-p "Backlinks" (buffer-string)))
      (should (string-match-p "Topic" (buffer-string))))))

(ert-deftest okf-roam-validation-reports-invalid-concepts ()
  (okf-roam-test--with-bundle
    (okf-roam-test--write root "valid.md" "---\ntype: Concept\n---\n")
    (okf-roam-test--write root "invalid.md" "---\ntitle: Missing Type\n---\n")
    (let ((errors (okf-roam-validate)))
      (should (= (length errors) 1))
      (should (string-match-p "invalid.md.*missing non-empty.*type.*field"
                              (car errors))))))

(ert-deftest okf-roam-does-not-follow-links-outside-bundle ()
  (okf-roam-test--with-bundle
    (let ((outside (make-temp-file "okf-roam-outside-" nil ".md")))
      (unwind-protect
          (progn
            (okf-roam-test--write
             root "concept.md"
             (format "---\ntype: Reference\n---\n[Outside](%s)\n"
                     (file-relative-name outside root)))
            (okf-roam-db-sync)
            (should (= (caar (okf-roam--select
                              "SELECT exists_in_bundle FROM links"))
                       0)))
        (delete-file outside)))))

(ert-deftest okf-roam-preview-preamble-uses-frontmatter ()
  (okf-roam-test--with-bundle
    (let* ((file (okf-roam-test--write
                  root "tables/users.md"
                  "---\ntype: Table\ntitle: Users & Accounts\ndescription: One row per <known> user.\n---\n\n# Schema\n"))
           (preamble
            (okf-roam--preview-preamble (okf-roam--read-concept file))))
      (should (string-match-p "<strong>Table</strong>" preamble))
      (should (string-match-p "<h1>Users &amp; Accounts</h1>" preamble))
      (should (string-match-p "One row per &lt;known&gt; user" preamble)))))

(provide 'okf-roam-test)

;;; okf-roam-test.el ends here
