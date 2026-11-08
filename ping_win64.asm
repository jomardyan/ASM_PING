; ping_win64.asm - IPv4 ICMP ping for Windows x64 (no CRT)
; Modern table UI on real consoles (VT colors + box drawing, CP437 or UTF-8);
; classic plain-text output when stdout is redirected. Force pretty with env
; PING_PRETTY=1.
; Build: powershell -File build.ps1
; Run:
;   ping.exe [-t] [-a] [-n count] [-l size] [-f] [-i ttl] [-v tos]
;            [-r count] [-w timeout] [-4] [--flood] target
;            [--interval ms] [--quiet] [--timestamp]
;     -j/-k/-s/-S/-R/-6 are not implemented and are rejected.

default rel

global main

extern GetStdHandle             ; kernel32
extern WriteFile
extern ExitProcess
extern GetCommandLineW
extern CommandLineToArgvW       ; shell32
extern WideCharToMultiByte
extern LocalFree
extern GetLastError
extern CreateEventW
extern SetEvent
extern ResetEvent
extern WaitForSingleObject
extern WaitForMultipleObjects
extern CloseHandle
extern GetTickCount64
extern GetSystemTime
extern SetConsoleCtrlHandler
extern GetConsoleMode
extern SetConsoleMode
extern GetConsoleOutputCP
extern GetEnvironmentVariableA
extern IcmpCreateFile           ; iphlpapi
extern IcmpSendEcho2
extern IcmpParseReplies
extern IcmpCloseHandle
extern WSAStartup               ; ws2_32
extern WSACleanup
extern gethostbyname
extern gethostbyaddr

MAX_PAYLOAD  equ 65500
REPLY_CAP    equ 65624          ; native x64 reply (40) + payload + 40 IP options + 8 error bytes
TOKEN_CAP    equ 32768
IP_FLAG_DF   equ 2
AF_INET      equ 2
VT_ENABLE    equ 4              ; ENABLE_VIRTUAL_TERMINAL_PROCESSING
CP_UTF8      equ 65001
TBL_W        equ 80             ; sum(colw_main) + 6 borders

; box charset indices
B_H  equ 0
B_V  equ 1
B_TL equ 2
B_TM equ 3
B_TR equ 4
B_ML equ 5
B_MM equ 6
B_MR equ 7
B_BL equ 8
B_BM equ 9
B_BR equ 10
; color indices
C_RESET  equ 0
C_GREEN  equ 1
C_RED    equ 2
C_CYAN   equ 3
C_YELLOW equ 4
C_BOLD   equ 5

section .data
    ; ---- classic plain output strings ----
    s_pinging  db "Pinging ", 0
    s_lb       db " [", 0
    s_rb_with  db "] with ", 0
    s_bytesdat db " bytes of data:", 13, 10, 13, 10, 0
    s_reply    db "Reply from ", 0
    s_rb_col   db "]: bytes=", 0
    s_colon_b  db ": bytes=", 0
    s_colon_sp db ": ", 0
    s_time     db " time", 0
    s_eq       db "=", 0
    s_lt1      db "<1ms", 0
    s_ms       db "ms", 0
    s_ttl      db " TTL=", 0
    s_route    db " route:", 0
    s_spc      db " ", 0
    s_nl       db 13, 10, 0
    s_colon_nl db ":", 13, 10, 0
    s_stat1    db "Ping statistics for ", 0
    s_pkts     db 13, 10, "    Packets: Sent = ", 0
    s_recv     db ", Received = ", 0
    s_lost     db ", Lost = ", 0
    s_pct      db " (", 0
    s_pct2     db "% loss),", 13, 10, 0
    s_rtt_hdr  db "Approximate round trip times in milli-seconds:", 13, 10, 0
    s_min      db "    Minimum = ", 0
    s_ms_comma db "ms, Maximum = ", 0
    s_avg      db "ms, Average = ", 0
    s_ms_nl    db "ms", 13, 10, 0
    s_badhost1 db "Ping request could not find host ", 0
    s_badhost2 db ". Please check the name and try again.", 13, 10, 0
    s_noicmp   db "error: IcmpCreateFile failed", 13, 10, 0
    s_wsa      db "error: WSAStartup failed", 13, 10, 0
    s_unsup    db "error: option not supported by this IPv4 build", 13, 10, 0
    s_badtgt   db "error: target must be an ASCII hostname or IPv4 address (max 255 bytes)", 13, 10, 0
    s_argerr   db "error: could not read command-line arguments", 13, 10, 0
    s_eventerr db "error: could not initialize interrupt handling", 13, 10, 0
    s_badopt   db "error: unknown option ", 0
    s_badval   db "error: invalid or missing option value", 13, 10, 0
    s_duptgt   db "error: only one target allowed", 13, 10, 0
    s_dot      db ".", 0
    s_usage    db "usage: ping [-t] [-a] [-n count] [-l size] [-f] [-i ttl] [-v tos]", 13, 10
               db "            [-r count] [-w timeout] [-4] [--flood]", 13, 10
               db "            [--interval ms] [--quiet] [--timestamp] target", 13, 10, 13, 10
               db "  -t      ping the specified host until stopped (Ctrl+C)", 13, 10
               db "  -a      resolve addresses to hostnames", 13, 10
               db "  -n      number of echo requests (1-100000, default 4)", 13, 10
               db "  -l      send buffer size in bytes (default 32, max 65500)", 13, 10
               db "  -f      set Don't Fragment flag on packets", 13, 10
               db "  -i      Time To Live (1-255)", 13, 10
               db "  -v      Type Of Service (0-255; may be ignored by Windows)", 13, 10
               db "  -r      record route for <count> hops (1-9)", 13, 10
               db "  -w      reply timeout in milliseconds (1-600000, default 4000)", 13, 10
               db "  -4      force IPv4 (the only mode in this build)", 13, 10
               db "  --flood send the next request immediately after each reply or timeout", 13, 10
               db "  --interval ms  request interval (1-600000 ms, default 1000; flood overrides)", 13, 10
               db "  --quiet        show the header and final statistics only", 13, 10
               db "  --timestamp    prefix results with UTC timestamps; use plain text output", 13, 10
               db "  -h, -?  show this help", 13, 10
               db "  Exit codes: 0 = success/help, 1 = no replies/target, 2 = usage/setup/output error.", 13, 10, 0
    ; ---- pretty UI strings ----
    s_pingcaps db "PING ", 0
    s_rb       db "]", 0
    s_payl     db "payload ", 0
    s_bytes2   db " bytes | timeout ", 0
    s_ms2      db " ms", 0
    s_floodopt db "--flood", 0
    s_intervalopt db "--interval", 0
    s_quietopt db "--quiet", 0
    s_timestampopt db "--timestamp", 0
    s_floodtag db " | flood", 0
    s_floodmsg db "Flood mode: no interval between requests.", 13, 10, 13, 10, 0
    s_intervaltag db " | interval ", 0
    s_intervalmsg db "Request interval: ", 0
    timestamp_text db "[0000-00-00T00:00:00.000Z] ", 0
    s_c_seq    db "#", 0
    s_c_from   db "From", 0
    s_c_bytes  db "Size", 0
    s_c_time   db "Time", 0
    s_c_ttl    db "TTL", 0
    s_c_metric db "Metric", 0
    s_c_value  db "Value", 0
    s_m_sent   db "Sent", 0
    s_m_recv   db "Received", 0
    s_m_lost   db "Lost", 0
    s_m_loss   db "Loss", 0
    s_m_min    db "Min RTT", 0
    s_m_max    db "Max RTT", 0
    s_m_avg    db "Avg RTT", 0
    s_dash     db "-", 0
    s_pctsuf   db "%", 0
    s_title1   db "Statistics for ", 0
    m_timeout  db "Request timed out.", 0
    m_unreach  db "Destination unreachable.", 0
    m_ttlexp   db "TTL expired in transit.", 0
    m_genfail  db "General failure.", 0
    m_frag     db "Packet needs fragmentation but DF is set.", 0
    m_fail     db "Transmit failed, error ", 0
    s_ellipsis db "...", 0
    s_spaces   times TBL_W db ' '
    envname    db "PING_PRETTY", 0
    ; ANSI escapes
    e_reset  db 27, "[0m", 0
    e_green  db 27, "[32m", 0
    e_red    db 27, "[31m", 0
    e_cyan   db 27, "[36m", 0
    e_yellow db 27, "[33m", 0
    e_bold   db 27, "[1m", 0
    escset   dq e_reset, e_green, e_red, e_cyan, e_yellow, e_bold
    ; box charsets: CP437 (legacy console) and UTF-8 (CP 65001)
    c437_h  db 0C4h, 0
    c437_v  db 0B3h, 0
    c437_tl db 0DAh, 0
    c437_tm db 0C2h, 0
    c437_tr db 0BFh, 0
    c437_ml db 0C3h, 0
    c437_mm db 0C5h, 0
    c437_mr db 0B4h, 0
    c437_bl db 0C0h, 0
    c437_bm db 0C1h, 0
    c437_br db 0D9h, 0
    set437 dq c437_h, c437_v, c437_tl, c437_tm, c437_tr
           dq c437_ml, c437_mm, c437_mr, c437_bl, c437_bm, c437_br
    c8_h  db 0E2h, 094h, 080h, 0
    c8_v  db 0E2h, 094h, 082h, 0
    c8_tl db 0E2h, 094h, 08Ch, 0
    c8_tm db 0E2h, 094h, 0ACh, 0
    c8_tr db 0E2h, 094h, 090h, 0
    c8_ml db 0E2h, 094h, 09Ch, 0
    c8_mm db 0E2h, 094h, 0BCh, 0
    c8_mr db 0E2h, 094h, 0A4h, 0
    c8_bl db 0E2h, 094h, 094h, 0
    c8_bm db 0E2h, 094h, 0B4h, 0
    c8_br db 0E2h, 094h, 098h, 0
    setutf8 dq c8_h, c8_v, c8_tl, c8_tm, c8_tr
            dq c8_ml, c8_mm, c8_mr, c8_bl, c8_bm, c8_br
    ca_h db '-', 0
    ca_v db '|', 0
    ca_c db '+', 0
    setascii dq ca_h, ca_v, ca_c, ca_c, ca_c, ca_c, ca_c, ca_c, ca_c, ca_c, ca_c
    ; column layouts
    colw_main  db 12, 30, 7, 16, 9       ; #, From, Size, Time, TTL (total 80)
    colw_span  db TBL_W-2
    colw_stats db 24, TBL_W-27

