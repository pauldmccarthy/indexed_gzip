#
# Tests for the zran module.
#
# Author: Paul McCarthy <pauldmccarthy@gmail.com>
#

from __future__ import print_function
from __future__ import division

import                    os
import os.path         as op
import itertools       as it
import subprocess      as sp
import                    sys
import                    time
import                    gzip
import                    shutil
import                    random
import                    hashlib
import                    tempfile
import                    threading
import                    contextlib

import numpy as np

# The stdlib resource module is only
# available on unix-like platforms.
try:
    import resource
except ImportError:
    resource = None


cimport numpy as np

from posix.types cimport  off_t
from io import BytesIO

from libc.stdio  cimport (SEEK_SET,
                          SEEK_CUR,
                          SEEK_END,
                          FILE,
                          fdopen,
                          fwrite)

from libc.stdint cimport int64_t

from libc.string cimport memset, memcmp

from cpython.exc cimport (PyErr_Clear,
                          PyErr_SetString)
from cpython.mem cimport (PyMem_Malloc,
                          PyMem_Realloc,
                          PyMem_Free)
from cpython.ref cimport PyObject

from posix.mman cimport (mmap,
                         munmap,
                         PROT_READ,
                         PROT_WRITE,
                         MAP_ANON,
                         MAP_SHARED)


from . import poll, check_data_valid, tempdir, compress_inmem


cdef extern from "sys/mman.h":
    cdef enum:
        MAP_FAILED

cimport indexed_gzip.zran as zran
cimport indexed_gzip.zran_file_util as zran_file_util

np.import_array()

cdef read_element(zran.zran_index_t *index, element, nelems, seek=True):

    cdef void *buffer

    buf    = ReadBuffer(8)
    buffer = buf.buffer

    if   element >= nelems: expseek = zran.ZRAN_SEEK_EOF
    else:                   expseek = zran.ZRAN_SEEK_OK

    if   element >= nelems: exptell = (nelems * 8)
    else:                   exptell = element * 8


    if seek:
        gotseek = zran.zran_seek(index, element * 8, SEEK_SET, NULL)
        gottell = zran.zran_tell(index)
        try:
            assert gotseek == expseek
            assert gottell == exptell
        except:
            print('expseek: {}'.format(expseek))
            print('exptell: {}'.format(exptell))
            print('gotseek: {}'.format(gotseek))
            print('gottell: {}'.format(gottell))
            raise


    if   element >= nelems: expread = zran.ZRAN_READ_EOF
    else:                   expread = 8

    if   element >= nelems: exptell = (nelems * 8)
    else:                   exptell = (element + 1) * 8

    gotread = zran.zran_read(index, buffer, 8)
    gottell = zran.zran_tell(index)

    try:
        assert gotread == expread
        assert gottell == exptell
    except:
        print('nelems:  {}'.format(nelems))
        print('element: {}'.format(element))
        print('expread: {}'.format(expread))
        print('exptell: {}'.format(exptell))
        print('gotread: {}'.format(gotread))
        print('gottell: {}'.format(gottell))
        raise

    if element < nelems:
        pybuf = <bytes>(<char *>buffer)[:8]
        val   = np.ndarray(1, np.uint64, buffer=pybuf)
        return val[0]
    else:
        return None


cdef class ReadBuffer:
    """Wrapper around a chunk of memory.

    .. see:: http://docs.cython.org/src/tutorial/memory_allocation.html
    """

    cdef void *buffer
    """A raw chunk of bytes. """

    cdef bint use_mmap
    """
    """

    cdef size_t size
    """
    """

    cdef object mmap_fd
    cdef object mmap_path


    def __cinit__(self, size_t size, use_mmap=False):
        """Allocate ``size`` bytes of memory. """

        self.use_mmap  = use_mmap
        self.mmap_fd   = None
        self.mmap_path = None
        self.size      = size
        self.buffer    = NULL

        if not self.use_mmap:
            self.buffer = PyMem_Malloc(size)

            memset(self.buffer, 0, size);

        else:

            fd, path = tempfile.mkstemp('readbuf_mmap_{}'.format(id(self)))

            print('Memory-mapping {:0.2f} GB ({})'.format(size / 1073741824., path))

            def initmem():

                towrite = size

                while towrite > 0:

                    zeros    = np.zeros(min(towrite, 134217728), dtype=np.uint8)
                    towrite -= len(zeros)

                    os.write(fd, zeros.tostring())

            th = threading.Thread(target=initmem)
            th.start()
            poll(lambda : not th.is_alive())

            self.mmap_fd   = fd
            self.mmap_path = path
            self.buffer    = mmap(NULL,
                                  size,
                                  PROT_READ | PROT_WRITE,
                                  MAP_SHARED,
                                  fd,
                                  0)

            if self.buffer == <void*>MAP_FAILED:
                raise RuntimeError('mmap fail')

        if not self.buffer:
            raise RuntimeError('ReadBuffer init fail')


    def resize(self, size_t size):
        """Re-allocate the memory to the given ``size``. """

        if self.use_mmap:
            raise NotImplementedError('Cannot resize a memmapped array!')

        buf = PyMem_Realloc(self.buffer, size)

        if not buf:
            raise MemoryError('PyMem_Realloc fail')

        self.buffer = buf
        self.size   = size


    def __dealloc__(self):
        """Free the mwmory. """

        if not self.use_mmap:
            PyMem_Free(self.buffer)
        else:
            munmap(self.buffer, self.size)
            os.close( self.mmap_fd)
            os.remove(self.mmap_path)


def error_fn(*args, **kwargs):
    raise Exception("Error")


def return_fn(return_value):
    return lambda *args, **kwargs: return_value


def test_fread():
    """Tests Python wrapper C function for fread."""

    f = BytesIO(b"abc")
    cdef char buf[3]
    elems_read = zran_file_util._fread_python(buf, 1, 3, <PyObject*>f)
    assert elems_read == 3
    assert f.tell() == 3
    assert buf[0:3] == b"abc"
    assert zran_file_util._ferror_python(<PyObject*>f) == 0

    # fread error conditions:
    for fn in [error_fn, return_fn(None)]:
        f.read = fn
        assert zran_file_util._fread_python(buf, 1, 3, <PyObject*>f) == 0
        assert zran_file_util._ferror_python(<PyObject*>f) == 1
        PyErr_Clear()


