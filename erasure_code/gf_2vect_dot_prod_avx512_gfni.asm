;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;  Copyright(c) 2023 Intel Corporation All rights reserved.
;
;  Redistribution and use in source and binary forms, with or without
;  modification, are permitted provided that the following conditions
;  are met:
;    * Redistributions of source code must retain the above copyright
;      notice, this list of conditions and the following disclaimer.
;    * Redistributions in binary form must reproduce the above copyright
;      notice, this list of conditions and the following disclaimer in
;      the documentation and/or other materials provided with the
;      distribution.
;    * Neither the name of Intel Corporation nor the names of its
;      contributors may be used to endorse or promote products derived
;      from this software without specific prior written permission.
;
;  THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
;  "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
;  LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
;  A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
;  OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
;  SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
;  LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
;  DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
;  THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
;  (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
;  OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;;;
;;; gf_2vect_dot_prod_avx512_gfni(len, vec, *g_tbls, **buffs, **dests);
;;;

%include "reg_sizes.asm"
%include "gf_vect_gfni.inc"

%ifidn __OUTPUT_FORMAT__, elf64
 %define arg0  rdi
 %define arg1  rsi
 %define arg2  rdx
 %define arg3  rcx
 %define arg4  r8
 %define arg5  r9

 %define tmp   r11
 %define tmp2  r10
 %define tmp3  r12		; must be saved and restored

 %define func(x) x: endbranch
 %macro FUNC_SAVE 0
	push	r12
 %endmacro
 %macro FUNC_RESTORE 0
	pop	r12
 %endmacro
%endif

%ifidn __OUTPUT_FORMAT__, win64
 %define arg0   rcx
 %define arg1   rdx
 %define arg2   r8
 %define arg3   r9

 %define arg4   r12 		; must be saved, loaded and restored
 %define arg5   r14 		; must be saved and restored
 %define tmp    r11
 %define tmp2   r10
 %define tmp3   r13		; must be saved and restored
 %define stack_size  3*8		; must be an odd multiple of 8
 %define arg(x)      [rsp + stack_size + 8 + 8*x]

 %define func(x) proc_frame x
 %macro FUNC_SAVE 0
	alloc_stack	stack_size
	mov	[rsp + 0*8], r12
	mov	[rsp + 1*8], r13
	mov	[rsp + 2*8], r14
	end_prolog
	mov	arg4, arg(4)
 %endmacro

 %macro FUNC_RESTORE 0
	mov	r12,  [rsp + 0*8]
	mov	r13,  [rsp + 1*8]
	mov	r14,  [rsp + 2*8]
	add	rsp, stack_size
 %endmacro
%endif


%define len    arg0
%define vec    arg1
%define mul_array arg2
%define src    arg3
%define dest1  arg4
%define ptr    arg5
%define vec_i  tmp2
%define dest2  tmp3
%define pos    rax


%ifndef EC_ALIGNED_ADDR
;;; Use Un-aligned load/store
 %define XLDR vmovdqu8
 %define XSTR vmovdqu8
%else
;;; Use Non-temporal load/stor
 %ifdef NO_NT_LDST
  %define XLDR vmovdqa64
  %define XSTR vmovdqa64
 %else
  %define XLDR vmovntdqa
  %define XSTR vmovntdq
 %endif
%endif

%define xgft1  zmm3
%define xgft2  zmm4

%define x0        zmm0
%define xp1       zmm1
%define xp2       zmm2

default rel
[bits 64]

section .text

;;
;; Encodes 64 bytes of all "k" sources into 2x 64 bytes (parity disks)
;;
%macro ENCODE_64B_2 0-1
%define %%KMASK %1

	vpxorq	xp1, xp1, xp1
	vpxorq	xp2, xp2, xp2
	mov	tmp, mul_array
	xor	vec_i, vec_i

%%next_vect:
	mov	ptr, [src + vec_i]
%if %0 == 1
	vmovdqu8 x0{%%KMASK}, [ptr + pos]	;Get next source vector (less than 64 bytes)
%else
	XLDR	x0, [ptr + pos]		;Get next source vector (64 bytes)
%endif
	add	vec_i, 8

        vbroadcastf32x2 xgft1, [tmp]
        vbroadcastf32x2 xgft2, [tmp + vec]
	add	tmp, 8

        GF_MUL_XOR EVEX, x0, xgft1, xgft1, xp1, xgft2, xgft2, xp2

	cmp	vec_i, vec
	jl	%%next_vect

%if %0 == 1
	vmovdqu8 [dest1 + pos]{%%KMASK}, xp1
	vmovdqu8 [dest2 + pos]{%%KMASK}, xp2
%else
	XSTR	[dest1 + pos], xp1
	XSTR	[dest2 + pos], xp2
%endif
%endmacro

align 16
mk_global gf_2vect_dot_prod_avx512_gfni, function
func(gf_2vect_dot_prod_avx512_gfni)
	FUNC_SAVE

	xor	pos, pos
	shl	vec, 3		;vec *= 8. Make vec_i count by 8
	mov	dest2, [dest1 + 8]
	mov	dest1, [dest1]

	cmp	len, 64
        jl      .len_lt_64

.loop64:

        ENCODE_64B_2

	add	pos, 64		;Loop on 64 bytes at a time
        sub     len, 64
	cmp	len, 64
	jge	.loop64

.len_lt_64:
        cmp     len, 0
        jle     .exit

        xor     tmp, tmp
        bts     tmp, len
        dec     tmp
        kmovq   k1, tmp

        ENCODE_64B_2 k1

.exit:
        vzeroupper

	FUNC_RESTORE
	ret

endproc_frame
