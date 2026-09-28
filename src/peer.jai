dummy_command: Incoming_Command;

peer_send :: (peer: *Peer, channel_id: Uint8, packet: *Packet) -> s32 {
    command: Protocol = ---;

    if peer.state != cast,no_check(u32) PEER_STATE_CONNECTED ||
        cast,no_check(u64) channel_id >= peer.channel_count ||
        packet.data_length > peer.host.maximum_packet_size {
        return -1;
    }

    channel := *peer.channels[channel_id];
    fragment_length := (cast(u64) peer.mtu) - size_of(Protocol_Header) - size_of(Protocol_Send_Fragment);
    if peer.host.checksum != null {
        fragment_length = cast,no_check(u64) (fragment_length - cast(u64) size_of(Uint32));
    }

    if packet.data_length > fragment_length {
        fragment_count := cast,no_check(Uint32) ((packet.data_length + fragment_length - 1) / fragment_length);
        fragment_number: Uint32 = ---;
        fragment_offset: Uint32 = ---;
        command_number: Uint8 = ---;
        start_sequence_number: Uint16 = ---;
        fragments: List = ---;
        fragment: *Outgoing_Command = ---;

        if fragment_count > cast,no_check(Uint32) PROTOCOL_MAXIMUM_FRAGMENT_COUNT {
            return -1;
        }

        if (packet.flags & cast,no_check(Uint32) ((cast,no_check(s32) (PACKET_FLAG_RELIABLE)) | cast,no_check(s32) (PACKET_FLAG_UNRELIABLE_FRAGMENT))) == cast,no_check(Uint32) PACKET_FLAG_UNRELIABLE_FRAGMENT &&
            channel.outgoing_unreliable_sequence_number < 0xffff {
            command_number = cast,no_check(Uint8) PROTOCOL_COMMAND_SEND_UNRELIABLE_FRAGMENT;
            start_sequence_number =
                htons(
                    cast,no_check(u16) ((cast(s32) channel.outgoing_unreliable_sequence_number) + 1)
                );
        } else {
            command_number =
                cast,no_check(Uint8) ((cast,no_check(s32) (PROTOCOL_COMMAND_SEND_FRAGMENT)) | cast,no_check(s32) (PROTOCOL_COMMAND_FLAG_ACKNOWLEDGE));
            start_sequence_number =
                htons(
                    cast,no_check(u16) ((cast(s32) channel.outgoing_reliable_sequence_number) + 1)
                );
        }

        list_clear(*fragments);

        fragment_number = 0;
        fragment_offset = 0;
        while cast,no_check(u64) fragment_offset < packet.data_length {
            if (packet.data_length - cast(u64) fragment_offset) < fragment_length {
                fragment_length = packet.data_length - cast(u64) fragment_offset;
            }

            fragment = cast(*Outgoing_Command) allocate_memory(size_of(Outgoing_Command));
            if fragment == null {
                while !(fragments.sentinel.next == *(fragments.sentinel)) {
                    fragment = cast(*Outgoing_Command) list_remove(fragments.sentinel.next);

                    deallocate_memory(cast(*void) fragment);
                }

                return -1;
            }

            fragment.fragment_offset = fragment_offset;
            fragment.fragment_length = cast,no_check(Uint16) fragment_length;
            fragment.packet = packet;
            fragment.command.header.command = command_number;
            fragment.command.header.channel_id = channel_id;
            fragment.command.send_fragment.start_sequence_number = start_sequence_number;
            fragment.command.send_fragment.data_length = htons(cast,no_check(u16) fragment_length);
            fragment.command.send_fragment.fragment_count = htonl(fragment_count);
            fragment.command.send_fragment.fragment_number = htonl(fragment_number);
            fragment.command.send_fragment.total_length = htonl(cast,no_check(u32) packet.data_length);
            fragment.command.send_fragment.fragment_offset = htonl(fragment_offset);

            list_insert(*(fragments.sentinel), cast(*void) fragment);
            fragment_number += 1;
            fragment_offset = cast,no_check(Uint32) ((cast,no_check(u64) fragment_offset) + fragment_length);
        }

        packet.reference_count += cast,no_check(u64) fragment_number;

        while !(fragments.sentinel.next == *(fragments.sentinel)) {
            fragment = cast(*Outgoing_Command) list_remove(fragments.sentinel.next);

            peer_setup_outgoing_command(peer, fragment);
        }

        return 0;
    }

    command.header.channel_id = channel_id;

    if (packet.flags & cast,no_check(Uint32) ((cast,no_check(s32) (PACKET_FLAG_RELIABLE)) | cast,no_check(s32) (PACKET_FLAG_UNSEQUENCED))) == cast,no_check(Uint32) PACKET_FLAG_UNSEQUENCED {
        command.header.command =
            cast,no_check(Uint8) ((cast,no_check(s32) (PROTOCOL_COMMAND_SEND_UNSEQUENCED)) | cast,no_check(s32) (PROTOCOL_COMMAND_FLAG_UNSEQUENCED));
        command.send_unsequenced.data_length = htons(cast,no_check(u16) packet.data_length);
    } else if packet.flags & cast,no_check(Uint32) PACKET_FLAG_RELIABLE != 0 || channel.outgoing_unreliable_sequence_number >= 0xffff {
        command.header.command =
            cast,no_check(Uint8) ((cast,no_check(s32) (PROTOCOL_COMMAND_SEND_RELIABLE)) | cast,no_check(s32) (PROTOCOL_COMMAND_FLAG_ACKNOWLEDGE));
        command.send_reliable.data_length = htons(cast,no_check(u16) packet.data_length);
    } else {
        command.header.command = cast,no_check(Uint8) PROTOCOL_COMMAND_SEND_UNRELIABLE;
        command.send_unreliable.data_length = htons(cast,no_check(u16) packet.data_length);
    }

    if peer_queue_outgoing_command(peer, *command, packet, 0, cast,no_check(Uint16) packet.data_length) == null {
        return -1;
    }

    return 0;
}

