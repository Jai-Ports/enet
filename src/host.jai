host_create :: (
    address: *Address,
    peer_count: u64,
    channel_limit: u64,
    incoming_bandwidth: Uint32,
    outgoing_bandwidth: Uint32
) -> *Host {
    if peer_count > cast,no_check(u64) PROTOCOL_MAXIMUM_PEER_ID {
        return null;
    }

    host := cast(*Host) allocate_memory(size_of(Host));
    if host == null {
        return null;
    }
    fill_memory(host, 0, size_of(Host));

    host.peers = cast(*Peer) allocate_memory(peer_count * size_of(Peer));
    if host.peers == null {
        deallocate_memory(cast(*void) host);

        return null;
    }
    fill_memory(host.peers, 0, peer_count * size_of(Peer));

    host.socket = socket_create(cast,no_check(Socket_Type_in_enet) SOCKET_TYPE_DATAGRAM);
    if host.socket == -1 || address != null && socket_bind(host.socket, address) < 0 {
        if host.socket != -1 {
            socket_destroy(host.socket);
        }

        deallocate_memory(cast(*void) host.peers);
        deallocate_memory(cast(*void) host);

        return null;
    }

    socket_set_option(host.socket, cast,no_check(Socket_Option) SOCKOPT_NONBLOCK, 1);
    socket_set_option(host.socket, cast,no_check(Socket_Option) SOCKOPT_BROADCAST, 1);
    socket_set_option(
        host.socket,
        cast,no_check(Socket_Option) SOCKOPT_RCVBUF,
        cast,no_check(s32) (HOST_RECEIVE_BUFFER_SIZE)
    );
    socket_set_option(
        host.socket,
        cast,no_check(Socket_Option) SOCKOPT_SNDBUF,
        cast,no_check(s32) (HOST_SEND_BUFFER_SIZE)
    );

    if address != null && socket_get_address(host.socket, *host.address) < 0 {
        host.address = address.*;
    }

    if channel_limit == 0 || channel_limit > cast,no_check(u64) PROTOCOL_MAXIMUM_CHANNEL_COUNT {
        channel_limit = cast,no_check(u64) PROTOCOL_MAXIMUM_CHANNEL_COUNT;
    } else if channel_limit < cast,no_check(u64) PROTOCOL_MINIMUM_CHANNEL_COUNT {
        channel_limit = cast,no_check(u64) PROTOCOL_MINIMUM_CHANNEL_COUNT;
    }

    host.random_seed = cast,no_check(Uint32) (cast,no_check(u64) host);
    host.random_seed += host_random_seed();
    host.random_seed = host.random_seed << 16 | (host.random_seed >> 16);
    host.channel_limit = channel_limit;
    host.incoming_bandwidth = incoming_bandwidth;
    host.outgoing_bandwidth = outgoing_bandwidth;
    host.bandwidth_throttle_epoch = 0;
    host.recalculate_bandwidth_limits = 0;
    host.mtu = cast,no_check(Uint32) HOST_DEFAULT_MTU;
    host.peer_count = peer_count;
    host.command_count = 0;
    host.buffer_count = 0;
    host.checksum = null;
    host.received_address.host = 0;
    host.received_address.port = 0;
    host.received_data = null;
    host.received_data_length = 0;

    host.total_sent_data = 0;
    host.total_sent_packets = 0;
    host.total_received_data = 0;
    host.total_received_packets = 0;
    host.total_queued = 0;

    host.connected_peers = 0;
    host.bandwidth_limited_peers = 0;
    host.duplicate_peers = cast,no_check(u64) PROTOCOL_MAXIMUM_PEER_ID;
    host.maximum_packet_size = cast,no_check(u64) HOST_DEFAULT_MAXIMUM_PACKET_SIZE;
    host.maximum_waiting_data = cast,no_check(u64) HOST_DEFAULT_MAXIMUM_WAITING_DATA;

    host.compressor.context_ = null;
    host.compressor.compress = null;
    host.compressor.decompress = null;
    host.compressor.destroy = null;

    host.intercept = null;

    list_clear(*host.dispatch_queue);

    current_peer := host.peers;
    while current_peer < *host.peers[host.peer_count] {
        current_peer.host = host;
        current_peer.incoming_peer_id = cast,no_check(Uint16) (current_peer - host.peers);
        current_peer.incoming_session_id = 0xff;
        current_peer.outgoing_session_id = current_peer.incoming_session_id;
        current_peer.data = null;

        list_clear(*current_peer.acknowledgements);
        list_clear(*current_peer.sent_reliable_commands);
        list_clear(*current_peer.outgoing_commands);
        list_clear(*current_peer.outgoing_send_reliable_commands);
        list_clear(*current_peer.dispatched_commands);

        peer_reset(current_peer);
        current_peer += 1;
    }

    return host;
}