def test_ftell():

    f = BytesIO(b"abc")
    assert zran_file_util._ftell_python(<PyObject*>f) == 0
    f.seek(2)
    assert zran_file_util._ftell_python(<PyObject*>f) == 2
    assert zran_file_util._ferror_python(<PyObject*>f) == 0

    # ftell error conditions
    for fn in [error_fn, return_fn(None)]:
        f.tell = fn
        assert zran_file_util._ftell_python(<PyObject*>f) == -1
        assert zran_file_util._ferror_python(<PyObject*>f) == 1
        PyErr_Clear()


def test_fseek():

    f = BytesIO(b"abc")
    zran_file_util._fseek_python(<PyObject*>f, 1, SEEK_SET)
    assert f.tell() == 1
    zran_file_util._fseek_python(<PyObject*>f, -1, SEEK_END)
    assert f.tell() == 2
    zran_file_util._fseek_python(<PyObject*>f, 100, SEEK_SET)
    assert f.tell() == 100
    assert zran_file_util._ferror_python(<PyObject*>f) == 0

    # fseek error conditions
    for fn in [error_fn]:
        f.seek = fn
        assert zran_file_util._fseek_python(<PyObject*>f, 1, SEEK_SET) == -1
        assert zran_file_util._ferror_python(<PyObject*>f) == 1
        PyErr_Clear()


def test_feof():

    f = BytesIO(b"abc")
    f.seek(0)
    # the EOF indicator shouldn't be set...
    assert zran_file_util._feof_python(<PyObject*>f, 2) == 0
    # ...unless f_read is zero.
    assert zran_file_util._feof_python(<PyObject*>f, 0) == 1
    assert zran_file_util._ferror_python(<PyObject*>f) == 0


def test_ferror():

    f = BytesIO(b"abc")
    assert zran_file_util._ferror_python(<PyObject*>f) == 0
    PyErr_SetString(ValueError, "Error")
    assert zran_file_util._ferror_python(<PyObject*>f) == 1
    PyErr_Clear()
    assert zran_file_util._ferror_python(<PyObject*>f) == 0


def test_fflush():

    f = BytesIO(b"abc")
    zran_file_util._fflush_python(<PyObject*>f)
    assert zran_file_util._ferror_python(<PyObject*>f) == 0

    # fflush error conditions
    for fn in [error_fn]:
        f.flush = fn
        assert zran_file_util._fflush_python(<PyObject*>f) == -1
        assert zran_file_util._ferror_python(<PyObject*>f) == 1
        PyErr_Clear()


def test_fwrite():

    f = BytesIO(b"abc")
    cdef char* inp = 'de'
    elems_written = zran_file_util._fwrite_python(inp, 1, 2, <PyObject*>f)
    assert elems_written == 2
    assert f.tell() == 2
    assert zran_file_util._ferror_python(<PyObject*>f) == 0
    f.seek(0)
    assert f.read() == b"dec"

    # fwrite error conditions
    # In Python 2, .write() returns None, so its return value
    # is ignored by _fwrite_python and can't cause an error.
    for fn in [error_fn, return_fn(None)] if sys.version_info[0] >= 3 else [error_fn]:
        f.write = fn
        result = zran_file_util._fwrite_python(inp, 1, 2, <PyObject*>f)
        assert result == 0, result
        assert zran_file_util._ferror_python(<PyObject*>f) == 1
        PyErr_Clear()


def test_getc():

    f = BytesIO(b"dbc")
    assert zran_file_util._getc_python(<PyObject*>f) == ord(b"d")
    assert zran_file_util._ferror_python(<PyObject*>f) == 0
    assert zran_file_util._getc_python(<PyObject*>f) == ord(b"b")
    assert zran_file_util._ferror_python(<PyObject*>f) == 0
    assert zran_file_util._getc_python(<PyObject*>f) == ord(b"c")
    assert zran_file_util._ferror_python(<PyObject*>f) == 0
    assert zran_file_util._getc_python(<PyObject*>f) == -1 # reached EOF
    assert zran_file_util._ferror_python(<PyObject*>f) == 0
    assert zran_file_util._feof_python(<PyObject*>f, 0) == 1

    # getc error conditions
    for fn in [error_fn, return_fn(None)]:
        f.read = fn
        assert zran_file_util._getc_python(<PyObject*>f) == -1
        assert zran_file_util._ferror_python(<PyObject*>f) == 1
        PyErr_Clear()


def test_seekable():

    f = BytesIO(b"abc")
    assert zran_file_util._seekable_python(<PyObject*>f) == 1
    f.seekable = lambda: False
    assert zran_file_util._seekable_python(<PyObject*>f) == 0


def test_init(testfile, no_fds):
    """Tests a bunch of permutations of the parameters to zran_init. """

    spacings      = [0, 16384, 32768, 65536, 524288, 1048576, 2097152, 4194304]
    window_sizes  = [0, 8192, 16384, 32768, 65536, 131072]
    readbuf_sizes = [0, 8192, 16384, 24576, 32768, 65536, 131072]
    flags         = [0, zran.ZRAN_AUTO_BUILD]

    cdef zran.zran_index_t index
    cdef FILE             *cfid

    with open(testfile, 'rb') as pyfid:

        cfid = fdopen(pyfid.fileno(), 'rb')

        for s, w, r, f in it.product(spacings,
                                     window_sizes,
                                     readbuf_sizes,
                                     flags):

            result = not zran.zran_init(&index, NULL if no_fds else cfid, <PyObject*>pyfid if no_fds else NULL, s, w, r, f)

            expected = True

            # zran_init should fail if the point spacing
            # is less than the window size

            if w == 0: w = 32768
            if s == 0: s = 1048576
            if r == 0: r = 16384

            expected = (w >= 32768) and (s > w)

            assert result == expected

            zran.zran_free(&index)


