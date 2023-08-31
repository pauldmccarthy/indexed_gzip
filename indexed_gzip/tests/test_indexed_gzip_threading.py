#!/usr/bin/env python
#
# test_indexed_gzip_threading.py -
#
# Author: Paul McCarthy <pauldmccarthy@gmail.com>
#

from __future__ import print_function
from __future__ import division

import sys

import threading

import numpy as np

import pytest

import indexed_gzip as igzip

from . import check_data_valid

pytestmark = pytest.mark.indexed_gzip_test


# def test_IndexedGzipFile_open_close(testfile, nelems, concat):
#     _test_IndexedGzipFile_open_close(testfile, False)

# def test_IndexedGzipFile_open_close_drop_handles(testfile, nelems, concat):
#     _test_IndexedGzipFile_open_close(testfile, True)

# @pytest.mark.slow_test
# def test_IndexedGzipFile_pread_threaded(testfile, nelems, concat):
#     _test_IndexedGzipFile_pread_threaded(testfile, nelems, False)

# @pytest.mark.slow_test
# def test_IndexedGzipFile_pread_threaded_drop_handles(testfile, nelems, concat):
#     _test_IndexedGzipFile_pread_threaded(testfile, nelems, True)


# def _test_IndexedGzipFile_open_close(testfile, drop):

#     f = igzip.IndexedGzipFile(filename=testfile, drop_handles=drop)
#     f.seek(10)
#     f.read(10)
#     f.close()


# def _test_IndexedGzipFile_pread_threaded(testfile, nelems, drop):

#     filesize     = nelems * 8
#     indexSpacing = max(524288, filesize // 2000)

#     with igzip.IndexedGzipFile(filename=testfile,
#                                spacing=indexSpacing,
#                                drop_handles=drop) as f:

#         readelems = 50
#         readsize  = readelems * 8
#         nthreads  = 100
#         allreads  = []

#         def do_pread(nbytes, offset):
#             data = f.pread(nbytes, int(offset * 8))
#             allreads.append((offset, data))

#         offsets = np.linspace(0, nelems - readelems, nthreads,
#                               dtype=np.uint64)
#         threads = [threading.Thread(target=do_pread, args=(readsize, o))
#                    for o in offsets]
#         [t.start() for t in threads]
#         [t.join()  for t in threads]

#         assert len(allreads) == nthreads
#         for offset, data in allreads:

#             assert len(data) == readsize

#             data = np.ndarray(shape=readelems, dtype=np.uint64,
#                               buffer=data)
#             assert check_data_valid(data, offset, offset + readelems)
