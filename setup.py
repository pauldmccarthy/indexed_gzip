#!/usr/bin/env python
"""Setup script for indexed_gzip.

If an environment variable called `INDEXED_GZIP_TESTING` is defined, the
Cython modules are compiled with line-tracing enabled, via the Cython
`linetrace` directive, and the `CYTHON_TRACE_NOGIL` macro.

See
https://cython.readthedocs.io/en/latest/src/reference/compilation.html#compiler-directives
for more details.

The ZLIB_HOME environment variable can be used to compile and statically link
ZLIB into the indexed_gzip shared library file. It should point to a directory
which contains the ZLIB source code. If not provided, the ZLIB header and
library files are assumed to be provided by the system.
"""

import sys
import os
import glob
import functools as ft
import os.path as op
import shutil

from setuptools import setup
from setuptools import Extension
from setuptools import Command


# Custom 'clean' command
class Clean(Command):

    user_options = []

    def initialize_options(self):
        pass
    def finalize_options(self):
        pass

    def run(self):

        base    = op.dirname(__file__)
        igzbase = op.join(base, 'indexed_gzip')

        shutil.rmtree(op.join(base, 'build'),
                      ignore_errors=True)
        shutil.rmtree(op.join(base, 'dist'),
                      ignore_errors=True)
        shutil.rmtree(op.join(base, 'indexed_gzip.egg-info'),
                      ignore_errors=True)
        shutil.rmtree(op.join(base, '.eggs'),
                      ignore_errors=True)
        shutil.rmtree(op.join(base, '__pycache__'),
                      ignore_errors=True)
        shutil.rmtree(op.join(igzbase, '__pycache__'),
                      ignore_errors=True)
        shutil.rmtree(op.join(igzbase, 'tests', '__pycache__'),
                      ignore_errors=True)

        files = [
            '*.so',
            op.join(igzbase, 'indexed_gzip.c'),
            op.join(igzbase, 'zran.o'),
            op.join(igzbase, 'zran_file_util.o'),
            op.join(igzbase, '*.pyc'),
            op.join(igzbase, '*.so'),
            op.join(igzbase, 'tests', '*.so'),
            op.join(igzbase, 'tests', '*.pyc'),
            op.join(igzbase, 'tests', 'ctest_zran.c'),
            op.join(igzbase, 'tests', 'ctest_indexed_gzip.c')]

        for f in files:
            for g in glob.glob(f):
                try:            os.remove(g)
                except OSError: pass

command_classes = {
    'clean' : Clean,
}

# Platform information
noc99     = sys.version_info[0] == 3 and sys.version_info[1] <= 4
stable_abi = sys.version_info[0] == 3 and sys.version_info[1] >= 11
windows   = sys.platform.startswith("win")
testing   = 'INDEXED_GZIP_TESTING' in os.environ
thisdir   = op.dirname(__file__)

# compile ZLIB source?
ZLIB_HOME = os.environ.get("ZLIB_HOME", None)
# setuptools may complain about
# absolute paths in some circumstances
if ZLIB_HOME is not None:
    ZLIB_HOME = op.relpath(ZLIB_HOME, thisdir)

# If cython is present, we'll compile
# the pyx files from scratch. Otherwise,
# we'll compile the pre-generated c
# files (which are assumed to be present).
have_cython = True
have_numpy  = True

try:
    import Cython
    from Cython.Build import cythonize
except Exception:
    have_cython = False

# We need numpy to compile the test modules
try:
    import numpy as np
except Exception:
    have_numpy = False

print('indexed_gzip setup')
print('  have_cython: {} (if True, modules will be cythonized, '
      'otherwise pre-cythonized C files are assumed to be '
      'present)'.format(have_cython))
print('  have_numpy:  {} (if True, test modules will '
      'be compiled)'.format(have_numpy))
print('  ZLIB_HOME:   {} (if set, ZLIB sources are compiled into '
      'the indexed_gzip extension)'.format(ZLIB_HOME))
