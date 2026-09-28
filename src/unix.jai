time_base: Uint32;

initialize :: () -> s32 {
    return 0;
}

deinitialize :: () {
}

time_get :: () -> Uint32 {
    time_val: C_Transpiler_POSIX.timeval = ---;

    gettimeofday(*time_val, null);

    return cast,no_check(Uint32) (((time_val.tv_sec * 1000) + time_val.tv_usec / 1000) - cast(s64) time_base);
}

time_set :: (new_time_base: Uint32) {
    time_val: C_Transpiler_POSIX.timeval = ---;

    gettimeofday(*time_val, null);

    time_base = cast,no_check(Uint32) (((time_val.tv_sec * 1000) + time_val.tv_usec / 1000) - cast(s64) new_time_base);
}

socket_create :: (type: Socket_Type_in_enet) -> Socket {
    return socket(
        2,
        (ifx type == cast,no_check(u32) SOCKET_TYPE_DATAGRAM then cast,no_check(s32) (SOCK_DGRAM) else cast,no_check(s32) (SOCK_STREAM)),
        0
    );
}

socket_bind :: (socket: Socket, address: *Address) -> s32 {
    sin: Sockaddr_In = ---;

    fill_memory(*sin, 0, size_of(Sockaddr_In));

    sin.sin_family = 2;

    if address != null {
        sin.sin_port = htons(address.port);
        sin.sin_addr.addr = address.host;
    } else {
        sin.sin_port = 0;
        sin.sin_addr.addr = 0;
    }

    return bind(socket, cast(*Sockaddr) *sin, cast,no_check(Socklen_T) (cast(u64) size_of(Sockaddr_In)));
}

socket_get_address :: (socket: Socket, address: *Address) -> s32 {
    sin: Sockaddr_In = ---;
    sin_length: Socklen_T = cast,no_check(Socklen_T) (cast(u64) size_of(Sockaddr_In));

    if getsockname(socket, cast(*Sockaddr) *sin, *sin_length) == -1 {
        return -1;
    }

    address.host = sin.sin_addr.addr;
    address.port = ntohs(sin.sin_port);

    return 0;
}

socket_listen :: (socket: Socket, backlog: s32) -> s32 {
    return listen(socket, (ifx backlog < 0 then 4096 else backlog));
}

socket_accept :: (socket: Socket, address: *Address) -> Socket {
    sin: Sockaddr_In = ---;
    sin_length: Socklen_T = cast,no_check(Socklen_T) (cast(u64) size_of(Sockaddr_In));

    result :=
        accept(
            socket,
            (ifx address != null then cast(*Sockaddr) *sin else null),
            (ifx address != null then *sin_length else null)
        );

    if result == -1 {
        return -1;
    }

    if address != null {
        address.host = sin.sin_addr.addr;
        address.port = ntohs(sin.sin_port);
    }

    return result;
}

socket_connect :: (socket: Socket, address: *Address) -> s32 {
    sin: Sockaddr_In = ---;

    fill_memory(*sin, 0, size_of(Sockaddr_In));

    sin.sin_family = 2;
    sin.sin_port = htons(address.port);
    sin.sin_addr.addr = address.host;

    result := connect(socket, cast(*Sockaddr) *sin, cast,no_check(Socklen_T) (cast(u64) size_of(Sockaddr_In)));
    if result == -1 && system_error_code().* == 115 {
        return 0;
    }

    return result;
}

socket_send :: (socket: Socket, address: *Address, buffers: *Buffer, buffer_count: u64) -> s32 {
    msg_hdr: Msghdr = ---;
    sin: Sockaddr_In = ---;

    fill_memory(*msg_hdr, 0, size_of(Msghdr));

    if address != null {
        fill_memory(*sin, 0, size_of(Sockaddr_In));

        sin.sin_family = 2;
        sin.sin_port = htons(address.port);
        sin.sin_addr.addr = address.host;

        msg_hdr.msg_name = cast(*void) *sin;
        msg_hdr.msg_namelen = cast,no_check(Socklen_T) (cast(u64) size_of(Sockaddr_In));
    }

    msg_hdr.msg_iov = cast(*Iovec) buffers;
    msg_hdr.msg_iovlen = buffer_count;

    sent_length := cast,no_check(s32) sendmsg(socket, *msg_hdr, cast,no_check(s32) (MSG_NOSIGNAL));

    if sent_length == -1 {
        if system_error_code().* == 11 {
            return 0;
        }

        return -1;
    }

    return sent_length;
}

