Range_Coder :: struct {
    symbols: [4096] Symbol;
}

Symbol :: struct {
    value: Uint8;
    count: Uint8;
    under: Uint16;
    left: Uint16;
    right: Uint16;
    symbols: Uint16;
    escapes: Uint16;
    total: Uint16;
    parent: Uint16;
}

Values_in_compress :: u32;
RANGE_CODER_TOP : s32 : 16777216;
RANGE_CODER_BOTTOM : s32 : 65536;
CONTEXT_SYMBOL_DELTA : s32 : 3;
CONTEXT_SYMBOL_MINIMUM : s32 : 1;
CONTEXT_ESCAPE_MINIMUM : s32 : 1;
SUBCONTEXT_ORDER : s32 : 2;
SUBCONTEXT_SYMBOL_DELTA : s32 : 2;
SUBCONTEXT_ESCAPE_DELTA : s32 : 5;

host_compress_with_range_coder :: (host: *Host) -> s32 {
    compressor: Compressor = ---;
    fill_memory(*compressor, 0, size_of(Compressor));
    compressor.context_ = range_coder_create();
    if compressor.context_ == null {
        return -1;
    }
    compressor.compress = range_coder_compress;
    compressor.decompress = range_coder_decompress;
    compressor.destroy = range_coder_destroy;
    host_compress(host, *compressor);
    return 0;
}

range_coder_destroy :: (context_: *void) {
    range_coder := cast(*Range_Coder) context_;
    if range_coder == null {
        return;
    }

    deallocate_memory(cast(*void) range_coder);
}