def test_init_file_modes(testfile, no_fds):

    modes = ['r', 'r+', 'w', 'w+', 'a', 'a+']

    files = [testfile, testfile,
             'dummy.gz', 'dummy.gz', 'dummy.gz', 'dummy.gz']

    cdef zran.zran_index_t index
    cdef FILE             *cfid
    cdef bytes             bmode
    cdef char             *cmode

    for filename, mode in zip(files, modes):

        with open(filename, mode) as pyfid:

            bmode    = mode.encode()
            cmode    = bmode
            cfid     = fdopen(pyfid.fileno(), cmode)

            # If no_fds is set, we can't detect the mode, so reading is always allowed.
            expected = 1 if no_fds else mode == 'r'

            result = not zran.zran_init(&index, NULL if no_fds else cfid, <PyObject*>pyfid if no_fds else NULL, 0, 0, 0, 0)

            assert result == expected

            zran.zran_free(&index)

        if filename == 'dummy.gz' and op.exists(filename):
            os.remove(filename)


def test_no_auto_build(testfile, no_fds, nelems):

    cdef zran.zran_index_t index
    cdef void             *buffer

    filesize     = nelems * 8
    indexSpacing = max(1048576, filesize // 1500)
    bufSize      = 1048576
    buf          = ReadBuffer(bufSize)
    buffer       = buf.buffer

    with open(testfile, 'rb') as pyfid:
        cfid = fdopen(pyfid.fileno(), 'rb')

        assert not zran.zran_init(&index,
                                  NULL if no_fds else cfid,
                                  <PyObject*>pyfid if no_fds else NULL,
                                  indexSpacing,
                                  32768,
                                  131072,
                                  0)

        assert zran.zran_seek(&index, 0, SEEK_SET, NULL) == zran.ZRAN_SEEK_OK
        assert zran.zran_tell(&index) == 0
        assert zran.zran_seek(&index, 1, SEEK_SET, NULL) == zran.ZRAN_SEEK_NOT_COVERED
        assert zran.zran_tell(&index) == 0

        gotread = zran.zran_read(&index, buffer, bufSize)
        gottell = zran.zran_tell(&index)

        if bufSize > filesize: expread = filesize
        else:                  expread = bufSize

        if bufSize > filesize: exptell = filesize
        else:                  exptell = bufSize

        try:
            assert gotread == expread
            assert gottell == exptell
        except:
            print("expread: {}".format(expread))
            print("gotread: {}".format(gotread))
            print("exptell: {}".format(exptell))
            print("gottell: {}".format(gottell))
            raise

        pybuf = <bytes>(<char *>buffer)[:gotread]
        data  = np.ndarray(gotread // 8, np.uint64, pybuf)

        assert check_data_valid(data, 0)

        if bufSize < filesize:
            assert zran.zran_read(&index, buffer, bufSize) == zran.ZRAN_READ_NOT_COVERED


def test_seek_to_end(testfile, no_fds, nelems):

    cdef zran.zran_index_t index

    filesize = nelems * 8

    seek_point   = filesize - 1
    indexSpacing = max(524288, filesize // 1500)

    with open(testfile, 'rb') as pyfid:
        cfid = fdopen(pyfid.fileno(), 'rb')

        assert not zran.zran_init(&index,
                                  NULL if no_fds else cfid,
                                  <PyObject*>pyfid if no_fds else NULL,
                                  indexSpacing,
                                  32768,
                                  131072,
                                  zran.ZRAN_AUTO_BUILD)

        assert zran.zran_seek(&index, seek_point, SEEK_SET, NULL) == 0

        zt = zran.zran_tell(&index)

        assert zt == seek_point

        zran.zran_free(&index)


def test_seek_cur(testfile, no_fds, nelems):

    cdef zran.zran_index_t index

    filesize     = nelems * 8
    indexSpacing = max(524288, filesize // 1500)
    seekstep     = max(1, (nelems - 1) // 500)
    curelem      = 0;

    with open(testfile, 'rb') as pyfid:
        cfid = fdopen(pyfid.fileno(), 'rb')

        assert not zran.zran_init(&index,
                                  NULL if no_fds else cfid,
                                  <PyObject*>pyfid if no_fds else NULL,
                                  indexSpacing,
                                  32768,
                                  131072,
                                  zran.ZRAN_AUTO_BUILD)

        while curelem < nelems:

            if (curelem + seekstep) * 8 < filesize: exp = zran.ZRAN_SEEK_OK
            else:                                   exp = zran.ZRAN_SEEK_EOF


            out = zran.zran_seek(&index, seekstep * 8, SEEK_CUR, NULL)
            assert out == exp, out

            if exp == zran.ZRAN_SEEK_EOF:
                break

            curelem += seekstep
            zt = zran.zran_tell(&index)
            val = read_element(&index, curelem, nelems, False)

            assert zt  == curelem * 8
            assert val == curelem

            assert zran.zran_seek(&index, -8, SEEK_CUR, NULL) == zran.ZRAN_SEEK_OK

        zran.zran_free(&index)


def test_seek_end(testfile, no_fds, nelems):
    cdef zran.zran_index_t index

    filesize     = nelems * 8
    indexSpacing = max(131072, filesize // 1500)
    seekstep     = max(1, (nelems - 1) // 500)
    curelem      = 0

    with open(testfile, 'rb') as pyfid:
        cfid = fdopen(pyfid.fileno(), 'rb')

        assert not zran.zran_init(&index,
                                  NULL if no_fds else cfid,
                                  <PyObject*>pyfid if no_fds else NULL,
                                  indexSpacing,
                                  32768,
                                  131072,
                                  zran.ZRAN_AUTO_BUILD)

        assert zran.zran_seek(&index, -10, SEEK_END, NULL) == zran.ZRAN_SEEK_INDEX_NOT_BUILT
        assert zran.zran_seek(&index,  20, SEEK_SET, NULL) == zran.ZRAN_SEEK_OK
        assert zran.zran_tell(&index)                      == 20
        assert zran.zran_seek(&index, -10, SEEK_END, NULL) == zran.ZRAN_SEEK_INDEX_NOT_BUILT

        assert zran.zran_build_index(&index, 0, 0)         == 0

        assert zran.zran_seek(&index,  0, SEEK_END, NULL) == zran.ZRAN_SEEK_EOF
        assert zran.zran_tell(&index)                     == filesize
        assert zran.zran_seek(&index, -1, SEEK_END, NULL) == zran.ZRAN_SEEK_OK
        assert zran.zran_tell(&index)                     == filesize - 1

        assert zran.zran_seek(&index,  1,             SEEK_END, NULL) == zran.ZRAN_SEEK_EOF
        assert zran.zran_tell(&index)                                 == filesize
        assert zran.zran_seek(&index,  -filesize - 1, SEEK_END, NULL) == zran.ZRAN_SEEK_FAIL
        assert zran.zran_seek(&index,  -filesize,     SEEK_END, NULL) == zran.ZRAN_SEEK_OK
        assert zran.zran_tell(&index)                                 == 0

        while curelem < nelems:
            seekloc = filesize - ((nelems + curelem - 1) * 8)

            if seekloc >= 0: exp = zran.ZRAN_SEEK_EOF
            else:            exp = zran.ZRAN_SEEK_OK

            assert zran.zran_seek(&index, seekloc, SEEK_END, NULL) == exp

            if exp == zran.ZRAN_SEEK_EOF:
                break

            curelem += seekstep
            zt = zran.zran_tell(&index)
            val = read_element(&index, curelem, nelems, False)

            assert zt  == curelem * 8
            assert val == curelem

        zran.zran_free(&index)


def test_seek_beyond_end(testfile, no_fds, nelems):

    cdef zran.zran_index_t index

    filesize     = nelems * 8
    indexSpacing = max(524288, filesize // 1500)
    seekpoints   = [filesize - 10,
                    filesize - 2,
                    filesize - 1,
                    filesize,
                    filesize + 1,
                    filesize + 2,
                    filesize + 10]

    with open(testfile, 'rb') as pyfid:
        cfid = fdopen(pyfid.fileno(), 'rb')

        assert not zran.zran_init(&index,
                                  NULL if no_fds else cfid,
                                  <PyObject*>pyfid if no_fds else NULL,
                                  indexSpacing,
                                  32768,
                                  131072,
                                  zran.ZRAN_AUTO_BUILD)

        for sp in seekpoints:

            zs = zran.zran_seek(&index, sp, SEEK_SET, NULL)

            if sp >= filesize: expected = zran.ZRAN_SEEK_EOF
            else:              expected = zran.ZRAN_SEEK_OK

            try:
                assert zs == expected

            except:
                print("{} != {} [sp={}, size={}]".format(zs, expected, sp, filesize))
                raise

            zt = zran.zran_tell(&index)

            if sp >= filesize: expected = filesize
            else:              expected = sp

            try:
                assert zt == expected

            except:
                print("{} != {}".format(zt, expected))
                raise

        zran.zran_free(&index)


def test_sequential_seek_to_end(testfile, no_fds, nelems, niters):

    cdef zran.zran_index_t index

    filesize   = nelems * 8

    seek_points = np.random.randint(0, filesize, niters, dtype=np.uint64)
    seek_points = np.sort(seek_points)
    indexSpacing = max(524288, filesize // 2000)

    with open(testfile, 'rb') as pyfid:
        cfid = fdopen(pyfid.fileno(), 'rb')

        assert not zran.zran_init(&index,
                                  NULL if no_fds else cfid,
                                  <PyObject*>pyfid if no_fds else NULL,
                                  indexSpacing,
                                  32768,
                                  131072,
                                  zran.ZRAN_AUTO_BUILD)

        for sp in seek_points:

            if sp >= filesize:
                expseek = zran.ZRAN_SEEK_EOF
                exptell = filesize
            else:
                expseek = zran.ZRAN_SEEK_OK
                exptell = sp

            seek = zran.zran_seek(&index, sp, SEEK_SET, NULL)
            tell = zran.zran_tell(&index)

            try:
                assert seek == expseek
                assert tell == exptell
            except:
                print("expseek: {}".format(expseek))
                print("exptell: {}".format(exptell))
                print("seek:    {}".format(seek))
                print("tell:    {}".format(tell))
                raise


        zran.zran_free(&index)


def test_random_seek(testfile, no_fds, nelems, niters, seed):

    cdef zran.zran_index_t index

    filesize = nelems * 8

    seekpoints   = [random.randint(0, filesize) for i in range(niters)]
    indexSpacing = max(524288, filesize // 1000)

    with open(testfile, 'rb') as pyfid:
        cfid = fdopen(pyfid.fileno(), 'rb')

        assert not zran.zran_init(&index,
                                  NULL if no_fds else cfid,
                                  <PyObject*>pyfid if no_fds else NULL,
                                  indexSpacing,
                                  32768,
                                  131072,
                                  zran.ZRAN_AUTO_BUILD)

        for sp in seekpoints:

            assert zran.zran_seek(&index, sp, SEEK_SET, NULL) == 0

            zt = zran.zran_tell(&index)

            assert zt == sp

        zran.zran_free(&index)


def test_read_all(testfile, no_fds, nelems, use_mmap):

    filesize = nelems * 8
    indexSpacing = max(524288, filesize // 1000)

    cdef zran.zran_index_t index
    cdef void             *buffer
    cdef np.npy_intp       nelemsp

    buf    = ReadBuffer(filesize, use_mmap=use_mmap)
    buffer = buf.buffer

    with open(testfile, 'rb') as pyfid:
        cfid = fdopen(pyfid.fileno(), 'rb')

        assert not zran.zran_init(&index,
                                  NULL if no_fds else cfid,
                                  <PyObject*>pyfid if no_fds else NULL,
                                  indexSpacing,
                                  32768,
                                  131072,
                                  zran.ZRAN_AUTO_BUILD)

        nbytes = zran.zran_read(&index, buffer, filesize)

        assert nbytes                 == filesize
        assert zran.zran_tell(&index) == nbytes

        zran.zran_free(&index)

    nelemsp = nbytes / 8.
    data    = np.PyArray_SimpleNewFromData(1, &nelemsp,  np.NPY_UINT64, buffer)

    assert check_data_valid(data, 0)


def test_seek_then_read_block(testfile, no_fds, nelems, niters, seed, use_mmap):

    filesize  = nelems * 8

    indexSpacing = max(524288, filesize // 1000)
    buf          = ReadBuffer(filesize, use_mmap=use_mmap)
    seekelems    = np.random.randint(0, nelems - 1, niters, dtype=np.uint64)

    cdef zran.zran_index_t index
    cdef void             *buffer = buf.buffer
    cdef np.npy_intp       nelemsp

    with open(testfile, 'rb') as pyfid:
        cfid = fdopen(pyfid.fileno(), 'rb')

        ret = zran.zran_init(&index,
                             NULL if no_fds else cfid,
                             <PyObject*>pyfid if no_fds else NULL,
                             indexSpacing,
                             32768,
                             131072,
                             zran.ZRAN_AUTO_BUILD)
        assert not ret, ret

        for i, se in enumerate(seekelems):


            if se == nelems - 1:
                readelems = 1
            else:
                readelems = np.random.randint(1, nelems - se)

            start = time.time()

            print("{} / {}: reading {} elements from {} ... ".format(
                i, len(seekelems), readelems, se), end='')

            assert zran.zran_seek(&index, se * 8, SEEK_SET, NULL) == zran.ZRAN_SEEK_OK

            nbytes = zran.zran_read(&index, buffer, readelems * 8)

            try:
                assert nbytes                 == readelems * 8
                assert zran.zran_tell(&index) == (se + readelems) * 8
            except:
                print('seekelem:    {}'.format(se))
                print('readelems:   {}'.format(readelems))
                print('nbytes:      {}'.format(nbytes))
                print('  should be: {}'.format(readelems * 8))
                print('ftell:       {}'.format(zran.zran_tell(&index)))
                print('  should be: {}'.format((se + readelems) * 8))
                raise

            nelemsp = nbytes / 8.
            data    = np.PyArray_SimpleNewFromData(1, &nelemsp,  np.NPY_UINT64, buffer)

            assert check_data_valid(data, se, se + readelems)

            end = time.time()

            print("{:0.2f} seconds".format(end - start))

        zran.zran_free(&index)


def test_random_seek_and_read(testfile, no_fds, nelems, niters, seed):

    cdef zran.zran_index_t index

    filesize = nelems * 8

    seekelems    = np.random.randint(0, nelems, niters)
    indexSpacing = max(524288, filesize // 1000)

    with open(testfile, 'rb') as pyfid:
        cfid = fdopen(pyfid.fileno(), 'rb')

        assert not zran.zran_init(&index,
                                  NULL if no_fds else cfid,
                                  <PyObject*>pyfid if no_fds else NULL,
                                  indexSpacing,
                                  32768,
                                  131072,
                                  zran.ZRAN_AUTO_BUILD)

        for se in seekelems:

            # Should never happen
            if se >= nelems: expval = None
            else:            expval = se

            val = read_element(&index, se, nelems, True)

            try:
                assert val == expval
            except:
                print("{} != {}".format(val, se))
                raise

        zran.zran_free(&index)


def test_read_all_sequential(testfile, no_fds, nelems):

    cdef zran.zran_index_t index

    filesize = nelems * 8

    indexSpacing = max(524288, filesize // 1000)

    # Takes too long to read all elements
    seekelems = np.random.randint(0, nelems - 1, 10000, dtype=np.uint64)
    seekelems = np.sort(seekelems)

    with open(testfile, 'rb') as pyfid:
        cfid = fdopen(pyfid.fileno(), 'rb')

        assert not zran.zran_init(&index,
                                  NULL if no_fds else cfid,
                                  <PyObject*>pyfid if no_fds else NULL,
                                  indexSpacing,
                                  32768,
                                  131072,
                                  zran.ZRAN_AUTO_BUILD)

        for se in seekelems:

            val = read_element(&index, se, nelems, True)
            try:
                assert val == se
            except:
                print("{} != {}".format(val, se))
                print("{:x} != {:x}".format(val, se))
                raise

        zran.zran_free(&index)


def test_build_then_read(testfile, no_fds, nelems, seed, use_mmap):

    filesize = nelems * 8

    indexSpacing = max(524288, filesize // 1000)
    buf          = ReadBuffer(filesize, use_mmap)
    seekelems    = np.random.randint(0, nelems - 1, 5000, dtype=np.uint64)

    cdef zran.zran_index_t index
    cdef void             *buffer = buf.buffer

    with open(testfile, 'rb') as pyfid:
        cfid = fdopen(pyfid.fileno(), 'rb')

        assert not zran.zran_init(&index,
                                  NULL if no_fds else cfid,
                                  <PyObject*>pyfid if no_fds else NULL,
                                  indexSpacing,
                                  32768,
                                  131072,
                                  zran.ZRAN_AUTO_BUILD)

        assert not zran.zran_build_index(&index, 0, 0)

        for se in seekelems:

            assert zran.zran_seek(&index, se * 8, SEEK_SET, NULL) == 0

            if se == nelems - 1:
                readelems = 1
            else:
                readelems = np.random.randint(1, min(nelems - se, 5000))

            nbytes = zran.zran_read(&index, buffer, readelems * 8)

            assert nbytes                 == readelems * 8
            assert zran.zran_tell(&index) == (se + readelems) * 8

            pybuf = <bytes>(<char *>buffer)[:nbytes]
            data  = np.ndarray(nbytes // 8, np.uint64, pybuf)

            for i, val in enumerate(data, se):
                assert val == i

        zran.zran_free(&index)


def test_readbuf_spacing_sizes(testfile, no_fds, nelems, niters, seed):

    cdef zran.zran_index_t index

    spacings = [262144,  524288,  1048576,
                2097152, 4194304, 8388608]
    bufsizes = [16384,   65536,   131072,  262144,
                524288,  1048575, 1048576, 1048577,
                2097152, 4194304, 8388608]

    seekelems = np.random.randint(0, nelems, niters // 2)
    seekelems = np.concatenate((spacings, bufsizes, seekelems))

    for sbi, (spacing, bufsize) in enumerate(it.product(spacings, bufsizes)):

        with open(testfile, 'rb') as pyfid:

            print('{} / {}: spacing={}, bufsize={} ... '.format(
                sbi,
                len(spacings) * len(bufsizes),
                spacing, bufsize), end='')

            cfid = fdopen(pyfid.fileno(), 'rb')

            assert not zran.zran_init(&index,
                                      NULL if no_fds else cfid,
                                      <PyObject*>pyfid if no_fds else NULL,
                                      spacing,
                                      32768,
                                      bufsize,
                                      zran.ZRAN_AUTO_BUILD)

            for i, se in enumerate(seekelems):

                # print('{} / {}: {}'.format(i, len(seekelems), se))

                if se >= nelems: expval = None
                else:            expval = se

                val = read_element(&index, se, nelems, seek=True)

                try:
                    assert val == expval
                except:
                    print('{} != {}'.format(val, expval))
                    raise

            print()
            zran.zran_free(&index)


cdef _compare_indexes(zran.zran_index_t *index1,
                      zran.zran_index_t *index2):
    """Check that two indexes are equivalent. """
    cdef zran.zran_point_t *p1
    cdef zran.zran_point_t *p2

    assert index2.compressed_size   == index1.compressed_size
    assert index2.uncompressed_size == index1.uncompressed_size
    assert index2.spacing           == index1.spacing
    assert index2.window_size       == index1.window_size
    assert index2.npoints           == index1.npoints

    ws = index1.window_size

    for i in range(index1.npoints):

        p1 = &index1.list[i]
        p2 = &index2.list[i]
        msg = 'Error at point %d' % i

        assert p2.cmp_offset   == p1.cmp_offset, msg
        assert p2.uncmp_offset == p1.uncmp_offset, msg
        assert p2.bits         == p1.bits, msg
        if (not p1.data):
            assert p1.data == p2.data, msg
        else:
            assert not memcmp(p2.data, p1.data, ws), msg


def test_export_then_import(testfile, no_fds):
    """Export-import round trip . Test exporting an index, then importing it
    back in.
    """

    cdef zran.zran_index_t index1
    cdef zran.zran_index_t index2

    indexSpacing = 1048576
    windowSize   = 32768
    readbufSize  = 131072
    flag         = 0

    with open(testfile, 'rb') as pyfid:
        cfid = fdopen(pyfid.fileno(), 'rb')

        assert not zran.zran_init(&index1,
                                  NULL if no_fds else cfid,
                                  <PyObject*>pyfid if no_fds else NULL,
                                  indexSpacing,
                                  windowSize,
                                  readbufSize,
                                  flag)

        assert not zran.zran_build_index(&index1, 0, 0)

        with open(testfile + '.idx.tmp', 'wb') as pyexportfid:
            cfid = fdopen(pyexportfid.fileno(), 'ab')
            ret  = zran.zran_export_index(&index1, NULL if no_fds else cfid, <PyObject*>pyexportfid if no_fds else NULL)
            assert not ret, str(ret)

    with open(testfile, 'rb') as pyfid:
        cfid = fdopen(pyfid.fileno(), 'rb')
        assert not zran.zran_init(&index2,
                                  NULL if no_fds else cfid,
                                  <PyObject*>pyfid if no_fds else NULL,
                                  indexSpacing,
                                  windowSize,
                                  readbufSize,
                                  flag)

        with open(testfile + '.idx.tmp', 'rb') as pyexportfid:
            cfid = fdopen(pyexportfid.fileno(), 'rb')
            ret  = zran.zran_import_index(&index2, NULL if no_fds else cfid, <PyObject*>pyexportfid if no_fds else NULL)
            assert not ret, str(ret)

        _compare_indexes(&index1, &index2)

        zran.zran_free(&index1)
        zran.zran_free(&index2)


def test_export_import_no_points(no_fds):
    """Test exporting and importing an index which does not contain any
    seek points.
    """
    cdef zran.zran_index_t index
    cdef void             *buffer

    data   = np.random.randint(1, 255, 100, dtype=np.uint8)
    buf    = ReadBuffer(100)
    buffer = buf.buffer

    with tempdir():

        with gzip.open('data.gz', 'wb') as f:
            f.write(data.tostring())

        with open('data.gz', 'rb')  as pyfid:
            cfid = fdopen(pyfid.fileno(), 'rb')
            assert zran.zran_init(&index,
                                  NULL if no_fds else cfid,
                                  <PyObject*>pyfid if no_fds else NULL,
                                  1048576,
                                  32768,
                                  131072,
                                  0) == 0
            output = zran.zran_read(&index, buffer, 100)
            assert output  == 100, output

            pybuf = <bytes>(<char *>buffer)[:100]
            assert np.all(np.frombuffer(pybuf, dtype=np.uint8) == data)

            with open('data.gz.index', 'wb') as pyidxfid:
                cidxfid = fdopen(pyidxfid.fileno(), 'wb')
                assert zran.zran_export_index(&index, NULL if no_fds else cidxfid, <PyObject*>pyidxfid if no_fds else NULL) == 0
            zran.zran_free(&index)

        with open('data.gz', 'rb')  as pyfid:
            cfid = fdopen(pyfid.fileno(), 'rb')
            assert zran.zran_init(&index,
                                  NULL if no_fds else cfid,
                                  <PyObject*>pyfid if no_fds else NULL,
                                  1048576,
                                  32768,
                                  131072,
                                  0) == 0

            with open('data.gz.index', 'rb') as pyidxfid:
                cidxfid = fdopen(pyidxfid.fileno(), 'rb')
                assert zran.zran_import_index(&index, NULL if no_fds else cidxfid, <PyObject*>pyidxfid if no_fds else NULL) == 0
            assert index.npoints == 0

            assert zran.zran_read(&index, buffer, 100)  == 100
            pybuf = <bytes>(<char *>buffer)[:100]
            assert np.all(np.frombuffer(pybuf, dtype=np.uint8) == data)
            zran.zran_free(&index)


def test_export_import_format_v0():
    """Test index export and import on a version 0 index file. """

    cdef zran.zran_index_t index1
    cdef zran.zran_index_t index2
    cdef int               ret

    data = np.random.randint(1, 255, 1000000, dtype=np.uint8)
    with tempdir():

        with gzip.open('data.gz', 'wb') as f:
            f.write(data.tostring())

        with open('data.gz', 'rb')  as pyfid:
            cfid = fdopen(pyfid.fileno(), 'rb')
            assert not zran.zran_init(
                &index1, cfid, NULL, 50000, 32768, 131072, 0)

            assert not zran.zran_build_index(&index1, 0, 0)
            _write_index_file_v0(&index1, 'data.gz.index')

        with open('data.gz', 'rb')  as pyfid:
            cfid = fdopen(pyfid.fileno(), 'rb')
            assert not zran.zran_init(
                &index2, cfid, NULL, 50000, 32768, 131072, 0)

            with open('data.gz.index', 'rb') as pyidxfid:
                cidxfid = fdopen(pyidxfid.fileno(), 'rb')
                ret = zran.zran_import_index(&index2, cidxfid,  NULL)
                assert ret == 0, ret

        _compare_indexes(&index1, &index2)
        zran.zran_free(&index1)
        zran.zran_free(&index2)


cdef _write_index_file_v0(zran.zran_index_t *index, dest):
    """Write the given index out to a file, index file version 0 format. """

    cdef zran.zran_point_t *point

    with open(dest, 'wb') as f:
        f.write(b'GZIDX\0\0')
        f.write(<bytes>(<char *>(&index.compressed_size))[:8])
        f.write(<bytes>(<char *>(&index.uncompressed_size))[:8])
        f.write(<bytes>(<char *>(&index.spacing))[:4])
        f.write(<bytes>(<char *>(&index.window_size))[:4])
        f.write(<bytes>(<char *>(&index.npoints))[:4])

        for i in range(index.npoints):
            point = &index.list[i]
            f.write(<bytes>(<char *>(&point.cmp_offset))[:8])
            f.write(<bytes>(<char *>(&point.uncmp_offset))[:8])
            f.write(<bytes>(<char *>(&point.bits))[:1])

        for i in range(1, index.npoints):
            point = &index.list[i]
            data  = <bytes>point.data[:index.window_size]
            f.write(data)


def test_crc_validation(concat):
    """Basic test of CRC validation. """

    cdef zran.zran_index_t index
    cdef void             *buffer
    cdef int64_t           ret

    # use uint32 so there are lots of zeros,
    # and so there is something to compress
    dsize             = 1048576 * 10
    data              = np.random.randint(0, 255, dsize // 4, dtype=np.uint32)
    cmpdata, strmoffs = compress_inmem(data.tobytes(), concat)
    buf               = ReadBuffer(dsize)
    buffer            = buf.buffer
    f                 = [None]  # to prevent gc

    def _zran_init(flags):
        f[0] = BytesIO(cmpdata)
        assert not zran.zran_init(&index,
                                  NULL,
                                  <PyObject*>f[0],
                                  1048576,
                                  32768,
                                  131072,
                                  flags)

    def _run_crc_tests(shouldpass, flags=zran.ZRAN_AUTO_BUILD):
        if shouldpass:
            expect_build = zran.ZRAN_BUILD_INDEX_OK
            expect_seek  = zran.ZRAN_SEEK_OK
            expect_read  = dsize
        else:
            expect_build = zran.ZRAN_BUILD_INDEX_CRC_ERROR
            expect_seek  = zran.ZRAN_SEEK_CRC_ERROR
            expect_read  = zran.ZRAN_READ_CRC_ERROR

        # CRC validation should occur on the first
        # pass through a gzip stream, regardless
        # of how that pass is initiated. Below we
        # test the most common scenarios.

        # Error if we try to build an index.  Note
        # that an error here is not guaranteed, as
        # the _zran_expand_index might need a few
        # passes through the data to reach the end,
        # which might cause inflation to be
        # re-initialised, and therefore validation
        # to be disabled.  It depends on the data,
        # and on the constants used in
        # _zran_estimate_offset
        _zran_init(flags)
        ret = zran.zran_build_index(&index, 0, 0)
        assert ret == expect_build, ret
        zran.zran_free(&index)

        # error if we try to seek
        _zran_init(flags)
        ret = zran.zran_seek(&index, dsize - 1, SEEK_SET, NULL)
        assert ret == expect_seek, ret
        zran.zran_free(&index)

        # error if we try to read
        _zran_init(flags)
        ret = zran.zran_read(&index, buffer, dsize)
        assert ret == expect_read, ret
        zran.zran_free(&index)

        if shouldpass:
            pybuf = <bytes>(<char *>buffer)[:dsize]
            assert np.all(np.frombuffer(pybuf, dtype=np.uint32) == data)

    def wrap(val):
        return val % 255

    # data/crc is good, all should be well
    _run_crc_tests(True)

    # corrupt the size, we should get an error
    cmpdata[-1] = wrap(cmpdata[-1] + 1)  # corrupt size
    _run_crc_tests(False)

    # corrupt the crc, we should get an error
    cmpdata[-1] = wrap(cmpdata[-1] - 1)  # restore size to correct value
    cmpdata[-5] = wrap(cmpdata[-5] + 1)  # corrupt crc
    _run_crc_tests(False)

    # Corrupt a different stream, if we have more than one
    cmpdata[-5] = wrap(cmpdata[-5] - 1)  # restore crc to correct value
    if len(strmoffs) > 1:
        for off in strmoffs[1:]:
            cmpdata[off-1] = wrap(cmpdata[off-1] + 1)
            _run_crc_tests(False)
            cmpdata[off-1] = wrap(cmpdata[off-1] - 1)

    # Disable CRC, all should be well, even with a corrupt CRC/size
    # First test with good data
    _run_crc_tests(True, zran.ZRAN_AUTO_BUILD | zran.ZRAN_SKIP_CRC_CHECK)

    cmpdata[-1] = wrap(cmpdata[-1] + 1)  # corrupt size
    _run_crc_tests(True, zran.ZRAN_AUTO_BUILD | zran.ZRAN_SKIP_CRC_CHECK)

    cmpdata[-1] = wrap(cmpdata[-1] - 1)  # restore size to correct value
    cmpdata[-5] = wrap(cmpdata[-5] - 1)  # corrupt crc
    _run_crc_tests(True, zran.ZRAN_AUTO_BUILD | zran.ZRAN_SKIP_CRC_CHECK)


def test_standard_usage_with_null_padding(concat):
    """Make sure standard usage works with files that have null-padding after
    the GZIP footer.

    See https://www.gnu.org/software/gzip/manual/gzip.html#Tapes
    """
    cdef zran.zran_index_t index
    cdef void             *buffer
    cdef int64_t           ret

    # use uint32 so there are lots of zeros,
    # and so there is something to compress
    dsize             = 1048576 * 10
    data              = np.random.randint(0, 255, dsize // 4, dtype=np.uint32)
    cmpdata, strmoffs = compress_inmem(data.tobytes(), concat)
    buf               = ReadBuffer(dsize)
    buffer            = buf.buffer
    f                 = [None]  # to prevent gc

    # random amount of padding for each stream
    padding = np.random.randint(1, 100, len(strmoffs))

    # new compressed data - bytearrays
    # are initialised to contain all 0s
    paddedcmpdata = bytearray(len(cmpdata) + padding.sum())

    # copy old unpadded compressed data
    # into new padded compressed data
    padoff = 0  # offset into padded data
    last   = 0  # offset to end of last copied stream in unpadded data
    print('Padding streams [orig size: {}] ...'.format(len(cmpdata)))
    for off, pad in zip(strmoffs, padding):

        strm = cmpdata[last:off]

        paddedcmpdata[padoff:padoff + len(strm)] = strm

        print('  Copied stream from [{} - {}] to [{} - {}] ({} '
              'padding bytes)'.format(
                  last, off, padoff, padoff + len(strm), pad))

        padoff += len(strm) + pad
        last    = off


    def _zran_init():
        f[0] = BytesIO(paddedcmpdata)
        assert not zran.zran_init(&index,
                                  NULL,
                                  <PyObject*>f[0],
                                  1048576,
                                  32768,
                                  131072,
                                  zran.ZRAN_AUTO_BUILD)

    _zran_init()
    ret = zran.zran_build_index(&index, 0, 0)
    assert ret == zran.ZRAN_BUILD_INDEX_OK, ret
    zran.zran_free(&index)

    _zran_init()
    ret = zran.zran_seek(&index, dsize - 1, SEEK_SET, NULL)
    assert ret == zran.ZRAN_SEEK_OK, ret
    zran.zran_free(&index)

    _zran_init()
    ret = zran.zran_read(&index, buffer, dsize)
    assert ret == dsize, ret
    zran.zran_free(&index)

    pybuf = <bytes>(<char *>buffer)[:dsize]
    assert np.all(np.frombuffer(pybuf, dtype=np.uint32) == data)


# pauldmccarthy/indexed_gzip#82
def test_inflateInit_leak_on_error():
    """Make sure memory is not leaked after a successful call to
    inflateInit2(), but then a failure on subsequent zlib calls.
    """

    cdef zran.zran_index_t index

    # inflateInit2 is called twice in the _zran_zlib_init_inflate function.
    # We can target the first call by passing a file containing random noise.
    # I haven't yet figured out a reliable way to target the second call.
    f = BytesIO(np.arange(1, 100).tobytes())

    iters = np.arange(1, 10000)
    mem   = np.zeros(10000, dtype=np.uint64)

    for i in iters:
        assert not zran.zran_init(&index,
                                  NULL,
                                  <PyObject*>f,
                                  1048576,
                                  32768,
                                  131072,
                                  zran.ZRAN_AUTO_BUILD)
        assert zran.zran_seek(&index, 20, SEEK_SET, NULL) == \
            zran.ZRAN_SEEK_FAIL
        zran.zran_free(&index)

        if resource is not None:
            mem[i] = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss

    # We expect to see some small growth in memory
    # usage for the first few iterations, but then
    # it should remain stable
    mem = mem[5:]
    assert np.all(mem == mem[0])


# pauldmccarthy/indexed_gzip#80
def test_read_eof_memmove_rotate_bug(seed):

    # This bug was triggered by the read buffer rotation
    # that takes place in zran.c::_zran_read_data_from_file,
    # and occurs when the file is at EOF, and the
    # stream->next_in pointer is ahead of index->readbuf by
    # less than stream->avail_in bytes. In this case, the
    # source and dest pointers passed to memmove are
    # overlapping, so the area pointed to by next_in is
    # modified. The bug was that, when at EOF, the
    # stream->next_in pointer was not being reset to point
    # to the beginning of readbuf, so the subsequent read
    # of the gzip footer in _zran_validate_stream was
    # reading from the wrong location.
    #
    # We can trigger this situation by generating a file
    # which has compressed file size (X * readbuf_size) + Y,
    # for any integer x, and for 9 <= Y < 16

    cdef zran.zran_index_t index
    cdef FILE             *cfid

    with tempdir():
        nelems = np.random.randint(524288, 525000, 1)[0]
        data   = np.random.random(nelems)
        with gzip.open('test.gz', 'wb') as f:
            f.write(data.tobytes())

        fsize        = os.stat('test.gz').st_size
        readbuf_size = fsize - 10

        with open('test.gz', 'rb') as pyfid:
            cfid = fdopen(pyfid.fileno(), 'rb')
            assert not zran.zran_init(&index,
                                      cfid,
                                      NULL,
                                      4194304,
                                      32768,
                                      readbuf_size,
                                      zran.ZRAN_AUTO_BUILD)

            eof = nelems * 8 - 1
            got = zran.zran_seek(&index, eof, SEEK_SET, NULL)

            assert got                    == zran.ZRAN_SEEK_OK, got
            assert zran.zran_tell(&index) == eof