peer_queue_outgoing_command :: (
    peer: *Peer,
    command: *Protocol,
    packet: *Packet,
    offset: Uint32,
    length: Uint16
) -> *Outgoing_Command {
    outgoing_command :=
        cast(*Outgoing_Command) allocate_memory(
            size_of(Outgoing_Command)
        );
    if outgoing_command == null {
        return null;
    }

    outgoing_command.command = command.*;
    outgoing_command.fragment_offset = offset;
    outgoing_command.fragment_length = length;
    outgoing_command.packet = packet;
    if packet != null {
        packet.reference_count += 1;
    }

    peer_setup_outgoing_command(peer, outgoing_command);

    return outgoing_command;
}

peer_setup_outgoing_command :: (peer: *Peer, outgoing_command: *Outgoing_Command) {
    c_transpiler_compound_add(*(peer.outgoing_data_total), ((protocol_command_size(outgoing_command.command.header.command) + cast(u64) outgoing_command.fragment_length)), u64, u64);

    if outgoing_command.command.header.channel_id == 0xff {
        peer.outgoing_reliable_sequence_number += 1;

        outgoing_command.reliable_sequence_number = peer.outgoing_reliable_sequence_number;
        outgoing_command.unreliable_sequence_number = 0;
    } else {
        channel := *peer.channels[outgoing_command.command.header.channel_id];

        if outgoing_command.command.header.command & PROTOCOL_COMMAND_FLAG_ACKNOWLEDGE != 0 {
            channel.outgoing_reliable_sequence_number += 1;
            channel.outgoing_unreliable_sequence_number = 0;

            outgoing_command.reliable_sequence_number = channel.outgoing_reliable_sequence_number;
            outgoing_command.unreliable_sequence_number = 0;
        } else if outgoing_command.command.header.command & PROTOCOL_COMMAND_FLAG_UNSEQUENCED != 0 {
            peer.outgoing_unsequenced_group += 1;

            outgoing_command.reliable_sequence_number = 0;
            outgoing_command.unreliable_sequence_number = 0;
        } else {
            if outgoing_command.fragment_offset == 0 {
                channel.outgoing_unreliable_sequence_number += 1;
            }

            outgoing_command.reliable_sequence_number = channel.outgoing_reliable_sequence_number;
            outgoing_command.unreliable_sequence_number = channel.outgoing_unreliable_sequence_number;
        }
    }

    outgoing_command.send_attempts = 0;
    outgoing_command.sent_time = 0;
    outgoing_command.round_trip_timeout = 0;
    outgoing_command.command.header.reliable_sequence_number = htons(outgoing_command.reliable_sequence_number);
    outgoing_command.queue_time = c_transpiler_pre_increment(*(peer.host.total_queued));

    if ((cast(s32) outgoing_command.command.header.command) & cast,no_check(s32) (PROTOCOL_COMMAND_MASK)) == {
        case PROTOCOL_COMMAND_SEND_UNRELIABLE;
            outgoing_command.command.send_unreliable.unreliable_sequence_number =
                htons(
                    outgoing_command.unreliable_sequence_number
                );
        case PROTOCOL_COMMAND_SEND_UNSEQUENCED;
            outgoing_command.command.send_unsequenced.unsequenced_group = htons(peer.outgoing_unsequenced_group);
        case;
    }

    if outgoing_command.command.header.command & PROTOCOL_COMMAND_FLAG_ACKNOWLEDGE != 0 && outgoing_command.packet != null {
        list_insert(*(peer.outgoing_send_reliable_commands.sentinel), cast(*void) outgoing_command);
    } else {
        list_insert(*(peer.outgoing_commands.sentinel), cast(*void) outgoing_command);
    }
}

peer_receive :: (peer: *Peer, channel_id: *Uint8) -> *Packet {
    if peer.dispatched_commands.sentinel.next == *(peer.dispatched_commands.sentinel) {
        return null;
    }

    incoming_command := cast(*Incoming_Command) list_remove(peer.dispatched_commands.sentinel.next);

    if channel_id != null {
        channel_id.* = incoming_command.command.header.channel_id;
    }

    packet := incoming_command.packet;

    packet.reference_count -= 1;

    if incoming_command.fragments != null {
        deallocate_memory(cast(*void) incoming_command.fragments);
    }

    deallocate_memory(cast(*void) incoming_command);

    peer.total_waiting_data -=
        (ifx peer.total_waiting_data < packet.data_length then peer.total_waiting_data else packet.data_length);

    return packet;
}

peer_ping :: (peer: *Peer) {
    command: Protocol = ---;

    if peer.state != cast,no_check(u32) PEER_STATE_CONNECTED {
        return;
    }

    command.header.command =
        cast,no_check(Uint8) ((cast,no_check(s32) (PROTOCOL_COMMAND_PING)) | cast,no_check(s32) (PROTOCOL_COMMAND_FLAG_ACKNOWLEDGE));
    command.header.channel_id = 0xff;

    peer_queue_outgoing_command(peer, *command, null, 0, 0);
}

peer_ping_interval :: (peer: *Peer, ping_interval: Uint32) {
    peer.ping_interval = ifx ping_interval != 0 then ping_interval else cast,no_check(Uint32) PEER_PING_INTERVAL;
}

peer_timeout :: (peer: *Peer, timeout_limit: Uint32, timeout_minimum: Uint32, timeout_maximum: Uint32) {
    peer.timeout_limit = ifx timeout_limit != 0 then timeout_limit else cast,no_check(Uint32) PEER_TIMEOUT_LIMIT;
    peer.timeout_minimum =
        ifx timeout_minimum != 0 then timeout_minimum else cast,no_check(Uint32) PEER_TIMEOUT_MINIMUM;
    peer.timeout_maximum =
        ifx timeout_maximum != 0 then timeout_maximum else cast,no_check(Uint32) PEER_TIMEOUT_MAXIMUM;
}

