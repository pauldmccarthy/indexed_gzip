#
# Tests for the indexed_gzip module.
#
# Author: Paul McCarthy <pauldmccarthy@gmail.com>
#

from __future__ import print_function

import                    os
import os.path         as op
import itertools       as it
import functools       as ft
import subprocess      as sp
import multiprocessing as mp
import copy            as cp
import                    sys
import                    time
import                    gzip
import                    random
import                    shutil
import                    pickle
import                    hashlib
import                    textwrap
import                    tempfile
import                    contextlib

import numpy as np
from io import BytesIO
import pytest

import indexed_gzip as igzip

from . import gen_test_data
from . import check_data_valid
from . import tempdir
from . import compress

from libc.stdio cimport (SEEK_SET,
                         SEEK_CUR,
                         SEEK_END)


def error_fn(*args, **kwargs):
    raise Exception("Error")


def read_element(gzf, element, seek=True):

    if seek:
        gzf.seek(int(element) * 8)

    bytes = gzf.read(8)
    val   = np.ndarray(1, np.uint64, buffer=bytes)

    return val[0]


def write_text_to_gzip_file(fname, lines):
    with gzip.open(fname, mode='wb') as f:
        for line in lines:
            f.write('{}\n'.format(line).encode())


def test_open_close(testfile, nelems, seed, drop):

    f = igzip._IndexedGzipFile(filename=testfile, drop_handles=drop)

    assert not f.closed

    element = np.random.randint(0, nelems, 1)
    readval = read_element(f, element)

    assert readval == element

    f.close()

    assert f.closed

    with pytest.raises(IOError):
        f.close()

def test_open_function(testfile, nelems):

    f1 = None
    f2 = None

    try:

        f1 = igzip.IndexedGzipFile(testfile)
        f2 = igzip.open(           testfile)

        element  = np.random.randint(0, nelems, 1)
        readval1 = read_element(f1, element)
        readval2 = read_element(f2, element)

        assert readval1 == element
        assert readval2 == element

    finally:
        if f1 is not None: f1.close()
        if f2 is not None: f2.close()


def test_open_close_ctxmanager(testfile, nelems, seed, drop):

    with igzip._IndexedGzipFile(filename=testfile, drop_handles=drop) as f:

        element = np.random.randint(0, nelems, 1)
        readval = read_element(f, element)

    assert readval == element
    assert f.closed


def test_atts(testfile, drop):

    modes = [None, 'rb', 'r']

    for m in modes:
        with igzip._IndexedGzipFile(filename=testfile,
                                   mode=m,
                                   drop_handles=drop) as f:
            assert not f.closed
            assert     f.readable()
            assert     f.seekable()
            assert not f.writable()
            assert f.mode     == 'rb'
            assert f.tell()   == 0

            if not drop:
                assert f.fileobj() is not None
                assert f.fileno() == f.fileobj().fileno()
            else:
                with pytest.raises(igzip.NoHandleError):
                    f.fileobj()
                with pytest.raises(igzip.NoHandleError):
                    f.fileno()


def test_init_failure_cases(concat, drop):

    with tempdir() as td:
        testfile = op.join(td, 'test.gz')
        gen_test_data(testfile, 65536, concat)

        # No writing
        with pytest.raises(ValueError):
            gf = igzip._IndexedGzipFile(filename=testfile,
                                       mode='w',
                                       drop_handles=drop)
        with pytest.raises(ValueError):
            gf = igzip._IndexedGzipFile(filename=testfile,
                                       mode='wb',
                                       drop_handles=drop)

        # No writing
        f  = open(testfile, mode='wb')
        with pytest.raises(ValueError):
            gf = igzip._IndexedGzipFile(fileobj=f, drop_handles=drop)
        f.close()

        # No writing
        f  = open(testfile, mode='w')
        with pytest.raises(ValueError):
            gf = igzip._IndexedGzipFile(fileobj=f, drop_handles=drop)
        f.close()

        # Need a filename or fid
        with pytest.raises(ValueError):
            f = igzip._IndexedGzipFile(drop_handles=drop)

        # can only specify one of filename/fid
        with pytest.raises(ValueError):
            with open(testfile, mode='rb'):
                f = igzip._IndexedGzipFile(filename=testfile,
                                          fileobj=f,
                                          drop_handles=drop)


