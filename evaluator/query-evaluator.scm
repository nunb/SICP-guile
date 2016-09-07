(define (query-driver-loop)
  "If the expression is a rule or assertion to be added to the data
base, then the information is added. Otherwise the expression is
assumed to be a query. The driver passes this query to `qeval'
together with an initial frame stream consisting of a single empty
frame resulting in a stream of frames generated by satisfying the
query with variable values found in the data base. These frames are
used to form a new stream consisting of copies of the original query
in which the variables are instantiated with values supplied by the
stream of frames, and this final stream is printed at the terminal"
  (prompt-for-input ";;; Query input:")
  (let ((q (query-syntax-process (read))))
    (cond
     ;; Add an assertion
     [(assertion-to-be-added? q)
      (add-rule-or-assertion! (add-assertion-body q))
      (newline)
      (display
       "Assertion added to data base.")
      (query-driver-loop)]
     ;; Otherwise this is a query
     [else
      (format #t "\n;;; Query Results: ")
      (display-stream
       (stream-map
        (lambda (frame)
          (instantiate
           q
           frame
           (λ (v f) (contract-question-mark v))))
        (qeval q (singleton-stream '()))))
      (query-driver-loop)])))


(define (assertion-to-be-added? exp) (eq? (type exp) 'assert!))
(define (add-assertion-body exp) (car (contents exp)))

(define (instantiate exp frame unbound-var-handler)
  "To instantiate an expression, we copy it, replacing any variables
in the expression by their values in a given frame. The values are
themselves instantiated, since they could contain variables (for
example, if `?x' in exp is bound to `?y' as the result of unification
and `?y' is in turn bound to 5). The action to take if a variable
cannot be instantiated is given by the unbound-var-handler callback"
  (define (copy exp)
    (cond
     [(var? exp)
      (let ([binding (binding-in-frame exp frame)])
        (if binding
            (copy (binding-value binding))
            (unbound-var-handler exp frame)))]
     [(pair? exp)
      (cons (copy (car exp))
            (copy (cdr exp)))]
     [else exp]))
  (copy exp))

(define (qeval query frame-stream)
  "The qeval procedure, called by the query-driver-loop, is the basic
evaluator of the query system. It takes as inputs a query and a stream
of frames, and it returns a stream of extended frames."
  (let ([qproc (get dispatch-tt 'qeval (type query))])
    (if qproc
        (qproc (contents query) frame-stream)
        (simple-query query frame-stream))))

;; Type and contents, used by qeval (4.4.4.2), specify that a special form is
;; identified by the symbol in its car. They are the same as the type-tag and
;; contents procedures in 2.4.2, except for the error message.
(define (type exp) (if (pair? exp) (car exp) (error "Invalid TYPE" exp)))
(define (contents exp) (if (pair? exp) (cdr exp) (error "Invalid CONTENTS" exp)))
(define (install-query-procedure p) (put dispatch-tt 'qeval (car p) (cadr p)))

;; Here are the syntax definitions for the and, or, not, and
;; lisp-value special forms

(define (empty-conjunction? exps) (null? exps))
(define (first-conjunct exps) (car exps))
(define (rest-conjuncts exps) (cdr exps))
(define (empty-disjunction? exps) (null? exps))
(define (first-disjunct exps) (car exps))
(define (rest-disjuncts exps) (cdr exps))
(define (negated-query exps) (car exps))
(define (predicate exps) (car exps))
(define (args exps) (cdr exps))


;; Simple Queries
(define (simple-query query-pattern frame-stream)
  "The simple-query procedure handles simple queries. It takes as
arguments a simple query (a pattern) together with a stream of frames,
and it returns the stream formed by extending each frame by all
data-base matches of the query."
  (stream-flatmap
   (λ (frame)
     (stream-append-delayed
      (find-assertions query-pattern frame)
      (delay (apply-rules query-pattern frame))))
   frame-stream))

;; Compound Queries
(define (conjoin conjuncts frame-stream)
  "And queries are handled as illustrated in Figure 4.5 by the conjoin
procedure. Conjoin takes as inputs the conjuncts and the frame stream
and returns the stream of extended frames. First, conjoin processes
the stream of frames to find the stream of all possible frame
extensions that satisfy the first query in the conjunction. Then,
using this as the new frame stream, it recursively applies conjoin to
the rest of the queries."
  (if (empty-conjunction? conjuncts)
      frame-stream
      (conjoin (rest-conjuncts conjuncts)
               (qeval
                (first-conjunct conjuncts)
                frame-stream))))

(install-query-procedure `(and ,conjoin))