section .bss
    hstdout    resq 1
    written    resq 1
    sendbuf    resb 65536
    replybuf   resb REPLY_CAP
    wsadata    resb 408
    optinfo    resb 16
    routedata  resb 44
    ip_scr     resb 4
    route_scr  resb 4
    numbuf     resb 32
    tgtbuf     resb 256
    namebuf    resb 256
    tokenbuf   resb TOKEN_CAP
    g_argv     resq 1
    g_argc     resd 1
    g_argidx   resd 1
    g_argerror resb 1
    g_wsa      resb 1
    g_conchanged resb 1
    g_ctrl     resb 1
    g_pending  resb 1
    g_output_error resb 1
    g_exitcode resd 1
    g_icmp     resq 1
    ; Keep these adjacent for WaitForMultipleObjects (stop has priority).
    g_stop_event resq 1
    g_reply_event resq 1
    g_started  resq 1
    conmode    resd 1
    envbuf     resb 8
    g_name     resq 1
    g_count    resq 1
    g_size     resq 1
    g_timeout  resq 1
    g_interval resq 1
    g_ttl      resb 1
    g_tos      resb 1
    g_df       resb 1
    g_resolve  resb 1
    g_infinite resb 1
    g_flood    resb 1
    g_quiet    resb 1
    g_timestamp resb 1
    systemtime resw 8
    g_hastgt   resb 1
    g_rr       resq 1
    g_stop     resb 1
    g_optptr   resq 1
    g_min      resq 1
    g_max      resq 1
    g_sum      resq 1
    g_pretty   resb 1
    g_color    resb 1
    boxset     resq 11
    g_colw     resq 1
    g_ncols    resq 1
    row_cells  resq 5
    hdr1       resb 320             ; bounded name + label + IPv4 address
    hdr2       resb 128
    ipstr      resb 16
    seqbuf     resb 32
    frombuf    resb 256
    bytesbuf   resb 8
    timebuf    resb 32
    ttlbuf     resb 8
    valbuf     resb 32
    errbuf     resb 160

section .text
main:
    sub     rsp, 78h              ; shadow space, eleven API arguments, locals

    ; defaults
    mov     qword [rel g_count], 4
    mov     qword [rel g_size], 32
    mov     qword [rel g_timeout], 4000
    mov     qword [rel g_interval], 1000
    mov     qword [rel g_min], -1

    ; hStdOut = GetStdHandle(STD_OUTPUT_HANDLE)
    mov     rcx, -11
    call    GetStdHandle
    mov     [rel hstdout], rax

    ; ---- pretty-mode detection ----
    mov     rcx, [rel hstdout]
    lea     rdx, [rel conmode]
    call    GetConsoleMode
    test    eax, eax
    jz      .try_env                ; not a console (pipe/file) -> maybe env force
    mov     byte [rel g_pretty], 1
    mov     eax, [rel conmode]
    or      eax, VT_ENABLE
    mov     edx, eax
    mov     rcx, [rel hstdout]
    call    SetConsoleMode
    test    eax, eax
    setnz   byte [rel g_color]
    setnz   byte [rel g_conchanged]
    call    GetConsoleOutputCP
    cmp     eax, CP_UTF8
    je      .utf8
    cmp     eax, 437
    je      .cp437
    cmp     eax, 850
    je      .cp437
    lea     rsi, [rel setascii]    ; do not emit CP437 bytes in other code pages
    jmp     .fillset
.cp437:
    lea     rsi, [rel set437]
    jmp     .fillset
.utf8:
    lea     rsi, [rel setutf8]
    jmp     .fillset
.try_env:
    lea     rcx, [rel envname]
    lea     rdx, [rel envbuf]
    mov     r8d, 8
    call    GetEnvironmentVariableA
    cmp     eax, 1
    jne     .plain
    cmp     byte [rel envbuf], '1'
    jne     .plain
    mov     byte [rel g_pretty], 1
    mov     byte [rel g_color], 1
    lea     rsi, [rel setutf8]
    jmp     .fillset
.fillset:
    lea     rdi, [rel boxset]
    mov     ecx, 11
    rep movsq
    jmp     .pretty_done
.plain:
.pretty_done:

    ; ---- parse arguments ----
    call    GetCommandLineW
    mov     rcx, rax
    lea     rdx, [rel g_argc]
    call    CommandLineToArgvW
    test    rax, rax
    jz      .argerr
    mov     [rel g_argv], rax
    mov     dword [rel g_argidx], 1 ; skip argv[0], including quoted/Unicode paths
.argloop:
    call    next_token                 ; rax = token or 0
    cmp     byte [rel g_argerror], 0
    jne     .argerr
    test    rax, rax
    jz      .args_done
    mov     rcx, rax
    movzx   eax, byte [rcx]
    cmp     al, '-'
    je      .opt
    cmp     al, '/'
    je      .opt
    cmp     byte [rel g_hastgt], 0
    jne     .dup_tgt
    mov     byte [rel g_hastgt], 1
    lea     rdi, [rel tgtbuf]
    xor     edx, edx
.copy_tgt:
    movzx   eax, byte [rcx]
    test    al, al
    jz      .target_end
    cmp     edx, 255
    jae     .badtgt
    ; DNS ASCII labels (IDNs must be supplied as punycode). Also prevents
    ; control characters in terminal output and ambiguous whitespace targets.
    cmp     al, '-'
    je      .target_char
    cmp     al, '.'
    je      .target_char
    cmp     al, '_'
    je      .target_char
    cmp     al, '0'
    jb      .badtgt
    cmp     al, '9'
    jbe     .target_char
    or      al, 32
    cmp     al, 'a'
    jb      .badtgt
    cmp     al, 'z'
    ja      .badtgt
.target_char:
    mov     al, [rcx]
    mov     [rdi], al
    inc     rcx
    inc     rdi
    inc     edx
    jmp     .copy_tgt
.target_end:
    test    edx, edx
    jz      .badtgt
    mov     byte [rdi], 0
    jmp     .argloop
.opt:
    cmp     word [rcx], 2D2Dh       ; exact long options start with "--"
    je      .long_opt
    movzx   eax, byte [rcx+1]
    mov     r9b, al
    test    al, al
    jz      .badopt
    cmp     r9b, 'R'
    je      .unsup
    cmp     al, 'A'
    jb      .lc_done
    cmp     al, 'Z'
    ja      .lc_done
    add     al, 32