socket_receive :: (socket: Socket, address: *Address, buffers: *Buffer, buffer_count: u64) -> s32 {
    msg_hdr: Msghdr = ---;
    sin: Sockaddr_In = ---;

    fill_memory(*msg_hdr, 0, size_of(Msghdr));

    if address != null {
        msg_hdr.msg_name = cast(*void) *sin;
        msg_hdr.msg_namelen = cast,no_check(Socklen_T) (cast(u64) size_of(Sockaddr_In));
    }

    msg_hdr.msg_iov = cast(*Iovec) buffers;
    msg_hdr.msg_iovlen = buffer_count;

    recv_length := cast,no_check(s32) recvmsg(socket, *msg_hdr, cast,no_check(s32) (MSG_NOSIGNAL));

    if recv_length == -1 {
        if system_error_code().* == {
            case 11;
                return 0;
            case 4; #through;
            case 90;
                return -2;
            case;
                return -1;
        }
    }

    if msg_hdr.msg_flags & cast,no_check(s32) (MSG_TRUNC) != 0 {
        return -2;
    }

    if address != null {
        address.host = sin.sin_addr.addr;
        address.port = ntohs(sin.sin_port);
    }

    return recv_length;
}

socket_wait :: (socket: Socket, condition: *Uint32, timeout: Uint32) -> s32 {
    poll_socket: C_Transpiler_POSIX.pollfd = ---;

    poll_socket.fd = socket;
    poll_socket.events = 0;

    if condition.* & cast,no_check(Uint32) SOCKET_WAIT_SEND != 0 {
        poll_socket.events = cast,no_check(s16) ((cast,no_check(s32) poll_socket.events) | 0x4);
    }

    if condition.* & cast,no_check(Uint32) SOCKET_WAIT_RECEIVE != 0 {
        poll_socket.events = cast,no_check(s16) ((cast,no_check(s32) poll_socket.events) | 0x1);
    }

    poll_count := poll(*poll_socket, 1, cast,no_check(s32) timeout);

    if poll_count < 0 {
        if system_error_code().* == 4 && condition.* & cast,no_check(Uint32) SOCKET_WAIT_INTERRUPT != 0 {
            condition.* = cast,no_check(Uint32) SOCKET_WAIT_INTERRUPT;

            return 0;
        }

        return -1;
    }

    condition.* = cast,no_check(Uint32) SOCKET_WAIT_NONE;

    if poll_count == 0 {
        return 0;
    }

    if poll_socket.revents & 0x4 != 0 {
        condition.* |= cast,no_check(Uint32) SOCKET_WAIT_SEND;
    }

    if poll_socket.revents & 0x1 != 0 {
        condition.* |= cast,no_check(Uint32) SOCKET_WAIT_RECEIVE;
    }

    return 0;
}