def test_init_success_cases(concat, drop):
    with tempdir() as td:
        testfile = op.join(td, 'test.gz')
        gen_test_data(testfile, 65536, concat)

        gf1 = igzip._IndexedGzipFile(filename=testfile,
                                    drop_handles=drop)
        gf2 = igzip._IndexedGzipFile(filename=testfile,
                                    mode='r',
                                    drop_handles=drop)
        gf3 = igzip._IndexedGzipFile(filename=testfile,
                                    mode='rb',
                                    drop_handles=drop)
        gf1.close()
        gf2.close()
        gf3.close()
        del gf1
        del gf2
        del gf3


def test_create_from_open_handle(testfile, nelems, seed, drop, file_like_object):

    f   = open(testfile, 'rb')
    if file_like_object:
        f = BytesIO(f.read())
    gzf = igzip._IndexedGzipFile(fileobj=f, drop_handles=drop)

    assert gzf.fileobj() is f
    assert not gzf.drop_handles

    element = np.random.randint(0, nelems, 1)
    readval = read_element(gzf, element)

    gzf.close()

    try:
        assert readval == element
        assert gzf.closed
        assert not f.closed

    finally:
        f.close()
        del gzf
        del f


def test_accept_filename_or_fileobj(testfile, nelems):

    f    = None
    gzf1 = None
    gzf2 = None
    gzf3 = None

    try:
        f    = open(testfile, 'rb')
        gzf1 = igzip._IndexedGzipFile(testfile)
        gzf2 = igzip._IndexedGzipFile(f)
        gzf3 = igzip._IndexedGzipFile(fileobj=BytesIO(open(testfile, 'rb').read()))

        element  = np.random.randint(0, nelems, 1)
        readval1 = read_element(gzf1, element)
        readval2 = read_element(gzf2, element)
        readval3 = read_element(gzf3, element)

        assert readval1 == element
        assert readval2 == element
        assert readval3 == element

    finally:
        if gzf3 is not None: gzf3.close()
        if gzf2 is not None: gzf2.close()
        if gzf1 is not None: gzf1.close()
        if f    is not None: f   .close()
        del f
        del gzf1
        del gzf2
        del gzf3


def test_prioritize_fd_over_f(testfile, nelems):
    """When a fileobj with an associated fileno is passed to IndexedGzipFile,
    the fileobj's file descriptor (fd) should be utilized by zran.c
    instead of the file-like object specified by fileobj (f).
    """
    if sys.version_info[0] < 3:
        # We can't set the .read attribute in Python 2
        # because it's read-only, so skip it.
        return

    f    = None
    gzf  = None

    try:
        f       = open(testfile, 'rb')
        f.read  = error_fn  # If the file-like object were directly used by zran.c, reading would raise an error.
        gzf     = igzip._IndexedGzipFile(fileobj=f)

        element  = np.random.randint(0, nelems, 1)
        readval  = read_element(gzf, element)

        assert readval == element

    finally:
        if gzf is not None: gzf.close()
        if f   is not None: f  .close()
        del f
        del gzf


def test_handles_not_dropped(testfile, nelems, seed):

    # When drop_handles is False
    with igzip._IndexedGzipFile(filename=testfile, drop_handles=False) as f:
        fid = f.fileobj()

        assert fid is not None

        # Check that the file object
        # doesn't change across reads
        for i in range(5):

            element = np.random.randint(0, nelems, 1)
            readval = read_element(f, element)

            assert readval == element
            assert f.fileobj() is fid

    # Also when given an open stream
    with open(testfile, 'rb') as f:
        with igzip._IndexedGzipFile(fileobj=f) as gzf:

            assert gzf.fileobj() is f

            for i in range(5):

                element = np.random.randint(0, nelems, 1)
                readval = read_element(gzf, element)

                assert readval == element
                assert gzf.fileobj() is f


