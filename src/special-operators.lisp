(in-package #:parenscript)
(in-readtable :parenscript)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; arithmetic and logic

(define-trivial-special-ops
  +          ps-js:+
  -          ps-js:-
  *          ps-js:*
  rem        ps-js:%
  and        ps-js:&&
  or         ps-js:\|\|

  logand     ps-js:&
  logior     ps-js:\|
  logxor     ps-js:^
  lognot     ps-js:~

  aref       ps-js:aref

  funcall    ps-js:funcall
  )

(define-expression-operator / (&rest args)
  `(ps-js:/ ,@(unless (cdr args) (list 1)) ,@(mapcar #'compile-expression args)))

(define-expression-operator - (&rest args)
  (let ((args (mapcar #'compile-expression args)))
    (cons (if (cdr args) 'ps-js:- 'ps-js:negate) args)))

(defun fix-nary-comparison (operator objects)
  (let* ((tmp-var-forms (butlast (cdr objects)))
         (tmp-vars (loop repeat (length tmp-var-forms)
                         collect (ps-gensym "_CMP")))
         (all-comparisons (append (list (car objects))
                                  tmp-vars
                                  (last objects))))
    `(let ,(mapcar #'list tmp-vars tmp-var-forms)
       (and ,@(loop for x1 in all-comparisons
                    for x2 in (cdr all-comparisons)
                    collect (list operator x1 x2))))))

(macrolet ((define-nary-comparison-forms (&rest mappings)
             `(progn
                ,@(loop for (form js-primitive) on mappings by #'cddr collect
                       `(define-expression-operator ,form (&rest objects)
                          (if (cddr objects)
                              (ps-compile
                               (fix-nary-comparison ',form objects))
                              (cons ',js-primitive
                                    (mapcar #'compile-expression objects))))))))
  (define-nary-comparison-forms
    <     ps-js:<
    >     ps-js:>
    <=    ps-js:<=
    >=    ps-js:>=
    eql   ps-js:===
    equal ps-js:==))

(define-expression-operator /= (a b)
  ;; for n>2, /= is finding duplicates in an array of numbers (ie -
  ;; nontrivial runtime algorithm), so we restrict it to binary in PS
  `(ps-js:!== ,(compile-expression a) ,(compile-expression b)))

(define-expression-operator incf (x &optional (delta 1))
  (let ((delta (ps-macroexpand delta)))
    (if (eql delta 1)
        `(ps-js:++ ,(compile-expression x))
        `(ps-js:+= ,(compile-expression x) ,(compile-expression delta)))))

(define-expression-operator decf (x &optional (delta 1))
  (let ((delta (ps-macroexpand delta)))
    (if (eql delta 1)
        `(ps-js:-- ,(compile-expression x))
        `(ps-js:-= ,(compile-expression x) ,(compile-expression delta)))))

(let ((inverses (mapcan (lambda (x)
                          (list x (reverse x)))
                        '((ps-js:=== ps-js:!==)
                          (ps-js:== ps-js:!=)
                          (ps-js:< ps-js:>=)
                          (ps-js:> ps-js:<=)))))
  (define-expression-operator not (x)
    (let ((form (compile-expression x)))
      (acond ((and (listp form) (eq (car form) 'ps-js:!))
              (second form))
             ((and (listp form) (cadr (assoc (car form) inverses)))
              `(,it ,@(cdr form)))
             (t `(ps-js:! ,form))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; blocks and control flow

(defun flatten-blocks (body)
  (when body
    (if (and (listp (car body)) (eq 'ps-js:block (caar body)))
        (append (cdr (car body)) (flatten-blocks (cdr body)))
        (cons (car body) (flatten-blocks (cdr body))))))

(defun compile-progn (body)
  (let ((block (flatten-blocks (mapcar #'ps-compile body))))
    (append (remove-if #'constantp (butlast block))
            (unless (and (or (eq *compilation-level* :toplevel)
                             (not compile-expression?))
                         (not (car (last block))))
              (last block)))))

(define-expression-operator progn (&rest body)
  (if (cdr body)
      `(ps-js:|,| ,@(compile-progn body))
      (compile-expression (car body))))

(define-statement-operator progn (&rest body)
  `(ps-js:block ,@(compile-progn body)))

(defun wrap-block-for-dynamic-return (tag body)
  (if (member tag *tags-that-return-throws-to*)
      `(ps-js:block
         (ps-js:try ,body
                    :catch (err ,(compile-statement `(progn (if (and err (eql ',tag (getprop err :ps-block-tag)))
                                                                ;; FIXME make this a multiple-value return
                                                                (return (getprop err :ps-return-value))
                                                                (throw err)))))
                   :finally nil))
      body))

(define-statement-operator block (name &rest body)
  (let* ((name (or name 'nilBlock))
         (*lexical-extent-return-tags* (cons name *lexical-extent-return-tags*))
         (*tags-that-return-throws-to* ()))
    `(ps-js:label ,name ,(wrap-block-for-dynamic-return name (compile-statement `(progn ,@body))))))

(defun try-expressionize-if? (form)
  (< (count #\Newline (with-output-to-string (*psw-stream*)
                        (let ((*ps-print-pretty* t))
                          (parenscript-print (compile-statement form) t))))
     (if (= (length form) 4) 5 4)))

(define-statement-operator return-from (tag &optional result)
  (if (not tag)
      (if in-loop-scope?
          (progn
            (when result
              (warn "Trying to (RETURN ~A) from inside a loop with an implicit nil block (DO, DOLIST, DOTIMES, etc.). Parenscript doesn't support returning values this way from inside a loop yet!" result))
            '(ps-js:break))
          (ps-compile `(return-from nilBlock ,result)))
      (let ((form (ps-macroexpand result)))
        (flet ((return-exp (value) ;; this stuff needs to be fixed to handle multiple-value returns, too
                 (let ((value (compile-expression value)))
                  (cond ((member tag *lexical-extent-return-tags*)
                         (when result
                           (warn "Trying to (RETURN-FROM ~A ~A) a value from a block. Parenscript doesn't support returning values this way from blocks yet!" tag result))
                         `(ps-js:break ,tag))
                        ((or (eql '%function-body tag) (member tag *function-block-names*))
                         `(ps-js:return ,value))
                        ((member tag *dynamic-extent-return-tags*)
                         (push tag *tags-that-return-throws-to*)
                         (ps-compile `(throw (create :ps-block-tag ',tag :ps-return-value ,value))))
                        (t (warn "Returning from unknown block ~A" tag)
                           `(ps-js:return ,value)))))) ;; for backwards-compatibility
          (if (listp form)
              (block expressionize
                (ps-compile
                 (case (car form)
                   (progn
                     `(progn ,@(butlast (cdr form)) (return-from ,tag ,(car (last (cdr form))))))
                   (switch
                       `(switch ,(second form)
                          ,@(loop for (cvalue . cbody) in (cddr form)
                               for remaining on (cddr form) collect
                                 (let ((last-n (cond ((or (eq 'default cvalue) (not (cdr remaining)))
                                                      1)
                                                     ((eq 'break (car (last cbody)))
                                                      2))))
                                   (if last-n
                                       (let ((result-form (ps-macroexpand (car (last cbody last-n)))))
                                         `(,cvalue
                                           ,@(butlast cbody last-n)
                                           (return-from ,tag ,result-form)
                                           ,@(when (and (= last-n 2)
                                                        (find-if (lambda (x) (or (eq x 'if) (eq x 'cond)))
                                                                 (flatten result-form)))
                                              '(break))))
                                       (cons cvalue cbody))))))
                   (try
                    `(try (return-from ,tag ,(second form))
                          ,@(let ((catch (cdr (assoc :catch (cdr form))))
                                  (finally (assoc :finally (cdr form))))
                                 (list (when catch
                                         `(:catch ,(car catch)
                                            ,@(butlast (cdr catch))
                                            (return-from ,tag ,(car (last (cdr catch))))))
                                       finally))))
                   (cond
                     `(cond ,@(loop for clause in (cdr form) collect
                                   `(,@(butlast clause) (return-from ,tag ,(car (last clause)))))))
                   ((with label let flet labels macrolet symbol-macrolet) ;; implicit progn forms
                    `(,(first form) ,(second form)
                       ,@(butlast (cddr form))
                       (return-from ,tag ,(car (last (cddr form))))))
                   ((continue break throw) ;; non-local exit
                    form)
                   (return-from ;; this will go away someday
                    (unless tag
                      (warn 'simple-style-warning
                            :format-control "Trying to RETURN a RETURN without a block tag specified. Perhaps you're still returning values from functions by hand? Parenscript now implements implicit return, update your code! Things like (lambda () (return x)) are not valid Common Lisp and may not be supported in future versions of Parenscript."))
                     form)
                   (if
                    (aif (and (try-expressionize-if? form)
                              (handler-case (compile-expression form)
                                (compile-expression-error () nil)))
                         (return-from expressionize `(ps-js:return ,it))
                         `(if ,(second form)
                              (return-from ,tag ,(third form))
                              ,@(when (fourth form) `((return-from ,tag ,(fourth form)))))))
                   (otherwise
                    (if (gethash (car form) *special-statement-operators*)
                        form ;; by now only special forms that return nil should be left, so this is ok for implicit return
                        (return-from expressionize (return-exp form)))))))
              (return-exp form))))))

(define-statement-operator throw (&rest args)
  `(ps-js:throw ,@(mapcar #'compile-expression args)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; conditionals

(define-expression-operator if (test then &optional else)
   `(ps-js:? ,(compile-expression test) ,(compile-expression then) ,(compile-expression else)))

(define-statement-operator if (test then &optional else)
  `(ps-js:if ,(compile-expression test)
     ,(compile-statement `(progn ,then))
     ,@(when else `(:else ,(compile-statement `(progn ,else))))))

(define-expression-operator cond (&rest clauses)
  (compile-expression
   (when clauses
     (destructuring-bind (test &rest body) (car clauses)
       (if (eq t test)
           `(progn ,@body)
           `(if ,test
                (progn ,@body)
                (cond ,@(cdr clauses))))))))

(define-statement-operator cond (&rest clauses)
  `(ps-js:if ,(compile-expression (caar clauses))
     ,(compile-statement `(progn ,@(cdar clauses)))
     ,@(loop for (test . body) in (cdr clauses) appending
            (if (eq t test)
                `(:else ,(compile-statement `(progn ,@body)))
                `(:else-if ,(compile-expression test)
                           ,(compile-statement `(progn ,@body)))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; macros

(defmacro with-local-macro-environment ((var env) &body body)
  `(let* ((,var (make-macro-dictionary))
          (,env (cons ,var ,env)))
     ,@body))

(define-expression-operator macrolet (macros &body body)
  (with-local-macro-environment (local-macro-dict *macro-env*)
    (dolist (macro macros)
      (destructuring-bind (name arglist &body body)
          macro
        (setf (gethash name local-macro-dict)
              (eval (make-ps-macro-function arglist body)))))
    (ps-compile `(progn ,@body))))

(define-expression-operator symbol-macrolet (symbol-macros &body body)
  (with-local-macro-environment (local-macro-dict *symbol-macro-env*)
    (let (local-var-bindings)
      (dolist (macro symbol-macros)
        (destructuring-bind (name expansion) macro
          (setf (gethash name local-macro-dict) (lambda (x) (declare (ignore x)) expansion))
          (push name local-var-bindings)))
      (let ((*enclosing-lexicals* (append local-var-bindings *enclosing-lexicals*)))
        (ps-compile `(progn ,@body))))))

(define-expression-operator defmacro (name args &body body)
  (eval `(defpsmacro ,name ,args ,@body))
  nil)

(define-expression-operator define-symbol-macro (name expansion)
  (eval `(define-ps-symbol-macro ,name ,expansion))
  nil)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; assignment

(defun assignment-op (op)
  (getf '(ps-js:+   ps-js:+=
          ps-js:~   ps-js:~=
          ps-js:&   ps-js:&=
          ps-js:\|  ps-js:\|=
          ps-js:-   ps-js:-=
          ps-js:*   ps-js:*=
          ps-js:%   ps-js:%=
          ps-js:>>  ps-js:>>=
          ps-js:^   ps-js:^=
          ps-js:<<  ps-js:<<=
          ps-js:>>> ps-js:>>>=
          ps-js:/   ps-js:/=)
        op))

(define-expression-operator ps-assign (lhs rhs)
  (let ((rhs (ps-macroexpand rhs)))
    (if (and (listp rhs) (eq (car rhs) 'progn))
        (ps-compile `(progn ,@(butlast (cdr rhs)) (ps-assign ,lhs ,(car (last (cdr rhs))))))
        (let ((lhs (compile-expression lhs))
              (rhs (compile-expression rhs)))
          (aif (and (listp rhs)
                    (= 3 (length rhs))
                    (equal lhs (second rhs))
                    (assignment-op (first rhs)))
               (list it lhs (if (fourth rhs)
                                (cons (first rhs) (cddr rhs))
                                (third rhs)))
               (list 'ps-js:= lhs rhs))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; binding

(defmacro with-declaration-effects ((var block) &body body)
  (let ((declarations (gensym)))
   `(let* ((,var ,block)
           (,declarations (and (listp (car ,var))
                               (eq (caar ,var) 'declare)
                               (cdar ,var)))
           (,var (if ,declarations
                     (cdr ,var)
                     ,var))
           (*special-variables* (append (cdr (find 'special ,declarations :key #'car)) *special-variables*)))
      ,@body)))

(define-expression-operator let (bindings &body body)
  (with-declaration-effects (body body)
    (let* ((lexical-bindings-introduced-here             ())
           (normalized-bindings                          (mapcar (lambda (x)
                                                                   (if (symbolp x)
                                                                       (list x nil)
                                                                       (list (car x) (ps-macroexpand (cadr x)))))
                                                                 bindings))
           (free-variables-in-binding-value-expressions  (mapcan (lambda (x) (flatten (cadr x)))
                                                                 normalized-bindings)))
      (flet ((maybe-rename-lexical-var (x)
               (if (or (member x *enclosing-lexicals*)
                       (member x *enclosing-function-arguments*)
                       (lookup-macro-def x *symbol-macro-env*)
                       (member x free-variables-in-binding-value-expressions))
                   (ps-gensym (string x))
                   (progn (push x lexical-bindings-introduced-here) nil)))
             (rename (x) (first x))
             (var (x) (second x))
             (val (x) (third x)))
        (let* ((lexical-bindings      (loop for x in normalized-bindings
                                            unless (special-variable? (car x))
                                            collect (cons (maybe-rename-lexical-var (car x)) x)))
               (dynamic-bindings      (loop for x in normalized-bindings
                                            when (special-variable? (car x))
                                            collect (cons (ps-gensym (format nil "~A_~A" (car x) 'tmp-stack)) x)))
               (renamed-body          `(symbol-macrolet ,(loop for x in lexical-bindings
                                                               when (rename x) collect
                                                               `(,(var x) ,(rename x)))
                                          ,@body))
               (*enclosing-lexicals*  (append lexical-bindings-introduced-here *enclosing-lexicals*))
               (*loop-scope-lexicals* (when in-loop-scope? (append lexical-bindings-introduced-here *loop-scope-lexicals*))))
          (ps-compile
           `(progn
              ,@(mapcar (lambda (x) `(var ,(or (rename x) (var x)) ,(val x)))
                        lexical-bindings)
              ,(if dynamic-bindings
                   `(progn ,@(mapcar (lambda (x) `(var ,(rename x)))
                                     dynamic-bindings)
                           (try (progn
                                  (setf ,@(loop for x in dynamic-bindings append
                                               `(,(rename x) ,(var x)
                                                  ,(var x) ,(val x))))
                                  ,renamed-body)
                                (:finally
                                 (setf ,@(mapcan (lambda (x) `(,(var x) ,(rename x)))
                                                 dynamic-bindings)))))
                   renamed-body))))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; iteration

(defun make-for-vars/inits (init-forms)
  (mapcar (lambda (x)
            (cons (ps-macroexpand (if (atom x) x (first x)))
                  (compile-expression (if (atom x) nil (second x)))))
          init-forms))

(defun compile-loop-body (loop-vars body)
  (let* ((in-loop-scope? t)
         (*loop-scope-lexicals* loop-vars)
         (*loop-scope-lexicals-captured* ())
         (*ps-gensym-counter* *ps-gensym-counter*)
         (compiled-body (compile-statement `(progn ,@body))))
    ;; the sort is there to make order for output-tests consistent across implementations
    (aif (sort (remove-duplicates *loop-scope-lexicals-captured*) #'string< :key #'symbol-name)
         `(ps-js:block
              (ps-js:with ,(compile-expression
                         `(create ,@(loop for x in it
                                          collect x
                                          collect (when (member x loop-vars) x))))
                ,compiled-body))
         compiled-body)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; evalutation

(define-expression-operator quote (x)
  (flet ((quote% (expr) (when expr `',expr)))
    (compile-expression
     (typecase x
       (cons `(array ,@(mapcar #'quote% x)))
       (null '(array))
       (keyword x)
       (symbol (symbol-to-js-string x))
       (number x)
       (string x)
       (vector `(array ,@(loop for el across x collect (quote% el))))))))

(define-expression-operator eval-when (situation-list &body body)
  "The body is evaluated only during the given situations. The
accepted situations are :load-toplevel, :compile-toplevel,
and :execute. The code in BODY is assumed to be Common Lisp code
in :compile-toplevel and :load-toplevel sitations, and Parenscript
code in :execute."
  (when (and (member :compile-toplevel situation-list)
	     (member *compilation-level* '(:toplevel :inside-toplevel-form)))
    (eval `(progn ,@body)))
  (if (member :execute situation-list)
      (ps-compile `(progn ,@body))
      (ps-compile `(progn))))
