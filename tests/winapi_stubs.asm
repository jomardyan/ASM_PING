; Test-only Win32 boundary fixtures, appended to an instrumented source copy.
; Production binaries never link these routines.
section .data
test_env db 'PING_TEST_MODE', 0
test_scoped_name db 'scoped-test', 0
test_long_name times 300 db 'x'
    db 0
align 8
test_ai4 dd 2, 2, 0, 0
    dq 16, test_long_name, test_sock4, 0
test_ai6 dd 2, 23, 0, 0
    dq 28, test_long_name, test_sock6, 0
test_sock4 dw 2, 0
    db 127, 0, 0, 1
    dq 0
test_sock6 dw 23, 0
    dd 0
    times 15 db 0
    db 1
    dd 0
section .bss
test_mode resd 1
test_envbuf resb 16
section .text

test_GetConsoleMode:
    sub rsp, 38h
    mov [rsp+20h], rcx
    mov [rsp+28h], rdx
    lea rcx, [rel test_env]
    lea rdx, [rel test_envbuf]
    mov r8d, 16
    call GetEnvironmentVariableA
    lea rcx, [rel test_envbuf]
    call parse_u32
    mov [rel test_mode], eax
    mov rcx, [rsp+20h]
    mov rdx, [rsp+28h]
    add rsp, 38h
    cmp dword [rel test_mode], 16
    je .console
    cmp dword [rel test_mode], 17
    je .console
    jmp GetConsoleMode
.console:
    mov dword [rdx], 3
    mov eax, 1
    ret

test_SetConsoleMode:
    cmp dword [rel test_mode], 16
    je .no_vt
    cmp dword [rel test_mode], 17
    je .vt
    jmp SetConsoleMode
.no_vt:
    xor eax, eax
    ret
.vt:
    ; Original mode was 3, so both the enable (7) and restore (3) are valid.
    cmp edx, 3
    je .ok
    cmp edx, 7
    je .ok
    mov byte [rel g_output_error], 1
.ok:
    mov eax, 1
    ret

test_GetConsoleOutputCP:
    cmp dword [rel test_mode], 16
    jne .utf8
    mov eax, 1252
    ret
.utf8:
    mov eax, CP_UTF8
    ret

test_GetSystemTime:
    cmp dword [rel test_mode], 20
    je .early
    cmp dword [rel test_mode], 21
    je .late
    jmp GetSystemTime
.early:
    mov word [rcx], 2026
    mov word [rcx+2], 1
    mov word [rcx+4], 5
    mov word [rcx+6], 2
    mov word [rcx+8], 3
    mov word [rcx+10], 4
    mov word [rcx+12], 5
    mov word [rcx+14], 6
    ret
.late:
    mov word [rcx], 2026
    mov word [rcx+2], 12
    mov word [rcx+4], 4
    mov word [rcx+6], 31
    mov word [rcx+8], 23
    mov word [rcx+10], 59
    mov word [rcx+12], 59
    mov word [rcx+14], 999
    ret

test_IcmpCreateFile:
    cmp dword [rel test_mode], 19
    je .fail
    jmp IcmpCreateFile
.fail:
    mov rax, -1
    ret

test_Icmp6CreateFile:
    cmp dword [rel test_mode], 19
    je test_IcmpCreateFile.fail
    jmp Icmp6CreateFile

test_getaddrinfo:
    cmp dword [rel test_mode], 10
    jne .normal
    test dword [r8], 4           ; numeric parsing must still fail for a hostname
    jnz .normal
    lea rax, [rel test_ai4]
    cmp dword [r8+4], 23
    jne .resolved
    lea rax, [rel test_ai6]
.resolved:
    mov [r9], rax
    xor eax, eax
    ret
.normal:
    jmp getaddrinfo

test_freeaddrinfo:
    lea rax, [rel test_ai4]
    cmp rcx, rax
    je .done
    lea rax, [rel test_ai6]
    cmp rcx, rax
    je .done
    jmp freeaddrinfo
.done:
    ret

test_getnameinfo:
    test dword [rsp+38h], 2      ; numeric formatting uses the real Winsock API
    jnz .normal
    cmp dword [rel test_mode], 27
    je .missing
    cmp dword [rel test_mode], 29
    je .scoped
    cmp dword [rel test_mode], 10
    jne .normal
    ; Return a full-sized reverse name including a control character. The
    ; resolver must sanitize it and preserve its own bounded copy.
    xor eax, eax
    dec r9d
