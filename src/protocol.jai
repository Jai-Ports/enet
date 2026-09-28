COMMAND_SIZES: [13] u64;

host_check_events :: (host: *Host, event: *Event) -> s32 {
    if event == null {
        return -1;
    }

    event.type = cast,no_check(Event_Type) EVENT_TYPE_NONE;
    event.peer = null;
    event.packet = null;

    return protocol_dispatch_incoming_commands(host, event);
}

protocol_dispatch_incoming_commands :: (host: *Host, event: *Event) -> s32 {
    while !(host.dispatch_queue.sentinel.next == *(host.dispatch_queue.sentinel)) {
        peer := cast(*Peer) list_remove(host.dispatch_queue.sentinel.next);

        peer.flags = cast,no_check(Uint16) ((cast,no_check(s32) peer.flags) & cast,no_check(s32) (~(PEER_FLAG_NEEDS_DISPATCH)));

        if peer.state == {
            case cast,no_check(u32) PEER_STATE_CONNECTION_PENDING; #through;
            case cast,no_check(u32) PEER_STATE_CONNECTION_SUCCEEDED;
                protocol_change_state(host, peer, cast,no_check(Peer_State) PEER_STATE_CONNECTED);
                event.type = cast,no_check(Event_Type) EVENT_TYPE_CONNECT;
                event.peer = peer;
                event.data = peer.event_data;
                return 1;
            case cast,no_check(u32) PEER_STATE_ZOMBIE;
                host.recalculate_bandwidth_limits = 1;
                event.type = cast,no_check(Event_Type) EVENT_TYPE_DISCONNECT;
                event.peer = peer;
                event.data = peer.event_data;
                peer_reset(peer);
                return 1;
            case cast,no_check(u32) PEER_STATE_CONNECTED;
                if peer.dispatched_commands.sentinel.next == *(peer.dispatched_commands.sentinel) {
                    continue;
                }
                event.packet = peer_receive(peer, *event.channel_id);
                if event.packet == null {
                    continue;
                }
                event.type = cast,no_check(Event_Type) EVENT_TYPE_RECEIVE;
                event.peer = peer;
                if !(peer.dispatched_commands.sentinel.next == *(peer.dispatched_commands.sentinel)) {
                    peer.flags = cast,no_check(Uint16) ((cast,no_check(s32) peer.flags) | cast,no_check(s32) (PEER_FLAG_NEEDS_DISPATCH));

                    list_insert(*(host.dispatch_queue.sentinel), cast(*void) *peer.dispatch_list);
                }
                return 1;
            case;
        }
    }

    return 0;
}

protocol_change_state :: (host: *Host, peer: *Peer, state: Peer_State) {
    if state == cast,no_check(u32) PEER_STATE_CONNECTED || state == cast,no_check(u32) PEER_STATE_DISCONNECT_LATER {
        peer_on_connect(peer);
    } else {
        peer_on_disconnect(peer);
    }

    peer.state = state;
}

host_service :: (host: *Host, event: *Event, timeout: Uint32) -> s32 {
    wait_condition: Uint32 = ---;

    if event != null {
        event.type = cast,no_check(Event_Type) EVENT_TYPE_NONE;
        event.peer = null;
        event.packet = null;

        if protocol_dispatch_incoming_commands(host, event) == {
            case 1;
                return 1;
            case -1;
                return -1;
            case;
        }
    }

    host.service_time = time_get();

    timeout += host.service_time;

    while true {
        if (ifx host.service_time - host.bandwidth_throttle_epoch >= 86400000 then host.bandwidth_throttle_epoch - host.service_time else host.service_time - host.bandwidth_throttle_epoch) >= cast,no_check(Uint32) HOST_BANDWIDTH_THROTTLE_INTERVAL {
            host_bandwidth_throttle(host);
        }

        if protocol_send_outgoing_commands(host, event, 1) == {
            case 1;
                return 1;
            case -1;
                return -1;
            case;
        }

        if protocol_receive_incoming_commands(host, event) == {
            case 1;
                return 1;
            case -1;
                return -1;
            case;
        }

        if protocol_send_outgoing_commands(host, event, 1) == {
            case 1;
                return 1;
            case -1;
                return -1;
            case;
        }

        if event != null {
            if protocol_dispatch_incoming_commands(host, event) == {
                case 1;
                    return 1;
                case -1;
                    return -1;
                case;
            }
        }

        if !(host.service_time - timeout >= 86400000) {
            return 0;
        }

        while true {
            host.service_time = time_get();

            if !(host.service_time - timeout >= 86400000) {
                return 0;
            }

            wait_condition =
                cast,no_check(Uint32) ((cast,no_check(s32) (SOCKET_WAIT_RECEIVE)) | cast,no_check(s32) (SOCKET_WAIT_INTERRUPT));

            if socket_wait(
                host.socket,
                *wait_condition,
                (ifx timeout - host.service_time >= 86400000 then host.service_time -
                timeout else timeout - host.service_time)
            ) != 0 {
                return -1;
            }
            if wait_condition & cast,no_check(Uint32) SOCKET_WAIT_INTERRUPT == 0 break;
        }

        host.service_time = time_get();
        if wait_condition & cast,no_check(Uint32) SOCKET_WAIT_RECEIVE == 0 break;
    }

    return 0;
}