host_destroy :: (host: *Host) {
    if host == null {
        return;
    }

    socket_destroy(host.socket);

    current_peer := host.peers;
    while current_peer < *host.peers[host.peer_count] {
        peer_reset(current_peer);
        current_peer += 1;
    }

    if host.compressor.context_ != null && host.compressor.destroy != null {
        host.compressor.destroy(host.compressor.context_);
    }

    deallocate_memory(cast(*void) host.peers);
    deallocate_memory(cast(*void) host);
}

host_connect :: (host: *Host, address: *Address, channel_count: u64, data: Uint32) -> *Peer {
    command: Protocol = ---;

    if channel_count < cast,no_check(u64) PROTOCOL_MINIMUM_CHANNEL_COUNT {
        channel_count = cast,no_check(u64) PROTOCOL_MINIMUM_CHANNEL_COUNT;
    } else if channel_count > cast,no_check(u64) PROTOCOL_MAXIMUM_CHANNEL_COUNT {
        channel_count = cast,no_check(u64) PROTOCOL_MAXIMUM_CHANNEL_COUNT;
    }

    current_peer := host.peers;
    while current_peer < *host.peers[host.peer_count] {
        if current_peer.state == cast,no_check(u32) PEER_STATE_DISCONNECTED {
            break;
        }
        current_peer += 1;
    }

    if current_peer >= *host.peers[host.peer_count] {
        return null;
    }

    current_peer.channels = cast(*Channel) allocate_memory(channel_count * size_of(Channel));
    if current_peer.channels == null {
        return null;
    }
    current_peer.channel_count = channel_count;
    current_peer.state = cast,no_check(Peer_State) PEER_STATE_CONNECTING;
    current_peer.address = address.*;
    current_peer.connect_id = host_random(host);
    current_peer.mtu = host.mtu;

    if host.outgoing_bandwidth == 0 {
        current_peer.window_size = cast,no_check(Uint32) PROTOCOL_MAXIMUM_WINDOW_SIZE;
    } else {
        current_peer.window_size =
            (host.outgoing_bandwidth / cast,no_check(Uint32) PEER_WINDOW_SIZE_SCALE) *
                cast,no_check(Uint32) PROTOCOL_MINIMUM_WINDOW_SIZE;
    }

    if current_peer.window_size < cast,no_check(Uint32) PROTOCOL_MINIMUM_WINDOW_SIZE {
        current_peer.window_size = cast,no_check(Uint32) PROTOCOL_MINIMUM_WINDOW_SIZE;
    } else if current_peer.window_size > cast,no_check(Uint32) PROTOCOL_MAXIMUM_WINDOW_SIZE {
        current_peer.window_size = cast,no_check(Uint32) PROTOCOL_MAXIMUM_WINDOW_SIZE;
    }

    channel := current_peer.channels;
    while channel < *current_peer.channels[channel_count] {
        channel.outgoing_reliable_sequence_number = 0;
        channel.outgoing_unreliable_sequence_number = 0;
        channel.incoming_reliable_sequence_number = 0;
        channel.incoming_unreliable_sequence_number = 0;

        list_clear(*channel.incoming_reliable_commands);
        list_clear(*channel.incoming_unreliable_commands);

        channel.used_reliable_windows = 0;
        fill_memory(channel.reliable_windows.data, 0, channel.reliable_windows.count * size_of(Uint16));
        channel += 1;
    }

    command.header.command =
        cast,no_check(Uint8) ((cast,no_check(s32) (PROTOCOL_COMMAND_CONNECT)) | cast,no_check(s32) (PROTOCOL_COMMAND_FLAG_ACKNOWLEDGE));
    command.header.channel_id = 0xff;
    command.connect.outgoing_peer_id = htons(current_peer.incoming_peer_id);
    command.connect.incoming_session_id = current_peer.incoming_session_id;
    command.connect.outgoing_session_id = current_peer.outgoing_session_id;
    command.connect.mtu = htonl(current_peer.mtu);
    command.connect.window_size = htonl(current_peer.window_size);
    command.connect.channel_count = htonl(cast,no_check(u32) channel_count);
    command.connect.incoming_bandwidth = htonl(host.incoming_bandwidth);
    command.connect.outgoing_bandwidth = htonl(host.outgoing_bandwidth);
    command.connect.packet_throttle_interval = htonl(current_peer.packet_throttle_interval);
    command.connect.packet_throttle_acceleration = htonl(current_peer.packet_throttle_acceleration);
    command.connect.packet_throttle_deceleration = htonl(current_peer.packet_throttle_deceleration);
    command.connect.connect_id = current_peer.connect_id;
    command.connect.data = htonl(data);

    peer_queue_outgoing_command(current_peer, *command, null, 0, 0);

    return current_peer;
}

