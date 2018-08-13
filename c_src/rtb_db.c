/********************************************************************
 * Copyright (c) 2012-2018 ProcessOne, SARL. All Rights Reserved.
 *
 * All rights reserved. This program and the accompanying materials
 * are made available under the terms of the Eclipse Public License v1.0
 * and Eclipse Distribution License v1.0 which accompany this distribution.
 *
 * The Eclipse Public License is available at
 *  http://www.eclipse.org/legal/epl-v10.html
 * and the Eclipse Distribution License is available at
 *  http://www.eclipse.org/org/documents/edl-v10.php.
 *
 * Contributors:
 *  Evgeny Khramtsov - initial implementation and documentation.
 *  Roger Light - implementation of password encryption from
 *                Eclipse Mosquitto project: https://mosquitto.org
 *******************************************************************/
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <getopt.h>
#include <sys/stat.h>
#include <openssl/evp.h>
#include <openssl/rand.h>
#include <openssl/buffer.h>

#define BUFSIZE 65535
#define SALT_LEN 12
#define VERSION "0.1.0"

#define USERS_CSV_FILE "/tmp/users.csv"
#define ROSTERS_CSV_FILE "/tmp/rosters.csv"
#define PASSWD_FILE "/tmp/passwd"
#define USERS_DIR "/tmp/accounts/"
#define ROSTERS_DIR "/tmp/roster/"

typedef enum {T_EJABBERD = 1,
              T_METRONOME,
              T_MOSQUITTO,
              T_PROSODY} server_type;
typedef enum {T_CSV = 1, T_FLAT} file_type;

typedef struct {
  char *server;
  server_type server_type;
  file_type file_type;
  int capacity;
  char *user;
  char *domain;
  char *password;
  int roster_size;
} state_t;

char *timestamp() {
  return "1970-01-01 00:00:00";
}

char *format_server_type(server_type t) {
  switch (t) {
  case T_EJABBERD: return "ejabberd";
  case T_METRONOME: return "Metronome";
  case T_PROSODY: return "Prosody";
  case T_MOSQUITTO: return "Mosquitto";
  }
  abort();
}

void replace(char *dst, const char *src, const char c, const char *str) {
  int len = strlen(src);
  memset(dst, 0, BUFSIZE);
  int i = 0, j = 0;
  while (i<len) {
    if (src[i] == c) {
      strcpy(dst+j, str);
      j += strlen(str);
    } else {
      dst[j++] = src[i];
    }
    i++;
  }
}

int base64_encode(unsigned char *in, unsigned int in_len, char **encoded)
{
  BIO *bmem, *b64;
  BUF_MEM *bptr;

  b64 = BIO_new(BIO_f_base64());
  BIO_set_flags(b64, BIO_FLAGS_BASE64_NO_NL);
  bmem = BIO_new(BIO_s_mem());
  b64 = BIO_push(b64, bmem);
  BIO_write(b64, in, in_len);
  if(BIO_flush(b64) != 1){
    BIO_free_all(b64);
    return -1;
  }
  BIO_get_mem_ptr(b64, &bptr);
  *encoded = malloc(bptr->length+1);
  if(!(*encoded)){
    BIO_free_all(b64);
    return -1;
  }
  memcpy(*encoded, bptr->data, bptr->length);
  (*encoded)[bptr->length] = '\0';
  BIO_free_all(b64);

  return 0;
}

int encrypt_password(char *buf, const char *password)
{
  int res;
  unsigned char salt[SALT_LEN];
  char *salt64 = NULL, *hash64 = NULL;
  unsigned char hash[EVP_MAX_MD_SIZE];
  unsigned int hash_len;
  const EVP_MD *digest;
#if OPENSSL_VERSION_NUMBER < 0x10100000L
  EVP_MD_CTX context;
#else
  EVP_MD_CTX *context;
#endif
  res = RAND_bytes(salt, SALT_LEN);
  if (!res) {
    fprintf(stderr, "Insufficient entropy available to perform password generation.\n");
    return -1;
  }
  res = base64_encode(salt, SALT_LEN, &salt64);
  if (res) {
    fprintf(stderr, "Unable to encode salt.\n");
    return -1;
  }
  digest = EVP_get_digestbyname("sha512");
  if (!digest) {
    fprintf(stderr, "Unable to create openssl digest.\n");
    return -1;
  }
#if OPENSSL_VERSION_NUMBER < 0x10100000L
  EVP_MD_CTX_init(&context);
  EVP_DigestInit_ex(&context, digest, NULL);
  EVP_DigestUpdate(&context, password, strlen(password));
  EVP_DigestUpdate(&context, salt, SALT_LEN);
  EVP_DigestFinal_ex(&context, hash, &hash_len);
  EVP_MD_CTX_cleanup(&context);
#else
  context = EVP_MD_CTX_new();
  EVP_DigestInit_ex(context, digest, NULL);
  EVP_DigestUpdate(context, password, strlen(password));
  EVP_DigestUpdate(context, salt, SALT_LEN);
  EVP_DigestFinal_ex(context, hash, &hash_len);
  EVP_MD_CTX_free(context);
#endif
  res = base64_encode(hash, hash_len, &hash64);
  if (res) {
    fprintf(stderr, "Unable to encode hash.\n");
    return -1;
  }
  sprintf(buf, "$6$%s$%s", salt64, hash64);
  free(salt64);
  free(hash64);
  return 0;
}

