#!/usr/bin/env python


import os.path as op
import functools as ft
import shutil

import pytest

nib = pytest.importorskip("nibabel")

import numpy        as np
import indexed_gzip as igzip

from indexed_gzip.tests import tempdir


pytestmark = pytest.mark.nibabel_test


@ft.total_ordering
class Version(object):
    def __init__(self, vstr):
        self.v = [int(v) for v in vstr.split('.')]
    def __eq__(self, other):
        return other.v == self.v
    def __lt__(self, other):
        for sv, ov in zip(self.v, other.v):
            if sv > ov: return False
            if sv < ov: return True
        return False


nibver = Version(nib.__version__)


if nibver >= Version('2.1.0'):
    from nibabel.filebasedimages import ImageFileError
else:
    from nibabel.spatialimages import ImageFileError


def create_random_image(shape, fname):
    data = np.random.random(shape).astype(np.float32)
    aff  = np.eye(4)
    nib.Nifti1Image(data, aff, None).to_filename(fname)
    return data

def load_image(fname):

    basename = op.basename(fname)[:-7]

    # nibabel pre-2.1 is not indexed_gzip-aware
    if nibver <= Version('2.1.0'):
        fobj = igzip.IndexedGzipFile(fname)
        fmap = nib.Nifti1Image.make_file_map()
        fmap[basename].fileobj = fobj
        image = nib.Nifti1Image.from_file_map(fmap)

    # nibabel 2.2.x, we have to set keep_file_open='auto'
    # to get it to use indexed_gzip
    elif Version('2.2.0') <= nibver < Version('2.3.0'):
        image = nib.load(fname, keep_file_open='auto')

    # nibabel >= 2.3.x uses indexed_gzip automatically
    else:
        image = nib.load(fname)

    return image


# def test_nibabel_integration():
#     with tempdir():

#         data = create_random_image((50, 50, 50, 50), 'image.nii.gz')
#         image = load_image('image.nii.gz')

#         idata = np.asanyarray(image.dataobj)
#         assert np.all(np.isclose(data, idata))
#         assert not image.in_memory

#         if nibver < Version('2.2.0'):
#             assert isinstance(image.file_map['image'].fileobj,
#                               igzip.IndexedGzipFile)
#         else:
#             assert isinstance(image.dataobj._opener.fobj,
#                               igzip.IndexedGzipFile)


# # https://github.com/pauldmccarthy/indexed_gzip/issues/40
# def test_readdata_twice():
#     with tempdir():
#         # the bug only occurs on relatively small images,
#         # where the full index comprises only one or two
#         # index points
#         data = create_random_image((10, 10, 10, 10), 'image.nii.gz')
#         image = load_image('image.nii.gz')

#         d1 = np.asanyarray(image.dataobj)
#         d2 = np.asanyarray(image.dataobj)

#         assert np.all(np.isclose(data, d1))
#         assert np.all(np.isclose(data, d2))


# # https://github.com/pauldmccarthy/indexed_gzip/pull/45
# def test_bad_image_error():

#     if nibver < Version('2.3.0'):
#         return

#     with tempdir():
#         create_random_image((10, 10, 10, 10), 'image.nii.gz')
#         shutil.move('image.nii.gz', 'image.nii')
#         with pytest.raises(ImageFileError):
#             nib.load('image.nii')
#         create_random_image((10, 10, 10, 10), 'image.nii')
#         shutil.move('image.nii', 'image.nii.gz')
#         with pytest.raises(ImageFileError):
#             nib.load('image.nii.gz')
