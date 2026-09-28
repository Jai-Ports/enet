list_clear :: (list: *List) {
    list.sentinel.next = *list.sentinel;
    list.sentinel.previous = *list.sentinel;
}

list_insert :: (position: List_Iterator, data: *void) -> List_Iterator {
    result := cast(List_Iterator) data;

    result.previous = position.previous;
    result.next = position;

    result.previous.next = result;
    position.previous = result;

    return result;
}

list_remove :: (position: List_Iterator) -> *void {
    position.previous.next = position.next;
    position.next.previous = position.previous;

    return cast(*void) position;
}

list_move :: (position: List_Iterator, data_first: *void, data_last: *void) -> List_Iterator {
    first := cast(List_Iterator) data_first;
    last := cast(List_Iterator) data_last;

    first.previous.next = last.next;
    last.next.previous = first.previous;

    first.previous = position.previous;
    last.next = position;

    first.previous.next = first;
    position.previous = last;

    return first;
}

list_size :: (list: *List) -> u64 {
    size: u64 = 0;

    position := list.sentinel.next;
    while position != *list.sentinel {
        size += 1;
        position = position.next;
    }

    return size;
}

List_Iterator :: *List_Node;