print('  testing:     {} (if True, code will be compiled with line '
      'tracing enabled)'.format(testing))

if stable_abi and have_cython:
    cython_version_info = tuple(map(int, Cython.__version__.split('.')[:2]))
    # Cython 3.1 is/will be the first version to support the stable ABI
    stable_abi = cython_version_info >= (3, 1)

# compile flags
include_dirs        = ['indexed_gzip']
lib_dirs            = []
libs                = []
extra_srcs          = []
extra_compile_args  = []
compiler_directives = {'language_level' : 2}
define_macros       = [
    ('NPY_NO_DEPRECATED_API', 'NPY_1_7_API_VERSION'),
]
if stable_abi:
    define_macros += [
        ('CYTHON_LIMITED_API', '1'),
        ('Py_LIMITED_API', '0x030b0000'),
    ]

if ZLIB_HOME is not None:
    include_dirs.append(ZLIB_HOME)
    extra_srcs.extend(glob.glob(op.join(ZLIB_HOME, '*.c')))

# If numpy is present, we need
# to include the headers
if have_numpy:
    include_dirs.append(np.get_include())

if windows:
    if ZLIB_HOME is None:
        libs.append('zlib')

    # Some C functions might not be present when compiling against
    # older versions of python
    if noc99:
        extra_compile_args += ['-DNO_C99']

# linux / macOS
else:
    # if ZLIB_HOME is set, statically link,
    # rather than use system-provided zlib
    if ZLIB_HOME is None:
        libs.append('z')
    extra_compile_args += ['-Wall', '-Wno-unused-function']

if testing:
    compiler_directives['linetrace'] = True
    define_macros += [('CYTHON_TRACE_NOGIL', '1')]

# Compile from cython files if
# possible, or compile from c.
if have_cython: pyx_ext = 'pyx'
else:           pyx_ext = 'c'

# The indexed_gzip module
igzip_ext = Extension(
    'indexed_gzip.indexed_gzip',
    [op.join('indexed_gzip', 'indexed_gzip.{}'.format(pyx_ext)),
     op.join('indexed_gzip', 'zran.c'),
     op.join('indexed_gzip', 'zran_file_util.c')] + extra_srcs,
    libraries=libs,
    library_dirs=lib_dirs,
    include_dirs=include_dirs,
    extra_compile_args=extra_compile_args,
    define_macros=define_macros,
    py_limited_api=stable_abi,
)

# Optional test modules
test_exts = []

if not windows:
    # Uses POSIX memmap API so won't work on Windows
    test_exts.append(Extension(
        'indexed_gzip.tests.ctest_zran',
        [op.join('indexed_gzip', 'tests', 'ctest_zran.{}'.format(pyx_ext)),
         op.join('indexed_gzip', 'zran.c'),
         op.join('indexed_gzip', 'zran_file_util.c')] + extra_srcs,
        libraries=libs,
        library_dirs=lib_dirs,
        include_dirs=include_dirs,
        extra_compile_args=extra_compile_args,
        define_macros=define_macros,
        py_limited_api=stable_abi,
    ))

# If we have numpy, we can compile the tests
if have_numpy: extensions = [igzip_ext] + test_exts
else:          extensions = [igzip_ext]


# Cythonize if we can
if have_cython:
    extensions = cythonize(extensions, compiler_directives=compiler_directives)

if stable_abi:
    from wheel.bdist_wheel import bdist_wheel

    class bdist_wheel_abi3(bdist_wheel):
        def get_tag(self):
            python, abi, plat = super().get_tag()
            if python.startswith('cp3'):
                python, abi = 'cp311', 'abi3'
            return python, abi, plat

    command_classes['bdist_wheel'] = bdist_wheel_abi3

setup(
    name='indexed_gzip',
    cmdclass=command_classes,
    ext_modules=extensions,
)
