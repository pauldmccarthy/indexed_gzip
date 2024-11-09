# cython: binding=True,embedsignature=True
#
# The IndexedGzipFile class.
#

"""This module provides the :class:`IndexedGzipFile` class, a drop-in
replacement for the built-in ``gzip.GzipFile`` class, for faster read-only
random access to gzip files.
"""


from libc.stdio     cimport (SEEK_SET,
                             SEEK_CUR,
                             SEEK_END,
                             FILE,
                             fopen,
                             fdopen,
                             fclose)

from libc.stdint    cimport (uint8_t,
                             uint32_t,
                             uint64_t,
                             int64_t)

from cpython.mem    cimport (PyMem_Malloc,
                             PyMem_Realloc,
                             PyMem_Free)

from cpython.buffer cimport (PyObject_GetBuffer,
                             PyBuffer_Release,
                             PyBUF_ANY_CONTIGUOUS,
                             PyBUF_SIMPLE)

from cpython.ref cimport PyObject, Py_XDECREF
from cpython.exc cimport PyErr_Occurred, PyErr_Fetch, PyErr_NormalizeException

cimport indexed_gzip.zran as zran

import            io
import            os
import os.path as op
import            pickle
import            logging
import            warnings
import            threading
import            contextlib


builtin_open = open
"""Reference to the built-in open function, which is otherwise masked by
our open function below.

When support for Python 2.7 is dropped, the ``builtins`` module can be used
instead.
"""


log = logging.getLogger(__name__)


def open(filename=None, fileobj=None, *args, **kwargs):
    """Create and return an ``IndexedGzipFile``.

    :arg filename: File name or open file handle.
    :arg fileobj:  Open file handle.

    See the ``IndexedGzipFile`` class for details on the other arguments.
    """
    return IndexedGzipFile(filename, fileobj, **kwargs)


cdef _get_python_exception():
    cdef PyObject *ptype
    cdef PyObject *pvalue
    cdef PyObject *ptraceback
    if PyErr_Occurred():
        PyErr_Fetch(&ptype, &pvalue, &ptraceback)
        PyErr_NormalizeException(&ptype, &pvalue, &ptraceback)
        exc = <object>pvalue
        Py_XDECREF(ptype)
        Py_XDECREF(pvalue)
        Py_XDECREF(ptraceback)
        return exc
    return None