peer_reset :: (peer: *Peer) {
    peer_on_disconnect(peer);

    peer.outgoing_peer_id = cast,no_check(Uint16) PROTOCOL_MAXIMUM_PEER_ID;
    peer.connect_id = 0;

    peer.state = cast,no_check(Peer_State) PEER_STATE_DISCONNECTED;

    peer.incoming_bandwidth = 0;
    peer.outgoing_bandwidth = 0;
    peer.incoming_bandwidth_throttle_epoch = 0;
    peer.outgoing_bandwidth_throttle_epoch = 0;
    peer.incoming_data_total = 0;
    peer.outgoing_data_total = 0;
    peer.last_send_time = 0;
    peer.last_receive_time = 0;
    peer.next_timeout = 0;
    peer.earliest_timeout = 0;
    peer.packet_loss_epoch = 0;
    peer.packets_sent = 0;
    peer.packets_lost = 0;
    peer.packet_loss = 0;
    peer.packet_loss_variance = 0;
    peer.packet_throttle = cast,no_check(Uint32) PEER_DEFAULT_PACKET_THROTTLE;
    peer.packet_throttle_limit = cast,no_check(Uint32) PEER_PACKET_THROTTLE_SCALE;
    peer.packet_throttle_counter = 0;
    peer.packet_throttle_epoch = 0;
    peer.packet_throttle_acceleration = cast,no_check(Uint32) PEER_PACKET_THROTTLE_ACCELERATION;
    peer.packet_throttle_deceleration = cast,no_check(Uint32) PEER_PACKET_THROTTLE_DECELERATION;
    peer.packet_throttle_interval = cast,no_check(Uint32) PEER_PACKET_THROTTLE_INTERVAL;
    peer.ping_interval = cast,no_check(Uint32) PEER_PING_INTERVAL;
    peer.timeout_limit = cast,no_check(Uint32) PEER_TIMEOUT_LIMIT;
    peer.timeout_minimum = cast,no_check(Uint32) PEER_TIMEOUT_MINIMUM;
    peer.timeout_maximum = cast,no_check(Uint32) PEER_TIMEOUT_MAXIMUM;
    peer.last_round_trip_time = cast,no_check(Uint32) PEER_DEFAULT_ROUND_TRIP_TIME;
    peer.lowest_round_trip_time = cast,no_check(Uint32) PEER_DEFAULT_ROUND_TRIP_TIME;
    peer.last_round_trip_time_variance = 0;
    peer.highest_round_trip_time_variance = 0;
    peer.round_trip_time = cast,no_check(Uint32) PEER_DEFAULT_ROUND_TRIP_TIME;
    peer.round_trip_time_variance = 0;
    peer.mtu = peer.host.mtu;
    peer.reliable_data_in_transit = 0;
    peer.outgoing_reliable_sequence_number = 0;
    peer.window_size = cast,no_check(Uint32) PROTOCOL_MAXIMUM_WINDOW_SIZE;
    peer.incoming_unsequenced_group = 0;
    peer.outgoing_unsequenced_group = 0;
    peer.event_data = 0;
    peer.total_waiting_data = 0;
    peer.flags = 0;

    fill_memory(peer.unsequenced_window.data, 0, peer.unsequenced_window.count * size_of(Uint32));

    peer_reset_queues(peer);
}

peer_reset_queues :: (peer: *Peer) {
    channel: *Channel = ---;

    if peer.flags & PEER_FLAG_NEEDS_DISPATCH != 0 {
        list_remove(*peer.dispatch_list);

        peer.flags = cast,no_check(Uint16) ((cast,no_check(s32) peer.flags) & cast,no_check(s32) (~(PEER_FLAG_NEEDS_DISPATCH)));
    }

    while !(peer.acknowledgements.sentinel.next == *(peer.acknowledgements.sentinel)) {
        deallocate_memory(list_remove(peer.acknowledgements.sentinel.next));
    }

    peer_reset_outgoing_commands(peer, *peer.sent_reliable_commands);
    peer_reset_outgoing_commands(peer, *peer.outgoing_commands);
    peer_reset_outgoing_commands(peer, *peer.outgoing_send_reliable_commands);
    peer_reset_incoming_commands(peer, *peer.dispatched_commands);

    if peer.channels != null && peer.channel_count > 0 {
        channel = peer.channels;
        while channel < *peer.channels[peer.channel_count] {
            peer_reset_incoming_commands(peer, *channel.incoming_reliable_commands);
            peer_reset_incoming_commands(peer, *channel.incoming_unreliable_commands);
            channel += 1;
        }

        deallocate_memory(cast(*void) peer.channels);
    }

    peer.channels = null;
    peer.channel_count = 0;
}

peer_reset_incoming_commands :: (peer: *Peer, queue: *List) {
    peer_remove_incoming_commands(peer, queue, queue.sentinel.next, *queue.sentinel, null);
}

peer_remove_incoming_commands :: (
    peer: *Peer,
    queue: *List,
    start_command: List_Iterator,
    end_command: List_Iterator,
    exclude_command: *Incoming_Command
) {
    current_command := start_command;
    while current_command != end_command {
        incoming_command := cast(*Incoming_Command) current_command;

        current_command = current_command.next;

        if incoming_command == exclude_command {
            continue;
        }

        list_remove(*incoming_command.incoming_command_list);

        if incoming_command.packet != null {
            incoming_command.packet.reference_count -= 1;

            peer.total_waiting_data -=
                (ifx peer.total_waiting_data < incoming_command.packet.data_length then peer.total_waiting_data else incoming_command.packet.data_length);

            if incoming_command.packet.reference_count == 0 {
                packet_destroy(incoming_command.packet);
            }
        }

        if incoming_command.fragments != null {
            deallocate_memory(cast(*void) incoming_command.fragments);
        }

        deallocate_memory(cast(*void) incoming_command);
    }
}

