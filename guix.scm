;; SPDX-License-Identifier: PMPL-1.0-or-later
;; Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
;;
;; Guix package definition for Bundle of Joy Server
;;
;; Usage:
;;   guix shell -D -f guix.scm    # Enter development shell
;;   guix build -f guix.scm       # Build package

(use-modules (guix packages)
             (guix gexp)
             (guix git-download)
             (guix build-system gnu)
             (guix licenses)
             (gnu packages base))

(package
  (name "boj-server")
  (version "0.1.0")
  (source (local-file "." "source"
                       #:recursive? #t
                       #:select? (lambda (file stat)
                                   (not (string-contains file ".git")))))
  (build-system gnu-build-system)
  (arguments
   '(#:phases
     (modify-phases %standard-phases
       (delete 'configure)
       (replace 'build
         (lambda _
           (invoke "zig" "build" "-Doptimize=ReleaseSafe")
           ;; Build cartridge FFIs
           (for-each (lambda (cart)
                       (chdir (string-append "cartridges/" cart "/ffi"))
                       (invoke "zig" "build")
                       (chdir "../../.."))
                     '("fleet-mcp" "nesy-mcp" "database-mcp" "agent-mcp"))))
       (replace 'check
         (lambda _
           (invoke "just" "test")))
       (replace 'install
         (lambda* (#:key outputs #:allow-other-keys)
           (let ((out (assoc-ref outputs "out")))
             (mkdir-p (string-append out "/share/doc"))
             (copy-file "README.adoc"
                        (string-append out "/share/doc/README.adoc"))))))))
  (native-inputs
   (list
    ;; Build-time: Idris2 for ABI type-checking, Zig for FFI compilation
    ;; Note: idris2 and zig packages may need custom channels
    ))
  (inputs (list))
  (home-page "https://github.com/hyperpolymath/boj-server")
  (synopsis "Formally verified capability catalogue for developer server protocols")
  (description "Bundle of Joy Server provides a unified, formally verified catalogue
of developer server capabilities. AI goes to ONE place instead of hunting across
dozens of MCP/LSP/etc servers. Uses Idris2 for formal proofs (ABI), Zig for
zero-overhead native execution (FFI), and V-lang for triple API adapters.")
  (license (list mpl2.0)))