.lc_done:
    cmp     al, 'n'
    je      .opt_count
    cmp     al, 'l'
    je      .opt_size
    cmp     al, 'w'
    je      .opt_timeout
    cmp     al, 'i'
    je      .opt_ttl
    cmp     al, 'v'
    je      .opt_tos
    cmp     al, 'r'
    je      .opt_rr
    ; Only numeric options accept attached values (-n4). Flags must be exact.
    cmp     byte [rcx+2], 0
    jne     .badopt
    cmp     al, 'f'
    je      .opt_df
    cmp     al, 'a'
    je      .opt_a
    cmp     al, 't'
    je      .opt_t
    cmp     al, '4'
    je      .argloop
    cmp     al, '?'
    je      .help
    cmp     al, 'h'
    je      .help
    cmp     al, '6'
    je      .unsup
    cmp     al, 'j'
    je      .unsup
    cmp     al, 'k'
    je      .unsup
    cmp     al, 's'
    je      .unsup
    cmp     r9b, 'S'
    je      .unsup
    jmp     .badopt

.long_opt:
    lea     rdx, [rel s_floodopt]
    call    option_equal
    test    eax, eax
    jnz     .opt_flood
    lea     rdx, [rel s_intervalopt]
    call    option_equal
    test    eax, eax
    jnz     .opt_interval
    lea     rdx, [rel s_quietopt]
    call    option_equal
    test    eax, eax
    jnz     .opt_quiet
    lea     rdx, [rel s_timestampopt]
    call    option_equal
    test    eax, eax
    jnz     .opt_timestamp
    jmp     .badopt
.opt_flood:
    mov     byte [rel g_flood], 1
    jmp     .argloop
.opt_interval:
    call    next_token             ; long options use a separate value
    test    rax, rax
    jz      .badval
    mov     rcx, rax
    call    parse_u32
    test    edx, edx
    jnz     .badval
    test    eax, eax
    jz      .badval
    cmp     eax, 600000
    ja      .badval
    mov     [rel g_interval], rax
    jmp     .argloop
.opt_quiet:
    mov     byte [rel g_quiet], 1
    jmp     .argloop
.opt_timestamp:
    mov     byte [rel g_timestamp], 1
    mov     byte [rel g_pretty], 0  ; timestamped records are plain text logs
    mov     byte [rel g_color], 0
    jmp     .argloop

.opt_count:
    call    get_val
    test    rax, rax
    jz      .badval
    mov     rcx, rax
    call    parse_u32
    test    edx, edx
    jnz     .badval
    cmp     eax, 1
    jb      .badval
    cmp     eax, 100000
    ja      .badval
    mov     [rel g_count], rax
    jmp     .argloop
.opt_size:
    call    get_val
    test    rax, rax
    jz      .badval
    mov     rcx, rax
    call    parse_u32
    test    edx, edx
    jnz     .badval
    cmp     eax, MAX_PAYLOAD
    ja      .badval
    mov     [rel g_size], rax
    jmp     .argloop
.opt_timeout:
    call    get_val
    test    rax, rax
    jz      .badval
    mov     rcx, rax
    call    parse_u32
    test    edx, edx
    jnz     .badval
    test    eax, eax
    jz      .badval
    cmp     eax, 600000
    ja      .badval
    mov     [rel g_timeout], rax
    jmp     .argloop
.opt_ttl:
    call    get_val
    test    rax, rax
    jz      .badval
    mov     rcx, rax
    call    parse_u32
    test    edx, edx
    jnz     .badval
    test    eax, eax
    jz      .badval
    cmp     eax, 255
    ja      .badval
    mov     [rel g_ttl], al
    jmp     .argloop
.opt_tos:
    call    get_val
    test    rax, rax
    jz      .badval
    mov     rcx, rax
    call    parse_u32
    test    edx, edx
    jnz     .badval
    cmp     eax, 255
    ja      .badval
    mov     [rel g_tos], al
    jmp     .argloop
.opt_rr:
    call    get_val
    test    rax, rax
    jz      .badval
    mov     rcx, rax
    call    parse_u32
    test    edx, edx
    jnz     .badval
    cmp     eax, 1
    jb      .badval
    cmp     eax, 9
    ja      .badval
    mov     [rel g_rr], rax
    jmp     .argloop
.opt_df:
    mov     byte [rel g_df], 1
    jmp     .argloop
.opt_a:
    mov     byte [rel g_resolve], 1
    jmp     .argloop
.opt_t:
    mov     byte [rel g_infinite], 1
    jmp     .argloop
.help:
    lea     rcx, [rel s_usage]
    call    print_sz
    jmp     .exit0
.badopt:
    lea     rsi, [rel tokenbuf]
    lea     rdi, [rel frombuf]
    call    append_name
    lea     rcx, [rel s_badopt]
    call    print_sz
    lea     rcx, [rel frombuf]
    call    print_sz
    lea     rcx, [rel s_nl]
    call    print_sz
    jmp     .exit2
.badval:
    lea     rcx, [rel s_badval]
    call    print_sz
    jmp     .exit2
.badtgt:
    lea     rcx, [rel s_badtgt]
    call    print_sz
    jmp     .exit2
.argerr:
    lea     rcx, [rel s_argerr]
    call    print_sz
    jmp     .exit2
.unsup:
    lea     rcx, [rel s_unsup]
    call    print_sz
    jmp     .exit2
.dup_tgt:
    lea     rcx, [rel s_duptgt]
    call    print_sz
    jmp     .exit2
.wsa_fail:
    lea     rcx, [rel s_wsa]
    call    print_sz
    jmp     .exit2
.args_done:
    cmp     byte [rel g_hastgt], 0
    je      .noarg
    mov     ecx, 0202h
    lea     rdx, [rel wsadata]
    call    WSAStartup
    test    eax, eax
    jnz     .wsa_fail
    mov     byte [rel g_wsa], 1

    ; ---- resolve target ----
    lea     rsi, [rel tgtbuf]
    call    parse_ip4
    test    rax, rax
    jz      .dns
    mov     r12d, edx
    lea     rsi, [rel tgtbuf]
    lea     rdi, [rel namebuf]
    call    append_name
    jmp     .resolved
.dns:
    lea     rcx, [rel tgtbuf]
    call    gethostbyname
    test    rax, rax
    jz      .nohost
    cmp     word [rax+16], AF_INET
    jne     .nohost
    cmp     word [rax+18], 4
    jne     .nohost
    mov     rcx, [rax+24]
    test    rcx, rcx
    jz      .nohost
    mov     rcx, [rcx]
    test    rcx, rcx
    jz      .nohost
    mov     r12d, [rcx]
    mov     rsi, [rax]
    test    rsi, rsi
    jnz     .copy_name
    lea     rsi, [rel tgtbuf]
.copy_name:
    lea     rdi, [rel namebuf]
    call    append_name
    jmp     .resolved
.nohost:
    lea     rcx, [rel s_badhost1]
    call    print_sz
    lea     rcx, [rel tgtbuf]
    call    print_sz
    lea     rcx, [rel s_badhost2]
    call    print_sz
    jmp     .exit2
.noarg:
    lea     rcx, [rel s_usage]
    call    print_sz
    jmp     .exit1
.resolved:
    ; Winsock's hostent storage is reused by later resolver calls.
    lea     rax, [rel namebuf]
    mov     [rel g_name], rax
    cmp     byte [rel g_resolve], 0
    je      .name_ready
    mov     [rel ip_scr], r12d
    lea     rcx, [rel ip_scr]
    mov     edx, 4
    mov     r8d, AF_INET
    call    gethostbyaddr
    test    rax, rax
    jz      .name_ready
    mov     rsi, [rax]
    test    rsi, rsi
    jz      .name_ready
    lea     rdi, [rel namebuf]
    call    append_name
