(in-package #:cl)
(named-readtables:in-readtable :parenscript)

(defpackage #:ps-test
  (:use #:cl #:parenscript #:eos)
  (:export #:run-tests #:interface-function #:test-js-eval))

(defpackage #:ps-eval-tests
  (:use #:cl #:eos #:ps-test #:cl-js))