def test_manual_build():
    with tempdir() as td:
        nelems = 65536
        fname = op.join(td, 'test.gz')

        gen_test_data(fname, nelems, False)

        with igzip._IndexedGzipFile(fname, auto_build=False) as f:

            # Seeking should fail
            with pytest.raises(igzip.NotCoveredError):
                f.seek(1234)

            # Reading from beginning should work
            readval = read_element(f, 0, seek=False)
            assert readval == 0

            # Seek should still fail even after read
            f.seek(0)
            with pytest.raises(igzip.NotCoveredError):
                f.seek(8)

            # But reading from beginning should still work
            readval = read_element(f, 0, seek=False)
            assert readval == 0

            # But after building the index,
            # seeking and reading should work
            f.build_full_index()

            for i in range(5):
                element = np.random.randint(0, nelems, 1)
                readval = read_element(f, element)
                assert readval == element


def test_read_all(testfile, nelems, use_mmap, drop):

    if use_mmap:
        pytest.skip('skipping test_read_all test as '
                    'it will require too much memory')

    with igzip._IndexedGzipFile(filename=testfile, drop_handles=drop) as f:
        data = f.read(nelems * 8)

    data = np.ndarray(shape=nelems, dtype=np.uint64, buffer=data)

    # Check that every value is valid
    assert check_data_valid(data, 0)


def test_simple_read_with_null_padding():
    
    with tempfile.NamedTemporaryFile() as file_in, tempfile.NamedTemporaryFile() as file_out:
        file_in.write(b"hello world")
        file_in.flush()
        compress(file_in.name, file_out.name)
        fileobj = BytesIO(open(file_out.name, "rb").read() + b"\0" * 100)
    
    with igzip._IndexedGzipFile(fileobj=fileobj) as f:
        assert f.read() == b"hello world"
        f.seek(3)
        assert f.read() == b"lo world"
        f.seek(20)
        assert f.read() == b""


def test_read_with_null_padding(testfile, nelems):

    fileobj = BytesIO(open(testfile, "rb").read() + b"\0" * 100)
    
    with igzip._IndexedGzipFile(fileobj=fileobj) as f:
        data = f.read(nelems * 8)
        # Read a bit further so we reach the zero-padded area.
        # This line should not throw an exception.
        f.read(1)
    
    data = np.ndarray(shape=nelems, dtype=np.uint64, buffer=data)

    # Check that every value is valid
    assert check_data_valid(data, 0)


def test_read_beyond_end(concat, drop):
    with tempdir() as tdir:
        nelems   = 65536
        testfile = op.join(tdir, 'test.gz')

        gen_test_data(testfile, nelems, concat)

        with igzip._IndexedGzipFile(filename=testfile,
                                   readall_buf_size=1024,
                                   drop_handles=drop) as f:
            # Try with a specific number of bytes
            data1 = f.read(nelems * 8 + 10)

            # And also with unspecified numbytes
            f.seek(0)
            data2 = f.read()

        data1 = np.ndarray(shape=nelems, dtype=np.uint64, buffer=data1)
        data2 = np.ndarray(shape=nelems, dtype=np.uint64, buffer=data2)
        assert check_data_valid(data1, 0)
        assert check_data_valid(data2, 0)


def test_seek(concat):
    with tempdir() as tdir:
        nelems   = 262144 # == 2MB
        testfile = op.join(tdir, 'test.gz')
        gen_test_data(testfile, nelems, concat)

        results = []

        with igzip._IndexedGzipFile(testfile, spacing=131072) as f:

            results.append((f.read(8), 0))

            f.seek(24, SEEK_SET)
            results.append((f.read(8), 3))

            f.seek(-16, SEEK_CUR)
            results.append((f.read(8), 2))

            f.seek(16, SEEK_CUR)
            results.append((f.read(8), 5))

            # SEEK_END only works when index is built
            with pytest.raises(ValueError):
                f.seek(-100, SEEK_END)

            f.build_full_index()

            f.seek(-800, SEEK_END)
            results.append((f.read(8), 262044))

            f.seek(-3200, SEEK_END)
            results.append((f.read(8), 261744))

        for data, expected in results:
            val = np.frombuffer(data, dtype=np.uint64)
            assert val == expected


def test_seek_and_read(testfile, nelems, niters, seed, drop):

    with igzip._IndexedGzipFile(filename=testfile, drop_handles=drop) as f:

        # Pick some random elements and make
        # sure their values are all right
        seekelems = np.random.randint(0, nelems, niters)

        for i, testval in enumerate(seekelems):

            readval = read_element(f, testval)

            ft = f.tell()

            assert ft      == (testval + 1) * 8
            assert readval == testval