socket_set_option :: (socket: Socket, option: Socket_Option, value: s32) -> s32 {
    result: s32 = ---;
    time_val: C_Transpiler_POSIX.timeval = ---;
    time_val_2: C_Transpiler_POSIX.timeval = ---;
    code_block_to_execute: s64 = 37;
    while c_transpiler_dispatch := true {
        if code_block_to_execute < 0 break;
        if code_block_to_execute == {
            case 10; {
                if result == -1 {
                    return -1;
                }
                return 0;
            }
            case 37; {
                result = -1;
                c_transpiler_switch_value_37 := option;
                if c_transpiler_switch_value_37 == {
                    case cast,no_check(u32) SOCKOPT_NONBLOCK; {
                        result =
                            fcntl(
                                socket,
                                4,
                                (ifx value != 0 then cast(s32) 2048 else 0) | (fcntl(socket, 3) & ~(cast(s32) 2048))
                            );
                        code_block_to_execute = 10;
                        continue c_transpiler_dispatch;
                    }
                    case cast,no_check(u32) SOCKOPT_BROADCAST; {
                        result =
                            setsockopt(
                                socket,
                                1,
                                6,
                                cast(*void) (cast(*s8) *value),
                                cast,no_check(Socklen_T) (cast(u64) size_of(s32))
                            );
                        code_block_to_execute = 10;
                        continue c_transpiler_dispatch;
                    }
                    case cast,no_check(u32) SOCKOPT_REUSEADDR; {
                        result =
                            setsockopt(
                                socket,
                                1,
                                2,
                                cast(*void) (cast(*s8) *value),
                                cast,no_check(Socklen_T) (cast(u64) size_of(s32))
                            );
                        code_block_to_execute = 10;
                        continue c_transpiler_dispatch;
                    }
                    case cast,no_check(u32) SOCKOPT_RCVBUF; {
                        result =
                            setsockopt(
                                socket,
                                1,
                                8,
                                cast(*void) (cast(*s8) *value),
                                cast,no_check(Socklen_T) (cast(u64) size_of(s32))
                            );
                        code_block_to_execute = 10;
                        continue c_transpiler_dispatch;
                    }
                    case cast,no_check(u32) SOCKOPT_SNDBUF; {
                        result =
                            setsockopt(
                                socket,
                                1,
                                7,
                                cast(*void) (cast(*s8) *value),
                                cast,no_check(Socklen_T) (cast(u64) size_of(s32))
                            );
                        code_block_to_execute = 10;
                        continue c_transpiler_dispatch;
                    }
                    case cast,no_check(u32) SOCKOPT_RCVTIMEO; {
                        time_val.tv_sec = cast,no_check(Time_T) (value / 1000);
                        time_val.tv_usec = cast,no_check(Suseconds_T) ((value % 1000) * 1000);
                        result =
                            setsockopt(
                                socket,
                                1,
                                20,
                                cast(*void) (cast(*s8) *time_val),
                                cast,no_check(Socklen_T) (cast(u64) size_of(C_Transpiler_POSIX.timeval))
                            );
                        code_block_to_execute = 10;
                        continue c_transpiler_dispatch;
                    }
                    case cast,no_check(u32) SOCKOPT_SNDTIMEO; {
                        time_val_2.tv_sec = cast,no_check(Time_T) (value / 1000);
                        time_val_2.tv_usec = cast,no_check(Suseconds_T) ((value % 1000) * 1000);
                        result =
                            setsockopt(
                                socket,
                                1,
                                21,
                                cast(*void) (cast(*s8) *time_val_2),
                                cast,no_check(Socklen_T) (cast(u64) size_of(C_Transpiler_POSIX.timeval))
                            );
                        code_block_to_execute = 10;
                        continue c_transpiler_dispatch;
                    }
                    case cast,no_check(u32) SOCKOPT_NODELAY; {
                        result =
                            setsockopt(
                                socket,
                                cast,no_check(s32) (IPPROTO_TCP),
                                1,
                                cast(*void) (cast(*s8) *value),
                                cast,no_check(Socklen_T) (cast(u64) size_of(s32))
                            );
                        code_block_to_execute = 10;
                        continue c_transpiler_dispatch;
                    }
                    case cast,no_check(u32) SOCKOPT_TTL; {
                        result =
                            setsockopt(
                                socket,
                                cast,no_check(s32) (IPPROTO_IP),
                                2,
                                cast(*void) (cast(*s8) *value),
                                cast,no_check(Socklen_T) (cast(u64) size_of(s32))
                            );
                        code_block_to_execute = 10;
                        continue c_transpiler_dispatch;
                    }
                    case; {
                        code_block_to_execute = 10;
                        continue c_transpiler_dispatch;
                    }
                }
            }
        }
        assert(false, tprint("invalid code block to execute %", code_block_to_execute));
        break;
    }
    return unreachable_value(s32);
}

