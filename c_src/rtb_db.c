#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <sys/stat.h>

#define BUFSIZE 65535
#define USERS_CSV_FILE "/tmp/users.csv"
#define ROSTERS_CSV_FILE "/tmp/rosters.csv"
#define USERS_DIR "/tmp/accounts/"
#define ROSTERS_DIR "/tmp/roster/"

typedef enum {T_EJABBERD, T_METRONOME, T_PROSODY} server_type;
typedef enum {T_CSV, T_FLAT} file_type;

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
  default: return "Prosody";
  }
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

void mk_user_csv_row(char *row, state_t *state) {
  char *user = state->user;
  char *password = state->password;
  char buf[BUFSIZE];
  memset(buf, 0, BUFSIZE);
  sprintf(buf, "\"%s\",\"%s\",\"\",\"\",\"0\",\"%s\"\n", user, password, timestamp());
  replace(row, buf, '%', "%lu");
}

void mk_roster_csv_row(char *row, state_t *state) {
  char *user = state->user;
  char *domain = state->domain;
  char buf[BUFSIZE];
  sprintf(buf,
	  "\"%s\",\"%s@%s\",\"%s\",\"B\",\"N\",\"\",\"N\",\"\",\"item\",\"%s\"\n",
	  user, user, domain, user, timestamp());
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
    printf("Failed to open file %s for writing: %s\n", USERS_CSV_FILE, strerror(errno));
    return errno;
  }

  printf("Generating %s... ", USERS_CSV_FILE);
  fflush(stdout);
  char row[BUFSIZE];
  mk_user_csv_row(row, state);
  for (int i=1; i<=state->capacity; i++) {
    if (fprintf(fd, row, i, i) < 0) {
      printf("Failed to write to file %s: %s\n", USERS_CSV_FILE, strerror(errno));
      return errno;
    }
  }
  printf("done\n");
  return 0;
}

int generate_rosters_csv(state_t *state) {
  FILE *fd = fopen(ROSTERS_CSV_FILE, "w");
  if (!fd) {
    printf("Failed to open file %s for writing: %s\n", ROSTERS_CSV_FILE, strerror(errno));
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
	printf("Failed to write to file %s: %s\n", ROSTERS_CSV_FILE, strerror(errno));
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
    printf("res = %d\n", res);
    printf("Failed to create directory %s: %s\n", USERS_DIR, strerror(errno));
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
      printf("Failed to open file %s for writing: %s\n", file, strerror(errno));
      return errno;
    }
    if (fprintf(fd, password, i) < 0) {
      printf("Failed to write to file %s: %s\n", file, strerror(errno));
      return errno;
    }
    fclose(fd);
  }
  printf("done\n");
  return 0;
}

int generate_roster_files(state_t *state) {
  int res = mkdir(ROSTERS_DIR, 0755);
  if (res && errno != EEXIST) {
    printf("res = %d\n", res);
    printf("Failed to create directory %s: %s\n", ROSTERS_DIR, strerror(errno));
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
      printf("Failed to open file %s for writing: %s\n", file, strerror(errno));
      return errno;
    }
    if (fprintf(fd,
		"return {\n\t[false] = {\n\t\t[\"version\"] = 1;\n"
		"\t\t[\"pending\"] = {};\n\t};\n") < 0) {
      printf("Failed to write to file %s: %s\n", file, strerror(errno));
      return errno;
    }
    for (j=1; j<=roster_size; j++) {
      next = i + j;
      next = (next > state->capacity) ? (next % state->capacity): next;
      prev = (i <= j) ? state->capacity - (j - 1) : i-j;
      if ((fprintf(fd, roster, next, next) < 0) ||
	  (fprintf(fd, roster, prev, prev) < 0)) {
	printf("Failed to write to file %s: %s\n", file, strerror(errno));
	return errno;
      }
    }
    if (fprintf(fd, "};\n") < 0) {
      printf("Failed to write to file %s: %s\n", file, strerror(errno));
      return errno;
    }
    fclose(fd);
  }
  printf("done\n");
  return 0;
}