def test_seek_and_tell(testfile, nelems, niters, seed, drop):

    filesize = nelems * 8

    with igzip._IndexedGzipFile(filename=testfile, drop_handles=drop) as f:

        # Pick some random seek positions
        # and make sure that seek and tell
        # return their location correctly
        seeklocs = np.random.randint(0, filesize, niters)

        for seekloc in seeklocs:

            st = f.seek(seekloc)
            ft = f.tell()

            assert ft == seekloc
            assert st == seekloc

        # Also test that seeking beyond
        # EOF is clamped to EOF
        eofseeks = [filesize,
                    filesize + 1,
                    filesize + 2,
                    filesize + 3,
                    filesize + 4,
                    filesize + 1000,
                    filesize * 1000]

        for es in eofseeks:
            assert f.seek(es) == filesize
            assert f.tell()   == filesize


def test_pread():
    with tempdir() as td:
        nelems = 1024
        testfile = op.join(td, 'test.gz')
        gen_test_data(testfile, nelems, False)

        with igzip.IndexedGzipFile(testfile) as f:
            for i in range(20):
                off  = np.random.randint(0, nelems, 1)[0]
                data = f.pread(8, off * 8)
                val  = np.frombuffer(data, dtype=np.uint64)
                assert val[0] == off


def test_readinto(drop):
    lines = textwrap.dedent("""
    line 1
    line 2
    this is line 3
    line the fourth
    here is the fifth line
    """).strip().split('\n')


    def line_offset(idx):
        return sum([len(l) for l in lines[:idx]]) + idx


    with tempdir() as td:
        testfile = op.join(td, 'test.gz')
        write_text_to_gzip_file(testfile, lines)
        with igzip._IndexedGzipFile(filename=testfile, drop_handles=drop) as f:

            # read first line into a byte array
            buf = bytearray(len(lines[0]))
            f.seek(0)
            assert f.readinto(buf) == len(lines[0])
            assert buf.decode() == lines[0]

            # read first line into memoryvew
            buf = memoryview(bytearray(len(lines[0])))
            f.seek(0)
            assert f.readinto(buf) == len(lines[0])
            assert buf.tobytes().decode() == lines[0]

            # read an arbitrary line
            offset = line_offset(2)
            buf = bytearray(len(lines[2]))
            f.seek(offset)
            assert f.readinto(buf) == len(lines[2])
            assert buf.decode() == lines[2]

            # read the end line, sans-newline
            offset = line_offset(len(lines) - 1)
            buf = bytearray(len(lines[-1]))
            f.seek(offset)
            assert f.readinto(buf) == len(lines[-1])
            assert buf.decode() == lines[-1]

            # read the end line, with newline
            buf = bytearray(len(lines[-1]) + 1)
            f.seek(offset)
            assert f.readinto(buf) == len(lines[-1]) + 1
            assert buf.decode() == lines[-1] + '\n'

            # read the end line with a bigger buffer
            buf = bytearray(len(lines[-1]) + 10)
            f.seek(offset)
            assert f.readinto(buf) == len(lines[-1]) + 1
            assert buf.decode() == lines[-1] + '\n' + (b'\0' * 9).decode()

            # start at EOF, and try to read something
            filelen = sum([len(l) for l in lines]) + len(lines)
            f.seek(filelen)
            buf = bytearray([99 for i in range(len(buf))])
            assert f.readinto(buf) == 0
            assert all([b == chr(99) for b in buf.decode()])


def test_readline(drop):
    lines = textwrap.dedent("""
    this is
    some text
    split across
    several lines
    how creative
    """).strip().split('\n')

    with tempdir() as td:
        fname = op.join(td, 'test.gz')
        write_text_to_gzip_file(fname, lines)

        with igzip._IndexedGzipFile(fname, drop_handles=drop) as f:
            seekpos = 0
            for line in lines:

                assert f.readline() == (line + '\n').encode()
                seekpos += len(line) + 1
                assert f.tell() == seekpos

            # Should return empty string after EOF
            assert f.readline() == b''

            f.seek(0)
            assert f.readline(0) == b''