class IndexedGzipFile(io.BufferedReader):
    """The ``IndexedGzipFile`` class allows for fast random access of a gzip
    file by using the ``zran`` library to build and maintain an index of seek
    points into the file.

    ``IndexedGzipFile`` is an ``io.BufferedReader`` which wraps an
    :class:`_IndexedGzipFile` instance. By accessing the ``_IndexedGzipFile``
    instance through an ``io.BufferedReader``, read performance is improved
    through buffering, and access to the I/O methods is made thread-safe.

    A :meth:`pread` method is also implemented, as it is not implemented by
    the ``io.BufferedReader``.
    """


    def __init__(self, *args, **kwargs):
        """Create an ``IndexedGzipFile``. The file may be specified either
        with an open file handle (``fileobj``), or with a ``filename``. If the
        former, the file must have been opened in ``'rb'`` mode.

        .. note:: The ``auto_build`` behaviour only takes place on calls to
                  :meth:`seek`.

        :arg filename:         File name or open file handle.

        :arg fileobj:          Open file handle.

        :arg mode:             Opening mode. Must be either ``'r'`` or ``'rb``.

        :arg auto_build:       If ``True`` (the default), the index is
                               automatically built on calls to :meth:`seek`.

        :arg skip_crc_check:   Defaults to ``False``. If ``True``, CRC/size
                               validation of the uncompressed data is not
                               performed.

        :arg spacing:          Number of bytes between index seek points.

        :arg window_size:      Number of bytes of uncompressed data stored with
                               each seek point.

        :arg readbuf_size:     Size of buffer in bytes for storing compressed
                               data read in from the file.

        :arg readall_buf_size: Size of buffer in bytes used by :meth:`read`
                               when reading until EOF.

        :arg drop_handles:     Has no effect if an open ``fid`` is specified,
                               rather than a ``filename``.  If ``True`` (the
                               default), a handle to the file is opened and
                               closed on every access. Otherwise the file is
                               opened at ``__cinit__``, and kept open until
                               this ``_IndexedGzipFile`` is destroyed.

        :arg index_file:       Pre-generated index for this ``gz`` file -
                               if provided, passed through to
                               :meth:`import_index`.

        :arg buffer_size:      Optional, must be passed as a keyword argument.
                               Passed through to
                               ``io.BufferedReader.__init__``. If not provided,
                               a default value of 4 * spacing is used if spacing
                               is given else 4 MiB is used.
        """

        # Use 4x spacing because each raw read seeks from the last index point
        # even if the position did not change since the last read call. On
        # average, this incurs an overhead of spacing / 2. For 4x spacing, this
        # overhead would be 1/8 = 12.5%, which should be negligible. The
        # increased memory-usage is not an issue because internally many buffers
        # are also allocated with 4 * spacing size.
        # Note that setting the buffer_size too high might incur performance
        # penalties for usecases with a lot of seeks and only small reads.
        spacing = kwargs['spacing'] if ('spacing' in kwargs
                  and kwargs['spacing'] > 0) else 1024 * 1024
        buffer_size = kwargs.pop('buffer_size', max(4096, 4 * spacing))

        fobj               = _IndexedGzipFile(*args, **kwargs)
        self.__file_lock   = threading.RLock()
        self.__igz_fobj    = fobj
        self.__buffer_size = buffer_size

        self.build_full_index = fobj.build_full_index
        self.import_index     = fobj.import_index
        self.export_index     = fobj.export_index
        self.fileobj          = fobj.fileobj
        self.drop_handles     = fobj.drop_handles
        self.seek_points      = fobj.seek_points

        super(IndexedGzipFile, self).__init__(fobj, buffer_size)


    def pread(self, nbytes, offset):
        """Seeks to ``offset``, then reads and returns up to ``nbytes``.
        The calls to seek and read are protected by a ``threading.RLock``.
        """
        with self.__file_lock:
            self.seek(offset)
            return self.read(nbytes)


    def __reduce_ex__(self, protocol):
        """Used to pickle an ``IndexedGzipFile``.

        :arg protocol:         Pickle protocol version

        Returns a tuple containing:
          - a reference to the ``unpickle`` function
          - a tuple containing a "state" object, which can be passed
            to ``unpickle``.
        """

        fobj = self.__igz_fobj

        if (not fobj.drop_handles) or (not fobj.own_file):
            raise pickle.PicklingError(
                'Cannot pickle IndexedGzipFile that has been created '
                'with an open file object, or that has been created '
                'with drop_handles=False')

        # export and serialise the index if
        # any index points have been created.
        # The index data is serialised as a
        # bytes object.
        if fobj.npoints == 0:
            index = None

        else:
            index = io.BytesIO()
            self.export_index(fileobj=index)
            index = index.getvalue()

        state = {
            'filename'         : fobj.filename,
            'auto_build'       : fobj.auto_build,
            'spacing'          : fobj.spacing,
            'window_size'      : fobj.window_size,
            'readbuf_size'     : fobj.readbuf_size,
            'readall_buf_size' : fobj.readall_buf_size,
            'buffer_size'      : self.__buffer_size,
            'tell'             : self.tell(),
            'index'            : index}

        return (unpickle, (state, ))