host_random :: (host: *Host) -> Uint32 {
    n := c_transpiler_compound_add(*(host.random_seed), (cast(u32) 0x6d2b79f5), u32, u32);
    n = n ^ (n >> 15) * n | 1;
    n ^= n + n ^ (n >> 7) * n | 61;
    return n ^ (n >> 14);
}

host_broadcast :: (host: *Host, channel_id: Uint8, packet: *Packet) {
    current_peer := host.peers;
    while current_peer < *host.peers[host.peer_count] {
        if current_peer.state != cast,no_check(u32) PEER_STATE_CONNECTED {
            current_peer += 1;
            continue;
        }

        peer_send(current_peer, channel_id, packet);
        current_peer += 1;
    }

    if packet.reference_count == 0 {
        packet_destroy(packet);
    }
}

host_compress :: (host: *Host, compressor: *Compressor) {
    if host.compressor.context_ != null && host.compressor.destroy != null {
        host.compressor.destroy(host.compressor.context_);
    }

    if compressor != null {
        host.compressor = compressor.*;
    } else {
        host.compressor.context_ = null;
    }
}

host_channel_limit :: (host: *Host, channel_limit: u64) {
    if channel_limit == 0 || channel_limit > cast,no_check(u64) PROTOCOL_MAXIMUM_CHANNEL_COUNT {
        channel_limit = cast,no_check(u64) PROTOCOL_MAXIMUM_CHANNEL_COUNT;
    } else if channel_limit < cast,no_check(u64) PROTOCOL_MINIMUM_CHANNEL_COUNT {
        channel_limit = cast,no_check(u64) PROTOCOL_MINIMUM_CHANNEL_COUNT;
    }

    host.channel_limit = channel_limit;
}

host_bandwidth_limit :: (host: *Host, incoming_bandwidth: Uint32, outgoing_bandwidth: Uint32) {
    host.incoming_bandwidth = incoming_bandwidth;
    host.outgoing_bandwidth = outgoing_bandwidth;
    host.recalculate_bandwidth_limits = 1;
}

