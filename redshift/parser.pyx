# cython: profile=True
"""
MALT-style dependency parser
"""
cimport cython
import random
from libc.stdlib cimport malloc, free
from libc.string cimport memcpy
from pathlib import Path
from collections import defaultdict
import sh
import sys

from _state cimport *
cimport io_parse
import io_parse
from io_parse cimport Sentence
from io_parse cimport Sentences
from io_parse cimport make_sentence
cimport features

from io_parse import LABEL_STRS, STR_TO_LABEL

import index.hashes
from index.hashes cimport InstanceCounter

from svm.cy_svm cimport Model, LibLinear, Perceptron

from libc.stdint cimport uint64_t, int64_t

cdef int CONTEXT_SIZE = features.CONTEXT_SIZE

from _state cimport *

VOCAB_SIZE = 1e6
TAG_SET_SIZE = 50
cdef double FOLLOW_ERR_PC = 0.90


DEBUG = False 
def set_debug(val):
    global DEBUG
    DEBUG = val

cdef enum:
    ERR
    SHIFT
    REDUCE
    LEFT
    RIGHT
    _n_moves

DEF N_MOVES = 5
assert N_MOVES == _n_moves, "Set N_MOVES compile var to %d" % _n_moves


DEF USE_COLOURS = True

def red(string):
    if USE_COLOURS:
        return u'\033[91m%s\033[0m' % string
    else:
        return string


cdef lmove_to_str(move, label):
    moves = ['E', 'S', 'D', 'L', 'R', 'W', 'V']
    label = LABEL_STRS[label]
    if move == SHIFT:
        return 'S'
    elif move == REDUCE:
        return 'D'
    else:
        return '%s-%s' % (moves[move], label)


def _parse_labels_str(labels_str):
    return [STR_TO_LABEL[l] for l in labels_str.split(',')]