void mk_user_csv_row(char *row, state_t *state) {
  char *user = state->user;
  char *domain = state->domain;
  char *password = state->password;
  char buf[BUFSIZE];
  memset(buf, 0, BUFSIZE);
  sprintf(buf, "\"%s\",\"%s\",\"%s\",\"\",\"\",\"0\",\"%s\"\n", user, domain, password, timestamp());
  replace(row, buf, '%', "%lu");
}

void mk_roster_csv_row(char *row, state_t *state) {
  char *user = state->user;
  char *domain = state->domain;
  char buf[BUFSIZE];
  sprintf(buf,
          "\"%s\",\"%s\",\"%s@%s\",\"%s\",\"B\",\"N\",\"\",\"N\",\"\",\"item\",\"%s\"\n",
          user, domain, user, domain, user, timestamp());
  replace(row, buf, '%', "%lu");
}

void mk_user_dat(char *data, state_t *state) {
  char *password = state->password;
  char buf[BUFSIZE];
  sprintf(buf, "return {\n\t[\"password\"] = \"%s\";\n};\n", password);
  replace(data, buf, '%', "%lu");
}

void mk_roster_dat(char *data, state_t *state) {
  char *user = state->user;
  char *domain = state->domain;
  char buf[BUFSIZE];
  sprintf(buf, "\t[\"%s@%s\"] = {\n"
          "\t\t[\"subscription\"] = \"both\";\n"
          "\t\t[\"groups\"] = {};\n"
          "\t\t[\"name\"] = \"%s\";\n"
          "\t};\n",
          user, domain, user);
  replace(data, buf, '%', "%lu");
}

int generate_users_csv(state_t *state) {
  FILE *fd = fopen(USERS_CSV_FILE, "w");
  if (!fd) {
    fprintf(stderr, "Failed to open file %s for writing: %s\n",
            USERS_CSV_FILE, strerror(errno));
    return errno;
  }

  printf("Generating %s... ", USERS_CSV_FILE);
  fflush(stdout);
  char row[BUFSIZE];
  int i;
  mk_user_csv_row(row, state);
  for (i=1; i<=state->capacity; i++) {
    if (fprintf(fd, row, i, i) < 0) {
      fprintf(stderr, "Failed to write to file %s: %s\n",
              USERS_CSV_FILE, strerror(errno));
      return errno;
    }
  }
  printf("done\n");
  return 0;
}

int generate_rosters_csv(state_t *state) {
  if (!state->roster_size)
    return 0;

  FILE *fd = fopen(ROSTERS_CSV_FILE, "w");
  if (!fd) {
    fprintf(stderr, "Failed to open file %s for writing: %s\n",
            ROSTERS_CSV_FILE, strerror(errno));
    return errno;
  }

  printf("Generating %s... ", ROSTERS_CSV_FILE);
  fflush(stdout);
  int i, j, next, prev;
  char row[BUFSIZE];
  mk_roster_csv_row(row, state);
  int roster_size = state->roster_size/2;
  for (i=1; i<=state->capacity; i++) {
    for (j=1; j<=roster_size; j++) {
      next = i + j;
      next = (next > state->capacity) ? (next % state->capacity): next;
      prev = (i <= j) ? state->capacity - (j - 1) : i-j;
      if ((fprintf(fd, row, i, next, next) < 0) ||
          (fprintf(fd, row, i, prev, prev) < 0)) {
        fprintf(stderr, "Failed to write to file %s: %s\n",
                ROSTERS_CSV_FILE, strerror(errno));
        return errno;
      }
    }
  }
  printf("done\n");
  return 0;
}

