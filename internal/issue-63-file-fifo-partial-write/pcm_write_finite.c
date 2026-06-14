#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <sys/time.h>

#include "asoundlib.h"

static volatile sig_atomic_t alarm_seen;

static int sample_amplitude(void)
{
	const char *value = getenv("SAMPLE_AMPLITUDE");
	long amplitude;

	if (!value || !*value)
		return 512;
	amplitude = strtol(value, NULL, 0);
	if (amplitude < 1)
		return 1;
	if (amplitude > 32767)
		return 32767;
	return (int)amplitude;
}

static void alarm_handler(int sig ATTRIBUTE_UNUSED)
{
	alarm_seen = 1;
}

static int arm_drain_alarm_from_env(void)
{
	const char *value = getenv("DRAIN_ALARM_USEC");
	struct sigaction sa;
	struct itimerval timer;
	unsigned long usec;

	if (!value || !*value)
		return 0;

	usec = strtoul(value, NULL, 0);
	if (!usec)
		return 0;

	memset(&sa, 0, sizeof(sa));
	sa.sa_handler = alarm_handler;
	sigemptyset(&sa.sa_mask);
	if (sigaction(SIGALRM, &sa, NULL) < 0) {
		perror("sigaction");
		return -1;
	}

	memset(&timer, 0, sizeof(timer));
	timer.it_value.tv_sec = (time_t)(usec / 1000000);
	timer.it_value.tv_usec = (suseconds_t)(usec % 1000000);
	if (setitimer(ITIMER_REAL, &timer, NULL) < 0) {
		perror("setitimer");
		return -1;
	}

	return 0;
}

static snd_pcm_format_t pcm_format_from_env(void)
{
	const char *value = getenv("PCM_FORMAT");

	if (value && strcmp(value, "S32_LE") == 0)
		return SND_PCM_FORMAT_S32_LE;
	return SND_PCM_FORMAT_S16_LE;
}

static size_t sample_bytes_for_format(snd_pcm_format_t format)
{
	return snd_pcm_format_physical_width(format) / 8;
}

static void fill_buffer(void *buffer, size_t frames, unsigned int channels,
			unsigned int seed, snd_pcm_format_t format)
{
	size_t frame;
	unsigned int ch;
	int amplitude = sample_amplitude();
	unsigned int span = (unsigned int)amplitude * 2 + 1;

	for (frame = 0; frame < frames; frame++) {
		for (ch = 0; ch < channels; ch++) {
			int value = (int)((seed + frame * 31 + ch * 997) % span) -
				    amplitude;
			if (format == SND_PCM_FORMAT_S32_LE)
				((int32_t *)buffer)[frame * channels + ch] =
					(int32_t)value << 16;
			else
				((int16_t *)buffer)[frame * channels + ch] =
					(int16_t)value;
		}
	}
}

int main(int argc, char **argv)
{
	const char *device = argc > 1 ? argv[1] : "default";
	unsigned int rate = argc > 2 ? (unsigned int)strtoul(argv[2], NULL, 0) : 48000;
	unsigned int channels = argc > 3 ? (unsigned int)strtoul(argv[3], NULL, 0) : 2;
	snd_pcm_uframes_t frames_per_write =
		argc > 4 ? (snd_pcm_uframes_t)strtoul(argv[4], NULL, 0) : 1024;
	unsigned int iterations = argc > 5 ? (unsigned int)strtoul(argv[5], NULL, 0) : 256;
	snd_pcm_format_t format = pcm_format_from_env();
	size_t sample_bytes = sample_bytes_for_format(format);
	snd_pcm_t *pcm = NULL;
	void *buffer;
	size_t sample_count;
	unsigned int iter;
	snd_pcm_sframes_t total = 0;
	int err;

	sample_count = (size_t)frames_per_write * channels;
	buffer = calloc(sample_count, sample_bytes);
	if (!buffer) {
		fprintf(stderr, "alloc failed\n");
		return EXIT_FAILURE;
	}

	err = snd_pcm_open(&pcm, device, SND_PCM_STREAM_PLAYBACK, 0);
	if (err < 0) {
		fprintf(stderr, "snd_pcm_open(%s): %s\n", device, snd_strerror(err));
		free(buffer);
		return EXIT_FAILURE;
	}

	err = snd_pcm_set_params(pcm, format,
				 SND_PCM_ACCESS_RW_INTERLEAVED,
				 channels, rate, 1, 500000);
	if (err < 0) {
		fprintf(stderr, "snd_pcm_set_params: %s\n", snd_strerror(err));
		snd_pcm_close(pcm);
		free(buffer);
		return EXIT_FAILURE;
	}

	for (iter = 0; iter < iterations; iter++) {
		snd_pcm_uframes_t remaining = frames_per_write;
		char *ptr = buffer;

		fill_buffer(buffer, frames_per_write, channels, iter, format);
		while (remaining > 0) {
			snd_pcm_sframes_t written = snd_pcm_writei(pcm, ptr, remaining);
			if (written < 0)
				written = snd_pcm_recover(pcm, written, 0);
			if (written < 0) {
				fprintf(stderr, "snd_pcm_writei: %s\n",
					snd_strerror(written));
				snd_pcm_close(pcm);
				free(buffer);
				return EXIT_FAILURE;
			}
			remaining -= (snd_pcm_uframes_t)written;
			ptr += written * channels * sample_bytes;
			total += written;
		}
	}

	if (arm_drain_alarm_from_env() < 0) {
		snd_pcm_close(pcm);
		free(buffer);
		return EXIT_FAILURE;
	}

	err = snd_pcm_drain(pcm);
	if (err < 0) {
		fprintf(stderr, "snd_pcm_drain: %s\n", snd_strerror(err));
		snd_pcm_close(pcm);
		free(buffer);
		return EXIT_FAILURE;
	}

	snd_pcm_close(pcm);
	free(buffer);
	printf("frames=%ld bytes=%ld format=%s alarm_seen=%d\n", (long)total,
	       (long)(total * channels * sample_bytes), snd_pcm_format_name(format),
	       alarm_seen ? 1 : 0);
	return EXIT_SUCCESS;
}