cdef class Parser:
    cdef size_t n_features
    cdef Model guide
    cdef object model_dir
    cdef Sentence* sentence
    cdef int n_preds
    cdef size_t* _context
    cdef uint64_t* _hashed_feats
    cdef TransitionSystem moves
    cdef InstanceCounter inst_counts
    cdef object add_extra
    cdef object label_set
    cdef object train_alg
    cdef int feat_thresh

    def __cinit__(self, model_dir, clean=False, train_alg='static',
                  add_extra=True, label_set='MALT', feat_thresh=5,
                  allow_reattach=False, allow_reduce=False,
                  reuse_idx=False, shifty=False):
        model_dir = Path(model_dir)
        if not clean:
            params = dict([line.split() for line in model_dir.join('parser.cfg').open()])
            C = float(params['C'])
            train_alg = params['train_alg']
            eps = float(params['eps'])
            add_extra = True if params['add_extra'] == 'True' else False
            label_set = params['label_set']
            feat_thresh = int(params['feat_thresh'])
            allow_reattach = params['allow_reattach'] == 'True'
            allow_reduce = params['allow_reduce'] == 'True'
            shifty = params.get('shifty') == 'True'
            l_labels = params['left_labels']
            r_labels = params['right_labels']
        if allow_reattach and allow_reduce:
            print 'NM L+D'
        elif allow_reattach:
            print 'NM L'
        elif allow_reduce:
            print 'NM D'
        else:
            print 'Baseline'
        self.model_dir = self.setup_model_dir(model_dir, clean)
        io_parse.set_labels(label_set)
        self.n_preds = features.make_predicates(add_extra, True)
        self.add_extra = add_extra
        self.label_set = label_set
        self.feat_thresh = feat_thresh
        self.train_alg = train_alg
        if clean == True:
            self.new_idx(self.model_dir, self.n_preds)
        else:
            self.load_idx(self.model_dir, self.n_preds)
        self.moves = TransitionSystem(io_parse.LABEL_STRS, allow_reattach=allow_reattach,
                                      allow_reduce=allow_reduce, shifty=shifty)
        if not clean:
            self.moves.set_labels(_parse_labels_str(l_labels), _parse_labels_str(r_labels))
        guide_loc = self.model_dir.join('model')
        n_labels = len(io_parse.LABEL_STRS)
        self.guide = Perceptron(self.moves.n_class, guide_loc)
        self._context = features.init_context()
        self._hashed_feats = features.init_hashed_features()
        self.inst_counts = InstanceCounter()

    def setup_model_dir(self, loc, clean):
        if clean and loc.exists():
            sh.rm('-rf', loc)
        if loc.exists():
            assert loc.is_dir()
        else:
            loc.mkdir()
        sh.git.log(n=1, _out=loc.join('version').open('wb'), _bg=True) 
        return loc

    def train(self, Sentences sents, C=None, eps=None, n_iter=15, held_out=None):
        cdef size_t i, j, n
        cdef Sentence* sent
        cdef Sentences held_out_gold
        cdef Sentences held_out_parse
        # Count classes and labels
        seen_l_labels = set([])
        seen_r_labels = set([])
        for i in range(sents.length):
            sent = &sents.s[i]
            for j in range(1, sent.length - 1):
                label = sent.parse.labels[j]
                if sent.parse.heads[j] > j:
                    seen_l_labels.add(label)
                else:
                    seen_r_labels.add(label)
        move_classes = self.moves.set_labels(seen_l_labels, seen_r_labels)
        self.guide.set_classes(move_classes)
        self.write_cfg(self.model_dir.join('parser.cfg'))
        indices = range(sents.length)
        for n in range(n_iter):
            random.shuffle(indices)
            for sent_id, i in enumerate(indices):
                if self.train_alg == 'beam':
                    self.train_beam(n, &sents.s[i], 5, sents.strings[i][0])
                else:
                    self.train_one(n, &sents.s[i], self.train_alg == 'online', sents.strings[i][0])
            move_acc = (float(self.guide.n_corr) / self.guide.total) * 100
            print "#%d: Moves %d/%d=%.2f" % (n, self.guide.n_corr,
                                             self.guide.total, move_acc)
            if self.feat_thresh > 1:
                self.guide.prune(self.feat_thresh)
            self.guide.n_corr = 0
            self.guide.total = 0
        self.guide.train()

    cdef int train_beam(self, int iter_num, Sentence* sent, size_t k,
                        py_words) except -1:
        cdef size_t* g_heads = sent.parse.heads
        cdef size_t* g_labels = sent.parse.labels
        cdef State * s
        cdef Beam beam = Beam(k, sent.length)
        if DEBUG:
            print ' '.join(py_words)
        while not beam.gold.is_finished:
            next_moves = self._get_move_scores(sent, beam.w, beam.beam)
            for i, (score, c, clas) in enumerate(next_moves):
                s = beam.beam[c]
                new = self._advance(s, clas, score, g_heads, g_labels)
                beam.add(new)
                if beam.is_full and beam.has_gold:
                    break
            assert beam.has_gold, beam._w
            if beam.g_idx == 0:
                self.guide.n_corr += 1
            self.guide.total += 1
            if beam.g_idx == -1:
                break
            beam.refresh()
        g = beam.gold
        p = beam.best_p()
        if DEBUG:
            for i in range(p.t):
                clas = p.history[i]
                move = self.moves.class_to_move(clas)
                label = self.moves.class_to_label(clas)
                print lmove_to_str(move, label), 
            print
        assert g.t == p.t, '%d vs %d' % (g.t, p.t)
        if g.score <= p.score and g is not p:
            pred_counts = self._count_feats(sent, p.t, p.history)
            gold_counts = self._count_feats(sent, g.t, g.history)
            self.guide.global_update(pred_counts, gold_counts)

    cdef State* _advance(self, State* s, clas, score, size_t* heads, size_t* labels) except NULL:
        new = copy_state(s)
        new.score = score
        oracle = self.moves.break_tie(new, heads, labels)
        valid = self.moves.get_valid(s)
        if oracle != 0:
            assert valid[oracle]
        new.is_gold = s.is_gold and oracle == clas
        self.moves.transition(clas, new)
        return new

    cdef object _get_move_scores(self, Sentence* sent, size_t k, State** beam):
        cdef size_t gold
        cdef size_t* context = self._context
        cdef uint64_t* feats = self._hashed_feats
        cdef size_t n_feats = self.n_preds
        cdef size_t i
        cdef uint64_t* labels = self.guide.get_labels()
        next_moves = []
        for i in range(k):
            s = beam[i]
            features.extract(context, feats, sent, s)
            valid = self.moves.get_valid(s)
            scores = self.guide.predict_scores(n_feats, feats)
            for j in range(self.guide.nr_class):
                clas = labels[j]
                if valid[clas]:
                    next_moves.append((scores[j] + s.score, i, clas))
        next_moves.sort()
        next_moves.reverse()
        return next_moves

    cdef dict _count_feats(self, Sentence* sent, size_t t, size_t* history):
        cdef size_t* context = self._context
        cdef uint64_t* feats = self._hashed_feats
        cdef size_t n_feats = self.n_preds
        cdef State* state = init_state(sent.length)
        pred_counts = {}
        for i in range(t):
            features.extract(context, feats, sent, state)
            clas = history[i]
            for f in range(n_feats):
                key = (clas, feats[f])
                if key not in pred_counts:
                    pred_counts[key] = 1
                else:
                    pred_counts[key] += 1
            self.moves.transition(clas, state)
        free_state(state)
        return pred_counts

    cdef int train_one(self, int iter_num, Sentence* sent, bint online, py_words) except -1:
        cdef bint* valid
        cdef bint* oracle
        cdef size_t* g_labels = sent.parse.labels
        cdef size_t* g_heads = sent.parse.heads

        cdef size_t* context = self._context
        cdef uint64_t* feats = self._hashed_feats
        cdef size_t n_feats = self.n_preds
        cdef State* s = init_state(sent.length)
        cdef size_t move = 0
        cdef size_t label = 0
        cdef size_t _ = 0
        if DEBUG:
            print ' '.join(py_words)
        while not s.is_finished:
            features.extract(context, feats, sent, s)
            valid = self.moves.get_valid(s)
            pred = self.predict(n_feats, feats, valid, &s.guess_labels[s.top][s.i])
            if online:
                oracle = self.moves.get_oracle(s, g_heads, g_labels)
                gold = self.predict(n_feats, feats, oracle, &_) if not oracle[pred] else pred
            else:
                gold = self.moves.break_tie(s, g_heads, g_labels)
            self.guide.update(pred, gold, n_feats, feats, 1)
            if online and iter_num >= 2 and random.random() < FOLLOW_ERR_PC:
                self.moves.transition(pred, s)
            else:
                self.moves.transition(gold, s)
        free_state(s)

    def add_parses(self, Sentences sents, Sentences gold=None, k=1):
        cdef:
            size_t i
        for i in range(sents.length):
            if k == 1:
                self.parse(&sents.s[i])
            else:
                self.beam_parse(&sents.s[i], k)
        if gold is not None:
            return sents.evaluate(gold)

    cdef int parse(self, Sentence* sent) except -1:
        cdef State* s
        cdef size_t move = 0
        cdef size_t label = 0
        cdef size_t clas
        cdef size_t n_preds = self.n_preds
        cdef size_t* context = self._context
        cdef uint64_t* feats = self._hashed_feats
        cdef double* scores
        s = init_state(sent.length)
        sent.parse.n_moves = 0
        while not s.is_finished:
            features.extract(context, feats, sent, s)
            clas = self.predict(n_preds, feats, self.moves.get_valid(s),
                                  &s.guess_labels[s.top][s.i])
            sent.parse.moves[s.t] = clas
            self.moves.transition(clas, s)
        sent.parse.n_moves = s.t
        # No need to copy heads for root and start symbols
        for i in range(1, sent.length - 1):
            assert s.heads[i] != 0
            sent.parse.heads[i] = s.heads[i]
            sent.parse.labels[i] = s.labels[i]
        free_state(s)

    cdef int beam_parse(self, Sentence* sent, size_t k) except -1:
        cdef State* s
        cdef State* new
        cdef Beam beam = Beam(k, sent.length)
        sent.parse.n_moves = 0
        while not beam.beam[0].is_finished:
            move_scores = self._get_move_scores(sent, beam.w, beam.beam)
            for score, c, clas in move_scores:
                s = beam.beam[c]
                new = copy_state(s)
                new.is_gold = False
                new.score = score
                self.moves.transition(clas, new)
                beam.add(new)
                if beam.is_full:
                    break
            beam.refresh()
        s = beam.best_p()
        sent.parse.n_moves = s.t
        for i in range(s.t):
            sent.parse.moves[i] = s.history[i]
        # No need to copy heads for root and start symbols
        for i in range(1, sent.length - 1):
            assert s.heads[i] != 0
            sent.parse.heads[i] = s.heads[i]
            sent.parse.labels[i] = s.labels[i]

    cdef int predict(self, uint64_t n_preds, uint64_t* feats, bint* valid,
                     size_t* rlabel) except -1:
        cdef:
            size_t i
            double score
            size_t clas, best_valid, best_right
            double* scores

        cdef size_t right_move = 0
        cdef double valid_score = -1000000
        cdef double right_score = -1000000
        cdef uint64_t* labels = self.guide.get_labels()
        scores = self.guide.predict_scores(n_preds, feats)
        seen_valid = False
        for i in range(self.guide.nr_class):
            score = scores[i]
            clas = labels[i]
            if valid[clas] and score > valid_score:
                best_valid = clas
                valid_score = score
                seen_valid = True
            if self.moves.right_arcs[clas] and score > right_score:
                best_right = clas
                right_score = score
        assert seen_valid
        rlabel[0] = self.moves.class_to_label(best_right)
        return best_valid

    def save(self):
        self.guide.save(self.model_dir.join('model'))

    def load(self):
        self.guide.load(self.model_dir.join('model'))

    def __dealloc__(self):
        free(self._context)
        free(self._hashed_feats)

    def new_idx(self, model_dir, size_t n_predicates):
        index.hashes.init_feat_idx(n_predicates, model_dir.join('features'))
        index.hashes.init_word_idx(model_dir.join('words'))
        index.hashes.init_pos_idx(model_dir.join('pos'))

    def load_idx(self, model_dir, size_t n_predicates):
        model_dir = Path(model_dir)
        index.hashes.load_word_idx(model_dir.join('words'))
        index.hashes.load_pos_idx(model_dir.join('pos'))
        index.hashes.load_feat_idx(n_predicates, model_dir.join('features'))
   
    def write_cfg(self, loc):
        with loc.open('w') as cfg:
            cfg.write(u'model_dir\t%s\n' % self.model_dir)
            cfg.write(u'C\t%s\n' % self.guide.C)
            cfg.write(u'eps\t%s\n' % self.guide.eps)
            cfg.write(u'train_alg\t%s\n' % self.train_alg)
            cfg.write(u'add_extra\t%s\n' % self.add_extra)
            cfg.write(u'label_set\t%s\n' % self.label_set)
            cfg.write(u'feat_thresh\t%d\n' % self.feat_thresh)
            cfg.write(u'allow_reattach\t%s\n' % self.moves.allow_reattach)
            cfg.write(u'shifty\t%s\n' % self.moves.shifty)
            cfg.write(u'allow_reduce\t%s\n' % self.moves.allow_reduce)
            cfg.write(u'left_labels\t%s\n' % ','.join(self.moves.left_labels))
            cfg.write(u'right_labels\t%s\n' % ','.join(self.moves.right_labels))
        
    def get_best_moves(self, Sentences sents, Sentences gold):
        """Get a list of move taken/oracle move pairs for output"""
        cdef State* s
        cdef size_t n
        cdef size_t move = 0
        cdef size_t label = 0
        cdef object best_moves
        cdef size_t i
        cdef size_t* g_labels
        cdef size_t* g_heads
        cdef size_t clas, parse_class
        best_moves = []
        for i in range(sents.length):
            sent = &sents.s[i]
            g_labels = gold.s[i].parse.labels
            g_heads = gold.s[i].parse.heads
            n = sent.length
            s = init_state(n)
            sent_moves = []
            tokens = sents.strings[i][0]
            while not s.is_finished:
                oracle = self.moves.get_oracle(s, g_heads, g_labels)
                best_strs = []
                best_ids = set()
                for clas in range(self.moves.n_class):
                    if oracle[clas]:
                        move = self.moves.class_to_move(clas)
                        label = self.moves.class_to_label(clas)
                        if move not in best_ids:
                            best_strs.append(lmove_to_str(move, label))
                        best_ids.add(move)
                best_strs = ','.join(best_strs)
                best_id_str = ','.join(map(str, sorted(best_ids)))
                parse_class = sent.parse.moves[s.t]
                state_str = transition_to_str(s, self.moves.class_to_move(parse_class),
                                              self.moves.class_to_label(parse_class),
                                              tokens)
                parse_move_str = lmove_to_str(move, label)
                if move not in best_ids:
                    parse_move_str = red(parse_move_str)
                sent_moves.append((best_id_str, int(move),
                                  best_strs, parse_move_str,
                                  state_str))
                self.moves.transition(parse_class, s)
            free_state(s)
            best_moves.append((u' '.join(tokens), sent_moves))
        return best_moves