int generate_user_files(state_t *state) {
  int res = mkdir(USERS_DIR, 0755);
  if (res && errno != EEXIST) {
    fprintf(stderr, "Failed to create directory %s: %s\n", USERS_DIR, strerror(errno));
    return errno;
  }

  printf("Generating accounts in %s... ", USERS_DIR);
  fflush(stdout);
  int i;
  FILE *fd;
  int dir_len = strlen(USERS_DIR);
  char password[BUFSIZE];
  char user[BUFSIZE];
  char file[BUFSIZE];
  mk_user_dat(password, state);
  replace(user, state->user, '%', "%lu");
  memset(file, 0, BUFSIZE);
  strcpy(user+strlen(user), ".dat");
  strcpy(file, USERS_DIR);
  for (i=1; i<=state->capacity; i++) {
    sprintf(file+dir_len, user, i);
    fd = fopen(file, "w");
    if (!fd) {
      fprintf(stderr, "Failed to open file %s for writing: %s\n", file, strerror(errno));
      return errno;
    }
    if (fprintf(fd, password, i) < 0) {
      fprintf(stderr, "Failed to write to file %s: %s\n", file, strerror(errno));
      return errno;
    }
    fclose(fd);
  }
  printf("done\n");
  return 0;
}

int generate_roster_files(state_t *state) {
  if (!state->roster_size)
    return 0;

  int res = mkdir(ROSTERS_DIR, 0755);
  if (res && errno != EEXIST) {
    fprintf(stderr, "Failed to create directory %s: %s\n", ROSTERS_DIR, strerror(errno));
    return errno;
  }

  printf("Generating rosters in %s... ", ROSTERS_DIR);
  fflush(stdout);
  int i, j, next, prev;
  FILE *fd;
  int dir_len = strlen(ROSTERS_DIR);
  char roster[BUFSIZE];
  char user[BUFSIZE];
  char file[BUFSIZE];
  int roster_size = state->roster_size/2;
  mk_roster_dat(roster, state);
  replace(user, state->user, '%', "%lu");
  memset(file, 0, BUFSIZE);
  strcpy(user+strlen(user), ".dat");
  strcpy(file, ROSTERS_DIR);
  for (i=1; i<=state->capacity; i++) {
    sprintf(file+dir_len, user, i);
    fd = fopen(file, "w");
    if (!fd) {
      fprintf(stderr, "Failed to open file %s for writing: %s\n", file, strerror(errno));
      return errno;
    }
    if (fprintf(fd,
                "return {\n\t[false] = {\n\t\t[\"version\"] = 1;\n"
                "\t\t[\"pending\"] = {};\n\t};\n") < 0) {
      fprintf(stderr, "Failed to write to file %s: %s\n", file, strerror(errno));
      return errno;
    }
    for (j=1; j<=roster_size; j++) {
      next = i + j;
      next = (next > state->capacity) ? (next % state->capacity): next;
      prev = (i <= j) ? state->capacity - (j - 1) : i-j;
      if ((fprintf(fd, roster, next, next) < 0) ||
          (fprintf(fd, roster, prev, prev) < 0)) {
        fprintf(stderr, "Failed to write to file %s: %s\n", file, strerror(errno));
        return errno;
      }
    }
    if (fprintf(fd, "};\n") < 0) {
      fprintf(stderr, "Failed to write to file %s: %s\n", file, strerror(errno));
      return errno;
    }
    fclose(fd);
  }
  printf("done\n");
  return 0;
}

int generate_passwd(state_t *state) {
  int i, res;
  FILE *fd = fopen(PASSWD_FILE, "w");
  if (!fd) {
    fprintf(stderr, "Failed to open file %s for writing: %s\n",
            PASSWD_FILE, strerror(errno));
    return errno;
  }

  printf("Generating %s... ", PASSWD_FILE);
  fflush(stdout);
  char user[BUFSIZE];
  char password[BUFSIZE];
  char buf1[BUFSIZE];
  char buf2[BUFSIZE];
  replace(user, state->user, '%', "%lu");
  replace(password, state->password, '%', "%lu");
  for (i=1; i<=state->capacity; i++) {
    sprintf(buf1, password, i);
    if ((res = encrypt_password(buf2, buf1)))
      return res;
    if (fprintf(fd, user, i) < 0 ||
        fprintf(fd, ":%s\n", buf2) < 0) {
      fprintf(stderr, "Failed to write to file %s: %s\n", PASSWD_FILE, strerror(errno));
      return errno;
    }
  }
  printf("done\n");
  return 0;
}

