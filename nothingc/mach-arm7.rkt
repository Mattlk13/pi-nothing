#lang racket/base
;; Copyright (C) 2012-2015 Tony Garnock-Jones <tonyg@leastfixedpoint.com>
;;
;; This file is part of pi-nothing.
;;
;; pi-nothing is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published
;; by the Free Software Foundation, either version 3 of the License,
;; or (at your option) any later version.
;;
;; pi-nothing is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
;; General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with pi-nothing. If not, see <http://www.gnu.org/licenses/>.

;; Concrete machine: ARMv7.

(require racket/match)
(require (only-in racket/list append-map))
(require (only-in srfi/1 iota))
(require (only-in '#%foreign _int32))

(require "lir.rkt")
(require "linker.rkt")
(require "asm-arm7.rkt")
(require "tailcall.rkt")
(require (only-in "machine.rkt" machine-description))

(provide machine-arm7
         (rename-out [cc calling-convention-arm7]))

;; r0-r11
;; r12 - scratch reg, never made available to the register allocator so free for use
;; r13 - stack
;; r14 - lr
;; r15 - pc

(define cc (calling-convention '(r0 r1 r2 r3)
			       4
			       (lambda (delta)
				 (@reg 'sp
				       (if (negative? delta) '- '+)
				       (if (negative? delta) (- delta) delta)))
			       4
			       8
			       0
			       0))

(define killed-regs '(r0 r1 r2 r3 lr))

;; Reversed so that, via trapeze-act, when we store regs in temps, we
;; happen to place ascending register-numbers in adjacent cells in
;; memory, potentially enabling the use of LDM and STM instructions to
;; transfer the whole bunch at once. There are some sticky points: lr
;; seems not to play nicely with this (why?), and there's a certain
;; amount of sp-shuffling involved which isn't easy to get rid of
;; without some ARM-specific peephole optimizations (!).
;;
;; See `compress-ldm-stm` below.
;;
(define saved-regs (reverse '(r4 r5 r6 r7 r8 r9 r10 r11 lr)))

(define available-regs (map (lambda (r) (preg r #f))
                            (append (reverse saved-regs)
                                    (reverse (filter (lambda (r) (not (memq r saved-regs)))
                                                     killed-regs)))))

(define ((expand-instruction saved-locs) instr)
  (match instr
    [`(w*/extended ,hi ,lo ,s1 ,s2)
     (list `(move-word ,(preg 'r0 #f) ,s1)
           `(move-word ,(preg 'r1 #f) ,s2)
           `(w*/extended ,(preg 'r1 #f) ,(preg 'r0 #f) ,(preg 'r0 #f) ,(preg 'r1 #f))
           `(move-word ,hi ,(preg 'r1 #f))
           `(move-word ,lo ,(preg 'r0 #f)))]
    [`(wdiv ,target ,s1 ,s2)
     (list `(move-word ,(preg 'r0 #f) ,s1)
	   `(move-word ,(preg 'r1 #f) ,s2)
	   `(call ,(preg 'r0 #f) ,(label '__udivsi3) (,(preg 'r0 #f) ,(preg 'r1 #f)))
	   `(use ,(preg 'r2 #f))
	   `(use ,(preg 'r3 #f))
	   `(use ,(preg 'lr #f))
	   `(move-word ,target ,(preg 'r0 #f)))]
    [`(wmod ,target ,s1 ,s2)
     (list `(move-word ,(preg 'r0 #f) ,s1)
	   `(move-word ,(preg 'r1 #f) ,s2)
	   `(call ,(preg 'r0 #f) ,(label '__udivsi3) (,(preg 'r0 #f) ,(preg 'r1 #f)))
	   `(use ,(preg 'r2 #f))
	   `(use ,(preg 'r3 #f))
	   `(use ,(preg 'lr #f))
	   `(move-word ,target ,(preg 'r1 #f)))]
    [`(ret ,target)
     (append (list `(move-word ,(preg 'r0 (lir-value-var target)) ,target))
	     (map (lambda (loc name) `(move-word ,(preg name #f) ,loc)) saved-locs saved-regs)
	     (map (lambda (name) `(use ,(preg name #f))) saved-regs)
	     (list `(ret ,(preg 'r0 (lir-value-var target)))))]
    [`(call ,target ,label (,arg ...))
     (define argcount (length arg))
     (define (mkarg i) ((outward-argument-location cc) 'nontail argcount i))
     (append (do ((i 0 (+ i 1))
		  (arg arg (cdr arg))
		  (acc '() (cons `(move-word ,(mkarg i) ,(car arg))
				 acc)))
		 ((null? arg) (reverse acc)))
	     (list `(call ,(preg 'r0 #f) ,label ,(map mkarg (iota argcount))))
             (map (lambda (name) `(move-word ,(preg name #f) ,(junk))) killed-regs)
             (map (lambda (name) `(use ,(preg name #f))) killed-regs)
             (list `(move-word ,target ,(preg 'r0 #f))))]
    [`(tailcall ,label (,arg ...))
     (define argcount (length arg))
     (define (mkarg i) ((outward-argument-location cc) 'tail argcount i))
     (append (do ((i 0 (+ i 1))
		  (arg arg (cdr arg))
		  (acc '() (cons `(move-word ,(mkarg i) ,(car arg))
				 acc)))
		 ((null? arg) (reverse acc)))
             (map (lambda (loc name) `(move-word ,(preg name #f) ,loc)) saved-locs saved-regs)
             ;;(map (lambda (name) `(use ,(preg name #f))) saved-regs)
	     (list `(tailcall ,label ,(map mkarg (iota argcount)))))]
    [`(,(and op (or 'store-word 'store-byte)) ,target ,source)
     (define rt (if (non-reg? target) (fresh-reg) target))
     (define rs (if (non-reg? source) (fresh-reg) source))
     (list `(move-word ,rt ,target)
	   `(move-word ,rs ,source)
	   `(,op ,rt ,rs))]
    [`(wshift ,op ,(? reg-or-preg? target) ,(lit n) ,(lit m))
     (list `(move-word ,target ,(lit (arithmetic-shift n m))))]
    [`(wshift ,op ,(? reg-or-preg? target) ,(lit n) ,shift-amount)
     (list `(move-word ,target ,(lit n))
	   `(wshift ,op ,target ,target ,shift-amount))]
    [`(,(and op (or 'compare/set 'compare/jmp)) ,cmpop ,target ,(? lit? n) ,m)
     #:when (not (lit? m))
     (list `(,op ,(negate-cmpop cmpop) ,target ,m ,n))]
    [i
     (list i)]))

(define (expand-instructions init-arg-instrs instrs)
  (define saved-locs (map (lambda (r) (fresh-reg)) saved-regs))
  (define expander (expand-instruction saved-locs))
  (append (map (lambda (loc name) `(move-word ,loc ,(preg name #f))) saved-locs saved-regs)
	  (append-map expander init-arg-instrs)
	  (append-map expander instrs)))

(define (evaluate-cmpop cmpop n m)
  (bool->bit (evaluate-cmpop32 cmpop n m)))

(define (expand-temporary-loads-and-stores instrs)
  (define (shuffle-for-two-args make-instr target s1 s2)
    (cond
     [(and (equal? target s1) (not (and (memory-location? s1) (memory-location? s2))))
      (list (make-instr target s1 s2))]
     [(or (reg? s2) (lit? s2))
      (list `(move-word ,target ,s1)
	    (make-instr target target s2))]
     [else
      (define r2 (fresh-reg))
      (list `(move-word ,target ,s1)
	    `(move-word ,r2 ,s2)
	    (make-instr target target r2))]))
  (append-map (match-lambda
	       [(and i `(move-word ,(? memory-location? n) ,(? non-reg? m)))
		(if (equal? n m)
		    (list i) ;; it'll be eliminated later
		    (let ((r (fresh-reg)))
		      (list `(move-word ,r ,m)
			    `(move-word ,n ,r))))]
	       [`(,(and op (or 'w+ 'w- 'w* 'wand 'wor 'wxor 'wdiv 'wmod))
		  ,(? non-reg? target)
		  ,s1
		  ,s2)
		(define r (fresh-reg))
		(list `(,op ,r ,s1 ,s2)
		      `(move-word ,target ,r))]
	       [`(,(and op (or 'w+ 'w- 'w* 'wand 'wor 'wxor 'wdiv 'wmod))
		  ,target
		  ,(? non-reg? s1)
		  ,s2)
		;; TODO: separate out commutative operators here and
		;; try flipping the arguments to see if that is an option
		(define r (fresh-reg))
		(list `(move-word ,r ,s1)
		      `(,op ,target ,r ,s2))]
	       [`(,(and op (or 'w+ 'w- 'w* 'wand 'wor 'wxor 'wdiv 'wmod))
		  ,target
		  ,s1
		  ,(? lit? s2))
                #:when (not (best-rotation-exists? (lit-val s2)))
		(define r (fresh-reg))
		(list `(move-word ,r ,s2)
		      `(,op ,target ,s1 ,r))]
	       [`(,(and op (or 'w+ 'w- 'w* 'wand 'wor 'wxor 'wdiv 'wmod))
                  ,target
                  ,s1
                  ,(? non-reg? s2))
		(define r (fresh-reg))
		(list `(move-word ,r ,s2)
		      `(,op ,target ,s1 ,r))]
	       [`(wshift ,op ,(? non-reg? target) ,s1 ,s2)
		(define r (fresh-reg))
                (list `(wshift ,op ,r ,s1 ,s2)
                      `(move-word ,target ,r))]
	       [`(wshift ,op ,target ,(? non-reg? s1) ,s2)
		(define r (fresh-reg))
                (list `(move-word ,r ,s1)
                      `(wshift ,op ,target ,r ,s2))]
	       [`(compare/set ,cmpop ,target ,(? memory-location? n) ,(? memory-location? m))
		(define rn (fresh-reg))
		(define rm (fresh-reg))
		(list `(move-word ,rn ,n)
                      `(move-word ,rm ,m)
		      `(compare/set ,cmpop ,target ,rn ,rm))]
	       [`(compare/jmp ,cmpop ,target ,(? memory-location? n) ,(? memory-location? m))
		(define rn (fresh-reg))
		(define rm (fresh-reg))
		(list `(move-word ,rn ,n)
                      `(move-word ,rm ,m)
		      `(compare/jmp ,cmpop ,target ,rn ,rm))]
	       [`(compare/set ,cmpop ,target ,(? memory-location? n) ,m)
		(define r (fresh-reg))
		(list `(move-word ,r ,n)
		      `(compare/set ,cmpop ,target ,r ,m))]
	       [`(compare/jmp ,cmpop ,target ,(? memory-location? n) ,m)
		(define r (fresh-reg))
		(list `(move-word ,r ,n)
		      `(compare/jmp ,cmpop ,target ,r ,m))]
	       [`(compare/set ,cmpop ,target ,n ,(? memory-location? m))
		(define r (fresh-reg))
		(list `(move-word ,r ,m)
		      `(compare/set ,cmpop ,target ,n ,r))]
	       [`(compare/jmp ,cmpop ,target ,n ,(? memory-location? m))
		(define r (fresh-reg))
		(list `(move-word ,r ,m)
		      `(compare/jmp ,cmpop ,target ,n ,r))]
               [`(compare/set ,cmpop ,target ,n ,(? lit? m))
                #:when (not (best-rotation-exists? (lit-val m)))
		(define r (fresh-reg))
		(list `(move-word ,r ,m)
                      `(compare/set ,cmpop ,target ,n ,r))]
               [`(compare/jmp ,cmpop ,target ,n ,(? lit? m))
                #:when (not (best-rotation-exists? (lit-val m)))
		(define r (fresh-reg))
		(list `(move-word ,r ,m)
                      `(compare/jmp ,cmpop ,target ,n ,r))]
	       [`(,(and op (or 'load-word 'load-byte)) ,(temporary n var) ,source ,offset)
		(define r (fresh-reg))
		(list `(,op ,r ,source ,offset)
		      `(move-word ,(temporary n var) ,r))]
	       [`(,(and op (or 'load-word 'load-byte)) ,target ,(temporary n var) ,offset)
		(define r (fresh-reg))
                (list `(move-word ,r ,(temporary n var))
                      `(,op ,target ,r ,offset))]
               [`(,(and op (or 'store-word 'store-byte)) ,(temporary n var) ,source)
                (define r (fresh-reg))
                (list `(move-word ,r ,(temporary n var))
                      `(,op ,r ,source))]
	       [`(,(and op (or 'store-word 'store-byte)) ,target ,(temporary n var))
		(define r (fresh-reg))
		(list `(move-word ,r ,(temporary n var))
		      `(,op ,target ,r))]
               [`(call ,target ,(? memory-location? proc) ,args)
                (define r (fresh-reg))
                (list `(move-word ,r ,proc)
                      `(call ,target ,r ,args))]
	       [i
		(list i)])
	      instrs))

(define (nodata code)
  (values code '()))

(define (code/data code data)
  (values code data))

;; For loading immediate values too large to fit in a single instruction.
(define (indirect-immediate target-reg immediate more-code)
  (if (label-reference? immediate)
      (nodata (label-linker (label-reference-name immediate)
			    4
			    (lambda (delta i)
			      (define final-delta (- delta 8))
			      (if (negative? final-delta)
				  (*sub 'al 0 target-reg 'pc (- final-delta))
				  (*add 'al 0 target-reg 'pc final-delta)))))
      (let ((L (fresh-label)))
	(code/data (list (label-linker (label-tag L)
				       4
				       (lambda (delta i)
					 (*ldr 'al target-reg (@reg 'pc '+ (- delta 8)))))
			 more-code)
		   (list (label-anchor (label-tag L)) (imm32* immediate))))))

(define (comparison-code cmpop real-s1 real-s2 k)
  (define cc (case cmpop
	       ((<=s) 'le) ((<s) 'lt)
	       ((<=u) 'ls) ((<u) 'lo)
	       ((=) 'eq) ((<>) 'ne)
	       ((>s) 'gt) ((>=s) 'ge)
	       ((>u) 'hi) ((>=u) 'hs)))
  (nodata (cons (if (and (number? real-s2) (negative? real-s2))
		    (*cmn 'al real-s1 (- real-s2))
		    (*cmp 'al real-s1 real-s2))
		(k cc))))

(define ((assemble-instr xs sp-delta) i)
  (match i
    [`(move-word ,target ,source)
     (define real-target (xs target))
     (define real-source (xs source))
     (cond
      [(and (@reg? real-target) (@reg? real-source))
       ;; We know by the action of expand-temporary-loads-and-stores
       ;; that we'll not see both a temporary source and target, but
       ;; just to be sure...
       (error 'assemble-instr "Cannot *mov from memory to memory on ARM ~v" i)]
      [(@reg? real-target)
       ;; Note that the *source* of the move goes in the "target
       ;; register" position because of the syntactic weirdness of the
       ;; STR instruction.
       (nodata (*str 'al real-source real-target))]
      [(@reg? real-source)
       (nodata (*ldr 'al real-target real-source))]
      [(and (number? real-source) (best-rotation-exists? real-source))
       (nodata (*mov 'al 0 real-target real-source))]
      [(and (number? real-source) (best-rotation-exists? (bitwise-not real-source)))
       (nodata (*mvn 'al 0 real-target (bitwise-not real-source)))]
      [(or (label-reference? real-source) (number? real-source))
       ;; Compare to the "load-word" instruction code slightly below. This is like x86 LEA.
       (indirect-immediate real-target
			   real-source
			   '())]
      [else
       (nodata (*mov 'al 0 real-target real-source))])]
    [`(load-word ,(preg target _) ,(preg source _) ,ofs)
     (nodata (*ldr 'al target (@reg source '+ ofs)))]
    [`(load-word ,(preg target _) ,(lit n) ,ofs)
     (indirect-immediate target
			 (+ n ofs)
			 (*ldr 'al target (@reg target '+ 0)))]
    [`(load-byte ,(preg target _) ,(preg source _) ,ofs)
     (nodata (*ldrb 'al target (@reg source '+ ofs)))]
    [`(load-byte ,(preg target _) ,(lit n) ,ofs)
     (indirect-immediate target
			 (+ n ofs)
			 (*ldrb 'al target (@reg target '+ 0)))]
    [`(store-word ,(preg target _) ,(preg source _))
     (nodata (*str 'al source (@reg target '+ 0)))]
    [`(store-byte ,(preg target _) ,(preg source _))
     (nodata (*strb 'al source (@reg target '+ 0)))]
    [`(w+ ,target ,s1 ,s2)			(nodata (*add 'al 0 (xs target) (xs s1) (xs s2)))]
    [`(w- ,target ,s1 ,s2)			(nodata (*sub 'al 0 (xs target) (xs s1) (xs s2)))]
    [`(w* ,target ,s1 ,s2)			(nodata (*mul 'al 0 (xs target) (xs s1) (xs s2)))]
    [`(w*/extended ,t1 ,t2 ,s1 ,s2)
     (nodata (*imul/extended 'al 0 (xs t2) (xs t1) (xs s1) (xs s2)))]
    [`(wand ,target ,s1 ,s2)
     (if (and (lit? s2)
	      (not (best-rotation-exists? (lit-val s2)))
	      (best-rotation-exists? (bitwise-and #xffffffff (bitwise-not (lit-val s2)))))
	 (nodata (*bic 'al 0
		       (xs target)
		       (xs s1)
		       (bitwise-and #xffffffff (bitwise-not (lit-val s2)))))
	 (nodata (*and 'al 0 (xs target) (xs s1) (xs s2))))]
    [`(wor ,target ,s1 ,s2)			(nodata (*orr 'al 0 (xs target) (xs s1) (xs s2)))]
    [`(wxor ,target ,s1 ,s2)			(nodata (*eor 'al 0 (xs target) (xs s1) (xs s2)))]
    [`(wnot ,target ,source)			(nodata (*mvn 'al 0 (xs target) (xs source)))]
    [`(wshift ,op ,(preg target _) ,(preg s1 _) ,s2)
     (define shift-val (match s2 [(lit n) n] [(preg r _) r]))
     (nodata (*mov 'al 0 target (@shifted s1 (case op
					       [(<<) shift-val]
					       [(>>u) (@lsr shift-val)]
					       [(>>s) (@asr shift-val)]))))]
    [`(compare/set ,cmpop ,target ,(? lit? n) ,(? lit? m))
     (nodata (*mov 'al 0 (xs target) (evaluate-cmpop cmpop (lit-val n) (lit-val m))))]
    [`(compare/jmp ,cmpop ,(label tag) ,(? lit? n) ,(? lit? m))
     (if (not (zero? (evaluate-cmpop cmpop (lit-val n) (lit-val m))))
         (nodata (*b 'al (label-reference tag)))
         (nodata '()))]
    [`(compare/set ,cmpop ,target ,s1 ,s2)
     (comparison-code cmpop (xs s1) (xs s2)
		      (lambda (cc)
			(list (*mov 'al 0 (xs target) 0)
			      (*mov cc 0 (xs target) 1))))]
    [`(compare/jmp ,cmpop ,(label tag) ,s1 ,s2)
     (comparison-code cmpop (xs s1) (xs s2)
		      (lambda (cc)
			(list (*b cc (label-reference tag)))))]
    [(label tag)
     (nodata (label-anchor tag))]
    [`(jmp ,(label tag))			(nodata (*b 'al (label-reference tag)))]
    [`(ret ,(preg 'r0 _))
     (nodata (list (if (zero? sp-delta) '() (*add 'al 0 'sp 'sp sp-delta))
		   (*mov 'al 0 'pc 'lr)))]
    [`(call ,(preg 'r0 _) ,target ,args)
     (nodata (match target
	       [(preg r _) (*blx 'al r)]
	       [(label tag) (*bl 'al (label-reference tag))]))]
    [`(tailcall ,target ,args)
     (nodata (list (if (zero? sp-delta) '() (*add 'al 0 'sp 'sp sp-delta))
		   (match target
		     [(preg r _) (*mov 'al 0 'pc r)]
		     [(label tag) (*b 'al (label-reference tag))])))]
    [_ (error 'assemble-instr "Cannot assemble ~v" i)]))

(define ((assemble-instr* xs sp-delta) i)
  (define-values (icode idata) ((assemble-instr xs sp-delta) i))
  ;; (write `(,i -> ,icode ,idata))
  ;; (newline)
  ;; (flush-output)
  (values icode idata))

(define (compress-ldm-stm xs orig-instrs code-rev data-rev k-normal-instrs)
  (k-normal-instrs orig-instrs code-rev data-rev))

;; ;; DISABLED for now; seems to work ok, but it's hard to tell (with the
;; ;; simple test cases I have) whether it makes much of a difference.
;; ;;
;; (define (compress-ldm-stm xs orig-instrs code-rev data-rev k-normal-instrs)
;;   (let loop ((kind #f)
;;              (reglist '())
;;              (prev-reg-num #f)
;;              (offset #f)
;;              (instrs orig-instrs))
;;     (log-info "~v" `(loop ,kind ,reglist ,prev-reg-num ,offset ,(and (pair? instrs) (car instrs))))
;;     (match instrs
;;       [(cons `(move-word ,(temporary n _) ,(preg source-reg _)) rest)
;;        #:when (and (or (not kind) (eq? kind 'stm))
;;                    (or (not prev-reg-num) (< (reg-num source-reg) prev-reg-num))
;;                    (or (not offset) (= n (- offset 1))))
;;        (loop 'stm (cons source-reg reglist) (reg-num source-reg) n rest)]
;;       [(cons `(move-word ,(preg source-reg _) ,(temporary n _)) rest)
;;        #:when (and (or (not kind) (eq? kind 'ldm))
;;                    (or (not prev-reg-num) (< (reg-num source-reg) prev-reg-num))
;;                    (or (not offset) (= n (- offset 1))))
;;        (loop 'ldm (cons source-reg reglist) (reg-num source-reg) n rest)]
;;       [_
;;        (if (> (length reglist) 1)
;;            (match* (kind (xs (temporary offset #f)))
;;              [('stm (@reg 'sp op delta0))
;;               (define delta (match op ['+ delta0] ['- (- delta0)]))
;;               (define topdelta (+ delta (* (length reglist) 4)))
;;               (k-normal-instrs
;;                instrs
;;                (cons (list ((if (positive? topdelta) *add *sub) 'al 0 'sp 'sp (abs topdelta))
;;                            (*push 'al reglist)
;;                            ((if (positive? delta) *sub *add) 'al 0 'sp 'sp (abs delta)))
;;                      code-rev)
;;                data-rev)]
;;              [('ldm (@reg 'sp op delta0))
;;               (define delta (match op ['+ delta0] ['- (- delta0)]))
;;               (define topdelta (+ delta (* (length reglist) 4)))
;;               (k-normal-instrs
;;                instrs
;;                (cons (list ((if (positive? delta) *add *sub) 'al 0 'sp 'sp (abs delta))
;;                            (*pop 'al reglist)
;;                            ((if (positive? topdelta) *sub *add) 'al 0 'sp 'sp (abs topdelta)))
;;                      code-rev)
;;                data-rev)])
;;            (k-normal-instrs orig-instrs code-rev data-rev))])))

(define (assemble inward-arg-count most-tail-args temp-count leaf? instrs)
  (define xs (make-location-resolver cc inward-arg-count most-tail-args temp-count leaf?))
  (define sp-delta (if leaf? 0 (compute-sp-delta cc most-tail-args temp-count)))
  (let loop ((instrs instrs)
	     (code-rev '())
	     (data-rev '()))
    (compress-ldm-stm
     xs
     instrs
     code-rev
     data-rev
     (lambda (instrs code-rev data-rev)
       (match instrs
         ['() (values (list (if (zero? sp-delta) '() (*sub 'al 0 'sp 'sp sp-delta))
                            (reverse code-rev))
                      (reverse data-rev))]
         [(cons instr rest)
          (define-values (icode idata)
            ((assemble-instr* xs sp-delta) instr))
          (loop rest
                (cons icode code-rev)
                (cons idata data-rev))])))))

(define machine-arm7
  (machine-description 'arm7
		       (calling-convention-word-size cc)
		       _int32
		       available-regs
		       (inward-argument-location cc)
		       (outward-argument-location cc)
		       expand-instructions
		       expand-temporary-loads-and-stores
		       assemble))