cdef class Beam:
    cdef State** beam
    cdef State** _new
    cdef State* gold
    cdef size_t k
    cdef size_t w
    cdef size_t _w
    cdef bint is_full
    cdef bint has_gold
    cdef int g_idx
    cdef list scores

    def __cinit__(self, size_t k, size_t length):
        self.k = k
        self._w = 0
        self.w = 1
        self.g_idx = -1
        self.has_gold = False
        cdef State* s = init_state(length)
        self.gold = s
        self.is_full = self.w >= self.k
        self.beam = <State**>malloc(k * sizeof(State*))
        self._new = <State**>malloc(k * sizeof(State*))
        self.beam[0] = s

    cdef add(self, State* s):
        if not self.is_full:
            self._new[self._w] = s
            if s.is_gold and not self.has_gold:
                self.g_idx = self._w
                self.gold = s
                self.has_gold = True
            self._w += 1
            self.is_full = self._w >= self.k
        elif not self.has_gold and s.is_gold:
            self.gold = s
            self.has_gold = True
            self.g_idx = -1
        else:
            free_state(s)

    cdef State* best_p(self):
        if self._w != 0:
            return self._new[0]
        else:
            return self.beam[0]

    cdef refresh(self):
        for i in range(self.w):
            free_state(self.beam[i])
        for i in range(self._w):
            self.beam[i] = self._new[i]
        if self.g_idx == -1 and self.has_gold:
            free_state(self.gold)
        self.has_gold = False
        self.is_full = False
        self.g_idx = -1
        self.w = self._w
        self._w = 0

    def __dealloc__(self):
        self.refresh()
        for i in range(self.w):
            free_state(self.beam[i])
        free(self.beam)
        free(self._new)


