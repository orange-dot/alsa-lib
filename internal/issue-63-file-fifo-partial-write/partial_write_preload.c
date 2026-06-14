#define _GNU_SOURCE

#include <dlfcn.h>
#include <errno.h>
#include <stdlib.h>
#include <unistd.h>

typedef ssize_t (*write_fn_t)(int fd, const void *buf, size_t count);

static write_fn_t real_write;

static size_t partial_limit(void)
{
	const char *value = getenv("PARTIAL_WRITE_LIMIT");
	size_t limit;

	if (!value || !*value)
		return 4096;
	limit = (size_t)strtoul(value, NULL, 0);
	return limit ? limit : 4096;
}

ssize_t write(int fd, const void *buf, size_t count)
{
	size_t limit;

	if (!real_write) {
		real_write = (write_fn_t)dlsym(RTLD_NEXT, "write");
		if (!real_write) {
			errno = EIO;
			return -1;
		}
	}

	limit = partial_limit();
	if (count > limit)
		count = limit;
	return real_write(fd, buf, count);
}
