#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"


#include "ppport.h"

#include "const-c.inc"


#define ONE_BLOCK_SIZE		512


#define QUEUE_KEY		"queue"
#define MARKERS_KEY		"markers"
#define SEEN_KEY		"seen"
#define MODE_KEY		"mode"
#define TRAILING_KEY		"what_wait"
#define MARKER_KEY		"marker"
#define BLOCK_SIZE_KEY		"block_size"
#define TAIL_KEY		"tail"
#define COUNTER_KEY		"counter"
#define BODY_DIGIT_KEY		"is_body_digit"
#define BODY_START_KEY		"body_start"
#define NEED_EVAL_KEY		"need_eval"
#define SQUARE_BRACKET_KEY	"square_bracket_balance"
#define CURLY_BRACKET_KEY       "curly_bracket_balance"



#define HASH_STORE(__h, __k, __v) *hv_store(__h, __k, sizeof(__k) - 1, __v, 0)
#define HASH_FETCH(__h, __k)      *hv_fetch(__h, __k, sizeof(__k) - 1, 0)
#define CASESPACE case ' ': case '\r': case '\n': case '\t': case '\f':
#define CASEDIGIT case '0': case '1': case '2': case '3': case '4': \
		  case '5': case '6': case '7': case '8': case '9':
#define IS_SPACE(__c) \
	(__c == ' ' || __c == '\r' || __c == '\n' || __c == '\t' || __c == '\f')
#define IS_DIGIT(__c) \
	(__c == '0' || __c == '1' || __c == '2' || __c == '3' || __c == '4' || \
	__c == '5' || __c == '6' || __c == '7' || __c == '8' || __c == '9' )


typedef enum {
	 WAIT_OBJECT = 1,
	 WAIT_OBJECT_TAIL,
	 WAIT_DIVIDER,

	 ERROR_UNEXPECTED_SYMBOL = -1000,
	 ERROR_BRACKET,
	 ERROR_SCALAR,
} mode;
typedef enum {
	 NO_OBJECT = 0,
	 EVAL_OBJECT,
	 UNDEF_OBJECT,
	 PARSED_OBJECT,
} object_type;


#define NO_MARKER	0

typedef struct {
	STRLEN		len;		// len and string
	char		*str;		//
	char		tsymbol;	// waiting trailing symbol
	int		marker;		// place where start marker was found
	int		seen;		// how many symbols was seen earlier
	mode		mode;		// current wait mode
	int		need_eval;	// if object need to be eval
	int		counter;	// session counter
	int		body;		// index of object's body
	int		body_size;	// body_size
	int		block_size;	// ONE_BLOCK_SIZE
	int		body_digit;	// body is digit
	object_type	object_found;	// type of found object
	char		marker_found;
	int		square_brackets;	// bracket_balance_counters
	int             curly_brackets;         //
} state;


static inline char get_end_bracket(char c) {


	switch(c) {
		case '{':
			return '}';
		case '[':
			return ']';
		case '(':
			return ')';
		case '<':
			return '>';
		case '~' :
		case '!' :
		case '@' :
		case '#' :
		case '%' :
		case '&' :
		case '$' :
		case '-' :
		case '+' :
		case '|' :
		case '\\':
		case '/' :
		case ',' :
		case '.' :
		case ';' :
		case ':' :
		case '\'':
		case '"' :
		case '^' :
			return c;
	}
	return 0;
}

