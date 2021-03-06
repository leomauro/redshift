from libc.string cimport const_void
from libc.stdint cimport uint64_t, int64_t

from cymem.cymem cimport Pool

from .sentence cimport Sentence, Token


include "compile_time_options.pxi"
IF TRANSITION_SYSTEM == 'arc_eager':
    from .arc_eager cimport *
ELSE:
    from .arc_hybrid cimport *


# From left-to-right in the string, the slot tokens are:
# S2, S1, S0le, S0l, S0l2, S0l0, S0, S0r0, S0r2, S0r, S0re
# N0le, N0l, N0l2, N0l0

cdef struct SlotTokens:
    Token s2
    Token s1
    Token s1r
    Token s0le
    Token s0l
    Token s0l2
    Token s0l0
    Token s0
    Token s0r0
    Token s0r2
    Token s0r
    Token s0re
    Token n0le
    Token n0l
    Token n0l2
    Token n0l0
    Token n0
    Token n1
    Token n2

    # Previous to n0
    Token p1
    Token p2
    # After S0
    Token s0n
    Token s0nn


cdef struct State:
    double score
    size_t i
    size_t m
    size_t n
    size_t stack_len
    size_t top
    int cost

    size_t* stack
    
    size_t** l_children
    size_t** r_children
    Token* parse
    Transition* history
    SlotTokens slots


cdef int fill_slots(State* s) except -1

cdef int add_dep(State *s, size_t head, size_t child, size_t label) except -1
cdef int del_l_child(State *s, size_t head) except -1
cdef int del_r_child(State *s, size_t head) except -1

cdef size_t pop_stack(State *s) except 0
cdef int push_stack(State *s) except -1

cdef inline size_t get_s1(State *s) nogil:
    if s.stack_len < 2:
        return 0
    return s.stack[s.stack_len - 2]

cdef inline size_t get_l(State *s, size_t head) nogil:
    if s.parse[head].l_valency == 0:
        return 0
    return s.l_children[head][s.parse[head].l_valency - 1]

cdef inline size_t get_l2(State *s, size_t head) nogil:
    if s.parse[head].l_valency < 2:
        return 0
    return s.l_children[head][s.parse[head].l_valency - 2]

cdef inline size_t get_r(State *s, size_t head) nogil:
    if s.parse[head].r_valency == 0:
        return 0
    return s.r_children[head][s.parse[head].r_valency - 1]

cdef inline size_t get_r2(State *s, size_t head) nogil:
    if s.parse[head].r_valency < 2:
        return 0
    return s.r_children[head][s.parse[head].r_valency - 2]


cdef inline bint at_eol(State *s) nogil:
    return s.i >= (s.n - 1)

cdef inline bint is_final(State *s) nogil:
    return at_eol(s) and s.stack_len == 0


cdef int has_child_in_buffer(State *s, size_t word, Token* gold) except -1
cdef int has_head_in_buffer(State *s, size_t word, Token* gold) except -1
cdef int has_child_in_stack(State *s, size_t word, Token* gold) except -1
cdef int has_head_in_stack(State *s, size_t word, Token* gold) except -1

cdef State* init_state(Sentence* sent, Pool pool)
cdef int copy_state(State* s, State* old) except -1
