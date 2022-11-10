/*
 * Simplified C interface for reading GZIP files with indexed_gzip.
 *
 * Both GZIP and other files may be loaded via this interface; GZIP files will
 * be read via the zran module, and other files will read normally.
 */
#include <string.h>
#include <stdint.h>

#include "cindexed_gzip/zran.h"
#include "cindexed_gzip/cindexed_gzip.h"


/*
 * igz_file struct, for reading from a GZIP or other file. File handle is
 * opened/closed on-demand.
 */
struct _igz_file {
  zran_index_t index;
  int          compressed;
  char        *filepath;
};


/*
 * Returns 1 if the given file is a GZIP file, 0 if it is not, -1 if an error
 * occurs.
 *
 * https://www.rfc-editor.org/rfc/rfc1952#section-2.3.1
 */

static int is_gzip_file(FILE *f) {

    uint8_t magic[2];

    if (fseek(f, 0, SEEK_SET) != 0) { goto fail; }
    if (fread(magic, 1, 2, f) != 2) { goto fail; }
    if (fseek(f, 0, SEEK_SET) != 0) { goto fail; }

    if (magic[0] == 0x1f && magic[1] == 0x8b) { return 1; }
    else                                      { return 0; }
fail:
    return -1;
};


/*
 * Returns the size of the given file.
 */
static uint64_t file_size(FILE *f) {

    size_t s;
    if (fseek(f, 0, SEEK_END) != 0) { goto fail; }

    s = ftello(f);

    if (s < 0)                      { goto fail; }
    if (fseek(f, 0, SEEK_SET) != 0) { goto fail; }

    return (uint64_t)s;
fail:
    return -1;
}


/*
 * Open a file for reading. GZIP files will be loaded via the zran module.
 * Other files will be read normally (via fseek/fread). The igz_file must be
 * passed to igz_close when it is no longer needed.
 */
igz_file * igz_open(const char *filepath) {

    igz_file *gzf     = NULL;
    FILE     *f       = NULL;
    size_t    namelen = 0;
    off_t     size    = 0;

    f = fopen(filepath, "rb");
    if (f == NULL) {
        goto fail;
    }

    gzf = calloc(1, sizeof(igz_file));
    if (gzf == NULL) {
        goto fail;
    }

    namelen       = strlen(filepath);
    gzf->filepath = malloc(namelen + 1);
    strcpy(gzf->filepath, filepath);

    gzf->compressed = is_gzip_file(f);
    if (gzf->compressed == -1) {
        goto fail;
    }

    if (gzf->compressed) {
        if (zran_init(&(gzf->index), f, NULL, 4194304,
                      32768, 1048576, ZRAN_AUTO_BUILD) != 0) {
            goto fail;
        }
        gzf->index.fd = NULL;
    }

    fclose(f);

    return gzf;

 fail:
    if (gzf != NULL) { free(gzf); }
    if (f   != NULL) { fclose(f); }
    return NULL;
}


/*
 * Free resources associated with the igz_file. Must only be called once for
 * a given igz_file.
 */
int igz_close(igz_file *gzf) {
    if (gzf->compressed) {
        zran_free(&(gzf->index));
    }
    free(gzf->filepath);
    free(gzf);
}

/*
 * Read up to len bytes from the given igz_file, starting from off. The bytes
 * are copied into buf.
 *
 * Returns th number of bytes that were read, 0 if off == EOF, or a negative
 * value if an error occurred.
 */
int64_t igz_read(igz_file *gzf, void *buf, uint64_t len, uint64_t off) {

    FILE *f            = NULL;
    int64_t bytes_read = 0;

    if (len > INT64_MAX) {
        goto fail;
    }

    f = fopen(gzf->filepath, "rb");
    if (f == NULL) {
        goto fail;
    }

    if (gzf->compressed) {
        gzf->index.fd = f;
        if (zran_seek(&(gzf->index), off, SEEK_SET, NULL) != ZRAN_SEEK_OK) {
            goto fail;
        }

        bytes_read = zran_read(&(gzf->index), buf, len);
        if (bytes_read == ZRAN_READ_EOF) {
            goto fail;
        }
    }
    else {
        fseek(f, off, SEEK_SET);
        fread(buf, len, 1, f);
    }

    gzf->index.fd = NULL;
    fclose(f);

    return bytes_read;

fail:
    if (f != NULL) {
        fclose(f);
    }
    return -1;
}
