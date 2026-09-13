# Third-pass audit of the floor-plan probe output.
#
# Room dicts in out_floorplans/plans.json are flat:
#   {id, kind, x, y, w, h, circ, service, entry, facade:[edge ids]}
# Legacy floors use the same shape; archetype floors add the stair hall.
#
# Reports what the first two audits could not see: whether a WC is still
# room-sized, how much of a floor goes to circulation, how deep the room bands
# are, how much of the plan is filler, and what each archetype actually serves.
# Exit code is non-zero when a hard expectation fails, so it can gate.

import io
import json
import sys
from collections import Counter, defaultdict

RESIDENTIAL = ('prague_', 'courtyard_', 'shopfront_', 'tavern_')


def is_residential(name):
    return any(name.startswith(p) for p in RESIDENTIAL)


def dims(r):
    try:
        return (float(r['x']), float(r['y']), float(r['w']), float(r['h']))
    except (KeyError, TypeError, ValueError):
        return None


def is_circ(r):
    return bool(r.get('circ', r.get('circulation', False)))


def frac(part, whole):
    return (float(part) / float(whole)) if whole else 0.0


def pct(vals, q):
    if not vals:
        return 0.0
    i = min(len(vals) - 1, max(0, int(round(q * (len(vals) - 1)))))
    return vals[i]


def door_counts(floor):
    """Count door 'openings' per room id from whichever key holds boundaries."""
    c = Counter()
    for key, val in floor.items():
        if not isinstance(val, list) or not val:
            continue
        if not isinstance(val[0], dict) or 'a' not in val[0]:
            continue
        for b in val:
            if b.get('opening') is not None:
                c[b.get('a')] += 1
                c[b.get('b')] += 1
    return c


