#!/usr/bin/env python

import os, re, subprocess, sys, time

def run(cmdline):
    rc = os.system(cmdline)
    if rc:
        print >> sys.stderr, 'FAIL: %s'
        sys.exit(1)

def qrange(lo,hi):
    n = lo
    while n < hi:
        yield n
        n = int(round(n * 1.25))

pat = re.compile(r'(?:Requests per second|Time per request):\s+([0-9.]+)')

def benchmark(which, url, lo, hi):
    fp = open('%s.dat' % which, 'w')
    for n in qrange(lo, hi):
        rpss = []
        lats = []
        print '%d:' % n
        #continue
        for i in xrange(7):
            start = time.time()
            p = subprocess.Popen(['ab', '-n30000', '-c%d' % n, url],
                                 executable='ab', stdout=subprocess.PIPE)
            rps, lat = None, None
            for line in p.stdout:
                m = pat.match(line)
                if not m:
                    continue
                if '[ms] (mean)' in line:
                    lat = float(m.group(1))
                elif '[#/sec]' in line:
                    rps = float(m.group(1))
            rc = p.wait()
            if rc:
                print >> sys.stderr, 'FAIL: %d @ %s' % (n, url)
            print '%d: %f %f' % (n, rps, lat)
            rpss.append(rps)
            lats.append(lat)
        fp.write('%d' % n)
        def report(ns):
            mean = sum(ns) / len(ns)
            median = ns[int(len(ns)/2)]
            fp.write(' %.3f %.3f %.3f %.3f' % (mean, median, ns[0], ns[-1]))
        report(sorted(rpss))
        report(sorted(lats))
        fp.write('\n')
        fp.flush()

url = 'http://localhost:5002/'

benchmark(sys.argv[1], sys.argv[2], 100, 1000)