.name_ready:

    ; ---- header ----
    cmp     byte [rel g_pretty], 0
    je      .hdr_plain
    mov     rax, C_CYAN
    call    print_color
    mov     eax, B_TL
    mov     edx, B_TR
    mov     ecx, TBL_W
    call    box_hline
    ; line 1: "PING <name> [<ip>]"
    lea     r15, [rel hdr1]
    lea     rsi, [rel s_pingcaps]
    mov     rdi, r15
    call    append_str
    mov     r15, rax
    mov     rsi, [rel g_name]
    mov     rdi, r15
    call    append_str
    mov     r15, rax
    lea     rsi, [rel s_lb]
    mov     rdi, r15
    call    append_str
    mov     r15, rax
    mov     [rel ip_scr], r12d
    lea     rsi, [rel ip_scr]
    lea     rdi, [rel ipstr]
    call    ip_str
    lea     rsi, [rel ipstr]
    mov     rdi, r15
    call    append_str
    mov     r15, rax
    lea     rsi, [rel s_rb]
    mov     rdi, r15
    call    append_str
    lea     rcx, [rel hdr1]
    mov     edx, TBL_W
    call    box_line
    ; line 2: "payload N bytes | timeout N ms"
    lea     r15, [rel hdr2]
    lea     rsi, [rel s_payl]
    mov     rdi, r15
    call    append_str
    mov     r15, rax
    mov     rdi, r15
    mov     eax, [rel g_size]
    call    append_dec
    mov     r15, rax
    lea     rsi, [rel s_bytes2]
    mov     rdi, r15
    call    append_str
    mov     r15, rax
    mov     rdi, r15
    mov     eax, [rel g_timeout]
    call    append_dec
    mov     r15, rax
    lea     rsi, [rel s_ms2]
    mov     rdi, r15
    call    append_str
    cmp     byte [rel g_flood], 0
    je      .hdr_interval
    lea     rsi, [rel s_floodtag]
    call    append_str
    jmp     .hdr_config_done
.hdr_interval:
    lea     rsi, [rel s_intervaltag]
    call    append_str
    mov     rax, [rel g_interval]
    call    append_dec
    lea     rsi, [rel s_ms2]
    call    append_str
.hdr_config_done:
    lea     rcx, [rel hdr2]
    mov     edx, TBL_W
    call    box_line
    mov     eax, B_BL
    mov     edx, B_BR
    mov     ecx, TBL_W
    call    box_hline
    mov     rax, C_RESET
    call    print_color
    lea     rcx, [rel s_nl]
    call    print_sz
    jmp     .hdr_done
.hdr_plain:
    lea     rcx, [rel s_pinging]
    call    print_sz
    mov     rcx, [rel g_name]
    call    print_sz
    lea     rcx, [rel s_lb]
    call    print_sz
    mov     [rel ip_scr], r12d
    lea     rcx, [rel ip_scr]
    call    print_ip
    lea     rcx, [rel s_rb_with]
    call    print_sz
    mov     eax, [rel g_size]
    call    print_dec
    lea     rcx, [rel s_bytesdat]
    call    print_sz
    cmp     byte [rel g_flood], 0
    je      .hdr_plain_interval
    lea     rcx, [rel s_floodmsg]
    call    print_sz
    jmp     .hdr_done
.hdr_plain_interval:
    cmp     qword [rel g_interval], 1000
    je      .hdr_done
    lea     rcx, [rel s_intervalmsg]
    call    print_sz
    mov     rax, [rel g_interval]
    call    print_dec
    lea     rcx, [rel s_ms_nl]
    call    print_sz
    lea     rcx, [rel s_nl]
    call    print_sz
.hdr_done:

    ; ---- ICMP handle + Ctrl+C handler ----
    call    IcmpCreateFile
    cmp     rax, -1
    je      .icmperr
    mov     rbx, rax
    mov     [rel g_icmp], rax
    xor     ecx, ecx
    mov     edx, 1                 ; manual reset stop event
    xor     r8d, r8d
    xor     r9d, r9d
    call    CreateEventW
    test    rax, rax
    jz      .eventerr
    mov     [rel g_stop_event], rax
    xor     ecx, ecx
    mov     edx, 1
    xor     r8d, r8d
    xor     r9d, r9d
    call    CreateEventW
    test    rax, rax
    jz      .eventerr
    mov     [rel g_reply_event], rax
    lea     rcx, [rel ctrl_handler]
    mov     edx, 1
    call    SetConsoleCtrlHandler
    test    eax, eax
    jz      .eventerr
    mov     byte [rel g_ctrl], 1

    ; ---- payload pattern ----
    lea     rdi, [rel sendbuf]
    mov     ecx, [rel g_size]
.fill:
    test    ecx, ecx
    jz      .fill_done
    mov     al, cl
    mov     [rdi], al
    inc     rdi
    dec     ecx
    jmp     .fill
.fill_done:

    ; ---- IP options ----
    mov     al, [rel g_ttl]
    test    al, al
    jnz     .ttl_ok
    mov     al, 128
.ttl_ok:
    mov     [rel optinfo+0], al
    mov     al, [rel g_tos]
    mov     [rel optinfo+1], al
    cmp     byte [rel g_df], 0
    je      .no_df
    mov     byte [rel optinfo+2], IP_FLAG_DF
.no_df:
    cmp     qword [rel g_rr], 0
    je      .no_rr
    mov     rax, [rel g_rr]
    lea     rcx, [rel routedata]
    mov     byte [rcx], 7
    lea     edx, [rax*4+3]
    mov     [rcx+1], dl
    mov     byte [rcx+2], 4
    add     edx, 3
    and     edx, 0FFFFFFFCh
    mov     [rel optinfo+3], dl
    lea     rax, [rel routedata]
    mov     [rel optinfo+8], rax
.no_rr:
    cmp     byte [rel g_ttl], 0
    jne     .use_opt
    cmp     byte [rel g_tos], 0
    jne     .use_opt
    cmp     byte [rel g_df], 0
    jne     .use_opt
    cmp     qword [rel g_rr], 0
    jne     .use_opt
    mov     qword [rel g_optptr], 0
    jmp     .opt_done
.use_opt:
    lea     rax, [rel optinfo]
    mov     [rel g_optptr], rax
.opt_done:

    ; ---- ping table header (pretty) ----
    cmp     byte [rel g_quiet], 0
    jne     .tbl_done
    cmp     byte [rel g_pretty], 0
    je      .tbl_done
    lea     rax, [rel colw_main]
    mov     [rel g_colw], rax
    mov     qword [rel g_ncols], 5
    lea     rax, [rel s_c_seq]
    mov     [rel row_cells+0], rax
    lea     rax, [rel s_c_from]
    mov     [rel row_cells+8], rax
    lea     rax, [rel s_c_bytes]
    mov     [rel row_cells+10h], rax
    lea     rax, [rel s_c_time]
    mov     [rel row_cells+18h], rax
    lea     rax, [rel s_c_ttl]
    mov     [rel row_cells+20h], rax
    mov     eax, B_TL
    mov     edx, B_TM
    mov     ecx, B_TR
    call    print_border
    mov     rax, C_BOLD
    call    print_color
    call    print_row
    mov     rax, C_RESET
    call    print_color
    mov     eax, B_ML
    mov     edx, B_MM
    mov     ecx, B_MR
    call    print_border
.tbl_done:

    ; ---- ping loop ----
    xor     r14d, r14d                 ; sent
    xor     r15d, r15d                 ; received
.loop:
    cmp     byte [rel g_stop], 0
    jne     .stats
    cmp     byte [rel g_infinite], 0
    jne     .do_ping
    cmp     r14, [rel g_count]
    jae     .stats
.do_ping:
    call    GetTickCount64
    mov     [rel g_started], rax
    mov     rcx, [rel g_reply_event]
    call    ResetEvent
    test    eax, eax
    jz      .eventerr
    ; Clear the reply header so no previous response can be reused.
    lea     rdi, [rel replybuf]
    xor     eax, eax
    mov     ecx, 5
    rep stosq
    mov     rcx, rbx
    mov     rdx, [rel g_reply_event]
    xor     r8d, r8d
    xor     r9d, r9d
    mov     [rsp+20h], r12
    lea     rax, [rel sendbuf]
    mov     [rsp+28h], rax
    mov     rax, [rel g_size]
    mov     [rsp+30h], rax
    mov     rax, [rel g_optptr]
    mov     [rsp+38h], rax
    lea     rax, [rel replybuf]
    mov     [rsp+40h], rax
    mov     qword [rsp+48h], REPLY_CAP
    mov     eax, [rel g_timeout]
    mov     [rsp+50h], rax
    inc     r14
    call    IcmpSendEcho2
    test    eax, eax
    jnz     .got_reply
    call    GetLastError
    cmp     eax, 997               ; ERROR_IO_PENDING
    jne     .fail_code
    mov     byte [rel g_pending], 1
    mov     ecx, 2
    lea     rdx, [rel g_stop_event]
    xor     r8d, r8d
    mov     r9d, -1
    call    WaitForMultipleObjects
    test    eax, eax               ; stop event
    jz      .stats
    cmp     eax, 1                 ; reply event
    jne     .eventerr
    mov     byte [rel g_pending], 0
    lea     rcx, [rel replybuf]
    mov     edx, REPLY_CAP
    call    IcmpParseReplies
    test    eax, eax
    jz      .fail