def test_readline_sizelimit(drop):

    lines = ['line one', 'line two']

    with tempdir() as td:
        fname = op.join(td, 'test.gz')
        write_text_to_gzip_file(fname, lines)

        with igzip._IndexedGzipFile(fname, drop_handles=drop) as f:

            # limit to one character before the end of the first line
            l = f.readline(len(lines[0]) - 1)
            assert l == (lines[0][:-1]).encode()

            # limit to the last character of the first line
            f.seek(0)
            l = f.readline(len(lines[0]) - 1)
            assert l == (lines[0][:-1]).encode()

            # limit to the newline at the end of the first line
            f.seek(0)
            l = f.readline(len(lines[0]) + 1)
            assert l == (lines[0] + '\n').encode()

            # limit to the first character after the first line
            f.seek(0)
            l = f.readline(len(lines[0]) + 2)
            assert l == (lines[0] + '\n').encode()


def test_readlines(drop):
    lines = textwrap.dedent("""
    this is
    some more text
    split across
    several lines
    super imaginative
    test data
    """).strip().split('\n')

    with tempdir() as td:
        fname = op.join(td, 'test.gz')
        write_text_to_gzip_file(fname, lines)

        with igzip._IndexedGzipFile(fname, drop_handles=drop) as f:

            gotlines = f.readlines()

            assert len(lines) == len(gotlines)

            for expl, gotl in zip(lines, gotlines):
                assert (expl + '\n').encode() == gotl

            assert f.read() == b''


def test_readlines_sizelimit(drop):

    lines = ['line one', 'line two']
    data  = '\n'.join(lines) + '\n'

    with tempdir() as td:
        fname = op.join(td, 'test.gz')
        write_text_to_gzip_file(fname, lines)

        limits = range(len(data) + 2)

        with igzip._IndexedGzipFile(fname, drop_handles=drop) as f:

            for lim in limits:
                f.seek(0)
                gotlines = f.readlines(lim)

                # Expect the first line
                if lim < len(lines[0]) + 1:
                    assert len(gotlines) == 1
                    assert gotlines[0] == (lines[0]  + '\n').encode()

                # Expect both lines
                else:
                    assert len(gotlines) == 2
                    assert gotlines[0] == (lines[0]  + '\n').encode()
                    assert gotlines[1] == (lines[1]  + '\n').encode()


def test_iter(drop):

    lines = textwrap.dedent("""
    this is
    even more text
    that is split
    across several lines
    the creativity
    involved in generating
    this test data is
    unparalleled
    """).strip().split('\n')

    with tempdir() as td:
        fname = op.join(td, 'test.gz')
        write_text_to_gzip_file(fname, lines)

        with igzip._IndexedGzipFile(fname, drop_handles=drop) as f:
            for i, gotline in enumerate(f):
                assert (lines[i] + '\n').encode() == gotline

            with pytest.raises(StopIteration):
                 next(f)


def test_get_index_seek_points():

    with tempdir() as td:
        fname   = op.join(td, 'test.gz')
        spacing = 1048576

        # make a test file
        data = np.arange(spacing, dtype=np.uint64)
        with gzip.open(fname, 'wb') as f:
            f.write(data.tostring())

        # check points before and after index creation
        with igzip._IndexedGzipFile(fname, spacing=spacing) as f:
            assert not list(f.seek_points())
            f.build_full_index()

            expected_number_of_seek_points = 1 + int(data.nbytes / spacing)
            seek_points = list(f.seek_points())

            assert len(seek_points) == expected_number_of_seek_points

            # check monotonic growth
            uncmp_offsets = [point[0] for point in seek_points]
            assert sorted(uncmp_offsets) == uncmp_offsets