void print_hint(state_t *state) {
  int have_rosters = state->roster_size;
  if (state->file_type == T_CSV) {
    char *mysql_cmd =
      " LOAD DATA LOCAL INFILE '%s'\n"
      "   INTO TABLE %s FIELDS TERMINATED BY ','\n"
      "   ENCLOSED BY '\"' LINES TERMINATED BY '\\n';\n";
    char *pgsql_cmd = " \\copy %s FROM '%s' WITH CSV QUOTE AS '\"';\n";
    char *sqlite_cmd = ".import '%s' %s\n";

    printf("Now execute the following SQL commands:\n");
    printf("** MySQL:\n");
    printf(mysql_cmd, USERS_CSV_FILE, "users");
    if (have_rosters)
      printf(mysql_cmd, ROSTERS_CSV_FILE, "rosterusers");
    printf("** PostgreSQL:\n");
    printf(pgsql_cmd, "users", USERS_CSV_FILE);
    if (have_rosters)
      printf(pgsql_cmd, "rosterusers", ROSTERS_CSV_FILE);
    printf("** SQLite: \n");
    printf(".mode csv\n");
    printf(sqlite_cmd, USERS_CSV_FILE, "users");
    if (have_rosters)
      printf(sqlite_cmd, ROSTERS_CSV_FILE, "rosterusers");
  } else if (state->server_type == T_MOSQUITTO) {
    printf("Now set 'password_file' option of mosquitto.conf "
           "pointing to %s. Something like:\n"
           " echo 'allow_anonymous false' >> /etc/mosquitto/mosquitto.conf\n"
           " echo 'password_file /tmp/passwd' >> /etc/mosquitto/mosquitto.conf\n",
           PASSWD_FILE);
  } else {
    char domain[BUFSIZE];
    replace(domain, state->domain, '.', "%2e");
    printf("Now copy %s and %s into %s spool directory. Something like:\n"
           " sudo rm -rf /var/lib/%s/%s/accounts\n"
           " sudo rm -rf /var/lib/%s/%s/roster\n"
           " sudo mv %s /var/lib/%s/%s/\n"
           " sudo mv %s /var/lib/%s/%s/\n"
           " sudo chown %s:%s -R /var/lib/%s/%s\n",
           USERS_DIR, ROSTERS_DIR, format_server_type(state->server_type),
           state->server, domain, state->server, domain,
           USERS_DIR, state->server, domain,
           ROSTERS_DIR, state->server, domain,
           state->server, state->server, state->server, domain);
  }
}

void print_help() {
  printf("Usage: rtb_db -t type -c capacity -u username -p password \n"
         "              [-f format] [-r roster-size] [-hv]\n"
         "Generate database/spool files for XMPP/MQTT servers.\n\n"
         "  -t, --type         type of the server; available values are:\n"
         "                     ejabberd, metronome, mosquitto, prosody\n"
         "  -c, --capacity     total number of accounts to generate;\n"
         "                     must be an even positive integer\n"
         "  -u, --username     username pattern; must contain '%%' symbol;\n"
         "                     for XMPP servers must be in user@domain format\n"
         "  -p, --password     password pattern; may contain '%%' symbol\n"
         "  -f, --format       format of the storage: sql or flat\n"
         "  -r, --roster-size  number of items in rosters; for XMPP servers only;\n"
         "                     must be an even non-negative integer less than capacity\n"
         "  -h, --help         print this help\n"
         "  -v, --version      print version\n\n");
}

int validate_state(state_t *state, char *user) {
  if (!state->server_type) {
    fprintf(stderr, "Missing required option: -t\n");
    return -1;
  }
  if (!state->capacity) {
    fprintf(stderr, "Missing required option: -c\n");
    return -1;
  }
  if (!user) {
    fprintf(stderr, "Missing required option: -u\n");
    return -1;
  }
  if (!state->password) {
    fprintf(stderr, "Missing required option: -p\n");
    return -1;
  }
  switch (state->file_type) {
  case T_FLAT:
    if (state->server_type == T_EJABBERD) {
      fprintf(stderr, "Unexpected database type for ejabberd: flat\n"
              "Currently only 'sql' is supported.\n");
      return -1;
    }
    break;
  case T_CSV:
    if (state->server_type != T_EJABBERD) {
      fprintf(stderr, "Unexpected database type for %s: sql\n"
              "Currenty only 'flat' is supported.\n",
              format_server_type(state->server_type));
      return -1;
    }
    break;
  default:
    if (state->server_type == T_EJABBERD)
      state->file_type = T_CSV;
    else
      state->file_type = T_FLAT;
  }
  if (state->server_type == T_MOSQUITTO) {
      state->user = user;
  } else {
    char *domain = strchr(user, '@');
    if (domain && domain != user && (strlen(domain) > 1)) {
      state->user = calloc(1, strlen(user));
      state->domain = calloc(1, strlen(user));
      if (state->user && state->domain) {
        memcpy(state->user, user, domain-user);
        strcpy(state->domain, domain+1);
      } else {
        fprintf(stderr, "Memory failure");
        return -1;
      }
    } else {
      fprintf(stderr, "Invalid username: '%s'\n"
              "The option must be presented in 'user@domain' format\n", user);
      return -1;
    }
  }
  if (!strchr(state->user, '%')) {
    fprintf(stderr, "The option 'username' must contain '%%' symbol\n");
    return -1;
  }
  if (state->server_type != T_MOSQUITTO) {
    if (state->roster_size < 0 ||
        state->roster_size >= state->capacity ||
        state->roster_size % 2) {
      printf("Invalid roster size: '%s'\n"
             "It must be an even non-negative integer < capacity.\n", optarg);
      return -1;
    }
  } else if (state->roster_size) {
    fprintf(stderr, "Option roster-size is not allowed for non-XMPP servers.\n");
    return -1;
  }
  return 0;
}