range_coder_decompress :: (context_: *void, in_data: *Uint8, in_limit: u64, out_data: *Uint8, out_limit: u64) -> u64 {
    range_coder := cast(*Range_Coder) context_;
    out_start := out_data;
    out_end := *out_data[out_limit];
    in_end := *in_data[in_limit];
    decode_low: Uint32 = 0;
    decode_code: Uint32 = 0;
    decode_range: Uint32 = 0xffffffff;
    root: *Symbol = ---;
    predicted: Uint16 = 0;
    order: u64 = 0;
    next_symbol: u64 = 0;

    if range_coder == null || in_limit <= 0 {
        return 0;
    }

    root = range_coder.symbols.data + c_transpiler_post_increment(*(next_symbol));

    root.value = 0;

    root.count = 0;

    root.under = 0;

    root.left = 0;

    root.right = 0;

    root.symbols = 0;

    root.escapes = 0;

    root.total = 0;

    root.parent = 0;

    root.escapes = cast,no_check(Uint16) CONTEXT_ESCAPE_MINIMUM;

    root.total =
        cast,no_check(Uint16) ((cast,no_check(s32) (CONTEXT_ESCAPE_MINIMUM)) +
            256 * cast,no_check(s32) (CONTEXT_SYMBOL_MINIMUM));

    root.symbols = 0;

    if in_data < in_end {
        decode_code |= cast,no_check(Uint32) ((cast(s32) ((c_transpiler_post_increment(*(in_data))).*)) << 24);
    }

    if in_data < in_end {
        decode_code |= cast,no_check(Uint32) ((cast(s32) ((c_transpiler_post_increment(*(in_data))).*)) << 16);
    }

    if in_data < in_end {
        decode_code |= cast,no_check(Uint32) ((cast(s32) ((c_transpiler_post_increment(*(in_data))).*)) << 8);
    }

    if in_data < in_end {
        decode_code |= cast,no_check(Uint32) ((c_transpiler_post_increment(*(in_data))).*);
    }

    while loop := true {
        subcontext, symbol, patch: *Symbol = ---;
        value: Uint8 = 0;
        code: Uint16 = ---;
        under: Uint16 = ---;
        count: Uint16 = ---;
        bottom: Uint16 = ---;
        parent := *predicted;
        total: Uint16 = ---;
        while patch_contexts := true { // Forward-goto shim; executes at most once.
            subcontext = range_coder.symbols.data + predicted;
            while subcontext != root {
                if subcontext.escapes <= 0 {
                    subcontext = range_coder.symbols.data + subcontext.parent;
                    continue;
                }
                total = subcontext.total;

                if subcontext.escapes >= total {
                    subcontext = range_coder.symbols.data + subcontext.parent;
                    continue;
                }
                code =
                    cast,no_check(Uint16) ((decode_code - decode_low) /
                        c_transpiler_compound_div(*(decode_range), (cast,no_check(Uint32) total), Uint32, Uint32));
                if code < subcontext.escapes {
                    decode_low += 0 * decode_range;

                    decode_range *= cast,no_check(Uint32) subcontext.escapes;

                    while true {
                        if decode_low ^ (decode_low + decode_range) >= cast,no_check(Uint32) RANGE_CODER_TOP {
                            if decode_range >= cast,no_check(Uint32) RANGE_CODER_BOTTOM {
                                break;
                            }

                            decode_range =
                                (cast,no_check(Uint32) (0 - cast(s64) (decode_low))) & cast,no_check(Uint32) ((cast,no_check(s32) (RANGE_CODER_BOTTOM)) -
                                    1);
                        }

                        c_transpiler_compound_shl(*(decode_code), (cast(s32) 8), Uint32, Uint32);

                        if in_data < in_end {
                            decode_code |= cast,no_check(Uint32) ((c_transpiler_post_increment(*(in_data))).*);
                        }

                        c_transpiler_compound_shl(*(decode_range), (cast(s32) 8), Uint32, Uint32);

                        c_transpiler_compound_shl(*(decode_low), (cast(s32) 8), Uint32, Uint32);
                    }
                    subcontext = range_coder.symbols.data + subcontext.parent;
                    continue;
                }
                code = cast,no_check(Uint16) ((cast,no_check(s32) code) - cast,no_check(s32) subcontext.escapes);

                under = 0;

                count = 0;

                if subcontext.symbols == 0 {
                    return 0;
                } else {
                    node := subcontext + cast,no_check(s32) subcontext.symbols;

                    while true {
                        after :=
                            cast,no_check(Uint16) (((cast(s32) under) + cast(s32) node.under) +
                                ((cast(s32) node.value) + 1) * 0);
                        before := cast,no_check(Uint16) ((cast(s32) node.count) + 0);

                        if code >= after {
                            under = cast,no_check(Uint16) ((cast,no_check(s32) under) + cast,no_check(s32) node.under);

                            if node.right != 0 {
                                node += cast,no_check(s32) node.right;

                                continue;
                            }

                            return 0;
                        } else if cast,no_check(s32) code < (cast(s32) after) - cast(s32) before {
                            node.under = cast,no_check(Uint16) ((cast,no_check(s32) node.under) + cast,no_check(s32) (SUBCONTEXT_SYMBOL_DELTA));

                            if node.left != 0 {
                                node += cast,no_check(s32) node.left;

                                continue;
                            }

                            return 0;
                        } else {
                            value = node.value;

                            count = cast,no_check(Uint16) ((cast,no_check(s32) count) + cast,no_check(s32) node.count);

                            under = cast,no_check(Uint16) ((cast(s32) after) - cast(s32) before);

                            node.under = cast,no_check(Uint16) ((cast,no_check(s32) node.under) + cast,no_check(s32) (SUBCONTEXT_SYMBOL_DELTA));

                            node.count = cast,no_check(Uint8) ((cast,no_check(s32) node.count) + cast,no_check(s32) (SUBCONTEXT_SYMBOL_DELTA));

                            symbol = node;
                        }

                        break;
                    }
                }
                bottom = cast,no_check(Uint16) (symbol - range_coder.symbols.data);
                decode_low += (cast,no_check(Uint32) ((cast(s32) subcontext.escapes) + cast(s32) under)) * decode_range;

                decode_range *= cast,no_check(Uint32) count;

                while true {
                    if decode_low ^ (decode_low + decode_range) >= cast,no_check(Uint32) RANGE_CODER_TOP {
                        if decode_range >= cast,no_check(Uint32) RANGE_CODER_BOTTOM {
                            break;
                        }

                        decode_range =
                            (cast,no_check(Uint32) (0 - cast(s64) (decode_low))) & cast,no_check(Uint32) ((cast,no_check(s32) (RANGE_CODER_BOTTOM)) -
                                1);
                    }

                    c_transpiler_compound_shl(*(decode_code), (cast(s32) 8), Uint32, Uint32);

                    if in_data < in_end {
                        decode_code |= cast,no_check(Uint32) ((c_transpiler_post_increment(*(in_data))).*);
                    }

                    c_transpiler_compound_shl(*(decode_range), (cast(s32) 8), Uint32, Uint32);

                    c_transpiler_compound_shl(*(decode_low), (cast(s32) 8), Uint32, Uint32);
                }
                subcontext.total = cast,no_check(Uint16) ((cast,no_check(s32) subcontext.total) + cast,no_check(s32) (SUBCONTEXT_SYMBOL_DELTA));
                if cast,no_check(s32) count > 0xff - 2 * cast,no_check(s32) (SUBCONTEXT_SYMBOL_DELTA) ||
                    cast,no_check(s32) subcontext.total > (cast,no_check(s32) (RANGE_CODER_BOTTOM)) - 0x100 {
                    subcontext.total =
                        cast,no_check(Uint16) ((ifx subcontext.symbols != 0 then cast,no_check(s32) symbol_rescale(
                            subcontext + cast,no_check(s32) subcontext.symbols
                        ) else 0));

                    subcontext.escapes = cast,no_check(Uint16) ((cast,no_check(s32) subcontext.escapes) - ((cast(s32) subcontext.escapes) >> 1));

                    subcontext.total = cast,no_check(Uint16) ((cast,no_check(s32) subcontext.total) + ((cast(s32) subcontext.escapes) + cast,no_check(s32) ((256 * 0))));
                }
                break patch_contexts;
            }
            total = root.total;
            code =
                cast,no_check(Uint16) ((decode_code - decode_low) /
                    c_transpiler_compound_div(*(decode_range), (cast,no_check(Uint32) total), Uint32, Uint32));
            if code < root.escapes {
                decode_low += 0 * decode_range;

                decode_range *= cast,no_check(Uint32) root.escapes;

                while true {
                    if decode_low ^ (decode_low + decode_range) >= cast,no_check(Uint32) RANGE_CODER_TOP {
                        if decode_range >= cast,no_check(Uint32) RANGE_CODER_BOTTOM {
                            break;
                        }

                        decode_range =
                            (cast,no_check(Uint32) (0 - cast(s64) (decode_low))) & cast,no_check(Uint32) ((cast,no_check(s32) (RANGE_CODER_BOTTOM)) -
                                1);
                    }

                    c_transpiler_compound_shl(*(decode_code), (cast(s32) 8), Uint32, Uint32);

                    if in_data < in_end {
                        decode_code |= cast,no_check(Uint32) ((c_transpiler_post_increment(*(in_data))).*);
                    }

                    c_transpiler_compound_shl(*(decode_range), (cast(s32) 8), Uint32, Uint32);

                    c_transpiler_compound_shl(*(decode_low), (cast(s32) 8), Uint32, Uint32);
                }
                break loop;
            }
            code = cast,no_check(Uint16) ((cast,no_check(s32) code) - cast,no_check(s32) root.escapes);
            {
                under = 0;

                count = cast,no_check(Uint16) CONTEXT_SYMBOL_MINIMUM;

                if root.symbols == 0 {
                    value = cast,no_check(Uint8) ((cast(s32) code) / cast,no_check(s32) (CONTEXT_SYMBOL_MINIMUM));

                    under =
                        cast,no_check(Uint16) ((cast(s32) code) -
                            (cast(s32) code) % cast,no_check(s32) (CONTEXT_SYMBOL_MINIMUM));

                    symbol = range_coder.symbols.data + c_transpiler_post_increment(*(next_symbol));

                    symbol.value = value;

                    symbol.count = cast,no_check(Uint8) CONTEXT_SYMBOL_DELTA;

                    symbol.under = cast,no_check(Uint16) CONTEXT_SYMBOL_DELTA;

                    symbol.left = 0;

                    symbol.right = 0;

                    symbol.symbols = 0;

                    symbol.escapes = 0;

                    symbol.total = 0;

                    symbol.parent = 0;

                    root.symbols = cast,no_check(Uint16) (symbol - root);
                } else {
                    node := root + cast,no_check(s32) root.symbols;

                    while true {
                        after :=
                            cast,no_check(Uint16) (((cast(s32) under) + cast(s32) node.under) +
                                ((cast(s32) node.value) + 1) * cast,no_check(s32) (CONTEXT_SYMBOL_MINIMUM));
                        before :=
                            cast,no_check(Uint16) ((cast(s32) node.count) +
                                cast,no_check(s32) (CONTEXT_SYMBOL_MINIMUM));

                        if code >= after {
                            under = cast,no_check(Uint16) ((cast,no_check(s32) under) + cast,no_check(s32) node.under);

                            if node.right != 0 {
                                node += cast,no_check(s32) node.right;

                                continue;
                            }

                            value =
                                cast,no_check(Uint8) ((cast(s32) node.value) + 1 +
                                    ((cast(s32) code) - cast(s32) after) / cast,no_check(s32) (CONTEXT_SYMBOL_MINIMUM));

                            under =
                                cast,no_check(Uint16) ((cast(s32) code) -
                                    ((cast(s32) code) - cast(s32) after) % cast,no_check(s32) (CONTEXT_SYMBOL_MINIMUM));

                            symbol = range_coder.symbols.data + c_transpiler_post_increment(*(next_symbol));

                            symbol.value = value;

                            symbol.count = cast,no_check(Uint8) CONTEXT_SYMBOL_DELTA;

                            symbol.under = cast,no_check(Uint16) CONTEXT_SYMBOL_DELTA;

                            symbol.left = 0;

                            symbol.right = 0;

                            symbol.symbols = 0;

                            symbol.escapes = 0;

                            symbol.total = 0;

                            symbol.parent = 0;

                            node.right = cast,no_check(Uint16) (symbol - node);
                        } else if cast,no_check(s32) code < (cast(s32) after) - cast(s32) before {
                            node.under = cast,no_check(Uint16) ((cast,no_check(s32) node.under) + cast,no_check(s32) (CONTEXT_SYMBOL_DELTA));

                            if node.left != 0 {
                                node += cast,no_check(s32) node.left;

                                continue;
                            }

                            value =
                                cast,no_check(Uint8) ((cast(s32) node.value) - 1 -
                                    ((((cast(s32) after) - cast(s32) before) - cast(s32) code) - 1) / cast,no_check(s32) (CONTEXT_SYMBOL_MINIMUM));

                            under =
                                cast,no_check(Uint16) ((cast(s32) code) -
                                    ((((cast(s32) after) - cast(s32) before) - cast(s32) code) - 1) % cast,no_check(s32) (CONTEXT_SYMBOL_MINIMUM));

                            symbol = range_coder.symbols.data + c_transpiler_post_increment(*(next_symbol));

                            symbol.value = value;

                            symbol.count = cast,no_check(Uint8) CONTEXT_SYMBOL_DELTA;

                            symbol.under = cast,no_check(Uint16) CONTEXT_SYMBOL_DELTA;

                            symbol.left = 0;

                            symbol.right = 0;

                            symbol.symbols = 0;

                            symbol.escapes = 0;

                            symbol.total = 0;

                            symbol.parent = 0;

                            node.left = cast,no_check(Uint16) (symbol - node);
                        } else {
                            value = node.value;

                            count = cast,no_check(Uint16) ((cast,no_check(s32) count) + cast,no_check(s32) node.count);

                            under = cast,no_check(Uint16) ((cast(s32) after) - cast(s32) before);

                            node.under = cast,no_check(Uint16) ((cast,no_check(s32) node.under) + cast,no_check(s32) (CONTEXT_SYMBOL_DELTA));

                            node.count = cast,no_check(Uint8) ((cast,no_check(s32) node.count) + cast,no_check(s32) (CONTEXT_SYMBOL_DELTA));

                            symbol = node;
                        }

                        break;
                    }
                }
            }
            bottom = cast,no_check(Uint16) (symbol - range_coder.symbols.data);
            {
                decode_low += (cast,no_check(Uint32) ((cast(s32) root.escapes) + cast(s32) under)) * decode_range;

                decode_range *= cast,no_check(Uint32) count;

                while true {
                    if decode_low ^ (decode_low + decode_range) >= cast,no_check(Uint32) RANGE_CODER_TOP {
                        if decode_range >= cast,no_check(Uint32) RANGE_CODER_BOTTOM {
                            break;
                        }

                        decode_range =
                            (cast,no_check(Uint32) (0 - cast(s64) (decode_low))) & cast,no_check(Uint32) ((cast,no_check(s32) (RANGE_CODER_BOTTOM)) -
                                1);
                    }

                    c_transpiler_compound_shl(*(decode_code), (cast(s32) 8), Uint32, Uint32);

                    if in_data < in_end {
                        decode_code |= cast,no_check(Uint32) ((c_transpiler_post_increment(*(in_data))).*);
                    }

                    c_transpiler_compound_shl(*(decode_range), (cast(s32) 8), Uint32, Uint32);

                    c_transpiler_compound_shl(*(decode_low), (cast(s32) 8), Uint32, Uint32);
                }
            }
            root.total = cast,no_check(Uint16) ((cast,no_check(s32) root.total) + cast,no_check(s32) (CONTEXT_SYMBOL_DELTA));
            if cast,no_check(s32) count > (0xff - 2 * cast,no_check(s32) (CONTEXT_SYMBOL_DELTA)) + cast,no_check(s32) (CONTEXT_SYMBOL_MINIMUM) ||
                cast,no_check(s32) root.total > (cast,no_check(s32) (RANGE_CODER_BOTTOM)) - 0x100 {
                root.total =
                    cast,no_check(Uint16) ((ifx root.symbols != 0 then cast,no_check(s32) symbol_rescale(root +
                        cast,no_check(s32) root.symbols) else 0));

                root.escapes = cast,no_check(Uint16) ((cast,no_check(s32) root.escapes) - ((cast(s32) root.escapes) >> 1));

                root.total = cast,no_check(Uint16) ((cast,no_check(s32) root.total) + ((cast(s32) root.escapes) + 256 * cast,no_check(s32) (CONTEXT_SYMBOL_MINIMUM)));
            }
            break patch_contexts;
        }
        patch = range_coder.symbols.data + predicted;
        while patch != subcontext {
            under = cast,no_check(Uint16) ((cast(s32) value) * 0);

            count = 0;

            if patch.symbols == 0 {
                symbol = range_coder.symbols.data + c_transpiler_post_increment(*(next_symbol));

                symbol.value = value;

                symbol.count = cast,no_check(Uint8) SUBCONTEXT_SYMBOL_DELTA;

                symbol.under = cast,no_check(Uint16) SUBCONTEXT_SYMBOL_DELTA;

                symbol.left = 0;

                symbol.right = 0;

                symbol.symbols = 0;

                symbol.escapes = 0;

                symbol.total = 0;

                symbol.parent = 0;

                patch.symbols = cast,no_check(Uint16) (symbol - patch);
            } else {
                node := patch + cast,no_check(s32) patch.symbols;

                while true {
                    if value < node.value {
                        node.under = cast,no_check(Uint16) ((cast,no_check(s32) node.under) + cast,no_check(s32) (SUBCONTEXT_SYMBOL_DELTA));

                        if node.left != 0 {
                            node += cast,no_check(s32) node.left;

                            continue;
                        }

                        symbol = range_coder.symbols.data + c_transpiler_post_increment(*(next_symbol));

                        symbol.value = value;

                        symbol.count = cast,no_check(Uint8) SUBCONTEXT_SYMBOL_DELTA;

                        symbol.under = cast,no_check(Uint16) SUBCONTEXT_SYMBOL_DELTA;

                        symbol.left = 0;

                        symbol.right = 0;

                        symbol.symbols = 0;

                        symbol.escapes = 0;

                        symbol.total = 0;

                        symbol.parent = 0;

                        node.left = cast,no_check(Uint16) (symbol - node);
                    } else if value > node.value {
                        under = cast,no_check(Uint16) ((cast,no_check(s32) under) + cast,no_check(s32) node.under);

                        if node.right != 0 {
                            node += cast,no_check(s32) node.right;

                            continue;
                        }

                        symbol = range_coder.symbols.data + c_transpiler_post_increment(*(next_symbol));

                        symbol.value = value;

                        symbol.count = cast,no_check(Uint8) SUBCONTEXT_SYMBOL_DELTA;

                        symbol.under = cast,no_check(Uint16) SUBCONTEXT_SYMBOL_DELTA;

                        symbol.left = 0;

                        symbol.right = 0;

                        symbol.symbols = 0;

                        symbol.escapes = 0;

                        symbol.total = 0;

                        symbol.parent = 0;

                        node.right = cast,no_check(Uint16) (symbol - node);
                    } else {
                        count = cast,no_check(Uint16) ((cast,no_check(s32) count) + cast,no_check(s32) node.count);

                        under = cast,no_check(Uint16) ((cast,no_check(s32) under) + ((cast(s32) node.under) - cast(s32) node.count));

                        node.under = cast,no_check(Uint16) ((cast,no_check(s32) node.under) + cast,no_check(s32) (SUBCONTEXT_SYMBOL_DELTA));

                        node.count = cast,no_check(Uint8) ((cast,no_check(s32) node.count) + cast,no_check(s32) (SUBCONTEXT_SYMBOL_DELTA));

                        symbol = node;
                    }

                    break;
                }
            }
            parent.* = cast,no_check(Uint16) (symbol - range_coder.symbols.data);
            parent = *symbol.parent;
            if count <= 0 {
                patch.escapes = cast,no_check(Uint16) ((cast,no_check(s32) patch.escapes) + cast,no_check(s32) (SUBCONTEXT_ESCAPE_DELTA));
                patch.total = cast,no_check(Uint16) ((cast,no_check(s32) patch.total) + cast,no_check(s32) (SUBCONTEXT_ESCAPE_DELTA));
            }
            patch.total = cast,no_check(Uint16) ((cast,no_check(s32) patch.total) + cast,no_check(s32) (SUBCONTEXT_SYMBOL_DELTA));
            if cast,no_check(s32) count > 0xff - 2 * cast,no_check(s32) (SUBCONTEXT_SYMBOL_DELTA) ||
                cast,no_check(s32) patch.total > (cast,no_check(s32) (RANGE_CODER_BOTTOM)) - 0x100 {
                patch.total =
                    cast,no_check(Uint16) ((ifx patch.symbols != 0 then cast,no_check(s32) symbol_rescale(patch +
                        cast,no_check(s32) patch.symbols) else 0));

                patch.escapes = cast,no_check(Uint16) ((cast,no_check(s32) patch.escapes) - ((cast(s32) patch.escapes) >> 1));

                patch.total = cast,no_check(Uint16) ((cast,no_check(s32) patch.total) + ((cast(s32) patch.escapes) + cast,no_check(s32) ((256 * 0))));
            }
            patch = range_coder.symbols.data + patch.parent;
        }
        parent.* = bottom;
        {
            if out_data >= out_end {
                return 0;
            }

            out_data.* = value;
            out_data += 1;
        }
        if order >= cast,no_check(u64) SUBCONTEXT_ORDER {
            predicted = range_coder.symbols[predicted].parent;
        } else {
            order += 1;
        }
        {
            if next_symbol >= (cast(u64) range_coder.symbols.count) - cast,no_check(u64) SUBCONTEXT_ORDER {
                next_symbol = 0;

                root = range_coder.symbols.data + c_transpiler_post_increment(*(next_symbol));

                root.value = 0;

                root.count = 0;

                root.under = 0;

                root.left = 0;

                root.right = 0;

                root.symbols = 0;

                root.escapes = 0;

                root.total = 0;

                root.parent = 0;

                root.escapes = cast,no_check(Uint16) CONTEXT_ESCAPE_MINIMUM;

                root.total =
                    cast,no_check(Uint16) ((cast,no_check(s32) (CONTEXT_ESCAPE_MINIMUM)) +
                        256 * cast,no_check(s32) (CONTEXT_SYMBOL_MINIMUM));

                root.symbols = 0;

                predicted = 0;

                order = 0;
            }
        }
    }

    return cast,no_check(u64) (out_data - out_start);
}