socket_get_option :: (socket: Socket, option: Socket_Option, value: *s32) -> s32 {
    result: s32 = -1;
    len: Socklen_T = ---;
    if option == {
        case cast,no_check(u32) SOCKOPT_ERROR;
            len = cast,no_check(Socklen_T) (cast(u64) size_of(s32));
            result = getsockopt(socket, 1, 4, cast(*void) value, *len);
        case cast,no_check(u32) SOCKOPT_TTL;
            len = cast,no_check(Socklen_T) (cast(u64) size_of(s32));
            result = getsockopt(socket, cast,no_check(s32) (IPPROTO_IP), 2, cast(*void) (cast(*s8) value), *len);
        case;
    }
    if result == -1 {
        return -1;
    }
    return 0;
}

socket_shutdown :: (socket: Socket, how: Socket_Shutdown) -> s32 {
    return shutdown(socket, cast,no_check(s32) how);
}

socket_destroy :: (socket: Socket) {
    if socket != -1 {
        close(socket);
    }
}

socketset_select :: (max_socket: Socket, read_set: *Socket_Set, write_set: *Socket_Set, timeout: Uint32) -> s32 {
    time_val: C_Transpiler_POSIX.timeval = ---;

    time_val.tv_sec = cast,no_check(Time_T) (timeout / 1000);
    time_val.tv_usec = cast,no_check(Suseconds_T) ((timeout % 1000) * 1000);

    return select(max_socket + 1, read_set, write_set, null, *time_val);
}

address_set_host_ip :: (address: *Address, name: *s8) -> s32 {
    if inet_pton(2, name, cast(*void) *address.host) == 0 {
        return -1;
    }

    return 0;
}

address_set_host :: (address: *Address, name: *s8) -> s32 {
    hints: Addrinfo = ---;
    result_list: *Addrinfo = null;
    result: *Addrinfo = null;

    fill_memory(*hints, 0, size_of(Addrinfo));
    hints.ai_family = 2;

    if getaddrinfo(name, null, null, *result_list) != 0 {
        return -1;
    }

    result = result_list;
    while result != null {
        if result.ai_family == 2 && result.ai_addr != null && cast,no_check(u64) result.ai_addrlen >= size_of(Sockaddr_In) {
            sin := cast(*Sockaddr_In) result.ai_addr;

            address.host = sin.sin_addr.addr;

            freeaddrinfo(result_list);

            return 0;
        }
        result = result.ai_next;
    }

    if result_list != null {
        freeaddrinfo(result_list);
    }

    return address_set_host_ip(address, name);
}

address_get_host_ip :: (address: *Address, name: *s8, name_length: u64) -> s32 {
    if inet_ntop(2, cast(*void) *address.host, name, cast,no_check(Socklen_T) name_length) == null {
        return -1;
    }
    return 0;
}

address_get_host :: (address: *Address, name: *s8, name_length: u64) -> s32 {
    sin: Sockaddr_In = ---;

    fill_memory(*sin, 0, size_of(Sockaddr_In));

    sin.sin_family = 2;
    sin.sin_port = htons(address.port);
    sin.sin_addr.addr = address.host;

    err :=
        getnameinfo(
            cast(*Sockaddr) *sin,
            cast,no_check(Socklen_T) (cast(u64) size_of(Sockaddr_In)),
            name,
            cast,no_check(Socklen_T) name_length,
            null,
            0,
            8
        );
    if err == 0 {
        if name != null && name_length > 0 && c_transpiler_memchr(cast(*void) name, 0, name_length) == null {
            return -1;
        }
        return 0;
    }
    if err != -2 {
        return -1;
    }

    return address_get_host_ip(address, name, name_length);
}

host_random_seed :: () -> Uint32 {
    return cast,no_check(Uint32) time(null);
}

globals_initialization_state_for_unix: u32;
initialize_globals_for_unix :: () {
    {
        state := atomic_load(*globals_initialization_state_for_unix);
        if state == 2 return;
        won, _ := compare_and_swap(*globals_initialization_state_for_unix, 0, 1);
        if !won {
            while atomic_load(*globals_initialization_state_for_unix) != 2 {}
            return;
        }
    }
    time_base = 0;
    atomic_store(*globals_initialization_state_for_unix, 2);
}

