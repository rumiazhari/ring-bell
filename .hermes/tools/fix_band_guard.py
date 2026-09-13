# Revert the stair-band guard that inflated circulation.
#
# _slice_rooms sized the stair band as
#     clampf(maxf(core.size.y, 2.4), 2.4, maxf(core.size.y, minf(3.0, ...)))
# The maxf(core.size.y, ...) "safety" term was wrong: the core rect is the stair
# CORE, not the stair hall, and it is not required to fit inside the band (the
# shaft is drawn inside the band wherever the band is). Honouring it turned the
# hall into the core's depth on plates with a deep core, so circulation hit
# 0.49-0.72 of the floor and the validator rejected those candidates for
# circ_frac -- coverage fell 59.9% -> 24.7%. The band is capped on its own.

import io
import sys

PLANNER = 'world/generation/floorplan/floor_plan_planner.gd'
OLD = 'maxf(core.size.y, minf(3.0, maxf(2.4, zone.size.y * 0.32))))'
NEW = 'minf(3.0, maxf(2.4, zone.size.y * 0.32)))'


def main() -> int:
    raw = io.open(PLANNER, encoding='utf-8').read()
    crlf = '\r\n' in raw
    t = raw.replace('\r\n', '\n') if crlf else raw
    n = t.count(OLD)
    print('matches=%d' % n)
    if n != 1:
        print('FAIL: expected exactly one anchor')
        return 1
    t = t.replace(OLD, NEW, 1)
    io.open(PLANNER, 'w', encoding='utf-8', newline='').write(
        t.replace('\n', '\r\n') if crlf else t)
    print('reverted stair-band guard')
    return 0


if __name__ == '__main__':
    sys.exit(main())