.got_reply:
    cmp     dword [rel replybuf+4], 0
    jne     .reply_err

    ; ---- success ----
    inc     r15
    mov     eax, [rel replybuf+8]
    mov     ecx, [rel g_min]
    cmp     eax, ecx
    jae     .nomin
    mov     [rel g_min], eax
.nomin:
    mov     ecx, [rel g_max]
    cmp     eax, ecx
    jbe     .nomax
    mov     [rel g_max], eax
.nomax:
    mov     rcx, [rel g_sum]
    add     rcx, rax
    mov     [rel g_sum], rcx

    cmp     byte [rel g_quiet], 0
    jne     .after
    cmp     byte [rel g_pretty], 0
    je      .row_plain
    ; seq
    lea     rdi, [rel seqbuf]
    mov     rax, r14
    call    append_dec
    ; from
    lea     rdi, [rel frombuf]
    cmp     byte [rel g_resolve], 0
    je      .fr_ip
    cmp     [rel replybuf], r12d
    jne     .fr_ip
    mov     rsi, [rel g_name]
    call    append_str
    jmp     .fr_done
.fr_ip:
    lea     rsi, [rel replybuf]
    call    ip_str
.fr_done:
    ; bytes
    lea     rdi, [rel bytesbuf]
    movzx   eax, word [rel replybuf+12]
    call    append_dec
    ; time
    lea     rdi, [rel timebuf]
    mov     eax, [rel replybuf+8]
    test    eax, eax
    jnz     .t_nz
    lea     rsi, [rel s_lt1]
    call    append_str
    jmp     .t_done
.t_nz:
    call    append_dec
    lea     rsi, [rel s_ms]
    call    append_str
.t_done:
    ; ttl
    lea     rdi, [rel ttlbuf]
    movzx   eax, byte [rel replybuf+24]
    call    append_dec
    ; row cells
    lea     rax, [rel seqbuf]
    mov     [rel row_cells+0], rax
    lea     rax, [rel frombuf]
    mov     [rel row_cells+8], rax
    lea     rax, [rel bytesbuf]
    mov     [rel row_cells+10h], rax
    lea     rax, [rel timebuf]
    mov     [rel row_cells+18h], rax
    lea     rax, [rel ttlbuf]
    mov     [rel row_cells+20h], rax
    mov     rax, C_GREEN
    call    print_color
    call    print_row
    mov     rax, C_RESET
    call    print_color
    jmp     .route
.row_plain:
    call    print_timestamp
    lea     rcx, [rel s_reply]
    call    print_sz
    cmp     byte [rel g_resolve], 0
    je      .norev
    cmp     [rel replybuf], r12d
    jne     .norev
    mov     rcx, [rel g_name]
    call    print_sz
    lea     rcx, [rel s_lb]
    call    print_sz
    lea     rcx, [rel replybuf]
    call    print_ip
    lea     rcx, [rel s_rb_col]
    call    print_sz
    jmp     .bytes
.norev:
    lea     rcx, [rel replybuf]
    call    print_ip
    lea     rcx, [rel s_colon_b]
    call    print_sz
.bytes:
    movzx   eax, word [rel replybuf+12]
    call    print_dec
    lea     rcx, [rel s_time]
    call    print_sz
    mov     eax, [rel replybuf+8]
    test    eax, eax
    jnz     .rtt_nz
    lea     rcx, [rel s_lt1]
    call    print_sz
    jmp     .ttl
.rtt_nz:
    lea     rcx, [rel s_eq]
    call    print_sz
    mov     eax, [rel replybuf+8]
    call    print_dec
    lea     rcx, [rel s_ms]
    call    print_sz
.ttl:
    lea     rcx, [rel s_ttl]
    call    print_sz
    movzx   eax, byte [rel replybuf+24]
    call    print_dec
    lea     rcx, [rel s_nl]
    call    print_sz
    ; fall into route
.route:
    cmp     qword [rel g_rr], 0
    je      .after
    call    print_route
    jmp     .after

    ; ---- failure ----
.fail:
    call    GetLastError
.fail_code:
    lea     rdi, [rel errbuf]
    mov     [rsp+40h], rdi
    mov     byte [rdi], 0
    jmp     .map_code
.reply_err:
    lea     rdi, [rel errbuf]
    mov     [rsp+40h], rdi
    lea     rsi, [rel s_reply]
    call    append_str
    mov     [rsp+40h], rax
    lea     rsi, [rel replybuf]
    mov     rdi, rax
    call    ip_str
    mov     [rsp+40h], rax
    lea     rsi, [rel s_colon_sp]
    mov     rdi, rax
    call    append_str
    mov     [rsp+40h], rax
    mov     eax, [rel replybuf+4]
.map_code:                          ; eax = error code, errbuf cursor at [rsp+40h]
    mov     [rsp+38h], eax
    lea     r13, [rel m_fail]
    cmp     eax, 11010
    je      .m_to
    cmp     eax, 11002
    je      .m_unr
    cmp     eax, 11003
    je      .m_unr
    cmp     eax, 11004
    je      .m_unr
    cmp     eax, 11005
    je      .m_unr
    cmp     eax, 11013
    je      .m_ttl
    cmp     eax, 11014
    je      .m_ttl
    cmp     eax, 11050
    je      .m_gf
    cmp     eax, 11009
    je      .m_frag
    jmp     .app_msg
.m_to:
    lea     r13, [rel m_timeout]
    jmp     .app_msg
.m_unr:
    lea     r13, [rel m_unreach]
    jmp     .app_msg
.m_ttl:
    lea     r13, [rel m_ttlexp]
    jmp     .app_msg
.m_gf:
    lea     r13, [rel m_genfail]
    jmp     .app_msg
.m_frag:
    lea     r13, [rel m_frag]
.app_msg:
    mov     rsi, r13
    mov     rdi, [rsp+40h]
    call    append_str
    mov     [rsp+40h], rax
    lea     rax, [rel m_fail]
    cmp     r13, rax
    jne     .emit_err
    mov     rdi, [rsp+40h]
    mov     eax, [rsp+38h]
    call    append_dec
.emit_err:
    cmp     byte [rel g_quiet], 0
    jne     .after
    cmp     byte [rel g_pretty], 0
    je      .err_plain
    lea     rax, [rel colw_span]
    mov     [rel g_colw], rax
    mov     qword [rel g_ncols], 1
    lea     rax, [rel errbuf]
    mov     [rel row_cells], rax
    mov     rax, C_RED
    call    print_color
    call    print_row
    mov     rax, C_RESET
    call    print_color
    lea     rax, [rel colw_main]
    mov     [rel g_colw], rax
    mov     qword [rel g_ncols], 5
    jmp     .after
.err_plain:
    call    print_timestamp
    lea     rcx, [rel errbuf]
    call    print_sz
    lea     rcx, [rel s_nl]
    call    print_sz
.after:
    cmp     byte [rel g_stop], 0
    jne     .stats
    cmp     byte [rel g_infinite], 0
    jne     .pace
    cmp     r14, [rel g_count]
    jae     .stats
.pace:
    cmp     byte [rel g_flood], 0
    jne     .loop                  ; keep count/stop checks and one pending request
    call    GetTickCount64
    sub     rax, [rel g_started]
    cmp     rax, [rel g_interval]
    jae     .loop
    mov     edx, [rel g_interval]
    sub     edx, eax
    mov     rcx, [rel g_stop_event]
    call    WaitForSingleObject
    cmp     eax, -1
    je      .eventerr
    jmp     .loop

    ; ---- statistics ----
.stats:
    cmp     byte [rel g_pretty], 0
    je      .stats_plain
    cmp     byte [rel g_quiet], 0
    jne     .stats_title
    ; close ping table
    mov     eax, B_BL
    mov     edx, B_BM
    mov     ecx, B_BR
    call    print_border
    lea     rcx, [rel s_nl]
    call    print_sz
