#ifndef PEBREL_SSH_H
#define PEBREL_SSH_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    uint8_t *ptr;
    size_t len;
} PebrelByteSlice;

/* Memory management */
void pebrel_string_free(char *ptr);
void pebrel_bytes_free(uint8_t *ptr, size_t len);
void pebrel_packet_list_free(PebrelByteSlice *items, size_t count);

/* SSH / SFTP / Query */
int64_t pebrel_ssh_create(
    const char *host,
    uint16_t port,
    const char *user,
    const uint8_t *password,
    size_t password_len,
    const char *fingerprint,
    const uint8_t *private_key,
    size_t private_key_len,
    const char **out_error
);

char *pebrel_ssh_next_event(int64_t id, const char **out_error);

bool pebrel_ssh_answer_host_key(
    int64_t id,
    bool accepted,
    const char **out_error
);

bool pebrel_ssh_open_shell(
    int64_t id,
    int32_t columns,
    int32_t rows,
    int32_t width,
    int32_t height,
    const char **out_error
);

bool pebrel_ssh_open_exec(
    int64_t id,
    const char *command,
    const char **out_error
);

bool pebrel_ssh_open_pty_exec(
    int64_t id,
    const char *command,
    int32_t columns,
    int32_t rows,
    int32_t width,
    int32_t height,
    const char **out_error
);

bool pebrel_ssh_query(
    int64_t id,
    const char *command,
    uint8_t **out_ptr,
    size_t *out_len,
    const char **out_error
);

/* Returns >0 bytes read, -1 on EOF, -2 on error (*out_error set). */
int32_t pebrel_ssh_read(
    int64_t id,
    uint8_t *target,
    size_t count,
    bool stderr_stream,
    const char **out_error
);

bool pebrel_ssh_write(
    int64_t id,
    const uint8_t *source,
    size_t count,
    const char **out_error
);

bool pebrel_ssh_resize(
    int64_t id,
    int32_t columns,
    int32_t rows,
    int32_t width,
    int32_t height,
    const char **out_error
);

bool pebrel_ssh_await_exit(
    int64_t id,
    int32_t *out_code,
    const char **out_error
);

char *pebrel_ssh_sftp(
    int64_t id,
    const char *request_json,
    const char **out_error
);

void pebrel_ssh_close(int64_t id);

/* Mobile Link (Noise NKpsk0 E2EE) */
int64_t pebrel_link_create(
    const uint8_t *host_pub,
    size_t host_len,
    const uint8_t *secret,
    size_t secret_len,
    const uint8_t *context,
    size_t context_len,
    const char **out_error
);

bool pebrel_link_hello(
    int64_t id,
    uint8_t **out_ptr,
    size_t *out_len,
    const char **out_error
);

bool pebrel_link_finish(
    int64_t id,
    const uint8_t *response,
    size_t response_len,
    bool *out_established,
    const char **out_error
);

char *pebrel_link_verification_code(int64_t id, const char **out_error);

bool pebrel_link_seal(
    int64_t id,
    const uint8_t *plaintext,
    size_t plaintext_len,
    PebrelByteSlice **out_packets,
    size_t *out_count,
    const char **out_error
);

bool pebrel_link_open(
    int64_t id,
    const uint8_t *ciphertext,
    size_t ciphertext_len,
    uint8_t **out_ptr,
    size_t *out_len,
    const char **out_error
);

void pebrel_link_close(int64_t id);

#ifdef __cplusplus
}
#endif

#endif /* PEBREL_SSH_H */