symbol_rescale :: (symbol: *Symbol) -> Uint16 {
    total: Uint16 = 0;
    while true {
        symbol.count = cast,no_check(Uint8) ((cast,no_check(s32) symbol.count) - ((cast(s32) symbol.count) >> 1));
        symbol.under = cast,no_check(Uint16) symbol.count;
        if symbol.left != 0 {
            c_transpiler_compound_add(*(symbol.under), (cast,no_check(s32) symbol_rescale(symbol + cast,no_check(s32) symbol.left)), s32, s32);
        }
        total = cast,no_check(Uint16) ((cast,no_check(s32) total) + cast,no_check(s32) symbol.under);
        if symbol.right == 0 {
            break;
        }
        symbol += cast,no_check(s32) symbol.right;
    }
    return total;
}

range_coder_compress :: (
    context_: *void,
    in_buffers: *Buffer,
    in_buffer_count: u64,
    in_limit: u64,
    out_data: *Uint8,
    out_limit: u64
) -> u64 {
    range_coder := cast(*Range_Coder) context_;
    out_start := out_data;
    out_end := *out_data[out_limit];
    in_data, in_end: *Uint8 = ---;
    encode_low: Uint32 = 0;
    encode_range: Uint32 = 0xffffffff;
    root: *Symbol = ---;
    predicted: Uint16 = 0;
    order: u64 = 0;
    next_symbol: u64 = 0;

    if range_coder == null || in_buffer_count <= 0 || in_limit <= 0 {
        return 0;
    }

    in_data = cast(*Uint8) in_buffers.data;
    in_end = *in_data[in_buffers.data_length];
    in_buffers += 1;
    in_buffer_count -= 1;

    root = range_coder.symbols.data + c_transpiler_post_increment(*(next_symbol));

    root.value = 0;

    root.count = 0;

    root.under = 0;

    root.left = 0;

    root.right = 0;

    root.symbols = 0;

    root.escapes = 0;

    root.total = 0;

    root.parent = 0;

    root.escapes = cast,no_check(Uint16) CONTEXT_ESCAPE_MINIMUM;

    root.total =
        cast,no_check(Uint16) ((cast,no_check(s32) (CONTEXT_ESCAPE_MINIMUM)) +
            256 * cast,no_check(s32) (CONTEXT_SYMBOL_MINIMUM));

    root.symbols = 0;

    while loop := true {
        subcontext, symbol: *Symbol = ---;
        value: Uint8 = ---;
        count: Uint16 = ---;
        under: Uint16 = ---;
        parent := *predicted;
        total: Uint16 = ---;
        if in_data >= in_end {
            if in_buffer_count <= 0 {
                break;
            }
            in_data = cast(*Uint8) in_buffers.data;
            in_end = *in_data[in_buffers.data_length];
            in_buffers += 1;
            in_buffer_count -= 1;
        }
        value = (c_transpiler_post_increment(*(in_data))).*;
        while next_input := true { // Forward-goto shim; executes at most once.
            subcontext = range_coder.symbols.data + predicted;
            while subcontext != root {
                under = cast,no_check(Uint16) ((cast(s32) value) * 0);

                count = 0;

                if subcontext.symbols == 0 {
                    symbol = range_coder.symbols.data + c_transpiler_post_increment(*(next_symbol));

                    symbol.value = value;

                    symbol.count = cast,no_check(Uint8) SUBCONTEXT_SYMBOL_DELTA;

                    symbol.under = cast,no_check(Uint16) SUBCONTEXT_SYMBOL_DELTA;

                    symbol.left = 0;

                    symbol.right = 0;

                    symbol.symbols = 0;

                    symbol.escapes = 0;

                    symbol.total = 0;

                    symbol.parent = 0;

                    subcontext.symbols = cast,no_check(Uint16) (symbol - subcontext);
                } else {
                    node := subcontext + cast,no_check(s32) subcontext.symbols;

                    while true {
                        if value < node.value {
                            node.under = cast,no_check(Uint16) ((cast,no_check(s32) node.under) + cast,no_check(s32) (SUBCONTEXT_SYMBOL_DELTA));

                            if node.left != 0 {
                                node += cast,no_check(s32) node.left;

                                continue;
                            }

                            symbol = range_coder.symbols.data + c_transpiler_post_increment(*(next_symbol));

                            symbol.value = value;

                            symbol.count = cast,no_check(Uint8) SUBCONTEXT_SYMBOL_DELTA;

                            symbol.under = cast,no_check(Uint16) SUBCONTEXT_SYMBOL_DELTA;

                            symbol.left = 0;

                            symbol.right = 0;

                            symbol.symbols = 0;

                            symbol.escapes = 0;

                            symbol.total = 0;

                            symbol.parent = 0;

                            node.left = cast,no_check(Uint16) (symbol - node);
                        } else if value > node.value {
                            under = cast,no_check(Uint16) ((cast,no_check(s32) under) + cast,no_check(s32) node.under);

                            if node.right != 0 {
                                node += cast,no_check(s32) node.right;

                                continue;
                            }

                            symbol = range_coder.symbols.data + c_transpiler_post_increment(*(next_symbol));

                            symbol.value = value;

                            symbol.count = cast,no_check(Uint8) SUBCONTEXT_SYMBOL_DELTA;

                            symbol.under = cast,no_check(Uint16) SUBCONTEXT_SYMBOL_DELTA;

                            symbol.left = 0;

                            symbol.right = 0;

                            symbol.symbols = 0;

                            symbol.escapes = 0;

                            symbol.total = 0;

                            symbol.parent = 0;

                            node.right = cast,no_check(Uint16) (symbol - node);
                        } else {
                            count = cast,no_check(Uint16) ((cast,no_check(s32) count) + cast,no_check(s32) node.count);

                            under = cast,no_check(Uint16) ((cast,no_check(s32) under) + ((cast(s32) node.under) - cast(s32) node.count));

                            node.under = cast,no_check(Uint16) ((cast,no_check(s32) node.under) + cast,no_check(s32) (SUBCONTEXT_SYMBOL_DELTA));

                            node.count = cast,no_check(Uint8) ((cast,no_check(s32) node.count) + cast,no_check(s32) (SUBCONTEXT_SYMBOL_DELTA));

                            symbol = node;
                        }

                        break;
                    }
                }
                parent.* = cast,no_check(Uint16) (symbol - range_coder.symbols.data);
                parent = *symbol.parent;
                total = subcontext.total;

                if count > 0 {
                    encode_range /= cast,no_check(Uint32) total;

                    encode_low +=
                        (cast,no_check(Uint32) ((cast(s32) subcontext.escapes) + cast(s32) under)) *
                            encode_range;

                    encode_range *= cast,no_check(Uint32) count;

                    while true {
                        if encode_low ^ (encode_low + encode_range) >= cast,no_check(Uint32) RANGE_CODER_TOP {
                            if encode_range >= cast,no_check(Uint32) RANGE_CODER_BOTTOM {
                                break;
                            }

                            encode_range =
                                (cast,no_check(Uint32) (0 - cast(s64) (encode_low))) & cast,no_check(Uint32) ((cast,no_check(s32) (RANGE_CODER_BOTTOM)) -
                                    1);
                        }

                        if out_data >= out_end {
                            return 0;
                        }

                        out_data.* = cast,no_check(Uint8) (encode_low >> 24);
                        out_data += 1;

                        c_transpiler_compound_shl(*(encode_range), (cast(s32) 8), Uint32, Uint32);

                        c_transpiler_compound_shl(*(encode_low), (cast(s32) 8), Uint32, Uint32);
                    }
                } else {
                    if subcontext.escapes > 0 && subcontext.escapes < total {
                        encode_range /= cast,no_check(Uint32) total;

                        encode_low += 0 * encode_range;

                        encode_range *= cast,no_check(Uint32) subcontext.escapes;

                        while true {
                            if encode_low ^ (encode_low + encode_range) >= cast,no_check(Uint32) RANGE_CODER_TOP {
                                if encode_range >= cast,no_check(Uint32) RANGE_CODER_BOTTOM {
                                    break;
                                }

                                encode_range =
                                    (cast,no_check(Uint32) (0 - cast(s64) (encode_low))) & cast,no_check(Uint32) ((cast,no_check(s32) (RANGE_CODER_BOTTOM)) -
                                        1);
                            }

                            if out_data >= out_end {
                                return 0;
                            }

                            out_data.* = cast,no_check(Uint8) (encode_low >> 24);
                            out_data += 1;

                            c_transpiler_compound_shl(*(encode_range), (cast(s32) 8), Uint32, Uint32);

                            c_transpiler_compound_shl(*(encode_low), (cast(s32) 8), Uint32, Uint32);
                        }
                    }
                    subcontext.escapes = cast,no_check(Uint16) ((cast,no_check(s32) subcontext.escapes) + cast,no_check(s32) (SUBCONTEXT_ESCAPE_DELTA));
                    subcontext.total = cast,no_check(Uint16) ((cast,no_check(s32) subcontext.total) + cast,no_check(s32) (SUBCONTEXT_ESCAPE_DELTA));
                }
                subcontext.total = cast,no_check(Uint16) ((cast,no_check(s32) subcontext.total) + cast,no_check(s32) (SUBCONTEXT_SYMBOL_DELTA));
                if cast,no_check(s32) count > 0xff - 2 * cast,no_check(s32) (SUBCONTEXT_SYMBOL_DELTA) ||
                    cast,no_check(s32) subcontext.total > (cast,no_check(s32) (RANGE_CODER_BOTTOM)) - 0x100 {
                    subcontext.total =
                        cast,no_check(Uint16) ((ifx subcontext.symbols != 0 then cast,no_check(s32) symbol_rescale(
                            subcontext + cast,no_check(s32) subcontext.symbols
                        ) else 0));

                    subcontext.escapes = cast,no_check(Uint16) ((cast,no_check(s32) subcontext.escapes) - ((cast(s32) subcontext.escapes) >> 1));

                    subcontext.total = cast,no_check(Uint16) ((cast,no_check(s32) subcontext.total) + ((cast(s32) subcontext.escapes) + cast,no_check(s32) ((256 * 0))));
                }
                if count > 0 {
                    break next_input;
                }
                subcontext = range_coder.symbols.data + subcontext.parent;
            }
            {
                under = cast,no_check(Uint16) ((cast(s32) value) * cast,no_check(s32) (CONTEXT_SYMBOL_MINIMUM));

                count = cast,no_check(Uint16) CONTEXT_SYMBOL_MINIMUM;

                if root.symbols == 0 {
                    symbol = range_coder.symbols.data + c_transpiler_post_increment(*(next_symbol));

                    symbol.value = value;

                    symbol.count = cast,no_check(Uint8) CONTEXT_SYMBOL_DELTA;

                    symbol.under = cast,no_check(Uint16) CONTEXT_SYMBOL_DELTA;

                    symbol.left = 0;

                    symbol.right = 0;

                    symbol.symbols = 0;

                    symbol.escapes = 0;

                    symbol.total = 0;

                    symbol.parent = 0;

                    root.symbols = cast,no_check(Uint16) (symbol - root);
                } else {
                    node := root + cast,no_check(s32) root.symbols;

                    while true {
                        if value < node.value {
                            node.under = cast,no_check(Uint16) ((cast,no_check(s32) node.under) + cast,no_check(s32) (CONTEXT_SYMBOL_DELTA));

                            if node.left != 0 {
                                node += cast,no_check(s32) node.left;

                                continue;
                            }

                            symbol = range_coder.symbols.data + c_transpiler_post_increment(*(next_symbol));

                            symbol.value = value;

                            symbol.count = cast,no_check(Uint8) CONTEXT_SYMBOL_DELTA;

                            symbol.under = cast,no_check(Uint16) CONTEXT_SYMBOL_DELTA;

                            symbol.left = 0;

                            symbol.right = 0;

                            symbol.symbols = 0;

                            symbol.escapes = 0;

                            symbol.total = 0;

                            symbol.parent = 0;

                            node.left = cast,no_check(Uint16) (symbol - node);
                        } else if value > node.value {
                            under = cast,no_check(Uint16) ((cast,no_check(s32) under) + cast,no_check(s32) node.under);

                            if node.right != 0 {
                                node += cast,no_check(s32) node.right;

                                continue;
                            }

                            symbol = range_coder.symbols.data + c_transpiler_post_increment(*(next_symbol));

                            symbol.value = value;

                            symbol.count = cast,no_check(Uint8) CONTEXT_SYMBOL_DELTA;

                            symbol.under = cast,no_check(Uint16) CONTEXT_SYMBOL_DELTA;

                            symbol.left = 0;

                            symbol.right = 0;

                            symbol.symbols = 0;

                            symbol.escapes = 0;

                            symbol.total = 0;

                            symbol.parent = 0;

                            node.right = cast,no_check(Uint16) (symbol - node);
                        } else {
                            count = cast,no_check(Uint16) ((cast,no_check(s32) count) + cast,no_check(s32) node.count);

                            under = cast,no_check(Uint16) ((cast,no_check(s32) under) + ((cast(s32) node.under) - cast(s32) node.count));

                            node.under = cast,no_check(Uint16) ((cast,no_check(s32) node.under) + cast,no_check(s32) (CONTEXT_SYMBOL_DELTA));

                            node.count = cast,no_check(Uint8) ((cast,no_check(s32) node.count) + cast,no_check(s32) (CONTEXT_SYMBOL_DELTA));

                            symbol = node;
                        }

                        break;
                    }
                }
            }
            parent.* = cast,no_check(Uint16) (symbol - range_coder.symbols.data);
            parent = *symbol.parent;
            total = root.total;
            {
                encode_range /= cast,no_check(Uint32) total;

                encode_low += (cast,no_check(Uint32) ((cast(s32) root.escapes) + cast(s32) under)) * encode_range;

                encode_range *= cast,no_check(Uint32) count;

                while true {
                    if encode_low ^ (encode_low + encode_range) >= cast,no_check(Uint32) RANGE_CODER_TOP {
                        if encode_range >= cast,no_check(Uint32) RANGE_CODER_BOTTOM {
                            break;
                        }

                        encode_range =
                            (cast,no_check(Uint32) (0 - cast(s64) (encode_low))) & cast,no_check(Uint32) ((cast,no_check(s32) (RANGE_CODER_BOTTOM)) -
                                1);
                    }

                    if out_data >= out_end {
                        return 0;
                    }

                    out_data.* = cast,no_check(Uint8) (encode_low >> 24);
                    out_data += 1;

                    c_transpiler_compound_shl(*(encode_range), (cast(s32) 8), Uint32, Uint32);

                    c_transpiler_compound_shl(*(encode_low), (cast(s32) 8), Uint32, Uint32);
                }
            }
            root.total = cast,no_check(Uint16) ((cast,no_check(s32) root.total) + cast,no_check(s32) (CONTEXT_SYMBOL_DELTA));
            if cast,no_check(s32) count > (0xff - 2 * cast,no_check(s32) (CONTEXT_SYMBOL_DELTA)) + cast,no_check(s32) (CONTEXT_SYMBOL_MINIMUM) ||
                cast,no_check(s32) root.total > (cast,no_check(s32) (RANGE_CODER_BOTTOM)) - 0x100 {
                root.total =
                    cast,no_check(Uint16) ((ifx root.symbols != 0 then cast,no_check(s32) symbol_rescale(root +
                        cast,no_check(s32) root.symbols) else 0));

                root.escapes = cast,no_check(Uint16) ((cast,no_check(s32) root.escapes) - ((cast(s32) root.escapes) >> 1));

                root.total = cast,no_check(Uint16) ((cast,no_check(s32) root.total) + ((cast(s32) root.escapes) + 256 * cast,no_check(s32) (CONTEXT_SYMBOL_MINIMUM)));
            }
            break next_input;
        }
        if order >= cast,no_check(u64) SUBCONTEXT_ORDER {
            predicted = range_coder.symbols[predicted].parent;
        } else {
            order += 1;
        }
        {
            if next_symbol >= (cast(u64) range_coder.symbols.count) - cast,no_check(u64) SUBCONTEXT_ORDER {
                next_symbol = 0;

                root = range_coder.symbols.data + c_transpiler_post_increment(*(next_symbol));

                root.value = 0;

                root.count = 0;

                root.under = 0;

                root.left = 0;

                root.right = 0;

                root.symbols = 0;

                root.escapes = 0;

                root.total = 0;

                root.parent = 0;

                root.escapes = cast,no_check(Uint16) CONTEXT_ESCAPE_MINIMUM;

                root.total =
                    cast,no_check(Uint16) ((cast,no_check(s32) (CONTEXT_ESCAPE_MINIMUM)) +
                        256 * cast,no_check(s32) (CONTEXT_SYMBOL_MINIMUM));

                root.symbols = 0;

                predicted = 0;

                order = 0;
            }
        }
    }

    while encode_low != 0 {
        if out_data >= out_end {
            return 0;
        }

        out_data.* = cast,no_check(Uint8) (encode_low >> 24);
        out_data += 1;

        c_transpiler_compound_shl(*(encode_low), (cast(s32) 8), Uint32, Uint32);
    }

    return cast,no_check(u64) (out_data - out_start);
}