static int seek_object(state * state) {
	int i;

	for (i = state->seen; i < state->len; i++) {
		state->counter++;
		if (state->counter >= state->block_size)
			break;

		switch(state->str[i]) {
			/* ignore spaces */
			CASESPACE
				state->seen = i + 1;
				break;

			/* usually quotting */
			case '"' :
			case '\'':
				state->marker = i;
				state->body = i + 1;
				state->body_size = 0;
				state->mode = WAIT_OBJECT_TAIL;
				state->seen = i + 1;
				state->tsymbol = state->str[i];
				state->body_digit = 0;
				state->need_eval = 0;
				return 1;


			case ']':
			case '}':
				state->mode = WAIT_DIVIDER;

			case '[':
			case '{':
			case '\\':
				state->seen = i + 1;
				state->marker_found = state->str[i];
				return 1;

			case '+':
			case '-':
				state->marker = i;
				state->seen = i + 1;
				state->body = i;
				state->body_size = 0;
				state->mode = WAIT_OBJECT_TAIL;
				state->tsymbol = ' ';
				state->body_digit = 1;
				return 1;
			CASEDIGIT
				state->marker = i;
				state->seen = i + 1;
				state->body = i;
				state->body_size = 0;
				state->mode = WAIT_OBJECT_TAIL;
				state->tsymbol = '1';
				state->body_digit = 1;
				return 1;



			case 'u':
				if (i + 4 >= state->len) {
					state->seen = i;
					return 0;
				}

				if (strncmp(&state->str[i], "undef", 5)==0) {
					state->object_found = UNDEF_OBJECT;
					state->mode = WAIT_DIVIDER;
					state->seen = i + 5;
					return 1;
				}
				state->mode = ERROR_UNEXPECTED_SYMBOL;
				state->seen = i;
				return 0;

			/* perl quotting */
			case 'q':
			{
				if (i + 2 >= state->len) {
					state->seen = i;
					return 0;
				}

				int j = i + 1;
				const char *p = state->str;

                                state->need_eval = 0;
				if (p[j] == 'q') {
					j++;
                                } else {
                                    if (p[j] == 'r') {
					j++;
					state->need_eval = 1;
                                    }
                                }

				char end_symbol = get_end_bracket(p[j]);
				if (end_symbol) {
					state->marker = i;
					state->body_size = 0;
					state->mode = WAIT_OBJECT_TAIL;
					state->seen = j + 1;
					state->body = j + 1;
					state->tsymbol = end_symbol;
					state->body_digit = 0;
					return 1;
				}
			} /* no break: error */

			/* unexpected symbol */
			default:
				state->mode = ERROR_UNEXPECTED_SYMBOL;
				state->seen = i;
				return 0;
		}
	}

	return 0;

}


static int seek_object_tail(state *state) {
	int i;

	for (i = state->seen; i < state->len; i++) {
		state->counter++;
		if (state->counter >= state->block_size)
			break;

		if (state->body_digit) {
			/* ignore spaces */
			if (state->tsymbol == ' ') {
				if (IS_SPACE(state->str[i])) {
					state->seen = i + 1;
					continue;
				}

				if (IS_DIGIT(state->str[i])) {
					state->tsymbol = state->str[i];
					state->seen = i + 1;
					continue;
				}

				state->mode = ERROR_UNEXPECTED_SYMBOL;
				state->seen = state->body;
				return 0;
			}

			if (IS_DIGIT(state->str[i])) {
				state->seen = i + 1;
				continue;
			}

			/* found the end of digit */
			state->body_size = i - state->body;
			state->seen = i;
			state->object_found = PARSED_OBJECT;
			if (state->str[state->body] == '+')
			    state->object_found = EVAL_OBJECT;
			state->mode = WAIT_DIVIDER;

			return 1;
		}

		/* found the object */
		if (state->str[i] == state->tsymbol) {
			state->seen = i + 1;
			state->mode = WAIT_DIVIDER;
			if (state->need_eval) {
				state->body = state->marker;
				state->object_found = EVAL_OBJECT;
				state->body_size = i - state->body + 1;
			} else {
				state->body_size = i - state->body;
				state->object_found = PARSED_OBJECT;
			}
			return 1;
		}

		if (state->str[i] == '\\') {
			if (i < state->len - 1) {
				i++;			// skip escaped symbol
				state->need_eval = 1;
				state->seen = i + 1;
				continue;
			}
			state->seen = i;
			return 0;
		}

		state->seen = i + 1;
	}

	return 0;
}


static int seek_divider(state *state) {
	int i;
	for (i = state->seen; i < state->len; i++) {
		state->counter++;
		if (state->counter >= state->block_size)
			break;

		switch(state->str[i]) {
			case ',':
				state->seen = i + 1;
				state->mode = WAIT_OBJECT;
				return 1;
			case '=':
				if (i >= state->len - 1) {
					state->seen = i;
					return 0;
				}
				if (state->str[i+1] == '>') {
					state->seen = i + 2;
					state->mode = WAIT_OBJECT;
					return 1;
				}
			CASESPACE
				break;

			case ']':
			case '}':
				state->marker_found = state->str[i];
				state->seen = i + 1;
				return 1;


			/* unexpected sequence */
			default:
				state->mode = ERROR_UNEXPECTED_SYMBOL;
				state->seen = i;
				return 0;

		}
		state->seen = i + 1;

	}
	return 0;
}