peer_reset_outgoing_commands :: (peer: *Peer, queue: *List) {
    while !(queue.sentinel.next == *queue.sentinel) {
        outgoing_command := cast(*Outgoing_Command) list_remove(queue.sentinel.next);

        if outgoing_command.packet != null {
            outgoing_command.packet.reference_count -= 1;

            if outgoing_command.packet.reference_count == 0 {
                packet_destroy(outgoing_command.packet);
            }
        }

        deallocate_memory(cast(*void) outgoing_command);
    }
}

peer_on_disconnect :: (peer: *Peer) {
    if peer.state == cast,no_check(u32) PEER_STATE_CONNECTED || peer.state == cast,no_check(u32) PEER_STATE_DISCONNECT_LATER {
        if peer.incoming_bandwidth != 0 {
            peer.host.bandwidth_limited_peers -= 1;
        }

        peer.host.connected_peers -= 1;
    }
}

peer_disconnect :: (peer: *Peer, data: Uint32) {
    command: Protocol = ---;

    if peer.state == cast,no_check(u32) PEER_STATE_DISCONNECTING ||
        peer.state == cast,no_check(u32) PEER_STATE_DISCONNECTED ||
        peer.state == cast,no_check(u32) PEER_STATE_ACKNOWLEDGING_DISCONNECT ||
        peer.state == cast,no_check(u32) PEER_STATE_ZOMBIE {
        return;
    }

    peer_reset_queues(peer);

    command.header.command = cast,no_check(Uint8) PROTOCOL_COMMAND_DISCONNECT;
    command.header.channel_id = 0xff;
    command.disconnect.data = htonl(data);

    if peer.state == cast,no_check(u32) PEER_STATE_CONNECTED || peer.state == cast,no_check(u32) PEER_STATE_DISCONNECT_LATER {
        command.header.command = cast,no_check(Uint8) ((cast,no_check(s32) command.header.command) | cast,no_check(s32) (PROTOCOL_COMMAND_FLAG_ACKNOWLEDGE));
    } else {
        command.header.command = cast,no_check(Uint8) ((cast,no_check(s32) command.header.command) | cast,no_check(s32) (PROTOCOL_COMMAND_FLAG_UNSEQUENCED));
    }

    peer_queue_outgoing_command(peer, *command, null, 0, 0);

    if peer.state == cast,no_check(u32) PEER_STATE_CONNECTED || peer.state == cast,no_check(u32) PEER_STATE_DISCONNECT_LATER {
        peer_on_disconnect(peer);

        peer.state = cast,no_check(Peer_State) PEER_STATE_DISCONNECTING;
    } else {
        host_flush(peer.host);
        peer_reset(peer);
    }
}

peer_disconnect_now :: (peer: *Peer, data: Uint32) {
    command: Protocol = ---;

    if peer.state == cast,no_check(u32) PEER_STATE_DISCONNECTED {
        return;
    }

    if peer.state != cast,no_check(u32) PEER_STATE_ZOMBIE && peer.state != cast,no_check(u32) PEER_STATE_DISCONNECTING {
        peer_reset_queues(peer);

        command.header.command =
            cast,no_check(Uint8) ((cast,no_check(s32) (PROTOCOL_COMMAND_DISCONNECT)) | cast,no_check(s32) (PROTOCOL_COMMAND_FLAG_UNSEQUENCED));
        command.header.channel_id = 0xff;
        command.disconnect.data = htonl(data);

        peer_queue_outgoing_command(peer, *command, null, 0, 0);

        host_flush(peer.host);
    }

    peer_reset(peer);
}

peer_disconnect_later :: (peer: *Peer, data: Uint32) {
    if (peer.state == cast,no_check(u32) PEER_STATE_CONNECTED || peer.state == cast,no_check(u32) PEER_STATE_DISCONNECT_LATER) &&
        peer_has_outgoing_commands(peer) != 0 {
        peer.state = cast,no_check(Peer_State) PEER_STATE_DISCONNECT_LATER;
        peer.event_data = data;
    } else {
        peer_disconnect(peer, data);
    }
}

peer_has_outgoing_commands :: (peer: *Peer) -> s32 {
    if peer.outgoing_commands.sentinel.next == *(peer.outgoing_commands.sentinel) &&
        peer.outgoing_send_reliable_commands.sentinel.next == *(peer.outgoing_send_reliable_commands.sentinel) &&
        peer.sent_reliable_commands.sentinel.next == *(peer.sent_reliable_commands.sentinel) {
        return 0;
    }

    return 1;
}

peer_throttle_configure :: (peer: *Peer, interval: Uint32, acceleration: Uint32, deceleration: Uint32) {
    command: Protocol = ---;

    peer.packet_throttle_interval = interval;
    peer.packet_throttle_acceleration = acceleration;
    peer.packet_throttle_deceleration = deceleration;

    command.header.command =
        cast,no_check(Uint8) ((cast,no_check(s32) (PROTOCOL_COMMAND_THROTTLE_CONFIGURE)) | cast,no_check(s32) (PROTOCOL_COMMAND_FLAG_ACKNOWLEDGE));
    command.header.channel_id = 0xff;

    command.throttle_configure.packet_throttle_interval = htonl(interval);
    command.throttle_configure.packet_throttle_acceleration = htonl(acceleration);
    command.throttle_configure.packet_throttle_deceleration = htonl(deceleration);

    peer_queue_outgoing_command(peer, *command, null, 0, 0);
}