range_coder_create :: () -> *void {
    range_coder := cast(*Range_Coder) allocate_memory(size_of(Range_Coder));
    if range_coder == null {
        return null;
    }

    return cast(*void) range_coder;
}

Uint8 :: u8;

Uint16 :: u16;

Host :: struct {
    socket: Socket #align 8;
    address: Address #align 1;
    incoming_bandwidth: Uint32 #align 1;
    outgoing_bandwidth: Uint32 #align 1;
    bandwidth_throttle_epoch: Uint32 #align 1;
    mtu: Uint32 #align 1;
    random_seed: Uint32 #align 1;
    recalculate_bandwidth_limits: s32 #align 1;
    layout_padding_0: [4] u8 #align 1;
    peers: *Peer #align 1;
    peer_count: u64 #align 1;
    channel_limit: u64 #align 1;
    service_time: Uint32 #align 1;
    layout_padding_1: [4] u8 #align 1;
    dispatch_queue: List #align 1;
    total_queued: Uint32 #align 1;
    layout_padding_2: [4] u8 #align 1;
    packet_size: u64 #align 1;
    header_flags: Uint16 #align 1;
    commands: [32] Protocol #align 1;
    layout_padding_3: [6] u8 #align 1;
    command_count: u64 #align 1;
    buffers: [65] Buffer #align 1;
    buffer_count: u64 #align 1;
    checksum: Checksum_Callback #align 1;
    compressor: Compressor #align 1;
    packet_data: [2] [4096] Uint8 #align 1;
    received_address: Address #align 1;
    received_data: *Uint8 #align 1;
    received_data_length: u64 #align 1;
    total_sent_data: Uint32 #align 1;
    total_sent_packets: Uint32 #align 1;
    total_received_data: Uint32 #align 1;
    total_received_packets: Uint32 #align 1;
    intercept: Intercept_Callback #align 1;
    connected_peers: u64 #align 1;
    bandwidth_limited_peers: u64 #align 1;
    duplicate_peers: u64 #align 1;
    maximum_packet_size: u64 #align 1;
    maximum_waiting_data: u64 #align 1;
} #no_padding;