cdef class _IndexedGzipFile:
    """The ``_IndexedGzipFile`` class allows for fast random access of a gzip
    file by using the ``zran`` library to build and maintain an index of seek
    points into the file.

    .. note:: The :meth:`seek` and :meth:`read` methods release the GIL while
              calling ``zran`` functions, but the ``_IndexedGzipFile`` is *not*
              thread-safe. Use the ``IndexedGzipFile`` class (i.e. without the
              leading underscore) if you need thread-safety.
    """


    cdef zran.zran_index_t index
    """A reference to the ``zran_index`` struct. """


    cdef readonly uint32_t spacing
    """Number of bytes between index seek points. """


    cdef readonly uint32_t window_size
    """Number of bytes of uncompressed data stored with each seek point."""


    cdef readonly uint32_t readbuf_size
    """Size of buffer in bytes for storing compressed data read in from the
    file.
    """


    cdef readonly unsigned int readall_buf_size
    """Size of buffer in bytes used by :meth:`read` when reading until EOF.
    """


    cdef readonly bint auto_build
    """Flag which is set to ``True`` if the file index is built automatically
    on seeks/reads.
    """


    cdef readonly bint skip_crc_check
    """Flag which is set to ``True`` if CRC/size validation of uncompressed
    data is disabled.
    """


    cdef readonly object filename
    """String containing path of file being indexed. Used to release and
    reopen file handles between seeks and reads.
    Set to ``None`` if file handle is passed.
    """


    cdef readonly bint own_file
    """Flag which tracks whether this ``_IndexedGzipFile`` has opened its
    own file handle, or was given one.
    """


    cdef readonly bint drop_handles
    """Copy of the ``drop_handles`` flag as passed to :meth:`__cinit__`. """


    cdef object pyfid
    """A reference to the python file handle. """


    cdef bint finalized
    """Flag which is set to ``True`` if the ``_IndexedGzipFile`` has been
    closed. Further operations will fail if ``True``.
    """


    def __init__(self,
                 filename=None,
                 fileobj=None,
                 mode=None,
                 auto_build=True,
                 spacing=4194304,
                 window_size=32768,
                 readbuf_size=1048576,
                 readall_buf_size=16777216,
                 drop_handles=True,
                 index_file=None,
                 skip_crc_check=False):
        """Create an ``_IndexedGzipFile``. The file may be specified either
        with an open file handle (``fileobj``), or with a ``filename``. If the
        former, the file is assumed have been opened for reading in binary
        mode.

        .. note:: The ``auto_build`` behaviour only takes place on calls to
                  :meth:`seek`.

        :arg filename:         File name or open file handle.

        :arg fileobj:          Open file handle.

        :arg mode:             Opening mode. Must be either ``'r'`` or ``'rb``.

        :arg auto_build:       If ``True`` (the default), the index is
                               automatically built on calls to :meth:`seek`.

        :arg skip_crc_check:   Defaults to ``False``. If ``True``, CRC/size
                               validation of the uncompressed data is not
                               performed. Automatically enabled if an
                               ``index_file`` is provided, or if
                               :meth:`import_index` is called.

        :arg spacing:          Number of bytes between index seek points.

        :arg window_size:      Number of bytes of uncompressed data stored with
                               each seek point.

        :arg readbuf_size:     Size of buffer in bytes for storing compressed
                               data read in from the file.

        :arg readall_buf_size: Size of buffer in bytes used by :meth:`read`
                               when reading until EOF.

        :arg drop_handles:     Has no effect if an open ``fid`` is specified,
                               rather than a ``filename``.  If ``True`` (the
                               default), a handle to the file is opened and
                               closed on every access. Otherwise the file is
                               opened at ``__cinit__``, and kept open until
                               this ``_IndexedGzipFile`` is destroyed.

        :arg index_file:       Pre-generated index for this ``gz`` file -
                               if provided, passed through to
                               :meth:`import_index`.
        """

        cdef FILE *fd = NULL

        if (fileobj is     None and filename is     None) or \
           (fileobj is not None and filename is not None):
            raise ValueError('One of fileobj or filename must be specified')

        # filename can be either a
        # name or a file object
        if  hasattr(filename, 'read'):
            fileobj  = filename
            filename = None

        if fileobj is not None and \
           getattr(fileobj, 'mode', 'rb') not in (None, 'r', 'rb'):
            raise ValueError('Invalid mode - fileobj must be opened '
                             'in read-only binary ("rb") mode')

        if (fileobj is None) and (mode not in (None, 'r', 'rb')):
            raise ValueError('Invalid mode ({}), must be '
                             '"r" or "rb"'.format(mode))

        # If __file_handle is called on a file
        # that doesn't exist, it passes the
        # path directly to fopen, which causes
        # a segmentation fault on linux. So
        # let's check before that happens.
        if (filename is not None) and (not op.isfile(filename)):
            raise DoesNotExistError('File {} does not exist'.format(filename))

        mode     = 'rb'
        own_file = fileobj is None

        # if file is specified with an open
        # file handle, drop_handles is ignored
        if fileobj is not None:
            drop_handles = False

        # if not drop_handles, we open a
        # file handle and keep it open for
        # the lifetime of this object.
        if not drop_handles:
            if fileobj is None:
                fileobj = builtin_open(filename, mode)
            # Try to get a reference to the
            # underlying file descriptor
            try:
                fd  = fdopen(fileobj.fileno(), 'rb')
            # If we can't get the file descriptor, fall
            # back to using the python file-like
            except Exception as e:
                log.debug('Cannot get file descriptor (%s), using file-like', e)
                fd  = NULL

        self.spacing          = spacing
        self.window_size      = window_size
        self.readbuf_size     = readbuf_size
        self.readall_buf_size = readall_buf_size
        self.auto_build       = auto_build
        self.skip_crc_check   = skip_crc_check
        self.drop_handles     = drop_handles
        self.filename         = filename
        self.own_file         = own_file
        self.pyfid            = fileobj

        flags = 0

        if auto_build:     flags |= zran.ZRAN_AUTO_BUILD
        if skip_crc_check: flags |= zran.ZRAN_SKIP_CRC_CHECK

        # Set index.fd here just for the initial
        # call, as __file_handle may otherwise
        # manipulate it incorrectly
        self.index.fd = fd
        with self.__file_handle():
            if zran.zran_init(index=&self.index,
                              fd=self.index.fd,
                              f=<PyObject*>fileobj,
                              spacing=spacing,
                              window_size=window_size,
                              readbuf_size=readbuf_size,
                              flags=flags):
                raise ZranError('zran_init returned error (file: '
                                '{})'.format(self.errname))

        log.debug('%s.__init__(%s, %s, %s, %s, %s, %s, %s)',
                  type(self).__name__,
                  fileobj,
                  filename,
                  auto_build,
                  spacing,
                  window_size,
                  readbuf_size,
                  drop_handles)

        if index_file is not None:
            self.import_index(index_file)


    def __file_handle(self):
        """This method is used as a context manager whenever access to the
        underlying file stream is required. It makes sure that ``index.fd``
        field is set appropriately, opening/closing the file handle as
        necessary (depending on the value of :attr:`drop_handles`).
        """

        # Errors occur with Python 2.7 and
        # Cython < 0.26 when decorating
        # cdef-class methods. This workaround
        # can be removed when you are happy
        # dropping support for cython < 0.26.
        @contextlib.contextmanager
        def proxy():

            # If a file handle already exists,
            # return it. This clause makes this
            # context manager reentrant.
            if self.index.fd is not NULL:
                yield

            # If a file-like object exists (without an associated
            # file descriptor, since self.index.fd is NULL),
            # also return it.
            elif self.pyfid is not None:
                yield

            # otherwise we open a new
            # file handle on each access
            else:
                try:
                    self.index.fd = fopen(self.filename.encode(), 'rb')
                    yield

                finally:
                    fclose(self.index.fd)
                    self.index.fd = NULL

        return proxy()


    def seek_points(self):
        """Return the seek point locations that currently exist in the index.

        Yields a sequence of tuples, with each tuple containing the
        uncompressed and compressed offsets for one seek point in the index.
        """
        for i in range(self.index.npoints):
            point = self.index.list[i]
            yield (point.uncmp_offset, point.cmp_offset)


    def fileno(self):
        """Calls ``fileno`` on the underlying file object. Raises a
        :exc:`NoHandleError` if ``drop_handles is True``.
        """
        if self.drop_handles:
            raise NoHandleError()
        return self.pyfid.fileno()


    def fileobj(self):
        """Returns a reference to the python file object. Raises a
        :exc:`NoHandleError` if ``drop_handles is True``.
        """
        if self.drop_handles:
            raise NoHandleError()
        return self.pyfid


    @property
    def errname(self):
        """Used in exception messages. Returns the file name associated with
        this ``_IndexedGzipFile``, or ``'n/a'`` if a file name cannot be
        identified.
        """
        if self.filename is not None:
            return self.filename
        if self.pyfid is not None:
            if getattr(self.pyfid, 'name', None) is not None:
                return self.pyfid.name
        return 'n/a'


    @property
    def npoints(self):
        """Returns the number of index points that have been created. """
        return self.index.npoints


    @property
    def mode(self):
        """Returns the mode that this file was opened in. Currently always
        returns ``'rb'``.
        """
        return 'rb'


    def close(self):
        """Closes this ``_IndexedGzipFile``. """

        if self.closed:
            raise IOError('_IndexedGzipFile is already closed '
                          '(file: {})'.format(self.errname))

        if   self.own_file and self.pyfid    is not None: self.pyfid.close()
        elif self.own_file and self.index.fd is not NULL: fclose(self.index.fd)

        zran.zran_free(&self.index)

        self.index.f   = NULL
        self.index.fd  = NULL
        self.filename  = None
        self.pyfid     = None
        self.finalized = True

        if log is not None:
            log.debug('%s.close()', type(self).__name__)


    @property
    def closed(self):
        """Returns ``True`` if this ``_IndexedGzipFile`` is closed, ``False``
        otherwise.
        """
        return self.finalized


    def readable(self):
        """Returns ``True`` if this ``_IndexedGzipFile`` is readable, ``False``
        otherwise.
        """
        return not self.closed


    def writable(self):
        """Currently always returns ``False`` - the ``_IndexedGzipFile`` does
        not support writing yet.
        """
        return False


    def seekable(self):
        """Returns ``True`` if this ``_IndexedGzipFile`` supports seeking,
        ``False`` otherwise.
        """
        return not self.closed


    def tell(self):
        """Returns the current seek offset into the uncompressed data stream.
        """
        return zran.zran_tell(&self.index)


    def __enter__(self):
        """Returns this ``_IndexedGzipFile``. """
        return self


    def __exit__(self, *args):
        """Calls close on this ``_IndexedGzipFile``. """
        if not self.closed:
            self.close()


    def __dealloc__(self):
        """Frees the memory used by this ``_IndexedGzipFile``. If a file name
        was passed to :meth:`__cinit__`, the file handle is closed.
        """
        if not self.closed:
            self.close()


    def build_full_index(self):
        """Re-builds the full file index. """

        with self.__file_handle():
            ret = zran.zran_build_index(&self.index, 0, 0)

        if ret != zran.ZRAN_BUILD_INDEX_OK:
            raise ZranError('zran_build_index returned error: {} (file: {})'
                            .format(ZRAN_ERRORS.ZRAN_BUILD[ret], self.errname))

        log.debug('%s.build_full_index()', type(self).__name__)


    def seek(self, offset, whence=SEEK_SET):
        """Seeks to the specified position in the uncompressed data stream.

        If this ``_IndexedGzipFile`` was created with ``auto_build=False``,
        and the requested offset is not covered by the index, a
        :exc:`NotCoveredError` is raised.

        :arg offset: Desired seek offset into the uncompressed data

        :arg whence: Either  ``SEEK_SET``, ``SEEK_CUR``, or ``SEEK_END``. If
                     not one of these, a :exc:`ValueError` is raised.

        :returns:    The final seek location into the uncompressed stream.

        .. note:: This method releases the GIL while ``zran_seek`` is
                  running.
        """

        cdef int                ret
        cdef int64_t            off      = offset
        cdef uint8_t            c_whence = whence
        cdef zran.zran_index_t *index    = &self.index

        if whence not in (SEEK_SET, SEEK_CUR, SEEK_END):
            raise ValueError('Invalid value for whence: {}'.format(whence))

        with self.__file_handle(), nogil:
            ret = zran.zran_seek(index, off, c_whence, NULL)

        if ret == zran.ZRAN_SEEK_NOT_COVERED:
            raise NotCoveredError('Index does not cover '
                                  'offset {}'.format(offset))

        elif ret == zran.ZRAN_SEEK_INDEX_NOT_BUILT:
            raise NotCoveredError('Index must be completely built '
                                  'in order to seek from SEEK_END')

        elif ret == zran.ZRAN_SEEK_CRC_ERROR:
            raise CrcError('CRC/size validation failed - the '
                           'GZIP data might be corrupt (file: '
                           '{})'.format(self.errname))

        elif ret not in (zran.ZRAN_SEEK_OK, zran.ZRAN_SEEK_EOF):
            raise ZranError('zran_seek returned error: {} (file: {})'
                            .format(ZRAN_ERRORS.ZRAN_SEEK[ret], self.errname))

        offset = self.tell()

        log.debug('%s.seek(%s)', type(self).__name__, offset)

        return offset


    def read(self, nbytes=-1):
        """Reads up to ``nbytes`` bytes from the uncompressed data stream.
        If ``nbytes < 0`` the stream is read until EOF.

        If the stream is already at EOF, ``b''`` is returned.

        .. note:: This method releases the GIL while ``zran_read`` is
                  running.
        """

        if   nbytes == 0: return bytes()
        elif nbytes <  0: buf = ReadBuffer(self.readall_buf_size)
        else:             buf = ReadBuffer(nbytes)

        cdef zran.zran_index_t *index  = &self.index
        cdef size_t             nread  = 0
        cdef uint64_t           bufsz  = buf.size
        cdef size_t             offset = 0
        cdef void              *buffer
        cdef int64_t            ret

        with self.__file_handle():

            # Read until EOF or enough
            # bytes have been read
            while True:

                # read some bytes into the correct
                # buffer location
                buffer = <char *>buf.buffer + offset

                with nogil:
                    ret = zran.zran_read(index, buffer, bufsz)

                # No bytes were read, and there are
                # no more bytes to read. This will
                # happen when the seek point was at
                # or beyond EOF when zran_read was
                # called
                if ret == zran.ZRAN_READ_EOF:
                    break

                # This will happen if the current
                # seek point is not covered by the
                # index, and auto-build is disabled
                elif ret == zran.ZRAN_READ_NOT_COVERED:
                    raise NotCoveredError('Index does not cover '
                                          'current offset')

                # CRC or size check failed - data
                # might be corrupt
                elif ret == zran.ZRAN_READ_CRC_ERROR:
                    raise CrcError('CRC/size validation failed - the '
                                   'GZIP data might be corrupt (file: '
                                   '{})'.format(self.errname))


                # Unknown error
                elif ret < 0:
                    exc = _get_python_exception()
                    raise ZranError('zran_read returned error: {} (file: '
                                    '{})'.format(ZRAN_ERRORS.ZRAN_READ[ret],
                                                 self.errname)) from exc

                nread  += ret
                offset += ret

                # If we requested a specific number of
                # bytes, zran_read will have returned
                # them all (or all until EOF), so we're
                # finished
                if nbytes > 0:
                    break

                # Otherwise if reading until EOF, check
                # and increase the buffer size if necessary
                if (nread + self.readall_buf_size) > buf.size:
                    buf.resize(buf.size + self.readall_buf_size)
                    offset = nread

        buf.resize(nread)
        pybuf = <bytes>(<char *>buf.buffer)[:nread]

        log.debug('%s.read(%s)', type(self).__name__, len(pybuf))

        return pybuf


    def readinto(self, buf):
        """Reads up to ``len(buf)`` bytes directly into ``buf``, which is
        assumed to be a mutable ``bytes``-like object (e.g. a ``memoryview``
        or ``bytearray``.
        """

        cdef zran.zran_index_t *index  = &self.index
        cdef uint64_t           bufsz  = len(buf)
        cdef Py_buffer          pbuf
        cdef void              *vbuf
        cdef int64_t            ret

        # Create a Py_Buffer which allows
        # us to access the memory managed
        # by the provided buf
        PyObject_GetBuffer(buf, &pbuf, PyBUF_SIMPLE | PyBUF_ANY_CONTIGUOUS)

        # read some bytes
        try:

            vbuf = <void *>pbuf.buf
            with self.__file_handle(), nogil:
                ret = zran.zran_read(index, vbuf, bufsz)

        # release the py_buffer
        finally:
            PyBuffer_Release(&pbuf)

        # see how the read went
        if ret == zran.ZRAN_READ_FAIL:
            exc = _get_python_exception()
            raise ZranError('zran_read returned error: {} (file: {})'
                            .format(ZRAN_ERRORS.ZRAN_READ[ret], self.errname)) from exc

        # This will happen if the current
        # seek point is not covered by the
        # index, and auto-build is disabled
        elif ret == zran.ZRAN_READ_NOT_COVERED:
            raise NotCoveredError('Index does not cover current offset')

        # No bytes were read, and there are
        # no more bytes to read. This will
        # happen when the seek point was at
        # or beyond EOF when zran_read was
        # called
        elif ret == zran.ZRAN_READ_EOF:
            return 0

        # Return the number of bytes that
        # were read
        else:
            return ret


    def pread(self, nbytes, offset):
        """Seeks to the specified ``offset``, then reads and returns
        ``nbytes``. See :meth:`seek` and :meth:`read`.
        """
        with self.__file_handle():
            self.seek(offset)
            return self.read(nbytes)


    def readline(self, size=-1):
        """Read and return up to the next ``'\n'`` character (up to at most
        ``size`` bytes, if ``size >= 0``) from the uncompressed data stream.

        If the end of the stream has been reached, ``b''`` is returned.
        """

        if size == 0:
            return bytes()

        linebuf  = b''
        startpos = self.tell()
        bufsz    = 1024

        # Read in chunks of [bufsz] bytes at a time
        with self.__file_handle():
            while True:

                buf = self.read(bufsz)

                lineidx  = buf.find(b'\n')
                haveline = lineidx  >= 0
                eof      = len(buf) == 0

                # Are we at EOF? Nothing more to do
                if eof:
                    break

                # Have we found a line? Discard
                # everything that comes after it
                if haveline:
                    linebuf = linebuf + buf[:lineidx + 1]

                # If we've found a line, and are
                # not size-limiting, we're done
                if haveline and size < 0:
                    break

                # If we're size limiting, and have
                # read in enough bytes, we're done
                if size >= 0 and len(linebuf) > size:
                    linebuf = linebuf[:size]
                    break

            # Rewind the seek location
            # to the finishing point
            self.seek(startpos + len(linebuf))

        return linebuf


    def readlines(self, hint=-1):
        """Reads and returns a list of lines from the uncompressed data.
        If ``hint`` is provided, lines will be read until the total size
        of all lines exceeds ``hint`` in bytes.
        """

        totalsize = 0
        lines     = []

        with self.__file_handle():
            while True:

                line = self.readline()
                if line == b'':
                    break

                lines.append(line)

                totalsize += len(line)

                if hint >= 0 and totalsize > hint:
                    break

        return lines


    def __iter__(self):
        """Returns this ``_IndexedGzipFile`` which can be iterated over to
        return lines (separated by ``'\n'``) in the uncompressed stream.
        """
        return self


    def __next__(self):
        """Returns the next line from the uncompressed stream. Raises
        :exc:`StopIteration` when there are no lines left.
        """
        line = self.readline()

        if line == b'':
            raise StopIteration()
        else:
            return line


    def write(self, *args, **kwargs):
        """Currently raises a :exc:`NotImplementedError`."""
        raise NotImplementedError('_IndexedGzipFile does not support writing')


    def flush(self):
        """Currently does nothing. """
        pass


    def export_index(self, filename=None, fileobj=None):
        """Export index data to the given file. Either ``filename`` or
        ``fileobj`` should be specified, but not both. ``fileobj`` should be
        opened in 'wb' mode.

        :arg filename: Name of the file.
        :arg fileobj:  Open file handle.
        """

        if filename is None and fileobj is None:
            raise ValueError('One of filename or fileobj must be specified')

        if filename is not None and fileobj is not None:
            raise ValueError(
                'Only one of filename or fileobj must be specified')

        if filename is not None:
            fileobj    = builtin_open(filename, 'wb')
            close_file = True

        else:
            close_file = False
            if getattr(fileobj, 'mode', 'wb') != 'wb':
                raise ValueError(
                    'File should be opened in writeable binary mode.')

        try:
            # Pass both the Python file object and
            # file descriptor (if this is an actual
            # file) to the zran_export_index function
            try:
                fd = fdopen(fileobj.fileno(), 'wb')
            except io.UnsupportedOperation:
                fd = NULL
            ret = zran.zran_export_index(&self.index, fd, <PyObject*>fileobj)
            if ret != zran.ZRAN_EXPORT_OK:
                raise ZranError('export_index returned error: {} (file: '
                                '{})'.format(ZRAN_ERRORS.ZRAN_EXPORT[ret],
                                             self.errname))

        finally:
            if close_file:
                fileobj.close()

        log.debug('%s.export_index(%s, %s)',
                  type(self).__name__,
                  filename,
                  fileobj)


    def import_index(self, filename=None, fileobj=None):
        """Import index data from the given file. Either ``filename`` or
        ``fileobj`` should be specified, but not both. ``fileobj`` should be
        opened in 'rb' mode.

        :arg filename: Name of the file.
        :arg fileobj:  Open file handle.
        """

        if filename is None and fileobj is None:
            raise ValueError('One of filename or fileobj must be specified')

        if filename is not None and fileobj is not None:
            raise ValueError(
                'Only one of filename or fileobj must be specified')

        if filename is not None:
            fileobj    = builtin_open(filename, 'rb')
            close_file = True

        else:
            close_file = False
            if getattr(fileobj, 'mode', 'rb') != 'rb':
                raise ValueError(
                    'File should be opened read-only binary mode.')

        try:
            # Pass both the Python file object and
            # file descriptor (if this is an actual
            # file) to the zran_import_index function
            try:
                fd = fdopen(fileobj.fileno(), 'rb')
            except io.UnsupportedOperation:
                fd = NULL
            ret = zran.zran_import_index(&self.index, fd, <PyObject*>fileobj)
            if ret != zran.ZRAN_IMPORT_OK:
                raise ZranError('import_index returned error: {} (file: '
                                '{})'.format(ZRAN_ERRORS.ZRAN_IMPORT[ret],
                                             self.errname))

            self.skip_crc_check = True

        finally:
            if close_file:
                fileobj.close()

        log.debug('%s.import_index(%s, %s)',
                  type(self).__name__,
                  filename,
                  fileobj)


