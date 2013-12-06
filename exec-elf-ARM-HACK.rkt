#lang racket/base
;; ELF x86_64 executables (Linux)
;; Copyright (C) 2013 Tony Garnock-Jones <tonygarnockjones@gmail.com>
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

;; TODO: factor out commonality between main-arm.rkt and this.

(require racket/match)
(require racket/system)
(require racket/format)
(require racket/pretty)
(require (only-in racket/file file->list))
(require (only-in racket/list make-list append-map))

(require (planet tonyg/bitsyntax))

(require "driver.rkt")
(require "linker.rkt")
(require "dump-bytes.rkt")
(require "disasm.rkt")

(require "lir.rkt")
(require "machine.rkt")
(require "asm-arm7.rkt")
(require "mach-arm7.rkt")

;; It looks like (on my system, at least) program images are usually
;; loaded into core at 0x400000, so we do the same here.

(define md machine-arm7)
(define origin-addr #x0000000000400000)
(define start-offset #x80)
(define start-addr (+ origin-addr start-offset))

;; Based on the teachings of http://www.muppetlabs.com/~breadbox/software/tiny/teensy.html
;; and /usr/include/linux/elf.h
;; and http://www.uclibc.org/docs/elf-64-gen.pdf
(define (format-elf-image image memsize)
  (define header
    (bit-string ;; Elf64_Ehdr
                #x7f
		(#"ELF" :: binary)

		1  ;; EI_CLASS - 64 bit (1 = 32 bit, 2 = 64 bit)
		1  ;; EI_DATA - ELFDATA2LSB = 1
		1  ;; EI_VERSION - EV_CURRENT = 1
		0  ;; EI_OSABI - ELFOSABI_SYSV (aka ELFOSABI_NONE) = 0
		0  ;; EI_ABIVERSION - should contain 0
		0 0 0 0 0 0 0 ;; EI_PAD

		(2 :: little-endian bits 16) ;; e_type - ET_EXEC = 2
		(40 :: little-endian bits 16) ;; e_machine - EM_386 = 3, EM_X86_64 = 62

		(1 :: little-endian bits 32) ;; e_version - EV_CURRENT = 1

		(start-addr :: little-endian bits 32) ;; e_entry
		(52 :: little-endian bits 32) ;; e_phoff - offset relative to start of file
		(0 :: little-endian bits 32)  ;; e_shoff

		(#x82 :: little-endian bits 32) ;; e_flags

		(52 :: little-endian bits 16) ;; e_ehsize
		(32 :: little-endian bits 16) ;; e_phentsize
		(1 :: little-endian bits 16)  ;; e_phnum
		(40 :: little-endian bits 16) ;; e_shentsize
		(0 :: little-endian bits 16)  ;; e_shnum
		(0 :: little-endian bits 16)  ;; e_shstrndx

		;; 52 bytes in

		;; Elf32_Phdr
		(1 :: little-endian bits 32) ;; p_type - PT_LOAD = 1
		(0 :: little-endian bits 32) ;; p_offset
		(origin-addr :: little-endian bits 32) ;; p_vaddr
		(origin-addr :: little-endian bits 32) ;; p_paddr
		((+ start-offset (bytes-length image)) :: little-endian bits 32) ;; p_filesz
		((+ start-offset memsize) :: little-endian bits 32) ;; p_memsz
		(7 :: little-endian bits 32) ;; p_flags - PT_R=4 | PT_W=2 | PT_X=1 --> 7
		(12 :: little-endian bits 32)  ;; p_align
		))
  (define padding (make-bytes (- start-offset (bit-string-byte-count header)) 0))
  (bit-string (header :: binary)
	      (padding :: binary)
	      (image :: binary)))

(define (write-image filename bs)
  (with-output-to-file filename #:exists 'replace
    (lambda ()
      (write-bytes (bit-string->bytes (format-elf-image bs (bytes-length bs))))))
  (system* "/usr/bin/env" "chmod" "+x" filename))

(define (startup-code)
  (list (*bl 'al (label-reference 'main))
	(*bl 'al (label-reference '%%exit))
))

(define (make-syscall name body)
  (list (label-anchor name)
	body
	(*mov 'al 0 'pc 'lr)))

(define (syscalls)
  (list (make-syscall '%%write ;; RDI=fd, RSI=ptr, RDX=length
		      (list (*mov 'al 0 'r7 4) ;; __NR_write <asm/unistd_64.h>
			    (*swi 'al 0)))
	(make-syscall '%%exit ;; RDI=exit_status
		      (list (*mov 'al 0 'r7 1) ;; __NR_exit <asm/unistd_64.h>
			    (*swi 'al 0)))
	))

(define (compile-toplevel form global-env)
  (match form
    [`(define (,proc ,argname ...)
	,body ...)
     (write `(compiling ,proc ...)) (newline)
     (define-values (code data) (compile-procedure md argname `(begin ,@body) global-env))
     (values (cons (label-anchor proc) code) data)]
    [`(struct ,_ ...)	(values '() '())]
    [`(const ,_ ...)	(values '() '())]
    [_
     (error 'compile-toplevel "Cannot compile toplevel form: ~v" form)]))

(define (link-blobs blobs)
  (define all-blobs (list* (startup-code)
			   (syscalls)
			   blobs))
  (pretty-print `(all-blobs ,all-blobs))
  (define-values (linked0 relocs link-map) (link all-blobs start-addr))
  (when (not (null? relocs))
    (error 'link-and-emit "Unresolved relocations: ~v" relocs))
  (define linked (list->bytes linked0))
  (dump-bytes! linked #:base start-addr) (flush-output)
  (for-each (match-lambda [(cons anchor addr)
			   (write `(,(label-anchor-name anchor) -> ,(number->string addr 16)))
			   (newline)])
	    link-map)
  (disassemble-bytes! linked
  		      #:arch (machine-description-architecture md)
  		      #:base 0) ;; should be start-addr, not 0
  linked)

(define (pad-to bs multiple)
  (define l (machine-code-length bs))
  (define leftover (modulo l multiple))
  (if (zero? leftover)
      bs
      (cons bs (make-list (- multiple leftover) #x90)))) ;; NOP

(define (field-def-size def)
  (match def
    [`(,name word64) 8]
    [`(,name word64 ,n) (* 8 n)]
    [`(,name word32) 4]
    [`(,name word32 ,n) (* 4 n)]
    [`(,name byte) 1]
    [`(,name byte ,n) (* 1 n)]))

(define (symbol-append . syms)
  (string->symbol (apply string-append (map symbol->string syms))))

(define (extract-constants forms)
  (append-map (match-lambda
	       [`(struct ,name (,field-defs ...))
		(define struct-size (foldl + 0 (map field-def-size field-defs)))
		(do ((field-defs field-defs (cdr field-defs))
		     (offset 0 (+ offset (field-def-size (car field-defs))))
		     (acc (list (list (symbol-append 'sizeof- name) (lit struct-size)))
			  (cons (list (symbol-append name '- (car (car field-defs))) (lit offset))
				acc)))
		    ((null? field-defs) (reverse acc)))]
	       [`(const ,name ,(? number? literal-value))
		(list (list name (lit literal-value)))]
	       [_
		'()])
	      forms))

(define (compile-file filename)
  (define all-forms (file->list filename))
  (define global-env (extract-constants all-forms))
  (let loop ((forms all-forms)
	     (blobs-rev '()))
    (match forms
      ['()
       (define blobs (reverse blobs-rev))
       (link-blobs blobs)]
      [(cons form rest)
       (define-values (code data) (compile-toplevel form global-env))
       (loop rest
	     (list* (pad-to data 4)
		    (pad-to code 4)
		    blobs-rev))])))

(define (compile-and-link filename-base)
  (let ((bs (compile-file (string-append filename-base".nothing"))))
    (write-image filename-base bs)))

(require racket/cmdline)
(compile-and-link
 (command-line
  #:program "exec-elf.rkt"
  #:args (base-filename)
  base-filename))