host_bandwidth_throttle :: (host: *Host) {
    time_current := time_get();
    elapsed_time := time_current - host.bandwidth_throttle_epoch;
    peers_remaining := cast,no_check(Uint32) host.connected_peers;
    data_total: Uint32 = 0xffffffff;
    bandwidth: Uint32 = 0xffffffff;
    throttle: Uint32 = 0;
    bandwidth_limit: Uint32 = 0;
    needs_adjustment := cast(s32) (host.bandwidth_limited_peers > 0);
    peer: *Peer = ---;
    command: Protocol = ---;

    if elapsed_time < cast,no_check(Uint32) HOST_BANDWIDTH_THROTTLE_INTERVAL {
        return;
    }

    host.bandwidth_throttle_epoch = time_current;

    if peers_remaining == 0 {
        return;
    }

    if host.outgoing_bandwidth != 0 {
        data_total = 0;
        bandwidth = host.outgoing_bandwidth * elapsed_time / 1000;

        peer = host.peers;
        while peer < *host.peers[host.peer_count] {
            if peer.state != cast,no_check(u32) PEER_STATE_CONNECTED && peer.state != cast,no_check(u32) PEER_STATE_DISCONNECT_LATER {
                peer += 1;
                continue;
            }

            data_total += peer.outgoing_data_total;
            peer += 1;
        }
    }

    while peers_remaining > 0 && needs_adjustment != 0 {
        needs_adjustment = 0;

        if data_total <= bandwidth {
            throttle = cast,no_check(Uint32) PEER_PACKET_THROTTLE_SCALE;
        } else {
            throttle = (bandwidth * cast,no_check(Uint32) PEER_PACKET_THROTTLE_SCALE) / data_total;
        }

        peer = host.peers;
        while peer < *host.peers[host.peer_count] {
            if peer.state != cast,no_check(u32) PEER_STATE_CONNECTED && peer.state != cast,no_check(u32) PEER_STATE_DISCONNECT_LATER ||
                peer.incoming_bandwidth == 0 ||
                peer.outgoing_bandwidth_throttle_epoch == time_current {
                peer += 1;
                continue;
            }

            peer_bandwidth := peer.incoming_bandwidth * elapsed_time / 1000;
            if (throttle * peer.outgoing_data_total / cast,no_check(Uint32) PEER_PACKET_THROTTLE_SCALE) <= peer_bandwidth {
                peer += 1;
                continue;
            }

            peer.packet_throttle_limit =
                (peer_bandwidth * cast,no_check(Uint32) PEER_PACKET_THROTTLE_SCALE) /
                    peer.outgoing_data_total;

            if peer.packet_throttle_limit == 0 {
                peer.packet_throttle_limit = 1;
            }

            if peer.packet_throttle > peer.packet_throttle_limit {
                peer.packet_throttle = peer.packet_throttle_limit;
            }

            peer.outgoing_bandwidth_throttle_epoch = time_current;

            peer.incoming_data_total = 0;
            peer.outgoing_data_total = 0;

            needs_adjustment = 1;
            peers_remaining -= 1;
            bandwidth -= peer_bandwidth;
            data_total -= peer_bandwidth;
            peer += 1;
        }
    }

    if peers_remaining > 0 {
        if data_total <= bandwidth {
            throttle = cast,no_check(Uint32) PEER_PACKET_THROTTLE_SCALE;
        } else {
            throttle = (bandwidth * cast,no_check(Uint32) PEER_PACKET_THROTTLE_SCALE) / data_total;
        }

        peer = host.peers;
        while peer < *host.peers[host.peer_count] {
            if peer.state != cast,no_check(u32) PEER_STATE_CONNECTED && peer.state != cast,no_check(u32) PEER_STATE_DISCONNECT_LATER ||
                peer.outgoing_bandwidth_throttle_epoch == time_current {
                peer += 1;
                continue;
            }

            peer.packet_throttle_limit = throttle;

            if peer.packet_throttle > peer.packet_throttle_limit {
                peer.packet_throttle = peer.packet_throttle_limit;
            }

            peer.incoming_data_total = 0;
            peer.outgoing_data_total = 0;
            peer += 1;
        }
    }

    if host.recalculate_bandwidth_limits != 0 {
        host.recalculate_bandwidth_limits = 0;

        peers_remaining = cast,no_check(Uint32) host.connected_peers;
        bandwidth = host.incoming_bandwidth;
        needs_adjustment = 1;

        if bandwidth == 0 {
            bandwidth_limit = 0;
        } else {
            while peers_remaining > 0 && needs_adjustment != 0 {
                needs_adjustment = 0;
                bandwidth_limit = bandwidth / peers_remaining;

                peer = host.peers;
                while peer < *host.peers[host.peer_count] {
                    if peer.state != cast,no_check(u32) PEER_STATE_CONNECTED && peer.state != cast,no_check(u32) PEER_STATE_DISCONNECT_LATER ||
                        peer.incoming_bandwidth_throttle_epoch == time_current {
                        peer += 1;
                        continue;
                    }

                    if peer.outgoing_bandwidth > 0 && peer.outgoing_bandwidth >= bandwidth_limit {
                        peer += 1;
                        continue;
                    }

                    peer.incoming_bandwidth_throttle_epoch = time_current;

                    needs_adjustment = 1;
                    peers_remaining -= 1;
                    bandwidth -= peer.outgoing_bandwidth;
                    peer += 1;
                }
            }
        }

        peer = host.peers;
        while peer < *host.peers[host.peer_count] {
            if peer.state != cast,no_check(u32) PEER_STATE_CONNECTED && peer.state != cast,no_check(u32) PEER_STATE_DISCONNECT_LATER {
                peer += 1;
                continue;
            }

            command.header.command =
                cast,no_check(Uint8) ((cast,no_check(s32) (PROTOCOL_COMMAND_BANDWIDTH_LIMIT)) | cast,no_check(s32) (PROTOCOL_COMMAND_FLAG_ACKNOWLEDGE));
            command.header.channel_id = 0xff;
            command.bandwidth_limit.outgoing_bandwidth = htonl(host.outgoing_bandwidth);

            if peer.incoming_bandwidth_throttle_epoch == time_current {
                command.bandwidth_limit.incoming_bandwidth = htonl(peer.outgoing_bandwidth);
            } else {
                command.bandwidth_limit.incoming_bandwidth = htonl(bandwidth_limit);
            }

            peer_queue_outgoing_command(peer, *command, null, 0, 0);
            peer += 1;
        }
    }
}