.stats_title:
    ; stats box title
    mov     rax, C_YELLOW
    call    print_color
    mov     eax, B_TL
    mov     edx, B_TR
    mov     ecx, TBL_W
    call    box_hline
    lea     r10, [rel hdr1]
    lea     rsi, [rel s_title1]
    mov     rdi, r10
    call    append_str
    mov     r10, rax
    mov     rsi, [rel g_name]
    mov     rdi, r10
    call    append_str
    lea     rcx, [rel hdr1]
    mov     edx, TBL_W
    call    box_line
    mov     eax, B_BL
    mov     edx, B_BR
    mov     ecx, TBL_W
    call    box_hline
    ; stats table
    lea     rax, [rel colw_stats]
    mov     [rel g_colw], rax
    mov     qword [rel g_ncols], 2
    mov     eax, B_TL
    mov     edx, B_TM
    mov     ecx, B_TR
    call    print_border
    lea     rax, [rel s_c_metric]
    mov     [rel row_cells], rax
    lea     rax, [rel s_c_value]
    mov     [rel row_cells+8], rax
    mov     rax, C_BOLD
    call    print_color
    call    print_row
    mov     rax, C_RESET
    call    print_color
    mov     eax, B_ML
    mov     edx, B_MM
    mov     ecx, B_MR
    call    print_border
    ; Sent
    lea     rdi, [rel valbuf]
    mov     rax, r14
    call    append_dec
    lea     rcx, [rel s_m_sent]
    lea     rdx, [rel valbuf]
    call    stat_row
    ; Received
    lea     rdi, [rel valbuf]
    mov     rax, r15
    call    append_dec
    lea     rcx, [rel s_m_recv]
    lea     rdx, [rel valbuf]
    call    stat_row
    ; Lost
    mov     rax, r14
    sub     rax, r15
    mov     r13, rax
    lea     rdi, [rel valbuf]
    call    append_dec
    lea     rcx, [rel s_m_lost]
    lea     rdx, [rel valbuf]
    call    stat_row
    ; Loss %
    lea     rdi, [rel valbuf]
    call    loss_percent
    call    append_dec
    lea     rsi, [rel s_pctsuf]
    mov     rdi, rax
    call    append_str
    lea     rcx, [rel s_m_loss]
    lea     rdx, [rel valbuf]
    call    stat_row
    ; RTT rows only when something was received
    test    r15, r15
    je      .no_times_p
    lea     rdi, [rel valbuf]
    mov     eax, [rel g_min]
    call    append_dec
    lea     rsi, [rel s_ms]
    mov     rdi, rax
    call    append_str
    lea     rcx, [rel s_m_min]
    lea     rdx, [rel valbuf]
    call    stat_row
    lea     rdi, [rel valbuf]
    mov     eax, [rel g_max]
    call    append_dec
    lea     rsi, [rel s_ms]
    mov     rdi, rax
    call    append_str
    lea     rcx, [rel s_m_max]
    lea     rdx, [rel valbuf]
    call    stat_row
    lea     rdi, [rel valbuf]
    mov     rax, [rel g_sum]
    mov     rcx, r15
    shr     rcx, 1
    add     rax, rcx
    xor     edx, edx
    div     r15
    call    append_dec
    lea     rsi, [rel s_ms]
    mov     rdi, rax
    call    append_str
    lea     rcx, [rel s_m_avg]
    lea     rdx, [rel valbuf]
    call    stat_row
    jmp     .times_done_p
.no_times_p:
    lea     rcx, [rel s_m_min]
    lea     rdx, [rel s_dash]
    call    stat_row
    lea     rcx, [rel s_m_max]
    lea     rdx, [rel s_dash]
    call    stat_row
    lea     rcx, [rel s_m_avg]
    lea     rdx, [rel s_dash]
    call    stat_row
.times_done_p:
    mov     eax, B_BL
    mov     edx, B_BM
    mov     ecx, B_BR
    call    print_border
    mov     rax, C_RESET
    call    print_color
    jmp     .stats_done
.stats_plain:
    lea     rcx, [rel s_stat1]
    call    print_sz
    mov     rcx, [rel g_name]
    call    print_sz
    lea     rcx, [rel s_colon_nl]
    call    print_sz
    lea     rcx, [rel s_pkts]
    call    print_sz
    mov     rax, r14
    call    print_dec
    lea     rcx, [rel s_recv]
    call    print_sz
    mov     rax, r15
    call    print_dec
    lea     rcx, [rel s_lost]
    call    print_sz
    mov     rax, r14
    sub     rax, r15
    mov     r13, rax
    call    print_dec
    lea     rcx, [rel s_pct]
    call    print_sz
    call    loss_percent
    call    print_dec
    lea     rcx, [rel s_pct2]
    call    print_sz
    test    r15, r15
    je      .no_times
    lea     rcx, [rel s_rtt_hdr]
    call    print_sz
    lea     rcx, [rel s_min]
    call    print_sz
    mov     eax, [rel g_min]
    call    print_dec
    lea     rcx, [rel s_ms_comma]
    call    print_sz
    mov     eax, [rel g_max]
    call    print_dec
    lea     rcx, [rel s_avg]
    call    print_sz
    mov     rax, [rel g_sum]
    mov     rcx, r15
    shr     rcx, 1
    add     rax, rcx
    xor     edx, edx
    div     r15
    call    print_dec
    lea     rcx, [rel s_ms_nl]
    call    print_sz
.no_times:
.stats_done:
    test    r15, r15
    jz      .exit1
    jmp     .exit0

.eventerr:
    lea     rcx, [rel s_eventerr]
    call    print_sz
    jmp     .exit2
.icmperr:
    lea     rcx, [rel s_noicmp]
    call    print_sz
.exit2:
    mov     ecx, 2
    jmp     .cleanup
.exit1:
    mov     ecx, 1
    jmp     .cleanup
.exit0:
    xor     ecx, ecx
.cleanup:
    mov     [rel g_exitcode], ecx
    cmp     byte [rel g_ctrl], 0
    je      .close_icmp
    lea     rcx, [rel ctrl_handler]
    xor     edx, edx
    call    SetConsoleCtrlHandler
.close_icmp:
    ; IcmpCloseHandle can wait for a pending request's full timeout. On an
    ; interrupted request, keep its handle, event and static buffer alive until
    ; ExitProcess cancels the I/O and reclaims them. Never free these early.
    cmp     byte [rel g_pending], 0
    jne     .close_wsa
    mov     rcx, [rel g_icmp]
    test    rcx, rcx
    jz      .close_reply
    call    IcmpCloseHandle
.close_reply:
    mov     rcx, [rel g_reply_event]
    test    rcx, rcx
    jz      .close_stop
    call    CloseHandle
.close_stop:
    mov     rcx, [rel g_stop_event]
    test    rcx, rcx
    jz      .close_wsa
    call    CloseHandle
.close_wsa:
    cmp     byte [rel g_wsa], 0
    je      .free_args
    call    WSACleanup
.free_args:
    mov     rcx, [rel g_argv]
    test    rcx, rcx
    jz      .restore_console
    call    LocalFree
.restore_console:
    mov     eax, C_RESET
    call    print_color
    cmp     byte [rel g_conchanged], 0
    je      .exit
    mov     rcx, [rel hstdout]
    mov     edx, [rel conmode]
    call    SetConsoleMode
.exit:
    mov     ecx, [rel g_exitcode]
    cmp     byte [rel g_output_error], 0
    je      .exit_ready
    mov     ecx, 2
.exit_ready:
    call    ExitProcess

; ---------- Ctrl+C handler ----------
ctrl_handler:
    cmp     ecx, 1                 ; handle Ctrl+C / Ctrl+Break only
    ja      .unhandled
    sub     rsp, 28h
    mov     byte [rel g_stop], 1
    mov     rcx, [rel g_stop_event]
    call    SetEvent
    mov     eax, 1
    add     rsp, 28h
    ret
.unhandled:
    xor     eax, eax
    ret

; ---------- token / parse helpers ----------

option_equal:                      ; rcx/rdx = strings, eax = bool; preserves pointers
    xor     r8d, r8d
.compare:
    mov     al, [rcx+r8]
    cmp     al, [rdx+r8]
    jne     .different
    test    al, al
    jz      .equal
    inc     r8
    jmp     .compare
.equal:
    mov     eax, 1
    ret
.different:
    xor     eax, eax
    ret

next_token:                         ; next Windows argv entry -> tokenbuf or 0
    sub     rsp, 48h
    mov     eax, [rel g_argidx]
    cmp     eax, [rel g_argc]
    jae     .none
    mov     r10, [rel g_argv]
    mov     r8, [r10+rax*8]
    inc     dword [rel g_argidx]
    mov     ecx, CP_UTF8
    xor     edx, edx
    mov     r9d, -1
    lea     rax, [rel tokenbuf]
    mov     [rsp+20h], rax
    mov     qword [rsp+28h], TOKEN_CAP
    mov     qword [rsp+30h], 0
    mov     qword [rsp+38h], 0
    call    WideCharToMultiByte
    test    eax, eax
    jz      .error
    lea     rax, [rel tokenbuf]
    add     rsp, 48h
    ret
