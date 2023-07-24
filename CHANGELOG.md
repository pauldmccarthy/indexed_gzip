# `indexed_gzip` changelog


## 1.8.0 (Under development)


* Changes to allow linking against
  [zlib-ng](https://github.com/zlib-ng/zlib-ng/) (#107).
* Simplified C interface `cindexed_gzip`, and machinery for compiling as a
  static or shared C library (#107).


## 1.7.1 (March 31st 2023)


* Small change to the `IndexedGzipFile` class so that it accepts file-likes
  which do not implement `fileno()` (#118).


## 1.7.0 (September 12th 2022)


* Changes to allow an index to be built from file-likes which don't support
  `seek()` or `tell()` operations (#103, #105).


## 1.6.13 (April 14th 2022)


* Changed the default read buffer size used by the `IndexedGzipFile` class
  (#90).
* Update to wheel building procedure (#92,#93,#95,#96,#97,#98,#99).
* Aded `pyproject.toml` to declare build-time requirements (#94).


## 1.6.4 (October 18th 2021)


* Fixed a bug related to buffering input data, which was causing a spurious
  `CrcError` (#80, #87).



## 1.6.3 (September 14th 2021)


* Relaxed `mode` check when creating an `IndexedGzipFile` from an open file
  handle - `fileobj.mode` may now be `'r'` or `'rb'` (or may not exist at all)
  (#85, #86).


## 1.6.2 (September 2nd 2021)


* Fixed a memory leak when initialising decompression / inflation (#82, #83).
* Added file name to exception messages when possible, to assist in diagnosing
  errors (#84).


## 1.6.1 (May 25th 2021)


* Tests requiring `nibabel` are now skipped, rather than causing failure (#78).


## 1.6.0 (May 23rd 2021)


* Python 2.7 wheels for Windows are no longer being built (#71, #73).
* A backwards-compatible change to the index file format, to accommodate seek
  points at stream boundaries. Index files created with older versions of
  `indexed_gzip` can still be loaded, but index files created with
  `indexed_gzip` 1.6.0 cannot be loaded by older versions of `indexed_gzip`
  (#75).
* CRC and size validation of uncompressed data is now performed by default,
  on the first pass through a GZIP file. This can be disabled by setting the
  new `skip_crc_check` argument to `False` when creating an
  `IndexedGzipFile`. Validation is not performed when an existing index is
  imported from file (#72).
* Null padding bytes at the end of a GZIP file, or in between GZIP streams,
  are now skipped over (#69, #70, #72).
* Seek points are now created at the beginning of every GZIP stream, in files
  containing concatenated streams (#72).


## 1.5.3 (March 23rd 2021)


* Restored wheel building for Python 2.7 on 32 bit Windows (#64, #66).
* Now building wheels for `aarch64` on Linux, and `amd64`/`universal2` on
  macOS (#66).
* Fixed some un-initialised pointers (#65).
* Fixed a bug in the use of `PyErr_Occurred` (#63).


## 1.5.2 (March 19th 2021)


* Not providing binary wheels for Python 2.7 on 32 bit Windows (#61).


## 1.5.1 (March 19th 2021)


* Minor adjustments to some unit test (#60).


## 1.5.0 (March 19th 2021)


* Added support for in-memory file-like objects (#55).
* Fixed a bug whereby a segmentation fault could occur if an `IndexedGzipFile`
  was created with a path to a non-existent file (#56).


## 1.4.0 (January 2nd 2021)


* Fixed a bug in the pickling/copying logic in the `IndexedGzipFile` class
  (#50, #51)
* New `indexed_gzip.open` function, which just creates and returns an
  `IndexedGzipFile`.
* When creating an `IndexedGzipFile`, the first argument (`filename`) may
  be either a file name, or an open file handle (#49, #53).
* Migrated CI testing and building to Github Actions (#52).
* Binary wheels for Windows now have ZLIB statically compiled in as part
  of the wheel, so ZLIB no longer needs to be installed (#43, #52).


## 1.3.3 (November 14th 2020)


* Adjusted the `ZranError` exception type to sub-class from `IOError`, to
  ease support for `nibabel`.
* Fixed a bug related to concatenated GZIP files which would occur when
  the read buffer ran out of space at the point where a stream boundary
  occurred.


## 1.3.2 (June 30th 2020)


* Adjusted the `NoHandleError` and `NotCoveredError` types to sub-class from
  `ValueError`, to preserve backwards compatibility with older versions of
  `nibabel`.


## 1.3.1 (June 25th 2020)


* Reverted the error type raised by the `IndexedGzipFile.seek` to `ValueError`,
  as `nibabel` assumes that the `seek` method of file objects raise a
  `ValueError` if `SEEK_END` is not supported.


## 1.3.0 (June 24th 2020)


* The `IndexedGzipFile.seek` method now accepts seeking from the end of
  uncompressed stream via `SEEK_END`, as long as the index has been built (#37).


## 1.2.0 (May 12th 2020)


* New `IndexedGzipFile.seek_points` method, which returns the compressed and
  uncompressed seek point locations.


## 1.1.0 (April 20th 2020)


* `IndexedGzipFile` objects are now picklable, as long as they are created with
  the default setting of `drop_handles=True` and with a `filename` and not an
  open `fileobj` (#28, #31).
* Changed the return type of `zran_tell` from `long` to `uint64_t`, because the
  former is not guaranteed to be 64 bit (#29, #30).
* Changed the `zran_index_t.compressed_size` and `uncompressed_size` fields from
  `size_t` to `uint64_t` because the former is not guaranteed to be 64 bit.


## 1.0.0 (February 21st 2020)


* Removed the deprecated `fid` argument to the `IndexedGzipFile` constructor.
* Removed the `SafeIndexedGzipFile`.


## 0.8.10 (May 15th 2019)


* Fix to package metadata.


## 0.8.9 (May 14th 2019)


* The `IndexedGzipFile.import_index` method and `zran_import_index` function
  can handle index files which do not contain any index points (#18).


## 0.8.8 (November 22nd 2018)

* Fixed bug affecting files which were an exact multiple of the read buffer
  size (#15).


## 0.8.7 (August 3rd 2018)

* Internal changes to how file handles are managed, to improve Windows
  compatibility.
* The `_IndexedGzipFile.read` method now acquires a single file handle, rather
  than opening/closing multiple handles across calls to `zran_read`.


## 0.8.6 (June 27th 2018)

* Workaround for issues with Python 2.7 and Cython < 0.26 (#10).


## 0.8.5 (June 16th 2018)

* Minor changes to packging.


## 0.8.4 (June 11th 2018)

* Removed `pytest-runner` as a dependency.


## 0.8.3 (June 11th 2018)

* Bugfix - variious methods and attributes were missing from the
  `IndexedGzipFile` wrapper class (#9).


## 0.8.2 (March 30th 2018)

Changes in this release:

* Bugfix in deprecated `SafeIndexedGzipFile`.


## 0.8.1 (March 24th 2018)

Changes in this release:

* Updated conda metadata.


## 0.8.0 (March 24th 2018)

Changes in this release:

* Added ability to import/export the index, via new `import_index` and
  `export_index` methods on the `IndexedGzipFile` class (#7, #8) - thanks
  @ozars !
* Deprecated `SafeIndexedGzipFile` - the `IndexedGzipFile` is now
  thread-safe, and has a read buffer. If you don't want buffering
  or thread-safety, use the `_IndexedGzipFile` class.
* Fixed bug in `seek` method - was not working with negative offsets.
* More unit tests, and code coverage of `.py` and `.pyx` files.


## 0.7.1 (March 5th 2018)

Changes in this release:

* Added `.conda/meta.yaml` file for building conda packages


## 0.7.0 (November 3rd 2017)

Changes in this release:

* `IndexedGzipFile.__init__` has a new option, `drop_handles` which causes an
  `IndexedGzipFile` to close/re-open the underlying file handle on every
  access (#5, #6). This has no impact on performance (as measured by the new
  benchmark script), so is enabled by default.

* New simpler benchmark script.

* Deprecated the `fid` parameter to `IndexedGzipFile.__init__` in favour of
  `fileobj` - another change to make `IndexedGzipFile` more similar to
  `gzip.GzipFile`.


## 0.6.1 (October 4th 2017)

Changes in this release:

* `IndexedGzipFile` now has a `readinto` method.
* `SafeIndexedGzipFile` is now an `io.BufferedReader`, which provides thread
  safety and dramatically improves performance for small files (see discussion
  at nipy/nibabel#558).
* Fixed issue #4 - the source distribution was missing `zran.h`.


## 0.6.0 (September 24th 2017)

Changes in this release:

* Preliminary support for Windows platforms (#1, #3) Thanks to @mcraig-ibme
  and @Trigonometry !

* Added `mode` attribute to `IndexedGzipFile`.


## 0.5.1 (September 12th 2017)

Changes in this release:

* Unit tests are run on a 32 bit platform
* The `indexed_gzip` package now has a `__version__` attribute


## 0.5.0 (September 8th 2017)

Changes in this release:

* Re-arranged code layout - there is now a top level `indexed_gzip` package,
  which contains the `indexed_gzip` module, and the `tests` package. Done so
  that tests can be distributed properly. No API changes though.

* `zran_seek` input parameter types made more specific due to an issue on 32 bit
  platforms.


## 0.4.1 (September 6th 2017)

Changes in this release:

* A tiny adjustment to unit test management allowing tests to be run from a
  different directory


## 0.4.0 (September 5th 2017)

Changes in this release involve modifications and additions to the
`IndexedGzipFile` class to make it look and behave more like the built-in
`gzip.GzipFile` class.

* `__init__` accepts `filename` and `mode` as its first two parameters

* Changed default values for `__init__` parameters to values which have been
  qualitatively tested

* `readline`, `readlines`, `__iter__` and `__next__` methods added, for
  iteration over lines in text data

* `seek` method accepts a `whence` parameter, and allows seeking from
  `SEEK_SET` or `SEEK_CUR`,


## 0.3.3 (May 3rd 2017)

Changes in this release:

* `SafeIndexedGzipFile` was broken under python 3.


## 0.3.2 (May 1st 2017)

Changes in this release:

* Bugfix (PR #2)


## 0.3.1 (October 17th 2016)

Changes in this release:

* One critical, silly bugfix that should have been in 0.3.


## 0.3 (October 16th 2016)

Changes in this release:

* Support for reading > 2**32 bytes in a single call.
* Support for concatenated gzip streams.
* Many related bug fixes.
* `zran.c` refactored so it is much cleaner and clearer.
* Test suite is much more comprehensive


## 0.2 (August 31st 2016)

The following changes have been made in this release:

* `indexed_gzip` now releases the GIL when possible
* A new `SafeIndexedGzipFile` class provides simple thread-safe file access to
  compressed files.
* Some initial test coverage using https://travis-ci.org
* Some important bug fixes.


## 0.1 (June 16th 2016)

* First seemingly stable release.
