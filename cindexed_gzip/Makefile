# Build the cindexed_gzip C library.
#
# The library can be built in one of the following ways:
#   - Dynamically linked against the system zlib installation (default)
#   - Statically linked against a zlib build at $ZLIB_HOME
#   - Statically linked against a zlib-ng build at $ZLIB_NG_HOME

all: libcindexed_gzip.so libcindexed_gzip_static.a

AR                      ?= ar
CC                      ?= gcc
PYTHON                  ?= python
LIBS                     =
OBJFILES                 = zran.o zran_file_util.o cindexed_gzip.o
PYTHON_INCLUDE_DIRECTORY = $(shell ${PYTHON} -c "from sysconfig import get_paths;  print(get_paths()['include'])")
CFLAGS                  += -I${PYTHON_INCLUDE_DIRECTORY}
INDEXED_GZIP_VERSION     = $(shell cat ../indexed_gzip/__init__.py | grep __version__ | cut -d ' ' -f 3 | tr -d "'")

# statically link against built zlib
ifdef ZLIB_HOME
  OBJFILES +=   ${ZLIB_HOME}/libz.a
  CFLAGS   += -I${ZLIB_HOME}
# statically link against built zlib-ng
else ifdef ZLIB_NG_HOME
  OBJFILES +=   ${ZLIB_NG_HOME}/libz-ng.a
  CFLAGS   += -I${ZLIB_NG_HOME} -DZRAN_USE_ZLIB_NG=1
# dynamically link against system zlib
else
  LIBS     += -lz
endif


clean:
	rm -f *.o *.so *.a cindexed_gzip.h


cindexed_gzip.h: cindexed_gzip.h.in
	sed -e "s/@INDEXED_GZIP_VERSION@/${INDEXED_GZIP_VERSION}/" $< > $@


%.o: %.c cindexed_gzip.h
	${CC} ${CFLAGS} -c -o $@ $<


libcindexed_gzip.so: ${OBJFILES}
	${CC} ${CFLAGS} -shared -o $@ $^ ${LDFLAGS} ${LIBS}


libcindexed_gzip_static.a: ${OBJFILES}
	${AR} -r $@ $^ ${LIBS}


install:
ifndef PREFIX
	@echo "PREFIX not set - aborting"
	exit 1
endif
	mkdir -p ${PREFIX}/lib
	mkdir -p ${PREFIX}/include/cindexed_gzip
	cp libcindexed_gzip.so       ${PREFIX}/lib/
	cp libcindexed_gzip_static.a ${PREFIX}/lib/
	cp cindexed_gzip.h           ${PREFIX}/include/cindexed_gzip/
	cp zran.h                    ${PREFIX}/include/cindexed_gzip/