Compressor :: struct {
    context_: *void;
    compress: #type (_: *void, _: *Buffer, _: u64, _: u64, _: *Uint8, _: u64) -> u64;
    decompress: #type (_: *void, _: *Uint8, _: u64, _: *Uint8, _: u64) -> u64;
    destroy: #type (_: *void);
}

Buffer :: struct {
    data: *void;
    data_length: u64;
}

Socket :: s32;

Checksum_Callback :: #type (_: *Buffer, _: u64) -> Uint32;

Event :: struct {
    type: Event_Type;
    peer: *Peer;
    channel_id: Uint8;
    data: Uint32;
    packet: *Packet;
}

Intercept_Callback :: #type (_: *Host, _: *Event) -> s32;

Address :: struct {
    host: Uint32;
    port: Uint16;
}

Peer :: struct {
    dispatch_list: List_Node;
    host: *Host;
    outgoing_peer_id: Uint16;
    incoming_peer_id: Uint16;
    connect_id: Uint32;
    outgoing_session_id: Uint8;
    incoming_session_id: Uint8;
    address: Address;
    data: *void;
    state: Peer_State;
    channels: *Channel;
    channel_count: u64;
    incoming_bandwidth: Uint32;
    outgoing_bandwidth: Uint32;
    incoming_bandwidth_throttle_epoch: Uint32;
    outgoing_bandwidth_throttle_epoch: Uint32;
    incoming_data_total: Uint32;
    outgoing_data_total: Uint32;
    last_send_time: Uint32;
    last_receive_time: Uint32;
    next_timeout: Uint32;
    earliest_timeout: Uint32;
    packet_loss_epoch: Uint32;
    packets_sent: Uint32;
    packets_lost: Uint32;
    packet_loss: Uint32;
    packet_loss_variance: Uint32;
    packet_throttle: Uint32;
    packet_throttle_limit: Uint32;
    packet_throttle_counter: Uint32;
    packet_throttle_epoch: Uint32;
    packet_throttle_acceleration: Uint32;
    packet_throttle_deceleration: Uint32;
    packet_throttle_interval: Uint32;
    ping_interval: Uint32;
    timeout_limit: Uint32;
    timeout_minimum: Uint32;
    timeout_maximum: Uint32;
    last_round_trip_time: Uint32;
    lowest_round_trip_time: Uint32;
    last_round_trip_time_variance: Uint32;
    highest_round_trip_time_variance: Uint32;
    round_trip_time: Uint32;
    round_trip_time_variance: Uint32;
    mtu: Uint32;
    window_size: Uint32;
    reliable_data_in_transit: Uint32;
    outgoing_reliable_sequence_number: Uint16;
    acknowledgements: List;
    sent_reliable_commands: List;
    outgoing_send_reliable_commands: List;
    outgoing_commands: List;
    dispatched_commands: List;
    flags: Uint16;
    reserved: Uint16;
    incoming_unsequenced_group: Uint16;
    outgoing_unsequenced_group: Uint16;
    unsequenced_window: [32] Uint32;
    event_data: Uint32;
    total_waiting_data: u64;
}

