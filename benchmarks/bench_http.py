#!/usr/bin/env python

import os, re, subprocess, sys, time, urlparse

def run(cmdline):
    rc = os.system(cmdline)
    if rc:
        print >> sys.stderr, 'FAIL: %s'
        sys.exit(1)

def qrange(lo,hi):
    n = lo
    while n < hi:
        yield n
        n = int(round(n * 2))

pat = re.compile(r'(?:Requests per second|Time per request):\s+([0-9.]+)')

def benchmark(which, url, lo, hi):
    fp = open('%s.dat' % which, 'a')
    (scheme, netloc, path, params, query, fragment) = urlparse.urlparse(url)
    if ':' in netloc:
        host, port = netloc.split(':')
    else:
        host, port = netloc, '80'
    d = None
    for n in qrange(lo, hi):
        rpss = []
        lats = []
        print '%d:' % n
        #continue
        for i in xrange(7):
            start = time.time()
            if True:
                d = subprocess.Popen(['deadconn', host, port, str(n)],
                                     executable='./deadconn',
                                     stdout=subprocess.PIPE,
                                     stderr=subprocess.STDOUT)
                sys.stdout.write(d.stdout.readline())
                p = subprocess.Popen(['ab', '-n10000', '-c64', url],
                                     executable='ab', stdout=subprocess.PIPE)
            else:
                p = subprocess.Popen(['ab', '-n10000', '-c%d' % n, url],
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
            if d:
                d.kill()
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

which = sys.argv[1]

if len(sys.argv) > 2:
    url = sys.argv[2]
else:
    url = 'http://localhost:5002/'

if len(sys.argv) > 3:
    start = int(sys.argv[3])
else:
    start = 1

if len(sys.argv) > 4:
    end = int(sys.argv[4])
else:
    end = 20000

benchmark(which, url, start, end)
