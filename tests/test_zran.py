#!/usr/bin/env python
#
# test_zran.py - Python wrapper around ctest_zran.pyx.
#
# Author: Paul McCarthy <pauldmccarthy@gmail.com>
#

import pytest

from . import ctest_zran


pytestmark = pytest.mark.zran_test

def test_init(                  testfile):                 ctest_zran.test_init(                  testfile)
def test_init_file_modes(       testfile):                 ctest_zran.test_init_file_modes(       testfile)
def test_seek_to_end(           testfile, nelems):         ctest_zran.test_seek_to_end(           testfile, nelems)
def test_seek_beyond_end(       testfile, nelems):         ctest_zran.test_seek_beyond_end(       testfile, nelems)
def test_sequential_seek_to_end(testfile, nelems, niters): ctest_zran.test_sequential_seek_to_end(testfile, nelems, niters)
def test_random_seek(           testfile, nelems, niters): ctest_zran.test_random_seek(           testfile, nelems, niters)
def test_read_all(              testfile, nelems):         ctest_zran.test_read_all(              testfile, nelems)
def test_seek_then_read_block(  testfile, nelems, niters): ctest_zran.test_seek_then_read_block(  testfile, nelems, niters)
def test_random_seek_and_read(  testfile, nelems, niters): ctest_zran.test_random_seek_and_read(  testfile, nelems, niters)
def test_read_all_sequential(   testfile, nelems):         ctest_zran.test_read_all_sequential(   testfile, nelems)
def test_build_then_read(       testfile, nelems):         ctest_zran.test_build_then_read(       testfile, nelems)
def test_readbuf_spacing_sizes( testfile, nelems, niters): ctest_zran.test_readbuf_spacing_sizes( testfile, nelems, niters)
