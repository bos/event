#!/usr/bin/env python

import os, sys, time

def run(cmdline):
    rc = os.system(cmdline)
    if rc:
        print >> sys.stderr, 'FAIL: %s'
        sys.exit(1)

if not os.path.exists('new-thread-delay'):
    run('make clean')
    run('make thread-delay')
    os.rename('thread-delay', 'new-thread-delay')

if not os.path.exists('old-thread-delay'):
    run('make clean')
    run('make thread-delay USE_GHC_IO_MANAGER=1')
    os.rename('thread-delay', 'old-thread-delay')

def qrange(lo,hi):
    n = lo
    while n < hi:
        yield n
        n = int(round(n * 1.1))

def benchmark(which, lo, hi):
    fp = open('%s.dat' % which, 'w')
    for n in qrange(lo, hi):
        times = []
        print '%d:' % n
        name = './%s-thread-delay' % which
        for i in xrange(7):
            start = time.time()
            rc = os.spawnl(os.P_WAIT, name, name, '-n%s' % n, '+RTS', '-N2')
            if rc:
                print rc
                print >> sys.stderr, 'FAIL at -n%s' % n
            elapsed = time.time() - start
            sys.stderr.write(' %.3f' % elapsed)
            times.append(elapsed)
        times.sort()
        print '    *** %.3f' % times[0]
        median = times[int(len(times)/2)]
        mean = sum(times) / len(times)
        print >> fp, ' '.join(map(str, [n, median, mean, times[0], times[-1]]))
        fp.flush()

benchmark('old', 1000, 20000)
benchmark('new', 10000, 3.5e6)