void print_hint(state_t *state) {
  if (state->file_type == T_CSV) {
    char *mysql_cmd =
      " LOAD DATA LOCAL INFILE '%s'\n"
      "   INTO TABLE %s FIELDS TERMINATED BY ','\n"
      "   ENCLOSED BY '\"' LINES TERMINATED BY '\\n';\n";
    char *pgsql_cmd = " \\copy %s FROM '%s' WITH CSV QUOTE AS '\"';\n";

    printf("Now execute the following SQL commands:\n");
    printf("** MySQL:\n");
    printf(mysql_cmd, USERS_CSV_FILE, "users");
    printf(mysql_cmd, ROSTERS_CSV_FILE, "rosterusers");
    printf("** PostgreSQL:\n");
    printf(pgsql_cmd, "users", USERS_CSV_FILE);
    printf(pgsql_cmd, "rosterusers", ROSTERS_CSV_FILE);
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

state_t *mk_state(int argc, char *argv[]) {
  state_t *state = malloc(sizeof(state_t));
  if (!state) {
    printf("Failed to allocate %lu bytes of memory\n", sizeof(state_t));
    return NULL;
  }
  if (argc != 7 && argc != 8) {
    printf("Usage: %s ejabberd|prosody|metronome sql|flat "
	   "capacity user server password [roster-size]\n", argv[0]);
    return NULL;
  }
  state->capacity = atoi(argv[3]);
  if (state->capacity <= 0 || state->capacity % 2) {
    printf("Invalid capacity: %s. It must be an even positive integer.\n", argv[3]);
    return NULL;
  }
  state->server = argv[1];
  if (!strcmp(state->server, "ejabberd")) {
    state->server_type = T_EJABBERD;
  } else if (!strcmp(state->server, "prosody")) {
    state->server_type = T_PROSODY;
  } else if (!strcmp(state->server, "metronome")) {
    state->server_type = T_METRONOME;
  } else {
    printf("Unsupported server type: %s. "
	   "It must be: ejabberd, metronome or prosody.\n", state->server);
    return NULL;
  }
  if (state->server_type == T_EJABBERD) {
    if (!strcmp(argv[2], "sql")) {
      state->file_type = T_CSV;
    } else {
      printf("Usupported ejabberd database type: %s. "
	     "Currently only 'sql' is supported.\n", argv[2]);
      return NULL;
    }
  } else {
    if (!strcmp(argv[2], "flat")) {
      state->file_type = T_FLAT;
    } else {
      printf("Usupported %s database type: %s. "
	     "Currently only 'flat' is supported.\n",
	     format_server_type(state->server_type), argv[2]);
      return NULL;
    }
  }
  state->user = argv[4];
  state->domain = argv[5];
  state->password = argv[6];
  if (argc == 8)
    state->roster_size = atoi(argv[7]);
  else
    state->roster_size = (state->capacity >= 22) ? 20 : 2*((state->capacity / 2)-1);
  if (state->roster_size <= 0 ||
      state->roster_size >= state->capacity ||
      state->roster_size % 2) {
    printf("Invalid roster size: %s. "
	   "It must be an even positive integer < capacity.\n", argv[7]);
    return NULL;
  }
  return state;
}

int main(int argc, char *argv[]) {
  state_t *state = mk_state(argc, argv);
  if (state) {
    int res = 0;
    switch (state->server_type) {
    case T_EJABBERD:
      res = generate_users_csv(state);
      if (!res) {
	res = generate_rosters_csv(state);
	if (!res) {
	  print_hint(state);
	}
      }
      return res;
    case T_METRONOME:
    case T_PROSODY:
      res = generate_user_files(state);
      if (!res) {
	res = generate_roster_files(state);
	if (!res) {
	  print_hint(state);
	}
      }
      return res;
    }
  }
  return -1;
}