def test_import_export_index():

    with tempdir() as td:
        fname    = op.join(td, 'test.gz')
        idxfname = op.join(td, 'test.gzidx')

        # make a test file
        data = np.arange(65536, dtype=np.uint64)
        with gzip.open(fname, 'wb') as f:
            f.write(data.tostring())

        # generate an index file
        with igzip._IndexedGzipFile(fname) as f:
            f.build_full_index()
            f.export_index(idxfname)

        # Check that index file works via __init__
        with igzip._IndexedGzipFile(fname, index_file=idxfname) as f:
            f.seek(65535 * 8)
            val = np.frombuffer(f.read(8), dtype=np.uint64)
            assert val[0] == 65535

        # Check that index file works via import_index
        with igzip._IndexedGzipFile(fname) as f:
            f.import_index(idxfname)
            f.seek(65535 * 8)
            val = np.frombuffer(f.read(8), dtype=np.uint64)
            assert val[0] == 65535

        # generate an index file from open file handle
        with igzip._IndexedGzipFile(fname) as f:
            f.build_full_index()

            # Should raise if wrong permissions
            with pytest.raises(ValueError):
                with open(idxfname, 'rb') as idxf:
                    f.export_index(fileobj=idxf)

            with open(idxfname, 'wb') as idxf:
                f.export_index(fileobj=idxf)

        # Check that we can read it back
        with igzip._IndexedGzipFile(fname) as f:

            # Should raise if wrong permissions
            # (append, so existing contents are
            # not overwritten)
            with pytest.raises(ValueError):
                with open(idxfname, 'ab') as idxf:
                    f.import_index(fileobj=idxf)

            with open(idxfname, 'rb') as idxf:
                f.import_index(fileobj=idxf)
            f.seek(65535 * 8)
            val = np.frombuffer(f.read(8), dtype=np.uint64)
            assert val[0] == 65535

        # Test exporting to / importing from a file-like object
        idxf = BytesIO()
        with igzip._IndexedGzipFile(fname) as f:
            f.export_index(fileobj=idxf)
        idxf.seek(0)
        with igzip._IndexedGzipFile(fname) as f:
            f.import_index(fileobj=idxf)
            f.seek(65535 * 8)
            val = np.frombuffer(f.read(8), dtype=np.uint64)
            assert val[0] == 65535


def test_wrapper_class():

    with tempdir() as td:
        fname    = op.join(td, 'test.gz')
        idxfname = op.join(td, 'test.gzidx')

        data = np.arange(65536, dtype=np.uint64)
        with gzip.open(fname, 'wb') as f:
            f.write(data.tostring())

        with igzip.IndexedGzipFile(fname, drop_handles=False) as f:

            assert f.fileno() == f.fileobj().fileno()
            assert not f.drop_handles

            f.build_full_index()
            f.export_index(idxfname)

            f.import_index(idxfname)


def test_size_multiple_of_readbuf():

    fname = 'test.gz'

    with tempdir():
        data = np.random.randint(1, 1000, 10000, dtype=np.uint32)

        with gzip.open(fname, 'wb') as f:
            f.write(data.tobytes())
        del f
        f = None

        fsize = op.getsize(fname)
        bufsz = fsize

        with igzip.IndexedGzipFile(fname, readbuf_size=bufsz) as f:
            assert f.seek(fsize) == fsize
        del f
        f = None

        with igzip.IndexedGzipFile(fname, readbuf_size=bufsz) as f:
            read = np.ndarray(shape=10000, dtype=np.uint32, buffer=f.read())
            assert np.all(read == data)
        del f
        f = None

        # we're screwed if the
        # file size is prime
        for div in (2, 3, 5, 7, 11, 13, 17):
            if div % fsize == 0:
                break

        bufsz = fsize / div

        with igzip.IndexedGzipFile(fname, readbuf_size=bufsz) as f:
            assert f.seek(fsize) == fsize
        del f
        f = None

        with igzip.IndexedGzipFile(fname, readbuf_size=bufsz) as f:
            read = np.ndarray(shape=10000, dtype=np.uint32, buffer=f.read())
            assert np.all(read == data)
        del f
        f = None