System_Library_Compiler :: #import "Compiler";
#run System_Library_Compiler.compiler_add_library_search_directory("/usr/lib");
System_Library_libc_so_6 :: #library,system "libc.so.6";
gettimeofday :: (tv: *C_Transpiler_POSIX.timeval, tz: *void) -> s32 #foreign System_Library_libc_so_6;

socket :: (domain: s32, type: s32, protocol: s32) -> s32 #foreign System_Library_libc_so_6;

bind :: (fd: s32, addr: CONST_SOCKADDR_ARG, len: Socklen_T) -> s32 #foreign System_Library_libc_so_6;

getsockname :: (fd: s32, addr: SOCKADDR_ARG, len: *Socklen_T) -> s32 #foreign System_Library_libc_so_6;

listen :: (fd: s32, n: s32) -> s32 #foreign System_Library_libc_so_6;

accept :: (fd: s32, addr: SOCKADDR_ARG, addr_len: *Socklen_T) -> s32 #foreign System_Library_libc_so_6;

connect :: (fd: s32, addr: CONST_SOCKADDR_ARG, len: Socklen_T) -> s32 #foreign System_Library_libc_so_6;

sendmsg :: (fd: s32, message: *Msghdr, flags: s32) -> s64 #foreign System_Library_libc_so_6;

recvmsg :: (fd: s32, message: *Msghdr, flags: s32) -> s64 #foreign System_Library_libc_so_6;

poll :: (fds: *C_Transpiler_POSIX.pollfd, nfds: Nfds_T, timeout: s32) -> s32 #foreign System_Library_libc_so_6;

fcntl :: (fd: s32, cmd: s32, variadic_arguments: ..Any) -> s32 #foreign System_Library_libc_so_6;

setsockopt :: (
    fd: s32,
    level: s32,
    optname: s32,
    optval: *void,
    optlen: Socklen_T
) -> s32 #foreign System_Library_libc_so_6;

getsockopt :: (
    fd: s32,
    level: s32,
    optname: s32,
    optval: *void,
    optlen: *Socklen_T
) -> s32 #foreign System_Library_libc_so_6;

shutdown :: (fd: s32, how: s32) -> s32 #foreign System_Library_libc_so_6;

close :: (fd: s32) -> s32 #foreign System_Library_libc_so_6;

select :: (
    nfds: s32,
    readfds: *Fd_Set,
    writefds: *Fd_Set,
    exceptfds: *Fd_Set,
    timeout: *C_Transpiler_POSIX.timeval
) -> s32 #foreign System_Library_libc_so_6;

inet_pton :: (af: s32, cp: *s8, buf: *void) -> s32 #foreign System_Library_libc_so_6;

getaddrinfo :: (name: *s8, service: *s8, req: *Addrinfo, pai: **Addrinfo) -> s32 #foreign System_Library_libc_so_6;

freeaddrinfo :: (ai: *Addrinfo) #foreign System_Library_libc_so_6;

inet_ntop :: (af: s32, cp: *void, buf: *s8, len: Socklen_T) -> *s8 #foreign System_Library_libc_so_6;

getnameinfo :: (
    sa: *Sockaddr,
    salen: Socklen_T,
    host: *s8,
    hostlen: Socklen_T,
    serv: *s8,
    servlen: Socklen_T,
    flags: s32
) -> s32 #foreign System_Library_libc_so_6;

time :: (timer: *Time_T) -> Time_T #foreign System_Library_libc_so_6;

Time_T :: s64;

Suseconds_T :: s64;

Socket_Type :: u32;
SOCK_STREAM : s32 : 1;
SOCK_DGRAM : s32 : 2;
SOCK_RAW : s32 : 3;
SOCK_RDM : s32 : 4;
SOCK_SEQPACKET : s32 : 5;
SOCK_DCCP : s32 : 6;
SOCK_PACKET : s32 : 10;
SOCK_CLOEXEC : s32 : 524288;
SOCK_NONBLOCK : s32 : 2048;

Sockaddr_In :: struct {
    sin_family: Sa_Family_T;
    sin_port: In_Port_T;
    sin_addr: In_Addr;
    sin_zero: [8] u8;
}

Sa_Family_T :: u16;

In_Port_T :: u16;

In_Addr_T :: u32;