cdef class ReadBuffer:
    """Wrapper around a chunk of memory.

    .. see:: http://docs.cython.org/src/tutorial/memory_allocation.html
    """

    cdef void *buffer
    """A raw chunk of bytes. """


    cdef size_t size;
    """Size of the buffer. """


    def __cinit__(self, size_t size):
        """Allocate ``size`` bytes of memory. """

        self.size   = size
        self.buffer = PyMem_Malloc(size)

        if not self.buffer:
            raise MemoryError('PyMem_Malloc fail')

        log.debug('ReadBuffer.__cinit__(%s)', size)


    def resize(self, size_t size):
        """Re-allocate the memory to the given ``size``. """

        if size == self.size:
            return

        buf = PyMem_Realloc(self.buffer, size)

        if not buf:
            raise MemoryError('PyMem_Realloc fail')

        log.debug('ReadBuffer.resize(%s)', size)

        self.size   = size
        self.buffer = buf


    def __dealloc__(self):
        """Free the mwmory. """
        PyMem_Free(self.buffer)

        log.debug('ReadBuffer.__dealloc__()')


def unpickle(state):
    """Create a new ``IndexedGzipFile`` from a pickled state.

    :arg state: State of a pickled object, as returned by the
                ``IndexedGzipFile.__reduce_ex__`` method.

    :returns:   A new ``IndexedGzipFile`` object.
    """

    tell  = state.pop('tell')
    index = state.pop('index')
    gzobj = IndexedGzipFile(**state)

    if index is not None:
        gzobj.import_index(fileobj=io.BytesIO(index))

    gzobj.seek(tell)

    return gzobj