def test_picklable():

    # default behaviour is for drop_handles=True,
    # which means that an IndexedGzipFile object
    # should be picklable/serialisable
    fname = 'test.gz'

    with tempdir():
        data = np.random.randint(1, 1000, (10000, 10000), dtype=np.uint32)
        with open(fname+'.bin', 'wb') as f:
            f.write(data.tobytes())
        compress(fname+'.bin', fname)
        del f

        gzf        = igzip.IndexedGzipFile(fname)
        first50MB  = gzf.read(1048576 * 50)
        gzf.seek(gzf.tell())
        pickled    = pickle.dumps(gzf)
        second50MB = gzf.read(1048576 * 50)
        gzf.seek(gzf.tell())

        gzf.close()
        del gzf

        gzf = pickle.loads(pickled)
        assert gzf.tell() == 1048576 * 50
        assert gzf.read(1048576 * 50) == second50MB
        gzf.seek(0)
        assert gzf.read(1048576 * 50) == first50MB
        gzf.close()
        del gzf

    # if drop_handles=False, no pickle
    with tempdir():
        data = np.random.randint(1, 1000, 50000, dtype=np.uint32)
        with gzip.open(fname, 'wb') as f:
            f.write(data.tobytes())
        del f

        gzf = igzip.IndexedGzipFile(fname, drop_handles=False)

        with pytest.raises(pickle.PicklingError):
            pickled = pickle.dumps(gzf)
        gzf.close()
        del gzf


def test_copyable():
    fname = 'test.gz'

    with tempdir():
        data = np.random.randint(1, 1000, (10000, 10000), dtype=np.uint32)
        with open(fname+'.bin', 'wb') as f:
            f.write(data.tobytes())
        compress(fname+'.bin', fname)
        del f

        gzf        = igzip.IndexedGzipFile(fname)
        gzf_copy   = cp.deepcopy(gzf)
        first50MB  = gzf.read(1048576 * 50)
        gzf.seek(gzf.tell())
        gzf_copy2  = cp.deepcopy(gzf)
        second50MB = gzf.read(1048576 * 50)
        gzf.seek(gzf.tell())

        gzf.close()
        del gzf

        assert gzf_copy.tell() == 0
        assert gzf_copy2.tell() == 1048576 * 50
        assert gzf_copy.read(1048576 * 50) == first50MB
        assert gzf_copy2.read(1048576 * 50) == second50MB
        gzf_copy2.seek(0)
        assert gzf_copy2.read(1048576 * 50) == first50MB
        gzf_copy.close()
        gzf_copy2.close()
        del gzf_copy
        del gzf_copy2

    with tempdir():
        data = np.random.randint(1, 1000, 50000, dtype=np.uint32)
        with gzip.open(fname, 'wb') as f:
            f.write(data.tobytes())
        del f

        # if drop_handles=False, no copy
        gzf = igzip.IndexedGzipFile(fname, drop_handles=False)

        with pytest.raises(pickle.PicklingError):
            gzf_copy = cp.deepcopy(gzf)
        gzf.close()
        del gzf

        # If passed an open filehandle, no copy
        with open(fname, 'rb') as fobj:
            gzf = igzip.IndexedGzipFile(fileobj=fobj)
            with pytest.raises(pickle.PicklingError):
                gzf_copy = cp.deepcopy(gzf)
            gzf.close()
            del gzf
        del fobj


def _mpfunc(gzf, size, offset):
    gzf.seek(offset)
    bytes = gzf.read(size)
    val = np.ndarray(int(size / 4), np.uint32, buffer=bytes)
    gzf.close()
    del gzf
    return val.sum()


def test_multiproc_serialise():
    fname = 'test.gz'
    with tempdir():

        data = np.arange(10000000, dtype=np.uint32)
        with gzip.open(fname, 'wb') as f:
            f.write(data.tobytes())
        del f

        gzf = igzip.IndexedGzipFile(fname)

        size    = len(data) / 16
        offsets = np.arange(0, len(data), size)
        func    = ft.partial(_mpfunc, gzf, size * 4)

        pool = mp.Pool(8)
        results = pool.map(func, offsets * 4)
        pool.close()
        pool.join()
        gzf.close()
        del gzf
        del pool

        expected = [data[off:off+size].sum() for off in offsets]

        assert results == expected


def test_32bit_overflow(niters, seed):
    with tempdir():

        block  = 2 ** 24     # 128MB
        nelems = block * 48  # 6GB

        data = np.ones(block, dtype=np.uint64).tobytes()

        with gzip.open('test.gz', 'wb') as f:
            for i in range(48):
                print('Generated to {}...'.format(block * i))
                f.write(data)

        with igzip._IndexedGzipFile(filename='test.gz') as f:

            seekelems = np.random.randint(0, nelems, niters)

            for i, testval in enumerate(seekelems):

                readval = read_element(f, testval)

                ft = f.tell()

                assert ft      == int(testval + 1) * 8
                assert readval == 1