htons :: (hostshort: u16) -> u16 {
    return C_Transpiler_Bit_Operations.byte_swap(hostshort);
}

htonl :: (hostlong: u32) -> u32 {
    return C_Transpiler_Bit_Operations.byte_swap(hostlong);
}

Values :: u32;
PROTOCOL_MINIMUM_MTU : s32 : 576;
PROTOCOL_MAXIMUM_MTU : s32 : 4096;
PROTOCOL_MAXIMUM_PACKET_COMMANDS : s32 : 32;
PROTOCOL_MINIMUM_WINDOW_SIZE : s32 : 4096;
PROTOCOL_MAXIMUM_WINDOW_SIZE : s32 : 65536;
PROTOCOL_MINIMUM_CHANNEL_COUNT : s32 : 1;
PROTOCOL_MAXIMUM_CHANNEL_COUNT : s32 : 255;
PROTOCOL_MAXIMUM_PEER_ID : s32 : 4095;
PROTOCOL_MAXIMUM_FRAGMENT_COUNT : s32 : 1048576;

Socket_Type_in_enet :: u32;
SOCKET_TYPE_STREAM : s32 : 1;
SOCKET_TYPE_DATAGRAM : s32 : 2;

Socket_Option :: u32;
SOCKOPT_NONBLOCK : s32 : 1;
SOCKOPT_BROADCAST : s32 : 2;
SOCKOPT_RCVBUF : s32 : 3;
SOCKOPT_SNDBUF : s32 : 4;
SOCKOPT_REUSEADDR : s32 : 5;
SOCKOPT_RCVTIMEO : s32 : 6;
SOCKOPT_SNDTIMEO : s32 : 7;
SOCKOPT_ERROR : s32 : 8;
SOCKOPT_NODELAY : s32 : 9;
SOCKOPT_TTL : s32 : 10;

