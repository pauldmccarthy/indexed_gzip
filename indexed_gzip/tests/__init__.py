#!/usr/bin/env python
#
# __init__.py -
#
# Author: Paul McCarthy <pauldmccarthy@gmail.com>
#

import                    io
import                    os
import                    sys
import                    time
import                    gzip
import                    shutil
import                    tempfile
import                    threading
import subprocess      as sp
import multiprocessing as mp

import numpy as np


def tempdir():
    """Returnsa context manager which creates and returns a temporary
    directory, and then deletes it on exit.
    """

    class ctx(object):

        def __enter__(self):
            self.prevdir = os.getcwd()
            self.tempdir = tempfile.mkdtemp()
            os.chdir(self.tempdir)
            return self.tempdir

        def __exit__(self, *a, **kwa):
            os.chdir(self.prevdir)
            shutil.rmtree(self.tempdir)

    return ctx()


def touch(path):
    """Create an enpty file."""
    with open(path, 'wt') as f:
        pass


def poll(until):
    """Waits until ``until`` returns ``True``, printing out a message every
    minute.
    """

    start = time.time()

    while not until():
        time.sleep(0.5)
        cur = time.time()
        elapsed = int(round(cur - start))
        if int(elapsed) % 60 == 0:
            print('Waiting ({:0.2f} minutes)'.format(elapsed / 60.0))


def compress(infile, outfile, buflen=-1):
    """Use gzip to compress the data in infile, saving it to outfile.

    If buflen == -1, we compress all of the data at once. Otherwise we
    compress chunks, creating a concatenated gzip stream.
    """

    def compress_with_gzip_module():

        print('Compressing data using python gzip module ...', outfile)

        with open(infile, 'rb') as inf:
            while True:
                data = inf.read(buflen)
                if len(data) == 0:
                    break
                with open(outfile, 'ab') as outf:
                    gzip.GzipFile(fileobj=outf).write(data)

    def compress_with_gzip_command():

        with open(infile, 'rb') as inf, open(outfile, 'wb') as outf:

            # If buflen == -1, do a single call
            if buflen == -1:

                print('Compressing data with a single '
                      'call to gzip ...', outfile)

                sp.Popen(['gzip', '-c'], stdin=inf, stdout=outf).wait()

            # Otherwise chunk the call
            else:

                print('Compressing data with multiple '
                      'calls to gzip ...', outfile)

                nbytes = 0
                chunk  = inf.read(buflen)

                while len(chunk) != 0:

                    proc = sp.Popen(['gzip', '-c'], stdin=sp.PIPE, stdout=outf)
                    proc.communicate(chunk)

                    nbytes += len(chunk)

                    if (nbytes / buflen) % 10 == 0:
                        print('Compressed to {}...'.format(nbytes))

                    chunk = inf.read(buflen)

    # Use python gzip module on windows,
    # can't assume gzip exists
    if sys.platform.startswith("win"):
        target = compress_with_gzip_module

    # If not windows, assume that gzip command
    # exists, and use it, because the python
    # gzip module is super-slow.
    else:
        target = compress_with_gzip_command

    cmpThread = threading.Thread(target=target)
    cmpThread.start()
    poll(lambda : not cmpThread.is_alive())


def compress_inmem(data, concat):
    """Compress the given data (assumed to be bytes) and return a bytearray
    containing the compressed data (including gzip header and footer).
    Also returns offsets for the end of each separate stream.
    """

    f = io.BytesIO()
    if concat: chunksize = len(data) // 10
    else:      chunksize = len(data)

    offsets    = []
    compressed = 0
    print('Generating compressed data {}, concat: {})'.format(
        len(data), concat))
    while compressed < len(data):
        start = len(f.getvalue())
        chunk = data[compressed:compressed + chunksize]
        with gzip.GzipFile(mode='ab', fileobj=f) as gzf:
            gzf.write(chunk)

        end = len(f.getvalue())

        print('  Wrote stream to {} - {} [{} bytes] ...'.format(
            start, end, end - start))
        offsets.append(end)
        compressed += chunksize

    print('  Final size: {}'.format(len(f.getvalue())))

    f.seek(0)
    return bytearray(f.read()), offsets


def gen_test_data(filename, nelems, concat):
    """Make some data to test with. """

    start = time.time()

    # The file just contains a sequentially
    # increasing list of numbers

    print('Generating test data ({} elems, {} bytes -> {})'.format(
        nelems,
        nelems * 8,
        filename))

    # Generate the data as a numpy memmap array.
    # Allocate at most 128MB at a time
    toWrite        = nelems
    offset         = 0
    writeBlockSize = min(16777216, nelems)

    datafile = '{}_temp'.format(filename)

    open(datafile, 'wb+').close()
    data = np.memmap(datafile, dtype=np.uint64, shape=nelems)
    idx = 0

    while toWrite > 0:

        if idx % 10 == 0:
            print('Generated to {}...'.format(offset))

        thisWrite = min(writeBlockSize, toWrite)

        vals = np.arange(offset, offset + thisWrite, dtype=np.uint64)

        data[offset:offset + thisWrite] = vals

        toWrite  -= thisWrite
        offset   += thisWrite
        idx      += 1
        data.flush()

    if not concat: maxBufSize = -1
    else:          maxBufSize = 8 * min(16777216, nelems // 50)

    compress(datafile, filename, maxBufSize)

    end = time.time()
    del data
    os.remove(datafile)

    print('Done in {:0.2f} seconds'.format(end - start))


def _check_chunk(args):
    s, e, test_data = args
    valid  = np.arange(s, e, dtype=np.uint64)
    return np.all(test_data == valid)


def check_data_valid(data, startval, endval=None):
    if endval is None:
        endval = len(data)

    chunksize = 10000000

    startval = int(startval)
    endval   = int(endval)

    offsets = np.arange(0, len(data), chunksize)
    args = []
    result = True
    for offset in offsets:
        s      = startval + offset
        e      = min(s + chunksize, endval)
        nelems = e - s
        test_chunk = data[offset:offset + nelems]
        args.append((s, e, test_chunk))

    pool = mp.Pool()
    result = all(pool.map(_check_chunk, args))
    pool.terminate()

    return result
