; Dual-stack Winsock endpoint resolution, included by ping_win64.asm.
; ADDRINFOA (x64): flags 0, family 4, type 8, protocol 12, addrlen 16,
; canonname 24, sockaddr pointer 32, next 40. sockaddr_in = 16 bytes;
; sockaddr_in6 = 28 bytes (the final dword is the interface scope ID).

extern getaddrinfo
extern freeaddrinfo
extern getnameinfo

section .bss
    alignb 4
    g_family       resd 1
    g_family_force resd 1
    g_has_source   resb 1
    source_text    resb 256
    alignb 4
    source_addr    resb 28
    dest_addr      resb 28
    source_ipstr   resb 64

section .text

; rcx = sockaddr, rdx = output buffer, r8d = buffer capacity.
; Returns getnameinfo status (zero on success). Preserves nonvolatile registers.
format_address:
    test    r8d, r8d
    jz      .bad
    mov     byte [rdx], 0
    mov     r9d, r8d
    mov     r8, rdx
    mov     edx, 16
    cmp     word [rcx], AF_INET
    je      .call
    mov     edx, 28
    cmp     word [rcx], AF_INET6
    jne     .bad
.call:
    sub     rsp, 56
    mov     qword [rsp+32], 0          ; no service string
    mov     qword [rsp+40], 0
    mov     qword [rsp+48], 2          ; NI_NUMERICHOST
    call    getnameinfo
    add     rsp, 56
    ret
.bad:
    mov     eax, 1
    ret

; rsi = endpoint text. Validate an optional numeric IPv6 %scope suffix.
; Returns eax = 0/1 for valid/invalid; ecx = whether ':' occurred.
; Windows may also accept interface names, but this CLI deliberately requires
; an unambiguous decimal uint32 index and rejects empty or overflowing indices.
validate_endpoint_scope:
    xor     ecx, ecx
.scan:
    movzx   eax, byte [rsi]
    inc     rsi
    test    eax, eax
    jz      .ok
    cmp     al, ':'
    jne     .percent
    mov     ecx, 1
    jmp     .scan
.percent:
    cmp     al, '%'
    jne     .scan
    test    ecx, ecx
    jz      .bad
    cmp     byte [rsi], 0
    je      .bad
    xor     edx, edx
.digits:
    movzx   eax, byte [rsi]
    inc     rsi
    test    eax, eax
    jz      .ok
    sub     eax, '0'
    cmp     eax, 9
    ja      .bad
    cmp     edx, 429496729
    ja      .bad
    jb      .accumulate
    cmp     eax, 5
    ja      .bad
.accumulate:
    imul    edx, edx, 10
    add     edx, eax
    jmp     .digits
.ok:
    xor     eax, eax
    ret
.bad:
    mov     eax, 1
    ret

; Resolve the numeric source (if supplied), then the destination. Hostnames
; default to IPv4; an IPv6 literal/source or explicit -6 selects IPv6.
; Returns eax: 0 success, 1 bad target, 2 bad source, 3 family mismatch.
; Preserves all Win64 nonvolatile registers except the program's RSI/RDI
; formatting convention. No addrinfo-owned pointers survive the return.
resolve_endpoints:
    push    rbx
    sub     rsp, 400
    ; [64..111] hints, [112] allocated list, [120] return status,
    ; [128] target contains colon, [136] numeric-target lookup,
    ; [144..399] temporary reverse name.
    xor     eax, eax
    mov     [rsp+112], rax
    mov     [rsp+64], rax
    mov     [rsp+72], rax
    mov     [rsp+80], rax
    mov     [rsp+88], rax
    mov     [rsp+96], rax
    mov     [rsp+104], rax
    mov     [rel source_addr], rax
    mov     [rel source_addr+8], rax
    mov     [rel source_addr+16], rax
    mov     [rel source_addr+24], eax
    mov     [rel dest_addr], rax
    mov     [rel dest_addr+8], rax
    mov     [rel dest_addr+16], rax
    mov     [rel dest_addr+24], eax
    mov     [rel g_family], eax
    mov     byte [rel ipstr], 0
    mov     byte [rel source_ipstr], 0
    lea     rsi, [rel tgtbuf]
    lea     rdi, [rel namebuf]
    call    append_name
    lea     rax, [rel namebuf]
    mov     [rel g_name], rax

    cmp     byte [rel g_has_source], 0
    je      .target
    lea     rsi, [rel source_text]
    call    validate_endpoint_scope
    test    eax, eax
    jnz     .bad_source
    cmp     byte [rel source_text], 0
    je      .bad_source
    mov     dword [rsp+64], 4          ; AI_NUMERICHOST, AF_UNSPEC
    lea     rcx, [rel source_text]
    xor     edx, edx
    lea     r8, [rsp+64]
    lea     r9, [rsp+112]
    call    getaddrinfo
    test    eax, eax
    jnz     .bad_source
    mov     rbx, [rsp+112]
    test    rbx, rbx
    jz      .bad_source
    mov     eax, [rbx+4]
    mov     ecx, 16
    cmp     eax, AF_INET
    je      .source_copy
    mov     ecx, 28
    cmp     eax, AF_INET6
    jne     .bad_source