Values_in_callbacks :: u32;
HOST_RECEIVE_BUFFER_SIZE : s32 : 262144;
HOST_SEND_BUFFER_SIZE : s32 : 262144;
HOST_BANDWIDTH_THROTTLE_INTERVAL : s32 : 1000;
HOST_DEFAULT_MTU : s32 : 1392;
HOST_DEFAULT_MAXIMUM_PACKET_SIZE : s32 : 33554432;
HOST_DEFAULT_MAXIMUM_WAITING_DATA : s32 : 33554432;
PEER_DEFAULT_ROUND_TRIP_TIME : s32 : 500;
PEER_DEFAULT_PACKET_THROTTLE : s32 : 32;
PEER_PACKET_THROTTLE_SCALE : s32 : 32;
PEER_PACKET_THROTTLE_COUNTER : s32 : 7;
PEER_PACKET_THROTTLE_ACCELERATION : s32 : 2;
PEER_PACKET_THROTTLE_DECELERATION : s32 : 2;
PEER_PACKET_THROTTLE_INTERVAL : s32 : 5000;
PEER_PACKET_LOSS_SCALE : s32 : 65536;
PEER_PACKET_LOSS_INTERVAL : s32 : 10000;
PEER_WINDOW_SIZE_SCALE : s32 : 65536;
PEER_TIMEOUT_LIMIT : s32 : 32;
PEER_TIMEOUT_MINIMUM : s32 : 5000;
PEER_TIMEOUT_MAXIMUM : s32 : 30000;
PEER_PING_INTERVAL : s32 : 500;
PEER_UNSEQUENCED_WINDOWS : s32 : 64;
PEER_UNSEQUENCED_WINDOW_SIZE : s32 : 1024;
PEER_FREE_UNSEQUENCED_WINDOWS : s32 : 32;
PEER_RELIABLE_WINDOWS : s32 : 16;
PEER_RELIABLE_WINDOW_SIZE : s32 : 4096;
PEER_FREE_RELIABLE_WINDOWS : s32 : 8;

Protocol_Command :: u32;
PROTOCOL_COMMAND_NONE : s32 : 0;
PROTOCOL_COMMAND_ACKNOWLEDGE : s32 : 1;
PROTOCOL_COMMAND_CONNECT : s32 : 2;
PROTOCOL_COMMAND_VERIFY_CONNECT : s32 : 3;
PROTOCOL_COMMAND_DISCONNECT : s32 : 4;
PROTOCOL_COMMAND_PING : s32 : 5;
PROTOCOL_COMMAND_SEND_RELIABLE : s32 : 6;
PROTOCOL_COMMAND_SEND_UNRELIABLE : s32 : 7;
PROTOCOL_COMMAND_SEND_FRAGMENT : s32 : 8;
PROTOCOL_COMMAND_SEND_UNSEQUENCED : s32 : 9;
PROTOCOL_COMMAND_BANDWIDTH_LIMIT : s32 : 10;
PROTOCOL_COMMAND_THROTTLE_CONFIGURE : s32 : 11;
PROTOCOL_COMMAND_SEND_UNRELIABLE_FRAGMENT : s32 : 12;
PROTOCOL_COMMAND_COUNT : s32 : 13;
PROTOCOL_COMMAND_MASK : s32 : 15;

Protocol_Flag :: u32;
PROTOCOL_COMMAND_FLAG_ACKNOWLEDGE : s32 : 128;
PROTOCOL_COMMAND_FLAG_UNSEQUENCED : s32 : 64;
PROTOCOL_HEADER_FLAG_COMPRESSED : s32 : 16384;
PROTOCOL_HEADER_FLAG_SENT_TIME : s32 : 32768;
PROTOCOL_HEADER_FLAG_MASK : s32 : 49152;
PROTOCOL_HEADER_SESSION_MASK : s32 : 12288;
PROTOCOL_HEADER_SESSION_SHIFT : s32 : 12;

Outgoing_Command :: struct {
    outgoing_command_list: List_Node #align 8;
    reliable_sequence_number: Uint16 #align 1;
    unreliable_sequence_number: Uint16 #align 1;
    sent_time: Uint32 #align 1;
    round_trip_timeout: Uint32 #align 1;
    queue_time: Uint32 #align 1;
    fragment_offset: Uint32 #align 1;
    fragment_length: Uint16 #align 1;
    send_attempts: Uint16 #align 1;
    command: Protocol #align 1;
    packet: *Packet #align 1;
} #no_padding;