cdef class TransitionSystem:
    cdef bint allow_reattach
    cdef bint allow_reduce
    cdef bint shifty
    cdef size_t n_labels
    cdef object py_labels
    cdef size_t[N_MOVES] offsets
    cdef bint* _oracle
    cdef bint* right_arcs
    cdef bint* left_arcs
    cdef list left_labels
    cdef list right_labels
    cdef size_t n_l_classes
    cdef size_t n_r_classes
    cdef size_t* l_classes
    cdef size_t* r_classes
    cdef size_t n_class
    cdef size_t s_id
    cdef size_t d_id
    cdef size_t l_start
    cdef size_t l_end
    cdef size_t r_start
    cdef size_t r_end
    cdef size_t w_start
    cdef size_t w_end
    cdef size_t v_id
    cdef int n_lmoves

    def __cinit__(self, object labels, allow_reattach=False,
                  allow_reduce=False, shifty=False):
        self.n_labels = len(labels)
        self.py_labels = labels
        self.allow_reattach = allow_reattach
        self.allow_reduce = allow_reduce
        self.shifty = shifty
        self.n_class = N_MOVES * self.n_labels
        self._oracle = <bint*>malloc(self.n_class * sizeof(bint))
        self.right_arcs = <bint*>malloc(self.n_class * sizeof(bint))
        self.left_arcs = <bint*>malloc(self.n_class * sizeof(bint))
        self.s_id = SHIFT * self.n_labels
        self.d_id = REDUCE * self.n_labels
        self.l_start = LEFT * self.n_labels
        self.l_end = (LEFT + 1) * self.n_labels
        self.r_start = RIGHT * self.n_labels
        self.r_end = (RIGHT + 1) * self.n_labels
        for i in range(self.n_class):
            self._oracle[i] = False
            self.right_arcs[i] = False
            self.left_arcs[i] = False
        for i in range(self.r_start, self.r_end):
            self.right_arcs[i] = True
        for i in range(self.l_start, self.l_end):
            self.left_arcs[i] = True

    def set_labels(self, left_labels, right_labels):
        self.left_labels = [self.py_labels[l] for l in sorted(left_labels)]
        self.right_labels = [self.py_labels[l] for l in sorted(right_labels)]
        self.l_classes = <size_t*>malloc(len(left_labels) * sizeof(size_t))
        self.r_classes = <size_t*>malloc(len(right_labels) * sizeof(size_t))
        self.n_l_classes = len(left_labels)
        self.n_r_classes = len(right_labels)
        valid_classes = [self.d_id]
        valid_classes.append(self.s_id)
        for i in range(self.n_class):
            self.right_arcs[i] = False
            self.left_arcs[i] = False
        for i, label in enumerate(left_labels):
            clas = self.pack_class(label, LEFT)
            valid_classes.append(clas)
            self.l_classes[i] = clas
            self.left_arcs[clas] = True
        for i, label in enumerate(right_labels):
            clas = self.pack_class(label, RIGHT)
            valid_classes.append(clas)
            self.right_arcs[clas] = True
            self.r_classes[i] = clas
        return valid_classes

    cdef size_t pack_class(self, size_t label, size_t move):
        return move * self.n_labels + label

    cdef size_t class_to_move(self, size_t clas):
        return clas / self.n_labels

    cdef size_t class_to_label(self, size_t clas):
        return clas % self.n_labels

    cdef int transition(self, size_t clas, State *s) except -1:
        cdef size_t head, child, new_parent, new_child, c, gc, move, label
        move = self.class_to_move(clas)
        label = self.class_to_label(clas)
        s.history[s.t] = clas
        s.t += 1 
        if move == SHIFT:
            push_stack(s)
        elif move == REDUCE:
            if s.heads[s.top] == 0:
                assert self.allow_reduce
                assert s.second != 0
                assert s.second < s.top
                add_dep(s, s.second, s.top, s.guess_labels[s.second][s.top])
            pop_stack(s)
        elif move == LEFT:
            child = pop_stack(s)
            if s.heads[child] != 0:
                assert get_r(s, s.heads[child]) == child, get_r(s, s.heads[child])
                del_r_child(s, s.heads[child])
            head = s.i
            add_dep(s, head, child, label)
        elif move == RIGHT:
            child = s.i
            head = s.top
            add_dep(s, head, child, label)
            push_stack(s)
        else:
            raise StandardError(lmove_to_str(move, label))
        if s.i == (s.n - 1):
            s.at_end_of_buffer = True
        if s.at_end_of_buffer and s.stack_len == 1:
            s.is_finished = True
  
    cdef bint* get_oracle(self, State* s, size_t* heads, size_t* labels) except NULL:
        cdef size_t i
        cdef bint* oracle = self._oracle
        for i in range(self.n_class):
            oracle[i] = False
        if s.stack_len == 1 and not s.at_end_of_buffer:
            oracle[self.s_id] = True
            return oracle
        if not s.at_end_of_buffer:
            self.s_oracle(s, heads, labels, oracle)
            self.r_oracle(s, heads, labels, oracle)
        if s.stack_len >= 2:
            self.d_oracle(s, heads, labels, oracle)
            self.l_oracle(s, heads, labels, oracle)
        return oracle

    cdef bint* get_valid(self, State* s):
        cdef size_t i
        cdef bint* valid = self._oracle
        for i in range(self.n_class):
            valid[i] = False
        if not s.at_end_of_buffer:
            valid[self.s_id] = True
            if s.stack_len == 1:
                return valid
            for i in range(self.n_r_classes):
                valid[self.r_classes[i]] = True
        if s.stack_len != 1:
            valid[self.d_id] = s.heads[s.top] != 0
            for i in range(self.n_l_classes):
                valid[self.l_classes[i]] = self.allow_reattach or s.heads[s.top] == 0
        if s.stack_len >= 3 and self.allow_reduce:
            valid[self.d_id] = True
        return valid  

    cdef int break_tie(self, State* s, size_t* heads, size_t* labels) except -1:
        if s.stack_len == 1:
            return self.s_id
        elif not s.at_end_of_buffer and heads[s.i] == s.top:
            return self.pack_class(labels[s.i], RIGHT)
        elif heads[s.top] == s.i and (self.allow_reattach or s.heads[s.top] == 0):
            return self.pack_class(labels[s.top], LEFT)
        elif self.d_oracle(s, heads, labels, self._oracle):
            return self.d_id
        elif not s.at_end_of_buffer and self.s_oracle(s, heads, labels, self._oracle):
            return self.s_id
        else:
            return 0
            #raise StandardError

    cdef bint s_oracle(self, State *s, size_t* heads, size_t* labels, bint* oracle):
        cdef size_t i, stack_i
        if has_child_in_stack(s, s.i, heads):
            return False
        if has_head_in_stack(s, s.i, heads):
            return False
        oracle[self.s_id] = True
        return True

    cdef bint r_oracle(self, State *s, size_t* heads, size_t* labels,
                       bint* oracle):
        cdef size_t i, buff_i, stack_i
        if heads[s.i] == s.top:
            oracle[self.pack_class(labels[s.i], RIGHT)] = True
            return True
        if has_head_in_buffer(s, s.i, heads):
            return False
        if has_child_in_stack(s, s.i, heads):
            return False
        if has_head_in_stack(s, s.i, heads):
            return False
        for i in range(self.n_r_classes):
            oracle[self.r_classes[i]] = True
        return True

    cdef bint d_oracle(self, State *s, size_t* g_heads, size_t* g_labels,
                       bint* oracle):
        if s.heads[s.top] == 0 and (s.stack_len == 2 or not self.allow_reattach):
            return False
        if has_child_in_buffer(s, s.top, g_heads):
            return False
        if has_head_in_buffer(s, s.top, g_heads):
            if self.allow_reattach:
                return False
            if self.allow_reduce and s.heads[s.top] == 0:
                return False
        oracle[self.d_id] = True
        return True

    cdef bint l_oracle(self, State *s, size_t* heads, size_t* labels, bint* oracle):
        cdef size_t buff_i, i

        if s.heads[s.top] != 0 and not self.allow_reattach:
            return False
        if heads[s.top] == s.i:
            oracle[self.pack_class(labels[s.top], LEFT)] = True
            return True
        if has_head_in_buffer(s, s.top, heads):
            return False
        if has_child_in_buffer(s, s.top, heads):
            return False
        if self.allow_reattach and heads[s.top] == s.heads[s.top]:
            return False
        if self.allow_reduce and heads[s.top] == s.second:
            return False
        for i in range(self.n_l_classes):
            oracle[self.l_classes[i]] = True
        return True


cdef transition_to_str(State* s, size_t move, label, object tokens):
    tokens = tokens + ['<end>']
    if move == SHIFT:
        return u'%s-->%s' % (tokens[s.i], tokens[s.top])
    elif move == REDUCE:
        if s.heads[s.top] == 0:
            return u'%s(%s)!!' % (tokens[s.second], tokens[s.top])
        return u'%s/%s' % (tokens[s.top], tokens[s.second])
    else:
        if move == LEFT:
            head = s.i
            child = s.top
        else:
            head = s.top
            child = s.i if s.i < len(tokens) else 0
        return u'%s(%s)' % (tokens[head], tokens[child])