peer_throttle :: (peer: *Peer, rtt: Uint32) -> s32 {
    if peer.last_round_trip_time <= peer.last_round_trip_time_variance {
        peer.packet_throttle = peer.packet_throttle_limit;
    } else if rtt <= peer.last_round_trip_time {
        peer.packet_throttle += peer.packet_throttle_acceleration;

        if peer.packet_throttle > peer.packet_throttle_limit {
            peer.packet_throttle = peer.packet_throttle_limit;
        }

        return 1;
    } else if rtt > peer.last_round_trip_time + 2 * peer.last_round_trip_time_variance {
        if peer.packet_throttle > peer.packet_throttle_deceleration {
            peer.packet_throttle -= peer.packet_throttle_deceleration;
        } else {
            peer.packet_throttle = 0;
        }

        return -1;
    }

    return 0;
}

peer_queue_incoming_command :: (
    peer: *Peer,
    command: *Protocol,
    data: *void,
    data_length: u64,
    flags: Uint32,
    fragment_count: Uint32
) -> *Incoming_Command {
    channel: *Channel = ---;
    unreliable_sequence_number: Uint32 = ---;
    reliable_sequence_number: Uint32 = ---;
    reliable_window: Uint16 = ---;
    current_window: Uint16 = ---;
    incoming_command: *Incoming_Command = ---;
    current_command: List_Iterator = ---;
    packet: *Packet = ---;
    code_block_to_execute: s64 = 110;
    // The transpiler had to use this control-flow loop because the source code used a goto, which Jai does not support.
    while c_transpiler_dispatch := true {
        if code_block_to_execute < 0 break;
        if code_block_to_execute == {
            case 13; {
                if packet != null && packet.reference_count == 0 {
                    packet_destroy(packet);
                    return null;
                } else {
                    return null;
                }
            }
            case 18; {
                if fragment_count > 0 {
                    code_block_to_execute = 13;
                    continue c_transpiler_dispatch;
                } else {
                    if packet != null && packet.reference_count == 0 {
                        packet_destroy(packet);
                        return *dummy_command;
                    } else {
                        return *dummy_command;
                    }
                }
            }
            case 25; {
                list_insert(current_command.next, cast(*void) incoming_command);
                c_transpiler_switch_value_25 := ((cast(s32) command.header.command) & cast,no_check(s32) (PROTOCOL_COMMAND_MASK));
                if c_transpiler_switch_value_25 == {
                    case PROTOCOL_COMMAND_SEND_FRAGMENT; {
                        peer_dispatch_incoming_reliable_commands(peer, channel, incoming_command);
                        return incoming_command;
                    }
                    case PROTOCOL_COMMAND_SEND_RELIABLE; {
                        peer_dispatch_incoming_reliable_commands(peer, channel, incoming_command);
                        return incoming_command;
                    }
                    case; {
                        peer_dispatch_incoming_unreliable_commands(peer, channel, incoming_command);
                        return incoming_command;
                    }
                }
            }
            case 28; {
                if packet != null {
                    packet.reference_count += 1;
                    peer.total_waiting_data += packet.data_length;
                    code_block_to_execute = 25;
                    continue c_transpiler_dispatch;
                } else {
                    code_block_to_execute = 25;
                    continue c_transpiler_dispatch;
                }
            }
            case 32; {
                if incoming_command.fragments == null {
                    deallocate_memory(cast(*void) incoming_command);
                    code_block_to_execute = 13;
                    continue c_transpiler_dispatch;
                } else {
                    fill_memory(
                        incoming_command.fragments,
                        0,
                        cast,no_check(u64) ((fragment_count + 31) / 32) * size_of(Uint32)
                    );
                    code_block_to_execute = 28;
                    continue c_transpiler_dispatch;
                }
            }
            case 50; {
                if peer.total_waiting_data >= peer.host.maximum_waiting_data {
                    code_block_to_execute = 13;
                    continue c_transpiler_dispatch;
                } else {
                    packet = packet_create(data, data_length, flags);
                    if packet == null {
                        code_block_to_execute = 13;
                        continue c_transpiler_dispatch;
                    } else {
                        incoming_command =
                            cast(*Incoming_Command) allocate_memory(
                                size_of(Incoming_Command)
                            );
                        if incoming_command == null {
                            code_block_to_execute = 13;
                            continue c_transpiler_dispatch;
                        } else {
                            incoming_command.reliable_sequence_number = command.header.reliable_sequence_number;
                            incoming_command.unreliable_sequence_number =
                                cast,no_check(Uint16) (unreliable_sequence_number & 0xffff);
                            incoming_command.command = command.*;
                            incoming_command.fragment_count = fragment_count;
                            incoming_command.fragments_remaining = fragment_count;
                            incoming_command.packet = packet;
                            incoming_command.fragments = null;
                            if fragment_count > 0 {
                                if fragment_count <= cast,no_check(Uint32) PROTOCOL_MAXIMUM_FRAGMENT_COUNT {
                                    incoming_command.fragments =
                                        cast(*Uint32) allocate_memory(
                                            (cast(u64) ((fragment_count + 31) / 32)) * size_of(Uint32)
                                        );
                                    code_block_to_execute = 32;
                                    continue c_transpiler_dispatch;
                                } else {
                                    code_block_to_execute = 32;
                                    continue c_transpiler_dispatch;
                                }
                            } else {
                                code_block_to_execute = 28;
                                continue c_transpiler_dispatch;
                            }
                        }
                    }
                }
            }
            case 55; {
                if current_command != *(channel.incoming_unreliable_commands.sentinel) {
                    code_block_to_execute = 72;
                    continue c_transpiler_dispatch;
                } else {
                    code_block_to_execute = 50;
                    continue c_transpiler_dispatch;
                }
            }
            case 56; {
                current_command = current_command.previous;
                code_block_to_execute = 55;
                continue c_transpiler_dispatch;
            }
            case 64; {
                if cast,no_check(Uint32) incoming_command.reliable_sequence_number < reliable_sequence_number {
                    code_block_to_execute = 50;
                    continue c_transpiler_dispatch;
                } else {
                    if cast,no_check(Uint32) incoming_command.reliable_sequence_number > reliable_sequence_number {
                        code_block_to_execute = 56;
                        continue c_transpiler_dispatch;
                    } else {
                        if cast,no_check(Uint32) incoming_command.unreliable_sequence_number <= unreliable_sequence_number {
                            if cast,no_check(Uint32) incoming_command.unreliable_sequence_number < unreliable_sequence_number {
                                code_block_to_execute = 50;
                                continue c_transpiler_dispatch;
                            } else {
                                code_block_to_execute = 18;
                                continue c_transpiler_dispatch;
                            }
                        } else {
                            code_block_to_execute = 56;
                            continue c_transpiler_dispatch;
                        }
                    }
                }
            }
            case 72; {
                incoming_command = cast(*Incoming_Command) current_command;
                if ((cast(s32) command.header.command) & cast,no_check(s32) (PROTOCOL_COMMAND_MASK)) == PROTOCOL_COMMAND_SEND_UNSEQUENCED {
                    code_block_to_execute = 56;
                    continue c_transpiler_dispatch;
                } else {
                    if reliable_sequence_number >= cast,no_check(Uint32) channel.incoming_reliable_sequence_number {
                        if incoming_command.reliable_sequence_number < channel.incoming_reliable_sequence_number {
                            code_block_to_execute = 56;
                            continue c_transpiler_dispatch;
                        } else {
                            code_block_to_execute = 64;
                            continue c_transpiler_dispatch;
                        }
                    } else {
                        if incoming_command.reliable_sequence_number >= channel.incoming_reliable_sequence_number {
                            code_block_to_execute = 50;
                            continue c_transpiler_dispatch;
                        } else {
                            code_block_to_execute = 64;
                            continue c_transpiler_dispatch;
                        }
                    }
                }
            }
            case 76; {
                unreliable_sequence_number =
                    cast,no_check(Uint32) ntohs(
                        command.send_unreliable.unreliable_sequence_number
                    );
                if reliable_sequence_number == cast,no_check(Uint32) channel.incoming_reliable_sequence_number && unreliable_sequence_number <= cast,no_check(Uint32) channel.incoming_unreliable_sequence_number {
                    code_block_to_execute = 18;
                    continue c_transpiler_dispatch;
                } else {
                    current_command = channel.incoming_unreliable_commands.sentinel.previous;
                    code_block_to_execute = 55;
                    continue c_transpiler_dispatch;
                }
            }
            case 78; {
                if current_command != *(channel.incoming_reliable_commands.sentinel) {
                    code_block_to_execute = 89;
                    continue c_transpiler_dispatch;
                } else {
                    code_block_to_execute = 50;
                    continue c_transpiler_dispatch;
                }
            }
            case 79; {
                current_command = current_command.previous;
                code_block_to_execute = 78;
                continue c_transpiler_dispatch;
            }
            case 83; {
                if cast,no_check(Uint32) incoming_command.reliable_sequence_number <= reliable_sequence_number {
                    if cast,no_check(Uint32) incoming_command.reliable_sequence_number < reliable_sequence_number {
                        code_block_to_execute = 50;
                        continue c_transpiler_dispatch;
                    } else {
                        code_block_to_execute = 18;
                        continue c_transpiler_dispatch;
                    }
                } else {
                    code_block_to_execute = 79;
                    continue c_transpiler_dispatch;
                }
            }
            case 89; {
                incoming_command = cast(*Incoming_Command) current_command;
                if reliable_sequence_number >= cast,no_check(Uint32) channel.incoming_reliable_sequence_number {
                    if incoming_command.reliable_sequence_number < channel.incoming_reliable_sequence_number {
                        code_block_to_execute = 79;
                        continue c_transpiler_dispatch;
                    } else {
                        code_block_to_execute = 83;
                        continue c_transpiler_dispatch;
                    }
                } else {
                    if incoming_command.reliable_sequence_number >= channel.incoming_reliable_sequence_number {
                        code_block_to_execute = 50;
                        continue c_transpiler_dispatch;
                    } else {
                        code_block_to_execute = 83;
                        continue c_transpiler_dispatch;
                    }
                }
            }
            case 92; {
                if reliable_sequence_number == cast,no_check(Uint32) channel.incoming_reliable_sequence_number {
                    code_block_to_execute = 18;
                    continue c_transpiler_dispatch;
                } else {
                    current_command = channel.incoming_reliable_commands.sentinel.previous;
                    code_block_to_execute = 78;
                    continue c_transpiler_dispatch;
                }
            }
            case 93; {
                c_transpiler_switch_value_93 := ((cast(s32) command.header.command) & cast,no_check(s32) (PROTOCOL_COMMAND_MASK));
                if c_transpiler_switch_value_93 == {
                    case PROTOCOL_COMMAND_SEND_FRAGMENT; {
                        code_block_to_execute = 92;
                        continue c_transpiler_dispatch;
                    }
                    case PROTOCOL_COMMAND_SEND_RELIABLE; {
                        code_block_to_execute = 92;
                        continue c_transpiler_dispatch;
                    }
                    case PROTOCOL_COMMAND_SEND_UNRELIABLE; {
                        code_block_to_execute = 76;
                        continue c_transpiler_dispatch;
                    }
                    case PROTOCOL_COMMAND_SEND_UNRELIABLE_FRAGMENT; {
                        code_block_to_execute = 76;
                        continue c_transpiler_dispatch;
                    }
                    case PROTOCOL_COMMAND_SEND_UNSEQUENCED; {
                        current_command = *(channel.incoming_unreliable_commands.sentinel);
                        code_block_to_execute = 50;
                        continue c_transpiler_dispatch;
                    }
                    case; {
                        code_block_to_execute = 18;
                        continue c_transpiler_dispatch;
                    }
                }
            }
            case 95; {
                if reliable_window < current_window || cast,no_check(s32) reliable_window >= ((cast(s32) current_window) + cast,no_check(s32) (PEER_FREE_RELIABLE_WINDOWS)) - 1 {
                    code_block_to_execute = 18;
                    continue c_transpiler_dispatch;
                } else {
                    code_block_to_execute = 93;
                    continue c_transpiler_dispatch;
                }
            }
            case 110; {
                channel = *peer.channels[command.header.channel_id];
                unreliable_sequence_number = 0;
                reliable_sequence_number = 0;
                packet = null;
                if peer.state == cast,no_check(u32) PEER_STATE_DISCONNECT_LATER {
                    code_block_to_execute = 18;
                    continue c_transpiler_dispatch;
                } else {
                    if ((cast(s32) command.header.command) & cast,no_check(s32) (PROTOCOL_COMMAND_MASK)) != PROTOCOL_COMMAND_SEND_UNSEQUENCED {
                        reliable_sequence_number = cast,no_check(Uint32) command.header.reliable_sequence_number;
                        reliable_window =
                            cast,no_check(Uint16) (reliable_sequence_number /
                                cast,no_check(Uint32) PEER_RELIABLE_WINDOW_SIZE);
                        current_window =
                            channel.incoming_reliable_sequence_number /
                                cast(Uint16) PEER_RELIABLE_WINDOW_SIZE;
                        if reliable_sequence_number < cast,no_check(Uint32) channel.incoming_reliable_sequence_number {
                            reliable_window = cast,no_check(Uint16) ((cast,no_check(s32) reliable_window) + cast,no_check(s32) (PEER_RELIABLE_WINDOWS));
                            code_block_to_execute = 95;
                            continue c_transpiler_dispatch;
                        } else {
                            code_block_to_execute = 95;
                            continue c_transpiler_dispatch;
                        }
                    } else {
                        code_block_to_execute = 93;
                        continue c_transpiler_dispatch;
                    }
                }
            }
        }
        assert(false, tprint("invalid code block to execute %", code_block_to_execute));
        break;
    }
    return unreachable_value(*Incoming_Command);
}

