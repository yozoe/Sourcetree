#include <ctype.h>
#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/un.h>
#include <unistd.h>

enum {
  kNonceLength = 64,
  kMaxPromptLength = 8 * 1024,
  kMaxResponseLength = 16 * 1024,
};

static int write_all(int fd, const char *bytes, size_t length) {
  while (length > 0) {
    const ssize_t written = write(fd, bytes, length);
    if (written <= 0) return -1;
    bytes += written;
    length -= (size_t)written;
  }
  return 0;
}

static int is_valid_nonce(const char *nonce) {
  if (nonce == NULL || strlen(nonce) != kNonceLength) return 0;
  for (size_t index = 0; index < kNonceLength; ++index) {
    if (!isxdigit((unsigned char)nonce[index])) return 0;
  }
  return 1;
}

static int is_private_current_user_socket(const char *socket_path) {
  struct stat socket_stat;
  if (lstat(socket_path, &socket_stat) != 0 || !S_ISSOCK(socket_stat.st_mode) ||
      socket_stat.st_uid != geteuid() || (socket_stat.st_mode & 0777) != 0600) {
    return 0;
  }
  return 1;
}

static int write_json_string(int fd, const char *value) {
  if (write_all(fd, "\"", 1) != 0) return -1;
  for (const unsigned char *cursor = (const unsigned char *)value;
       *cursor != '\0'; ++cursor) {
    switch (*cursor) {
      case '"':
        if (write_all(fd, "\\\"", 2) != 0) return -1;
        break;
      case '\\':
        if (write_all(fd, "\\\\", 2) != 0) return -1;
        break;
      case '\b':
        if (write_all(fd, "\\b", 2) != 0) return -1;
        break;
      case '\f':
        if (write_all(fd, "\\f", 2) != 0) return -1;
        break;
      case '\n':
        if (write_all(fd, "\\n", 2) != 0) return -1;
        break;
      case '\r':
        if (write_all(fd, "\\r", 2) != 0) return -1;
        break;
      case '\t':
        if (write_all(fd, "\\t", 2) != 0) return -1;
        break;
      default:
        if (*cursor < 0x20 || write_all(fd, (const char *)cursor, 1) != 0) {
          return -1;
        }
    }
  }
  return write_all(fd, "\"", 1);
}

static int send_request(int fd, const char *nonce, const char *prompt) {
  if (write_all(fd, "{\"nonce\":", 9) != 0 ||
      write_json_string(fd, nonce) != 0 ||
      write_all(fd, ",\"prompt\":", 10) != 0 ||
      write_json_string(fd, prompt) != 0) {
    return -1;
  }
  return write_all(fd, "}\n", 2);
}

static int read_response(int fd, char *buffer, size_t capacity) {
  size_t length = 0;
  while (length + 1 < capacity) {
    const ssize_t read_count = read(fd, buffer + length, 1);
    if (read_count <= 0) return -1;
    if (buffer[length++] == '\n') break;
  }
  if (length == capacity - 1 && buffer[length - 1] != '\n') return -1;
  if (length > 0 && buffer[length - 1] == '\n') --length;
  buffer[length] = '\0';
  return 0;
}

static int parse_secret_response(char *response, char **secret) {
  const char *prefix = "{\"secret\":\"";
  const size_t prefix_length = strlen(prefix);
  const size_t response_length = strlen(response);
  if (response_length < prefix_length + 2 ||
      strncmp(response, prefix, prefix_length) != 0 ||
      response[response_length - 2] != '"' ||
      response[response_length - 1] != '}') {
    return -1;
  }

  char *input = response + prefix_length;
  char *output = input;
  char *end = response + response_length - 2;
  while (input < end) {
    if (*input != '\\') {
      if ((unsigned char)*input < 0x20) return -1;
      *output++ = *input++;
      continue;
    }
    if (++input >= end) return -1;
    switch (*input++) {
      case '"': *output++ = '"'; break;
      case '\\': *output++ = '\\'; break;
      case '/': *output++ = '/'; break;
      case 'b': *output++ = '\b'; break;
      case 'f': *output++ = '\f'; break;
      case 'n': *output++ = '\n'; break;
      case 'r': *output++ = '\r'; break;
      case 't': *output++ = '\t'; break;
      default: return -1;
    }
  }
  *output = '\0';
  *secret = response + prefix_length;
  return 0;
}

int main(int argc, char *argv[]) {
  const char *socket_path = getenv("GIT_DESKTOP_ASKPASS_SOCKET");
  const char *nonce = getenv("GIT_DESKTOP_ASKPASS_NONCE");
  const char *timeout_value = getenv("GIT_DESKTOP_ASKPASS_TIMEOUT_SECONDS");
  char *timeout_end = NULL;
  const unsigned long parsed_timeout =
      timeout_value == NULL ? 0 : strtoul(timeout_value, &timeout_end, 10);
  const char *prompt = argc == 2 ? argv[1] : NULL;
  if (socket_path == NULL || socket_path[0] != '/' ||
      strlen(socket_path) >= sizeof(((struct sockaddr_un *)0)->sun_path) ||
      !is_valid_nonce(nonce) || timeout_value == NULL ||
      timeout_end == timeout_value || *timeout_end != '\0' ||
      parsed_timeout == 0 || parsed_timeout > UINT_MAX ||
      prompt == NULL || prompt[0] == '\0' ||
      strlen(prompt) > kMaxPromptLength ||
      !is_private_current_user_socket(socket_path)) {
    fputs("AskPass is unavailable.\n", stderr);
    return 1;
  }

  const int socket_fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (socket_fd < 0) return 1;
  struct timeval timeout = {.tv_sec = (time_t)parsed_timeout, .tv_usec = 0};
  (void)setsockopt(socket_fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
  (void)setsockopt(socket_fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));

  struct sockaddr_un address;
  memset(&address, 0, sizeof(address));
  address.sun_family = AF_UNIX;
  memcpy(address.sun_path, socket_path, strlen(socket_path) + 1);
  uid_t peer_uid = 0;
  gid_t peer_gid = 0;
  if (connect(socket_fd, (const struct sockaddr *)&address, sizeof(address)) != 0 ||
      getpeereid(socket_fd, &peer_uid, &peer_gid) != 0 ||
      peer_uid != geteuid() ||
      send_request(socket_fd, nonce, prompt) != 0) {
    close(socket_fd);
    return 1;
  }

  char response[kMaxResponseLength + 1];
  char *secret = NULL;
  const int success = read_response(socket_fd, response, sizeof(response)) == 0 &&
      parse_secret_response(response, &secret) == 0 &&
      write_all(STDOUT_FILENO, secret, strlen(secret)) == 0 &&
      write_all(STDOUT_FILENO, "\n", 1) == 0;
  memset(response, 0, sizeof(response));
  close(socket_fd);
  return success ? 0 : 1;
}
