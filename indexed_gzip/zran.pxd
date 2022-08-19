#
# Cython declaration for the zran library.
#

from libc.stdio  cimport FILE
from libc.stdint cimport uint8_t, uint16_t, uint32_t, uint64_t, int64_t
from posix.types cimport off_t
from cpython.ref cimport PyObject


cdef extern from "zran.h":

    ctypedef struct zran_index_t:
        FILE         *fd;
        PyObject     *f;
        size_t        compressed_size;
        size_t        uncompressed_size;
        uint32_t      spacing;
        uint32_t      window_size;
        uint32_t      readbuf_size;
        uint32_t      npoints;
        zran_point_t *list;

    ctypedef struct zran_point_t:
        uint64_t  cmp_offset;
        uint64_t  uncmp_offset;
        uint8_t   bits;
        uint8_t  *data;

    enum:
        # flags for zran_init
        ZRAN_AUTO_BUILD     =  1,
        ZRAN_SKIP_CRC_CHECK =  2,

        # return codes for zran_build_index
        ZRAN_BUILD_INDEX_OK        =  0,
        ZRAN_BUILD_INDEX_FAIL      = -1,
        ZRAN_BUILD_INDEX_CRC_ERROR = -2,

        # return codes for zran_seek
        ZRAN_SEEK_CRC_ERROR       = -2,
        ZRAN_SEEK_FAIL            = -1,
        ZRAN_SEEK_OK              =  0,
        ZRAN_SEEK_NOT_COVERED     =  1,
        ZRAN_SEEK_EOF             =  2,
        ZRAN_SEEK_INDEX_NOT_BUILT =  3,

        # return codes for zran_read
        ZRAN_READ_NOT_COVERED = -1,
        ZRAN_READ_EOF         = -2,
        ZRAN_READ_FAIL        = -3,
        ZRAN_READ_CRC_ERROR   = -4,

        # return codes for zran_export_index
        ZRAN_EXPORT_OK          =  0,
        ZRAN_EXPORT_WRITE_ERROR = -1,

        # return codes for zran_import_index
        ZRAN_IMPORT_OK                  =  0,
        ZRAN_IMPORT_FAIL                = -1,
        ZRAN_IMPORT_EOF                 = -2,
        ZRAN_IMPORT_READ_ERROR          = -3,
        ZRAN_IMPORT_INCONSISTENT        = -4,
        ZRAN_IMPORT_MEMORY_ERROR        = -5,
        ZRAN_IMPORT_UNKNOWN_FORMAT      = -6,
        ZRAN_IMPORT_UNSUPPORTED_VERSION = -7

    int zran_init(zran_index_t *index,
                  FILE         *fd,
                  PyObject     *f,
                  uint32_t      spacing,
                  uint32_t      window_size,
                  uint32_t      readbuf_size,
                  uint64_t      compressed_size,
                  uint16_t      flags)

    void zran_free(zran_index_t *index)

    int zran_build_index(zran_index_t *index,
                         uint64_t      from_,
                         uint64_t      until) nogil;

    uint64_t zran_tell(zran_index_t *index);

    int zran_seek(zran_index_t  *index,
                  int64_t        offset,
                  uint8_t        whence,
                  zran_point_t **point) nogil;

    int64_t zran_read(zran_index_t *index,
                      void         *buf,
                      uint64_t      len) nogil;

    int zran_export_index(zran_index_t *index,
                          FILE         *fd,
                          PyObject     *f);

    int zran_import_index(zran_index_t *index,
                          FILE         *fd,
                          PyObject     *f);