peer_dispatch_incoming_unreliable_commands :: (peer: *Peer, channel: *Channel, queued_command: *Incoming_Command) {
    dropped_command, start_command, current_command: List_Iterator = ---;

    current_command = channel.incoming_unreliable_commands.sentinel.next;
    start_command = current_command;
    dropped_command = start_command;
    while current_command != *(channel.incoming_unreliable_commands.sentinel) {
        incoming_command := cast(*Incoming_Command) current_command;

        if ((cast(s32) incoming_command.command.header.command) & cast,no_check(s32) (PROTOCOL_COMMAND_MASK)) == PROTOCOL_COMMAND_SEND_UNSEQUENCED {
            current_command = current_command.next;
            continue;
        }

        if incoming_command.reliable_sequence_number == channel.incoming_reliable_sequence_number {
            if incoming_command.fragments_remaining <= 0 {
                channel.incoming_unreliable_sequence_number = incoming_command.unreliable_sequence_number;
                current_command = current_command.next;
                continue;
            }

            if start_command != current_command {
                list_move(
                    *(peer.dispatched_commands.sentinel),
                    cast(*void) start_command,
                    cast(*void) current_command.previous
                );

                if (cast(s32) peer.flags) & cast,no_check(s32) (PEER_FLAG_NEEDS_DISPATCH) == 0 {
                    list_insert(*(peer.host.dispatch_queue.sentinel), cast(*void) *peer.dispatch_list);

                    peer.flags = cast,no_check(Uint16) ((cast,no_check(s32) peer.flags) | cast,no_check(s32) (PEER_FLAG_NEEDS_DISPATCH));
                }

                dropped_command = current_command;
            } else if dropped_command != current_command {
                dropped_command = current_command.previous;
            }
        } else {
            reliable_window := incoming_command.reliable_sequence_number / cast(Uint16) PEER_RELIABLE_WINDOW_SIZE;
            current_window := channel.incoming_reliable_sequence_number / cast(Uint16) PEER_RELIABLE_WINDOW_SIZE;
            if incoming_command.reliable_sequence_number < channel.incoming_reliable_sequence_number {
                reliable_window = cast,no_check(Uint16) ((cast,no_check(s32) reliable_window) + cast,no_check(s32) (PEER_RELIABLE_WINDOWS));
            }
            if reliable_window >= current_window &&
                cast,no_check(s32) reliable_window < ((cast(s32) current_window) + cast,no_check(s32) (PEER_FREE_RELIABLE_WINDOWS)) - 1 {
                break;
            }

            dropped_command = current_command.next;

            if start_command != current_command {
                list_move(
                    *(peer.dispatched_commands.sentinel),
                    cast(*void) start_command,
                    cast(*void) current_command.previous
                );

                if (cast(s32) peer.flags) & cast,no_check(s32) (PEER_FLAG_NEEDS_DISPATCH) == 0 {
                    list_insert(*(peer.host.dispatch_queue.sentinel), cast(*void) *peer.dispatch_list);

                    peer.flags = cast,no_check(Uint16) ((cast,no_check(s32) peer.flags) | cast,no_check(s32) (PEER_FLAG_NEEDS_DISPATCH));
                }
            }
        }

        start_command = current_command.next;
        current_command = current_command.next;
    }

    if start_command != current_command {
        list_move(*(peer.dispatched_commands.sentinel), cast(*void) start_command, cast(*void) current_command.previous);

        if (cast(s32) peer.flags) & cast,no_check(s32) (PEER_FLAG_NEEDS_DISPATCH) == 0 {
            list_insert(*(peer.host.dispatch_queue.sentinel), cast(*void) *peer.dispatch_list);

            peer.flags = cast,no_check(Uint16) ((cast,no_check(s32) peer.flags) | cast,no_check(s32) (PEER_FLAG_NEEDS_DISPATCH));
        }

        dropped_command = current_command;
    }

    peer_remove_incoming_commands(
        peer,
        *channel.incoming_unreliable_commands,
        channel.incoming_unreliable_commands.sentinel.next,
        dropped_command,
        queued_command
    );
}

