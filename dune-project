(lang dune 3.0)

(name url-router)

(generate_opam_files true)

(package
 (name url-router)
 (allow_empty)
 (synopsis "Multi-tenant URL routing system")
 (depends
  (ocaml
   (>= 5.0))
  (base
   (>= v0.17))
  (stdio
   (>= v0.17))
  (yojson
   (>= 2.0))
  (ppx_deriving_yojson
   (>= 3.0))
  (ppx_jane
   (>= v0.17))
  (eio
   (>= 1.0))
  (eio_main
   (>= 1.0))
  (re
   (>= 1.0))
  (alcotest
   (and
    :with-test
    (>= 1.0)))))