state_t *mk_state(int argc, char *argv[]) {
  int opt;
  char *user = NULL;
  state_t *state = malloc(sizeof(state_t));
  if (!state) {
    fprintf(stderr, "Memory failure\n");
    return NULL;
  }
  memset(state, 0, sizeof(state_t));
  static struct option long_options[] = {
    {"type",        required_argument, 0, 't'},
    {"format",      required_argument, 0, 'f'},
    {"capacity",    required_argument, 0, 'c'},
    {"username",    required_argument, 0, 'u'},
    {"password",    required_argument, 0, 'p'},
    {"roster-size", required_argument, 0, 'r'},
    {"help",        no_argument,       0, 'h'},
    {"version",     no_argument,       0, 'v'},
    {0, 0, 0, 0}
  };
  while (1) {
    int option_index = 0;
    opt = getopt_long(argc, argv, "t:f:c:u:p:r:hv", long_options, &option_index);
    if (opt == -1)
      break;
    switch (opt) {
    case 't':
      if (!strcmp(optarg, "ejabberd")) {
        state->server_type = T_EJABBERD;
      } else if (!strcmp(optarg, "prosody")) {
        state->server_type = T_PROSODY;
      } else if (!strcmp(optarg, "metronome")) {
        state->server_type = T_METRONOME;
      } else if (!strcmp(optarg, "mosquitto")) {
        state->server_type = T_MOSQUITTO;
      } else {
        fprintf(stderr,
                "Unsupported server type: '%s'\n"
                "Available types: ejabberd, metronome, mosquitto and prosody\n",
                optarg);
        return NULL;
      }
      state->server = optarg;
      break;
    case 'f':
      if (!strcmp(optarg, "sql")) {
        state->file_type = T_CSV;
      } else if (!strcmp(optarg, "flat")) {
        state->file_type = T_FLAT;
      } else {
        fprintf(stderr, "Unexpected database type: '%s'\n", optarg);
        return NULL;
      }
      break;
    case 'c':
      state->capacity = atoi(optarg);
      if (state->capacity <= 0 || state->capacity % 2) {
        fprintf(stderr,
                "Invalid capacity: '%s'\n"
                "It must be an even positive integer\n", optarg);
        return NULL;
      }
      break;
    case 'u':
      user = optarg;
      if (!strlen(user)) {
        fprintf(stderr, "Empty username\n");
        return NULL;
      }
      break;
    case 'p':
      state->password = optarg;
      if (!strlen(state->password)) {
        fprintf(stderr, "Empty password\n");
        return NULL;
      }
      break;
    case 'r':
      state->roster_size = atoi(optarg);
      break;
    case 'v':
      printf("rtb_db %s\n", VERSION);
      return NULL;
    case 'h':
      print_help();
      return NULL;
    default:
      printf("Try '%s --help' for more information.\n", argv[0]);
      return NULL;
    }
  }

  if (validate_state(state, user))
    return NULL;
  else
    return state;
}

int main(int argc, char *argv[]) {
  int res = -1;
  state_t *state = mk_state(argc, argv);
  if (state) {
    switch (state->server_type) {
    case T_EJABBERD:
      res = generate_users_csv(state);
      if (!res) {
        res = generate_rosters_csv(state);
        if (!res)
          print_hint(state);
      }
      break;
    case T_METRONOME:
    case T_PROSODY:
      res = generate_user_files(state);
      if (!res) {
        res = generate_roster_files(state);
        if (!res)
          print_hint(state);
      }
      break;
    case T_MOSQUITTO:
      res = generate_passwd(state);
      if (!res)
        print_hint(state);
      break;
    }
  }
  free(state);
  return res;
}