protocol_send_outgoing_commands :: (host: *Host, event: *Event, check_for_timeouts: s32) -> s32 {
    header_data: [8] Uint8 = ---;
    header := cast(*Protocol_Header) header_data.data;
    sent_length: s32 = 0;
    should_compress: u64 = 0;
    sent_unreliable_commands: List = ---;

    list_clear(*sent_unreliable_commands);

    {
        send_pass: s32 = 0;
        continue_sending: s32 = 0;
        while send_pass <= continue_sending {
            {
                current_peer := host.peers;
                while loop := current_peer < *host.peers[host.peer_count] {
                    if current_peer.state == cast,no_check(u32) PEER_STATE_DISCONNECTED ||
                        current_peer.state == cast,no_check(u32) PEER_STATE_ZOMBIE ||
                        send_pass > 0 && (cast(s32) current_peer.flags) & cast,no_check(s32) (PEER_FLAG_CONTINUE_SENDING) == 0 {
                        current_peer += 1;
                        continue;
                    }
                    current_peer.flags = cast,no_check(Uint16) ((cast,no_check(s32) current_peer.flags) & cast,no_check(s32) (~(PEER_FLAG_CONTINUE_SENDING)));
                    host.header_flags = 0;
                    host.command_count = 0;
                    host.buffer_count = 1;
                    host.packet_size = cast(u64) size_of(Protocol_Header);
                    if !(current_peer.acknowledgements.sentinel.next == *(current_peer.acknowledgements.sentinel)) {
                        protocol_send_acknowledgements(host, current_peer);
                    }
                    while next_peer := true { // Forward-goto shim; executes at most once.
                        if check_for_timeouts != 0 &&
                            !(current_peer.sent_reliable_commands.sentinel.next == *(current_peer.sent_reliable_commands.sentinel)) &&
                            !(host.service_time - current_peer.next_timeout >= 86400000) &&
                            protocol_check_timeouts(host, current_peer, event) == 1 {
                            if event != null && event.type != cast,no_check(u32) EVENT_TYPE_NONE {
                                return 1;
                            } else {
                                break next_peer;
                            }
                        }
                        if (current_peer.outgoing_commands.sentinel.next == *(current_peer.outgoing_commands.sentinel) &&
                            current_peer.outgoing_send_reliable_commands.sentinel.next == *(current_peer.outgoing_send_reliable_commands.sentinel) ||
                            protocol_check_outgoing_commands(host, current_peer, *sent_unreliable_commands) != 0) &&
                            current_peer.sent_reliable_commands.sentinel.next == *(current_peer.sent_reliable_commands.sentinel) &&
                            (ifx host.service_time - current_peer.last_receive_time >= 86400000 then current_peer.last_receive_time - host.service_time else host.service_time - current_peer.last_receive_time) >= current_peer.ping_interval &&
                            (cast(u64) current_peer.mtu) - host.packet_size >= size_of(Protocol_Ping) {
                            peer_ping(current_peer);
                            protocol_check_outgoing_commands(host, current_peer, *sent_unreliable_commands);
                        }
                        if host.command_count == 0 {
                            break next_peer;
                        }
                        if current_peer.packet_loss_epoch == 0 {
                            current_peer.packet_loss_epoch = host.service_time;
                        } else if (ifx host.service_time - current_peer.packet_loss_epoch >= 86400000 then current_peer.packet_loss_epoch - host.service_time else host.service_time - current_peer.packet_loss_epoch) >= cast,no_check(Uint32) PEER_PACKET_LOSS_INTERVAL &&
                            current_peer.packets_sent > 0 {
                            packet_loss :=
                                (current_peer.packets_lost * cast,no_check(Uint32) PEER_PACKET_LOSS_SCALE) /
                                    current_peer.packets_sent;

                            current_peer.packet_loss_variance =
                                ((current_peer.packet_loss_variance * 3) + (ifx packet_loss < current_peer.packet_loss then current_peer.packet_loss - packet_loss else packet_loss - current_peer.packet_loss)) /
                                    4;
                            current_peer.packet_loss = ((current_peer.packet_loss * 7) + packet_loss) / 8;

                            current_peer.packet_loss_epoch = host.service_time;
                            current_peer.packets_sent = 0;
                            current_peer.packets_lost = 0;
                        }
                        assignment_0: *void = cast(*void) header_data.data;
                        (host.buffers[0].data) = assignment_0;
                        if host.header_flags & PROTOCOL_HEADER_FLAG_SENT_TIME != 0 {
                            header.sent_time = htons(cast,no_check(u16) (host.service_time & 0xffff));

                            assignment_1: u64 = cast(u64) size_of(Protocol_Header);
                            (host.buffers[0].data_length) = assignment_1;
                        } else {
                            assignment_2: u64 = cast(u64) 2;
                            (host.buffers[0].data_length) = assignment_2;
                        }
                        should_compress = 0;
                        if host.compressor.context_ != null && host.compressor.compress != null {
                            original_size := host.packet_size - size_of(Protocol_Header);
                            compressed_size :=
                                host.compressor.compress(
                                    host.compressor.context_,
                                    host.buffers.data + 1,
                                    host.buffer_count - 1,
                                    original_size,
                                    host.packet_data[1].data,
                                    original_size
                                );
                            if compressed_size > 0 && compressed_size < original_size {
                                host.header_flags = cast,no_check(Uint16) ((cast,no_check(s32) host.header_flags) | cast,no_check(s32) (PROTOCOL_HEADER_FLAG_COMPRESSED));
                                should_compress = compressed_size;
                            }
                        }
                        if current_peer.outgoing_peer_id < cast,no_check(Uint16) PROTOCOL_MAXIMUM_PEER_ID {
                            host.header_flags = cast,no_check(Uint16) ((cast,no_check(s32) host.header_flags) | ((cast(s32) current_peer.outgoing_session_id) << ((PROTOCOL_HEADER_SESSION_SHIFT) & 31)));
                        }
                        header.peer_id =
                            htons(
                                cast,no_check(u16) ((cast(s32) current_peer.outgoing_peer_id) | cast(s32) host.header_flags)
                            );
                        if host.checksum != null {
                            checksum := cast(*Uint32) (header_data.data + host.buffers[0].data_length);
                            new_checksum :=
                                (ifx current_peer.outgoing_peer_id < cast,no_check(Uint16) PROTOCOL_MAXIMUM_PEER_ID then current_peer.connect_id else 0);

                            copy_memory(checksum, *new_checksum, size_of(Uint32));
                            c_transpiler_compound_add(*(host.buffers[0].data_length), (cast(u64) size_of(Uint32)), u64, u64);
                            new_checksum = host.checksum(host.buffers.data, host.buffer_count);
                            copy_memory(checksum, *new_checksum, size_of(Uint32));
                        }
                        if should_compress > 0 {
                            host.buffers[1].data = cast(*void) host.packet_data[1].data;
                            host.buffers[1].data_length = should_compress;
                            host.buffer_count = 2;
                        }
                        current_peer.last_send_time = host.service_time;
                        sent_length =
                            (cast,no_check(#type (_: Socket, _: *Address, _: *Buffer, _: u64) -> s32) (cast(*void) socket_send))(
                                host.socket,
                                *current_peer.address,
                                host.buffers.data,
                                host.buffer_count
                            );
                        protocol_remove_sent_unreliable_commands(current_peer, *sent_unreliable_commands);
                        if sent_length < 0 {
                            return -1;
                        }
                        host.total_sent_data += cast,no_check(Uint32) sent_length;
                        host.total_sent_packets += 1;
                        break next_peer;
                    }
                    if current_peer.flags & PEER_FLAG_CONTINUE_SENDING != 0 {
                        continue_sending = send_pass + 1;
                    }
                    current_peer += 1;
                }
            }
            send_pass += 1;
        }
    }

    return 0;
}

protocol_remove_sent_unreliable_commands :: (peer: *Peer, sent_unreliable_commands: *List) {
    outgoing_command: *Outgoing_Command = ---;

    if sent_unreliable_commands.sentinel.next == *sent_unreliable_commands.sentinel {
        return;
    }

    while true {
        outgoing_command = cast(*Outgoing_Command) (cast(*void) sent_unreliable_commands.sentinel.next);

        list_remove(*outgoing_command.outgoing_command_list);

        if outgoing_command.packet != null {
            outgoing_command.packet.reference_count -= 1;

            if outgoing_command.packet.reference_count == 0 {
                outgoing_command.packet.flags |= cast,no_check(Uint32) PACKET_FLAG_SENT;

                packet_destroy(outgoing_command.packet);
            }
        }

        deallocate_memory(cast(*void) outgoing_command);
        if sent_unreliable_commands.sentinel.next == *sent_unreliable_commands.sentinel break;
    }

    if peer.state == cast,no_check(u32) PEER_STATE_DISCONNECT_LATER && peer_has_outgoing_commands(peer) == 0 {
        peer_disconnect(peer, peer.event_data);
    }
}

protocol_check_outgoing_commands :: (host: *Host, peer: *Peer, sent_unreliable_commands: *List) -> s32 {
    command := host.commands.data + host.command_count;
    buffer := host.buffers.data + host.buffer_count;
    outgoing_command: *Outgoing_Command = ---;
    current_command, current_send_reliable_command: List_Iterator = ---;
    channel: *Channel = null;
    reliable_window: Uint16 = 0;
    command_size: u64 = ---;
    window_wrap: s32 = 0;
    can_ping: s32 = 1;

    current_command = peer.outgoing_commands.sentinel.next;
    current_send_reliable_command = peer.outgoing_send_reliable_commands.sentinel.next;

    while true {
        use_send_reliable_command := false;
        if current_command != *(peer.outgoing_commands.sentinel) {
            outgoing_command = cast(*Outgoing_Command) current_command;
            if current_send_reliable_command != *(peer.outgoing_send_reliable_commands.sentinel) && (cast(*Outgoing_Command) current_send_reliable_command).queue_time - outgoing_command.queue_time >= 86400000 {
                use_send_reliable_command = true;
            }
            if !use_send_reliable_command {
                current_command = current_command.next;
            }
        } else if current_send_reliable_command != *(peer.outgoing_send_reliable_commands.sentinel) {
            use_send_reliable_command = true;
        } else {
            break;
        }
        if use_send_reliable_command {
            outgoing_command = cast(*Outgoing_Command) current_send_reliable_command;
            current_send_reliable_command = current_send_reliable_command.next;
        }

        if outgoing_command.command.header.command & PROTOCOL_COMMAND_FLAG_ACKNOWLEDGE != 0 {
            channel =
                ifx cast,no_check(u64) outgoing_command.command.header.channel_id < peer.channel_count then *peer.channels[outgoing_command.command.header.channel_id] else null;
            reliable_window = outgoing_command.reliable_sequence_number / cast(Uint16) PEER_RELIABLE_WINDOW_SIZE;
            if channel != null {
                if window_wrap != 0 {
                    continue;
                } else if outgoing_command.send_attempts < 1 &&
                    outgoing_command.reliable_sequence_number % cast(Uint16) PEER_RELIABLE_WINDOW_SIZE == 0 &&
                    (channel.reliable_windows[(((cast(s32) reliable_window) + cast,no_check(s32) (PEER_RELIABLE_WINDOWS)) - 1) % cast,no_check(s32) (PEER_RELIABLE_WINDOWS)] >= cast,no_check(Uint16) PEER_RELIABLE_WINDOW_SIZE ||
                        (cast(u32) channel.used_reliable_windows) & ((((cast(u32) 1) << ((((cast,no_check(s32) (PEER_FREE_RELIABLE_WINDOWS)) + 2)) & 31) - 1) << ((reliable_window) & 31)) | (((cast(u32) 1) << ((((cast,no_check(s32) (PEER_FREE_RELIABLE_WINDOWS)) + 2)) & 31) - 1) >> ((((cast,no_check(s32) (PEER_RELIABLE_WINDOWS)) - cast(s32) reliable_window)) & 31))) != 0) {
                    window_wrap = 1;
                    current_send_reliable_command = *(peer.outgoing_send_reliable_commands.sentinel);

                    continue;
                }
            }

            if outgoing_command.packet != null {
                window_size :=
                    peer.packet_throttle * peer.window_size /
                        cast,no_check(Uint32) PEER_PACKET_THROTTLE_SCALE;

                if (peer.reliable_data_in_transit + cast(Uint32) outgoing_command.fragment_length) > (ifx window_size > peer.mtu then window_size else peer.mtu) {
                    current_send_reliable_command = *(peer.outgoing_send_reliable_commands.sentinel);

                    continue;
                }
            }

            can_ping = 0;
        }

        command_size = COMMAND_SIZES[outgoing_command.command.header.command & PROTOCOL_COMMAND_MASK];
        if command >= host.commands.data + cast(u64) host.commands.count ||
            buffer + 1 >= host.buffers.data + cast(u64) host.buffers.count ||
            (cast(u64) peer.mtu) - host.packet_size < command_size ||
            outgoing_command.packet != null &&
                cast,no_check(Uint16) ((cast(u64) peer.mtu) - host.packet_size) < cast,no_check(Uint16) (command_size + cast(u64) outgoing_command.fragment_length) {
            peer.flags = cast,no_check(Uint16) ((cast,no_check(s32) peer.flags) | cast,no_check(s32) (PEER_FLAG_CONTINUE_SENDING));

            break;
        }

        if outgoing_command.command.header.command & PROTOCOL_COMMAND_FLAG_ACKNOWLEDGE != 0 {
            if channel != null && outgoing_command.send_attempts < 1 {
                channel.used_reliable_windows = cast,no_check(Uint16) ((cast,no_check(u32) channel.used_reliable_windows) | ((cast(u32) 1) << ((reliable_window) & 31)));
                channel.reliable_windows[reliable_window] += 1;
            }

            outgoing_command.send_attempts += 1;

            if outgoing_command.round_trip_timeout == 0 {
                outgoing_command.round_trip_timeout = peer.round_trip_time + 4 * peer.round_trip_time_variance;
            }

            if peer.sent_reliable_commands.sentinel.next == *(peer.sent_reliable_commands.sentinel) {
                peer.next_timeout = host.service_time + outgoing_command.round_trip_timeout;
            }

            list_insert(*(peer.sent_reliable_commands.sentinel), list_remove(*outgoing_command.outgoing_command_list));

            outgoing_command.sent_time = host.service_time;

            host.header_flags = cast,no_check(Uint16) ((cast,no_check(s32) host.header_flags) | cast,no_check(s32) (PROTOCOL_HEADER_FLAG_SENT_TIME));

            peer.reliable_data_in_transit += cast,no_check(Uint32) outgoing_command.fragment_length;
        } else {
            if outgoing_command.packet != null && outgoing_command.fragment_offset == 0 {
                peer.packet_throttle_counter += cast,no_check(Uint32) PEER_PACKET_THROTTLE_COUNTER;
                peer.packet_throttle_counter %= cast,no_check(Uint32) PEER_PACKET_THROTTLE_SCALE;

                if peer.packet_throttle_counter > peer.packet_throttle {
                    reliable_sequence_number := outgoing_command.reliable_sequence_number;
                    unreliable_sequence_number := outgoing_command.unreliable_sequence_number;
                    while true {
                        outgoing_command.packet.reference_count -= 1;

                        if outgoing_command.packet.reference_count == 0 {
                            packet_destroy(outgoing_command.packet);
                        }

                        list_remove(*outgoing_command.outgoing_command_list);
                        deallocate_memory(cast(*void) outgoing_command);

                        if current_command == *(peer.outgoing_commands.sentinel) {
                            break;
                        }

                        outgoing_command = cast(*Outgoing_Command) current_command;
                        if outgoing_command.reliable_sequence_number != reliable_sequence_number ||
                            outgoing_command.unreliable_sequence_number != unreliable_sequence_number {
                            break;
                        }

                        current_command = current_command.next;
                    }

                    continue;
                }
            }

            list_remove(*outgoing_command.outgoing_command_list);

            if outgoing_command.packet != null {
                list_insert(*sent_unreliable_commands.sentinel, cast(*void) outgoing_command);
            }
        }

        buffer.data = cast(*void) command;
        buffer.data_length = command_size;

        host.packet_size += buffer.data_length;

        command.* = outgoing_command.command;

        if outgoing_command.packet != null {
            buffer += 1;

            buffer.data = cast(*void) (outgoing_command.packet.data + outgoing_command.fragment_offset);
            buffer.data_length = cast,no_check(u64) outgoing_command.fragment_length;

            host.packet_size += cast,no_check(u64) outgoing_command.fragment_length;
        } else if (cast(s32) outgoing_command.command.header.command) & cast,no_check(s32) (PROTOCOL_COMMAND_FLAG_ACKNOWLEDGE) == 0 {
            deallocate_memory(cast(*void) outgoing_command);
        }

        peer.packets_sent += 1;

        command += 1;
        buffer += 1;
    }

    host.command_count = cast,no_check(u64) (command - host.commands.data);
    host.buffer_count = cast,no_check(u64) (buffer - host.buffers.data);

    if peer.state == cast,no_check(u32) PEER_STATE_DISCONNECT_LATER &&
        peer_has_outgoing_commands(peer) == 0 &&
        sent_unreliable_commands.sentinel.next == *sent_unreliable_commands.sentinel {
        peer_disconnect(peer, peer.event_data);
    }

    return can_ping;
}

protocol_check_timeouts :: (host: *Host, peer: *Peer, event: *Event) -> s32 {
    outgoing_command: *Outgoing_Command = ---;
    current_command: List_Iterator = ---;

    current_command = peer.sent_reliable_commands.sentinel.next;
    insert_position := peer.outgoing_commands.sentinel.next;
    insert_send_reliable_position := peer.outgoing_send_reliable_commands.sentinel.next;

    while current_command != *(peer.sent_reliable_commands.sentinel) {
        outgoing_command = cast(*Outgoing_Command) current_command;

        current_command = current_command.next;

        if (ifx host.service_time - outgoing_command.sent_time >= 86400000 then outgoing_command.sent_time - host.service_time else host.service_time - outgoing_command.sent_time) < outgoing_command.round_trip_timeout {
            continue;
        }

        if peer.earliest_timeout == 0 || outgoing_command.sent_time - peer.earliest_timeout >= 86400000 {
            peer.earliest_timeout = outgoing_command.sent_time;
        }

        if peer.earliest_timeout != 0 &&
            ((ifx host.service_time - peer.earliest_timeout >= 86400000 then peer.earliest_timeout - host.service_time else host.service_time - peer.earliest_timeout) >= peer.timeout_maximum ||
                (cast(u32) 1) << ((((cast(s32) outgoing_command.send_attempts) - 1)) & 31) >= peer.timeout_limit &&
                    (ifx host.service_time - peer.earliest_timeout >= 86400000 then peer.earliest_timeout - host.service_time else host.service_time - peer.earliest_timeout) >= peer.timeout_minimum) {
            protocol_notify_disconnect(host, peer, event);

            return 1;
        }

        peer.packets_lost += 1;

        outgoing_command.round_trip_timeout *= 2;

        if outgoing_command.packet != null {
            peer.reliable_data_in_transit -= cast,no_check(Uint32) outgoing_command.fragment_length;

            list_insert(insert_send_reliable_position, list_remove(*outgoing_command.outgoing_command_list));
        } else {
            list_insert(insert_position, list_remove(*outgoing_command.outgoing_command_list));
        }

        if current_command == peer.sent_reliable_commands.sentinel.next &&
            !(peer.sent_reliable_commands.sentinel.next == *(peer.sent_reliable_commands.sentinel)) {
            outgoing_command = cast(*Outgoing_Command) current_command;

            peer.next_timeout = outgoing_command.sent_time + outgoing_command.round_trip_timeout;
        }
    }

    return 0;
}

protocol_notify_disconnect :: (host: *Host, peer: *Peer, event: *Event) {
    if peer.state >= cast,no_check(u32) PEER_STATE_CONNECTION_PENDING {
        host.recalculate_bandwidth_limits = 1;
    }

    if peer.state != cast,no_check(u32) PEER_STATE_CONNECTING &&
        peer.state < cast,no_check(u32) PEER_STATE_CONNECTION_SUCCEEDED {
        peer_reset(peer);
    } else if event != null {
        event.type = cast,no_check(Event_Type) EVENT_TYPE_DISCONNECT;
        event.peer = peer;
        event.data = 0;

        peer_reset(peer);
    } else {
        peer.event_data = 0;

        protocol_dispatch_state(host, peer, cast,no_check(Peer_State) PEER_STATE_ZOMBIE);
    }
}

protocol_dispatch_state :: (host: *Host, peer: *Peer, state: Peer_State) {
    protocol_change_state(host, peer, state);

    if (cast(s32) peer.flags) & cast,no_check(s32) (PEER_FLAG_NEEDS_DISPATCH) == 0 {
        list_insert(*(host.dispatch_queue.sentinel), cast(*void) *peer.dispatch_list);

        peer.flags = cast,no_check(Uint16) ((cast,no_check(s32) peer.flags) | cast,no_check(s32) (PEER_FLAG_NEEDS_DISPATCH));
    }
}

protocol_send_acknowledgements :: (host: *Host, peer: *Peer) {
    command := host.commands.data + host.command_count;
    buffer := host.buffers.data + host.buffer_count;
    acknowledgement: *Acknowledgement = ---;

    current_acknowledgement := peer.acknowledgements.sentinel.next;

    while current_acknowledgement != *(peer.acknowledgements.sentinel) {
        if command >= host.commands.data + cast(u64) host.commands.count ||
            buffer >= host.buffers.data + cast(u64) host.buffers.count ||
            (cast(u64) peer.mtu) - host.packet_size < size_of(Protocol_Acknowledge) {
            peer.flags = cast,no_check(Uint16) ((cast,no_check(s32) peer.flags) | cast,no_check(s32) (PEER_FLAG_CONTINUE_SENDING));

            break;
        }

        acknowledgement = cast(*Acknowledgement) current_acknowledgement;

        current_acknowledgement = current_acknowledgement.next;

        buffer.data = cast(*void) command;
        buffer.data_length = cast(u64) size_of(Protocol_Acknowledge);

        host.packet_size += buffer.data_length;

        reliable_sequence_number := htons(acknowledgement.command.header.reliable_sequence_number);

        command.header.command = cast,no_check(Uint8) PROTOCOL_COMMAND_ACKNOWLEDGE;
        command.header.channel_id = acknowledgement.command.header.channel_id;
        command.header.reliable_sequence_number = reliable_sequence_number;
        command.acknowledge.received_reliable_sequence_number = reliable_sequence_number;
        command.acknowledge.received_sent_time = htons(cast,no_check(u16) acknowledgement.sent_time);

        if ((cast(s32) acknowledgement.command.header.command) & cast,no_check(s32) (PROTOCOL_COMMAND_MASK)) == PROTOCOL_COMMAND_DISCONNECT {
            protocol_dispatch_state(host, peer, cast,no_check(Peer_State) PEER_STATE_ZOMBIE);
        }

        list_remove(*acknowledgement.acknowledgement_list);
        deallocate_memory(cast(*void) acknowledgement);

        command += 1;
        buffer += 1;
    }

    host.command_count = cast,no_check(u64) (command - host.commands.data);
    host.buffer_count = cast,no_check(u64) (buffer - host.buffers.data);
}

protocol_receive_incoming_commands :: (host: *Host, event: *Event) -> s32 {
    for packets: 0..cast(s32) 256 - 1 {
        buffer: Buffer = ---;

        buffer.data = cast(*void) host.packet_data[0].data;
        buffer.data_length = 4096 * cast(u64) size_of(Uint8);

        received_length :=
            (cast,no_check(#type (_: Socket, _: *Address, _: *Buffer, _: u64) -> s32) (cast(*void) socket_receive))(
                host.socket,
                *host.received_address,
                *buffer,
                1
            );

        if received_length == -2 {
            continue;
        }

        if received_length < 0 {
            return -1;
        }

        if received_length == 0 {
            return 0;
        }

        host.received_data = host.packet_data[0].data;
        host.received_data_length = cast,no_check(u64) received_length;

        host.total_received_data += cast,no_check(Uint32) received_length;
        host.total_received_packets += 1;

        if host.intercept != null {
            if host.intercept(host, event) == {
                case 1;
                    if event != null && event.type != cast,no_check(u32) EVENT_TYPE_NONE {
                        return 1;
                    }
                    continue;
                case -1;
                    return -1;
                case;
            }
        }

        if protocol_handle_incoming_commands(host, event) == {
            case 1;
                return 1;
            case -1;
                return -1;
            case;
        }
    }

    return 0;
}

protocol_handle_incoming_commands :: (host: *Host, event: *Event) -> s32 {
    header: *Protocol_Header = ---;
    command: *Protocol = ---;
    peer: *Peer = ---;
    current_data: *Uint8 = ---;
    header_size: u64 = ---;
    peer_id: Uint16 = ---;
    flags: Uint16 = ---;
    session_id: Uint8 = ---;
    original_size: u64 = ---;
    checksum: *Uint32 = ---;
    desired_checksum: Uint32 = ---;
    new_checksum: Uint32 = ---;
    buffer: Buffer = ---;
    command_number: Uint8 = ---;
    command_size: u64 = ---;
    sent_time: Uint16 = ---;
    code_block_to_execute: s64 = 141;
    // The transpiler had to use this control-flow loop because the source code used a goto, which Jai does not support.
    while c_transpiler_dispatch := true {
        if code_block_to_execute < 0 break;
        if code_block_to_execute == {
            case 22; {
                if event != null && event.type != cast,no_check(u32) EVENT_TYPE_NONE {
                    return 1;
                } else {
                    return 0;
                }
            }
            case 23; {
                if current_data < *host.received_data[host.received_data_length] {
                    code_block_to_execute = 91;
                    continue c_transpiler_dispatch;
                } else {
                    code_block_to_execute = 22;
                    continue c_transpiler_dispatch;
                }
            }
            case 25; {
                peer_queue_acknowledgement(peer, command, sent_time);
                code_block_to_execute = 23;
                continue c_transpiler_dispatch;
            }
            case 35; {
                if peer != null && command.header.command & PROTOCOL_COMMAND_FLAG_ACKNOWLEDGE != 0 {
                    if (cast(s32) flags) & cast,no_check(s32) (PROTOCOL_HEADER_FLAG_SENT_TIME) == 0 {
                        code_block_to_execute = 22;
                        continue c_transpiler_dispatch;
                    } else {
                        sent_time = ntohs(header.sent_time);
                        c_transpiler_switch_value_31 := peer.state;
                        if c_transpiler_switch_value_31 == {
                            case cast,no_check(u32) PEER_STATE_DISCONNECTING; {
                                code_block_to_execute = 23;
                                continue c_transpiler_dispatch;
                            }
                            case cast,no_check(u32) PEER_STATE_ACKNOWLEDGING_CONNECT; {
                                code_block_to_execute = 23;
                                continue c_transpiler_dispatch;
                            }
                            case cast,no_check(u32) PEER_STATE_DISCONNECTED; {
                                code_block_to_execute = 23;
                                continue c_transpiler_dispatch;
                            }
                            case cast,no_check(u32) PEER_STATE_ZOMBIE; {
                                code_block_to_execute = 23;
                                continue c_transpiler_dispatch;
                            }
                            case cast,no_check(u32) PEER_STATE_ACKNOWLEDGING_DISCONNECT; {
                                if ((cast(s32) command.header.command) & cast,no_check(s32) (PROTOCOL_COMMAND_MASK)) == PROTOCOL_COMMAND_DISCONNECT {
                                    peer_queue_acknowledgement(peer, command, sent_time);
                                    code_block_to_execute = 23;
                                    continue c_transpiler_dispatch;
                                } else {
                                    code_block_to_execute = 23;
                                    continue c_transpiler_dispatch;
                                }
                            }
                            case; {
                                code_block_to_execute = 25;
                                continue c_transpiler_dispatch;
                            }
                        }
                    }
                } else {
                    code_block_to_execute = 23;
                    continue c_transpiler_dispatch;
                }
            }
            case 91; {
                command = cast(*Protocol) current_data;
                if (current_data + cast(u64) size_of(Protocol_Command_Header)) > *host.received_data[host.received_data_length] {
                    code_block_to_execute = 22;
                    continue c_transpiler_dispatch;
                } else {
                    command_number =
                        cast,no_check(Uint8) ((cast(s32) command.header.command) & cast,no_check(s32) (PROTOCOL_COMMAND_MASK));
                    if command_number >= cast,no_check(Uint8) PROTOCOL_COMMAND_COUNT {
                        code_block_to_execute = 22;
                        continue c_transpiler_dispatch;
                    } else {
                        command_size = COMMAND_SIZES[command_number];
                        if command_size == 0 || current_data + command_size > *host.received_data[host.received_data_length] {
                            code_block_to_execute = 22;
                            continue c_transpiler_dispatch;
                        } else {
                            current_data += command_size;
                            if peer == null && command_number != cast,no_check(Uint8) PROTOCOL_COMMAND_CONNECT {
                                code_block_to_execute = 22;
                                continue c_transpiler_dispatch;
                            } else {
                                command.header.reliable_sequence_number =
                                    ntohs(command.header.reliable_sequence_number);
                                c_transpiler_switch_value_77 := cast,no_check(s32) command_number;
                                if c_transpiler_switch_value_77 == {
                                    case PROTOCOL_COMMAND_ACKNOWLEDGE; {
                                        if protocol_handle_acknowledge(host, event, peer, command) != 0 {
                                            code_block_to_execute = 22;
                                            continue c_transpiler_dispatch;
                                        } else {
                                            code_block_to_execute = 35;
                                            continue c_transpiler_dispatch;
                                        }
                                    }
                                    case PROTOCOL_COMMAND_CONNECT; {
                                        if peer != null {
                                            code_block_to_execute = 22;
                                            continue c_transpiler_dispatch;
                                        } else {
                                            peer = protocol_handle_connect(host, header, command);
                                            if peer == null {
                                                code_block_to_execute = 22;
                                                continue c_transpiler_dispatch;
                                            } else {
                                                code_block_to_execute = 35;
                                                continue c_transpiler_dispatch;
                                            }
                                        }
                                    }
                                    case PROTOCOL_COMMAND_VERIFY_CONNECT; {
                                        if protocol_handle_verify_connect(host, event, peer, command) != 0 {
                                            code_block_to_execute = 22;
                                            continue c_transpiler_dispatch;
                                        } else {
                                            code_block_to_execute = 35;
                                            continue c_transpiler_dispatch;
                                        }
                                    }
                                    case PROTOCOL_COMMAND_DISCONNECT; {
                                        if protocol_handle_disconnect(host, peer, command) != 0 {
                                            code_block_to_execute = 22;
                                            continue c_transpiler_dispatch;
                                        } else {
                                            code_block_to_execute = 35;
                                            continue c_transpiler_dispatch;
                                        }
                                    }
                                    case PROTOCOL_COMMAND_PING; {
                                        if protocol_handle_ping(host, peer, command) != 0 {
                                            code_block_to_execute = 22;
                                            continue c_transpiler_dispatch;
                                        } else {
                                            code_block_to_execute = 35;
                                            continue c_transpiler_dispatch;
                                        }
                                    }
                                    case PROTOCOL_COMMAND_SEND_RELIABLE; {
                                        if protocol_handle_send_reliable(host, peer, command, *current_data) != 0 {
                                            code_block_to_execute = 22;
                                            continue c_transpiler_dispatch;
                                        } else {
                                            code_block_to_execute = 35;
                                            continue c_transpiler_dispatch;
                                        }
                                    }
                                    case PROTOCOL_COMMAND_SEND_UNRELIABLE; {
                                        if protocol_handle_send_unreliable(host, peer, command, *current_data) != 0 {
                                            code_block_to_execute = 22;
                                            continue c_transpiler_dispatch;
                                        } else {
                                            code_block_to_execute = 35;
                                            continue c_transpiler_dispatch;
                                        }
                                    }
                                    case PROTOCOL_COMMAND_SEND_UNSEQUENCED; {
                                        if protocol_handle_send_unsequenced(host, peer, command, *current_data) != 0 {
                                            code_block_to_execute = 22;
                                            continue c_transpiler_dispatch;
                                        } else {
                                            code_block_to_execute = 35;
                                            continue c_transpiler_dispatch;
                                        }
                                    }
                                    case PROTOCOL_COMMAND_SEND_FRAGMENT; {
                                        if protocol_handle_send_fragment(host, peer, command, *current_data) != 0 {
                                            code_block_to_execute = 22;
                                            continue c_transpiler_dispatch;
                                        } else {
                                            code_block_to_execute = 35;
                                            continue c_transpiler_dispatch;
                                        }
                                    }
                                    case PROTOCOL_COMMAND_BANDWIDTH_LIMIT; {
                                        if protocol_handle_bandwidth_limit(host, peer, command) != 0 {
                                            code_block_to_execute = 22;
                                            continue c_transpiler_dispatch;
                                        } else {
                                            code_block_to_execute = 35;
                                            continue c_transpiler_dispatch;
                                        }
                                    }
                                    case PROTOCOL_COMMAND_THROTTLE_CONFIGURE; {
                                        if protocol_handle_throttle_configure(host, peer, command) != 0 {
                                            code_block_to_execute = 22;
                                            continue c_transpiler_dispatch;
                                        } else {
                                            code_block_to_execute = 35;
                                            continue c_transpiler_dispatch;
                                        }
                                    }
                                    case PROTOCOL_COMMAND_SEND_UNRELIABLE_FRAGMENT; {
                                        if protocol_handle_send_unreliable_fragment(host, peer, command, *current_data) != 0 {
                                            code_block_to_execute = 22;
                                            continue c_transpiler_dispatch;
                                        } else {
                                            code_block_to_execute = 35;
                                            continue c_transpiler_dispatch;
                                        }
                                    }
                                    case; {
                                        code_block_to_execute = 22;
                                        continue c_transpiler_dispatch;
                                    }
                                }
                            }
                        }
                    }
                }
            }
            case 92; {
                current_data = host.received_data + header_size;
                code_block_to_execute = 23;
                continue c_transpiler_dispatch;
            }
            case 96; {
                if peer != null {
                    peer.address.host = host.received_address.host;
                    peer.address.port = host.received_address.port;
                    peer.incoming_data_total = cast,no_check(Uint32) ((cast,no_check(u64) peer.incoming_data_total) + host.received_data_length);
                    code_block_to_execute = 92;
                    continue c_transpiler_dispatch;
                } else {
                    code_block_to_execute = 92;
                    continue c_transpiler_dispatch;
                }
            }
            case 107; {
                if host.checksum != null {
                    checksum = cast(*Uint32) (*host.received_data[header_size - size_of(Uint32)]);
                    copy_memory(*desired_checksum, checksum, size_of(Uint32));
                    new_checksum = ifx peer != null then peer.connect_id else 0;
                    copy_memory(checksum, *new_checksum, size_of(Uint32));
                    buffer.data = cast(*void) host.received_data;
                    buffer.data_length = host.received_data_length;
                    if host.checksum(*buffer, 1) != desired_checksum {
                        return 0;
                    } else {
                        code_block_to_execute = 96;
                        continue c_transpiler_dispatch;
                    }
                } else {
                    code_block_to_execute = 96;
                    continue c_transpiler_dispatch;
                }
            }
            case 117; {
                if flags & PROTOCOL_HEADER_FLAG_COMPRESSED != 0 {
                    if host.compressor.context_ == null || host.compressor.decompress == null {
                        return 0;
                    } else {
                        original_size =
                            host.compressor.decompress(
                                host.compressor.context_,
                                host.received_data + header_size,
                                host.received_data_length - header_size,
                                host.packet_data[1].data + header_size,
                                (4096 * cast(u64) size_of(Uint8)) - header_size
                            );
                        if original_size <= 0 || original_size > (4096 * cast(u64) size_of(Uint8)) - header_size {
                            return 0;
                        } else {
                            copy_memory(host.packet_data[1].data, header, header_size);
                            host.received_data = host.packet_data[1].data;
                            host.received_data_length = header_size + original_size;
                            code_block_to_execute = 107;
                            continue c_transpiler_dispatch;
                        }
                    }
                } else {
                    code_block_to_execute = 107;
                    continue c_transpiler_dispatch;
                }
            }
            case 124; {
                if peer_id == cast,no_check(Uint16) PROTOCOL_MAXIMUM_PEER_ID {
                    peer = null;
                    code_block_to_execute = 117;
                    continue c_transpiler_dispatch;
                } else {
                    if cast,no_check(u64) peer_id >= host.peer_count {
                        return 0;
                    } else {
                        peer = *host.peers[peer_id];
                        if peer.state == cast,no_check(u32) PEER_STATE_DISCONNECTED || peer.state == cast,no_check(u32) PEER_STATE_ZOMBIE || (host.received_address.host != peer.address.host || host.received_address.port != peer.address.port) && peer.address.host != 0xffffffff || peer.outgoing_peer_id < cast,no_check(Uint16) PROTOCOL_MAXIMUM_PEER_ID && session_id != peer.incoming_session_id {
                            return 0;
                        } else {
                            code_block_to_execute = 117;
                            continue c_transpiler_dispatch;
                        }
                    }
                }
            }
            case 141; {
                if host.received_data_length < cast(u64) 2 {
                    return 0;
                } else {
                    header = cast(*Protocol_Header) host.received_data;
                    peer_id = ntohs(header.peer_id);
                    session_id =
                        cast,no_check(Uint8) (((cast(s32) peer_id) & cast,no_check(s32) (PROTOCOL_HEADER_SESSION_MASK)) >> ((PROTOCOL_HEADER_SESSION_SHIFT) & 31));
                    flags =
                        cast,no_check(Uint16) ((cast(s32) peer_id) & cast,no_check(s32) (PROTOCOL_HEADER_FLAG_MASK));
                    peer_id = cast,no_check(Uint16) ((cast,no_check(s32) peer_id) & ~((cast,no_check(s32) (PROTOCOL_HEADER_FLAG_MASK)) | cast,no_check(s32) (PROTOCOL_HEADER_SESSION_MASK)));
                    header_size =
                        ifx flags & PROTOCOL_HEADER_FLAG_SENT_TIME != 0 then cast(u64) size_of(Protocol_Header) else cast(u64) 2;
                    if host.checksum != null {
                        header_size = cast,no_check(u64) (header_size + cast(u64) size_of(Uint32));
                        code_block_to_execute = 124;
                        continue c_transpiler_dispatch;
                    } else {
                        code_block_to_execute = 124;
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

protocol_handle_send_unreliable_fragment :: (
    host: *Host,
    peer: *Peer,
    command: *Protocol,
    current_data: **Uint8
) -> s32 {
    start_command: *Incoming_Command = null;

    if cast,no_check(u64) command.header.channel_id >= peer.channel_count ||
        peer.state != cast,no_check(u32) PEER_STATE_CONNECTED && peer.state != cast,no_check(u32) PEER_STATE_DISCONNECT_LATER {
        return -1;
    }

    fragment_length := cast,no_check(Uint32) ntohs(command.send_fragment.data_length);
    current_data.* += fragment_length;
    if fragment_length <= 0 ||
        cast,no_check(u64) fragment_length > host.maximum_packet_size ||
        current_data.* < host.received_data ||
        current_data.* > *host.received_data[host.received_data_length] {
        return -1;
    }

    channel := *peer.channels[command.header.channel_id];
    reliable_sequence_number := cast,no_check(Uint32) command.header.reliable_sequence_number;
    start_sequence_number := cast,no_check(Uint32) ntohs(command.send_fragment.start_sequence_number);

    reliable_window :=
        cast,no_check(Uint16) (reliable_sequence_number /
            cast,no_check(Uint32) PEER_RELIABLE_WINDOW_SIZE);
    current_window := channel.incoming_reliable_sequence_number / cast(Uint16) PEER_RELIABLE_WINDOW_SIZE;

    if reliable_sequence_number < cast,no_check(Uint32) channel.incoming_reliable_sequence_number {
        reliable_window = cast,no_check(Uint16) ((cast,no_check(s32) reliable_window) + cast,no_check(s32) (PEER_RELIABLE_WINDOWS));
    }

    if reliable_window < current_window ||
        cast,no_check(s32) reliable_window >= ((cast(s32) current_window) + cast,no_check(s32) (PEER_FREE_RELIABLE_WINDOWS)) - 1 {
        return 0;
    }

    if reliable_sequence_number == cast,no_check(Uint32) channel.incoming_reliable_sequence_number &&
        start_sequence_number <= cast,no_check(Uint32) channel.incoming_unreliable_sequence_number {
        return 0;
    }

    fragment_number := ntohl(command.send_fragment.fragment_number);
    fragment_count := ntohl(command.send_fragment.fragment_count);
    fragment_offset := ntohl(command.send_fragment.fragment_offset);
    total_length := ntohl(command.send_fragment.total_length);

    if fragment_count > cast,no_check(Uint32) PROTOCOL_MAXIMUM_FRAGMENT_COUNT ||
        fragment_number >= fragment_count ||
        cast,no_check(u64) total_length > host.maximum_packet_size ||
        total_length < fragment_count ||
        fragment_offset >= total_length ||
        fragment_length > total_length - fragment_offset {
        return -1;
    }

    current_command := channel.incoming_unreliable_commands.sentinel.previous;
    while current_command != *(channel.incoming_unreliable_commands.sentinel) {
        incoming_command := cast(*Incoming_Command) current_command;

        if reliable_sequence_number >= cast,no_check(Uint32) channel.incoming_reliable_sequence_number {
            if incoming_command.reliable_sequence_number < channel.incoming_reliable_sequence_number {
                current_command = current_command.previous;
                continue;
            }
        } else if incoming_command.reliable_sequence_number >= channel.incoming_reliable_sequence_number {
            break;
        }

        if cast,no_check(Uint32) incoming_command.reliable_sequence_number < reliable_sequence_number {
            break;
        }

        if cast,no_check(Uint32) incoming_command.reliable_sequence_number > reliable_sequence_number {
            current_command = current_command.previous;
            continue;
        }

        if cast,no_check(Uint32) incoming_command.unreliable_sequence_number <= start_sequence_number {
            if cast,no_check(Uint32) incoming_command.unreliable_sequence_number < start_sequence_number {
                break;
            }

            if ((cast(s32) incoming_command.command.header.command) & cast,no_check(s32) (PROTOCOL_COMMAND_MASK)) != PROTOCOL_COMMAND_SEND_UNRELIABLE_FRAGMENT ||
                cast,no_check(u64) total_length != incoming_command.packet.data_length ||
                fragment_count != incoming_command.fragment_count {
                return -1;
            }

            start_command = incoming_command;
            break;
        }
        current_command = current_command.previous;
    }

    if start_command == null {
        start_command =
            peer_queue_incoming_command(
                peer,
                command,
                null,
                cast,no_check(u64) total_length,
                cast,no_check(Uint32) PACKET_FLAG_UNRELIABLE_FRAGMENT,
                fragment_count
            );
        if start_command == null {
            return -1;
        }
    }

    if (start_command.fragments[fragment_number / 32] & ((cast(u32) 1) << (((fragment_number % 32)) & 31))) == 0 {
        start_command.fragments_remaining -= 1;

        start_command.fragments[fragment_number / 32] |= (cast(u32) 1) << (((fragment_number % 32)) & 31);

        if cast,no_check(u64) (fragment_offset + fragment_length) > start_command.packet.data_length {
            fragment_length = cast,no_check(Uint32) (start_command.packet.data_length - cast(u64) fragment_offset);
        }

        copy_memory(
            start_command.packet.data + fragment_offset,
            (cast(*Uint8) command) + cast(u64) size_of(Protocol_Send_Fragment),
            cast,no_check(u64) fragment_length
        );

        if start_command.fragments_remaining <= 0 {
            peer_dispatch_incoming_unreliable_commands(peer, channel, null);
        }
    }

    return 0;
}

protocol_handle_throttle_configure :: (host: *Host, peer: *Peer, command: *Protocol) -> s32 {
    if peer.state != cast,no_check(u32) PEER_STATE_CONNECTED && peer.state != cast,no_check(u32) PEER_STATE_DISCONNECT_LATER {
        return -1;
    }

    peer.packet_throttle_interval = ntohl(command.throttle_configure.packet_throttle_interval);
    peer.packet_throttle_acceleration = ntohl(command.throttle_configure.packet_throttle_acceleration);
    peer.packet_throttle_deceleration = ntohl(command.throttle_configure.packet_throttle_deceleration);

    return 0;
}

protocol_handle_bandwidth_limit :: (host: *Host, peer: *Peer, command: *Protocol) -> s32 {
    if peer.state != cast,no_check(u32) PEER_STATE_CONNECTED && peer.state != cast,no_check(u32) PEER_STATE_DISCONNECT_LATER {
        return -1;
    }

    if peer.incoming_bandwidth != 0 {
        host.bandwidth_limited_peers -= 1;
    }

    peer.incoming_bandwidth = ntohl(command.bandwidth_limit.incoming_bandwidth);
    peer.outgoing_bandwidth = ntohl(command.bandwidth_limit.outgoing_bandwidth);

    if peer.incoming_bandwidth != 0 {
        host.bandwidth_limited_peers += 1;
    }

    if peer.incoming_bandwidth == 0 && host.outgoing_bandwidth == 0 {
        peer.window_size = cast,no_check(Uint32) PROTOCOL_MAXIMUM_WINDOW_SIZE;
    } else if peer.incoming_bandwidth == 0 || host.outgoing_bandwidth == 0 {
        peer.window_size =
            ((ifx peer.incoming_bandwidth > host.outgoing_bandwidth then peer.incoming_bandwidth else host.outgoing_bandwidth) / cast,no_check(Uint32) PEER_WINDOW_SIZE_SCALE) *
                cast,no_check(Uint32) PROTOCOL_MINIMUM_WINDOW_SIZE;
    } else {
        peer.window_size =
            ((ifx peer.incoming_bandwidth < host.outgoing_bandwidth then peer.incoming_bandwidth else host.outgoing_bandwidth) / cast,no_check(Uint32) PEER_WINDOW_SIZE_SCALE) *
                cast,no_check(Uint32) PROTOCOL_MINIMUM_WINDOW_SIZE;
    }

    if peer.window_size < cast,no_check(Uint32) PROTOCOL_MINIMUM_WINDOW_SIZE {
        peer.window_size = cast,no_check(Uint32) PROTOCOL_MINIMUM_WINDOW_SIZE;
    } else if peer.window_size > cast,no_check(Uint32) PROTOCOL_MAXIMUM_WINDOW_SIZE {
        peer.window_size = cast,no_check(Uint32) PROTOCOL_MAXIMUM_WINDOW_SIZE;
    }

    return 0;
}

protocol_handle_send_fragment :: (host: *Host, peer: *Peer, command: *Protocol, current_data: **Uint8) -> s32 {
    start_command: *Incoming_Command = null;

    if cast,no_check(u64) command.header.channel_id >= peer.channel_count ||
        peer.state != cast,no_check(u32) PEER_STATE_CONNECTED && peer.state != cast,no_check(u32) PEER_STATE_DISCONNECT_LATER {
        return -1;
    }

    fragment_length := cast,no_check(Uint32) ntohs(command.send_fragment.data_length);
    current_data.* += fragment_length;
    if fragment_length <= 0 ||
        cast,no_check(u64) fragment_length > host.maximum_packet_size ||
        current_data.* < host.received_data ||
        current_data.* > *host.received_data[host.received_data_length] {
        return -1;
    }

    channel := *peer.channels[command.header.channel_id];
    start_sequence_number := cast,no_check(Uint32) ntohs(command.send_fragment.start_sequence_number);
    start_window := cast,no_check(Uint16) (start_sequence_number / cast,no_check(Uint32) PEER_RELIABLE_WINDOW_SIZE);
    current_window := channel.incoming_reliable_sequence_number / cast(Uint16) PEER_RELIABLE_WINDOW_SIZE;

    if start_sequence_number < cast,no_check(Uint32) channel.incoming_reliable_sequence_number {
        start_window = cast,no_check(Uint16) ((cast,no_check(s32) start_window) + cast,no_check(s32) (PEER_RELIABLE_WINDOWS));
    }

    if start_window < current_window ||
        cast,no_check(s32) start_window >= ((cast(s32) current_window) + cast,no_check(s32) (PEER_FREE_RELIABLE_WINDOWS)) - 1 {
        return 0;
    }

    fragment_number := ntohl(command.send_fragment.fragment_number);
    fragment_count := ntohl(command.send_fragment.fragment_count);
    fragment_offset := ntohl(command.send_fragment.fragment_offset);
    total_length := ntohl(command.send_fragment.total_length);

    if fragment_count > cast,no_check(Uint32) PROTOCOL_MAXIMUM_FRAGMENT_COUNT ||
        fragment_number >= fragment_count ||
        cast,no_check(u64) total_length > host.maximum_packet_size ||
        total_length < fragment_count ||
        fragment_offset >= total_length ||
        fragment_length > total_length - fragment_offset {
        return -1;
    }

    current_command := channel.incoming_reliable_commands.sentinel.previous;
    while current_command != *(channel.incoming_reliable_commands.sentinel) {
        incoming_command := cast(*Incoming_Command) current_command;

        if start_sequence_number >= cast,no_check(Uint32) channel.incoming_reliable_sequence_number {
            if incoming_command.reliable_sequence_number < channel.incoming_reliable_sequence_number {
                current_command = current_command.previous;
                continue;
            }
        } else if incoming_command.reliable_sequence_number >= channel.incoming_reliable_sequence_number {
            break;
        }

        if cast,no_check(Uint32) incoming_command.reliable_sequence_number <= start_sequence_number {
            if cast,no_check(Uint32) incoming_command.reliable_sequence_number < start_sequence_number {
                break;
            }

            if ((cast(s32) incoming_command.command.header.command) & cast,no_check(s32) (PROTOCOL_COMMAND_MASK)) != PROTOCOL_COMMAND_SEND_FRAGMENT ||
                cast,no_check(u64) total_length != incoming_command.packet.data_length ||
                fragment_count != incoming_command.fragment_count {
                return -1;
            }

            start_command = incoming_command;
            break;
        }
        current_command = current_command.previous;
    }

    if start_command == null {
        host_command := command.*;

        host_command.header.reliable_sequence_number = cast,no_check(Uint16) start_sequence_number;

        start_command =
            peer_queue_incoming_command(
                peer,
                *host_command,
                null,
                cast,no_check(u64) total_length,
                cast,no_check(Uint32) PACKET_FLAG_RELIABLE,
                fragment_count
            );
        if start_command == null {
            return -1;
        }
    }

    if (start_command.fragments[fragment_number / 32] & ((cast(u32) 1) << (((fragment_number % 32)) & 31))) == 0 {
        start_command.fragments_remaining -= 1;

        start_command.fragments[fragment_number / 32] |= (cast(u32) 1) << (((fragment_number % 32)) & 31);

        if cast,no_check(u64) (fragment_offset + fragment_length) > start_command.packet.data_length {
            fragment_length = cast,no_check(Uint32) (start_command.packet.data_length - cast(u64) fragment_offset);
        }

        copy_memory(
            start_command.packet.data + fragment_offset,
            (cast(*Uint8) command) + cast(u64) size_of(Protocol_Send_Fragment),
            cast,no_check(u64) fragment_length
        );

        if start_command.fragments_remaining <= 0 {
            peer_dispatch_incoming_reliable_commands(peer, channel, null);
        }
    }

    return 0;
}

protocol_handle_send_unsequenced :: (host: *Host, peer: *Peer, command: *Protocol, current_data: **Uint8) -> s32 {
    if cast,no_check(u64) command.header.channel_id >= peer.channel_count ||
        peer.state != cast,no_check(u32) PEER_STATE_CONNECTED && peer.state != cast,no_check(u32) PEER_STATE_DISCONNECT_LATER {
        return -1;
    }

    data_length := cast,no_check(u64) ntohs(command.send_unsequenced.data_length);
    current_data.* += data_length;
    if data_length > host.maximum_packet_size ||
        current_data.* < host.received_data ||
        current_data.* > *host.received_data[host.received_data_length] {
        return -1;
    }

    unsequenced_group := cast,no_check(Uint32) ntohs(command.send_unsequenced.unsequenced_group);
    index := unsequenced_group % cast,no_check(Uint32) PEER_UNSEQUENCED_WINDOW_SIZE;

    if unsequenced_group < cast,no_check(Uint32) peer.incoming_unsequenced_group {
        unsequenced_group += 0x10000;
    }

    if unsequenced_group >= (cast,no_check(Uint32) peer.incoming_unsequenced_group) + cast,no_check(Uint32) ((cast,no_check(s32) (PEER_FREE_UNSEQUENCED_WINDOWS)) * cast,no_check(s32) (PEER_UNSEQUENCED_WINDOW_SIZE)) {
        return 0;
    }

    unsequenced_group &= 0xffff;

    if unsequenced_group - index != cast,no_check(Uint32) peer.incoming_unsequenced_group {
        peer.incoming_unsequenced_group = cast,no_check(Uint16) (unsequenced_group - index);

        fill_memory(peer.unsequenced_window.data, 0, peer.unsequenced_window.count * size_of(Uint32));
    } else if peer.unsequenced_window[index / 32] & ((cast(u32) 1) << (((index % 32)) & 31)) != 0 {
        return 0;
    }

    if peer_queue_incoming_command(
        peer,
        command,
        cast(*void) ((cast(*Uint8) command) + cast(u64) size_of(Protocol_Send_Unsequenced)),
        data_length,
        cast,no_check(Uint32) PACKET_FLAG_UNSEQUENCED,
        0
    ) == null {
        return -1;
    }

    peer.unsequenced_window[index / 32] |= (cast(u32) 1) << (((index % 32)) & 31);

    return 0;
}

protocol_handle_send_unreliable :: (host: *Host, peer: *Peer, command: *Protocol, current_data: **Uint8) -> s32 {
    if cast,no_check(u64) command.header.channel_id >= peer.channel_count ||
        peer.state != cast,no_check(u32) PEER_STATE_CONNECTED && peer.state != cast,no_check(u32) PEER_STATE_DISCONNECT_LATER {
        return -1;
    }

    data_length := cast,no_check(u64) ntohs(command.send_unreliable.data_length);
    current_data.* += data_length;
    if data_length > host.maximum_packet_size ||
        current_data.* < host.received_data ||
        current_data.* > *host.received_data[host.received_data_length] {
        return -1;
    }

    if peer_queue_incoming_command(
        peer,
        command,
        cast(*void) ((cast(*Uint8) command) + cast(u64) size_of(Protocol_Send_Unreliable)),
        data_length,
        0,
        0
    ) == null {
        return -1;
    }

    return 0;
}

protocol_handle_send_reliable :: (host: *Host, peer: *Peer, command: *Protocol, current_data: **Uint8) -> s32 {
    if cast,no_check(u64) command.header.channel_id >= peer.channel_count ||
        peer.state != cast,no_check(u32) PEER_STATE_CONNECTED && peer.state != cast,no_check(u32) PEER_STATE_DISCONNECT_LATER {
        return -1;
    }

    data_length := cast,no_check(u64) ntohs(command.send_reliable.data_length);
    current_data.* += data_length;
    if data_length > host.maximum_packet_size ||
        current_data.* < host.received_data ||
        current_data.* > *host.received_data[host.received_data_length] {
        return -1;
    }

    if peer_queue_incoming_command(
        peer,
        command,
        cast(*void) ((cast(*Uint8) command) + cast(u64) size_of(Protocol_Send_Reliable)),
        data_length,
        cast,no_check(Uint32) PACKET_FLAG_RELIABLE,
        0
    ) == null {
        return -1;
    }

    return 0;
}

protocol_handle_ping :: (host: *Host, peer: *Peer, command: *Protocol) -> s32 {
    if peer.state != cast,no_check(u32) PEER_STATE_CONNECTED && peer.state != cast,no_check(u32) PEER_STATE_DISCONNECT_LATER {
        return -1;
    }

    return 0;
}

protocol_handle_disconnect :: (host: *Host, peer: *Peer, command: *Protocol) -> s32 {
    if peer.state == cast,no_check(u32) PEER_STATE_DISCONNECTED ||
        peer.state == cast,no_check(u32) PEER_STATE_ZOMBIE ||
        peer.state == cast,no_check(u32) PEER_STATE_ACKNOWLEDGING_DISCONNECT {
        return 0;
    }

    peer_reset_queues(peer);

    if peer.state == cast,no_check(u32) PEER_STATE_CONNECTION_SUCCEEDED ||
        peer.state == cast,no_check(u32) PEER_STATE_DISCONNECTING ||
        peer.state == cast,no_check(u32) PEER_STATE_CONNECTING {
        protocol_dispatch_state(host, peer, cast,no_check(Peer_State) PEER_STATE_ZOMBIE);
    } else if peer.state != cast,no_check(u32) PEER_STATE_CONNECTED && peer.state != cast,no_check(u32) PEER_STATE_DISCONNECT_LATER {
        if peer.state == cast,no_check(u32) PEER_STATE_CONNECTION_PENDING {
            host.recalculate_bandwidth_limits = 1;
        }

        peer_reset(peer);
    } else if command.header.command & PROTOCOL_COMMAND_FLAG_ACKNOWLEDGE != 0 {
        protocol_change_state(host, peer, cast,no_check(Peer_State) PEER_STATE_ACKNOWLEDGING_DISCONNECT);
    } else {
        protocol_dispatch_state(host, peer, cast,no_check(Peer_State) PEER_STATE_ZOMBIE);
    }

    if peer.state != cast,no_check(u32) PEER_STATE_DISCONNECTED {
        peer.event_data = ntohl(command.disconnect.data);
    }

    return 0;
}

protocol_handle_verify_connect :: (host: *Host, event: *Event, peer: *Peer, command: *Protocol) -> s32 {
    if peer.state != cast,no_check(u32) PEER_STATE_CONNECTING {
        return 0;
    }

    channel_count := cast,no_check(u64) ntohl(command.verify_connect.channel_count);

    if channel_count < cast,no_check(u64) PROTOCOL_MINIMUM_CHANNEL_COUNT ||
        channel_count > cast,no_check(u64) PROTOCOL_MAXIMUM_CHANNEL_COUNT ||
        ntohl(command.verify_connect.packet_throttle_interval) != peer.packet_throttle_interval ||
        ntohl(command.verify_connect.packet_throttle_acceleration) != peer.packet_throttle_acceleration ||
        ntohl(command.verify_connect.packet_throttle_deceleration) != peer.packet_throttle_deceleration ||
        command.verify_connect.connect_id != peer.connect_id {
        peer.event_data = 0;

        protocol_dispatch_state(host, peer, cast,no_check(Peer_State) PEER_STATE_ZOMBIE);

        return -1;
    }

    protocol_remove_sent_reliable_command(peer, 1, 0xff);

    if channel_count < peer.channel_count {
        peer.channel_count = channel_count;
    }

    peer.outgoing_peer_id = ntohs(command.verify_connect.outgoing_peer_id);
    peer.incoming_session_id = command.verify_connect.incoming_session_id;
    peer.outgoing_session_id = command.verify_connect.outgoing_session_id;

    mtu := ntohl(command.verify_connect.mtu);

    if mtu < cast,no_check(Uint32) PROTOCOL_MINIMUM_MTU {
        mtu = cast,no_check(Uint32) PROTOCOL_MINIMUM_MTU;
    } else if mtu > cast,no_check(Uint32) PROTOCOL_MAXIMUM_MTU {
        mtu = cast,no_check(Uint32) PROTOCOL_MAXIMUM_MTU;
    }

    if mtu < peer.mtu {
        peer.mtu = mtu;
    }

    window_size := ntohl(command.verify_connect.window_size);

    if window_size < cast,no_check(Uint32) PROTOCOL_MINIMUM_WINDOW_SIZE {
        window_size = cast,no_check(Uint32) PROTOCOL_MINIMUM_WINDOW_SIZE;
    }

    if window_size > cast,no_check(Uint32) PROTOCOL_MAXIMUM_WINDOW_SIZE {
        window_size = cast,no_check(Uint32) PROTOCOL_MAXIMUM_WINDOW_SIZE;
    }

    if window_size < peer.window_size {
        peer.window_size = window_size;
    }

    peer.incoming_bandwidth = ntohl(command.verify_connect.incoming_bandwidth);
    peer.outgoing_bandwidth = ntohl(command.verify_connect.outgoing_bandwidth);

    protocol_notify_connect(host, peer, event);
    return 0;
}

protocol_notify_connect :: (host: *Host, peer: *Peer, event: *Event) {
    host.recalculate_bandwidth_limits = 1;

    if event != null {
        protocol_change_state(host, peer, cast,no_check(Peer_State) PEER_STATE_CONNECTED);

        event.type = cast,no_check(Event_Type) EVENT_TYPE_CONNECT;
        event.peer = peer;
        event.data = peer.event_data;
    } else {
        protocol_dispatch_state(
            host,
            peer,
            cast,no_check(Peer_State) ((ifx peer.state == cast,no_check(u32) PEER_STATE_CONNECTING then cast,no_check(s32) (PEER_STATE_CONNECTION_SUCCEEDED) else cast,no_check(s32) (PEER_STATE_CONNECTION_PENDING)))
        );
    }
}

protocol_remove_sent_reliable_command :: (
    peer: *Peer,
    reliable_sequence_number: Uint16,
    channel_id: Uint8
) -> Protocol_Command {
    outgoing_command: *Outgoing_Command = null;

    was_sent: s32 = 1;

    current_command := peer.sent_reliable_commands.sentinel.next;
    while current_command != *(peer.sent_reliable_commands.sentinel) {
        outgoing_command = cast(*Outgoing_Command) current_command;

        if outgoing_command.reliable_sequence_number == reliable_sequence_number &&
            outgoing_command.command.header.channel_id == channel_id {
            break;
        }
        current_command = current_command.next;
    }

    if current_command == *(peer.sent_reliable_commands.sentinel) {
        outgoing_command =
            protocol_find_sent_reliable_command(
                *peer.outgoing_commands,
                reliable_sequence_number,
                channel_id
            );
        if outgoing_command == null {
            outgoing_command =
                protocol_find_sent_reliable_command(
                    *peer.outgoing_send_reliable_commands,
                    reliable_sequence_number,
                    channel_id
                );
        }

        was_sent = 0;
    }

    if outgoing_command == null {
        return cast,no_check(Protocol_Command) PROTOCOL_COMMAND_NONE;
    }

    if cast,no_check(u64) channel_id < peer.channel_count {
        channel := *peer.channels[channel_id];
        reliable_window := reliable_sequence_number / cast(Uint16) PEER_RELIABLE_WINDOW_SIZE;
        if channel.reliable_windows[reliable_window] > 0 {
            channel.reliable_windows[reliable_window] -= 1;
            if channel.reliable_windows[reliable_window] == 0 {
                channel.used_reliable_windows = cast,no_check(Uint16) ((cast,no_check(u32) channel.used_reliable_windows) & ~((cast(u32) 1) << ((reliable_window) & 31)));
            }
        }
    }

    command_number :=
        cast,no_check(Protocol_Command) ((cast(s32) outgoing_command.command.header.command) & cast,no_check(s32) (PROTOCOL_COMMAND_MASK));

    list_remove(*outgoing_command.outgoing_command_list);

    if outgoing_command.packet != null {
        if was_sent != 0 {
            peer.reliable_data_in_transit -= cast,no_check(Uint32) outgoing_command.fragment_length;
        }

        outgoing_command.packet.reference_count -= 1;

        if outgoing_command.packet.reference_count == 0 {
            outgoing_command.packet.flags |= cast,no_check(Uint32) PACKET_FLAG_SENT;

            packet_destroy(outgoing_command.packet);
        }
    }

    deallocate_memory(cast(*void) outgoing_command);

    if peer.sent_reliable_commands.sentinel.next == *(peer.sent_reliable_commands.sentinel) {
        return command_number;
    }

    outgoing_command = cast(*Outgoing_Command) (cast(*void) peer.sent_reliable_commands.sentinel.next);

    peer.next_timeout = outgoing_command.sent_time + outgoing_command.round_trip_timeout;

    return command_number;
}

protocol_find_sent_reliable_command :: (
    list: *List,
    reliable_sequence_number: Uint16,
    channel_id: Uint8
) -> *Outgoing_Command {
    current_command := list.sentinel.next;
    while current_command != *list.sentinel {
        outgoing_command := cast(*Outgoing_Command) current_command;

        if (cast(s32) outgoing_command.command.header.command) & cast,no_check(s32) (PROTOCOL_COMMAND_FLAG_ACKNOWLEDGE) == 0 {
            current_command = current_command.next;
            continue;
        }

        if outgoing_command.send_attempts < 1 {
            break;
        }

        if outgoing_command.reliable_sequence_number == reliable_sequence_number &&
            outgoing_command.command.header.channel_id == channel_id {
            return outgoing_command;
        }
        current_command = current_command.next;
    }

    return null;
}

protocol_handle_connect :: (host: *Host, header: *Protocol_Header, command: *Protocol) -> *Peer {
    duplicate_peers: u64 = 0;
    peer: *Peer = null;
    verify_command: Protocol = ---;

    channel_count := cast,no_check(u64) ntohl(command.connect.channel_count);

    if channel_count < cast,no_check(u64) PROTOCOL_MINIMUM_CHANNEL_COUNT ||
        channel_count > cast,no_check(u64) PROTOCOL_MAXIMUM_CHANNEL_COUNT {
        return null;
    }

    current_peer := host.peers;
    while current_peer < *host.peers[host.peer_count] {
        if current_peer.state == cast,no_check(u32) PEER_STATE_DISCONNECTED {
            if peer == null {
                peer = current_peer;
            }
        } else if current_peer.state != cast,no_check(u32) PEER_STATE_CONNECTING &&
            current_peer.address.host == host.received_address.host {
            if current_peer.address.port == host.received_address.port && current_peer.connect_id == command.connect.connect_id {
                return null;
            }

            duplicate_peers += 1;
        }
        current_peer += 1;
    }

    if peer == null || duplicate_peers >= host.duplicate_peers {
        return null;
    }

    if channel_count > host.channel_limit {
        channel_count = host.channel_limit;
    }
    peer.channels = cast(*Channel) allocate_memory(channel_count * size_of(Channel));
    if peer.channels == null {
        return null;
    }
    peer.channel_count = channel_count;
    peer.state = cast,no_check(Peer_State) PEER_STATE_ACKNOWLEDGING_CONNECT;
    peer.connect_id = command.connect.connect_id;
    peer.address = host.received_address;
    peer.mtu = host.mtu;
    peer.outgoing_peer_id = ntohs(command.connect.outgoing_peer_id);
    peer.incoming_bandwidth = ntohl(command.connect.incoming_bandwidth);
    peer.outgoing_bandwidth = ntohl(command.connect.outgoing_bandwidth);
    peer.packet_throttle_interval = ntohl(command.connect.packet_throttle_interval);
    peer.packet_throttle_acceleration = ntohl(command.connect.packet_throttle_acceleration);
    peer.packet_throttle_deceleration = ntohl(command.connect.packet_throttle_deceleration);
    peer.event_data = ntohl(command.connect.data);

    incoming_session_id :=
        cast,no_check(Uint8) ((ifx command.connect.incoming_session_id == 0xff then cast,no_check(s32) peer.outgoing_session_id else cast,no_check(s32) command.connect.incoming_session_id));
    incoming_session_id =
        cast,no_check(Uint8) (((cast(s32) incoming_session_id) +
            1) & ((cast,no_check(s32) (PROTOCOL_HEADER_SESSION_MASK)) >> ((PROTOCOL_HEADER_SESSION_SHIFT) & 31)));
    if incoming_session_id == peer.outgoing_session_id {
        incoming_session_id =
            cast,no_check(Uint8) (((cast(s32) incoming_session_id) +
                1) & ((cast,no_check(s32) (PROTOCOL_HEADER_SESSION_MASK)) >> ((PROTOCOL_HEADER_SESSION_SHIFT) & 31)));
    }
    peer.outgoing_session_id = incoming_session_id;

    outgoing_session_id :=
        cast,no_check(Uint8) ((ifx command.connect.outgoing_session_id == 0xff then cast,no_check(s32) peer.incoming_session_id else cast,no_check(s32) command.connect.outgoing_session_id));
    outgoing_session_id =
        cast,no_check(Uint8) (((cast(s32) outgoing_session_id) +
            1) & ((cast,no_check(s32) (PROTOCOL_HEADER_SESSION_MASK)) >> ((PROTOCOL_HEADER_SESSION_SHIFT) & 31)));
    if outgoing_session_id == peer.incoming_session_id {
        outgoing_session_id =
            cast,no_check(Uint8) (((cast(s32) outgoing_session_id) +
                1) & ((cast,no_check(s32) (PROTOCOL_HEADER_SESSION_MASK)) >> ((PROTOCOL_HEADER_SESSION_SHIFT) & 31)));
    }
    peer.incoming_session_id = outgoing_session_id;

    channel := peer.channels;
    while channel < *peer.channels[channel_count] {
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

    mtu := ntohl(command.connect.mtu);

    if mtu < cast,no_check(Uint32) PROTOCOL_MINIMUM_MTU {
        mtu = cast,no_check(Uint32) PROTOCOL_MINIMUM_MTU;
    } else if mtu > cast,no_check(Uint32) PROTOCOL_MAXIMUM_MTU {
        mtu = cast,no_check(Uint32) PROTOCOL_MAXIMUM_MTU;
    }

    if mtu < peer.mtu {
        peer.mtu = mtu;
    }

    if host.outgoing_bandwidth == 0 && peer.incoming_bandwidth == 0 {
        peer.window_size = cast,no_check(Uint32) PROTOCOL_MAXIMUM_WINDOW_SIZE;
    } else if host.outgoing_bandwidth == 0 || peer.incoming_bandwidth == 0 {
        peer.window_size =
            ((ifx host.outgoing_bandwidth > peer.incoming_bandwidth then host.outgoing_bandwidth else peer.incoming_bandwidth) / cast,no_check(Uint32) PEER_WINDOW_SIZE_SCALE) *
                cast,no_check(Uint32) PROTOCOL_MINIMUM_WINDOW_SIZE;
    } else {
        peer.window_size =
            ((ifx host.outgoing_bandwidth < peer.incoming_bandwidth then host.outgoing_bandwidth else peer.incoming_bandwidth) / cast,no_check(Uint32) PEER_WINDOW_SIZE_SCALE) *
                cast,no_check(Uint32) PROTOCOL_MINIMUM_WINDOW_SIZE;
    }

    if peer.window_size < cast,no_check(Uint32) PROTOCOL_MINIMUM_WINDOW_SIZE {
        peer.window_size = cast,no_check(Uint32) PROTOCOL_MINIMUM_WINDOW_SIZE;
    } else if peer.window_size > cast,no_check(Uint32) PROTOCOL_MAXIMUM_WINDOW_SIZE {
        peer.window_size = cast,no_check(Uint32) PROTOCOL_MAXIMUM_WINDOW_SIZE;
    }

    window_size: Uint32 = ifx host.incoming_bandwidth == 0
        then cast,no_check(Uint32) PROTOCOL_MAXIMUM_WINDOW_SIZE
        else (host.incoming_bandwidth / cast,no_check(Uint32) PEER_WINDOW_SIZE_SCALE) * cast,no_check(Uint32) PROTOCOL_MINIMUM_WINDOW_SIZE;

    if window_size > ntohl(command.connect.window_size) {
        window_size = ntohl(command.connect.window_size);
    }

    if window_size < cast,no_check(Uint32) PROTOCOL_MINIMUM_WINDOW_SIZE {
        window_size = cast,no_check(Uint32) PROTOCOL_MINIMUM_WINDOW_SIZE;
    } else if window_size > cast,no_check(Uint32) PROTOCOL_MAXIMUM_WINDOW_SIZE {
        window_size = cast,no_check(Uint32) PROTOCOL_MAXIMUM_WINDOW_SIZE;
    }

    verify_command.header.command =
        cast,no_check(Uint8) ((cast,no_check(s32) (PROTOCOL_COMMAND_VERIFY_CONNECT)) | cast,no_check(s32) (PROTOCOL_COMMAND_FLAG_ACKNOWLEDGE));
    verify_command.header.channel_id = 0xff;
    verify_command.verify_connect.outgoing_peer_id = htons(peer.incoming_peer_id);
    verify_command.verify_connect.incoming_session_id = incoming_session_id;
    verify_command.verify_connect.outgoing_session_id = outgoing_session_id;
    verify_command.verify_connect.mtu = htonl(peer.mtu);
    verify_command.verify_connect.window_size = htonl(window_size);
    verify_command.verify_connect.channel_count = htonl(cast,no_check(u32) channel_count);
    verify_command.verify_connect.incoming_bandwidth = htonl(host.incoming_bandwidth);
    verify_command.verify_connect.outgoing_bandwidth = htonl(host.outgoing_bandwidth);
    verify_command.verify_connect.packet_throttle_interval = htonl(peer.packet_throttle_interval);
    verify_command.verify_connect.packet_throttle_acceleration = htonl(peer.packet_throttle_acceleration);
    verify_command.verify_connect.packet_throttle_deceleration = htonl(peer.packet_throttle_deceleration);
    verify_command.verify_connect.connect_id = peer.connect_id;

    peer_queue_outgoing_command(peer, *verify_command, null, 0, 0);

    return peer;
}

protocol_handle_acknowledge :: (host: *Host, event: *Event, peer: *Peer, command: *Protocol) -> s32 {
    if peer.state == cast,no_check(u32) PEER_STATE_DISCONNECTED || peer.state == cast,no_check(u32) PEER_STATE_ZOMBIE {
        return 0;
    }

    received_sent_time := cast,no_check(Uint32) ntohs(command.acknowledge.received_sent_time);
    received_sent_time |= host.service_time & 0xffff0000;
    if (received_sent_time & 0x8000) > host.service_time & 0x8000 {
        received_sent_time -= 0x10000;
    }

    if host.service_time - received_sent_time >= 86400000 {
        return 0;
    }

    round_trip_time :=
        (ifx host.service_time - received_sent_time >= 86400000 then received_sent_time -
            host.service_time else host.service_time - received_sent_time);
    round_trip_time = ifx round_trip_time > 1 then round_trip_time else 1;

    if peer.last_receive_time > 0 {
        peer_throttle(peer, round_trip_time);

        peer.round_trip_time_variance -= peer.round_trip_time_variance / 4;

        if round_trip_time >= peer.round_trip_time {
            diff := round_trip_time - peer.round_trip_time;
            peer.round_trip_time_variance += diff / 4;
            peer.round_trip_time += diff / 8;
        } else {
            diff := peer.round_trip_time - round_trip_time;
            peer.round_trip_time_variance += diff / 4;
            peer.round_trip_time -= diff / 8;
        }
    } else {
        peer.round_trip_time = round_trip_time;
        peer.round_trip_time_variance = (round_trip_time + 1) / 2;
    }

    if peer.round_trip_time < peer.lowest_round_trip_time {
        peer.lowest_round_trip_time = peer.round_trip_time;
    }

    if peer.round_trip_time_variance > peer.highest_round_trip_time_variance {
        peer.highest_round_trip_time_variance = peer.round_trip_time_variance;
    }

    if peer.packet_throttle_epoch == 0 ||
        (ifx host.service_time - peer.packet_throttle_epoch >= 86400000 then peer.packet_throttle_epoch - host.service_time else host.service_time - peer.packet_throttle_epoch) >= peer.packet_throttle_interval {
        peer.last_round_trip_time = peer.lowest_round_trip_time;
        peer.last_round_trip_time_variance =
            ifx peer.highest_round_trip_time_variance > 1 then peer.highest_round_trip_time_variance else 1;
        peer.lowest_round_trip_time = peer.round_trip_time;
        peer.highest_round_trip_time_variance = peer.round_trip_time_variance;
        peer.packet_throttle_epoch = host.service_time;
    }

    peer.last_receive_time = ifx host.service_time > 1 then host.service_time else 1;
    peer.earliest_timeout = 0;

    received_reliable_sequence_number :=
        cast,no_check(Uint32) ntohs(
            command.acknowledge.received_reliable_sequence_number
        );

    command_number :=
        protocol_remove_sent_reliable_command(
            peer,
            cast,no_check(Uint16) received_reliable_sequence_number,
            command.header.channel_id
        );

    if peer.state == {
        case cast,no_check(u32) PEER_STATE_ACKNOWLEDGING_CONNECT;
            if command_number != cast,no_check(u32) PROTOCOL_COMMAND_VERIFY_CONNECT {
                return -1;
            }
            protocol_notify_connect(host, peer, event);
        case cast,no_check(u32) PEER_STATE_DISCONNECTING;
            if command_number != cast,no_check(u32) PROTOCOL_COMMAND_DISCONNECT {
                return -1;
            }
            protocol_notify_disconnect(host, peer, event);
        case cast,no_check(u32) PEER_STATE_DISCONNECT_LATER;
            if peer_has_outgoing_commands(peer) == 0 {
                peer_disconnect(peer, peer.event_data);
            }
        case;
    }

    return 0;
}

host_flush :: (host: *Host) {
    host.service_time = time_get();

    protocol_send_outgoing_commands(host, null, 0);
}

protocol_command_size :: (command_number: Uint8) -> u64 {
    return COMMAND_SIZES[command_number & PROTOCOL_COMMAND_MASK];
}

globals_initialization_state_for_protocol: u32;
initialize_globals_for_protocol :: () {
    {
        state := atomic_load(*globals_initialization_state_for_protocol);
        if state == 2 return;
        won, _ := compare_and_swap(*globals_initialization_state_for_protocol, 0, 1);
        if !won {
            while atomic_load(*globals_initialization_state_for_protocol) != 2 {}
            return;
        }
    }
    COMMAND_SIZES =
        u64.[
            0,
            cast(u64) size_of(Protocol_Acknowledge),
            cast(u64) size_of(Protocol_Connect),
            cast(u64) size_of(Protocol_Verify_Connect),
            cast(u64) size_of(Protocol_Disconnect),
            cast(u64) size_of(Protocol_Ping),
            cast(u64) size_of(Protocol_Send_Reliable),
            cast(u64) size_of(Protocol_Send_Unreliable),
            cast(u64) size_of(Protocol_Send_Fragment),
            cast(u64) size_of(Protocol_Send_Unsequenced),
            cast(u64) size_of(Protocol_Bandwidth_Limit),
            cast(u64) size_of(Protocol_Throttle_Configure),
            cast(u64) size_of(Protocol_Send_Fragment)
        ];
    atomic_store(*globals_initialization_state_for_protocol, 2);
}

ntohl :: (netlong: u32) -> u32 {
    return C_Transpiler_Bit_Operations.byte_swap(netlong);
}

Socket_Wait :: u32;
SOCKET_WAIT_NONE : s32 : 0;
SOCKET_WAIT_SEND : s32 : 1;
SOCKET_WAIT_RECEIVE : s32 : 2;
SOCKET_WAIT_INTERRUPT : s32 : 4;