.error:
    mov     byte [rel g_argerror], 1
.none:
    xor     eax, eax
    add     rsp, 48h
    ret

get_val:                            ; rcx = option token -> rax = value ptr or 0
    cmp     byte [rcx+2], 0
    jne     .inline
    jmp     next_token
.inline:
    lea     rax, [rcx+2]
    ret

parse_u32:                          ; rcx = asciiz -> rax = value, edx = 0/1
    xor     eax, eax
    xor     r8d, r8d
.loop:
    movzx   edx, byte [rcx]
    test    dl, dl
    jz      .end
    sub     edx, '0'
    cmp     edx, 9
    ja      .bad
    cmp     eax, 429496729
    ja      .bad
    jb      .accumulate
    cmp     edx, 5
    ja      .bad
.accumulate:
    imul    eax, eax, 10
    add     eax, edx
    inc     rcx
    inc     r8d
    jmp     .loop
.end:
    test    r8d, r8d
    jz      .bad
    xor     edx, edx
    ret
.bad:
    mov     edx, 1
    ret

parse_ip4:                          ; rsi = asciiz -> rax = 1, edx = ip / rax = 0
    xor     edx, edx
    mov     r8d, 4
.octet:
    xor     ecx, ecx
    xor     r9d, r9d
.digit:
    movzx   eax, byte [rsi]
    sub     al, '0'
    cmp     al, 9
    ja      .digit_end
    imul    ecx, ecx, 10
    add     ecx, eax
    cmp     ecx, 255
    ja      .fail
    inc     rsi
    inc     r9d
    jmp     .digit
.digit_end:
    test    r9d, r9d
    jz      .fail
    imul    edx, edx, 256
    add     edx, ecx
    dec     r8d
    jz      .done
    cmp     byte [rsi], '.'
    jne     .fail
    inc     rsi
    jmp     .octet
.done:
    cmp     byte [rsi], 0
    jne     .fail
    bswap   edx
    mov     eax, 1
    ret
.fail:
    xor     eax, eax
    ret

; ---------- string helpers ----------
; Internal format helpers deliberately advance RSI/RDI. All imported Win32
; calls use the x64 ABI, with 16-byte stack alignment and 32-byte shadow space.

append_name:                        ; bounded/sanitized hostent name -> 256 bytes
    mov     ecx, 255
.loop:
    mov     al, [rsi]
    test    al, al
    jz      .done
    cmp     al, 32
    jb      .replace
    cmp     al, 127
    jb      .copy
.replace:
    mov     al, '?'
.copy:
    mov     [rdi], al
    inc     rsi
    inc     rdi
    dec     ecx
    jnz     .loop
.done:
    mov     byte [rdi], 0
    mov     rax, rdi
    ret

append_str:                         ; rdi = cursor, rsi = asciiz -> rax = new cursor
.l:
    movzx   eax, byte [rsi]
    mov     [rdi], al
    test    al, al
    jz      .done
    inc     rsi
    inc     rdi
    jmp     .l
.done:
    mov     rax, rdi
    ret

dec_to_buf:                         ; rax = uint64, rdi = cursor -> rdi advanced
    mov     r8, rax
    lea     r10, [rel numbuf+31]
.conv:
    xor     edx, edx
    mov     rax, r8
    mov     r11d, 10
    div     r11
    add     dl, '0'
    dec     r10
    mov     [r10], dl
    mov     r8, rax
    test    r8, r8
    jnz     .conv
    lea     r11, [rel numbuf+31]
.cp:
    mov     al, [r10]
    mov     [rdi], al
    inc     r10
    inc     rdi
    cmp     r10, r11
    jb      .cp
    ret

append_dec:                         ; rdi = cursor, rax = value -> rax = new cursor
    sub     rsp, 28h
    call    dec_to_buf
    mov     byte [rdi], 0
    mov     rax, rdi
    add     rsp, 28h
    ret

ip_str:                             ; rsi = 4 addr bytes, rdi = dest -> rax = cursor
    sub     rsp, 28h
    mov     dword [rsp+20h], 0
.l:
    movzx   eax, byte [rsi]
    call    dec_to_buf
    inc     rsi
    inc     dword [rsp+20h]
    cmp     dword [rsp+20h], 4
    jge     .done
    mov     byte [rdi], '.'
    inc     rdi
    jmp     .l
.done:
    mov     byte [rdi], 0
    mov     rax, rdi
    add     rsp, 28h
    ret

; ---------- console output helpers ----------

print_timestamp:
    cmp     byte [rel g_timestamp], 0
    je      .done
    sub     rsp, 28h
    lea     rcx, [rel systemtime]
    call    GetSystemTime           ; UTC; SYSTEMTIME is eight WORD fields
    lea     rdi, [rel timestamp_text+1]
    movzx   eax, word [rel systemtime]
    mov     ecx, 4
    call    fixed_digits
    lea     rdi, [rel timestamp_text+6]
    movzx   eax, word [rel systemtime+2]
    mov     ecx, 2
    call    fixed_digits
    lea     rdi, [rel timestamp_text+9]
    movzx   eax, word [rel systemtime+6]
    mov     ecx, 2
    call    fixed_digits
    lea     rdi, [rel timestamp_text+12]
    movzx   eax, word [rel systemtime+8]
    mov     ecx, 2
    call    fixed_digits
    lea     rdi, [rel timestamp_text+15]
    movzx   eax, word [rel systemtime+10]
    mov     ecx, 2
    call    fixed_digits
    lea     rdi, [rel timestamp_text+18]
    movzx   eax, word [rel systemtime+12]
    mov     ecx, 2
    call    fixed_digits
    lea     rdi, [rel timestamp_text+21]
    movzx   eax, word [rel systemtime+14]
    mov     ecx, 3
    call    fixed_digits
    lea     rcx, [rel timestamp_text]
    call    print_sz
    add     rsp, 28h
.done:
    ret

fixed_digits:                       ; eax=value, ecx=width, rdi=destination
    mov     r9d, 10
.digit:
    xor     edx, edx
    div     r9d
    add     dl, '0'
    dec     ecx
    mov     [rdi+rcx], dl
    test    ecx, ecx
    jnz     .digit
    ret

loss_percent:                      ; sent=r14, received=r15; zero-safe uint64 math
    xor     eax, eax
    test    r14, r14
    jz      .done
    mov     rax, r14
    sub     rax, r15
    mov     ecx, 100
    mul     rcx                    ; 128-bit product avoids long-run overflow
    div     r14
.done:
    ret

print_route:
    push    r13
    push    r14
    sub     rsp, 28h
    movzx   edx, byte [rel replybuf+27]
    test    edx, edx
    jz      .done
    cmp     edx, 40
    ja      .done
    mov     r10, [rel replybuf+32]
    lea     rax, [rel replybuf+40]
    cmp     r10, rax
    jb      .done
    lea     rax, [rel replybuf+REPLY_CAP]
    sub     rax, rdx
    cmp     r10, rax
    ja      .done
    lea     r11, [r10+rdx]
.option:
    cmp     r10, r11
    jae     .done
    movzx   eax, byte [r10]
    test    eax, eax               ; end of options
    jz      .done
    cmp     eax, 1                 ; one-byte NOP
    je      .nop
    lea     rax, [r10+2]
    cmp     rax, r11
    ja      .done
    movzx   ecx, byte [r10+1]
    cmp     ecx, 2
    jb      .done
    lea     rax, [r10+rcx]
    cmp     rax, r11
    ja      .done
    cmp     byte [r10], 7          ; record-route TLV
    je      .rr
    mov     r10, rax
    jmp     .option
.nop:
    inc     r10
    jmp     .option
.rr:
    cmp     ecx, 3
    jb      .done
    movzx   eax, byte [r10+2]       ; 1-based next-write pointer
    cmp     eax, 4
    jb      .done
    lea     edx, [rcx+1]
    cmp     eax, edx
    ja      .done
    sub     eax, 4
    test    eax, 3
    jnz     .done
    shr     eax, 2
    test    eax, eax
    jz      .done
    cmp     eax, 9
    ja      .done
    mov     r14d, eax
    lea     r13, [r10+3]           ; addresses start after three header bytes
    mov     dword [rsp+20h], 0
    lea     rdi, [rel errbuf]
    lea     rsi, [rel s_route]
    call    append_str
