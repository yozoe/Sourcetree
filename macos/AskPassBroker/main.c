#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

enum {
  kNonceLength = 64,
  kMaxFrameLength = 16 * 1024,
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
    const char character = nonce[index];
    if (!((character >= '0' && character <= '9') ||
          (character >= 'a' && character <= 'f'))) {
      return 0;
    }
  }
  return 1;
}

static int read_line(int fd, char *buffer, size_t capacity) {
  size_t length = 0;
  while (length + 1 < capacity) {
    const ssize_t read_count = read(fd, buffer + length, 1);
    if (read_count <= 0) return -1;
    if (buffer[length++] == '\n') {
      buffer[length - 1] = '\0';
      return 0;
    }
  }
  return -1;
}

int main(int argc, char *argv[]) {
  const char *socket_path = argc == 3 ? argv[1] : NULL;
  const char *nonce = argc == 3 ? argv[2] : NULL;
  if (socket_path == NULL || socket_path[0] != '/' ||
      strlen(socket_path) >= sizeof(((struct sockaddr_un *)0)->sun_path) ||
      !is_valid_nonce(nonce)) {
    return 1;
  }

  const int server_fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (server_fd < 0) return 1;
  struct sockaddr_un address;
  memset(&address, 0, sizeof(address));
  address.sun_family = AF_UNIX;
  memcpy(address.sun_path, socket_path, strlen(socket_path) + 1);
  if (bind(server_fd, (const struct sockaddr *)&address, sizeof(address)) != 0 ||
      chmod(socket_path, 0600) != 0 || listen(server_fd, 1) != 0 ||
      write_all(STDOUT_FILENO, "READY\n", 6) != 0) {
    close(server_fd);
    unlink(socket_path);
    return 1;
  }

  alarm(60);
  const int client_fd = accept(server_fd, NULL, NULL);
  uid_t peer_uid = 0;
  gid_t peer_gid = 0;
  if (client_fd < 0 || getpeereid(client_fd, &peer_uid, &peer_gid) != 0 ||
      peer_uid != geteuid()) {
    if (client_fd >= 0) close(client_fd);
    close(server_fd);
    unlink(socket_path);
    return 1;
  }

  char request[kMaxFrameLength + 1];
  char response[kMaxFrameLength + 1];
  const int success = read_line(client_fd, request, sizeof(request)) == 0 &&
      write_all(STDOUT_FILENO, request, strlen(request)) == 0 &&
      write_all(STDOUT_FILENO, "\n", 1) == 0 &&
      read_line(STDIN_FILENO, response, sizeof(response)) == 0 &&
      write_all(client_fd, response, strlen(response)) == 0 &&
      write_all(client_fd, "\n", 1) == 0;
  memset(response, 0, sizeof(response));
  close(client_fd);
  close(server_fd);
  unlink(socket_path);
  return success ? 0 : 1;
}
