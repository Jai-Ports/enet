#load "cpp_transpiler_runtime.jai";

callbacks: Callbacks;

allocate_memory :: (size: u64) -> *void {
    memory := callbacks.malloc(size);

    if memory == null {
        callbacks.no_memory();
    }

    return memory;
}

deallocate_memory :: (memory: *void) {
    callbacks.free_(memory);
}

initialize_with_callbacks :: (version: Version, inits: *Callbacks) -> s32 {
    if version < cast,no_check(Version) ((cast(s32) 1) << 16 | ((cast(s32) 3) << 8) | 0) {
        return -1;
    }

    if inits.malloc != null || inits.free_ != null {
        if inits.malloc == null || inits.free_ == null {
            return -1;
        }

        callbacks.malloc = inits.malloc;
        callbacks.free_ = inits.free_;
    }

    if inits.no_memory != null {
        callbacks.no_memory = inits.no_memory;
    }

    return initialize();
}

linked_version :: () -> Version {
    return cast,no_check(Version) ((cast(s32) 1) << 16 | ((cast(s32) 3) << 8) | 18);
}

globals_initialization_state_for_callbacks: u32;
initialize_globals_for_callbacks :: () {
    {
        state := atomic_load(*globals_initialization_state_for_callbacks);
        if state == 2 return;
        won, _ := compare_and_swap(*globals_initialization_state_for_callbacks, 0, 1);
        if !won {
            while atomic_load(*globals_initialization_state_for_callbacks) != 2 {}
            return;
        }
    }
    callbacks =
        Callbacks.{
            malloc = c_transpiler_malloc,
            free_ = c_transpiler_free,
            no_memory = c_transpiler_abort
        };
    atomic_store(*globals_initialization_state_for_callbacks, 2);
}

Version :: Uint32;

Callbacks :: struct {
    malloc: #type (_: u64) -> *void;
    free_: #type (_: *void);
    no_memory: #type ();
}

Uint32 :: u32;

