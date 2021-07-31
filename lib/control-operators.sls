#!r6rs

;; Copyright (C) Marc Nieper-Wißkirchen (2021).  All Rights Reserved.

;; Permission is hereby granted, free of charge, to any person
;; obtaining a copy of this software and associated documentation
;; files (the "Software"), to deal in the Software without
;; restriction, including without limitation the rights to use, copy,
;; modify, merge, publish, distribute, sublicense, and/or sell copies
;; of the Software, and to permit persons to whom the Software is
;; furnished to do so, subject to the following conditions:

;; The above copyright notice and this permission notice shall be
;; included in all copies or substantial portions of the Software.

;; THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
;; EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
;; MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
;; NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS
;; BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN
;; ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
;; CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
;; SOFTWARE.

(library (control-operators)
  (export call-with-continuation-prompt abort-current-continuation
	  call-with-current-continuation call-with-composable-continuation
	  continuation?
	  call-in-continuation continuation-prompt-available?
	  call-with-continuation-barrier dynamic-wind
	  with-continuation-mark call-with-immediate-continuation-mark
	  continuation-mark-set->list continuation-mark-set->list*
	  continuation-mark-set->iterator continuation-mark-set-first
          make-continuation-prompt-tag continuation-prompt-tag?
	  default-continuation-prompt-tag
          make-continuation-mark-key continuation-mark-key?
	  condition-prompt-tag
	  &continuation make-continuation-error continuation-error?
	  continuation-prompt-tag
	  guard else =>
	  run
	  (rename (call-with-current-continuation call/cc)))
  (import (except (rnrs (6))
		  call/cc
		  call-with-current-continuation
		  dynamic-wind
		  guard)
	  (control-operators define-who)
	  (control-operators primitives))

  ;; TODO:
  ;; parameterize with body in tail position. (we may need to handle io parameters special).
  ;; Check how to handle shallow marks.
  ;; Demonstrate interoperability with SRFI 18 threads.
  ;; Add a guard form.
  ;; Optimize (mark-set-first).
  ;; Optimize (shortcuts).

  ;; Conditions

  (define-condition-type &continuation &error
    make-continuation-error continuation-error?
    (prompt-tag condition-prompt-tag))

  (define continuation-error
    (lambda (who msg prompt-tag . irr*)
      (let ((c (condition
		(make-continuation-error prompt-tag)
		(make-message-condition msg)
		(make-irritants-condition irr*))))
	(raise
	 (if who
	     (condition c (make-who-condition who))
	     c)))))

  ;; Continuation mark keys

  (define-record-type continuation-mark-key
    (nongenerative) (sealed #t) (opaque #f)
    (fields (mutable name))
    (protocol
     (lambda (p)
       (case-lambda
	[() (p #f)]
	[(name)
	 (assert (symbol? name))
	 (p name)]))))

  ;; Continuation prompt tags

  (define-record-type (%continuation-prompt-tag make-continuation-prompt-tag continuation-prompt-tag?)
    (nongenerative) (sealed #t) (opaque #f)
    (fields (mutable name))
    (protocol
     (lambda (p)
       (case-lambda
	[() (p #f)]
	[(name)
	 (assert (symbol? name))
	 (p name)]))))

  (define default-continuation-prompt-tag
    (let ([prompt-tag (make-continuation-prompt-tag 'default)])
      (lambda ()
	prompt-tag)))

  (define continuation-barrier-tag
    (let ([barrier-tag (make-continuation-prompt-tag 'barrier)])
      (lambda ()
	barrier-tag)))

  ;; Continuation info

  (define-record-type continuation-info
    (nongenerative) (sealed #t) (opaque #f)
    (fields metacontinuation prompt-tag resume-k non-composable?)
    (protocol
     (lambda (p)
       (lambda (mk tag c non-comp?)
	 (assert (continuation-prompt-tag? tag))
	 (assert (procedure? c))
	 (assert (boolean? non-comp?))
	 (p mk tag c non-comp?)))))

  (define make-continuation
    (lambda (mk k marks winders prompt-tag resume-k non-composable?)
      (%lambda-box
       (make-continuation-info mk prompt-tag resume-k non-composable?)
       val* (resume-k (lambda () (apply values val*))))))

  (define continuation->continuation-info
    (lambda (who k)
      (or
       (%lambda-box-ref k #f)
       (assertion-violation who "not a continuation" k))))

  (define continuation-metacontinuation
    (lambda (who k)
      (continuation-info-metacontinuation
       (continuation->continuation-info who k))))

  (define continuation-resume-k
    (lambda (who k)
      (continuation-info-resume-k
       (continuation->continuation-info who k))))

  (define continuation-prompt-tag
    (lambda (who k)
      (continuation-info-prompt-tag
       (continuation->continuation-info who k))))

  (define continuation-non-composable?
    (lambda (who k)
      (continuation-info-non-composable?
       (continuation->continuation-info who k))))

  (define continuation?
    (lambda (obj)
      (continuation-info? (%lambda-box-ref obj #f))))

  ;; Marks

  (define make-marks
    (lambda ()
      '()))

  (define marks-ref
    (case-lambda
     [(marks key)
      (marks-ref marks key (lambda () (assert #f)))]
     [(marks key fail)
      (marks-ref marks key fail values)]
     [(marks key fail succ)
      (cond
       [(assq key marks) => (lambda (a) (succ (cdr a)))]
       [else (fail)])]))

  (define marks-ref*
    (lambda (marks keys default)
      (let ([n (length keys)])
	(let f ([keys keys] [i 0] [vec #f])
	  (define g (lambda (vec) (f (cdr keys) (fx+ i 1) vec)))
	  (if (null? keys)
	      vec
	      (marks-ref
	       marks
	       (car keys)
	       (lambda ()
		 (g vec))
	       (lambda (val)
		 (let ([vec (or vec (make-vector n default))])
		   (vector-set! vec i val)
		   (g vec)))))))))

  (define marks-empty?
    (lambda (marks)
      (null? marks)))

  (define current-marks
    (let ([marks (make-marks)])
      (case-lambda
       [() marks]
       [(m) (set! marks m)])))

  (define empty-marks?
    (lambda ()
      (marks-empty? (current-marks))))

  (define clear-marks!
    (lambda ()
      (current-marks (make-marks))))

  (define set-mark!
    (lambda (key val)
      (current-marks
       (cons (cons key val) (current-marks)))))

  (define ref-mark
    (lambda (key default)
      (marks-ref (current-marks) key (lambda () default))))

  ;; Winders

  (define current-winders
    (let ([winders '()])
      (case-lambda
       [() winders]
       [(w)
	(set! winders w)])))

  (define-record-type winder
    (nongenerative) (sealed #t) (opaque #f)
    (fields height continuation marks pre-thunk post-thunk)
    (protocol
     (lambda (p)
       (lambda (ht k marks pre-thunk post-thunk)
	 (assert (fixnum? ht))
	 (assert (procedure? k))
	 (assert (procedure? pre-thunk))
	 (assert (procedure? post-thunk))
	 (p ht k marks pre-thunk post-thunk)))))

  (define winders-height
    (lambda (winders)
      (if (null? winders)
	  0
	  (fx+ (winder-height (car winders)) 1))))

  ;; Mark set frames

  (define-record-type mark-set-frame
    (nongenerative) (sealed #t) (opaque #f)
    (fields tag marks)
    (protocol
     (lambda (p)
       (lambda (tag marks)
	 (assert (or (not tag)
		     (continuation-prompt-tag? tag)))
	 (p tag marks)))))

  ;; Continuation mark sets

  (define-record-type continuation-mark-set
    (nongenerative) (sealed #t) (opaque #f)
    (fields frames))

  ;; Threads

  ;; TODO

  (define %current-thread
    (let ([current-thread #f])
      (case-lambda
       [() current-thread]
       [(thread) (set! current-thread thread)])))

  (define current-thread
    (lambda ()
      (assert (%current-thread))))

  (define-record-type thread
    (nongenerative) (sealed #t)
    (fields thunk name)
    (protocol
     (lambda (p)
       (define (make-thread thunk name)
	 (assert (procedure? thunk))
	 (p thunk name))
       (case-lambda
	[(thunk) (make-thread thunk #f)]
	[(thunk name) (make-thread thunk name)]))))

  ;; Metacontinuations

  (define-record-type metacontinuation-frame
    (nongenerative) (sealed #t) (opaque #f)
    (fields tag continuation handler marks winders) ;TODO: Move handler before contination.
    (protocol
     (lambda (p)
       (lambda (tag k handler marks winders)
	 (assert (or (not tag)
		     (continuation-prompt-tag? tag)))
	 (assert (procedure? k))
	 (assert (or (not handler) (procedure? handler)))
	 (p tag k handler marks winders)))))

  (define current-metacontinuation
    (let ([metacontinuation '()])
      (case-lambda
       [() metacontinuation]
       [(mk) (set! metacontinuation mk)])))

  (define reset-metacontinuation!
    (lambda (k)
      (current-metacontinuation
       (list
	(make-metacontinuation-frame
	 (default-continuation-prompt-tag)
	 k
	 (make-default-handler (default-continuation-prompt-tag))
	 (make-marks)
	 '())))))

  (define push-continuation!
    (lambda (k marks winders)
      (when (or (not (empty-continuation? k))
		(not (marks-empty? marks))
		(null? winders))
	(push-metacontinuation-frame!
	 (make-metacontinuation-frame
	  #f k #f marks winders)))
      (clear-marks!)
      (current-winders '())))

  (define push-metacontinuation-frame!
    (lambda (frame)
      (assert (metacontinuation-frame? frame))
      (current-metacontinuation
       (cons frame (current-metacontinuation)))))

  (define pop-metacontinuation-frame!
    (lambda ()
      (let ([mk (current-metacontinuation)])
	(assert (pair? mk))
	(let ([mf (car mk)])
	  (current-metacontinuation (cdr mk))
	  (current-marks (metacontinuation-frame-marks mf))
	  (current-winders (metacontinuation-frame-winders mf))
	  mf))))

  (define append-metacontinuation!
    (lambda (mk)
      (current-metacontinuation (append mk (current-metacontinuation)))))

  (define take-metacontinuation
    (lambda (who prompt-tag barrier?)
      (let f ([mk (current-metacontinuation)])
	(when (null? mk)
	  (assertion-violation who "continuation includes no prompt with the given tag" prompt-tag))
	(let ([frame (car mk)] (mk (cdr mk)))
	  (let ([tag (metacontinuation-frame-tag frame)])
	    (cond
	     [(eq? tag prompt-tag)
	      '()]
	     [(and barrier? (eq? tag (continuation-barrier-tag)))
	      (continuation-error who "applying the composable continuation would introduce a continuation barrier"
				  prompt-tag)]
	     [else
	      (cons frame (f mk))]))))))

  (define take-mark-set-frames
   (lambda (mk prompt-tag)
     (%call-with-current-continuation
      (lambda (k)
	(let f ([mk mk])
	  (when (null? mk)
	    (k #f))
	  (let ([frame (car mk)] [mk (cdr mk)])
	    (let ([tag (metacontinuation-frame-tag frame)])
	      (if (eq? tag prompt-tag)
		  '()
		  (let ([marks (metacontinuation-frame-marks frame)])
		    (if (and (not tag) (marks-empty? marks))
			(f mk)
			(cons (make-mark-set-frame tag marks) (f mk))))))))))))

  ;; Trampoline

  (define empty-continuation
    (let ([continuation #f])
      (case-lambda
       [()
	(assert continuation)]
       [(k)
	(assert (procedure? k))
	(set! continuation k)])))

  (define abort-continuation
    (let ([continuation #f])
      (case-lambda
       [()
	(assert continuation)]
       [(k)
	(assert (procedure? k))
	(set! continuation k)])))

  (define abort
    (lambda (thunk)
      (assert (procedure? thunk))
      (%call-in-continuation (empty-continuation) thunk)))

  (define empty-continuation?
    (lambda (k)
      (%continuation=? k (empty-continuation))))

  (define run
    (lambda (thunk)
      (%call-with-current-continuation
       (lambda (k)
	 (reset-metacontinuation! k)
	 (call-with-values
	     (lambda ()
	       (%call-with-current-continuation
		(lambda (k)
		  (empty-continuation k)
		  (abort thunk))))
	   (lambda val*
	     (let ([mf (pop-metacontinuation-frame!)])
	       (apply (metacontinuation-frame-continuation mf) val*))))))))

  (define call-in-empty-continuation
    (lambda (thunk)
      (%call-with-current-continuation
       (lambda (k)
	 (when (not (empty-continuation? k))
	   (push-metacontinuation-frame!
	    (make-metacontinuation-frame #f k #f (current-marks) (current-winders)))
	   (clear-marks!)
	   (current-winders '()))
	 (abort thunk)))))

  (define call-in-empty-marks
    (case-lambda
     [(thunk)
      (call-in-empty-marks #f #f thunk)]
     [(tag handler thunk)
      (%call-with-current-continuation
       (lambda (k)
	 (when (or tag
		   (not (empty-continuation? k))
		   (not (empty-marks?)))
	   (push-metacontinuation-frame!
	    (make-metacontinuation-frame tag k handler (current-marks) (current-winders)))
	   (clear-marks!)
	   (current-winders '()))
	 (abort thunk)))]))

  (define abort-to
    (lambda (k marks winders thunk)
      (assert (procedure? k))
      (%call-in-continuation
       k
       (lambda ()
	 (current-marks marks)
	 (current-winders winders)
	 (thunk)))))

  ;; Continuation prompts

  (define call-with-continuation-prompt
    (case-lambda
     [(thunk)
      (call-with-continuation-prompt thunk (default-continuation-prompt-tag))]
     [(thunk prompt-tag)
      (call-with-continuation-prompt thunk prompt-tag
				     (make-default-handler prompt-tag))]
     [(thunk prompt-tag handler)
      (assert (continuation-prompt-tag? prompt-tag))
      (assert (procedure? handler))
      (call-in-empty-marks prompt-tag handler thunk)]))

  (define make-default-handler
    (lambda (prompt-tag)
      (lambda (thunk)
	(call-with-continuation-prompt thunk prompt-tag))))

  (define/who abort-current-continuation
    (lambda (prompt-tag . arg*)
      (unless (continuation-prompt-tag? prompt-tag)
	(assertion-violation 'who "not a continuation prompt tag" prompt-tag))
      (unless
	  (metacontinuation-contains-prompt?
	   (current-metacontinuation)
	   prompt-tag)
	(continuation-error
	 who "no prompt with the given tag in current continuation" prompt-tag))
      (let f ()
	(if (null? (current-winders))
	    (let ([mf (car (current-metacontinuation))])
	      (if (eq? (metacontinuation-frame-tag mf) prompt-tag)
		  (let ([handler (metacontinuation-frame-handler mf)])
		    (pop-metacontinuation-frame!)
		    (abort-to
		     (metacontinuation-frame-continuation mf)
		     (metacontinuation-frame-marks mf)
		     (metacontinuation-frame-winders mf)
		     (lambda ()
		       (apply handler arg*))))
		  (begin
		    (pop-metacontinuation-frame!)
		    (f))))
	    (wind-to
	     (current-marks)
	     '()
	     f
	     (lambda ()
	       (unless
		   (metacontinuation-contains-prompt?
		    (current-metacontinuation)
		    prompt-tag)
		 (continuation-error
		  who
		  "lost prompt with the given tag during abort of the current continuation"
		  prompt-tag))
	       (f)))))

      (let f ([mk (current-metacontinuation)])
	(when (null? mk)
	  (continuation-error
	   who
	   "prompt tag not found in current continuation"
	   prompt-tag))
	(let ([frame (car mk)] [mk (cdr mk)])
	  (if (eq? (metacontinuation-frame-tag frame) prompt-tag)
	      (let ([handler (metacontinuation-frame-handler frame)])
		(current-metacontinuation mk)
		(abort-to
		 (metacontinuation-frame-continuation frame)
		 (metacontinuation-frame-marks frame)
		 (metacontinuation-frame-winders frame)
		 (lambda ()
		   (apply handler arg*))))
	      ;; we have to remove the frame...

	      (f mk))))))

  ;; Continuations

  (define make-composable-continuation
    (lambda (mk k marks winders prompt-tag)
      (make-continuation
       mk
       k
       marks
       winders
       prompt-tag
       (lambda (thunk)
	 (call-in-composable-continuation mk k marks winders thunk))
       #f)))

  (define make-non-composable-continuation
    (lambda (mk k marks winders prompt-tag)
      (make-continuation
       mk
       k
       marks
       winders
       prompt-tag
       (lambda (thunk)
	 (call-in-non-composable-continuation mk k marks winders prompt-tag thunk))
       #t)))

  (define call-in-composable-continuation
    (lambda (mk k marks winders thunk)
      (call-in-empty-marks
       (lambda ()
	 (abort-to-composition (reverse mk) k marks winders thunk #f)))))

  (define call-in-non-composable-continuation
    (lambda (mk k marks winders prompt-tag thunk)
      (let retry ()
	(let-values ([(dest-mf* base-mk)
		      (common-metacontinuation #f mk (current-metacontinuation) prompt-tag)])
	  (let f ()
	    (if (eq? (current-metacontinuation) base-mk)
		(abort-to-composition dest-mf* k marks winders thunk retry)
		(wind-to
		 (current-marks)
		 '()
		 (lambda ()
		   (pop-metacontinuation-frame!)
		   (f))
		 retry)))))))

  (define abort-to-composition
    (lambda (mf* k marks winders thunk maybe-again-thunk)
      (let f ([mf* mf*])
	(if (null? mf*)
	    (wind-to
	     marks
	     winders
	     (lambda ()
	       (abort-to k marks winders thunk))
	     maybe-again-thunk)
	    (let ([mf (car mf*)])
	      (wind-to
	       (metacontinuation-frame-marks mf)
	       (metacontinuation-frame-winders mf)
	       (lambda ()
		 (current-metacontinuation (cons mf (current-metacontinuation)))
		 (current-winders '())
		 (f (cdr mf*)))
	       maybe-again-thunk))))))

  (define/who call-with-current-continuation
    (case-lambda
     [(proc)
      (call-with-current-continuation proc (default-continuation-prompt-tag))]
     [(proc prompt-tag)
      (assert (procedure? proc))
      (assert (continuation-prompt-tag? prompt-tag))
      (%call-with-current-continuation
       (lambda (k)
	 (proc (make-non-composable-continuation
		(take-metacontinuation who prompt-tag #f)
		k
		(current-marks)
		(current-winders)
		prompt-tag))))]))

  (define/who call-with-composable-continuation
    (case-lambda
     [(proc)
      (call-with-composable-continuation proc (default-continuation-prompt-tag))]
     [(proc prompt-tag)
      (assert (procedure? proc))
      (assert (continuation-prompt-tag? prompt-tag))
      (%call-with-current-continuation
       (lambda (k)
	 (proc
	  (make-composable-continuation
	   (take-metacontinuation who prompt-tag #t)
	   k
	   (current-marks)
	   (current-winders)
	   prompt-tag))))]))

  (define common-metacontinuation
    (lambda (who dest-mk current-mk tag)
      (let ([base-mk*
	     (let f ([current-mk current-mk] [base-mk* '()])
	       (when (null? current-mk)
		 (continuation-error who "current continuation includes no prompt with the given tag" tag))
	       (if (eq? (metacontinuation-frame-tag (car current-mk)) tag)
		   (cons current-mk base-mk*)
		   (f (cdr current-mk) (cons current-mk base-mk*))))])
	(let f ([dest-mf* (reverse dest-mk)]
		[base-mk* (cdr base-mk*)]
		[base-mk (car base-mk*)])
	  (cond
	   [(null? dest-mf*)
	    (values '() base-mk)]
	   [(null? base-mk*)
	    (check-for-barriers dest-mf* tag)
	    (values dest-mf* base-mk)]
	   [(eq? (car dest-mf*) (caar base-mk*))
	    (f (cdr dest-mf*) (cdr base-mk*) (car base-mk*))]
	   [else
	    (check-for-barriers dest-mf* tag)
	    (values dest-mf* base-mk)])))))

  (define check-for-barriers
    (lambda (dest-mf* tag)
      (do ([dest-mf* dest-mf* (cdr dest-mf*)])
	  ((null? dest-mf*))
	(when (eq? (metacontinuation-frame-tag (car dest-mf*)) (continuation-barrier-tag))
	  (continuation-error #f "apply the continuation would introduce a continuation barrier" tag)))))

  (define call-in-continuation
    (lambda (k thunk)
      ((continuation-resume-k 'call-in-continuation k) thunk)))

  (define/who continuation-prompt-available?
    (case-lambda
     [(tag)
      (metacontinuation-contains-prompt? (current-metacontinuation) tag)]
     [(tag k)
      (or (and (continuation-non-composable? who k)
	       (eq? (continuation-prompt-tag who k) tag))
	  (metacontinuation-contains-prompt? (continuation-metacontinuation who k) tag))]))

  (define metacontinuation-contains-prompt?
    (lambda (mk tag)
      (let f ([mk mk])
	(and (not (null? mk))
	     (or (eq? (metacontinuation-frame-tag (car mk)) tag)
		 (f (cdr mk)))))))

  (define call-with-continuation-barrier
    (lambda (thunk)
      (call-in-empty-marks (continuation-barrier-tag) #f thunk)))

  ;; Dynamic-wind

  (define/who dynamic-wind
    (lambda (pre-thunk thunk post-thunk)
      (unless (procedure? pre-thunk)
	(assertion-violation who "not a procedure" pre-thunk))
      (unless (procedure? thunk)
	(assertion-violation who "not a procedure" pre-thunk))
      (unless (procedure? post-thunk)
	(assertion-violation who "not a procedure" pre-thunk))
      (%call-with-current-continuation
       (lambda (k)
	 (let* ([winders (current-winders)]
		[winder (make-winder (winders-height winders)
				     k
				     (current-marks)
				     pre-thunk post-thunk)])
	   (pre-thunk)
	   (current-winders (cons winder winders))
	   (call-with-values thunk
	     (lambda val*
	       (current-winders winders)
	       (post-thunk)
	       (apply values val*))))))))

  (define wind-to
    (lambda (marks dest-winders then-thunk maybe-again-thunk)
      (let ([saved-mk (current-metacontinuation)])
	(current-marks marks)
	(let f ([winder* '()] [dest-winders dest-winders])
	  (if (and maybe-again-thunk (not (eq? saved-mk (current-metacontinuation))))
	      (maybe-again-thunk)
	      (let ([winders (current-winders)])
		(cond
		 [(winders=? dest-winders winders)
		  (if (null? winder*)
		      (then-thunk)
		      (let ([winders (cons (car winder*) winders)]
			    [winder* (cdr winder*)])
			(rewind winders
				(lambda ()
				  (current-winders winders)
				  (f winder* winders)))))]
		 [(or (null? dest-winders)
		      (and (not (null? winders))
			   (fx>? (winder-height (car winders))
				 (winder-height (car dest-winders)))))
		  (unwind winders
			  (lambda ()
			    (f winder* dest-winders)))]
		 [else
		  (f (cons (car dest-winders) winder*) (cdr dest-winders))])))))))

  (define wind
    (lambda (winders ref then-thunk)
      (let ([winder (car winders)]
	    [winders (cdr winders)])
	(let ([winder-thunk (ref winder)])
	  (abort-to
	   (winder-continuation winder)
	   (winder-marks winder)
	   winders
	   (lambda ()
	     (winder-thunk)
	     (then-thunk)))))))

  (define unwind
    (lambda (winders thunk)
      (wind winders winder-post-thunk thunk)))

  (define rewind
    (lambda (winders thunk)
      (wind winders winder-pre-thunk thunk)))

  (define winders=?
    (lambda (w1 w2)
      (fx=? (winders-height w1) (winders-height w2))))

  ;; Continuation marks

  (define-syntax/who with-continuation-mark
    (lambda (stx)
      (syntax-case stx ()
	[(_ key-expr val-expr result-expr)
	 #'(call-in-continuation-mark
	    key-expr
	    val-expr
	    (lambda ()
	      result-expr))]
	[_
	 (syntax-violation who "invalid syntax" stx)])))

  (define call-in-continuation-mark
    (lambda (key val thunk)
      (call-in-empty-continuation
       (lambda ()
	 (set-mark! key val)
	 (thunk)))))

  (define/who call-with-immediate-continuation-mark
    (case-lambda
     [(key proc)
      (call-with-immediate-continuation-mark key proc #f)]
     [(key proc default)
      (unless (procedure? proc)
	(assertion-violation
	 'who "not a procedure" proc))
      (call-in-empty-continuation
       (lambda ()
	 (proc (ref-mark key default))))]))

  (define/who continuation-marks
    (case-lambda
     [(k) (continuation-marks k (default-continuation-prompt-tag))]
     [(k prompt-tag)
      (unless (continuation-prompt-tag? prompt-tag)
	(assertion-violation
	 who "not a continuation prompt tag" prompt-tag))
      (let ([frames (take-mark-set-frames (continuation-metacontinuation who k) prompt-tag)])
	(unless (or frames (eq? (continuation-prompt-tag who k) prompt-tag))
	  (assertion-violation who "prompt tag not found in continuation" prompt-tag))
	(make-continuation-mark-set (or frames '())))]))

  (define/who current-continuation-marks
    (case-lambda
     [()
      (current-continuation-marks (default-continuation-prompt-tag))]
     [(prompt-tag)
      (unless (continuation-prompt-tag? prompt-tag)
	(assertion-violation
	 who "not a continuation prompt tag" prompt-tag))
      (let ([frames (or (take-mark-set-frames (current-metacontinuation) prompt-tag)
			'())])
	(make-continuation-mark-set
	 (if (empty-marks?)
	     frames
	     (cons (make-mark-set-frame #f (current-marks)) frames))))]))

  (define call-with-continuation-mark-set
    (lambda (who set tag proc)
      (unless (continuation-prompt-tag? tag)
	(assertion-violation
	 who "not a continuation prompt tag" tag))
      (let ([set (or set (current-continuation-marks tag))])
	(unless (continuation-mark-set? set)
	  (assertion-violation
	   who "not a continuation mark set" set))
	(proc set))))

  (define/who continuation-mark-set->list
    (case-lambda
     [(set key)
      (continuation-mark-set->list set key (default-continuation-prompt-tag))]
     [(set key tag)
      (call-with-continuation-mark-set
       who set tag
       (lambda (set)
	 (let f ([frames (continuation-mark-set-frames set)])
	   (if (null? frames)
	       '()
	       (let ([frame (car frames)] [frames (cdr frames)])
		 (if (eq? (mark-set-frame-tag frame) tag)
		     '()
		     (marks-ref
		      (mark-set-frame-marks frame)
		      key
		      (lambda ()
			(f frames))
		      (lambda (val)
			(cons val (f frames))))))))))]))

  (define/who continuation-mark-set->list*
    (case-lambda
     [(set keys)
      (continuation-mark-set->list* set keys #f)]
     [(set keys default)
      (continuation-mark-set->list* set keys default (default-continuation-prompt-tag))]
     [(set keys default tag)
      (unless (list? keys)
	(assertion-violation who "not a key list keys"))
      (let f ([iter (continuation-mark-set->iterator set keys default tag)])
	(let-values ([(vec iter) (iter)])
	  (if vec
	      (cons vec (f iter))
	      '())))]))

  (define/who continuation-mark-set->iterator
    (case-lambda
     [(set keys)
      (continuation-mark-set->iterator set keys #f)]
     [(set keys default)
      (continuation-mark-set->iterator set keys default (default-continuation-prompt-tag))]
     [(set keys default tag)
      (unless (list? keys)
	(assertion-violation who "not a key list" keys))
      (call-with-continuation-mark-set
       who set tag
       (lambda (set)
	 (let make-iterator ([frames (continuation-mark-set-frames set)])
	   (lambda ()
	     (let f ([frames frames])
	       (if (null? frames)
		   (values #f (make-iterator '()))
		   (let ([frame (car frames)] [frames (cdr frames)])
		     (if (eq? (mark-set-frame-tag frame) tag)
			 (values #f (make-iterator '()))
			 (let ([val-vec
				(marks-ref*
				 (mark-set-frame-marks frame)
				 keys
				 default)])
			   (if val-vec
			       (values val-vec (make-iterator frames))
			       (f frames)))))))))))]))

  (define/who continuation-mark-set-first
    (case-lambda
     [(set key)
      (continuation-mark-set-first set key #f)]
     [(set key default)
      (continuation-mark-set-first set key default (default-continuation-prompt-tag))]
     [(set key default tag)
      (call-with-continuation-mark-set
       who set tag
       (lambda (set)
	 (let f ([frames (continuation-mark-set-frames set)])
	   (if (null? frames)
	       default
	       (let ([frame (car frames)])
		 (if (eq? (mark-set-frame-tag frame) tag)
		     default
		     (marks-ref
		      (mark-set-frame-marks frame)
		      key
		      (lambda ()
			(f (cdr frames)))
		      values)))))))]))

  (define-syntax/who guard
    (lambda (stx)
      (syntax-case stx ()
	[(_ (id c1 c2 ...) e1 e2 ...)
	 (identifier? #'id)
	 #`(call-with-current-continuation
	    (lambda (guard-k)
	      (with-exception-handler
	       (lambda (c)
		 (call-with-current-continuation
		  (lambda (handler-k)
		    (call-in-continuation guard-k
		      (lambda ()
			(let ([id c])
			  #,(let f ([c1 #'c1] [c2* #'(c2 ...)])
			      (syntax-case c2* ()
				[()
				 (with-syntax
				     ([rest
				       #'(call-in-continuation handler-k
					   (lambda ()
					     (raise-continuable c)))])
				   (syntax-case c1 (else =>)
				     [(else e1 e2 ...)
				      #'(begin e1 e2 ...)]
				     [(e0) #'e0]
				     [(e0 => e1)
				      #'(let ([t e0]) (if t (e1 t) rest))]
				     [(e0 e1 e2 ...)
				      #'(if e0
					    (begin e1 e2 ...)
					    rest)]))]
				[(c2 c3 ...)
				 (with-syntax ([rest (f #'c2 #'(c3 ...))])
				   (syntax-case c1 (=>)
				     [(e0) #'(let ([t e0]) (if t t rest))]
				     [(e0 => e1)
				      #'(let ([t e0]) (if t (e1 t) rest))]
				     [(e0 e1 e2 ...)
				      #'(if e0
					    (begin e1 e2 ...)
					    rest)]))]))))))))
	       (lambda ()
		 (call-with-values
		     (lambda () e1 e2 ...)
		   guard-k)))))]
	[_
	 (syntax-violation who "invalid syntax" stx)]

	))
    )

  )

;; Local Variables:
;; mode: scheme
;; End: