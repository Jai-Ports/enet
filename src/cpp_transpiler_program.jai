// Generated multi-translation-unit C/C++ to Jai program loader.
// Initialize before publishing translated APIs/callbacks to other threads.
// Call initialize_program once from the host; generated main does this automatically.
#load "callbacks.jai";
#load "compress.jai";
#load "host.jai";
#load "list.jai";
#load "packet.jai";
#load "peer.jai";
#load "protocol.jai";
#load "unix.jai";
program_initialization_state: u32;
program_initialization_owner: u32;
initialize_program :: () {
    state := atomic_load(*program_initialization_state);
    if state == 2 return;
    thread_id := cast(u32) thread_local_index() + 1;
    if state == 1 {
        if atomic_load(*program_initialization_owner) == thread_id return;
        while atomic_load(*program_initialization_state) != 2 {}
        return;
    }
    won, _ := compare_and_swap(*program_initialization_state, 0, 1);
    if !won {
        while atomic_load(*program_initialization_state) != 2 {}
        return;
    }
    atomic_store(*program_initialization_owner, thread_id);
    initialize_globals_for_callbacks();
    initialize_globals_for_packet();
    initialize_globals_for_protocol();
    initialize_globals_for_unix();
    atomic_store(*program_initialization_owner, 0);
    atomic_store(*program_initialization_state, 2);
}
