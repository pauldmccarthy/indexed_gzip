#!/usr/bin/env python
#
# __init__.py - The indexed_gzip namespace.
#
"""The indexed_gzip namespace. """


try:
    from ._version import __version__
except ImportError:
    __version__ = '<unknown>'

from .indexed_gzip import (_IndexedGzipFile,     # noqa
                           IndexedGzipFile,
                           open,
                           NotCoveredError,
                           NoHandleError,
                           ZranError)


SafeIndexedGzipFile = IndexedGzipFile
"""Alias for ``IndexedGzipFile``, to preserve compatibility with older
versions of ``nibabel``.
"""