peer_dispatch_incoming_reliable_commands :: (peer: *Peer, channel: *Channel, queued_command: *Incoming_Command) {
    current_command := channel.incoming_reliable_commands.sentinel.next;
    while current_command != *(channel.incoming_reliable_commands.sentinel) {
        incoming_command := cast(*Incoming_Command) current_command;

        if incoming_command.fragments_remaining > 0 ||
            incoming_command.reliable_sequence_number != cast,no_check(Uint16) ((cast(s32) channel.incoming_reliable_sequence_number) + 1) {
            break;
        }

        channel.incoming_reliable_sequence_number = incoming_command.reliable_sequence_number;

        if incoming_command.fragment_count > 0 {
            channel.incoming_reliable_sequence_number = cast,no_check(Uint16) ((cast,no_check(Uint32) channel.incoming_reliable_sequence_number) + (incoming_command.fragment_count - 1));
        }
        current_command = current_command.next;
    }

    if current_command == channel.incoming_reliable_commands.sentinel.next {
        return;
    }

    channel.incoming_unreliable_sequence_number = 0;

    list_move(
        *(peer.dispatched_commands.sentinel),
        cast(*void) channel.incoming_reliable_commands.sentinel.next,
        cast(*void) current_command.previous
    );

    if (cast(s32) peer.flags) & cast,no_check(s32) (PEER_FLAG_NEEDS_DISPATCH) == 0 {
        list_insert(*(peer.host.dispatch_queue.sentinel), cast(*void) *peer.dispatch_list);

        peer.flags = cast,no_check(Uint16) ((cast,no_check(s32) peer.flags) | cast,no_check(s32) (PEER_FLAG_NEEDS_DISPATCH));
    }

    if !(channel.incoming_unreliable_commands.sentinel.next == *(channel.incoming_unreliable_commands.sentinel)) {
        peer_dispatch_incoming_unreliable_commands(peer, channel, queued_command);
    }
}