.copy:
    cmp eax, r9d
    jae .terminate
    mov byte [r8+rax], 'x'
    inc eax
    jmp .copy
.terminate:
    mov byte [r8+rax], 0
    mov byte [r8], 'y'
    mov byte [r8+20], 27
    xor eax, eax
    ret
.missing:
    mov eax, 11001
    ret
.scoped:
    xor eax, eax
    lea r10, [rel test_scoped_name]
.copy_scoped:
    mov dl, [r10+rax]
    mov [r8+rax], dl
    inc eax
    test dl, dl
    jnz .copy_scoped
    xor eax, eax
    ret
.normal:
    jmp getnameinfo

test_CreateThread:
    cmp dword [rel test_mode], 28
    jne .normal
    xor eax, eax
    ret
.normal:
    jmp CreateThread

test_SetConsoleCtrlHandler:
    cmp dword [rel test_mode], 11
    jne .normal
    mov byte [rel g_stop], 1
    mov eax, 1
    ret
.normal:
    jmp SetConsoleCtrlHandler

test_IcmpCloseHandle:
    ; A real pending request can make this call block until its timeout.
    cmp dword [rel test_mode], 12
    jne .close
    mov byte [rel g_output_error], 1
.close:
    jmp IcmpCloseHandle

test_GetLastError:
    mov eax, 11010
    cmp dword [rel test_mode], 2
    je .done
    mov eax, 11050
    cmp dword [rel test_mode], 3
    je .done
    mov eax, 54321
    cmp dword [rel test_mode], 4
    je .done
    mov eax, 997
    cmp dword [rel test_mode], 12
    je .done
    jmp GetLastError
.done:
    ret

test_IcmpSendEcho2:
    ; Check alignment and the actual x64 API argument layout.
    mov rax, rsp
    and eax, 15
    cmp eax, 8
    jne .abi_fail
    cmp qword [rsp+50h], REPLY_CAP
    jne .abi_fail
    mov r10, [rsp+48h]
    lea rax, [rel replybuf]
    cmp r10, rax
    jne .abi_fail
    mov eax, [rsp+28h]
    mov [r10], eax
    mov dword [r10+4], 0
    mov dword [r10+8], 23
    mov eax, [rsp+38h]
    mov [r10+12], ax
    mov byte [r10+24], 64
    mov eax, [rel test_mode]
    cmp eax, 1
    je .ttl
    cmp eax, 2
    je .fail
    cmp eax, 3
    je .fail
    cmp eax, 4
    je .fail
    cmp eax, 12
    je .fail
    cmp eax, 18
    je .nine_hops
    cmp eax, 5
    jb .success
    cmp eax, 9
    ja .success
    lea r11, [r10+40]
    mov [r10+32], r11
    mov byte [r10+27], 14
    ; NOP, unknown two-byte TLV, then record route with two recorded hops.
    mov byte [r11], 1
    mov word [r11+1], 021Eh
    mov byte [r11+3], 7
    mov byte [r11+4], 11
    mov byte [r11+5], 12
    mov dword [r11+6], 010200C0h   ; 192.0.2.1
    mov dword [r11+10], 026433C6h  ; 198.51.100.2
    cmp eax, 6
    jne .pointer
    mov byte [r11+4], 2           ; invalid RR header length
.pointer:
    cmp eax, 7
    jne .outside
    mov byte [r11+5], 255         ; next-write pointer outside option
.outside:
    cmp eax, 8
    jne .size
    mov qword [r10+32], -16       ; invalid returned pointer
.size:
    cmp eax, 9
    jne .success
    mov byte [r10+27], 255        ; too many option bytes
.success:
    mov eax, 1
    ret
.nine_hops:
    lea r11, [r10+40]
    mov [r10+32], r11
    mov byte [r10+27], 39
    mov byte [r11], 7
    mov byte [r11+1], 39
    mov byte [r11+2], 40
    xor ecx, ecx
.hop:
    lea edx, [rcx+1]
    shl edx, 24
    or edx, 006433C6h
    mov [r11+rcx*4+3], edx
    inc ecx
    cmp ecx, 9
    jb .hop
    jmp .success
.ttl:
    mov dword [r10], 010200C0h
    mov dword [r10+4], 11013
    jmp .success