(define (disjoin disjuncts frame-stream)
  "Disjoin handles `or' queries, which are handled similarly, as shown in Figure
4.6. The output streams for the various disjuncts of the or are computed
separately and merged using the interleave-delayed procedure from 4.4.4.6. (See
Exercise 4.71 and Exercise 4.72.)"
  (if (empty-disjunction? disjuncts)
      stream-null
      (interleave-delayed
       (qeval (first-disjunct disjuncts)
              frame-stream)
       (delay (disjoin
               (rest-disjuncts disjuncts)
               frame-stream)))))

(install-query-procedure `(or ,disjoin))

;; Filters

(define (negate operands frame-stream)
  "Not is handled by the method outlined in 4.4.2. We attempt to
extend each frame in the input stream to satisfy the query being
negated, and we include a given frame in the output stream only if it
cannot be extended."
  (stream-flatmap
   (lambda (frame)
     (if (stream-null?
          (qeval (negated-query operands)
                 (singleton-stream frame)))
         (singleton-stream frame)
         stream-null))
   frame-stream))

(install-query-procedure `(not ,negate))

(define (lisp-value call frame-stream)
  "Lisp-value is a filter similar to not. Each frame in the stream is
used to instantiate the variables in the pattern, the indicated
predicate is applied, and the frames for which the predicate returns
false are filtered out of the input stream. An error results if there
are unbound pattern variables. "
  (stream-flatmap
   (lambda (frame)
     (if (execute
          (instantiate
           call
           frame
           (λ (v f)
             (error "Unknown pat var: LISP-VALUE" v))))
         (singleton-stream frame)
         stream-null))
   frame-stream))

(install-query-procedure `(lisp-value ,lisp-value))

(define (execute exp)
  "Execute applies the predicate to the arguments. However, it must
not evaluate the arguments, since they are already the actual
arguments, not expressions whose evaluation (in Lisp) will produce the
arguments. Note that execute is implemented using eval and apply from
the underlying Lisp system. "
  (apply (eval (predicate exp)
               (interaction-environment))
         (args exp)))

(define (always-true ignore frame-stream)
  "The always-true special form provides for a query that is always
satisfied. It ignores its contents (normally empty) and simply passes
through all the frames in the input stream"
  frame-stream)

(install-query-procedure `(always-true ,always-true))

;; Finding Assertions By Pattern Matching
(define (find-assertions pattern frame)
  "Find-assertions, called by simple-query, takes as input a pattern
and a frame. It returns a stream of frames, each extending the given
one by a data-base match of the given pattern.

This function is not strictly required, it simply eliminates vacously
false statements"
  (stream-flatmap
   (λ (datum) (check-an-assertion datum pattern frame))
   (fetch-assertions pattern frame)))

