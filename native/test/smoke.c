/*
 * Host smoke test for libqfli_git.
 *
 * Runs the flow the example app uses:
 *   clone -> commit -> push -> branch -> conflicting merge -> resolve ->
 *   merge commit -> push -> clone again and verify the result.
 *
 * Then clones a small public repository over HTTPS to prove that mbedTLS
 * and the bundled CA file work.
 *
 * usage: smoke [ca-file|-] [https-url|-]
 *
 * Exits with 0 when every check passed.
 */

#include "qfli_git.h"

#include <stdio.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#define PATH_SIZE 1024

static qg_error err;

static unsigned int local_checkout_reports;

static void local_clone_progress(int stage, uint32_t completed, uint32_t total,
                                  uint64_t bytes, void *payload)
{
	unsigned int *reports = payload;
	(void)bytes;
	if (stage == 3 && total > 0 && completed == total)
		(*reports)++;
}

static const char *AUTHOR_NAME = "Qfli Git Smoke";
static const char *AUTHOR_EMAIL = "smoke@qfli.invalid";

#define CHECK(expr)                                                             \
	do {                                                                     \
		if (check((expr), #expr) < 0)                                     \
			return -1;                                                \
	} while (0)

static int check(int rc, const char *what)
{
	if (rc < 0) {
		printf("FAIL %s\n     rc=%d code=%d klass=%d message=%s\n", what, rc, err.code,
		       err.klass, err.message);
		return -1;
	}

	printf("ok   %s\n", what);
	fflush(stdout);
	return 0;
}

static int expect_code(int rc, int code, const char *what)
{
	if (rc != code) {
		printf("FAIL %s\n     expected %d, got rc=%d code=%d klass=%d message=%s\n", what, code,
		       rc, err.code, err.klass, err.message);
		return -1;
	}

	printf("ok   %s\n", what);
	fflush(stdout);
	return 0;
}

static int join_path(char *out, size_t size, const char *root, const char *name)
{
	int written = snprintf(out, size, "%s/%s", root, name);

	return (written < 0 || (size_t)written >= size) ? -1 : 0;
}

static int write_text(const char *path, const char *text)
{
	FILE *file = fopen(path, "wb");

	if (file == NULL)
		return -1;

	if (fputs(text, file) < 0) {
		fclose(file);
		return -1;
	}

	return fclose(file) == 0 ? 0 : -1;
}

static int write_bytes(const char *path, const void *data, size_t size)
{
	FILE *file = fopen(path, "wb");

	if (file == NULL)
		return -1;

	if (size > 0 && fwrite(data, 1, size, file) != size) {
		fclose(file);
		return -1;
	}

	return fclose(file) == 0 ? 0 : -1;
}

static int count_occurrences(const char *text, const char *needle)
{
	size_t length = strlen(needle);
	int count = 0;
	const char *cursor = text;

	while ((cursor = strstr(cursor, needle)) != NULL) {
		count++;
		cursor += length;
	}

	return count;
}

/* Returns a static buffer holding the file content, or NULL. */
static const char *read_text(const char *path)
{
	static char buffer[8192];
	size_t read;
	FILE *file = fopen(path, "rb");

	if (file == NULL)
		return NULL;

	read = fread(buffer, 1, sizeof(buffer) - 1, file);
	fclose(file);
	buffer[read] = '\0';

	return buffer;
}

/* Copy the "branch" value out of a qg_head_json() result. */
static int head_branch(qg_repo *repo, char *out, size_t size)
{
	char *json = NULL;
	const char *key = "\"branch\":\"";
	const char *start;
	const char *end;
	size_t length;

	CHECK(qg_head_json(repo, &json, &err));

	start = strstr(json, key);
	if (start == NULL) {
		printf("FAIL head json has no branch: %s\n", json);
		qg_string_free(json);
		return -1;
	}

	start += strlen(key);
	end = strchr(start, '"');
	if (end == NULL) {
		printf("FAIL head json is malformed: %s\n", json);
		qg_string_free(json);
		return -1;
	}

	length = (size_t)(end - start);
	if (length + 1 > size) {
		qg_string_free(json);
		return -1;
	}

	memcpy(out, start, length);
	out[length] = '\0';
	qg_string_free(json);

	return 0;
}

static int head_oid(qg_repo *repo, char out[41])
{
	char *json = NULL;
	const char *key = "\"oid\":\"";
	const char *start;

	CHECK(qg_head_json(repo, &json, &err));

	start = strstr(json, key);
	if (start == NULL || strlen(start + strlen(key)) < 40) {
		printf("FAIL head json has no oid: %s\n", json);
		qg_string_free(json);
		return -1;
	}

	memcpy(out, start + strlen(key), 40);
	out[40] = '\0';
	qg_string_free(json);

	return 0;
}

static int head_state_is(qg_repo *repo, const char *expected, const char *what)
{
	char needle[64];
	char *json = NULL;
	int rc;

	rc = qg_head_json(repo, &json, &err);
	if (rc < 0)
		return check(rc, what);

	snprintf(needle, sizeof(needle), "\"state\":\"%s\"", expected);

	if (strstr(json, needle) == NULL) {
		printf("FAIL %s: %s\n", what, json);
		qg_string_free(json);
		return -1;
	}

	printf("ok   %s\n", what);
	fflush(stdout);
	qg_string_free(json);

	return 0;
}

static int push_branch(qg_repo *repo, const char *branch)
{
	char refspec[PATH_SIZE];

	snprintf(refspec, sizeof(refspec), "refs/heads/%s:refs/heads/%s", branch, branch);

	return check(qg_push(repo, "origin", refspec, NULL, NULL, NULL, &err), "push");
}

static int test_local(const char *root)
{
	char remote[PATH_SIZE];
	char work[PATH_SIZE];
	char verify[PATH_SIZE];
	char file[PATH_SIZE];
	char other[PATH_SIZE];
	char branch[128];
	char merge_oid[41];
	char pushed_oid[41];
	char refspec[PATH_SIZE];
	char *conflicts = NULL;
	qg_repo *repo = NULL;
	qg_repo *clone = NULL;
	int result = -1;
	int status = -1;

	snprintf(remote, sizeof(remote), "%s/remote.git", root);
	snprintf(work, sizeof(work), "%s/work", root);
	snprintf(verify, sizeof(verify), "%s/verify", root);

	printf("-- bare remote and first clone\n");

	CHECK(qg_repo_init(remote, 1, &repo, &err));
	qg_repo_free(repo);
	repo = NULL;

	CHECK(qg_clone(remote, work, NULL, NULL, NULL, &repo, &err));

	CHECK(join_path(file, sizeof(file), work, "file.txt"));
	if (write_text(file, "line one\nbase\n") < 0) {
		printf("FAIL cannot write %s\n", file);
		goto done;
	}

	CHECK(qg_add_all(repo, &err));
	{
		char oid[41];

		CHECK(qg_commit(repo, "add file", AUTHOR_NAME, AUTHOR_EMAIL, oid, &err));
		if (head_branch(repo, branch, sizeof(branch)) < 0)
			goto done;
		printf("     branch is %s\n", branch);
	}

	if (head_state_is(repo, "clean", "head reports a clean repository") < 0)
		goto done;

	if (push_branch(repo, branch) < 0)
		goto done;

	printf("-- branch with a conflicting edit\n");

	CHECK(qg_branch_create(repo, "feature", NULL, &err));
	CHECK(qg_checkout_branch(repo, "feature", &err));

	if (write_text(file, "line one\nfeature\n") < 0) {
		printf("FAIL cannot write %s\n", file);
		goto done;
	}

	CHECK(qg_add_all(repo, &err));
	{
		char oid[41];

		CHECK(qg_commit(repo, "feature edit", AUTHOR_NAME, AUTHOR_EMAIL, oid, &err));
	}

	CHECK(qg_checkout_branch(repo, branch, &err));

	if (write_text(file, "line one\nmain\n") < 0) {
		printf("FAIL cannot write %s\n", file);
		goto done;
	}

	CHECK(qg_add_all(repo, &err));
	{
		char oid[41];

		CHECK(qg_commit(repo, "main edit", AUTHOR_NAME, AUTHOR_EMAIL, oid, &err));
	}

	printf("-- conflicting merge\n");

	CHECK(qg_merge(repo, "feature", AUTHOR_NAME, AUTHOR_EMAIL, &result, merge_oid, &err));
	if (result != 3) {
		printf("FAIL expected conflicts (3), got %d\n", result);
		goto done;
	}
	printf("ok   merge reports conflicts\n");

	CHECK(qg_conflicts_json(repo, &conflicts, &err));
	if (strstr(conflicts, "file.txt") == NULL) {
		printf("FAIL conflicts json does not list file.txt: %s\n", conflicts);
		goto done;
	}
	printf("ok   conflicts json lists file.txt\n");
	qg_string_free(conflicts);
	conflicts = NULL;

	if (head_state_is(repo, "merge", "head reports an open merge") < 0)
		goto done;

	{
		char oid[41];
		int rc = qg_merge_commit(repo, "too early", AUTHOR_NAME, AUTHOR_EMAIL, oid, &err);

		if (expect_code(rc, QG_ECONFLICT, "merge commit refuses open conflicts") < 0)
			goto done;
	}

	printf("-- resolve and finish the merge\n");

	if (write_text(file, "line one\nmerged\n") < 0) {
		printf("FAIL cannot write %s\n", file);
		goto done;
	}

	CHECK(qg_add_all(repo, &err));
	CHECK(qg_merge_commit(repo, "merge feature", AUTHOR_NAME, AUTHOR_EMAIL, merge_oid, &err));
	if (head_state_is(repo, "clean", "head reports no merge after the merge commit") < 0)
		goto done;

	if (head_oid(repo, pushed_oid) < 0)
		goto done;
	if (strcmp(pushed_oid, merge_oid) != 0) {
		printf("FAIL head %s does not match the merge commit %s\n", pushed_oid, merge_oid);
		goto done;
	}
	printf("ok   head points at the merge commit\n");

	if (push_branch(repo, branch) < 0)
		goto done;

	printf("-- normal merge\n");

	CHECK(qg_branch_create(repo, "side", NULL, &err));
	CHECK(qg_checkout_branch(repo, "side", &err));

	if (join_path(other, sizeof(other), work, "side.txt") < 0 ||
	    write_text(other, "side\n") < 0) {
		printf("FAIL cannot write %s\n", other);
		goto done;
	}

	CHECK(qg_add_all(repo, &err));
	{
		char oid[41];

		CHECK(qg_commit(repo, "side edit", AUTHOR_NAME, AUTHOR_EMAIL, oid, &err));
	}

	CHECK(qg_checkout_branch(repo, branch, &err));

	if (join_path(other, sizeof(other), work, "main.txt") < 0 ||
	    write_text(other, "main\n") < 0) {
		printf("FAIL cannot write %s\n", other);
		goto done;
	}

	CHECK(qg_add_all(repo, &err));
	{
		char oid[41];

		CHECK(qg_commit(repo, "main edit", AUTHOR_NAME, AUTHOR_EMAIL, oid, &err));
	}

	CHECK(qg_merge(repo, "side", AUTHOR_NAME, AUTHOR_EMAIL, &result, merge_oid, &err));
	if (result != 2) {
		printf("FAIL expected a merge commit (2), got %d\n", result);
		goto done;
	}
	printf("ok   merge creates a merge commit\n");

	if (head_state_is(repo, "clean", "head reports clean after an automatic merge") < 0)
		goto done;

	{
		char oid[41];
		int rc = qg_merge_commit(repo, "no merge", AUTHOR_NAME, AUTHOR_EMAIL, oid, &err);

		if (expect_code(rc, QG_EINVALID, "merge commit refuses a finished merge") < 0)
			goto done;
	}

	if (push_branch(repo, branch) < 0)
		goto done;

	printf("-- fast-forward and up to date\n");

	CHECK(qg_branch_create(repo, "ff", NULL, &err));
	CHECK(qg_checkout_branch(repo, "ff", &err));

	if (write_text(file, "line one\nmerged\nfast forward\n") < 0) {
		printf("FAIL cannot write %s\n", file);
		goto done;
	}

	CHECK(qg_add_all(repo, &err));
	{
		char oid[41];

		CHECK(qg_commit(repo, "ff commit", AUTHOR_NAME, AUTHOR_EMAIL, oid, &err));
	}

	CHECK(qg_checkout_branch(repo, branch, &err));

	CHECK(qg_merge(repo, "ff", AUTHOR_NAME, AUTHOR_EMAIL, &result, merge_oid, &err));
	if (result != 1) {
		printf("FAIL expected fast-forward (1), got %d\n", result);
		goto done;
	}
	printf("ok   merge fast-forwards\n");

	CHECK(qg_merge(repo, branch, AUTHOR_NAME, AUTHOR_EMAIL, &result, merge_oid, &err));
	if (result != 0) {
		printf("FAIL expected up to date (0), got %d\n", result);
		goto done;
	}
	printf("ok   merging the current branch is a no-op\n");

	if (push_branch(repo, branch) < 0)
		goto done;

	CHECK(qg_fetch(repo, "origin", NULL, NULL, NULL, &err));

	printf("-- clone again and verify\n");

	CHECK(qg_clone_with_progress(remote, verify, NULL, NULL, NULL,
	                            local_clone_progress, &local_checkout_reports, &clone, &err));
	if (local_checkout_reports == 0) {
		printf("FAIL clone did not report completed checkout\n");
		goto done;
	}

	if (join_path(file, sizeof(file), verify, "file.txt") < 0 ||
	    read_text(file) == NULL) {
		printf("FAIL cannot read the cloned file\n");
		goto done;
	}

	if (strcmp(read_text(file), "line one\nmerged\nfast forward\n") != 0) {
		printf("FAIL unexpected file content: %s\n", read_text(file));
		goto done;
	}
	printf("ok   cloned content matches\n");

	if (head_oid(clone, refspec) < 0)
		goto done;
	if (strcmp(refspec, merge_oid) != 0) {
		printf("FAIL clone head %s does not match %s\n", refspec, merge_oid);
		goto done;
	}
	printf("ok   cloned head matches the pushed fast-forward commit\n");

	status = 0;

done:
	qg_string_free(conflicts);
	qg_repo_free(clone);
	qg_repo_free(repo);
	return status;
}

static int test_api_v2(const char *root)
{
	char dir[PATH_SIZE];
	char file_a[PATH_SIZE];
	char file_b[PATH_SIZE];
	char file_bin[PATH_SIZE];
	char file_big[PATH_SIZE];
	char remote_url[PATH_SIZE];
	char branch[128];
	char needle[256];
	char *json = NULL;
	qg_repo *repo = NULL;
	const char *files[2];
	const char *single[1];
	const char *bad[1];
	FILE *big = NULL;
	int status = -1;
	int line;

	printf("-- api v2 stage, unstage, diff, log, branches and remotes\n");

	snprintf(dir, sizeof(dir), "%s/api-v2", root);
	CHECK(qg_repo_init(dir, 0, &repo, &err));

	CHECK(qg_log_json(repo, 10, &json, &err));
	if (strcmp(json, "[]") != 0) {
		printf("FAIL unborn log is not empty: %s\n", json);
		goto done;
	}
	qg_string_free(json);
	json = NULL;
	printf("ok   unborn log is empty\n");

	CHECK(qg_branches_json(repo, &json, &err));
	if (strcmp(json, "[]") != 0) {
		printf("FAIL unborn branches are not empty: %s\n", json);
		goto done;
	}
	qg_string_free(json);
	json = NULL;
	printf("ok   unborn branch list is empty\n");

	CHECK(join_path(file_a, sizeof(file_a), dir, "a.txt"));
	CHECK(join_path(file_b, sizeof(file_b), dir, "b.txt"));
	if (write_text(file_a, "one\n") < 0 || write_text(file_b, "bee\n") < 0) {
		printf("FAIL cannot write initial files\n");
		goto done;
	}

	single[0] = "a.txt";
	CHECK(qg_stage_paths(repo, single, 1, &err));

	CHECK(qg_diff_json(repo, "a.txt", 1, 262144, &json, &err));
	if (strstr(json, "new file mode") == NULL || strstr(json, "\"binary\":false") == NULL) {
		printf("FAIL unborn staged diff is wrong: %s\n", json);
		goto done;
	}
	qg_string_free(json);
	json = NULL;
	printf("ok   unborn staged diff shows a new file\n");

	CHECK(qg_unstage_paths(repo, single, 1, &err));

	CHECK(qg_status_json(repo, &json, &err));
	if (strstr(json, "\"status\":\"worktree_new\"") == NULL) {
		printf("FAIL unborn unstage did not leave an untracked file: %s\n", json);
		goto done;
	}
	qg_string_free(json);
	json = NULL;
	if (read_text(file_a) == NULL) {
		printf("FAIL unborn unstage removed the work tree file\n");
		goto done;
	}
	printf("ok   unborn unstage keeps the work tree file\n");

	bad[0] = "../escape.txt";
	if (expect_code(qg_stage_paths(repo, bad, 1, &err), QG_EINVALID, "traversal rejected") < 0)
		goto done;

	files[0] = "a.txt";
	files[1] = "b.txt";
	CHECK(qg_stage_paths(repo, files, 2, &err));
	{
		char oid[41];

		CHECK(qg_commit(repo, "initial commit", AUTHOR_NAME, AUTHOR_EMAIL, oid, &err));
	}

	if (head_branch(repo, branch, sizeof(branch)) < 0)
		goto done;

	CHECK(qg_branches_json(repo, &json, &err));
	snprintf(needle, sizeof(needle), "\"name\":\"%s\"", branch);
	if (strstr(json, needle) == NULL || strstr(json, "\"current\":true") == NULL) {
		printf("FAIL branches json is wrong: %s\n", json);
		goto done;
	}
	qg_string_free(json);
	json = NULL;
	printf("ok   branches json marks the current branch\n");

	CHECK(qg_log_json(repo, 10, &json, &err));
	if (strstr(json, "\"message\":\"initial commit\"") == NULL ||
	    strstr(json, "\"authorName\":\"Qfli Git Smoke\"") == NULL ||
	    strstr(json, "\"authorEmail\":\"smoke@qfli.invalid\"") == NULL ||
	    strstr(json, "\"time\":") == NULL) {
		printf("FAIL log json is wrong: %s\n", json);
		goto done;
	}
	qg_string_free(json);
	json = NULL;
	printf("ok   log json carries commit metadata\n");

	if (write_text(file_a, "two\n") < 0 || remove(file_b) != 0) {
		printf("FAIL cannot modify a.txt or delete b.txt\n");
		goto done;
	}

	CHECK(qg_stage_paths(repo, files, 2, &err));

	CHECK(qg_diff_json(repo, "a.txt", 1, 262144, &json, &err));
	if (strstr(json, "\"patch\":\"diff --git") == NULL ||
	    strstr(json, "\"binary\":false") == NULL) {
		printf("FAIL staged modification diff is wrong: %s\n", json);
		goto done;
	}
	qg_string_free(json);
	json = NULL;

	CHECK(qg_diff_json(repo, "b.txt", 1, 262144, &json, &err));
	if (strstr(json, "deleted file mode") == NULL ||
	    strstr(json, "\"truncated\":false") == NULL) {
		printf("FAIL staged deletion diff is wrong: %s\n", json);
		goto done;
	}
	qg_string_free(json);
	json = NULL;
	printf("ok   staged diff renders modification and deletion\n");

	CHECK(qg_unstage_paths(repo, files, 2, &err));

	CHECK(qg_diff_json(repo, "b.txt", 1, 262144, &json, &err));
	if (strstr(json, "\"patch\":\"\"") == NULL) {
		printf("FAIL unstage did not reset the index: %s\n", json);
		goto done;
	}
	qg_string_free(json);
	json = NULL;

	CHECK(qg_status_json(repo, &json, &err));
	if (strstr(json, "\"status\":\"worktree_modified\"") == NULL ||
	    strstr(json, "\"status\":\"worktree_deleted\"") == NULL) {
		printf("FAIL unstage did not preserve the work tree: %s\n", json);
		goto done;
	}
	qg_string_free(json);
	json = NULL;

	if (read_text(file_a) == NULL || strcmp(read_text(file_a), "two\n") != 0) {
		printf("FAIL unstage changed a.txt\n");
		goto done;
	}
	if (read_text(file_b) != NULL) {
		printf("FAIL unstage restored the deleted b.txt\n");
		goto done;
	}
	printf("ok   unstage preserves work tree changes\n");

	CHECK(qg_stage_paths(repo, files, 2, &err));
	{
		char oid[41];

		CHECK(qg_commit(repo, "second commit", AUTHOR_NAME, AUTHOR_EMAIL, oid, &err));
	}

	CHECK(join_path(file_bin, sizeof(file_bin), dir, "bin.dat"));
	{
		const char binary_data[] = { 'a', '\0', 'b', '\0', '\n' };

		if (write_bytes(file_bin, binary_data, sizeof(binary_data)) < 0) {
			printf("FAIL cannot write bin.dat\n");
			goto done;
		}
	}
	single[0] = "bin.dat";
	CHECK(qg_stage_paths(repo, single, 1, &err));
	CHECK(qg_diff_json(repo, "bin.dat", 1, 262144, &json, &err));
	if (strstr(json, "\"binary\":true") == NULL) {
		printf("FAIL binary diff is not labelled: %s\n", json);
		goto done;
	}
	qg_string_free(json);
	json = NULL;
	printf("ok   binary diff is labelled\n");

	CHECK(join_path(file_big, sizeof(file_big), dir, "big.txt"));
	big = fopen(file_big, "wb");
	if (big == NULL) {
		printf("FAIL cannot write big.txt\n");
		goto done;
	}
	for (line = 0; line < 200; line++) {
		if (fprintf(big, "line %03d abcdefghijklmnopqrstuvwxyz\n", line) < 0) {
			printf("FAIL cannot write big.txt\n");
			goto done;
		}
	}
	if (fclose(big) != 0) {
		big = NULL;
		printf("FAIL cannot close big.txt\n");
		goto done;
	}
	big = NULL;

	single[0] = "big.txt";
	CHECK(qg_stage_paths(repo, single, 1, &err));
	CHECK(qg_diff_json(repo, "big.txt", 1, 128, &json, &err));
	if (strstr(json, "\"truncated\":true") == NULL || strlen(json) > 4096) {
		printf("FAIL bounded diff is wrong: %s\n", json);
		goto done;
	}
	qg_string_free(json);
	json = NULL;
	printf("ok   diff is truncated at the byte bound\n");

	snprintf(remote_url, sizeof(remote_url), "%s/remote.git", root);
	CHECK(qg_remote_set_url(repo, "origin", remote_url, &err));
	CHECK(qg_remotes_json(repo, &json, &err));
	if (strstr(json, "\"name\":\"origin\"") == NULL || strstr(json, remote_url) == NULL) {
		printf("FAIL remotes json is wrong: %s\n", json);
		goto done;
	}
	qg_string_free(json);
	json = NULL;

	if (expect_code(qg_remote_set_url(repo, "origin",
	                                  "https://user:secret@example.com/repo.git", &err),
	                QG_EINVALID, "credential URL rejected") < 0)
		goto done;

	CHECK(qg_remote_set_url(repo, "origin", remote_url, &err));
	printf("ok   remotes json and url updates work\n");

	CHECK(qg_log_json(repo, 1, &json, &err));
	if (count_occurrences(json, "\"oid\":") != 1) {
		printf("FAIL log limit was not honoured: %s\n", json);
		goto done;
	}
	qg_string_free(json);
	json = NULL;
	printf("ok   log limit is honoured\n");

	status = 0;

done:
	qg_string_free(json);
	if (big != NULL)
		fclose(big);
	qg_repo_free(repo);
	return status;
}

typedef struct {
	pthread_mutex_t mutex;
	pthread_cond_t condition;
	int ready;
	int start;
} clone_start_gate;

typedef struct {
	clone_start_gate *gate;
	const char *url;
	char target[PATH_SIZE];
	qg_error error;
	int rc;
	unsigned int reports;
	unsigned int receiving_reports;
} https_clone_worker;

static void https_clone_progress(int stage, uint32_t completed, uint32_t total,
                                  uint64_t bytes, void *payload)
{
	https_clone_worker *worker = payload;
	(void)completed;
	(void)total;
	(void)bytes;
	worker->reports++;
	if (stage == 1)
		worker->receiving_reports++;
}

static void *run_https_clone(void *payload)
{
	https_clone_worker *worker = payload;
	qg_repo *repo = NULL;
	pthread_mutex_lock(&worker->gate->mutex);
	worker->gate->ready++;
	pthread_cond_broadcast(&worker->gate->condition);
	while (!worker->gate->start)
		pthread_cond_wait(&worker->gate->condition, &worker->gate->mutex);
	pthread_mutex_unlock(&worker->gate->mutex);
	worker->rc = qg_clone_with_progress(worker->url, worker->target, NULL, NULL, NULL,
	                                     https_clone_progress, worker, &repo, &worker->error);
	qg_repo_free(repo);
	return NULL;
}

static int test_https(const char *root, const char *url)
{
	clone_start_gate gate = { PTHREAD_MUTEX_INITIALIZER, PTHREAD_COND_INITIALIZER, 0, 0 };
	https_clone_worker workers[2];
	pthread_t threads[2];
	int created = 0, i, rc = 0;

	printf("-- two simultaneous anonymous https clones\n");
	memset(workers, 0, sizeof(workers));
	for (i = 0; i < 2; i++) {
		workers[i].gate = &gate;
		workers[i].url = url;
		snprintf(workers[i].target, sizeof(workers[i].target), "%s/https-%d", root, i);
		if (pthread_create(&threads[i], NULL, run_https_clone, &workers[i]) != 0) {
			rc = -1;
			break;
		}
		created++;
	}
	pthread_mutex_lock(&gate.mutex);
	while (gate.ready < created)
		pthread_cond_wait(&gate.condition, &gate.mutex);
	gate.start = 1;
	pthread_cond_broadcast(&gate.condition);
	pthread_mutex_unlock(&gate.mutex);
	for (i = 0; i < created; i++) {
		pthread_join(threads[i], NULL);
		if (workers[i].rc != 0 || workers[i].receiving_reports == 0) {
			printf("FAIL https clone %d rc=%d reports=%u: %s\n", i, workers[i].rc,
			       workers[i].reports, workers[i].error.message);
			rc = -1;
		}
	}
	pthread_cond_destroy(&gate.condition);
	pthread_mutex_destroy(&gate.mutex);
	if (rc == 0)
		printf("ok   both HTTPS clones completed with independent progress\n");
	return rc;
}

int main(int argc, char **argv)
{
	char root_template[PATH_SIZE];
	char root[PATH_SIZE];
	const char *ca_file = NULL;
	const char *https_url = "https://github.com/libgit2/TestGitRepository";
	const char *tmp = getenv("TMPDIR");
	size_t length;
	int rc = 0;

	printf("qfli_git smoke test\n");
	printf("     qg_api_version     %d\n", qg_api_version());
	printf("     libgit2            %s\n", qg_libgit2_version());
	printf("     mbedtls            %s\n", qg_mbedtls_version());

	if (argc > 1 && strcmp(argv[1], "-") != 0)
		ca_file = argv[1];
	else if (fopen("assets/cacert.pem", "rb") != NULL)
		ca_file = "assets/cacert.pem";

	if (argc > 2)
		https_url = strcmp(argv[2], "-") == 0 ? NULL : argv[2];

	if (ca_file != NULL) {
		FILE *probe = fopen(ca_file, "rb");

		if (probe == NULL) {
			printf("FAIL cannot open CA file %s\n", ca_file);
			return 1;
		}
		fclose(probe);
		printf("     ca file            %s\n", ca_file);
	}

	CHECK(qg_init(ca_file, &err));

	if (tmp == NULL || tmp[0] == '\0')
		tmp = "/tmp";

	length = strlen(tmp);
	while (length > 1 && tmp[length - 1] == '/')
		length--;

	snprintf(root_template, sizeof(root_template), "%.*s/qfli-git-smoke-XXXXXX", (int)length,
	         tmp);

	if (mkdtemp(root_template) == NULL) {
		printf("FAIL cannot create a temporary directory\n");
		qg_shutdown();
		return 1;
	}

	snprintf(root, sizeof(root), "%s", root_template);
	printf("     work directory     %s\n", root);

	if (test_local(root) < 0) {
		printf("FAIL local flow failed, directory kept for inspection\n");
		qg_shutdown();
		return 1;
	}

	if (test_api_v2(root) < 0) {
		printf("FAIL api v2 flow failed, directory kept for inspection\n");
		qg_shutdown();
		return 1;
	}

	if (https_url != NULL && test_https(root, https_url) < 0) {
		printf("FAIL https flow failed, directory kept for inspection\n");
		qg_shutdown();
		return 1;
	}

	{
		char command[PATH_SIZE + 32];

		snprintf(command, sizeof(command), "rm -rf '%s'", root);
		if (system(command) != 0)
			printf("     note: cannot remove %s\n", root);
	}

	qg_shutdown();

	printf("PASS\n");
	return rc;
}