.fail:
    xor eax, eax
    ret
.abi_fail:
    mov byte [rel g_output_error], 1
    mov byte [rel g_stop], 1
    jmp .fail

test_IcmpSendEcho2Ex:
    ; An explicit IPv4 source must reach the source-address API argument.
    mov eax, [rel source_addr+4]
    cmp [rsp+28h], eax
    jne test_IcmpSendEcho2.abi_fail
    ; Reuse the IPv4 reply fixture after adapting the extra source argument.
    mov rax, [rsp+30h]
    mov [rsp+28h], rax
    mov rax, [rsp+38h]
    mov [rsp+30h], rax
    mov rax, [rsp+40h]
    mov [rsp+38h], rax
    mov rax, [rsp+48h]
    mov [rsp+40h], rax
    mov rax, [rsp+50h]
    mov [rsp+48h], rax
    mov rax, [rsp+58h]
    mov [rsp+50h], rax
    mov rax, [rsp+60h]
    mov [rsp+58h], rax
    jmp test_IcmpSendEcho2

test_Icmp6SendEcho2:
    ; The IPv6 worker makes a synchronous call so -w remains effective.
    mov rax, rsp
    and eax, 15
    cmp eax, 8
    jne test_IcmpSendEcho2.abi_fail
    test rdx, rdx
    jnz test_IcmpSendEcho2.abi_fail
    test r8, r8
    jnz test_IcmpSendEcho2.abi_fail
    test r9, r9
    jnz test_IcmpSendEcho2.abi_fail
    cmp qword [rsp+58h], REPLY_CAP
    jne test_IcmpSendEcho2.abi_fail
    mov r10, [rsp+28h]
    lea rax, [rel source_addr]
    cmp r10, rax
    jne test_IcmpSendEcho2.abi_fail
    cmp word [r10], 23
    jne test_IcmpSendEcho2.abi_fail
    mov r11, [rsp+30h]
    lea rax, [rel dest_addr]
    cmp r11, rax
    jne test_IcmpSendEcho2.abi_fail
    cmp word [r11], 23
    jne test_IcmpSendEcho2.abi_fail
    mov eax, [rsp+60h]
    cmp eax, [rel g_timeout]
    jne test_IcmpSendEcho2.abi_fail
    mov eax, [rel test_mode]
    cmp eax, 12
    je .pending
    cmp eax, 2
    je .fail
    cmp eax, 3
    je .fail
    cmp eax, 4
    je .fail
    mov r10, [rsp+50h]
    mov rax, [r11+8]
    mov [r10+6], rax
    mov rax, [r11+16]
    mov [r10+14], rax
    mov eax, [r11+24]
    bswap eax
    mov [r10+22], eax
    mov dword [r10+28], 0
    mov dword [r10+32], 23
    mov eax, [rel test_mode]
    cmp eax, 22
    je .ttl
    cmp eax, 23
    je .unreachable
    cmp eax, 24
    je .too_big
    cmp eax, 25
    je .scope
.success:
    mov eax, 1
    ret
.ttl:
    ; 2001:db8::1 in the returned IPV6_ADDRESS_EX.
    mov dword [r10+6], 0B80D0120h
    mov dword [r10+10], 0
    mov rax, 0100000000000000h
    mov [r10+14], rax
    mov dword [r10+28], 11041
    jmp .success
.unreachable:
    mov dword [r10+28], 11040
    jmp .success
.too_big:
    mov dword [r10+28], 11009
    jmp .success
.scope:
    mov dword [r10+28], 11045
    jmp .success
.fail:
    xor eax, eax
    ret
.pending:
    sub rsp, 28h
    xor ecx, ecx
    mov edx, 1
    xor r8d, r8d
    xor r9d, r9d
    call CreateEventW
    mov rcx, rax
    mov edx, -1
    call WaitForSingleObject
    add rsp, 28h
    xor eax, eax
    ret

test_WriteFile:
    cmp dword [rel test_mode], 13
    je .zero
    cmp dword [rel test_mode], 14
    je .fail
    cmp dword [rel test_mode], 15
    jne .write
    cmp r8d, 2
    jbe .write
    mov r8d, 2                   ; force partial writes, including UTF-8 bytes
.write:
    jmp WriteFile
.zero:
    mov dword [r9], 0
    mov eax, 1
    ret
.fail:
    xor eax, eax
    ret