peer_queue_acknowledgement :: (peer: *Peer, command: *Protocol, sent_time: Uint16) -> *Acknowledgement {
    if cast,no_check(u64) command.header.channel_id < peer.channel_count {
        channel := *peer.channels[command.header.channel_id];
        reliable_window := command.header.reliable_sequence_number / cast(Uint16) PEER_RELIABLE_WINDOW_SIZE;
        current_window := channel.incoming_reliable_sequence_number / cast(Uint16) PEER_RELIABLE_WINDOW_SIZE;

        if command.header.reliable_sequence_number < channel.incoming_reliable_sequence_number {
            reliable_window = cast,no_check(Uint16) ((cast,no_check(s32) reliable_window) + cast,no_check(s32) (PEER_RELIABLE_WINDOWS));
        }

        if cast,no_check(s32) reliable_window >= ((cast(s32) current_window) + cast,no_check(s32) (PEER_FREE_RELIABLE_WINDOWS)) - 1 &&
            cast,no_check(s32) reliable_window <= (cast(s32) current_window) + cast,no_check(s32) (PEER_FREE_RELIABLE_WINDOWS) {
            return null;
        }
    }

    acknowledgement := cast(*Acknowledgement) allocate_memory(size_of(Acknowledgement));
    if acknowledgement == null {
        return null;
    }

    peer.outgoing_data_total = cast,no_check(Uint32) ((cast,no_check(u64) peer.outgoing_data_total) + cast(u64) size_of(Protocol_Acknowledge));

    acknowledgement.sent_time = cast,no_check(Uint32) sent_time;
    acknowledgement.command = command.*;

    list_insert(*(peer.acknowledgements.sentinel), cast(*void) acknowledgement);

    return acknowledgement;
}

peer_on_connect :: (peer: *Peer) {
    if peer.state != cast,no_check(u32) PEER_STATE_CONNECTED && peer.state != cast,no_check(u32) PEER_STATE_DISCONNECT_LATER {
        if peer.incoming_bandwidth != 0 {
            peer.host.bandwidth_limited_peers += 1;
        }

        peer.host.connected_peers += 1;
    }
}

ntohs :: (netshort: u16) -> u16 {
    return C_Transpiler_Bit_Operations.byte_swap(netshort);
}

Peer_Flag :: u32;
PEER_FLAG_NEEDS_DISPATCH : s32 : 1;
PEER_FLAG_CONTINUE_SENDING : s32 : 2;

Incoming_Command :: struct {
    incoming_command_list: List_Node #align 8;
    reliable_sequence_number: Uint16 #align 1;
    unreliable_sequence_number: Uint16 #align 1;
    command: Protocol #align 1;
    fragment_count: Uint32 #align 1;
    fragments_remaining: Uint32 #align 1;
    layout_padding_0: [4] u8 #align 1;
    fragments: *Uint32 #align 1;
    packet: *Packet #align 1;
} #no_padding;

Protocol_Header :: struct {
    peer_id: Uint16 #align 1;
    sent_time: Uint16 #align 1;
} #no_padding;

Acknowledgement :: struct {
    acknowledgement_list: List_Node #align 8;
    sent_time: Uint32 #align 1;
    command: Protocol #align 1;
    layout_padding_0: [4] u8 #align 1;
} #no_padding;

