#lang scribble/manual

@(require (for-label (except-in racket ...)))
@(require redex/pict
	  racket/runtime-path
	  scribble/examples
	  "hustle/semantics.rkt"
	  "utils.rkt"
	  "ev.rkt"
	  "../utils.rkt")

@(define codeblock-include (make-codeblock-include #'h))

@(for-each (λ (f) (ev `(require (file ,(path->string (build-path notes "jig" f))))))
	   '("interp.rkt" "compile.rkt" "asm/interp.rkt" "asm/printer.rkt"))

@title[#:tag "Jig"]{Jig: jumping to tail calls}

@table-of-contents[]

@section[#:tag-prefix "jig"]{Tail Calls}

With Iniquity, we've finally introduced some computational power via
the mechanism of functions and function calls.  Together with the
notion of inductive data, which we have in the form of pairs, we can
write fixed-sized programs that operate over arbitrarily large data.

The problem, however, is that there are a class of programs that
should operate with a fixed amount of memory, but instead consume
memory in proportion to the size of the data they operate on.  This is
unfortunate because a design flaw in our compiler now leads to
asympototically bad run-times.

We can correct this problem by generating space-efficient code for
function calls when those calls are in @bold{tail position}.

Let's call this language @bold{Jig}.

There are no syntactic additions required: we simply will properly
handling function calls.


@section[#:tag-prefix "jig"]{What is a Tail Call?}

A @bold{tail call} is a function call that occurs in @bold{tail
position}.  What is tail position and why is important to consider
function calls made in this position?

Tail position captures the notion of ``the last subexpression that
needs to be computed.''  If the whole program is some expression
@racket[_e], the @racket[_e] is in tail position.  Computing
@racket[_e] is the last thing (it's the only thing!) the program needs
to compute.

Let's look at some examples to get a sense of the subexpressions in
tail position.  If @racket[_e] is in tail position and @racket[_e] is
of the form:

@itemlist[

@item{@racket[(let ((_x _e0)) _e1)]: then @racket[_e1] is in tail
position, while @racket[_e0] is not.  The reason @racket[_e0] is not
in tail position is because after evaluating it, the @racket[_e1]
still needs to be evaluated.  On the other hand, once @racket[_e0] is
evaluated, then whatever @racket[_e1] evaluates to is what the whole
@racket[let]-expression evaluates to; it is all that remains to
compute.}

@item{@racket[(if _e0 _e1 _e2)]: then @emph{both} @racket[_e1] and
@racket[_e2] are in tail position, while @racket[_e0] is not.  After
the @racket[_e0], then based on its result, either @racket[_e1] or
@racket[_e2] is evaluated, but whichever it is determines the result
of the @racket[if] expression.}

@item{@racket[(+ _e0 _e1)]: then neither @racket[_e0] or @racket[_e1]
are in tail position because after both are evaluated, their results
still must be added together.}

@item{@racket[(f _e0 ...)], where @racket[f] is a function
@racket[(define (f _x ...) _e)]: then none of the arguments
@racket[_e0 ...] are in tail position, because after evaluating them,
the function still needs to be applied, but the body of the function,
@racket[_e] is in tail position.}

]

The significance of tail position is relevant to the compilation of
calls.  Consider the compilation of a call as described in
@secref{Iniquity}: arguments are pushed on the call stack, then the
@racket['call] instruction is issued, which pushes the address of the
return point on the stack and jumps to the called position.  When the
function returns, the return point is popped off the stack and jumped
back to.

But if the call is in tail position, what else is there to do?
Nothing.  So after the call, return transfers back to the caller, who
then just returns itself.

This leads to unconditional stack space consumption on @emph{every}
function call, even function calls that don't need to consume space.

Consider this program:

@#reader scribble/comment-reader
(racketblock
;; (Listof Number) -> Number
(define (sum xs) (sum/acc xs 0))

;; (Listof Number) Number -> Number
(define (sum/acc xs a)
  (if (empty? xs)
      a
      (sum/acc (cdr xs) (+ (car xs) a))))
)

The @racket[sum/acc] function @emph{should} operate as efficiently as
a loop that iterates over the elements of a list accumulating their
sum.  But, as currently compiled, the function will push stack frames
for each call.

Matters become worse if we were re-write this program in a seemingly
benign way to locally bind a variable:

@#reader scribble/comment-reader
(racketblock
;; (Listof Number) Number -> Number
(define (sum/acc xs a)
  (if (empty? xs)
      a
      (let ((b (+ (car xs) a)))
        (sum/acc (cdr xs) b))))
)

Now the function pushes a return point @emph{and} a local binding for
@racket[b] on every recursive call.

But we know that whatever the recursive call produces is the answer to
the overall call to @racket[sum].  There's no need for a new return
point and there's no need to keep the local binding of @racket[b]
since there's no way this program can depend on it after the recursive
call.  Instead of pushing a new, useless, return point, we should make
the call with whatever the current return point.  This is the idea of
@tt{proper tail calls}.

@bold{An axe to grind:} the notion of proper tail calls is often
referred to with misleading terminology such as @bold{tail call
optimization} or @bold{tail recursion}.  Optimization seems to imply
it is a nice, but optional strategy for implementing function calls.
Consequently, a large number of mainstream programming languages, most
notably Java, do not properly implement tail calls.  But a language
without proper tail calls is fundamentally @emph{broken}.  It means
that functions cannot reliably be designed to match the structure of
the data they operate on.  It means iteration cannot be expressed with
function calls.  There's really no justification for it.  It's just
broken.  Similarly, it's not about recursion alone (although it is
critical @emph{for} recursion), it really is about getting function
calls, all calls, right. @bold{/rant}



@section[#:tag-prefix "jig"]{An Interpreter for Proper Calls}

Before addressing the issue of compiling proper tail calls, let's
first think about the interpreter, starting from the interpreter we
wrote for Iniquity:

@codeblock-include["iniquity/interp.rkt"]

What needs to be done to make it implement proper tail calls?

Well... not much.  Notice how every Iniquity subexpression that is in
tail position is interpreted by a call to @racket[interp-env] that is
itself in tail position in the Racket program!

So long as Racket implements tail calls properly, which is does, then
this interpreter implements tail calls properly.  The interpreter
@emph{inherits} the property of proper tail calls from the
meta-language.  This is but one reason to do tail calls correctly.
Had we transliterated this program to Java, we'd be in trouble as the
interpeter would inherit the lack of tail calls and we would have to
re-write the interpreter, but as it is, we're already done.

@section[#:tag-prefix "jig"]{A Compiler with Proper Tail Calls}

@codeblock-include["jig/compile.rkt"]