class NotCoveredError(ValueError):
    """Exception raised by the :class:`_IndexedGzipFile` when an attempt is
    made to seek to/read from a location that is not covered by the
    index. If the ``_IndexedGzipFile`` was created with ``auto_build=True``,
    this error will only occur on attempts to call the ``seek`` method
    with ``whence=SEEK_END``, where the index has not been completely built.
    """


class ZranError(IOError):
    """Exception raised by the :class:`_IndexedGzipFile` when the ``zran``
    library signals an error.
    """


class CrcError(OSError):
    """Exception raised by the :class:`_IndexedGzipFile` when a CRC/size
    validation check fails, which suggests that the GZIP data might be
    corrupt.
    """


class NoHandleError(ValueError):
    """Exception raised by the :class:`_IndexedGzipFile` when
    ``drop_handles is True`` and an attempt is made to access the underlying
    file object.
    """


class DoesNotExistError(ValueError, FileNotFoundError):
    """Exception raised by the :class:`_IndexedGzipFile` when it is passed
    a path to a file that does not exist.
    """


class ZRAN_ERRORS(object):
    """Contains text versions of all error codes emitted by zran.c. """
    ZRAN_BUILD = {
        zran.ZRAN_BUILD_INDEX_FAIL      : 'ZRAN_BUILD_INDEX_FAIL',
        zran.ZRAN_BUILD_INDEX_CRC_ERROR : 'ZRAN_BUILD_INDEX_CRC_ERROR'
    }
    ZRAN_SEEK = {
        zran.ZRAN_SEEK_CRC_ERROR       : 'ZRAN_SEEK_CRC_ERROR',
        zran.ZRAN_SEEK_FAIL            : 'ZRAN_SEEK_FAIL',
        zran.ZRAN_SEEK_NOT_COVERED     : 'ZRAN_SEEK_NOT_COVERED',
        zran.ZRAN_SEEK_EOF             : 'ZRAN_SEEK_EOF',
        zran.ZRAN_SEEK_INDEX_NOT_BUILT : 'ZRAN_SEEK_INDEX_NOT_BUILT'
    }
    ZRAN_READ = {
        zran.ZRAN_READ_NOT_COVERED : 'ZRAN_READ_NOT_COVERED',
        zran.ZRAN_READ_EOF         : 'ZRAN_READ_EOF',
        zran.ZRAN_READ_FAIL        : 'ZRAN_READ_FAIL',
        zran.ZRAN_READ_CRC_ERROR   : 'ZRAN_READ_CRC_ERROR'
    }
    ZRAN_EXPORT = {
        zran.ZRAN_EXPORT_WRITE_ERROR : 'ZRAN_EXPORT_WRITE_ERROR'
    }
    ZRAN_IMPORT = {
        zran.ZRAN_IMPORT_OK                  : 'ZRAN_IMPORT_OK',
        zran.ZRAN_IMPORT_FAIL                : 'ZRAN_IMPORT_FAIL',
        zran.ZRAN_IMPORT_EOF                 : 'ZRAN_IMPORT_EOF',
        zran.ZRAN_IMPORT_READ_ERROR          : 'ZRAN_IMPORT_READ_ERROR',
        zran.ZRAN_IMPORT_INCONSISTENT        : 'ZRAN_IMPORT_INCONSISTENT',
        zran.ZRAN_IMPORT_MEMORY_ERROR        : 'ZRAN_IMPORT_MEMORY_ERROR',
        zran.ZRAN_IMPORT_UNKNOWN_FORMAT      : 'ZRAN_IMPORT_UNKNOWN_FORMAT',
        zran.ZRAN_IMPORT_UNSUPPORTED_VERSION : 'ZRAN_IMPORT_UNSUPPORTED_VERSION'
    }