static int eval_value(SV * v) {
	dSP;
	int count;
	int ok = 1;

	ENTER;
	SAVETMPS;

	PUSHMARK(SP);
	// XPUSHs(v);
	// PUTBACK;

	// count = call_pv("Data::StreamDeserializer::_val_eval", G_SCALAR);

	count = eval_sv(v, G_SCALAR);
	if (count != 1)
		croak("Data::StreamDeserializer::_val_eval must return scalar");

	SPAGAIN;
	if (SvTRUE(ERRSV)) {
		sv_setsv(v, ERRSV);
		ok = 0;
		POPs;
	} else {
		sv_setsv(v, POPs);
	}

	PUTBACK;
	FREETMPS;
	LEAVE;

	return ok;
}


static SV * collapse_ref_markers(SV *v, AV *queue, AV *markers) {
	int i;
	int mcount = av_len(markers);
	int number = av_len(queue) + 1;
	if (mcount == -1) return v;

	for (i = mcount; i >= 0; i--) {
		AV * minfo = (AV *)SvRV(*av_fetch(markers, i, 0));
		if (SvIV(*av_fetch(minfo, 1, 0)) != number)
			return v;
		if (*SvPV_nolen(*av_fetch(minfo, 0, 0)) != '\\')
			return v;
		v = newRV_noinc(v);
		SvREFCNT_dec(av_pop(markers));
	}

	return v;
}

static void collapse_arrayref(state * state, AV * queue, AV *markers) {
	int i;
	int mcount = av_len(markers) + 1;
	int qcount = av_len(queue) + 1;
	if (!mcount)
		return;

	AV *close_marker = (AV *)SvRV(*av_fetch(markers, mcount - 1, 0));

	/* verify */
	if (*SvPV_nolen(*av_fetch(close_marker, 0, 0)) != ']')
		return;

	int close_index = SvIV(*av_fetch(close_marker, 1, 0));
	if (close_index != qcount) {
		state->mode = ERROR_BRACKET;
		return;
	}

	if (mcount < 2) {
		state->mode = ERROR_BRACKET;
		return;
	}


	AV *open_marker = (AV *)SvRV(*av_fetch(markers, mcount - 2, 0));
	/* verify */
	if (*SvPV_nolen(*av_fetch(open_marker, 0, 0)) != '[') {
		state->mode = ERROR_BRACKET;
		return;
	}

	int open_index = SvIV(*av_fetch(open_marker, 1, 0));

	if (open_index > close_index || open_index < 0) {
		state->mode = ERROR_BRACKET;
		return;
	}

	AV * ar = newAV();
	if (close_index > open_index)
		av_extend(ar, close_index - open_index);
	for (i = open_index; i < close_index; i++) {
		SV *e = *av_fetch(queue, i, 0);
		av_push(ar, e);
	}
	for (i = open_index; i < close_index; i++)
		av_pop(queue);

	SvREFCNT_dec(av_pop(markers));
	SvREFCNT_dec(av_pop(markers));

	ar = (AV *) collapse_ref_markers((SV *)ar, queue, markers);
	av_push(queue, newRV_noinc((SV *)ar));
}

