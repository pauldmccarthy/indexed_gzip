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
        zrbase  = op.join(base, 'zran')
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
            op.join(zrbase,  'zran.o'),
            op.join(zrbase,  'zran_file_util.o'),
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


# Platform information
python2 = sys.version_info[0] == 2
noc99   = python2 or (sys.version_info[0] == 3 and sys.version_info[1] <= 4)
windows = sys.platform.startswith("win")
testing = 'INDEXED_GZIP_TESTING' in os.environ

# We can use zlib or zlib-ng via one
# of the following mechanisms:
#
#  - Default:      Dynamically link against system zlib
#  - ZLIB_HOME:    Path to zlib build directory - statically
#                  link against built zlib library. Takes
#                  precedence over ZLIB_NG_HOME
#  - ZLIB_NG_HOME: Path to zlib-ng build directory - statically
#                  link against built zlib-ng library

# compile ZLIB source?
ZLIB_HOME    = os.environ.get('ZLIB_HOME',    None)
ZLIB_NG_HOME = os.environ.get('ZLIB_NG_HOME', None)

# Load README description
readme = op.join(op.dirname(__file__), 'README.md')
if python2:
    openreadme = ft.partial(open, readme, 'rt')
else:
    openreadme = ft.partial(open, readme, 'rt', encoding='utf-8')
with openreadme() as f:
    readme = f.read().strip()

# If cython is present, we'll compile
# the pyx files from scratch. Otherwise,
# we'll compile the pre-generated c
# files (which are assumed to be present).
have_cython = True
have_numpy  = True

try:
    from Cython.Build import cythonize
except Exception:
    have_cython = False

# We need numpy to compile the test modules
try:
    import numpy as np
except Exception:
    have_numpy = False

print('indexed_gzip setup')
print('  have_cython:  {} (if True, modules will be cythonized, '
      'otherwise pre-cythonized C files are assumed to be '
      'present)'.format(have_cython))
print('  have_numpy:   {} (if True, test modules will '
      'be compiled)'.format(have_numpy))
print('  ZLIB_HOME:    {} (if set, indexed_gzip is linked against '
      'zlib)'.format(ZLIB_HOME))
print('  ZLIB_NG_HOME: {} (if set, indexed_gzip is linked against '
      'zlib-ng (unless ZLIB_HOME is also set)'.format(ZLIB_NG_HOME))
print('  testing:      {} (if True, code will be compiled with line '
      'tracing enabled)'.format(testing))


# compile flags
include_dirs        = ['zran']
lib_dirs            = []
libs                = []
extra_srcs          = []
extra_objects       = []
extra_compile_args  = []
compiler_directives = {'language_level' : 2}
define_macros       = []

# Link against zlib built in ZLIB_HOME
if ZLIB_HOME is not None:
    include_dirs.append(ZLIB_HOME)
    if windows: extra_objects.append(op.join(ZLIB_HOME, 'zlibstatic.lib'))
    else:       extra_objects.append(op.join(ZLIB_HOME, 'libz.a'))

# Link against zlib built in ZLIB_NG_HOME
elif ZLIB_NG_HOME is not None:
    include_dirs .append(ZLIB_NG_HOME)
    define_macros.append(('ZRAN_USE_ZLIB_NG', '1'))
    if windows: extra_objects.append(op.join(ZLIB_NG_HOME, 'zlib-ngstatic.lib'))
    else:       extra_objects.append(op.join(ZLIB_NG_HOME, 'libz-ng.a'))

# Link against system zlib
else:
    if windows: libs.append('zlib')
    else:       libs.append('z')

# If numpy is present, we need
# to include the headers
if have_numpy:
    include_dirs.append(np.get_include())

# Windows specific flags
if windows:
    # For stdint.h which is not included in the old Visual C
    # compiler used for Python 2
    if python2:
        include_dirs.append('compat')

    # Some C functions might not be present when compiling against
    # older versions of python
    if noc99:
        extra_compile_args += ['-DNO_C99']

# linux / macOS specific flags
else:
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
     op.join('zran',         'zran.c'),
     op.join('zran',         'zran_file_util.c')] + extra_srcs,
    libraries=libs,
    library_dirs=lib_dirs,
    include_dirs=include_dirs,
    extra_compile_args=extra_compile_args,
    extra_objects=extra_objects,
    define_macros=define_macros)

# Optional test modules
test_exts = [
    Extension(
        'indexed_gzip.tests.ctest_indexed_gzip',
        [op.join('indexed_gzip', 'tests',
                 'ctest_indexed_gzip.{}'.format(pyx_ext))],
        libraries=libs,
        library_dirs=lib_dirs,
        include_dirs=include_dirs,
        extra_objects=extra_objects,
        extra_compile_args=extra_compile_args,
        define_macros=define_macros)
]

if not windows:
    # Uses POSIX memmap API so won't work on Windows
    test_exts.append(Extension(
        'indexed_gzip.tests.ctest_zran',
        [op.join('indexed_gzip', 'tests', 'ctest_zran.{}'.format(pyx_ext)),
         op.join('zran',         'zran.c'),
         op.join('zran',         'zran_file_util.c')] + extra_srcs,
        libraries=libs,
        library_dirs=lib_dirs,
        include_dirs=include_dirs,
        extra_objects=extra_objects,
        extra_compile_args=extra_compile_args,
        define_macros=define_macros))

# If we have numpy, we can compile the tests
if have_numpy: extensions = [igzip_ext] + test_exts
else:          extensions = [igzip_ext]


# Cythonize if we can
if have_cython:
    extensions = cythonize(extensions, compiler_directives=compiler_directives)


# find the version number
def readVersion():
    version  = {}
    initfile = op.join(op.dirname(__file__), 'indexed_gzip', '__init__.py')
    with open(initfile, 'rt') as f:
        for line in f:
            if line.startswith('__version__'):
                exec(line, version)
                break
    return version.get('__version__')


setup(
    name='indexed_gzip',
    packages=['indexed_gzip', 'indexed_gzip.tests'],
    version=readVersion(),
    author='Paul McCarthy',
    author_email='pauldmccarthy@gmail.com',
    description='Fast random access of gzip files in Python',
    long_description=readme,
    long_description_content_type='text/markdown',
    url='https://github.com/pauldmccarthy/indexed_gzip',
    license='zlib',

    classifiers=[
        'Development Status :: 3 - Alpha',
        'Intended Audience :: Developers',
        'License :: OSI Approved :: zlib/libpng License',
        'Programming Language :: C',
        'Programming Language :: Cython',
        'Programming Language :: Python :: 2',
        'Programming Language :: Python :: 3',
        'Topic :: System :: Archiving :: Compression',
    ],

    cmdclass={'clean' : Clean},

    ext_modules=extensions,

    tests_require=['pytest', 'numpy', 'nibabel'],
    test_suite='tests',
)