(define (check-an-assertion assertion query-pat query-frame)
  "Check-an-assertion takes as arguments a pattern, a data object
(assertion), and a frame and returns either a one-element stream
containing the extended frame or stream-null if the match fails.
"
  (let ([match-result
         (pattern-match query-pat assertion query-frame)])
    (if (eq? match-result 'failed) stream-null
        (singleton-stream match-result))))

(define (pattern-match pat dat frame)
  (cond ((eq? frame 'failed) 'failed)
        ((equal? pat dat) frame)
        ((var? pat)
         (extend-if-consistent
          pat dat frame))
        ((and (pair? pat) (pair? dat))
         (pattern-match
          (cdr pat)
          (cdr dat)
          (pattern-match
           (car pat) (car dat) frame)))
        (else 'failed)))

(define (extend-if-consistent var dat frame)
  "Extends a frame by adding a new binding, if this is consistent with
the bindings already in the frame"
  (let ([binding (binding-in-frame var frame)])
    (if binding
        (pattern-match
         (binding-value binding) dat frame)
        (extend var dat frame))))

(define (apply-rules pattern frame)
  "Apply-rules is the rule analog of `find-assertions'. It takes as
input a pattern and a frame, and it forms a stream of extension frames
by applying rules from the data base. `stream-flatmap' maps
apply-a-rule down the stream of possibly applicable rules (selected by
`fetch-rules') and combines the resulting streams of frames."
  (stream-flatmap
   (λ (rule) (apply-a-rule rule pattern frame))
   (fetch-rules pattern frame)))

(define (apply-a-rule rule query-pattern query-frame)
  "`apply-a-rule' applies rules using the method outlined in 4.4.2. It
first augments its argument frame by unifying the rule conclusion with
the pattern in the given frame. If this succeeds, it evaluates the
rule body in this new frame. "
  (let* ([clean-rule
          (rename-variables-in rule)] ; alpha-conversion
         [unify-result
          (unify-match query-pattern
                       (conclusion clean-rule)
                       query-frame)])
    (if (eq? unify-result 'failed)
        stream-null
        (qeval (rule-body clean-rule)
               (singleton-stream
                unify-result)))))

(define (rename-variables-in rule)
  "We generate unique variable names by associating a unique
identifier (such as a number) with each rule application and combining
this identifier with the original variable names. For example, if the
rule-application identifier is 7, we might change each ?x in the rule
to ?x-7 and each ?y in the rule to ?y-7."
  (let ([rule-application-id (new-rule-application-id)])
    (define (tree-walk exp)
      (cond [(var? exp)
             (make-new-variable
              exp
              rule-application-id)]
            [(pair? exp)
             (cons (tree-walk (car exp))
                   (tree-walk (cdr exp)))]
            [else exp]))
    (tree-walk rule)))

(define (unify-match p1 p2 frame)
  "The unification algorithm is implemented as a procedure that takes
as inputs two patterns and a frame and returns either the extended
frame or the symbol failed. The unifier is like the pattern matcher
except that it is symmetrical—variables are allowed on both sides of
the match. Unify-match is basically the same as pattern-match, except
that there is extra code to handle the case where the object on the
right side of the match is a variable. "
  (cond
   [(eq? frame 'failed) 'failed]
   [(equal? p1 p2) frame]
   [(var? p1) (extend-if-possible p1 p2 frame)]
   [(var? p2) ; handle object on right side as variable
    (extend-if-possible p2 p1 frame)]
   [(and (pair? p1) (pair? p2))
    (unify-match
     (cdr p1)
     (cdr p2)
     (unify-match (car p1) (car p2) frame))]
   [else 'failed]))

(define (extend-if-possible var val frame)
  "In unification, as in one-sided pattern matching, we want to accept
a proposed extension of the frame only if it is consistent with
existing bindings. The procedure `extend-if-possible' used in
unification is the same as the `extend-if-consistent' used in pattern
matching except for two special checks, marked “***” in the program
below. In the first case, if the variable we are trying to match is
not bound, but the value we are trying to match it with is itself a
(different) variable, it is necessary to check to see if the value is
bound, and if so, to match its value. If both parties to the match are
unbound, we may bind either to the other.

The second check deals with attempts to bind a variable to a pattern
that includes that variable. Such a situation can occur whenever a
variable is repeated in both patterns. Consider, for example, unifying
the two patterns (?x ?x) and (?y ⟨expression involving ?y⟩) in a frame
where both ?x and ?y are unbound. First ?x is matched against ?y,
making a binding of ?x to ?y. Next, the same ?x is matched against the
given expression involving ?y. Since ?x is already bound to ?y, this
results in matching ?y against the expression. If we think of the
unifier as finding a set of values for the pattern variables that make
the patterns the same, then these patterns imply instructions to find
a ?y such that ?y is equal to the expression involving ?y. There is no
general method for solving such equations, so we reject such bindings;
these cases are recognized by the predicate depends-on?.284 On the
other hand, we do not want to reject attempts to bind a variable to
itself. For example, consider unifying (?x ?x) and (?y ?y). The second
attempt to bind ?x to ?y matches ?y (the stored value of ?x) against
?y (the new value of ?x). This is taken care of by the equal? clause
of unify-match."
  (let ((binding (binding-in-frame var frame)))
    (cond (binding
           (unify-match
            (binding-value binding) val frame))
          ((var? val)                   ; ***
           (let ((binding
                  (binding-in-frame
                   val
                   frame)))
             (if binding
                 (unify-match
                  var
                  (binding-value binding)
                  frame)
                 (extend var val frame))))
          ((depends-on? val var frame)  ; ***
           'failed)
          (else (extend var val frame)))))

(define (depends-on? exp var frame)
  "Depends-on? is a predicate that tests whether an expression
proposed to be the value of a pattern variable depends on the
variable. This must be done relative to the current frame because the
expression may contain occurrences of a variable that already has a
value that depends on our test variable. The structure of depends-on?
is a simple recursive tree walk in which we substitute for the values
of variables whenever necessary."
  (define (tree-walk e)
    (cond ((var? e)
           (if (equal? var e)
               #t
               (let
                   ((b (binding-in-frame e frame)))
                 (if b
                     (tree-walk
                      (binding-value b))
                     #f))))
          ((pair? e)
           (or (tree-walk (car e))
               (tree-walk (cdr e))))
          (else #f)))
  (tree-walk exp))

;; Database Maintainence

;; One important problem in designing logic programming languages is that
;; of arranging things so that as few irrelevant data-base entries as
;; possible will be examined in checking a given pattern. In our system,
;; in addition to storing all assertions in one big stream, we store all
;; assertions whose cars are constant symbols in separate streams, in a
;; table indexed by the symbol. To fetch an assertion that may match a
;; pattern, we first check to see if the car of the pattern is a constant
;; symbol. If so, we return (to be tested using the matcher) all the
;; stored assertions that have the same car. If the pattern’s car is not
;; a constant symbol, we return all the stored assertions. Cleverer
;; methods could also take advantage of information in the frame, or try
;; also to optimize the case where the car of the pattern is not a
;; constant symbol. We avoid building our criteria for indexing (using
;; the car, handling only the case of constant symbols) into the program;
;; instead we call on predicates and selectors that embody our criteria.

(define THE-ASSERTIONS stream-null)

(define (fetch-assertions pattern frame)
  (if (use-index? pattern)
      (get-indexed-assertions pattern)
      (get-all-assertions)))

(define (get-all-assertions) THE-ASSERTIONS)

;; TODO get-stream && `get'
(define stream-table (make <dispatch-table>))
(define (get-indexed-assertions pattern)
  (get-stream (index-key-of pattern) 'assertion-stream))

(define (get-stream key1 key2)
  "Get-stream looks up a stream in the table and returns an empty
stream if nothing is stored there."
  (let ((s (get stream-table key1 key2)))
    (if s s stream-null)))

;; Rules are stored similarly, using the car of the rule conclusion. Rule
;; conclusions are arbitrary patterns, however, so they differ from
;; assertions in that they can contain variables. A pattern whose car is
;; a constant symbol can match rules whose conclusions start with a
;; variable as well as rules whose conclusions have the same car. Thus,
;; when fetching rules that might match a pattern whose car is a constant
;; symbol we fetch all rules whose conclusions start with a variable as
;; well as those whose conclusions have the same car as the pattern. For
;; this purpose we store all rules whose conclusions start with a
;; variable in a separate stream in our table, indexed by the symbol ?.

(define THE-RULES stream-null)

(define (fetch-rules pattern frame)
  (if (use-index? pattern)
      (get-indexed-rules pattern)
      (get-all-rules)))

(define (get-all-rules) THE-RULES)

(define (get-indexed-rules pattern)
  (stream-append
   (get-stream (index-key-of pattern)
               'rule-stream)
   (get-stream '? 'rule-stream)))

(define (add-rule-or-assertion! assertion)
  "Add-rule-or-assertion! is used by query-driver-loop to add
assertions and rules to the data base. Each item is stored in the
index, if appropriate, and in a stream of all assertions or rules in
the data base."
  (if (rule? assertion)
      (add-rule! assertion)
      (add-assertion! assertion)))

(define (add-assertion! assertion)
  (store-assertion-in-index assertion)
  (let ((old-assertions THE-ASSERTIONS))
    (set! THE-ASSERTIONS
          (stream-cons assertion
                       old-assertions))
    'ok))

(define (add-rule! rule)
  (store-rule-in-index rule)
  (let ((old-rules THE-RULES))
    (set! THE-RULES
          (stream-cons rule old-rules))
    'ok))

(define (store-assertion-in-index assertion)
  "To actually store an assertion or a rule, we check to see if it can
be indexed. If so, we store it in the appropriate stream."
  (if (indexable? assertion)
      (let ((key (index-key-of assertion)))
        (let ((current-assertion-stream
               (get-stream
                key 'assertion-stream)))
          (put stream-table
               key
               'assertion-stream
               (stream-cons
                assertion
                current-assertion-stream))))))

(define (store-rule-in-index rule)
  (let ((pattern (conclusion rule)))
    (if (indexable? pattern)
        (let ((key (index-key-of pattern)))
          (let ((current-rule-stream
                 (get-stream
                  key 'rule-stream)))
            (put stream-table
                 key
                 'rule-stream
                 (stream-cons
                  rule
                  current-rule-stream)))))))

(define (indexable? pat)
  "The following procedures define how the data-base index is used. A
pattern (an assertion or a rule conclusion) will be stored in the
table if it starts with a variable or a constant symbol."
  (or (constant-symbol? (car pat))
      (var? (car pat))))


(define (index-key-of pat)
  "The key under which a pattern is stored in the table is either ?
(if it starts with a variable) or the constant symbol with which it
starts."
  (let ((key (car pat)))
    (if (var? key) '? key)))

(define (use-index? pat)
  "The index will be used to retrieve items that might match a pattern
if the pattern starts with a constant symbol."
  (constant-symbol? (car pat)))

;; Stream operations
;; (use-modules (ice-9 streams))
(define (display-stream s)
  (stream-for-each display-line s))

(define (display-line x)
  (newline)
  (display x))

(define (interleave s1 s2)
  (if (stream-null? s1)
      s2
      (stream-cons (stream-car s1)
                   (interleave s2 (stream-cdr s1)))))

#| Streams:

Stream-append-delayed and interleave-delayed are just like stream-append and
interleave (3.5.3), except that they take a delayed argument (like the integral
procedure in 3.5.4). This postpones looping in some cases
|#

(define (stream-append-delayed s1 delayed-s2)
  (if (stream-null? s1)
      (force delayed-s2)
      (stream-cons
       (stream-car s1)
       (stream-append-delayed (stream-cdr s1) delayed-s2))))

(define (interleave-delayed s1 delayed-s2)
  (if (stream-null? s1)
      (force delayed-s2)
      (stream-cons
       (stream-car s1)
       (interleave-delayed (force delayed-s2)
                           (delay (stream-cdr s1))))))

(define (stream-flatmap proc s)
  (flatten-stream (stream-map proc s)))

(define (flatten-stream stream)
  (if (stream-null? stream) stream-null
      (interleave-delayed
       (stream-car stream)
       (delay (flatten-stream (stream-cdr stream))))))

(define (singleton-stream x)
  "Stream-flatmap, which is used throughout the query evaluator to map a
procedure over a stream of frames and combine the resulting streams of frames,
is the stream analog of the flatmap procedure introduced for ordinary lists in
As long as `old-assertions' is being copied (and isn't simply a new
reference), this creates an infinite loop when referncing an assertion that
2.2.3. Unlike ordinary flatmap, however, we accumulate the streams with an
interleaving process, rather than simply appending them"
  (stream-cons x stream-null))

;; The following three procedures define the syntax of rules:

(define (rule? statement)
  (tagged-list? statement 'rule))

(define (conclusion rule) (cadr rule))

(define (rule-body rule)
  (if (null? (cddr rule))
      '(always-true)
      (caddr rule)))

;; Query-driver-loop (4.4.4.1) calls query-syntax-process to transform
;; pattern variables in the expression, which have the form ?symbol, into
;; the internal format (? symbol). That is to say, a pattern such as (job
;; ?x ?y) is actually represented internally by the system as (job (? x)
;; (? y)). This increases the efficiency of query processing, since it
;; means that the system can check to see if an expression is a pattern
;; variable by checking whether the car of the expression is the symbol
;; ?, rather than having to extract characters from the symbol. The
;; syntax transformation is accomplished by the following procedure:285

(define (query-syntax-process exp)
  "Transform `(job ?x ?y)' => `(job (? x) (? y))'"
  (map-over-symbols expand-question-mark exp))

(define (map-over-symbols proc exp)
  (cond ((pair? exp)
         (cons (map-over-symbols
                proc (car exp))
               (map-over-symbols
                proc (cdr exp))))
        ((symbol? exp) (proc exp))
        (else exp)))

(define (expand-question-mark symbol)
  (let ((chars (symbol->string symbol)))
    (if (string=? (substring chars 0 1) "?")
        (list '? (string->symbol
                  (substring
                   chars
                   1
                   (string-length chars))))
        symbol)))

;; Once the variables are transformed in this way, the variables in a
;; pattern are lists starting with ?, and the constant symbols are just
;; the symbols.

(define (var? exp) (tagged-list? exp '?))
(define (constant-symbol? exp) (symbol? exp))

;; Unique variables are constructed during rule application (in 4.4.4.4)
;; by means of the following procedures. The unique identifier for a rule
;; application is a number, which is incremented each time a rule is
;; applied.

(define rule-counter 0)

(define (new-rule-application-id)
  (set! rule-counter (+ 1 rule-counter))
  rule-counter)

(define (make-new-variable
         var rule-application-id)
  (cons '? (cons rule-application-id
                 (cdr var))))

;; When query-driver-loop instantiates the query to print the answer,
;; it converts any unbound pattern variables back to the right form for
;; printing, using
(define (contract-question-mark variable)
  (string->symbol
   (string-append "?"
                  (if (number? (cadr variable))
                      (string-append
                       (symbol->string (caddr variable))
                       "-"
                       (number->string (cadr variable)))
                      (symbol->string (cadr variable))))))

;; Frames are represented as lists of bindings, which are variable-value pairs:

(define (make-binding variable value)
  (cons variable value))

(define (binding-variable binding)
  (car binding))

(define (binding-value binding)
  (cdr binding))

(define (binding-in-frame variable frame)
  (assoc variable frame))

(define (extend variable value frame)
  (cons (make-binding variable value) frame))