static void collapse_hashref(state * state, AV * queue, AV *markers) {
	int i;
	int mcount = av_len(markers) + 1;
	int qcount = av_len(queue) + 1;
	if (!mcount)
		return;

	AV *close_marker = (AV *)SvRV(*av_fetch(markers, mcount - 1, 0));

	/* verify */
	if (*SvPV_nolen(*av_fetch(close_marker, 0, 0)) != '}')
		return;

	int close_index = SvIV(*av_fetch(close_marker, 1, 0));
	if (close_index != qcount) {
		state->mode = ERROR_BRACKET;
		return;
	}

	if (mcount < 2) {
		state->mode = ERROR_BRACKET;
		return;
	}


	AV *open_marker = (AV *)SvRV(*av_fetch(markers, mcount - 2, 0));
	/* verify */
	if (*SvPV_nolen(*av_fetch(open_marker, 0, 0)) != '{') {
		state->mode = ERROR_BRACKET;
		return;
	}

	int open_index = SvIV(*av_fetch(open_marker, 1, 0));

	if (open_index > close_index || open_index < 0) {
		state->mode = ERROR_BRACKET;
		return;
	}

	// odd elements: our behaviour is like eval
	if ((close_index - open_index) % 2) {
		av_push(queue, newSV(0));
		close_index++;
	}

	HV * hr = newHV();
	for (i = open_index; i < close_index; i+= 2) {
		SV *k, *v;
		v = av_pop(queue);
		k = av_pop(queue);

		// undefined key: we do this action like 'eval'
		if (!SvOK(k))
			sv_setpvn(k, "", 0);

		// hv_store_ent(hr, sv_2mortal(k), v, 0);
		hv_store_ent(hr, k, v, 0);
		SvREFCNT_dec(k);
	}

	SvREFCNT_dec(av_pop(markers));
	SvREFCNT_dec(av_pop(markers));

	hr = (HV *) collapse_ref_markers((SV *)hr, queue, markers);
	av_push(queue, newRV_noinc((SV *)hr));
}

MODULE = Data::StreamDeserializer PACKAGE = Data::StreamDeserializer
INCLUDE: const-xs.inc
PROTOTYPES: ENABLE


HV * _ds_init()
    PREINIT:
        HV *res		= newHV();
    CODE:
        sv_2mortal((SV *)res);
        HASH_STORE(res, QUEUE_KEY, newRV_noinc((SV *)newAV()));
        HASH_STORE(res, MARKERS_KEY, newRV_noinc((SV *)newAV()));
        HASH_STORE(res, SEEN_KEY, newSViv(0));
        HASH_STORE(res, MODE_KEY, newSViv(WAIT_OBJECT));
        HASH_STORE(res, TRAILING_KEY, newSVpv("}", 1));
        HASH_STORE(res, MARKER_KEY, newSViv(0));
        HASH_STORE(res, BLOCK_SIZE_KEY, newSViv(ONE_BLOCK_SIZE));
        HASH_STORE(res, TAIL_KEY, newSVpv("", 0));
        HASH_STORE(res, COUNTER_KEY, newSViv(0));
        HASH_STORE(res, BODY_DIGIT_KEY, newSViv(0));
        HASH_STORE(res, BODY_START_KEY, newSViv(0));
        HASH_STORE(res, NEED_EVAL_KEY, newSViv(0));
        HASH_STORE(res, SQUARE_BRACKET_KEY, newSViv(0));
        HASH_STORE(res, CURLY_BRACKET_KEY, newSViv(0));

        RETVAL		= res;
    OUTPUT:
        RETVAL



