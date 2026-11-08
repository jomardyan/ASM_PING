; Test-only Win32 boundary fixtures, appended to an instrumented source copy.
; Production binaries never link these routines.
section .data
test_env db 'PING_TEST_MODE', 0
test_long_name times 300 db 'x'
    db 0
test_host dq test_long_name, 0
    dw AF_INET, 4
    dd 0
    dq test_addrs
test_addrs dq test_addr, 0
test_addr db 127, 0, 0, 1
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

test_gethostbyname:
    lea rax, [rel test_host]
    ret
test_gethostbyaddr:
    ; Deliberately reuses hostent storage and changes it for reverse lookups.
    mov byte [rel test_long_name], 'y'
    mov byte [rel test_long_name+20], 27
    lea rax, [rel test_host]
    ret

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
