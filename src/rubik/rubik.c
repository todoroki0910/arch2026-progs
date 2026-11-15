#include "rubik.h"

/* Optimal 2x2x2 solver: IDA* over the permutation rank p (0..5039) and the
 * orientation rank o (0..728), with h = max(perm_dist[p], ori_dist[o]). Both
 * distances are exact for their coordinate alone, so h never overestimates
 * and the first solution found under the bound is a shortest one.
 *
 * The search is the one of minirubik stage 3: one loop over an explicit stack,
 * no recursion and no call per node. Each frame g holds the state at depth g,
 * the face that reached it, and the face and move of the child being tried.
 * The next turn of the same face starts from the sibling that just returned,
 * so every child costs one lookup in each table.
 */
extern const uint16_t perm_move[3][5040];
extern const uint16_t ori_move[3][729];
extern const uint8_t perm_dist[5040];
extern const uint8_t ori_dist[729];

#define MAX_DEPTH 11 /* the diameter of the 2x2x2 in the half-turn metric */
#define NO_FACE 3

static const uint16_t *const perm_row[3] = {perm_move[0], perm_move[1],
                                            perm_move[2]};
static const uint16_t *const ori_row[3] = {ori_move[0], ori_move[1],
                                           ori_move[2]};

/* Writes the moves 0..8 (R R2 R' B B2 B' D D2 D') to path, returns their
 * number.
 */
static int ida_solve(uint32_t p0, uint32_t o0, uint8_t path[MAX_DEPTH])
{
    uint32_t P[MAX_DEPTH + 1], O[MAX_DEPTH + 1];
    uint32_t last[MAX_DEPTH + 1], face[MAX_DEPTH + 1];

    uint32_t hp = perm_dist[p0], ho = ori_dist[o0];
    uint32_t bound = hp > ho ? hp : ho;

    for (;;) {
        uint32_t next_bound = 255;
        uint32_t g = 0;
        P[0] = p0;
        O[0] = o0;
        last[0] = NO_FACE;

    enter: /* first visit to the node in frame g */
        hp = perm_dist[P[g]];
        ho = ori_dist[O[g]];
        {
            uint32_t f = g + (hp > ho ? hp : ho);
            if (f > bound) {
                if (f < next_bound)
                    next_bound = f;
                goto leave;
            }
        }
        if ((P[g] | O[g]) == 0)
            return (int) g;
        face[g] = 0;
        goto first_turn;

    next_child: /* back in frame g after a child returned */
        if (path[g] != face[g] + face[g] + face[g] + 2) {
            path[g]++;
            P[g + 1] = perm_row[face[g]][P[g + 1]];
            O[g + 1] = ori_row[face[g]][O[g + 1]];
            last[g + 1] = face[g];
            g++;
            goto enter;
        }
        face[g]++;

    first_turn: /* start face[g], skipping the face that reached frame g */
        if (face[g] == last[g])
            face[g]++;
        if (face[g] >= 3) /* at the root last is NO_FACE, so face may be 4 */
            goto leave;
        path[g] = (uint8_t) (face[g] + face[g] + face[g]);
        P[g + 1] = perm_row[face[g]][P[g]];
        O[g + 1] = ori_row[face[g]][O[g]];
        last[g + 1] = face[g];
        g++;
        goto enter;

    leave: /* frame g is done: return to its parent */
        if (g == 0) {
            bound = next_bound;
            continue;
        }
        g--;
        goto next_child;
    }
}

static const char move_char[9] = {'R', 'R', 'R', 'B', 'B', 'B', 'D', 'D', 'D'};
static const char move_suffix[9] = {0, '2', '\'', 0, '2', '\'', 0, '2', '\''};

int rubik_solve(const char *state, char *out, size_t cap)
{
    /* Validate: seven distinct cubies '1'..'7', seven twists '1'..'3' whose
     * values minus one sum to a multiple of 3, then the terminating NUL.
     */
    uint32_t seen = 0, sum = 0;
    for (int i = 0; i < 7; i++) {
        uint32_t d = (uint32_t) (state[i] - '1');
        if (d > 6 || (seen >> d & 1))
            return -1;
        seen |= 1u << d;
    }
    for (int i = 7; i < 14; i++) {
        uint32_t d = (uint32_t) (state[i] - '1');
        if (d > 2)
            return -1;
        sum += d;
    }
    if (state[14] != '\0')
        return -1;
    while (sum >= 3)
        sum -= 3;
    if (sum)
        return -1;

    /* Rank the permutation by its Lehmer code and the first six twists in
     * base 3, as the tables do.
     */
    uint32_t p = 0, o = 0;
    for (int i = 0; i < 7; i++) {
        uint32_t smaller = 0;
        for (int j = i + 1; j < 7; j++)
            smaller += state[j] < state[i];
        p = p * (uint32_t) (7 - i) + smaller;
    }
    for (int i = 7; i < 13; i++)
        o = o * 3 + (uint32_t) (state[i] - '1');

    uint8_t path[MAX_DEPTH];
    int n = ida_solve(p, o, path);

    /* The text needs one or two characters per move, a space before every
     * move but the first, and the NUL.
     */
    size_t need = 1;
    for (int i = 0; i < n; i++)
        need += (i ? 2u : 1u) + (move_suffix[path[i]] != 0);
    if (need > cap) {
        if (cap)
            out[0] = '\0';
        return -2;
    }
    char *w = out;
    for (int i = 0; i < n; i++) {
        if (i)
            *w++ = ' ';
        *w++ = move_char[path[i]];
        if (move_suffix[path[i]])
            *w++ = move_suffix[path[i]];
    }
    *w = '\0';
    return n;
}