CONST_SOCKADDR_ARG :: *Sockaddr;

Sockaddr :: struct {
    sa_family: Sa_Family_T;
    sa_data: [14] s8;
}

SOCKADDR_ARG :: *Sockaddr;

Msghdr :: struct {
    msg_name: *void;
    msg_namelen: Socklen_T;
    msg_iov: *Iovec;
    msg_iovlen: u64;
    msg_control: *void;
    msg_controllen: u64;
    msg_flags: s32;
}

Iovec :: struct {
    iov_base: *void;
    iov_len: u64;
}

MSG_Values :: u32;
MSG_OOB : s32 : 1;
MSG_PEEK : s32 : 2;
MSG_DONTROUTE : s32 : 4;
MSG_TRYHARD : s32 : 4;
MSG_CTRUNC : s32 : 8;
MSG_PROXY : s32 : 16;
MSG_TRUNC : s32 : 32;
MSG_DONTWAIT : s32 : 64;
MSG_EOR : s32 : 128;
MSG_WAITALL : s32 : 256;
MSG_FIN : s32 : 512;
MSG_SYN : s32 : 1024;
MSG_CONFIRM : s32 : 2048;
MSG_RST : s32 : 4096;
MSG_ERRQUEUE : s32 : 8192;
MSG_NOSIGNAL : s32 : 16384;
MSG_MORE : s32 : 32768;
MSG_WAITFORONE : s32 : 65536;
MSG_BATCH : s32 : 262144;
MSG_SOCK_DEVMEM : s32 : 33554432;
MSG_ZEROCOPY : s32 : 67108864;
MSG_FASTOPEN : s32 : 536870912;
MSG_CMSG_CLOEXEC : s32 : 1073741824;

Nfds_T :: u64;

IPPROTO_Values :: u32;
IPPROTO_IP : s32 : 0;
IPPROTO_ICMP : s32 : 1;
IPPROTO_IGMP : s32 : 2;
IPPROTO_IPIP : s32 : 4;
IPPROTO_TCP : s32 : 6;
IPPROTO_EGP : s32 : 8;
IPPROTO_PUP : s32 : 12;
IPPROTO_UDP : s32 : 17;
IPPROTO_IDP : s32 : 22;
IPPROTO_TP : s32 : 29;
IPPROTO_DCCP : s32 : 33;
IPPROTO_IPV6 : s32 : 41;
IPPROTO_RSVP : s32 : 46;
IPPROTO_GRE : s32 : 47;
IPPROTO_ESP : s32 : 50;
IPPROTO_AH : s32 : 51;
IPPROTO_MTP : s32 : 92;
IPPROTO_BEETPH : s32 : 94;
IPPROTO_ENCAP : s32 : 98;
IPPROTO_PIM : s32 : 103;
IPPROTO_COMP : s32 : 108;
IPPROTO_L2TP : s32 : 115;
IPPROTO_SCTP : s32 : 132;
IPPROTO_UDPLITE : s32 : 136;
IPPROTO_MPLS : s32 : 137;
IPPROTO_ETHERNET : s32 : 143;
IPPROTO_AGGFRAG : s32 : 144;
IPPROTO_RAW : s32 : 255;
IPPROTO_SMC : s32 : 256;
IPPROTO_MPTCP : s32 : 262;
IPPROTO_MAX : s32 : 263;

Socket_Set :: Fd_Set;

Addrinfo :: struct {
    ai_flags: s32;
    ai_family: s32;
    ai_socktype: s32;
    ai_protocol: s32;
    ai_addrlen: Socklen_T;
    ai_addr: *Sockaddr;
    ai_canonname: *s8;
    ai_next: *Addrinfo;
}

In_Addr :: struct {
    addr: In_Addr_T;
}

Socklen_T :: u32;

Socket_Shutdown :: u32;
SOCKET_SHUTDOWN_READ : s32 : 0;
SOCKET_SHUTDOWN_WRITE : s32 : 1;
SOCKET_SHUTDOWN_READ_WRITE : s32 : 2;

Fd_Set :: struct {
    fds_bits: [16] Fd_Mask;
}

Fd_Mask :: s64;