List :: struct {
    sentinel: List_Node;
}

Protocol :: union {
    header: Protocol_Command_Header #align 1;
    acknowledge: Protocol_Acknowledge #align 1;
    connect: Protocol_Connect #align 1;
    verify_connect: Protocol_Verify_Connect #align 1;
    disconnect: Protocol_Disconnect #align 1;
    ping: Protocol_Ping #align 1;
    send_reliable: Protocol_Send_Reliable #align 1;
    send_unreliable: Protocol_Send_Unreliable #align 1;
    send_unsequenced: Protocol_Send_Unsequenced #align 1;
    send_fragment: Protocol_Send_Fragment #align 1;
    bandwidth_limit: Protocol_Bandwidth_Limit #align 1;
    throttle_configure: Protocol_Throttle_Configure #align 1;
}

Event_Type :: u32;
EVENT_TYPE_NONE : s32 : 0;
EVENT_TYPE_CONNECT : s32 : 1;
EVENT_TYPE_DISCONNECT : s32 : 2;
EVENT_TYPE_RECEIVE : s32 : 3;

Packet :: struct {
    reference_count: u64;
    flags: Uint32;
    data: *Uint8;
    data_length: u64;
    free_callback: Packet_Free_Callback;
    user_data: *void;
}

List_Node :: struct {
    next: *List_Node;
    previous: *List_Node;
}