def main():
    data = json.loads(io.open('out_floorplans/plans.json', encoding='utf-8').read())
    plans = data['plans'] if isinstance(data, dict) else data

    arche = Counter()
    kind_rooms = Counter()
    kind_area = defaultdict(float)
    arch_rooms = Counter()
    arch_tier0 = Counter()
    arch_tier0_fac = Counter()
    floors = legacy = arch_floors = buildings_with_arch = 0
    wc_over_floor = wc_over_6_5 = 0
    wc_max = 0.0
    circ_shares, circ_gross, laterals = [], [], []
    thin = filler = rooms_total = no_door = doors_total = prog_gap = 0
    res_missing = 0

    for p in plans:
        floors_here = 0
        for f in p['floors']:
            floors += 1
            a = f.get('archetype') or 'legacy'
            arche[a] += 1
            if a == 'legacy':
                legacy += 1
            else:
                arch_floors += 1
                floors_here += 1
            total = circ_area = 0.0
            for r in f.get('rooms', []):
                dd = dims(r)
                if not dd:
                    continue
                total += dd[2] * dd[3]
                if is_circ(r):
                    circ_area += dd[2] * dd[3]
            if total > 0.0:
                circ_gross.append(frac(circ_area, total))
                if a != 'legacy':
                    circ_shares.append(frac(circ_area, total))
            doors = door_counts(f)
            wanted = set()
            for r in f.get('rooms', []):
                if is_circ(r) or not r.get('kind'):
                    continue
                rooms_total += 1
                k = r['kind']
                kind_rooms[k] += 1
                if a != 'legacy':
                    arch_rooms[a] += 1
                if int(r.get('tier', 1)) == 0:
                    arch_tier0[a] += 1
                    if r.get('facade'):
                        arch_tier0_fac[a] += 1
                dd = dims(r)
                if not dd:
                    continue
                w, h = dd[2], dd[3]
                area = w * h
                kind_area[k] += area
                laterals.append(round(min(w, h), 2))
                if min(w, h) < 2.55 and not r.get('service', False) and \
                        k not in ('corridor', 'stair_hall', 'hall'):
                    thin += 1
                if k == 'toilet' and a != 'legacy':
                    wc_max = max(wc_max, area)
                    if total > 0 and area > 0.13 * total:
                        wc_over_floor += 1
                    if area > 6.5:
                        wc_over_6_5 += 1
                if k in ('storage', 'landing'):
                    filler += 1
                wanted.add(k)
                if r.get('id') and not doors.get(r.get('id')):
                    no_door += 1
            doors_total += sum(doors.values()) // 2
            if a != 'legacy':
                if 'toilet' not in wanted:
                    prog_gap += 1
                if is_residential(a) and ('kitchen' not in wanted or
                                          not ({'living', 'sleeping'} & wanted)):
                    res_missing += 1
        if floors_here:
            buildings_with_arch += 1

    laterals = sorted(v for v in laterals if v > 0)

    print('=== coverage')
    print('buildings=%d floors=%d archetype=%d legacy=%d coverage=%.1f%% '
          'buildings_with_any_archetype=%d' % (
              len(plans), floors, arch_floors, legacy,
              100.0 * frac(arch_floors, floors), buildings_with_arch))
    print('=== archetypes (floors won)')
    for a, n in arche.most_common():
        t0 = arch_tier0.get(a, 0)
        fac = ('facade %.2f' % frac(arch_tier0_fac.get(a, 0), t0)) if t0 else 'facade -'
        print('  %-26s %4d  %5.1f%%  rooms %5d  tier0 %3d  %s' % (
            a, n, 100.0 * frac(n, floors), arch_rooms.get(a, 0), t0, fac))
    live = len([a for a, n in arche.items() if a != 'legacy' and n > 0])
    dead = [a for a, n in arche.items() if a != 'legacy' and n == 0]
    print('  archetypes winning floors: %d | dead: %s' % (live, dead or 'none'))
    print('=== rooms on archetype floors (kind: count, avg m2)')
    for k, n in kind_rooms.most_common(14):
        print('  %-12s %4d  avg %.1f' % (k, n, frac(kind_area[k], n)))
    print('  kitchen/living=%.2f toilet/living=%.2f' % (
        frac(kind_rooms['kitchen'], kind_rooms['living']),
        frac(kind_rooms['toilet'], kind_rooms['living'])))
    print('=== quality')
    print('WC: max %.1f m2 | over 6.5 m2 = %d | over 13%% of floor = %d' % (
        wc_max, wc_over_6_5, wc_over_floor))
    if circ_shares:
        cs = sorted(circ_shares)
        print('circulation (archetype floors): p50 %.3f p90 %.3f max %.3f; '
              'real housing 0.10-0.20' % (pct(cs, 0.5), pct(cs, 0.9), cs[-1]))
    if circ_gross:
        cg = sorted(circ_gross)
        print('circulation gross (all floors): p50 %.3f p90 %.3f' % (
            pct(cg, 0.5), pct(cg, 0.9)))
    if laterals:
        print('room short side: p10 %.2f p50 %.2f p90 %.2f | under 2.55 m: %d/%d' % (
            pct(laterals, 0.1), pct(laterals, 0.5), pct(laterals, 0.9),
            thin, rooms_total))
    print('filler (storage/landing): %d/%d = %.1f%% | rooms with no door: %d | '
          'doors %d' % (filler, rooms_total,
                        100.0 * frac(filler, rooms_total), no_door, doors_total))
    print('=== gates')
    fails = []
    if frac(arch_floors, floors) < 0.90:
        fails.append('coverage %.1f%% < 90%%' % (100.0 * frac(arch_floors, floors)))
    if wc_over_floor:
        fails.append('room-sized WC on %d archetype floors' % wc_over_floor)
    if thin > int(0.25 * max(rooms_total, 1)):
        fails.append('thin rooms %d/%d > 25%%' % (thin, rooms_total))
    if prog_gap:
        fails.append('no WC on %d archetype floors' % prog_gap)
    if res_missing:
        fails.append('residential floors missing kitchen/living: %d' % res_missing)
    if circ_shares and pct(sorted(circ_shares), 0.5) > 0.30:
        fails.append('circulation p50 %.3f > 0.30' % pct(sorted(circ_shares), 0.5))
    if no_door:
        fails.append('%d rooms with no door' % no_door)
    if dead:
        fails.append('dead archetypes %s' % dead)
    if fails:
        for f in fails:
            print('  FAIL: %s' % f)
    else:
        print('  all gates pass')
    print('=== per-archetype serving (archetype floors only)')
    balance = defaultdict(Counter)
    for p in plans:
        for f in p['floors']:
            a = f.get('archetype')
            if not a or a == 'legacy':
                continue
            for r in f.get('rooms', []):
                if not is_circ(r) and r.get('kind'):
                    balance[a][r['kind']] += 1
    for a, n in arche.most_common():
        if a == 'legacy' or not n:
            continue
        c = balance[a]
        print('  %-26s floors %3d  rooms %4d  living %3d kitchen %3d sleeping %3d '
              'toilet %3d storage %3d' % (
                  a, n, sum(c.values()), c['living'], c['kitchen'], c['sleeping'],
                  c['toilet'], c['storage']))
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
