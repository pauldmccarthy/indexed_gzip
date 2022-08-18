# indexed_gzip
 

[![PyPi version](https://img.shields.io/pypi/v/indexed_gzip.svg)](https://pypi.python.org/pypi/indexed_gzip/) [![Anaconda version](https://anaconda.org/conda-forge/indexed_gzip/badges/version.svg)](https://anaconda.org/conda-forge/indexed_gzip/)![Test status](https://github.com/pauldmccarthy/indexed_gzip/actions/workflows/master.yaml/badge.svg)


 *Fast random access of gzip files in Python*


 * [Overview](#overview)
 * [Installation](#installation)
 * [Usage](#usage)
 * [Using with `nibabel`](#using-with-nibabel)
 * [Index import/export](#index-import-export)
 * [Write support](#write-support)
 * [Performance](#performance)
 * [Acknowledgements](#acknowledgements)
 * [License](#license)


## Overview


The `indexed_gzip` project is a Python extension which aims to provide a
drop-in replacement for the built-in Python `gzip.GzipFile` class, the
`IndexedGzipFile`.


`indexed_gzip` was written to allow fast random access of compressed
[NIFTI](http://nifti.nimh.nih.gov/) image files (for which GZIP is the
de-facto compression standard), but will work with any GZIP file.
`indexed_gzip` is easy to use with `nibabel` (http://nipy.org/nibabel/).


The standard `gzip.GzipFile` class exposes a random access-like interface (via
its `seek` and `read` methods), but every time you seek to a new point in the
uncompressed data stream, the `GzipFile` instance has to start decompressing
from the beginning of the file, until it reaches the requested location.


An `IndexedGzipFile` instance gets around this performance limitation by
building an index, which contains *seek points*, mappings between
corresponding locations in the compressed and uncompressed data streams. Each
seek point is accompanied by a chunk (32KB) of uncompressed data which is used
to initialise the decompression algorithm, allowing us to start reading from
any seek point. If the index is built with a seek point spacing of 1MB, we
only have to decompress (on average) 512KB of data to read from any location
in the file.


## Intended use


You may find `indexed_gzip` useful if you need to read from large GZIP files.
A major advantage of `indexed_gzip` is that it will work with any GZIP file.
However, if you have control over the creation of your GZIP files, you may
wish to consider some alternatives:

 * [`mgzip`](https://github.com/vinlyx/mgzip/) provides an accelerated
   GZIP compression and decompression library.
 * Compression formats other than GZIP, such as `bzip2` and `xz`, have better
   support for random access.


## Installation


`indexed_gzip` is available on [PyPi](https://pypi.python.org/pypi) - to
install, simply type:
```sh
pip install indexed_gzip
```


You can also install `indexed_gzip` from conda-forge:

```sh
conda install -c conda-forge indexed_gzip
```

To compile `indexed_gzip`, make sure you have [cython](http://cython.org/)
installed (and `numpy` if you want to compile the tests), and then run:
```sh
python setup.py develop
```


To run the tests, type the following; you will need `numpy`, `nibabel`,
`pytest`, `pytest-cov`, and `coverage` installed:

```sh
python -m indexed_gzip.tests
```

## Usage


You can use the `indexed_gzip` module directly:


```python
import indexed_gzip as igzip

# You can create an IndexedGzipFile instance
# by specifying a file name, or an open file
# handle. For the latter use, the file handle
# must be opened in read-only binary mode.
# Write support is currently non-existent.
myfile = igzip.IndexedGzipFile('big_file.gz')

some_offset_into_uncompressed_data = 234195

# The index will be automatically
# built on-demand when seeking.
myfile.seek(some_offset_into_uncompressed_data)
data = myfile.read(1048576)
```


## Using with in-memory data

You can use `indexed_gzip` with any Python file-like object. For example:

```python

import io
import indexed_gzip as igzip

# Load some gzip data from somewhere
with open('my_file.gz') as f:
    data = f.read()

# Create an IndexedGzipFile based on the
# in-memory data buffer
gzf = igzip.IndexedGzipFile(fileobj=io.BytesIO(data))
uncompressed = gzf.read(1048576)
```


## Using with `nibabel`


You can use `indexed_gzip` with `nibabel`. `nibabel` >= 2.3.0 will
automatically use `indexed_gzip` if it is present:


```python
import nibabel as nib

image = nib.load('big_image.nii.gz')
```


If you are using `nibabel` 2.2.x, you need to explicitly set the
`keep_file_open` flag:


```python
import nibabel as nib

image = nib.load('big_image.nii.gz', keep_file_open='auto')
```


To use `indexed_gzip` with `nibabel` 2.1.0 or older, you need to do a little
more work:


```python
import nibabel      as nib
import indexed_gzip as igzip

# Here we are using 4MB spacing between
# seek points, and using a larger read
# buffer (than the default size of 16KB).
fobj = igzip.IndexedGzipFile(
    filename='big_image.nii.gz',
    spacing=4194304,
    readbuf_size=131072)

# Create a nibabel image using
# the existing file handle.
fmap = nib.Nifti1Image.make_file_map()
fmap['image'].fileobj = fobj
image = nib.Nifti1Image.from_file_map(fmap)

# Use the image ArrayProxy to access the
# data - the index will automatically be
# built as data is accessed.
vol3 = image.dataobj[:, :, :, 3]
```


## Index import/export


If you have a large file, you may wish to pre-generate the index once, and
save it out to an index file:


```python
import indexed_gzip as igzip

# Load the file, pre-generate the
# index, and save it out to disk.
fobj = igzip.IndexedGzipFile('big_file.gz')
fobj.build_full_index()
fobj.export_index('big_file.gzidx')
```


The next time you open the same file, you can load in the index:


```python
import indexed_gip as igzip
fobj = igzip.IndexedGzipFile('big_file.gz', index_file='big_file.gzidx')
```


## Write support


`indexed_gzip` does not currently have any support for writing. Currently if
you wish to write to a file, you will need to save the file by alternate means
(e.g.  via `gzip` or `nibabel`), and then re-create a new `IndexedGzipFile`
instance.  For example:


```python

import nibabel as nib

# Load the entire image into memory
image = nib.load('big_image.nii.gz')
data = image.get_data()

# Make changes to the data
data[:, :, :, 5] *= 100

# Save the image using nibabel
nib.save(data, 'big_image.nii.gz')

# Re-load the image
image = nib.load('big_image.nii.gz')
```


## Performance


A small [test script](indexed_gzip/tests/benchmark.py) is included with
`indexed_gzip`; this script compares the performance of the `IndexedGzipFile`
class with the `gzip.GzipFile` class. This script does the following:

  1. Generates a test file.

  2. Generates a specified number of seek locations, uniformly spaced
     throughout the test file.

  3. Randomly shuffles these locations

  4. Seeks to each location, and reads a chunk of data from the file.


This plot shows the results of this test for a few compresed files of varying
sizes, with 500 seeks:


![Indexed gzip performance](./performance.png)


## Acknowledgements


The `indexed_gzip` project is based upon the `zran.c` example (written by Mark
Alder) which ships with the [zlib](http://www.zlib.net/) source code.


`indexed_gzip` was originally inspired by Zalan Rajna's (@zrajna)
[zindex](https://github.com/zrajna/zindex) project:

    Z. Rajna, A. Keskinarkaus, V. Kiviniemi and T. Seppanen
    "Speeding up the file access of large compressed NIfTI neuroimaging data"
    Engineering in Medicine and Biology Society (EMBC), 2015 37th Annual
    International Conference of the IEEE, Milan, 2015, pp. 654-657.

    https://sourceforge.net/projects/libznzwithzindex/


Initial work on `indexed_gzip` took place at
[Brainhack](http://www.brainhack.org/) Paris, at the Institut Pasteur,
24th-26th February 2016, with the support of the
[FMRIB Centre](https://www.ndcn.ox.ac.uk/divisions/fmrib/), at the
University of Oxford, UK.

Many thanks to the following contributors (listed chronologically):

 - Zalan Rajna (@zrajna): Bug fixes (#2)
 - Martin Craig (@mcraig-ibme): Porting `indexed_gzip` to Windows (#3)
 - Chris Markiewicz (@effigies): Option to drop file handles (#6)
 - Omer Ozarslan (@ozars): Index import/export (#8)
 - @DarioDaF: Windows overflow bug (#30)
 - Sławomir Zborowski (@szborows): `seek_points` method (#35), README fixes
   (#34)
 - Ashwin Ramaswami (@epicfaace): Support for in-memory file objects (#55),
   bug fixes (#63, #64, #65).
 - Michał Górny (@mgorny): Remove hard dependency on `nibabel` from test suite
   (#78).
 - Alexander Gorban (@alexgorban) Fix memory leak (#82, #83).
 - Maximilian Knespel (@mxmlnkn) Change default read buffer size to
   improve performance (#90).


## License


`indexed_gzip` inherits the [zlib](http://www.zlib.net) license, available for
perusal in the [LICENSE](LICENSE) file.