Peer_State :: u32;
PEER_STATE_DISCONNECTED : s32 : 0;
PEER_STATE_CONNECTING : s32 : 1;
PEER_STATE_ACKNOWLEDGING_CONNECT : s32 : 2;
PEER_STATE_CONNECTION_PENDING : s32 : 3;
PEER_STATE_CONNECTION_SUCCEEDED : s32 : 4;
PEER_STATE_CONNECTED : s32 : 5;
PEER_STATE_DISCONNECT_LATER : s32 : 6;
PEER_STATE_DISCONNECTING : s32 : 7;
PEER_STATE_ACKNOWLEDGING_DISCONNECT : s32 : 8;
PEER_STATE_ZOMBIE : s32 : 9;

Channel :: struct {
    outgoing_reliable_sequence_number: Uint16;
    outgoing_unreliable_sequence_number: Uint16;
    used_reliable_windows: Uint16;
    reliable_windows: [16] Uint16;
    incoming_reliable_sequence_number: Uint16;
    incoming_unreliable_sequence_number: Uint16;
    incoming_reliable_commands: List;
    incoming_unreliable_commands: List;
}

Protocol_Command_Header :: struct {
    command: Uint8 #align 1;
    channel_id: Uint8 #align 1;
    reliable_sequence_number: Uint16 #align 1;
} #no_padding;

