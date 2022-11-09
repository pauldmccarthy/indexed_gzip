/*
 * Simplified C interface for reading GZIP files with indexed_gzip.
 *
 * Both GZIP and other files may be loaded via this interface; GZIP files will
 * be read via the zran module, and other files will read normally.
 */
#ifndef __CINDEXED_GZIP_H__
#define __CINDEXED_GZIP_H__

#ifdef  __cplusplus
extern "C" {
#endif

#include <stdint.h>

#include "zran.h"

/*
 * Struct representing a file which has been loaded via igz_open.
 */
struct _igz_file;
typedef struct _igz_file igz_file;


/*
 * Open a file for reading. GZIP files will be loaded via the zran module.
 * Other files will be read normally (via fseek/fread). The igz_file must be
 * passed to igz_close when it is no longer needed.
 */
igz_file * igz_open(char *filepath);


/*
 * Free resources associated with the igz_file. Must only be called once for
 * a given igz_file.
 */
int igz_close(igz_file *gzf);


/*
 * Read up to len bytes from the given igz_file, starting from off. The bytes
 * are copied into buf.
 *
 * Returns th number of bytes that were read, 0 if off == EOF, or a negative
 * value if an error occurred.
 */
int64_t igz_read(igz_file *gzf, void *buf, uint64_t len, uint64_t off);

#ifdef  __cplusplus
}
#endif

#endif /* __CINDEXED_GZIP_H__ */