.address:
    lea     rsi, [rel s_spc]
    call    append_str
    mov     rsi, r13
    call    ip_str
    add     r13, 4
    dec     r14
    jz      .emit
    inc     dword [rsp+20h]
    cmp     byte [rel g_pretty], 0
    je      .address
    cmp     dword [rsp+20h], 4
    jb      .address
    call    route_row              ; wrap complete addresses, never hide hops
    mov     dword [rsp+20h], 0
    lea     rdi, [rel errbuf]
    lea     rsi, [rel s_route]
    call    append_str
    jmp     .address
.emit:
    cmp     byte [rel g_pretty], 0
    jne     .pretty
    lea     rcx, [rel errbuf]
    call    print_sz
    lea     rcx, [rel s_nl]
    call    print_sz
    jmp     .done
.pretty:
    call    route_row
.done:
    add     rsp, 28h
    pop     r14
    pop     r13
    ret

route_row:
    sub     rsp, 28h
    lea     rax, [rel colw_span]
    mov     [rel g_colw], rax
    mov     qword [rel g_ncols], 1
    lea     rax, [rel errbuf]
    mov     [rel row_cells], rax
    call    print_row
    lea     rax, [rel colw_main]
    mov     [rel g_colw], rax
    mov     qword [rel g_ncols], 5
    add     rsp, 28h
    ret

print_sz:                           ; rcx = asciiz
    sub     rsp, 28h
    call    strlen8
    mov     rdx, rax
    call    ws_print_raw
    add     rsp, 28h
    ret

strlen8:
    xor     rax, rax
.scan:
    cmp     byte [rcx + rax], 0
    je      .found
    inc     rax
    jmp     .scan
.found:
    ret

ws_print_raw:                       ; rcx = buffer, rdx = length
    sub     rsp, 48h
    mov     [rsp+28h], rcx
    mov     [rsp+30h], rdx
.loop:
    cmp     qword [rsp+30h], 0
    je      .done
    cmp     byte [rel g_output_error], 0
    jne     .done
    mov     rcx, [rel hstdout]
    mov     rdx, [rsp+28h]
    mov     r8d, [rsp+30h]
    lea     r9, [rel written]
    mov     qword [rsp + 20h], 0
    call    WriteFile
    test    eax, eax
    jz      .error
    mov     eax, [rel written]
    test    eax, eax
    jz      .error
    add     [rsp+28h], rax
    sub     [rsp+30h], rax
    jmp     .loop
.error:
    mov     byte [rel g_output_error], 1
    mov     byte [rel g_stop], 1
.done:
    add     rsp, 48h
    ret

print_dec:                          ; rax = unsigned value
    sub     rsp, 28h
    lea     rdi, [rel numbuf]
    call    dec_to_buf
    mov     byte [rdi], 0
    lea     rcx, [rel numbuf]
    mov     rdx, rdi
    sub     rdx, rcx
    call    ws_print_raw
    add     rsp, 28h
    ret

print_ip:                           ; rcx = ptr to 4 bytes (network order)
    push    r13
    push    r14
    sub     rsp, 28h
    mov     r13, rcx
    lea     r14, [rcx + 3]
.oct:
    movzx   eax, byte [r13]
    call    print_dec
    inc     r13
    cmp     r13, r14
    ja      .ipend
    lea     rcx, [rel s_dot]
    call    print_sz
    jmp     .oct
.ipend:
    add     rsp, 28h
    pop     r14
    pop     r13
    ret

print_color:                        ; rax = color index
    cmp     byte [rel g_color], 0
    je      .done
    lea     r10, [rel escset]
    mov     rcx, [r10 + rax*8]
    jmp     print_sz
.done:
    ret

print_charset:                      ; rax = box charset index
    lea     r10, [rel boxset]
    mov     rcx, [r10 + rax*8]
    jmp     print_sz

; print_cell: rcx = string, rdx = cell width (prints " " + content + padding)
print_cell:
    sub     rsp, 48h
    mov     [rsp+20h], rcx          ; content
    mov     [rsp+28h], rdx          ; width
    mov     byte [rsp+38h], 0
    mov     rcx, [rsp+20h]
    call    strlen8                 ; rax = len
    mov     rdx, rax
    mov     r10, [rsp+28h]
    sub     r10, 2                  ; max content
    cmp     rdx, r10
    jbe     .nocap
    mov     rdx, r10
    cmp     rdx, 3
    jb      .nocap
    sub     rdx, 3
    mov     byte [rsp+38h], 1
.nocap:
    mov     [rsp+30h], rdx          ; printed length
    lea     rcx, [rel s_spc]
    call    print_sz
    mov     rcx, [rsp+20h]
    mov     rdx, [rsp+30h]
    call    ws_print_raw
    cmp     byte [rsp+38h], 0
    je      .padding
    lea     rcx, [rel s_ellipsis]
    call    print_sz
    add     qword [rsp+30h], 3
.padding:
    mov     r11, [rsp+28h]
    sub     r11, 2
    sub     r11, [rsp+30h]         ; pad count
    cmp     r11, TBL_W
    jbe     .sp
    mov     r11, TBL_W
.sp:
    lea     rcx, [rel s_spaces]
    mov     rdx, r11
    call    ws_print_raw
    lea     rcx, [rel s_spc]       ; trailing space: cell total = width
    call    print_sz
    add     rsp, 48h
    ret

; print_row: prints one table row from row_cells[0..g_ncols), g_colw layout
print_row:
    sub     rsp, 48h
    mov     rax, B_V
    call    print_charset
    mov     dword [rsp+40h], 0
.rl:
    mov     eax, [rsp+40h]
    cmp     eax, [rel g_ncols]
    jge     .rdone
    lea     r10, [rel row_cells]
    mov     rcx, [r10 + rax*8]
    mov     r10, [rel g_colw]
    movzx   edx, byte [r10 + rax]
    call    print_cell
    inc     dword [rsp+40h]
    mov     rax, B_V
    call    print_charset
    jmp     .rl
.rdone:
    lea     rcx, [rel s_nl]
    call    print_sz
    add     rsp, 48h
    ret

; print_border: eax = left idx, edx = mid idx, ecx = right idx
print_border:
    sub     rsp, 58h
    mov     [rsp+28h], rax
    mov     [rsp+30h], rdx
    mov     [rsp+38h], rcx
    mov     rax, [rsp+28h]
    call    print_charset
    mov     dword [rsp+40h], 0
.bl:
    mov     eax, [rsp+40h]
    cmp     eax, [rel g_ncols]
    jge     .bdone
    mov     r10, [rel g_colw]
    movzx   eax, byte [r10 + rax]
    mov     [rsp+48h], rax          ; dash count for this column
.rep:
    cmp     qword [rsp+48h], 0
    je      .rep_done
    mov     rax, B_H
    call    print_charset
    dec     qword [rsp+48h]
    jmp     .rep
.rep_done:
    inc     dword [rsp+40h]
    mov     eax, [rsp+40h]
    cmp     eax, [rel g_ncols]
    jl      .mid
    mov     rax, [rsp+38h]
    jmp     .app
.mid:
    mov     rax, [rsp+30h]
.app:
    call    print_charset
    jmp     .bl
.bdone:
    lea     rcx, [rel s_nl]
    call    print_sz
    add     rsp, 58h
    ret

; box_hline: eax = left idx, edx = right idx, ecx = total width
box_hline:
    sub     rsp, 38h
    mov     [rsp+20h], rcx          ; width
    mov     [rsp+28h], rdx          ; right idx
    call    print_charset           ; left (rax)
    mov     rcx, [rsp+20h]
    sub     rcx, 2
    mov     [rsp+20h], rcx          ; dash count
.rep:
    cmp     qword [rsp+20h], 0
    je      .done
    mov     rax, B_H
    call    print_charset
    dec     qword [rsp+20h]
    jmp     .rep
.done:
    mov     rax, [rsp+28h]
    call    print_charset
    lea     rcx, [rel s_nl]
    call    print_sz
    add     rsp, 38h
    ret

; box_line: rcx = content, edx = total box width
box_line:
    sub     rsp, 38h
    mov     [rsp+20h], rcx
    mov     [rsp+28h], rdx
    mov     rax, B_V
    call    print_charset
    mov     rcx, [rsp+20h]
    mov     rdx, [rsp+28h]
    sub     rdx, 2
    call    print_cell
    mov     rax, B_V
    call    print_charset
    lea     rcx, [rel s_nl]
    call    print_sz
    add     rsp, 38h
    ret

; stat_row: rcx = label, rdx = value string
stat_row:
    sub     rsp, 28h
    mov     [rel row_cells], rcx
    mov     [rel row_cells+8], rdx
    call    print_row
    add     rsp, 28h
    ret