Protocol_Acknowledge :: struct {
    header: Protocol_Command_Header #align 1;
    received_reliable_sequence_number: Uint16 #align 1;
    received_sent_time: Uint16 #align 1;
} #no_padding;

Protocol_Connect :: struct {
    header: Protocol_Command_Header #align 1;
    outgoing_peer_id: Uint16 #align 1;
    incoming_session_id: Uint8 #align 1;
    outgoing_session_id: Uint8 #align 1;
    mtu: Uint32 #align 1;
    window_size: Uint32 #align 1;
    channel_count: Uint32 #align 1;
    incoming_bandwidth: Uint32 #align 1;
    outgoing_bandwidth: Uint32 #align 1;
    packet_throttle_interval: Uint32 #align 1;
    packet_throttle_acceleration: Uint32 #align 1;
    packet_throttle_deceleration: Uint32 #align 1;
    connect_id: Uint32 #align 1;
    data: Uint32 #align 1;
} #no_padding;

Protocol_Verify_Connect :: struct {
    header: Protocol_Command_Header #align 1;
    outgoing_peer_id: Uint16 #align 1;
    incoming_session_id: Uint8 #align 1;
    outgoing_session_id: Uint8 #align 1;
    mtu: Uint32 #align 1;
    window_size: Uint32 #align 1;
    channel_count: Uint32 #align 1;
    incoming_bandwidth: Uint32 #align 1;
    outgoing_bandwidth: Uint32 #align 1;
    packet_throttle_interval: Uint32 #align 1;
    packet_throttle_acceleration: Uint32 #align 1;
    packet_throttle_deceleration: Uint32 #align 1;
    connect_id: Uint32 #align 1;
} #no_padding;

Protocol_Disconnect :: struct {
    header: Protocol_Command_Header #align 1;
    data: Uint32 #align 1;
} #no_padding;

Protocol_Ping :: struct {
    header: Protocol_Command_Header #align 1;
} #no_padding;

Protocol_Send_Reliable :: struct {
    header: Protocol_Command_Header #align 1;
    data_length: Uint16 #align 1;
} #no_padding;

Protocol_Send_Unreliable :: struct {
    header: Protocol_Command_Header #align 1;
    unreliable_sequence_number: Uint16 #align 1;
    data_length: Uint16 #align 1;
} #no_padding;

Protocol_Send_Unsequenced :: struct {
    header: Protocol_Command_Header #align 1;
    unsequenced_group: Uint16 #align 1;
    data_length: Uint16 #align 1;
} #no_padding;

Protocol_Send_Fragment :: struct {
    header: Protocol_Command_Header #align 1;
    start_sequence_number: Uint16 #align 1;
    data_length: Uint16 #align 1;
    fragment_count: Uint32 #align 1;
    fragment_number: Uint32 #align 1;
    total_length: Uint32 #align 1;
    fragment_offset: Uint32 #align 1;
} #no_padding;

Protocol_Bandwidth_Limit :: struct {
    header: Protocol_Command_Header #align 1;
    incoming_bandwidth: Uint32 #align 1;
    outgoing_bandwidth: Uint32 #align 1;
} #no_padding;

Protocol_Throttle_Configure :: struct {
    header: Protocol_Command_Header #align 1;
    packet_throttle_interval: Uint32 #align 1;
    packet_throttle_acceleration: Uint32 #align 1;
    packet_throttle_deceleration: Uint32 #align 1;
} #no_padding;

Packet_Free_Callback :: #type (_: *Packet);