.source_copy:
    cmp     [rbx+16], rcx
    jb      .bad_source
    mov     rsi, [rbx+32]
    test    rsi, rsi
    jz      .bad_source
    mov     [rel g_family], eax
    lea     rdi, [rel source_addr]
    rep movsb
    mov     rcx, [rsp+112]
    call    freeaddrinfo
    mov     qword [rsp+112], 0
    mov     eax, [rel g_family_force]
    test    eax, eax
    jz      .source_format
    cmp     eax, [rel g_family]
    jne     .mismatch
.source_format:
    lea     rcx, [rel source_addr]
    lea     rdx, [rel source_ipstr]
    mov     r8d, 64
    call    format_address
    test    eax, eax
    jnz     .bad_source

.target:
    lea     rsi, [rel tgtbuf]
    call    validate_endpoint_scope
    test    eax, eax
    jnz     .bad_target
    mov     [rsp+128], ecx
    cmp     byte [rel tgtbuf], 0
    je      .bad_target
    ; Identify numeric targets before filtering by family so contradictions
    ; produce the family-mismatch diagnostic instead of a DNS failure.
    mov     dword [rsp+64], 6          ; AI_CANONNAME | AI_NUMERICHOST
    mov     dword [rsp+68], 0          ; AF_UNSPEC
    mov     dword [rsp+136], 1
.query_target:
    lea     rcx, [rel tgtbuf]
    xor     edx, edx
    lea     r8, [rsp+64]
    lea     r9, [rsp+112]
    call    getaddrinfo
    test    eax, eax
    jz      .target_result
    cmp     dword [rsp+136], 0
    je      .bad_target
    cmp     dword [rsp+128], 0
    jne     .bad_target                ; malformed IPv6 literal
    mov     rcx, [rsp+112]
    test    rcx, rcx
    jz      .hostname
    call    freeaddrinfo
    mov     qword [rsp+112], 0
.hostname:
    mov     eax, [rel g_family_force]
    test    eax, eax
    jnz     .family_chosen
    mov     eax, [rel g_family]
    test    eax, eax
    jnz     .family_chosen
    mov     eax, AF_INET
.family_chosen:
    mov     [rsp+68], eax
    mov     dword [rsp+64], 2          ; AI_CANONNAME; no AI_ADDRCONFIG
    mov     dword [rsp+136], 0
    jmp     .query_target

.target_result:
    mov     rbx, [rsp+112]
    test    rbx, rbx
    jz      .bad_target
    mov     eax, [rbx+4]
    mov     ecx, 16
    cmp     eax, AF_INET
    je      .target_family
    mov     ecx, 28
    cmp     eax, AF_INET6
    jne     .bad_target
.target_family:
    cmp     [rbx+16], rcx
    jb      .bad_target
    mov     edx, [rel g_family_force]
    test    edx, edx
    jz      .compare_source
    cmp     edx, eax
    jne     .mismatch
.compare_source:
    cmp     byte [rel g_has_source], 0
    je      .target_copy
    cmp     eax, [rel g_family]
    jne     .mismatch
.target_copy:
    mov     rsi, [rbx+32]
    test    rsi, rsi
    jz      .bad_target
    mov     [rel g_family], eax
    lea     rdi, [rel dest_addr]
    rep movsb
    cmp     byte [rel g_has_source], 0
    jne     .canonical
    mov     eax, [rel g_family]
    mov     [rel source_addr], ax      ; unspecified address of selected family
.canonical:
    mov     rsi, [rbx+24]
    test    rsi, rsi
    jz      .free_target
    cmp     byte [rsi], 0
    je      .free_target
    lea     rdi, [rel namebuf]
    call    append_name
.free_target:
    mov     rcx, [rsp+112]
    call    freeaddrinfo
    mov     qword [rsp+112], 0
    lea     rcx, [rel dest_addr]
    lea     rdx, [rel ipstr]
    mov     r8d, 64
    call    format_address
    test    eax, eax
    jnz     .bad_target
    cmp     byte [rel g_resolve], 0
    je      .success
    lea     rcx, [rel dest_addr]
    mov     edx, 16
    cmp     dword [rel g_family], AF_INET
    je      .reverse
    mov     edx, 28
.reverse:
    lea     r8, [rsp+144]
    mov     r9d, 256
    mov     qword [rsp+32], 0
    mov     qword [rsp+40], 0
    mov     qword [rsp+48], 4          ; NI_NAMEREQD, leave fallback on failure
    call    getnameinfo
    test    eax, eax
    jnz     .success
    cmp     byte [rsp+144], 0
    je      .success
    lea     rsi, [rsp+144]
    lea     rdi, [rel namebuf]
    call    append_name
.success:
    xor     eax, eax
    jmp     .finish
.bad_target:
    mov     eax, 1
    jmp     .finish
.bad_source:
    mov     eax, 2
    jmp     .finish
.mismatch:
    mov     eax, 3
.finish:
    mov     [rsp+120], eax
    mov     rcx, [rsp+112]
    test    rcx, rcx
    jz      .return
    call    freeaddrinfo
.return:
    mov     eax, [rsp+120]
    add     rsp, 400
    pop     rbx
    ret
