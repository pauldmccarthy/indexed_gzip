#!/usr/bin/env bash

set -e

# prevent any prompts when
# apt/yum installing tzdata
export DEBIAN_FRONTEND="noninteractive"
export TZ="Europe/London"

# Make sure zlib headers are available on linux
export CIBW_BEFORE_ALL_LINUX="yum install -y zlib-devel || apt-get install -y zlib1g-dev || apk add zlib-dev || true"

# ZLIB is compiled into indexed_gzip on windwos -
# see .ci/download_zlib.sh and setup.py
export CIBW_ENVIRONMENT_WINDOWS="ZLIB_HOME='$ZLIB_HOME'"

# Run quick test suite on built wheels.
export CIBW_TEST_REQUIRES="cython pytest numpy nibabel coverage pytest-cov"

# Skip i686 and aarch64 tests:
#
#  - I have experienced hangs on these platforms,
#    which I traced to a trivial numpy operation -
#    "numpy.linalg.det(numpy.eye(3))".
#
#  - Numpy wheels are not available for these
#    platforms for all pyvers, so has to be compiled
#    from source during the build, which massively
#    increases build time and complexity.

# Skip windows tests for some python versions:
#
#  - Some tests fail in the GHA Windows environment
#    for certain Python versions. I don't know why,
#    as the tests pass for the same Python versions
#    in other environments. I don't have easy access
#    to a Windows machine to try and reproduce this
#    locally, so am disabling them for the time
#    being.
#
export CIBW_TEST_SKIP="*i686* *aarch64* cp312-win* cp313-win* cp313t-win*"

# Pytest makes it *very* awkward to run tests
# from an installed package, and still find/
# interpret a conftest.py file correctly.
echo '#!/usr/bin/env bash'                                                                           >  testcmd
echo 'cp $1/pyproject.toml .'                                                                        >> testcmd
echo 'python -m indexed_gzip.tests -c pyproject.toml --no-cov -m "not slow_test" -k "not test_zran"' >> testcmd
chmod a+x testcmd

export CIBW_TEST_COMMAND="bash {project}/testcmd {project}"

python -m pip install --upgrade pip
python -m pip install --upgrade setuptools
python -m pip install cibuildwheel
python -m cibuildwheel --output-dir ./dist
