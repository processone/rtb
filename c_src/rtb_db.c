#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <sys/stat.h>

#define USERS_CSV_FILE "/tmp/users.csv"
#define ROSTERS_CSV_FILE "/tmp/rosters.csv"
#define USERS_DIR "/tmp/accounts/"
#define ROSTERS_DIR "/tmp/roster/"

typedef enum {T_EJABBERD, T_PROSODY} server_type;
typedef enum {T_CSV, T_FLAT} file_type;

char *timestamp() {
  return "1970-01-01 00:00:00";
}

char *replace(char *str) {
  ssize_t len = strlen(str);
  char *buf = calloc(1, 1000);
  if (buf) {
    int i = 0, j = 0;
    while (i<len) {
      if (str[i] == '%') {
	buf[j++] = '%';
	buf[j++] = 'l';
	buf[j++] = 'u';
      } else {
	buf[j++] = str[i];
      }
      i++;
    }
  }
  return buf;
}

char *mk_user_csv_row(char *argv[]) {
  char *user = argv[4];
  char *password = argv[6];
  char *buf = calloc(1, 1000);
  char *res = NULL;
  if (buf) {
    sprintf(buf, "\"%s\",\"%s\",\"\",\"\",\"0\",\"%s\"\n", user, password, timestamp());
    res = replace(buf);
  }
  return res;
}

char *mk_roster_csv_row(char *argv[]) {
  char *user = argv[4];
  char *server = argv[5];
  char *buf = calloc(1, 1000);
  char *res = NULL;
  if (buf) {
    sprintf(buf,
	    "\"%s\",\"%s@%s\",\"%s\",\"B\",\"N\",\"\",\"N\",\"\",\"item\",\"%s\"\n",
	    user, user, server, user, timestamp());
    res = replace(buf);
  }
  return res;
}

char *mk_user_dat(char *argv[]) {
  char *password = argv[6];
  char *buf = calloc(1, 1000);
  char *res = NULL;
  if (buf) {
    sprintf(buf, "return {\n\t[\"password\"] = \"%s\";\n};\n", password);
    res = replace(buf);
  }
  return res;
}

int generate_users_csv(long int capacity, char *argv[]) {
  FILE *fd = fopen(USERS_CSV_FILE, "w");
  if (!fd) {
    printf("Failed to open file %s for writing: %s\n", USERS_CSV_FILE, strerror(errno));
    return errno;
  }

  printf("Generating %s... ", USERS_CSV_FILE);
  fflush(stdout);
  char *pattern = mk_user_csv_row(argv);
  if (pattern) {
    for (long int i=1; i<=capacity; i++) {
      if (fprintf(fd, pattern, i, i) < 0) {
	printf("Failed to write to file %s: %s\n", USERS_CSV_FILE, strerror(errno));
	return errno;
      }
    }
    printf("done\n");
    return 0;
  } else {
    printf("Failed to generate CSV row for %s: %s\n", USERS_CSV_FILE, strerror(ENOMEM));
    return ENOMEM;
  }
}

int generate_rosters_csv(long int capacity, char *argv[]) {
  FILE *fd = fopen(ROSTERS_CSV_FILE, "w");
  if (!fd) {
    printf("Failed to open file %s for writing: %s\n", ROSTERS_CSV_FILE, strerror(errno));
    return errno;
  }

  printf("Generating %s... ", ROSTERS_CSV_FILE);
  fflush(stdout);
  long int i, j, next, prev;
  char *pattern = mk_roster_csv_row(argv);
  if (pattern) {
    for (i=1; i<=capacity; i++) {
      for (j=1; j<=10; j++) {
	next = i + j;
	next = (next > capacity) ? (next - capacity): next;
	prev = (i <= j) ? capacity - (j - 1) : i-j;
	if ((fprintf(fd, pattern, i, next, next) < 0) ||
	    (fprintf(fd, pattern, i, prev, prev) < 0)) {
	  printf("Failed to write to file %s: %s\n", ROSTERS_CSV_FILE, strerror(errno));
	  return errno;
	}
      }
    }
    printf("done\n");
    return 0;
  } else {
    printf("Failed to generate CSV row for %s: %s\n", USERS_CSV_FILE, strerror(ENOMEM));
    return ENOMEM;
  }
}

int generate_user_files(long int capacity, char *argv[]) {
  int res = mkdir(USERS_DIR, 0755);
  if (res && errno != EEXIST) {
    printf("res = %d\n", res);
    printf("Failed to create directory %s: %s\n", USERS_DIR, strerror(errno));
    return errno;
  }

  printf("Generating accounts in %s... ", USERS_DIR);
  fflush(stdout);
  long int i;
  FILE *fd;
  ssize_t dir_len = strlen(USERS_DIR);
  char *password = mk_user_dat(argv);
  char *user = replace(argv[4]);
  char *file = calloc(1, 1000);
  strcpy(user+strlen(user), ".dat");
  strcpy(file, USERS_DIR);
  if (password && user && file) {
    for (i=1; i<=capacity; i++) {
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
  } else {
    printf("Failed to generate content for user*.dat: %s\n", strerror(ENOMEM));
    return ENOMEM;
  }
}

void print_hint(file_type t) {
  if (t == T_CSV) {
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
  }
}

int main(int argc, char *argv[]) {
  if (argc != 7) {
    printf("Usage: %s ejabberd|prosody sql|flat capacity user server password\n", argv[0]);
    return -1;
  }
  int res = 0;
  long int capacity = strtol(argv[3], NULL, 10);
  if (capacity >= 22) {
    if (!strcmp(argv[1], "ejabberd")) {
      if (!strcmp(argv[2], "sql")) {
	res = generate_users_csv(capacity, argv);
	if (!res) {
	  res = generate_rosters_csv(capacity, argv);
	  if (!res) {
	    print_hint(T_CSV);
	  }
	}
      } else {
	printf("Usupported ejabberd database type: %s\n", argv[2]);
	res = -1;
      }
    } else if (!strcmp(argv[1], "prosody")) {
      if (!strcmp(argv[2], "flat")) {
	res = generate_user_files(capacity, argv);
      } else {
	printf("Usupported Prosody database type: %s\n", argv[2]);
	res = -1;
      }
    } else {
      printf("Unsupported server type: %s\n", argv[1]);
      res = -1;
    }
  } else {
    printf("Invalid capacity: %s\n", argv[3]);
    res = -1;
  }

  return res;
}