int _ds_look_tail(st, data)
        HV * st
        SV * data
    PREINIT:
        AV * queue;
        AV * markers;
        state state;
        state.counter = 0;
        state.str = SvPV(data, state.len);
    CODE:
        if (!state.len) {
            if (state.mode < 0) {
		RETVAL = 1;
            } else {
                if (state.seen)
                    RETVAL = 0;
                else
                    RETVAL = 1;
            }
            return;
        }

        queue	= (AV *) SvRV((AV *) HASH_FETCH(st, QUEUE_KEY));
        markers	= (AV *) SvRV((AV *) HASH_FETCH(st, MARKERS_KEY));
        state.mode = SvIV(HASH_FETCH(st, MODE_KEY));
        state.seen = SvIV(HASH_FETCH(st, SEEN_KEY));
        state.marker = SvIV(HASH_FETCH(st, MARKER_KEY));
        state.tsymbol = *SvPV_nolen(HASH_FETCH(st, TRAILING_KEY));

        state.body = SvIV(HASH_FETCH(st, BODY_START_KEY));
        state.body_digit = SvIV(HASH_FETCH(st, BODY_DIGIT_KEY));
        state.need_eval = SvIV(HASH_FETCH(st, NEED_EVAL_KEY));
        state.square_brackets =
            SvIV(HASH_FETCH(st, SQUARE_BRACKET_KEY));
        state.curly_brackets = SvIV(HASH_FETCH(st, CURLY_BRACKET_KEY));

        state.object_found = NO_OBJECT;
        state.marker_found = NO_MARKER;
        state.block_size = SvIV(HASH_FETCH(st, BLOCK_SIZE_KEY));

        if (!state.block_size)
                state.block_size = ONE_BLOCK_SIZE;

        for (;state.mode >= 0;) {
                int cf = 0;
                switch(state.mode) {
                        case WAIT_OBJECT:
                                cf = seek_object(&state);
                                break;
                        case WAIT_OBJECT_TAIL:
                                cf = seek_object_tail(&state);
                                break;

                        case WAIT_DIVIDER:
                                cf = seek_divider(&state);
                                break;
                }


                if (state.object_found) {
                        SV * v = newSVpvn(
                                state.str + state.body,
                                state.body_size
                        );

                        switch(state.object_found) {
                                case EVAL_OBJECT:
                                        if (!eval_value(v)) {
                                                state.mode = ERROR_SCALAR;
                                                state.seen = state.body;
                                        }
                                        break;
                                case UNDEF_OBJECT:
                                        sv_setsv(v,
                                                 sv_2mortal(newSV(0)));
                                        break;
                        }


			v = collapse_ref_markers(v, queue, markers);
                        av_push(queue, v);
                        state.object_found = 0;
                }

                if (state.marker_found) {
                        AV * mi = newAV();
                        av_push(mi, newSVpvn(&state.marker_found, 1));
                        av_push(mi, newSViv(av_len(queue) + 1));

                        if (state.marker_found == '{')
                                state.curly_brackets++;
                        if (state.marker_found == '}')
                                state.curly_brackets--;
                        if (state.marker_found == '[')
                                state.square_brackets++;
                        if (state.marker_found == ']')
                                state.square_brackets--;

                        if (state.square_brackets < 0) {
                                state.mode = ERROR_BRACKET;
                                state.seen--;
                                break;
                        }

                        if (state.curly_brackets < 0) {
                                state.mode = ERROR_BRACKET;
                                state.seen--;
                                break;
                        }

                        av_push(markers, newRV_noinc((SV *) mi));

                        if (state.marker_found == ']')
				collapse_arrayref(&state, queue, markers);

                        if (state.marker_found == '}')
				collapse_hashref(&state, queue, markers);
                        state.marker_found = 0;
                }

                if (!cf)
                        break;
                if (state.seen >= state.len)
                        break;
        }

        sv_setiv(HASH_FETCH(st, MODE_KEY), state.mode);
        sv_setiv(HASH_FETCH(st, SEEN_KEY), state.seen);
        sv_setpvn(HASH_FETCH(st, TRAILING_KEY), &state.tsymbol, 1);
        sv_setiv(HASH_FETCH(st, MARKER_KEY), state.marker);
        sv_setiv(HASH_FETCH(st, COUNTER_KEY), state.counter);
        sv_setiv(HASH_FETCH(st, BODY_DIGIT_KEY), state.body_digit);
        sv_setiv(HASH_FETCH(st, BODY_START_KEY), state.body);
        sv_setiv(HASH_FETCH(st, NEED_EVAL_KEY), state.need_eval);
        sv_setiv(
            HASH_FETCH(st, SQUARE_BRACKET_KEY), state.square_brackets);
        sv_setiv(
            HASH_FETCH(st, CURLY_BRACKET_KEY), state.curly_brackets);


        // if eof we will show unparsed tail
        if (state.mode == WAIT_OBJECT_TAIL) {
            sv_setpvn(
                HASH_FETCH(st, TAIL_KEY),
                &state.str[state.marker],
                state.len - state.marker
            );
        } else {
            if (state.seen < state.len)
                sv_setpvn(HASH_FETCH(st, TAIL_KEY),
                        &state.str[state.seen], state.len - state.seen);
            else
                sv_setpvn(HASH_FETCH(st, TAIL_KEY), "", 0);
        }

        if (state.seen < state.len) {
                if (state.mode < 0)
                    RETVAL = 1;
                else
                    RETVAL = 0;
        } else {
                RETVAL = 1;
        }

    OUTPUT:
        RETVAL

unsigned long _memory_size()
        CODE:
                RETVAL = (unsigned long) sbrk(0);
        OUTPUT:
                RETVAL
